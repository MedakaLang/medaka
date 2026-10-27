# META
source_lines=425
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
import support.source_index.{offsetToLineColFast}

import frontend.recovery_result.{
  RecoveredSource, SourceExtent(..), InvalidReason(..), RecoveryStop(..),
  RecoveryCompleteness(..), RecoveryStats(..), makeInvalidRegion,
  makeRecoveredSource, recoveredDecls, recoveredPositions, recoveredDiagnostics,
  invalidRegions, recoveredCompleteness, recoveredStats
}

public export data RecoveryLimits = RecoveryLimits Int Int Int Int

export
defaultRecoveryLimits : RecoveryLimits
defaultRecoveryLimits = RecoveryLimits 8388608 500000 4096 32

openKind : Token -> Int
openKind TLParen = 1
openKind TLBracket = 2
openKind TLBracketTight = 2
openKind TLArray = 3
openKind TLBrace = 4
openKind TDotLBrace = 4
openKind (TInterpOpen _) = 5
openKind _ = 0

closeKind : Token -> Int
closeKind TRParen = 1
closeKind TRBracket = 2
closeKind TRArray = 3
closeKind TRBrace = 4
closeKind (TInterpEnd _) = 5
closeKind _ = 0

isRoot : List Int -> Bool
isRoot [] = True
isRoot _ = False

fences : ParseContext -> (Array Bool, Option InvalidReason)
fences ctx =
  let (flags, reason) = walkFence ctx 0 0 [] False []
  (arrayFromList (reverse flags), reason)

walkFence : ParseContext ->
  Int ->
  Int ->
  List Int ->
  Bool ->
  List Bool ->
  (List Bool, Option InvalidReason)
walkFence ctx p depth stack poison acc
  | p >= arrayLength (contextTokens ctx) = (
    acc,
    if poison then
      Some MismatchedDelimiter
    else if not (isRoot stack) then
      Some UnclosedDelimiter
    else
      None,
  )
  | otherwise =
    let t = peekTok (contextTokens ctx) p
    let off = fst (arrayGetUnsafe p (contextOffsets ctx))
    let (_line, col) = offsetToLineColFast (contextLineStarts ctx) off
    let allowed =
      col == 0 && not (isNoiseTok t) && depth == 0 && isRoot stack && not poison
    let d = match t
      TIndent => depth + 1
      TDedent => max 0 (depth - 1)
      _ => depth
    let o = openKind t
    let c = closeKind t
    if o > 0 then
      walkFence ctx (p + 1) d (o :: stack) poison (allowed :: acc)
    else if c > 0 then match stack
      [] => walkFence ctx (p + 1) d [] poison (allowed :: acc)
      k :: rest =>
        walkFence ctx (p + 1) d rest (poison || k /= c) (allowed :: acc)
    else
      walkFence ctx (p + 1) d stack poison (allowed :: acc)

noiseEnd : ParseContext -> Int -> Int
noiseEnd ctx p
  | isNoiseTok (peekTok (contextTokens ctx) p) = noiseEnd ctx (p + 1)
  | otherwise = p

nextFence : ParseContext -> Array Bool -> Int -> Int
nextFence ctx fs p
  | p >= arrayLength fs = p
  | isEofTok (peekTok (contextTokens ctx) p) = p
  | arrayGetUnsafe p fs = p
  | otherwise = nextFence ctx fs (p + 1)

offAt : ParseContext -> Int -> Int -> Int
offAt ctx size p
  | isEofTok (peekTok (contextTokens ctx) p) = size
  | p < arrayLength (contextOffsets ctx) =
    fst (arrayGetUnsafe p (contextOffsets ctx))
  | otherwise = size

sliceList : Array a -> Int -> Int -> List a
sliceList xs s e = toList (sliceClamped s e xs)

publish : ParseContext ->
  List (Decl, Int, Int) ->
  List ParseDiagnostic ->
  List (Int, Int, InvalidReason) ->
  RecoveryStop ->
  Int ->
  RecoveredSource
publish ctx revSpans ds rs stop attempts =
  let spans = reverse revSpans
  makeRecoveredSource
    (map ((d, _s, _e) => d) spans)
    (positionsFromSpans
      (contextLineStarts ctx)
      (contextTokens ctx)
      (contextOffsets ctx)
      spans)
    (reverse ds)
    (map
      ((s, e, reason) => makeInvalidRegion (SourceExtent s e) reason)
      (reverse rs))
    (Partial stop)
    (RecoveryStats (arrayLength (contextTokens ctx)) attempts (length ds))

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

recoverLoop : RecoveryLimits ->
  String ->
  ParseContext ->
  Array Bool ->
  Option InvalidReason ->
  Int ->
  Int ->
  List (Decl, Int, Int) ->
  List ParseDiagnostic ->
  List (Int, Int, InvalidReason) ->
  Int ->
  RecoveredSource
recoverLoop (limits@(RecoveryLimits _ _ maxAttempts maxDiagnostics)) src ctx fs damage size p spans ds rs attempts
  | isEofTok (peekTok (contextTokens ctx) p) =
    publish ctx spans ds rs ReachedEnd attempts
  | attempts >= maxAttempts || length ds >= maxDiagnostics =
    publish
      ctx
      spans
      ds
      ((offAt ctx size p, size, RecoveryBudget) :: rs)
      ExhaustedBudget
      attempts
  | p >= arrayLength fs || not (arrayGetUnsafe p fs) =
    publish
      ctx
      spans
      ds
      ((offAt ctx size p, size, UntrustedBoundary) :: rs)
      StoppedBoundary
      attempts
  | otherwise = match peekTok (contextTokens ctx) p
    TLexError kind =>
      publish
        ctx
        spans
        (failureDiag ctx size p kind :: ds)
        ((offAt ctx size p, size, TerminalLexError) :: rs)
        StoppedLexically
        (attempts + 1)
    _ =>
      let saved = mark ctx
      match P.parseDeclAt ctx p
        POk d q =>
          let end = noiseEnd ctx q
          let boundary =
            isEofTok (peekTok (contextTokens ctx) end)
              || end < arrayLength fs && arrayGetUnsafe end fs
          if q > p && boundary then
            let ts = sliceList (contextTokens ctx) p q
            let os = sliceList (contextOffsets ctx) p q
            match (P.prescanErrorPairs
              src
              (ts ++ [TEof])
              (os ++ [(offAt ctx size q, offAt ctx size q)]))
              None =>
                recoverLoop
                  limits
                  src
                  ctx
                  fs
                  damage
                  size
                  end
                  ((d, p, q) :: spans)
                  ds
                  rs
                  (attempts + 1)
              Some err =>
                rewind saved
                reject
                  limits
                  src
                  ctx
                  fs
                  damage
                  size
                  p
                  spans
                  ds
                  rs
                  attempts
                  (parseErrorDiagnostic err)
          else
            rewind saved
            reject
              limits
              src
              ctx
              fs
              damage
              size
              p
              spans
              ds
              rs
              attempts
              (failureDiag
                ctx
                size
                q
                (GenericParse "declaration did not end at a safe boundary"))
        PErr f q =>
          reject
            limits
            src
            ctx
            fs
            damage
            size
            p
            spans
            ds
            rs
            attempts
            (failureDiag ctx size q (failProblem f))
        PFatal f q =>
          reject
            limits
            src
            ctx
            fs
            damage
            size
            p
            spans
            ds
            rs
            attempts
            (failureDiag ctx size q (failProblem f))

reject : RecoveryLimits ->
  String ->
  ParseContext ->
  Array Bool ->
  Option InvalidReason ->
  Int ->
  Int ->
  List (Decl, Int, Int) ->
  List ParseDiagnostic ->
  List (Int, Int, InvalidReason) ->
  Int ->
  ParseDiagnostic ->
  RecoveredSource
reject limits src ctx fs damage size p spans ds rs attempts diagnostic =
  let next = nextFence ctx fs (p + 1)
  let terminal = findLex ctx p (min (arrayLength fs) (next + 1))
  if terminal >= 0 then
    let kind = match peekTok (contextTokens ctx) terminal
      TLexError k => k
      _ => GenericParse "unreachable"
    publish
      ctx
      spans
      (failureDiag ctx size terminal kind :: ds)
      ((offAt ctx size p, size, TerminalLexError) :: rs)
      StoppedLexically
      (attempts + 1)
  else
    let ts = sliceList (contextTokens ctx) p next
    let os = sliceList (contextOffsets ctx) p next
    let checked =
      match P.prescanErrorPairs src (ts ++ [TEof]) (os ++ [(size, size)])
        Some err => parseErrorDiagnostic err
        None => diagnostic
    if isEofTok (peekTok (contextTokens ctx) next) && isSome damage then
      publish
        ctx
        spans
        (checked :: ds)
        ((offAt ctx size p, size, optionOr UnclosedDelimiter damage) :: rs)
        StoppedDelimiter
        (attempts + 1)
    else
      recoverLoop
        limits
        src
        ctx
        fs
        damage
        size
        next
        spans
        (checked :: ds)
        ((offAt ctx size p, offAt ctx size next, InvalidDeclaration) :: rs)
        (attempts + 1)

findLex : ParseContext -> Int -> Int -> Int
findLex ctx p end
  | p >= end = -1
  | otherwise = match peekTok (contextTokens ctx) p
    TLexError _ => p
    _ => findLex ctx (p + 1) end

export
parseRecovering : String -> RecoveredSource
parseRecovering = parseRecoveringWith defaultRecoveryLimits

export
parseRecoveringWith : RecoveryLimits -> String -> RecoveredSource
parseRecoveringWith (limits@(RecoveryLimits maxSource maxTokens maxAttempts maxDiagnostics)) src
  | min (min maxSource maxTokens) (min maxAttempts maxDiagnostics) < 0 =
    budgetResult src 0
  | stringLength src > maxSource = budgetResult src 0
  | otherwise = recoverTokens limits src

budgetResult : String -> Int -> RecoveredSource
budgetResult src count =
  makeRecoveredSource
    []
    (Positions [] [] 0 [])
    []
    [makeInvalidRegion (SourceExtent 0 (stringLength src)) RecoveryBudget]
    (Partial ExhaustedBudget)
    (RecoveryStats count 0 0)

recoverTokens : RecoveryLimits -> String -> RecoveredSource
recoverTokens (limits@(RecoveryLimits _ maxTokens _ _)) src =
  let (ts, os) = tokenizeWithOffsetPairs src
  let count = length ts
  if count > maxTokens then
    budgetResult src count
  else match P.parseSourcePairs src ts os
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
      ensureDiagnostic
        limits
        firstDiagnostic
        (recoverLoop
          limits
          src
          ctx
          fs
          damage
          (stringLength src)
          (noiseEnd ctx 0)
          []
          []
          []
          0)

ensureDiagnostic : RecoveryLimits ->
  ParseDiagnostic ->
  RecoveredSource ->
  RecoveredSource
ensureDiagnostic (RecoveryLimits _ _ _ maxDiagnostics) diagnostic result =
  if maxDiagnostics <= 0 || length (recoveredDiagnostics result) > 0 then
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
(DUse false (UseGroup ("support" "source_index") ((mem "offsetToLineColFast" false))))
(DUse false (UseGroup ("frontend" "recovery_result") ((mem "RecoveredSource" false) (mem "SourceExtent" true) (mem "InvalidReason" true) (mem "RecoveryStop" true) (mem "RecoveryCompleteness" true) (mem "RecoveryStats" true) (mem "makeInvalidRegion" false) (mem "makeRecoveredSource" false) (mem "recoveredDecls" false) (mem "recoveredPositions" false) (mem "recoveredDiagnostics" false) (mem "invalidRegions" false) (mem "recoveredCompleteness" false) (mem "recoveredStats" false))))
(DData Public "RecoveryLimits" () ((variant "RecoveryLimits" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))) ())
(DTypeSig true "defaultRecoveryLimits" (TyCon "RecoveryLimits"))
(DFunDef false "defaultRecoveryLimits" () (EApp (EApp (EApp (EApp (EVar "RecoveryLimits") (ELit (LInt 8388608))) (ELit (LInt 500000))) (ELit (LInt 4096))) (ELit (LInt 32))))
(DTypeSig false "openKind" (TyFun (TyCon "Token") (TyCon "Int")))
(DFunDef false "openKind" ((PCon "TLParen")) (ELit (LInt 1)))
(DFunDef false "openKind" ((PCon "TLBracket")) (ELit (LInt 2)))
(DFunDef false "openKind" ((PCon "TLBracketTight")) (ELit (LInt 2)))
(DFunDef false "openKind" ((PCon "TLArray")) (ELit (LInt 3)))
(DFunDef false "openKind" ((PCon "TLBrace")) (ELit (LInt 4)))
(DFunDef false "openKind" ((PCon "TDotLBrace")) (ELit (LInt 4)))
(DFunDef false "openKind" ((PCon "TInterpOpen" PWild)) (ELit (LInt 5)))
(DFunDef false "openKind" (PWild) (ELit (LInt 0)))
(DTypeSig false "closeKind" (TyFun (TyCon "Token") (TyCon "Int")))
(DFunDef false "closeKind" ((PCon "TRParen")) (ELit (LInt 1)))
(DFunDef false "closeKind" ((PCon "TRBracket")) (ELit (LInt 2)))
(DFunDef false "closeKind" ((PCon "TRArray")) (ELit (LInt 3)))
(DFunDef false "closeKind" ((PCon "TRBrace")) (ELit (LInt 4)))
(DFunDef false "closeKind" ((PCon "TInterpEnd" PWild)) (ELit (LInt 5)))
(DFunDef false "closeKind" (PWild) (ELit (LInt 0)))
(DTypeSig false "isRoot" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool")))
(DFunDef false "isRoot" ((PList)) (EVar "True"))
(DFunDef false "isRoot" (PWild) (EVar "False"))
(DTypeSig false "fences" (TyFun (TyCon "ParseContext") (TyTuple (TyApp (TyCon "Array") (TyCon "Bool")) (TyApp (TyCon "Option") (TyCon "InvalidReason")))))
(DFunDef false "fences" ((PVar "ctx")) (EBlock (DoLet false false (PTuple (PVar "flags") (PVar "reason")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkFence") (EVar "ctx")) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit)) (EVar "False")) (EListLit))) (DoExpr (ETuple (EApp (EVar "arrayFromList") (EApp (EVar "reverse") (EVar "flags"))) (EVar "reason")))))
(DTypeSig false "walkFence" (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyTuple (TyApp (TyCon "List") (TyCon "Bool")) (TyApp (TyCon "Option") (TyCon "InvalidReason"))))))))))
(DFunDef false "walkFence" ((PVar "ctx") (PVar "p") (PVar "depth") (PVar "stack") (PVar "poison") (PVar "acc")) (EIf (EBinOp ">=" (EVar "p") (EApp (EVar "arrayLength") (EApp (EVar "contextTokens") (EVar "ctx")))) (ETuple (EVar "acc") (EIf (EVar "poison") (EApp (EVar "Some") (EVar "MismatchedDelimiter")) (EIf (EApp (EVar "not") (EApp (EVar "isRoot") (EVar "stack"))) (EApp (EVar "Some") (EVar "UnclosedDelimiter")) (EVar "None")))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "t") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p"))) (DoLet false false (PVar "off") (EApp (EVar "fst") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "p")) (EApp (EVar "contextOffsets") (EVar "ctx"))))) (DoLet false false (PTuple (PVar "_line") (PVar "col")) (EApp (EApp (EVar "offsetToLineColFast") (EApp (EVar "contextLineStarts") (EVar "ctx"))) (EVar "off"))) (DoLet false false (PVar "allowed") (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "col") (ELit (LInt 0))) (EApp (EVar "not") (EApp (EVar "isNoiseTok") (EVar "t")))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EApp (EVar "isRoot") (EVar "stack"))) (EApp (EVar "not") (EVar "poison")))) (DoLet false false (PVar "d") (EMatch (EVar "t") (arm (PCon "TIndent") () (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (arm (PCon "TDedent") () (EApp (EApp (EVar "max") (ELit (LInt 0))) (EBinOp "-" (EVar "depth") (ELit (LInt 1))))) (arm PWild () (EVar "depth")))) (DoLet false false (PVar "o") (EApp (EVar "openKind") (EVar "t"))) (DoLet false false (PVar "c") (EApp (EVar "closeKind") (EVar "t"))) (DoExpr (EIf (EBinOp ">" (EVar "o") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkFence") (EVar "ctx")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "d")) (EBinOp "::" (EVar "o") (EVar "stack"))) (EVar "poison")) (EBinOp "::" (EVar "allowed") (EVar "acc"))) (EIf (EBinOp ">" (EVar "c") (ELit (LInt 0))) (EMatch (EVar "stack") (arm (PList) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkFence") (EVar "ctx")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "d")) (EListLit)) (EVar "poison")) (EBinOp "::" (EVar "allowed") (EVar "acc")))) (arm (PCons (PVar "k") (PVar "rest")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkFence") (EVar "ctx")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "d")) (EVar "rest")) (EBinOp "||" (EVar "poison") (EBinOp "/=" (EVar "k") (EVar "c")))) (EBinOp "::" (EVar "allowed") (EVar "acc"))))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkFence") (EVar "ctx")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "d")) (EVar "stack")) (EVar "poison")) (EBinOp "::" (EVar "allowed") (EVar "acc"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "noiseEnd" (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "noiseEnd" ((PVar "ctx") (PVar "p")) (EIf (EApp (EVar "isNoiseTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p"))) (EApp (EApp (EVar "noiseEnd") (EVar "ctx")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "p") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "nextFence" (TyFun (TyCon "ParseContext") (TyFun (TyApp (TyCon "Array") (TyCon "Bool")) (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "nextFence" ((PVar "ctx") (PVar "fs") (PVar "p")) (EIf (EBinOp ">=" (EVar "p") (EApp (EVar "arrayLength") (EVar "fs"))) (EVar "p") (EIf (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p"))) (EVar "p") (EIf (EApp (EApp (EVar "arrayGetUnsafe") (EVar "p")) (EVar "fs")) (EVar "p") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "nextFence") (EVar "ctx")) (EVar "fs")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "offAt" (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "offAt" ((PVar "ctx") (PVar "size") (PVar "p")) (EIf (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p"))) (EVar "size") (EIf (EBinOp "<" (EVar "p") (EApp (EVar "arrayLength") (EApp (EVar "contextOffsets") (EVar "ctx")))) (EApp (EVar "fst") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "p")) (EApp (EVar "contextOffsets") (EVar "ctx")))) (EIf (EVar "otherwise") (EVar "size") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "sliceList" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "sliceList" ((PVar "xs") (PVar "s") (PVar "e")) (EApp (EVar "toList") (EApp (EApp (EApp (EVar "sliceClamped") (EVar "s")) (EVar "e")) (EVar "xs"))))
(DTypeSig false "publish" (TyFun (TyCon "ParseContext") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "ParseDiagnostic")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "InvalidReason"))) (TyFun (TyCon "RecoveryStop") (TyFun (TyCon "Int") (TyCon "RecoveredSource"))))))))
(DFunDef false "publish" ((PVar "ctx") (PVar "revSpans") (PVar "ds") (PVar "rs") (PVar "stop") (PVar "attempts")) (EBlock (DoLet false false (PVar "spans") (EApp (EVar "reverse") (EVar "revSpans"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "makeRecoveredSource") (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "d") (PVar "_s") (PVar "_e"))) (EVar "d"))) (EVar "spans"))) (EApp (EApp (EApp (EApp (EVar "positionsFromSpans") (EApp (EVar "contextLineStarts") (EVar "ctx"))) (EApp (EVar "contextTokens") (EVar "ctx"))) (EApp (EVar "contextOffsets") (EVar "ctx"))) (EVar "spans"))) (EApp (EVar "reverse") (EVar "ds"))) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "s") (PVar "e") (PVar "reason"))) (EApp (EApp (EVar "makeInvalidRegion") (EApp (EApp (EVar "SourceExtent") (EVar "s")) (EVar "e"))) (EVar "reason")))) (EApp (EVar "reverse") (EVar "rs")))) (EApp (EVar "Partial") (EVar "stop"))) (EApp (EApp (EApp (EVar "RecoveryStats") (EApp (EVar "arrayLength") (EApp (EVar "contextTokens") (EVar "ctx")))) (EVar "attempts")) (EApp (EVar "length") (EVar "ds")))))))
(DTypeSig false "failureDiag" (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "ParseDiagnosticKind") (TyCon "ParseDiagnostic"))))))
(DFunDef false "failureDiag" ((PVar "ctx") (PVar "size") (PVar "p") (PVar "problem")) (EBlock (DoLet false false (PVar "loc") (EIf (EBinOp "||" (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p"))) (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "size") (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "p")) (ELit (LInt 0)))) (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EApp (EApp (EVar "noiseEnd") (EVar "ctx")) (EVar "p")))))) (EBlock (DoLet false false (PTuple (PVar "line") (PVar "col")) (EApp (EApp (EVar "offsetToLineColFast") (EApp (EVar "contextLineStarts") (EVar "ctx"))) (EVar "size"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EVar "line")) (EVar "col")) (EVar "line")) (EVar "col")))) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))))) (DoExpr (EApp (EApp (EVar "makeParseDiagnostic") (EVar "problem")) (EVar "loc")))))
(DTypeSig false "recoverLoop" (TyFun (TyCon "RecoveryLimits") (TyFun (TyCon "String") (TyFun (TyCon "ParseContext") (TyFun (TyApp (TyCon "Array") (TyCon "Bool")) (TyFun (TyApp (TyCon "Option") (TyCon "InvalidReason")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "ParseDiagnostic")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "InvalidReason"))) (TyFun (TyCon "Int") (TyCon "RecoveredSource")))))))))))))
(DFunDef false "recoverLoop" ((PAs "limits" (PCon "RecoveryLimits" PWild PWild (PVar "maxAttempts") (PVar "maxDiagnostics"))) (PVar "src") (PVar "ctx") (PVar "fs") (PVar "damage") (PVar "size") (PVar "p") (PVar "spans") (PVar "ds") (PVar "rs") (PVar "attempts")) (EIf (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "publish") (EVar "ctx")) (EVar "spans")) (EVar "ds")) (EVar "rs")) (EVar "ReachedEnd")) (EVar "attempts")) (EIf (EBinOp "||" (EBinOp ">=" (EVar "attempts") (EVar "maxAttempts")) (EBinOp ">=" (EApp (EVar "length") (EVar "ds")) (EVar "maxDiagnostics"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "publish") (EVar "ctx")) (EVar "spans")) (EVar "ds")) (EBinOp "::" (ETuple (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "p")) (EVar "size") (EVar "RecoveryBudget")) (EVar "rs"))) (EVar "ExhaustedBudget")) (EVar "attempts")) (EIf (EBinOp "||" (EBinOp ">=" (EVar "p") (EApp (EVar "arrayLength") (EVar "fs"))) (EApp (EVar "not") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "p")) (EVar "fs")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "publish") (EVar "ctx")) (EVar "spans")) (EVar "ds")) (EBinOp "::" (ETuple (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "p")) (EVar "size") (EVar "UntrustedBoundary")) (EVar "rs"))) (EVar "StoppedBoundary")) (EVar "attempts")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p")) (arm (PCon "TLexError" (PVar "kind")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "publish") (EVar "ctx")) (EVar "spans")) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "failureDiag") (EVar "ctx")) (EVar "size")) (EVar "p")) (EVar "kind")) (EVar "ds"))) (EBinOp "::" (ETuple (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "p")) (EVar "size") (EVar "TerminalLexError")) (EVar "rs"))) (EVar "StoppedLexically")) (EBinOp "+" (EVar "attempts") (ELit (LInt 1))))) (arm PWild () (EBlock (DoLet false false (PVar "saved") (EApp (EVar "mark") (EVar "ctx"))) (DoExpr (EMatch (EApp (EApp (EVar "P.parseDeclAt") (EVar "ctx")) (EVar "p")) (arm (PCon "POk" (PVar "d") (PVar "q")) () (EBlock (DoLet false false (PVar "end") (EApp (EApp (EVar "noiseEnd") (EVar "ctx")) (EVar "q"))) (DoLet false false (PVar "boundary") (EBinOp "||" (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "end"))) (EBinOp "&&" (EBinOp "<" (EVar "end") (EApp (EVar "arrayLength") (EVar "fs"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "end")) (EVar "fs"))))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">" (EVar "q") (EVar "p")) (EVar "boundary")) (EBlock (DoLet false false (PVar "ts") (EApp (EApp (EApp (EVar "sliceList") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p")) (EVar "q"))) (DoLet false false (PVar "os") (EApp (EApp (EApp (EVar "sliceList") (EApp (EVar "contextOffsets") (EVar "ctx"))) (EVar "p")) (EVar "q"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "P.prescanErrorPairs") (EVar "src")) (EBinOp "++" (EVar "ts") (EListLit (EVar "TEof")))) (EBinOp "++" (EVar "os") (EListLit (ETuple (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "q")) (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "q")))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recoverLoop") (EVar "limits")) (EVar "src")) (EVar "ctx")) (EVar "fs")) (EVar "damage")) (EVar "size")) (EVar "end")) (EBinOp "::" (ETuple (EVar "d") (EVar "p") (EVar "q")) (EVar "spans"))) (EVar "ds")) (EVar "rs")) (EBinOp "+" (EVar "attempts") (ELit (LInt 1))))) (arm (PCon "Some" (PVar "err")) () (EBlock (DoExpr (EApp (EVar "rewind") (EVar "saved"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reject") (EVar "limits")) (EVar "src")) (EVar "ctx")) (EVar "fs")) (EVar "damage")) (EVar "size")) (EVar "p")) (EVar "spans")) (EVar "ds")) (EVar "rs")) (EVar "attempts")) (EApp (EVar "parseErrorDiagnostic") (EVar "err"))))))))) (EBlock (DoExpr (EApp (EVar "rewind") (EVar "saved"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reject") (EVar "limits")) (EVar "src")) (EVar "ctx")) (EVar "fs")) (EVar "damage")) (EVar "size")) (EVar "p")) (EVar "spans")) (EVar "ds")) (EVar "rs")) (EVar "attempts")) (EApp (EApp (EApp (EApp (EVar "failureDiag") (EVar "ctx")) (EVar "size")) (EVar "q")) (EApp (EVar "GenericParse") (ELit (LString "declaration did not end at a safe boundary"))))))))))) (arm (PCon "PErr" (PVar "f") (PVar "q")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reject") (EVar "limits")) (EVar "src")) (EVar "ctx")) (EVar "fs")) (EVar "damage")) (EVar "size")) (EVar "p")) (EVar "spans")) (EVar "ds")) (EVar "rs")) (EVar "attempts")) (EApp (EApp (EApp (EApp (EVar "failureDiag") (EVar "ctx")) (EVar "size")) (EVar "q")) (EApp (EVar "failProblem") (EVar "f"))))) (arm (PCon "PFatal" (PVar "f") (PVar "q")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reject") (EVar "limits")) (EVar "src")) (EVar "ctx")) (EVar "fs")) (EVar "damage")) (EVar "size")) (EVar "p")) (EVar "spans")) (EVar "ds")) (EVar "rs")) (EVar "attempts")) (EApp (EApp (EApp (EApp (EVar "failureDiag") (EVar "ctx")) (EVar "size")) (EVar "q")) (EApp (EVar "failProblem") (EVar "f")))))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "reject" (TyFun (TyCon "RecoveryLimits") (TyFun (TyCon "String") (TyFun (TyCon "ParseContext") (TyFun (TyApp (TyCon "Array") (TyCon "Bool")) (TyFun (TyApp (TyCon "Option") (TyCon "InvalidReason")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "ParseDiagnostic")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "InvalidReason"))) (TyFun (TyCon "Int") (TyFun (TyCon "ParseDiagnostic") (TyCon "RecoveredSource"))))))))))))))
(DFunDef false "reject" ((PVar "limits") (PVar "src") (PVar "ctx") (PVar "fs") (PVar "damage") (PVar "size") (PVar "p") (PVar "spans") (PVar "ds") (PVar "rs") (PVar "attempts") (PVar "diagnostic")) (EBlock (DoLet false false (PVar "next") (EApp (EApp (EApp (EVar "nextFence") (EVar "ctx")) (EVar "fs")) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (DoLet false false (PVar "terminal") (EApp (EApp (EApp (EVar "findLex") (EVar "ctx")) (EVar "p")) (EApp (EApp (EVar "min") (EApp (EVar "arrayLength") (EVar "fs"))) (EBinOp "+" (EVar "next") (ELit (LInt 1)))))) (DoExpr (EIf (EBinOp ">=" (EVar "terminal") (ELit (LInt 0))) (EBlock (DoLet false false (PVar "kind") (EMatch (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "terminal")) (arm (PCon "TLexError" (PVar "k")) () (EVar "k")) (arm PWild () (EApp (EVar "GenericParse") (ELit (LString "unreachable")))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "publish") (EVar "ctx")) (EVar "spans")) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "failureDiag") (EVar "ctx")) (EVar "size")) (EVar "terminal")) (EVar "kind")) (EVar "ds"))) (EBinOp "::" (ETuple (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "p")) (EVar "size") (EVar "TerminalLexError")) (EVar "rs"))) (EVar "StoppedLexically")) (EBinOp "+" (EVar "attempts") (ELit (LInt 1)))))) (EBlock (DoLet false false (PVar "ts") (EApp (EApp (EApp (EVar "sliceList") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p")) (EVar "next"))) (DoLet false false (PVar "os") (EApp (EApp (EApp (EVar "sliceList") (EApp (EVar "contextOffsets") (EVar "ctx"))) (EVar "p")) (EVar "next"))) (DoLet false false (PVar "checked") (EMatch (EApp (EApp (EApp (EVar "P.prescanErrorPairs") (EVar "src")) (EBinOp "++" (EVar "ts") (EListLit (EVar "TEof")))) (EBinOp "++" (EVar "os") (EListLit (ETuple (EVar "size") (EVar "size"))))) (arm (PCon "Some" (PVar "err")) () (EApp (EVar "parseErrorDiagnostic") (EVar "err"))) (arm (PCon "None") () (EVar "diagnostic")))) (DoExpr (EIf (EBinOp "&&" (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "next"))) (EApp (EVar "isSome") (EVar "damage"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "publish") (EVar "ctx")) (EVar "spans")) (EBinOp "::" (EVar "checked") (EVar "ds"))) (EBinOp "::" (ETuple (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "p")) (EVar "size") (EApp (EApp (EVar "optionOr") (EVar "UnclosedDelimiter")) (EVar "damage"))) (EVar "rs"))) (EVar "StoppedDelimiter")) (EBinOp "+" (EVar "attempts") (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recoverLoop") (EVar "limits")) (EVar "src")) (EVar "ctx")) (EVar "fs")) (EVar "damage")) (EVar "size")) (EVar "next")) (EVar "spans")) (EBinOp "::" (EVar "checked") (EVar "ds"))) (EBinOp "::" (ETuple (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "p")) (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "next")) (EVar "InvalidDeclaration")) (EVar "rs"))) (EBinOp "+" (EVar "attempts") (ELit (LInt 1)))))))))))
(DTypeSig false "findLex" (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "findLex" ((PVar "ctx") (PVar "p") (PVar "end")) (EIf (EBinOp ">=" (EVar "p") (EVar "end")) (EUnOp "-" (ELit (LInt 1))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p")) (arm (PCon "TLexError" PWild) () (EVar "p")) (arm PWild () (EApp (EApp (EApp (EVar "findLex") (EVar "ctx")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "end")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "parseRecovering" (TyFun (TyCon "String") (TyCon "RecoveredSource")))
(DFunDef false "parseRecovering" () (EApp (EVar "parseRecoveringWith") (EVar "defaultRecoveryLimits")))
(DTypeSig true "parseRecoveringWith" (TyFun (TyCon "RecoveryLimits") (TyFun (TyCon "String") (TyCon "RecoveredSource"))))
(DFunDef false "parseRecoveringWith" ((PAs "limits" (PCon "RecoveryLimits" (PVar "maxSource") (PVar "maxTokens") (PVar "maxAttempts") (PVar "maxDiagnostics"))) (PVar "src")) (EIf (EBinOp "<" (EApp (EApp (EVar "min") (EApp (EApp (EVar "min") (EVar "maxSource")) (EVar "maxTokens"))) (EApp (EApp (EVar "min") (EVar "maxAttempts")) (EVar "maxDiagnostics"))) (ELit (LInt 0))) (EApp (EApp (EVar "budgetResult") (EVar "src")) (ELit (LInt 0))) (EIf (EBinOp ">" (EApp (EVar "stringLength") (EVar "src")) (EVar "maxSource")) (EApp (EApp (EVar "budgetResult") (EVar "src")) (ELit (LInt 0))) (EIf (EVar "otherwise") (EApp (EApp (EVar "recoverTokens") (EVar "limits")) (EVar "src")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "budgetResult" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "RecoveredSource"))))
(DFunDef false "budgetResult" ((PVar "src") (PVar "count")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "makeRecoveredSource") (EListLit)) (EApp (EApp (EApp (EApp (EVar "Positions") (EListLit)) (EListLit)) (ELit (LInt 0))) (EListLit))) (EListLit)) (EListLit (EApp (EApp (EVar "makeInvalidRegion") (EApp (EApp (EVar "SourceExtent") (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "src")))) (EVar "RecoveryBudget")))) (EApp (EVar "Partial") (EVar "ExhaustedBudget"))) (EApp (EApp (EApp (EVar "RecoveryStats") (EVar "count")) (ELit (LInt 0))) (ELit (LInt 0)))))
(DTypeSig false "recoverTokens" (TyFun (TyCon "RecoveryLimits") (TyFun (TyCon "String") (TyCon "RecoveredSource"))))
(DFunDef false "recoverTokens" ((PAs "limits" (PCon "RecoveryLimits" PWild (PVar "maxTokens") PWild PWild)) (PVar "src")) (EBlock (DoLet false false (PTuple (PVar "ts") (PVar "os")) (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src"))) (DoLet false false (PVar "count") (EApp (EVar "length") (EVar "ts"))) (DoExpr (EIf (EBinOp ">" (EVar "count") (EVar "maxTokens")) (EApp (EApp (EVar "budgetResult") (EVar "src")) (EVar "count")) (EMatch (EApp (EApp (EApp (EVar "P.parseSourcePairs") (EVar "src")) (EVar "ts")) (EVar "os")) (arm (PCon "Ok" (PVar "result")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "makeRecoveredSource") (EApp (EVar "parsedDecls") (EVar "result"))) (EApp (EVar "parsedPositions") (EVar "result"))) (EListLit)) (EListLit)) (EVar "Complete")) (EApp (EApp (EApp (EVar "RecoveryStats") (EVar "count")) (ELit (LInt 0))) (ELit (LInt 0))))) (arm (PCon "Err" (PVar "firstDiagnostic")) () (EBlock (DoLet false false (PVar "ctx") (EApp (EApp (EApp (EVar "newParseContext") (EVar "src")) (EApp (EVar "arrayFromList") (EVar "ts"))) (EApp (EVar "arrayFromList") (EVar "os")))) (DoLet false false (PTuple (PVar "fs") (PVar "damage")) (EApp (EVar "fences") (EVar "ctx"))) (DoExpr (EApp (EApp (EApp (EVar "ensureDiagnostic") (EVar "limits")) (EVar "firstDiagnostic")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recoverLoop") (EVar "limits")) (EVar "src")) (EVar "ctx")) (EVar "fs")) (EVar "damage")) (EApp (EVar "stringLength") (EVar "src"))) (EApp (EApp (EVar "noiseEnd") (EVar "ctx")) (ELit (LInt 0)))) (EListLit)) (EListLit)) (EListLit)) (ELit (LInt 0))))))))))))
(DTypeSig false "ensureDiagnostic" (TyFun (TyCon "RecoveryLimits") (TyFun (TyCon "ParseDiagnostic") (TyFun (TyCon "RecoveredSource") (TyCon "RecoveredSource")))))
(DFunDef false "ensureDiagnostic" ((PCon "RecoveryLimits" PWild PWild PWild (PVar "maxDiagnostics")) (PVar "diagnostic") (PVar "result")) (EIf (EBinOp "||" (EBinOp "<=" (EVar "maxDiagnostics") (ELit (LInt 0))) (EBinOp ">" (EApp (EVar "length") (EApp (EVar "recoveredDiagnostics") (EVar "result"))) (ELit (LInt 0)))) (EVar "result") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "makeRecoveredSource") (EApp (EVar "recoveredDecls") (EVar "result"))) (EApp (EVar "recoveredPositions") (EVar "result"))) (EListLit (EVar "diagnostic"))) (EApp (EVar "invalidRegions") (EVar "result"))) (EApp (EVar "recoveredCompleteness") (EVar "result"))) (EMatch (EApp (EVar "recoveredStats") (EVar "result")) (arm (PCon "RecoveryStats" (PVar "tokens") (PVar "attempts") PWild) () (EApp (EApp (EApp (EVar "RecoveryStats") (EVar "tokens")) (EVar "attempts")) (ELit (LInt 1))))))))
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
(DUse false (UseGroup ("support" "source_index") ((mem "offsetToLineColFast" false))))
(DUse false (UseGroup ("frontend" "recovery_result") ((mem "RecoveredSource" false) (mem "SourceExtent" true) (mem "InvalidReason" true) (mem "RecoveryStop" true) (mem "RecoveryCompleteness" true) (mem "RecoveryStats" true) (mem "makeInvalidRegion" false) (mem "makeRecoveredSource" false) (mem "recoveredDecls" false) (mem "recoveredPositions" false) (mem "recoveredDiagnostics" false) (mem "invalidRegions" false) (mem "recoveredCompleteness" false) (mem "recoveredStats" false))))
(DData Public "RecoveryLimits" () ((variant "RecoveryLimits" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))) ())
(DTypeSig true "defaultRecoveryLimits" (TyCon "RecoveryLimits"))
(DFunDef false "defaultRecoveryLimits" () (EApp (EApp (EApp (EApp (EVar "RecoveryLimits") (ELit (LInt 8388608))) (ELit (LInt 500000))) (ELit (LInt 4096))) (ELit (LInt 32))))
(DTypeSig false "openKind" (TyFun (TyCon "Token") (TyCon "Int")))
(DFunDef false "openKind" ((PCon "TLParen")) (ELit (LInt 1)))
(DFunDef false "openKind" ((PCon "TLBracket")) (ELit (LInt 2)))
(DFunDef false "openKind" ((PCon "TLBracketTight")) (ELit (LInt 2)))
(DFunDef false "openKind" ((PCon "TLArray")) (ELit (LInt 3)))
(DFunDef false "openKind" ((PCon "TLBrace")) (ELit (LInt 4)))
(DFunDef false "openKind" ((PCon "TDotLBrace")) (ELit (LInt 4)))
(DFunDef false "openKind" ((PCon "TInterpOpen" PWild)) (ELit (LInt 5)))
(DFunDef false "openKind" (PWild) (ELit (LInt 0)))
(DTypeSig false "closeKind" (TyFun (TyCon "Token") (TyCon "Int")))
(DFunDef false "closeKind" ((PCon "TRParen")) (ELit (LInt 1)))
(DFunDef false "closeKind" ((PCon "TRBracket")) (ELit (LInt 2)))
(DFunDef false "closeKind" ((PCon "TRArray")) (ELit (LInt 3)))
(DFunDef false "closeKind" ((PCon "TRBrace")) (ELit (LInt 4)))
(DFunDef false "closeKind" ((PCon "TInterpEnd" PWild)) (ELit (LInt 5)))
(DFunDef false "closeKind" (PWild) (ELit (LInt 0)))
(DTypeSig false "isRoot" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool")))
(DFunDef false "isRoot" ((PList)) (EVar "True"))
(DFunDef false "isRoot" (PWild) (EVar "False"))
(DTypeSig false "fences" (TyFun (TyCon "ParseContext") (TyTuple (TyApp (TyCon "Array") (TyCon "Bool")) (TyApp (TyCon "Option") (TyCon "InvalidReason")))))
(DFunDef false "fences" ((PVar "ctx")) (EBlock (DoLet false false (PTuple (PVar "flags") (PVar "reason")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkFence") (EVar "ctx")) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit)) (EVar "False")) (EListLit))) (DoExpr (ETuple (EApp (EVar "arrayFromList") (EApp (EVar "reverse") (EVar "flags"))) (EVar "reason")))))
(DTypeSig false "walkFence" (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyTuple (TyApp (TyCon "List") (TyCon "Bool")) (TyApp (TyCon "Option") (TyCon "InvalidReason"))))))))))
(DFunDef false "walkFence" ((PVar "ctx") (PVar "p") (PVar "depth") (PVar "stack") (PVar "poison") (PVar "acc")) (EIf (EBinOp ">=" (EVar "p") (EApp (EVar "arrayLength") (EApp (EVar "contextTokens") (EVar "ctx")))) (ETuple (EVar "acc") (EIf (EVar "poison") (EApp (EVar "Some") (EVar "MismatchedDelimiter")) (EIf (EApp (EVar "not") (EApp (EVar "isRoot") (EVar "stack"))) (EApp (EVar "Some") (EVar "UnclosedDelimiter")) (EVar "None")))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "t") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p"))) (DoLet false false (PVar "off") (EApp (EVar "fst") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "p")) (EApp (EVar "contextOffsets") (EVar "ctx"))))) (DoLet false false (PTuple (PVar "_line") (PVar "col")) (EApp (EApp (EVar "offsetToLineColFast") (EApp (EVar "contextLineStarts") (EVar "ctx"))) (EVar "off"))) (DoLet false false (PVar "allowed") (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "col") (ELit (LInt 0))) (EApp (EVar "not") (EApp (EVar "isNoiseTok") (EVar "t")))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EApp (EVar "isRoot") (EVar "stack"))) (EApp (EVar "not") (EVar "poison")))) (DoLet false false (PVar "d") (EMatch (EVar "t") (arm (PCon "TIndent") () (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (arm (PCon "TDedent") () (EApp (EApp (EMethodRef "max") (ELit (LInt 0))) (EBinOp "-" (EVar "depth") (ELit (LInt 1))))) (arm PWild () (EVar "depth")))) (DoLet false false (PVar "o") (EApp (EVar "openKind") (EVar "t"))) (DoLet false false (PVar "c") (EApp (EVar "closeKind") (EVar "t"))) (DoExpr (EIf (EBinOp ">" (EVar "o") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkFence") (EVar "ctx")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "d")) (EBinOp "::" (EVar "o") (EVar "stack"))) (EVar "poison")) (EBinOp "::" (EVar "allowed") (EVar "acc"))) (EIf (EBinOp ">" (EVar "c") (ELit (LInt 0))) (EMatch (EVar "stack") (arm (PList) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkFence") (EVar "ctx")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "d")) (EListLit)) (EVar "poison")) (EBinOp "::" (EVar "allowed") (EVar "acc")))) (arm (PCons (PVar "k") (PVar "rest")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkFence") (EVar "ctx")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "d")) (EVar "rest")) (EBinOp "||" (EVar "poison") (EBinOp "/=" (EVar "k") (EVar "c")))) (EBinOp "::" (EVar "allowed") (EVar "acc"))))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkFence") (EVar "ctx")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "d")) (EVar "stack")) (EVar "poison")) (EBinOp "::" (EVar "allowed") (EVar "acc"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "noiseEnd" (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "noiseEnd" ((PVar "ctx") (PVar "p")) (EIf (EApp (EVar "isNoiseTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p"))) (EApp (EApp (EVar "noiseEnd") (EVar "ctx")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "p") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "nextFence" (TyFun (TyCon "ParseContext") (TyFun (TyApp (TyCon "Array") (TyCon "Bool")) (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "nextFence" ((PVar "ctx") (PVar "fs") (PVar "p")) (EIf (EBinOp ">=" (EVar "p") (EApp (EVar "arrayLength") (EVar "fs"))) (EVar "p") (EIf (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p"))) (EVar "p") (EIf (EApp (EApp (EVar "arrayGetUnsafe") (EVar "p")) (EVar "fs")) (EVar "p") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "nextFence") (EVar "ctx")) (EVar "fs")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "offAt" (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "offAt" ((PVar "ctx") (PVar "size") (PVar "p")) (EIf (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p"))) (EVar "size") (EIf (EBinOp "<" (EVar "p") (EApp (EVar "arrayLength") (EApp (EVar "contextOffsets") (EVar "ctx")))) (EApp (EVar "fst") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "p")) (EApp (EVar "contextOffsets") (EVar "ctx")))) (EIf (EVar "otherwise") (EVar "size") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "sliceList" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "sliceList" ((PVar "xs") (PVar "s") (PVar "e")) (EApp (EMethodRef "toList") (EApp (EApp (EApp (EVar "sliceClamped") (EVar "s")) (EVar "e")) (EVar "xs"))))
(DTypeSig false "publish" (TyFun (TyCon "ParseContext") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "ParseDiagnostic")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "InvalidReason"))) (TyFun (TyCon "RecoveryStop") (TyFun (TyCon "Int") (TyCon "RecoveredSource"))))))))
(DFunDef false "publish" ((PVar "ctx") (PVar "revSpans") (PVar "ds") (PVar "rs") (PVar "stop") (PVar "attempts")) (EBlock (DoLet false false (PVar "spans") (EApp (EVar "reverse") (EVar "revSpans"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "makeRecoveredSource") (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "d") (PVar "_s") (PVar "_e"))) (EVar "d"))) (EVar "spans"))) (EApp (EApp (EApp (EApp (EVar "positionsFromSpans") (EApp (EVar "contextLineStarts") (EVar "ctx"))) (EApp (EVar "contextTokens") (EVar "ctx"))) (EApp (EVar "contextOffsets") (EVar "ctx"))) (EVar "spans"))) (EApp (EVar "reverse") (EVar "ds"))) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "s") (PVar "e") (PVar "reason"))) (EApp (EApp (EVar "makeInvalidRegion") (EApp (EApp (EVar "SourceExtent") (EVar "s")) (EVar "e"))) (EVar "reason")))) (EApp (EVar "reverse") (EVar "rs")))) (EApp (EVar "Partial") (EVar "stop"))) (EApp (EApp (EApp (EVar "RecoveryStats") (EApp (EVar "arrayLength") (EApp (EVar "contextTokens") (EVar "ctx")))) (EVar "attempts")) (EApp (EMethodRef "length") (EVar "ds")))))))
(DTypeSig false "failureDiag" (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "ParseDiagnosticKind") (TyCon "ParseDiagnostic"))))))
(DFunDef false "failureDiag" ((PVar "ctx") (PVar "size") (PVar "p") (PVar "problem")) (EBlock (DoLet false false (PVar "loc") (EIf (EBinOp "||" (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p"))) (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "size") (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "p")) (ELit (LInt 0)))) (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EApp (EApp (EVar "noiseEnd") (EVar "ctx")) (EVar "p")))))) (EBlock (DoLet false false (PTuple (PVar "line") (PVar "col")) (EApp (EApp (EVar "offsetToLineColFast") (EApp (EVar "contextLineStarts") (EVar "ctx"))) (EVar "size"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EVar "line")) (EVar "col")) (EVar "line")) (EVar "col")))) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))))) (DoExpr (EApp (EApp (EVar "makeParseDiagnostic") (EVar "problem")) (EVar "loc")))))
(DTypeSig false "recoverLoop" (TyFun (TyCon "RecoveryLimits") (TyFun (TyCon "String") (TyFun (TyCon "ParseContext") (TyFun (TyApp (TyCon "Array") (TyCon "Bool")) (TyFun (TyApp (TyCon "Option") (TyCon "InvalidReason")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "ParseDiagnostic")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "InvalidReason"))) (TyFun (TyCon "Int") (TyCon "RecoveredSource")))))))))))))
(DFunDef false "recoverLoop" ((PAs "limits" (PCon "RecoveryLimits" PWild PWild (PVar "maxAttempts") (PVar "maxDiagnostics"))) (PVar "src") (PVar "ctx") (PVar "fs") (PVar "damage") (PVar "size") (PVar "p") (PVar "spans") (PVar "ds") (PVar "rs") (PVar "attempts")) (EIf (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "publish") (EVar "ctx")) (EVar "spans")) (EVar "ds")) (EVar "rs")) (EVar "ReachedEnd")) (EVar "attempts")) (EIf (EBinOp "||" (EBinOp ">=" (EVar "attempts") (EVar "maxAttempts")) (EBinOp ">=" (EApp (EMethodRef "length") (EVar "ds")) (EVar "maxDiagnostics"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "publish") (EVar "ctx")) (EVar "spans")) (EVar "ds")) (EBinOp "::" (ETuple (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "p")) (EVar "size") (EVar "RecoveryBudget")) (EVar "rs"))) (EVar "ExhaustedBudget")) (EVar "attempts")) (EIf (EBinOp "||" (EBinOp ">=" (EVar "p") (EApp (EVar "arrayLength") (EVar "fs"))) (EApp (EVar "not") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "p")) (EVar "fs")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "publish") (EVar "ctx")) (EVar "spans")) (EVar "ds")) (EBinOp "::" (ETuple (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "p")) (EVar "size") (EVar "UntrustedBoundary")) (EVar "rs"))) (EVar "StoppedBoundary")) (EVar "attempts")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p")) (arm (PCon "TLexError" (PVar "kind")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "publish") (EVar "ctx")) (EVar "spans")) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "failureDiag") (EVar "ctx")) (EVar "size")) (EVar "p")) (EVar "kind")) (EVar "ds"))) (EBinOp "::" (ETuple (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "p")) (EVar "size") (EVar "TerminalLexError")) (EVar "rs"))) (EVar "StoppedLexically")) (EBinOp "+" (EVar "attempts") (ELit (LInt 1))))) (arm PWild () (EBlock (DoLet false false (PVar "saved") (EApp (EVar "mark") (EVar "ctx"))) (DoExpr (EMatch (EApp (EApp (EVar "P.parseDeclAt") (EVar "ctx")) (EVar "p")) (arm (PCon "POk" (PVar "d") (PVar "q")) () (EBlock (DoLet false false (PVar "end") (EApp (EApp (EVar "noiseEnd") (EVar "ctx")) (EVar "q"))) (DoLet false false (PVar "boundary") (EBinOp "||" (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "end"))) (EBinOp "&&" (EBinOp "<" (EVar "end") (EApp (EVar "arrayLength") (EVar "fs"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "end")) (EVar "fs"))))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">" (EVar "q") (EVar "p")) (EVar "boundary")) (EBlock (DoLet false false (PVar "ts") (EApp (EApp (EApp (EVar "sliceList") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p")) (EVar "q"))) (DoLet false false (PVar "os") (EApp (EApp (EApp (EVar "sliceList") (EApp (EVar "contextOffsets") (EVar "ctx"))) (EVar "p")) (EVar "q"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "P.prescanErrorPairs") (EVar "src")) (EBinOp "++" (EVar "ts") (EListLit (EVar "TEof")))) (EBinOp "++" (EVar "os") (EListLit (ETuple (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "q")) (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "q")))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recoverLoop") (EVar "limits")) (EVar "src")) (EVar "ctx")) (EVar "fs")) (EVar "damage")) (EVar "size")) (EVar "end")) (EBinOp "::" (ETuple (EVar "d") (EVar "p") (EVar "q")) (EVar "spans"))) (EVar "ds")) (EVar "rs")) (EBinOp "+" (EVar "attempts") (ELit (LInt 1))))) (arm (PCon "Some" (PVar "err")) () (EBlock (DoExpr (EApp (EVar "rewind") (EVar "saved"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reject") (EVar "limits")) (EVar "src")) (EVar "ctx")) (EVar "fs")) (EVar "damage")) (EVar "size")) (EVar "p")) (EVar "spans")) (EVar "ds")) (EVar "rs")) (EVar "attempts")) (EApp (EVar "parseErrorDiagnostic") (EVar "err"))))))))) (EBlock (DoExpr (EApp (EVar "rewind") (EVar "saved"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reject") (EVar "limits")) (EVar "src")) (EVar "ctx")) (EVar "fs")) (EVar "damage")) (EVar "size")) (EVar "p")) (EVar "spans")) (EVar "ds")) (EVar "rs")) (EVar "attempts")) (EApp (EApp (EApp (EApp (EVar "failureDiag") (EVar "ctx")) (EVar "size")) (EVar "q")) (EApp (EVar "GenericParse") (ELit (LString "declaration did not end at a safe boundary"))))))))))) (arm (PCon "PErr" (PVar "f") (PVar "q")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reject") (EVar "limits")) (EVar "src")) (EVar "ctx")) (EVar "fs")) (EVar "damage")) (EVar "size")) (EVar "p")) (EVar "spans")) (EVar "ds")) (EVar "rs")) (EVar "attempts")) (EApp (EApp (EApp (EApp (EVar "failureDiag") (EVar "ctx")) (EVar "size")) (EVar "q")) (EApp (EVar "failProblem") (EVar "f"))))) (arm (PCon "PFatal" (PVar "f") (PVar "q")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reject") (EVar "limits")) (EVar "src")) (EVar "ctx")) (EVar "fs")) (EVar "damage")) (EVar "size")) (EVar "p")) (EVar "spans")) (EVar "ds")) (EVar "rs")) (EVar "attempts")) (EApp (EApp (EApp (EApp (EVar "failureDiag") (EVar "ctx")) (EVar "size")) (EVar "q")) (EApp (EVar "failProblem") (EVar "f")))))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "reject" (TyFun (TyCon "RecoveryLimits") (TyFun (TyCon "String") (TyFun (TyCon "ParseContext") (TyFun (TyApp (TyCon "Array") (TyCon "Bool")) (TyFun (TyApp (TyCon "Option") (TyCon "InvalidReason")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "ParseDiagnostic")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "InvalidReason"))) (TyFun (TyCon "Int") (TyFun (TyCon "ParseDiagnostic") (TyCon "RecoveredSource"))))))))))))))
(DFunDef false "reject" ((PVar "limits") (PVar "src") (PVar "ctx") (PVar "fs") (PVar "damage") (PVar "size") (PVar "p") (PVar "spans") (PVar "ds") (PVar "rs") (PVar "attempts") (PVar "diagnostic")) (EBlock (DoLet false false (PVar "next") (EApp (EApp (EApp (EVar "nextFence") (EVar "ctx")) (EVar "fs")) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (DoLet false false (PVar "terminal") (EApp (EApp (EApp (EVar "findLex") (EVar "ctx")) (EVar "p")) (EApp (EApp (EMethodRef "min") (EApp (EVar "arrayLength") (EVar "fs"))) (EBinOp "+" (EVar "next") (ELit (LInt 1)))))) (DoExpr (EIf (EBinOp ">=" (EVar "terminal") (ELit (LInt 0))) (EBlock (DoLet false false (PVar "kind") (EMatch (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "terminal")) (arm (PCon "TLexError" (PVar "k")) () (EVar "k")) (arm PWild () (EApp (EVar "GenericParse") (ELit (LString "unreachable")))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "publish") (EVar "ctx")) (EVar "spans")) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "failureDiag") (EVar "ctx")) (EVar "size")) (EVar "terminal")) (EVar "kind")) (EVar "ds"))) (EBinOp "::" (ETuple (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "p")) (EVar "size") (EVar "TerminalLexError")) (EVar "rs"))) (EVar "StoppedLexically")) (EBinOp "+" (EVar "attempts") (ELit (LInt 1)))))) (EBlock (DoLet false false (PVar "ts") (EApp (EApp (EApp (EVar "sliceList") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p")) (EVar "next"))) (DoLet false false (PVar "os") (EApp (EApp (EApp (EVar "sliceList") (EApp (EVar "contextOffsets") (EVar "ctx"))) (EVar "p")) (EVar "next"))) (DoLet false false (PVar "checked") (EMatch (EApp (EApp (EApp (EVar "P.prescanErrorPairs") (EVar "src")) (EBinOp "++" (EVar "ts") (EListLit (EVar "TEof")))) (EBinOp "++" (EVar "os") (EListLit (ETuple (EVar "size") (EVar "size"))))) (arm (PCon "Some" (PVar "err")) () (EApp (EVar "parseErrorDiagnostic") (EVar "err"))) (arm (PCon "None") () (EVar "diagnostic")))) (DoExpr (EIf (EBinOp "&&" (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "next"))) (EApp (EVar "isSome") (EVar "damage"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "publish") (EVar "ctx")) (EVar "spans")) (EBinOp "::" (EVar "checked") (EVar "ds"))) (EBinOp "::" (ETuple (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "p")) (EVar "size") (EApp (EApp (EVar "optionOr") (EVar "UnclosedDelimiter")) (EVar "damage"))) (EVar "rs"))) (EVar "StoppedDelimiter")) (EBinOp "+" (EVar "attempts") (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recoverLoop") (EVar "limits")) (EVar "src")) (EVar "ctx")) (EVar "fs")) (EVar "damage")) (EVar "size")) (EVar "next")) (EVar "spans")) (EBinOp "::" (EVar "checked") (EVar "ds"))) (EBinOp "::" (ETuple (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "p")) (EApp (EApp (EApp (EVar "offAt") (EVar "ctx")) (EVar "size")) (EVar "next")) (EVar "InvalidDeclaration")) (EVar "rs"))) (EBinOp "+" (EVar "attempts") (ELit (LInt 1)))))))))))
(DTypeSig false "findLex" (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "findLex" ((PVar "ctx") (PVar "p") (PVar "end")) (EIf (EBinOp ">=" (EVar "p") (EVar "end")) (EUnOp "-" (ELit (LInt 1))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "p")) (arm (PCon "TLexError" PWild) () (EVar "p")) (arm PWild () (EApp (EApp (EApp (EVar "findLex") (EVar "ctx")) (EBinOp "+" (EVar "p") (ELit (LInt 1)))) (EVar "end")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "parseRecovering" (TyFun (TyCon "String") (TyCon "RecoveredSource")))
(DFunDef false "parseRecovering" () (EApp (EVar "parseRecoveringWith") (EVar "defaultRecoveryLimits")))
(DTypeSig true "parseRecoveringWith" (TyFun (TyCon "RecoveryLimits") (TyFun (TyCon "String") (TyCon "RecoveredSource"))))
(DFunDef false "parseRecoveringWith" ((PAs "limits" (PCon "RecoveryLimits" (PVar "maxSource") (PVar "maxTokens") (PVar "maxAttempts") (PVar "maxDiagnostics"))) (PVar "src")) (EIf (EBinOp "<" (EApp (EApp (EMethodRef "min") (EApp (EApp (EMethodRef "min") (EVar "maxSource")) (EVar "maxTokens"))) (EApp (EApp (EMethodRef "min") (EVar "maxAttempts")) (EVar "maxDiagnostics"))) (ELit (LInt 0))) (EApp (EApp (EVar "budgetResult") (EVar "src")) (ELit (LInt 0))) (EIf (EBinOp ">" (EApp (EVar "stringLength") (EVar "src")) (EVar "maxSource")) (EApp (EApp (EVar "budgetResult") (EVar "src")) (ELit (LInt 0))) (EIf (EVar "otherwise") (EApp (EApp (EVar "recoverTokens") (EVar "limits")) (EVar "src")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "budgetResult" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "RecoveredSource"))))
(DFunDef false "budgetResult" ((PVar "src") (PVar "count")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "makeRecoveredSource") (EListLit)) (EApp (EApp (EApp (EApp (EVar "Positions") (EListLit)) (EListLit)) (ELit (LInt 0))) (EListLit))) (EListLit)) (EListLit (EApp (EApp (EVar "makeInvalidRegion") (EApp (EApp (EVar "SourceExtent") (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "src")))) (EVar "RecoveryBudget")))) (EApp (EVar "Partial") (EVar "ExhaustedBudget"))) (EApp (EApp (EApp (EVar "RecoveryStats") (EDictApp "count")) (ELit (LInt 0))) (ELit (LInt 0)))))
(DTypeSig false "recoverTokens" (TyFun (TyCon "RecoveryLimits") (TyFun (TyCon "String") (TyCon "RecoveredSource"))))
(DFunDef false "recoverTokens" ((PAs "limits" (PCon "RecoveryLimits" PWild (PVar "maxTokens") PWild PWild)) (PVar "src")) (EBlock (DoLet false false (PTuple (PVar "ts") (PVar "os")) (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src"))) (DoLet false false (PVar "count") (EApp (EMethodRef "length") (EVar "ts"))) (DoExpr (EIf (EBinOp ">" (EDictApp "count") (EVar "maxTokens")) (EApp (EApp (EVar "budgetResult") (EVar "src")) (EDictApp "count")) (EMatch (EApp (EApp (EApp (EVar "P.parseSourcePairs") (EVar "src")) (EVar "ts")) (EVar "os")) (arm (PCon "Ok" (PVar "result")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "makeRecoveredSource") (EApp (EVar "parsedDecls") (EVar "result"))) (EApp (EVar "parsedPositions") (EVar "result"))) (EListLit)) (EListLit)) (EVar "Complete")) (EApp (EApp (EApp (EVar "RecoveryStats") (EDictApp "count")) (ELit (LInt 0))) (ELit (LInt 0))))) (arm (PCon "Err" (PVar "firstDiagnostic")) () (EBlock (DoLet false false (PVar "ctx") (EApp (EApp (EApp (EVar "newParseContext") (EVar "src")) (EApp (EVar "arrayFromList") (EVar "ts"))) (EApp (EVar "arrayFromList") (EVar "os")))) (DoLet false false (PTuple (PVar "fs") (PVar "damage")) (EApp (EVar "fences") (EVar "ctx"))) (DoExpr (EApp (EApp (EApp (EVar "ensureDiagnostic") (EVar "limits")) (EVar "firstDiagnostic")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recoverLoop") (EVar "limits")) (EVar "src")) (EVar "ctx")) (EVar "fs")) (EVar "damage")) (EApp (EVar "stringLength") (EVar "src"))) (EApp (EApp (EVar "noiseEnd") (EVar "ctx")) (ELit (LInt 0)))) (EListLit)) (EListLit)) (EListLit)) (ELit (LInt 0))))))))))))
(DTypeSig false "ensureDiagnostic" (TyFun (TyCon "RecoveryLimits") (TyFun (TyCon "ParseDiagnostic") (TyFun (TyCon "RecoveredSource") (TyCon "RecoveredSource")))))
(DFunDef false "ensureDiagnostic" ((PCon "RecoveryLimits" PWild PWild PWild (PVar "maxDiagnostics")) (PVar "diagnostic") (PVar "result")) (EIf (EBinOp "||" (EBinOp "<=" (EVar "maxDiagnostics") (ELit (LInt 0))) (EBinOp ">" (EApp (EMethodRef "length") (EApp (EVar "recoveredDiagnostics") (EVar "result"))) (ELit (LInt 0)))) (EVar "result") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "makeRecoveredSource") (EApp (EVar "recoveredDecls") (EVar "result"))) (EApp (EVar "recoveredPositions") (EVar "result"))) (EListLit (EVar "diagnostic"))) (EApp (EVar "invalidRegions") (EVar "result"))) (EApp (EVar "recoveredCompleteness") (EVar "result"))) (EMatch (EApp (EVar "recoveredStats") (EVar "result")) (arm (PCon "RecoveryStats" (PVar "tokens") (PVar "attempts") PWild) () (EApp (EApp (EApp (EVar "RecoveryStats") (EVar "tokens")) (EVar "attempts")) (ELit (LInt 1))))))))
