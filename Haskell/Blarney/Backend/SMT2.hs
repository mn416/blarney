{-# LANGUAGE NoRebindableSyntax #-}

{-|
Module      : Blarney.Backend.SMT2
Description : SMT2 generation
Copyright   : (c) Alexandre Joannou, 2020
License     : MIT
Stability   : experimental

Convert Blarney Netlist to SMT2 scripts.
-}

module Blarney.Backend.SMT2 (
  genSMT2Script
) where

-- Standard imports
import Data.Char
import Data.List
import System.IO
import Data.Maybe
import Data.STRef
import Control.Monad
import Data.Array.ST
import System.Process
import Control.Monad.ST
import Text.PrettyPrint
import Data.Array.IArray
import Prelude hiding ((<>))
import Numeric (showIntAtBase)
import qualified Data.Set as Set

-- Blarney imports
import Blarney.Netlist

-- Toplevel API
--------------------------------------------------------------------------------

-- | Convert given blarney 'Netlist' to an SMT2 script
genSMT2Script :: Netlist -- ^ blarney netlist
              -> String  -- ^ script name
              -> String  -- ^ output directory
              -> IO ()
genSMT2Script nl nm dir =
  do system ("mkdir -p " ++ dir)
     h <- openFile fileName WriteMode
     hPutStr h (renderStyle rStyle $ showAll nl (head outputs))
     hClose h
  where fileName = dir ++ "/" ++ nm ++ ".smt2"
        rStyle = Style PageMode 80 1.05
        outputs = [ n | Just n@Net{netPrim=p} <- elems nl
                      , case p of Output _ _ -> True
                                  _          -> False ]

-- basic internal helpers for pretty printing SMT-lib bit vector code
--------------------------------------------------------------------------------

showAtBase :: (Integral a, Show a) => a -> a -> Doc
showAtBase b n = text $ showIntAtBase b intToDigit n ""
showHex :: (Integral a, Show a) => a -> Doc
showHex n = showAtBase 16 n
showBin :: (Integral a, Show a) => a -> Doc
showBin n = showAtBase 2 n
showBVHexLit :: Integer -> Doc
showBVHexLit n = text "#x" <> showHex n
showBVBinLit :: Integer -> Doc
showBVBinLit n = text "#b" <> showBin n
showBVSlice :: Int-> Int-> Doc -> Doc
showBVSlice hi lo bv =
  parens $ (parens $ char '_' <+> text "extract" <+> int hi <+> int lo) <+> bv
strBVSort :: Int -> String
strBVSort n = "(_ BitVec " ++ show n ++ ")"
showBVSort :: Int -> Doc
showBVSort = text . strBVSort
int2bv :: Int -> Integer -> Doc
int2bv w n =
  parens $ parens (char '_' <+> text "int2bv" <+> int w) <+> int (fromInteger n)
bvIsFalse :: Doc -> Doc
bvIsFalse doc = parens $ text "=" <+> doc <+> text "#b0"
bvIsTrue :: Doc -> Doc
bvIsTrue doc = parens $ text "=" <+> doc <+> text "#b1"
bv2Bool :: Doc -> Doc
bv2Bool = bvIsTrue
bool2BV :: Doc -> Doc
bool2BV doc = parens $ text "ite" <+> doc <+> text "#b1" <+> text "#b0"
psep = parens . sep
plist :: [(Doc, Doc)] -> Doc
plist = psep . map (\(v, s) -> parens $ sep [v, s])
-- | helper for applying an operation to arguments
applyOp :: Doc -> [Doc] -> Doc
applyOp opName opArgs = psep $ opName : opArgs
-- qualifiers
qualify :: Doc -> Doc -> Doc
qualify expr sort = applyOp (text "as") [ expr, sort ]
-- binders
parBind :: [String] -> Doc -> Doc
parBind [] doc = doc
parBind params doc = applyOp (text "par") [parens (sep $ text <$> params), doc]
flatBind :: Doc -> [(Doc, Doc)] -> Doc -> Doc
flatBind _ [] doc = doc
--flatBind binder xs doc = applyOp binder [ plist xs, doc ]
flatBind binder xs doc = parens $ binder <+> sep [ plist xs, doc ]
forallBind :: [(Doc, Doc)] -> Doc -> Doc
forallBind = flatBind $ text "forall"
existsBind :: [(Doc, Doc)] -> Doc -> Doc
existsBind = flatBind $ text "exists"
matchBind :: Doc -> [(Doc, Doc)] -> Doc
matchBind doc [] = doc
matchBind doc matches = applyOp (text "match") [ doc, plist matches ]
letBind :: [(Doc, Doc)] -> Doc -> Doc
letBind = flatBind $ text "let"
nestLetBind :: [[(Doc, Doc)]] -> Doc -> Doc
nestLetBind [] doc = doc
--nestLetBind (xs:xss) doc = letBind xs (nestLetBind xss doc)
-- the 5 is the length of "let " + 1
nestLetBind (xs:xss) doc = letBind xs (nest (-5) (nestLetBind xss doc))

-- | argument is a list of triples representing one datatype:
--   the name, a potentially empty list of parameters, and a non empty list of
--   constructors consisting of a name and a potentially empty list of fields
showDeclareDataTypes :: [(String, [String], [(String, [String])])] -> Doc
showDeclareDataTypes dts =
  applyOp (text "declare-datatypes") [ plist dtNames, psep dtConss ]
  where (dtNames, dtConss) = unzip $ fmt <$> dts
        fmt (nm, ps, conss) = ( (text nm, int $ length ps)
                              , (parBind ps) . psep $ fmtCons <$> conss)
        fmtCons (cnm, flds) = psep $ (text cnm) : ((parens . text) <$> flds)

showDeclareDataType :: String -> [String] -> [(String, [(String, String)])]
                    -> Doc
showDeclareDataType dtName dtParams dtConsAndFields =
  applyOp (text "declare-datatype") [ text dtName, dtDef ]
  where dtDef = parBind dtParams dtCons
        dtCons = psep . (map dtOneCons) $ dtConsAndFields
        dtOneCons (cN, cFs) = psep $ text cN : (map dtField cFs)
        dtField (v, s) = parens $ text v <+> text s

showDefineFun :: Doc -> [(Doc, Doc)] -> Doc -> Doc -> Doc
showDefineFun fName fArgs fRet fBody =
  applyOp (text "define-fun") [ fName, plist fArgs, fRet, fBody ]

showDefineFunRec :: Doc -> [(Doc, Doc)] -> Doc -> Doc -> Doc
showDefineFunRec fName fArgs fRet fBody =
  applyOp (text "define-fun-rec") [ fName, plist fArgs, fRet, fBody ]

-- | argument is a list of tuples representing one function:
--   the name, a potentially empty list of arguments, a return type and
--   a function body
showDefineFunsRec :: [(String, [(String, String)], String, Doc)] -> Doc
showDefineFunsRec fs = applyOp (text "define-funs-rec") [ psep fDecls
                                                        , psep fDefs ]
  where (fDecls, fDefs) = unzip $ fmt <$> fs
        fmt (nm, as, r, body) = ( psep [ text nm
                                       , plist [(text a, text b) | (a,b) <- as]
                                       , text r ]
                                , body )

-- internal helpers specific to blarney netlists
--------------------------------------------------------------------------------

-- | helper to retrieve a 'Net' from a 'Netlist' given an 'InstId'
--   TODO: move to Netlist module
getNet :: Netlist -> InstId -> Net
getNet nl i = fromMaybe err (nl ! i)
  where err = error $ "SMT2 backend error: " ++
                      "access to non existing Net at instId " ++ show i

-- | show SMT for netlist primitives
showPrim :: Prim -> [Doc] -> Doc
-- nullary primitives
showPrim (Const w n)  [] = int2bv w n
showPrim (DontCare w) [] = existsBind [(char 'x', showBVSort w)] (char 'x')
-- unary primitives
showPrim (Identity _) [i] = i
showPrim (ReplicateBit w) [i] = applyOp (text "concat") (replicate w i)
showPrim (ZeroExtend iw ow) [i] = applyOp (text "concat") [int2bv (ow-iw) 0, i]
showPrim (SignExtend iw ow) [i] =
  letBind [(sgn_var, sgn)] $ applyOp (text "concat")
                                     [ sep $ replicate (ow - iw) sgn_var, i ]
  where sgn = showBVSlice msb_idx msb_idx i
        sgn_var = char 's'
        msb_idx = iw - 1
showPrim (SelectBits _ hi lo) [i] = showBVSlice hi lo i
showPrim (Not _) ins = applyOp (text "bvneg")  ins
-- binary / multary primitives
showPrim (Add _)               ins = applyOp (text "bvadd")  ins
showPrim (Sub _)               ins = applyOp (text "bvsub")  ins
showPrim (Mul _ _ _)           ins = applyOp (text "bvmul")  ins
showPrim (Div _)               ins = applyOp (text "bvdiv")  ins
showPrim (Mod _)               ins = applyOp (text "bvmod")  ins
showPrim (And _)               ins = applyOp (text "bvand")  ins
showPrim (Or _)                ins = applyOp (text "bvor")   ins
showPrim (Xor _)               ins = applyOp (text "bvxor")  ins
showPrim (ShiftLeft _ _)       ins = applyOp (text "bvshl")  ins
showPrim (ShiftRight _ _)      ins = applyOp (text "bvlshr") ins
showPrim (ArithShiftRight _ _) ins = applyOp (text "bvashr") ins
showPrim (Concat _ _)          ins = applyOp (text "concat") ins
showPrim (LessThan _)          ins = applyOp (text "bvult")  ins
showPrim (LessThanEq _)        ins = applyOp (text "bvule")  ins
showPrim (Equal _)    ins = bool2BV $ applyOp (text "=") ins
showPrim (NotEqual w) ins = applyOp (text "bvnot") [showPrim (Equal w) ins]
-- unsupported primitives
showPrim p ins = error $
  "SMT2 backend error: cannot showPrim Prim '" ++ show p ++ "'"

genName :: NameHints -> String
genName hints
  | Set.null hints = "v"
  | otherwise = intercalate "_" $ filter (not . null) [prefx, root, sufx]
                where nms = Set.toList hints
                      prefxs = [nm | x@(NmPrefix _ nm) <- nms]
                      roots  = [nm | x@(NmRoot   _ nm) <- nms]
                      sufxs  = [nm | x@(NmSuffix _ nm) <- nms]
                      prefx  = intercalate "_" prefxs
                      root   = intercalate "_" roots
                      sufx   = intercalate "_" sufxs

-- | derive the wire name for the net output (= net id + net output name)
wireName :: Netlist -> WireId -> String
wireName nl (iId, m_outnm) = name ++ richNm ++ outnm ++ "_" ++ show iId
  where outnm = case m_outnm of Just nm -> nm
                                _       -> ""
        net = getNet nl iId
        richNm = case netPrim net of Input      _ nm -> "inpt_" ++ nm
                                     Register   _ _  -> "reg"
                                     RegisterEn _ _  -> "reg"
                                     _               -> ""
        name = genName $ netNameHints net
showWire :: Netlist -> WireId -> Doc
showWire nl wId = text $ wireName nl wId

-- | derive the SMT representation for a 'NetInput'
showNetInput :: Netlist -> NetInput -> Doc
showNetInput nl (InputWire (nId, m_nm)) = case netPrim $ getNet nl nId of
  Input    _ _ -> parens $ showWire nl (nId, m_nm) <+> text "inpts"
  Register _ _ -> parens $ showWire nl (nId, m_nm) <+> text "prev"
  _            -> showWire nl (nId, m_nm)
showNetInput nl (InputTree p ins) = showPrim p (showNetInput nl <$> ins)

-- | derive the SMT representation for a net
showNet :: Netlist -> InstId -> Doc
showNet nl instId = showPrim (netPrim net) (showNetInput nl <$> netInputs net)
  where net = getNet nl instId

withBoundNets :: Netlist -> [InstId] -> Doc -> Doc
withBoundNets _ [] doc = doc
withBoundNets nl instIds doc = nestLetBind decls doc
  where decls = map (\i -> [(showWire nl (i, Nothing), showNet nl i)]) instIds

strSort :: Netlist -> WireId -> String
strSort nl (instId, m_outnm) = strBVSort w
  where w = primOutWidth (netPrim $ getNet nl instId) m_outnm

showDefineTuples :: [Int] -> Doc
showDefineTuples ns = showDeclareDataTypes $ decl <$> nub ns
  where decl n = ( "Tuple" ++ show n, (("X" ++) . show) <$> [1 .. n]
                 , [( "mkTuple" ++ show n
                    , fld n <$> [1 .. n] )] )
        fld n i = "tpl" ++ show n ++ "_" ++ show i ++ " X" ++ show i

showCreateListX :: [String] -> String -> Doc
showCreateListX [] lstSort = qualify (text "nil")
                                     (text $ "(ListX "++lstSort++")")
showCreateListX (e:es) lstSort = applyOp (text "cons")
                                         [ text e
                                         , showCreateListX es lstSort ]
showDefineAndReduce :: Doc
showDefineAndReduce =
  showDefineFunRec (text "andReduce")
                   [ (text "lst", text "(ListX Bool)") ]
                   (text "Bool")
                   fBody
  where fBody = matchBind (text "lst")
                          [ (text "nil", text "true")
                          , ( text "(cons h t)"
                            , applyOp (text "and")
                                      [ text "h"
                                      , applyOp (text "andReduce")
                                                [text "t"] ] ) ]
showDefineImpliesReduce :: Doc
showDefineImpliesReduce =
  showDefineFunRec (text "impliesReduce")
                   [ (text "lst", text "(ListX Bool)") ]
                   (text "Bool")
                   fBody
  where fBody = matchBind (text "lst")
                          [ (text "nil", text "true")
                          , ( text "(cons h t)"
                            , matchBind (text "t") recCases ) ]
        recCases = [ (text "nil", text "h")
                   , (text "(cons hh tt)", applyOp (text "=>") [ text "h"
                                                               , recCall ]) ]
        recCall = applyOp (text "impliesReduce") [text "t"]

showDeclareNLDatatype :: Netlist -> [InstId] -> String -> Doc
showDeclareNLDatatype nl netIds dtNm =
  showDeclareDataType dtNm [] [("mk" ++ dtNm, map mkField netIds)]
  where mkField nId = let wId = (nId, Nothing)
                      in  (wireName nl wId, strSort nl wId)

showDefineDistinctState :: Doc
showDefineDistinctState = showDefineFunsRec
  [ ( "distinctStates", [ ("lst", "(ListX State)") ], "Bool"
    , applyOp (text "distinctStatePairs")
              [applyOp (text "allStatePairs") [text "lst"]])
  , ( "distinctStatePairs", [ ("lst", "(ListX (Tuple2 State State))") ], "Bool"
    , matchBind (text "lst")
                [ ( text "nil", text "true" )
                , ( text "(cons h t)"
                  , applyOp (text "and") [ matchBind (text "h")
                                                     [( text "(mkTuple2 a b)"
                                                     , text "(distinct a b)" )]
                                         , applyOp (text "distinctStatePairs")
                                                   [ text "t" ]])])
  , ( "allStatePairs", [ ("lst", "(ListX State)") ]
    , "(ListX (Tuple2 State State))"
    , matchBind (text "lst") [ ( text "nil"
                               , qualify (text "nil")
                                         (text "(ListX (Tuple2 State State))"))
                             , ( text "(cons h t)"
                               , applyOp (text "appendStatePairs")
                                         [ applyOp (text "pairWithState")
                                                   [ text "h", text "t" ]
                                         , applyOp (text "allStatePairs")
                                                   [ text "t" ]])])
  , ( "appendStatePairs", [ ("xs", "(ListX (Tuple2 State State))")
                          , ("ys", "(ListX (Tuple2 State State))") ]
    , "(ListX (Tuple2 State State))"
    , matchBind (text "xs") [ ( text "nil", text "ys" )
                            , ( text "(cons h t)"
                              , applyOp (text "cons")
                                        [ text "h"
                                        , applyOp (text "appendStatePairs")
                                                  [ text "t", text "ys" ]])])
  , ( "pairWithState", [ ("s", "State"), ("ss", "(ListX State)") ]
    , "(ListX (Tuple2 State State))"
    , matchBind (text "ss") [ ( text "nil"
                              , qualify (text "nil")
                                        (text "(ListX (Tuple2 State State))"))
                            , ( text "(cons h t)"
                              , applyOp (text "cons")
                                        [ applyOp (text "mkTuple2")
                                                  [ text "s", text "h" ]
                                        , applyOp (text "pairWithState")
                                                  [ text "s", text "t" ]])])]

showDefineTransition :: Netlist -> Net -> [InstId] -> String -> Doc
showDefineTransition nl n@Net { netPrim = Output _ nm
                              , netInputs = [e0] } state name =
  showDefineFun (text name) fArgs fRet fBody
  where fArgs = [ (text "inpts", text "Inputs")
                , (text "prev",  text "State") ]
        fRet  = text "(Tuple2 Bool State)"
        fBody = withBoundNets nl filtered $ newTuple2 assertE stateUpdtE
        newTuple2 a b = applyOp (text "mkTuple2") [a, b]
        dontPrune i = case netPrim (getNet nl i) of Input      _ _ -> False
                                                    Register   _ _ -> False
                                                    RegisterEn _ _ -> False
                                                    Output     _ _ -> False
                                                    _              -> True
        sorted = topologicalSort nl
        filtered = [i | i <- sorted, dontPrune i]
        assertE = bvIsTrue $ showNetInput nl e0
        stateUpdtE
          | null state = text "mkState"
          | otherwise  = applyOp (text "mkState") $ regsInpts state
        regsInpts = map \i -> (showNetInput nl . head . netInputs . getNet nl) i
showDefineTransition _ n _ _ =
  error $ "SMT2 backend error: cannot showDefineTransition on " ++ show n

showDefineChainTransition :: String -> String -> Doc
showDefineChainTransition tName cName =
  showDefineFunRec (text cName)
                   [ (text "inpts", text "(ListX Inputs)")
                   , (text "prevS", text "State") ]
                   (text "(Tuple2 (ListX Bool) (ListX State))") fBody
  where fBody = matchBind (text "inpts")
                          [ (text "nil", lastRet)
                          , (text "(cons h t)", matchInvokeT) ]
        lastRet = applyOp (text "mkTuple2")
                          [ qualify (text "nil") (text "(ListX Bool)")
                          , applyOp (text "cons")
                                    [ text "prevS"
                                    , qualify (text "nil")
                                              (text "(ListX State)") ] ]
        matchInvokeT = matchBind (applyOp (text tName) [text "h", text "prevS"])
                                 [(text "(mkTuple2 ok nextS)", matchRecCall)]
        matchRecCall = matchBind (applyOp (text cName) [text "t", text "nextS"])
                                 [( text "(mkTuple2 oks ss)", recRet)]
        recRet = applyOp (text "mkTuple2")
                         [ applyOp (text "cons") [text "ok", text "oks"]
                         , applyOp (text "cons") [text "nextS", text "ss"] ]

showBaseCase :: String -> [(Integer, InputWidth)] -> Int -> Doc
showBaseCase tFun initS depth =
  text "(push)" $+$ decls $+$ assertion $+$ text "(check-sat)" $+$ text "(pop)"
  where inpts = [ "in" ++ show i | i <- [0 .. depth-1] ]
        decls = vcat $ map (\i -> text $ "(declare-const " ++ i ++ " Inputs)")
                           inpts
        assertion = applyOp (text "assert") [ letBind bindArgs matchInvoke ]
        bindArgs = [ (text "inpts", showCreateListX inpts "Inputs")
                   , (text "initS", createState initS) ]
        createState [] = text "mkState"
        createState xs = parens $   text "mkState"
                                <+> sep (map (\(v, w) -> int2bv w v) xs)
        matchInvoke = matchBind (applyOp (text tFun)
                                         [text "inpts", text "initS"])
                                [( text "(mkTuple2 oks ss)"
                                 , applyOp (text "not")
                                           [applyOp (text "andReduce")
                                                    [text "oks"]] )]

showInductionStep :: String -> Int -> Bool -> Doc
showInductionStep tFun depth restrict =
  text "(push)" $+$ decls $+$ assertion $+$ text "(check-sat)" $+$ text "(pop)"
  where inpts = [ "in" ++ show i | i <- [0 .. depth] ]
        decls = vcat $ (text "(declare-const startS State)") :
                       map (\i -> text $ "(declare-const " ++ i ++ " Inputs)")
                           inpts
        assertion = applyOp (text "assert") [ letBind bindArgs matchInvoke ]
        bindArgs = [ (text "inpts", showCreateListX inpts "Inputs") ]
        matchInvoke = matchBind (applyOp (text tFun)
                                         [text "inpts", text "startS"])
                                [( text "(mkTuple2 oks ss)"
                                 , applyOp (text "not") [propHolds] )]
        propHolds = applyOp (text "and") $
                            [ applyOp (text "impliesReduce") [text "oks"] ]
                            ++ [ applyOp (text "distinctStates") [text "ss"]
                               | restrict ]

showAll :: Netlist -> Net -> Doc
showAll nl n@Net { netPrim = Output _ nm, netInputs = [e0] } =
      char ';' <> text (replicate 79 '-')
  $+$ text "; Defining Tuple sorts"
  $+$ showDefineTuples [2, 3]
  $+$ text "; Defining a generic ListX sort"
  $+$ showDeclareDataType "ListX" ["X"] [ ("nil", [])
                                        , ("cons", [ ("head", "X")
                                                   , ("tail", "(ListX X)") ]) ]
  $+$ text "; Defining an \"and\" reduction function for ListX Bool"
  $+$ showDefineAndReduce
  $+$ text "; Defining an \"implies\" reduction function for ListX Bool"
  $+$ showDefineImpliesReduce
  $+$ char ';' <> text (replicate 79 '-')
  $+$ text "; Defining the Inputs record type specific to the current netlist"
  $+$ showDeclareNLDatatype nl inputIds "Inputs"
  $+$ char ';' <> text (replicate 79 '-')
  $+$ text "; Defining the State record type specific to the current netlist"
  $+$ showDeclareNLDatatype nl stateIds "State"
  $+$ char ';' <> text (replicate 79 '-')
  $+$ text "; Defining the transition function specific to the current netlist"
  $+$ showDefineTransition nl n stateIds tFunName
  $+$ char ';' <> text (replicate 79 '-')
  $+$ text "; Defining the recursive chaining of the transition function"
  $+$ showDefineChainTransition tFunName cFunName
  $+$ char ';' <> text (replicate 79 '-')
  $+$ text "; Proof by induction, induction depth =" <+> int depth
  $+$ char ';' <> text (replicate 79 '-')
  $+$ text "; Base case"
  $+$ showBaseCase cFunName stateInits depth
  $+$ char ';' <> text (replicate 79 '-')
  $+$ (if restrictStates then
             text "; Defining helpers for restricted state checking"
         $+$ showDefineDistinctState
       else empty)
  $+$ text "; Induction step"
  $+$ showInductionStep cFunName depth restrictStates
  where depth = 1 -- MUST BE AT LEAST 1
        restrictStates = False -- XXX TODO still WIP
        tFunName = "t_" ++ nm
        cFunName = "chain_" ++ tFunName
        inputIds = [ netInstId n | Just n@Net{netPrim = p} <- elems nl
                                 , case p of Input _ _ -> True
                                             _         -> False ]
        stateElems = [ n | Just n@Net{netPrim = p} <- elems nl
                         , case p of RegisterEn _ _ -> True
                                     Register   _ _ -> True
                                     _              -> False ]
        stateIds = map netInstId stateElems
        stateInits = map stateInit stateElems
        stateInit Net{netPrim=RegisterEn init w} = (init, w)
        stateInit Net{netPrim=Register   init w} = (init, w)
        stateInit _ =
          error $ "SMT2 backend error: encountered non state net " ++ show n ++
                  " where one was expected"
showAll _ n = error $ "SMT2 backend error: cannot showAll on'" ++ show n ++ "'"

-- topological stort of a netlist
-- TODO: move to Netlist passes module
--------------------------------------------------------------------------------

-- | the 'Mark' type is only useful to the 'topologicalSort' function and should
--   not be exported
data Mark = Unmarked | Temporary | Permanent
-- | get a topologically sorted '[InstId]' for the given 'Netlist'
topologicalSort :: Netlist -> [InstId]
topologicalSort nl = runST do
  -- initialise state for the topological sorting
  visited <- newArray (bounds nl) Unmarked -- track visit through the netlist
  sorted  <- newSTRef [] -- sorted list as a result
  -- run the internal topological sort from all relevant root
  mapM_ (topoSort visited sorted) relevantRoots
  -- return the sorted list of InstId
  reverse <$> readSTRef sorted
  -- helpers
  where
    -- identify Netlist's outputs and state holding elements
    relevantRoots = [ netInstId n | Just n@Net{netPrim = p} <- elems nl
                                  , case p of RegisterEn _ _ -> True
                                              Register   _ _ -> True
                                              Output     _ _ -> True
                                              _              -> False ]
    -- identify leaf net
    isLeaf :: Net -> Bool
    isLeaf Net{ netPrim = Input      _ _ } = True
    isLeaf Net{ netPrim = Register   _ _ } = True
    isLeaf Net{ netPrim = RegisterEn _ _ } = True
    isLeaf _                               = False
    -- list insertion helper
    insert lst elem = modifySTRef' lst $ \xs -> elem : xs
    -- the actual recursive topological sort algorithm
    topoSort :: STArray s InstId Mark -> STRef s [InstId] -> InstId
             -> ST s ()
    topoSort visited sorted netId = do
      -- retrieve the 'visited' array entry for the current net
      netVisit <- readArray visited netId
      case netVisit of
        -- For already visited nets, do not do anything
        Permanent -> return ()
        -- For nets under visit, we identified a combinational cycle
        -- (unsupported ==> error out)
        Temporary -> do let net = getNet nl netId
                        error $ "SMT2 backend error: " ++
                                "combinational cycle detected -- " ++
                                show net
        -- For new visits:
        Unmarked -> do
          let net = getNet nl netId
          -- For non leaf nets: mark net as temporarily under visit,
          --                    explore all inputs recursively
          when (not $ isLeaf net) do
            writeArray visited netId Temporary
            let allInputIds = concatMap (map fst . netInputWireIds)
                                        (netInputs net)
            mapM_ (topoSort visited sorted) allInputIds
          -- Mark net as permanent and insert it into the sorted list
          writeArray visited netId Permanent
          insert sorted netId
