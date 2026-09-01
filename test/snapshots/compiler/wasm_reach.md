# META
source_lines=257
stages=DESUGAR,MARK
# SOURCE
-- DISPATCH-ROOTED REACHABILITY for the WasmGC MODULES emit path (#2359 / #2377).
--
-- WHY: `ir/dce.mdk` runs at the elaborated-AST level and, by design, retains EVERY
-- impl-method and interface-default body WHOLE (it can only drop plain top-level
-- `DFunDef`s — see that file's SOUNDNESS block; it is SHARED with the LLVM path and
-- is not touched here).  Because every impl body is a DCE ROOT, the whole real
-- `core.mdk` prelude survives into the lowered `CProgram`: on the 43-fixture wasm
-- modules corpus that is 14,868 emitted wasm functions of which a whole-program
-- optimizer (`wasm-opt --remove-unused-module-elements`) can prove ~89.8% dead.
--
-- WHAT: a SECOND, WASM-MODULES-ONLY reachability filter, applied to the already-
-- lowered `CProgram` (downstream of `dceFilter`, upstream of `emitProgram`), that
-- roots impl-method / interface-default bodies by the METHOD NAMES the program can
-- actually dispatch on, and drops the rest — together with the plain top-level
-- bindings that were only reachable THROUGH those dropped impls.
--
-- ── THE NOTION OF "REACHABLE" (the contract S5 consumes) ─────────────────────
--
-- ONE name space.  A `String` key is simultaneously (a) a top-level binding name and
-- (b) an interface METHOD name.  Marking a key reachable keeps BOTH the binding of
-- that name (if one exists) and EVERY `CImplEntry` whose method is that name.  A
-- name that is both is over-approximated in one direction only: more is kept.
--
-- ROOTS
--   * `main`.
--   * every `$memo_<tag>_<method>` top-level CAF (`core_ir_lower.memoBindName`).
--     These are referenced by the wasm emitter's RDict dispatch arm
--     (`wasm_emit.dispatchCallSeqW` emits `call $force_$memo_…`) WITHOUT any
--     `CVar` occurrence in the IR, so an IR-only walk cannot see the edge.  There
--     are two in the whole corpus (`$memo_List_empty`, `$memo_String_empty`), so
--     rooting them unconditionally is both cheap and the only safe rule.
--
-- EDGES out of a reachable key K = the union of the reference sets of
--   * every clause body of the top-level binding named K, and
--   * every `CImplEntry` (tagged impl clause OR interface default) whose method is K.
-- A body's reference set is every `CVar` name, every `CMethod` name, every `CDict`
-- name, and every `RLocal` target symbol reachable structurally inside it — binder
-- scoping is deliberately IGNORED (a local named `x` marks a global `x`: an
-- over-approximation that can only keep more).
--
-- CANONICALIZATION mirrors `dce.canonRef` / `wasm_emit.canonFn`: a bare reference
-- that is not itself defined but whose `core__`-mangled form is resolves to the
-- mangled definition (`elaborateModules` synthesizes bare prelude references such
-- as `not` AFTER `mangleUnits` has renamed the definition).
--
-- ── WHY THIS IS SOUND WHERE NAIVE IMPL-DCE IS NOT ────────────────────────────
--
-- Dispatch is dynamic dict-passing, so an impl is NOT reached through the static
-- call graph.  The rule that makes this safe is ALL-OR-NOTHING PER METHOD NAME:
-- for a method `m` we either keep EVERY entry naming `m` or none, and "none" is
-- chosen only when no reachable body mentions `m` at all.  Every emitter query
-- against the impl list is filtered by the BARE METHOD NAME first
-- (`implForW`, `methodImpls` → the RDict if-chain, `findDefaultW`,
-- `headTagForKeyW`), so for a kept method the emitter sees the identical candidate
-- set it saw before, and for a dropped method it never asks.  In particular this
-- cannot silently turn a concrete `RKey` impl call into an interface-default
-- synthesis (`implForW` returning `None` for an impl we pruned), which is the one
-- way a per-(method, tag) prune could miscompile without failing validation.
--
-- The residual is exactly that conservatism: a method mentioned anywhere reachable
-- keeps ALL of its impls at ALL types, even the ones a whole-program optimizer can
-- prove unreachable from the concrete dict witnesses in play.
--
-- SCOPE: called from the two entries that run the REAL multi-module front end —
-- `compiler/entries/wasm_emit_modules_main.mdk` (the native modules emitter) and
-- `compiler/entries/playground_main.mdk` (the in-browser combined diagnostics+emit
-- compiler), which run the identical `lowerProgramEmit` → `emitProgram` shape and
-- so must prune identically.  The prelude-free W1–W4 (`wasm_emit_main`) and typed
-- W5 (`wasm_emit_typed_main`) entries build their own minimal impl sets and are
-- left byte-identical, as is the LLVM path.

import frontend.ast.{Route(..)}
import ir.core_ir.{
  CProgram(..),
  CExpr(..),
  CBind(..),
  CClause(..),
  CArm(..),
  CGuard(..),
  CStmt(..),
  CField(..),
  CImplEntry(..),
  CImplBody(..),
}
import support.util.{filterList, startsWith}
import hash_map.{HashMap, new, setInPlace, has, findWithDefault}

-- ── entry point ────────────────────────────────────────────────────────────
-- Filter a lowered `CProgram` to the bindings and impl entries reachable from
-- `main` (+ the `$memo_*` CAFs) under the rule documented above.  The constructor
-- and ctor→type tables are left untouched: they seed the wasm TYPE section and
-- carry no code.
export
wasmReachFilter : CProgram -> CProgram
wasmReachFilter (CProgram groups ctorArs ctorTypes impls) =
  let reach = reachKeys groups impls
  CProgram
    (filterList (b => has (bindKey b) reach) groups)
    ctorArs
    ctorTypes
    (filterList (e => has (implKey e) reach) impls)

-- local peer of wasm_emit's forEachU (module-private there); the HashMap builders
-- below are effectful folds, not value folds.
forEachU : (a -> Unit) -> List a -> Unit
forEachU _ [] = ()
forEachU f (x::xs) = let _ = f x in forEachU f xs

bindKey : CBind -> String
bindKey (CBind name _) = name

implKey : CImplEntry -> String
implKey (CImplEntry method _ _) = method

-- ── reachability ───────────────────────────────────────────────────────────
reachKeys : List CBind -> List CImplEntry -> HashMap String Unit
reachKeys groups impls =
  let defined = definedKeys groups impls
  let graph = refGraph defined groups impls
  let seen = new ()
  let roots = map (canonKey defined) ("main" :: memoRootNames groups)
  let _ = closure graph seen roots
  seen

-- every key the graph can name: top-level binding names + impl method names.
definedKeys : List CBind -> List CImplEntry -> HashMap String Unit
definedKeys groups impls =
  let s = new ()
  let _ = forEachU (b => setInPlace (bindKey b) () s) groups
  let _ = forEachU (e => setInPlace (implKey e) () s) impls
  s

-- mirrors dce.canonRef / wasm_emit.canonFn: a post-mangle-synthesized bare prelude
-- reference (`not`) resolves to its `core__`-mangled definition.
--
-- This is deliberately NOT consolidated with `dce.canonRef` (which
-- `rule-duplicate-body` will pair it with the moment the two bodies converge):
-- `canonRef` is module-private in `compiler/ir/dce.mdk`, and that file is a hard
-- no-touch here — it is SHARED with the LLVM emit path, where the identical
-- reachability question has a different (and deliberately more conservative)
-- answer.  Exporting it to share would widen this wasm-only change into the LLVM
-- path's blast radius for one three-line lookup.
canonKey : HashMap String Unit -> String -> String
canonKey defined n =
  let mangled = "core__" ++ n
  if has n defined then n else if has mangled defined then mangled else n

-- the `$memo_<tag>_<method>` CAFs — rooted unconditionally (see header).
memoRootNames : List CBind -> List String
memoRootNames groups =
  map bindKey (filterList (b => startsWith "$memo_" (bindKey b)) groups)

-- key -> the keys its bodies reference.  A binding and a same-named method merge
-- into one entry (over-approximation in the keep direction only).
refGraph : HashMap String Unit -> List CBind -> List CImplEntry -> HashMap String (List String)
refGraph defined groups impls =
  let g = new ()
  let _ = forEachU (b => addBindEdges defined g b) groups
  let _ = forEachU (e => addImplEdges defined g e) impls
  g

addBindEdges : HashMap String Unit -> HashMap String (List String) -> CBind -> Unit
addBindEdges defined g (CBind name clauses) =
  addEdges defined g name (flatMap refsClause clauses)

addImplEdges : HashMap String Unit -> HashMap String (List String) -> CImplEntry -> Unit
addImplEdges defined g (CImplEntry method _ body) =
  addEdges defined g method (refsImplBody body)

addEdges : HashMap String Unit -> HashMap String (List String) -> String -> List String -> Unit
addEdges defined g key refs =
  setInPlace key (map (canonKey defined) refs ++ findWithDefault [] key g) g

-- BFS worklist closure; `has` skips already-processed keys so each is expanded once.
closure : HashMap String (List String) -> HashMap String Unit -> List String -> Unit
closure _ _ [] = ()
closure graph seen (w::work)
  | has w seen = closure graph seen work
  | otherwise =
    let _ = setInPlace w () seen
    closure graph seen (findWithDefault [] w graph ++ work)

-- ── structural reference collection ────────────────────────────────────────
-- Every name a body can turn into a call/global reference at emit time.  Binder
-- scoping is ignored on purpose (see header).  This match is deliberately
-- EXHAUSTIVE over `CExpr` — no `_ =>` arm — so a new Core IR constructor is a
-- compile error here rather than a silently dropped edge.
refsE : CExpr -> List String
refsE (CLit _) = []
refsE (CVar x _) = [x]
refsE (CApp f a) = refsE f ++ refsE a
refsE (CLam _ body) = refsE body
refsE (CLet _ _ e1 e2) = refsE e1 ++ refsE e2
refsE (CLetGroup binds body) = flatMap refsBind binds ++ refsE body
refsE (CMatch scrut arms) = refsE scrut ++ flatMap refsArm arms
refsE (CDecision scrut arms _) = refsE scrut ++ flatMap refsArm arms
refsE (CIf c t f) = refsE c ++ refsE t ++ refsE f
refsE (CBinPrim _ l r _) = refsE l ++ refsE r
refsE (CUnOp _ x) = refsE x
refsE (CTuple es) = flatMap refsE es
refsE (CList es) = flatMap refsE es
refsE (CRecord _ fields) = flatMap refsField fields
refsE (CFieldAccess e _ _) = refsE e
refsE (CRecordUpdate _ base updates) = refsE base ++ flatMap refsField updates
refsE (CVariantUpdate _ base updates) = refsE base ++ flatMap refsField updates
refsE (CArray es) = flatMap refsE es
refsE (CRangeList lo hi _) = refsE lo ++ refsE hi
refsE (CRangeArray lo hi _) = refsE lo ++ refsE hi
refsE (CIndex a i) = refsE a ++ refsE i
refsE (CSlice a lo hi _) = refsE a ++ refsE lo ++ refsE hi
refsE (CStringIndex a i) = refsE a ++ refsE i
refsE (CStringSlice a lo hi _) = refsE a ++ refsE lo ++ refsE hi
refsE (CListIndex a i) = refsE a ++ refsE i
refsE (CListSlice a lo hi _) = refsE a ++ refsE lo ++ refsE hi
refsE (CBlock stmts) = flatMap refsStmt stmts
-- a method occurrence names its METHOD KEY; its routes can additionally name a
-- shadowing standalone (RLocal).
refsE (CMethod name route implRoutes methRoutes) =
  name :: flatMap refsRoute (route :: implRoutes ++ methRoutes)
refsE (CDict name routes) = name :: flatMap refsRoute routes

-- RLocal's carried symbol IS a top-level function the emitter calls directly
-- (wasm_emit's emitMethodRef RLocal arm).  RKey's tag and RDict/RDictFwd's dict
-- parameter name no top-level definition; RKey's nested requires-routes can still
-- carry an RLocal, so recurse.
refsRoute : Route -> List String
refsRoute RNone = []
refsRoute (RKey _ reqs) = flatMap refsRoute reqs
refsRoute (RDict _) = []
refsRoute (RDictFwd _) = []
refsRoute (RLocal sym reqs) = sym :: flatMap refsRoute reqs
refsRoute (RScalar _) = []

refsBind : CBind -> List String
refsBind (CBind _ clauses) = flatMap refsClause clauses

refsClause : CClause -> List String
refsClause (CClause _ body) = refsE body

refsArm : CArm -> List String
refsArm (CArm _ guards body) = flatMap refsGuard guards ++ refsE body

refsGuard : CGuard -> List String
refsGuard (CGBool e) = refsE e
refsGuard (CGBind _ e) = refsE e

refsStmt : CStmt -> List String
refsStmt (CSExpr e) = refsE e
refsStmt (CSLet _ _ e) = refsE e
refsStmt (CSAssign _ e) = refsE e

refsField : CField -> List String
refsField (CField _ e) = refsE e

refsImplBody : CImplBody -> List String
refsImplBody (CImplTagged _ _ _ _ _ body) = refsE body
refsImplBody (CImplDefault _ _ body) = refsE body
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Route" true))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true) (mem "CExpr" true) (mem "CBind" true) (mem "CClause" true) (mem "CArm" true) (mem "CGuard" true) (mem "CStmt" true) (mem "CField" true) (mem "CImplEntry" true) (mem "CImplBody" true))))
(DUse false (UseGroup ("support" "util") ((mem "filterList" false) (mem "startsWith" false))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false) (mem "setInPlace" false) (mem "has" false) (mem "findWithDefault" false))))
(DTypeSig true "wasmReachFilter" (TyFun (TyCon "CProgram") (TyCon "CProgram")))
(DFunDef false "wasmReachFilter" ((PCon "CProgram" (PVar "groups") (PVar "ctorArs") (PVar "ctorTypes") (PVar "impls"))) (EBlock (DoLet false false (PVar "reach") (EApp (EApp (EVar "reachKeys") (EVar "groups")) (EVar "impls"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "CProgram") (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EApp (EApp (EVar "has") (EApp (EVar "bindKey") (EVar "b"))) (EVar "reach")))) (EVar "groups"))) (EVar "ctorArs")) (EVar "ctorTypes")) (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EApp (EVar "has") (EApp (EVar "implKey") (EVar "e"))) (EVar "reach")))) (EVar "impls"))))))
(DTypeSig false "forEachU" (TyFun (TyFun (TyVar "a") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Unit"))))
(DFunDef false "forEachU" (PWild (PList)) (ELit LUnit))
(DFunDef false "forEachU" ((PVar "f") (PCons (PVar "x") (PVar "xs"))) (ELet false PWild (EApp (EVar "f") (EVar "x")) (EApp (EApp (EVar "forEachU") (EVar "f")) (EVar "xs"))))
(DTypeSig false "bindKey" (TyFun (TyCon "CBind") (TyCon "String")))
(DFunDef false "bindKey" ((PCon "CBind" (PVar "name") PWild)) (EVar "name"))
(DTypeSig false "implKey" (TyFun (TyCon "CImplEntry") (TyCon "String")))
(DFunDef false "implKey" ((PCon "CImplEntry" (PVar "method") PWild PWild)) (EVar "method"))
(DTypeSig false "reachKeys" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "reachKeys" ((PVar "groups") (PVar "impls")) (EBlock (DoLet false false (PVar "defined") (EApp (EApp (EVar "definedKeys") (EVar "groups")) (EVar "impls"))) (DoLet false false (PVar "graph") (EApp (EApp (EApp (EVar "refGraph") (EVar "defined")) (EVar "groups")) (EVar "impls"))) (DoLet false false (PVar "seen") (EApp (EVar "new") (ELit LUnit))) (DoLet false false (PVar "roots") (EApp (EApp (EVar "map") (EApp (EVar "canonKey") (EVar "defined"))) (EBinOp "::" (ELit (LString "main")) (EApp (EVar "memoRootNames") (EVar "groups"))))) (DoLet false false PWild (EApp (EApp (EApp (EVar "closure") (EVar "graph")) (EVar "seen")) (EVar "roots"))) (DoExpr (EVar "seen"))))
(DTypeSig false "definedKeys" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "definedKeys" ((PVar "groups") (PVar "impls")) (EBlock (DoLet false false (PVar "s") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "forEachU") (ELam ((PVar "b")) (EApp (EApp (EApp (EVar "setInPlace") (EApp (EVar "bindKey") (EVar "b"))) (ELit LUnit)) (EVar "s")))) (EVar "groups"))) (DoLet false false PWild (EApp (EApp (EVar "forEachU") (ELam ((PVar "e")) (EApp (EApp (EApp (EVar "setInPlace") (EApp (EVar "implKey") (EVar "e"))) (ELit LUnit)) (EVar "s")))) (EVar "impls"))) (DoExpr (EVar "s"))))
(DTypeSig false "canonKey" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "canonKey" ((PVar "defined") (PVar "n")) (EBlock (DoLet false false (PVar "mangled") (EBinOp "++" (ELit (LString "core__")) (EVar "n"))) (DoExpr (EIf (EApp (EApp (EVar "has") (EVar "n")) (EVar "defined")) (EVar "n") (EIf (EApp (EApp (EVar "has") (EVar "mangled")) (EVar "defined")) (EVar "mangled") (EVar "n"))))))
(DTypeSig false "memoRootNames" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "memoRootNames" ((PVar "groups")) (EApp (EApp (EVar "map") (EVar "bindKey")) (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EApp (EApp (EVar "startsWith") (ELit (LString "$memo_"))) (EApp (EVar "bindKey") (EVar "b"))))) (EVar "groups"))))
(DTypeSig false "refGraph" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "refGraph" ((PVar "defined") (PVar "groups") (PVar "impls")) (EBlock (DoLet false false (PVar "g") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "forEachU") (ELam ((PVar "b")) (EApp (EApp (EApp (EVar "addBindEdges") (EVar "defined")) (EVar "g")) (EVar "b")))) (EVar "groups"))) (DoLet false false PWild (EApp (EApp (EVar "forEachU") (ELam ((PVar "e")) (EApp (EApp (EApp (EVar "addImplEdges") (EVar "defined")) (EVar "g")) (EVar "e")))) (EVar "impls"))) (DoExpr (EVar "g"))))
(DTypeSig false "addBindEdges" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "CBind") (TyCon "Unit")))))
(DFunDef false "addBindEdges" ((PVar "defined") (PVar "g") (PCon "CBind" (PVar "name") (PVar "clauses"))) (EApp (EApp (EApp (EApp (EVar "addEdges") (EVar "defined")) (EVar "g")) (EVar "name")) (EApp (EApp (EVar "flatMap") (EVar "refsClause")) (EVar "clauses"))))
(DTypeSig false "addImplEdges" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "CImplEntry") (TyCon "Unit")))))
(DFunDef false "addImplEdges" ((PVar "defined") (PVar "g") (PCon "CImplEntry" (PVar "method") PWild (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "addEdges") (EVar "defined")) (EVar "g")) (EVar "method")) (EApp (EVar "refsImplBody") (EVar "body"))))
(DTypeSig false "addEdges" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "addEdges" ((PVar "defined") (PVar "g") (PVar "key") (PVar "refs")) (EApp (EApp (EApp (EVar "setInPlace") (EVar "key")) (EBinOp "++" (EApp (EApp (EVar "map") (EApp (EVar "canonKey") (EVar "defined"))) (EVar "refs")) (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "key")) (EVar "g")))) (EVar "g")))
(DTypeSig false "closure" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "closure" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "closure" ((PVar "graph") (PVar "seen") (PCons (PVar "w") (PVar "work"))) (EIf (EApp (EApp (EVar "has") (EVar "w")) (EVar "seen")) (EApp (EApp (EApp (EVar "closure") (EVar "graph")) (EVar "seen")) (EVar "work")) (EIf (EVar "otherwise") (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EVar "w")) (ELit LUnit)) (EVar "seen"))) (DoExpr (EApp (EApp (EApp (EVar "closure") (EVar "graph")) (EVar "seen")) (EBinOp "++" (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "w")) (EVar "graph")) (EVar "work"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "refsE" (TyFun (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "refsE" ((PCon "CLit" PWild)) (EListLit))
(DFunDef false "refsE" ((PCon "CVar" (PVar "x") PWild)) (EListLit (EVar "x")))
(DFunDef false "refsE" ((PCon "CApp" (PVar "f") (PVar "a"))) (EBinOp "++" (EApp (EVar "refsE") (EVar "f")) (EApp (EVar "refsE") (EVar "a"))))
(DFunDef false "refsE" ((PCon "CLam" PWild (PVar "body"))) (EApp (EVar "refsE") (EVar "body")))
(DFunDef false "refsE" ((PCon "CLet" PWild PWild (PVar "e1") (PVar "e2"))) (EBinOp "++" (EApp (EVar "refsE") (EVar "e1")) (EApp (EVar "refsE") (EVar "e2"))))
(DFunDef false "refsE" ((PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "refsBind")) (EVar "binds")) (EApp (EVar "refsE") (EVar "body"))))
(DFunDef false "refsE" ((PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EBinOp "++" (EApp (EVar "refsE") (EVar "scrut")) (EApp (EApp (EVar "flatMap") (EVar "refsArm")) (EVar "arms"))))
(DFunDef false "refsE" ((PCon "CDecision" (PVar "scrut") (PVar "arms") PWild)) (EBinOp "++" (EApp (EVar "refsE") (EVar "scrut")) (EApp (EApp (EVar "flatMap") (EVar "refsArm")) (EVar "arms"))))
(DFunDef false "refsE" ((PCon "CIf" (PVar "c") (PVar "t") (PVar "f"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "refsE") (EVar "c")) (EApp (EVar "refsE") (EVar "t"))) (EApp (EVar "refsE") (EVar "f"))))
(DFunDef false "refsE" ((PCon "CBinPrim" PWild (PVar "l") (PVar "r") PWild)) (EBinOp "++" (EApp (EVar "refsE") (EVar "l")) (EApp (EVar "refsE") (EVar "r"))))
(DFunDef false "refsE" ((PCon "CUnOp" PWild (PVar "x"))) (EApp (EVar "refsE") (EVar "x")))
(DFunDef false "refsE" ((PCon "CTuple" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EVar "refsE")) (EVar "es")))
(DFunDef false "refsE" ((PCon "CList" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EVar "refsE")) (EVar "es")))
(DFunDef false "refsE" ((PCon "CRecord" PWild (PVar "fields"))) (EApp (EApp (EVar "flatMap") (EVar "refsField")) (EVar "fields")))
(DFunDef false "refsE" ((PCon "CFieldAccess" (PVar "e") PWild PWild)) (EApp (EVar "refsE") (EVar "e")))
(DFunDef false "refsE" ((PCon "CRecordUpdate" PWild (PVar "base") (PVar "updates"))) (EBinOp "++" (EApp (EVar "refsE") (EVar "base")) (EApp (EApp (EVar "flatMap") (EVar "refsField")) (EVar "updates"))))
(DFunDef false "refsE" ((PCon "CVariantUpdate" PWild (PVar "base") (PVar "updates"))) (EBinOp "++" (EApp (EVar "refsE") (EVar "base")) (EApp (EApp (EVar "flatMap") (EVar "refsField")) (EVar "updates"))))
(DFunDef false "refsE" ((PCon "CArray" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EVar "refsE")) (EVar "es")))
(DFunDef false "refsE" ((PCon "CRangeList" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EVar "refsE") (EVar "lo")) (EApp (EVar "refsE") (EVar "hi"))))
(DFunDef false "refsE" ((PCon "CRangeArray" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EVar "refsE") (EVar "lo")) (EApp (EVar "refsE") (EVar "hi"))))
(DFunDef false "refsE" ((PCon "CIndex" (PVar "a") (PVar "i"))) (EBinOp "++" (EApp (EVar "refsE") (EVar "a")) (EApp (EVar "refsE") (EVar "i"))))
(DFunDef false "refsE" ((PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EVar "refsE") (EVar "a")) (EApp (EVar "refsE") (EVar "lo"))) (EApp (EVar "refsE") (EVar "hi"))))
(DFunDef false "refsE" ((PCon "CStringIndex" (PVar "a") (PVar "i"))) (EBinOp "++" (EApp (EVar "refsE") (EVar "a")) (EApp (EVar "refsE") (EVar "i"))))
(DFunDef false "refsE" ((PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EVar "refsE") (EVar "a")) (EApp (EVar "refsE") (EVar "lo"))) (EApp (EVar "refsE") (EVar "hi"))))
(DFunDef false "refsE" ((PCon "CListIndex" (PVar "a") (PVar "i"))) (EBinOp "++" (EApp (EVar "refsE") (EVar "a")) (EApp (EVar "refsE") (EVar "i"))))
(DFunDef false "refsE" ((PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EVar "refsE") (EVar "a")) (EApp (EVar "refsE") (EVar "lo"))) (EApp (EVar "refsE") (EVar "hi"))))
(DFunDef false "refsE" ((PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EVar "flatMap") (EVar "refsStmt")) (EVar "stmts")))
(DFunDef false "refsE" ((PCon "CMethod" (PVar "name") (PVar "route") (PVar "implRoutes") (PVar "methRoutes"))) (EBinOp "::" (EVar "name") (EApp (EApp (EVar "flatMap") (EVar "refsRoute")) (EBinOp "::" (EVar "route") (EBinOp "++" (EVar "implRoutes") (EVar "methRoutes"))))))
(DFunDef false "refsE" ((PCon "CDict" (PVar "name") (PVar "routes"))) (EBinOp "::" (EVar "name") (EApp (EApp (EVar "flatMap") (EVar "refsRoute")) (EVar "routes"))))
(DTypeSig false "refsRoute" (TyFun (TyCon "Route") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "refsRoute" ((PCon "RNone")) (EListLit))
(DFunDef false "refsRoute" ((PCon "RKey" PWild (PVar "reqs"))) (EApp (EApp (EVar "flatMap") (EVar "refsRoute")) (EVar "reqs")))
(DFunDef false "refsRoute" ((PCon "RDict" PWild)) (EListLit))
(DFunDef false "refsRoute" ((PCon "RDictFwd" PWild)) (EListLit))
(DFunDef false "refsRoute" ((PCon "RLocal" (PVar "sym") (PVar "reqs"))) (EBinOp "::" (EVar "sym") (EApp (EApp (EVar "flatMap") (EVar "refsRoute")) (EVar "reqs"))))
(DFunDef false "refsRoute" ((PCon "RScalar" PWild)) (EListLit))
(DTypeSig false "refsBind" (TyFun (TyCon "CBind") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "refsBind" ((PCon "CBind" PWild (PVar "clauses"))) (EApp (EApp (EVar "flatMap") (EVar "refsClause")) (EVar "clauses")))
(DTypeSig false "refsClause" (TyFun (TyCon "CClause") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "refsClause" ((PCon "CClause" PWild (PVar "body"))) (EApp (EVar "refsE") (EVar "body")))
(DTypeSig false "refsArm" (TyFun (TyCon "CArm") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "refsArm" ((PCon "CArm" PWild (PVar "guards") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "refsGuard")) (EVar "guards")) (EApp (EVar "refsE") (EVar "body"))))
(DTypeSig false "refsGuard" (TyFun (TyCon "CGuard") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "refsGuard" ((PCon "CGBool" (PVar "e"))) (EApp (EVar "refsE") (EVar "e")))
(DFunDef false "refsGuard" ((PCon "CGBind" PWild (PVar "e"))) (EApp (EVar "refsE") (EVar "e")))
(DTypeSig false "refsStmt" (TyFun (TyCon "CStmt") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "refsStmt" ((PCon "CSExpr" (PVar "e"))) (EApp (EVar "refsE") (EVar "e")))
(DFunDef false "refsStmt" ((PCon "CSLet" PWild PWild (PVar "e"))) (EApp (EVar "refsE") (EVar "e")))
(DFunDef false "refsStmt" ((PCon "CSAssign" PWild (PVar "e"))) (EApp (EVar "refsE") (EVar "e")))
(DTypeSig false "refsField" (TyFun (TyCon "CField") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "refsField" ((PCon "CField" PWild (PVar "e"))) (EApp (EVar "refsE") (EVar "e")))
(DTypeSig false "refsImplBody" (TyFun (TyCon "CImplBody") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "refsImplBody" ((PCon "CImplTagged" PWild PWild PWild PWild PWild (PVar "body"))) (EApp (EVar "refsE") (EVar "body")))
(DFunDef false "refsImplBody" ((PCon "CImplDefault" PWild PWild (PVar "body"))) (EApp (EVar "refsE") (EVar "body")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Route" true))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true) (mem "CExpr" true) (mem "CBind" true) (mem "CClause" true) (mem "CArm" true) (mem "CGuard" true) (mem "CStmt" true) (mem "CField" true) (mem "CImplEntry" true) (mem "CImplBody" true))))
(DUse false (UseGroup ("support" "util") ((mem "filterList" false) (mem "startsWith" false))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false) (mem "setInPlace" false) (mem "has" false) (mem "findWithDefault" false))))
(DTypeSig true "wasmReachFilter" (TyFun (TyCon "CProgram") (TyCon "CProgram")))
(DFunDef false "wasmReachFilter" ((PCon "CProgram" (PVar "groups") (PVar "ctorArs") (PVar "ctorTypes") (PVar "impls"))) (EBlock (DoLet false false (PVar "reach") (EApp (EApp (EVar "reachKeys") (EVar "groups")) (EVar "impls"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "CProgram") (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EApp (EApp (EVar "has") (EApp (EVar "bindKey") (EVar "b"))) (EVar "reach")))) (EVar "groups"))) (EVar "ctorArs")) (EVar "ctorTypes")) (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EApp (EVar "has") (EApp (EVar "implKey") (EVar "e"))) (EVar "reach")))) (EVar "impls"))))))
(DTypeSig false "forEachU" (TyFun (TyFun (TyVar "a") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Unit"))))
(DFunDef false "forEachU" (PWild (PList)) (ELit LUnit))
(DFunDef false "forEachU" ((PVar "f") (PCons (PVar "x") (PVar "xs"))) (ELet false PWild (EApp (EVar "f") (EVar "x")) (EApp (EApp (EVar "forEachU") (EVar "f")) (EVar "xs"))))
(DTypeSig false "bindKey" (TyFun (TyCon "CBind") (TyCon "String")))
(DFunDef false "bindKey" ((PCon "CBind" (PVar "name") PWild)) (EVar "name"))
(DTypeSig false "implKey" (TyFun (TyCon "CImplEntry") (TyCon "String")))
(DFunDef false "implKey" ((PCon "CImplEntry" (PVar "method") PWild PWild)) (EVar "method"))
(DTypeSig false "reachKeys" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "reachKeys" ((PVar "groups") (PVar "impls")) (EBlock (DoLet false false (PVar "defined") (EApp (EApp (EVar "definedKeys") (EVar "groups")) (EVar "impls"))) (DoLet false false (PVar "graph") (EApp (EApp (EApp (EVar "refGraph") (EVar "defined")) (EVar "groups")) (EVar "impls"))) (DoLet false false (PVar "seen") (EApp (EVar "new") (ELit LUnit))) (DoLet false false (PVar "roots") (EApp (EApp (EMethodRef "map") (EApp (EVar "canonKey") (EVar "defined"))) (EBinOp "::" (ELit (LString "main")) (EApp (EVar "memoRootNames") (EVar "groups"))))) (DoLet false false PWild (EApp (EApp (EApp (EVar "closure") (EVar "graph")) (EVar "seen")) (EVar "roots"))) (DoExpr (EVar "seen"))))
(DTypeSig false "definedKeys" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "definedKeys" ((PVar "groups") (PVar "impls")) (EBlock (DoLet false false (PVar "s") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "forEachU") (ELam ((PVar "b")) (EApp (EApp (EApp (EVar "setInPlace") (EApp (EVar "bindKey") (EVar "b"))) (ELit LUnit)) (EVar "s")))) (EVar "groups"))) (DoLet false false PWild (EApp (EApp (EVar "forEachU") (ELam ((PVar "e")) (EApp (EApp (EApp (EVar "setInPlace") (EApp (EVar "implKey") (EVar "e"))) (ELit LUnit)) (EVar "s")))) (EVar "impls"))) (DoExpr (EVar "s"))))
(DTypeSig false "canonKey" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "canonKey" ((PVar "defined") (PVar "n")) (EBlock (DoLet false false (PVar "mangled") (EBinOp "++" (ELit (LString "core__")) (EVar "n"))) (DoExpr (EIf (EApp (EApp (EVar "has") (EVar "n")) (EVar "defined")) (EVar "n") (EIf (EApp (EApp (EVar "has") (EVar "mangled")) (EVar "defined")) (EVar "mangled") (EVar "n"))))))
(DTypeSig false "memoRootNames" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "memoRootNames" ((PVar "groups")) (EApp (EApp (EMethodRef "map") (EVar "bindKey")) (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EApp (EApp (EVar "startsWith") (ELit (LString "$memo_"))) (EApp (EVar "bindKey") (EVar "b"))))) (EVar "groups"))))
(DTypeSig false "refGraph" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "refGraph" ((PVar "defined") (PVar "groups") (PVar "impls")) (EBlock (DoLet false false (PVar "g") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "forEachU") (ELam ((PVar "b")) (EApp (EApp (EApp (EVar "addBindEdges") (EVar "defined")) (EVar "g")) (EVar "b")))) (EVar "groups"))) (DoLet false false PWild (EApp (EApp (EVar "forEachU") (ELam ((PVar "e")) (EApp (EApp (EApp (EVar "addImplEdges") (EVar "defined")) (EVar "g")) (EVar "e")))) (EVar "impls"))) (DoExpr (EVar "g"))))
(DTypeSig false "addBindEdges" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "CBind") (TyCon "Unit")))))
(DFunDef false "addBindEdges" ((PVar "defined") (PVar "g") (PCon "CBind" (PVar "name") (PVar "clauses"))) (EApp (EApp (EApp (EApp (EVar "addEdges") (EVar "defined")) (EVar "g")) (EVar "name")) (EApp (EApp (EDictApp "flatMap") (EVar "refsClause")) (EVar "clauses"))))
(DTypeSig false "addImplEdges" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "CImplEntry") (TyCon "Unit")))))
(DFunDef false "addImplEdges" ((PVar "defined") (PVar "g") (PCon "CImplEntry" (PVar "method") PWild (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "addEdges") (EVar "defined")) (EVar "g")) (EVar "method")) (EApp (EVar "refsImplBody") (EVar "body"))))
(DTypeSig false "addEdges" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "addEdges" ((PVar "defined") (PVar "g") (PVar "key") (PVar "refs")) (EApp (EApp (EApp (EVar "setInPlace") (EVar "key")) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EApp (EVar "canonKey") (EVar "defined"))) (EVar "refs")) (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "key")) (EVar "g")))) (EVar "g")))
(DTypeSig false "closure" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "closure" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "closure" ((PVar "graph") (PVar "seen") (PCons (PVar "w") (PVar "work"))) (EIf (EApp (EApp (EVar "has") (EVar "w")) (EVar "seen")) (EApp (EApp (EApp (EVar "closure") (EVar "graph")) (EVar "seen")) (EVar "work")) (EIf (EVar "otherwise") (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EVar "w")) (ELit LUnit)) (EVar "seen"))) (DoExpr (EApp (EApp (EApp (EVar "closure") (EVar "graph")) (EVar "seen")) (EBinOp "++" (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "w")) (EVar "graph")) (EVar "work"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "refsE" (TyFun (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "refsE" ((PCon "CLit" PWild)) (EListLit))
(DFunDef false "refsE" ((PCon "CVar" (PVar "x") PWild)) (EListLit (EVar "x")))
(DFunDef false "refsE" ((PCon "CApp" (PVar "f") (PVar "a"))) (EBinOp "++" (EApp (EVar "refsE") (EVar "f")) (EApp (EVar "refsE") (EVar "a"))))
(DFunDef false "refsE" ((PCon "CLam" PWild (PVar "body"))) (EApp (EVar "refsE") (EVar "body")))
(DFunDef false "refsE" ((PCon "CLet" PWild PWild (PVar "e1") (PVar "e2"))) (EBinOp "++" (EApp (EVar "refsE") (EVar "e1")) (EApp (EVar "refsE") (EVar "e2"))))
(DFunDef false "refsE" ((PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "refsBind")) (EVar "binds")) (EApp (EVar "refsE") (EVar "body"))))
(DFunDef false "refsE" ((PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EBinOp "++" (EApp (EVar "refsE") (EVar "scrut")) (EApp (EApp (EDictApp "flatMap") (EVar "refsArm")) (EVar "arms"))))
(DFunDef false "refsE" ((PCon "CDecision" (PVar "scrut") (PVar "arms") PWild)) (EBinOp "++" (EApp (EVar "refsE") (EVar "scrut")) (EApp (EApp (EDictApp "flatMap") (EVar "refsArm")) (EVar "arms"))))
(DFunDef false "refsE" ((PCon "CIf" (PVar "c") (PVar "t") (PVar "f"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "refsE") (EVar "c")) (EApp (EVar "refsE") (EVar "t"))) (EApp (EVar "refsE") (EVar "f"))))
(DFunDef false "refsE" ((PCon "CBinPrim" PWild (PVar "l") (PVar "r") PWild)) (EBinOp "++" (EApp (EVar "refsE") (EVar "l")) (EApp (EVar "refsE") (EVar "r"))))
(DFunDef false "refsE" ((PCon "CUnOp" PWild (PVar "x"))) (EApp (EVar "refsE") (EVar "x")))
(DFunDef false "refsE" ((PCon "CTuple" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EVar "refsE")) (EVar "es")))
(DFunDef false "refsE" ((PCon "CList" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EVar "refsE")) (EVar "es")))
(DFunDef false "refsE" ((PCon "CRecord" PWild (PVar "fields"))) (EApp (EApp (EDictApp "flatMap") (EVar "refsField")) (EVar "fields")))
(DFunDef false "refsE" ((PCon "CFieldAccess" (PVar "e") PWild PWild)) (EApp (EVar "refsE") (EVar "e")))
(DFunDef false "refsE" ((PCon "CRecordUpdate" PWild (PVar "base") (PVar "updates"))) (EBinOp "++" (EApp (EVar "refsE") (EVar "base")) (EApp (EApp (EDictApp "flatMap") (EVar "refsField")) (EVar "updates"))))
(DFunDef false "refsE" ((PCon "CVariantUpdate" PWild (PVar "base") (PVar "updates"))) (EBinOp "++" (EApp (EVar "refsE") (EVar "base")) (EApp (EApp (EDictApp "flatMap") (EVar "refsField")) (EVar "updates"))))
(DFunDef false "refsE" ((PCon "CArray" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EVar "refsE")) (EVar "es")))
(DFunDef false "refsE" ((PCon "CRangeList" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EVar "refsE") (EVar "lo")) (EApp (EVar "refsE") (EVar "hi"))))
(DFunDef false "refsE" ((PCon "CRangeArray" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EVar "refsE") (EVar "lo")) (EApp (EVar "refsE") (EVar "hi"))))
(DFunDef false "refsE" ((PCon "CIndex" (PVar "a") (PVar "i"))) (EBinOp "++" (EApp (EVar "refsE") (EVar "a")) (EApp (EVar "refsE") (EVar "i"))))
(DFunDef false "refsE" ((PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EVar "refsE") (EVar "a")) (EApp (EVar "refsE") (EVar "lo"))) (EApp (EVar "refsE") (EVar "hi"))))
(DFunDef false "refsE" ((PCon "CStringIndex" (PVar "a") (PVar "i"))) (EBinOp "++" (EApp (EVar "refsE") (EVar "a")) (EApp (EVar "refsE") (EVar "i"))))
(DFunDef false "refsE" ((PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EVar "refsE") (EVar "a")) (EApp (EVar "refsE") (EVar "lo"))) (EApp (EVar "refsE") (EVar "hi"))))
(DFunDef false "refsE" ((PCon "CListIndex" (PVar "a") (PVar "i"))) (EBinOp "++" (EApp (EVar "refsE") (EVar "a")) (EApp (EVar "refsE") (EVar "i"))))
(DFunDef false "refsE" ((PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EVar "refsE") (EVar "a")) (EApp (EVar "refsE") (EVar "lo"))) (EApp (EVar "refsE") (EVar "hi"))))
(DFunDef false "refsE" ((PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EDictApp "flatMap") (EVar "refsStmt")) (EVar "stmts")))
(DFunDef false "refsE" ((PCon "CMethod" (PVar "name") (PVar "route") (PVar "implRoutes") (PVar "methRoutes"))) (EBinOp "::" (EVar "name") (EApp (EApp (EDictApp "flatMap") (EVar "refsRoute")) (EBinOp "::" (EVar "route") (EBinOp "++" (EVar "implRoutes") (EVar "methRoutes"))))))
(DFunDef false "refsE" ((PCon "CDict" (PVar "name") (PVar "routes"))) (EBinOp "::" (EVar "name") (EApp (EApp (EDictApp "flatMap") (EVar "refsRoute")) (EVar "routes"))))
(DTypeSig false "refsRoute" (TyFun (TyCon "Route") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "refsRoute" ((PCon "RNone")) (EListLit))
(DFunDef false "refsRoute" ((PCon "RKey" PWild (PVar "reqs"))) (EApp (EApp (EDictApp "flatMap") (EVar "refsRoute")) (EVar "reqs")))
(DFunDef false "refsRoute" ((PCon "RDict" PWild)) (EListLit))
(DFunDef false "refsRoute" ((PCon "RDictFwd" PWild)) (EListLit))
(DFunDef false "refsRoute" ((PCon "RLocal" (PVar "sym") (PVar "reqs"))) (EBinOp "::" (EVar "sym") (EApp (EApp (EDictApp "flatMap") (EVar "refsRoute")) (EVar "reqs"))))
(DFunDef false "refsRoute" ((PCon "RScalar" PWild)) (EListLit))
(DTypeSig false "refsBind" (TyFun (TyCon "CBind") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "refsBind" ((PCon "CBind" PWild (PVar "clauses"))) (EApp (EApp (EDictApp "flatMap") (EVar "refsClause")) (EVar "clauses")))
(DTypeSig false "refsClause" (TyFun (TyCon "CClause") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "refsClause" ((PCon "CClause" PWild (PVar "body"))) (EApp (EVar "refsE") (EVar "body")))
(DTypeSig false "refsArm" (TyFun (TyCon "CArm") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "refsArm" ((PCon "CArm" PWild (PVar "guards") (PVar "body"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "refsGuard")) (EVar "guards")) (EApp (EVar "refsE") (EVar "body"))))
(DTypeSig false "refsGuard" (TyFun (TyCon "CGuard") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "refsGuard" ((PCon "CGBool" (PVar "e"))) (EApp (EVar "refsE") (EVar "e")))
(DFunDef false "refsGuard" ((PCon "CGBind" PWild (PVar "e"))) (EApp (EVar "refsE") (EVar "e")))
(DTypeSig false "refsStmt" (TyFun (TyCon "CStmt") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "refsStmt" ((PCon "CSExpr" (PVar "e"))) (EApp (EVar "refsE") (EVar "e")))
(DFunDef false "refsStmt" ((PCon "CSLet" PWild PWild (PVar "e"))) (EApp (EVar "refsE") (EVar "e")))
(DFunDef false "refsStmt" ((PCon "CSAssign" PWild (PVar "e"))) (EApp (EVar "refsE") (EVar "e")))
(DTypeSig false "refsField" (TyFun (TyCon "CField") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "refsField" ((PCon "CField" PWild (PVar "e"))) (EApp (EVar "refsE") (EVar "e")))
(DTypeSig false "refsImplBody" (TyFun (TyCon "CImplBody") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "refsImplBody" ((PCon "CImplTagged" PWild PWild PWild PWild PWild (PVar "body"))) (EApp (EVar "refsE") (EVar "body")))
(DFunDef false "refsImplBody" ((PCon "CImplDefault" PWild PWild (PVar "body"))) (EApp (EVar "refsE") (EVar "body")))
