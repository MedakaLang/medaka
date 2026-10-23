# META
source_lines=102
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
-- A process that loads the prelude's shipped declarations (`stdlib/core.mdkd`,
-- `driver/build_cmd.mdk`) registers a decoder per text instead, and neither
-- text is lexed, parsed or desugared.
--
-- Bounded for the same reason `parse_cache.mdk` bounds its cache: an LSP
-- session calls the prelude sites per request, and the limit keeps the assoc
-- list from growing if the prelude source is ever edited underneath a
-- long-lived process. Two prelude files plus slack.

import frontend.ast.{Decl}
import frontend.parse_cache.{parsePrelude, takeFirstN}
import frontend.desugar.{desugar}
import support.util.{lookupAssoc, dropAssoc}

desugarCacheLimit : Int
desugarCacheLimit = 4

-- An entry is a tree minted under a generation, or a pending decoder for the
-- text's shipped tree (`registerPreludeDecls`), run on the text's first demand.
-- The generation is a fresh Int minted each time a tree is desugared or decoded
-- for a key, so a downstream memo keyed on it (the typechecked-core memo in
-- `types/typecheck.mdk`, `checkCoreMemoized`, the prelude interface cache)
-- can tell "the same tree I saw before" from "the same source, re-minted after
-- an eviction": the re-minted tree carries other binder ids, so the two are not
-- the same input.
data DesugarEntry =
  | Minted Int (List Decl)
  | Pending (Unit -> Option (List Decl))

desugarCacheRef : Ref (List (String, DesugarEntry))
desugarCacheRef = Ref []

desugarGenRef : Ref Int
desugarGenRef = Ref 0

-- Record a tree for `src`'s prelude under a fresh generation.
noteDesugaredPrelude : String -> List Decl -> (Int, List Decl)
noteDesugaredPrelude src decls =
  let gen = !desugarGenRef + 1
  desugarGenRef := gen
  desugarCacheRef :=
    takeFirstN
      desugarCacheLimit
      ((src, Minted gen decls) :: dropAssoc src !desugarCacheRef)
  (gen, decls)

-- Hold [decode] as `src`'s tree until something first asks for it.  The decoder
-- takes the binder ordinals its tree holds off the counter when it runs, so the
-- tree's ids are the ones a desugar at that point would have minted; `None`
-- means its file did not decode, and the text is parsed and desugared instead.
-- A text that already has an entry keeps it: its generation may key a memo.
export
registerPreludeDecls : String -> (Unit -> Option (List Decl)) -> Unit
registerPreludeDecls src decode = match lookupAssoc src !desugarCacheRef
  Some _ => ()
  None =>
    desugarCacheRef :=
      takeFirstN desugarCacheLimit ((src, Pending decode) :: !desugarCacheRef)

-- `desugar (parsePrelude src)`, memoized by source string.
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

-- The generation pair of the two prelude texts: the key the prelude caches and
-- a drive's `diPreludeKey` are keyed by.
export
preludeGeneration : String -> String -> (Int, Int)
preludeGeneration rsrc csrc =
  (desugaredPreludeKey rsrc, desugaredPreludeKey csrc)

desugaredPreludeEntry : String -> (Int, List Decl)
desugaredPreludeEntry src = match lookupAssoc src !desugarCacheRef
  Some (Minted gen decls) => (gen, decls)
  Some (Pending decode) => match decode ()
    Some decls => noteDesugaredPrelude src decls
    None => noteDesugaredPrelude src (desugar (parsePrelude src))
  None => noteDesugaredPrelude src (desugar (parsePrelude src))
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "parse_cache") ((mem "parsePrelude" false) (mem "takeFirstN" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("support" "util") ((mem "lookupAssoc" false) (mem "dropAssoc" false))))
(DTypeSig false "desugarCacheLimit" (TyCon "Int"))
(DFunDef false "desugarCacheLimit" () (ELit (LInt 4)))
(DData Private "DesugarEntry" () ((variant "Minted" (ConPos (TyCon "Int") (TyApp (TyCon "List") (TyCon "Decl")))) (variant "Pending" (ConPos (TyFun (TyCon "Unit") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))) ())
(DTypeSig false "desugarCacheRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DesugarEntry")))))
(DFunDef false "desugarCacheRef" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "desugarGenRef" (TyApp (TyCon "Ref") (TyCon "Int")))
(DFunDef false "desugarGenRef" () (EApp (EVar "Ref") (ELit (LInt 0))))
(DTypeSig false "noteDesugaredPrelude" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "noteDesugaredPrelude" ((PVar "src") (PVar "decls")) (EBlock (DoLet false false (PVar "gen") (EBinOp "+" (EUnOp "!" (EVar "desugarGenRef")) (ELit (LInt 1)))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "desugarGenRef")) (EVar "gen"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "desugarCacheRef")) (EApp (EApp (EVar "takeFirstN") (EVar "desugarCacheLimit")) (EBinOp "::" (ETuple (EVar "src") (EApp (EApp (EVar "Minted") (EVar "gen")) (EVar "decls"))) (EApp (EApp (EVar "dropAssoc") (EVar "src")) (EUnOp "!" (EVar "desugarCacheRef"))))))) (DoExpr (ETuple (EVar "gen") (EVar "decls")))))
(DTypeSig true "registerPreludeDecls" (TyFun (TyCon "String") (TyFun (TyFun (TyCon "Unit") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "Unit"))))
(DFunDef false "registerPreludeDecls" ((PVar "src") (PVar "decode")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "src")) (EUnOp "!" (EVar "desugarCacheRef"))) (arm (PCon "Some" PWild) () (ELit LUnit)) (arm (PCon "None") () (EApp (EApp (EVar "setRef") (EVar "desugarCacheRef")) (EApp (EApp (EVar "takeFirstN") (EVar "desugarCacheLimit")) (EBinOp "::" (ETuple (EVar "src") (EApp (EVar "Pending") (EVar "decode"))) (EUnOp "!" (EVar "desugarCacheRef"))))))))
(DTypeSig true "desugaredPrelude" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "desugaredPrelude" ((PVar "src")) (EApp (EVar "snd") (EApp (EVar "desugaredPreludeEntry") (EVar "src"))))
(DTypeSig true "desugaredPreludeKey" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "desugaredPreludeKey" ((PVar "src")) (EApp (EVar "fst") (EApp (EVar "desugaredPreludeEntry") (EVar "src"))))
(DTypeSig true "preludeGeneration" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "preludeGeneration" ((PVar "rsrc") (PVar "csrc")) (ETuple (EApp (EVar "desugaredPreludeKey") (EVar "rsrc")) (EApp (EVar "desugaredPreludeKey") (EVar "csrc"))))
(DTypeSig false "desugaredPreludeEntry" (TyFun (TyCon "String") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "desugaredPreludeEntry" ((PVar "src")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "src")) (EUnOp "!" (EVar "desugarCacheRef"))) (arm (PCon "Some" (PCon "Minted" (PVar "gen") (PVar "decls"))) () (ETuple (EVar "gen") (EVar "decls"))) (arm (PCon "Some" (PCon "Pending" (PVar "decode"))) () (EMatch (EApp (EVar "decode") (ELit LUnit)) (arm (PCon "Some" (PVar "decls")) () (EApp (EApp (EVar "noteDesugaredPrelude") (EVar "src")) (EVar "decls"))) (arm (PCon "None") () (EApp (EApp (EVar "noteDesugaredPrelude") (EVar "src")) (EApp (EVar "desugar") (EApp (EVar "parsePrelude") (EVar "src"))))))) (arm (PCon "None") () (EApp (EApp (EVar "noteDesugaredPrelude") (EVar "src")) (EApp (EVar "desugar") (EApp (EVar "parsePrelude") (EVar "src")))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "parse_cache") ((mem "parsePrelude" false) (mem "takeFirstN" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("support" "util") ((mem "lookupAssoc" false) (mem "dropAssoc" false))))
(DTypeSig false "desugarCacheLimit" (TyCon "Int"))
(DFunDef false "desugarCacheLimit" () (ELit (LInt 4)))
(DData Private "DesugarEntry" () ((variant "Minted" (ConPos (TyCon "Int") (TyApp (TyCon "List") (TyCon "Decl")))) (variant "Pending" (ConPos (TyFun (TyCon "Unit") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))) ())
(DTypeSig false "desugarCacheRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "DesugarEntry")))))
(DFunDef false "desugarCacheRef" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "desugarGenRef" (TyApp (TyCon "Ref") (TyCon "Int")))
(DFunDef false "desugarGenRef" () (EApp (EVar "Ref") (ELit (LInt 0))))
(DTypeSig false "noteDesugaredPrelude" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "noteDesugaredPrelude" ((PVar "src") (PVar "decls")) (EBlock (DoLet false false (PVar "gen") (EBinOp "+" (EUnOp "!" (EVar "desugarGenRef")) (ELit (LInt 1)))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "desugarGenRef")) (EVar "gen"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "desugarCacheRef")) (EApp (EApp (EVar "takeFirstN") (EVar "desugarCacheLimit")) (EBinOp "::" (ETuple (EVar "src") (EApp (EApp (EVar "Minted") (EVar "gen")) (EVar "decls"))) (EApp (EApp (EVar "dropAssoc") (EVar "src")) (EUnOp "!" (EVar "desugarCacheRef"))))))) (DoExpr (ETuple (EVar "gen") (EVar "decls")))))
(DTypeSig true "registerPreludeDecls" (TyFun (TyCon "String") (TyFun (TyFun (TyCon "Unit") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "Unit"))))
(DFunDef false "registerPreludeDecls" ((PVar "src") (PVar "decode")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "src")) (EUnOp "!" (EVar "desugarCacheRef"))) (arm (PCon "Some" PWild) () (ELit LUnit)) (arm (PCon "None") () (EApp (EApp (EVar "setRef") (EVar "desugarCacheRef")) (EApp (EApp (EVar "takeFirstN") (EVar "desugarCacheLimit")) (EBinOp "::" (ETuple (EVar "src") (EApp (EVar "Pending") (EVar "decode"))) (EUnOp "!" (EVar "desugarCacheRef"))))))))
(DTypeSig true "desugaredPrelude" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "desugaredPrelude" ((PVar "src")) (EApp (EVar "snd") (EApp (EVar "desugaredPreludeEntry") (EVar "src"))))
(DTypeSig true "desugaredPreludeKey" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "desugaredPreludeKey" ((PVar "src")) (EApp (EVar "fst") (EApp (EVar "desugaredPreludeEntry") (EVar "src"))))
(DTypeSig true "preludeGeneration" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "preludeGeneration" ((PVar "rsrc") (PVar "csrc")) (ETuple (EApp (EVar "desugaredPreludeKey") (EVar "rsrc")) (EApp (EVar "desugaredPreludeKey") (EVar "csrc"))))
(DTypeSig false "desugaredPreludeEntry" (TyFun (TyCon "String") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "desugaredPreludeEntry" ((PVar "src")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "src")) (EUnOp "!" (EVar "desugarCacheRef"))) (arm (PCon "Some" (PCon "Minted" (PVar "gen") (PVar "decls"))) () (ETuple (EVar "gen") (EVar "decls"))) (arm (PCon "Some" (PCon "Pending" (PVar "decode"))) () (EMatch (EApp (EVar "decode") (ELit LUnit)) (arm (PCon "Some" (PVar "decls")) () (EApp (EApp (EVar "noteDesugaredPrelude") (EVar "src")) (EVar "decls"))) (arm (PCon "None") () (EApp (EApp (EVar "noteDesugaredPrelude") (EVar "src")) (EApp (EVar "desugar") (EApp (EVar "parsePrelude") (EVar "src"))))))) (arm (PCon "None") () (EApp (EApp (EVar "noteDesugaredPrelude") (EVar "src")) (EApp (EVar "desugar") (EApp (EVar "parsePrelude") (EVar "src")))))))
