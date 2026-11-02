# META
source_lines=544
stages=DESUGAR,MARK
# SOURCE
import support.symbol_encoding.{encodePair}
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
-- without filtering anything, through `reachedExternChains`, and for the
-- interpreter the narrower reach of what it evaluates (`dispatchedNames`).

import frontend.ast.{
  Decl(..),
  ExternDecl(..),
  LetBind,
  UsePath(..),
  ifaceMethodName,
  implMethodName,
  letBindName,
  useMemberAlias,
  useMemberOrigin,
}
import frontend.marker.{declRefs}
import types.private_mangle.{scopeUnitNames}
import hash_map.{HashMap, new, fromList, setInPlace, has, findWithDefault, get}
import list.{zip}
import support.util.{anyList, contains}

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
    (reachedExternRoutes EmittedRoots builtins core modules)

-- What a reach starts from.  `EmittedRoots` is what an emitter lowers whether
-- or not `main` calls it: `main`, and every impl method, interface default and
-- top-level let group (`reachableNames`).  `DispatchedRoots` is what the
-- interpreter evaluates: `main`, and an impl method or interface default only
-- once a reached name can dispatch to it (`dispatchedNames`); a top-level let
-- group is a binding like a function, reached when its binder is.
public export data ReachRoots = EmittedRoots | DispatchedRoots

-- The same chains with each name's module, `""` for a name no module of the
-- program declares (a prelude binding or a method name), reached from `roots`.
export
reachedExternRoutes : ReachRoots ->
  Option (String, List Decl) ->
  List Decl ->
  List (String, List Decl) ->
  List ((String, String), List (String, String))
reachedExternRoutes roots builtins core modules =
  let units = match builtins
    Some b => b :: modules
    None => modules
  let (scopedCore, scopedModules) = scopeUnitNames builtins core modules
  let reach = match roots
    EmittedRoots => reachableNames (scopedCore ++ flatMap snd scopedModules)
    DispatchedRoots => dispatchedNames scopedCore (flatMap snd scopedModules)
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
  | has (encodePair "core" n) defined = encodePair "core" n
  | otherwise = n

-- set of all DFunDef names defined in the program (the only DCE-droppable decls).
definedFnNames : List Decl -> HashMap String Unit
definedFnNames decls =
  let s = new ()
  definedFnNamesInto decls s
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
  setInPlace n () s
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
  closure graph seen [
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
  funGraphInto defined decls g
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
-- DLetGroup also lowers to emitted code (funClausesOf/lowerGroupsWith in core_ir_lower)
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

-- ── the interpreter's reach ────────────────────────────────────────────────
-- The interpreter installs every impl method and inherited default under its
-- bare method name and runs one only when a call names that method
-- (`eval.declImplEntries`, `eval.coalesceImpls`).  A top-level binding, a let
-- group's among them, is a deferred value or a closure, run only when
-- referenced, and only `main` is forced.  So the roots are `main` and, until
-- nothing new fires, the impls and defaults of each interface a module
-- declares, once a reached body of a module names one of its method names
-- (`methodSpellings`).  A prelude body is not consulted: its free names are its
-- own bindings and methods, and a local spelled like a method is not a call of
-- it.  The impls and defaults of a prelude interface, of an interface sharing
-- a method name with one (whose impls share its dispatcher), and of an
-- interface no unit declares are roots outright: an operator, an
-- interpolation, an index or a printed `main` dispatches to a prelude method
-- without naming it in this tree.
dispatchedNames : List Decl -> List Decl -> HashMap String String
dispatchedNames core modules =
  let decls = core ++ modules
  let defined = definedFnNames decls
  let graph = funGraph defined decls
  letGroupGraphInto defined decls graph
  let classify =
    dispatchOf
      (ifaceMethodTable core)
      (nameSet (flatMap declaredMethodNames core))
      (ifaceMethodTable modules)
      (methodSpellings (moduleAliases modules) (memberAliases modules))
  let moduleEntries = filterMap classify modules
  let moduleRoots = flatMap rootRefs moduleEntries
  let seen = new ()
  closure graph seen [
    (
      "",
      map
        (canonRef defined)
        ("main" :: flatMap entryRefs (filterMap classify core) ++ moduleRoots),
    ),
  ]
  dispatchUntilStable
    defined
    graph
    seen
    modules
    moduleRoots
    (filterMap onceNamed moduleEntries)
  seen

-- An impl or interface default as the interpreter reaches it: a root, with
-- its references, or one that fires once a reached body names one of the
-- spellings, with its references.
data DispatchEntry =
  | DispatchRoot (List String)
  | DispatchOnce (List String) (List String)

entryRefs : DispatchEntry -> List String
entryRefs (DispatchRoot refs) = refs
entryRefs (DispatchOnce _ refs) = refs

rootRefs : DispatchEntry -> List String
rootRefs (DispatchRoot refs) = refs
rootRefs (DispatchOnce _ _) = []

onceNamed : DispatchEntry -> Option (List String, List String)
onceNamed (DispatchRoot _) = None
onceNamed (DispatchOnce names refs) = Some (names, refs)

dispatchOf : HashMap String (List String) ->
  HashMap String Unit ->
  HashMap String (List String) ->
  (List String -> List String) ->
  Decl ->
  Option DispatchEntry
dispatchOf ifaces methods declared spell (DAttrib _ d) =
  dispatchOf ifaces methods declared spell d
dispatchOf ifaces methods declared spell (d@(DInterface { name, ... })) =
  Some (dispatchOn ifaces methods declared spell name [] (declRefs d))
dispatchOf ifaces methods declared spell (d@(DImpl { iface, methods = own, ... })) =
  Some
    (dispatchOn
      ifaces
      methods
      declared
      spell
      (bareIfaceName iface)
      (map implMethodName own)
      (declRefs d))
dispatchOf _ _ _ _ _ = None

-- `ifaces` and `methods` are the prelude's interfaces and method names,
-- `declared` the modules' interfaces.
dispatchOn : HashMap String (List String) ->
  HashMap String Unit ->
  HashMap String (List String) ->
  (List String -> List String) ->
  String ->
  List String ->
  List String ->
  DispatchEntry
dispatchOn ifaces methods declared spell iface own refs
  | has iface ifaces = DispatchRoot refs
  | otherwise = match get iface declared
    Some names =>
      if anyList (m => has m methods) (names ++ own) then
        DispatchRoot refs
      else
        DispatchOnce (spell (names ++ own)) refs
    None => DispatchRoot refs

-- An impl may name its interface qualified (`A.Iface`); interfaces are
-- matched by their declared name.
bareIfaceName : String -> String
bareIfaceName iface = match stringLastIndexOf "." iface
  Some i => stringSlice (i + 1) (stringLength iface) iface
  None => iface

-- Fire every pending entry one of whose spellings a reached module body, or a
-- fired or root impl of a module, names, from that spelling, until a round
-- fires none.  `named` holds the references of the impls fired so far.
dispatchUntilStable : HashMap String Unit ->
  HashMap String (List String) ->
  HashMap String String ->
  List Decl ->
  List String ->
  List (List String, List String) ->
  Unit
dispatchUntilStable defined graph seen modules named pending =
  let names = nameSet (flatMap (reachedRefs seen) modules ++ named)
  match filterMap (firedBy names) pending
    [] => ()
    fired =>
      closure
        graph
        seen
        (map ((n, refs) => (n, map (canonRef defined) refs)) fired)
      dispatchUntilStable
        defined
        graph
        seen
        modules
        (named ++ flatMap snd fired)
        (filter (p => isNone (firedBy names p)) pending)

firedBy : HashMap String Unit ->
  (List String, List String) ->
  Option (String, List String)
firedBy names (spellings, refs) = match filter (n => has n names) spellings
  n :: _ => Some (n, refs)
  [] => None

-- The references of a module's top-level binding the reach holds.
reachedRefs : HashMap String String -> Decl -> List String
reachedRefs seen (DAttrib _ d) = reachedRefs seen d
reachedRefs seen (d@(DFunDef _ n _ _ _ _)) =
  if has n seen then declRefs d else []
reachedRefs seen (DLetGroup pub binds) =
  flatMap
    (b => if has (letBindName b) seen then declRefs (DLetGroup pub [b]) else [])
    binds
reachedRefs _ _ = []

nameSet : List String -> HashMap String Unit
nameSet names = fromList (map (n => (n, ())) names)

declaredMethodNames : Decl -> List String
declaredMethodNames (DAttrib _ d) = declaredMethodNames d
declaredMethodNames (DInterface { methods, ... }) = map ifaceMethodName methods
declaredMethodNames _ = []

-- Each interface a unit declares, with its method names.
ifaceMethodTable : List Decl -> HashMap String (List String)
ifaceMethodTable decls =
  let t = new ()
  ifaceMethodsInto decls t
  t

ifaceMethodsInto : List Decl -> HashMap String (List String) -> Unit
ifaceMethodsInto [] _ = ()
ifaceMethodsInto ((DAttrib _ d) :: rest) t = ifaceMethodsInto (d :: rest) t
ifaceMethodsInto ((DInterface { name, methods, ... }) :: rest) t =
  setInPlace name (map ifaceMethodName methods ++ findWithDefault [] name t) t
  ifaceMethodsInto rest t
ifaceMethodsInto (_ :: rest) t = ifaceMethodsInto rest t

-- Every spelling a reference can give one of the method names `ms`: the name,
-- `A.name` under `import M as A`, and `local` under `import M.{name as local}`.
-- A method keeps its bare name through `scopeUnitNames`.
methodSpellings : List String ->
  List (String, String) ->
  List String ->
  List String
methodSpellings aliases members ms =
  ms
    ++ flatMap (a => map (m => "\{a}.\{m}") ms) aliases
    ++ map fst (filter (lo => contains (snd lo) ms) members)

moduleAliases : List Decl -> List String
moduleAliases decls = flatMap moduleAlias decls

moduleAlias : Decl -> List String
moduleAlias (DAttrib _ d) = moduleAlias d
moduleAlias (DUse _ (UseAlias _ a) _) = [a]
moduleAlias _ = []

-- Each `import M.{origin as local}` member, as (local, origin).
memberAliases : List Decl -> List (String, String)
memberAliases decls = flatMap memberAliasesOf decls

memberAliasesOf : Decl -> List (String, String)
memberAliasesOf (DAttrib _ d) = memberAliasesOf d
memberAliasesOf (DUse _ (UseGroup _ members) _) =
  filterMap
    (m => map (local => (local, useMemberOrigin m)) (useMemberAlias m))
    members
memberAliasesOf _ = []

-- Each binder of a top-level let group as a node of `funGraph`'s graph.
letGroupGraphInto : HashMap String Unit ->
  List Decl ->
  HashMap String (List String) ->
  Unit
letGroupGraphInto _ [] _ = ()
letGroupGraphInto defined ((DAttrib _ d) :: rest) g =
  letGroupGraphInto defined (d :: rest) g
letGroupGraphInto defined ((DLetGroup pub binds) :: rest) g =
  letBindsInto defined pub binds g
  letGroupGraphInto defined rest g
letGroupGraphInto defined (_ :: rest) g = letGroupGraphInto defined rest g

letBindsInto : HashMap String Unit ->
  Bool ->
  List LetBind ->
  HashMap String (List String) ->
  Unit
letBindsInto _ _ [] _ = ()
letBindsInto defined pub (b :: rest) g =
  let n = letBindName b
  setInPlace
    n
    (map (canonRef defined) (declRefs (DLetGroup pub [b]))
      ++ findWithDefault [] n g)
    g
  letBindsInto defined pub rest g

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
    setInPlace w from seen
    closure graph seen ((w, refsOf graph w) :: (from, ws) :: stack)

refsOf : HashMap String (List String) -> String -> List String
refsOf graph n = findWithDefault [] n graph
# DESUGAR
(DUse false (UseGroup ("support" "symbol_encoding") ((mem "encodePair" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "ExternDecl" true) (mem "LetBind" false) (mem "UsePath" true) (mem "ifaceMethodName" false) (mem "implMethodName" false) (mem "letBindName" false) (mem "useMemberAlias" false) (mem "useMemberOrigin" false))))
(DUse false (UseGroup ("frontend" "marker") ((mem "declRefs" false))))
(DUse false (UseGroup ("types" "private_mangle") ((mem "scopeUnitNames" false))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false) (mem "fromList" false) (mem "setInPlace" false) (mem "has" false) (mem "findWithDefault" false) (mem "get" false))))
(DUse false (UseGroup ("list") ((mem "zip" false))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "contains" false))))
(DTypeSig true "dceFilter" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "dceFilter" ((PVar "decls")) (EApp (EApp (EVar "filterReachable") (EApp (EVar "reachableNames") (EVar "decls"))) (EVar "decls")))
(DTypeSig true "reachedExternChains" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "reachedExternChains" ((PVar "builtins") (PVar "core") (PVar "modules")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "key") (PVar "route"))) (ETuple (EVar "key") (EApp (EApp (EVar "map") (EVar "snd")) (EVar "route"))))) (EApp (EApp (EApp (EApp (EVar "reachedExternRoutes") (EVar "EmittedRoots")) (EVar "builtins")) (EVar "core")) (EVar "modules"))))
(DData Public "ReachRoots" () ((variant "EmittedRoots" (ConPos)) (variant "DispatchedRoots" (ConPos))) ())
(DTypeSig true "reachedExternRoutes" (TyFun (TyCon "ReachRoots") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))))))
(DFunDef false "reachedExternRoutes" ((PVar "roots") (PVar "builtins") (PVar "core") (PVar "modules")) (EBlock (DoLet false false (PVar "units") (EMatch (EVar "builtins") (arm (PCon "Some" (PVar "b")) () (EBinOp "::" (EVar "b") (EVar "modules"))) (arm (PCon "None") () (EVar "modules")))) (DoLet false false (PTuple (PVar "scopedCore") (PVar "scopedModules")) (EApp (EApp (EApp (EVar "scopeUnitNames") (EVar "builtins")) (EVar "core")) (EVar "modules"))) (DoLet false false (PVar "reach") (EMatch (EVar "roots") (arm (PCon "EmittedRoots") () (EApp (EVar "reachableNames") (EBinOp "++" (EVar "scopedCore") (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "scopedModules"))))) (arm (PCon "DispatchedRoots") () (EApp (EApp (EVar "dispatchedNames") (EVar "scopedCore")) (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "scopedModules")))))) (DoLet false false (PVar "pairs") (EApp (EApp (EVar "flatMap") (ELam ((PTuple (PTuple (PVar "mid") (PVar "ds")) (PTuple PWild (PVar "scoped")))) (EApp (EApp (EVar "map") (ELam ((PVar "p")) (ETuple (EVar "mid") (EVar "p")))) (EApp (EApp (EVar "zip") (EVar "ds")) (EVar "scoped"))))) (EApp (EApp (EVar "zip") (EVar "units")) (EVar "scopedModules")))) (DoLet false false (PVar "declared") (EApp (EVar "fromList") (EApp (EApp (EVar "flatMap") (ELam ((PTuple (PVar "mid") (PTuple (PVar "d") (PVar "s")))) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "sc") (PVar "n"))) (ETuple (EVar "sc") (ETuple (EVar "mid") (EVar "n"))))) (EApp (EApp (EVar "scopedNames") (EVar "d")) (EVar "s"))))) (EVar "pairs")))) (DoExpr (EApp (EApp (EVar "filterMap") (EApp (EApp (EVar "externChain") (EVar "reach")) (EVar "declared"))) (EVar "pairs")))))
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
(DFunDef false "canonRef" ((PVar "defined") (PVar "n")) (EIf (EApp (EApp (EVar "has") (EVar "n")) (EVar "defined")) (EVar "n") (EIf (EApp (EApp (EVar "has") (EApp (EApp (EVar "encodePair") (ELit (LString "core"))) (EVar "n"))) (EVar "defined")) (EApp (EApp (EVar "encodePair") (ELit (LString "core"))) (EVar "n")) (EIf (EVar "otherwise") (EVar "n") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "definedFnNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "definedFnNames" ((PVar "decls")) (EBlock (DoLet false false (PVar "s") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "definedFnNamesInto") (EVar "decls")) (EVar "s"))) (DoExpr (EVar "s"))))
(DTypeSig false "definedFnNamesInto" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyCon "Unit"))))
(DFunDef false "definedFnNamesInto" ((PList) PWild) (ELit LUnit))
(DFunDef false "definedFnNamesInto" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "s")) (EApp (EApp (EVar "definedFnNamesInto") (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "s")))
(DFunDef false "definedFnNamesInto" ((PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild PWild PWild) (PVar "rest")) (PVar "s")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "setInPlace") (EVar "n")) (ELit LUnit)) (EVar "s"))) (DoExpr (EApp (EApp (EVar "definedFnNamesInto") (EVar "rest")) (EVar "s")))))
(DFunDef false "definedFnNamesInto" ((PCons PWild (PVar "rest")) (PVar "s")) (EApp (EApp (EVar "definedFnNamesInto") (EVar "rest")) (EVar "s")))
(DTypeSig false "reachableNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String"))))
(DFunDef false "reachableNames" ((PVar "decls")) (EBlock (DoLet false false (PVar "defined") (EApp (EVar "definedFnNames") (EVar "decls"))) (DoLet false false (PVar "graph") (EApp (EApp (EVar "funGraph") (EVar "defined")) (EVar "decls"))) (DoLet false false (PVar "seen") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "closure") (EVar "graph")) (EVar "seen")) (EListLit (ETuple (ELit (LString "")) (EApp (EApp (EVar "map") (EApp (EVar "canonRef") (EVar "defined"))) (EBinOp "::" (ELit (LString "main")) (EApp (EVar "emittingRoots") (EVar "decls")))))))) (DoExpr (EVar "seen"))))
(DTypeSig false "funGraph" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "funGraph" ((PVar "defined") (PVar "decls")) (EBlock (DoLet false false (PVar "g") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "funGraphInto") (EVar "defined")) (EVar "decls")) (EVar "g"))) (DoExpr (EVar "g"))))
(DTypeSig false "funGraphInto" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Unit")))))
(DFunDef false "funGraphInto" (PWild (PList) PWild) (ELit LUnit))
(DFunDef false "funGraphInto" ((PVar "defined") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "g")) (EApp (EApp (EApp (EVar "funGraphInto") (EVar "defined")) (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "g")))
(DFunDef false "funGraphInto" ((PVar "defined") (PCons (PCon "DFunDef" PWild (PVar "n") (PVar "ps") (PVar "body") (PVar "site") (PVar "bid")) (PVar "rest")) (PVar "g")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "setInPlace") (EVar "n")) (EBinOp "++" (EApp (EApp (EVar "map") (EApp (EVar "canonRef") (EVar "defined"))) (EApp (EVar "declRefs") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "False")) (EVar "n")) (EVar "ps")) (EVar "body")) (EVar "site")) (EVar "bid")))) (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "n")) (EVar "g")))) (EVar "g"))) (DoExpr (EApp (EApp (EApp (EVar "funGraphInto") (EVar "defined")) (EVar "rest")) (EVar "g")))))
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
(DTypeSig false "dispatchedNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")))))
(DFunDef false "dispatchedNames" ((PVar "core") (PVar "modules")) (EBlock (DoLet false false (PVar "decls") (EBinOp "++" (EVar "core") (EVar "modules"))) (DoLet false false (PVar "defined") (EApp (EVar "definedFnNames") (EVar "decls"))) (DoLet false false (PVar "graph") (EApp (EApp (EVar "funGraph") (EVar "defined")) (EVar "decls"))) (DoExpr (EApp (EApp (EApp (EVar "letGroupGraphInto") (EVar "defined")) (EVar "decls")) (EVar "graph"))) (DoLet false false (PVar "classify") (EApp (EApp (EApp (EApp (EVar "dispatchOf") (EApp (EVar "ifaceMethodTable") (EVar "core"))) (EApp (EVar "nameSet") (EApp (EApp (EVar "flatMap") (EVar "declaredMethodNames")) (EVar "core")))) (EApp (EVar "ifaceMethodTable") (EVar "modules"))) (EApp (EApp (EVar "methodSpellings") (EApp (EVar "moduleAliases") (EVar "modules"))) (EApp (EVar "memberAliases") (EVar "modules"))))) (DoLet false false (PVar "moduleEntries") (EApp (EApp (EVar "filterMap") (EVar "classify")) (EVar "modules"))) (DoLet false false (PVar "moduleRoots") (EApp (EApp (EVar "flatMap") (EVar "rootRefs")) (EVar "moduleEntries"))) (DoLet false false (PVar "seen") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "closure") (EVar "graph")) (EVar "seen")) (EListLit (ETuple (ELit (LString "")) (EApp (EApp (EVar "map") (EApp (EVar "canonRef") (EVar "defined"))) (EBinOp "::" (ELit (LString "main")) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "entryRefs")) (EApp (EApp (EVar "filterMap") (EVar "classify")) (EVar "core"))) (EVar "moduleRoots")))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "dispatchUntilStable") (EVar "defined")) (EVar "graph")) (EVar "seen")) (EVar "modules")) (EVar "moduleRoots")) (EApp (EApp (EVar "filterMap") (EVar "onceNamed")) (EVar "moduleEntries")))) (DoExpr (EVar "seen"))))
(DData Private "DispatchEntry" () ((variant "DispatchRoot" (ConPos (TyApp (TyCon "List") (TyCon "String")))) (variant "DispatchOnce" (ConPos (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))) ())
(DTypeSig false "entryRefs" (TyFun (TyCon "DispatchEntry") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "entryRefs" ((PCon "DispatchRoot" (PVar "refs"))) (EVar "refs"))
(DFunDef false "entryRefs" ((PCon "DispatchOnce" PWild (PVar "refs"))) (EVar "refs"))
(DTypeSig false "rootRefs" (TyFun (TyCon "DispatchEntry") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "rootRefs" ((PCon "DispatchRoot" (PVar "refs"))) (EVar "refs"))
(DFunDef false "rootRefs" ((PCon "DispatchOnce" PWild PWild)) (EListLit))
(DTypeSig false "onceNamed" (TyFun (TyCon "DispatchEntry") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "onceNamed" ((PCon "DispatchRoot" PWild)) (EVar "None"))
(DFunDef false "onceNamed" ((PCon "DispatchOnce" (PVar "names") (PVar "refs"))) (EApp (EVar "Some") (ETuple (EVar "names") (EVar "refs"))))
(DTypeSig false "dispatchOf" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "DispatchEntry"))))))))
(DFunDef false "dispatchOf" ((PVar "ifaces") (PVar "methods") (PVar "declared") (PVar "spell") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EApp (EVar "dispatchOf") (EVar "ifaces")) (EVar "methods")) (EVar "declared")) (EVar "spell")) (EVar "d")))
(DFunDef false "dispatchOf" ((PVar "ifaces") (PVar "methods") (PVar "declared") (PVar "spell") (PAs "d" (PRec "DInterface" ((rf "name" None)) true))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "dispatchOn") (EVar "ifaces")) (EVar "methods")) (EVar "declared")) (EVar "spell")) (EVar "name")) (EListLit)) (EApp (EVar "declRefs") (EVar "d")))))
(DFunDef false "dispatchOf" ((PVar "ifaces") (PVar "methods") (PVar "declared") (PVar "spell") (PAs "d" (PRec "DImpl" ((rf "iface" None) (rf "methods" (PVar "own"))) true))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "dispatchOn") (EVar "ifaces")) (EVar "methods")) (EVar "declared")) (EVar "spell")) (EApp (EVar "bareIfaceName") (EVar "iface"))) (EApp (EApp (EVar "map") (EVar "implMethodName")) (EVar "own"))) (EApp (EVar "declRefs") (EVar "d")))))
(DFunDef false "dispatchOf" (PWild PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "dispatchOn" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "DispatchEntry")))))))))
(DFunDef false "dispatchOn" ((PVar "ifaces") (PVar "methods") (PVar "declared") (PVar "spell") (PVar "iface") (PVar "own") (PVar "refs")) (EIf (EApp (EApp (EVar "has") (EVar "iface")) (EVar "ifaces")) (EApp (EVar "DispatchRoot") (EVar "refs")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "get") (EVar "iface")) (EVar "declared")) (arm (PCon "Some" (PVar "names")) () (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "m")) (EApp (EApp (EVar "has") (EVar "m")) (EVar "methods")))) (EBinOp "++" (EVar "names") (EVar "own"))) (EApp (EVar "DispatchRoot") (EVar "refs")) (EApp (EApp (EVar "DispatchOnce") (EApp (EVar "spell") (EBinOp "++" (EVar "names") (EVar "own")))) (EVar "refs")))) (arm (PCon "None") () (EApp (EVar "DispatchRoot") (EVar "refs")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "bareIfaceName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "bareIfaceName" ((PVar "iface")) (EMatch (EApp (EApp (EVar "stringLastIndexOf") (ELit (LString "."))) (EVar "iface")) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "iface"))) (EVar "iface"))) (arm (PCon "None") () (EVar "iface"))))
(DTypeSig false "dispatchUntilStable" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Unit"))))))))
(DFunDef false "dispatchUntilStable" ((PVar "defined") (PVar "graph") (PVar "seen") (PVar "modules") (PVar "named") (PVar "pending")) (EBlock (DoLet false false (PVar "names") (EApp (EVar "nameSet") (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EVar "reachedRefs") (EVar "seen"))) (EVar "modules")) (EVar "named")))) (DoExpr (EMatch (EApp (EApp (EVar "filterMap") (EApp (EVar "firedBy") (EVar "names"))) (EVar "pending")) (arm (PList) () (ELit LUnit)) (arm (PVar "fired") () (EBlock (DoExpr (EApp (EApp (EApp (EVar "closure") (EVar "graph")) (EVar "seen")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "n") (PVar "refs"))) (ETuple (EVar "n") (EApp (EApp (EVar "map") (EApp (EVar "canonRef") (EVar "defined"))) (EVar "refs"))))) (EVar "fired")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "dispatchUntilStable") (EVar "defined")) (EVar "graph")) (EVar "seen")) (EVar "modules")) (EBinOp "++" (EVar "named") (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "fired")))) (EApp (EApp (EVar "filter") (ELam ((PVar "p")) (EApp (EVar "isNone") (EApp (EApp (EVar "firedBy") (EVar "names")) (EVar "p"))))) (EVar "pending"))))))))))
(DTypeSig false "firedBy" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "firedBy" ((PVar "names") (PTuple (PVar "spellings") (PVar "refs"))) (EMatch (EApp (EApp (EVar "filter") (ELam ((PVar "n")) (EApp (EApp (EVar "has") (EVar "n")) (EVar "names")))) (EVar "spellings")) (arm (PCons (PVar "n") PWild) () (EApp (EVar "Some") (ETuple (EVar "n") (EVar "refs")))) (arm (PList) () (EVar "None"))))
(DTypeSig false "reachedRefs" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reachedRefs" ((PVar "seen") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "reachedRefs") (EVar "seen")) (EVar "d")))
(DFunDef false "reachedRefs" ((PVar "seen") (PAs "d" (PCon "DFunDef" PWild (PVar "n") PWild PWild PWild PWild))) (EIf (EApp (EApp (EVar "has") (EVar "n")) (EVar "seen")) (EApp (EVar "declRefs") (EVar "d")) (EListLit)))
(DFunDef false "reachedRefs" ((PVar "seen") (PCon "DLetGroup" (PVar "pub") (PVar "binds"))) (EApp (EApp (EVar "flatMap") (ELam ((PVar "b")) (EIf (EApp (EApp (EVar "has") (EApp (EVar "letBindName") (EVar "b"))) (EVar "seen")) (EApp (EVar "declRefs") (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EListLit (EVar "b")))) (EListLit)))) (EVar "binds")))
(DFunDef false "reachedRefs" (PWild PWild) (EListLit))
(DTypeSig false "nameSet" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "nameSet" ((PVar "names")) (EApp (EVar "fromList") (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (ELit LUnit)))) (EVar "names"))))
(DTypeSig false "declaredMethodNames" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declaredMethodNames" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declaredMethodNames") (EVar "d")))
(DFunDef false "declaredMethodNames" ((PRec "DInterface" ((rf "methods" None)) true)) (EApp (EApp (EVar "map") (EVar "ifaceMethodName")) (EVar "methods")))
(DFunDef false "declaredMethodNames" (PWild) (EListLit))
(DTypeSig false "ifaceMethodTable" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ifaceMethodTable" ((PVar "decls")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "ifaceMethodsInto") (EVar "decls")) (EVar "t"))) (DoExpr (EVar "t"))))
(DTypeSig false "ifaceMethodsInto" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Unit"))))
(DFunDef false "ifaceMethodsInto" ((PList) PWild) (ELit LUnit))
(DFunDef false "ifaceMethodsInto" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "t")) (EApp (EApp (EVar "ifaceMethodsInto") (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "t")))
(DFunDef false "ifaceMethodsInto" ((PCons (PRec "DInterface" ((rf "name" None) (rf "methods" None)) true) (PVar "rest")) (PVar "t")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "setInPlace") (EVar "name")) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "ifaceMethodName")) (EVar "methods")) (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "name")) (EVar "t")))) (EVar "t"))) (DoExpr (EApp (EApp (EVar "ifaceMethodsInto") (EVar "rest")) (EVar "t")))))
(DFunDef false "ifaceMethodsInto" ((PCons PWild (PVar "rest")) (PVar "t")) (EApp (EApp (EVar "ifaceMethodsInto") (EVar "rest")) (EVar "t")))
(DTypeSig false "methodSpellings" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "methodSpellings" ((PVar "aliases") (PVar "members") (PVar "ms")) (EBinOp "++" (EBinOp "++" (EVar "ms") (EApp (EApp (EVar "flatMap") (ELam ((PVar "a")) (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "a"))) (ELit (LString "."))) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (EVar "ms")))) (EVar "aliases"))) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EVar "filter") (ELam ((PVar "lo")) (EApp (EApp (EVar "contains") (EApp (EVar "snd") (EVar "lo"))) (EVar "ms")))) (EVar "members")))))
(DTypeSig false "moduleAliases" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "moduleAliases" ((PVar "decls")) (EApp (EApp (EVar "flatMap") (EVar "moduleAlias")) (EVar "decls")))
(DTypeSig false "moduleAlias" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "moduleAlias" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "moduleAlias") (EVar "d")))
(DFunDef false "moduleAlias" ((PCon "DUse" PWild (PCon "UseAlias" PWild (PVar "a")) PWild)) (EListLit (EVar "a")))
(DFunDef false "moduleAlias" (PWild) (EListLit))
(DTypeSig false "memberAliases" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "memberAliases" ((PVar "decls")) (EApp (EApp (EVar "flatMap") (EVar "memberAliasesOf")) (EVar "decls")))
(DTypeSig false "memberAliasesOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "memberAliasesOf" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "memberAliasesOf") (EVar "d")))
(DFunDef false "memberAliasesOf" ((PCon "DUse" PWild (PCon "UseGroup" PWild (PVar "members")) PWild)) (EApp (EApp (EVar "filterMap") (ELam ((PVar "m")) (EApp (EApp (EVar "map") (ELam ((PVar "local")) (ETuple (EVar "local") (EApp (EVar "useMemberOrigin") (EVar "m"))))) (EApp (EVar "useMemberAlias") (EVar "m"))))) (EVar "members")))
(DFunDef false "memberAliasesOf" (PWild) (EListLit))
(DTypeSig false "letGroupGraphInto" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Unit")))))
(DFunDef false "letGroupGraphInto" (PWild (PList) PWild) (ELit LUnit))
(DFunDef false "letGroupGraphInto" ((PVar "defined") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "g")) (EApp (EApp (EApp (EVar "letGroupGraphInto") (EVar "defined")) (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "g")))
(DFunDef false "letGroupGraphInto" ((PVar "defined") (PCons (PCon "DLetGroup" (PVar "pub") (PVar "binds")) (PVar "rest")) (PVar "g")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "letBindsInto") (EVar "defined")) (EVar "pub")) (EVar "binds")) (EVar "g"))) (DoExpr (EApp (EApp (EApp (EVar "letGroupGraphInto") (EVar "defined")) (EVar "rest")) (EVar "g")))))
(DFunDef false "letGroupGraphInto" ((PVar "defined") (PCons PWild (PVar "rest")) (PVar "g")) (EApp (EApp (EApp (EVar "letGroupGraphInto") (EVar "defined")) (EVar "rest")) (EVar "g")))
(DTypeSig false "letBindsInto" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Unit"))))))
(DFunDef false "letBindsInto" (PWild PWild (PList) PWild) (ELit LUnit))
(DFunDef false "letBindsInto" ((PVar "defined") (PVar "pub") (PCons (PVar "b") (PVar "rest")) (PVar "g")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "letBindName") (EVar "b"))) (DoExpr (EApp (EApp (EApp (EVar "setInPlace") (EVar "n")) (EBinOp "++" (EApp (EApp (EVar "map") (EApp (EVar "canonRef") (EVar "defined"))) (EApp (EVar "declRefs") (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EListLit (EVar "b"))))) (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "n")) (EVar "g")))) (EVar "g"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "letBindsInto") (EVar "defined")) (EVar "pub")) (EVar "rest")) (EVar "g")))))
(DTypeSig false "closure" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Unit")))))
(DFunDef false "closure" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "closure" ((PVar "graph") (PVar "seen") (PCons (PTuple PWild (PList)) (PVar "stack"))) (EApp (EApp (EApp (EVar "closure") (EVar "graph")) (EVar "seen")) (EVar "stack")))
(DFunDef false "closure" ((PVar "graph") (PVar "seen") (PCons (PTuple (PVar "from") (PCons (PVar "w") (PVar "ws"))) (PVar "stack"))) (EIf (EApp (EApp (EVar "has") (EVar "w")) (EVar "seen")) (EApp (EApp (EApp (EVar "closure") (EVar "graph")) (EVar "seen")) (EBinOp "::" (ETuple (EVar "from") (EVar "ws")) (EVar "stack"))) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EVar "setInPlace") (EVar "w")) (EVar "from")) (EVar "seen"))) (DoExpr (EApp (EApp (EApp (EVar "closure") (EVar "graph")) (EVar "seen")) (EBinOp "::" (ETuple (EVar "w") (EApp (EApp (EVar "refsOf") (EVar "graph")) (EVar "w"))) (EBinOp "::" (ETuple (EVar "from") (EVar "ws")) (EVar "stack")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "refsOf" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "refsOf" ((PVar "graph") (PVar "n")) (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "n")) (EVar "graph")))
# MARK
(DUse false (UseGroup ("support" "symbol_encoding") ((mem "encodePair" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "ExternDecl" true) (mem "LetBind" false) (mem "UsePath" true) (mem "ifaceMethodName" false) (mem "implMethodName" false) (mem "letBindName" false) (mem "useMemberAlias" false) (mem "useMemberOrigin" false))))
(DUse false (UseGroup ("frontend" "marker") ((mem "declRefs" false))))
(DUse false (UseGroup ("types" "private_mangle") ((mem "scopeUnitNames" false))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false) (mem "fromList" false) (mem "setInPlace" false) (mem "has" false) (mem "findWithDefault" false) (mem "get" false))))
(DUse false (UseGroup ("list") ((mem "zip" false))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "contains" false))))
(DTypeSig true "dceFilter" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "dceFilter" ((PVar "decls")) (EApp (EApp (EVar "filterReachable") (EApp (EVar "reachableNames") (EVar "decls"))) (EVar "decls")))
(DTypeSig true "reachedExternChains" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "reachedExternChains" ((PVar "builtins") (PVar "core") (PVar "modules")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "key") (PVar "route"))) (ETuple (EVar "key") (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "route"))))) (EApp (EApp (EApp (EApp (EVar "reachedExternRoutes") (EVar "EmittedRoots")) (EVar "builtins")) (EVar "core")) (EVar "modules"))))
(DData Public "ReachRoots" () ((variant "EmittedRoots" (ConPos)) (variant "DispatchedRoots" (ConPos))) ())
(DTypeSig true "reachedExternRoutes" (TyFun (TyCon "ReachRoots") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))))))
(DFunDef false "reachedExternRoutes" ((PVar "roots") (PVar "builtins") (PVar "core") (PVar "modules")) (EBlock (DoLet false false (PVar "units") (EMatch (EVar "builtins") (arm (PCon "Some" (PVar "b")) () (EBinOp "::" (EVar "b") (EVar "modules"))) (arm (PCon "None") () (EVar "modules")))) (DoLet false false (PTuple (PVar "scopedCore") (PVar "scopedModules")) (EApp (EApp (EApp (EVar "scopeUnitNames") (EVar "builtins")) (EVar "core")) (EVar "modules"))) (DoLet false false (PVar "reach") (EMatch (EVar "roots") (arm (PCon "EmittedRoots") () (EApp (EVar "reachableNames") (EBinOp "++" (EVar "scopedCore") (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "scopedModules"))))) (arm (PCon "DispatchedRoots") () (EApp (EApp (EVar "dispatchedNames") (EVar "scopedCore")) (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "scopedModules")))))) (DoLet false false (PVar "pairs") (EApp (EApp (EDictApp "flatMap") (ELam ((PTuple (PTuple (PVar "mid") (PVar "ds")) (PTuple PWild (PVar "scoped")))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (ETuple (EVar "mid") (EVar "p")))) (EApp (EApp (EVar "zip") (EVar "ds")) (EVar "scoped"))))) (EApp (EApp (EVar "zip") (EVar "units")) (EVar "scopedModules")))) (DoLet false false (PVar "declared") (EApp (EVar "fromList") (EApp (EApp (EDictApp "flatMap") (ELam ((PTuple (PVar "mid") (PTuple (PVar "d") (PVar "s")))) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "sc") (PVar "n"))) (ETuple (EVar "sc") (ETuple (EVar "mid") (EVar "n"))))) (EApp (EApp (EVar "scopedNames") (EVar "d")) (EVar "s"))))) (EVar "pairs")))) (DoExpr (EApp (EApp (EMethodRef "filterMap") (EApp (EApp (EVar "externChain") (EVar "reach")) (EVar "declared"))) (EVar "pairs")))))
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
(DFunDef false "canonRef" ((PVar "defined") (PVar "n")) (EIf (EApp (EApp (EVar "has") (EVar "n")) (EVar "defined")) (EVar "n") (EIf (EApp (EApp (EVar "has") (EApp (EApp (EVar "encodePair") (ELit (LString "core"))) (EVar "n"))) (EVar "defined")) (EApp (EApp (EVar "encodePair") (ELit (LString "core"))) (EVar "n")) (EIf (EVar "otherwise") (EVar "n") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "definedFnNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "definedFnNames" ((PVar "decls")) (EBlock (DoLet false false (PVar "s") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "definedFnNamesInto") (EVar "decls")) (EVar "s"))) (DoExpr (EVar "s"))))
(DTypeSig false "definedFnNamesInto" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyCon "Unit"))))
(DFunDef false "definedFnNamesInto" ((PList) PWild) (ELit LUnit))
(DFunDef false "definedFnNamesInto" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "s")) (EApp (EApp (EVar "definedFnNamesInto") (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "s")))
(DFunDef false "definedFnNamesInto" ((PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild PWild PWild) (PVar "rest")) (PVar "s")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "setInPlace") (EVar "n")) (ELit LUnit)) (EVar "s"))) (DoExpr (EApp (EApp (EVar "definedFnNamesInto") (EVar "rest")) (EVar "s")))))
(DFunDef false "definedFnNamesInto" ((PCons PWild (PVar "rest")) (PVar "s")) (EApp (EApp (EVar "definedFnNamesInto") (EVar "rest")) (EVar "s")))
(DTypeSig false "reachableNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String"))))
(DFunDef false "reachableNames" ((PVar "decls")) (EBlock (DoLet false false (PVar "defined") (EApp (EVar "definedFnNames") (EVar "decls"))) (DoLet false false (PVar "graph") (EApp (EApp (EVar "funGraph") (EVar "defined")) (EVar "decls"))) (DoLet false false (PVar "seen") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "closure") (EVar "graph")) (EVar "seen")) (EListLit (ETuple (ELit (LString "")) (EApp (EApp (EMethodRef "map") (EApp (EVar "canonRef") (EVar "defined"))) (EBinOp "::" (ELit (LString "main")) (EApp (EVar "emittingRoots") (EVar "decls")))))))) (DoExpr (EVar "seen"))))
(DTypeSig false "funGraph" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "funGraph" ((PVar "defined") (PVar "decls")) (EBlock (DoLet false false (PVar "g") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "funGraphInto") (EVar "defined")) (EVar "decls")) (EVar "g"))) (DoExpr (EVar "g"))))
(DTypeSig false "funGraphInto" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Unit")))))
(DFunDef false "funGraphInto" (PWild (PList) PWild) (ELit LUnit))
(DFunDef false "funGraphInto" ((PVar "defined") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "g")) (EApp (EApp (EApp (EVar "funGraphInto") (EVar "defined")) (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "g")))
(DFunDef false "funGraphInto" ((PVar "defined") (PCons (PCon "DFunDef" PWild (PVar "n") (PVar "ps") (PVar "body") (PVar "site") (PVar "bid")) (PVar "rest")) (PVar "g")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "setInPlace") (EVar "n")) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EApp (EVar "canonRef") (EVar "defined"))) (EApp (EVar "declRefs") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "False")) (EVar "n")) (EVar "ps")) (EVar "body")) (EVar "site")) (EVar "bid")))) (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "n")) (EVar "g")))) (EVar "g"))) (DoExpr (EApp (EApp (EApp (EVar "funGraphInto") (EVar "defined")) (EVar "rest")) (EVar "g")))))
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
(DTypeSig false "dispatchedNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")))))
(DFunDef false "dispatchedNames" ((PVar "core") (PVar "modules")) (EBlock (DoLet false false (PVar "decls") (EBinOp "++" (EVar "core") (EVar "modules"))) (DoLet false false (PVar "defined") (EApp (EVar "definedFnNames") (EVar "decls"))) (DoLet false false (PVar "graph") (EApp (EApp (EVar "funGraph") (EVar "defined")) (EVar "decls"))) (DoExpr (EApp (EApp (EApp (EVar "letGroupGraphInto") (EVar "defined")) (EVar "decls")) (EVar "graph"))) (DoLet false false (PVar "classify") (EApp (EApp (EApp (EApp (EVar "dispatchOf") (EApp (EVar "ifaceMethodTable") (EVar "core"))) (EApp (EVar "nameSet") (EApp (EApp (EDictApp "flatMap") (EVar "declaredMethodNames")) (EVar "core")))) (EApp (EVar "ifaceMethodTable") (EVar "modules"))) (EApp (EApp (EVar "methodSpellings") (EApp (EVar "moduleAliases") (EVar "modules"))) (EApp (EVar "memberAliases") (EVar "modules"))))) (DoLet false false (PVar "moduleEntries") (EApp (EApp (EMethodRef "filterMap") (EVar "classify")) (EVar "modules"))) (DoLet false false (PVar "moduleRoots") (EApp (EApp (EDictApp "flatMap") (EVar "rootRefs")) (EVar "moduleEntries"))) (DoLet false false (PVar "seen") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "closure") (EVar "graph")) (EVar "seen")) (EListLit (ETuple (ELit (LString "")) (EApp (EApp (EMethodRef "map") (EApp (EVar "canonRef") (EVar "defined"))) (EBinOp "::" (ELit (LString "main")) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "entryRefs")) (EApp (EApp (EMethodRef "filterMap") (EVar "classify")) (EVar "core"))) (EVar "moduleRoots")))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "dispatchUntilStable") (EVar "defined")) (EVar "graph")) (EVar "seen")) (EVar "modules")) (EVar "moduleRoots")) (EApp (EApp (EMethodRef "filterMap") (EVar "onceNamed")) (EVar "moduleEntries")))) (DoExpr (EVar "seen"))))
(DData Private "DispatchEntry" () ((variant "DispatchRoot" (ConPos (TyApp (TyCon "List") (TyCon "String")))) (variant "DispatchOnce" (ConPos (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))) ())
(DTypeSig false "entryRefs" (TyFun (TyCon "DispatchEntry") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "entryRefs" ((PCon "DispatchRoot" (PVar "refs"))) (EVar "refs"))
(DFunDef false "entryRefs" ((PCon "DispatchOnce" PWild (PVar "refs"))) (EVar "refs"))
(DTypeSig false "rootRefs" (TyFun (TyCon "DispatchEntry") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "rootRefs" ((PCon "DispatchRoot" (PVar "refs"))) (EVar "refs"))
(DFunDef false "rootRefs" ((PCon "DispatchOnce" PWild PWild)) (EListLit))
(DTypeSig false "onceNamed" (TyFun (TyCon "DispatchEntry") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "onceNamed" ((PCon "DispatchRoot" PWild)) (EVar "None"))
(DFunDef false "onceNamed" ((PCon "DispatchOnce" (PVar "names") (PVar "refs"))) (EApp (EVar "Some") (ETuple (EVar "names") (EVar "refs"))))
(DTypeSig false "dispatchOf" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "DispatchEntry"))))))))
(DFunDef false "dispatchOf" ((PVar "ifaces") (PVar "methods") (PVar "declared") (PVar "spell") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EApp (EVar "dispatchOf") (EVar "ifaces")) (EVar "methods")) (EVar "declared")) (EVar "spell")) (EVar "d")))
(DFunDef false "dispatchOf" ((PVar "ifaces") (PVar "methods") (PVar "declared") (PVar "spell") (PAs "d" (PRec "DInterface" ((rf "name" None)) true))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "dispatchOn") (EVar "ifaces")) (EVar "methods")) (EVar "declared")) (EVar "spell")) (EVar "name")) (EListLit)) (EApp (EVar "declRefs") (EVar "d")))))
(DFunDef false "dispatchOf" ((PVar "ifaces") (PVar "methods") (PVar "declared") (PVar "spell") (PAs "d" (PRec "DImpl" ((rf "iface" None) (rf "methods" (PVar "own"))) true))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "dispatchOn") (EVar "ifaces")) (EVar "methods")) (EVar "declared")) (EVar "spell")) (EApp (EVar "bareIfaceName") (EVar "iface"))) (EApp (EApp (EMethodRef "map") (EVar "implMethodName")) (EVar "own"))) (EApp (EVar "declRefs") (EVar "d")))))
(DFunDef false "dispatchOf" (PWild PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "dispatchOn" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "DispatchEntry")))))))))
(DFunDef false "dispatchOn" ((PVar "ifaces") (PVar "methods") (PVar "declared") (PVar "spell") (PVar "iface") (PVar "own") (PVar "refs")) (EIf (EApp (EApp (EVar "has") (EVar "iface")) (EVar "ifaces")) (EApp (EVar "DispatchRoot") (EVar "refs")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "get") (EVar "iface")) (EVar "declared")) (arm (PCon "Some" (PVar "names")) () (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "m")) (EApp (EApp (EVar "has") (EVar "m")) (EVar "methods")))) (EBinOp "++" (EVar "names") (EVar "own"))) (EApp (EVar "DispatchRoot") (EVar "refs")) (EApp (EApp (EVar "DispatchOnce") (EApp (EVar "spell") (EBinOp "++" (EVar "names") (EVar "own")))) (EVar "refs")))) (arm (PCon "None") () (EApp (EVar "DispatchRoot") (EVar "refs")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "bareIfaceName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "bareIfaceName" ((PVar "iface")) (EMatch (EApp (EApp (EVar "stringLastIndexOf") (ELit (LString "."))) (EVar "iface")) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "iface"))) (EVar "iface"))) (arm (PCon "None") () (EVar "iface"))))
(DTypeSig false "dispatchUntilStable" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Unit"))))))))
(DFunDef false "dispatchUntilStable" ((PVar "defined") (PVar "graph") (PVar "seen") (PVar "modules") (PVar "named") (PVar "pending")) (EBlock (DoLet false false (PVar "names") (EApp (EVar "nameSet") (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EVar "reachedRefs") (EVar "seen"))) (EVar "modules")) (EVar "named")))) (DoExpr (EMatch (EApp (EApp (EMethodRef "filterMap") (EApp (EVar "firedBy") (EVar "names"))) (EVar "pending")) (arm (PList) () (ELit LUnit)) (arm (PVar "fired") () (EBlock (DoExpr (EApp (EApp (EApp (EVar "closure") (EVar "graph")) (EVar "seen")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "n") (PVar "refs"))) (ETuple (EVar "n") (EApp (EApp (EMethodRef "map") (EApp (EVar "canonRef") (EVar "defined"))) (EVar "refs"))))) (EVar "fired")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "dispatchUntilStable") (EVar "defined")) (EVar "graph")) (EVar "seen")) (EVar "modules")) (EBinOp "++" (EVar "named") (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "fired")))) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "p")) (EApp (EVar "isNone") (EApp (EApp (EVar "firedBy") (EVar "names")) (EVar "p"))))) (EVar "pending"))))))))))
(DTypeSig false "firedBy" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "firedBy" ((PVar "names") (PTuple (PVar "spellings") (PVar "refs"))) (EMatch (EApp (EApp (EMethodRef "filter") (ELam ((PVar "n")) (EApp (EApp (EVar "has") (EVar "n")) (EVar "names")))) (EVar "spellings")) (arm (PCons (PVar "n") PWild) () (EApp (EVar "Some") (ETuple (EVar "n") (EVar "refs")))) (arm (PList) () (EVar "None"))))
(DTypeSig false "reachedRefs" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reachedRefs" ((PVar "seen") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "reachedRefs") (EVar "seen")) (EVar "d")))
(DFunDef false "reachedRefs" ((PVar "seen") (PAs "d" (PCon "DFunDef" PWild (PVar "n") PWild PWild PWild PWild))) (EIf (EApp (EApp (EVar "has") (EVar "n")) (EVar "seen")) (EApp (EVar "declRefs") (EVar "d")) (EListLit)))
(DFunDef false "reachedRefs" ((PVar "seen") (PCon "DLetGroup" (PVar "pub") (PVar "binds"))) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "b")) (EIf (EApp (EApp (EVar "has") (EApp (EVar "letBindName") (EVar "b"))) (EVar "seen")) (EApp (EVar "declRefs") (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EListLit (EVar "b")))) (EListLit)))) (EVar "binds")))
(DFunDef false "reachedRefs" (PWild PWild) (EListLit))
(DTypeSig false "nameSet" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "nameSet" ((PVar "names")) (EApp (EVar "fromList") (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (ELit LUnit)))) (EVar "names"))))
(DTypeSig false "declaredMethodNames" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declaredMethodNames" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declaredMethodNames") (EVar "d")))
(DFunDef false "declaredMethodNames" ((PRec "DInterface" ((rf "methods" None)) true)) (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodName")) (EVar "methods")))
(DFunDef false "declaredMethodNames" (PWild) (EListLit))
(DTypeSig false "ifaceMethodTable" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ifaceMethodTable" ((PVar "decls")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "ifaceMethodsInto") (EVar "decls")) (EVar "t"))) (DoExpr (EVar "t"))))
(DTypeSig false "ifaceMethodsInto" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Unit"))))
(DFunDef false "ifaceMethodsInto" ((PList) PWild) (ELit LUnit))
(DFunDef false "ifaceMethodsInto" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "t")) (EApp (EApp (EVar "ifaceMethodsInto") (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "t")))
(DFunDef false "ifaceMethodsInto" ((PCons (PRec "DInterface" ((rf "name" None) (rf "methods" None)) true) (PVar "rest")) (PVar "t")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "setInPlace") (EVar "name")) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodName")) (EVar "methods")) (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "name")) (EVar "t")))) (EVar "t"))) (DoExpr (EApp (EApp (EVar "ifaceMethodsInto") (EVar "rest")) (EVar "t")))))
(DFunDef false "ifaceMethodsInto" ((PCons PWild (PVar "rest")) (PVar "t")) (EApp (EApp (EVar "ifaceMethodsInto") (EVar "rest")) (EVar "t")))
(DTypeSig false "methodSpellings" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "methodSpellings" ((PVar "aliases") (PVar "members") (PVar "ms")) (EBinOp "++" (EBinOp "++" (EVar "ms") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "a")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "."))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (EVar "ms")))) (EVar "aliases"))) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "lo")) (EApp (EApp (EVar "contains") (EApp (EVar "snd") (EVar "lo"))) (EVar "ms")))) (EVar "members")))))
(DTypeSig false "moduleAliases" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "moduleAliases" ((PVar "decls")) (EApp (EApp (EDictApp "flatMap") (EVar "moduleAlias")) (EVar "decls")))
(DTypeSig false "moduleAlias" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "moduleAlias" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "moduleAlias") (EVar "d")))
(DFunDef false "moduleAlias" ((PCon "DUse" PWild (PCon "UseAlias" PWild (PVar "a")) PWild)) (EListLit (EVar "a")))
(DFunDef false "moduleAlias" (PWild) (EListLit))
(DTypeSig false "memberAliases" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "memberAliases" ((PVar "decls")) (EApp (EApp (EDictApp "flatMap") (EVar "memberAliasesOf")) (EVar "decls")))
(DTypeSig false "memberAliasesOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "memberAliasesOf" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "memberAliasesOf") (EVar "d")))
(DFunDef false "memberAliasesOf" ((PCon "DUse" PWild (PCon "UseGroup" PWild (PVar "members")) PWild)) (EApp (EApp (EMethodRef "filterMap") (ELam ((PVar "m")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "local")) (ETuple (EVar "local") (EApp (EVar "useMemberOrigin") (EVar "m"))))) (EApp (EVar "useMemberAlias") (EVar "m"))))) (EVar "members")))
(DFunDef false "memberAliasesOf" (PWild) (EListLit))
(DTypeSig false "letGroupGraphInto" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Unit")))))
(DFunDef false "letGroupGraphInto" (PWild (PList) PWild) (ELit LUnit))
(DFunDef false "letGroupGraphInto" ((PVar "defined") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "g")) (EApp (EApp (EApp (EVar "letGroupGraphInto") (EVar "defined")) (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "g")))
(DFunDef false "letGroupGraphInto" ((PVar "defined") (PCons (PCon "DLetGroup" (PVar "pub") (PVar "binds")) (PVar "rest")) (PVar "g")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "letBindsInto") (EVar "defined")) (EVar "pub")) (EVar "binds")) (EVar "g"))) (DoExpr (EApp (EApp (EApp (EVar "letGroupGraphInto") (EVar "defined")) (EVar "rest")) (EVar "g")))))
(DFunDef false "letGroupGraphInto" ((PVar "defined") (PCons PWild (PVar "rest")) (PVar "g")) (EApp (EApp (EApp (EVar "letGroupGraphInto") (EVar "defined")) (EVar "rest")) (EVar "g")))
(DTypeSig false "letBindsInto" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Unit"))))))
(DFunDef false "letBindsInto" (PWild PWild (PList) PWild) (ELit LUnit))
(DFunDef false "letBindsInto" ((PVar "defined") (PVar "pub") (PCons (PVar "b") (PVar "rest")) (PVar "g")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "letBindName") (EVar "b"))) (DoExpr (EApp (EApp (EApp (EVar "setInPlace") (EVar "n")) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EApp (EVar "canonRef") (EVar "defined"))) (EApp (EVar "declRefs") (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EListLit (EVar "b"))))) (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "n")) (EVar "g")))) (EVar "g"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "letBindsInto") (EVar "defined")) (EVar "pub")) (EVar "rest")) (EVar "g")))))
(DTypeSig false "closure" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Unit")))))
(DFunDef false "closure" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "closure" ((PVar "graph") (PVar "seen") (PCons (PTuple PWild (PList)) (PVar "stack"))) (EApp (EApp (EApp (EVar "closure") (EVar "graph")) (EVar "seen")) (EVar "stack")))
(DFunDef false "closure" ((PVar "graph") (PVar "seen") (PCons (PTuple (PVar "from") (PCons (PVar "w") (PVar "ws"))) (PVar "stack"))) (EIf (EApp (EApp (EVar "has") (EVar "w")) (EVar "seen")) (EApp (EApp (EApp (EVar "closure") (EVar "graph")) (EVar "seen")) (EBinOp "::" (ETuple (EVar "from") (EVar "ws")) (EVar "stack"))) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EVar "setInPlace") (EVar "w")) (EVar "from")) (EVar "seen"))) (DoExpr (EApp (EApp (EApp (EVar "closure") (EVar "graph")) (EVar "seen")) (EBinOp "::" (ETuple (EVar "w") (EApp (EApp (EVar "refsOf") (EVar "graph")) (EVar "w"))) (EBinOp "::" (ETuple (EVar "from") (EVar "ws")) (EVar "stack")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "refsOf" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "refsOf" ((PVar "graph") (PVar "n")) (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "n")) (EVar "graph")))
