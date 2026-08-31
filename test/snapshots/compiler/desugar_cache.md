# META
source_lines=55
stages=DESUGAR,MARK
# SOURCE
-- Source-keyed memoization of `desugar (parsePrelude src)` (#2234, S-1).
--
-- `parse_cache.mdk` already memoizes the prelude PARSE by source string, but
-- every one of its call sites re-ran `desugar` on the (memoized) parse result
-- -- so desugar was still paid once per call site rather than once per
-- process. This module is the second tier: same shape, same justification,
-- one level up the pipeline -- keyed on the SAME source string, since equal
-- source parses (and therefore desugars) to equal decls.
--
-- Deliberately a SIBLING of `parse_cache.mdk`, not an extension of it, so the
-- two tiers stay visually distinct at the call site: `parsePrelude` is the
-- raw-parse tier, `desugaredPrelude` is the parsed+desugared tier. A future
-- typechecked-prelude artifact (S-2) attaches the same way: a third field/Ref
-- keyed by this same `src` string, in a sibling `typecheck_cache.mdk` (or
-- alongside this one) -- it should not need to rework this cache's shape.
--
-- Bounded for the same reason `parse_cache.mdk` bounds its cache: an LSP
-- session calls the prelude sites per request, and the limit keeps the assoc
-- list from growing if the prelude source is ever edited underneath a
-- long-lived process. Two prelude files plus slack.

import frontend.ast.{Decl}
import frontend.parse_cache.{parsePrelude, takeFirstN}
import frontend.desugar.{desugar}
import support.util.{lookupAssoc}

desugarCacheLimit : Int
desugarCacheLimit = 4

desugarCacheRef : Ref (List (String, List Decl))
desugarCacheRef = Ref []

-- Record an already-computed desugar of `src`'s prelude parse.
noteDesugaredPrelude : String -> List Decl -> Unit
noteDesugaredPrelude src decls =
  desugarCacheRef :=
    takeFirstN desugarCacheLimit ((src, decls) :: dropKeyD src !desugarCacheRef)

-- `desugar (parsePrelude src)`, memoized by source string. Most-recently-used
-- moves to the front, mirroring `parsePrelude`.
export
desugaredPrelude : String -> List Decl
desugaredPrelude src = match lookupAssoc src !desugarCacheRef
  Some decls => decls
  None =>
    let decls = desugar (parsePrelude src)
    let _ = noteDesugaredPrelude src decls
    decls

-- drop any existing entry with this key (so a re-desugar refreshes its position).
dropKeyD : String -> List (String, List Decl) -> List (String, List Decl)
dropKeyD _ [] = []
dropKeyD k ((k2, v)::rest)
  | k == k2 = dropKeyD k rest
  | otherwise = (k2, v) :: dropKeyD k rest
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "parse_cache") ((mem "parsePrelude" false) (mem "takeFirstN" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("support" "util") ((mem "lookupAssoc" false))))
(DTypeSig false "desugarCacheLimit" (TyCon "Int"))
(DFunDef false "desugarCacheLimit" () (ELit (LInt 4)))
(DTypeSig false "desugarCacheRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "desugarCacheRef" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "noteDesugaredPrelude" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "noteDesugaredPrelude" ((PVar "src") (PVar "decls")) (EApp (EApp (EVar "setRef") (EVar "desugarCacheRef")) (EApp (EApp (EVar "takeFirstN") (EVar "desugarCacheLimit")) (EBinOp "::" (ETuple (EVar "src") (EVar "decls")) (EApp (EApp (EVar "dropKeyD") (EVar "src")) (EUnOp "!" (EVar "desugarCacheRef")))))))
(DTypeSig true "desugaredPrelude" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "desugaredPrelude" ((PVar "src")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "src")) (EUnOp "!" (EVar "desugarCacheRef"))) (arm (PCon "Some" (PVar "decls")) () (EVar "decls")) (arm (PCon "None") () (EBlock (DoLet false false (PVar "decls") (EApp (EVar "desugar") (EApp (EVar "parsePrelude") (EVar "src")))) (DoLet false false PWild (EApp (EApp (EVar "noteDesugaredPrelude") (EVar "src")) (EVar "decls"))) (DoExpr (EVar "decls"))))))
(DTypeSig false "dropKeyD" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "dropKeyD" (PWild (PList)) (EListLit))
(DFunDef false "dropKeyD" ((PVar "k") (PCons (PTuple (PVar "k2") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "k2")) (EApp (EApp (EVar "dropKeyD") (EVar "k")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k2") (EVar "v")) (EApp (EApp (EVar "dropKeyD") (EVar "k")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "parse_cache") ((mem "parsePrelude" false) (mem "takeFirstN" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("support" "util") ((mem "lookupAssoc" false))))
(DTypeSig false "desugarCacheLimit" (TyCon "Int"))
(DFunDef false "desugarCacheLimit" () (ELit (LInt 4)))
(DTypeSig false "desugarCacheRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "desugarCacheRef" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "noteDesugaredPrelude" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "noteDesugaredPrelude" ((PVar "src") (PVar "decls")) (EApp (EApp (EVar "setRef") (EVar "desugarCacheRef")) (EApp (EApp (EVar "takeFirstN") (EVar "desugarCacheLimit")) (EBinOp "::" (ETuple (EVar "src") (EVar "decls")) (EApp (EApp (EVar "dropKeyD") (EVar "src")) (EUnOp "!" (EVar "desugarCacheRef")))))))
(DTypeSig true "desugaredPrelude" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "desugaredPrelude" ((PVar "src")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "src")) (EUnOp "!" (EVar "desugarCacheRef"))) (arm (PCon "Some" (PVar "decls")) () (EVar "decls")) (arm (PCon "None") () (EBlock (DoLet false false (PVar "decls") (EApp (EVar "desugar") (EApp (EVar "parsePrelude") (EVar "src")))) (DoLet false false PWild (EApp (EApp (EVar "noteDesugaredPrelude") (EVar "src")) (EVar "decls"))) (DoExpr (EVar "decls"))))))
(DTypeSig false "dropKeyD" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "dropKeyD" (PWild (PList)) (EListLit))
(DFunDef false "dropKeyD" ((PVar "k") (PCons (PTuple (PVar "k2") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "k2")) (EApp (EApp (EVar "dropKeyD") (EVar "k")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k2") (EVar "v")) (EApp (EApp (EVar "dropKeyD") (EVar "k")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
