# META
source_lines=446
stages=DESUGAR,MARK
# SOURCE
import list.{reverse}
import array.{sliceClamped}
import frontend.parser as P
import frontend.lexer.{tokenizeWithOffsetPairs}
import frontend.lex_token.{Token(..), isNoiseTok, isEofTok}
import frontend.parse_engine.{
  ParseContext, PR(..), newParseContext, contextTokens, contextOffsets,
  contextLineStarts, peekTok, mark, rewind, failProblem, locOfSpan
}
import frontend.parse_result.{
  ParsedSource, parsedDecls, parsedPositions, parseErrorDiagnostic
}
import frontend.parse_positions.{Positions(..), positionsFromSpans}
import frontend.parse_diagnostic.{
  ParseDiagnostic, ParseDiagnosticKind(..), makeParseDiagnostic
}
import frontend.ast.{Decl, Loc(..)}
import support.source_index.{SourceIndex, indexSource, offsetToLineColFast}
import support.util.{isEmptyL, isNonEmptyL}

import frontend.recovery_result.{
  RecoveredSource, SourceExtent(..), InvalidReason(..), RecoveryStop(..),
  RecoveryCompleteness(..), RecoveryStats(..), makeInvalidRegion,
  makeRecoveredSource, recoveredDecls, recoveredPositions, recoveredDiagnostics,
  invalidRegions, recoveredCompleteness, recoveredStats
}

public export data RecoveryLimits = RecoveryLimits Int Int Int Int deriving (Eq)

export
defaultRecoveryLimits : RecoveryLimits
defaultRecoveryLimits = RecoveryLimits 8388608 500000 4096 32

data DelimiterKind =
  | Paren
  | Bracket
  | ArrayDelimiter
  | Brace
  | Interpolation
  deriving (Eq)

openKind : Token -> Option DelimiterKind
openKind TLParen = Some Paren
openKind TLBracket = Some Bracket
openKind TLBracketTight = Some Bracket
openKind TLArray = Some ArrayDelimiter
openKind TLBrace = Some Brace
openKind TDotLBrace = Some Brace
openKind (TInterpOpen _) = Some Interpolation
openKind _ = None

closeKind : Token -> Option DelimiterKind
closeKind TRParen = Some Paren
closeKind TRBracket = Some Bracket
closeKind TRArray = Some ArrayDelimiter
closeKind TRBrace = Some Brace
closeKind (TInterpEnd _) = Some Interpolation
closeKind _ = None

fences : ParseContext -> (Array Bool, Option InvalidReason)
fences ctx =
  let (flags, reason) = walkFence ctx 0 0 [] False []
  (arrayFromList (reverse flags), reason)

walkFence : ParseContext ->
  Int ->
  Int ->
  List DelimiterKind ->
  Bool ->
  List Bool ->
  (List Bool, Option InvalidReason)
walkFence ctx p depth stack poison acc
  | p >= arrayLength (contextTokens ctx) = (
    acc,
    if poison then
      Some MismatchedDelimiter
    else if isNonEmptyL stack then
      Some UnclosedDelimiter
    else
      None,
  )
  | otherwise =
    let t = peekTok (contextTokens ctx) p
    let off = fst (arrayGetUnsafe p (contextOffsets ctx))
    let (_line, col) = offsetToLineColFast (contextLineStarts ctx) off
    let allowed =
      col == 0
        && not (isNoiseTok t)
        && depth == 0
        && isEmptyL stack
        && not poison
    let d = match t
      TIndent => depth + 1
      TDedent => max 0 (depth - 1)
      _ => depth
    match openKind t
      Some o => walkFence ctx (p + 1) d (o :: stack) poison (allowed :: acc)
      None => match closeKind t
        Some c => match stack
          [] => walkFence ctx (p + 1) d [] poison (allowed :: acc)
          k :: rest =>
            walkFence ctx (p + 1) d rest (poison || k /= c) (allowed :: acc)
        None => walkFence ctx (p + 1) d stack poison (allowed :: acc)

noiseEnd : ParseContext -> Int -> Int
noiseEnd ctx p
  | isNoiseTok (peekTok (contextTokens ctx) p) = noiseEnd ctx (p + 1)
  | otherwise = p

nextFence : ParseContext -> Array Bool -> Int -> Int
nextFence ctx fs start =
  let go p =
    if p >= arrayLength fs
      || isEofTok (peekTok (contextTokens ctx) p)
      || arrayGetUnsafe p fs then
      p
    else
      go (p + 1)
  go start

offAt : ParseContext -> Int -> Int -> Int
offAt ctx size p
  | isEofTok (peekTok (contextTokens ctx) p) = size
  | p < arrayLength (contextOffsets ctx) =
    fst (arrayGetUnsafe p (contextOffsets ctx))
  | otherwise = size

sliceList : Array a -> Int -> Int -> List a
sliceList xs s e = toList (sliceClamped s e xs)

data RecoveryContext = {
  limits : RecoveryLimits,
  source : String,
  index : Unit -> SourceIndex,
  parser : ParseContext,
  fences : Array Bool,
  damage : Option InvalidReason,
  size : Int,
}

data RecoveryState = {
  position : Int,
  spans : List (Decl, Int, Int),
  diagnostics : List ParseDiagnostic,
  regions : List (Int, Int, InvalidReason),
  attempts : Int,
}

publish : RecoveryContext -> RecoveryState -> RecoveryStop -> RecoveredSource
publish run state stop =
  let ctx = run.parser
  let spans = reverse state.spans
  makeRecoveredSource
    (map ((d, _s, _e) => d) spans)
    (positionsFromSpans
      (contextLineStarts ctx)
      (contextTokens ctx)
      (contextOffsets ctx)
      spans)
    (reverse state.diagnostics)
    (map
      ((s, e, reason) => makeInvalidRegion (SourceExtent s e) reason)
      (reverse state.regions))
    (Partial stop)
    (RecoveryStats
      (arrayLength (contextTokens ctx))
      state.attempts
      (length state.diagnostics))

failureDiag : ParseContext ->
  Int ->
  Int ->
  ParseDiagnosticKind ->
  ParseDiagnostic
failureDiag ctx size p problem =
  let loc =
    if isEofTok (peekTok (contextTokens ctx) p)
      || size > 0
        && offAt ctx size p == 0
        && isEofTok (peekTok (contextTokens ctx) (noiseEnd ctx p)) then
      let (line, col) = offsetToLineColFast (contextLineStarts ctx) size
      Loc "" line col line col
    else
      locOfSpan ctx p (p + 1)
  makeParseDiagnostic problem loc

recoverLoop : RecoveryContext -> RecoveryState -> RecoveredSource
recoverLoop run state =
  let ctx = run.parser
  let fs = run.fences
  let size = run.size
  let p = state.position
  let (RecoveryLimits _ _ maxAttempts maxDiagnostics) = run.limits
  if isEofTok (peekTok (contextTokens ctx) p) then
    publish run state ReachedEnd
  else if state.attempts >= maxAttempts
    || length state.diagnostics >= maxDiagnostics then
    publish
      run
      { state |
        regions = (offAt ctx size p, size, RecoveryBudget) :: state.regions,
      }
      ExhaustedBudget
  else if p >= arrayLength fs || not (arrayGetUnsafe p fs) then
    publish
      run
      { state |
        regions = (offAt ctx size p, size, UntrustedBoundary) :: state.regions,
      }
      StoppedBoundary
  else match peekTok (contextTokens ctx) p
    TLexError kind =>
      publish
        run
        { state |
          diagnostics = failureDiag ctx size p kind :: state.diagnostics,
          regions = (offAt ctx size p, size, TerminalLexError) :: state.regions,
          attempts = state.attempts + 1,
        }
        StoppedLexically
    _ =>
      let saved = mark ctx
      let rejectFailure f q =
        reject run state (failureDiag ctx size q (failProblem f))
      match P.parseDeclAt ctx p
        POk d q =>
          let end = noiseEnd ctx q
          let boundary =
            isEofTok (peekTok (contextTokens ctx) end)
              || end < arrayLength fs && arrayGetUnsafe end fs
          if q > p && boundary then
            let ts = sliceList (contextTokens ctx) p q
            let os = sliceList (contextOffsets ctx) p q
            match (P.prescanErrorPairsWithIndex
              run.source
              (ts ++ [TEof])
              (os ++ [(offAt ctx size q, offAt ctx size q)])
              run.index)
              None => recoverLoop run { state |
                position = end,
                spans = (d, p, q) :: state.spans,
                attempts = state.attempts + 1,
              }
              Some err =>
                rewind saved
                reject run state (parseErrorDiagnostic err)
          else
            rewind saved
            reject
              run
              state
              (failureDiag
                ctx
                size
                q
                (GenericParse "declaration did not end at a safe boundary"))
        PErr f q => rejectFailure f q
        PFatal f q => rejectFailure f q

reject : RecoveryContext -> RecoveryState -> ParseDiagnostic -> RecoveredSource
reject run state diagnostic =
  let ctx = run.parser
  let size = run.size
  let p = state.position
  let next = nextFence ctx run.fences (p + 1)
  let terminal = findLex ctx p (min (arrayLength run.fences) (next + 1))
  match terminal
    Some terminal =>
      let kind = match peekTok (contextTokens ctx) terminal
        TLexError k => k
        _ => GenericParse "unreachable"
      publish
        run
        { state |
          diagnostics = failureDiag ctx size terminal kind :: state.diagnostics,
          regions = (offAt ctx size p, size, TerminalLexError) :: state.regions,
          attempts = state.attempts + 1,
        }
        StoppedLexically
    None =>
      let ts = sliceList (contextTokens ctx) p next
      let os = sliceList (contextOffsets ctx) p next
      let checked =
        match (P.prescanErrorPairsWithIndex
          run.source
          (ts ++ [TEof])
          (os ++ [(size, size)])
          run.index)
          Some err => parseErrorDiagnostic err
          None => diagnostic
      let updated = { state |
        diagnostics = checked :: state.diagnostics,
        attempts = state.attempts + 1,
      }
      match (isEofTok (peekTok (contextTokens ctx) next), run.damage)
        (True, Some reason) =>
          publish
            run
            { updated |
              regions = (offAt ctx size p, size, reason) :: state.regions,
            }
            StoppedDelimiter
        _ => recoverLoop run { updated |
          position = next,
          regions =
            (offAt ctx size p, offAt ctx size next, InvalidDeclaration)
              :: state.regions,
        }

findLex : ParseContext -> Int -> Int -> Option Int
findLex ctx start end =
  let go p =
    if p >= end then
      None
    else match peekTok (contextTokens ctx) p
      TLexError _ => Some p
      _ => go (p + 1)
  go start

export
parseRecovering : String -> RecoveredSource
parseRecovering = parseRecoveringWith defaultRecoveryLimits

export
parseRecoveringWith : RecoveryLimits -> String -> RecoveredSource
parseRecoveringWith (limits@(RecoveryLimits maxSource maxTokens maxAttempts maxDiagnostics)) src
  | min (min maxSource maxTokens) (min maxAttempts maxDiagnostics) < 0 =
    budgetResult src 0
  | stringLength src > maxSource = budgetResult src 0
  | otherwise =
    let cell = Ref None
    let index () = match !cell
      Some value => value
      None =>
        let value = indexSource src
        cell := Some value
        value
    recoverTokens limits src index

export
defaultRecoveryAdmission : String -> Option RecoveredSource
defaultRecoveryAdmission src = match defaultRecoveryLimits
  RecoveryLimits maxSource _ _ _ =>
    if stringLength src > maxSource then Some (budgetResult src 0) else None

export
parseRecoveringWithIndex : SourceIndex -> String -> RecoveredSource
parseRecoveringWithIndex index src = match defaultRecoveryAdmission src
  Some result => result
  None => recoverTokens defaultRecoveryLimits src (() => index)

export
budgetResult : String -> Int -> RecoveredSource
budgetResult src count =
  makeRecoveredSource
    []
    (Positions [] [] 0 [])
    []
    [makeInvalidRegion (SourceExtent 0 (stringLength src)) RecoveryBudget]
    (Partial ExhaustedBudget)
    (RecoveryStats count 0 0)

recoverTokens : RecoveryLimits ->
  String ->
  (Unit -> SourceIndex) ->
  RecoveredSource
recoverTokens (limits@(RecoveryLimits _ maxTokens _ _)) src index =
  let (ts, os) = tokenizeWithOffsetPairs src
  let count = length ts
  if count > maxTokens then
    budgetResult src count
  else
    recoverPrepared
      limits
      src
      index
      ts
      os
      (P.parseSourcePairsWithIndex src ts os index)

export
recoverSourcePairsWithIndex : RecoveryLimits ->
  SourceIndex ->
  String ->
  List Token ->
  List (Int, Int) ->
  Result ParseDiagnostic ParsedSource ->
  RecoveredSource
recoverSourcePairsWithIndex limits index src ts os strict =
  recoverPrepared limits src (() => index) ts os strict

recoverPrepared : RecoveryLimits ->
  String ->
  (Unit -> SourceIndex) ->
  List Token ->
  List (Int, Int) ->
  Result ParseDiagnostic ParsedSource ->
  RecoveredSource
recoverPrepared limits src index ts os strict =
  let count = length ts
  match strict
    Ok result =>
      makeRecoveredSource
        (parsedDecls result)
        (parsedPositions result)
        []
        []
        Complete
        (RecoveryStats count 0 0)
    Err firstDiagnostic =>
      let ctx = newParseContext src (arrayFromList ts) (arrayFromList os)
      let (fs, damage) = fences ctx
      let run = RecoveryContext {
        limits = limits,
        source = src,
        index = index,
        parser = ctx,
        fences = fs,
        damage = damage,
        size = stringLength src,
      }
      let state = RecoveryState {
        position = noiseEnd ctx 0,
        spans = [],
        diagnostics = [],
        regions = [],
        attempts = 0,
      }
      ensureDiagnostic limits firstDiagnostic (recoverLoop run state)

ensureDiagnostic : RecoveryLimits ->
  ParseDiagnostic ->
  RecoveredSource ->
  RecoveredSource
ensureDiagnostic (RecoveryLimits _ _ _ maxDiagnostics) diagnostic result =
  if maxDiagnostics <= 0 || not (isEmpty (recoveredDiagnostics result)) then
    result
  else
    makeRecoveredSource
      (recoveredDecls result)
      (recoveredPositions result)
      [diagnostic]
      (invalidRegions result)
      (recoveredCompleteness result)
      (match recoveredStats result
        RecoveryStats tokens attempts _ => RecoveryStats tokens attempts 1)
# DESUGAR
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseGroup ("array") ((mem "sliceClamped" false))))
(DUse false (UseAlias ("frontend" "parser") "P"))
(DUse false (UseGroup ("frontend" "lexer") ((mem "tokenizeWithOffsetPairs" false))))
(DUse false (UseGroup ("frontend" "lex_token") ((mem "Token" true) (mem "isNoiseTok" false) (mem "isEofTok" false))))
(DUse false (UseGroup ("frontend" "parse_engine") ((mem "ParseContext" false) (mem "PR" true) (mem "newParseContext" false) (mem "contextTokens" false) (mem "contextOffsets" false) (mem "contextLineStarts" false) (mem "peekTok" false) (mem "mark" false) (mem "rewind" false) (mem "failProblem" false) (mem "locOfSpan" false))))
(DUse false (UseGroup ("frontend" "parse_result") ((mem "ParsedSource" false) (mem "parsedDecls" false) (mem "parsedPositions" false) (mem "parseErrorDiagnostic" false))))
(DUse false (UseGroup ("frontend" "parse_positions") ((mem "Positions" true) (mem "positionsFromSpans" false))))
(DUse false (UseGroup ("frontend" "parse_diagnostic") ((mem "ParseDiagnostic" false) (mem "ParseDiagnosticKind" true) (mem "makeParseDiagnostic" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "Loc" true))))
(DUse false (UseGroup ("support" "source_index") ((mem "SourceIndex" false) (mem "indexSource" false) (mem "offsetToLineColFast" false))))
(DUse false (UseGroup ("support" "util") ((mem "isEmptyL" false) (mem "isNonEmptyL" false))))
(DUse false (UseGroup ("frontend" "recovery_result") ((mem "RecoveredSource" false) (mem "SourceExtent" true) (mem "InvalidReason" true) (mem "RecoveryStop" true) (mem "RecoveryCompleteness" true) (mem "RecoveryStats" true) (mem "makeInvalidRegion" false) (mem "makeRecoveredSource" false) (mem "recoveredDecls" false) (mem "recoveredPositions" false) (mem "recoveredDiagnostics" false) (mem "invalidRegions" false) (mem "recoveredCompleteness" false) (mem "recoveredStats" false))))
(DData Public "RecoveryLimits" () ((variant "RecoveryLimits" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))) ())
(DImpl true "Eq" ((TyCon "RecoveryLimits")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "RecoveryLimits" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3")) (PCon "RecoveryLimits" (PVar "__b0") (PVar "__b1") (PVar "__b2") (PVar "__b3"))) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EVar "eq") (EVar "__a3")) (EVar "__b3"))))))))
(DTypeSig true "defaultRecoveryLimits" (TyCon "RecoveryLimits"))
(DFunDef false "defaultRecoveryLimits" () (EApp (EApp (EApp (EApp (EVar "RecoveryLimits") (ELit (LInt 8388608))) (ELit (LInt 500000))) (ELit (LInt 4096))) (ELit (LInt 32))))
(DData Private "DelimiterKind" () ((variant "Paren" (ConPos)) (variant "Bracket" (ConPos)) (variant "ArrayDelimiter" (ConPos)) (variant "Brace" (ConPos)) (variant "Interpolation" (ConPos))) ())
(DImpl true "Eq" ((TyCon "DelimiterKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Paren") (PCon "Paren")) () (EVar "True")) (arm (PTuple (PCon "Bracket") (PCon "Bracket")) () (EVar "True")) (arm (PTuple (PCon "ArrayDelimiter") (PCon "ArrayDelimiter")) () (EVar "True")) (arm (PTuple (PCon "Brace") (PCon "Brace")) () (EVar "True")) (arm (PTuple (PCon "Interpolation") (PCon "Interpolation")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DTypeSig false "openKind" (TyFun (TyCon "Token") (TyApp (TyCon "Option") (TyCon "DelimiterKind"))))
(DFunDef false "openKind" ((PCon "TLParen")) (EApp (EVar "Some") (EVar "Paren")))
(DFunDef false "openKind" ((PCon "TLBracket")) (EApp (EVar "Some") (EVar "Bracket")))
(DFunDef false "openKind" ((PCon "TLBracketTight")) (EApp (EVar "Some") (EVar "Bracket")))
(DFunDef false "openKind" ((PCon "TLArray")) (EApp (EVar "Some") (EVar "ArrayDelimiter")))
(DFunDef false "openKind" ((PCon "TLBrace")) (EApp (EVar "Some") (EVar "Brace")))
(DFunDef false "openKind" ((PCon "TDotLBrace")) (EApp (EVar "Some") (EVar "Brace")))
(DFunDef false "openKind" ((PCon "TInterpOpen" PWild)) (EApp (EVar "Some") (EVar "Interpolation")))
(DFunDef false "openKind" (PWild) (EVar "None"))
(DTypeSig false "closeKind" (TyFun (TyCon "Token") (TyApp (TyCon "Option") (TyCon "DelimiterKind"))))
(DFunDef false "closeKind" ((PCon "TRParen")) (EApp (EVar "Some") (EVar "Paren")))
(DFunDef false "closeKind" ((PCon "TRBracket")) (EApp (EVar "Some") (EVar "Bracket")))
(DFunDef false "closeKind" ((PCon "TRArray")) (EApp (EVar "Some") (EVar "ArrayDelimiter")))
(DFunDef false "closeKind" ((PCon "TRBrace")) (EApp (EVar "Some") (EVar "Brace")))
(DFunDef false "closeKind" ((PCon "TInterpEnd" PWild)) (EApp (EVar "Some") (EVar "Interpolation")))
(DFunDef false "closeKind" (PWild) (EVar "None"))
(DTypeSig false "fences" (TyFun (TyCon "ParseContext") (TyTuple (TyApp (TyCon "Array") (TyCon "Bool")) (TyApp (TyCon "Option") (TyCon "InvalidReason")))))
(DFunDef false "fences" ((PVar "ctx")) (EBlock (DoLet false false (PTuple (PVar "flags") (PVar "reason")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkFence") (EVar "ctx")) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit)) (EVar "False")) (EListLit))) (DoExpr (ETuple (EApp (EVar "arrayFromList") (EApp (EVar "reverse") (EVar "flags"))) (EVar "reason")))))
(DTypeSig false "walkFence" (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DelimiterKind")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyTuple (TyApp (TyCon "List") (TyCon "Bool")) (TyApp (TyCon "Option") (TyCon "InvalidReason"))))))))))
(DFunDef false "walkFence" ((PVar "ctx") (PVar "p") (PVar "depth") (PVar "stack") (PVar "poison") (PVar "acc")) (EIf (EBinOp ">=" (EVar "p") (EApp (EVar "arrayLength") (EApp (EVar "contextTokens") (EVar "ctx")))) (ETuple (EVar "acc") (EIf (EVar "poison") (EApp (EVar "Some") (EVar "MismatchedDelimiter")) (EIf (EApp (EVar "isNonEmptyL") (EVar "stack")) (EApp (EVar "Some") (EVar "UnclosedDelimiter")) (EVar "None")))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "t") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p"))) (DoLet false false (PVar "off") (EApp (EVar "fst") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "p")) (EApp (EVar "contextOffsets") (EVar "ctx"))))) (DoLet false false (PTuple (PVar "_line") (PVar "col")) (EApp (EApp (EVar "offsetToLineColFast") (EApp (EVar "contextLineStarts") (EVar "ctx"))) (EVar "off"))) (DoLet false false (PVar "allowed") (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "col") (ELit (LInt 0))) (EApp (EVar "not") (EApp (EVar "isNoiseTok") (EVar "t")))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EApp (EVar "isEmptyL") (EVar "stack"))) (EApp (EVar "not") (EVar "poison")))) (DoLet false false (PVar "d") (EMatch (EVar "t") (arm (PCon "TIndent") () (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (arm (PCon "TDedent") () (EApp (EApp (EVar "max") (ELit (LInt 0))) (EBinOp "-" (EVar "depth") (ELit (LInt 1))))) (arm PWild () (EVar "depth")))) (DoExpr (EMatch (EApp (EVar "openKind") (EVar "t")) (arm (PCon "Some" (PVar "o")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkFence") (EVar "ctx")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "d")) (EBinOp "::" (EVar "o") (EVar "stack"))) (EVar "poison")) (EBinOp "::" (EVar "allowed") (EVar "acc")))) (arm (PCon "None") () (EMatch (EApp (EVar "closeKind") (EVar "t")) (arm (PCon "Some" (PVar "c")) () (EMatch (EVar "stack") (arm (PList) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkFence") (EVar "ctx")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "d")) (EListLit)) (EVar "poison")) (EBinOp "::" (EVar "allowed") (EVar "acc")))) (arm (PCons (PVar "k") (PVar "rest")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkFence") (EVar "ctx")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "d")) (EVar "rest")) (EBinOp "||" (EVar "poison") (EBinOp "/=" (EVar "k") (EVar "c")))) (EBinOp "::" (EVar "allowed") (EVar "acc")))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkFence") (EVar "ctx")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "d")) (EVar "stack")) (EVar "poison")) (EBinOp "::" (EVar "allowed") (EVar "acc"))))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "noiseEnd" (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "noiseEnd" ((PVar "ctx") (PVar "p")) (EIf (EApp (EVar "isNoiseTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p"))) (EApp (EApp (EVar "noiseEnd") (EVar "ctx")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "p") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "nextFence" (TyFun (TyCon "ParseContext") (TyFun (TyApp (TyCon "Array") (TyCon "Bool")) (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "nextFence" ((PVar "ctx") (PVar "fs") (PVar "start")) (EBlock (DoLet false true (PVar "go") (ELam ((PVar "p")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp ">=" (EVar "p") (EApp (EVar "arrayLength") (EVar "fs"))) (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p")))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "p")) (EVar "fs"))) (EVar "p") (EApp (EVar "go") (EBinOp "+" (EVar "p") (ELit (LInt 1))))))) (DoExpr (EApp (EVar "go") (EVar "start")))))
(DTypeSig false "offAt" (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "offAt" ((PVar "ctx") (PVar "size") (PVar "p")) (EIf (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p"))) (EVar "size") (EIf (EBinOp "<" (EVar "p") (EApp (EVar "arrayLength") (EApp (EVar "contextOffsets") (EVar "ctx")))) (EApp (EVar "fst") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "p")) (EApp (EVar "contextOffsets") (EVar "ctx")))) (EIf (EVar "otherwise") (EVar "size") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "sliceList" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "sliceList" ((PVar "xs") (PVar "s") (PVar "e")) (EApp (EVar "toList") (EApp (EApp (EApp (EVar "sliceClamped") (EVar "s")) (EVar "e")) (EVar "xs"))))
(DData Private "RecoveryContext" () ((variant "RecoveryContext" (ConNamed (field "limits" (TyCon "RecoveryLimits")) (field "source" (TyCon "String")) (field "index" (TyFun (TyCon "Unit") (TyCon "SourceIndex"))) (field "parser" (TyCon "ParseContext")) (field "fences" (TyApp (TyCon "Array") (TyCon "Bool"))) (field "damage" (TyApp (TyCon "Option") (TyCon "InvalidReason"))) (field "size" (TyCon "Int"))))) ())
(DData Private "RecoveryState" () ((variant "RecoveryState" (ConNamed (field "position" (TyCon "Int")) (field "spans" (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int")))) (field "diagnostics" (TyApp (TyCon "List") (TyCon "ParseDiagnostic"))) (field "regions" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "InvalidReason")))) (field "attempts" (TyCon "Int"))))) ())
(DTypeSig false "publish" (TyFun (TyCon "RecoveryContext") (TyFun (TyCon "RecoveryState") (TyFun (TyCon "RecoveryStop") (TyCon "RecoveredSource")))))
(DFunDef false "publish" ((PVar "run") (PVar "state") (PVar "stop")) (EBlock (DoLet false false (PVar "ctx") (EFieldAccess (EVar "run") "parser")) (DoLet false false (PVar "spans") (EApp (EVar "reverse") (EFieldAccess (EVar "state") "spans"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "makeRecoveredSource") (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "d") (PVar "_s") (PVar "_e"))) (EVar "d"))) (EVar "spans"))) (EApp (EApp (EApp (EApp (EVar "positionsFromSpans") (EApp (EVar "contextLineStarts") (EVar "ctx"))) (EApp (EVar "contextTokens") (EVar "ctx"))) (EApp (EVar "contextOffsets") (EVar "ctx"))) (EVar "spans"))) (EApp (EVar "reverse") (EFieldAccess (EVar "state") "diagnostics"))) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "s") (PVar "e") (PVar "reason"))) (EApp (EApp (EVar "makeInvalidRegion") (EApp (EApp (EVar "SourceExtent") (EVar "s")) (EVar "e"))) (EVar "reason")))) (EApp (EVar "reverse") (EFieldAccess (EVar "state") "regions")))) (EApp (EVar "Partial") (EVar "stop"))) (EApp (EApp (EApp (EVar "RecoveryStats") (EApp (EVar "arrayLength") (EApp (EVar "contextTokens") (EVar "ctx")))) (EFieldAccess (EVar "state") "attempts")) (EApp (EVar "length") (EFieldAccess (EVar "state") "diagnostics")))))))
(DTypeSig false "failureDiag" (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "ParseDiagnosticKind") (TyCon "ParseDiagnostic"))))))
(DFunDef false "failureDiag" ((PVar "ctx") (PVar "size") (PVar "p") (PVar "problem")) (EBlock (DoLet false false (PVar "loc") (EIf (EBinOp "||" (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p"))) (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "size") (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "p")) (ELit (LInt 0)))) (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EApp (EApp (EVar "noiseEnd") (EVar "ctx")) (EVar "p")))))) (EBlock (DoLet false false (PTuple (PVar "line") (PVar "col")) (EApp (EApp (EVar "offsetToLineColFast") (EApp (EVar "contextLineStarts") (EVar "ctx"))) (EVar "size"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EVar "line")) (EVar "col")) (EVar "line")) (EVar "col")))) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))))) (DoExpr (EApp (EApp (EVar "makeParseDiagnostic") (EVar "problem")) (EVar "loc")))))
(DTypeSig false "recoverLoop" (TyFun (TyCon "RecoveryContext") (TyFun (TyCon "RecoveryState") (TyCon "RecoveredSource"))))
(DFunDef false "recoverLoop" ((PVar "run") (PVar "state")) (EBlock (DoLet false false (PVar "ctx") (EFieldAccess (EVar "run") "parser")) (DoLet false false (PVar "fs") (EFieldAccess (EVar "run") "fences")) (DoLet false false (PVar "size") (EFieldAccess (EVar "run") "size")) (DoLet false false (PVar "p") (EFieldAccess (EVar "state") "position")) (DoLet false false (PCon "RecoveryLimits" PWild PWild (PVar "maxAttempts") (PVar "maxDiagnostics")) (EFieldAccess (EVar "run") "limits")) (DoExpr (EIf (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p"))) (EApp (EApp (EApp (EVar "publish") (EVar "run")) (EVar "state")) (EVar "ReachedEnd")) (EIf (EBinOp "||" (EBinOp ">=" (EFieldAccess (EVar "state") "attempts") (EVar "maxAttempts")) (EBinOp ">=" (EApp (EVar "length") (EFieldAccess (EVar "state") "diagnostics")) (EVar "maxDiagnostics"))) (EApp (EApp (EApp (EVar "publish") (EVar "run")) (ERecordUpdate (EVar "state") ((fa "regions" (EBinOp "::" (ETuple (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "p")) (EVar "size") (EVar "RecoveryBudget")) (EFieldAccess (EVar "state") "regions")))))) (EVar "ExhaustedBudget")) (EIf (EBinOp "||" (EBinOp ">=" (EVar "p") (EApp (EVar "arrayLength") (EVar "fs"))) (EApp (EVar "not") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "p")) (EVar "fs")))) (EApp (EApp (EApp (EVar "publish") (EVar "run")) (ERecordUpdate (EVar "state") ((fa "regions" (EBinOp "::" (ETuple (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "p")) (EVar "size") (EVar "UntrustedBoundary")) (EFieldAccess (EVar "state") "regions")))))) (EVar "StoppedBoundary")) (EMatch (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p")) (arm (PCon "TLexError" (PVar "kind")) () (EApp (EApp (EApp (EVar "publish") (EVar "run")) (ERecordUpdate (EVar "state") ((fa "diagnostics" (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "failureDiag") (EVar "ctx")) (EVar "size")) (EVar "p")) (EVar "kind")) (EFieldAccess (EVar "state") "diagnostics"))) (fa "regions" (EBinOp "::" (ETuple (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "p")) (EVar "size") (EVar "TerminalLexError")) (EFieldAccess (EVar "state") "regions"))) (fa "attempts" (EBinOp "+" (EFieldAccess (EVar "state") "attempts") (ELit (LInt 1))))))) (EVar "StoppedLexically"))) (arm PWild () (EBlock (DoLet false false (PVar "saved") (EApp (EVar "mark") (EVar "ctx"))) (DoLet false true (PVar "rejectFailure") (ELam ((PVar "f")) (ELam ((PVar "q")) (EApp (EApp (EApp (EVar "reject") (EVar "run")) (EVar "state")) (EApp (EApp (EApp (EApp (EVar "failureDiag") (EVar "ctx")) (EVar "size")) (EVar "q")) (EApp (EVar "failProblem") (EVar "f"))))))) (DoExpr (EMatch (EApp (EApp (EVar "P.parseDeclAt") (EVar "ctx")) (EVar "p")) (arm (PCon "POk" (PVar "d") (PVar "q")) () (EBlock (DoLet false false (PVar "end") (EApp (EApp (EVar "noiseEnd") (EVar "ctx")) (EVar "q"))) (DoLet false false (PVar "boundary") (EBinOp "||" (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "end"))) (EBinOp "&&" (EBinOp "<" (EVar "end") (EApp (EVar "arrayLength") (EVar "fs"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "end")) (EVar "fs"))))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">" (EVar "q") (EVar "p")) (EVar "boundary")) (EBlock (DoLet false false (PVar "ts") (EApp (EApp (EApp (EVar "sliceList") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p")) (EVar "q"))) (DoLet false false (PVar "os") (EApp (EApp (EApp (EVar "sliceList") (EApp (EVar "contextOffsets") (EVar "ctx"))) (EVar "p")) (EVar "q"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "P.prescanErrorPairsWithIndex") (EFieldAccess (EVar "run") "source")) (EBinOp "++" (EVar "ts") (EListLit (EVar "TEof")))) (EBinOp "++" (EVar "os") (EListLit (ETuple (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "q")) (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "q")))))) (EFieldAccess (EVar "run") "index")) (arm (PCon "None") () (EApp (EApp (EVar "recoverLoop") (EVar "run")) (ERecordUpdate (EVar "state") ((fa "position" (EVar "end")) (fa "spans" (EBinOp "::" (ETuple (EVar "d") (EVar "p") (EVar "q")) (EFieldAccess (EVar "state") "spans"))) (fa "attempts" (EBinOp "+" (EFieldAccess (EVar "state") "attempts") (ELit (LInt 1)))))))) (arm (PCon "Some" (PVar "err")) () (EBlock (DoExpr (EApp (EVar "rewind") (EVar "saved"))) (DoExpr (EApp (EApp (EApp (EVar "reject") (EVar "run")) (EVar "state")) (EApp (EVar "parseErrorDiagnostic") (EVar "err"))))))))) (EBlock (DoExpr (EApp (EVar "rewind") (EVar "saved"))) (DoExpr (EApp (EApp (EApp (EVar "reject") (EVar "run")) (EVar "state")) (EApp (EApp (EApp (EApp (EVar "failureDiag") (EVar "ctx")) (EVar "size")) (EVar "q")) (EApp (EVar "GenericParse") (ELit (LString "declaration did not end at a safe boundary"))))))))))) (arm (PCon "PErr" (PVar "f") (PVar "q")) () (EApp (EApp (EVar "rejectFailure") (EVar "f")) (EVar "q"))) (arm (PCon "PFatal" (PVar "f") (PVar "q")) () (EApp (EApp (EVar "rejectFailure") (EVar "f")) (EVar "q"))))))))))))))
(DTypeSig false "reject" (TyFun (TyCon "RecoveryContext") (TyFun (TyCon "RecoveryState") (TyFun (TyCon "ParseDiagnostic") (TyCon "RecoveredSource")))))
(DFunDef false "reject" ((PVar "run") (PVar "state") (PVar "diagnostic")) (EBlock (DoLet false false (PVar "ctx") (EFieldAccess (EVar "run") "parser")) (DoLet false false (PVar "size") (EFieldAccess (EVar "run") "size")) (DoLet false false (PVar "p") (EFieldAccess (EVar "state") "position")) (DoLet false false (PVar "next") (EApp (EApp (EApp (EVar "nextFence") (EVar "ctx")) (EFieldAccess (EVar "run") "fences")) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (DoLet false false (PVar "terminal") (EApp (EApp (EApp (EVar "findLex") (EVar "ctx")) (EVar "p")) (EApp (EApp (EVar "min") (EApp (EVar "arrayLength") (EFieldAccess (EVar "run") "fences"))) (EBinOp "+" (EVar "next") (ELit (LInt 1)))))) (DoExpr (EMatch (EVar "terminal") (arm (PCon "Some" (PVar "terminal")) () (EBlock (DoLet false false (PVar "kind") (EMatch (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "terminal")) (arm (PCon "TLexError" (PVar "k")) () (EVar "k")) (arm PWild () (EApp (EVar "GenericParse") (ELit (LString "unreachable")))))) (DoExpr (EApp (EApp (EApp (EVar "publish") (EVar "run")) (ERecordUpdate (EVar "state") ((fa "diagnostics" (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "failureDiag") (EVar "ctx")) (EVar "size")) (EVar "terminal")) (EVar "kind")) (EFieldAccess (EVar "state") "diagnostics"))) (fa "regions" (EBinOp "::" (ETuple (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "p")) (EVar "size") (EVar "TerminalLexError")) (EFieldAccess (EVar "state") "regions"))) (fa "attempts" (EBinOp "+" (EFieldAccess (EVar "state") "attempts") (ELit (LInt 1))))))) (EVar "StoppedLexically"))))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "ts") (EApp (EApp (EApp (EVar "sliceList") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p")) (EVar "next"))) (DoLet false false (PVar "os") (EApp (EApp (EApp (EVar "sliceList") (EApp (EVar "contextOffsets") (EVar "ctx"))) (EVar "p")) (EVar "next"))) (DoLet false false (PVar "checked") (EMatch (EApp (EApp (EApp (EApp (EVar "P.prescanErrorPairsWithIndex") (EFieldAccess (EVar "run") "source")) (EBinOp "++" (EVar "ts") (EListLit (EVar "TEof")))) (EBinOp "++" (EVar "os") (EListLit (ETuple (EVar "size") (EVar "size"))))) (EFieldAccess (EVar "run") "index")) (arm (PCon "Some" (PVar "err")) () (EApp (EVar "parseErrorDiagnostic") (EVar "err"))) (arm (PCon "None") () (EVar "diagnostic")))) (DoLet false false (PVar "updated") (ERecordUpdate (EVar "state") ((fa "diagnostics" (EBinOp "::" (EVar "checked") (EFieldAccess (EVar "state") "diagnostics"))) (fa "attempts" (EBinOp "+" (EFieldAccess (EVar "state") "attempts") (ELit (LInt 1))))))) (DoExpr (EMatch (ETuple (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "next"))) (EFieldAccess (EVar "run") "damage")) (arm (PTuple (PCon "True") (PCon "Some" (PVar "reason"))) () (EApp (EApp (EApp (EVar "publish") (EVar "run")) (ERecordUpdate (EVar "updated") ((fa "regions" (EBinOp "::" (ETuple (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "p")) (EVar "size") (EVar "reason")) (EFieldAccess (EVar "state") "regions")))))) (EVar "StoppedDelimiter"))) (arm PWild () (EApp (EApp (EVar "recoverLoop") (EVar "run")) (ERecordUpdate (EVar "updated") ((fa "position" (EVar "next")) (fa "regions" (EBinOp "::" (ETuple (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "p")) (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "next")) (EVar "InvalidDeclaration")) (EFieldAccess (EVar "state") "regions")))))))))))))))
(DTypeSig false "findLex" (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "findLex" ((PVar "ctx") (PVar "start") (PVar "end")) (EBlock (DoLet false true (PVar "go") (ELam ((PVar "p")) (EIf (EBinOp ">=" (EVar "p") (EVar "end")) (EVar "None") (EMatch (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p")) (arm (PCon "TLexError" PWild) () (EApp (EVar "Some") (EVar "p"))) (arm PWild () (EApp (EVar "go") (EBinOp "+" (EVar "p") (ELit (LInt 1))))))))) (DoExpr (EApp (EVar "go") (EVar "start")))))
(DTypeSig true "parseRecovering" (TyFun (TyCon "String") (TyCon "RecoveredSource")))
(DFunDef false "parseRecovering" () (EApp (EVar "parseRecoveringWith") (EVar "defaultRecoveryLimits")))
(DTypeSig true "parseRecoveringWith" (TyFun (TyCon "RecoveryLimits") (TyFun (TyCon "String") (TyCon "RecoveredSource"))))
(DFunDef false "parseRecoveringWith" ((PAs "limits" (PCon "RecoveryLimits" (PVar "maxSource") (PVar "maxTokens") (PVar "maxAttempts") (PVar "maxDiagnostics"))) (PVar "src")) (EIf (EBinOp "<" (EApp (EApp (EVar "min") (EApp (EApp (EVar "min") (EVar "maxSource")) (EVar "maxTokens"))) (EApp (EApp (EVar "min") (EVar "maxAttempts")) (EVar "maxDiagnostics"))) (ELit (LInt 0))) (EApp (EApp (EVar "budgetResult") (EVar "src")) (ELit (LInt 0))) (EIf (EBinOp ">" (EApp (EVar "stringLength") (EVar "src")) (EVar "maxSource")) (EApp (EApp (EVar "budgetResult") (EVar "src")) (ELit (LInt 0))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "cell") (EApp (EVar "Ref") (EVar "None"))) (DoLet false true (PVar "index") (ELam ((PLit LUnit)) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Some" (PVar "value")) () (EVar "value")) (arm (PCon "None") () (EBlock (DoLet false false (PVar "value") (EApp (EVar "indexSource") (EVar "src"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EVar "Some") (EVar "value")))) (DoExpr (EVar "value"))))))) (DoExpr (EApp (EApp (EApp (EVar "recoverTokens") (EVar "limits")) (EVar "src")) (EVar "index")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "defaultRecoveryAdmission" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "RecoveredSource"))))
(DFunDef false "defaultRecoveryAdmission" ((PVar "src")) (EMatch (EVar "defaultRecoveryLimits") (arm (PCon "RecoveryLimits" (PVar "maxSource") PWild PWild PWild) () (EIf (EBinOp ">" (EApp (EVar "stringLength") (EVar "src")) (EVar "maxSource")) (EApp (EVar "Some") (EApp (EApp (EVar "budgetResult") (EVar "src")) (ELit (LInt 0)))) (EVar "None")))))
(DTypeSig true "parseRecoveringWithIndex" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "String") (TyCon "RecoveredSource"))))
(DFunDef false "parseRecoveringWithIndex" ((PVar "index") (PVar "src")) (EMatch (EApp (EVar "defaultRecoveryAdmission") (EVar "src")) (arm (PCon "Some" (PVar "result")) () (EVar "result")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "recoverTokens") (EVar "defaultRecoveryLimits")) (EVar "src")) (ELam ((PLit LUnit)) (EVar "index"))))))
(DTypeSig true "budgetResult" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "RecoveredSource"))))
(DFunDef false "budgetResult" ((PVar "src") (PVar "count")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "makeRecoveredSource") (EListLit)) (EApp (EApp (EApp (EApp (EVar "Positions") (EListLit)) (EListLit)) (ELit (LInt 0))) (EListLit))) (EListLit)) (EListLit (EApp (EApp (EVar "makeInvalidRegion") (EApp (EApp (EVar "SourceExtent") (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "src")))) (EVar "RecoveryBudget")))) (EApp (EVar "Partial") (EVar "ExhaustedBudget"))) (EApp (EApp (EApp (EVar "RecoveryStats") (EVar "count")) (ELit (LInt 0))) (ELit (LInt 0)))))
(DTypeSig false "recoverTokens" (TyFun (TyCon "RecoveryLimits") (TyFun (TyCon "String") (TyFun (TyFun (TyCon "Unit") (TyCon "SourceIndex")) (TyCon "RecoveredSource")))))
(DFunDef false "recoverTokens" ((PAs "limits" (PCon "RecoveryLimits" PWild (PVar "maxTokens") PWild PWild)) (PVar "src") (PVar "index")) (EBlock (DoLet false false (PTuple (PVar "ts") (PVar "os")) (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src"))) (DoLet false false (PVar "count") (EApp (EVar "length") (EVar "ts"))) (DoExpr (EIf (EBinOp ">" (EVar "count") (EVar "maxTokens")) (EApp (EApp (EVar "budgetResult") (EVar "src")) (EVar "count")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recoverPrepared") (EVar "limits")) (EVar "src")) (EVar "index")) (EVar "ts")) (EVar "os")) (EApp (EApp (EApp (EApp (EVar "P.parseSourcePairsWithIndex") (EVar "src")) (EVar "ts")) (EVar "os")) (EVar "index")))))))
(DTypeSig true "recoverSourcePairsWithIndex" (TyFun (TyCon "RecoveryLimits") (TyFun (TyCon "SourceIndex") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "ParseDiagnostic")) (TyCon "ParsedSource")) (TyCon "RecoveredSource"))))))))
(DFunDef false "recoverSourcePairsWithIndex" ((PVar "limits") (PVar "index") (PVar "src") (PVar "ts") (PVar "os") (PVar "strict")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recoverPrepared") (EVar "limits")) (EVar "src")) (ELam ((PLit LUnit)) (EVar "index"))) (EVar "ts")) (EVar "os")) (EVar "strict")))
(DTypeSig false "recoverPrepared" (TyFun (TyCon "RecoveryLimits") (TyFun (TyCon "String") (TyFun (TyFun (TyCon "Unit") (TyCon "SourceIndex")) (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "ParseDiagnostic")) (TyCon "ParsedSource")) (TyCon "RecoveredSource"))))))))
(DFunDef false "recoverPrepared" ((PVar "limits") (PVar "src") (PVar "index") (PVar "ts") (PVar "os") (PVar "strict")) (EBlock (DoLet false false (PVar "count") (EApp (EVar "length") (EVar "ts"))) (DoExpr (EMatch (EVar "strict") (arm (PCon "Ok" (PVar "result")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "makeRecoveredSource") (EApp (EVar "parsedDecls") (EVar "result"))) (EApp (EVar "parsedPositions") (EVar "result"))) (EListLit)) (EListLit)) (EVar "Complete")) (EApp (EApp (EApp (EVar "RecoveryStats") (EVar "count")) (ELit (LInt 0))) (ELit (LInt 0))))) (arm (PCon "Err" (PVar "firstDiagnostic")) () (EBlock (DoLet false false (PVar "ctx") (EApp (EApp (EApp (EVar "newParseContext") (EVar "src")) (EApp (EVar "arrayFromList") (EVar "ts"))) (EApp (EVar "arrayFromList") (EVar "os")))) (DoLet false false (PTuple (PVar "fs") (PVar "damage")) (EApp (EVar "fences") (EVar "ctx"))) (DoLet false false (PVar "run") (ERecordCreate "RecoveryContext" ((fa "limits" (EVar "limits")) (fa "source" (EVar "src")) (fa "index" (EVar "index")) (fa "parser" (EVar "ctx")) (fa "fences" (EVar "fs")) (fa "damage" (EVar "damage")) (fa "size" (EApp (EVar "stringLength") (EVar "src")))))) (DoLet false false (PVar "state") (ERecordCreate "RecoveryState" ((fa "position" (EApp (EApp (EVar "noiseEnd") (EVar "ctx")) (ELit (LInt 0)))) (fa "spans" (EListLit)) (fa "diagnostics" (EListLit)) (fa "regions" (EListLit)) (fa "attempts" (ELit (LInt 0)))))) (DoExpr (EApp (EApp (EApp (EVar "ensureDiagnostic") (EVar "limits")) (EVar "firstDiagnostic")) (EApp (EApp (EVar "recoverLoop") (EVar "run")) (EVar "state"))))))))))
(DTypeSig false "ensureDiagnostic" (TyFun (TyCon "RecoveryLimits") (TyFun (TyCon "ParseDiagnostic") (TyFun (TyCon "RecoveredSource") (TyCon "RecoveredSource")))))
(DFunDef false "ensureDiagnostic" ((PCon "RecoveryLimits" PWild PWild PWild (PVar "maxDiagnostics")) (PVar "diagnostic") (PVar "result")) (EIf (EBinOp "||" (EBinOp "<=" (EVar "maxDiagnostics") (ELit (LInt 0))) (EApp (EVar "not") (EApp (EVar "isEmpty") (EApp (EVar "recoveredDiagnostics") (EVar "result"))))) (EVar "result") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "makeRecoveredSource") (EApp (EVar "recoveredDecls") (EVar "result"))) (EApp (EVar "recoveredPositions") (EVar "result"))) (EListLit (EVar "diagnostic"))) (EApp (EVar "invalidRegions") (EVar "result"))) (EApp (EVar "recoveredCompleteness") (EVar "result"))) (EMatch (EApp (EVar "recoveredStats") (EVar "result")) (arm (PCon "RecoveryStats" (PVar "tokens") (PVar "attempts") PWild) () (EApp (EApp (EApp (EVar "RecoveryStats") (EVar "tokens")) (EVar "attempts")) (ELit (LInt 1))))))))
# MARK
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseGroup ("array") ((mem "sliceClamped" false))))
(DUse false (UseAlias ("frontend" "parser") "P"))
(DUse false (UseGroup ("frontend" "lexer") ((mem "tokenizeWithOffsetPairs" false))))
(DUse false (UseGroup ("frontend" "lex_token") ((mem "Token" true) (mem "isNoiseTok" false) (mem "isEofTok" false))))
(DUse false (UseGroup ("frontend" "parse_engine") ((mem "ParseContext" false) (mem "PR" true) (mem "newParseContext" false) (mem "contextTokens" false) (mem "contextOffsets" false) (mem "contextLineStarts" false) (mem "peekTok" false) (mem "mark" false) (mem "rewind" false) (mem "failProblem" false) (mem "locOfSpan" false))))
(DUse false (UseGroup ("frontend" "parse_result") ((mem "ParsedSource" false) (mem "parsedDecls" false) (mem "parsedPositions" false) (mem "parseErrorDiagnostic" false))))
(DUse false (UseGroup ("frontend" "parse_positions") ((mem "Positions" true) (mem "positionsFromSpans" false))))
(DUse false (UseGroup ("frontend" "parse_diagnostic") ((mem "ParseDiagnostic" false) (mem "ParseDiagnosticKind" true) (mem "makeParseDiagnostic" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "Loc" true))))
(DUse false (UseGroup ("support" "source_index") ((mem "SourceIndex" false) (mem "indexSource" false) (mem "offsetToLineColFast" false))))
(DUse false (UseGroup ("support" "util") ((mem "isEmptyL" false) (mem "isNonEmptyL" false))))
(DUse false (UseGroup ("frontend" "recovery_result") ((mem "RecoveredSource" false) (mem "SourceExtent" true) (mem "InvalidReason" true) (mem "RecoveryStop" true) (mem "RecoveryCompleteness" true) (mem "RecoveryStats" true) (mem "makeInvalidRegion" false) (mem "makeRecoveredSource" false) (mem "recoveredDecls" false) (mem "recoveredPositions" false) (mem "recoveredDiagnostics" false) (mem "invalidRegions" false) (mem "recoveredCompleteness" false) (mem "recoveredStats" false))))
(DData Public "RecoveryLimits" () ((variant "RecoveryLimits" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))) ())
(DImpl true "Eq" ((TyCon "RecoveryLimits")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "RecoveryLimits" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3")) (PCon "RecoveryLimits" (PVar "__b0") (PVar "__b1") (PVar "__b2") (PVar "__b3"))) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EMethodRef "eq") (EVar "__a3")) (EVar "__b3"))))))))
(DTypeSig true "defaultRecoveryLimits" (TyCon "RecoveryLimits"))
(DFunDef false "defaultRecoveryLimits" () (EApp (EApp (EApp (EApp (EVar "RecoveryLimits") (ELit (LInt 8388608))) (ELit (LInt 500000))) (ELit (LInt 4096))) (ELit (LInt 32))))
(DData Private "DelimiterKind" () ((variant "Paren" (ConPos)) (variant "Bracket" (ConPos)) (variant "ArrayDelimiter" (ConPos)) (variant "Brace" (ConPos)) (variant "Interpolation" (ConPos))) ())
(DImpl true "Eq" ((TyCon "DelimiterKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Paren") (PCon "Paren")) () (EVar "True")) (arm (PTuple (PCon "Bracket") (PCon "Bracket")) () (EVar "True")) (arm (PTuple (PCon "ArrayDelimiter") (PCon "ArrayDelimiter")) () (EVar "True")) (arm (PTuple (PCon "Brace") (PCon "Brace")) () (EVar "True")) (arm (PTuple (PCon "Interpolation") (PCon "Interpolation")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DTypeSig false "openKind" (TyFun (TyCon "Token") (TyApp (TyCon "Option") (TyCon "DelimiterKind"))))
(DFunDef false "openKind" ((PCon "TLParen")) (EApp (EVar "Some") (EVar "Paren")))
(DFunDef false "openKind" ((PCon "TLBracket")) (EApp (EVar "Some") (EVar "Bracket")))
(DFunDef false "openKind" ((PCon "TLBracketTight")) (EApp (EVar "Some") (EVar "Bracket")))
(DFunDef false "openKind" ((PCon "TLArray")) (EApp (EVar "Some") (EVar "ArrayDelimiter")))
(DFunDef false "openKind" ((PCon "TLBrace")) (EApp (EVar "Some") (EVar "Brace")))
(DFunDef false "openKind" ((PCon "TDotLBrace")) (EApp (EVar "Some") (EVar "Brace")))
(DFunDef false "openKind" ((PCon "TInterpOpen" PWild)) (EApp (EVar "Some") (EVar "Interpolation")))
(DFunDef false "openKind" (PWild) (EVar "None"))
(DTypeSig false "closeKind" (TyFun (TyCon "Token") (TyApp (TyCon "Option") (TyCon "DelimiterKind"))))
(DFunDef false "closeKind" ((PCon "TRParen")) (EApp (EVar "Some") (EVar "Paren")))
(DFunDef false "closeKind" ((PCon "TRBracket")) (EApp (EVar "Some") (EVar "Bracket")))
(DFunDef false "closeKind" ((PCon "TRArray")) (EApp (EVar "Some") (EVar "ArrayDelimiter")))
(DFunDef false "closeKind" ((PCon "TRBrace")) (EApp (EVar "Some") (EVar "Brace")))
(DFunDef false "closeKind" ((PCon "TInterpEnd" PWild)) (EApp (EVar "Some") (EVar "Interpolation")))
(DFunDef false "closeKind" (PWild) (EVar "None"))
(DTypeSig false "fences" (TyFun (TyCon "ParseContext") (TyTuple (TyApp (TyCon "Array") (TyCon "Bool")) (TyApp (TyCon "Option") (TyCon "InvalidReason")))))
(DFunDef false "fences" ((PVar "ctx")) (EBlock (DoLet false false (PTuple (PVar "flags") (PVar "reason")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkFence") (EVar "ctx")) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit)) (EVar "False")) (EListLit))) (DoExpr (ETuple (EApp (EVar "arrayFromList") (EApp (EVar "reverse") (EVar "flags"))) (EVar "reason")))))
(DTypeSig false "walkFence" (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DelimiterKind")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyTuple (TyApp (TyCon "List") (TyCon "Bool")) (TyApp (TyCon "Option") (TyCon "InvalidReason"))))))))))
(DFunDef false "walkFence" ((PVar "ctx") (PVar "p") (PVar "depth") (PVar "stack") (PVar "poison") (PVar "acc")) (EIf (EBinOp ">=" (EVar "p") (EApp (EVar "arrayLength") (EApp (EVar "contextTokens") (EVar "ctx")))) (ETuple (EVar "acc") (EIf (EVar "poison") (EApp (EVar "Some") (EVar "MismatchedDelimiter")) (EIf (EApp (EVar "isNonEmptyL") (EVar "stack")) (EApp (EVar "Some") (EVar "UnclosedDelimiter")) (EVar "None")))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "t") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p"))) (DoLet false false (PVar "off") (EApp (EVar "fst") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "p")) (EApp (EVar "contextOffsets") (EVar "ctx"))))) (DoLet false false (PTuple (PVar "_line") (PVar "col")) (EApp (EApp (EVar "offsetToLineColFast") (EApp (EVar "contextLineStarts") (EVar "ctx"))) (EVar "off"))) (DoLet false false (PVar "allowed") (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "col") (ELit (LInt 0))) (EApp (EVar "not") (EApp (EVar "isNoiseTok") (EVar "t")))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EApp (EVar "isEmptyL") (EVar "stack"))) (EApp (EVar "not") (EVar "poison")))) (DoLet false false (PVar "d") (EMatch (EVar "t") (arm (PCon "TIndent") () (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (arm (PCon "TDedent") () (EApp (EApp (EMethodRef "max") (ELit (LInt 0))) (EBinOp "-" (EVar "depth") (ELit (LInt 1))))) (arm PWild () (EVar "depth")))) (DoExpr (EMatch (EApp (EVar "openKind") (EVar "t")) (arm (PCon "Some" (PVar "o")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkFence") (EVar "ctx")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "d")) (EBinOp "::" (EVar "o") (EVar "stack"))) (EVar "poison")) (EBinOp "::" (EVar "allowed") (EVar "acc")))) (arm (PCon "None") () (EMatch (EApp (EVar "closeKind") (EVar "t")) (arm (PCon "Some" (PVar "c")) () (EMatch (EVar "stack") (arm (PList) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkFence") (EVar "ctx")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "d")) (EListLit)) (EVar "poison")) (EBinOp "::" (EVar "allowed") (EVar "acc")))) (arm (PCons (PVar "k") (PVar "rest")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkFence") (EVar "ctx")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "d")) (EVar "rest")) (EBinOp "||" (EVar "poison") (EBinOp "/=" (EVar "k") (EVar "c")))) (EBinOp "::" (EVar "allowed") (EVar "acc")))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkFence") (EVar "ctx")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "d")) (EVar "stack")) (EVar "poison")) (EBinOp "::" (EVar "allowed") (EVar "acc"))))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "noiseEnd" (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "noiseEnd" ((PVar "ctx") (PVar "p")) (EIf (EApp (EVar "isNoiseTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p"))) (EApp (EApp (EVar "noiseEnd") (EVar "ctx")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "p") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "nextFence" (TyFun (TyCon "ParseContext") (TyFun (TyApp (TyCon "Array") (TyCon "Bool")) (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "nextFence" ((PVar "ctx") (PVar "fs") (PVar "start")) (EBlock (DoLet false true (PVar "go") (ELam ((PVar "p")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp ">=" (EVar "p") (EApp (EVar "arrayLength") (EVar "fs"))) (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p")))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "p")) (EVar "fs"))) (EVar "p") (EApp (EVar "go") (EBinOp "+" (EVar "p") (ELit (LInt 1))))))) (DoExpr (EApp (EVar "go") (EVar "start")))))
(DTypeSig false "offAt" (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "offAt" ((PVar "ctx") (PVar "size") (PVar "p")) (EIf (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p"))) (EVar "size") (EIf (EBinOp "<" (EVar "p") (EApp (EVar "arrayLength") (EApp (EVar "contextOffsets") (EVar "ctx")))) (EApp (EVar "fst") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "p")) (EApp (EVar "contextOffsets") (EVar "ctx")))) (EIf (EVar "otherwise") (EVar "size") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "sliceList" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "sliceList" ((PVar "xs") (PVar "s") (PVar "e")) (EApp (EMethodRef "toList") (EApp (EApp (EApp (EVar "sliceClamped") (EVar "s")) (EVar "e")) (EVar "xs"))))
(DData Private "RecoveryContext" () ((variant "RecoveryContext" (ConNamed (field "limits" (TyCon "RecoveryLimits")) (field "source" (TyCon "String")) (field "index" (TyFun (TyCon "Unit") (TyCon "SourceIndex"))) (field "parser" (TyCon "ParseContext")) (field "fences" (TyApp (TyCon "Array") (TyCon "Bool"))) (field "damage" (TyApp (TyCon "Option") (TyCon "InvalidReason"))) (field "size" (TyCon "Int"))))) ())
(DData Private "RecoveryState" () ((variant "RecoveryState" (ConNamed (field "position" (TyCon "Int")) (field "spans" (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int")))) (field "diagnostics" (TyApp (TyCon "List") (TyCon "ParseDiagnostic"))) (field "regions" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "InvalidReason")))) (field "attempts" (TyCon "Int"))))) ())
(DTypeSig false "publish" (TyFun (TyCon "RecoveryContext") (TyFun (TyCon "RecoveryState") (TyFun (TyCon "RecoveryStop") (TyCon "RecoveredSource")))))
(DFunDef false "publish" ((PVar "run") (PVar "state") (PVar "stop")) (EBlock (DoLet false false (PVar "ctx") (EFieldAccess (EVar "run") "parser")) (DoLet false false (PVar "spans") (EApp (EVar "reverse") (EFieldAccess (EVar "state") "spans"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "makeRecoveredSource") (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "d") (PVar "_s") (PVar "_e"))) (EVar "d"))) (EVar "spans"))) (EApp (EApp (EApp (EApp (EVar "positionsFromSpans") (EApp (EVar "contextLineStarts") (EVar "ctx"))) (EApp (EVar "contextTokens") (EVar "ctx"))) (EApp (EVar "contextOffsets") (EVar "ctx"))) (EVar "spans"))) (EApp (EVar "reverse") (EFieldAccess (EVar "state") "diagnostics"))) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "s") (PVar "e") (PVar "reason"))) (EApp (EApp (EVar "makeInvalidRegion") (EApp (EApp (EVar "SourceExtent") (EVar "s")) (EVar "e"))) (EVar "reason")))) (EApp (EVar "reverse") (EFieldAccess (EVar "state") "regions")))) (EApp (EVar "Partial") (EVar "stop"))) (EApp (EApp (EApp (EVar "RecoveryStats") (EApp (EVar "arrayLength") (EApp (EVar "contextTokens") (EVar "ctx")))) (EFieldAccess (EVar "state") "attempts")) (EApp (EMethodRef "length") (EFieldAccess (EVar "state") "diagnostics")))))))
(DTypeSig false "failureDiag" (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "ParseDiagnosticKind") (TyCon "ParseDiagnostic"))))))
(DFunDef false "failureDiag" ((PVar "ctx") (PVar "size") (PVar "p") (PVar "problem")) (EBlock (DoLet false false (PVar "loc") (EIf (EBinOp "||" (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p"))) (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "size") (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "p")) (ELit (LInt 0)))) (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EApp (EApp (EVar "noiseEnd") (EVar "ctx")) (EVar "p")))))) (EBlock (DoLet false false (PTuple (PVar "line") (PVar "col")) (EApp (EApp (EVar "offsetToLineColFast") (EApp (EVar "contextLineStarts") (EVar "ctx"))) (EVar "size"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EVar "line")) (EVar "col")) (EVar "line")) (EVar "col")))) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))))) (DoExpr (EApp (EApp (EVar "makeParseDiagnostic") (EVar "problem")) (EVar "loc")))))
(DTypeSig false "recoverLoop" (TyFun (TyCon "RecoveryContext") (TyFun (TyCon "RecoveryState") (TyCon "RecoveredSource"))))
(DFunDef false "recoverLoop" ((PVar "run") (PVar "state")) (EBlock (DoLet false false (PVar "ctx") (EFieldAccess (EVar "run") "parser")) (DoLet false false (PVar "fs") (EFieldAccess (EVar "run") "fences")) (DoLet false false (PVar "size") (EFieldAccess (EVar "run") "size")) (DoLet false false (PVar "p") (EFieldAccess (EVar "state") "position")) (DoLet false false (PCon "RecoveryLimits" PWild PWild (PVar "maxAttempts") (PVar "maxDiagnostics")) (EFieldAccess (EVar "run") "limits")) (DoExpr (EIf (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p"))) (EApp (EApp (EApp (EVar "publish") (EVar "run")) (EVar "state")) (EVar "ReachedEnd")) (EIf (EBinOp "||" (EBinOp ">=" (EFieldAccess (EVar "state") "attempts") (EVar "maxAttempts")) (EBinOp ">=" (EApp (EMethodRef "length") (EFieldAccess (EVar "state") "diagnostics")) (EVar "maxDiagnostics"))) (EApp (EApp (EApp (EVar "publish") (EVar "run")) (ERecordUpdate (EVar "state") ((fa "regions" (EBinOp "::" (ETuple (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "p")) (EVar "size") (EVar "RecoveryBudget")) (EFieldAccess (EVar "state") "regions")))))) (EVar "ExhaustedBudget")) (EIf (EBinOp "||" (EBinOp ">=" (EVar "p") (EApp (EVar "arrayLength") (EVar "fs"))) (EApp (EVar "not") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "p")) (EVar "fs")))) (EApp (EApp (EApp (EVar "publish") (EVar "run")) (ERecordUpdate (EVar "state") ((fa "regions" (EBinOp "::" (ETuple (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "p")) (EVar "size") (EVar "UntrustedBoundary")) (EFieldAccess (EVar "state") "regions")))))) (EVar "StoppedBoundary")) (EMatch (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p")) (arm (PCon "TLexError" (PVar "kind")) () (EApp (EApp (EApp (EVar "publish") (EVar "run")) (ERecordUpdate (EVar "state") ((fa "diagnostics" (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "failureDiag") (EVar "ctx")) (EVar "size")) (EVar "p")) (EVar "kind")) (EFieldAccess (EVar "state") "diagnostics"))) (fa "regions" (EBinOp "::" (ETuple (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "p")) (EVar "size") (EVar "TerminalLexError")) (EFieldAccess (EVar "state") "regions"))) (fa "attempts" (EBinOp "+" (EFieldAccess (EVar "state") "attempts") (ELit (LInt 1))))))) (EVar "StoppedLexically"))) (arm PWild () (EBlock (DoLet false false (PVar "saved") (EApp (EVar "mark") (EVar "ctx"))) (DoLet false true (PVar "rejectFailure") (ELam ((PVar "f")) (ELam ((PVar "q")) (EApp (EApp (EApp (EVar "reject") (EVar "run")) (EVar "state")) (EApp (EApp (EApp (EApp (EVar "failureDiag") (EVar "ctx")) (EVar "size")) (EVar "q")) (EApp (EVar "failProblem") (EVar "f"))))))) (DoExpr (EMatch (EApp (EApp (EVar "P.parseDeclAt") (EVar "ctx")) (EVar "p")) (arm (PCon "POk" (PVar "d") (PVar "q")) () (EBlock (DoLet false false (PVar "end") (EApp (EApp (EVar "noiseEnd") (EVar "ctx")) (EVar "q"))) (DoLet false false (PVar "boundary") (EBinOp "||" (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "end"))) (EBinOp "&&" (EBinOp "<" (EVar "end") (EApp (EVar "arrayLength") (EVar "fs"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "end")) (EVar "fs"))))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">" (EVar "q") (EVar "p")) (EVar "boundary")) (EBlock (DoLet false false (PVar "ts") (EApp (EApp (EApp (EVar "sliceList") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p")) (EVar "q"))) (DoLet false false (PVar "os") (EApp (EApp (EApp (EVar "sliceList") (EApp (EVar "contextOffsets") (EVar "ctx"))) (EVar "p")) (EVar "q"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "P.prescanErrorPairsWithIndex") (EFieldAccess (EVar "run") "source")) (EBinOp "++" (EVar "ts") (EListLit (EVar "TEof")))) (EBinOp "++" (EVar "os") (EListLit (ETuple (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "q")) (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "q")))))) (EFieldAccess (EVar "run") "index")) (arm (PCon "None") () (EApp (EApp (EVar "recoverLoop") (EVar "run")) (ERecordUpdate (EVar "state") ((fa "position" (EVar "end")) (fa "spans" (EBinOp "::" (ETuple (EVar "d") (EVar "p") (EVar "q")) (EFieldAccess (EVar "state") "spans"))) (fa "attempts" (EBinOp "+" (EFieldAccess (EVar "state") "attempts") (ELit (LInt 1)))))))) (arm (PCon "Some" (PVar "err")) () (EBlock (DoExpr (EApp (EVar "rewind") (EVar "saved"))) (DoExpr (EApp (EApp (EApp (EVar "reject") (EVar "run")) (EVar "state")) (EApp (EVar "parseErrorDiagnostic") (EVar "err"))))))))) (EBlock (DoExpr (EApp (EVar "rewind") (EVar "saved"))) (DoExpr (EApp (EApp (EApp (EVar "reject") (EVar "run")) (EVar "state")) (EApp (EApp (EApp (EApp (EVar "failureDiag") (EVar "ctx")) (EVar "size")) (EVar "q")) (EApp (EVar "GenericParse") (ELit (LString "declaration did not end at a safe boundary"))))))))))) (arm (PCon "PErr" (PVar "f") (PVar "q")) () (EApp (EApp (EVar "rejectFailure") (EVar "f")) (EVar "q"))) (arm (PCon "PFatal" (PVar "f") (PVar "q")) () (EApp (EApp (EVar "rejectFailure") (EVar "f")) (EVar "q"))))))))))))))
(DTypeSig false "reject" (TyFun (TyCon "RecoveryContext") (TyFun (TyCon "RecoveryState") (TyFun (TyCon "ParseDiagnostic") (TyCon "RecoveredSource")))))
(DFunDef false "reject" ((PVar "run") (PVar "state") (PVar "diagnostic")) (EBlock (DoLet false false (PVar "ctx") (EFieldAccess (EVar "run") "parser")) (DoLet false false (PVar "size") (EFieldAccess (EVar "run") "size")) (DoLet false false (PVar "p") (EFieldAccess (EVar "state") "position")) (DoLet false false (PVar "next") (EApp (EApp (EApp (EVar "nextFence") (EVar "ctx")) (EFieldAccess (EVar "run") "fences")) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (DoLet false false (PVar "terminal") (EApp (EApp (EApp (EVar "findLex") (EVar "ctx")) (EVar "p")) (EApp (EApp (EMethodRef "min") (EApp (EVar "arrayLength") (EFieldAccess (EVar "run") "fences"))) (EBinOp "+" (EVar "next") (ELit (LInt 1)))))) (DoExpr (EMatch (EVar "terminal") (arm (PCon "Some" (PVar "terminal")) () (EBlock (DoLet false false (PVar "kind") (EMatch (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "terminal")) (arm (PCon "TLexError" (PVar "k")) () (EVar "k")) (arm PWild () (EApp (EVar "GenericParse") (ELit (LString "unreachable")))))) (DoExpr (EApp (EApp (EApp (EVar "publish") (EVar "run")) (ERecordUpdate (EVar "state") ((fa "diagnostics" (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "failureDiag") (EVar "ctx")) (EVar "size")) (EVar "terminal")) (EVar "kind")) (EFieldAccess (EVar "state") "diagnostics"))) (fa "regions" (EBinOp "::" (ETuple (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "p")) (EVar "size") (EVar "TerminalLexError")) (EFieldAccess (EVar "state") "regions"))) (fa "attempts" (EBinOp "+" (EFieldAccess (EVar "state") "attempts") (ELit (LInt 1))))))) (EVar "StoppedLexically"))))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "ts") (EApp (EApp (EApp (EVar "sliceList") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p")) (EVar "next"))) (DoLet false false (PVar "os") (EApp (EApp (EApp (EVar "sliceList") (EApp (EVar "contextOffsets") (EVar "ctx"))) (EVar "p")) (EVar "next"))) (DoLet false false (PVar "checked") (EMatch (EApp (EApp (EApp (EApp (EVar "P.prescanErrorPairsWithIndex") (EFieldAccess (EVar "run") "source")) (EBinOp "++" (EVar "ts") (EListLit (EVar "TEof")))) (EBinOp "++" (EVar "os") (EListLit (ETuple (EVar "size") (EVar "size"))))) (EFieldAccess (EVar "run") "index")) (arm (PCon "Some" (PVar "err")) () (EApp (EVar "parseErrorDiagnostic") (EVar "err"))) (arm (PCon "None") () (EVar "diagnostic")))) (DoLet false false (PVar "updated") (ERecordUpdate (EVar "state") ((fa "diagnostics" (EBinOp "::" (EVar "checked") (EFieldAccess (EVar "state") "diagnostics"))) (fa "attempts" (EBinOp "+" (EFieldAccess (EVar "state") "attempts") (ELit (LInt 1))))))) (DoExpr (EMatch (ETuple (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "next"))) (EFieldAccess (EVar "run") "damage")) (arm (PTuple (PCon "True") (PCon "Some" (PVar "reason"))) () (EApp (EApp (EApp (EVar "publish") (EVar "run")) (ERecordUpdate (EVar "updated") ((fa "regions" (EBinOp "::" (ETuple (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "p")) (EVar "size") (EVar "reason")) (EFieldAccess (EVar "state") "regions")))))) (EVar "StoppedDelimiter"))) (arm PWild () (EApp (EApp (EVar "recoverLoop") (EVar "run")) (ERecordUpdate (EVar "updated") ((fa "position" (EVar "next")) (fa "regions" (EBinOp "::" (ETuple (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "p")) (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "next")) (EVar "InvalidDeclaration")) (EFieldAccess (EVar "state") "regions")))))))))))))))
(DTypeSig false "findLex" (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "findLex" ((PVar "ctx") (PVar "start") (PVar "end")) (EBlock (DoLet false true (PVar "go") (ELam ((PVar "p")) (EIf (EBinOp ">=" (EVar "p") (EVar "end")) (EVar "None") (EMatch (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p")) (arm (PCon "TLexError" PWild) () (EApp (EVar "Some") (EVar "p"))) (arm PWild () (EApp (EVar "go") (EBinOp "+" (EVar "p") (ELit (LInt 1))))))))) (DoExpr (EApp (EVar "go") (EVar "start")))))
(DTypeSig true "parseRecovering" (TyFun (TyCon "String") (TyCon "RecoveredSource")))
(DFunDef false "parseRecovering" () (EApp (EVar "parseRecoveringWith") (EVar "defaultRecoveryLimits")))
(DTypeSig true "parseRecoveringWith" (TyFun (TyCon "RecoveryLimits") (TyFun (TyCon "String") (TyCon "RecoveredSource"))))
(DFunDef false "parseRecoveringWith" ((PAs "limits" (PCon "RecoveryLimits" (PVar "maxSource") (PVar "maxTokens") (PVar "maxAttempts") (PVar "maxDiagnostics"))) (PVar "src")) (EIf (EBinOp "<" (EApp (EApp (EMethodRef "min") (EApp (EApp (EMethodRef "min") (EVar "maxSource")) (EVar "maxTokens"))) (EApp (EApp (EMethodRef "min") (EVar "maxAttempts")) (EVar "maxDiagnostics"))) (ELit (LInt 0))) (EApp (EApp (EVar "budgetResult") (EVar "src")) (ELit (LInt 0))) (EIf (EBinOp ">" (EApp (EVar "stringLength") (EVar "src")) (EVar "maxSource")) (EApp (EApp (EVar "budgetResult") (EVar "src")) (ELit (LInt 0))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "cell") (EApp (EVar "Ref") (EVar "None"))) (DoLet false true (PVar "index") (ELam ((PLit LUnit)) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Some" (PVar "value")) () (EVar "value")) (arm (PCon "None") () (EBlock (DoLet false false (PVar "value") (EApp (EVar "indexSource") (EVar "src"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EVar "Some") (EVar "value")))) (DoExpr (EVar "value"))))))) (DoExpr (EApp (EApp (EApp (EVar "recoverTokens") (EVar "limits")) (EVar "src")) (EMethodRef "index")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "defaultRecoveryAdmission" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "RecoveredSource"))))
(DFunDef false "defaultRecoveryAdmission" ((PVar "src")) (EMatch (EVar "defaultRecoveryLimits") (arm (PCon "RecoveryLimits" (PVar "maxSource") PWild PWild PWild) () (EIf (EBinOp ">" (EApp (EVar "stringLength") (EVar "src")) (EVar "maxSource")) (EApp (EVar "Some") (EApp (EApp (EVar "budgetResult") (EVar "src")) (ELit (LInt 0)))) (EVar "None")))))
(DTypeSig true "parseRecoveringWithIndex" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "String") (TyCon "RecoveredSource"))))
(DFunDef false "parseRecoveringWithIndex" ((PVar "index") (PVar "src")) (EMatch (EApp (EVar "defaultRecoveryAdmission") (EVar "src")) (arm (PCon "Some" (PVar "result")) () (EVar "result")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "recoverTokens") (EVar "defaultRecoveryLimits")) (EVar "src")) (ELam ((PLit LUnit)) (EMethodRef "index"))))))
(DTypeSig true "budgetResult" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "RecoveredSource"))))
(DFunDef false "budgetResult" ((PVar "src") (PVar "count")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "makeRecoveredSource") (EListLit)) (EApp (EApp (EApp (EApp (EVar "Positions") (EListLit)) (EListLit)) (ELit (LInt 0))) (EListLit))) (EListLit)) (EListLit (EApp (EApp (EVar "makeInvalidRegion") (EApp (EApp (EVar "SourceExtent") (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "src")))) (EVar "RecoveryBudget")))) (EApp (EVar "Partial") (EVar "ExhaustedBudget"))) (EApp (EApp (EApp (EVar "RecoveryStats") (EDictApp "count")) (ELit (LInt 0))) (ELit (LInt 0)))))
(DTypeSig false "recoverTokens" (TyFun (TyCon "RecoveryLimits") (TyFun (TyCon "String") (TyFun (TyFun (TyCon "Unit") (TyCon "SourceIndex")) (TyCon "RecoveredSource")))))
(DFunDef false "recoverTokens" ((PAs "limits" (PCon "RecoveryLimits" PWild (PVar "maxTokens") PWild PWild)) (PVar "src") (PVar "index")) (EBlock (DoLet false false (PTuple (PVar "ts") (PVar "os")) (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src"))) (DoLet false false (PVar "count") (EApp (EMethodRef "length") (EVar "ts"))) (DoExpr (EIf (EBinOp ">" (EDictApp "count") (EVar "maxTokens")) (EApp (EApp (EVar "budgetResult") (EVar "src")) (EDictApp "count")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recoverPrepared") (EVar "limits")) (EVar "src")) (EMethodRef "index")) (EVar "ts")) (EVar "os")) (EApp (EApp (EApp (EApp (EVar "P.parseSourcePairsWithIndex") (EVar "src")) (EVar "ts")) (EVar "os")) (EMethodRef "index")))))))
(DTypeSig true "recoverSourcePairsWithIndex" (TyFun (TyCon "RecoveryLimits") (TyFun (TyCon "SourceIndex") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "ParseDiagnostic")) (TyCon "ParsedSource")) (TyCon "RecoveredSource"))))))))
(DFunDef false "recoverSourcePairsWithIndex" ((PVar "limits") (PVar "index") (PVar "src") (PVar "ts") (PVar "os") (PVar "strict")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recoverPrepared") (EVar "limits")) (EVar "src")) (ELam ((PLit LUnit)) (EMethodRef "index"))) (EVar "ts")) (EVar "os")) (EVar "strict")))
(DTypeSig false "recoverPrepared" (TyFun (TyCon "RecoveryLimits") (TyFun (TyCon "String") (TyFun (TyFun (TyCon "Unit") (TyCon "SourceIndex")) (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "ParseDiagnostic")) (TyCon "ParsedSource")) (TyCon "RecoveredSource"))))))))
(DFunDef false "recoverPrepared" ((PVar "limits") (PVar "src") (PVar "index") (PVar "ts") (PVar "os") (PVar "strict")) (EBlock (DoLet false false (PVar "count") (EApp (EMethodRef "length") (EVar "ts"))) (DoExpr (EMatch (EVar "strict") (arm (PCon "Ok" (PVar "result")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "makeRecoveredSource") (EApp (EVar "parsedDecls") (EVar "result"))) (EApp (EVar "parsedPositions") (EVar "result"))) (EListLit)) (EListLit)) (EVar "Complete")) (EApp (EApp (EApp (EVar "RecoveryStats") (EDictApp "count")) (ELit (LInt 0))) (ELit (LInt 0))))) (arm (PCon "Err" (PVar "firstDiagnostic")) () (EBlock (DoLet false false (PVar "ctx") (EApp (EApp (EApp (EVar "newParseContext") (EVar "src")) (EApp (EVar "arrayFromList") (EVar "ts"))) (EApp (EVar "arrayFromList") (EVar "os")))) (DoLet false false (PTuple (PVar "fs") (PVar "damage")) (EApp (EVar "fences") (EVar "ctx"))) (DoLet false false (PVar "run") (ERecordCreate "RecoveryContext" ((fa "limits" (EVar "limits")) (fa "source" (EVar "src")) (fa "index" (EMethodRef "index")) (fa "parser" (EVar "ctx")) (fa "fences" (EVar "fs")) (fa "damage" (EVar "damage")) (fa "size" (EApp (EVar "stringLength") (EVar "src")))))) (DoLet false false (PVar "state") (ERecordCreate "RecoveryState" ((fa "position" (EApp (EApp (EVar "noiseEnd") (EVar "ctx")) (ELit (LInt 0)))) (fa "spans" (EListLit)) (fa "diagnostics" (EListLit)) (fa "regions" (EListLit)) (fa "attempts" (ELit (LInt 0)))))) (DoExpr (EApp (EApp (EApp (EVar "ensureDiagnostic") (EVar "limits")) (EVar "firstDiagnostic")) (EApp (EApp (EVar "recoverLoop") (EVar "run")) (EVar "state"))))))))))
(DTypeSig false "ensureDiagnostic" (TyFun (TyCon "RecoveryLimits") (TyFun (TyCon "ParseDiagnostic") (TyFun (TyCon "RecoveredSource") (TyCon "RecoveredSource")))))
(DFunDef false "ensureDiagnostic" ((PCon "RecoveryLimits" PWild PWild PWild (PVar "maxDiagnostics")) (PVar "diagnostic") (PVar "result")) (EIf (EBinOp "||" (EBinOp "<=" (EVar "maxDiagnostics") (ELit (LInt 0))) (EApp (EVar "not") (EApp (EMethodRef "isEmpty") (EApp (EVar "recoveredDiagnostics") (EVar "result"))))) (EVar "result") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "makeRecoveredSource") (EApp (EVar "recoveredDecls") (EVar "result"))) (EApp (EVar "recoveredPositions") (EVar "result"))) (EListLit (EVar "diagnostic"))) (EApp (EVar "invalidRegions") (EVar "result"))) (EApp (EVar "recoveredCompleteness") (EVar "result"))) (EMatch (EApp (EVar "recoveredStats") (EVar "result")) (arm (PCon "RecoveryStats" (PVar "tokens") (PVar "attempts") PWild) () (EApp (EApp (EApp (EVar "RecoveryStats") (EVar "tokens")) (EVar "attempts")) (ELit (LInt 1))))))))
