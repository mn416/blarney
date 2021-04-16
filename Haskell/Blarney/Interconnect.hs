{-# LANGUAGE DataKinds              #-}
{-# LANGUAGE Rank2Types             #-}
{-# LANGUAGE DeriveGeneric          #-}
{-# LANGUAGE BlockArguments         #-}
{-# LANGUAGE DeriveAnyClass         #-}
{-# LANGUAGE TypeApplications       #-}
{-# LANGUAGE RebindableSyntax       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE ScopedTypeVariables    #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE FunctionalDependencies #-}

{-|
Module      : Blarney.Interconnect
Description : Interconnect library
Copyright   : (c) Matthew Naylor, 2020
License     : MIT
Maintainer  : mattfn@gmail.com
Stability   : experimental
-}
module Blarney.Interconnect where

-- Blarney imports
import Blarney
import Blarney.Queue
import Blarney.Stream

-- Generic imports
import Control.Applicative

-- Stream mergers and switches
-- ===========================

-- | Unbuffered left-biased merge of two streams
mergeTwo :: Bits a => Stream a -> Stream a -> Stream a
mergeTwo s0 s1 =
  Source {
    canPeek = s0.canPeek .|. s1.canPeek
  , peek    = s0.canPeek ? (s0.peek, s1.peek)
  , consume = if s0.canPeek then s0.consume else s1.consume
  }

-- | Unbuffered sequential left-biased merge of multiple sources
mergeChain :: Bits a => [Stream a] -> Stream a
mergeChain = foldr mergeTwo nullStream

-- | Unbuffered parallel tree merge of multiple streams,
-- where each merger is left biased
mergeTree :: Bits a => [Stream a] -> Stream a
mergeTree = tree mergeTwo nullStream

-- | Shorthand for a two-way switch
type TwoWaySwitch a =
     (a -> Bit 1)                 -- ^ Routing function
  -> (Stream a, Stream a)         -- ^ Input streams
  -> Module (Stream a, Stream a)  -- ^ Output streams

-- | Buffered fair merger of two streams
makeGenericFairMergeTwo :: Bits a =>
     Module (Queue a)     -- ^ Queue kind to use for buffering
  -> (a -> Bit 1)         -- ^ Guard on whether data is consumed by merger
  -> (Stream a, Stream a) -- ^ Input streams to be merged
  -> Module (Stream a)    -- ^ Output stream
makeGenericFairMergeTwo makeQueue g (origInA, origInB) = do
  -- Output buffer
  buffer <- makeQueue

  -- Apply guard
  let inA = guardStream g origInA
  let inB = guardStream g origInB

  -- Was previous output taken from stream A?
  prevChoiceWasA :: Reg (Bit 1) <- makeReg false

  always do
    when (buffer.notFull) do
      -- Take next input from stream B?
      let chooseB = inB.canPeek .&. (inA.canPeek.inv .|. prevChoiceWasA.val)
      -- Consume input
      if chooseB
        then do inB.consume
        else when (inA.canPeek) do inA.consume
      -- Produce output
      when (inA.canPeek .|. inB.canPeek) do
        enq buffer (chooseB ? (inB.peek, inA.peek))
        prevChoiceWasA <== inv chooseB

  return (buffer.toStream)

-- | Buffered fair switch between two streams, based on routing function
makeFairExchange :: Bits a =>
     Module (Queue a)            -- ^ Queue kind to use for buffering
  -> (a -> Bit 1)                -- ^ Routing function
  -> (Stream a, Stream a)        -- ^ Input streams
  -> Module (Stream a, Stream a) -- ^ Output streams
makeFairExchange q route (inA, inB) = do
  -- Determine first output
  outA <- makeGenericFairMergeTwo q (\x -> inv (route x)) (inA, inB)
  -- Determine second output
  outB <- makeGenericFairMergeTwo q route (inA, inB)
  return (outA, outB)

-- | Optionally broadcast items from an input stream into two output
-- streams.  If an item is to be broadcast, then *both* consumers must
-- eventually consume it (perhaps at different times).
makeTwoWayBroadcast :: Bits a =>
     (a -> Bit 1)                 -- ^ Broadcast condition
  -> Stream a                     -- ^ Input stream
  -> Module (Stream a, Stream a)  -- ^ Output streams
makeTwoWayBroadcast isBroadcast streamIn = do
  -- Pulsed when data is consumed from an output stream
  consume0 <- makeWire false
  consume1 <- makeWire false

  -- If the current item is to be broadcast, and one of the consumers
  -- has already consumed it, then this register is true
  waiting <- makeReg false

  -- If we're waiting, then this register indicates the consumer that
  -- has not yet consumed the current item
  waitingFor :: Reg (Bit 1) <- makeReg dontCare

  -- State machine
  always do
    when (streamIn.canPeek) do
      if streamIn.peek.isBroadcast
        then do
          -- Broadcast
          if waiting.val
            then do
              -- If we're waiting and a consumer consumes, we're done
              when (consume0.val .||. consume1.val) do
                streamIn.consume
                waiting <== false
            else do
              -- If we're not waiting, and both consumers consume, we're done
              when (consume0.val .&&. consume1.val) do
                streamIn.consume
              -- If we're not waiting, and 1 consumer consumes, we must wait
              when (consume0.val .^. consume1.val) do
                waiting <== true
                waitingFor <== consume1.val
        else do
          -- No broadcast, just consume immediately
          when (consume0.val .||. consume1.val) do
            streamIn.consume

  -- First output stream
  let out0 =
        Source {
          peek = streamIn.peek
        , canPeek = streamIn.canPeek .&&.
                      (waiting.val .==>. waitingFor.val .==. 0)
        , consume = consume0 <== true
        }

  -- Second output stream
  let out1 =
        Source {
          peek = streamIn.peek
        , canPeek = streamIn.canPeek .&&.
                      (waiting.val .==>. waitingFor.val .==. 1)
        , consume = consume1 <== true
        }

  return (out0, out1)

-- | Buffered fair switch between two streams, based on routing
-- function, with optional broadcast
makeFairExchangeWithBroadcast :: Bits a =>
     Module (Queue a)            -- ^ Queue kind to use for buffering
  -> (a -> Bit 1)                -- ^ Broadcast condition
  -> (a -> Bit 1)                -- ^ Routing function
  -> (Stream a, Stream a)        -- ^ Input streams
  -> Module (Stream a, Stream a) -- ^ Output streams
makeFairExchangeWithBroadcast q bcast route (inA, inB) = do
  -- Insert broadcasters
  (inA0, inA1) <- makeTwoWayBroadcast bcast inA
  (inB0, inB1) <- makeTwoWayBroadcast bcast inB
  -- Determine first output
  outA <- makeGenericFairMergeTwo q
            (\x -> inv (route x) .||. bcast x) (inA0, inB0)
  -- Determine second output
  outB <- makeGenericFairMergeTwo q
            (\x -> route x .||. bcast x) (inA1, inB1)
  return (outA, outB)

-- Shuffle Exchange network
-- ========================

-- | Shuffle Exchange network.  Data from a set of input streams is
-- routed to a set of output streams based on a routing function.  The
-- number of streams in and out must be a power of two.  The number of
-- 2-input muxes used is N * log(N), where N is the number of stream
-- inputs.  The latency of the network is log(N), assuming no
-- congestion and no routing clashes.  This is useful to implement
-- network switches thar are too large to be handled by a crossbar
-- (which would require N*N 2-input muxes).  The throughput will not
-- match that of a crossbar in general, but the network is capable of
-- handling a large number of simultaneous connections. When the
-- routing pattern is a shift or rotation (by any amount), the
-- throughput is equivalent to that of a full crossbar.  Indeed, the
-- network is similar to that found in a barrel shifter.
makeShuffleExchange :: forall n a. (KnownNat n, Bits a) =>
     TwoWaySwitch a    -- ^ Primitive two-way switch
  -> (a -> Bit n)      -- ^ Routing function
  -> [Stream a]        -- ^ Input streams
  -> Module [Stream a] -- ^ Output streams
makeShuffleExchange switch route ins
  | length ins == 2 ^ valueOf @n = shuffEx (valueOf @n) ins
  | otherwise = error $
      "Blarney.Interconnect.makeShuffleExchange: " ++
      " number of streams not consistent with routing function"
  where
    shuffEx 0 xs = return xs
    shuffEx i xs = do
      -- Split inputs into two halves
      let n = 2 ^ (i-1)
      let top = take n xs
      let bottom = drop n xs

      -- Recurse
      ts <- shuffEx (i-1) top
      bs <- shuffEx (i-1) bottom

      -- Combine using MSB of routing function
      let merge = switch (\x -> unsafeAt (i-1) (route x))
      (ts', bs') <- unzip <$> mapM merge (zip ts bs)
      return (ts' ++ bs')
