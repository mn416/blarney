-- Emit netlist in C format

module Blarney.EmitC
  ( printC
  , writeC
  ) where

import Blarney.Unbit
import Data.Array
import System.IO

-- Emit C code to standard out
printC :: [Net] -> IO ()
printC = hWriteC stdout

-- Emit C code to file
writeC :: String -> [Net] -> IO ()
writeC filename netlist = do
  h <- openFile filename WriteMode
  hWriteC h netlist
  hClose h

-- Extract state variables (that are updated on each cycle) from net
getStateVars :: Net -> [WireId]
getStateVars net =
  case netPrim net of
    Register i w   -> [(netInstId net, 0)]
    RegisterEn i w -> [(netInstId net, 0)]
    other          -> []

-- This pass introduces temporary state variables, where necessary, so
-- that parallel state updates can be performed sequentially
sequentialise :: [Net] -> [Net]
sequentialise nets = newAssigns ++ newNets
  where
    -- Number of nets
    n = length nets

    -- Array mapping net ids to nets
    --netArray = array (0, n-1) [(netInstId net, net) | net <- nets]

    -- Lookup net with given id
    --lookup i = netArray ! i

    -- Mapping from wires to new wires
    subst = [(w, (id, 0)) | (w, id) <- zip toSave [n..]]
    substMap = M.fromList subst

    -- New temporary-variable assignments
    newAssigns = [ Net { netPrim   = Id
                       , netInstId = fst newWire
                       , netInputs = [wire] }
                 | (wire, newWire) <- subst]

    -- Determine state vars that need to be saved
    toSave = S.toList (save S.empty S.empty stateNets)

    save modSet saveSet [] = saveSet
    save modSet saveSet (net:nets) = save modSet' saveSet' nets
      where
        modSet' = foldr S.insert modSet (getStateVars net)
        saveSet' = foldr S.insert saveSet
                     [wire | wire <- netInputs net, wire `S.member` modSet]

    newNets = TODO
    stateNets = TODO

hWriteC :: Handle -> [Net] -> IO ()
hWriteC h netlist = do
    emit "module top (input wire clock);\n"
    mapM_ emitDecl netlist
    mapM_ emitInst netlist
    emit "always @(posedge clock) begin\n"
    mapM_ emitAlways netlist
    emit "end\n"
    emit "endmodule\n"
  where
    emit = hPutStr h

    emitWire (instId, outNum) = do
      emit "v"
      emit (show instId)
      emit "_"
      emit (show outNum)

    emitDeclHelper width wire = do
      emit "["
      emit (show (width-1))
      emit ":0] "
      emitWire wire
      emit ";\n"

    emitDeclInitHelper width wire init = do
      emit "["
      emit (show (width-1))
      emit ":0] "
      emitWire wire
      emit " = "
      emit (show width)
      emit "'d"
      emit (show init)
      emit ";\n"

    emitWireDecl width wire = do
      emit "wire "
      emitDeclHelper width wire

    emitWireInitDecl width wire init = do
      emit "wire "
      emitDeclInitHelper width wire init

    emitRegInitDecl width wire init = do
      emit "reg "
      emitDeclInitHelper width wire init

    emitDecl net =
      let wire = (netInstId net, 0) in
        case netPrim net of
          Const w i         -> emitWireInitDecl w wire i
          Add w             -> emitWireDecl w wire
          Sub w             -> emitWireDecl w wire
          Mul w             -> emitWireDecl w wire
          Div w             -> emitWireDecl w wire
          Mod w             -> emitWireDecl w wire
          Not w             -> emitWireDecl w wire
          And w             -> emitWireDecl w wire
          Or  w             -> emitWireDecl w wire
          Xor w             -> emitWireDecl w wire
          ShiftLeft w       -> emitWireDecl w wire
          ShiftRight w      -> emitWireDecl w wire
          Equal w           -> emitWireDecl 1 wire
          NotEqual w        -> emitWireDecl 1 wire
          LessThan w        -> emitWireDecl 1 wire
          LessThanEq w      -> emitWireDecl 1 wire
          Register i w      -> emitRegInitDecl w wire i
          RegisterEn i w    -> emitRegInitDecl w wire i
          ReplicateBit w    -> emitWireDecl w wire
          ZeroExtend wi wo  -> emitWireDecl wo wire
          SignExtend wi wo  -> emitWireDecl wo wire
          SelectBits hi lo  -> emitWireDecl (hi-lo) wire
          Concat aw bw      -> emitWireDecl (aw+bw) wire
          Mux w             -> emitWireDecl w wire
          CountOnes w       -> emitWireDecl w wire
          Display args      -> return ()
          Finish            -> return ()
          Custom p is os ps -> 
            sequence_ [ emitWireDecl w (netInstId net, n)
                      | ((o, w), n) <- zip os [0..] ]

    emitAssignConst w i net = do
      emit "assign "
      emitWire (netInstId net, 0)
      emit " = "
      emit (show w)
      emit "'d" >>  emit (show i) >> emit ";\n"

    emitPrefixOpInst op net = do
      emit "assign "
      emitWire (netInstId net, 0)
      emit " = " >> emit op >> emit "("
      emitWire (netInputs net !! 0)
      emit ");\n"

    emitInfixOpInst op net = do
      emit "assign "
      emitWire (netInstId net, 0)
      emit " = "
      emitWire (netInputs net !! 0)
      emit " " >> emit op >> emit " "
      emitWire (netInputs net !! 1)
      emit ";\n"

    emitReplicateInst w net = do
      emit "assign "
      emitWire (netInstId net, 0)
      emit " = {"
      emit (show w)
      emit "{"
      emitWire (netInputs net !! 0)
      emit "}};\n"

    emitMuxInst net = do
      emit "assign "
      emitWire (netInstId net, 0)
      emit " = "
      emitWire (netInputs net !! 0)
      emit " ? "
      emitWire (netInputs net !! 1)
      emit " : "
      emitWire (netInputs net !! 2)
      emit ";\n"

    emitConcatInst net = do
      emit "assign "
      emitWire (netInstId net, 0)
      emit " = {"
      emitWire (netInputs net !! 0)
      emit ","
      emitWire (netInputs net !! 1)
      emit "};\n"

    emitSelectBitsInst net hi lo = do
      emit "assign "
      emitWire (netInstId net, 0)
      emit " = "
      emitWire (netInputs net !! 0)
      emit "["
      emit (show hi)
      emit ":"
      emit (show lo)
      emit "];\n"

    emitZeroExtendInst net wi wo = do
      emit "assign "
      emitWire (netInstId net, 0)
      emit " = "
      emit "{{"
      emit (show (wo-wi))
      emit "{1'b0}},"
      emitWire (netInputs net !! 0)
      emit "};\n"

    emitSignExtendInst net wi wo = do
      emit "assign "
      emitWire (netInstId net, 0)
      emit " = "
      emit "{"
      emit (show (wo-wi))
      emit "{"
      emitWire (netInputs net !! 0)
      emit "["
      emit (show (wi-1))
      emit "],"
      emitWire (netInputs net !! 0)
      emit "};\n"

    emitCustomInst net name ins outs params = do
      emit name >> emit " "
      let numParams = length params
      if numParams == 0
        then return ()
        else do
          emit "#("
          sequence_
               [ do emit "." >> emit key
                    emit "(" >> emit val >> emit ")"
                    if i < numParams then emit ",\n" else return ()
               | (key :-> val, i) <- zip params [1..] ]
      emit ("i" ++ show (netInstId net))
      let args = zip ins (netInputs net) ++
                   [ (o, (netInstId net, n))
                   | (o, n) <- zip (map fst outs) [0..] ]
      let numArgs = length args
      emit "("
      if numArgs == 0
        then return ()
        else do
          sequence_
             [ do emit "." >> emit name
                  emit "(" >> emitWire wire >> emit ")"
                  if i < numArgs then emit ",\n" else return ()
             | ((name, wire), i) <- zip args [1..] ]
      emit ");\n"

    emitInst net =
      case netPrim net of
        Const w i         -> emitAssignConst w i net
        Add w             -> emitInfixOpInst "+" net
        Sub w             -> emitInfixOpInst "-" net
        Mul w             -> emitInfixOpInst "*" net
        Div w             -> emitInfixOpInst "/" net
        Mod w             -> emitInfixOpInst "%" net
        Not w             -> emitPrefixOpInst "~" net
        And w             -> emitInfixOpInst "&" net
        Or  w             -> emitInfixOpInst "|" net
        Xor w             -> emitInfixOpInst "^" net
        ShiftLeft w       -> emitInfixOpInst "<<" net
        ShiftRight w      -> emitInfixOpInst ">>" net
        Equal w           -> emitInfixOpInst "==" net
        NotEqual w        -> emitInfixOpInst "!=" net
        LessThan w        -> emitInfixOpInst "<" net
        LessThanEq w      -> emitInfixOpInst "<=" net
        Register i w      -> return ()
        RegisterEn i w    -> return ()
        ReplicateBit w    -> emitReplicateInst w net
        ZeroExtend wi wo  -> emitZeroExtendInst net wi wo
        SignExtend wi wo  -> emitSignExtendInst net wi wo
        SelectBits hi lo  -> emitSelectBitsInst net hi lo
        Concat aw bw      -> emitConcatInst net
        Mux w             -> emitMuxInst net
        CountOnes w       -> emitPrefixOpInst "$countones" net
        Display args      -> return ()
        Finish            -> return ()
        Custom p is os ps -> emitCustomInst net p is os ps
 
    emitAlways net =
      case netPrim net of
        Register init w -> do
          emitWire (netInstId net, 0)
          emit " <= "
          emitWire (netInputs net !! 0)
          emit ";\n"
        RegisterEn init w -> do
          emit "if ("
          emitWire (netInputs net !! 0)
          emit " == 1) "
          emitWire (netInstId net, 0)
          emit " <= "
          emitWire (netInputs net !! 1)
          emit ";\n"
        Display args -> do
          emit "if ("
          emitWire (netInputs net !! 0)
          emit " == 1) $display(\""
          emitDisplayFormat args
          emit ","
          emitDisplayArgs args (tail (netInputs net))
          emit ");\n"
        Finish -> do
          emit "if ("
          emitWire (netInputs net !! 0)
          emit " == 1) $finish;\n"
        other -> return ()

    emitDisplayFormat [] = emit "\\n\""
    emitDisplayFormat (DisplayArgString s : args) = do
      emit "%s"
      emitDisplayFormat args
    emitDisplayFormat (DisplayArgBit w : args) = do
      emit "%d"
      emitDisplayFormat args

    emitDisplayArgs [] _ = return ()
    emitDisplayArgs (DisplayArgString s : args) wires = do
      emit ("\"" ++ s ++ "\"")
      if null args then return () else emit ","
      emitDisplayArgs args wires
    emitDisplayArgs (DisplayArgBit w : args) (wire:wires) = do
      emitWire wire
      if null args then return () else emit ","
      emitDisplayArgs args wires
