# META
source_lines=73
stages=DESUGAR,MARK
# SOURCE
-- One parse, one desugar and one comment scan of a `medaka test` target per process.
--
-- The test verb reads the target's declarations from many sites that each
-- hold only the source text (`tsrc`): the pre-parse, the `test "…"` and `prop`
-- discovery, the native prop planner and `test --json`.  Threading decls
-- through every one of them would re-sign the whole report/driver surface, so
-- the located parse and its desugaring are memoized here, keyed on the source
-- string, with a single entry (a test run has one target; an `mcp` session
-- replaces the entry when the source changes).  The doctest examples are a
-- pure function of the same source string and are held in a second
-- single-entry slot with the same key discipline.
--
-- Always the LOCATED parse: `parseLocated` primes the loc side-channel from the
-- source it parses, so the result is a pure function of the source string.  The
-- unlocated `parse` is not, which is why this cache can hold user code while
-- `frontend/parse_cache.mdk` is confined to the prelude.

import frontend.ast.{Decl}
import frontend.parser.{parse, parseLocatedResult, ParseError}
import frontend.desugar.{desugar}
import frontend.lexer.{collectComments}
import tools.doctest.{Example, extractExamples}

targetRef : Ref (Option (String, List Decl, Option (List Decl)))
targetRef = Ref None

cachedFor : String -> Option (List Decl, Option (List Decl))
cachedFor src = match !targetRef
  Some (key, decls, ds) => if key == src then Some (decls, ds) else None
  None => None

-- The located parse of `src`, non-panicking; a success is memoized.
export
parseTargetResult : String -> Result ParseError (List Decl)
parseTargetResult src = match cachedFor src
  Some (decls, _) => Ok decls
  None => match parseLocatedResult src
    Err e => Err e
    Ok decls =>
      targetRef := Some (src, decls, None)
      Ok decls

-- The located decls, panicking on a parse error exactly as `parse` does.
export
targetRaw : String -> List Decl
targetRaw src = match parseTargetResult src
  Ok decls => decls
  Err _ => parse src

-- `desugar (targetRaw src)`, computed once.
export
targetDesugared : String -> List Decl
targetDesugared src =
  let raw = targetRaw src
  match cachedFor src
    Some (_, Some ds) => ds
    _ =>
      let ds = desugar raw
      targetRef := Some (src, raw, Some ds)
      ds

examplesRef : Ref (Option (String, List Example))
examplesRef = Ref None

-- `extractExamples (collectComments src)`, computed once.
export
targetExamples : String -> List Example
targetExamples src = match !examplesRef
  Some (key, exs) if key == src => exs
  _ =>
    let exs = extractExamples (collectComments src)
    examplesRef := Some (src, exs)
    exs
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false) (mem "parseLocatedResult" false) (mem "ParseError" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "collectComments" false))))
(DUse false (UseGroup ("tools" "doctest") ((mem "Example" false) (mem "extractExamples" false))))
(DTypeSig false "targetRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "targetRef" () (EApp (EVar "Ref") (EVar "None")))
(DTypeSig false "cachedFor" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "cachedFor" ((PVar "src")) (EMatch (EUnOp "!" (EVar "targetRef")) (arm (PCon "Some" (PTuple (PVar "key") (PVar "decls") (PVar "ds"))) () (EIf (EBinOp "==" (EVar "key") (EVar "src")) (EApp (EVar "Some") (ETuple (EVar "decls") (EVar "ds"))) (EVar "None"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig true "parseTargetResult" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "parseTargetResult" ((PVar "src")) (EMatch (EApp (EVar "cachedFor") (EVar "src")) (arm (PCon "Some" (PTuple (PVar "decls") PWild)) () (EApp (EVar "Ok") (EVar "decls"))) (arm (PCon "None") () (EMatch (EApp (EVar "parseLocatedResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "decls")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "targetRef")) (EApp (EVar "Some") (ETuple (EVar "src") (EVar "decls") (EVar "None"))))) (DoExpr (EApp (EVar "Ok") (EVar "decls")))))))))
(DTypeSig true "targetRaw" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "targetRaw" ((PVar "src")) (EMatch (EApp (EVar "parseTargetResult") (EVar "src")) (arm (PCon "Ok" (PVar "decls")) () (EVar "decls")) (arm (PCon "Err" PWild) () (EApp (EVar "parse") (EVar "src")))))
(DTypeSig true "targetDesugared" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "targetDesugared" ((PVar "src")) (EBlock (DoLet false false (PVar "raw") (EApp (EVar "targetRaw") (EVar "src"))) (DoExpr (EMatch (EApp (EVar "cachedFor") (EVar "src")) (arm (PCon "Some" (PTuple PWild (PCon "Some" (PVar "ds")))) () (EVar "ds")) (arm PWild () (EBlock (DoLet false false (PVar "ds") (EApp (EVar "desugar") (EVar "raw"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "targetRef")) (EApp (EVar "Some") (ETuple (EVar "src") (EVar "raw") (EApp (EVar "Some") (EVar "ds")))))) (DoExpr (EVar "ds"))))))))
(DTypeSig false "examplesRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Example"))))))
(DFunDef false "examplesRef" () (EApp (EVar "Ref") (EVar "None")))
(DTypeSig true "targetExamples" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Example"))))
(DFunDef false "targetExamples" ((PVar "src")) (EMatch (EUnOp "!" (EVar "examplesRef")) (arm (PCon "Some" (PTuple (PVar "key") (PVar "exs"))) ((GBool (EBinOp "==" (EVar "key") (EVar "src")))) (EVar "exs")) (arm PWild () (EBlock (DoLet false false (PVar "exs") (EApp (EVar "extractExamples") (EApp (EVar "collectComments") (EVar "src")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "examplesRef")) (EApp (EVar "Some") (ETuple (EVar "src") (EVar "exs"))))) (DoExpr (EVar "exs"))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false) (mem "parseLocatedResult" false) (mem "ParseError" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "collectComments" false))))
(DUse false (UseGroup ("tools" "doctest") ((mem "Example" false) (mem "extractExamples" false))))
(DTypeSig false "targetRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "targetRef" () (EApp (EVar "Ref") (EVar "None")))
(DTypeSig false "cachedFor" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "cachedFor" ((PVar "src")) (EMatch (EUnOp "!" (EVar "targetRef")) (arm (PCon "Some" (PTuple (PVar "key") (PVar "decls") (PVar "ds"))) () (EIf (EBinOp "==" (EVar "key") (EVar "src")) (EApp (EVar "Some") (ETuple (EVar "decls") (EVar "ds"))) (EVar "None"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig true "parseTargetResult" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "parseTargetResult" ((PVar "src")) (EMatch (EApp (EVar "cachedFor") (EVar "src")) (arm (PCon "Some" (PTuple (PVar "decls") PWild)) () (EApp (EVar "Ok") (EVar "decls"))) (arm (PCon "None") () (EMatch (EApp (EVar "parseLocatedResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "decls")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "targetRef")) (EApp (EVar "Some") (ETuple (EVar "src") (EVar "decls") (EVar "None"))))) (DoExpr (EApp (EVar "Ok") (EVar "decls")))))))))
(DTypeSig true "targetRaw" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "targetRaw" ((PVar "src")) (EMatch (EApp (EVar "parseTargetResult") (EVar "src")) (arm (PCon "Ok" (PVar "decls")) () (EVar "decls")) (arm (PCon "Err" PWild) () (EApp (EVar "parse") (EVar "src")))))
(DTypeSig true "targetDesugared" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "targetDesugared" ((PVar "src")) (EBlock (DoLet false false (PVar "raw") (EApp (EVar "targetRaw") (EVar "src"))) (DoExpr (EMatch (EApp (EVar "cachedFor") (EVar "src")) (arm (PCon "Some" (PTuple PWild (PCon "Some" (PVar "ds")))) () (EVar "ds")) (arm PWild () (EBlock (DoLet false false (PVar "ds") (EApp (EVar "desugar") (EVar "raw"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "targetRef")) (EApp (EVar "Some") (ETuple (EVar "src") (EVar "raw") (EApp (EVar "Some") (EVar "ds")))))) (DoExpr (EVar "ds"))))))))
(DTypeSig false "examplesRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Example"))))))
(DFunDef false "examplesRef" () (EApp (EVar "Ref") (EVar "None")))
(DTypeSig true "targetExamples" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Example"))))
(DFunDef false "targetExamples" ((PVar "src")) (EMatch (EUnOp "!" (EVar "examplesRef")) (arm (PCon "Some" (PTuple (PVar "key") (PVar "exs"))) ((GBool (EBinOp "==" (EVar "key") (EVar "src")))) (EVar "exs")) (arm PWild () (EBlock (DoLet false false (PVar "exs") (EApp (EVar "extractExamples") (EApp (EVar "collectComments") (EVar "src")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "examplesRef")) (EApp (EVar "Some") (ETuple (EVar "src") (EVar "exs"))))) (DoExpr (EVar "exs"))))))
