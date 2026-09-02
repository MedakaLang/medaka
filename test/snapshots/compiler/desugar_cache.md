# META
source_lines=82
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

-- Entries carry a GENERATION: a fresh Int minted each time a tree is desugared
-- for a key, so a downstream memo keyed on the generation (the typechecked-core
-- memo in `types/typecheck.mdk`, `checkCoreMemoized`) can tell "the same tree I
-- saw before" from "the same source, re-minted after an eviction" — the tree
-- carries mutable route Refs the typechecker fills, so the two are not the same
-- input.
desugarCacheRef : Ref (List (String, (Int, List Decl)))
desugarCacheRef = Ref []

desugarGenRef : Ref Int
desugarGenRef = Ref 0

-- Record an already-computed desugar of `src`'s prelude parse under a fresh generation.
noteDesugaredPrelude : String -> List Decl -> Int
noteDesugaredPrelude src decls =
  let gen = !desugarGenRef + 1
  desugarGenRef := gen
  desugarCacheRef :=
    takeFirstN
      desugarCacheLimit
      ((src, (gen, decls)) :: dropKeyD src !desugarCacheRef)
  gen

-- `desugar (parsePrelude src)`, memoized by source string. Most-recently-used
-- moves to the front, mirroring `parsePrelude`.
export
desugaredPrelude : String -> List Decl
desugaredPrelude src = snd (desugaredPreludeEntry src)

-- The generation of the tree `desugaredPrelude src` returns right now.  Hand it
-- to the typechecker's keyed entry points (`checkOneDiagsK` and siblings) as the
-- identity of that exact tree; a re-minted tree gets a new generation, so a
-- stale memo can never hit on it.
export
desugaredPreludeKey : String -> Int
desugaredPreludeKey src = fst (desugaredPreludeEntry src)

desugaredPreludeEntry : String -> (Int, List Decl)
desugaredPreludeEntry src = match lookupAssoc src !desugarCacheRef
  Some e => e
  None =>
    let decls = desugar (parsePrelude src)
    let gen = noteDesugaredPrelude src decls
    (gen, decls)

-- drop any existing entry with this key (so a re-desugar refreshes its position).
dropKeyD : String ->
  List (String, (Int, List Decl)) ->
  List (String, (Int, List Decl))
dropKeyD _ [] = []
dropKeyD k ((k2, v) :: rest)
  | k == k2 = dropKeyD k rest
  | otherwise = (k2, v) :: dropKeyD k rest
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "parse_cache") ((mem "parsePrelude" false) (mem "takeFirstN" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("support" "util") ((mem "lookupAssoc" false))))
(DTypeSig false "desugarCacheLimit" (TyCon "Int"))
(DFunDef false "desugarCacheLimit" () (ELit (LInt 4)))
(DTypeSig false "desugarCacheRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "desugarCacheRef" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "desugarGenRef" (TyApp (TyCon "Ref") (TyCon "Int")))
(DFunDef false "desugarGenRef" () (EApp (EVar "Ref") (ELit (LInt 0))))
(DTypeSig false "noteDesugaredPrelude" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Int"))))
(DFunDef false "noteDesugaredPrelude" ((PVar "src") (PVar "decls")) (EBlock (DoLet false false (PVar "gen") (EBinOp "+" (EUnOp "!" (EVar "desugarGenRef")) (ELit (LInt 1)))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "desugarGenRef")) (EVar "gen"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "desugarCacheRef")) (EApp (EApp (EVar "takeFirstN") (EVar "desugarCacheLimit")) (EBinOp "::" (ETuple (EVar "src") (ETuple (EVar "gen") (EVar "decls"))) (EApp (EApp (EVar "dropKeyD") (EVar "src")) (EUnOp "!" (EVar "desugarCacheRef"))))))) (DoExpr (EVar "gen"))))
(DTypeSig true "desugaredPrelude" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "desugaredPrelude" ((PVar "src")) (EApp (EVar "snd") (EApp (EVar "desugaredPreludeEntry") (EVar "src"))))
(DTypeSig true "desugaredPreludeKey" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "desugaredPreludeKey" ((PVar "src")) (EApp (EVar "fst") (EApp (EVar "desugaredPreludeEntry") (EVar "src"))))
(DTypeSig false "desugaredPreludeEntry" (TyFun (TyCon "String") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "desugaredPreludeEntry" ((PVar "src")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "src")) (EUnOp "!" (EVar "desugarCacheRef"))) (arm (PCon "Some" (PVar "e")) () (EVar "e")) (arm (PCon "None") () (EBlock (DoLet false false (PVar "decls") (EApp (EVar "desugar") (EApp (EVar "parsePrelude") (EVar "src")))) (DoLet false false (PVar "gen") (EApp (EApp (EVar "noteDesugaredPrelude") (EVar "src")) (EVar "decls"))) (DoExpr (ETuple (EVar "gen") (EVar "decls")))))))
(DTypeSig false "dropKeyD" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "Decl"))))))))
(DFunDef false "dropKeyD" (PWild (PList)) (EListLit))
(DFunDef false "dropKeyD" ((PVar "k") (PCons (PTuple (PVar "k2") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "k2")) (EApp (EApp (EVar "dropKeyD") (EVar "k")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k2") (EVar "v")) (EApp (EApp (EVar "dropKeyD") (EVar "k")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "parse_cache") ((mem "parsePrelude" false) (mem "takeFirstN" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("support" "util") ((mem "lookupAssoc" false))))
(DTypeSig false "desugarCacheLimit" (TyCon "Int"))
(DFunDef false "desugarCacheLimit" () (ELit (LInt 4)))
(DTypeSig false "desugarCacheRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "desugarCacheRef" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "desugarGenRef" (TyApp (TyCon "Ref") (TyCon "Int")))
(DFunDef false "desugarGenRef" () (EApp (EVar "Ref") (ELit (LInt 0))))
(DTypeSig false "noteDesugaredPrelude" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Int"))))
(DFunDef false "noteDesugaredPrelude" ((PVar "src") (PVar "decls")) (EBlock (DoLet false false (PVar "gen") (EBinOp "+" (EUnOp "!" (EVar "desugarGenRef")) (ELit (LInt 1)))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "desugarGenRef")) (EVar "gen"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "desugarCacheRef")) (EApp (EApp (EVar "takeFirstN") (EVar "desugarCacheLimit")) (EBinOp "::" (ETuple (EVar "src") (ETuple (EVar "gen") (EVar "decls"))) (EApp (EApp (EVar "dropKeyD") (EVar "src")) (EUnOp "!" (EVar "desugarCacheRef"))))))) (DoExpr (EVar "gen"))))
(DTypeSig true "desugaredPrelude" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "desugaredPrelude" ((PVar "src")) (EApp (EVar "snd") (EApp (EVar "desugaredPreludeEntry") (EVar "src"))))
(DTypeSig true "desugaredPreludeKey" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "desugaredPreludeKey" ((PVar "src")) (EApp (EVar "fst") (EApp (EVar "desugaredPreludeEntry") (EVar "src"))))
(DTypeSig false "desugaredPreludeEntry" (TyFun (TyCon "String") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "desugaredPreludeEntry" ((PVar "src")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "src")) (EUnOp "!" (EVar "desugarCacheRef"))) (arm (PCon "Some" (PVar "e")) () (EVar "e")) (arm (PCon "None") () (EBlock (DoLet false false (PVar "decls") (EApp (EVar "desugar") (EApp (EVar "parsePrelude") (EVar "src")))) (DoLet false false (PVar "gen") (EApp (EApp (EVar "noteDesugaredPrelude") (EVar "src")) (EVar "decls"))) (DoExpr (ETuple (EVar "gen") (EVar "decls")))))))
(DTypeSig false "dropKeyD" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "Decl"))))))))
(DFunDef false "dropKeyD" (PWild (PList)) (EListLit))
(DFunDef false "dropKeyD" ((PVar "k") (PCons (PTuple (PVar "k2") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "k2")) (EApp (EApp (EVar "dropKeyD") (EVar "k")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k2") (EVar "v")) (EApp (EApp (EVar "dropKeyD") (EVar "k")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
