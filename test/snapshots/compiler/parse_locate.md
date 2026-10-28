# META
source_lines=44
stages=DESUGAR,MARK
# SOURCE
import frontend.lex_token.{Token(..), peekTok, isEofTok}
import frontend.parse_diagnostic.{
  ParseDiagnostic, ParseDiagnosticKind, locateParseProblem
}
import support.source_index.{SourceIndex}

-- Char offset of token index `i` from the parallel offset array.  Two synthetic
-- tail tokens (a trailing NEWLINE and the EOF) carry offset 0 rather than a real
-- source position, so an end-of-input failure must NOT resolve through them or
-- it mislocates to 1:0.  `locateOffset` therefore pins any failure AT-OR-AFTER
-- the last real token (TEof, or an index past the array) to the source length —
-- i.e. end-of-file — and otherwise returns the token's own offset.
offsetAt : Array Int -> Int -> Int -> Int
offsetAt offs srcLen i
  | i < arrayLength offs = arrayGetUnsafe i offs
  | otherwise = srcLen

-- Resolve a failing token index to a char offset, treating the EOF / past-end
-- positions as end-of-file (srcLen) so a dangling-operator / unexpected-EOF
-- error lands at the file's end rather than the synthetic token's bogus 0.
export
locateOffset : Array Token -> Array Int -> Int -> Int -> Int
locateOffset toks offs srcLen pos
  | pos >= arrayLength toks = srcLen
  | isEofTok (peekTok toks pos) = srcLen
  | otherwise = offsetAt offs srcLen pos

export
locateTokenDiagnostic : (Unit -> SourceIndex) ->
  Array Token ->
  Array Int ->
  Array Int ->
  Int ->
  ParseDiagnosticKind ->
  Int ->
  ParseDiagnostic
locateTokenDiagnostic index toks offs ends srcLen kind pos =
  let start = locateOffset toks offs srcLen pos
  let end =
    if pos >= arrayLength toks || isEofTok (peekTok toks pos) then
      srcLen
    else
      max start (offsetAt ends srcLen pos)
  locateParseProblem (index ()) start end kind
# DESUGAR
(DUse false (UseGroup ("frontend" "lex_token") ((mem "Token" true) (mem "peekTok" false) (mem "isEofTok" false))))
(DUse false (UseGroup ("frontend" "parse_diagnostic") ((mem "ParseDiagnostic" false) (mem "ParseDiagnosticKind" false) (mem "locateParseProblem" false))))
(DUse false (UseGroup ("support" "source_index") ((mem "SourceIndex" false))))
(DTypeSig false "offsetAt" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "offsetAt" ((PVar "offs") (PVar "srcLen") (PVar "i")) (EIf (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "offs"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "offs")) (EIf (EVar "otherwise") (EVar "srcLen") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "locateOffset" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "locateOffset" ((PVar "toks") (PVar "offs") (PVar "srcLen") (PVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EApp (EVar "arrayLength") (EVar "toks"))) (EVar "srcLen") (EIf (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "pos"))) (EVar "srcLen") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "offsetAt") (EVar "offs")) (EVar "srcLen")) (EVar "pos")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "locateTokenDiagnostic" (TyFun (TyFun (TyCon "Unit") (TyCon "SourceIndex")) (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "ParseDiagnosticKind") (TyFun (TyCon "Int") (TyCon "ParseDiagnostic")))))))))
(DFunDef false "locateTokenDiagnostic" ((PVar "index") (PVar "toks") (PVar "offs") (PVar "ends") (PVar "srcLen") (PVar "kind") (PVar "pos")) (EBlock (DoLet false false (PVar "start") (EApp (EApp (EApp (EApp (EVar "locateOffset") (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "pos"))) (DoLet false false (PVar "end") (EIf (EBinOp "||" (EBinOp ">=" (EVar "pos") (EApp (EVar "arrayLength") (EVar "toks"))) (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "pos")))) (EVar "srcLen") (EApp (EApp (EVar "max") (EVar "start")) (EApp (EApp (EApp (EVar "offsetAt") (EVar "ends")) (EVar "srcLen")) (EVar "pos"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "locateParseProblem") (EApp (EVar "index") (ELit LUnit))) (EVar "start")) (EVar "end")) (EVar "kind")))))
# MARK
(DUse false (UseGroup ("frontend" "lex_token") ((mem "Token" true) (mem "peekTok" false) (mem "isEofTok" false))))
(DUse false (UseGroup ("frontend" "parse_diagnostic") ((mem "ParseDiagnostic" false) (mem "ParseDiagnosticKind" false) (mem "locateParseProblem" false))))
(DUse false (UseGroup ("support" "source_index") ((mem "SourceIndex" false))))
(DTypeSig false "offsetAt" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "offsetAt" ((PVar "offs") (PVar "srcLen") (PVar "i")) (EIf (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "offs"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "offs")) (EIf (EVar "otherwise") (EVar "srcLen") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "locateOffset" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "locateOffset" ((PVar "toks") (PVar "offs") (PVar "srcLen") (PVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EApp (EVar "arrayLength") (EVar "toks"))) (EVar "srcLen") (EIf (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "pos"))) (EVar "srcLen") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "offsetAt") (EVar "offs")) (EVar "srcLen")) (EVar "pos")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "locateTokenDiagnostic" (TyFun (TyFun (TyCon "Unit") (TyCon "SourceIndex")) (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "ParseDiagnosticKind") (TyFun (TyCon "Int") (TyCon "ParseDiagnostic")))))))))
(DFunDef false "locateTokenDiagnostic" ((PVar "index") (PVar "toks") (PVar "offs") (PVar "ends") (PVar "srcLen") (PVar "kind") (PVar "pos")) (EBlock (DoLet false false (PVar "start") (EApp (EApp (EApp (EApp (EVar "locateOffset") (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "pos"))) (DoLet false false (PVar "end") (EIf (EBinOp "||" (EBinOp ">=" (EVar "pos") (EApp (EVar "arrayLength") (EVar "toks"))) (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "pos")))) (EVar "srcLen") (EApp (EApp (EMethodRef "max") (EVar "start")) (EApp (EApp (EApp (EVar "offsetAt") (EVar "ends")) (EVar "srcLen")) (EVar "pos"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "locateParseProblem") (EApp (EMethodRef "index") (ELit LUnit))) (EVar "start")) (EVar "end")) (EVar "kind")))))
