# META
source_lines=157
stages=DESUGAR,MARK
# SOURCE
import support.stage_count.{stageBump}
import frontend.lex_token.{Token, RawTok(..)}
import frontend.lex_scan.{scanRawChars}
import frontend.lex_layout.{applyLayoutRanges}
import frontend.parser.{parseSourcePairsWithIndex, parseSourceSyntaxPairs}
import frontend.parse_result.{
  ParsedSource, makeParsedSource, parsedPositions, parsedMetadata
}
import frontend.parse_diagnostic.{ParseDiagnostic}
import frontend.parse_recovery.{RecoveryLimits(..), recoverSourcePairsWithIndex}
import frontend.recovery_result.{RecoveredSource}
import frontend.ast.{Loc(..), Decl}
import support.source_index.{SourceIndex, indexSource}

public export data SourceSpan = SourceSpan Int Int
public export data TriviaKind = LineComment | BlockComment
export data Trivia = Trivia TriviaKind SourceSpan
public export data PieceKind = TokenCoverage | CommentCoverage | SourceGap
export data SourcePiece = SourcePiece PieceKind SourceSpan
-- Source and token limits identify distinct admission failures.
-- lint-disable-next-line rule-clone-type
public export data SyntaxAdmission =
  | SourceLimit Int
  | TokenLimit Int
  deriving (Debug, Display)

export data SyntaxSource =
  SyntaxSource String SourceIndex (Array Token) (Array SourceSpan) (Array Trivia) (Array SourcePiece) (Result ParseDiagnostic ParsedSource) (Option ParsedSource) RecoveredSource

rawRange : RawTok -> (Int, Int, PieceKind)
rawRange (RTok _ s e) = (s, e, TokenCoverage)
rawRange (RTripleInterpOpen _ s e) = (s, e, TokenCoverage)
rawRange (RComment s e) = (s, e, CommentCoverage)
rawRange (RNewline _ s) = (s, s, SourceGap)
rawRange (RClauseNl _ s) = (s, s, SourceGap)
rawRange (RClauseOpen _ s _) = (s, s, SourceGap)

pieces : Int -> Int -> List RawTok -> List SourcePiece
pieces size pos [] =
  if pos < size then [SourcePiece SourceGap (SourceSpan pos size)] else []
pieces size pos (r :: rest) =
  let (s, end, kind) = rawRange r
  let e = min size end
  if e <= pos then
    pieces size pos rest
  else if s > pos then
    SourcePiece SourceGap (SourceSpan pos (min size s))
      :: pieces size s (r :: rest)
  else
    SourcePiece kind (SourceSpan pos e) :: pieces size e rest

comments : String -> List RawTok -> List Trivia
comments _ [] = []
comments src ((RComment s e) :: rest) =
  let opener = stringSlice s (s + 2) src
  let kind =
    if opener == "--" || opener == "#!" then LineComment else BlockComment
  Trivia kind (SourceSpan s e) :: comments src rest
comments src (_ :: rest) = comments src rest

export
publishSyntax : RecoveryLimits -> String -> Result SyntaxAdmission SyntaxSource
publishSyntax = publishSyntaxPrepared None

export
publishSyntaxWithCheckedDecls : RecoveryLimits ->
  String ->
  List Decl ->
  Result SyntaxAdmission SyntaxSource
publishSyntaxWithCheckedDecls limits src decls =
  publishSyntaxPrepared (Some decls) limits src

publishSyntaxPrepared : Option (List Decl) ->
  RecoveryLimits ->
  String ->
  Result SyntaxAdmission SyntaxSource
publishSyntaxPrepared known (limits@(RecoveryLimits maxSource maxTokens maxAttempts maxDiagnostics)) src =
  let _ = stageBump "syntax.publish"
  if min (min maxSource maxTokens) (min maxAttempts maxDiagnostics) < 0
    || stringLength src > maxSource then
    Err (SourceLimit (stringLength src))
  else
    let _ = stageBump "syntax.scan_raw"
    let raw = scanRawChars (stringToChars src)
    let ranges = applyLayoutRanges raw
    let tokens = map ((t, _, _) => t) ranges
    let offsets = map ((_, s, e) => (s, e)) ranges
    let count = length tokens
    if count > maxTokens then
      Err (TokenLimit count)
    else
      let index = indexSource src
      let positioned = match known
        Some _ =>
          let _ = stageBump "syntax.parse_only"
          parseSourceSyntaxPairs src tokens offsets
        None => None
      let strict = match (known, positioned)
        (Some decls, Some parsed) =>
          Ok
            (makeParsedSource
              decls
              (parsedPositions parsed)
              (parsedMetadata parsed))
        _ =>
          let _ = stageBump "syntax.parse_checked"
          parseSourcePairsWithIndex src tokens offsets (() => index)
      let structural = match strict
        Ok parsed => Some parsed
        Err _ => match known
          Some _ => positioned
          None =>
            let _ = stageBump "syntax.parse_only"
            parseSourceSyntaxPairs src tokens offsets
      let recovered =
        recoverSourcePairsWithIndex limits index src tokens offsets strict
      Ok
        (SyntaxSource
          src
          index
          (arrayFromList tokens)
          (arrayFromList (map ((s, e) => SourceSpan s e) offsets))
          (arrayFromList (comments src raw))
          (arrayFromList (pieces (stringLength src) 0 raw))
          strict
          structural
          recovered)

export
syntaxSourceText : SyntaxSource -> String
syntaxSourceText (SyntaxSource src _ _ _ _ _ _ _ _) = src

export
renderOriginal : SyntaxSource -> String
renderOriginal = syntaxSourceText

export
syntaxIndex : SyntaxSource -> SourceIndex
syntaxIndex (SyntaxSource _ index _ _ _ _ _ _ _) = index

export
syntaxTokens : SyntaxSource -> Array Token
syntaxTokens (SyntaxSource _ _ tokens _ _ _ _ _ _) =
  arrayFromList (toList tokens)

export
syntaxTokenSpans : SyntaxSource -> Array SourceSpan
syntaxTokenSpans (SyntaxSource _ _ _ spans _ _ _ _ _) =
  arrayFromList (toList spans)

export
syntaxRecovered : SyntaxSource -> RecoveredSource
syntaxRecovered (SyntaxSource _ _ _ _ _ _ _ _ recovered) = recovered

export
syntaxStructural : SyntaxSource -> Option ParsedSource
syntaxStructural (SyntaxSource _ _ _ _ _ _ _ structural _) = structural
# DESUGAR
(DUse false (UseGroup ("support" "stage_count") ((mem "stageBump" false))))
(DUse false (UseGroup ("frontend" "lex_token") ((mem "Token" false) (mem "RawTok" true))))
(DUse false (UseGroup ("frontend" "lex_scan") ((mem "scanRawChars" false))))
(DUse false (UseGroup ("frontend" "lex_layout") ((mem "applyLayoutRanges" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseSourcePairsWithIndex" false) (mem "parseSourceSyntaxPairs" false))))
(DUse false (UseGroup ("frontend" "parse_result") ((mem "ParsedSource" false) (mem "makeParsedSource" false) (mem "parsedPositions" false) (mem "parsedMetadata" false))))
(DUse false (UseGroup ("frontend" "parse_diagnostic") ((mem "ParseDiagnostic" false))))
(DUse false (UseGroup ("frontend" "parse_recovery") ((mem "RecoveryLimits" true) (mem "recoverSourcePairsWithIndex" false))))
(DUse false (UseGroup ("frontend" "recovery_result") ((mem "RecoveredSource" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Decl" false))))
(DUse false (UseGroup ("support" "source_index") ((mem "SourceIndex" false) (mem "indexSource" false))))
(DData Public "SourceSpan" () ((variant "SourceSpan" (ConPos (TyCon "Int") (TyCon "Int")))) ())
(DData Public "TriviaKind" () ((variant "LineComment" (ConPos)) (variant "BlockComment" (ConPos))) ())
(DData Abstract "Trivia" () ((variant "Trivia" (ConPos (TyCon "TriviaKind") (TyCon "SourceSpan")))) ())
(DData Public "PieceKind" () ((variant "TokenCoverage" (ConPos)) (variant "CommentCoverage" (ConPos)) (variant "SourceGap" (ConPos))) ())
(DData Abstract "SourcePiece" () ((variant "SourcePiece" (ConPos (TyCon "PieceKind") (TyCon "SourceSpan")))) ())
(DData Public "SyntaxAdmission" () ((variant "SourceLimit" (ConPos (TyCon "Int"))) (variant "TokenLimit" (ConPos (TyCon "Int")))) ())
(DImpl true "Debug" ((TyCon "SyntaxAdmission")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "SourceLimit" (PVar "__a0")) () (EBinOp "++" (ELit (LString "SourceLimit ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "TokenLimit" (PVar "__a0")) () (EBinOp "++" (ELit (LString "TokenLimit ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))))))))
(DImpl true "Display" ((TyCon "SyntaxAdmission")) () ((im "display" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "SourceLimit" (PVar "__a0")) () (EBinOp "++" (ELit (LString "SourceLimit ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "display") (EVar "__a0"))))) (arm (PCon "TokenLimit" (PVar "__a0")) () (EBinOp "++" (ELit (LString "TokenLimit ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "display") (EVar "__a0")))))))))
(DData Abstract "SyntaxSource" () ((variant "SyntaxSource" (ConPos (TyCon "String") (TyCon "SourceIndex") (TyApp (TyCon "Array") (TyCon "Token")) (TyApp (TyCon "Array") (TyCon "SourceSpan")) (TyApp (TyCon "Array") (TyCon "Trivia")) (TyApp (TyCon "Array") (TyCon "SourcePiece")) (TyApp (TyApp (TyCon "Result") (TyCon "ParseDiagnostic")) (TyCon "ParsedSource")) (TyApp (TyCon "Option") (TyCon "ParsedSource")) (TyCon "RecoveredSource")))) ())
(DTypeSig false "rawRange" (TyFun (TyCon "RawTok") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "PieceKind"))))
(DFunDef false "rawRange" ((PCon "RTok" PWild (PVar "s") (PVar "e"))) (ETuple (EVar "s") (EVar "e") (EVar "TokenCoverage")))
(DFunDef false "rawRange" ((PCon "RTripleInterpOpen" PWild (PVar "s") (PVar "e"))) (ETuple (EVar "s") (EVar "e") (EVar "TokenCoverage")))
(DFunDef false "rawRange" ((PCon "RComment" (PVar "s") (PVar "e"))) (ETuple (EVar "s") (EVar "e") (EVar "CommentCoverage")))
(DFunDef false "rawRange" ((PCon "RNewline" PWild (PVar "s"))) (ETuple (EVar "s") (EVar "s") (EVar "SourceGap")))
(DFunDef false "rawRange" ((PCon "RClauseNl" PWild (PVar "s"))) (ETuple (EVar "s") (EVar "s") (EVar "SourceGap")))
(DFunDef false "rawRange" ((PCon "RClauseOpen" PWild (PVar "s") PWild)) (ETuple (EVar "s") (EVar "s") (EVar "SourceGap")))
(DTypeSig false "pieces" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyCon "SourcePiece"))))))
(DFunDef false "pieces" ((PVar "size") (PVar "pos") (PList)) (EIf (EBinOp "<" (EVar "pos") (EVar "size")) (EListLit (EApp (EApp (EVar "SourcePiece") (EVar "SourceGap")) (EApp (EApp (EVar "SourceSpan") (EVar "pos")) (EVar "size")))) (EListLit)))
(DFunDef false "pieces" ((PVar "size") (PVar "pos") (PCons (PVar "r") (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "s") (PVar "end") (PVar "kind")) (EApp (EVar "rawRange") (EVar "r"))) (DoLet false false (PVar "e") (EApp (EApp (EVar "min") (EVar "size")) (EVar "end"))) (DoExpr (EIf (EBinOp "<=" (EVar "e") (EVar "pos")) (EApp (EApp (EApp (EVar "pieces") (EVar "size")) (EVar "pos")) (EVar "rest")) (EIf (EBinOp ">" (EVar "s") (EVar "pos")) (EBinOp "::" (EApp (EApp (EVar "SourcePiece") (EVar "SourceGap")) (EApp (EApp (EVar "SourceSpan") (EVar "pos")) (EApp (EApp (EVar "min") (EVar "size")) (EVar "s")))) (EApp (EApp (EApp (EVar "pieces") (EVar "size")) (EVar "s")) (EBinOp "::" (EVar "r") (EVar "rest")))) (EBinOp "::" (EApp (EApp (EVar "SourcePiece") (EVar "kind")) (EApp (EApp (EVar "SourceSpan") (EVar "pos")) (EVar "e"))) (EApp (EApp (EApp (EVar "pieces") (EVar "size")) (EVar "e")) (EVar "rest"))))))))
(DTypeSig false "comments" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyCon "Trivia")))))
(DFunDef false "comments" (PWild (PList)) (EListLit))
(DFunDef false "comments" ((PVar "src") (PCons (PCon "RComment" (PVar "s") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "opener") (EApp (EApp (EApp (EVar "stringSlice") (EVar "s")) (EBinOp "+" (EVar "s") (ELit (LInt 2)))) (EVar "src"))) (DoLet false false (PVar "kind") (EIf (EBinOp "||" (EBinOp "==" (EVar "opener") (ELit (LString "--"))) (EBinOp "==" (EVar "opener") (ELit (LString "#!")))) (EVar "LineComment") (EVar "BlockComment"))) (DoExpr (EBinOp "::" (EApp (EApp (EVar "Trivia") (EVar "kind")) (EApp (EApp (EVar "SourceSpan") (EVar "s")) (EVar "e"))) (EApp (EApp (EVar "comments") (EVar "src")) (EVar "rest"))))))
(DFunDef false "comments" ((PVar "src") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "comments") (EVar "src")) (EVar "rest")))
(DTypeSig true "publishSyntax" (TyFun (TyCon "RecoveryLimits") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "SyntaxAdmission")) (TyCon "SyntaxSource")))))
(DFunDef false "publishSyntax" () (EApp (EVar "publishSyntaxPrepared") (EVar "None")))
(DTypeSig true "publishSyntaxWithCheckedDecls" (TyFun (TyCon "RecoveryLimits") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "Result") (TyCon "SyntaxAdmission")) (TyCon "SyntaxSource"))))))
(DFunDef false "publishSyntaxWithCheckedDecls" ((PVar "limits") (PVar "src") (PVar "decls")) (EApp (EApp (EApp (EVar "publishSyntaxPrepared") (EApp (EVar "Some") (EVar "decls"))) (EVar "limits")) (EVar "src")))
(DTypeSig false "publishSyntaxPrepared" (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))) (TyFun (TyCon "RecoveryLimits") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "SyntaxAdmission")) (TyCon "SyntaxSource"))))))
(DFunDef false "publishSyntaxPrepared" ((PVar "known") (PAs "limits" (PCon "RecoveryLimits" (PVar "maxSource") (PVar "maxTokens") (PVar "maxAttempts") (PVar "maxDiagnostics"))) (PVar "src")) (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "syntax.publish")))) (DoExpr (EIf (EBinOp "||" (EBinOp "<" (EApp (EApp (EVar "min") (EApp (EApp (EVar "min") (EVar "maxSource")) (EVar "maxTokens"))) (EApp (EApp (EVar "min") (EVar "maxAttempts")) (EVar "maxDiagnostics"))) (ELit (LInt 0))) (EBinOp ">" (EApp (EVar "stringLength") (EVar "src")) (EVar "maxSource"))) (EApp (EVar "Err") (EApp (EVar "SourceLimit") (EApp (EVar "stringLength") (EVar "src")))) (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "syntax.scan_raw")))) (DoLet false false (PVar "raw") (EApp (EVar "scanRawChars") (EApp (EVar "stringToChars") (EVar "src")))) (DoLet false false (PVar "ranges") (EApp (EVar "applyLayoutRanges") (EVar "raw"))) (DoLet false false (PVar "tokens") (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "t") PWild PWild)) (EVar "t"))) (EVar "ranges"))) (DoLet false false (PVar "offsets") (EApp (EApp (EVar "map") (ELam ((PTuple PWild (PVar "s") (PVar "e"))) (ETuple (EVar "s") (EVar "e")))) (EVar "ranges"))) (DoLet false false (PVar "count") (EApp (EVar "length") (EVar "tokens"))) (DoExpr (EIf (EBinOp ">" (EVar "count") (EVar "maxTokens")) (EApp (EVar "Err") (EApp (EVar "TokenLimit") (EVar "count"))) (EBlock (DoLet false false (PVar "index") (EApp (EVar "indexSource") (EVar "src"))) (DoLet false false (PVar "positioned") (EMatch (EVar "known") (arm (PCon "Some" PWild) () (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "syntax.parse_only")))) (DoExpr (EApp (EApp (EApp (EVar "parseSourceSyntaxPairs") (EVar "src")) (EVar "tokens")) (EVar "offsets"))))) (arm (PCon "None") () (EVar "None")))) (DoLet false false (PVar "strict") (EMatch (ETuple (EVar "known") (EVar "positioned")) (arm (PTuple (PCon "Some" (PVar "decls")) (PCon "Some" (PVar "parsed"))) () (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "makeParsedSource") (EVar "decls")) (EApp (EVar "parsedPositions") (EVar "parsed"))) (EApp (EVar "parsedMetadata") (EVar "parsed"))))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "syntax.parse_checked")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "parseSourcePairsWithIndex") (EVar "src")) (EVar "tokens")) (EVar "offsets")) (ELam ((PLit LUnit)) (EVar "index")))))))) (DoLet false false (PVar "structural") (EMatch (EVar "strict") (arm (PCon "Ok" (PVar "parsed")) () (EApp (EVar "Some") (EVar "parsed"))) (arm (PCon "Err" PWild) () (EMatch (EVar "known") (arm (PCon "Some" PWild) () (EVar "positioned")) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "syntax.parse_only")))) (DoExpr (EApp (EApp (EApp (EVar "parseSourceSyntaxPairs") (EVar "src")) (EVar "tokens")) (EVar "offsets"))))))))) (DoLet false false (PVar "recovered") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recoverSourcePairsWithIndex") (EVar "limits")) (EVar "index")) (EVar "src")) (EVar "tokens")) (EVar "offsets")) (EVar "strict"))) (DoExpr (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "SyntaxSource") (EVar "src")) (EVar "index")) (EApp (EVar "arrayFromList") (EVar "tokens"))) (EApp (EVar "arrayFromList") (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "s") (PVar "e"))) (EApp (EApp (EVar "SourceSpan") (EVar "s")) (EVar "e")))) (EVar "offsets")))) (EApp (EVar "arrayFromList") (EApp (EApp (EVar "comments") (EVar "src")) (EVar "raw")))) (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EVar "pieces") (EApp (EVar "stringLength") (EVar "src"))) (ELit (LInt 0))) (EVar "raw")))) (EVar "strict")) (EVar "structural")) (EVar "recovered"))))))))))))
(DTypeSig true "syntaxSourceText" (TyFun (TyCon "SyntaxSource") (TyCon "String")))
(DFunDef false "syntaxSourceText" ((PCon "SyntaxSource" (PVar "src") PWild PWild PWild PWild PWild PWild PWild PWild)) (EVar "src"))
(DTypeSig true "renderOriginal" (TyFun (TyCon "SyntaxSource") (TyCon "String")))
(DFunDef false "renderOriginal" () (EVar "syntaxSourceText"))
(DTypeSig true "syntaxIndex" (TyFun (TyCon "SyntaxSource") (TyCon "SourceIndex")))
(DFunDef false "syntaxIndex" ((PCon "SyntaxSource" PWild (PVar "index") PWild PWild PWild PWild PWild PWild PWild)) (EVar "index"))
(DTypeSig true "syntaxTokens" (TyFun (TyCon "SyntaxSource") (TyApp (TyCon "Array") (TyCon "Token"))))
(DFunDef false "syntaxTokens" ((PCon "SyntaxSource" PWild PWild (PVar "tokens") PWild PWild PWild PWild PWild PWild)) (EApp (EVar "arrayFromList") (EApp (EVar "toList") (EVar "tokens"))))
(DTypeSig true "syntaxTokenSpans" (TyFun (TyCon "SyntaxSource") (TyApp (TyCon "Array") (TyCon "SourceSpan"))))
(DFunDef false "syntaxTokenSpans" ((PCon "SyntaxSource" PWild PWild PWild (PVar "spans") PWild PWild PWild PWild PWild)) (EApp (EVar "arrayFromList") (EApp (EVar "toList") (EVar "spans"))))
(DTypeSig true "syntaxRecovered" (TyFun (TyCon "SyntaxSource") (TyCon "RecoveredSource")))
(DFunDef false "syntaxRecovered" ((PCon "SyntaxSource" PWild PWild PWild PWild PWild PWild PWild PWild (PVar "recovered"))) (EVar "recovered"))
(DTypeSig true "syntaxStructural" (TyFun (TyCon "SyntaxSource") (TyApp (TyCon "Option") (TyCon "ParsedSource"))))
(DFunDef false "syntaxStructural" ((PCon "SyntaxSource" PWild PWild PWild PWild PWild PWild PWild (PVar "structural") PWild)) (EVar "structural"))
# MARK
(DUse false (UseGroup ("support" "stage_count") ((mem "stageBump" false))))
(DUse false (UseGroup ("frontend" "lex_token") ((mem "Token" false) (mem "RawTok" true))))
(DUse false (UseGroup ("frontend" "lex_scan") ((mem "scanRawChars" false))))
(DUse false (UseGroup ("frontend" "lex_layout") ((mem "applyLayoutRanges" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseSourcePairsWithIndex" false) (mem "parseSourceSyntaxPairs" false))))
(DUse false (UseGroup ("frontend" "parse_result") ((mem "ParsedSource" false) (mem "makeParsedSource" false) (mem "parsedPositions" false) (mem "parsedMetadata" false))))
(DUse false (UseGroup ("frontend" "parse_diagnostic") ((mem "ParseDiagnostic" false))))
(DUse false (UseGroup ("frontend" "parse_recovery") ((mem "RecoveryLimits" true) (mem "recoverSourcePairsWithIndex" false))))
(DUse false (UseGroup ("frontend" "recovery_result") ((mem "RecoveredSource" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Decl" false))))
(DUse false (UseGroup ("support" "source_index") ((mem "SourceIndex" false) (mem "indexSource" false))))
(DData Public "SourceSpan" () ((variant "SourceSpan" (ConPos (TyCon "Int") (TyCon "Int")))) ())
(DData Public "TriviaKind" () ((variant "LineComment" (ConPos)) (variant "BlockComment" (ConPos))) ())
(DData Abstract "Trivia" () ((variant "Trivia" (ConPos (TyCon "TriviaKind") (TyCon "SourceSpan")))) ())
(DData Public "PieceKind" () ((variant "TokenCoverage" (ConPos)) (variant "CommentCoverage" (ConPos)) (variant "SourceGap" (ConPos))) ())
(DData Abstract "SourcePiece" () ((variant "SourcePiece" (ConPos (TyCon "PieceKind") (TyCon "SourceSpan")))) ())
(DData Public "SyntaxAdmission" () ((variant "SourceLimit" (ConPos (TyCon "Int"))) (variant "TokenLimit" (ConPos (TyCon "Int")))) ())
(DImpl true "Debug" ((TyCon "SyntaxAdmission")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "SourceLimit" (PVar "__a0")) () (EBinOp "++" (ELit (LString "SourceLimit ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "TokenLimit" (PVar "__a0")) () (EBinOp "++" (ELit (LString "TokenLimit ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))))))))
(DImpl true "Display" ((TyCon "SyntaxAdmission")) () ((im "display" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "SourceLimit" (PVar "__a0")) () (EBinOp "++" (ELit (LString "SourceLimit ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "display") (EVar "__a0"))))) (arm (PCon "TokenLimit" (PVar "__a0")) () (EBinOp "++" (ELit (LString "TokenLimit ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "display") (EVar "__a0")))))))))
(DData Abstract "SyntaxSource" () ((variant "SyntaxSource" (ConPos (TyCon "String") (TyCon "SourceIndex") (TyApp (TyCon "Array") (TyCon "Token")) (TyApp (TyCon "Array") (TyCon "SourceSpan")) (TyApp (TyCon "Array") (TyCon "Trivia")) (TyApp (TyCon "Array") (TyCon "SourcePiece")) (TyApp (TyApp (TyCon "Result") (TyCon "ParseDiagnostic")) (TyCon "ParsedSource")) (TyApp (TyCon "Option") (TyCon "ParsedSource")) (TyCon "RecoveredSource")))) ())
(DTypeSig false "rawRange" (TyFun (TyCon "RawTok") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "PieceKind"))))
(DFunDef false "rawRange" ((PCon "RTok" PWild (PVar "s") (PVar "e"))) (ETuple (EVar "s") (EVar "e") (EVar "TokenCoverage")))
(DFunDef false "rawRange" ((PCon "RTripleInterpOpen" PWild (PVar "s") (PVar "e"))) (ETuple (EVar "s") (EVar "e") (EVar "TokenCoverage")))
(DFunDef false "rawRange" ((PCon "RComment" (PVar "s") (PVar "e"))) (ETuple (EVar "s") (EVar "e") (EVar "CommentCoverage")))
(DFunDef false "rawRange" ((PCon "RNewline" PWild (PVar "s"))) (ETuple (EVar "s") (EVar "s") (EVar "SourceGap")))
(DFunDef false "rawRange" ((PCon "RClauseNl" PWild (PVar "s"))) (ETuple (EVar "s") (EVar "s") (EVar "SourceGap")))
(DFunDef false "rawRange" ((PCon "RClauseOpen" PWild (PVar "s") PWild)) (ETuple (EVar "s") (EVar "s") (EVar "SourceGap")))
(DTypeSig false "pieces" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyCon "SourcePiece"))))))
(DFunDef false "pieces" ((PVar "size") (PVar "pos") (PList)) (EIf (EBinOp "<" (EVar "pos") (EVar "size")) (EListLit (EApp (EApp (EVar "SourcePiece") (EVar "SourceGap")) (EApp (EApp (EVar "SourceSpan") (EVar "pos")) (EVar "size")))) (EListLit)))
(DFunDef false "pieces" ((PVar "size") (PVar "pos") (PCons (PVar "r") (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "s") (PVar "end") (PVar "kind")) (EApp (EVar "rawRange") (EVar "r"))) (DoLet false false (PVar "e") (EApp (EApp (EMethodRef "min") (EVar "size")) (EVar "end"))) (DoExpr (EIf (EBinOp "<=" (EVar "e") (EVar "pos")) (EApp (EApp (EApp (EVar "pieces") (EVar "size")) (EVar "pos")) (EVar "rest")) (EIf (EBinOp ">" (EVar "s") (EVar "pos")) (EBinOp "::" (EApp (EApp (EVar "SourcePiece") (EVar "SourceGap")) (EApp (EApp (EVar "SourceSpan") (EVar "pos")) (EApp (EApp (EMethodRef "min") (EVar "size")) (EVar "s")))) (EApp (EApp (EApp (EVar "pieces") (EVar "size")) (EVar "s")) (EBinOp "::" (EVar "r") (EVar "rest")))) (EBinOp "::" (EApp (EApp (EVar "SourcePiece") (EVar "kind")) (EApp (EApp (EVar "SourceSpan") (EVar "pos")) (EVar "e"))) (EApp (EApp (EApp (EVar "pieces") (EVar "size")) (EVar "e")) (EVar "rest"))))))))
(DTypeSig false "comments" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "RawTok")) (TyApp (TyCon "List") (TyCon "Trivia")))))
(DFunDef false "comments" (PWild (PList)) (EListLit))
(DFunDef false "comments" ((PVar "src") (PCons (PCon "RComment" (PVar "s") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "opener") (EApp (EApp (EApp (EVar "stringSlice") (EVar "s")) (EBinOp "+" (EVar "s") (ELit (LInt 2)))) (EVar "src"))) (DoLet false false (PVar "kind") (EIf (EBinOp "||" (EBinOp "==" (EVar "opener") (ELit (LString "--"))) (EBinOp "==" (EVar "opener") (ELit (LString "#!")))) (EVar "LineComment") (EVar "BlockComment"))) (DoExpr (EBinOp "::" (EApp (EApp (EVar "Trivia") (EVar "kind")) (EApp (EApp (EVar "SourceSpan") (EVar "s")) (EVar "e"))) (EApp (EApp (EVar "comments") (EVar "src")) (EVar "rest"))))))
(DFunDef false "comments" ((PVar "src") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "comments") (EVar "src")) (EVar "rest")))
(DTypeSig true "publishSyntax" (TyFun (TyCon "RecoveryLimits") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "SyntaxAdmission")) (TyCon "SyntaxSource")))))
(DFunDef false "publishSyntax" () (EApp (EVar "publishSyntaxPrepared") (EVar "None")))
(DTypeSig true "publishSyntaxWithCheckedDecls" (TyFun (TyCon "RecoveryLimits") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "Result") (TyCon "SyntaxAdmission")) (TyCon "SyntaxSource"))))))
(DFunDef false "publishSyntaxWithCheckedDecls" ((PVar "limits") (PVar "src") (PVar "decls")) (EApp (EApp (EApp (EVar "publishSyntaxPrepared") (EApp (EVar "Some") (EVar "decls"))) (EVar "limits")) (EVar "src")))
(DTypeSig false "publishSyntaxPrepared" (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))) (TyFun (TyCon "RecoveryLimits") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "SyntaxAdmission")) (TyCon "SyntaxSource"))))))
(DFunDef false "publishSyntaxPrepared" ((PVar "known") (PAs "limits" (PCon "RecoveryLimits" (PVar "maxSource") (PVar "maxTokens") (PVar "maxAttempts") (PVar "maxDiagnostics"))) (PVar "src")) (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "syntax.publish")))) (DoExpr (EIf (EBinOp "||" (EBinOp "<" (EApp (EApp (EMethodRef "min") (EApp (EApp (EMethodRef "min") (EVar "maxSource")) (EVar "maxTokens"))) (EApp (EApp (EMethodRef "min") (EVar "maxAttempts")) (EVar "maxDiagnostics"))) (ELit (LInt 0))) (EBinOp ">" (EApp (EVar "stringLength") (EVar "src")) (EVar "maxSource"))) (EApp (EVar "Err") (EApp (EVar "SourceLimit") (EApp (EVar "stringLength") (EVar "src")))) (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "syntax.scan_raw")))) (DoLet false false (PVar "raw") (EApp (EVar "scanRawChars") (EApp (EVar "stringToChars") (EVar "src")))) (DoLet false false (PVar "ranges") (EApp (EVar "applyLayoutRanges") (EVar "raw"))) (DoLet false false (PVar "tokens") (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "t") PWild PWild)) (EVar "t"))) (EVar "ranges"))) (DoLet false false (PVar "offsets") (EApp (EApp (EMethodRef "map") (ELam ((PTuple PWild (PVar "s") (PVar "e"))) (ETuple (EVar "s") (EVar "e")))) (EVar "ranges"))) (DoLet false false (PVar "count") (EApp (EMethodRef "length") (EVar "tokens"))) (DoExpr (EIf (EBinOp ">" (EDictApp "count") (EVar "maxTokens")) (EApp (EVar "Err") (EApp (EVar "TokenLimit") (EDictApp "count"))) (EBlock (DoLet false false (PVar "index") (EApp (EVar "indexSource") (EVar "src"))) (DoLet false false (PVar "positioned") (EMatch (EVar "known") (arm (PCon "Some" PWild) () (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "syntax.parse_only")))) (DoExpr (EApp (EApp (EApp (EVar "parseSourceSyntaxPairs") (EVar "src")) (EVar "tokens")) (EVar "offsets"))))) (arm (PCon "None") () (EVar "None")))) (DoLet false false (PVar "strict") (EMatch (ETuple (EVar "known") (EVar "positioned")) (arm (PTuple (PCon "Some" (PVar "decls")) (PCon "Some" (PVar "parsed"))) () (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "makeParsedSource") (EVar "decls")) (EApp (EVar "parsedPositions") (EVar "parsed"))) (EApp (EVar "parsedMetadata") (EVar "parsed"))))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "syntax.parse_checked")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "parseSourcePairsWithIndex") (EVar "src")) (EVar "tokens")) (EVar "offsets")) (ELam ((PLit LUnit)) (EMethodRef "index")))))))) (DoLet false false (PVar "structural") (EMatch (EVar "strict") (arm (PCon "Ok" (PVar "parsed")) () (EApp (EVar "Some") (EVar "parsed"))) (arm (PCon "Err" PWild) () (EMatch (EVar "known") (arm (PCon "Some" PWild) () (EVar "positioned")) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "syntax.parse_only")))) (DoExpr (EApp (EApp (EApp (EVar "parseSourceSyntaxPairs") (EVar "src")) (EVar "tokens")) (EVar "offsets"))))))))) (DoLet false false (PVar "recovered") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recoverSourcePairsWithIndex") (EVar "limits")) (EMethodRef "index")) (EVar "src")) (EVar "tokens")) (EVar "offsets")) (EVar "strict"))) (DoExpr (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "SyntaxSource") (EVar "src")) (EMethodRef "index")) (EApp (EVar "arrayFromList") (EVar "tokens"))) (EApp (EVar "arrayFromList") (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "s") (PVar "e"))) (EApp (EApp (EVar "SourceSpan") (EVar "s")) (EVar "e")))) (EVar "offsets")))) (EApp (EVar "arrayFromList") (EApp (EApp (EVar "comments") (EVar "src")) (EVar "raw")))) (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EVar "pieces") (EApp (EVar "stringLength") (EVar "src"))) (ELit (LInt 0))) (EVar "raw")))) (EVar "strict")) (EVar "structural")) (EVar "recovered"))))))))))))
(DTypeSig true "syntaxSourceText" (TyFun (TyCon "SyntaxSource") (TyCon "String")))
(DFunDef false "syntaxSourceText" ((PCon "SyntaxSource" (PVar "src") PWild PWild PWild PWild PWild PWild PWild PWild)) (EVar "src"))
(DTypeSig true "renderOriginal" (TyFun (TyCon "SyntaxSource") (TyCon "String")))
(DFunDef false "renderOriginal" () (EVar "syntaxSourceText"))
(DTypeSig true "syntaxIndex" (TyFun (TyCon "SyntaxSource") (TyCon "SourceIndex")))
(DFunDef false "syntaxIndex" ((PCon "SyntaxSource" PWild (PVar "index") PWild PWild PWild PWild PWild PWild PWild)) (EMethodRef "index"))
(DTypeSig true "syntaxTokens" (TyFun (TyCon "SyntaxSource") (TyApp (TyCon "Array") (TyCon "Token"))))
(DFunDef false "syntaxTokens" ((PCon "SyntaxSource" PWild PWild (PVar "tokens") PWild PWild PWild PWild PWild PWild)) (EApp (EVar "arrayFromList") (EApp (EMethodRef "toList") (EVar "tokens"))))
(DTypeSig true "syntaxTokenSpans" (TyFun (TyCon "SyntaxSource") (TyApp (TyCon "Array") (TyCon "SourceSpan"))))
(DFunDef false "syntaxTokenSpans" ((PCon "SyntaxSource" PWild PWild PWild (PVar "spans") PWild PWild PWild PWild PWild)) (EApp (EVar "arrayFromList") (EApp (EMethodRef "toList") (EVar "spans"))))
(DTypeSig true "syntaxRecovered" (TyFun (TyCon "SyntaxSource") (TyCon "RecoveredSource")))
(DFunDef false "syntaxRecovered" ((PCon "SyntaxSource" PWild PWild PWild PWild PWild PWild PWild PWild (PVar "recovered"))) (EVar "recovered"))
(DTypeSig true "syntaxStructural" (TyFun (TyCon "SyntaxSource") (TyApp (TyCon "Option") (TyCon "ParsedSource"))))
(DFunDef false "syntaxStructural" ((PCon "SyntaxSource" PWild PWild PWild PWild PWild PWild PWild (PVar "structural") PWild)) (EVar "structural"))
