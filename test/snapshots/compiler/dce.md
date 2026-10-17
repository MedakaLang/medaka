# META
source_lines=278
stages=DESUGAR,MARK
# SOURCE
-- DEAD-CODE ELIMINATION for the native LLVM emit path (Stage 3 #2a).
--
-- WHY: `medaka build` could only load an EMPTY prelude, because emitting the real
-- `stdlib/core.mdk` aborts: its `maximum`/`minimum`/`clamp` reference the open
-- `max`/`min` arg-tag-dispatch gap (EMITTER-GAPS.md residual #2), and the emitter
-- emits EVERY top-level binding whether or not the program reaches it — so an
-- unreached-but-gapped prelude function aborts the whole build.  DCE drops the
-- unreached plain functions before lowering, clearing the prelude for programs
-- that never actually call `maximum`/`minimum`/`clamp`.
--
-- SOUNDNESS (the one thing not to get wrong): Medaka dispatches typeclass methods
-- by RUNTIME dict-passing, so an `impl` is reached through dynamic dispatch, NOT
-- the static call graph.  Naive call-graph DCE that drops an "unreferenced" impl
-- would be a silent miscompile.  So this is the CONSERVATIVE sound rule:
--
--   * RETAIN every non-`DFunDef` decl untouched — all DImpl, DInterface, DData,
--     DTypeSig, DExtern, DUse, DEffect, DTypeAlias, DNewtype, DLetGroup,
--     DProp/DTest, DAttrib.  Impls and interface defaults are kept WHOLE.
--   * Eliminate ONLY plain top-level `DFunDef` bindings unreachable from the roots.
--
-- ROOTS = `main` + the references of every EMITTING decl that is not a plain
-- function: impl-method bodies and interface-default bodies (the only other decls
-- `core_ir_lower` lowers to code — `funClausesOf` pulls just DFunDef, `lowerImpls`
-- just DImpl/DInterface).  DProp/DTest bodies do NOT emit, so they are NOT
-- roots — that is exactly what lets `clamp` (referenced only by a core prop) drop.
-- Reachability is the transitive closure of those roots over DFunDef bodies.
--
-- DETERMINISM: the output preserves the input decl order (we filter in place), so
-- the emitted IR stays byte-stable (required for the C3 IR1==IR2 fixpoint).
--
-- This is intentionally a REACHABILITY FILTER on the flattened, elaborated decl
-- list, applied in the emit drivers only (runEmit), so the oracle/golden dumps and
-- the eval pipeline are unaffected.  The target check reads the same reach,
-- without filtering anything, through `reachedExternChains`.

import frontend.ast.{Decl(..), ExternDecl(..), letBindName}
import frontend.marker.{declRefs}
import types.private_mangle.{scopeUnitNames}
import hash_map.{HashMap, new, fromList, setInPlace, has, findWithDefault, get}
import list.{zip}

-- ── entry point ────────────────────────────────────────────────────────────
-- Filter `decls` (the flattened, elaborated whole-program decl list) to retain
-- every non-DFunDef decl plus the DFunDefs reachable from main + impls/interfaces.
export
dceFilter : List Decl -> List Decl
dceFilter decls = filterReachable (reachableNames decls) decls

-- Each `DExtern` of `modules` that a reached decl refers to, as its module and
-- declared name, in declaration order, with the names that reach it: the root
-- first (`main`, or a name an impl method, interface default or top-level let
-- group refers to), the extern last.  An extern is never a root, so it is
-- reached only through a reference, and the reach is `dceFilter`'s, over the
-- program with every top-level name scoped by its module
-- (`types.private_mangle.scopeUnitNames`): a reference reaches the declaration
-- it resolves to through any import form, and not a same-named declaration of
-- another module or a local binder.  `builtins`, when given, is a module every
-- unit sees without an import (`scopeUnitNames`), and its externs are reported
-- under its module name.
export
reachedExternChains : Option (String, List Decl) ->
  List Decl ->
  List (String, List Decl) ->
  List ((String, String), List String)
reachedExternChains builtins core modules =
  map
    ((key, route) => (key, map snd route))
    (reachedExternRoutes builtins core modules)

-- The same chains with each name's module, `""` for a name no module of the
-- program declares (a prelude binding).
export
reachedExternRoutes : Option (String, List Decl) ->
  List Decl ->
  List (String, List Decl) ->
  List ((String, String), List (String, String))
reachedExternRoutes builtins core modules =
  let units = match builtins
    Some b => b :: modules
    None => modules
  let (scopedCore, scopedModules) = scopeUnitNames builtins core modules
  let reach = reachableNames (scopedCore ++ flatMap snd scopedModules)
  let pairs =
    flatMap
      (((mid, ds), (_, scoped)) => map (p => (mid, p)) (zip ds scoped))
      (zip units scopedModules)
  let declared =
    fromList
      (flatMap
        ((mid, (d, s)) => map ((sc, n) => (sc, (mid, n))) (scopedNames d s))
        pairs)
  filterMap (externChain reach declared) pairs

-- Each top-level name of a scoped declaration, with the name its source
-- declaration `d` wrote.
scopedNames : Decl -> Decl -> List (String, String)
scopedNames (DAttrib _ d) (DAttrib _ s) = scopedNames d s
scopedNames (DFunDef _ n _ _ _ _) (DFunDef _ scoped _ _ _ _) = [(scoped, n)]
scopedNames (DExtern ed) (DExtern scoped) = [(scoped.edName, ed.edName)]
scopedNames (DLetGroup _ bs) (DLetGroup _ scoped) =
  zip (map letBindName scoped) (map letBindName bs)
scopedNames _ _ = []

externChain : HashMap String String ->
  HashMap String (String, String) ->
  (String, (Decl, Decl)) ->
  Option ((String, String), List (String, String))
externChain reach declared (mid, (DAttrib _ d, DAttrib _ s)) =
  externChain reach declared (mid, (d, s))
externChain reach declared (mid, (DExtern ed, DExtern scoped)) =
  if has scoped.edName reach then
    Some (
      (mid, ed.edName),
      map
        (n => findWithDefault ("", n) n declared)
        (chainTo reach scoped.edName []),
    )
  else
    None
externChain _ _ _ = None

-- The names from the root to `n`, following each name to the one it was
-- first reached from.
chainTo : HashMap String String -> String -> List String -> List String
chainTo reach n acc = match get n reach
  Some "" => n :: acc
  Some from => chainTo reach from (n :: acc)
  None => n :: acc

-- Drop only unreachable DFunDefs; keep everything else verbatim, in order.
-- `reach` is a HashMap-as-set, so `has` is O(1) average and this is O(#decls).
filterReachable : HashMap String String -> List Decl -> List Decl
filterReachable _ [] = []
filterReachable reach ((DFunDef pub n ps body site bid) :: rest)
  | has n reach = DFunDef pub n ps body site bid :: filterReachable reach rest
  | otherwise = filterReachable reach rest
filterReachable reach (d :: rest) = d :: filterReachable reach rest

-- ── prelude-reference canonicalization (a mangle-first accommodation) ────────
-- An emit driver that runs `mangleUnits` BEFORE `elaborateModules` renames
-- every prelude definition to `core__<name>`, while `elaborateModules` SYNTHESIZES
-- bare references AFTERWARDS — notably the `/=` rewrite (typecheck.mdk
-- binopMethodApp builds `EApp (EVar "not") …`).  Such a bare name (`not`) does not
-- match its mangled definition (`core__not`) by string equality, so a naive
-- reachability walk treats the def as unreached and DCE DROPS it → the emitter
-- aborts `unbound variable 'not'` (and `canonFnName` in the emitter cannot recover
-- a def that was never emitted).  The bridge below is that repair: a referenced
-- bare name that is not itself a defined fn but whose `core__`-mangled form IS
-- resolves to the mangled def, mirroring the emitter's `canonFnName` so
-- reachability and emission agree.
-- Since #2809 the emit drivers elaborate FIRST and mangle the elaborated trees, so
-- a synthesized bare reference is renamed with everything else and arrives here
-- already spelled `core__not`: the defect this bridges cannot arise on the emit
-- path any more.  It is accommodation 12 of the census in
-- `compiler/TYPECHECK-TARGET-ARCHITECTURE.md` SA-10a item 20 — four mirrored copies
-- of one canonicalization (here, `llvm_emit.canonFnName`, `wasm_emit.canonFn`,
-- `wasm_reach`) — and retires with it; each copy owes its own measurement of which
-- callers still reach it, so none is deleted here.
canonRef : HashMap String Unit -> String -> String
canonRef defined n
  | has n defined = n
  | has ("core__" ++ n) defined = "core__" ++ n
  | otherwise = n

-- set of all DFunDef names defined in the program (the only DCE-droppable decls).
definedFnNames : List Decl -> HashMap String Unit
definedFnNames decls =
  let s = new ()
  let _ = definedFnNamesInto decls s
  s

definedFnNamesInto : List Decl -> HashMap String Unit -> Unit
definedFnNamesInto [] _ = ()
-- #1037: `@deprecated "…"` written directly on a DEFINITION (no separate signature
-- line) parses to `DAttrib attrs (DFunDef …)`, which these two walks skipped —
-- so the fn was neither in `defined` nor in the call graph, and a helper it alone
-- called was DCE'd: `medaka build` died with `unbound variable '<helper>'` on a
-- program `check` and `medaka run` both accept.  (Write the attribute above a
-- SIGNATURE instead and it wraps the DSig, leaving the DFunDef bare — which is why
-- this only reproduces on the no-signature form.)
definedFnNamesInto ((DAttrib _ d) :: rest) s = definedFnNamesInto (d :: rest) s
definedFnNamesInto ((DFunDef _ n _ _ _ _) :: rest) s =
  let _ = setInPlace n () s
  definedFnNamesInto rest s
definedFnNamesInto (_ :: rest) s = definedFnNamesInto rest s

-- ── reachability ───────────────────────────────────────────────────────────
-- Transitive closure of the roots over the DFunDef call graph, as a map from
-- each reached name to the name it was first reached from (`""` for a root).
-- O(1)-average membership + O(1) graph lookup keep it ~O(reachable + edges).
reachableNames : List Decl -> HashMap String String
reachableNames decls =
  let defined = definedFnNames decls
  let graph = funGraph defined decls
  let seen = new ()
  let _ = closure graph seen [
    ("", map (canonRef defined) ("main" :: emittingRoots decls)),
  ]
  seen

-- name -> refs(body) as a HashMap (multi-clause defs merged). O(1)
-- setInPlace/get; replaces the old O(N²) assoc-list `addRefs`. Ref-list order
-- decides only which first reach a name records, never whether it is reached.
-- Each ref is canonicalized against the defined set so a post-mangle bare
-- prelude reference (`not`) resolves to `core__not`.
funGraph : HashMap String Unit -> List Decl -> HashMap String (List String)
funGraph defined decls =
  let g = new ()
  let _ = funGraphInto defined decls g
  g

funGraphInto : HashMap String Unit ->
  List Decl ->
  HashMap String (List String) ->
  Unit
funGraphInto _ [] _ = ()
-- #1037: see definedFnNamesInto — an attributed definition must still contribute
-- its call-graph edges.
funGraphInto defined ((DAttrib _ d) :: rest) g =
  funGraphInto defined (d :: rest) g
funGraphInto defined ((DFunDef _ n ps body site bid) :: rest) g =
  let _ =
    setInPlace
      n
      (map (canonRef defined) (declRefs (DFunDef False n ps body site bid))
        ++ findWithDefault [] n g)
      g
  funGraphInto defined rest g
funGraphInto defined (_ :: rest) g = funGraphInto defined rest g

-- roots from emitting non-DFunDef decls: impl-method + interface-default bodies.
-- (declRefs walks an impl's method bodies / an interface's default bodies; it is
-- empty for every other non-FunDef decl EXCEPT DProp/DTest — which DO NOT
-- emit code — so those are excluded here to keep prop-only refs like `clamp` from
-- becoming roots.)
emittingRoots : List Decl -> List String
emittingRoots [] = []
emittingRoots (d :: rest)
  | isEmittingDecl d = declRefs d ++ emittingRoots rest
  | otherwise = emittingRoots rest

-- DImpl / DInterface lower to emitted code among the non-DFunDef decls.
-- DLetGroup also lowers to emitted code (funClausesOf/lowerGroups in core_ir_lower)
-- so its refs must seed reachability, or DFunDefs called only from a let-group are DCE'd.
--
-- #1037: a decl ATTRIBUTE wraps the decl (`DAttrib attrs <impl>`), and this said
-- False for it — so an attributed impl's method bodies seeded NO roots and any
-- helper called only from there was DCE'd out from under the emitter.  That was
-- latent while `lowerDeclImpl` skipped attributed impls entirely (no body was
-- emitted to dangle); the moment it stopped skipping them, an un-rooted attributed
-- impl would have become `unbound variable '<helper>'` at build time.  `declRefs`
-- (marker.mdk) already peels DAttrib, so this is the only half that was missing.
isEmittingDecl : Decl -> Bool
isEmittingDecl (DAttrib _ d) = isEmittingDecl d
isEmittingDecl (DImpl { ... }) = True
isEmittingDecl (DInterface { ... }) = True
isEmittingDecl (DLetGroup _ _) = True
isEmittingDecl _ = False

-- ── worklist closure ───────────────────────────────────────────────────────
-- Depth-first over the call graph.  The stack holds, per name being expanded,
-- that name and its refs still to visit.  Each unseen name is inserted into
-- `seen` with the name that reached it, so every name is inserted once →
-- O(reachable + edges) with O(1)-average membership and O(1) graph lookup.
closure : HashMap String (List String) ->
  HashMap String String ->
  List (String, List String) ->
  Unit
closure _ _ [] = ()
closure graph seen ((_, []) :: stack) = closure graph seen stack
closure graph seen ((from, w :: ws) :: stack)
  | has w seen = closure graph seen ((from, ws) :: stack)
  | otherwise =
    let _ = setInPlace w from seen
    closure graph seen ((w, refsOf graph w) :: (from, ws) :: stack)

refsOf : HashMap String (List String) -> String -> List String
refsOf graph n = findWithDefault [] n graph
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "ExternDecl" true) (mem "letBindName" false))))
(DUse false (UseGroup ("frontend" "marker") ((mem "declRefs" false))))
(DUse false (UseGroup ("types" "private_mangle") ((mem "scopeUnitNames" false))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false) (mem "fromList" false) (mem "setInPlace" false) (mem "has" false) (mem "findWithDefault" false) (mem "get" false))))
(DUse false (UseGroup ("list") ((mem "zip" false))))
(DTypeSig true "dceFilter" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "dceFilter" ((PVar "decls")) (EApp (EApp (EVar "filterReachable") (EApp (EVar "reachableNames") (EVar "decls"))) (EVar "decls")))
(DTypeSig true "reachedExternChains" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "reachedExternChains" ((PVar "builtins") (PVar "core") (PVar "modules")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "key") (PVar "route"))) (ETuple (EVar "key") (EApp (EApp (EVar "map") (EVar "snd")) (EVar "route"))))) (EApp (EApp (EApp (EVar "reachedExternRoutes") (EVar "builtins")) (EVar "core")) (EVar "modules"))))
(DTypeSig true "reachedExternRoutes" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))))
(DFunDef false "reachedExternRoutes" ((PVar "builtins") (PVar "core") (PVar "modules")) (EBlock (DoLet false false (PVar "units") (EMatch (EVar "builtins") (arm (PCon "Some" (PVar "b")) () (EBinOp "::" (EVar "b") (EVar "modules"))) (arm (PCon "None") () (EVar "modules")))) (DoLet false false (PTuple (PVar "scopedCore") (PVar "scopedModules")) (EApp (EApp (EApp (EVar "scopeUnitNames") (EVar "builtins")) (EVar "core")) (EVar "modules"))) (DoLet false false (PVar "reach") (EApp (EVar "reachableNames") (EBinOp "++" (EVar "scopedCore") (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "scopedModules"))))) (DoLet false false (PVar "pairs") (EApp (EApp (EVar "flatMap") (ELam ((PTuple (PTuple (PVar "mid") (PVar "ds")) (PTuple PWild (PVar "scoped")))) (EApp (EApp (EVar "map") (ELam ((PVar "p")) (ETuple (EVar "mid") (EVar "p")))) (EApp (EApp (EVar "zip") (EVar "ds")) (EVar "scoped"))))) (EApp (EApp (EVar "zip") (EVar "units")) (EVar "scopedModules")))) (DoLet false false (PVar "declared") (EApp (EVar "fromList") (EApp (EApp (EVar "flatMap") (ELam ((PTuple (PVar "mid") (PTuple (PVar "d") (PVar "s")))) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "sc") (PVar "n"))) (ETuple (EVar "sc") (ETuple (EVar "mid") (EVar "n"))))) (EApp (EApp (EVar "scopedNames") (EVar "d")) (EVar "s"))))) (EVar "pairs")))) (DoExpr (EApp (EApp (EVar "filterMap") (EApp (EApp (EVar "externChain") (EVar "reach")) (EVar "declared"))) (EVar "pairs")))))
(DTypeSig false "scopedNames" (TyFun (TyCon "Decl") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "scopedNames" ((PCon "DAttrib" PWild (PVar "d")) (PCon "DAttrib" PWild (PVar "s"))) (EApp (EApp (EVar "scopedNames") (EVar "d")) (EVar "s")))
(DFunDef false "scopedNames" ((PCon "DFunDef" PWild (PVar "n") PWild PWild PWild PWild) (PCon "DFunDef" PWild (PVar "scoped") PWild PWild PWild PWild)) (EListLit (ETuple (EVar "scoped") (EVar "n"))))
(DFunDef false "scopedNames" ((PCon "DExtern" (PVar "ed")) (PCon "DExtern" (PVar "scoped"))) (EListLit (ETuple (EFieldAccess (EVar "scoped") "edName") (EFieldAccess (EVar "ed") "edName"))))
(DFunDef false "scopedNames" ((PCon "DLetGroup" PWild (PVar "bs")) (PCon "DLetGroup" PWild (PVar "scoped"))) (EApp (EApp (EVar "zip") (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "scoped"))) (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "bs"))))
(DFunDef false "scopedNames" (PWild PWild) (EListLit))
(DTypeSig false "externChain" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyTuple (TyCon "String") (TyTuple (TyCon "Decl") (TyCon "Decl"))) (TyApp (TyCon "Option") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))))
(DFunDef false "externChain" ((PVar "reach") (PVar "declared") (PTuple (PVar "mid") (PTuple (PCon "DAttrib" PWild (PVar "d")) (PCon "DAttrib" PWild (PVar "s"))))) (EApp (EApp (EApp (EVar "externChain") (EVar "reach")) (EVar "declared")) (ETuple (EVar "mid") (ETuple (EVar "d") (EVar "s")))))
(DFunDef false "externChain" ((PVar "reach") (PVar "declared") (PTuple (PVar "mid") (PTuple (PCon "DExtern" (PVar "ed")) (PCon "DExtern" (PVar "scoped"))))) (EIf (EApp (EApp (EVar "has") (EFieldAccess (EVar "scoped") "edName")) (EVar "reach")) (EApp (EVar "Some") (ETuple (ETuple (EVar "mid") (EFieldAccess (EVar "ed") "edName")) (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EApp (EApp (EApp (EVar "findWithDefault") (ETuple (ELit (LString "")) (EVar "n"))) (EVar "n")) (EVar "declared")))) (EApp (EApp (EApp (EVar "chainTo") (EVar "reach")) (EFieldAccess (EVar "scoped") "edName")) (EListLit))))) (EVar "None")))
(DFunDef false "externChain" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "chainTo" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "chainTo" ((PVar "reach") (PVar "n") (PVar "acc")) (EMatch (EApp (EApp (EVar "get") (EVar "n")) (EVar "reach")) (arm (PCon "Some" (PLit (LString ""))) () (EBinOp "::" (EVar "n") (EVar "acc"))) (arm (PCon "Some" (PVar "from")) () (EApp (EApp (EApp (EVar "chainTo") (EVar "reach")) (EVar "from")) (EBinOp "::" (EVar "n") (EVar "acc")))) (arm (PCon "None") () (EBinOp "::" (EVar "n") (EVar "acc")))))
(DTypeSig false "filterReachable" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "filterReachable" (PWild (PList)) (EListLit))
(DFunDef false "filterReachable" ((PVar "reach") (PCons (PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "ps") (PVar "body") (PVar "site") (PVar "bid")) (PVar "rest"))) (EIf (EApp (EApp (EVar "has") (EVar "n")) (EVar "reach")) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "n")) (EVar "ps")) (EVar "body")) (EVar "site")) (EVar "bid")) (EApp (EApp (EVar "filterReachable") (EVar "reach")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "filterReachable") (EVar "reach")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "filterReachable" ((PVar "reach") (PCons (PVar "d") (PVar "rest"))) (EBinOp "::" (EVar "d") (EApp (EApp (EVar "filterReachable") (EVar "reach")) (EVar "rest"))))
(DTypeSig false "canonRef" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "canonRef" ((PVar "defined") (PVar "n")) (EIf (EApp (EApp (EVar "has") (EVar "n")) (EVar "defined")) (EVar "n") (EIf (EApp (EApp (EVar "has") (EBinOp "++" (ELit (LString "core__")) (EVar "n"))) (EVar "defined")) (EBinOp "++" (ELit (LString "core__")) (EVar "n")) (EIf (EVar "otherwise") (EVar "n") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "definedFnNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "definedFnNames" ((PVar "decls")) (EBlock (DoLet false false (PVar "s") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "definedFnNamesInto") (EVar "decls")) (EVar "s"))) (DoExpr (EVar "s"))))
(DTypeSig false "definedFnNamesInto" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyCon "Unit"))))
(DFunDef false "definedFnNamesInto" ((PList) PWild) (ELit LUnit))
(DFunDef false "definedFnNamesInto" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "s")) (EApp (EApp (EVar "definedFnNamesInto") (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "s")))
(DFunDef false "definedFnNamesInto" ((PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild PWild PWild) (PVar "rest")) (PVar "s")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EVar "n")) (ELit LUnit)) (EVar "s"))) (DoExpr (EApp (EApp (EVar "definedFnNamesInto") (EVar "rest")) (EVar "s")))))
(DFunDef false "definedFnNamesInto" ((PCons PWild (PVar "rest")) (PVar "s")) (EApp (EApp (EVar "definedFnNamesInto") (EVar "rest")) (EVar "s")))
(DTypeSig false "reachableNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String"))))
(DFunDef false "reachableNames" ((PVar "decls")) (EBlock (DoLet false false (PVar "defined") (EApp (EVar "definedFnNames") (EVar "decls"))) (DoLet false false (PVar "graph") (EApp (EApp (EVar "funGraph") (EVar "defined")) (EVar "decls"))) (DoLet false false (PVar "seen") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EVar "closure") (EVar "graph")) (EVar "seen")) (EListLit (ETuple (ELit (LString "")) (EApp (EApp (EVar "map") (EApp (EVar "canonRef") (EVar "defined"))) (EBinOp "::" (ELit (LString "main")) (EApp (EVar "emittingRoots") (EVar "decls")))))))) (DoExpr (EVar "seen"))))
(DTypeSig false "funGraph" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "funGraph" ((PVar "defined") (PVar "decls")) (EBlock (DoLet false false (PVar "g") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EVar "funGraphInto") (EVar "defined")) (EVar "decls")) (EVar "g"))) (DoExpr (EVar "g"))))
(DTypeSig false "funGraphInto" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Unit")))))
(DFunDef false "funGraphInto" (PWild (PList) PWild) (ELit LUnit))
(DFunDef false "funGraphInto" ((PVar "defined") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "g")) (EApp (EApp (EApp (EVar "funGraphInto") (EVar "defined")) (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "g")))
(DFunDef false "funGraphInto" ((PVar "defined") (PCons (PCon "DFunDef" PWild (PVar "n") (PVar "ps") (PVar "body") (PVar "site") (PVar "bid")) (PVar "rest")) (PVar "g")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EVar "n")) (EBinOp "++" (EApp (EApp (EVar "map") (EApp (EVar "canonRef") (EVar "defined"))) (EApp (EVar "declRefs") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "False")) (EVar "n")) (EVar "ps")) (EVar "body")) (EVar "site")) (EVar "bid")))) (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "n")) (EVar "g")))) (EVar "g"))) (DoExpr (EApp (EApp (EApp (EVar "funGraphInto") (EVar "defined")) (EVar "rest")) (EVar "g")))))
(DFunDef false "funGraphInto" ((PVar "defined") (PCons PWild (PVar "rest")) (PVar "g")) (EApp (EApp (EApp (EVar "funGraphInto") (EVar "defined")) (EVar "rest")) (EVar "g")))
(DTypeSig false "emittingRoots" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "emittingRoots" ((PList)) (EListLit))
(DFunDef false "emittingRoots" ((PCons (PVar "d") (PVar "rest"))) (EIf (EApp (EVar "isEmittingDecl") (EVar "d")) (EBinOp "++" (EApp (EVar "declRefs") (EVar "d")) (EApp (EVar "emittingRoots") (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EVar "emittingRoots") (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isEmittingDecl" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isEmittingDecl" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "isEmittingDecl") (EVar "d")))
(DFunDef false "isEmittingDecl" ((PRec "DImpl" () true)) (EVar "True"))
(DFunDef false "isEmittingDecl" ((PRec "DInterface" () true)) (EVar "True"))
(DFunDef false "isEmittingDecl" ((PCon "DLetGroup" PWild PWild)) (EVar "True"))
(DFunDef false "isEmittingDecl" (PWild) (EVar "False"))
(DTypeSig false "closure" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Unit")))))
(DFunDef false "closure" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "closure" ((PVar "graph") (PVar "seen") (PCons (PTuple PWild (PList)) (PVar "stack"))) (EApp (EApp (EApp (EVar "closure") (EVar "graph")) (EVar "seen")) (EVar "stack")))
(DFunDef false "closure" ((PVar "graph") (PVar "seen") (PCons (PTuple (PVar "from") (PCons (PVar "w") (PVar "ws"))) (PVar "stack"))) (EIf (EApp (EApp (EVar "has") (EVar "w")) (EVar "seen")) (EApp (EApp (EApp (EVar "closure") (EVar "graph")) (EVar "seen")) (EBinOp "::" (ETuple (EVar "from") (EVar "ws")) (EVar "stack"))) (EIf (EVar "otherwise") (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EVar "w")) (EVar "from")) (EVar "seen"))) (DoExpr (EApp (EApp (EApp (EVar "closure") (EVar "graph")) (EVar "seen")) (EBinOp "::" (ETuple (EVar "w") (EApp (EApp (EVar "refsOf") (EVar "graph")) (EVar "w"))) (EBinOp "::" (ETuple (EVar "from") (EVar "ws")) (EVar "stack")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "refsOf" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "refsOf" ((PVar "graph") (PVar "n")) (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "n")) (EVar "graph")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "ExternDecl" true) (mem "letBindName" false))))
(DUse false (UseGroup ("frontend" "marker") ((mem "declRefs" false))))
(DUse false (UseGroup ("types" "private_mangle") ((mem "scopeUnitNames" false))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false) (mem "fromList" false) (mem "setInPlace" false) (mem "has" false) (mem "findWithDefault" false) (mem "get" false))))
(DUse false (UseGroup ("list") ((mem "zip" false))))
(DTypeSig true "dceFilter" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "dceFilter" ((PVar "decls")) (EApp (EApp (EVar "filterReachable") (EApp (EVar "reachableNames") (EVar "decls"))) (EVar "decls")))
(DTypeSig true "reachedExternChains" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "reachedExternChains" ((PVar "builtins") (PVar "core") (PVar "modules")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "key") (PVar "route"))) (ETuple (EVar "key") (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "route"))))) (EApp (EApp (EApp (EVar "reachedExternRoutes") (EVar "builtins")) (EVar "core")) (EVar "modules"))))
(DTypeSig true "reachedExternRoutes" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))))
(DFunDef false "reachedExternRoutes" ((PVar "builtins") (PVar "core") (PVar "modules")) (EBlock (DoLet false false (PVar "units") (EMatch (EVar "builtins") (arm (PCon "Some" (PVar "b")) () (EBinOp "::" (EVar "b") (EVar "modules"))) (arm (PCon "None") () (EVar "modules")))) (DoLet false false (PTuple (PVar "scopedCore") (PVar "scopedModules")) (EApp (EApp (EApp (EVar "scopeUnitNames") (EVar "builtins")) (EVar "core")) (EVar "modules"))) (DoLet false false (PVar "reach") (EApp (EVar "reachableNames") (EBinOp "++" (EVar "scopedCore") (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "scopedModules"))))) (DoLet false false (PVar "pairs") (EApp (EApp (EDictApp "flatMap") (ELam ((PTuple (PTuple (PVar "mid") (PVar "ds")) (PTuple PWild (PVar "scoped")))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (ETuple (EVar "mid") (EVar "p")))) (EApp (EApp (EVar "zip") (EVar "ds")) (EVar "scoped"))))) (EApp (EApp (EVar "zip") (EVar "units")) (EVar "scopedModules")))) (DoLet false false (PVar "declared") (EApp (EVar "fromList") (EApp (EApp (EDictApp "flatMap") (ELam ((PTuple (PVar "mid") (PTuple (PVar "d") (PVar "s")))) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "sc") (PVar "n"))) (ETuple (EVar "sc") (ETuple (EVar "mid") (EVar "n"))))) (EApp (EApp (EVar "scopedNames") (EVar "d")) (EVar "s"))))) (EVar "pairs")))) (DoExpr (EApp (EApp (EMethodRef "filterMap") (EApp (EApp (EVar "externChain") (EVar "reach")) (EVar "declared"))) (EVar "pairs")))))
(DTypeSig false "scopedNames" (TyFun (TyCon "Decl") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "scopedNames" ((PCon "DAttrib" PWild (PVar "d")) (PCon "DAttrib" PWild (PVar "s"))) (EApp (EApp (EVar "scopedNames") (EVar "d")) (EVar "s")))
(DFunDef false "scopedNames" ((PCon "DFunDef" PWild (PVar "n") PWild PWild PWild PWild) (PCon "DFunDef" PWild (PVar "scoped") PWild PWild PWild PWild)) (EListLit (ETuple (EVar "scoped") (EVar "n"))))
(DFunDef false "scopedNames" ((PCon "DExtern" (PVar "ed")) (PCon "DExtern" (PVar "scoped"))) (EListLit (ETuple (EFieldAccess (EVar "scoped") "edName") (EFieldAccess (EVar "ed") "edName"))))
(DFunDef false "scopedNames" ((PCon "DLetGroup" PWild (PVar "bs")) (PCon "DLetGroup" PWild (PVar "scoped"))) (EApp (EApp (EVar "zip") (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "scoped"))) (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "bs"))))
(DFunDef false "scopedNames" (PWild PWild) (EListLit))
(DTypeSig false "externChain" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyTuple (TyCon "String") (TyTuple (TyCon "Decl") (TyCon "Decl"))) (TyApp (TyCon "Option") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))))
(DFunDef false "externChain" ((PVar "reach") (PVar "declared") (PTuple (PVar "mid") (PTuple (PCon "DAttrib" PWild (PVar "d")) (PCon "DAttrib" PWild (PVar "s"))))) (EApp (EApp (EApp (EVar "externChain") (EVar "reach")) (EVar "declared")) (ETuple (EVar "mid") (ETuple (EVar "d") (EVar "s")))))
(DFunDef false "externChain" ((PVar "reach") (PVar "declared") (PTuple (PVar "mid") (PTuple (PCon "DExtern" (PVar "ed")) (PCon "DExtern" (PVar "scoped"))))) (EIf (EApp (EApp (EVar "has") (EFieldAccess (EVar "scoped") "edName")) (EVar "reach")) (EApp (EVar "Some") (ETuple (ETuple (EVar "mid") (EFieldAccess (EVar "ed") "edName")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EApp (EApp (EApp (EVar "findWithDefault") (ETuple (ELit (LString "")) (EVar "n"))) (EVar "n")) (EVar "declared")))) (EApp (EApp (EApp (EVar "chainTo") (EVar "reach")) (EFieldAccess (EVar "scoped") "edName")) (EListLit))))) (EVar "None")))
(DFunDef false "externChain" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "chainTo" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "chainTo" ((PVar "reach") (PVar "n") (PVar "acc")) (EMatch (EApp (EApp (EVar "get") (EVar "n")) (EVar "reach")) (arm (PCon "Some" (PLit (LString ""))) () (EBinOp "::" (EVar "n") (EVar "acc"))) (arm (PCon "Some" (PVar "from")) () (EApp (EApp (EApp (EVar "chainTo") (EVar "reach")) (EVar "from")) (EBinOp "::" (EVar "n") (EVar "acc")))) (arm (PCon "None") () (EBinOp "::" (EVar "n") (EVar "acc")))))
(DTypeSig false "filterReachable" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "filterReachable" (PWild (PList)) (EListLit))
(DFunDef false "filterReachable" ((PVar "reach") (PCons (PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "ps") (PVar "body") (PVar "site") (PVar "bid")) (PVar "rest"))) (EIf (EApp (EApp (EVar "has") (EVar "n")) (EVar "reach")) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "n")) (EVar "ps")) (EVar "body")) (EVar "site")) (EVar "bid")) (EApp (EApp (EVar "filterReachable") (EVar "reach")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "filterReachable") (EVar "reach")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "filterReachable" ((PVar "reach") (PCons (PVar "d") (PVar "rest"))) (EBinOp "::" (EVar "d") (EApp (EApp (EVar "filterReachable") (EVar "reach")) (EVar "rest"))))
(DTypeSig false "canonRef" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "canonRef" ((PVar "defined") (PVar "n")) (EIf (EApp (EApp (EVar "has") (EVar "n")) (EVar "defined")) (EVar "n") (EIf (EApp (EApp (EVar "has") (EBinOp "++" (ELit (LString "core__")) (EVar "n"))) (EVar "defined")) (EBinOp "++" (ELit (LString "core__")) (EVar "n")) (EIf (EVar "otherwise") (EVar "n") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "definedFnNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "definedFnNames" ((PVar "decls")) (EBlock (DoLet false false (PVar "s") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "definedFnNamesInto") (EVar "decls")) (EVar "s"))) (DoExpr (EVar "s"))))
(DTypeSig false "definedFnNamesInto" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyCon "Unit"))))
(DFunDef false "definedFnNamesInto" ((PList) PWild) (ELit LUnit))
(DFunDef false "definedFnNamesInto" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "s")) (EApp (EApp (EVar "definedFnNamesInto") (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "s")))
(DFunDef false "definedFnNamesInto" ((PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild PWild PWild) (PVar "rest")) (PVar "s")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EVar "n")) (ELit LUnit)) (EVar "s"))) (DoExpr (EApp (EApp (EVar "definedFnNamesInto") (EVar "rest")) (EVar "s")))))
(DFunDef false "definedFnNamesInto" ((PCons PWild (PVar "rest")) (PVar "s")) (EApp (EApp (EVar "definedFnNamesInto") (EVar "rest")) (EVar "s")))
(DTypeSig false "reachableNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String"))))
(DFunDef false "reachableNames" ((PVar "decls")) (EBlock (DoLet false false (PVar "defined") (EApp (EVar "definedFnNames") (EVar "decls"))) (DoLet false false (PVar "graph") (EApp (EApp (EVar "funGraph") (EVar "defined")) (EVar "decls"))) (DoLet false false (PVar "seen") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EVar "closure") (EVar "graph")) (EVar "seen")) (EListLit (ETuple (ELit (LString "")) (EApp (EApp (EMethodRef "map") (EApp (EVar "canonRef") (EVar "defined"))) (EBinOp "::" (ELit (LString "main")) (EApp (EVar "emittingRoots") (EVar "decls")))))))) (DoExpr (EVar "seen"))))
(DTypeSig false "funGraph" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "funGraph" ((PVar "defined") (PVar "decls")) (EBlock (DoLet false false (PVar "g") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EVar "funGraphInto") (EVar "defined")) (EVar "decls")) (EVar "g"))) (DoExpr (EVar "g"))))
(DTypeSig false "funGraphInto" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Unit")))))
(DFunDef false "funGraphInto" (PWild (PList) PWild) (ELit LUnit))
(DFunDef false "funGraphInto" ((PVar "defined") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "g")) (EApp (EApp (EApp (EVar "funGraphInto") (EVar "defined")) (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "g")))
(DFunDef false "funGraphInto" ((PVar "defined") (PCons (PCon "DFunDef" PWild (PVar "n") (PVar "ps") (PVar "body") (PVar "site") (PVar "bid")) (PVar "rest")) (PVar "g")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EVar "n")) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EApp (EVar "canonRef") (EVar "defined"))) (EApp (EVar "declRefs") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "False")) (EVar "n")) (EVar "ps")) (EVar "body")) (EVar "site")) (EVar "bid")))) (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "n")) (EVar "g")))) (EVar "g"))) (DoExpr (EApp (EApp (EApp (EVar "funGraphInto") (EVar "defined")) (EVar "rest")) (EVar "g")))))
(DFunDef false "funGraphInto" ((PVar "defined") (PCons PWild (PVar "rest")) (PVar "g")) (EApp (EApp (EApp (EVar "funGraphInto") (EVar "defined")) (EVar "rest")) (EVar "g")))
(DTypeSig false "emittingRoots" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "emittingRoots" ((PList)) (EListLit))
(DFunDef false "emittingRoots" ((PCons (PVar "d") (PVar "rest"))) (EIf (EApp (EVar "isEmittingDecl") (EVar "d")) (EBinOp "++" (EApp (EVar "declRefs") (EVar "d")) (EApp (EVar "emittingRoots") (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EVar "emittingRoots") (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isEmittingDecl" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isEmittingDecl" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "isEmittingDecl") (EVar "d")))
(DFunDef false "isEmittingDecl" ((PRec "DImpl" () true)) (EVar "True"))
(DFunDef false "isEmittingDecl" ((PRec "DInterface" () true)) (EVar "True"))
(DFunDef false "isEmittingDecl" ((PCon "DLetGroup" PWild PWild)) (EVar "True"))
(DFunDef false "isEmittingDecl" (PWild) (EVar "False"))
(DTypeSig false "closure" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Unit")))))
(DFunDef false "closure" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "closure" ((PVar "graph") (PVar "seen") (PCons (PTuple PWild (PList)) (PVar "stack"))) (EApp (EApp (EApp (EVar "closure") (EVar "graph")) (EVar "seen")) (EVar "stack")))
(DFunDef false "closure" ((PVar "graph") (PVar "seen") (PCons (PTuple (PVar "from") (PCons (PVar "w") (PVar "ws"))) (PVar "stack"))) (EIf (EApp (EApp (EVar "has") (EVar "w")) (EVar "seen")) (EApp (EApp (EApp (EVar "closure") (EVar "graph")) (EVar "seen")) (EBinOp "::" (ETuple (EVar "from") (EVar "ws")) (EVar "stack"))) (EIf (EVar "otherwise") (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EVar "w")) (EVar "from")) (EVar "seen"))) (DoExpr (EApp (EApp (EApp (EVar "closure") (EVar "graph")) (EVar "seen")) (EBinOp "::" (ETuple (EVar "w") (EApp (EApp (EVar "refsOf") (EVar "graph")) (EVar "w"))) (EBinOp "::" (ETuple (EVar "from") (EVar "ws")) (EVar "stack")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "refsOf" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "refsOf" ((PVar "graph") (PVar "n")) (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "n")) (EVar "graph")))
