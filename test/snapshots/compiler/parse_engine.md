# META
source_lines=351
stages=DESUGAR,MARK
# SOURCE
import frontend.lex_token.{Token(..), describeToken}
import frontend.ast.{Loc(..)}
import frontend.parse_diagnostic.{ParseDiagnosticKind(..), renderParseProblem}
import frontend.parse_positions.{locOfSpanWith}
import support.source_index.{lineStartsOf, offsetToLineColFast}
import support.util.{reverseL}

public export data PR a = POk a Int | PErr PFail Int | PFatal PFail Int
public export data PFail =
  | FailMsg String
  | FailExpect Token Token
  | FailProblem ParseDiagnosticKind

public export data ParseMode =
  | UnlocatedSyntax
  | LocatedSyntax
  | UnlocatedChecked
  | LocatedChecked

export data ParseContext = {
  pcTokens : Array Token,
  pcOffsets : Array (Int, Int),
  pcLineStarts : Array Int,
  pcLocated : Bool,
  pcGuardPositions : Bool,
  pcDepth : Ref Int,
  pcCommas : Ref (List (Int, Int)),
  pcUnits : Ref (List (Int, Int, Int)),
}

export data ParseMark =
  ParseMark ParseContext Int (List (Int, Int)) (List (Int, Int, Int))

public export data ParserE (e : Effect) a =
  ParserE (ParseContext -> Int -> <e> PR a)
export type Parser a = ParserE <> a

export
newParseContext : String -> Array Token -> Array (Int, Int) -> ParseContext
newParseContext = newParseContextWith LocatedChecked

export
newParseContextWith : ParseMode ->
  String ->
  Array Token ->
  Array (Int, Int) ->
  ParseContext
newParseContextWith mode src toks offs = ParseContext {
  pcTokens = toks,
  pcOffsets = offs,
  pcLineStarts = lineStartsOf src,
  pcLocated = match mode
    LocatedSyntax => True
    LocatedChecked => True
    _ => False,
  pcGuardPositions = match mode
    UnlocatedChecked => True
    LocatedChecked => True
    _ => False,
  pcDepth = Ref 0,
  pcCommas = Ref [],
  pcUnits = Ref [],
}

export
contextTokens : ParseContext -> Array Token
contextTokens ctx = ctx.pcTokens

export
contextOffsets : ParseContext -> Array (Int, Int)
contextOffsets ctx = ctx.pcOffsets

export
contextLineStarts : ParseContext -> Array Int
contextLineStarts ctx = ctx.pcLineStarts

export
runPWith : ParseContext -> ParserE e a -> Int -> <e> PR a
runPWith ctx (ParserE f) pos = f ctx pos

export
runP : ParserE e a -> Array Token -> Int -> <e> PR a
runP p toks pos =
  runPWith
    (newParseContextWith UnlocatedSyntax "" toks (arrayFromList []))
    p
    pos

mapPR : (a -> <e> b) -> PR a -> <e> PR b
mapPR f (POk a pos) = POk (f a) pos
mapPR _ (PErr e pos) = PErr e pos
mapPR _ (PFatal e pos) = PFatal e pos

impl DeferredMappable ParserE where
  deferMap f pa = ParserE (ctx pos => mapPR f (runPWith ctx pa pos))

apPR : ParserE e (a -> b) -> ParserE e a -> ParseContext -> Int -> <e> PR b
apPR pf pa ctx pos = match runPWith ctx pf pos
  POk f pos1 => mapPR f (runPWith ctx pa pos1)
  PErr e pos1 => PErr e pos1
  PFatal e pos1 => PFatal e pos1

impl DeferredApplicative ParserE where
  deferPure x = ParserE (_ctx pos => POk x pos)
  deferAp pf pa = ParserE (ctx pos => apPR pf pa ctx pos)

bindPR : ParserE e a ->
  (a -> <e> ParserE e b) ->
  ParseContext ->
  Int ->
  <e> PR b
bindPR pa k ctx pos = match runPWith ctx pa pos
  POk a pos1 => runPWith ctx (k a) pos1
  PErr e pos1 => PErr e pos1
  PFatal e pos1 => PFatal e pos1

impl DeferredThenable ParserE where
  deferThen pa k = ParserE (ctx pos => bindPR pa k ctx pos)

export
contextP : ParserE e ParseContext
contextP = ParserE (ctx pos => POk ctx pos)

export
getPos : ParserE e Int
getPos = ParserE (_ctx pos => POk pos pos)

export
peekTok : Array Token -> Int -> Token
peekTok toks pos
  | pos < arrayLength toks = arrayGetUnsafe pos toks
  | otherwise = TEof

export
peekP : ParserE e Token
peekP = ParserE (ctx pos => POk (peekTok ctx.pcTokens pos) pos)

export
peek2P : ParserE e Token
peek2P = ParserE (ctx pos => POk (peekTok ctx.pcTokens (pos + 1)) pos)

export
peek3P : ParserE e Token
peek3P = ParserE (ctx pos => POk (peekTok ctx.pcTokens (pos + 2)) pos)

export
advance : ParserE e Token
advance = ParserE (ctx pos => match peekTok ctx.pcTokens pos
  TEof => PErr (FailProblem UnexpectedEnd) pos
  t => POk t (pos + 1))

export
emit : a -> ParserE e a
emit x = defer
  advance
  deferPure x

export
expectTok : Token -> ParserE e Unit
expectTok t = ParserE (ctx pos =>
  let x = peekTok ctx.pcTokens pos
  if x == t then match x
    TEof => PErr (FailProblem UnexpectedEnd) pos
    _ => POk () (pos + 1)
  else
    PErr (FailExpect x t) pos)

export
failP : String -> ParserE e a
failP msg = ParserE (_ctx pos => PErr (FailMsg msg) pos)

export
fatalP : ParseDiagnosticKind -> ParserE e a
fatalP kind = ParserE (_ctx pos => PFatal (FailProblem kind) pos)

export
fatalProblemAtP : ParseDiagnosticKind -> Int -> ParserE e a
fatalProblemAtP kind pos0 =
  ParserE (_ctx _pos => PFatal (FailProblem kind) pos0)

export
fatalAtP : String -> Int -> ParserE e a
fatalAtP msg pos0 = ParserE (_ctx _pos => PFatal (FailMsg msg) pos0)

export
renderFail : PFail -> String
renderFail (FailMsg m) = m
renderFail (FailProblem kind) = renderParseProblem kind
renderFail (FailExpect x t) =
  "\{unexpectedTokenMsg x}; expected \{expectedTokenMsg t}"

export
failProblem : PFail -> ParseDiagnosticKind
failProblem (FailProblem kind) = kind
failProblem (FailExpect TEof expected) =
  UnexpectedEndExpected (expectedTokenMsg expected)
failProblem other = GenericParse (renderFail other)

export
mark : ParseContext -> ParseMark
mark ctx = ParseMark ctx !ctx.pcDepth !ctx.pcCommas !ctx.pcUnits

export
rewind : ParseMark -> Unit
rewind (ParseMark ctx depth commas units) =
  ctx.pcDepth := depth
  ctx.pcCommas := commas
  ctx.pcUnits := units

export
orElse : ParserE e a -> ParserE e a -> ParserE e a
orElse pa pb = ParserE (ctx pos =>
  let saved = mark ctx
  match runPWith ctx pa pos
    r@(POk _ _) => r
    r@(PFatal _ _) =>
      rewind saved
      r
    PErr ea qa =>
      rewind saved
      match runPWith ctx pb pos
        r@(POk _ _) => r
        r@(PFatal _ _) =>
          rewind saved
          r
        PErr eb qb =>
          rewind saved
          if qa > qb then PErr ea qa else PErr eb qb)

export
many : ParserE e a -> ParserE e (List a)
many p = ParserE (ctx pos => manyGo p ctx pos [])

manyGo : ParserE e a -> ParseContext -> Int -> List a -> <e> PR (List a)
manyGo p ctx pos acc =
  let saved = mark ctx
  match runPWith ctx p pos
    POk x q =>
      if q > pos then
        manyGo p ctx q (x :: acc)
      else
        rewind saved
        POk (reverseL (x :: acc)) q
    PFatal e q =>
      rewind saved
      PFatal e q
    PErr _ _ =>
      rewind saved
      POk (reverseL acc) pos

export
sepThen : ParserE e b -> ParserE e a -> ParserE e a
sepThen sep p = defer
  sep
  p

export
sepBy1 : ParserE e a -> ParserE e b -> ParserE e (List a)
sepBy1 p sep = defer
  x <- p
  xs <- many (sepThen sep p)
  deferPure (x :: xs)

export
locOfSpan : ParseContext -> Int -> Int -> Loc
locOfSpan ctx start end =
  if ctx.pcLocated then
    locOfSpanWith ctx.pcOffsets ctx.pcLineStarts start end
  else
    Loc "" 1 0 1 0

export
spanLoc : Int -> Int -> ParserE e Loc
spanLoc start end = ParserE (ctx pos => POk (locOfSpan ctx start end) pos)

export
tokLineCol : ParseContext -> Int -> (Int, Int)
tokLineCol ctx i =
  if ctx.pcGuardPositions && i >= 0 && i < arrayLength ctx.pcOffsets then
    offsetToLineColFast ctx.pcLineStarts (fst (arrayGetUnsafe i ctx.pcOffsets))
  else
    (0, 0)

export
depthOf : ParseContext -> Int
depthOf ctx = !ctx.pcDepth

export
withDepth : Int -> PFail -> ParserE e a -> ParserE e a
withDepth limit problem p = ParserE (ctx pos =>
  let depth = !ctx.pcDepth
  if depth >= limit then
    PFatal problem pos
  else
    ctx.pcDepth := depth + 1
    let r = runPWith ctx p pos
    ctx.pcDepth := depth
    r)

export
recordTrailingComma : Int -> ParserE e Unit
recordTrailingComma p = ParserE (ctx pos =>
  let (Loc _ sl sc _ _) = locOfSpan ctx p (p + 1)
  ctx.pcCommas := (sl, sc) :: !ctx.pcCommas
  POk () pos)

export
recordUnitStart : Int -> Int -> ParserE e Unit
recordUnitStart k p = ParserE (ctx pos =>
  let (Loc _ sl sc _ _) = locOfSpan ctx p (p + 1)
  ctx.pcUnits := (k, sl, sc) :: !ctx.pcUnits
  POk () pos)

export
forgetLatestUnitStart : ParserE e Unit
forgetLatestUnitStart = ParserE (ctx pos =>
  ctx.pcUnits := match !ctx.pcUnits
    [] => []
    _ :: rest => rest
  POk () pos)

export
contextCues : ParseContext -> (List (Int, Int), List (Int, Int, Int))
contextCues ctx = (reverseL !ctx.pcCommas, reverseL !ctx.pcUnits)

-- The "unexpected X" half of a parse error.  A description that carries an
-- article (`a number`) or names a layout event (`a dedent`) reads badly after
-- "unexpected", so those tokens get a bare noun phrase here.
export
unexpectedTokenMsg : Token -> String
unexpectedTokenMsg t = "unexpected " ++ unexpectedTokenText t

unexpectedTokenText : Token -> String
unexpectedTokenText (TInt _ _) = "number"
unexpectedTokenText (TWideInt _ _ _) = "number"
unexpectedTokenText (TFloat _) = "number"
unexpectedTokenText (TString _) = "string"
unexpectedTokenText (TInterpOpen _) = "string"
unexpectedTokenText (TInterpMid _) = "string"
unexpectedTokenText (TInterpEnd _) = "string"
unexpectedTokenText (TChar _) = "character literal"
unexpectedTokenText TNewline = "line break"
unexpectedTokenText TIndent = "indentation"
unexpectedTokenText TDedent = "end of block"
unexpectedTokenText t = describeToken t

-- The "expected Y" half: a layout token is named by what the user would write.
expectedTokenMsg : Token -> String
expectedTokenMsg TIndent = "an indented block"
expectedTokenMsg TDedent = "the end of the block"
expectedTokenMsg t = describeToken t
# DESUGAR
(DUse false (UseGroup ("frontend" "lex_token") ((mem "Token" true) (mem "describeToken" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true))))
(DUse false (UseGroup ("frontend" "parse_diagnostic") ((mem "ParseDiagnosticKind" true) (mem "renderParseProblem" false))))
(DUse false (UseGroup ("frontend" "parse_positions") ((mem "locOfSpanWith" false))))
(DUse false (UseGroup ("support" "source_index") ((mem "lineStartsOf" false) (mem "offsetToLineColFast" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false))))
(DData Public "PR" ("a") ((variant "POk" (ConPos (TyVar "a") (TyCon "Int"))) (variant "PErr" (ConPos (TyCon "PFail") (TyCon "Int"))) (variant "PFatal" (ConPos (TyCon "PFail") (TyCon "Int")))) ())
(DData Public "PFail" () ((variant "FailMsg" (ConPos (TyCon "String"))) (variant "FailExpect" (ConPos (TyCon "Token") (TyCon "Token"))) (variant "FailProblem" (ConPos (TyCon "ParseDiagnosticKind")))) ())
(DData Public "ParseMode" () ((variant "UnlocatedSyntax" (ConPos)) (variant "LocatedSyntax" (ConPos)) (variant "UnlocatedChecked" (ConPos)) (variant "LocatedChecked" (ConPos))) ())
(DData Abstract "ParseContext" () ((variant "ParseContext" (ConNamed (field "pcTokens" (TyApp (TyCon "Array") (TyCon "Token"))) (field "pcOffsets" (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int")))) (field "pcLineStarts" (TyApp (TyCon "Array") (TyCon "Int"))) (field "pcLocated" (TyCon "Bool")) (field "pcGuardPositions" (TyCon "Bool")) (field "pcDepth" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "pcCommas" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (field "pcUnits" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int")))))))) ())
(DData Abstract "ParseMark" () ((variant "ParseMark" (ConPos (TyCon "ParseContext") (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int")))))) ())
(DData Public "ParserE" ("e" "a") ((variant "ParserE" (ConPos (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "PR") (TyVar "a")))))))) ())
(DTypeAlias true "Parser" ("a") (TyApp (TyApp (TyCon "ParserE") (TyRow () None)) (TyVar "a")))
(DTypeSig true "newParseContext" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyCon "ParseContext")))))
(DFunDef false "newParseContext" () (EApp (EVar "newParseContextWith") (EVar "LocatedChecked")))
(DTypeSig true "newParseContextWith" (TyFun (TyCon "ParseMode") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyCon "ParseContext"))))))
(DFunDef false "newParseContextWith" ((PVar "mode") (PVar "src") (PVar "toks") (PVar "offs")) (ERecordCreate "ParseContext" ((fa "pcTokens" (EVar "toks")) (fa "pcOffsets" (EVar "offs")) (fa "pcLineStarts" (EApp (EVar "lineStartsOf") (EVar "src"))) (fa "pcLocated" (EMatch (EVar "mode") (arm (PCon "LocatedSyntax") () (EVar "True")) (arm (PCon "LocatedChecked") () (EVar "True")) (arm PWild () (EVar "False")))) (fa "pcGuardPositions" (EMatch (EVar "mode") (arm (PCon "UnlocatedChecked") () (EVar "True")) (arm (PCon "LocatedChecked") () (EVar "True")) (arm PWild () (EVar "False")))) (fa "pcDepth" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "pcCommas" (EApp (EVar "Ref") (EListLit))) (fa "pcUnits" (EApp (EVar "Ref") (EListLit))))))
(DTypeSig true "contextTokens" (TyFun (TyCon "ParseContext") (TyApp (TyCon "Array") (TyCon "Token"))))
(DFunDef false "contextTokens" ((PVar "ctx")) (EFieldAccess (EVar "ctx") "pcTokens"))
(DTypeSig true "contextOffsets" (TyFun (TyCon "ParseContext") (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "contextOffsets" ((PVar "ctx")) (EFieldAccess (EVar "ctx") "pcOffsets"))
(DTypeSig true "contextLineStarts" (TyFun (TyCon "ParseContext") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "contextLineStarts" ((PVar "ctx")) (EFieldAccess (EVar "ctx") "pcLineStarts"))
(DTypeSig true "runPWith" (TyFun (TyCon "ParseContext") (TyFun (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a")) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "PR") (TyVar "a")))))))
(DFunDef false "runPWith" ((PVar "ctx") (PCon "ParserE" (PVar "f")) (PVar "pos")) (EApp (EApp (EVar "f") (EVar "ctx")) (EVar "pos")))
(DTypeSig true "runP" (TyFun (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "PR") (TyVar "a")))))))
(DFunDef false "runP" ((PVar "p") (PVar "toks") (PVar "pos")) (EApp (EApp (EApp (EVar "runPWith") (EApp (EApp (EApp (EApp (EVar "newParseContextWith") (EVar "UnlocatedSyntax")) (ELit (LString ""))) (EVar "toks")) (EApp (EVar "arrayFromList") (EListLit)))) (EVar "p")) (EVar "pos")))
(DTypeSig false "mapPR" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b"))) (TyFun (TyApp (TyCon "PR") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "PR") (TyVar "b"))))))
(DFunDef false "mapPR" ((PVar "f") (PCon "POk" (PVar "a") (PVar "pos"))) (EApp (EApp (EVar "POk") (EApp (EVar "f") (EVar "a"))) (EVar "pos")))
(DFunDef false "mapPR" (PWild (PCon "PErr" (PVar "e") (PVar "pos"))) (EApp (EApp (EVar "PErr") (EVar "e")) (EVar "pos")))
(DFunDef false "mapPR" (PWild (PCon "PFatal" (PVar "e") (PVar "pos"))) (EApp (EApp (EVar "PFatal") (EVar "e")) (EVar "pos")))
(DImpl false "DeferredMappable" ((TyCon "ParserE")) () ((im "deferMap" ((PVar "f") (PVar "pa")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EApp (EApp (EVar "mapPR") (EVar "f")) (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "pa")) (EVar "pos"))))))))
(DTypeSig false "apPR" (TyFun (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyFun (TyVar "a") (TyVar "b"))) (TyFun (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a")) (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "PR") (TyVar "b"))))))))
(DFunDef false "apPR" ((PVar "pf") (PVar "pa") (PVar "ctx") (PVar "pos")) (EMatch (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "pf")) (EVar "pos")) (arm (PCon "POk" (PVar "f") (PVar "pos1")) () (EApp (EApp (EVar "mapPR") (EVar "f")) (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "pa")) (EVar "pos1")))) (arm (PCon "PErr" (PVar "e") (PVar "pos1")) () (EApp (EApp (EVar "PErr") (EVar "e")) (EVar "pos1"))) (arm (PCon "PFatal" (PVar "e") (PVar "pos1")) () (EApp (EApp (EVar "PFatal") (EVar "e")) (EVar "pos1")))))
(DImpl false "DeferredApplicative" ((TyCon "ParserE")) () ((im "deferPure" ((PVar "x")) (EApp (EVar "ParserE") (ELam ((PVar "_ctx") (PVar "pos")) (EApp (EApp (EVar "POk") (EVar "x")) (EVar "pos"))))) (im "deferAp" ((PVar "pf") (PVar "pa")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EApp (EApp (EApp (EApp (EVar "apPR") (EVar "pf")) (EVar "pa")) (EVar "ctx")) (EVar "pos")))))))
(DTypeSig false "bindPR" (TyFun (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a")) (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "b")))) (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "PR") (TyVar "b"))))))))
(DFunDef false "bindPR" ((PVar "pa") (PVar "k") (PVar "ctx") (PVar "pos")) (EMatch (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "pa")) (EVar "pos")) (arm (PCon "POk" (PVar "a") (PVar "pos1")) () (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EApp (EVar "k") (EVar "a"))) (EVar "pos1"))) (arm (PCon "PErr" (PVar "e") (PVar "pos1")) () (EApp (EApp (EVar "PErr") (EVar "e")) (EVar "pos1"))) (arm (PCon "PFatal" (PVar "e") (PVar "pos1")) () (EApp (EApp (EVar "PFatal") (EVar "e")) (EVar "pos1")))))
(DImpl false "DeferredThenable" ((TyCon "ParserE")) () ((im "deferThen" ((PVar "pa") (PVar "k")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EApp (EApp (EApp (EApp (EVar "bindPR") (EVar "pa")) (EVar "k")) (EVar "ctx")) (EVar "pos")))))))
(DTypeSig true "contextP" (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyCon "ParseContext")))
(DFunDef false "contextP" () (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EApp (EApp (EVar "POk") (EVar "ctx")) (EVar "pos")))))
(DTypeSig true "getPos" (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyCon "Int")))
(DFunDef false "getPos" () (EApp (EVar "ParserE") (ELam ((PVar "_ctx") (PVar "pos")) (EApp (EApp (EVar "POk") (EVar "pos")) (EVar "pos")))))
(DTypeSig true "peekTok" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Token"))))
(DFunDef false "peekTok" ((PVar "toks") (PVar "pos")) (EIf (EBinOp "<" (EVar "pos") (EApp (EVar "arrayLength") (EVar "toks"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pos")) (EVar "toks")) (EIf (EVar "otherwise") (EVar "TEof") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "peekP" (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyCon "Token")))
(DFunDef false "peekP" () (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EApp (EApp (EVar "POk") (EApp (EApp (EVar "peekTok") (EFieldAccess (EVar "ctx") "pcTokens")) (EVar "pos"))) (EVar "pos")))))
(DTypeSig true "peek2P" (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyCon "Token")))
(DFunDef false "peek2P" () (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EApp (EApp (EVar "POk") (EApp (EApp (EVar "peekTok") (EFieldAccess (EVar "ctx") "pcTokens")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (EVar "pos")))))
(DTypeSig true "peek3P" (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyCon "Token")))
(DFunDef false "peek3P" () (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EApp (EApp (EVar "POk") (EApp (EApp (EVar "peekTok") (EFieldAccess (EVar "ctx") "pcTokens")) (EBinOp "+" (EVar "pos") (ELit (LInt 2))))) (EVar "pos")))))
(DTypeSig true "advance" (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyCon "Token")))
(DFunDef false "advance" () (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EMatch (EApp (EApp (EVar "peekTok") (EFieldAccess (EVar "ctx") "pcTokens")) (EVar "pos")) (arm (PCon "TEof") () (EApp (EApp (EVar "PErr") (EApp (EVar "FailProblem") (EVar "UnexpectedEnd"))) (EVar "pos"))) (arm (PVar "t") () (EApp (EApp (EVar "POk") (EVar "t")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))))))
(DTypeSig true "emit" (TyFun (TyVar "a") (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a"))))
(DFunDef false "emit" ((PVar "x")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "deferPure") (EVar "x")))))
(DTypeSig true "expectTok" (TyFun (TyCon "Token") (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyCon "Unit"))))
(DFunDef false "expectTok" ((PVar "t")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EBlock (DoLet false false (PVar "x") (EApp (EApp (EVar "peekTok") (EFieldAccess (EVar "ctx") "pcTokens")) (EVar "pos"))) (DoExpr (EIf (EBinOp "==" (EVar "x") (EVar "t")) (EMatch (EVar "x") (arm (PCon "TEof") () (EApp (EApp (EVar "PErr") (EApp (EVar "FailProblem") (EVar "UnexpectedEnd"))) (EVar "pos"))) (arm PWild () (EApp (EApp (EVar "POk") (ELit LUnit)) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))) (EApp (EApp (EVar "PErr") (EApp (EApp (EVar "FailExpect") (EVar "x")) (EVar "t"))) (EVar "pos"))))))))
(DTypeSig true "failP" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a"))))
(DFunDef false "failP" ((PVar "msg")) (EApp (EVar "ParserE") (ELam ((PVar "_ctx") (PVar "pos")) (EApp (EApp (EVar "PErr") (EApp (EVar "FailMsg") (EVar "msg"))) (EVar "pos")))))
(DTypeSig true "fatalP" (TyFun (TyCon "ParseDiagnosticKind") (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a"))))
(DFunDef false "fatalP" ((PVar "kind")) (EApp (EVar "ParserE") (ELam ((PVar "_ctx") (PVar "pos")) (EApp (EApp (EVar "PFatal") (EApp (EVar "FailProblem") (EVar "kind"))) (EVar "pos")))))
(DTypeSig true "fatalProblemAtP" (TyFun (TyCon "ParseDiagnosticKind") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a")))))
(DFunDef false "fatalProblemAtP" ((PVar "kind") (PVar "pos0")) (EApp (EVar "ParserE") (ELam ((PVar "_ctx") (PVar "_pos")) (EApp (EApp (EVar "PFatal") (EApp (EVar "FailProblem") (EVar "kind"))) (EVar "pos0")))))
(DTypeSig true "fatalAtP" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a")))))
(DFunDef false "fatalAtP" ((PVar "msg") (PVar "pos0")) (EApp (EVar "ParserE") (ELam ((PVar "_ctx") (PVar "_pos")) (EApp (EApp (EVar "PFatal") (EApp (EVar "FailMsg") (EVar "msg"))) (EVar "pos0")))))
(DTypeSig true "renderFail" (TyFun (TyCon "PFail") (TyCon "String")))
(DFunDef false "renderFail" ((PCon "FailMsg" (PVar "m"))) (EVar "m"))
(DFunDef false "renderFail" ((PCon "FailProblem" (PVar "kind"))) (EApp (EVar "renderParseProblem") (EVar "kind")))
(DFunDef false "renderFail" ((PCon "FailExpect" (PVar "x") (PVar "t"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "unexpectedTokenMsg") (EVar "x")))) (ELit (LString "; expected "))) (EApp (EVar "display") (EApp (EVar "expectedTokenMsg") (EVar "t")))) (ELit (LString ""))))
(DTypeSig true "failProblem" (TyFun (TyCon "PFail") (TyCon "ParseDiagnosticKind")))
(DFunDef false "failProblem" ((PCon "FailProblem" (PVar "kind"))) (EVar "kind"))
(DFunDef false "failProblem" ((PCon "FailExpect" (PCon "TEof") (PVar "expected"))) (EApp (EVar "UnexpectedEndExpected") (EApp (EVar "expectedTokenMsg") (EVar "expected"))))
(DFunDef false "failProblem" ((PVar "other")) (EApp (EVar "GenericParse") (EApp (EVar "renderFail") (EVar "other"))))
(DTypeSig true "mark" (TyFun (TyCon "ParseContext") (TyCon "ParseMark")))
(DFunDef false "mark" ((PVar "ctx")) (EApp (EApp (EApp (EApp (EVar "ParseMark") (EVar "ctx")) (EUnOp "!" (EFieldAccess (EVar "ctx") "pcDepth"))) (EUnOp "!" (EFieldAccess (EVar "ctx") "pcCommas"))) (EUnOp "!" (EFieldAccess (EVar "ctx") "pcUnits"))))
(DTypeSig true "rewind" (TyFun (TyCon "ParseMark") (TyCon "Unit")))
(DFunDef false "rewind" ((PCon "ParseMark" (PVar "ctx") (PVar "depth") (PVar "commas") (PVar "units"))) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "ctx") "pcDepth")) (EVar "depth"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "ctx") "pcCommas")) (EVar "commas"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "ctx") "pcUnits")) (EVar "units")))))
(DTypeSig true "orElse" (TyFun (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a")) (TyFun (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a")))))
(DFunDef false "orElse" ((PVar "pa") (PVar "pb")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EBlock (DoLet false false (PVar "saved") (EApp (EVar "mark") (EVar "ctx"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "pa")) (EVar "pos")) (arm (PAs "r" (PCon "POk" PWild PWild)) () (EVar "r")) (arm (PAs "r" (PCon "PFatal" PWild PWild)) () (EBlock (DoExpr (EApp (EVar "rewind") (EVar "saved"))) (DoExpr (EVar "r")))) (arm (PCon "PErr" (PVar "ea") (PVar "qa")) () (EBlock (DoExpr (EApp (EVar "rewind") (EVar "saved"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "pb")) (EVar "pos")) (arm (PAs "r" (PCon "POk" PWild PWild)) () (EVar "r")) (arm (PAs "r" (PCon "PFatal" PWild PWild)) () (EBlock (DoExpr (EApp (EVar "rewind") (EVar "saved"))) (DoExpr (EVar "r")))) (arm (PCon "PErr" (PVar "eb") (PVar "qb")) () (EBlock (DoExpr (EApp (EVar "rewind") (EVar "saved"))) (DoExpr (EIf (EBinOp ">" (EVar "qa") (EVar "qb")) (EApp (EApp (EVar "PErr") (EVar "ea")) (EVar "qa")) (EApp (EApp (EVar "PErr") (EVar "eb")) (EVar "qb"))))))))))))))))
(DTypeSig true "many" (TyFun (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "many" ((PVar "p")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EApp (EApp (EApp (EApp (EVar "manyGo") (EVar "p")) (EVar "ctx")) (EVar "pos")) (EListLit)))))
(DTypeSig false "manyGo" (TyFun (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a")) (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "PR") (TyApp (TyCon "List") (TyVar "a")))))))))
(DFunDef false "manyGo" ((PVar "p") (PVar "ctx") (PVar "pos") (PVar "acc")) (EBlock (DoLet false false (PVar "saved") (EApp (EVar "mark") (EVar "ctx"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "p")) (EVar "pos")) (arm (PCon "POk" (PVar "x") (PVar "q")) () (EIf (EBinOp ">" (EVar "q") (EVar "pos")) (EApp (EApp (EApp (EApp (EVar "manyGo") (EVar "p")) (EVar "ctx")) (EVar "q")) (EBinOp "::" (EVar "x") (EVar "acc"))) (EBlock (DoExpr (EApp (EVar "rewind") (EVar "saved"))) (DoExpr (EApp (EApp (EVar "POk") (EApp (EVar "reverseL") (EBinOp "::" (EVar "x") (EVar "acc")))) (EVar "q")))))) (arm (PCon "PFatal" (PVar "e") (PVar "q")) () (EBlock (DoExpr (EApp (EVar "rewind") (EVar "saved"))) (DoExpr (EApp (EApp (EVar "PFatal") (EVar "e")) (EVar "q"))))) (arm (PCon "PErr" PWild PWild) () (EBlock (DoExpr (EApp (EVar "rewind") (EVar "saved"))) (DoExpr (EApp (EApp (EVar "POk") (EApp (EVar "reverseL") (EVar "acc"))) (EVar "pos")))))))))
(DTypeSig true "sepThen" (TyFun (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "b")) (TyFun (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a")))))
(DFunDef false "sepThen" ((PVar "sep") (PVar "p")) (EApp (EApp (EVar "deferThen") (EVar "sep")) (ELam (PWild) (EVar "p"))))
(DTypeSig true "sepBy1" (TyFun (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a")) (TyFun (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "b")) (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "sepBy1" ((PVar "p") (PVar "sep")) (EApp (EApp (EVar "deferThen") (EVar "p")) (ELam ((PVar "x")) (EApp (EApp (EVar "deferThen") (EApp (EVar "many") (EApp (EApp (EVar "sepThen") (EVar "sep")) (EVar "p")))) (ELam ((PVar "xs")) (EApp (EVar "deferPure") (EBinOp "::" (EVar "x") (EVar "xs"))))))))
(DTypeSig true "locOfSpan" (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Loc")))))
(DFunDef false "locOfSpan" ((PVar "ctx") (PVar "start") (PVar "end")) (EIf (EFieldAccess (EVar "ctx") "pcLocated") (EApp (EApp (EApp (EApp (EVar "locOfSpanWith") (EFieldAccess (EVar "ctx") "pcOffsets")) (EFieldAccess (EVar "ctx") "pcLineStarts")) (EVar "start")) (EVar "end")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 1))) (ELit (LInt 0))) (ELit (LInt 1))) (ELit (LInt 0)))))
(DTypeSig true "spanLoc" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyCon "Loc")))))
(DFunDef false "spanLoc" ((PVar "start") (PVar "end")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EApp (EApp (EVar "POk") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "start")) (EVar "end"))) (EVar "pos")))))
(DTypeSig true "tokLineCol" (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "tokLineCol" ((PVar "ctx") (PVar "i")) (EIf (EBinOp "&&" (EBinOp "&&" (EFieldAccess (EVar "ctx") "pcGuardPositions") (EBinOp ">=" (EVar "i") (ELit (LInt 0)))) (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EFieldAccess (EVar "ctx") "pcOffsets")))) (EApp (EApp (EVar "offsetToLineColFast") (EFieldAccess (EVar "ctx") "pcLineStarts")) (EApp (EVar "fst") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EFieldAccess (EVar "ctx") "pcOffsets")))) (ETuple (ELit (LInt 0)) (ELit (LInt 0)))))
(DTypeSig true "depthOf" (TyFun (TyCon "ParseContext") (TyCon "Int")))
(DFunDef false "depthOf" ((PVar "ctx")) (EUnOp "!" (EFieldAccess (EVar "ctx") "pcDepth")))
(DTypeSig true "withDepth" (TyFun (TyCon "Int") (TyFun (TyCon "PFail") (TyFun (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a"))))))
(DFunDef false "withDepth" ((PVar "limit") (PVar "problem") (PVar "p")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EBlock (DoLet false false (PVar "depth") (EUnOp "!" (EFieldAccess (EVar "ctx") "pcDepth"))) (DoExpr (EIf (EBinOp ">=" (EVar "depth") (EVar "limit")) (EApp (EApp (EVar "PFatal") (EVar "problem")) (EVar "pos")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "ctx") "pcDepth")) (EBinOp "+" (EVar "depth") (ELit (LInt 1))))) (DoLet false false (PVar "r") (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "p")) (EVar "pos"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "ctx") "pcDepth")) (EVar "depth"))) (DoExpr (EVar "r")))))))))
(DTypeSig true "recordTrailingComma" (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyCon "Unit"))))
(DFunDef false "recordTrailingComma" ((PVar "p")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EBlock (DoLet false false (PCon "Loc" PWild (PVar "sl") (PVar "sc") PWild PWild) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "ctx") "pcCommas")) (EBinOp "::" (ETuple (EVar "sl") (EVar "sc")) (EUnOp "!" (EFieldAccess (EVar "ctx") "pcCommas"))))) (DoExpr (EApp (EApp (EVar "POk") (ELit LUnit)) (EVar "pos")))))))
(DTypeSig true "recordUnitStart" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyCon "Unit")))))
(DFunDef false "recordUnitStart" ((PVar "k") (PVar "p")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EBlock (DoLet false false (PCon "Loc" PWild (PVar "sl") (PVar "sc") PWild PWild) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "ctx") "pcUnits")) (EBinOp "::" (ETuple (EVar "k") (EVar "sl") (EVar "sc")) (EUnOp "!" (EFieldAccess (EVar "ctx") "pcUnits"))))) (DoExpr (EApp (EApp (EVar "POk") (ELit LUnit)) (EVar "pos")))))))
(DTypeSig true "forgetLatestUnitStart" (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyCon "Unit")))
(DFunDef false "forgetLatestUnitStart" () (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "ctx") "pcUnits")) (EMatch (EUnOp "!" (EFieldAccess (EVar "ctx") "pcUnits")) (arm (PList) () (EListLit)) (arm (PCons PWild (PVar "rest")) () (EVar "rest"))))) (DoExpr (EApp (EApp (EVar "POk") (ELit LUnit)) (EVar "pos")))))))
(DTypeSig true "contextCues" (TyFun (TyCon "ParseContext") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "contextCues" ((PVar "ctx")) (ETuple (EApp (EVar "reverseL") (EUnOp "!" (EFieldAccess (EVar "ctx") "pcCommas"))) (EApp (EVar "reverseL") (EUnOp "!" (EFieldAccess (EVar "ctx") "pcUnits")))))
(DTypeSig true "unexpectedTokenMsg" (TyFun (TyCon "Token") (TyCon "String")))
(DFunDef false "unexpectedTokenMsg" ((PVar "t")) (EBinOp "++" (ELit (LString "unexpected ")) (EApp (EVar "unexpectedTokenText") (EVar "t"))))
(DTypeSig false "unexpectedTokenText" (TyFun (TyCon "Token") (TyCon "String")))
(DFunDef false "unexpectedTokenText" ((PCon "TInt" PWild PWild)) (ELit (LString "number")))
(DFunDef false "unexpectedTokenText" ((PCon "TWideInt" PWild PWild PWild)) (ELit (LString "number")))
(DFunDef false "unexpectedTokenText" ((PCon "TFloat" PWild)) (ELit (LString "number")))
(DFunDef false "unexpectedTokenText" ((PCon "TString" PWild)) (ELit (LString "string")))
(DFunDef false "unexpectedTokenText" ((PCon "TInterpOpen" PWild)) (ELit (LString "string")))
(DFunDef false "unexpectedTokenText" ((PCon "TInterpMid" PWild)) (ELit (LString "string")))
(DFunDef false "unexpectedTokenText" ((PCon "TInterpEnd" PWild)) (ELit (LString "string")))
(DFunDef false "unexpectedTokenText" ((PCon "TChar" PWild)) (ELit (LString "character literal")))
(DFunDef false "unexpectedTokenText" ((PCon "TNewline")) (ELit (LString "line break")))
(DFunDef false "unexpectedTokenText" ((PCon "TIndent")) (ELit (LString "indentation")))
(DFunDef false "unexpectedTokenText" ((PCon "TDedent")) (ELit (LString "end of block")))
(DFunDef false "unexpectedTokenText" ((PVar "t")) (EApp (EVar "describeToken") (EVar "t")))
(DTypeSig false "expectedTokenMsg" (TyFun (TyCon "Token") (TyCon "String")))
(DFunDef false "expectedTokenMsg" ((PCon "TIndent")) (ELit (LString "an indented block")))
(DFunDef false "expectedTokenMsg" ((PCon "TDedent")) (ELit (LString "the end of the block")))
(DFunDef false "expectedTokenMsg" ((PVar "t")) (EApp (EVar "describeToken") (EVar "t")))
# MARK
(DUse false (UseGroup ("frontend" "lex_token") ((mem "Token" true) (mem "describeToken" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true))))
(DUse false (UseGroup ("frontend" "parse_diagnostic") ((mem "ParseDiagnosticKind" true) (mem "renderParseProblem" false))))
(DUse false (UseGroup ("frontend" "parse_positions") ((mem "locOfSpanWith" false))))
(DUse false (UseGroup ("support" "source_index") ((mem "lineStartsOf" false) (mem "offsetToLineColFast" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false))))
(DData Public "PR" ("a") ((variant "POk" (ConPos (TyVar "a") (TyCon "Int"))) (variant "PErr" (ConPos (TyCon "PFail") (TyCon "Int"))) (variant "PFatal" (ConPos (TyCon "PFail") (TyCon "Int")))) ())
(DData Public "PFail" () ((variant "FailMsg" (ConPos (TyCon "String"))) (variant "FailExpect" (ConPos (TyCon "Token") (TyCon "Token"))) (variant "FailProblem" (ConPos (TyCon "ParseDiagnosticKind")))) ())
(DData Public "ParseMode" () ((variant "UnlocatedSyntax" (ConPos)) (variant "LocatedSyntax" (ConPos)) (variant "UnlocatedChecked" (ConPos)) (variant "LocatedChecked" (ConPos))) ())
(DData Abstract "ParseContext" () ((variant "ParseContext" (ConNamed (field "pcTokens" (TyApp (TyCon "Array") (TyCon "Token"))) (field "pcOffsets" (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int")))) (field "pcLineStarts" (TyApp (TyCon "Array") (TyCon "Int"))) (field "pcLocated" (TyCon "Bool")) (field "pcGuardPositions" (TyCon "Bool")) (field "pcDepth" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "pcCommas" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (field "pcUnits" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int")))))))) ())
(DData Abstract "ParseMark" () ((variant "ParseMark" (ConPos (TyCon "ParseContext") (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int")))))) ())
(DData Public "ParserE" ("e" "a") ((variant "ParserE" (ConPos (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "PR") (TyVar "a")))))))) ())
(DTypeAlias true "Parser" ("a") (TyApp (TyApp (TyCon "ParserE") (TyRow () None)) (TyVar "a")))
(DTypeSig true "newParseContext" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyCon "ParseContext")))))
(DFunDef false "newParseContext" () (EApp (EVar "newParseContextWith") (EVar "LocatedChecked")))
(DTypeSig true "newParseContextWith" (TyFun (TyCon "ParseMode") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyCon "ParseContext"))))))
(DFunDef false "newParseContextWith" ((PVar "mode") (PVar "src") (PVar "toks") (PVar "offs")) (ERecordCreate "ParseContext" ((fa "pcTokens" (EVar "toks")) (fa "pcOffsets" (EVar "offs")) (fa "pcLineStarts" (EApp (EVar "lineStartsOf") (EVar "src"))) (fa "pcLocated" (EMatch (EVar "mode") (arm (PCon "LocatedSyntax") () (EVar "True")) (arm (PCon "LocatedChecked") () (EVar "True")) (arm PWild () (EVar "False")))) (fa "pcGuardPositions" (EMatch (EVar "mode") (arm (PCon "UnlocatedChecked") () (EVar "True")) (arm (PCon "LocatedChecked") () (EVar "True")) (arm PWild () (EVar "False")))) (fa "pcDepth" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "pcCommas" (EApp (EVar "Ref") (EListLit))) (fa "pcUnits" (EApp (EVar "Ref") (EListLit))))))
(DTypeSig true "contextTokens" (TyFun (TyCon "ParseContext") (TyApp (TyCon "Array") (TyCon "Token"))))
(DFunDef false "contextTokens" ((PVar "ctx")) (EFieldAccess (EVar "ctx") "pcTokens"))
(DTypeSig true "contextOffsets" (TyFun (TyCon "ParseContext") (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "contextOffsets" ((PVar "ctx")) (EFieldAccess (EVar "ctx") "pcOffsets"))
(DTypeSig true "contextLineStarts" (TyFun (TyCon "ParseContext") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "contextLineStarts" ((PVar "ctx")) (EFieldAccess (EVar "ctx") "pcLineStarts"))
(DTypeSig true "runPWith" (TyFun (TyCon "ParseContext") (TyFun (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a")) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "PR") (TyVar "a")))))))
(DFunDef false "runPWith" ((PVar "ctx") (PCon "ParserE" (PVar "f")) (PVar "pos")) (EApp (EApp (EVar "f") (EVar "ctx")) (EVar "pos")))
(DTypeSig true "runP" (TyFun (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "PR") (TyVar "a")))))))
(DFunDef false "runP" ((PVar "p") (PVar "toks") (PVar "pos")) (EApp (EApp (EApp (EVar "runPWith") (EApp (EApp (EApp (EApp (EVar "newParseContextWith") (EVar "UnlocatedSyntax")) (ELit (LString ""))) (EVar "toks")) (EApp (EVar "arrayFromList") (EListLit)))) (EVar "p")) (EVar "pos")))
(DTypeSig false "mapPR" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b"))) (TyFun (TyApp (TyCon "PR") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "PR") (TyVar "b"))))))
(DFunDef false "mapPR" ((PVar "f") (PCon "POk" (PVar "a") (PVar "pos"))) (EApp (EApp (EVar "POk") (EApp (EVar "f") (EVar "a"))) (EVar "pos")))
(DFunDef false "mapPR" (PWild (PCon "PErr" (PVar "e") (PVar "pos"))) (EApp (EApp (EVar "PErr") (EVar "e")) (EVar "pos")))
(DFunDef false "mapPR" (PWild (PCon "PFatal" (PVar "e") (PVar "pos"))) (EApp (EApp (EVar "PFatal") (EVar "e")) (EVar "pos")))
(DImpl false "DeferredMappable" ((TyCon "ParserE")) () ((im "deferMap" ((PVar "f") (PVar "pa")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EApp (EApp (EVar "mapPR") (EVar "f")) (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "pa")) (EVar "pos"))))))))
(DTypeSig false "apPR" (TyFun (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyFun (TyVar "a") (TyVar "b"))) (TyFun (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a")) (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "PR") (TyVar "b"))))))))
(DFunDef false "apPR" ((PVar "pf") (PVar "pa") (PVar "ctx") (PVar "pos")) (EMatch (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "pf")) (EVar "pos")) (arm (PCon "POk" (PVar "f") (PVar "pos1")) () (EApp (EApp (EVar "mapPR") (EVar "f")) (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "pa")) (EVar "pos1")))) (arm (PCon "PErr" (PVar "e") (PVar "pos1")) () (EApp (EApp (EVar "PErr") (EVar "e")) (EVar "pos1"))) (arm (PCon "PFatal" (PVar "e") (PVar "pos1")) () (EApp (EApp (EVar "PFatal") (EVar "e")) (EVar "pos1")))))
(DImpl false "DeferredApplicative" ((TyCon "ParserE")) () ((im "deferPure" ((PVar "x")) (EApp (EVar "ParserE") (ELam ((PVar "_ctx") (PVar "pos")) (EApp (EApp (EVar "POk") (EVar "x")) (EVar "pos"))))) (im "deferAp" ((PVar "pf") (PVar "pa")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EApp (EApp (EApp (EApp (EVar "apPR") (EVar "pf")) (EVar "pa")) (EVar "ctx")) (EVar "pos")))))))
(DTypeSig false "bindPR" (TyFun (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a")) (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "b")))) (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "PR") (TyVar "b"))))))))
(DFunDef false "bindPR" ((PVar "pa") (PVar "k") (PVar "ctx") (PVar "pos")) (EMatch (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "pa")) (EVar "pos")) (arm (PCon "POk" (PVar "a") (PVar "pos1")) () (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EApp (EVar "k") (EVar "a"))) (EVar "pos1"))) (arm (PCon "PErr" (PVar "e") (PVar "pos1")) () (EApp (EApp (EVar "PErr") (EVar "e")) (EVar "pos1"))) (arm (PCon "PFatal" (PVar "e") (PVar "pos1")) () (EApp (EApp (EVar "PFatal") (EVar "e")) (EVar "pos1")))))
(DImpl false "DeferredThenable" ((TyCon "ParserE")) () ((im "deferThen" ((PVar "pa") (PVar "k")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EApp (EApp (EApp (EApp (EVar "bindPR") (EVar "pa")) (EVar "k")) (EVar "ctx")) (EVar "pos")))))))
(DTypeSig true "contextP" (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyCon "ParseContext")))
(DFunDef false "contextP" () (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EApp (EApp (EVar "POk") (EVar "ctx")) (EVar "pos")))))
(DTypeSig true "getPos" (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyCon "Int")))
(DFunDef false "getPos" () (EApp (EVar "ParserE") (ELam ((PVar "_ctx") (PVar "pos")) (EApp (EApp (EVar "POk") (EVar "pos")) (EVar "pos")))))
(DTypeSig true "peekTok" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Token"))))
(DFunDef false "peekTok" ((PVar "toks") (PVar "pos")) (EIf (EBinOp "<" (EVar "pos") (EApp (EVar "arrayLength") (EVar "toks"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pos")) (EVar "toks")) (EIf (EVar "otherwise") (EVar "TEof") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "peekP" (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyCon "Token")))
(DFunDef false "peekP" () (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EApp (EApp (EVar "POk") (EApp (EApp (EVar "peekTok") (EFieldAccess (EVar "ctx") "pcTokens")) (EVar "pos"))) (EVar "pos")))))
(DTypeSig true "peek2P" (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyCon "Token")))
(DFunDef false "peek2P" () (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EApp (EApp (EVar "POk") (EApp (EApp (EVar "peekTok") (EFieldAccess (EVar "ctx") "pcTokens")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (EVar "pos")))))
(DTypeSig true "peek3P" (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyCon "Token")))
(DFunDef false "peek3P" () (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EApp (EApp (EVar "POk") (EApp (EApp (EVar "peekTok") (EFieldAccess (EVar "ctx") "pcTokens")) (EBinOp "+" (EVar "pos") (ELit (LInt 2))))) (EVar "pos")))))
(DTypeSig true "advance" (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyCon "Token")))
(DFunDef false "advance" () (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EMatch (EApp (EApp (EVar "peekTok") (EFieldAccess (EVar "ctx") "pcTokens")) (EVar "pos")) (arm (PCon "TEof") () (EApp (EApp (EVar "PErr") (EApp (EVar "FailProblem") (EVar "UnexpectedEnd"))) (EVar "pos"))) (arm (PVar "t") () (EApp (EApp (EVar "POk") (EVar "t")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))))))
(DTypeSig true "emit" (TyFun (TyVar "a") (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a"))))
(DFunDef false "emit" ((PVar "x")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EVar "x")))))
(DTypeSig true "expectTok" (TyFun (TyCon "Token") (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyCon "Unit"))))
(DFunDef false "expectTok" ((PVar "t")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EBlock (DoLet false false (PVar "x") (EApp (EApp (EVar "peekTok") (EFieldAccess (EVar "ctx") "pcTokens")) (EVar "pos"))) (DoExpr (EIf (EBinOp "==" (EVar "x") (EVar "t")) (EMatch (EVar "x") (arm (PCon "TEof") () (EApp (EApp (EVar "PErr") (EApp (EVar "FailProblem") (EVar "UnexpectedEnd"))) (EVar "pos"))) (arm PWild () (EApp (EApp (EVar "POk") (ELit LUnit)) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))) (EApp (EApp (EVar "PErr") (EApp (EApp (EVar "FailExpect") (EVar "x")) (EVar "t"))) (EVar "pos"))))))))
(DTypeSig true "failP" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a"))))
(DFunDef false "failP" ((PVar "msg")) (EApp (EVar "ParserE") (ELam ((PVar "_ctx") (PVar "pos")) (EApp (EApp (EVar "PErr") (EApp (EVar "FailMsg") (EVar "msg"))) (EVar "pos")))))
(DTypeSig true "fatalP" (TyFun (TyCon "ParseDiagnosticKind") (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a"))))
(DFunDef false "fatalP" ((PVar "kind")) (EApp (EVar "ParserE") (ELam ((PVar "_ctx") (PVar "pos")) (EApp (EApp (EVar "PFatal") (EApp (EVar "FailProblem") (EVar "kind"))) (EVar "pos")))))
(DTypeSig true "fatalProblemAtP" (TyFun (TyCon "ParseDiagnosticKind") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a")))))
(DFunDef false "fatalProblemAtP" ((PVar "kind") (PVar "pos0")) (EApp (EVar "ParserE") (ELam ((PVar "_ctx") (PVar "_pos")) (EApp (EApp (EVar "PFatal") (EApp (EVar "FailProblem") (EVar "kind"))) (EVar "pos0")))))
(DTypeSig true "fatalAtP" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a")))))
(DFunDef false "fatalAtP" ((PVar "msg") (PVar "pos0")) (EApp (EVar "ParserE") (ELam ((PVar "_ctx") (PVar "_pos")) (EApp (EApp (EVar "PFatal") (EApp (EVar "FailMsg") (EVar "msg"))) (EVar "pos0")))))
(DTypeSig true "renderFail" (TyFun (TyCon "PFail") (TyCon "String")))
(DFunDef false "renderFail" ((PCon "FailMsg" (PVar "m"))) (EVar "m"))
(DFunDef false "renderFail" ((PCon "FailProblem" (PVar "kind"))) (EApp (EVar "renderParseProblem") (EVar "kind")))
(DFunDef false "renderFail" ((PCon "FailExpect" (PVar "x") (PVar "t"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "unexpectedTokenMsg") (EVar "x")))) (ELit (LString "; expected "))) (EApp (EMethodRef "display") (EApp (EVar "expectedTokenMsg") (EVar "t")))) (ELit (LString ""))))
(DTypeSig true "failProblem" (TyFun (TyCon "PFail") (TyCon "ParseDiagnosticKind")))
(DFunDef false "failProblem" ((PCon "FailProblem" (PVar "kind"))) (EVar "kind"))
(DFunDef false "failProblem" ((PCon "FailExpect" (PCon "TEof") (PVar "expected"))) (EApp (EVar "UnexpectedEndExpected") (EApp (EVar "expectedTokenMsg") (EVar "expected"))))
(DFunDef false "failProblem" ((PVar "other")) (EApp (EVar "GenericParse") (EApp (EVar "renderFail") (EVar "other"))))
(DTypeSig true "mark" (TyFun (TyCon "ParseContext") (TyCon "ParseMark")))
(DFunDef false "mark" ((PVar "ctx")) (EApp (EApp (EApp (EApp (EVar "ParseMark") (EVar "ctx")) (EUnOp "!" (EFieldAccess (EVar "ctx") "pcDepth"))) (EUnOp "!" (EFieldAccess (EVar "ctx") "pcCommas"))) (EUnOp "!" (EFieldAccess (EVar "ctx") "pcUnits"))))
(DTypeSig true "rewind" (TyFun (TyCon "ParseMark") (TyCon "Unit")))
(DFunDef false "rewind" ((PCon "ParseMark" (PVar "ctx") (PVar "depth") (PVar "commas") (PVar "units"))) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "ctx") "pcDepth")) (EVar "depth"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "ctx") "pcCommas")) (EVar "commas"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "ctx") "pcUnits")) (EVar "units")))))
(DTypeSig true "orElse#shadow" (TyFun (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a")) (TyFun (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a")))))
(DFunDef false "orElse#shadow" ((PVar "pa") (PVar "pb")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EBlock (DoLet false false (PVar "saved") (EApp (EVar "mark") (EVar "ctx"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "pa")) (EVar "pos")) (arm (PAs "r" (PCon "POk" PWild PWild)) () (EVar "r")) (arm (PAs "r" (PCon "PFatal" PWild PWild)) () (EBlock (DoExpr (EApp (EVar "rewind") (EVar "saved"))) (DoExpr (EVar "r")))) (arm (PCon "PErr" (PVar "ea") (PVar "qa")) () (EBlock (DoExpr (EApp (EVar "rewind") (EVar "saved"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "pb")) (EVar "pos")) (arm (PAs "r" (PCon "POk" PWild PWild)) () (EVar "r")) (arm (PAs "r" (PCon "PFatal" PWild PWild)) () (EBlock (DoExpr (EApp (EVar "rewind") (EVar "saved"))) (DoExpr (EVar "r")))) (arm (PCon "PErr" (PVar "eb") (PVar "qb")) () (EBlock (DoExpr (EApp (EVar "rewind") (EVar "saved"))) (DoExpr (EIf (EBinOp ">" (EVar "qa") (EVar "qb")) (EApp (EApp (EVar "PErr") (EVar "ea")) (EVar "qa")) (EApp (EApp (EVar "PErr") (EVar "eb")) (EVar "qb"))))))))))))))))
(DTypeSig true "many" (TyFun (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "many" ((PVar "p")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EApp (EApp (EApp (EApp (EVar "manyGo") (EVar "p")) (EVar "ctx")) (EVar "pos")) (EListLit)))))
(DTypeSig false "manyGo" (TyFun (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a")) (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "PR") (TyApp (TyCon "List") (TyVar "a")))))))))
(DFunDef false "manyGo" ((PVar "p") (PVar "ctx") (PVar "pos") (PVar "acc")) (EBlock (DoLet false false (PVar "saved") (EApp (EVar "mark") (EVar "ctx"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "p")) (EVar "pos")) (arm (PCon "POk" (PVar "x") (PVar "q")) () (EIf (EBinOp ">" (EVar "q") (EVar "pos")) (EApp (EApp (EApp (EApp (EVar "manyGo") (EVar "p")) (EVar "ctx")) (EVar "q")) (EBinOp "::" (EVar "x") (EVar "acc"))) (EBlock (DoExpr (EApp (EVar "rewind") (EVar "saved"))) (DoExpr (EApp (EApp (EVar "POk") (EApp (EVar "reverseL") (EBinOp "::" (EVar "x") (EVar "acc")))) (EVar "q")))))) (arm (PCon "PFatal" (PVar "e") (PVar "q")) () (EBlock (DoExpr (EApp (EVar "rewind") (EVar "saved"))) (DoExpr (EApp (EApp (EVar "PFatal") (EVar "e")) (EVar "q"))))) (arm (PCon "PErr" PWild PWild) () (EBlock (DoExpr (EApp (EVar "rewind") (EVar "saved"))) (DoExpr (EApp (EApp (EVar "POk") (EApp (EVar "reverseL") (EVar "acc"))) (EVar "pos")))))))))
(DTypeSig true "sepThen" (TyFun (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "b")) (TyFun (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a")))))
(DFunDef false "sepThen" ((PVar "sep") (PVar "p")) (EApp (EApp (EMethodRef "deferThen") (EVar "sep")) (ELam (PWild) (EVar "p"))))
(DTypeSig true "sepBy1" (TyFun (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a")) (TyFun (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "b")) (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "sepBy1" ((PVar "p") (PVar "sep")) (EApp (EApp (EMethodRef "deferThen") (EVar "p")) (ELam ((PVar "x")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "many") (EApp (EApp (EVar "sepThen") (EVar "sep")) (EVar "p")))) (ELam ((PVar "xs")) (EApp (EMethodRef "deferPure") (EBinOp "::" (EVar "x") (EVar "xs"))))))))
(DTypeSig true "locOfSpan" (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Loc")))))
(DFunDef false "locOfSpan" ((PVar "ctx") (PVar "start") (PVar "end")) (EIf (EFieldAccess (EVar "ctx") "pcLocated") (EApp (EApp (EApp (EApp (EVar "locOfSpanWith") (EFieldAccess (EVar "ctx") "pcOffsets")) (EFieldAccess (EVar "ctx") "pcLineStarts")) (EVar "start")) (EVar "end")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 1))) (ELit (LInt 0))) (ELit (LInt 1))) (ELit (LInt 0)))))
(DTypeSig true "spanLoc" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyCon "Loc")))))
(DFunDef false "spanLoc" ((PVar "start") (PVar "end")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EApp (EApp (EVar "POk") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "start")) (EVar "end"))) (EVar "pos")))))
(DTypeSig true "tokLineCol" (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "tokLineCol" ((PVar "ctx") (PVar "i")) (EIf (EBinOp "&&" (EBinOp "&&" (EFieldAccess (EVar "ctx") "pcGuardPositions") (EBinOp ">=" (EVar "i") (ELit (LInt 0)))) (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EFieldAccess (EVar "ctx") "pcOffsets")))) (EApp (EApp (EVar "offsetToLineColFast") (EFieldAccess (EVar "ctx") "pcLineStarts")) (EApp (EVar "fst") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EFieldAccess (EVar "ctx") "pcOffsets")))) (ETuple (ELit (LInt 0)) (ELit (LInt 0)))))
(DTypeSig true "depthOf" (TyFun (TyCon "ParseContext") (TyCon "Int")))
(DFunDef false "depthOf" ((PVar "ctx")) (EUnOp "!" (EFieldAccess (EVar "ctx") "pcDepth")))
(DTypeSig true "withDepth" (TyFun (TyCon "Int") (TyFun (TyCon "PFail") (TyFun (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyVar "a"))))))
(DFunDef false "withDepth" ((PVar "limit") (PVar "problem") (PVar "p")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EBlock (DoLet false false (PVar "depth") (EUnOp "!" (EFieldAccess (EVar "ctx") "pcDepth"))) (DoExpr (EIf (EBinOp ">=" (EVar "depth") (EVar "limit")) (EApp (EApp (EVar "PFatal") (EVar "problem")) (EVar "pos")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "ctx") "pcDepth")) (EBinOp "+" (EVar "depth") (ELit (LInt 1))))) (DoLet false false (PVar "r") (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "p")) (EVar "pos"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "ctx") "pcDepth")) (EVar "depth"))) (DoExpr (EVar "r")))))))))
(DTypeSig true "recordTrailingComma" (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyCon "Unit"))))
(DFunDef false "recordTrailingComma" ((PVar "p")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EBlock (DoLet false false (PCon "Loc" PWild (PVar "sl") (PVar "sc") PWild PWild) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "ctx") "pcCommas")) (EBinOp "::" (ETuple (EVar "sl") (EVar "sc")) (EUnOp "!" (EFieldAccess (EVar "ctx") "pcCommas"))))) (DoExpr (EApp (EApp (EVar "POk") (ELit LUnit)) (EVar "pos")))))))
(DTypeSig true "recordUnitStart" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyCon "Unit")))))
(DFunDef false "recordUnitStart" ((PVar "k") (PVar "p")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EBlock (DoLet false false (PCon "Loc" PWild (PVar "sl") (PVar "sc") PWild PWild) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "ctx") "pcUnits")) (EBinOp "::" (ETuple (EVar "k") (EVar "sl") (EVar "sc")) (EUnOp "!" (EFieldAccess (EVar "ctx") "pcUnits"))))) (DoExpr (EApp (EApp (EVar "POk") (ELit LUnit)) (EVar "pos")))))))
(DTypeSig true "forgetLatestUnitStart" (TyApp (TyApp (TyCon "ParserE") (TyVar "e")) (TyCon "Unit")))
(DFunDef false "forgetLatestUnitStart" () (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "ctx") "pcUnits")) (EMatch (EUnOp "!" (EFieldAccess (EVar "ctx") "pcUnits")) (arm (PList) () (EListLit)) (arm (PCons PWild (PVar "rest")) () (EVar "rest"))))) (DoExpr (EApp (EApp (EVar "POk") (ELit LUnit)) (EVar "pos")))))))
(DTypeSig true "contextCues" (TyFun (TyCon "ParseContext") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "contextCues" ((PVar "ctx")) (ETuple (EApp (EVar "reverseL") (EUnOp "!" (EFieldAccess (EVar "ctx") "pcCommas"))) (EApp (EVar "reverseL") (EUnOp "!" (EFieldAccess (EVar "ctx") "pcUnits")))))
(DTypeSig true "unexpectedTokenMsg" (TyFun (TyCon "Token") (TyCon "String")))
(DFunDef false "unexpectedTokenMsg" ((PVar "t")) (EBinOp "++" (ELit (LString "unexpected ")) (EApp (EVar "unexpectedTokenText") (EVar "t"))))
(DTypeSig false "unexpectedTokenText" (TyFun (TyCon "Token") (TyCon "String")))
(DFunDef false "unexpectedTokenText" ((PCon "TInt" PWild PWild)) (ELit (LString "number")))
(DFunDef false "unexpectedTokenText" ((PCon "TWideInt" PWild PWild PWild)) (ELit (LString "number")))
(DFunDef false "unexpectedTokenText" ((PCon "TFloat" PWild)) (ELit (LString "number")))
(DFunDef false "unexpectedTokenText" ((PCon "TString" PWild)) (ELit (LString "string")))
(DFunDef false "unexpectedTokenText" ((PCon "TInterpOpen" PWild)) (ELit (LString "string")))
(DFunDef false "unexpectedTokenText" ((PCon "TInterpMid" PWild)) (ELit (LString "string")))
(DFunDef false "unexpectedTokenText" ((PCon "TInterpEnd" PWild)) (ELit (LString "string")))
(DFunDef false "unexpectedTokenText" ((PCon "TChar" PWild)) (ELit (LString "character literal")))
(DFunDef false "unexpectedTokenText" ((PCon "TNewline")) (ELit (LString "line break")))
(DFunDef false "unexpectedTokenText" ((PCon "TIndent")) (ELit (LString "indentation")))
(DFunDef false "unexpectedTokenText" ((PCon "TDedent")) (ELit (LString "end of block")))
(DFunDef false "unexpectedTokenText" ((PVar "t")) (EApp (EVar "describeToken") (EVar "t")))
(DTypeSig false "expectedTokenMsg" (TyFun (TyCon "Token") (TyCon "String")))
(DFunDef false "expectedTokenMsg" ((PCon "TIndent")) (ELit (LString "an indented block")))
(DFunDef false "expectedTokenMsg" ((PCon "TDedent")) (ELit (LString "the end of the block")))
(DFunDef false "expectedTokenMsg" ((PVar "t")) (EApp (EVar "describeToken") (EVar "t")))
