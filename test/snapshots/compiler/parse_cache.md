# META
source_lines=89
stages=DESUGAR,MARK
# SOURCE
-- Source-keyed memoization of the IMPLICIT PRELUDE parse (#2234).
--
-- `stdlib/runtime.mdk` + `stdlib/core.mdk` are read once per invocation (through
-- `readPreludeFile`, driver/build_cmd.mdk) but were PARSED four times each on the
-- `medaka check` path: `readPreludeFile`'s own validating `parseResult` (whose
-- `Ok` payload it threw away, keeping only the source text), then three separate
-- `parse` calls -- `runCheck` (tools/check.mdk), `checkRoute` (driver/medaka_cli.mdk)
-- and `analyzeFrom` (driver/diagnostics.mdk).  Measured at base b6d029cd, those
-- eight parse invocations were 54.15% of a hello-world `medaka check`.
--
-- The prelude never goes through the loader, so `parseCachedLocated`
-- (driver/loader.mdk) -- which already memoizes `parseLocated` by source string
-- for the LSP's dep graph -- does not cover it.  This module is that memo for the
-- prelude's non-located `parse`, with the same shape and the same justification:
-- the cache is keyed on SOURCE CONTENT, and equal source parses to equal decls.
--
-- Why a module-global `Ref` rather than a threaded one (loader.mdk threads its
-- cache through `loadProgramFilesLocatedCached`): the prelude parse sites are
-- eleven `readPreludeFile` call-site PAIRS across two driver files plus the whole
-- `analyzeFrom` surface, so a threaded cache would mean re-signing every one of
-- them.  A process-global memo is the same lifetime the prelude source itself
-- has, and `driverState` (types/typecheck.mdk) and `locSrcRef`
-- (frontend/parser.mdk) are the established precedent for compiler-global
-- session state.
--
-- WHAT THIS IS NOT FOR.  Only the prelude.  Do NOT route the LOCATED entries
-- (`parseLocated`/`parseLocatedResult`) or user-module parses through here: those
-- carry real ELoc spans derived from the loc side-channel `setLocState` primes,
-- so their result is a function of more than the source string.  `parse` reads
-- that side-channel too (see `located` / `ifaceMember` in frontend/parser.mdk),
-- which is exactly why the cache is confined to the two prelude files, whose
-- decls no diagnostic is ever rendered against.
--
-- Bounded for the same reason loader.mdk bounds its cache: an LSP session calls
-- `readPreludeFile` per request, and the limit keeps the assoc list from growing
-- if the prelude source is ever edited underneath a long-lived process.  Two
-- prelude files plus slack.

import frontend.ast.{Decl}
import frontend.parser.{parse}
import support.util.{lookupAssoc}

preludeCacheLimit : Int
preludeCacheLimit = 4

preludeCacheRef : Ref (List (String, List Decl))
preludeCacheRef = Ref []

-- Record an already-computed parse of `src`.  `readPreludeFile` calls this with
-- the decls its validating `parseResult` produced, so the validation parse IS the
-- one parse -- the downstream `parsePrelude` calls hit rather than re-parse.
--
-- Sound because `parseResult`'s success payload is `parse`'s output: both run
-- `runP parseProgram toks 0` over the token array of the SAME `layoutWithOffsets`
-- pass (`tokenize` and `tokenizeWithOffsets` differ only in whether they keep the
-- offsets), and their `POk` arms both hand back the same `ds`.  `parseResult`
-- additionally runs the removed-construct/lex pre-scan AHEAD of that grammar, so
-- it is a strict refinement: anything it accepts, `parse` accepts identically.
export
notePreludeParse : String -> List Decl -> Unit
notePreludeParse src decls =
  preludeCacheRef :=
    takeFirstN preludeCacheLimit ((src, decls) :: dropKeyP src !preludeCacheRef)

-- `parse`, memoized by source string.  Most-recently-used moves to the front.
export
parsePrelude : String -> List Decl
parsePrelude src = match lookupAssoc src !preludeCacheRef
  Some decls => decls
  None =>
    let decls = parse src
    let _ = notePreludeParse src decls
    decls

-- drop any existing entry with this key (so a re-parse refreshes its position).
dropKeyP : String -> List (String, List Decl) -> List (String, List Decl)
dropKeyP _ [] = []
dropKeyP k ((k2, v)::rest)
  | k == k2 = dropKeyP k rest
  | otherwise = (k2, v) :: dropKeyP k rest

-- Exported so sibling per-tier caches (e.g. desugar_cache.mdk) can reuse the
-- same MRU-truncation helper rather than duplicating it (rule-duplicate-body).
export
takeFirstN : Int -> List a -> List a
takeFirstN _ [] = []
takeFirstN n (x::xs)
  | n <= 0 = []
  | otherwise = x :: takeFirstN (n - 1) xs
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false))))
(DUse false (UseGroup ("support" "util") ((mem "lookupAssoc" false))))
(DTypeSig false "preludeCacheLimit" (TyCon "Int"))
(DFunDef false "preludeCacheLimit" () (ELit (LInt 4)))
(DTypeSig false "preludeCacheRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "preludeCacheRef" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig true "notePreludeParse" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "notePreludeParse" ((PVar "src") (PVar "decls")) (EApp (EApp (EVar "setRef") (EVar "preludeCacheRef")) (EApp (EApp (EVar "takeFirstN") (EVar "preludeCacheLimit")) (EBinOp "::" (ETuple (EVar "src") (EVar "decls")) (EApp (EApp (EVar "dropKeyP") (EVar "src")) (EUnOp "!" (EVar "preludeCacheRef")))))))
(DTypeSig true "parsePrelude" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "parsePrelude" ((PVar "src")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "src")) (EUnOp "!" (EVar "preludeCacheRef"))) (arm (PCon "Some" (PVar "decls")) () (EVar "decls")) (arm (PCon "None") () (EBlock (DoLet false false (PVar "decls") (EApp (EVar "parse") (EVar "src"))) (DoLet false false PWild (EApp (EApp (EVar "notePreludeParse") (EVar "src")) (EVar "decls"))) (DoExpr (EVar "decls"))))))
(DTypeSig false "dropKeyP" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "dropKeyP" (PWild (PList)) (EListLit))
(DFunDef false "dropKeyP" ((PVar "k") (PCons (PTuple (PVar "k2") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "k2")) (EApp (EApp (EVar "dropKeyP") (EVar "k")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k2") (EVar "v")) (EApp (EApp (EVar "dropKeyP") (EVar "k")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "takeFirstN" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "takeFirstN" (PWild (PList)) (EListLit))
(DFunDef false "takeFirstN" ((PVar "n") (PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EApp (EApp (EVar "takeFirstN") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "xs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false))))
(DUse false (UseGroup ("support" "util") ((mem "lookupAssoc" false))))
(DTypeSig false "preludeCacheLimit" (TyCon "Int"))
(DFunDef false "preludeCacheLimit" () (ELit (LInt 4)))
(DTypeSig false "preludeCacheRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "preludeCacheRef" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig true "notePreludeParse" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "notePreludeParse" ((PVar "src") (PVar "decls")) (EApp (EApp (EVar "setRef") (EVar "preludeCacheRef")) (EApp (EApp (EVar "takeFirstN") (EVar "preludeCacheLimit")) (EBinOp "::" (ETuple (EVar "src") (EVar "decls")) (EApp (EApp (EVar "dropKeyP") (EVar "src")) (EUnOp "!" (EVar "preludeCacheRef")))))))
(DTypeSig true "parsePrelude" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "parsePrelude" ((PVar "src")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "src")) (EUnOp "!" (EVar "preludeCacheRef"))) (arm (PCon "Some" (PVar "decls")) () (EVar "decls")) (arm (PCon "None") () (EBlock (DoLet false false (PVar "decls") (EApp (EVar "parse") (EVar "src"))) (DoLet false false PWild (EApp (EApp (EVar "notePreludeParse") (EVar "src")) (EVar "decls"))) (DoExpr (EVar "decls"))))))
(DTypeSig false "dropKeyP" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "dropKeyP" (PWild (PList)) (EListLit))
(DFunDef false "dropKeyP" ((PVar "k") (PCons (PTuple (PVar "k2") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "k2")) (EApp (EApp (EVar "dropKeyP") (EVar "k")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k2") (EVar "v")) (EApp (EApp (EVar "dropKeyP") (EVar "k")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "takeFirstN" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "takeFirstN" (PWild (PList)) (EListLit))
(DFunDef false "takeFirstN" ((PVar "n") (PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EApp (EApp (EVar "takeFirstN") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "xs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
