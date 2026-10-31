# META
source_lines=2048
stages=DESUGAR,MARK
# SOURCE
-- tc_elab: dict-passing elaboration (`dictPass`), the grant rewrite (`grantWholeDomain`),
-- operator-to-method rewriting: tree-to-tree passes over evidence; and the realization of solved
-- evidence into the tree's route cells, one recorded site at a time (`resolve*Site`,
-- `resolveArgStamps`, `resolveMethodDicts`, `resolveDictApps`, `realizeRecDictApps`): the cells
-- `dictPass` reads.
--
-- Spec: DICT section 4 (translation), section 7; EFFECTS section 8.
--
-- Placement: declarations are placed by R1-R6 of the Phase 4 module table,
-- compiler/ARCHITECTURE-PLAYBOOK.md section 6.
-- Closure rule: this module may not import `types.typecheck`, nor any of `tc_global`, `tc_module`.

import types.tc_types.{
  AdmittedAnswer(..),
  BuiltinClass(..),
  EntailKind(..),
  GrantBinder(..),
  MethodGrantUse(..),
  MethodReturnTraceStage(..),
  PendingDictApp(..),
  PredicateSlot(..),
  PredicateSlotArgs(..),
  SiteCtx(..),
  SiteKind(..),
  GrantOcc,
  GrantState,
  grantTopKey,
  GraphCtx,
  LocalAbs,
  MethodGrant,
  MethodPredicateSlot,
  MethodReturnRequest,
  ModuleCtx,
  PassEvidence,
  PassMethod,
  PendingEntry,
  PendingMethodDict,
  RecDictApp,
}
import types.tc_mono.{anyMember}
import types.tc_state.{dictParamName, interners}
import types.tc_env.{
  builtinClassName,
  builtinClassOrigin,
  declTopFnNames,
  importerReachIndex,
  methodLevelConstraintVarNames,
  methodSlotKey,
  namesToSet,
}
import types.tc_scope.{
  aliasConstraintEntries,
}
import types.tc_unify.{lookupQualPayload}
import types.tc_decls.{methodDictArityOf}
import types.tc_solve_givens.{lookupPredicateSlots}
import types.tc_solve_entail.{
  entail, implDictRoutesForRow, rowRouteKey, selectedCallSupers
}
import types.tc_solve.{
  admittedSelection,
  exactReturnRoutes,
  isLocalAbsName,
  methodPredicateRoutes,
  methodReturnAmbiguousWithoutGiven,
  methodReturnArgs,
  methodReturnResolutionValid,
  noteMethodReturnTrace,
  numericReturnRoute,
  recRoutes,
  returnPosMethodNames,
  routesOfMonosTopV,
  solveExactReturnOnce,
}
import types.tc_solve_check.{setFunPredicateSlots}
import types.tc_shadow.{
  methodCellOf,
}
import types.tc_effects.{
  evOrdinal,
  fileBodyLoc,
  fileBoundSite,
  fileValueKey,
  grantOccOf,
  hasFileBoundValue,
  methodGrantOf,
  narrowFileAtom,
}
import types.tc_occurrence.{
  arithDispatchMethod,
  binopMethod,
  constrainedSigNames,
  isGrantOnlyEv,
  mintMethodCellRaw,
  unopMethod,
}
import types.tc_groups.{sigConstraints}
import frontend.ast.{
  Arm(..),
  Decl(..),
  DoStmt(..),
  EvId(..),
  EvVal(..),
  Expr(..),
  FieldAssign(..),
  FunClause(..),
  Guard(..),
  IfaceMethod(..),
  ImplMethod(..),
  LetBind(..),
  Lit(..),
  Loc(..),
  MethodDefault(..),
  Pat(..),
  Route(..),
  Ty(..),
  TyConOrigin(..),
  EvTable,
  isI32Head,
  isI64Head,
  isU64Head,
  noBinderId,
  noDeclLoc,
  taggedFixedRange,
  tyConBuiltin,
  unminted,
}
import types.effect_authority.{
  Authority(..),
  Authvar(..),
  GrantShape(..),
  authGrantShape,
  authvarId,
}
import types.solver_contract.{ClassPredicate(..)}
import types.effect_rows.{EffRow(..), atomAuth, atomLabel, rowFlat}
import types.route_key.{
  evDictRoutesIn,
  evidenceLookup,
  EvIndex,
  evIndexOf,
  evSiteLitIn,
  evSiteRouteIn,
  ifaceWordOf,
}
import types.repr.{IfaceRef(..), Mono(..), normalize}
import support.ordmap.{
  omEmpty,
  omFromNames,
  omHasKey,
  omInsert,
  omLookup,
  OrdMap,
}
import types.evidence.{ScopeId(..)}
import map.{Map(..)}
import types.runtime_ops.{arithmeticTag}
import types.module_interface.{
  cellEntriesFrom, servedEntriesFrom, setServedArity
}
import support.util.{
  contains,
  dedup,
  filterList,
  int64Halves,
  isEmptyL,
  isNonEmptyL,
  isSome,
  listLen,
  splitOnChar,
}
import list.{drop, elemIndex, range, replicate, reverse, take}
import types.runtime_grants.{fileGrantExterns}
import types.chain_key.{isConstrainedTy}
import frontend.desugar.{mapChildren, mapProg}
import map as IdMap

-- The `dictPass` mints: a node constructed AFTER the drain, from a route another
-- node already solved, so its cells start at their final values.  The entry is
-- recorded in [pe] as well: the index the pass reads was taken before the node
-- existed.
mintMethodCellWith : ModuleCtx ->
  PassEvidence ->
  String ->
  Int ->
  Route ->
  List Route ->
  EvId
mintMethodCellWith mctx (PassEvidence _ minted) iface arity tag impls =
  let ev = mintMethodCellRaw mctx iface (Some arity) tag impls
  minted :=
    omInsert
      (intToString (evOrdinal ev))
      (EvMethod iface arity tag impls [])
      minted.value
  ev

-- The whole evidence table of this graph: one entry per method occurrence and per
-- minted site, plus the per-goal entries the drain recorded and the entries of the
-- modules a tree drive served (`applyModuleTrees`).
export
drivenEvidence : GraphCtx -> Unit -> EvTable
drivenEvidence gctx _ =
  cellEntriesFrom gctx.graphRun gctx.graphRun.evBase
    ++ gctx.graphRun.evTable.value

localAbsFor : GraphCtx -> String -> Option LocalAbs
localAbsFor gctx name =
  optionOr None (omLookup name gctx.graphRun.localAbs.lasBinders.value)

-- dict_pass for locals: an abstracted binder takes its dictionary parameters, and an
-- occurrence of a binder that abstracted nothing is a plain variable again.
rewriteLocalDictExpr : GraphCtx -> Expr -> Expr
rewriteLocalDictExpr gctx (EDictAt n ev)
  | isLocalAbsName n = match localAbsFor gctx n
    Some _ => EDictAt n ev
    None => EVar n
  | otherwise = EDictAt n ev
rewriteLocalDictExpr gctx (ELet m r (PVar x xloc bid) e1 e2) =
  match localAbsFor gctx x
    Some la => ELet m r (PVar x xloc bid) (prependLocalDicts la.laParams e1) e2
    None => ELet m r (PVar x xloc bid) e1 e2
rewriteLocalDictExpr gctx (ELetGroup binds body) =
  ELetGroup (map (rewriteLocalLetBind gctx) binds) body
rewriteLocalDictExpr gctx (EBlock stmts) =
  EBlock (map (rewriteLocalDoStmt gctx) stmts)
rewriteLocalDictExpr _gctx e = e

rewriteLocalLetBind : GraphCtx -> LetBind -> LetBind
rewriteLocalLetBind gctx (LetBind n clauses site bid) = match localAbsFor gctx n
  Some la =>
    LetBind n (map (prependLocalDictClause la.laParams) clauses) site bid
  None => LetBind n clauses site bid

prependLocalDictClause : List String -> FunClause -> FunClause
prependLocalDictClause params (FunClause pats body) =
  FunClause (map localDictPat params ++ pats) body

rewriteLocalDoStmt : GraphCtx -> DoStmt -> DoStmt
rewriteLocalDoStmt gctx (DoLet m r (PVar x xloc bid) e site) =
  match localAbsFor gctx x
    Some la =>
      DoLet m r (PVar x xloc bid) (prependLocalDicts la.laParams e) site
    None => DoLet m r (PVar x xloc bid) e site
rewriteLocalDoStmt _gctx stmt = stmt

prependLocalDicts : List String -> Expr -> Expr
prependLocalDicts params (ELoc l e) = ELoc l (prependLocalDicts params e)
prependLocalDicts params (ELam pats body) =
  ELam (map localDictPat params ++ pats) body
prependLocalDicts params e = ELam (map localDictPat params) e

localDictPat : String -> Pat
localDictPat n = PVar n (Loc "" 0 0 0 0) noBinderId

-- A program lowered without elaboration (the prelude-free emitter probes) has no
-- inference to solve a grant from: each file extern it names is granted the
-- whole domain, and saturated as elaboration saturates it.  The parameter names
-- come from the process's grant counter (the interners' lineage), which the next
-- drive continues.
export
grantWholeDomain : List Decl -> List Decl
grantWholeDomain prog =
  map (mapDeclBodies (wholeDomainExpr interners.value.lineage.lnGrants)) prog

wholeDomainExpr : GrantState -> Expr -> Expr
wholeDomainExpr st (e@(EApp _ _)) = match grantSpine e []
  (EVar n, args) => match omLookup n fileGrantExterns
    Some (arity, paths) =>
      saturateGrants
        st
        (EVar n)
        arity
        (replicate paths (EListLit []))
        (map (wholeDomainExpr st) args)
    None => mapChildren (wholeDomainExpr st) e
  _ => mapChildren (wholeDomainExpr st) e
wholeDomainExpr st (EVar n) = match omLookup n fileGrantExterns
  Some (arity, paths) =>
    saturateGrants st (EVar n) arity (replicate paths (EListLit [])) []
  None => EVar n
-- every other node: its children, through the one traversal every pass shares
wholeDomainExpr st e = mapChildren (wholeDomainExpr st) e

-- Apply [f] once to the root of every expression a declaration holds.
mapDeclBodies : (Expr -> Expr) -> Decl -> Decl
mapDeclBodies f (DFunDef pub n ps e site bid) = DFunDef pub n ps (f e) site bid
mapDeclBodies f (DLetGroup pub binds) =
  DLetGroup
    pub
    (map
      (b => match b
        LetBind n clauses site bid =>
          LetBind
            n
            (map
              (c => match c
                FunClause ps e => FunClause ps (f e))
              clauses)
            site
            bid)
      binds)
mapDeclBodies f (d@(DInterface { methods, ... })) = DInterface { d |
  methods =
    map
      (m => match m
        IfaceMethod n ty def mloc =>
          IfaceMethod
            n
            ty
            (map
              (dm => match dm
                MethodDefault ps e => MethodDefault ps (f e))
              def)
            mloc)
      methods,
}
mapDeclBodies f (d@(DImpl { methods, ... })) = DImpl { d |
  methods =
    map
      (m => match m
        ImplMethod n ps e => ImplMethod n ps (f e))
      methods,
}
mapDeclBodies f (DProp pub name params body) = DProp pub name params (f body)
mapDeclBodies f (DTest pub name body) = DTest pub name (f body)
mapDeclBodies f (DAttrib attrs d) = DAttrib attrs (mapDeclBodies f d)
-- a declaration with no expression body (data, signatures, imports, externs)
mapDeclBodies _ d = d

isSourceless : GraphCtx -> Int -> Bool
isSourceless gctx i = IdMap.has i gctx.graphRun.grants.gsSourceless.value

-- The interface word of the built-in class declaring an operator's method.  An
-- operator denotes the prelude's method whatever a module names in scope, so the
-- method nodes `dictPass` mints for operators and literals take their identity from
-- here rather than from the module's admission.
builtinMethodIfaceWord : GraphCtx -> String -> String
builtinMethodIfaceWord gctx method = match builtinClassOfMethod method
  Some c => ifaceWordOf (builtinClassOrigin gctx c) (builtinClassName c)
  None => ""

builtinClassOfMethod : String -> Option BuiltinClass
builtinClassOfMethod "eq" = Some BEq
builtinClassOfMethod "append" = Some BSemigroup
builtinClassOfMethod m
  | contains m ["compare", "lt", "gt", "lte", "gte"] = Some BOrd
  | contains m ["add", "sub", "mul", "div", "rem", "negate", "fromInt"] =
    Some BNum
  | otherwise = None

-- D3a/D3b-1: stamp each queued arg-position route from its now-resolved
-- discriminating arg mono.  D3b-1 first: a mono pinned to an impl's `requires`
-- element tyvar (registered in activeDictVars by registerImplRequires) → the
-- element dict param RDict $dict_<method>_<slot> — the ARGUMENT-position analogue
-- of resolveSite's return-position RDict.  Else (D3a): a concrete head
-- (Int/String/Float/… or any ADT tycon) → a static `RKey tag …`, and when that
-- head names a parametric impl WITH a requires, fill the impl-dicts ref so the
-- call threads the element dict (concrete element → RKey Int; a recursive element
-- of the SAME parametric type → RDict forwarding the in-scope dict param).  A
-- still-unsolved free type variable → left RNone (the emitter arg-tag-dispatches).
export
resolveArgStamps : SiteCtx -> List PendingEntry -> Unit
resolveArgStamps _sx [] = ()
resolveArgStamps sx ((PendingEntry name tagRef am encl kind loc scope _) :: rest) =
  let sx = { sx | sxSite = loc }
  match kind
    SKArg implRef fullMono omitted =>
      resolveArgStamp sx name tagRef implRef am fullMono omitted encl loc scope
    _ => ()
  resolveArgStamps sx rest

-- #156 S3c: a thin adapter over `entail` (EKArg kind).  `entail` returns
-- `(primaryRoute, elementRoutes)`; stamp them into (tagRef, implRef).  Reproduces the
-- pre-S3c arm-by-arm body: assum → `(RDict dname, [])`, inst → `(RKey key [],
-- argImplDictRoutesForEncl …)`, fallback → `(RNone, [])`.
-- TYPECHECK-AUDIT C7 (arg-position): when ≥2 impls of this method share head tycon [tag]
-- but differ in type ARGS (e.g. `MyPair Int Bool` vs `MyPair Bool Int`), bare-head `RKey
-- tag` narrows to the FIRST impl (eval's hasTag matches the head `t`).  `keyForSite`
-- (inside entailInst) upgrades to the canonical full-type impl key so eval's hasTag
-- matches the right impl's `k`.  No collision → bare head, unchanged.
-- tagRef is NOT always RNone-seeded: rewriteArgScoped (~7438) seeds a standalone-shadow
-- arg site to `RLocal <sym> []`.  At an `EKArg` site, `resolveRLocalSites` leaves that
-- importer seed untouched only for an ungrounded receiver or a grounded receiver with a
-- visible impl; a no-impl grounded receiver is restamped `RLocal`.  So the pre-S3c None
-- arm's `()` was load-bearing: it PRESERVED the seed until that receiver decision.  For
-- EKArg `entail` yields RNone ONLY from its fallback (assum→RDict,
-- inst→RKey), so guarding the stamp on RNone reproduces that do-nothing None arm exactly
-- and never clobbers an RLocal seed.  implRef is []-seeded everywhere (every EMethodAt
-- construction — 7313/7355/7356/7438/7441/7443 — uses `(Ref [])`, and only this resolver
-- ever writes an arg-site's implRef), so []-over-[] needs no guard (matches resolveSite).
resolveArgStamp : SiteCtx ->
  String ->
  Ref Route ->
  Ref (List Route) ->
  Mono ->
  Mono ->
  List (String, Mono) ->
  String ->
  Option Loc ->
  ScopeId ->
  Unit
resolveArgStamp sx name tagRef implRef am fullMono omitted encl _origin scope =
  let (route, routes) = entail sx name am encl scope (EKArg fullMono omitted)
  match route
    RNone => ()
    _ => tagRef := route
  implRef := routes

-- a method occurrence's route: if its discriminating type is a constrained
-- function's constraint variable, read that function's dict param (RDict);
-- otherwise the selected impl's key (RKey); an unresolved polymorphic type
-- stays RNone.  When the route resolves to a concrete head
-- that names a parametric impl WITH a `requires`, also fill the impl-dicts ref so
-- eval threads the element dict(s) into the impl body (Phase 83/84 single-level).
-- Phase 83/84 #5: stamp the route for one pending method site.  At a concrete
-- result type (ground RKey case) the element dict routes are computed recursively
-- by implDictRoutesFor.  At a polymorphic result type (RDict case) the route is
-- RDictFwd for return-position methods — eval will extract and forward the
-- enclosing VDict's nested requires at runtime.  Arg-position methods (display/==)
-- stay RDict; their VMulti dispatch is by arg-tag, not by the forwarded reqs.
-- TYPECHECK-AUDIT C7: the ground RKey case prefers the canonical impl KEY (via
-- keyForSite) over the bare head tycon, so two non-overlapping impls sharing a
-- head tycon (Pair Int Bool vs Pair Bool Int) route to distinct keys; eval's
-- narrowMethod then matches the right VTypedImpl by its key field.  No selected
-- row → no route (`RNone`).
-- C5 NOTE: standalone-shadow RLocal routing is NOT done here — a return-position
-- site keys off the RESULT mono (`isEmpty`'s `Bool`), which never names the receiver's
-- impl, so this gate would mis-route every shadow method.  RLocal is stamped by the
-- arg-position resolveRLocalSites (keyed on the RECEIVER mono) AFTER resolveSites.
export
resolveSite : SiteCtx ->
  OrdMap Unit ->
  String ->
  Ref Route ->
  Ref (List Route) ->
  Mono ->
  Mono ->
  String ->
  Option Loc ->
  ScopeId ->
  Unit
-- #156 S3b: a thin adapter over `entail` (EKReturn kind).  `entail` returns
-- `(primaryRoute, elementRoutes)`; stamp them into (tagRef, implRef).  Reproduces the
-- pre-S3b arm-by-arm body: assum → `(RDictFwd/RDict, [])`, inst → `(RKey key [],
-- selected-row prerequisite routes)`, fallback → `(RNone, [])`.
-- tagRef is NOT always RNone-seeded: a P0-18 standalone-shadow site seeds it to
-- `RLocal <sym> []` at rewriteArgScoped (~7438).  A return-position standalone value
-- shadow is then force-stamped `RLocal` by `resolveRLocalSites`; an argument-position
-- importer shadow is the separate receiver-sensitive case described at `resolveArgStamp`.
-- The pre-S3b None arm's `()` was load-bearing: it PRESERVED that RLocal seed.  For
-- EKReturn `entail` yields RNone ONLY from its fallback (assum→RDict/RDictFwd, inst→RKey),
-- so guarding the stamp on RNone reproduces that do-nothing None arm exactly and never
-- clobbers an RLocal seed.  implRef is []-seeded everywhere, so []-over-[] needs no guard.
resolveSite sx rpNames name tagRef implRef resultMono fullMono encl _origin scope =
  let (route, routes) =
    entail
      sx
      name
      resultMono
      encl
      scope
      (EKReturn fullMono (omHasKey name rpNames))
  match route
    RNone => ()
    _ => tagRef := route
  implRef := routes

-- An admitted-set occurrence's route, committed by `admittedSelection`, the function
-- that decides its verdict in the same drain (`runStampCtx`): the selected instance's
-- canonical key and prerequisites, and the selecting declaration's interface word on
-- the occurrence, which carried none while its spelling named two or more.  Any
-- other answer is rejected there, and the site keeps no route.
export
resolveAdmittedSite : SiteCtx ->
  String ->
  Ref String ->
  Ref Route ->
  Ref (List Route) ->
  Mono ->
  String ->
  ScopeId ->
  Unit
resolveAdmittedSite sx name ifaceRef tagRef implRef fullMono encl scope =
  match (admittedSelection
    sx
    sx.sxModule.mcCells.bodyImplEnvRef.value
    name
    fullMono)
    Selects iface row goals =>
      ifaceRef := ifaceWordOf iface.irOrigin iface.irName
      tagRef :=
        RKey
          (rowRouteKey row)
          []
          (selectedCallSupers sx name (Some row) encl scope goals)
      implRef := implDictRoutesForRow sx encl scope goals row
    _ => ()

export
resolveExactReturnSite : SiteCtx ->
  OrdMap Unit ->
  String ->
  Ref Route ->
  Ref (List Route) ->
  Mono ->
  MethodReturnRequest ->
  String ->
  Option Loc ->
  ScopeId ->
  Unit
resolveExactReturnSite sx rpNames name tagRef implRef resultMono request encl origin scope =
  if methodReturnAmbiguousWithoutGiven sx.sxModule request then
    noteMethodReturnTrace sx.sxModule MRTStamped request None []
  else match methodReturnArgs sx.sxModule.mcGraph request
    None =>
      noteMethodReturnTrace sx.sxModule MRTStamped request None []
      resolveSite
        sx
        rpNames
        name
        tagRef
        implRef
        resultMono
        request.mrrOccurrence
        encl
        origin
        scope
    Some _ =>
      let resolution = solveExactReturnOnce sx request
      if methodReturnResolutionValid sx.sxModule request resolution then
        ()
      else
        panic "ordinary return route received invalid solver evidence"
      let (route, routes) =
        exactReturnRoutes sx name encl scope (omHasKey name rpNames) resolution
      noteMethodReturnTrace sx.sxModule MRTStamped request (Some route) routes
      match route
        RNone => ()
        _ => tagRef := route
      implRef := routes

export
resolveNumLitSite : SiteCtx ->
  OrdMap Unit ->
  String ->
  Ref Route ->
  Mono ->
  Mono ->
  ClassPredicate ->
  String ->
  Option Loc ->
  ScopeId ->
  Unit
resolveNumLitSite sx rpNames name tagRef resultMono fullMono predicate encl origin scope =
  let (route, routes) =
    entail
      sx
      name
      resultMono
      encl
      scope
      (EKNumReturn predicate fullMono (omHasKey name rpNames) origin)
  match route
    RNone => ()
    _ => tagRef := numericReturnRoute route routes
  ()

export
resolveArithSite : Ref Route -> Mono -> Unit
resolveArithSite dref m = match !dref
  RNone => match arithmeticTag m
    Some tag => dref := RScalar tag
    None => ()
  _ => ()

-- #156 S3c: a thin adapter over `entail` (EKOp kind).  `entail`'s ladder IS this
-- resolver's ladder: assum = opDictVarOf → RDict; inst = stampOpRouteVal (builtin head →
-- RNone; else RKey with the element reqs PACKED in, so `snd` is empty and no separate
-- implRef exists); fallback = RNone.  Op-site route cells are minted `RNone`-seeded
-- (`mintOpSite`), and the mark pass mints each site once, so the two do-nothing arms
-- (builtin-inst, fallback) both yield RNone and the RNone guard preserves that seed.
export
resolveOpSite : SiteCtx ->
  Bool ->
  String ->
  Ref Route ->
  Mono ->
  Bool ->
  String ->
  ScopeId ->
  Unit
resolveOpSite sx isBinop method tagRef operandMono inImpl encl scope =
  match fst (entail sx method operandMono encl scope (EKOp isBinop inImpl))
    RNone => ()
    route => tagRef := route

export
resolvePredicateOpSite : SiteCtx ->
  Bool ->
  String ->
  Ref Route ->
  Mono ->
  Bool ->
  ClassPredicate ->
  String ->
  ScopeId ->
  Unit
resolvePredicateOpSite sx isBinop method tagRef operandMono inImpl predicate encl scope =
  match (fst
    (entail
      sx
      method
      operandMono
      encl
      scope
      (EKPredicateOp isBinop inImpl predicate)))
    RNone => ()
    route => tagRef := route

-- Phase 69.x-e: fill each method occurrence's method-dicts ref — one route per
-- method-level constraint, from the instantiated constraint mono.  A concrete head
-- → RKey (eval supplies a literal VDict for the body's `empty`/… to read); a
-- constraint variable still (the caller is itself constrained) → RDict forwarding
-- the caller's dict.  Mirrors resolveDictApps; runs after inference.
export
resolveMethodDicts : SiteCtx -> List PendingMethodDict -> Unit
resolveMethodDicts _sx [] = ()
resolveMethodDicts sx (pending :: rest) =
  pending.pmdRoutesRef :=
    methodPredicateRoutes sx pending.pmdEncl pending.pmdScope pending.pmdSlots
  resolveMethodDicts sx rest

-- fill each constrained-fn call site's routes: one route per constraint mono.  A
-- mono pinned to a concrete head → RKey; still a constraint variable (a nested
-- constrained call) → RDict; otherwise RNone.
export
resolveDictApps : SiteCtx -> List PendingDictApp -> Unit
resolveDictApps _sx [] = ()
resolveDictApps sx (app :: rest) =
  let sx = { sx | sxSite = app.pdaLoc }
  let routes =
    routesOfMonosTopV
      sx
      app.pdaEncl
      app.pdaScope
      app.pdaMonos
      app.pdaIfaces
      app.pdaArgVecs
  app.pdaRoutesRef := routes
  resolveDictApps sx rest

-- A deferred recursive call records one route per the CALLEE's constraint slot
-- (matching the dict params dict_pass prepends to its def), each forwarding the
-- ENCLOSING fn's own dict param.  Run after inference, when `funPredicateSlotsRef` is
-- fully populated.
export
realizeRecDictApps : SiteCtx -> List RecDictApp -> Unit
realizeRecDictApps _sx [] = ()
realizeRecDictApps sx ((RecDictApp routesRef callee encl mono scope _) :: rest) =
  let slots =
    optionOr
      []
      (lookupPredicateSlots
        callee
        sx.sxModule.mcCells.funPredicateSlotsIdxRef.value)
  let routes = recRoutes sx encl scope mono slots
  routesRef := routes
  realizeRecDictApps sx rest

-- ── dict_pass: prepend dict parameters to constrained function definitions ──
-- For each top-level def of a name in [dictNames], prepend one `$dict_<fn>_<slot>`
-- parameter per constraint (arity from `funPredicateSlotsRef`, populated during
-- inference), matching the dicts EDictAt applies at call sites.  Multi-clause
-- functions are several DFunDef decls; each clause gets the same leading params.
-- #2189: [names] is the dict-passed set, which grows with the program, and this
-- maps over every decl, so a `contains n names` scan inside `dictPassDecl` is
-- O(decls x names).  The set is indexed once here; `dictPassDecl`/`dictPassLetBind`
-- probe it with `omHasKey`.
dictPass : ModuleCtx ->
  EvIndex ->
  String ->
  List String ->
  List Decl ->
  List Decl
dictPass mctx idx mid names prog =
  let pe = PassEvidence idx (Ref omEmpty)
  map
    (dictPassDecl
      mctx
      pe
      (omFromNames names omEmpty)
      (returnPosMethodNames prog))
    (mapProg
      (e => rewriteLocalDictExpr mctx.mcGraph (rewriteBinopExpr mctx pe e))
      (grantPass mctx.mcGraph pe mid prog))

passIndex : PassEvidence -> EvIndex
passIndex (PassEvidence idx _) = idx

-- The entry published for method occurrence [ev].  A miss in both is the index's
-- miss.
passMethodOf : PassEvidence -> EvId -> PassMethod
passMethodOf (PassEvidence idx minted) ev =
  match evidenceLookup (Some idx) "method occurrence" ev
    Ok v => passMethodFacts v
    Err message => match omLookup (intToString (evOrdinal ev)) minted.value
      Some v => passMethodFacts v
      None => panic message

passMethodFacts : EvVal -> PassMethod
passMethodFacts (EvMethod iface _ tag impls meths) =
  PassMethod iface tag (impls ++ meths)
passMethodFacts _ =
  panic "evidence table: a method occurrence answered by another kind of entry"

-- ── grant passing: the authority analogue of the dictionary pass ─────────────
-- Runs before the dictionary rewrites of module [mid], so a binder's authority
-- parameters land after the dictionary parameters those rewrites prepend, and
-- each recorded use is applied to its grants while it still carries its id.
grantPass : GraphCtx -> PassEvidence -> String -> List Decl -> List Decl
grantPass gctx pe mid prog =
  let st = gctx.graphRun.grants
  let saved = st.gsPassingModule.value
  st.gsPassingModule := mid
  let result = map (grantDecl gctx pe mid) prog
  st.gsPassingModule := saved
  result

grantDecl : GraphCtx -> PassEvidence -> String -> Decl -> Decl
grantDecl gctx pe mid (DFunDef pub n pats body site bid) =
  DFunDef
    pub
    n
    (grantParamPats (topGrantIds gctx mid n) n ++ pats)
    (grantBody gctx pe body)
    site
    bid
grantDecl gctx pe mid (DLetGroup pub binds) =
  DLetGroup
    pub
    (map
      (b => match b
        LetBind n clauses site bid =>
          grantLetBind
            gctx
            pe
            (grantParamPats (topGrantIds gctx mid n) n)
            (LetBind n clauses site bid))
      binds)
grantDecl gctx pe _ (d@(DInterface { name, ifaceOrigin, methods, ... })) = DInterface { d |
  methods =
    map (grantIfaceMethod gctx pe (ifaceWordOf ifaceOrigin name)) methods,
}
grantDecl gctx pe _ (d@(DImpl { iface, implOrigin, methods, ... })) = DImpl { d |
  methods = map (grantImplMethod gctx pe (ifaceWordOf implOrigin iface)) methods,
}
grantDecl gctx pe _ (DProp pub name params body) =
  DProp pub name params (grantExpr gctx pe body)
grantDecl gctx pe _ (DTest pub name body) =
  DTest pub name (grantExpr gctx pe body)
grantDecl gctx pe mid (DAttrib attrs d) =
  DAttrib attrs (grantDecl gctx pe mid d)
-- a declaration with no expression body (data, signatures, imports, externs)
grantDecl _gctx _ _ d = d

-- A method that takes grants declares them after its value arguments, so the
-- arity every backend reads off the declaration counts them.
grantIfaceMethod : GraphCtx ->
  PassEvidence ->
  String ->
  IfaceMethod ->
  IfaceMethod
grantIfaceMethod gctx pe word (IfaceMethod n ty def mloc) =
  match methodGrantOf gctx word n
    None =>
      IfaceMethod
        n
        ty
        (map
          (d => match d
            MethodDefault ps e => MethodDefault ps (grantBody gctx pe e))
          def)
        mloc
    Some mg =>
      IfaceMethod
        n
        (insertGrantArrows mg.mgArity (listLen mg.mgNames) ty)
        (map
          (d => match d
            MethodDefault ps e =>
              let (ps2, e2) =
                grantMethodParams gctx mg n ps (grantBody gctx pe e)
              MethodDefault ps2 e2)
          def)
        mloc

grantImplMethod : GraphCtx -> PassEvidence -> String -> ImplMethod -> ImplMethod
grantImplMethod gctx pe word (ImplMethod n ps e) =
  match methodGrantOf gctx word n
    None => ImplMethod n ps (grantBody gctx pe e)
    Some mg =>
      let (ps2, e2) = grantMethodParams gctx mg n ps (grantBody gctx pe e)
      ImplMethod n ps2 e2

-- A method clause's grant parameters, after its value parameters; a clause
-- written with fewer parameters than the method's arity takes the missing ones
-- first and applies its body to them.
grantMethodParams : GraphCtx ->
  MethodGrant ->
  String ->
  List Pat ->
  Expr ->
  (List Pat, Expr)
grantMethodParams gctx mg n ps body =
  let grants = grantParamPats mg.mgNames n
  let given = listLen ps
  if given >= mg.mgArity then
    (take mg.mgArity ps ++ grants ++ drop mg.mgArity ps, body)
  else
    let missing =
      map (_ => freshGrantName gctx.graphRun.grants ()) (range given mg.mgArity)
    (
      ps ++ map (x => PVar x (Loc "" 0 0 0 0) noBinderId) missing ++ grants,
      applyExprs body (map EVar missing),
    )

-- [g] `List String` arguments after the first [k] arrows of a method's type.
insertGrantArrows : Int -> Int -> Ty -> Ty
insertGrantArrows k g (TyConstrained cs t) =
  TyConstrained cs (insertGrantArrows k g t)
insertGrantArrows k g (TyEffect effs tails t)
  | k > 0 = TyEffect effs tails (insertGrantArrows k g t)
insertGrantArrows k g (TyFun a b)
  | k > 0 = TyFun a (insertGrantArrows (k - 1) g b)
insertGrantArrows _ g t = grantArrows g t

grantArrows : Int -> Ty -> Ty
grantArrows g t
  | g <= 0 = t
  | otherwise =
    TyFun
      (TyApp (tyConBuiltin "List" None) (tyConBuiltin "String" None))
      (grantArrows (g - 1) t)

grantLetBind : GraphCtx -> PassEvidence -> List Pat -> LetBind -> LetBind
grantLetBind gctx pe params (LetBind n clauses site bid) =
  LetBind
    n
    (map
      (c => match c
        FunClause ps body => FunClause (params ++ ps) (grantBody gctx pe body))
      clauses)
    site
    bid

topGrantIds : GraphCtx -> String -> String -> List Int
topGrantIds gctx mid n =
  optionOr [] (omLookup (grantTopKey mid n) gctx.graphRun.grants.gsTopIds.value)

localGrantIds : GraphCtx -> String -> List Int
localGrantIds gctx n =
  optionOr [] (omLookup n gctx.graphRun.grants.gsLocalIds.value)

grantParamName : String -> Int -> String
grantParamName n i = "$auth_\{n}_\{intToString i}"

grantParamPats : List a -> String -> List Pat
grantParamPats ids n =
  map
    (i => PVar (grantParamName n i) (Loc "" 0 0 0 0) noBinderId)
    (range 0 (listLen ids))

-- The top-down walk: a use of a file extern or a method is rebuilt with every
-- argument it takes, so it sees its whole application spine before its
-- arguments do.
grantExpr : GraphCtx -> PassEvidence -> Expr -> Expr
grantExpr gctx pe e =
  let inner = grantExprInner gctx pe e
  let st = gctx.graphRun.grants
  match st.gsValueBounds.value
    Tip => inner
    _ => match fileValueKey st.gsPassingModule.value e
      Some key =>
        let bounds = optionOr [] (omLookup key st.gsValueBounds.value)
        fold
          (result (ty, chain) => fileBoundValue gctx chain ty result)
          inner
          bounds
      None => inner

grantExprInner : GraphCtx -> PassEvidence -> Expr -> Expr
grantExprInner gctx pe (ELam pats body) = ELam pats (grantBody gctx pe body)
grantExprInner gctx pe (e@(EApp _ _)) = match grantSpine e []
  (EDictAt n ev, args) => match grantOccOf gctx ev
    Some occ => match occ.goTrailing
      Some arity =>
        saturateGrants
          gctx.graphRun.grants
          (EVar n)
          arity
          (grantTerms gctx occ)
          (map (grantExpr gctx pe) args)
      None => mapChildren (grantExpr gctx pe) e
    None => mapChildren (grantExpr gctx pe) e
  (EMethodAt n seed ev, args) => match methodGrantUse gctx pe n ev
    MethodGrants arity grants =>
      saturateGrants
        gctx.graphRun.grants
        (EMethodAt n seed ev)
        arity
        grants
        (map (grantExpr gctx pe) args)
    LeadingGrants _ grants =>
      applyExprs
        (applyExprs (EMethodAt n seed ev) grants)
        (map (grantExpr gctx pe) args)
    NoGrants => mapChildren (grantExpr gctx pe) e
  _ => mapChildren (grantExpr gctx pe) e
grantExprInner gctx _ (EDictAt n ev) = grantUse gctx n ev
grantExprInner gctx pe (EMethodAt n seed ev) = match methodGrantUse gctx pe n ev
  MethodGrants arity grants =>
    saturateGrants gctx.graphRun.grants (EMethodAt n seed ev) arity grants []
  LeadingGrants _ grants => applyExprs (EMethodAt n seed ev) grants
  NoGrants => EMethodAt n seed ev
grantExprInner gctx pe (ELet m r (PVar x xloc bid) e1 e2) =
  ELet
    m
    r
    (PVar x xloc bid)
    (grantLocalRhs gctx x (grantExpr gctx pe e1))
    (grantExpr gctx pe e2)
grantExprInner gctx pe (ELetGroup binds body) =
  ELetGroup
    (map
      (b => match b
        LetBind x clauses site bid =>
          grantLetBind
            gctx
            pe
            (grantParamPats (localGrantIds gctx x) x)
            (LetBind x clauses site bid))
      binds)
    (grantExpr gctx pe body)
grantExprInner gctx pe (EBlock stmts) = EBlock (map (grantStmt gctx pe) stmts)
-- every other node: its children, through the one traversal every pass shares
grantExprInner gctx pe e = mapChildren (grantExpr gctx pe) e

grantStmt : GraphCtx -> PassEvidence -> DoStmt -> DoStmt
grantStmt gctx pe (DoLet m r (PVar x xloc bid) e site) =
  DoLet m r (PVar x xloc bid) (grantLocalRhs gctx x (grantExpr gctx pe e)) site
grantStmt gctx pe (DoExpr e) = DoExpr (grantExpr gctx pe e)
grantStmt gctx pe (DoBind p e) = DoBind p (grantExpr gctx pe e)
grantStmt gctx pe (DoLet m r p e site) = DoLet m r p (grantExpr gctx pe e) site
grantStmt gctx pe (DoAssign x e) = DoAssign x (grantExpr gctx pe e)
grantStmt gctx pe (DoFieldAssign x fs e) =
  DoFieldAssign x fs (grantExpr gctx pe e)

-- A local that quantifies authorities takes them ahead of its own parameters.
grantLocalRhs : GraphCtx -> String -> Expr -> Expr
grantLocalRhs gctx x e = match localGrantIds gctx x
  [] => e
  ids =>
    prependLocalDicts (map (i => grantParamName x i) (range 0 (listLen ids))) e

-- An application spine's head and its arguments, through source-location
-- wrappers.
grantSpine : Expr -> List Expr -> (Expr, List Expr)
grantSpine (EApp f x) args = grantSpine f (x :: args)
grantSpine (ELoc _ e) args = grantSpine e args
-- any other node is the head
grantSpine e args = (e, args)

-- A use of a source binding: the head applied to its grants.  A grant-only use
-- of a binding that quantifies nothing is the plain variable it stood for.
grantUse : GraphCtx -> String -> EvId -> Expr
grantUse gctx n ev =
  let head = if isGrantOnlyEv gctx ev then EVar n else EDictAt n ev
  match grantOccOf gctx ev
    None => head
    Some occ => match occ.goTrailing
      Some arity =>
        saturateGrants
          gctx.graphRun.grants
          (EVar n)
          arity
          (grantTerms gctx occ)
          []
      None => applyExprs head (grantTerms gctx occ)

-- A method occurrence's grants.  One that dispatches passes the method's, after
-- the value arity its written type spells; a use that inference did not record
-- (its denotation was settled by a path that instantiates no method scheme) passes
-- the empty authority, so the method's arity still agrees with every body and the
-- use is refused rather than admitted.  One routed to the standalone its name
-- shadows passes that binding's grants, which inference recorded when it typed
-- the occurrence as the standalone; a grant-taking standalone reached without that
-- record has no grants to pass, and is a compile-time failure.  The occurrence's
-- published arity counts the grants, as the backends read it; the published table
-- is read out of the cells after the pass, so that count is written to the
-- occurrence's cell (`setOccurrenceArity`).
methodGrantUse : GraphCtx -> PassEvidence -> String -> EvId -> MethodGrantUse
methodGrantUse gctx pe n ev =
  let (PassMethod iface tag _) = passMethodOf pe ev
  let recorded = grantOccOf gctx ev
  let use = match tag
    RLocal sym _ => match standaloneOcc recorded
      Some (arity, occ) => LeadingGrants arity (grantTerms gctx occ)
      None =>
        if omHasKey
          (if sym == "" then n else sym)
          gctx.graphRun.grants.gsTakers.value then
          panic
            "grant pass: '\{n}' is routed to a standalone binding that takes authority grants, but inference did not type this use as that binding"
        else
          NoGrants
    _ => match methodGrantOf gctx iface n
      None => NoGrants
      Some mg => match recorded
        Some occ =>
          if occ.goStandalone then
            MethodGrants mg.mgArity (map (_ => bottomGrant) mg.mgNames)
          else
            MethodGrants mg.mgArity (methodTerms gctx n mg occ)
        None => MethodGrants mg.mgArity (map (_ => bottomGrant) mg.mgNames)
  match use
    MethodGrants arity grants =>
      setOccurrenceArity gctx pe ev (arity + listLen grants)
    LeadingGrants arity grants =>
      setOccurrenceArity gctx pe ev (arity + listLen grants)
    NoGrants => ()
  use

-- An occurrence in a module the drive served has no cell in this lineage: its
-- entry in the index takes the count (`setServedArity`).
setOccurrenceArity : GraphCtx -> PassEvidence -> EvId -> Int -> Unit
setOccurrenceArity gctx pe ev arity
  | evOrdinal ev < gctx.graphRun.evBase = setServedArity (passIndex pe) ev arity
  | otherwise =
    let cell = methodCellOf gctx ev
    cell.ecArity := Some arity

-- A use recorded as the standalone binding a method occurrence shadows, with its
-- value arity.
standaloneOcc : Option GrantOcc -> Option (Int, GrantOcc)
standaloneOcc (Some occ) = match (occ.goStandalone, occ.goTrailing)
  (True, Some arity) => Some (arity, occ)
  _ => None
standaloneOcc None = None

-- A recorded method use's grants, one per authority the method quantifies.
methodTerms : GraphCtx -> String -> MethodGrant -> GrantOcc -> List Expr
methodTerms gctx n mg occ =
  let terms = grantTerms gctx occ
  if listLen terms == listLen mg.mgNames then
    terms
  else
    panic
      "grant pass: a use of method '\{n}' instantiated \{intToString (listLen terms)} authorities, but the method takes \{intToString (listLen mg.mgNames)} grants"

-- The empty authority: a grant that admits no path.
bottomGrant : Expr
bottomGrant = EListLit [ELit (LString "")]

applyExprs : Expr -> List Expr -> Expr
applyExprs f args = fold (acc a => EApp acc a) f args

-- A head applied to all [arity] value arguments and then its grants.  A partial
-- or value use becomes a function of the arguments still missing; the arguments
-- it was given are bound first, so each is evaluated once, where the program
-- wrote it.
saturateGrants : GrantState -> Expr -> Int -> List Expr -> List Expr -> Expr
saturateGrants st head arity grants args =
  let given = listLen args
  if given >= arity then
    applyExprs (applyExprs head (take arity args ++ grants)) (drop arity args)
  else
    let bound = map (a => (freshGrantName st (), a)) args
    let missing = map (_ => freshGrantName st ()) (range given arity)
    let call =
      applyExprs
        head
        (map (b => EVar (fst b)) bound ++ map EVar missing ++ grants)
    fold
      (body b =>
        ELet
          noDeclLoc
          False
          (PVar (fst b) (Loc "" 0 0 0 0) noBinderId)
          (snd b)
          body)
      (ELam (map (x => PVar x (Loc "" 0 0 0 0) noBinderId) missing) call)
      (reverse bound)

freshGrantName : GrantState -> Unit -> String
freshGrantName st _ =
  let k = st.gsFresh.value
  st.gsFresh := k + 1
  "$grant_arg_\{intToString k}"

-- Evaluate a function-valued expression once. Its bound becomes active on
-- application, and the returned function (if any) retains its own arrow rows.
fileBoundValue : GraphCtx -> List GrantBinder -> Mono -> Expr -> Expr
fileBoundValue gctx chain ty e =
  if hasFileBoundValue ty then match normalize ty
    TFun _ row result =>
      let fn = freshGrantName gctx.graphRun.grants ()
      let arg = freshGrantName gctx.graphRun.grants ()
      ELet
        noDeclLoc
        False
        (PVar fn (Loc "" 0 0 0 0) noBinderId)
        e
        (ELam
          [PVar arg (Loc "" 0 0 0 0) noBinderId]
          (fileBoundExpr
            gctx
            chain
            row
            (fileBoundValue gctx chain result (EApp (EVar fn) (EVar arg)))))
    TQual inner _ => fileBoundValue gctx chain inner e
    _ => e
  else
    e

grantBody : GraphCtx -> PassEvidence -> Expr -> Expr
grantBody gctx pe body =
  let inner = grantExpr gctx pe body
  match gctx.graphRun.grants.gsBounds.value
    Tip => inner
    boundsBySite =>
      let bounds = match fileBodyLoc body
        Some loc =>
          optionOr
            []
            (omLookup
              (fileBoundSite gctx.graphRun.grants.gsPassingModule.value loc)
              boundsBySite)
        None => []
      fold
        (result (row, chain) => fileBoundExpr gctx chain row result)
        inner
        bounds

fileBoundExpr : GraphCtx -> List GrantBinder -> EffRow -> Expr -> Expr
fileBoundExpr gctx chain row body =
  let (atoms, tails) = rowFlat row
  if isNonEmptyL tails then
    body
  else
    fold
      (result atom =>
        let label = atomLabel atom
        if narrowFileAtom atom then
          applyExprs (EVar ("$with" ++ label ++ "Bound")) [
            grantTerm gctx chain (atomAuth atom),
            ELam [PWild] result,
          ]
        else
          result)
      body
      atoms

-- The grant terms of one use, one per authority the callee quantifies.
grantTerms : GraphCtx -> GrantOcc -> List Expr
grantTerms gctx occ = match occ.goRecIds
  [] => map (grantTerm gctx occ.goChain) occ.goCells
  ids => map (i => grantIdTerm gctx occ.goChain i) ids

-- The whole domain is the empty list, the empty authority a list holding only the
-- empty element (it admits no path), and a set of elements joined with the
-- parameters of enclosing binders is their concatenation.  A variable is the
-- parameter of the innermost enclosing binder that quantifies it.  Two kinds of
-- variable have no caller to supply them, an opened existential and an instance
-- head's index (`markSourceless`), and each is the whole domain: the escape check
-- has held the declaration it reaches to its label's top.  Any other variable
-- whose binder is not found contributes the empty authority, so a lost binder is
-- a refusal at run time rather than an unconfined operation.
grantTerm : GraphCtx -> List GrantBinder -> Authority -> Expr
grantTerm gctx chain a = match authGrantShape a
  GrantTop => EListLit []
  GrantBottom => bottomGrant
  GrantParts elems vars => match grantVarParams gctx chain vars []
    None => EListLit []
    Some params =>
      let parts =
        (if isEmptyL elems then
            []
          else
            [EListLit (map (s => ELit (LString s)) elems)])
          ++ map EVar (dedup params)
      match parts
        [] => bottomGrant
        [p] => p
        p :: rest =>
          fold
            (acc param => topAbsorbs param acc)
            -- Generated after inference: the list identity supplies the operand
            -- representation that a hidden grant parameter alone cannot carry.
            (fold
              (acc q => EBinOp "++" acc q unminted)
              (EListLit [])
              (p :: rest))
            (dedup params)

-- The parameters a join's variables are, or None when one of them has no caller
-- to supply it and so makes the join the whole domain.  A variable whose binder
-- is not found contributes nothing.
grantVarParams : GraphCtx ->
  List GrantBinder ->
  List (Ref Authvar) ->
  List String ->
  Option (List String)
grantVarParams _gctx _ [] acc = Some (reverse acc)
grantVarParams gctx chain (v :: rest) acc =
  match grantParamFor gctx chain (authvarId v)
    Some p => grantVarParams gctx chain rest (p :: acc)
    None =>
      if isSourceless gctx (authvarId v) then
        None
      else
        grantVarParams gctx chain rest acc

-- A parameter holding the whole domain makes a join it is part of the whole
-- domain; concatenation alone would narrow it to the other parts.
topAbsorbs : String -> Expr -> Expr
topAbsorbs param join =
  EMatch (EVar param) [Arm (PList []) [] (EListLit []), Arm PWild [] join]

-- A recursive use forwards its enclosing binder's parameters; one whose binder is
-- not found is the empty authority, as in `grantTerm`.
grantIdTerm : GraphCtx -> List GrantBinder -> Int -> Expr
grantIdTerm gctx chain i = match grantParamFor gctx chain i
  Some p => EVar p
  None => bottomGrant

-- The parameter of the innermost enclosing binder that quantifies authority [i].
grantParamFor : GraphCtx -> List GrantBinder -> Int -> Option String
grantParamFor _gctx [] _ = None
grantParamFor gctx (b :: rest) i =
  let (name, ids) = match b
    TopGrantBinder mid n => (n, topGrantIds gctx mid n)
    LocalGrantBinder n => (n, localGrantIds gctx n)
    BodyGrantBinder n bound => (n, bound)
  match elemIndex i ids
    Some k => Some (grantParamName name k)
    None => grantParamFor gctx rest i

-- Routed operators become method applications, including generic arithmetic.
-- Packed instance prerequisites move into EMethodAt's implementation-dictionary
-- routes. RNone and scalar routes preserve primitive operations, so primitive
-- Num method bodies do not recursively call their own dictionary methods.
rewriteBinopExpr : ModuleCtx -> PassEvidence -> Expr -> Expr
rewriteBinopExpr mctx pe (EBinOp op l r ev) =
  match evSiteRouteIn (passIndex pe) ev
    RNone => EBinOp op l r ev
    -- SHARED-FLOAT-RESIDUAL §3(C): an RScalar route is NOT a typeclass dispatch — it
    -- is the scalar-type tag typecheck stamped on a monomorphic binop
    -- (its primitive head on arithmetic, an allowed comparison tag on comparison).
    -- Lowering does not read the
    -- EBinOp's site id, so we carry the scalar type in a NODE by wrapping the binop
    -- in `EAnnot … (TyCon tag)`.  Eval ignores the
    -- annotation (`eval (EAnnot e _) = eval e`) and evaluates the binop dynamically
    -- (Float-correct); lowering reads the annotation to stamp CBinPrim's scalar tag so
    -- the native emitter picks that type's primitive without reading the operands'
    -- structure.  This is the dispatch route READ-OUT the design names, relocated
    -- from the (lost) ref cell to a (surviving) node.
    --
    -- #1110 (was a residual, DRAINED by the stamping PR): `tag` is a SCALAR-TYPE
    -- TAG this pass synthesises (never a head the user wrote), and this runs AFTER
    -- resolve, so nothing downstream would ever stamp it.  It takes the same
    -- treatment as `parser.mdk`'s tuple head — the reserved BUILTIN origin, not the
    -- module under elaboration, which resolve does not know and this pass would be
    -- inventing.  Its only reader is `ir/core_ir_lower.mdk`'s
    -- `lower (EAnnot (EBinOp …) (TyCon { tyConName }))`, which takes the NAME and
    -- nothing else, so the origin is unobserved either way — but `OriginBuiltin` is
    -- the TRUE identity of a scalar tag, and leaving `OriginUnresolved` on a
    -- post-resolve node would keep the §8 I6.3 sentinel alive for no reason.
    RScalar tag => EAnnot (EBinOp op l r ev) (tyConBuiltin tag None)
    route => binopMethodApp mctx pe op l r route
-- PLAN.md #11: re-tag a source integer literal to its inferred runtime rep, a 3-way
-- decision.  setNumlitFloats already
-- decided: float cell `Some f` ⇒ concrete Float ⇒ `ELit (LFloat f)`; otherwise the
-- route cell [dref] distinguishes concrete-Int (RNone, cleared) from a surviving
-- polymorphic `Num a` (a non-RNone RDictFwd/RKey route, the soundness case) — the
-- latter dispatches through the runtime Num dict via `fromInt n` (the SAME dict the
-- enclosing `Num a => …` function threads), closing the hole where `inc x = x + 1`
-- instantiated at Float crashed `VFloat + VInt`.  A selected Num impl's prerequisite
-- routes are packed in [dref] and split onto the EMethodAt impl-dict carrier here.
-- Done in the same mapProg walk that rewrites binops, so
-- eval/lower never see ENumLit and eval_arith / the emitter get matching tags.
rewriteBinopExpr mctx pe (ENumLit n ev _) = match evSiteLitIn (passIndex pe) ev
  (Some f, _) => ELit (LFloat f)
  (None, dref) => match dref
    RNone => ELit (LInt n)
    route if fixedWidthLiteralFits route n => ELit (LInt n)
    route if u64LiteralFits route n =>
      ELit (LU64 (n / 4294967296) (n % 4294967296))
    RKey word _ _ if isI64Head (literalRouteHead word) =>
      let halves = int64Halves n
      ELit (LI64 (fst halves) (snd halves))
    route =>
      let split = binopRouteSplit route
      EApp
        (EMethodAt
          "fromInt"
          ""
          (mintMethodCellWith
            mctx
            pe
            (builtinMethodIfaceWord mctx.mcGraph "fromInt")
            1
            (fst split)
            (snd split)))
        (ELit (LInt n))
-- Roadmap #18c: rewrite each *stamped* EUnOp (`-` → `negate`) into its Num
-- method application via EMethodAt, exactly like the EBinOp arm above.  A site
-- whose operand is a non-primitive instance or a dictionary carries a dispatch
-- route; Int/Float (RNone or a scalar tag) stay the literal EUnOp the eval builtin handles
-- structurally (no recursion — Int's own `negate` body uses the BINOP `0 - a`, and
-- Float's unary minus has a scalar operand).  `!` never routes (stays RNone).
rewriteBinopExpr mctx pe (EUnOp op e ev) = match evSiteRouteIn (passIndex pe) ev
  RNone => EUnOp op e ev
  -- a primitive operand's scalar tag: the builtin negation, as for an unrouted site
  RScalar _ => EUnOp op e ev
  RKey word _ _ if op == "-"
    && isI32Head (literalRouteHead word)
    && isSome (negatedI32Lit e) => ELit (LInt (optionOr 0 (negatedI32Lit e)))
  route => unopMethodApp mctx pe op e route
-- A wide literal is a `U64` or `I64` constant (`checkWideLiterals` has refused it
-- at any other type, so a program that reaches eval/emit only has it at those).
-- At `I64` the halves are the pattern of the magnitude; a `-` around it is the
-- wrapping negation that makes `-2^63` `minBound`.
rewriteBinopExpr _mctx pe (EWideLit hi lo ev _) =
  match evSiteRouteIn (passIndex pe) ev
    RKey word _ _ if isI64Head (literalRouteHead word) => ELit (LI64 hi lo)
    _ => ELit (LU64 hi lo)
rewriteBinopExpr _mctx _ e = e

-- `-N` at `I32` is the constant `-N`: `-2147483648` is the one literal whose
-- magnitude alone does not fit, so negating `fromInt 2147483648` would panic
-- where the literal range check (which reads the negated value) accepted it.  The
-- operand is the literal already rewritten below it: a word, or the `fromInt`
-- call an out-of-range magnitude keeps.
negatedI32Lit : Expr -> Option Int
negatedI32Lit (ELoc _ e) = negatedI32Lit e
negatedI32Lit (ELit (LInt n)) = negatedInI32 n
negatedI32Lit (EApp (EMethodAt "fromInt" _ _) (ELit (LInt n))) = negatedInI32 n
-- Every other operand is ordinary negation, which `Num I32` wraps.
negatedI32Lit _ = None

-- The range is tested on `n` before it is negated, so no `Int` negation traps.
negatedInI32 : Int -> Option Int
negatedInI32 n =
  if n >= -2147483647 && n <= 2147483648 then Some (0 - n) else None

-- A literal routed to `U64`'s `fromInt` is a `U64` constant when it is not negative;
-- a negative one keeps its `fromInt` call, which panics, exactly as
-- `fixedWidthLiteralFits` leaves an out-of-range tagged literal.
u64LiteralFits : Route -> Int -> Bool
u64LiteralFits (RKey word _ _) n = isU64Head (literalRouteHead word) && n >= 0
u64LiteralFits _ _ = False

-- A literal routed to a fixed-width head's `fromInt` is that head's word already
-- when it is in range (the heads share Int's tagged word), so it needs no call.  The
-- range is checked HERE, on the value, not assumed from the module check: an
-- out-of-range literal keeps its `fromInt` call, which panics rather than storing it.
fixedWidthLiteralFits : Route -> Int -> Bool
fixedWidthLiteralFits (RKey word _ _) n =
  let head = literalRouteHead word
  match taggedFixedRange head
    Some (lo, hi) => n >= lo && n <= hi
    None => False
fixedWidthLiteralFits _ _ = False

-- The head type a literal's `fromInt` dictionary word names: the type field of the
-- instance's canonical key (`Num|I64|`).  The readers above test it only against the
-- builtin fixed-width heads, whose type field is the head's own name.
literalRouteHead : String -> String
literalRouteHead word = match splitOnChar '|' word
  _ :: ty :: _ => ty
  _ => word

-- split the stamped RKey route into a bare-tag route (reqs dropped) + the element
-- dict routes, so the dicts ride on the EMethodAt impl-dict ref (where emitMethod /
-- eval read leading dict words) rather than the route reqs (which the RKey call
-- path ignores).  A non-RKey / empty-reqs route forwards no dicts.
binopRouteSplit : Route -> (Route, List Route)
binopRouteSplit (RKey tag reqs sups) = (RKey tag [] sups, reqs)
binopRouteSplit r = (r, [])

binopMethodApp : ModuleCtx ->
  PassEvidence ->
  String ->
  Expr ->
  Expr ->
  Route ->
  Expr
binopMethodApp mctx pe op l r route =
  let method = optionOr "eq" (binopDispatchMethod op)
  let split = binopRouteSplit route
  let call =
    EApp
      (EApp
        (EMethodAt
          method
          ""
          (mintMethodCellWith
            mctx
            pe
            (builtinMethodIfaceWord mctx.mcGraph method)
            2
            (fst split)
            (snd split)))
        l)
      r
  if op == "/=" then EApp (EVar "not") call else call

binopDispatchMethod : String -> Option String
binopDispatchMethod op = match arithDispatchMethod op
  Some method => Some method
  None => binopMethod op

-- The EUnOp analogue of binopMethodApp: one operand, no `/=`-style postfix
-- (unopMethod only ever routes `-`).  Reuses binopRouteSplit (a generic
-- Route-ripping helper — nothing about it is binop-specific).
unopMethodApp : ModuleCtx -> PassEvidence -> String -> Expr -> Route -> Expr
unopMethodApp mctx pe op e route =
  let method = optionOr "negate" (unopMethod op)
  let split = binopRouteSplit route
  EApp
    (EMethodAt
      method
      ""
      (mintMethodCellWith
        mctx
        pe
        (builtinMethodIfaceWord mctx.mcGraph method)
        1
        (fst split)
        (snd split)))
    e

dictPassDecl : ModuleCtx ->
  PassEvidence ->
  OrdMap Unit ->
  List String ->
  Decl ->
  Decl
dictPassDecl mctx _ names _ (DFunDef pub n pats body site bid)
  | omHasKey n names =
    DFunDef pub n (dictParams n (dictArityOf mctx n) ++ pats) body site bid
  | otherwise = DFunDef pub n pats body site bid
-- Top-level `let rec … with …` (DLetGroup): each binding is dict-passed exactly
-- like a DFunDef — a constrained member gets `dictParams n (dictArityOf n)`
-- prepended to every clause's params, so the dict-passed call sites (which DO get
-- rewritten) line up with the definition.  (Without this, a `Num a => a -> a` group member's call site
-- supplies a leading dict the body never binds → the dict lands in the first user
-- param → arithmetic over a dict value panics `unknown op`.)
dictPassDecl mctx _ names _ (DLetGroup pub binds) =
  DLetGroup pub (map (dictPassLetBind mctx names) binds)
-- Phase 83/84 single-level + D3b-1: a parametric impl with `requires` gets one
-- leading `$dict_<method>_<slot>` param on each method (return- OR argument-
-- position) whose body actually reads an impl dict (so a terminal body like
-- `eq Nil Nil = True` would take none — but see implDictPassMethods: the param is
-- added UNIFORMLY across all clauses of a method when ANY clause uses the dict, so
-- a multi-clause method keeps one arity).  The routes resolveSite/resolveArgStamp
-- filled on the call-site EMethodAt's impl-dicts ref line up with these params.
dictPassDecl mctx pe _ _ (d@(DImpl { iface, implOrigin, reqs, methods, ... })) = DImpl { d |
  methods =
    implDictPassMethods
      mctx
      pe
      IfaceRef { irName = iface, irOrigin = implOrigin }
      (listLen reqs)
      methods,
}
-- Phase 69.x-e: a method with method-level constraints (foldMap's `Monoid m`) gets
-- one leading `$dict_<method>_<slot>` param per constraint on its DEFAULT body, so a
-- caller can supply the dictionary the body's `empty`/… reads (routed RDict by
-- inferDefaultMethod).
dictPassDecl _mctx _ _ _ (d@(DInterface { typarams, methods, ... })) =
  DInterface { d | methods = map (ifaceDictPassMethod typarams) methods }
dictPassDecl mctx pe names ret (DAttrib attrs d) =
  DAttrib attrs (dictPassDecl mctx pe names ret d)
dictPassDecl _mctx _ _ _ d = d

-- DLetGroup binding dict-pass: prepend the member's dict params to every clause.
-- `dictArityOf n` is 0 for an unconstrained member (no change), matching the
-- oracle's `if k = 0 then (n, clauses)` guard.  Gated on `names` (the constrained
-- set) so an unconstrained member with a coincidental arity entry is untouched.
dictPassLetBind : ModuleCtx -> OrdMap Unit -> LetBind -> LetBind
dictPassLetBind mctx names (LetBind n clauses site bid)
  | omHasKey n names =
    LetBind n (map (prependDictClause n (dictArityOf mctx n)) clauses) site bid
  | otherwise = LetBind n clauses site bid

prependDictClause : String -> Int -> FunClause -> FunClause
prependDictClause n k (FunClause pats body) =
  FunClause (dictParams n k ++ pats) body

ifaceDictPassMethod : List String -> IfaceMethod -> IfaceMethod
ifaceDictPassMethod typarams (IfaceMethod n ty (Some (MethodDefault pats body)) mloc) =
  ifaceDictPassDefault
    n
    ty
    pats
    body
    mloc
    (listLen (methodLevelConstraintVarNames typarams ty))
ifaceDictPassMethod _ m = m

ifaceDictPassDefault : String ->
  Ty ->
  List Pat ->
  Expr ->
  Option Loc ->
  Int ->
  IfaceMethod
ifaceDictPassDefault n ty pats body mloc k
  | k > 0 =
    IfaceMethod n ty (Some (MethodDefault (dictParams n k ++ pats) body)) mloc
  | otherwise = IfaceMethod n ty (Some (MethodDefault pats body)) mloc

-- D3b-1: add the leading `$dict_<method>_<slot>` params UNIFORMLY across all
-- clauses of a method.  An impl method is many ImplMethod entries (one per
-- clause), so a per-clause `usesImplDict` test would give clauses different
-- arities (`eq Nil Nil = True` uses no dict; `eq (Cons …) (Cons …) = … eq x y …`
-- does) and break coalescing.  Compute the set of method NAMES any of whose
-- clauses reads the dict, then prepend the params to every clause of those names.
-- No rpNames gate: usesImplDict already requires an in-body RDict route to one of
-- these params, which on the non-emit path no arg-position site ever has (its
-- occurrences stay bare EVar), so return-position goldens are unaffected.
-- TYPECHECK-AUDIT S2: each method gets, in oracle slot order, its selected
-- interface declaration's METHOD-LEVEL dict params (`dictParams n k` — e.g.
-- `build`'s `Num e`) FOLLOWED BY the impl-`requires` element-dict params (at slots
-- k..k+nReq-1, only when the body reads one), then the original pats.  The final
-- pass reads k through `DImpl.implOrigin`; body inference derives the same k from
-- its selected ClassEnv row.  This is a direct mirror of
-- `dict_pats n k @ impl_pats @ pats` shape and the
-- `method_off + slot` impl-dict naming.  Eval applies
-- method dicts unconditionally first (eval.mdk), so dropping the leading method-level
-- params (the old `match reqs []=>d` early-out) mis-bound the dict into the first
-- value parameter.
implDictPassMethods : ModuleCtx ->
  PassEvidence ->
  IfaceRef ->
  Int ->
  List ImplMethod ->
  List ImplMethod
implDictPassMethods mctx pe iface nReq methods =
  let users = dedup (flatMap (clauseImplDictUser mctx pe iface nReq) methods)
  map (prependImplDictIfUser mctx iface nReq users) methods

clauseImplDictUser : ModuleCtx ->
  PassEvidence ->
  IfaceRef ->
  Int ->
  ImplMethod ->
  List String
clauseImplDictUser mctx pe iface nReq (ImplMethod n _ body)
  | usesImplDict pe n (implMethodDictArity mctx iface n) nReq body = [n]
  | otherwise = []

-- params = method-level dicts (slots 0..k-1) ++ impl-`requires` dicts (slots
-- k..k+nReq-1, only when this method's body consumes one) ++ original pats.  Skip
-- entirely only when there are neither (k = 0 and no impl-dict use), matching the
-- oracle's `if k = 0 && not uses_impl_dict then (n, pats, body)`.
prependImplDictIfUser : ModuleCtx ->
  IfaceRef ->
  Int ->
  List String ->
  ImplMethod ->
  ImplMethod
prependImplDictIfUser mctx iface nReq users (ImplMethod n pats body) =
  let k = implMethodDictArity mctx iface n
  let implPats = if contains n users then dictParamsFrom n k nReq else []
  if k == 0 && isEmptyL implPats then
    ImplMethod n pats body
  else
    ImplMethod n (dictParams n k ++ implPats ++ pats) body

-- does [body] reference an in-body return-position method already routed RDict to
-- one of THIS method's would-be impl-dict params? (the gate that distinguishes a
-- body that consumes the element dict from a terminal one that doesn't).  Impl-dict
-- slots are offset by the method's own method-level arity (S2), so probe at k..k+nReq-1.
usesImplDict : PassEvidence -> String -> Int -> Int -> Expr -> Bool
usesImplDict pe mname methodArity nReq body =
  anyMember (collectDictSites pe body) (implDictNames mname methodArity nReq)

implDictNames : String -> Int -> Int -> List String
implDictNames mname methodArity nReq =
  map (dictParamName mname) (range methodArity (methodArity + nReq))

implMethodDictArity : ModuleCtx -> IfaceRef -> String -> Int
implMethodDictArity mctx iface method =
  methodDictArityAtOrigin mctx iface.irOrigin (methodSlotKey iface method)

-- [key] is a `methodSlotKey`; [origin] is its interface's declaring module.
methodDictArityAtOrigin : ModuleCtx -> TyConOrigin -> String -> Int
methodDictArityAtOrigin mctx (OriginModule mid) key =
  match (lookupQualPayload
    mid
    key
    mctx.mcGraph.crossRun.crossModuleMethodPredicateSlotsQualRef.value)
    Some slots => listLen slots
    None => methodDictArityOf mctx key
methodDictArityAtOrigin mctx _ key = methodDictArityOf mctx key

siteRDictName : Route -> List String
siteRDictName (RDict d) = [d]
siteRDictName (RDictFwd d) = [d]
siteRDictName (RProj inner _) = routeRDictName inner
siteRDictName _ = []

siteRDictNamesL : List Route -> List String
siteRDictNamesL rs = flatMap routeRDictName rs

routeRDictName : Route -> List String
routeRDictName (RDict d) = [d]
routeRDictName (RDictFwd d) = [d]
-- Native #54/#21 residual: an element-dict RKey route can NEST an RDict forwarding
-- the enclosing impl's `requires` dict (e.g. `RKey "$tuple" [RDict $dict_debug_0,
-- RDict $dict_debug_1]` for `debug (toList m)` in a `Debug (Map k v)` body).  The
-- gate that decides whether to PREPEND those impl-dict params (usesImplDict) must
-- see the nested name, else the route references a param the clause never declares
-- → emitter panics "unbound dict witness".  Recurse into the nested reqs.
routeRDictName (RKey _ reqs sups) =
  flatMap routeRDictName reqs ++ flatMap routeRDictName sups
routeRDictName (RProj r _) = routeRDictName r
routeRDictName _ = []

-- The dict-param names the method occurrences and dictionary applications in [e]
-- route to: an `EMethodAt`'s dispatch route (RDict/RDictFwd, post-resolveSites)
-- and its impl-/method-dict route LISTS, and every `EDictAt` route list that
-- forwards RDict/RDictFwd to an impl param (a `=>`-constrained helper call that
-- threads the impl dict through, e.g. `debug xs = "[\{debugListItems xs}]"` where
-- `debugListItems` is an EDictAt).
--
-- An EMethodAt arg-position site carries its element-dict routes in the
-- impl-/method-dict lists, not its dispatch route.  A nested `requires` impl whose
-- body dispatches a method on its own element tyvar routes RDict $dict_<m>_<slot>
-- there, so both are scanned for implDictPassMethods' usesImplDict gate to prepend
-- the matching param.
collectDictSites : PassEvidence -> Expr -> List String
collectDictSites pe (EDictAt _ ev) =
  siteRDictNamesL (evDictRoutesIn (passIndex pe) ev)
collectDictSites pe (EMethodAt _ _ ev) =
  let (PassMethod _ tag dicts) = passMethodOf pe ev
  siteRDictName tag ++ siteRDictNamesL dicts
collectDictSites pe (ELoc _ e) = collectDictSites pe e
collectDictSites pe (EDoOrigin _ e) = collectDictSites pe e
collectDictSites pe (EApp f x) = collectDictSites pe f ++ collectDictSites pe x
collectDictSites pe (ELam _ b) = collectDictSites pe b
collectDictSites pe (ELet _ _ _ e1 e2) =
  collectDictSites pe e1 ++ collectDictSites pe e2
collectDictSites pe (ELetGroup binds body) =
  flatMap (letBindDictSites pe) binds ++ collectDictSites pe body
collectDictSites pe (EMatch e arms) =
  collectDictSites pe e ++ flatMap (armDictSites pe) arms
collectDictSites pe (EIf c t e) =
  collectDictSites pe c ++ collectDictSites pe t ++ collectDictSites pe e
collectDictSites pe (EBinOp _ l r _) =
  collectDictSites pe l ++ collectDictSites pe r
collectDictSites pe (EUnOp _ e _) = collectDictSites pe e
collectDictSites pe (EInfix _ l r) =
  collectDictSites pe l ++ collectDictSites pe r
collectDictSites pe (EFieldAccess e _ _) = collectDictSites pe e
collectDictSites pe (ETuple es) = flatMap (collectDictSites pe) es
collectDictSites pe (EListLit es) = flatMap (collectDictSites pe) es
collectDictSites pe (EArrayLit es) = flatMap (collectDictSites pe) es
collectDictSites pe (ERangeList a b _) =
  collectDictSites pe a ++ collectDictSites pe b
collectDictSites pe (ERangeArray a b _) =
  collectDictSites pe a ++ collectDictSites pe b
collectDictSites pe (ESlice e a b _) =
  collectDictSites pe e ++ collectDictSites pe a ++ collectDictSites pe b
collectDictSites pe (EIndex e i) =
  collectDictSites pe e ++ collectDictSites pe i
collectDictSites pe (EAnnot e _) = collectDictSites pe e
collectDictSites pe (EBlock stmts) = flatMap (doStmtDictSites pe) stmts
collectDictSites pe (ERecordCreate _ fs) = flatMap (fieldAssignDictSites pe) fs
collectDictSites pe (ERecordUpdate e fs _) =
  collectDictSites pe e ++ flatMap (fieldAssignDictSites pe) fs
collectDictSites pe (EVariantUpdate _ e fs) =
  collectDictSites pe e ++ flatMap (fieldAssignDictSites pe) fs
collectDictSites _ _ = []

letBindDictSites : PassEvidence -> LetBind -> List String
letBindDictSites pe (LetBind _ clauses _ _) =
  flatMap (funClauseDictSites pe) clauses

funClauseDictSites : PassEvidence -> FunClause -> List String
funClauseDictSites pe (FunClause _ body) = collectDictSites pe body

armDictSites : PassEvidence -> Arm -> List String
armDictSites pe (Arm _ guards body) =
  flatMap (guardDictSites pe) guards ++ collectDictSites pe body

guardDictSites : PassEvidence -> Guard -> List String
guardDictSites pe (GBool e) = collectDictSites pe e
guardDictSites pe (GBind _ e) = collectDictSites pe e

doStmtDictSites : PassEvidence -> DoStmt -> List String
doStmtDictSites pe (DoExpr e) = collectDictSites pe e
doStmtDictSites pe (DoLet _ _ _ e _) = collectDictSites pe e
doStmtDictSites pe (DoBind _ e) = collectDictSites pe e
doStmtDictSites pe (DoAssign _ e) = collectDictSites pe e
doStmtDictSites pe (DoFieldAssign _ _ e) = collectDictSites pe e

fieldAssignDictSites : PassEvidence -> FieldAssign -> List String
fieldAssignDictSites pe (FieldAssign _ e) = collectDictSites pe e

dictArityOf : ModuleCtx -> String -> Int
dictArityOf mctx n =
  listLen
    (optionOr
      []
      (lookupPredicateSlots n mctx.mcCells.funPredicateSlotsIdxRef.value))

dictParams : String -> Int -> List Pat
dictParams n k = dictParamsGo n 0 k

dictParamsGo : String -> Int -> Int -> List Pat
dictParamsGo n slot k
  | slot >= k = []
  | otherwise =
    PVar (dictParamName n slot) (Loc "" 0 0 0 0) noBinderId
      :: dictParamsGo n (slot + 1) k

-- [count] dict params for [n] starting at slot [start]: $dict_n_start ..
-- $dict_n_(start+count-1).  Used for impl-`requires` element-dict params, which
-- follow the method's own method-level params (S2 offset = methodDictArityOf).
dictParamsFrom : String -> Int -> Int -> List Pat
dictParamsFrom n start count
  | count <= 0 = []
  | otherwise =
    PVar (dictParamName n start) (Loc "" 0 0 0 0) noBinderId
      :: dictParamsFrom n (start + 1) (count - 1)

-- E5/E6: final dict-pass of the stamped module trees, on every path.
-- [dictNames] is the prelude + module `=>`-constrained fn set.
-- E6: each module's typecheck calls `freshModuleCtx`, which clears funConstraintsRef,
-- so by this final pass only the LAST module's constraint arities survive — a
-- core-level constrained fn like `clamp` would get `dictArityOf` = 0 and NO leading
-- param.  Re-seed funConstraintsRef from every constrained signature (core +
-- modules) so dictPassDecl's DFunDef arm prepends the right number of
-- `$dict_<fn>_<slot>` params.  Only the COUNT is read here (the body's EDictAt/RDict
-- routes were already stamped, with real ids, during each module's own pass), so a
-- placeholder id list of the correct length is sufficient.  Prepended → wins the
-- lookupPredicateSlots first-match over any stale last-module entry.  (Golden module
-- drivers never reach elaborateModules, so their trees are untouched.)
-- Step 4 (Phase-134 fix): per-module importer-scoped arity, mirroring the oracle
-- eval.ml:2104-2164 collect_arities-per-scope.  The pre-fix JOINT
-- seedDictAritiesFromSigs keyed arity by BARE NAME, so a constrained fn in module A
-- forced spurious leading dict params onto an unconstrained same-named fn in module
-- B (whose call sites then under-applied → silent partial closure).  Core
-- (≈ the oracle's prelude) is imported by every module, so it keeps the FULL joint
-- scope.  Each module's scope = its own decls ∪ the decls of its transitive
-- importers ∪ core (the importer part covers a PUBLIC constrained fn referenced only
-- by its importers; mangleUnits already de-collided PRIVATES).  promotedC = the
-- joint-discovered promoted-fn slots (unsignatured, so constrainedSigPredicateSlots misses
-- them) carried across `freshModuleCtx` in the cross-module function carrier.
-- [mctx] is the record the drive's last module left current, whose slot tables the
-- pass rewrites.  [corePassed]: [core2] arrives dict-passed already (the prelude's
-- shipped trees), so only the user modules are passed.
export
dictPassModulesIfEnabled : ModuleCtx ->
  List String ->
  Bool ->
  List Decl ->
  List (String, List Decl) ->
  (List Decl, List (String, List Decl))
dictPassModulesIfEnabled mctx dictNames corePassed core2 modules2 =
  -- #2549 M2: index this sweep's solved evidence before anything reads a route
  -- out of it.  Here because `dictPass` is itself a reader (`collectDictSites`,
  -- `methodGrantUse`), and this is the Module arm's one funnel into it.
  let idx = evIndexOf (drivenEvidence mctx.mcGraph ())
  let promotedQ =
    mctx.mcGraph.crossRun.crossModuleFunPredicateSlotsQualRef.value
  let allMods = namesToSet (map fst modules2) omEmpty
  -- core imports nothing, so its definitions take their dict parameters from core's
  -- own signatures: a user fn sharing a bare name with a core private is another fn.
  setFunPredicateSlots mctx (scopePredicateSlots [] omEmpty core2)
  -- The sidecar is cleared, not left alone.  No module record is minted
  -- between the last `checkBodyImpl` and this call, so writing nothing leaves the previous
  -- module's entries live: a reader in this phase would get a PRESENT, WRONG `CDPLen`,
  -- resolved by bare-name first-match against a differently-populated table, with no
  -- `CDPUnknown` to trip on.  Empty ⇒ `clampPrefix`'s `None` arm ⇒ `CDPUnknown` ⇒
  -- withhold, which is the honest answer for a table this phase does not repopulate.
  mctx.mcCells.funConstraintDeclaredRef := []
  mctx.mcCells.methodPredicateSlotsRef :=
    scopeMethodPredicateSlots
      mctx.mcGraph.crossRun.crossModuleMethodPredicateSlotsQualRef.value
      allMods
  let core2' =
    if corePassed then
      core2
    else
      dictPass mctx idx "" (constrainedSigNames core2) core2
  -- ONE reverse-reachability index for the whole run: `dictPassModulesScoped` asks the
  -- importer question once per module, and re-deriving it there re-walked the graph
  -- (twice — ids and decls) with a decl-list scan at every visited node.
  let importerReach = importerReachIndex modules2
  let modules2' =
    dictPassModulesScoped
      mctx
      idx
      dictNames
      promotedQ
      importerReach
      core2
      modules2
      modules2
  let r = mctx.mcGraph.graphRun
  r.evTable := servedEntriesFrom idx r.evBase r.evTable.value
  (core2', modules2')

-- per-module: set funConstraintsRef to the module's importer-scoped arities, then
-- dict-pass that module.  [allModules] is the full set (for the transitive-importer
-- walk); [modules2] is the remaining suffix to process.  core2 is always in scope.
-- [importerReach] is the run's one reachability index; it answers the importer
-- question for every module, so nothing here re-walks the import graph.
dictPassModulesScoped : ModuleCtx ->
  EvIndex ->
  List String ->
  List ((String, String), List PredicateSlot) ->
  OrdMap (OrdMap Unit) ->
  List Decl ->
  List (String, List Decl) ->
  List (String, List Decl) ->
  List (String, List Decl)
dictPassModulesScoped _mctx _ _ _ _ _ _ [] = []
dictPassModulesScoped mctx idx dictNames promotedQ importerReach core2 allModules ((mid, prog) :: rest) =
  let importers = transitiveImporters importerReach mid allModules
  let importerDecls = flatMap snd importers
  let scope = core2 ++ prog ++ importerDecls
  let scopeMods = namesToSet (mid :: map fst importers) omEmpty
  -- IMPORT ALIASING: scopePredicateSlots keys arity by the DEFINITION's name, but an aliased
  -- call site in THIS module writes the LOCAL name.  Re-key this module's own aliases
  -- (from its DUse decls) onto the origin's arity, else the aliased call under-applies
  -- its dicts.  This is the RUN/eval path's counterpart to the same fix in
  -- checkModuleFullImpl — the EMIT path never needs it, because private_mangle has
  -- already rewritten `A.name` to the origin's real symbol before this point.
  -- #1425 site 3: re-key the names THIS module declares onto its own qual rows before the
  -- table is handed to `dictPass`.  `scopePredicateSlots` reduces `(mid, name)` to a bare name and
  -- throws the module id away, which is where a foreign module's constrained row becomes
  -- this module's phantom dict param; `selfDeclArities` is what puts the identity back for
  -- the one set of names this module can answer authoritatively — its own.
  setFunPredicateSlots
    mctx
    (selfDeclArities
      mid
      prog
      promotedQ
      (aliasConstraintEntries mctx.mcGraph prog promotedQ
        ++ scopePredicateSlots promotedQ scopeMods scope))
  -- Cleared for the same reason as in `dictPassModulesIfEnabled`: a stale
  -- prefix table is worse than an empty one, because only the empty one answers
  -- `CDPUnknown`.
  mctx.mcCells.funConstraintDeclaredRef := []
  mctx.mcCells.methodPredicateSlotsRef :=
    scopeMethodPredicateSlots
      mctx.mcGraph.crossRun.crossModuleMethodPredicateSlotsQualRef.value
      scopeMods
  (mid, dictPass mctx idx mid dictNames prog)
    :: dictPassModulesScoped
      mctx
      idx
      dictNames
      promotedQ
      importerReach
      core2
      allModules
      rest

-- the arity table for a scope: every `=>`-constrained signature in [scope]
-- (constrainedSigPredicateSlots) PLUS the joint-discovered promoted-fn slots whose fn is
-- DEFINED in [scope] (so a promoted fn out of scope doesn't leak a param count in).
-- #55: the signature count (`constrainedSigPredicateSlots`) is the syntactic predicate
-- count; the inferred count in the cross-module carrier (the
-- surviving generalized constraint vars from each body's inference) is what every
-- CALL site computes (constraintMonosOf over the call's instantiated scheme).  These
-- diverge for a point-free fn whose body MONOMORPHIZES a constraint var — e.g.
-- `sum = fold (+) 0`: the `0` literal is typed `Int` (litType), pinning `Num a`'s `a`
-- to `Int`, so `a` is NOT generalized → the scheme keeps only `Foldable t` (1
-- constraint) while the signature still lists 2.  If the define were sized off the
-- 2-count sig it would take 2 leading dict params while call sites pass 1 (dict +
-- container) → the container arg lands in an unpassed register → garbage deref /
-- SIGSEGV at -O2.  So for a fn WITH an inferred entry, the inferred arity WINS (drop
-- its sig entry); the sig count is the fallback for fns the body-inference path never
-- registered (unreached/never-called constrained fns).  `elem` is unaffected: both
-- its `Eq a` and `Foldable t` vars survive (no literal pins them) → inferred == sig == 2.
-- WS-2/D2: [promotedQ] is the module-attributed inferred arities
-- (crossModuleFunConstraintsQualRef); [scopeMods] is the set of module ids in this
-- dict-pass scope (this module ∪ its transitive importers ∪ "" for core, which is in
-- every scope).  An inferred entry survives when its fn NAME is in scope (as before).
-- For the SUBSET of names that collide (same bare name from ≥2 modules), prefer the
-- entry whose OWNING module is in scope — that disambiguation is the WS-2/D2 fix.
-- A non-colliding name, or a colliding name with NO in-scope-module entry, keeps the
-- old bare behavior (every same-name entry retained; first-match downstream).  This
-- is intentionally minimal: it changes arity ONLY for the cross-module bare-name
-- collision, so non-colliding programs (every golden) are byte-identical.
-- Reduces the qualified entries to the bare (name,ids) form downstream readers expect.
scopePredicateSlots : List ((String, String), List PredicateSlot) ->
  OrdMap Unit ->
  List Decl ->
  List (String, List PredicateSlot)
scopePredicateSlots promotedQ scopeMods scope =
  let scopeNames = namesToSet (declTopFnNames scope) omEmpty
  let nameInScope =
    filterList (e => omHasKey (snd (fst e)) scopeNames) promotedQ
  -- names that have at least one in-scope-module entry → drop their out-of-scope-module twins
  let resolvedNames =
    namesToSet
      (map
        (e => snd (fst e))
        (filterList (e => modInScope (fst (fst e)) scopeMods) nameInScope))
      omEmpty
  let inferredQ =
    filterList
      (e =>
        modInScope (fst (fst e)) scopeMods
          || not (omHasKey (snd (fst e)) resolvedNames))
      nameInScope
  let inferred = map (e => (snd (fst e), snd e)) inferredQ
  let inferredNames = namesToSet (map fst inferred) omEmpty
  let sigEntries =
    filterList
      (e => not (omHasKey (fst e) inferredNames))
      (flatMap constrainedSigPredicateSlots scope)
  inferred ++ sigEntries

-- ── #1425 / #1351: a module's OWN declarations take their arity from their OWN row ──
-- A bare-name arity table cannot say WHOSE `f` an entry is.  When two modules each declare
-- a top-level `f` — one `=>`-constrained, one not — the graph-wide bare accumulator carries
-- only the CONSTRAINED one's row, because an unconstrained binding contributes none at all.
-- So the unconstrained module's OWN `f` is sized with the OTHER module's dict arity: its
-- `define` takes a phantom dict parameter that its call sites never pass, and the argument
-- lands in the dict slot.  Which of the two import orderings breaks is decided by the order
-- of two `import` lines, because that decides the topological order the bare accumulator is
-- grown in — a wrong answer selected by source-file layout.
--
-- This is the case `scopePredicateSlots`' own in-scope preference cannot reach, and it is why
-- that preference is not enough on its own.  Its ladder prefers "an entry whose owning
-- module is in scope", and an unconstrained binding has no entry — it can never win a
-- preference it does not enter.  Worse, `scopeMods` is the IMPORTER direction (`mid` ∪ the
-- modules that transitively import it), so a foreign definer is never "in scope" and its row
-- survives by the `not (omHasKey … resolvedNames)` arm precisely when it is most wrong.
--
-- The repair supplies the DECLARATION's identity where it is already available and nowhere
-- else.  For each name THIS module declares at top level, the entry is THIS module's
-- `(mid, name)` qual row — and ABSENT when there is none, which is the accurate reading of
-- an unconstrained binding, not a missing fact: `declaredConstraintFor`'s `None` arm already
-- reads a qual miss for a known import exactly that way ("a MISS for a known import means
-- 'no constraint', not 'look elsewhere'"), and this is the same discipline applied to the
-- module's own declarations instead of to its imports.  A name the module does NOT declare
-- keeps the incoming table's answer byte-identical, so a program with no same-name collision
-- across modules is unaffected.
--
-- Fails closed on absent identity.  `mid == ""` is the "no module id" sentinel of the
-- loader-less drivers (single-file `check`, lsp, repl, doc); there the incoming table is
-- returned untouched, i.e. today's behaviour.  A supply that turned absence into a dropped
-- dict would be a severity increase, and absence is common on those paths by construction.
--
-- Keyed on `elaborateModules`' OWN inputs — the module's decls and the qual accumulator,
-- both already in hand at every site that calls this — never on which driver invoked it.
export
selfDeclArities : String ->
  List Decl ->
  List ((String, String), a) ->
  List (String, a) ->
  List (String, a)
selfDeclArities mid prog qual bare =
  if mid == "" then
    bare
  else
    let own = namesToSet (declTopFnNames prog) omEmpty
    selfQualEntries mid own qual
      ++ filterList (e => not (omHasKey (fst e) own)) bare

-- this module's own qual rows, reduced to the bare (name, payload) shape readers expect.
selfQualEntries : String ->
  OrdMap Unit ->
  List ((String, String), a) ->
  List (String, a)
selfQualEntries mid own qual =
  map
    (e => (snd (fst e), snd e))
    (filterList (e => fst (fst e) == mid && omHasKey (snd (fst e)) own) qual)

-- WS-2/D2 method analog of scopePredicateSlots, WITHOUT the sig-fallback: every method-level
-- constraint is registered during its interface module's typecheck
-- (installMethodPredicateSlots during method-row construction), so there is no
-- unsignatured-promoted residual to seed from signatures.  No method scope filter
-- either: keep every entry whose `methodSlotKey` no in-scope module also carries (so a
-- method whose impl lives in a different module than its interface is never dropped),
-- and for a key that some in-scope module does carry, keep only the in-scope entries.
-- The key already names the declaring interface, so one key has one owning module and
-- this keeps every entry.
scopeMethodPredicateSlots : List ((String, String), List MethodPredicateSlot) ->
  OrdMap Unit ->
  List (String, List MethodPredicateSlot)
scopeMethodPredicateSlots promotedMQ scopeMods =
  let resolvedNames =
    namesToSet
      (map
        (e => snd (fst e))
        (filterList (e => modInScope (fst (fst e)) scopeMods) promotedMQ))
      omEmpty
  let kept =
    filterList
      (e =>
        modInScope (fst (fst e)) scopeMods
          || not (omHasKey (snd (fst e)) resolvedNames))
      promotedMQ
  map (e => (snd (fst e), snd e)) kept

-- core (mid "") is in every scope; otherwise membership in the scope-module set.
modInScope : String -> OrdMap Unit -> Bool
modInScope mid scopeMods = mid == "" || omHasKey mid scopeMods

-- the modules that transitively import [mid] (excluding [mid]), in module-list order.
-- Their decls are the importer half of [mid]'s dict-pass scope — a public
-- constrained/promoted fn defined in [mid] but referenced only by an importer must be
-- in scope when [mid] is dict-passed — and their ids are the owning-module set
-- `scopePredicateSlots` filters on.  Both halves read the SAME row, so the two can no
-- longer disagree about who the importers are.
transitiveImporters : OrdMap (OrdMap Unit) ->
  String ->
  List (String, List Decl) ->
  List (String, List Decl)
transitiveImporters reach mid modules =
  filterList
    (p =>
      fst p /= mid && omHasKey mid (optionOr omEmpty (omLookup (fst p) reach)))
    modules

constrainedSigPredicateSlots : Decl -> List (String, List PredicateSlot)
constrainedSigPredicateSlots (DTypeSig _ n ty _)
  | isConstrainedTy ty = [(n, map sigPredicateSlot (sigConstraints ty))]
  | otherwise = []
constrainedSigPredicateSlots (DAttrib _ d) = constrainedSigPredicateSlots d
constrainedSigPredicateSlots _ = []

sigPredicateSlot : (IfaceRef, List String) -> PredicateSlot
sigPredicateSlot (iface, _) =
  PredicateSlot { psIface = iface, psArgs = PSArgsUnknown, psBoundIds = [] }
# DESUGAR
(DUse false (UseGroup ("types" "tc_types") ((mem "AdmittedAnswer" true) (mem "BuiltinClass" true) (mem "EntailKind" true) (mem "GrantBinder" true) (mem "MethodGrantUse" true) (mem "MethodReturnTraceStage" true) (mem "PendingDictApp" true) (mem "PredicateSlot" true) (mem "PredicateSlotArgs" true) (mem "SiteCtx" true) (mem "SiteKind" true) (mem "GrantOcc" false) (mem "GrantState" false) (mem "grantTopKey" false) (mem "GraphCtx" false) (mem "LocalAbs" false) (mem "MethodGrant" false) (mem "MethodPredicateSlot" false) (mem "MethodReturnRequest" false) (mem "ModuleCtx" false) (mem "PassEvidence" false) (mem "PassMethod" false) (mem "PendingEntry" false) (mem "PendingMethodDict" false) (mem "RecDictApp" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "anyMember" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "dictParamName" false) (mem "interners" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "builtinClassName" false) (mem "builtinClassOrigin" false) (mem "declTopFnNames" false) (mem "importerReachIndex" false) (mem "methodLevelConstraintVarNames" false) (mem "methodSlotKey" false) (mem "namesToSet" false))))
(DUse false (UseGroup ("types" "tc_scope") ((mem "aliasConstraintEntries" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "lookupQualPayload" false))))
(DUse false (UseGroup ("types" "tc_decls") ((mem "methodDictArityOf" false))))
(DUse false (UseGroup ("types" "tc_solve_givens") ((mem "lookupPredicateSlots" false))))
(DUse false (UseGroup ("types" "tc_solve_entail") ((mem "entail" false) (mem "implDictRoutesForRow" false) (mem "rowRouteKey" false) (mem "selectedCallSupers" false))))
(DUse false (UseGroup ("types" "tc_solve") ((mem "admittedSelection" false) (mem "exactReturnRoutes" false) (mem "isLocalAbsName" false) (mem "methodPredicateRoutes" false) (mem "methodReturnAmbiguousWithoutGiven" false) (mem "methodReturnArgs" false) (mem "methodReturnResolutionValid" false) (mem "noteMethodReturnTrace" false) (mem "numericReturnRoute" false) (mem "recRoutes" false) (mem "returnPosMethodNames" false) (mem "routesOfMonosTopV" false) (mem "solveExactReturnOnce" false))))
(DUse false (UseGroup ("types" "tc_solve_check") ((mem "setFunPredicateSlots" false))))
(DUse false (UseGroup ("types" "tc_shadow") ((mem "methodCellOf" false))))
(DUse false (UseGroup ("types" "tc_effects") ((mem "evOrdinal" false) (mem "fileBodyLoc" false) (mem "fileBoundSite" false) (mem "fileValueKey" false) (mem "grantOccOf" false) (mem "hasFileBoundValue" false) (mem "methodGrantOf" false) (mem "narrowFileAtom" false))))
(DUse false (UseGroup ("types" "tc_occurrence") ((mem "arithDispatchMethod" false) (mem "binopMethod" false) (mem "constrainedSigNames" false) (mem "isGrantOnlyEv" false) (mem "mintMethodCellRaw" false) (mem "unopMethod" false))))
(DUse false (UseGroup ("types" "tc_groups") ((mem "sigConstraints" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "Decl" true) (mem "DoStmt" true) (mem "EvId" true) (mem "EvVal" true) (mem "Expr" true) (mem "FieldAssign" true) (mem "FunClause" true) (mem "Guard" true) (mem "IfaceMethod" true) (mem "ImplMethod" true) (mem "LetBind" true) (mem "Lit" true) (mem "Loc" true) (mem "MethodDefault" true) (mem "Pat" true) (mem "Route" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "EvTable" false) (mem "isI32Head" false) (mem "isI64Head" false) (mem "isU64Head" false) (mem "noBinderId" false) (mem "noDeclLoc" false) (mem "taggedFixedRange" false) (mem "tyConBuiltin" false) (mem "unminted" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" true) (mem "GrantShape" true) (mem "authGrantShape" false) (mem "authvarId" false))))
(DUse false (UseGroup ("types" "solver_contract") ((mem "ClassPredicate" true))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffRow" true) (mem "atomAuth" false) (mem "atomLabel" false) (mem "rowFlat" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "evDictRoutesIn" false) (mem "evidenceLookup" false) (mem "EvIndex" false) (mem "evIndexOf" false) (mem "evSiteLitIn" false) (mem "evSiteRouteIn" false) (mem "ifaceWordOf" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Mono" true) (mem "normalize" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("types" "evidence") ((mem "ScopeId" true))))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("types" "runtime_ops") ((mem "arithmeticTag" false))))
(DUse false (UseGroup ("types" "module_interface") ((mem "cellEntriesFrom" false) (mem "servedEntriesFrom" false) (mem "setServedArity" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "dedup" false) (mem "filterList" false) (mem "int64Halves" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "isSome" false) (mem "listLen" false) (mem "splitOnChar" false))))
(DUse false (UseGroup ("list") ((mem "drop" false) (mem "elemIndex" false) (mem "range" false) (mem "replicate" false) (mem "reverse" false) (mem "take" false))))
(DUse false (UseGroup ("types" "runtime_grants") ((mem "fileGrantExterns" false))))
(DUse false (UseGroup ("types" "chain_key") ((mem "isConstrainedTy" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "mapChildren" false) (mem "mapProg" false))))
(DUse false (UseAlias ("map") "IdMap"))
(DTypeSig false "mintMethodCellWith" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Route") (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyCon "EvId"))))))))
(DFunDef false "mintMethodCellWith" ((PVar "mctx") (PCon "PassEvidence" PWild (PVar "minted")) (PVar "iface") (PVar "arity") (PVar "tag") (PVar "impls")) (EBlock (DoLet false false (PVar "ev") (EApp (EApp (EApp (EApp (EApp (EVar "mintMethodCellRaw") (EVar "mctx")) (EVar "iface")) (EApp (EVar "Some") (EVar "arity"))) (EVar "tag")) (EVar "impls"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "minted")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "intToString") (EApp (EVar "evOrdinal") (EVar "ev")))) (EApp (EApp (EApp (EApp (EApp (EVar "EvMethod") (EVar "iface")) (EVar "arity")) (EVar "tag")) (EVar "impls")) (EListLit))) (EFieldAccess (EVar "minted") "value")))) (DoExpr (EVar "ev"))))
(DTypeSig true "drivenEvidence" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyCon "EvTable"))))
(DFunDef false "drivenEvidence" ((PVar "gctx") PWild) (EBinOp "++" (EApp (EApp (EVar "cellEntriesFrom") (EFieldAccess (EVar "gctx") "graphRun")) (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "evBase")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "evTable") "value")))
(DTypeSig false "localAbsFor" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "LocalAbs")))))
(DFunDef false "localAbsFor" ((PVar "gctx") (PVar "name")) (EApp (EApp (EVar "optionOr") (EVar "None")) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "localAbs") "lasBinders") "value"))))
(DTypeSig false "rewriteLocalDictExpr" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "rewriteLocalDictExpr" ((PVar "gctx") (PCon "EDictAt" (PVar "n") (PVar "ev"))) (EIf (EApp (EVar "isLocalAbsName") (EVar "n")) (EMatch (EApp (EApp (EVar "localAbsFor") (EVar "gctx")) (EVar "n")) (arm (PCon "Some" PWild) () (EApp (EApp (EVar "EDictAt") (EVar "n")) (EVar "ev"))) (arm (PCon "None") () (EApp (EVar "EVar") (EVar "n")))) (EIf (EVar "otherwise") (EApp (EApp (EVar "EDictAt") (EVar "n")) (EVar "ev")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "rewriteLocalDictExpr" ((PVar "gctx") (PCon "ELet" (PVar "m") (PVar "r") (PCon "PVar" (PVar "x") (PVar "xloc") (PVar "bid")) (PVar "e1") (PVar "e2"))) (EMatch (EApp (EApp (EVar "localAbsFor") (EVar "gctx")) (EVar "x")) (arm (PCon "Some" (PVar "la")) () (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "r")) (EApp (EApp (EApp (EVar "PVar") (EVar "x")) (EVar "xloc")) (EVar "bid"))) (EApp (EApp (EVar "prependLocalDicts") (EFieldAccess (EVar "la") "laParams")) (EVar "e1"))) (EVar "e2"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "r")) (EApp (EApp (EApp (EVar "PVar") (EVar "x")) (EVar "xloc")) (EVar "bid"))) (EVar "e1")) (EVar "e2")))))
(DFunDef false "rewriteLocalDictExpr" ((PVar "gctx") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EVar "map") (EApp (EVar "rewriteLocalLetBind") (EVar "gctx"))) (EVar "binds"))) (EVar "body")))
(DFunDef false "rewriteLocalDictExpr" ((PVar "gctx") (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EVar "map") (EApp (EVar "rewriteLocalDoStmt") (EVar "gctx"))) (EVar "stmts"))))
(DFunDef false "rewriteLocalDictExpr" ((PVar "_gctx") (PVar "e")) (EVar "e"))
(DTypeSig false "rewriteLocalLetBind" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "LetBind") (TyCon "LetBind"))))
(DFunDef false "rewriteLocalLetBind" ((PVar "gctx") (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EMatch (EApp (EApp (EVar "localAbsFor") (EVar "gctx")) (EVar "n")) (arm (PCon "Some" (PVar "la")) () (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "prependLocalDictClause") (EFieldAccess (EVar "la") "laParams"))) (EVar "clauses"))) (EVar "site")) (EVar "bid"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EVar "clauses")) (EVar "site")) (EVar "bid")))))
(DTypeSig false "prependLocalDictClause" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "FunClause") (TyCon "FunClause"))))
(DFunDef false "prependLocalDictClause" ((PVar "params") (PCon "FunClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EBinOp "++" (EApp (EApp (EVar "map") (EVar "localDictPat")) (EVar "params")) (EVar "pats"))) (EVar "body")))
(DTypeSig false "rewriteLocalDoStmt" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "DoStmt") (TyCon "DoStmt"))))
(DFunDef false "rewriteLocalDoStmt" ((PVar "gctx") (PCon "DoLet" (PVar "m") (PVar "r") (PCon "PVar" (PVar "x") (PVar "xloc") (PVar "bid")) (PVar "e") (PVar "site"))) (EMatch (EApp (EApp (EVar "localAbsFor") (EVar "gctx")) (EVar "x")) (arm (PCon "Some" (PVar "la")) () (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EApp (EApp (EApp (EVar "PVar") (EVar "x")) (EVar "xloc")) (EVar "bid"))) (EApp (EApp (EVar "prependLocalDicts") (EFieldAccess (EVar "la") "laParams")) (EVar "e"))) (EVar "site"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EApp (EApp (EApp (EVar "PVar") (EVar "x")) (EVar "xloc")) (EVar "bid"))) (EVar "e")) (EVar "site")))))
(DFunDef false "rewriteLocalDoStmt" ((PVar "_gctx") (PVar "stmt")) (EVar "stmt"))
(DTypeSig false "prependLocalDicts" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "prependLocalDicts" ((PVar "params") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EApp (EVar "prependLocalDicts") (EVar "params")) (EVar "e"))))
(DFunDef false "prependLocalDicts" ((PVar "params") (PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "ELam") (EBinOp "++" (EApp (EApp (EVar "map") (EVar "localDictPat")) (EVar "params")) (EVar "pats"))) (EVar "body")))
(DFunDef false "prependLocalDicts" ((PVar "params") (PVar "e")) (EApp (EApp (EVar "ELam") (EApp (EApp (EVar "map") (EVar "localDictPat")) (EVar "params"))) (EVar "e")))
(DTypeSig false "localDictPat" (TyFun (TyCon "String") (TyCon "Pat")))
(DFunDef false "localDictPat" ((PVar "n")) (EApp (EApp (EApp (EVar "PVar") (EVar "n")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (EVar "noBinderId")))
(DTypeSig true "grantWholeDomain" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "grantWholeDomain" ((PVar "prog")) (EApp (EApp (EVar "map") (EApp (EVar "mapDeclBodies") (EApp (EVar "wholeDomainExpr") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "interners") "value") "lineage") "lnGrants")))) (EVar "prog")))
(DTypeSig false "wholeDomainExpr" (TyFun (TyCon "GrantState") (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "wholeDomainExpr" ((PVar "st") (PAs "e" (PCon "EApp" PWild PWild))) (EMatch (EApp (EApp (EVar "grantSpine") (EVar "e")) (EListLit)) (arm (PTuple (PCon "EVar" (PVar "n")) (PVar "args")) () (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "fileGrantExterns")) (arm (PCon "Some" (PTuple (PVar "arity") (PVar "paths"))) () (EApp (EApp (EApp (EApp (EApp (EVar "saturateGrants") (EVar "st")) (EApp (EVar "EVar") (EVar "n"))) (EVar "arity")) (EApp (EApp (EVar "replicate") (EVar "paths")) (EApp (EVar "EListLit") (EListLit)))) (EApp (EApp (EVar "map") (EApp (EVar "wholeDomainExpr") (EVar "st"))) (EVar "args")))) (arm (PCon "None") () (EApp (EApp (EVar "mapChildren") (EApp (EVar "wholeDomainExpr") (EVar "st"))) (EVar "e"))))) (arm PWild () (EApp (EApp (EVar "mapChildren") (EApp (EVar "wholeDomainExpr") (EVar "st"))) (EVar "e")))))
(DFunDef false "wholeDomainExpr" ((PVar "st") (PCon "EVar" (PVar "n"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "fileGrantExterns")) (arm (PCon "Some" (PTuple (PVar "arity") (PVar "paths"))) () (EApp (EApp (EApp (EApp (EApp (EVar "saturateGrants") (EVar "st")) (EApp (EVar "EVar") (EVar "n"))) (EVar "arity")) (EApp (EApp (EVar "replicate") (EVar "paths")) (EApp (EVar "EListLit") (EListLit)))) (EListLit))) (arm (PCon "None") () (EApp (EVar "EVar") (EVar "n")))))
(DFunDef false "wholeDomainExpr" ((PVar "st") (PVar "e")) (EApp (EApp (EVar "mapChildren") (EApp (EVar "wholeDomainExpr") (EVar "st"))) (EVar "e")))
(DTypeSig false "mapDeclBodies" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "mapDeclBodies" ((PVar "f") (PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "ps") (PVar "e") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "n")) (EVar "ps")) (EApp (EVar "f") (EVar "e"))) (EVar "site")) (EVar "bid")))
(DFunDef false "mapDeclBodies" ((PVar "f") (PCon "DLetGroup" (PVar "pub") (PVar "binds"))) (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EApp (EApp (EVar "map") (ELam ((PVar "b")) (EMatch (EVar "b") (arm (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid")) () (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EVar "map") (ELam ((PVar "c")) (EMatch (EVar "c") (arm (PCon "FunClause" (PVar "ps") (PVar "e")) () (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EVar "f") (EVar "e"))))))) (EVar "clauses"))) (EVar "site")) (EVar "bid")))))) (EVar "binds"))))
(DFunDef false "mapDeclBodies" ((PVar "f") (PAs "d" (PRec "DInterface" ((rf "methods" None)) true))) (EVariantUpdate "DInterface" (EVar "d") ((fa "methods" (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EMatch (EVar "m") (arm (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PVar "def") (PVar "mloc")) () (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EApp (EApp (EVar "map") (ELam ((PVar "dm")) (EMatch (EVar "dm") (arm (PCon "MethodDefault" (PVar "ps") (PVar "e")) () (EApp (EApp (EVar "MethodDefault") (EVar "ps")) (EApp (EVar "f") (EVar "e"))))))) (EVar "def"))) (EVar "mloc")))))) (EVar "methods"))))))
(DFunDef false "mapDeclBodies" ((PVar "f") (PAs "d" (PRec "DImpl" ((rf "methods" None)) true))) (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EMatch (EVar "m") (arm (PCon "ImplMethod" (PVar "n") (PVar "ps") (PVar "e")) () (EApp (EApp (EApp (EVar "ImplMethod") (EVar "n")) (EVar "ps")) (EApp (EVar "f") (EVar "e"))))))) (EVar "methods"))))))
(DFunDef false "mapDeclBodies" ((PVar "f") (PCon "DProp" (PVar "pub") (PVar "name") (PVar "params") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DProp") (EVar "pub")) (EVar "name")) (EVar "params")) (EApp (EVar "f") (EVar "body"))))
(DFunDef false "mapDeclBodies" ((PVar "f") (PCon "DTest" (PVar "pub") (PVar "name") (PVar "body"))) (EApp (EApp (EApp (EVar "DTest") (EVar "pub")) (EVar "name")) (EApp (EVar "f") (EVar "body"))))
(DFunDef false "mapDeclBodies" ((PVar "f") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EVar "mapDeclBodies") (EVar "f")) (EVar "d"))))
(DFunDef false "mapDeclBodies" (PWild (PVar "d")) (EVar "d"))
(DTypeSig false "isSourceless" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "isSourceless" ((PVar "gctx") (PVar "i")) (EApp (EApp (EVar "IdMap.has") (EVar "i")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants") "gsSourceless") "value")))
(DTypeSig false "builtinMethodIfaceWord" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "builtinMethodIfaceWord" ((PVar "gctx") (PVar "method")) (EMatch (EApp (EVar "builtinClassOfMethod") (EVar "method")) (arm (PCon "Some" (PVar "c")) () (EApp (EApp (EVar "ifaceWordOf") (EApp (EApp (EVar "builtinClassOrigin") (EVar "gctx")) (EVar "c"))) (EApp (EVar "builtinClassName") (EVar "c")))) (arm (PCon "None") () (ELit (LString "")))))
(DTypeSig false "builtinClassOfMethod" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "BuiltinClass"))))
(DFunDef false "builtinClassOfMethod" ((PLit (LString "eq"))) (EApp (EVar "Some") (EVar "BEq")))
(DFunDef false "builtinClassOfMethod" ((PLit (LString "append"))) (EApp (EVar "Some") (EVar "BSemigroup")))
(DFunDef false "builtinClassOfMethod" ((PVar "m")) (EIf (EApp (EApp (EVar "contains") (EVar "m")) (EListLit (ELit (LString "compare")) (ELit (LString "lt")) (ELit (LString "gt")) (ELit (LString "lte")) (ELit (LString "gte")))) (EApp (EVar "Some") (EVar "BOrd")) (EIf (EApp (EApp (EVar "contains") (EVar "m")) (EListLit (ELit (LString "add")) (ELit (LString "sub")) (ELit (LString "mul")) (ELit (LString "div")) (ELit (LString "rem")) (ELit (LString "negate")) (ELit (LString "fromInt")))) (EApp (EVar "Some") (EVar "BNum")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "resolveArgStamps" (TyFun (TyCon "SiteCtx") (TyFun (TyApp (TyCon "List") (TyCon "PendingEntry")) (TyCon "Unit"))))
(DFunDef false "resolveArgStamps" ((PVar "_sx") (PList)) (ELit LUnit))
(DFunDef false "resolveArgStamps" ((PVar "sx") (PCons (PCon "PendingEntry" (PVar "name") (PVar "tagRef") (PVar "am") (PVar "encl") (PVar "kind") (PVar "loc") (PVar "scope") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "sx") (ERecordUpdate (EVar "sx") ((fa "sxSite" (EVar "loc"))))) (DoExpr (EMatch (EVar "kind") (arm (PCon "SKArg" (PVar "implRef") (PVar "fullMono") (PVar "omitted")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveArgStamp") (EVar "sx")) (EVar "name")) (EVar "tagRef")) (EVar "implRef")) (EVar "am")) (EVar "fullMono")) (EVar "omitted")) (EVar "encl")) (EVar "loc")) (EVar "scope"))) (arm PWild () (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "resolveArgStamps") (EVar "sx")) (EVar "rest")))))
(DTypeSig false "resolveArgStamp" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ScopeId") (TyCon "Unit"))))))))))))
(DFunDef false "resolveArgStamp" ((PVar "sx") (PVar "name") (PVar "tagRef") (PVar "implRef") (PVar "am") (PVar "fullMono") (PVar "omitted") (PVar "encl") (PVar "_origin") (PVar "scope")) (EBlock (DoLet false false (PTuple (PVar "route") (PVar "routes")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "entail") (EVar "sx")) (EVar "name")) (EVar "am")) (EVar "encl")) (EVar "scope")) (EApp (EApp (EVar "EKArg") (EVar "fullMono")) (EVar "omitted")))) (DoExpr (EMatch (EVar "route") (arm (PCon "RNone") () (ELit LUnit)) (arm PWild () (EApp (EApp (EVar "setRef") (EVar "tagRef")) (EVar "route"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "implRef")) (EVar "routes")))))
(DTypeSig true "resolveSite" (TyFun (TyCon "SiteCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ScopeId") (TyCon "Unit"))))))))))))
(DFunDef false "resolveSite" ((PVar "sx") (PVar "rpNames") (PVar "name") (PVar "tagRef") (PVar "implRef") (PVar "resultMono") (PVar "fullMono") (PVar "encl") (PVar "_origin") (PVar "scope")) (EBlock (DoLet false false (PTuple (PVar "route") (PVar "routes")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "entail") (EVar "sx")) (EVar "name")) (EVar "resultMono")) (EVar "encl")) (EVar "scope")) (EApp (EApp (EVar "EKReturn") (EVar "fullMono")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "rpNames"))))) (DoExpr (EMatch (EVar "route") (arm (PCon "RNone") () (ELit LUnit)) (arm PWild () (EApp (EApp (EVar "setRef") (EVar "tagRef")) (EVar "route"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "implRef")) (EVar "routes")))))
(DTypeSig true "resolveAdmittedSite" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "String")) (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyCon "Unit"))))))))))
(DFunDef false "resolveAdmittedSite" ((PVar "sx") (PVar "name") (PVar "ifaceRef") (PVar "tagRef") (PVar "implRef") (PVar "fullMono") (PVar "encl") (PVar "scope")) (EMatch (EApp (EApp (EApp (EApp (EVar "admittedSelection") (EVar "sx")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "bodyImplEnvRef") "value")) (EVar "name")) (EVar "fullMono")) (arm (PCon "Selects" (PVar "iface") (PVar "row") (PVar "goals")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "ifaceRef")) (EApp (EApp (EVar "ifaceWordOf") (EFieldAccess (EVar "iface") "irOrigin")) (EFieldAccess (EVar "iface") "irName")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "tagRef")) (EApp (EApp (EApp (EVar "RKey") (EApp (EVar "rowRouteKey") (EVar "row"))) (EListLit)) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "selectedCallSupers") (EVar "sx")) (EVar "name")) (EApp (EVar "Some") (EVar "row"))) (EVar "encl")) (EVar "scope")) (EVar "goals"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "implRef")) (EApp (EApp (EApp (EApp (EApp (EVar "implDictRoutesForRow") (EVar "sx")) (EVar "encl")) (EVar "scope")) (EVar "goals")) (EVar "row")))))) (arm PWild () (ELit LUnit))))
(DTypeSig true "resolveExactReturnSite" (TyFun (TyCon "SiteCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyFun (TyCon "Mono") (TyFun (TyCon "MethodReturnRequest") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ScopeId") (TyCon "Unit"))))))))))))
(DFunDef false "resolveExactReturnSite" ((PVar "sx") (PVar "rpNames") (PVar "name") (PVar "tagRef") (PVar "implRef") (PVar "resultMono") (PVar "request") (PVar "encl") (PVar "origin") (PVar "scope")) (EIf (EApp (EApp (EVar "methodReturnAmbiguousWithoutGiven") (EFieldAccess (EVar "sx") "sxModule")) (EVar "request")) (EApp (EApp (EApp (EApp (EApp (EVar "noteMethodReturnTrace") (EFieldAccess (EVar "sx") "sxModule")) (EVar "MRTStamped")) (EVar "request")) (EVar "None")) (EListLit)) (EMatch (EApp (EApp (EVar "methodReturnArgs") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "request")) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "noteMethodReturnTrace") (EFieldAccess (EVar "sx") "sxModule")) (EVar "MRTStamped")) (EVar "request")) (EVar "None")) (EListLit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveSite") (EVar "sx")) (EVar "rpNames")) (EVar "name")) (EVar "tagRef")) (EVar "implRef")) (EVar "resultMono")) (EFieldAccess (EVar "request") "mrrOccurrence")) (EVar "encl")) (EVar "origin")) (EVar "scope"))))) (arm (PCon "Some" PWild) () (EBlock (DoLet false false (PVar "resolution") (EApp (EApp (EVar "solveExactReturnOnce") (EVar "sx")) (EVar "request"))) (DoExpr (EIf (EApp (EApp (EApp (EVar "methodReturnResolutionValid") (EFieldAccess (EVar "sx") "sxModule")) (EVar "request")) (EVar "resolution")) (ELit LUnit) (EApp (EVar "panic") (ELit (LString "ordinary return route received invalid solver evidence"))))) (DoLet false false (PTuple (PVar "route") (PVar "routes")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "exactReturnRoutes") (EVar "sx")) (EVar "name")) (EVar "encl")) (EVar "scope")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "rpNames"))) (EVar "resolution"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "noteMethodReturnTrace") (EFieldAccess (EVar "sx") "sxModule")) (EVar "MRTStamped")) (EVar "request")) (EApp (EVar "Some") (EVar "route"))) (EVar "routes"))) (DoExpr (EMatch (EVar "route") (arm (PCon "RNone") () (ELit LUnit)) (arm PWild () (EApp (EApp (EVar "setRef") (EVar "tagRef")) (EVar "route"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "implRef")) (EVar "routes"))))))))
(DTypeSig true "resolveNumLitSite" (TyFun (TyCon "SiteCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyFun (TyCon "ClassPredicate") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ScopeId") (TyCon "Unit"))))))))))))
(DFunDef false "resolveNumLitSite" ((PVar "sx") (PVar "rpNames") (PVar "name") (PVar "tagRef") (PVar "resultMono") (PVar "fullMono") (PVar "predicate") (PVar "encl") (PVar "origin") (PVar "scope")) (EBlock (DoLet false false (PTuple (PVar "route") (PVar "routes")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "entail") (EVar "sx")) (EVar "name")) (EVar "resultMono")) (EVar "encl")) (EVar "scope")) (EApp (EApp (EApp (EApp (EVar "EKNumReturn") (EVar "predicate")) (EVar "fullMono")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "rpNames"))) (EVar "origin")))) (DoExpr (EMatch (EVar "route") (arm (PCon "RNone") () (ELit LUnit)) (arm PWild () (EApp (EApp (EVar "setRef") (EVar "tagRef")) (EApp (EApp (EVar "numericReturnRoute") (EVar "route")) (EVar "routes")))))) (DoExpr (ELit LUnit))))
(DTypeSig true "resolveArithSite" (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyCon "Mono") (TyCon "Unit"))))
(DFunDef false "resolveArithSite" ((PVar "dref") (PVar "m")) (EMatch (EUnOp "!" (EVar "dref")) (arm (PCon "RNone") () (EMatch (EApp (EVar "arithmeticTag") (EVar "m")) (arm (PCon "Some" (PVar "tag")) () (EApp (EApp (EVar "setRef") (EVar "dref")) (EApp (EVar "RScalar") (EVar "tag")))) (arm (PCon "None") () (ELit LUnit)))) (arm PWild () (ELit LUnit))))
(DTypeSig true "resolveOpSite" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyCon "Mono") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyCon "Unit"))))))))))
(DFunDef false "resolveOpSite" ((PVar "sx") (PVar "isBinop") (PVar "method") (PVar "tagRef") (PVar "operandMono") (PVar "inImpl") (PVar "encl") (PVar "scope")) (EMatch (EApp (EVar "fst") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "entail") (EVar "sx")) (EVar "method")) (EVar "operandMono")) (EVar "encl")) (EVar "scope")) (EApp (EApp (EVar "EKOp") (EVar "isBinop")) (EVar "inImpl")))) (arm (PCon "RNone") () (ELit LUnit)) (arm (PVar "route") () (EApp (EApp (EVar "setRef") (EVar "tagRef")) (EVar "route")))))
(DTypeSig true "resolvePredicateOpSite" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyCon "Mono") (TyFun (TyCon "Bool") (TyFun (TyCon "ClassPredicate") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyCon "Unit")))))))))))
(DFunDef false "resolvePredicateOpSite" ((PVar "sx") (PVar "isBinop") (PVar "method") (PVar "tagRef") (PVar "operandMono") (PVar "inImpl") (PVar "predicate") (PVar "encl") (PVar "scope")) (EMatch (EApp (EVar "fst") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "entail") (EVar "sx")) (EVar "method")) (EVar "operandMono")) (EVar "encl")) (EVar "scope")) (EApp (EApp (EApp (EVar "EKPredicateOp") (EVar "isBinop")) (EVar "inImpl")) (EVar "predicate")))) (arm (PCon "RNone") () (ELit LUnit)) (arm (PVar "route") () (EApp (EApp (EVar "setRef") (EVar "tagRef")) (EVar "route")))))
(DTypeSig true "resolveMethodDicts" (TyFun (TyCon "SiteCtx") (TyFun (TyApp (TyCon "List") (TyCon "PendingMethodDict")) (TyCon "Unit"))))
(DFunDef false "resolveMethodDicts" ((PVar "_sx") (PList)) (ELit LUnit))
(DFunDef false "resolveMethodDicts" ((PVar "sx") (PCons (PVar "pending") (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "pending") "pmdRoutesRef")) (EApp (EApp (EApp (EApp (EVar "methodPredicateRoutes") (EVar "sx")) (EFieldAccess (EVar "pending") "pmdEncl")) (EFieldAccess (EVar "pending") "pmdScope")) (EFieldAccess (EVar "pending") "pmdSlots")))) (DoExpr (EApp (EApp (EVar "resolveMethodDicts") (EVar "sx")) (EVar "rest")))))
(DTypeSig true "resolveDictApps" (TyFun (TyCon "SiteCtx") (TyFun (TyApp (TyCon "List") (TyCon "PendingDictApp")) (TyCon "Unit"))))
(DFunDef false "resolveDictApps" ((PVar "_sx") (PList)) (ELit LUnit))
(DFunDef false "resolveDictApps" ((PVar "sx") (PCons (PVar "app") (PVar "rest"))) (EBlock (DoLet false false (PVar "sx") (ERecordUpdate (EVar "sx") ((fa "sxSite" (EFieldAccess (EVar "app") "pdaLoc"))))) (DoLet false false (PVar "routes") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routesOfMonosTopV") (EVar "sx")) (EFieldAccess (EVar "app") "pdaEncl")) (EFieldAccess (EVar "app") "pdaScope")) (EFieldAccess (EVar "app") "pdaMonos")) (EFieldAccess (EVar "app") "pdaIfaces")) (EFieldAccess (EVar "app") "pdaArgVecs"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "app") "pdaRoutesRef")) (EVar "routes"))) (DoExpr (EApp (EApp (EVar "resolveDictApps") (EVar "sx")) (EVar "rest")))))
(DTypeSig true "realizeRecDictApps" (TyFun (TyCon "SiteCtx") (TyFun (TyApp (TyCon "List") (TyCon "RecDictApp")) (TyCon "Unit"))))
(DFunDef false "realizeRecDictApps" ((PVar "_sx") (PList)) (ELit LUnit))
(DFunDef false "realizeRecDictApps" ((PVar "sx") (PCons (PCon "RecDictApp" (PVar "routesRef") (PVar "callee") (PVar "encl") (PVar "mono") (PVar "scope") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "slots") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "lookupPredicateSlots") (EVar "callee")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "funPredicateSlotsIdxRef") "value")))) (DoLet false false (PVar "routes") (EApp (EApp (EApp (EApp (EApp (EVar "recRoutes") (EVar "sx")) (EVar "encl")) (EVar "scope")) (EVar "mono")) (EVar "slots"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "routesRef")) (EVar "routes"))) (DoExpr (EApp (EApp (EVar "realizeRecDictApps") (EVar "sx")) (EVar "rest")))))
(DTypeSig false "dictPass" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "EvIndex") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))))))
(DFunDef false "dictPass" ((PVar "mctx") (PVar "idx") (PVar "mid") (PVar "names") (PVar "prog")) (EBlock (DoLet false false (PVar "pe") (EApp (EApp (EVar "PassEvidence") (EVar "idx")) (EApp (EVar "Ref") (EVar "omEmpty")))) (DoExpr (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EVar "dictPassDecl") (EVar "mctx")) (EVar "pe")) (EApp (EApp (EVar "omFromNames") (EVar "names")) (EVar "omEmpty"))) (EApp (EVar "returnPosMethodNames") (EVar "prog")))) (EApp (EApp (EVar "mapProg") (ELam ((PVar "e")) (EApp (EApp (EVar "rewriteLocalDictExpr") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EApp (EVar "rewriteBinopExpr") (EVar "mctx")) (EVar "pe")) (EVar "e"))))) (EApp (EApp (EApp (EApp (EVar "grantPass") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "pe")) (EVar "mid")) (EVar "prog")))))))
(DTypeSig false "passIndex" (TyFun (TyCon "PassEvidence") (TyCon "EvIndex")))
(DFunDef false "passIndex" ((PCon "PassEvidence" (PVar "idx") PWild)) (EVar "idx"))
(DTypeSig false "passMethodOf" (TyFun (TyCon "PassEvidence") (TyFun (TyCon "EvId") (TyCon "PassMethod"))))
(DFunDef false "passMethodOf" ((PCon "PassEvidence" (PVar "idx") (PVar "minted")) (PVar "ev")) (EMatch (EApp (EApp (EApp (EVar "evidenceLookup") (EApp (EVar "Some") (EVar "idx"))) (ELit (LString "method occurrence"))) (EVar "ev")) (arm (PCon "Ok" (PVar "v")) () (EApp (EVar "passMethodFacts") (EVar "v"))) (arm (PCon "Err" (PVar "message")) () (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "intToString") (EApp (EVar "evOrdinal") (EVar "ev")))) (EFieldAccess (EVar "minted") "value")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "passMethodFacts") (EVar "v"))) (arm (PCon "None") () (EApp (EVar "panic") (EVar "message")))))))
(DTypeSig false "passMethodFacts" (TyFun (TyCon "EvVal") (TyCon "PassMethod")))
(DFunDef false "passMethodFacts" ((PCon "EvMethod" (PVar "iface") PWild (PVar "tag") (PVar "impls") (PVar "meths"))) (EApp (EApp (EApp (EVar "PassMethod") (EVar "iface")) (EVar "tag")) (EBinOp "++" (EVar "impls") (EVar "meths"))))
(DFunDef false "passMethodFacts" (PWild) (EApp (EVar "panic") (ELit (LString "evidence table: a method occurrence answered by another kind of entry"))))
(DTypeSig false "grantPass" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "grantPass" ((PVar "gctx") (PVar "pe") (PVar "mid") (PVar "prog")) (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (DoLet false false (PVar "saved") (EFieldAccess (EFieldAccess (EVar "st") "gsPassingModule") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsPassingModule")) (EVar "mid"))) (DoLet false false (PVar "result") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "grantDecl") (EVar "gctx")) (EVar "pe")) (EVar "mid"))) (EVar "prog"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsPassingModule")) (EVar "saved"))) (DoExpr (EVar "result"))))
(DTypeSig false "grantDecl" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyCon "Decl"))))))
(DFunDef false "grantDecl" ((PVar "gctx") (PVar "pe") (PVar "mid") (PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "pats") (PVar "body") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "n")) (EBinOp "++" (EApp (EApp (EVar "grantParamPats") (EApp (EApp (EApp (EVar "topGrantIds") (EVar "gctx")) (EVar "mid")) (EVar "n"))) (EVar "n")) (EVar "pats"))) (EApp (EApp (EApp (EVar "grantBody") (EVar "gctx")) (EVar "pe")) (EVar "body"))) (EVar "site")) (EVar "bid")))
(DFunDef false "grantDecl" ((PVar "gctx") (PVar "pe") (PVar "mid") (PCon "DLetGroup" (PVar "pub") (PVar "binds"))) (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EApp (EApp (EVar "map") (ELam ((PVar "b")) (EMatch (EVar "b") (arm (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid")) () (EApp (EApp (EApp (EApp (EVar "grantLetBind") (EVar "gctx")) (EVar "pe")) (EApp (EApp (EVar "grantParamPats") (EApp (EApp (EApp (EVar "topGrantIds") (EVar "gctx")) (EVar "mid")) (EVar "n"))) (EVar "n"))) (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EVar "clauses")) (EVar "site")) (EVar "bid"))))))) (EVar "binds"))))
(DFunDef false "grantDecl" ((PVar "gctx") (PVar "pe") PWild (PAs "d" (PRec "DInterface" ((rf "name" None) (rf "ifaceOrigin" None) (rf "methods" None)) true))) (EVariantUpdate "DInterface" (EVar "d") ((fa "methods" (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "grantIfaceMethod") (EVar "gctx")) (EVar "pe")) (EApp (EApp (EVar "ifaceWordOf") (EVar "ifaceOrigin")) (EVar "name")))) (EVar "methods"))))))
(DFunDef false "grantDecl" ((PVar "gctx") (PVar "pe") PWild (PAs "d" (PRec "DImpl" ((rf "iface" None) (rf "implOrigin" None) (rf "methods" None)) true))) (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "grantImplMethod") (EVar "gctx")) (EVar "pe")) (EApp (EApp (EVar "ifaceWordOf") (EVar "implOrigin")) (EVar "iface")))) (EVar "methods"))))))
(DFunDef false "grantDecl" ((PVar "gctx") (PVar "pe") PWild (PCon "DProp" (PVar "pub") (PVar "name") (PVar "params") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DProp") (EVar "pub")) (EVar "name")) (EVar "params")) (EApp (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe")) (EVar "body"))))
(DFunDef false "grantDecl" ((PVar "gctx") (PVar "pe") PWild (PCon "DTest" (PVar "pub") (PVar "name") (PVar "body"))) (EApp (EApp (EApp (EVar "DTest") (EVar "pub")) (EVar "name")) (EApp (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe")) (EVar "body"))))
(DFunDef false "grantDecl" ((PVar "gctx") (PVar "pe") (PVar "mid") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EApp (EApp (EVar "grantDecl") (EVar "gctx")) (EVar "pe")) (EVar "mid")) (EVar "d"))))
(DFunDef false "grantDecl" ((PVar "_gctx") PWild PWild (PVar "d")) (EVar "d"))
(DTypeSig false "grantIfaceMethod" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyCon "String") (TyFun (TyCon "IfaceMethod") (TyCon "IfaceMethod"))))))
(DFunDef false "grantIfaceMethod" ((PVar "gctx") (PVar "pe") (PVar "word") (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PVar "def") (PVar "mloc"))) (EMatch (EApp (EApp (EApp (EVar "methodGrantOf") (EVar "gctx")) (EVar "word")) (EVar "n")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EApp (EApp (EVar "map") (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PCon "MethodDefault" (PVar "ps") (PVar "e")) () (EApp (EApp (EVar "MethodDefault") (EVar "ps")) (EApp (EApp (EApp (EVar "grantBody") (EVar "gctx")) (EVar "pe")) (EVar "e"))))))) (EVar "def"))) (EVar "mloc"))) (arm (PCon "Some" (PVar "mg")) () (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EApp (EApp (EApp (EVar "insertGrantArrows") (EFieldAccess (EVar "mg") "mgArity")) (EApp (EVar "listLen") (EFieldAccess (EVar "mg") "mgNames"))) (EVar "ty"))) (EApp (EApp (EVar "map") (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PCon "MethodDefault" (PVar "ps") (PVar "e")) () (EBlock (DoLet false false (PTuple (PVar "ps2") (PVar "e2")) (EApp (EApp (EApp (EApp (EApp (EVar "grantMethodParams") (EVar "gctx")) (EVar "mg")) (EVar "n")) (EVar "ps")) (EApp (EApp (EApp (EVar "grantBody") (EVar "gctx")) (EVar "pe")) (EVar "e")))) (DoExpr (EApp (EApp (EVar "MethodDefault") (EVar "ps2")) (EVar "e2")))))))) (EVar "def"))) (EVar "mloc")))))
(DTypeSig false "grantImplMethod" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyCon "String") (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod"))))))
(DFunDef false "grantImplMethod" ((PVar "gctx") (PVar "pe") (PVar "word") (PCon "ImplMethod" (PVar "n") (PVar "ps") (PVar "e"))) (EMatch (EApp (EApp (EApp (EVar "methodGrantOf") (EVar "gctx")) (EVar "word")) (EVar "n")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "ImplMethod") (EVar "n")) (EVar "ps")) (EApp (EApp (EApp (EVar "grantBody") (EVar "gctx")) (EVar "pe")) (EVar "e")))) (arm (PCon "Some" (PVar "mg")) () (EBlock (DoLet false false (PTuple (PVar "ps2") (PVar "e2")) (EApp (EApp (EApp (EApp (EApp (EVar "grantMethodParams") (EVar "gctx")) (EVar "mg")) (EVar "n")) (EVar "ps")) (EApp (EApp (EApp (EVar "grantBody") (EVar "gctx")) (EVar "pe")) (EVar "e")))) (DoExpr (EApp (EApp (EApp (EVar "ImplMethod") (EVar "n")) (EVar "ps2")) (EVar "e2")))))))
(DTypeSig false "grantMethodParams" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "MethodGrant") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))))
(DFunDef false "grantMethodParams" ((PVar "gctx") (PVar "mg") (PVar "n") (PVar "ps") (PVar "body")) (EBlock (DoLet false false (PVar "grants") (EApp (EApp (EVar "grantParamPats") (EFieldAccess (EVar "mg") "mgNames")) (EVar "n"))) (DoLet false false (PVar "given") (EApp (EVar "listLen") (EVar "ps"))) (DoExpr (EIf (EBinOp ">=" (EVar "given") (EFieldAccess (EVar "mg") "mgArity")) (ETuple (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "take") (EFieldAccess (EVar "mg") "mgArity")) (EVar "ps")) (EVar "grants")) (EApp (EApp (EVar "drop") (EFieldAccess (EVar "mg") "mgArity")) (EVar "ps"))) (EVar "body")) (EBlock (DoLet false false (PVar "missing") (EApp (EApp (EVar "map") (ELam (PWild) (EApp (EApp (EVar "freshGrantName") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (ELit LUnit)))) (EApp (EApp (EVar "range") (EVar "given")) (EFieldAccess (EVar "mg") "mgArity")))) (DoExpr (ETuple (EBinOp "++" (EBinOp "++" (EVar "ps") (EApp (EApp (EVar "map") (ELam ((PVar "x")) (EApp (EApp (EApp (EVar "PVar") (EVar "x")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (EVar "noBinderId")))) (EVar "missing"))) (EVar "grants")) (EApp (EApp (EVar "applyExprs") (EVar "body")) (EApp (EApp (EVar "map") (EVar "EVar")) (EVar "missing"))))))))))
(DTypeSig false "insertGrantArrows" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Ty") (TyCon "Ty")))))
(DFunDef false "insertGrantArrows" ((PVar "k") (PVar "g") (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EApp (EApp (EVar "TyConstrained") (EVar "cs")) (EApp (EApp (EApp (EVar "insertGrantArrows") (EVar "k")) (EVar "g")) (EVar "t"))))
(DFunDef false "insertGrantArrows" ((PVar "k") (PVar "g") (PCon "TyEffect" (PVar "effs") (PVar "tails") (PVar "t"))) (EIf (EBinOp ">" (EVar "k") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "TyEffect") (EVar "effs")) (EVar "tails")) (EApp (EApp (EApp (EVar "insertGrantArrows") (EVar "k")) (EVar "g")) (EVar "t"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "insertGrantArrows" ((PVar "k") (PVar "g") (PCon "TyFun" (PVar "a") (PVar "b"))) (EIf (EBinOp ">" (EVar "k") (ELit (LInt 0))) (EApp (EApp (EVar "TyFun") (EVar "a")) (EApp (EApp (EApp (EVar "insertGrantArrows") (EBinOp "-" (EVar "k") (ELit (LInt 1)))) (EVar "g")) (EVar "b"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "insertGrantArrows" (PWild (PVar "g") (PVar "t")) (EApp (EApp (EVar "grantArrows") (EVar "g")) (EVar "t")))
(DTypeSig false "grantArrows" (TyFun (TyCon "Int") (TyFun (TyCon "Ty") (TyCon "Ty"))))
(DFunDef false "grantArrows" ((PVar "g") (PVar "t")) (EIf (EBinOp "<=" (EVar "g") (ELit (LInt 0))) (EVar "t") (EIf (EVar "otherwise") (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "TyApp") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "List"))) (EVar "None"))) (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "String"))) (EVar "None")))) (EApp (EApp (EVar "grantArrows") (EBinOp "-" (EVar "g") (ELit (LInt 1)))) (EVar "t"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "grantLetBind" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "LetBind") (TyCon "LetBind"))))))
(DFunDef false "grantLetBind" ((PVar "gctx") (PVar "pe") (PVar "params") (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EVar "map") (ELam ((PVar "c")) (EMatch (EVar "c") (arm (PCon "FunClause" (PVar "ps") (PVar "body")) () (EApp (EApp (EVar "FunClause") (EBinOp "++" (EVar "params") (EVar "ps"))) (EApp (EApp (EApp (EVar "grantBody") (EVar "gctx")) (EVar "pe")) (EVar "body"))))))) (EVar "clauses"))) (EVar "site")) (EVar "bid")))
(DTypeSig false "topGrantIds" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "topGrantIds" ((PVar "gctx") (PVar "mid") (PVar "n")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EApp (EApp (EVar "grantTopKey") (EVar "mid")) (EVar "n"))) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants") "gsTopIds") "value"))))
(DTypeSig false "localGrantIds" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "localGrantIds" ((PVar "gctx") (PVar "n")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants") "gsLocalIds") "value"))))
(DTypeSig false "grantParamName" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "grantParamName" ((PVar "n") (PVar "i")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "$auth_")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "_"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ""))))
(DTypeSig false "grantParamPats" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")))))
(DFunDef false "grantParamPats" ((PVar "ids") (PVar "n")) (EApp (EApp (EVar "map") (ELam ((PVar "i")) (EApp (EApp (EApp (EVar "PVar") (EApp (EApp (EVar "grantParamName") (EVar "n")) (EVar "i"))) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (EVar "noBinderId")))) (EApp (EApp (EVar "range") (ELit (LInt 0))) (EApp (EVar "listLen") (EVar "ids")))))
(DTypeSig false "grantExpr" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "grantExpr" ((PVar "gctx") (PVar "pe") (PVar "e")) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EApp (EVar "grantExprInner") (EVar "gctx")) (EVar "pe")) (EVar "e"))) (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (DoExpr (EMatch (EFieldAccess (EFieldAccess (EVar "st") "gsValueBounds") "value") (arm (PCon "Tip") () (EVar "inner")) (arm PWild () (EMatch (EApp (EApp (EVar "fileValueKey") (EFieldAccess (EFieldAccess (EVar "st") "gsPassingModule") "value")) (EVar "e")) (arm (PCon "Some" (PVar "key")) () (EBlock (DoLet false false (PVar "bounds") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EFieldAccess (EVar "st") "gsValueBounds") "value")))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "result") (PTuple (PVar "ty") (PVar "chain"))) (EApp (EApp (EApp (EApp (EVar "fileBoundValue") (EVar "gctx")) (EVar "chain")) (EVar "ty")) (EVar "result")))) (EVar "inner")) (EVar "bounds"))))) (arm (PCon "None") () (EVar "inner"))))))))
(DTypeSig false "grantExprInner" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "grantExprInner" ((PVar "gctx") (PVar "pe") (PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "ELam") (EVar "pats")) (EApp (EApp (EApp (EVar "grantBody") (EVar "gctx")) (EVar "pe")) (EVar "body"))))
(DFunDef false "grantExprInner" ((PVar "gctx") (PVar "pe") (PAs "e" (PCon "EApp" PWild PWild))) (EMatch (EApp (EApp (EVar "grantSpine") (EVar "e")) (EListLit)) (arm (PTuple (PCon "EDictAt" (PVar "n") (PVar "ev")) (PVar "args")) () (EMatch (EApp (EApp (EVar "grantOccOf") (EVar "gctx")) (EVar "ev")) (arm (PCon "Some" (PVar "occ")) () (EMatch (EFieldAccess (EVar "occ") "goTrailing") (arm (PCon "Some" (PVar "arity")) () (EApp (EApp (EApp (EApp (EApp (EVar "saturateGrants") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (EApp (EVar "EVar") (EVar "n"))) (EVar "arity")) (EApp (EApp (EVar "grantTerms") (EVar "gctx")) (EVar "occ"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe"))) (EVar "args")))) (arm (PCon "None") () (EApp (EApp (EVar "mapChildren") (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe"))) (EVar "e"))))) (arm (PCon "None") () (EApp (EApp (EVar "mapChildren") (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe"))) (EVar "e"))))) (arm (PTuple (PCon "EMethodAt" (PVar "n") (PVar "seed") (PVar "ev")) (PVar "args")) () (EMatch (EApp (EApp (EApp (EApp (EVar "methodGrantUse") (EVar "gctx")) (EVar "pe")) (EVar "n")) (EVar "ev")) (arm (PCon "MethodGrants" (PVar "arity") (PVar "grants")) () (EApp (EApp (EApp (EApp (EApp (EVar "saturateGrants") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (EApp (EApp (EApp (EVar "EMethodAt") (EVar "n")) (EVar "seed")) (EVar "ev"))) (EVar "arity")) (EVar "grants")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe"))) (EVar "args")))) (arm (PCon "LeadingGrants" PWild (PVar "grants")) () (EApp (EApp (EVar "applyExprs") (EApp (EApp (EVar "applyExprs") (EApp (EApp (EApp (EVar "EMethodAt") (EVar "n")) (EVar "seed")) (EVar "ev"))) (EVar "grants"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe"))) (EVar "args")))) (arm (PCon "NoGrants") () (EApp (EApp (EVar "mapChildren") (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe"))) (EVar "e"))))) (arm PWild () (EApp (EApp (EVar "mapChildren") (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe"))) (EVar "e")))))
(DFunDef false "grantExprInner" ((PVar "gctx") PWild (PCon "EDictAt" (PVar "n") (PVar "ev"))) (EApp (EApp (EApp (EVar "grantUse") (EVar "gctx")) (EVar "n")) (EVar "ev")))
(DFunDef false "grantExprInner" ((PVar "gctx") (PVar "pe") (PCon "EMethodAt" (PVar "n") (PVar "seed") (PVar "ev"))) (EMatch (EApp (EApp (EApp (EApp (EVar "methodGrantUse") (EVar "gctx")) (EVar "pe")) (EVar "n")) (EVar "ev")) (arm (PCon "MethodGrants" (PVar "arity") (PVar "grants")) () (EApp (EApp (EApp (EApp (EApp (EVar "saturateGrants") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (EApp (EApp (EApp (EVar "EMethodAt") (EVar "n")) (EVar "seed")) (EVar "ev"))) (EVar "arity")) (EVar "grants")) (EListLit))) (arm (PCon "LeadingGrants" PWild (PVar "grants")) () (EApp (EApp (EVar "applyExprs") (EApp (EApp (EApp (EVar "EMethodAt") (EVar "n")) (EVar "seed")) (EVar "ev"))) (EVar "grants"))) (arm (PCon "NoGrants") () (EApp (EApp (EApp (EVar "EMethodAt") (EVar "n")) (EVar "seed")) (EVar "ev")))))
(DFunDef false "grantExprInner" ((PVar "gctx") (PVar "pe") (PCon "ELet" (PVar "m") (PVar "r") (PCon "PVar" (PVar "x") (PVar "xloc") (PVar "bid")) (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "r")) (EApp (EApp (EApp (EVar "PVar") (EVar "x")) (EVar "xloc")) (EVar "bid"))) (EApp (EApp (EApp (EVar "grantLocalRhs") (EVar "gctx")) (EVar "x")) (EApp (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe")) (EVar "e1")))) (EApp (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe")) (EVar "e2"))))
(DFunDef false "grantExprInner" ((PVar "gctx") (PVar "pe") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EVar "map") (ELam ((PVar "b")) (EMatch (EVar "b") (arm (PCon "LetBind" (PVar "x") (PVar "clauses") (PVar "site") (PVar "bid")) () (EApp (EApp (EApp (EApp (EVar "grantLetBind") (EVar "gctx")) (EVar "pe")) (EApp (EApp (EVar "grantParamPats") (EApp (EApp (EVar "localGrantIds") (EVar "gctx")) (EVar "x"))) (EVar "x"))) (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "x")) (EVar "clauses")) (EVar "site")) (EVar "bid"))))))) (EVar "binds"))) (EApp (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe")) (EVar "body"))))
(DFunDef false "grantExprInner" ((PVar "gctx") (PVar "pe") (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EVar "map") (EApp (EApp (EVar "grantStmt") (EVar "gctx")) (EVar "pe"))) (EVar "stmts"))))
(DFunDef false "grantExprInner" ((PVar "gctx") (PVar "pe") (PVar "e")) (EApp (EApp (EVar "mapChildren") (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe"))) (EVar "e")))
(DTypeSig false "grantStmt" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyCon "DoStmt") (TyCon "DoStmt")))))
(DFunDef false "grantStmt" ((PVar "gctx") (PVar "pe") (PCon "DoLet" (PVar "m") (PVar "r") (PCon "PVar" (PVar "x") (PVar "xloc") (PVar "bid")) (PVar "e") (PVar "site"))) (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EApp (EApp (EApp (EVar "PVar") (EVar "x")) (EVar "xloc")) (EVar "bid"))) (EApp (EApp (EApp (EVar "grantLocalRhs") (EVar "gctx")) (EVar "x")) (EApp (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe")) (EVar "e")))) (EVar "site")))
(DFunDef false "grantStmt" ((PVar "gctx") (PVar "pe") (PCon "DoExpr" (PVar "e"))) (EApp (EVar "DoExpr") (EApp (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe")) (EVar "e"))))
(DFunDef false "grantStmt" ((PVar "gctx") (PVar "pe") (PCon "DoBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "DoBind") (EVar "p")) (EApp (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe")) (EVar "e"))))
(DFunDef false "grantStmt" ((PVar "gctx") (PVar "pe") (PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e") (PVar "site"))) (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p")) (EApp (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe")) (EVar "e"))) (EVar "site")))
(DFunDef false "grantStmt" ((PVar "gctx") (PVar "pe") (PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe")) (EVar "e"))))
(DFunDef false "grantStmt" ((PVar "gctx") (PVar "pe") (PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e"))) (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe")) (EVar "e"))))
(DTypeSig false "grantLocalRhs" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "grantLocalRhs" ((PVar "gctx") (PVar "x") (PVar "e")) (EMatch (EApp (EApp (EVar "localGrantIds") (EVar "gctx")) (EVar "x")) (arm (PList) () (EVar "e")) (arm (PVar "ids") () (EApp (EApp (EVar "prependLocalDicts") (EApp (EApp (EVar "map") (ELam ((PVar "i")) (EApp (EApp (EVar "grantParamName") (EVar "x")) (EVar "i")))) (EApp (EApp (EVar "range") (ELit (LInt 0))) (EApp (EVar "listLen") (EVar "ids"))))) (EVar "e")))))
(DTypeSig false "grantSpine" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))))
(DFunDef false "grantSpine" ((PCon "EApp" (PVar "f") (PVar "x")) (PVar "args")) (EApp (EApp (EVar "grantSpine") (EVar "f")) (EBinOp "::" (EVar "x") (EVar "args"))))
(DFunDef false "grantSpine" ((PCon "ELoc" PWild (PVar "e")) (PVar "args")) (EApp (EApp (EVar "grantSpine") (EVar "e")) (EVar "args")))
(DFunDef false "grantSpine" ((PVar "e") (PVar "args")) (ETuple (EVar "e") (EVar "args")))
(DTypeSig false "grantUse" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "Expr")))))
(DFunDef false "grantUse" ((PVar "gctx") (PVar "n") (PVar "ev")) (EBlock (DoLet false false (PVar "head") (EIf (EApp (EApp (EVar "isGrantOnlyEv") (EVar "gctx")) (EVar "ev")) (EApp (EVar "EVar") (EVar "n")) (EApp (EApp (EVar "EDictAt") (EVar "n")) (EVar "ev")))) (DoExpr (EMatch (EApp (EApp (EVar "grantOccOf") (EVar "gctx")) (EVar "ev")) (arm (PCon "None") () (EVar "head")) (arm (PCon "Some" (PVar "occ")) () (EMatch (EFieldAccess (EVar "occ") "goTrailing") (arm (PCon "Some" (PVar "arity")) () (EApp (EApp (EApp (EApp (EApp (EVar "saturateGrants") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (EApp (EVar "EVar") (EVar "n"))) (EVar "arity")) (EApp (EApp (EVar "grantTerms") (EVar "gctx")) (EVar "occ"))) (EListLit))) (arm (PCon "None") () (EApp (EApp (EVar "applyExprs") (EVar "head")) (EApp (EApp (EVar "grantTerms") (EVar "gctx")) (EVar "occ"))))))))))
(DTypeSig false "methodGrantUse" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "MethodGrantUse"))))))
(DFunDef false "methodGrantUse" ((PVar "gctx") (PVar "pe") (PVar "n") (PVar "ev")) (EBlock (DoLet false false (PCon "PassMethod" (PVar "iface") (PVar "tag") PWild) (EApp (EApp (EVar "passMethodOf") (EVar "pe")) (EVar "ev"))) (DoLet false false (PVar "recorded") (EApp (EApp (EVar "grantOccOf") (EVar "gctx")) (EVar "ev"))) (DoLet false false (PVar "use") (EMatch (EVar "tag") (arm (PCon "RLocal" (PVar "sym") PWild) () (EMatch (EApp (EVar "standaloneOcc") (EVar "recorded")) (arm (PCon "Some" (PTuple (PVar "arity") (PVar "occ"))) () (EApp (EApp (EVar "LeadingGrants") (EVar "arity")) (EApp (EApp (EVar "grantTerms") (EVar "gctx")) (EVar "occ")))) (arm (PCon "None") () (EIf (EApp (EApp (EVar "omHasKey") (EIf (EBinOp "==" (EVar "sym") (ELit (LString ""))) (EVar "n") (EVar "sym"))) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants") "gsTakers") "value")) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "grant pass: '")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "' is routed to a standalone binding that takes authority grants, but inference did not type this use as that binding")))) (EVar "NoGrants"))))) (arm PWild () (EMatch (EApp (EApp (EApp (EVar "methodGrantOf") (EVar "gctx")) (EVar "iface")) (EVar "n")) (arm (PCon "None") () (EVar "NoGrants")) (arm (PCon "Some" (PVar "mg")) () (EMatch (EVar "recorded") (arm (PCon "Some" (PVar "occ")) () (EIf (EFieldAccess (EVar "occ") "goStandalone") (EApp (EApp (EVar "MethodGrants") (EFieldAccess (EVar "mg") "mgArity")) (EApp (EApp (EVar "map") (ELam (PWild) (EVar "bottomGrant"))) (EFieldAccess (EVar "mg") "mgNames"))) (EApp (EApp (EVar "MethodGrants") (EFieldAccess (EVar "mg") "mgArity")) (EApp (EApp (EApp (EApp (EVar "methodTerms") (EVar "gctx")) (EVar "n")) (EVar "mg")) (EVar "occ"))))) (arm (PCon "None") () (EApp (EApp (EVar "MethodGrants") (EFieldAccess (EVar "mg") "mgArity")) (EApp (EApp (EVar "map") (ELam (PWild) (EVar "bottomGrant"))) (EFieldAccess (EVar "mg") "mgNames")))))))))) (DoExpr (EMatch (EVar "use") (arm (PCon "MethodGrants" (PVar "arity") (PVar "grants")) () (EApp (EApp (EApp (EApp (EVar "setOccurrenceArity") (EVar "gctx")) (EVar "pe")) (EVar "ev")) (EBinOp "+" (EVar "arity") (EApp (EVar "listLen") (EVar "grants"))))) (arm (PCon "LeadingGrants" (PVar "arity") (PVar "grants")) () (EApp (EApp (EApp (EApp (EVar "setOccurrenceArity") (EVar "gctx")) (EVar "pe")) (EVar "ev")) (EBinOp "+" (EVar "arity") (EApp (EVar "listLen") (EVar "grants"))))) (arm (PCon "NoGrants") () (ELit LUnit)))) (DoExpr (EVar "use"))))
(DTypeSig false "setOccurrenceArity" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyCon "EvId") (TyFun (TyCon "Int") (TyCon "Unit"))))))
(DFunDef false "setOccurrenceArity" ((PVar "gctx") (PVar "pe") (PVar "ev") (PVar "arity")) (EIf (EBinOp "<" (EApp (EVar "evOrdinal") (EVar "ev")) (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "evBase")) (EApp (EApp (EApp (EVar "setServedArity") (EApp (EVar "passIndex") (EVar "pe"))) (EVar "ev")) (EVar "arity")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "cell") (EApp (EApp (EVar "methodCellOf") (EVar "gctx")) (EVar "ev"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "cell") "ecArity")) (EApp (EVar "Some") (EVar "arity"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "standaloneOcc" (TyFun (TyApp (TyCon "Option") (TyCon "GrantOcc")) (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "GrantOcc")))))
(DFunDef false "standaloneOcc" ((PCon "Some" (PVar "occ"))) (EMatch (ETuple (EFieldAccess (EVar "occ") "goStandalone") (EFieldAccess (EVar "occ") "goTrailing")) (arm (PTuple (PCon "True") (PCon "Some" (PVar "arity"))) () (EApp (EVar "Some") (ETuple (EVar "arity") (EVar "occ")))) (arm PWild () (EVar "None"))))
(DFunDef false "standaloneOcc" ((PCon "None")) (EVar "None"))
(DTypeSig false "methodTerms" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "MethodGrant") (TyFun (TyCon "GrantOcc") (TyApp (TyCon "List") (TyCon "Expr")))))))
(DFunDef false "methodTerms" ((PVar "gctx") (PVar "n") (PVar "mg") (PVar "occ")) (EBlock (DoLet false false (PVar "terms") (EApp (EApp (EVar "grantTerms") (EVar "gctx")) (EVar "occ"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "terms")) (EApp (EVar "listLen") (EFieldAccess (EVar "mg") "mgNames"))) (EVar "terms") (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "grant pass: a use of method '")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "' instantiated "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "terms"))))) (ELit (LString " authorities, but the method takes "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EFieldAccess (EVar "mg") "mgNames"))))) (ELit (LString " grants"))))))))
(DTypeSig false "bottomGrant" (TyCon "Expr"))
(DFunDef false "bottomGrant" () (EApp (EVar "EListLit") (EListLit (EApp (EVar "ELit") (EApp (EVar "LString") (ELit (LString "")))))))
(DTypeSig false "applyExprs" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Expr"))))
(DFunDef false "applyExprs" ((PVar "f") (PVar "args")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "a")) (EApp (EApp (EVar "EApp") (EVar "acc")) (EVar "a")))) (EVar "f")) (EVar "args")))
(DTypeSig false "saturateGrants" (TyFun (TyCon "GrantState") (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Expr")))))))
(DFunDef false "saturateGrants" ((PVar "st") (PVar "head") (PVar "arity") (PVar "grants") (PVar "args")) (EBlock (DoLet false false (PVar "given") (EApp (EVar "listLen") (EVar "args"))) (DoExpr (EIf (EBinOp ">=" (EVar "given") (EVar "arity")) (EApp (EApp (EVar "applyExprs") (EApp (EApp (EVar "applyExprs") (EVar "head")) (EBinOp "++" (EApp (EApp (EVar "take") (EVar "arity")) (EVar "args")) (EVar "grants")))) (EApp (EApp (EVar "drop") (EVar "arity")) (EVar "args"))) (EBlock (DoLet false false (PVar "bound") (EApp (EApp (EVar "map") (ELam ((PVar "a")) (ETuple (EApp (EApp (EVar "freshGrantName") (EVar "st")) (ELit LUnit)) (EVar "a")))) (EVar "args"))) (DoLet false false (PVar "missing") (EApp (EApp (EVar "map") (ELam (PWild) (EApp (EApp (EVar "freshGrantName") (EVar "st")) (ELit LUnit)))) (EApp (EApp (EVar "range") (EVar "given")) (EVar "arity")))) (DoLet false false (PVar "call") (EApp (EApp (EVar "applyExprs") (EVar "head")) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "b")) (EApp (EVar "EVar") (EApp (EVar "fst") (EVar "b"))))) (EVar "bound")) (EApp (EApp (EVar "map") (EVar "EVar")) (EVar "missing"))) (EVar "grants")))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "body") (PVar "b")) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "noDeclLoc")) (EVar "False")) (EApp (EApp (EApp (EVar "PVar") (EApp (EVar "fst") (EVar "b"))) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (EVar "noBinderId"))) (EApp (EVar "snd") (EVar "b"))) (EVar "body")))) (EApp (EApp (EVar "ELam") (EApp (EApp (EVar "map") (ELam ((PVar "x")) (EApp (EApp (EApp (EVar "PVar") (EVar "x")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (EVar "noBinderId")))) (EVar "missing"))) (EVar "call"))) (EApp (EVar "reverse") (EVar "bound")))))))))
(DTypeSig false "freshGrantName" (TyFun (TyCon "GrantState") (TyFun (TyCon "Unit") (TyCon "String"))))
(DFunDef false "freshGrantName" ((PVar "st") PWild) (EBlock (DoLet false false (PVar "k") (EFieldAccess (EFieldAccess (EVar "st") "gsFresh") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsFresh")) (EBinOp "+" (EVar "k") (ELit (LInt 1))))) (DoExpr (EBinOp "++" (EBinOp "++" (ELit (LString "$grant_arg_")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString ""))))))
(DTypeSig false "fileBoundValue" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "GrantBinder")) (TyFun (TyCon "Mono") (TyFun (TyCon "Expr") (TyCon "Expr"))))))
(DFunDef false "fileBoundValue" ((PVar "gctx") (PVar "chain") (PVar "ty") (PVar "e")) (EIf (EApp (EVar "hasFileBoundValue") (EVar "ty")) (EMatch (EApp (EVar "normalize") (EVar "ty")) (arm (PCon "TFun" PWild (PVar "row") (PVar "result")) () (EBlock (DoLet false false (PVar "fn") (EApp (EApp (EVar "freshGrantName") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (ELit LUnit))) (DoLet false false (PVar "arg") (EApp (EApp (EVar "freshGrantName") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "noDeclLoc")) (EVar "False")) (EApp (EApp (EApp (EVar "PVar") (EVar "fn")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (EVar "noBinderId"))) (EVar "e")) (EApp (EApp (EVar "ELam") (EListLit (EApp (EApp (EApp (EVar "PVar") (EVar "arg")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (EVar "noBinderId")))) (EApp (EApp (EApp (EApp (EVar "fileBoundExpr") (EVar "gctx")) (EVar "chain")) (EVar "row")) (EApp (EApp (EApp (EApp (EVar "fileBoundValue") (EVar "gctx")) (EVar "chain")) (EVar "result")) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "fn"))) (EApp (EVar "EVar") (EVar "arg")))))))))) (arm (PCon "TQual" (PVar "inner") PWild) () (EApp (EApp (EApp (EApp (EVar "fileBoundValue") (EVar "gctx")) (EVar "chain")) (EVar "inner")) (EVar "e"))) (arm PWild () (EVar "e"))) (EVar "e")))
(DTypeSig false "grantBody" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "grantBody" ((PVar "gctx") (PVar "pe") (PVar "body")) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe")) (EVar "body"))) (DoExpr (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants") "gsBounds") "value") (arm (PCon "Tip") () (EVar "inner")) (arm (PVar "boundsBySite") () (EBlock (DoLet false false (PVar "bounds") (EMatch (EApp (EVar "fileBodyLoc") (EVar "body")) (arm (PCon "Some" (PVar "loc")) () (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EApp (EApp (EVar "fileBoundSite") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants") "gsPassingModule") "value")) (EVar "loc"))) (EVar "boundsBySite")))) (arm (PCon "None") () (EListLit)))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "result") (PTuple (PVar "row") (PVar "chain"))) (EApp (EApp (EApp (EApp (EVar "fileBoundExpr") (EVar "gctx")) (EVar "chain")) (EVar "row")) (EVar "result")))) (EVar "inner")) (EVar "bounds")))))))))
(DTypeSig false "fileBoundExpr" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "GrantBinder")) (TyFun (TyCon "EffRow") (TyFun (TyCon "Expr") (TyCon "Expr"))))))
(DFunDef false "fileBoundExpr" ((PVar "gctx") (PVar "chain") (PVar "row") (PVar "body")) (EBlock (DoLet false false (PTuple (PVar "atoms") (PVar "tails")) (EApp (EVar "rowFlat") (EVar "row"))) (DoExpr (EIf (EApp (EVar "isNonEmptyL") (EVar "tails")) (EVar "body") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "result") (PVar "atom")) (EBlock (DoLet false false (PVar "label") (EApp (EVar "atomLabel") (EVar "atom"))) (DoExpr (EIf (EApp (EVar "narrowFileAtom") (EVar "atom")) (EApp (EApp (EVar "applyExprs") (EApp (EVar "EVar") (EBinOp "++" (EBinOp "++" (ELit (LString "$with")) (EVar "label")) (ELit (LString "Bound"))))) (EListLit (EApp (EApp (EApp (EVar "grantTerm") (EVar "gctx")) (EVar "chain")) (EApp (EVar "atomAuth") (EVar "atom"))) (EApp (EApp (EVar "ELam") (EListLit (EVar "PWild"))) (EVar "result")))) (EVar "result")))))) (EVar "body")) (EVar "atoms"))))))
(DTypeSig false "grantTerms" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "GrantOcc") (TyApp (TyCon "List") (TyCon "Expr")))))
(DFunDef false "grantTerms" ((PVar "gctx") (PVar "occ")) (EMatch (EFieldAccess (EVar "occ") "goRecIds") (arm (PList) () (EApp (EApp (EVar "map") (EApp (EApp (EVar "grantTerm") (EVar "gctx")) (EFieldAccess (EVar "occ") "goChain"))) (EFieldAccess (EVar "occ") "goCells"))) (arm (PVar "ids") () (EApp (EApp (EVar "map") (ELam ((PVar "i")) (EApp (EApp (EApp (EVar "grantIdTerm") (EVar "gctx")) (EFieldAccess (EVar "occ") "goChain")) (EVar "i")))) (EVar "ids")))))
(DTypeSig false "grantTerm" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "GrantBinder")) (TyFun (TyCon "Authority") (TyCon "Expr")))))
(DFunDef false "grantTerm" ((PVar "gctx") (PVar "chain") (PVar "a")) (EMatch (EApp (EVar "authGrantShape") (EVar "a")) (arm (PCon "GrantTop") () (EApp (EVar "EListLit") (EListLit))) (arm (PCon "GrantBottom") () (EVar "bottomGrant")) (arm (PCon "GrantParts" (PVar "elems") (PVar "vars")) () (EMatch (EApp (EApp (EApp (EApp (EVar "grantVarParams") (EVar "gctx")) (EVar "chain")) (EVar "vars")) (EListLit)) (arm (PCon "None") () (EApp (EVar "EListLit") (EListLit))) (arm (PCon "Some" (PVar "params")) () (EBlock (DoLet false false (PVar "parts") (EBinOp "++" (EIf (EApp (EVar "isEmptyL") (EVar "elems")) (EListLit) (EListLit (EApp (EVar "EListLit") (EApp (EApp (EVar "map") (ELam ((PVar "s")) (EApp (EVar "ELit") (EApp (EVar "LString") (EVar "s"))))) (EVar "elems"))))) (EApp (EApp (EVar "map") (EVar "EVar")) (EApp (EVar "dedup") (EVar "params"))))) (DoExpr (EMatch (EVar "parts") (arm (PList) () (EVar "bottomGrant")) (arm (PList (PVar "p")) () (EVar "p")) (arm (PCons (PVar "p") (PVar "rest")) () (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "param")) (EApp (EApp (EVar "topAbsorbs") (EVar "param")) (EVar "acc")))) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "q")) (EApp (EApp (EApp (EApp (EVar "EBinOp") (ELit (LString "++"))) (EVar "acc")) (EVar "q")) (EVar "unminted")))) (EApp (EVar "EListLit") (EListLit))) (EBinOp "::" (EVar "p") (EVar "rest")))) (EApp (EVar "dedup") (EVar "params"))))))))))))
(DTypeSig false "grantVarParams" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "GrantBinder")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "grantVarParams" ((PVar "_gctx") PWild (PList) (PVar "acc")) (EApp (EVar "Some") (EApp (EVar "reverse") (EVar "acc"))))
(DFunDef false "grantVarParams" ((PVar "gctx") (PVar "chain") (PCons (PVar "v") (PVar "rest")) (PVar "acc")) (EMatch (EApp (EApp (EApp (EVar "grantParamFor") (EVar "gctx")) (EVar "chain")) (EApp (EVar "authvarId") (EVar "v"))) (arm (PCon "Some" (PVar "p")) () (EApp (EApp (EApp (EApp (EVar "grantVarParams") (EVar "gctx")) (EVar "chain")) (EVar "rest")) (EBinOp "::" (EVar "p") (EVar "acc")))) (arm (PCon "None") () (EIf (EApp (EApp (EVar "isSourceless") (EVar "gctx")) (EApp (EVar "authvarId") (EVar "v"))) (EVar "None") (EApp (EApp (EApp (EApp (EVar "grantVarParams") (EVar "gctx")) (EVar "chain")) (EVar "rest")) (EVar "acc"))))))
(DTypeSig false "topAbsorbs" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "topAbsorbs" ((PVar "param") (PVar "join")) (EApp (EApp (EVar "EMatch") (EApp (EVar "EVar") (EVar "param"))) (EListLit (EApp (EApp (EApp (EVar "Arm") (EApp (EVar "PList") (EListLit))) (EListLit)) (EApp (EVar "EListLit") (EListLit))) (EApp (EApp (EApp (EVar "Arm") (EVar "PWild")) (EListLit)) (EVar "join")))))
(DTypeSig false "grantIdTerm" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "GrantBinder")) (TyFun (TyCon "Int") (TyCon "Expr")))))
(DFunDef false "grantIdTerm" ((PVar "gctx") (PVar "chain") (PVar "i")) (EMatch (EApp (EApp (EApp (EVar "grantParamFor") (EVar "gctx")) (EVar "chain")) (EVar "i")) (arm (PCon "Some" (PVar "p")) () (EApp (EVar "EVar") (EVar "p"))) (arm (PCon "None") () (EVar "bottomGrant"))))
(DTypeSig false "grantParamFor" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "GrantBinder")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "grantParamFor" ((PVar "_gctx") (PList) PWild) (EVar "None"))
(DFunDef false "grantParamFor" ((PVar "gctx") (PCons (PVar "b") (PVar "rest")) (PVar "i")) (EBlock (DoLet false false (PTuple (PVar "name") (PVar "ids")) (EMatch (EVar "b") (arm (PCon "TopGrantBinder" (PVar "mid") (PVar "n")) () (ETuple (EVar "n") (EApp (EApp (EApp (EVar "topGrantIds") (EVar "gctx")) (EVar "mid")) (EVar "n")))) (arm (PCon "LocalGrantBinder" (PVar "n")) () (ETuple (EVar "n") (EApp (EApp (EVar "localGrantIds") (EVar "gctx")) (EVar "n")))) (arm (PCon "BodyGrantBinder" (PVar "n") (PVar "bound")) () (ETuple (EVar "n") (EVar "bound"))))) (DoExpr (EMatch (EApp (EApp (EVar "elemIndex") (EVar "i")) (EVar "ids")) (arm (PCon "Some" (PVar "k")) () (EApp (EVar "Some") (EApp (EApp (EVar "grantParamName") (EVar "name")) (EVar "k")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "grantParamFor") (EVar "gctx")) (EVar "rest")) (EVar "i")))))))
(DTypeSig false "rewriteBinopExpr" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "rewriteBinopExpr" ((PVar "mctx") (PVar "pe") (PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") (PVar "ev"))) (EMatch (EApp (EApp (EVar "evSiteRouteIn") (EApp (EVar "passIndex") (EVar "pe"))) (EVar "ev")) (arm (PCon "RNone") () (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EVar "l")) (EVar "r")) (EVar "ev"))) (arm (PCon "RScalar" (PVar "tag")) () (EApp (EApp (EVar "EAnnot") (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EVar "l")) (EVar "r")) (EVar "ev"))) (EApp (EApp (EVar "tyConBuiltin") (EVar "tag")) (EVar "None")))) (arm (PVar "route") () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "binopMethodApp") (EVar "mctx")) (EVar "pe")) (EVar "op")) (EVar "l")) (EVar "r")) (EVar "route")))))
(DFunDef false "rewriteBinopExpr" ((PVar "mctx") (PVar "pe") (PCon "ENumLit" (PVar "n") (PVar "ev") PWild)) (EMatch (EApp (EApp (EVar "evSiteLitIn") (EApp (EVar "passIndex") (EVar "pe"))) (EVar "ev")) (arm (PTuple (PCon "Some" (PVar "f")) PWild) () (EApp (EVar "ELit") (EApp (EVar "LFloat") (EVar "f")))) (arm (PTuple (PCon "None") (PVar "dref")) () (EMatch (EVar "dref") (arm (PCon "RNone") () (EApp (EVar "ELit") (EApp (EVar "LInt") (EVar "n")))) (arm (PVar "route") ((GBool (EApp (EApp (EVar "fixedWidthLiteralFits") (EVar "route")) (EVar "n")))) (EApp (EVar "ELit") (EApp (EVar "LInt") (EVar "n")))) (arm (PVar "route") ((GBool (EApp (EApp (EVar "u64LiteralFits") (EVar "route")) (EVar "n")))) (EApp (EVar "ELit") (EApp (EApp (EVar "LU64") (EBinOp "/" (EVar "n") (ELit (LInt 4294967296)))) (EBinOp "%" (EVar "n") (ELit (LInt 4294967296)))))) (arm (PCon "RKey" (PVar "word") PWild PWild) ((GBool (EApp (EVar "isI64Head") (EApp (EVar "literalRouteHead") (EVar "word"))))) (EBlock (DoLet false false (PVar "halves") (EApp (EVar "int64Halves") (EVar "n"))) (DoExpr (EApp (EVar "ELit") (EApp (EApp (EVar "LI64") (EApp (EVar "fst") (EVar "halves"))) (EApp (EVar "snd") (EVar "halves"))))))) (arm (PVar "route") () (EBlock (DoLet false false (PVar "split") (EApp (EVar "binopRouteSplit") (EVar "route"))) (DoExpr (EApp (EApp (EVar "EApp") (EApp (EApp (EApp (EVar "EMethodAt") (ELit (LString "fromInt"))) (ELit (LString ""))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mintMethodCellWith") (EVar "mctx")) (EVar "pe")) (EApp (EApp (EVar "builtinMethodIfaceWord") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit (LString "fromInt")))) (ELit (LInt 1))) (EApp (EVar "fst") (EVar "split"))) (EApp (EVar "snd") (EVar "split"))))) (EApp (EVar "ELit") (EApp (EVar "LInt") (EVar "n")))))))))))
(DFunDef false "rewriteBinopExpr" ((PVar "mctx") (PVar "pe") (PCon "EUnOp" (PVar "op") (PVar "e") (PVar "ev"))) (EMatch (EApp (EApp (EVar "evSiteRouteIn") (EApp (EVar "passIndex") (EVar "pe"))) (EVar "ev")) (arm (PCon "RNone") () (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EVar "e")) (EVar "ev"))) (arm (PCon "RScalar" PWild) () (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EVar "e")) (EVar "ev"))) (arm (PCon "RKey" (PVar "word") PWild PWild) ((GBool (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "op") (ELit (LString "-"))) (EApp (EVar "isI32Head") (EApp (EVar "literalRouteHead") (EVar "word")))) (EApp (EVar "isSome") (EApp (EVar "negatedI32Lit") (EVar "e")))))) (EApp (EVar "ELit") (EApp (EVar "LInt") (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EVar "negatedI32Lit") (EVar "e")))))) (arm (PVar "route") () (EApp (EApp (EApp (EApp (EApp (EVar "unopMethodApp") (EVar "mctx")) (EVar "pe")) (EVar "op")) (EVar "e")) (EVar "route")))))
(DFunDef false "rewriteBinopExpr" ((PVar "_mctx") (PVar "pe") (PCon "EWideLit" (PVar "hi") (PVar "lo") (PVar "ev") PWild)) (EMatch (EApp (EApp (EVar "evSiteRouteIn") (EApp (EVar "passIndex") (EVar "pe"))) (EVar "ev")) (arm (PCon "RKey" (PVar "word") PWild PWild) ((GBool (EApp (EVar "isI64Head") (EApp (EVar "literalRouteHead") (EVar "word"))))) (EApp (EVar "ELit") (EApp (EApp (EVar "LI64") (EVar "hi")) (EVar "lo")))) (arm PWild () (EApp (EVar "ELit") (EApp (EApp (EVar "LU64") (EVar "hi")) (EVar "lo"))))))
(DFunDef false "rewriteBinopExpr" ((PVar "_mctx") PWild (PVar "e")) (EVar "e"))
(DTypeSig false "negatedI32Lit" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "negatedI32Lit" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "negatedI32Lit") (EVar "e")))
(DFunDef false "negatedI32Lit" ((PCon "ELit" (PCon "LInt" (PVar "n")))) (EApp (EVar "negatedInI32") (EVar "n")))
(DFunDef false "negatedI32Lit" ((PCon "EApp" (PCon "EMethodAt" (PLit (LString "fromInt")) PWild PWild) (PCon "ELit" (PCon "LInt" (PVar "n"))))) (EApp (EVar "negatedInI32") (EVar "n")))
(DFunDef false "negatedI32Lit" (PWild) (EVar "None"))
(DTypeSig false "negatedInI32" (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "negatedInI32" ((PVar "n")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (EUnOp "-" (ELit (LInt 2147483647)))) (EBinOp "<=" (EVar "n") (ELit (LInt 2147483648)))) (EApp (EVar "Some") (EBinOp "-" (ELit (LInt 0)) (EVar "n"))) (EVar "None")))
(DTypeSig false "u64LiteralFits" (TyFun (TyCon "Route") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "u64LiteralFits" ((PCon "RKey" (PVar "word") PWild PWild) (PVar "n")) (EBinOp "&&" (EApp (EVar "isU64Head") (EApp (EVar "literalRouteHead") (EVar "word"))) (EBinOp ">=" (EVar "n") (ELit (LInt 0)))))
(DFunDef false "u64LiteralFits" (PWild PWild) (EVar "False"))
(DTypeSig false "fixedWidthLiteralFits" (TyFun (TyCon "Route") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "fixedWidthLiteralFits" ((PCon "RKey" (PVar "word") PWild PWild) (PVar "n")) (EBlock (DoLet false false (PVar "head") (EApp (EVar "literalRouteHead") (EVar "word"))) (DoExpr (EMatch (EApp (EVar "taggedFixedRange") (EVar "head")) (arm (PCon "Some" (PTuple (PVar "lo") (PVar "hi"))) () (EBinOp "&&" (EBinOp ">=" (EVar "n") (EVar "lo")) (EBinOp "<=" (EVar "n") (EVar "hi")))) (arm (PCon "None") () (EVar "False"))))))
(DFunDef false "fixedWidthLiteralFits" (PWild PWild) (EVar "False"))
(DTypeSig false "literalRouteHead" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "literalRouteHead" ((PVar "word")) (EMatch (EApp (EApp (EVar "splitOnChar") (ELit (LChar "|"))) (EVar "word")) (arm (PCons PWild (PCons (PVar "ty") PWild)) () (EVar "ty")) (arm PWild () (EVar "word"))))
(DTypeSig false "binopRouteSplit" (TyFun (TyCon "Route") (TyTuple (TyCon "Route") (TyApp (TyCon "List") (TyCon "Route")))))
(DFunDef false "binopRouteSplit" ((PCon "RKey" (PVar "tag") (PVar "reqs") (PVar "sups"))) (ETuple (EApp (EApp (EApp (EVar "RKey") (EVar "tag")) (EListLit)) (EVar "sups")) (EVar "reqs")))
(DFunDef false "binopRouteSplit" ((PVar "r")) (ETuple (EVar "r") (EListLit)))
(DTypeSig false "binopMethodApp" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Route") (TyCon "Expr"))))))))
(DFunDef false "binopMethodApp" ((PVar "mctx") (PVar "pe") (PVar "op") (PVar "l") (PVar "r") (PVar "route")) (EBlock (DoLet false false (PVar "method") (EApp (EApp (EVar "optionOr") (ELit (LString "eq"))) (EApp (EVar "binopDispatchMethod") (EVar "op")))) (DoLet false false (PVar "split") (EApp (EVar "binopRouteSplit") (EVar "route"))) (DoLet false false (PVar "call") (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EApp (EApp (EVar "EMethodAt") (EVar "method")) (ELit (LString ""))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mintMethodCellWith") (EVar "mctx")) (EVar "pe")) (EApp (EApp (EVar "builtinMethodIfaceWord") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "method"))) (ELit (LInt 2))) (EApp (EVar "fst") (EVar "split"))) (EApp (EVar "snd") (EVar "split"))))) (EVar "l"))) (EVar "r"))) (DoExpr (EIf (EBinOp "==" (EVar "op") (ELit (LString "/="))) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "not")))) (EVar "call")) (EVar "call")))))
(DTypeSig false "binopDispatchMethod" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "binopDispatchMethod" ((PVar "op")) (EMatch (EApp (EVar "arithDispatchMethod") (EVar "op")) (arm (PCon "Some" (PVar "method")) () (EApp (EVar "Some") (EVar "method"))) (arm (PCon "None") () (EApp (EVar "binopMethod") (EVar "op")))))
(DTypeSig false "unopMethodApp" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Route") (TyCon "Expr")))))))
(DFunDef false "unopMethodApp" ((PVar "mctx") (PVar "pe") (PVar "op") (PVar "e") (PVar "route")) (EBlock (DoLet false false (PVar "method") (EApp (EApp (EVar "optionOr") (ELit (LString "negate"))) (EApp (EVar "unopMethod") (EVar "op")))) (DoLet false false (PVar "split") (EApp (EVar "binopRouteSplit") (EVar "route"))) (DoExpr (EApp (EApp (EVar "EApp") (EApp (EApp (EApp (EVar "EMethodAt") (EVar "method")) (ELit (LString ""))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mintMethodCellWith") (EVar "mctx")) (EVar "pe")) (EApp (EApp (EVar "builtinMethodIfaceWord") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "method"))) (ELit (LInt 1))) (EApp (EVar "fst") (EVar "split"))) (EApp (EVar "snd") (EVar "split"))))) (EVar "e")))))
(DTypeSig false "dictPassDecl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Decl") (TyCon "Decl")))))))
(DFunDef false "dictPassDecl" ((PVar "mctx") PWild (PVar "names") PWild (PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "pats") (PVar "body") (PVar "site") (PVar "bid"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "names")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "n")) (EBinOp "++" (EApp (EApp (EVar "dictParams") (EVar "n")) (EApp (EApp (EVar "dictArityOf") (EVar "mctx")) (EVar "n"))) (EVar "pats"))) (EVar "body")) (EVar "site")) (EVar "bid")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "n")) (EVar "pats")) (EVar "body")) (EVar "site")) (EVar "bid")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "dictPassDecl" ((PVar "mctx") PWild (PVar "names") PWild (PCon "DLetGroup" (PVar "pub") (PVar "binds"))) (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "dictPassLetBind") (EVar "mctx")) (EVar "names"))) (EVar "binds"))))
(DFunDef false "dictPassDecl" ((PVar "mctx") (PVar "pe") PWild PWild (PAs "d" (PRec "DImpl" ((rf "iface" None) (rf "implOrigin" None) (rf "reqs" None) (rf "methods" None)) true))) (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EApp (EApp (EApp (EApp (EApp (EVar "implDictPassMethods") (EVar "mctx")) (EVar "pe")) (ERecordCreate "IfaceRef" ((fa "irName" (EVar "iface")) (fa "irOrigin" (EVar "implOrigin"))))) (EApp (EVar "listLen") (EVar "reqs"))) (EVar "methods"))))))
(DFunDef false "dictPassDecl" ((PVar "_mctx") PWild PWild PWild (PAs "d" (PRec "DInterface" ((rf "typarams" None) (rf "methods" None)) true))) (EVariantUpdate "DInterface" (EVar "d") ((fa "methods" (EApp (EApp (EVar "map") (EApp (EVar "ifaceDictPassMethod") (EVar "typarams"))) (EVar "methods"))))))
(DFunDef false "dictPassDecl" ((PVar "mctx") (PVar "pe") (PVar "names") (PVar "ret") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EApp (EApp (EApp (EVar "dictPassDecl") (EVar "mctx")) (EVar "pe")) (EVar "names")) (EVar "ret")) (EVar "d"))))
(DFunDef false "dictPassDecl" ((PVar "_mctx") PWild PWild PWild (PVar "d")) (EVar "d"))
(DTypeSig false "dictPassLetBind" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "LetBind") (TyCon "LetBind")))))
(DFunDef false "dictPassLetBind" ((PVar "mctx") (PVar "names") (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "names")) (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "prependDictClause") (EVar "n")) (EApp (EApp (EVar "dictArityOf") (EVar "mctx")) (EVar "n")))) (EVar "clauses"))) (EVar "site")) (EVar "bid")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EVar "clauses")) (EVar "site")) (EVar "bid")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "prependDictClause" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "FunClause") (TyCon "FunClause")))))
(DFunDef false "prependDictClause" ((PVar "n") (PVar "k") (PCon "FunClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EBinOp "++" (EApp (EApp (EVar "dictParams") (EVar "n")) (EVar "k")) (EVar "pats"))) (EVar "body")))
(DTypeSig false "ifaceDictPassMethod" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyCon "IfaceMethod"))))
(DFunDef false "ifaceDictPassMethod" ((PVar "typarams") (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "Some" (PCon "MethodDefault" (PVar "pats") (PVar "body"))) (PVar "mloc"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ifaceDictPassDefault") (EVar "n")) (EVar "ty")) (EVar "pats")) (EVar "body")) (EVar "mloc")) (EApp (EVar "listLen") (EApp (EApp (EVar "methodLevelConstraintVarNames") (EVar "typarams")) (EVar "ty")))))
(DFunDef false "ifaceDictPassMethod" (PWild (PVar "m")) (EVar "m"))
(DTypeSig false "ifaceDictPassDefault" (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Int") (TyCon "IfaceMethod"))))))))
(DFunDef false "ifaceDictPassDefault" ((PVar "n") (PVar "ty") (PVar "pats") (PVar "body") (PVar "mloc") (PVar "k")) (EIf (EBinOp ">" (EVar "k") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EApp (EVar "Some") (EApp (EApp (EVar "MethodDefault") (EBinOp "++" (EApp (EApp (EVar "dictParams") (EVar "n")) (EVar "k")) (EVar "pats"))) (EVar "body")))) (EVar "mloc")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EApp (EVar "Some") (EApp (EApp (EVar "MethodDefault") (EVar "pats")) (EVar "body")))) (EVar "mloc")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "implDictPassMethods" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyApp (TyCon "List") (TyCon "ImplMethod"))))))))
(DFunDef false "implDictPassMethods" ((PVar "mctx") (PVar "pe") (PVar "iface") (PVar "nReq") (PVar "methods")) (EBlock (DoLet false false (PVar "users") (EApp (EVar "dedup") (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EApp (EVar "clauseImplDictUser") (EVar "mctx")) (EVar "pe")) (EVar "iface")) (EVar "nReq"))) (EVar "methods")))) (DoExpr (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EVar "prependImplDictIfUser") (EVar "mctx")) (EVar "iface")) (EVar "nReq")) (EVar "users"))) (EVar "methods")))))
(DTypeSig false "clauseImplDictUser" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "Int") (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "clauseImplDictUser" ((PVar "mctx") (PVar "pe") (PVar "iface") (PVar "nReq") (PCon "ImplMethod" (PVar "n") PWild (PVar "body"))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "usesImplDict") (EVar "pe")) (EVar "n")) (EApp (EApp (EApp (EVar "implMethodDictArity") (EVar "mctx")) (EVar "iface")) (EVar "n"))) (EVar "nReq")) (EVar "body")) (EListLit (EVar "n")) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "prependImplDictIfUser" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod")))))))
(DFunDef false "prependImplDictIfUser" ((PVar "mctx") (PVar "iface") (PVar "nReq") (PVar "users") (PCon "ImplMethod" (PVar "n") (PVar "pats") (PVar "body"))) (EBlock (DoLet false false (PVar "k") (EApp (EApp (EApp (EVar "implMethodDictArity") (EVar "mctx")) (EVar "iface")) (EVar "n"))) (DoLet false false (PVar "implPats") (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "users")) (EApp (EApp (EApp (EVar "dictParamsFrom") (EVar "n")) (EVar "k")) (EVar "nReq")) (EListLit))) (DoExpr (EIf (EBinOp "&&" (EBinOp "==" (EVar "k") (ELit (LInt 0))) (EApp (EVar "isEmptyL") (EVar "implPats"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "n")) (EVar "pats")) (EVar "body")) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "n")) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "dictParams") (EVar "n")) (EVar "k")) (EVar "implPats")) (EVar "pats"))) (EVar "body"))))))
(DTypeSig false "usesImplDict" (TyFun (TyCon "PassEvidence") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Expr") (TyCon "Bool")))))))
(DFunDef false "usesImplDict" ((PVar "pe") (PVar "mname") (PVar "methodArity") (PVar "nReq") (PVar "body")) (EApp (EApp (EVar "anyMember") (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "body"))) (EApp (EApp (EApp (EVar "implDictNames") (EVar "mname")) (EVar "methodArity")) (EVar "nReq"))))
(DTypeSig false "implDictNames" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "implDictNames" ((PVar "mname") (PVar "methodArity") (PVar "nReq")) (EApp (EApp (EVar "map") (EApp (EVar "dictParamName") (EVar "mname"))) (EApp (EApp (EVar "range") (EVar "methodArity")) (EBinOp "+" (EVar "methodArity") (EVar "nReq")))))
(DTypeSig false "implMethodDictArity" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "String") (TyCon "Int")))))
(DFunDef false "implMethodDictArity" ((PVar "mctx") (PVar "iface") (PVar "method")) (EApp (EApp (EApp (EVar "methodDictArityAtOrigin") (EVar "mctx")) (EFieldAccess (EVar "iface") "irOrigin")) (EApp (EApp (EVar "methodSlotKey") (EVar "iface")) (EVar "method"))))
(DTypeSig false "methodDictArityAtOrigin" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyCon "Int")))))
(DFunDef false "methodDictArityAtOrigin" ((PVar "mctx") (PCon "OriginModule" (PVar "mid")) (PVar "key")) (EMatch (EApp (EApp (EApp (EVar "lookupQualPayload") (EVar "mid")) (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "crossRun") "crossModuleMethodPredicateSlotsQualRef") "value")) (arm (PCon "Some" (PVar "slots")) () (EApp (EVar "listLen") (EVar "slots"))) (arm (PCon "None") () (EApp (EApp (EVar "methodDictArityOf") (EVar "mctx")) (EVar "key")))))
(DFunDef false "methodDictArityAtOrigin" ((PVar "mctx") PWild (PVar "key")) (EApp (EApp (EVar "methodDictArityOf") (EVar "mctx")) (EVar "key")))
(DTypeSig false "siteRDictName" (TyFun (TyCon "Route") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "siteRDictName" ((PCon "RDict" (PVar "d"))) (EListLit (EVar "d")))
(DFunDef false "siteRDictName" ((PCon "RDictFwd" (PVar "d"))) (EListLit (EVar "d")))
(DFunDef false "siteRDictName" ((PCon "RProj" (PVar "inner") PWild)) (EApp (EVar "routeRDictName") (EVar "inner")))
(DFunDef false "siteRDictName" (PWild) (EListLit))
(DTypeSig false "siteRDictNamesL" (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "siteRDictNamesL" ((PVar "rs")) (EApp (EApp (EVar "flatMap") (EVar "routeRDictName")) (EVar "rs")))
(DTypeSig false "routeRDictName" (TyFun (TyCon "Route") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "routeRDictName" ((PCon "RDict" (PVar "d"))) (EListLit (EVar "d")))
(DFunDef false "routeRDictName" ((PCon "RDictFwd" (PVar "d"))) (EListLit (EVar "d")))
(DFunDef false "routeRDictName" ((PCon "RKey" PWild (PVar "reqs") (PVar "sups"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "routeRDictName")) (EVar "reqs")) (EApp (EApp (EVar "flatMap") (EVar "routeRDictName")) (EVar "sups"))))
(DFunDef false "routeRDictName" ((PCon "RProj" (PVar "r") PWild)) (EApp (EVar "routeRDictName") (EVar "r")))
(DFunDef false "routeRDictName" (PWild) (EListLit))
(DTypeSig false "collectDictSites" (TyFun (TyCon "PassEvidence") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "EDictAt" PWild (PVar "ev"))) (EApp (EVar "siteRDictNamesL") (EApp (EApp (EVar "evDictRoutesIn") (EApp (EVar "passIndex") (EVar "pe"))) (EVar "ev"))))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "EMethodAt" PWild PWild (PVar "ev"))) (EBlock (DoLet false false (PCon "PassMethod" PWild (PVar "tag") (PVar "dicts")) (EApp (EApp (EVar "passMethodOf") (EVar "pe")) (EVar "ev"))) (DoExpr (EBinOp "++" (EApp (EVar "siteRDictName") (EVar "tag")) (EApp (EVar "siteRDictNamesL") (EVar "dicts"))))))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "ELoc" PWild (PVar "e"))) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "EApp" (PVar "f") (PVar "x"))) (EBinOp "++" (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "f")) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "x"))))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "ELam" PWild (PVar "b"))) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "b")))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "ELet" PWild PWild PWild (PVar "e1") (PVar "e2"))) (EBinOp "++" (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e1")) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e2"))))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EVar "letBindDictSites") (EVar "pe"))) (EVar "binds")) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "body"))))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "EMatch" (PVar "e") (PVar "arms"))) (EBinOp "++" (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")) (EApp (EApp (EVar "flatMap") (EApp (EVar "armDictSites") (EVar "pe"))) (EVar "arms"))))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "EIf" (PVar "c") (PVar "t") (PVar "e"))) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "c")) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "t"))) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e"))))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "EBinOp" PWild (PVar "l") (PVar "r") PWild)) (EBinOp "++" (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "l")) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "r"))))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "EUnOp" PWild (PVar "e") PWild)) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "EInfix" PWild (PVar "l") (PVar "r"))) (EBinOp "++" (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "l")) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "r"))))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "EFieldAccess" (PVar "e") PWild PWild)) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "ETuple" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "collectDictSites") (EVar "pe"))) (EVar "es")))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "EListLit" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "collectDictSites") (EVar "pe"))) (EVar "es")))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "collectDictSites") (EVar "pe"))) (EVar "es")))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "ERangeList" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "a")) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "b"))))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "ERangeArray" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "a")) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "b"))))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "ESlice" (PVar "e") (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "a"))) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "b"))))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "EIndex" (PVar "e") (PVar "i"))) (EBinOp "++" (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "i"))))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "EAnnot" (PVar "e") PWild)) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "doStmtDictSites") (EVar "pe"))) (EVar "stmts")))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "ERecordCreate" PWild (PVar "fs"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "fieldAssignDictSites") (EVar "pe"))) (EVar "fs")))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "ERecordUpdate" (PVar "e") (PVar "fs") PWild)) (EBinOp "++" (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")) (EApp (EApp (EVar "flatMap") (EApp (EVar "fieldAssignDictSites") (EVar "pe"))) (EVar "fs"))))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "EVariantUpdate" PWild (PVar "e") (PVar "fs"))) (EBinOp "++" (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")) (EApp (EApp (EVar "flatMap") (EApp (EVar "fieldAssignDictSites") (EVar "pe"))) (EVar "fs"))))
(DFunDef false "collectDictSites" (PWild PWild) (EListLit))
(DTypeSig false "letBindDictSites" (TyFun (TyCon "PassEvidence") (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "letBindDictSites" ((PVar "pe") (PCon "LetBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EVar "flatMap") (EApp (EVar "funClauseDictSites") (EVar "pe"))) (EVar "clauses")))
(DTypeSig false "funClauseDictSites" (TyFun (TyCon "PassEvidence") (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "funClauseDictSites" ((PVar "pe") (PCon "FunClause" PWild (PVar "body"))) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "body")))
(DTypeSig false "armDictSites" (TyFun (TyCon "PassEvidence") (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "armDictSites" ((PVar "pe") (PCon "Arm" PWild (PVar "guards") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EVar "guardDictSites") (EVar "pe"))) (EVar "guards")) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "body"))))
(DTypeSig false "guardDictSites" (TyFun (TyCon "PassEvidence") (TyFun (TyCon "Guard") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "guardDictSites" ((PVar "pe") (PCon "GBool" (PVar "e"))) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")))
(DFunDef false "guardDictSites" ((PVar "pe") (PCon "GBind" PWild (PVar "e"))) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")))
(DTypeSig false "doStmtDictSites" (TyFun (TyCon "PassEvidence") (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "doStmtDictSites" ((PVar "pe") (PCon "DoExpr" (PVar "e"))) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")))
(DFunDef false "doStmtDictSites" ((PVar "pe") (PCon "DoLet" PWild PWild PWild (PVar "e") PWild)) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")))
(DFunDef false "doStmtDictSites" ((PVar "pe") (PCon "DoBind" PWild (PVar "e"))) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")))
(DFunDef false "doStmtDictSites" ((PVar "pe") (PCon "DoAssign" PWild (PVar "e"))) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")))
(DFunDef false "doStmtDictSites" ((PVar "pe") (PCon "DoFieldAssign" PWild PWild (PVar "e"))) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")))
(DTypeSig false "fieldAssignDictSites" (TyFun (TyCon "PassEvidence") (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "fieldAssignDictSites" ((PVar "pe") (PCon "FieldAssign" PWild (PVar "e"))) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")))
(DTypeSig false "dictArityOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "dictArityOf" ((PVar "mctx") (PVar "n")) (EApp (EVar "listLen") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "lookupPredicateSlots") (EVar "n")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funPredicateSlotsIdxRef") "value")))))
(DTypeSig false "dictParams" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Pat")))))
(DFunDef false "dictParams" ((PVar "n") (PVar "k")) (EApp (EApp (EApp (EVar "dictParamsGo") (EVar "n")) (ELit (LInt 0))) (EVar "k")))
(DTypeSig false "dictParamsGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Pat"))))))
(DFunDef false "dictParamsGo" ((PVar "n") (PVar "slot") (PVar "k")) (EIf (EBinOp ">=" (EVar "slot") (EVar "k")) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EApp (EVar "PVar") (EApp (EApp (EVar "dictParamName") (EVar "n")) (EVar "slot"))) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (EVar "noBinderId")) (EApp (EApp (EApp (EVar "dictParamsGo") (EVar "n")) (EBinOp "+" (EVar "slot") (ELit (LInt 1)))) (EVar "k"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dictParamsFrom" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Pat"))))))
(DFunDef false "dictParamsFrom" ((PVar "n") (PVar "start") (PVar "count")) (EIf (EBinOp "<=" (EVar "count") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EApp (EVar "PVar") (EApp (EApp (EVar "dictParamName") (EVar "n")) (EVar "start"))) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (EVar "noBinderId")) (EApp (EApp (EApp (EVar "dictParamsFrom") (EVar "n")) (EBinOp "+" (EVar "start") (ELit (LInt 1)))) (EBinOp "-" (EVar "count") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "dictPassModulesIfEnabled" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))))))
(DFunDef false "dictPassModulesIfEnabled" ((PVar "mctx") (PVar "dictNames") (PVar "corePassed") (PVar "core2") (PVar "modules2")) (EBlock (DoLet false false (PVar "idx") (EApp (EVar "evIndexOf") (EApp (EApp (EVar "drivenEvidence") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit)))) (DoLet false false (PVar "promotedQ") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "crossRun") "crossModuleFunPredicateSlotsQualRef") "value")) (DoLet false false (PVar "allMods") (EApp (EApp (EVar "namesToSet") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "modules2"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "setFunPredicateSlots") (EVar "mctx")) (EApp (EApp (EApp (EVar "scopePredicateSlots") (EListLit)) (EVar "omEmpty")) (EVar "core2")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funConstraintDeclaredRef")) (EListLit))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodPredicateSlotsRef")) (EApp (EApp (EVar "scopeMethodPredicateSlots") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "crossRun") "crossModuleMethodPredicateSlotsQualRef") "value")) (EVar "allMods")))) (DoLet false false (PVar "core2'") (EIf (EVar "corePassed") (EVar "core2") (EApp (EApp (EApp (EApp (EApp (EVar "dictPass") (EVar "mctx")) (EVar "idx")) (ELit (LString ""))) (EApp (EVar "constrainedSigNames") (EVar "core2"))) (EVar "core2")))) (DoLet false false (PVar "importerReach") (EApp (EVar "importerReachIndex") (EVar "modules2"))) (DoLet false false (PVar "modules2'") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "dictPassModulesScoped") (EVar "mctx")) (EVar "idx")) (EVar "dictNames")) (EVar "promotedQ")) (EVar "importerReach")) (EVar "core2")) (EVar "modules2")) (EVar "modules2"))) (DoLet false false (PVar "r") (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "r") "evTable")) (EApp (EApp (EApp (EVar "servedEntriesFrom") (EVar "idx")) (EFieldAccess (EVar "r") "evBase")) (EFieldAccess (EFieldAccess (EVar "r") "evTable") "value")))) (DoExpr (ETuple (EVar "core2'") (EVar "modules2'")))))
(DTypeSig false "dictPassModulesScoped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "EvIndex") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "PredicateSlot")))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))))))))
(DFunDef false "dictPassModulesScoped" ((PVar "_mctx") PWild PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "dictPassModulesScoped" ((PVar "mctx") (PVar "idx") (PVar "dictNames") (PVar "promotedQ") (PVar "importerReach") (PVar "core2") (PVar "allModules") (PCons (PTuple (PVar "mid") (PVar "prog")) (PVar "rest"))) (EBlock (DoLet false false (PVar "importers") (EApp (EApp (EApp (EVar "transitiveImporters") (EVar "importerReach")) (EVar "mid")) (EVar "allModules"))) (DoLet false false (PVar "importerDecls") (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "importers"))) (DoLet false false (PVar "scope") (EBinOp "++" (EBinOp "++" (EVar "core2") (EVar "prog")) (EVar "importerDecls"))) (DoLet false false (PVar "scopeMods") (EApp (EApp (EVar "namesToSet") (EBinOp "::" (EVar "mid") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "importers")))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "setFunPredicateSlots") (EVar "mctx")) (EApp (EApp (EApp (EApp (EVar "selfDeclArities") (EVar "mid")) (EVar "prog")) (EVar "promotedQ")) (EBinOp "++" (EApp (EApp (EApp (EVar "aliasConstraintEntries") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "prog")) (EVar "promotedQ")) (EApp (EApp (EApp (EVar "scopePredicateSlots") (EVar "promotedQ")) (EVar "scopeMods")) (EVar "scope")))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funConstraintDeclaredRef")) (EListLit))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodPredicateSlotsRef")) (EApp (EApp (EVar "scopeMethodPredicateSlots") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "crossRun") "crossModuleMethodPredicateSlotsQualRef") "value")) (EVar "scopeMods")))) (DoExpr (EBinOp "::" (ETuple (EVar "mid") (EApp (EApp (EApp (EApp (EApp (EVar "dictPass") (EVar "mctx")) (EVar "idx")) (EVar "mid")) (EVar "dictNames")) (EVar "prog"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "dictPassModulesScoped") (EVar "mctx")) (EVar "idx")) (EVar "dictNames")) (EVar "promotedQ")) (EVar "importerReach")) (EVar "core2")) (EVar "allModules")) (EVar "rest"))))))
(DTypeSig false "scopePredicateSlots" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "PredicateSlot")))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "PredicateSlot"))))))))
(DFunDef false "scopePredicateSlots" ((PVar "promotedQ") (PVar "scopeMods") (PVar "scope")) (EBlock (DoLet false false (PVar "scopeNames") (EApp (EApp (EVar "namesToSet") (EApp (EVar "declTopFnNames") (EVar "scope"))) (EVar "omEmpty"))) (DoLet false false (PVar "nameInScope") (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "snd") (EApp (EVar "fst") (EVar "e")))) (EVar "scopeNames")))) (EVar "promotedQ"))) (DoLet false false (PVar "resolvedNames") (EApp (EApp (EVar "namesToSet") (EApp (EApp (EVar "map") (ELam ((PVar "e")) (EApp (EVar "snd") (EApp (EVar "fst") (EVar "e"))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EApp (EVar "modInScope") (EApp (EVar "fst") (EApp (EVar "fst") (EVar "e")))) (EVar "scopeMods")))) (EVar "nameInScope")))) (EVar "omEmpty"))) (DoLet false false (PVar "inferredQ") (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EBinOp "||" (EApp (EApp (EVar "modInScope") (EApp (EVar "fst") (EApp (EVar "fst") (EVar "e")))) (EVar "scopeMods")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EApp (EVar "snd") (EApp (EVar "fst") (EVar "e")))) (EVar "resolvedNames")))))) (EVar "nameInScope"))) (DoLet false false (PVar "inferred") (EApp (EApp (EVar "map") (ELam ((PVar "e")) (ETuple (EApp (EVar "snd") (EApp (EVar "fst") (EVar "e"))) (EApp (EVar "snd") (EVar "e"))))) (EVar "inferredQ"))) (DoLet false false (PVar "inferredNames") (EApp (EApp (EVar "namesToSet") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "inferred"))) (EVar "omEmpty"))) (DoLet false false (PVar "sigEntries") (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EVar "e"))) (EVar "inferredNames"))))) (EApp (EApp (EVar "flatMap") (EVar "constrainedSigPredicateSlots")) (EVar "scope")))) (DoExpr (EBinOp "++" (EVar "inferred") (EVar "sigEntries")))))
(DTypeSig true "selfDeclArities" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))))))
(DFunDef false "selfDeclArities" ((PVar "mid") (PVar "prog") (PVar "qual") (PVar "bare")) (EIf (EBinOp "==" (EVar "mid") (ELit (LString ""))) (EVar "bare") (EBlock (DoLet false false (PVar "own") (EApp (EApp (EVar "namesToSet") (EApp (EVar "declTopFnNames") (EVar "prog"))) (EVar "omEmpty"))) (DoExpr (EBinOp "++" (EApp (EApp (EApp (EVar "selfQualEntries") (EVar "mid")) (EVar "own")) (EVar "qual")) (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EVar "e"))) (EVar "own"))))) (EVar "bare")))))))
(DTypeSig false "selfQualEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyVar "a"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a")))))))
(DFunDef false "selfQualEntries" ((PVar "mid") (PVar "own") (PVar "qual")) (EApp (EApp (EVar "map") (ELam ((PVar "e")) (ETuple (EApp (EVar "snd") (EApp (EVar "fst") (EVar "e"))) (EApp (EVar "snd") (EVar "e"))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "fst") (EApp (EVar "fst") (EVar "e"))) (EVar "mid")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "snd") (EApp (EVar "fst") (EVar "e")))) (EVar "own"))))) (EVar "qual"))))
(DTypeSig false "scopeMethodPredicateSlots" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")))))))
(DFunDef false "scopeMethodPredicateSlots" ((PVar "promotedMQ") (PVar "scopeMods")) (EBlock (DoLet false false (PVar "resolvedNames") (EApp (EApp (EVar "namesToSet") (EApp (EApp (EVar "map") (ELam ((PVar "e")) (EApp (EVar "snd") (EApp (EVar "fst") (EVar "e"))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EApp (EVar "modInScope") (EApp (EVar "fst") (EApp (EVar "fst") (EVar "e")))) (EVar "scopeMods")))) (EVar "promotedMQ")))) (EVar "omEmpty"))) (DoLet false false (PVar "kept") (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EBinOp "||" (EApp (EApp (EVar "modInScope") (EApp (EVar "fst") (EApp (EVar "fst") (EVar "e")))) (EVar "scopeMods")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EApp (EVar "snd") (EApp (EVar "fst") (EVar "e")))) (EVar "resolvedNames")))))) (EVar "promotedMQ"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "e")) (ETuple (EApp (EVar "snd") (EApp (EVar "fst") (EVar "e"))) (EApp (EVar "snd") (EVar "e"))))) (EVar "kept")))))
(DTypeSig false "modInScope" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyCon "Bool"))))
(DFunDef false "modInScope" ((PVar "mid") (PVar "scopeMods")) (EBinOp "||" (EBinOp "==" (EVar "mid") (ELit (LString ""))) (EApp (EApp (EVar "omHasKey") (EVar "mid")) (EVar "scopeMods"))))
(DTypeSig false "transitiveImporters" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))
(DFunDef false "transitiveImporters" ((PVar "reach") (PVar "mid") (PVar "modules")) (EApp (EApp (EVar "filterList") (ELam ((PVar "p")) (EBinOp "&&" (EBinOp "/=" (EApp (EVar "fst") (EVar "p")) (EVar "mid")) (EApp (EApp (EVar "omHasKey") (EVar "mid")) (EApp (EApp (EVar "optionOr") (EVar "omEmpty")) (EApp (EApp (EVar "omLookup") (EApp (EVar "fst") (EVar "p"))) (EVar "reach"))))))) (EVar "modules")))
(DTypeSig false "constrainedSigPredicateSlots" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "PredicateSlot"))))))
(DFunDef false "constrainedSigPredicateSlots" ((PCon "DTypeSig" PWild (PVar "n") (PVar "ty") PWild)) (EIf (EApp (EVar "isConstrainedTy") (EVar "ty")) (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "map") (EVar "sigPredicateSlot")) (EApp (EVar "sigConstraints") (EVar "ty"))))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "constrainedSigPredicateSlots" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "constrainedSigPredicateSlots") (EVar "d")))
(DFunDef false "constrainedSigPredicateSlots" (PWild) (EListLit))
(DTypeSig false "sigPredicateSlot" (TyFun (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "PredicateSlot")))
(DFunDef false "sigPredicateSlot" ((PTuple (PVar "iface") PWild)) (ERecordCreate "PredicateSlot" ((fa "psIface" (EVar "iface")) (fa "psArgs" (EVar "PSArgsUnknown")) (fa "psBoundIds" (EListLit)))))
# MARK
(DUse false (UseGroup ("types" "tc_types") ((mem "AdmittedAnswer" true) (mem "BuiltinClass" true) (mem "EntailKind" true) (mem "GrantBinder" true) (mem "MethodGrantUse" true) (mem "MethodReturnTraceStage" true) (mem "PendingDictApp" true) (mem "PredicateSlot" true) (mem "PredicateSlotArgs" true) (mem "SiteCtx" true) (mem "SiteKind" true) (mem "GrantOcc" false) (mem "GrantState" false) (mem "grantTopKey" false) (mem "GraphCtx" false) (mem "LocalAbs" false) (mem "MethodGrant" false) (mem "MethodPredicateSlot" false) (mem "MethodReturnRequest" false) (mem "ModuleCtx" false) (mem "PassEvidence" false) (mem "PassMethod" false) (mem "PendingEntry" false) (mem "PendingMethodDict" false) (mem "RecDictApp" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "anyMember" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "dictParamName" false) (mem "interners" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "builtinClassName" false) (mem "builtinClassOrigin" false) (mem "declTopFnNames" false) (mem "importerReachIndex" false) (mem "methodLevelConstraintVarNames" false) (mem "methodSlotKey" false) (mem "namesToSet" false))))
(DUse false (UseGroup ("types" "tc_scope") ((mem "aliasConstraintEntries" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "lookupQualPayload" false))))
(DUse false (UseGroup ("types" "tc_decls") ((mem "methodDictArityOf" false))))
(DUse false (UseGroup ("types" "tc_solve_givens") ((mem "lookupPredicateSlots" false))))
(DUse false (UseGroup ("types" "tc_solve_entail") ((mem "entail" false) (mem "implDictRoutesForRow" false) (mem "rowRouteKey" false) (mem "selectedCallSupers" false))))
(DUse false (UseGroup ("types" "tc_solve") ((mem "admittedSelection" false) (mem "exactReturnRoutes" false) (mem "isLocalAbsName" false) (mem "methodPredicateRoutes" false) (mem "methodReturnAmbiguousWithoutGiven" false) (mem "methodReturnArgs" false) (mem "methodReturnResolutionValid" false) (mem "noteMethodReturnTrace" false) (mem "numericReturnRoute" false) (mem "recRoutes" false) (mem "returnPosMethodNames" false) (mem "routesOfMonosTopV" false) (mem "solveExactReturnOnce" false))))
(DUse false (UseGroup ("types" "tc_solve_check") ((mem "setFunPredicateSlots" false))))
(DUse false (UseGroup ("types" "tc_shadow") ((mem "methodCellOf" false))))
(DUse false (UseGroup ("types" "tc_effects") ((mem "evOrdinal" false) (mem "fileBodyLoc" false) (mem "fileBoundSite" false) (mem "fileValueKey" false) (mem "grantOccOf" false) (mem "hasFileBoundValue" false) (mem "methodGrantOf" false) (mem "narrowFileAtom" false))))
(DUse false (UseGroup ("types" "tc_occurrence") ((mem "arithDispatchMethod" false) (mem "binopMethod" false) (mem "constrainedSigNames" false) (mem "isGrantOnlyEv" false) (mem "mintMethodCellRaw" false) (mem "unopMethod" false))))
(DUse false (UseGroup ("types" "tc_groups") ((mem "sigConstraints" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "Decl" true) (mem "DoStmt" true) (mem "EvId" true) (mem "EvVal" true) (mem "Expr" true) (mem "FieldAssign" true) (mem "FunClause" true) (mem "Guard" true) (mem "IfaceMethod" true) (mem "ImplMethod" true) (mem "LetBind" true) (mem "Lit" true) (mem "Loc" true) (mem "MethodDefault" true) (mem "Pat" true) (mem "Route" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "EvTable" false) (mem "isI32Head" false) (mem "isI64Head" false) (mem "isU64Head" false) (mem "noBinderId" false) (mem "noDeclLoc" false) (mem "taggedFixedRange" false) (mem "tyConBuiltin" false) (mem "unminted" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" true) (mem "GrantShape" true) (mem "authGrantShape" false) (mem "authvarId" false))))
(DUse false (UseGroup ("types" "solver_contract") ((mem "ClassPredicate" true))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffRow" true) (mem "atomAuth" false) (mem "atomLabel" false) (mem "rowFlat" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "evDictRoutesIn" false) (mem "evidenceLookup" false) (mem "EvIndex" false) (mem "evIndexOf" false) (mem "evSiteLitIn" false) (mem "evSiteRouteIn" false) (mem "ifaceWordOf" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Mono" true) (mem "normalize" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("types" "evidence") ((mem "ScopeId" true))))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("types" "runtime_ops") ((mem "arithmeticTag" false))))
(DUse false (UseGroup ("types" "module_interface") ((mem "cellEntriesFrom" false) (mem "servedEntriesFrom" false) (mem "setServedArity" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "dedup" false) (mem "filterList" false) (mem "int64Halves" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "isSome" false) (mem "listLen" false) (mem "splitOnChar" false))))
(DUse false (UseGroup ("list") ((mem "drop" false) (mem "elemIndex" false) (mem "range" false) (mem "replicate" false) (mem "reverse" false) (mem "take" false))))
(DUse false (UseGroup ("types" "runtime_grants") ((mem "fileGrantExterns" false))))
(DUse false (UseGroup ("types" "chain_key") ((mem "isConstrainedTy" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "mapChildren" false) (mem "mapProg" false))))
(DUse false (UseAlias ("map") "IdMap"))
(DTypeSig false "mintMethodCellWith" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Route") (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyCon "EvId"))))))))
(DFunDef false "mintMethodCellWith" ((PVar "mctx") (PCon "PassEvidence" PWild (PVar "minted")) (PVar "iface") (PVar "arity") (PVar "tag") (PVar "impls")) (EBlock (DoLet false false (PVar "ev") (EApp (EApp (EApp (EApp (EApp (EVar "mintMethodCellRaw") (EVar "mctx")) (EVar "iface")) (EApp (EVar "Some") (EVar "arity"))) (EVar "tag")) (EVar "impls"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "minted")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "intToString") (EApp (EVar "evOrdinal") (EVar "ev")))) (EApp (EApp (EApp (EApp (EApp (EVar "EvMethod") (EVar "iface")) (EVar "arity")) (EVar "tag")) (EVar "impls")) (EListLit))) (EFieldAccess (EVar "minted") "value")))) (DoExpr (EVar "ev"))))
(DTypeSig true "drivenEvidence" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyCon "EvTable"))))
(DFunDef false "drivenEvidence" ((PVar "gctx") PWild) (EBinOp "++" (EApp (EApp (EVar "cellEntriesFrom") (EFieldAccess (EVar "gctx") "graphRun")) (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "evBase")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "evTable") "value")))
(DTypeSig false "localAbsFor" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "LocalAbs")))))
(DFunDef false "localAbsFor" ((PVar "gctx") (PVar "name")) (EApp (EApp (EVar "optionOr") (EVar "None")) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "localAbs") "lasBinders") "value"))))
(DTypeSig false "rewriteLocalDictExpr" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "rewriteLocalDictExpr" ((PVar "gctx") (PCon "EDictAt" (PVar "n") (PVar "ev"))) (EIf (EApp (EVar "isLocalAbsName") (EVar "n")) (EMatch (EApp (EApp (EVar "localAbsFor") (EVar "gctx")) (EVar "n")) (arm (PCon "Some" PWild) () (EApp (EApp (EVar "EDictAt") (EVar "n")) (EVar "ev"))) (arm (PCon "None") () (EApp (EVar "EVar") (EVar "n")))) (EIf (EVar "otherwise") (EApp (EApp (EVar "EDictAt") (EVar "n")) (EVar "ev")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "rewriteLocalDictExpr" ((PVar "gctx") (PCon "ELet" (PVar "m") (PVar "r") (PCon "PVar" (PVar "x") (PVar "xloc") (PVar "bid")) (PVar "e1") (PVar "e2"))) (EMatch (EApp (EApp (EVar "localAbsFor") (EVar "gctx")) (EVar "x")) (arm (PCon "Some" (PVar "la")) () (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "r")) (EApp (EApp (EApp (EVar "PVar") (EVar "x")) (EVar "xloc")) (EVar "bid"))) (EApp (EApp (EVar "prependLocalDicts") (EFieldAccess (EVar "la") "laParams")) (EVar "e1"))) (EVar "e2"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "r")) (EApp (EApp (EApp (EVar "PVar") (EVar "x")) (EVar "xloc")) (EVar "bid"))) (EVar "e1")) (EVar "e2")))))
(DFunDef false "rewriteLocalDictExpr" ((PVar "gctx") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteLocalLetBind") (EVar "gctx"))) (EVar "binds"))) (EVar "body")))
(DFunDef false "rewriteLocalDictExpr" ((PVar "gctx") (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteLocalDoStmt") (EVar "gctx"))) (EVar "stmts"))))
(DFunDef false "rewriteLocalDictExpr" ((PVar "_gctx") (PVar "e")) (EVar "e"))
(DTypeSig false "rewriteLocalLetBind" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "LetBind") (TyCon "LetBind"))))
(DFunDef false "rewriteLocalLetBind" ((PVar "gctx") (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EMatch (EApp (EApp (EVar "localAbsFor") (EVar "gctx")) (EVar "n")) (arm (PCon "Some" (PVar "la")) () (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "prependLocalDictClause") (EFieldAccess (EVar "la") "laParams"))) (EVar "clauses"))) (EVar "site")) (EVar "bid"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EVar "clauses")) (EVar "site")) (EVar "bid")))))
(DTypeSig false "prependLocalDictClause" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "FunClause") (TyCon "FunClause"))))
(DFunDef false "prependLocalDictClause" ((PVar "params") (PCon "FunClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "localDictPat")) (EVar "params")) (EVar "pats"))) (EVar "body")))
(DTypeSig false "rewriteLocalDoStmt" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "DoStmt") (TyCon "DoStmt"))))
(DFunDef false "rewriteLocalDoStmt" ((PVar "gctx") (PCon "DoLet" (PVar "m") (PVar "r") (PCon "PVar" (PVar "x") (PVar "xloc") (PVar "bid")) (PVar "e") (PVar "site"))) (EMatch (EApp (EApp (EVar "localAbsFor") (EVar "gctx")) (EVar "x")) (arm (PCon "Some" (PVar "la")) () (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EApp (EApp (EApp (EVar "PVar") (EVar "x")) (EVar "xloc")) (EVar "bid"))) (EApp (EApp (EVar "prependLocalDicts") (EFieldAccess (EVar "la") "laParams")) (EVar "e"))) (EVar "site"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EApp (EApp (EApp (EVar "PVar") (EVar "x")) (EVar "xloc")) (EVar "bid"))) (EVar "e")) (EVar "site")))))
(DFunDef false "rewriteLocalDoStmt" ((PVar "_gctx") (PVar "stmt")) (EVar "stmt"))
(DTypeSig false "prependLocalDicts" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "prependLocalDicts" ((PVar "params") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EApp (EVar "prependLocalDicts") (EVar "params")) (EVar "e"))))
(DFunDef false "prependLocalDicts" ((PVar "params") (PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "ELam") (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "localDictPat")) (EVar "params")) (EVar "pats"))) (EVar "body")))
(DFunDef false "prependLocalDicts" ((PVar "params") (PVar "e")) (EApp (EApp (EVar "ELam") (EApp (EApp (EMethodRef "map") (EVar "localDictPat")) (EVar "params"))) (EVar "e")))
(DTypeSig false "localDictPat" (TyFun (TyCon "String") (TyCon "Pat")))
(DFunDef false "localDictPat" ((PVar "n")) (EApp (EApp (EApp (EVar "PVar") (EVar "n")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (EVar "noBinderId")))
(DTypeSig true "grantWholeDomain" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "grantWholeDomain" ((PVar "prog")) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapDeclBodies") (EApp (EVar "wholeDomainExpr") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "interners") "value") "lineage") "lnGrants")))) (EVar "prog")))
(DTypeSig false "wholeDomainExpr" (TyFun (TyCon "GrantState") (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "wholeDomainExpr" ((PVar "st") (PAs "e" (PCon "EApp" PWild PWild))) (EMatch (EApp (EApp (EVar "grantSpine") (EVar "e")) (EListLit)) (arm (PTuple (PCon "EVar" (PVar "n")) (PVar "args")) () (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "fileGrantExterns")) (arm (PCon "Some" (PTuple (PVar "arity") (PVar "paths"))) () (EApp (EApp (EApp (EApp (EApp (EVar "saturateGrants") (EVar "st")) (EApp (EVar "EVar") (EVar "n"))) (EVar "arity")) (EApp (EApp (EVar "replicate") (EVar "paths")) (EApp (EVar "EListLit") (EListLit)))) (EApp (EApp (EMethodRef "map") (EApp (EVar "wholeDomainExpr") (EVar "st"))) (EVar "args")))) (arm (PCon "None") () (EApp (EApp (EVar "mapChildren") (EApp (EVar "wholeDomainExpr") (EVar "st"))) (EVar "e"))))) (arm PWild () (EApp (EApp (EVar "mapChildren") (EApp (EVar "wholeDomainExpr") (EVar "st"))) (EVar "e")))))
(DFunDef false "wholeDomainExpr" ((PVar "st") (PCon "EVar" (PVar "n"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "fileGrantExterns")) (arm (PCon "Some" (PTuple (PVar "arity") (PVar "paths"))) () (EApp (EApp (EApp (EApp (EApp (EVar "saturateGrants") (EVar "st")) (EApp (EVar "EVar") (EVar "n"))) (EVar "arity")) (EApp (EApp (EVar "replicate") (EVar "paths")) (EApp (EVar "EListLit") (EListLit)))) (EListLit))) (arm (PCon "None") () (EApp (EVar "EVar") (EVar "n")))))
(DFunDef false "wholeDomainExpr" ((PVar "st") (PVar "e")) (EApp (EApp (EVar "mapChildren") (EApp (EVar "wholeDomainExpr") (EVar "st"))) (EVar "e")))
(DTypeSig false "mapDeclBodies" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "mapDeclBodies" ((PVar "f") (PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "ps") (PVar "e") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "n")) (EVar "ps")) (EApp (EVar "f") (EVar "e"))) (EVar "site")) (EVar "bid")))
(DFunDef false "mapDeclBodies" ((PVar "f") (PCon "DLetGroup" (PVar "pub") (PVar "binds"))) (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "b")) (EMatch (EVar "b") (arm (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid")) () (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "c")) (EMatch (EVar "c") (arm (PCon "FunClause" (PVar "ps") (PVar "e")) () (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EVar "f") (EVar "e"))))))) (EVar "clauses"))) (EVar "site")) (EVar "bid")))))) (EVar "binds"))))
(DFunDef false "mapDeclBodies" ((PVar "f") (PAs "d" (PRec "DInterface" ((rf "methods" None)) true))) (EVariantUpdate "DInterface" (EVar "d") ((fa "methods" (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EMatch (EVar "m") (arm (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PVar "def") (PVar "mloc")) () (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "dm")) (EMatch (EVar "dm") (arm (PCon "MethodDefault" (PVar "ps") (PVar "e")) () (EApp (EApp (EVar "MethodDefault") (EVar "ps")) (EApp (EVar "f") (EVar "e"))))))) (EVar "def"))) (EVar "mloc")))))) (EVar "methods"))))))
(DFunDef false "mapDeclBodies" ((PVar "f") (PAs "d" (PRec "DImpl" ((rf "methods" None)) true))) (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EMatch (EVar "m") (arm (PCon "ImplMethod" (PVar "n") (PVar "ps") (PVar "e")) () (EApp (EApp (EApp (EVar "ImplMethod") (EVar "n")) (EVar "ps")) (EApp (EVar "f") (EVar "e"))))))) (EVar "methods"))))))
(DFunDef false "mapDeclBodies" ((PVar "f") (PCon "DProp" (PVar "pub") (PVar "name") (PVar "params") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DProp") (EVar "pub")) (EVar "name")) (EVar "params")) (EApp (EVar "f") (EVar "body"))))
(DFunDef false "mapDeclBodies" ((PVar "f") (PCon "DTest" (PVar "pub") (PVar "name") (PVar "body"))) (EApp (EApp (EApp (EVar "DTest") (EVar "pub")) (EVar "name")) (EApp (EVar "f") (EVar "body"))))
(DFunDef false "mapDeclBodies" ((PVar "f") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EVar "mapDeclBodies") (EVar "f")) (EVar "d"))))
(DFunDef false "mapDeclBodies" (PWild (PVar "d")) (EVar "d"))
(DTypeSig false "isSourceless" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "isSourceless" ((PVar "gctx") (PVar "i")) (EApp (EApp (EVar "IdMap.has") (EVar "i")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants") "gsSourceless") "value")))
(DTypeSig false "builtinMethodIfaceWord" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "builtinMethodIfaceWord" ((PVar "gctx") (PVar "method")) (EMatch (EApp (EVar "builtinClassOfMethod") (EVar "method")) (arm (PCon "Some" (PVar "c")) () (EApp (EApp (EVar "ifaceWordOf") (EApp (EApp (EVar "builtinClassOrigin") (EVar "gctx")) (EVar "c"))) (EApp (EVar "builtinClassName") (EVar "c")))) (arm (PCon "None") () (ELit (LString "")))))
(DTypeSig false "builtinClassOfMethod" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "BuiltinClass"))))
(DFunDef false "builtinClassOfMethod" ((PLit (LString "eq"))) (EApp (EVar "Some") (EVar "BEq")))
(DFunDef false "builtinClassOfMethod" ((PLit (LString "append"))) (EApp (EVar "Some") (EVar "BSemigroup")))
(DFunDef false "builtinClassOfMethod" ((PVar "m")) (EIf (EApp (EApp (EVar "contains") (EVar "m")) (EListLit (ELit (LString "compare")) (ELit (LString "lt")) (ELit (LString "gt")) (ELit (LString "lte")) (ELit (LString "gte")))) (EApp (EVar "Some") (EVar "BOrd")) (EIf (EApp (EApp (EVar "contains") (EVar "m")) (EListLit (ELit (LString "add")) (ELit (LString "sub")) (ELit (LString "mul")) (ELit (LString "div")) (ELit (LString "rem")) (ELit (LString "negate")) (ELit (LString "fromInt")))) (EApp (EVar "Some") (EVar "BNum")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "resolveArgStamps" (TyFun (TyCon "SiteCtx") (TyFun (TyApp (TyCon "List") (TyCon "PendingEntry")) (TyCon "Unit"))))
(DFunDef false "resolveArgStamps" ((PVar "_sx") (PList)) (ELit LUnit))
(DFunDef false "resolveArgStamps" ((PVar "sx") (PCons (PCon "PendingEntry" (PVar "name") (PVar "tagRef") (PVar "am") (PVar "encl") (PVar "kind") (PVar "loc") (PVar "scope") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "sx") (ERecordUpdate (EVar "sx") ((fa "sxSite" (EVar "loc"))))) (DoExpr (EMatch (EVar "kind") (arm (PCon "SKArg" (PVar "implRef") (PVar "fullMono") (PVar "omitted")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveArgStamp") (EVar "sx")) (EVar "name")) (EVar "tagRef")) (EVar "implRef")) (EVar "am")) (EVar "fullMono")) (EVar "omitted")) (EVar "encl")) (EVar "loc")) (EVar "scope"))) (arm PWild () (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "resolveArgStamps") (EVar "sx")) (EVar "rest")))))
(DTypeSig false "resolveArgStamp" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ScopeId") (TyCon "Unit"))))))))))))
(DFunDef false "resolveArgStamp" ((PVar "sx") (PVar "name") (PVar "tagRef") (PVar "implRef") (PVar "am") (PVar "fullMono") (PVar "omitted") (PVar "encl") (PVar "_origin") (PVar "scope")) (EBlock (DoLet false false (PTuple (PVar "route") (PVar "routes")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "entail") (EVar "sx")) (EVar "name")) (EVar "am")) (EVar "encl")) (EVar "scope")) (EApp (EApp (EVar "EKArg") (EVar "fullMono")) (EVar "omitted")))) (DoExpr (EMatch (EVar "route") (arm (PCon "RNone") () (ELit LUnit)) (arm PWild () (EApp (EApp (EVar "setRef") (EVar "tagRef")) (EVar "route"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "implRef")) (EVar "routes")))))
(DTypeSig true "resolveSite" (TyFun (TyCon "SiteCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ScopeId") (TyCon "Unit"))))))))))))
(DFunDef false "resolveSite" ((PVar "sx") (PVar "rpNames") (PVar "name") (PVar "tagRef") (PVar "implRef") (PVar "resultMono") (PVar "fullMono") (PVar "encl") (PVar "_origin") (PVar "scope")) (EBlock (DoLet false false (PTuple (PVar "route") (PVar "routes")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "entail") (EVar "sx")) (EVar "name")) (EVar "resultMono")) (EVar "encl")) (EVar "scope")) (EApp (EApp (EVar "EKReturn") (EVar "fullMono")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "rpNames"))))) (DoExpr (EMatch (EVar "route") (arm (PCon "RNone") () (ELit LUnit)) (arm PWild () (EApp (EApp (EVar "setRef") (EVar "tagRef")) (EVar "route"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "implRef")) (EVar "routes")))))
(DTypeSig true "resolveAdmittedSite" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "String")) (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyCon "Unit"))))))))))
(DFunDef false "resolveAdmittedSite" ((PVar "sx") (PVar "name") (PVar "ifaceRef") (PVar "tagRef") (PVar "implRef") (PVar "fullMono") (PVar "encl") (PVar "scope")) (EMatch (EApp (EApp (EApp (EApp (EVar "admittedSelection") (EVar "sx")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "bodyImplEnvRef") "value")) (EVar "name")) (EVar "fullMono")) (arm (PCon "Selects" (PVar "iface") (PVar "row") (PVar "goals")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "ifaceRef")) (EApp (EApp (EVar "ifaceWordOf") (EFieldAccess (EVar "iface") "irOrigin")) (EFieldAccess (EVar "iface") "irName")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "tagRef")) (EApp (EApp (EApp (EVar "RKey") (EApp (EVar "rowRouteKey") (EVar "row"))) (EListLit)) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "selectedCallSupers") (EVar "sx")) (EVar "name")) (EApp (EVar "Some") (EVar "row"))) (EVar "encl")) (EVar "scope")) (EVar "goals"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "implRef")) (EApp (EApp (EApp (EApp (EApp (EVar "implDictRoutesForRow") (EVar "sx")) (EVar "encl")) (EVar "scope")) (EVar "goals")) (EVar "row")))))) (arm PWild () (ELit LUnit))))
(DTypeSig true "resolveExactReturnSite" (TyFun (TyCon "SiteCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyFun (TyCon "Mono") (TyFun (TyCon "MethodReturnRequest") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ScopeId") (TyCon "Unit"))))))))))))
(DFunDef false "resolveExactReturnSite" ((PVar "sx") (PVar "rpNames") (PVar "name") (PVar "tagRef") (PVar "implRef") (PVar "resultMono") (PVar "request") (PVar "encl") (PVar "origin") (PVar "scope")) (EIf (EApp (EApp (EVar "methodReturnAmbiguousWithoutGiven") (EFieldAccess (EVar "sx") "sxModule")) (EVar "request")) (EApp (EApp (EApp (EApp (EApp (EVar "noteMethodReturnTrace") (EFieldAccess (EVar "sx") "sxModule")) (EVar "MRTStamped")) (EVar "request")) (EVar "None")) (EListLit)) (EMatch (EApp (EApp (EVar "methodReturnArgs") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "request")) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "noteMethodReturnTrace") (EFieldAccess (EVar "sx") "sxModule")) (EVar "MRTStamped")) (EVar "request")) (EVar "None")) (EListLit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveSite") (EVar "sx")) (EVar "rpNames")) (EVar "name")) (EVar "tagRef")) (EVar "implRef")) (EVar "resultMono")) (EFieldAccess (EVar "request") "mrrOccurrence")) (EVar "encl")) (EVar "origin")) (EVar "scope"))))) (arm (PCon "Some" PWild) () (EBlock (DoLet false false (PVar "resolution") (EApp (EApp (EVar "solveExactReturnOnce") (EVar "sx")) (EVar "request"))) (DoExpr (EIf (EApp (EApp (EApp (EVar "methodReturnResolutionValid") (EFieldAccess (EVar "sx") "sxModule")) (EVar "request")) (EVar "resolution")) (ELit LUnit) (EApp (EVar "panic") (ELit (LString "ordinary return route received invalid solver evidence"))))) (DoLet false false (PTuple (PVar "route") (PVar "routes")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "exactReturnRoutes") (EVar "sx")) (EVar "name")) (EVar "encl")) (EVar "scope")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "rpNames"))) (EVar "resolution"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "noteMethodReturnTrace") (EFieldAccess (EVar "sx") "sxModule")) (EVar "MRTStamped")) (EVar "request")) (EApp (EVar "Some") (EVar "route"))) (EVar "routes"))) (DoExpr (EMatch (EVar "route") (arm (PCon "RNone") () (ELit LUnit)) (arm PWild () (EApp (EApp (EVar "setRef") (EVar "tagRef")) (EVar "route"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "implRef")) (EVar "routes"))))))))
(DTypeSig true "resolveNumLitSite" (TyFun (TyCon "SiteCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyFun (TyCon "ClassPredicate") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ScopeId") (TyCon "Unit"))))))))))))
(DFunDef false "resolveNumLitSite" ((PVar "sx") (PVar "rpNames") (PVar "name") (PVar "tagRef") (PVar "resultMono") (PVar "fullMono") (PVar "predicate") (PVar "encl") (PVar "origin") (PVar "scope")) (EBlock (DoLet false false (PTuple (PVar "route") (PVar "routes")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "entail") (EVar "sx")) (EVar "name")) (EVar "resultMono")) (EVar "encl")) (EVar "scope")) (EApp (EApp (EApp (EApp (EVar "EKNumReturn") (EVar "predicate")) (EVar "fullMono")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "rpNames"))) (EVar "origin")))) (DoExpr (EMatch (EVar "route") (arm (PCon "RNone") () (ELit LUnit)) (arm PWild () (EApp (EApp (EVar "setRef") (EVar "tagRef")) (EApp (EApp (EVar "numericReturnRoute") (EVar "route")) (EVar "routes")))))) (DoExpr (ELit LUnit))))
(DTypeSig true "resolveArithSite" (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyCon "Mono") (TyCon "Unit"))))
(DFunDef false "resolveArithSite" ((PVar "dref") (PVar "m")) (EMatch (EUnOp "!" (EVar "dref")) (arm (PCon "RNone") () (EMatch (EApp (EVar "arithmeticTag") (EVar "m")) (arm (PCon "Some" (PVar "tag")) () (EApp (EApp (EVar "setRef") (EVar "dref")) (EApp (EVar "RScalar") (EVar "tag")))) (arm (PCon "None") () (ELit LUnit)))) (arm PWild () (ELit LUnit))))
(DTypeSig true "resolveOpSite" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyCon "Mono") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyCon "Unit"))))))))))
(DFunDef false "resolveOpSite" ((PVar "sx") (PVar "isBinop") (PVar "method") (PVar "tagRef") (PVar "operandMono") (PVar "inImpl") (PVar "encl") (PVar "scope")) (EMatch (EApp (EVar "fst") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "entail") (EVar "sx")) (EVar "method")) (EVar "operandMono")) (EVar "encl")) (EVar "scope")) (EApp (EApp (EVar "EKOp") (EVar "isBinop")) (EVar "inImpl")))) (arm (PCon "RNone") () (ELit LUnit)) (arm (PVar "route") () (EApp (EApp (EVar "setRef") (EVar "tagRef")) (EVar "route")))))
(DTypeSig true "resolvePredicateOpSite" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyCon "Mono") (TyFun (TyCon "Bool") (TyFun (TyCon "ClassPredicate") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyCon "Unit")))))))))))
(DFunDef false "resolvePredicateOpSite" ((PVar "sx") (PVar "isBinop") (PVar "method") (PVar "tagRef") (PVar "operandMono") (PVar "inImpl") (PVar "predicate") (PVar "encl") (PVar "scope")) (EMatch (EApp (EVar "fst") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "entail") (EVar "sx")) (EVar "method")) (EVar "operandMono")) (EVar "encl")) (EVar "scope")) (EApp (EApp (EApp (EVar "EKPredicateOp") (EVar "isBinop")) (EVar "inImpl")) (EVar "predicate")))) (arm (PCon "RNone") () (ELit LUnit)) (arm (PVar "route") () (EApp (EApp (EVar "setRef") (EVar "tagRef")) (EVar "route")))))
(DTypeSig true "resolveMethodDicts" (TyFun (TyCon "SiteCtx") (TyFun (TyApp (TyCon "List") (TyCon "PendingMethodDict")) (TyCon "Unit"))))
(DFunDef false "resolveMethodDicts" ((PVar "_sx") (PList)) (ELit LUnit))
(DFunDef false "resolveMethodDicts" ((PVar "sx") (PCons (PVar "pending") (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "pending") "pmdRoutesRef")) (EApp (EApp (EApp (EApp (EVar "methodPredicateRoutes") (EVar "sx")) (EFieldAccess (EVar "pending") "pmdEncl")) (EFieldAccess (EVar "pending") "pmdScope")) (EFieldAccess (EVar "pending") "pmdSlots")))) (DoExpr (EApp (EApp (EVar "resolveMethodDicts") (EVar "sx")) (EVar "rest")))))
(DTypeSig true "resolveDictApps" (TyFun (TyCon "SiteCtx") (TyFun (TyApp (TyCon "List") (TyCon "PendingDictApp")) (TyCon "Unit"))))
(DFunDef false "resolveDictApps" ((PVar "_sx") (PList)) (ELit LUnit))
(DFunDef false "resolveDictApps" ((PVar "sx") (PCons (PVar "app") (PVar "rest"))) (EBlock (DoLet false false (PVar "sx") (ERecordUpdate (EVar "sx") ((fa "sxSite" (EFieldAccess (EVar "app") "pdaLoc"))))) (DoLet false false (PVar "routes") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routesOfMonosTopV") (EVar "sx")) (EFieldAccess (EVar "app") "pdaEncl")) (EFieldAccess (EVar "app") "pdaScope")) (EFieldAccess (EVar "app") "pdaMonos")) (EFieldAccess (EVar "app") "pdaIfaces")) (EFieldAccess (EVar "app") "pdaArgVecs"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "app") "pdaRoutesRef")) (EVar "routes"))) (DoExpr (EApp (EApp (EVar "resolveDictApps") (EVar "sx")) (EVar "rest")))))
(DTypeSig true "realizeRecDictApps" (TyFun (TyCon "SiteCtx") (TyFun (TyApp (TyCon "List") (TyCon "RecDictApp")) (TyCon "Unit"))))
(DFunDef false "realizeRecDictApps" ((PVar "_sx") (PList)) (ELit LUnit))
(DFunDef false "realizeRecDictApps" ((PVar "sx") (PCons (PCon "RecDictApp" (PVar "routesRef") (PVar "callee") (PVar "encl") (PVar "mono") (PVar "scope") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "slots") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "lookupPredicateSlots") (EVar "callee")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "funPredicateSlotsIdxRef") "value")))) (DoLet false false (PVar "routes") (EApp (EApp (EApp (EApp (EApp (EVar "recRoutes") (EVar "sx")) (EVar "encl")) (EVar "scope")) (EVar "mono")) (EVar "slots"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "routesRef")) (EVar "routes"))) (DoExpr (EApp (EApp (EVar "realizeRecDictApps") (EVar "sx")) (EVar "rest")))))
(DTypeSig false "dictPass" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "EvIndex") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))))))
(DFunDef false "dictPass" ((PVar "mctx") (PVar "idx") (PVar "mid") (PVar "names") (PVar "prog")) (EBlock (DoLet false false (PVar "pe") (EApp (EApp (EVar "PassEvidence") (EVar "idx")) (EApp (EVar "Ref") (EVar "omEmpty")))) (DoExpr (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EVar "dictPassDecl") (EVar "mctx")) (EVar "pe")) (EApp (EApp (EVar "omFromNames") (EVar "names")) (EVar "omEmpty"))) (EApp (EVar "returnPosMethodNames") (EVar "prog")))) (EApp (EApp (EVar "mapProg") (ELam ((PVar "e")) (EApp (EApp (EVar "rewriteLocalDictExpr") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EApp (EVar "rewriteBinopExpr") (EVar "mctx")) (EVar "pe")) (EVar "e"))))) (EApp (EApp (EApp (EApp (EVar "grantPass") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "pe")) (EVar "mid")) (EVar "prog")))))))
(DTypeSig false "passIndex" (TyFun (TyCon "PassEvidence") (TyCon "EvIndex")))
(DFunDef false "passIndex" ((PCon "PassEvidence" (PVar "idx") PWild)) (EVar "idx"))
(DTypeSig false "passMethodOf" (TyFun (TyCon "PassEvidence") (TyFun (TyCon "EvId") (TyCon "PassMethod"))))
(DFunDef false "passMethodOf" ((PCon "PassEvidence" (PVar "idx") (PVar "minted")) (PVar "ev")) (EMatch (EApp (EApp (EApp (EVar "evidenceLookup") (EApp (EVar "Some") (EVar "idx"))) (ELit (LString "method occurrence"))) (EVar "ev")) (arm (PCon "Ok" (PVar "v")) () (EApp (EVar "passMethodFacts") (EVar "v"))) (arm (PCon "Err" (PVar "message")) () (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "intToString") (EApp (EVar "evOrdinal") (EVar "ev")))) (EFieldAccess (EVar "minted") "value")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "passMethodFacts") (EVar "v"))) (arm (PCon "None") () (EApp (EVar "panic") (EVar "message")))))))
(DTypeSig false "passMethodFacts" (TyFun (TyCon "EvVal") (TyCon "PassMethod")))
(DFunDef false "passMethodFacts" ((PCon "EvMethod" (PVar "iface") PWild (PVar "tag") (PVar "impls") (PVar "meths"))) (EApp (EApp (EApp (EVar "PassMethod") (EVar "iface")) (EVar "tag")) (EBinOp "++" (EVar "impls") (EVar "meths"))))
(DFunDef false "passMethodFacts" (PWild) (EApp (EVar "panic") (ELit (LString "evidence table: a method occurrence answered by another kind of entry"))))
(DTypeSig false "grantPass" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "grantPass" ((PVar "gctx") (PVar "pe") (PVar "mid") (PVar "prog")) (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (DoLet false false (PVar "saved") (EFieldAccess (EFieldAccess (EVar "st") "gsPassingModule") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsPassingModule")) (EVar "mid"))) (DoLet false false (PVar "result") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "grantDecl") (EVar "gctx")) (EVar "pe")) (EVar "mid"))) (EVar "prog"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsPassingModule")) (EVar "saved"))) (DoExpr (EVar "result"))))
(DTypeSig false "grantDecl" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyCon "Decl"))))))
(DFunDef false "grantDecl" ((PVar "gctx") (PVar "pe") (PVar "mid") (PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "pats") (PVar "body") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "n")) (EBinOp "++" (EApp (EApp (EVar "grantParamPats") (EApp (EApp (EApp (EVar "topGrantIds") (EVar "gctx")) (EVar "mid")) (EVar "n"))) (EVar "n")) (EVar "pats"))) (EApp (EApp (EApp (EVar "grantBody") (EVar "gctx")) (EVar "pe")) (EVar "body"))) (EVar "site")) (EVar "bid")))
(DFunDef false "grantDecl" ((PVar "gctx") (PVar "pe") (PVar "mid") (PCon "DLetGroup" (PVar "pub") (PVar "binds"))) (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "b")) (EMatch (EVar "b") (arm (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid")) () (EApp (EApp (EApp (EApp (EVar "grantLetBind") (EVar "gctx")) (EVar "pe")) (EApp (EApp (EVar "grantParamPats") (EApp (EApp (EApp (EVar "topGrantIds") (EVar "gctx")) (EVar "mid")) (EVar "n"))) (EVar "n"))) (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EVar "clauses")) (EVar "site")) (EVar "bid"))))))) (EVar "binds"))))
(DFunDef false "grantDecl" ((PVar "gctx") (PVar "pe") PWild (PAs "d" (PRec "DInterface" ((rf "name" None) (rf "ifaceOrigin" None) (rf "methods" None)) true))) (EVariantUpdate "DInterface" (EVar "d") ((fa "methods" (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "grantIfaceMethod") (EVar "gctx")) (EVar "pe")) (EApp (EApp (EVar "ifaceWordOf") (EVar "ifaceOrigin")) (EVar "name")))) (EVar "methods"))))))
(DFunDef false "grantDecl" ((PVar "gctx") (PVar "pe") PWild (PAs "d" (PRec "DImpl" ((rf "iface" None) (rf "implOrigin" None) (rf "methods" None)) true))) (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "grantImplMethod") (EVar "gctx")) (EVar "pe")) (EApp (EApp (EVar "ifaceWordOf") (EVar "implOrigin")) (EVar "iface")))) (EVar "methods"))))))
(DFunDef false "grantDecl" ((PVar "gctx") (PVar "pe") PWild (PCon "DProp" (PVar "pub") (PVar "name") (PVar "params") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DProp") (EVar "pub")) (EVar "name")) (EVar "params")) (EApp (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe")) (EVar "body"))))
(DFunDef false "grantDecl" ((PVar "gctx") (PVar "pe") PWild (PCon "DTest" (PVar "pub") (PVar "name") (PVar "body"))) (EApp (EApp (EApp (EVar "DTest") (EVar "pub")) (EVar "name")) (EApp (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe")) (EVar "body"))))
(DFunDef false "grantDecl" ((PVar "gctx") (PVar "pe") (PVar "mid") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EApp (EApp (EVar "grantDecl") (EVar "gctx")) (EVar "pe")) (EVar "mid")) (EVar "d"))))
(DFunDef false "grantDecl" ((PVar "_gctx") PWild PWild (PVar "d")) (EVar "d"))
(DTypeSig false "grantIfaceMethod" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyCon "String") (TyFun (TyCon "IfaceMethod") (TyCon "IfaceMethod"))))))
(DFunDef false "grantIfaceMethod" ((PVar "gctx") (PVar "pe") (PVar "word") (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PVar "def") (PVar "mloc"))) (EMatch (EApp (EApp (EApp (EVar "methodGrantOf") (EVar "gctx")) (EVar "word")) (EVar "n")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PCon "MethodDefault" (PVar "ps") (PVar "e")) () (EApp (EApp (EVar "MethodDefault") (EVar "ps")) (EApp (EApp (EApp (EVar "grantBody") (EVar "gctx")) (EVar "pe")) (EVar "e"))))))) (EVar "def"))) (EVar "mloc"))) (arm (PCon "Some" (PVar "mg")) () (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EApp (EApp (EApp (EVar "insertGrantArrows") (EFieldAccess (EVar "mg") "mgArity")) (EApp (EVar "listLen") (EFieldAccess (EVar "mg") "mgNames"))) (EVar "ty"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PCon "MethodDefault" (PVar "ps") (PVar "e")) () (EBlock (DoLet false false (PTuple (PVar "ps2") (PVar "e2")) (EApp (EApp (EApp (EApp (EApp (EVar "grantMethodParams") (EVar "gctx")) (EVar "mg")) (EVar "n")) (EVar "ps")) (EApp (EApp (EApp (EVar "grantBody") (EVar "gctx")) (EVar "pe")) (EVar "e")))) (DoExpr (EApp (EApp (EVar "MethodDefault") (EVar "ps2")) (EVar "e2")))))))) (EVar "def"))) (EVar "mloc")))))
(DTypeSig false "grantImplMethod" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyCon "String") (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod"))))))
(DFunDef false "grantImplMethod" ((PVar "gctx") (PVar "pe") (PVar "word") (PCon "ImplMethod" (PVar "n") (PVar "ps") (PVar "e"))) (EMatch (EApp (EApp (EApp (EVar "methodGrantOf") (EVar "gctx")) (EVar "word")) (EVar "n")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "ImplMethod") (EVar "n")) (EVar "ps")) (EApp (EApp (EApp (EVar "grantBody") (EVar "gctx")) (EVar "pe")) (EVar "e")))) (arm (PCon "Some" (PVar "mg")) () (EBlock (DoLet false false (PTuple (PVar "ps2") (PVar "e2")) (EApp (EApp (EApp (EApp (EApp (EVar "grantMethodParams") (EVar "gctx")) (EVar "mg")) (EVar "n")) (EVar "ps")) (EApp (EApp (EApp (EVar "grantBody") (EVar "gctx")) (EVar "pe")) (EVar "e")))) (DoExpr (EApp (EApp (EApp (EVar "ImplMethod") (EVar "n")) (EVar "ps2")) (EVar "e2")))))))
(DTypeSig false "grantMethodParams" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "MethodGrant") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))))
(DFunDef false "grantMethodParams" ((PVar "gctx") (PVar "mg") (PVar "n") (PVar "ps") (PVar "body")) (EBlock (DoLet false false (PVar "grants") (EApp (EApp (EVar "grantParamPats") (EFieldAccess (EVar "mg") "mgNames")) (EVar "n"))) (DoLet false false (PVar "given") (EApp (EVar "listLen") (EVar "ps"))) (DoExpr (EIf (EBinOp ">=" (EVar "given") (EFieldAccess (EVar "mg") "mgArity")) (ETuple (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "take") (EFieldAccess (EVar "mg") "mgArity")) (EVar "ps")) (EVar "grants")) (EApp (EApp (EVar "drop") (EFieldAccess (EVar "mg") "mgArity")) (EVar "ps"))) (EVar "body")) (EBlock (DoLet false false (PVar "missing") (EApp (EApp (EMethodRef "map") (ELam (PWild) (EApp (EApp (EVar "freshGrantName") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (ELit LUnit)))) (EApp (EApp (EVar "range") (EVar "given")) (EFieldAccess (EVar "mg") "mgArity")))) (DoExpr (ETuple (EBinOp "++" (EBinOp "++" (EVar "ps") (EApp (EApp (EMethodRef "map") (ELam ((PVar "x")) (EApp (EApp (EApp (EVar "PVar") (EVar "x")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (EVar "noBinderId")))) (EVar "missing"))) (EVar "grants")) (EApp (EApp (EVar "applyExprs") (EVar "body")) (EApp (EApp (EMethodRef "map") (EVar "EVar")) (EVar "missing"))))))))))
(DTypeSig false "insertGrantArrows" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Ty") (TyCon "Ty")))))
(DFunDef false "insertGrantArrows" ((PVar "k") (PVar "g") (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EApp (EApp (EVar "TyConstrained") (EVar "cs")) (EApp (EApp (EApp (EVar "insertGrantArrows") (EVar "k")) (EVar "g")) (EVar "t"))))
(DFunDef false "insertGrantArrows" ((PVar "k") (PVar "g") (PCon "TyEffect" (PVar "effs") (PVar "tails") (PVar "t"))) (EIf (EBinOp ">" (EVar "k") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "TyEffect") (EVar "effs")) (EVar "tails")) (EApp (EApp (EApp (EVar "insertGrantArrows") (EVar "k")) (EVar "g")) (EVar "t"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "insertGrantArrows" ((PVar "k") (PVar "g") (PCon "TyFun" (PVar "a") (PVar "b"))) (EIf (EBinOp ">" (EVar "k") (ELit (LInt 0))) (EApp (EApp (EVar "TyFun") (EVar "a")) (EApp (EApp (EApp (EVar "insertGrantArrows") (EBinOp "-" (EVar "k") (ELit (LInt 1)))) (EVar "g")) (EVar "b"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "insertGrantArrows" (PWild (PVar "g") (PVar "t")) (EApp (EApp (EVar "grantArrows") (EVar "g")) (EVar "t")))
(DTypeSig false "grantArrows" (TyFun (TyCon "Int") (TyFun (TyCon "Ty") (TyCon "Ty"))))
(DFunDef false "grantArrows" ((PVar "g") (PVar "t")) (EIf (EBinOp "<=" (EVar "g") (ELit (LInt 0))) (EVar "t") (EIf (EVar "otherwise") (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "TyApp") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "List"))) (EVar "None"))) (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "String"))) (EVar "None")))) (EApp (EApp (EVar "grantArrows") (EBinOp "-" (EVar "g") (ELit (LInt 1)))) (EVar "t"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "grantLetBind" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "LetBind") (TyCon "LetBind"))))))
(DFunDef false "grantLetBind" ((PVar "gctx") (PVar "pe") (PVar "params") (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "c")) (EMatch (EVar "c") (arm (PCon "FunClause" (PVar "ps") (PVar "body")) () (EApp (EApp (EVar "FunClause") (EBinOp "++" (EVar "params") (EVar "ps"))) (EApp (EApp (EApp (EVar "grantBody") (EVar "gctx")) (EVar "pe")) (EVar "body"))))))) (EVar "clauses"))) (EVar "site")) (EVar "bid")))
(DTypeSig false "topGrantIds" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "topGrantIds" ((PVar "gctx") (PVar "mid") (PVar "n")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EApp (EApp (EVar "grantTopKey") (EVar "mid")) (EVar "n"))) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants") "gsTopIds") "value"))))
(DTypeSig false "localGrantIds" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "localGrantIds" ((PVar "gctx") (PVar "n")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants") "gsLocalIds") "value"))))
(DTypeSig false "grantParamName" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "grantParamName" ((PVar "n") (PVar "i")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "$auth_")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "_"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ""))))
(DTypeSig false "grantParamPats" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")))))
(DFunDef false "grantParamPats" ((PVar "ids") (PVar "n")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "i")) (EApp (EApp (EApp (EVar "PVar") (EApp (EApp (EVar "grantParamName") (EVar "n")) (EVar "i"))) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (EVar "noBinderId")))) (EApp (EApp (EVar "range") (ELit (LInt 0))) (EApp (EVar "listLen") (EVar "ids")))))
(DTypeSig false "grantExpr" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "grantExpr" ((PVar "gctx") (PVar "pe") (PVar "e")) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EApp (EVar "grantExprInner") (EVar "gctx")) (EVar "pe")) (EVar "e"))) (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (DoExpr (EMatch (EFieldAccess (EFieldAccess (EVar "st") "gsValueBounds") "value") (arm (PCon "Tip") () (EVar "inner")) (arm PWild () (EMatch (EApp (EApp (EVar "fileValueKey") (EFieldAccess (EFieldAccess (EVar "st") "gsPassingModule") "value")) (EVar "e")) (arm (PCon "Some" (PVar "key")) () (EBlock (DoLet false false (PVar "bounds") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EFieldAccess (EVar "st") "gsValueBounds") "value")))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "result") (PTuple (PVar "ty") (PVar "chain"))) (EApp (EApp (EApp (EApp (EVar "fileBoundValue") (EVar "gctx")) (EVar "chain")) (EVar "ty")) (EVar "result")))) (EVar "inner")) (EVar "bounds"))))) (arm (PCon "None") () (EVar "inner"))))))))
(DTypeSig false "grantExprInner" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "grantExprInner" ((PVar "gctx") (PVar "pe") (PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "ELam") (EVar "pats")) (EApp (EApp (EApp (EVar "grantBody") (EVar "gctx")) (EVar "pe")) (EVar "body"))))
(DFunDef false "grantExprInner" ((PVar "gctx") (PVar "pe") (PAs "e" (PCon "EApp" PWild PWild))) (EMatch (EApp (EApp (EVar "grantSpine") (EVar "e")) (EListLit)) (arm (PTuple (PCon "EDictAt" (PVar "n") (PVar "ev")) (PVar "args")) () (EMatch (EApp (EApp (EVar "grantOccOf") (EVar "gctx")) (EVar "ev")) (arm (PCon "Some" (PVar "occ")) () (EMatch (EFieldAccess (EVar "occ") "goTrailing") (arm (PCon "Some" (PVar "arity")) () (EApp (EApp (EApp (EApp (EApp (EVar "saturateGrants") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (EApp (EVar "EVar") (EVar "n"))) (EVar "arity")) (EApp (EApp (EVar "grantTerms") (EVar "gctx")) (EVar "occ"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe"))) (EVar "args")))) (arm (PCon "None") () (EApp (EApp (EVar "mapChildren") (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe"))) (EVar "e"))))) (arm (PCon "None") () (EApp (EApp (EVar "mapChildren") (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe"))) (EVar "e"))))) (arm (PTuple (PCon "EMethodAt" (PVar "n") (PVar "seed") (PVar "ev")) (PVar "args")) () (EMatch (EApp (EApp (EApp (EApp (EVar "methodGrantUse") (EVar "gctx")) (EVar "pe")) (EVar "n")) (EVar "ev")) (arm (PCon "MethodGrants" (PVar "arity") (PVar "grants")) () (EApp (EApp (EApp (EApp (EApp (EVar "saturateGrants") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (EApp (EApp (EApp (EVar "EMethodAt") (EVar "n")) (EVar "seed")) (EVar "ev"))) (EVar "arity")) (EVar "grants")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe"))) (EVar "args")))) (arm (PCon "LeadingGrants" PWild (PVar "grants")) () (EApp (EApp (EVar "applyExprs") (EApp (EApp (EVar "applyExprs") (EApp (EApp (EApp (EVar "EMethodAt") (EVar "n")) (EVar "seed")) (EVar "ev"))) (EVar "grants"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe"))) (EVar "args")))) (arm (PCon "NoGrants") () (EApp (EApp (EVar "mapChildren") (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe"))) (EVar "e"))))) (arm PWild () (EApp (EApp (EVar "mapChildren") (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe"))) (EVar "e")))))
(DFunDef false "grantExprInner" ((PVar "gctx") PWild (PCon "EDictAt" (PVar "n") (PVar "ev"))) (EApp (EApp (EApp (EVar "grantUse") (EVar "gctx")) (EVar "n")) (EVar "ev")))
(DFunDef false "grantExprInner" ((PVar "gctx") (PVar "pe") (PCon "EMethodAt" (PVar "n") (PVar "seed") (PVar "ev"))) (EMatch (EApp (EApp (EApp (EApp (EVar "methodGrantUse") (EVar "gctx")) (EVar "pe")) (EVar "n")) (EVar "ev")) (arm (PCon "MethodGrants" (PVar "arity") (PVar "grants")) () (EApp (EApp (EApp (EApp (EApp (EVar "saturateGrants") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (EApp (EApp (EApp (EVar "EMethodAt") (EVar "n")) (EVar "seed")) (EVar "ev"))) (EVar "arity")) (EVar "grants")) (EListLit))) (arm (PCon "LeadingGrants" PWild (PVar "grants")) () (EApp (EApp (EVar "applyExprs") (EApp (EApp (EApp (EVar "EMethodAt") (EVar "n")) (EVar "seed")) (EVar "ev"))) (EVar "grants"))) (arm (PCon "NoGrants") () (EApp (EApp (EApp (EVar "EMethodAt") (EVar "n")) (EVar "seed")) (EVar "ev")))))
(DFunDef false "grantExprInner" ((PVar "gctx") (PVar "pe") (PCon "ELet" (PVar "m") (PVar "r") (PCon "PVar" (PVar "x") (PVar "xloc") (PVar "bid")) (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "r")) (EApp (EApp (EApp (EVar "PVar") (EVar "x")) (EVar "xloc")) (EVar "bid"))) (EApp (EApp (EApp (EVar "grantLocalRhs") (EVar "gctx")) (EVar "x")) (EApp (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe")) (EVar "e1")))) (EApp (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe")) (EVar "e2"))))
(DFunDef false "grantExprInner" ((PVar "gctx") (PVar "pe") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EMethodRef "map") (ELam ((PVar "b")) (EMatch (EVar "b") (arm (PCon "LetBind" (PVar "x") (PVar "clauses") (PVar "site") (PVar "bid")) () (EApp (EApp (EApp (EApp (EVar "grantLetBind") (EVar "gctx")) (EVar "pe")) (EApp (EApp (EVar "grantParamPats") (EApp (EApp (EVar "localGrantIds") (EVar "gctx")) (EVar "x"))) (EVar "x"))) (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "x")) (EVar "clauses")) (EVar "site")) (EVar "bid"))))))) (EVar "binds"))) (EApp (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe")) (EVar "body"))))
(DFunDef false "grantExprInner" ((PVar "gctx") (PVar "pe") (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "grantStmt") (EVar "gctx")) (EVar "pe"))) (EVar "stmts"))))
(DFunDef false "grantExprInner" ((PVar "gctx") (PVar "pe") (PVar "e")) (EApp (EApp (EVar "mapChildren") (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe"))) (EVar "e")))
(DTypeSig false "grantStmt" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyCon "DoStmt") (TyCon "DoStmt")))))
(DFunDef false "grantStmt" ((PVar "gctx") (PVar "pe") (PCon "DoLet" (PVar "m") (PVar "r") (PCon "PVar" (PVar "x") (PVar "xloc") (PVar "bid")) (PVar "e") (PVar "site"))) (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EApp (EApp (EApp (EVar "PVar") (EVar "x")) (EVar "xloc")) (EVar "bid"))) (EApp (EApp (EApp (EVar "grantLocalRhs") (EVar "gctx")) (EVar "x")) (EApp (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe")) (EVar "e")))) (EVar "site")))
(DFunDef false "grantStmt" ((PVar "gctx") (PVar "pe") (PCon "DoExpr" (PVar "e"))) (EApp (EVar "DoExpr") (EApp (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe")) (EVar "e"))))
(DFunDef false "grantStmt" ((PVar "gctx") (PVar "pe") (PCon "DoBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "DoBind") (EVar "p")) (EApp (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe")) (EVar "e"))))
(DFunDef false "grantStmt" ((PVar "gctx") (PVar "pe") (PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e") (PVar "site"))) (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p")) (EApp (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe")) (EVar "e"))) (EVar "site")))
(DFunDef false "grantStmt" ((PVar "gctx") (PVar "pe") (PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe")) (EVar "e"))))
(DFunDef false "grantStmt" ((PVar "gctx") (PVar "pe") (PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e"))) (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe")) (EVar "e"))))
(DTypeSig false "grantLocalRhs" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "grantLocalRhs" ((PVar "gctx") (PVar "x") (PVar "e")) (EMatch (EApp (EApp (EVar "localGrantIds") (EVar "gctx")) (EVar "x")) (arm (PList) () (EVar "e")) (arm (PVar "ids") () (EApp (EApp (EVar "prependLocalDicts") (EApp (EApp (EMethodRef "map") (ELam ((PVar "i")) (EApp (EApp (EVar "grantParamName") (EVar "x")) (EVar "i")))) (EApp (EApp (EVar "range") (ELit (LInt 0))) (EApp (EVar "listLen") (EVar "ids"))))) (EVar "e")))))
(DTypeSig false "grantSpine" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))))
(DFunDef false "grantSpine" ((PCon "EApp" (PVar "f") (PVar "x")) (PVar "args")) (EApp (EApp (EVar "grantSpine") (EVar "f")) (EBinOp "::" (EVar "x") (EVar "args"))))
(DFunDef false "grantSpine" ((PCon "ELoc" PWild (PVar "e")) (PVar "args")) (EApp (EApp (EVar "grantSpine") (EVar "e")) (EVar "args")))
(DFunDef false "grantSpine" ((PVar "e") (PVar "args")) (ETuple (EVar "e") (EVar "args")))
(DTypeSig false "grantUse" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "Expr")))))
(DFunDef false "grantUse" ((PVar "gctx") (PVar "n") (PVar "ev")) (EBlock (DoLet false false (PVar "head") (EIf (EApp (EApp (EVar "isGrantOnlyEv") (EVar "gctx")) (EVar "ev")) (EApp (EVar "EVar") (EVar "n")) (EApp (EApp (EVar "EDictAt") (EVar "n")) (EVar "ev")))) (DoExpr (EMatch (EApp (EApp (EVar "grantOccOf") (EVar "gctx")) (EVar "ev")) (arm (PCon "None") () (EVar "head")) (arm (PCon "Some" (PVar "occ")) () (EMatch (EFieldAccess (EVar "occ") "goTrailing") (arm (PCon "Some" (PVar "arity")) () (EApp (EApp (EApp (EApp (EApp (EVar "saturateGrants") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (EApp (EVar "EVar") (EVar "n"))) (EVar "arity")) (EApp (EApp (EVar "grantTerms") (EVar "gctx")) (EVar "occ"))) (EListLit))) (arm (PCon "None") () (EApp (EApp (EVar "applyExprs") (EVar "head")) (EApp (EApp (EVar "grantTerms") (EVar "gctx")) (EVar "occ"))))))))))
(DTypeSig false "methodGrantUse" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "MethodGrantUse"))))))
(DFunDef false "methodGrantUse" ((PVar "gctx") (PVar "pe") (PVar "n") (PVar "ev")) (EBlock (DoLet false false (PCon "PassMethod" (PVar "iface") (PVar "tag") PWild) (EApp (EApp (EVar "passMethodOf") (EVar "pe")) (EVar "ev"))) (DoLet false false (PVar "recorded") (EApp (EApp (EVar "grantOccOf") (EVar "gctx")) (EVar "ev"))) (DoLet false false (PVar "use") (EMatch (EVar "tag") (arm (PCon "RLocal" (PVar "sym") PWild) () (EMatch (EApp (EVar "standaloneOcc") (EVar "recorded")) (arm (PCon "Some" (PTuple (PVar "arity") (PVar "occ"))) () (EApp (EApp (EVar "LeadingGrants") (EVar "arity")) (EApp (EApp (EVar "grantTerms") (EVar "gctx")) (EVar "occ")))) (arm (PCon "None") () (EIf (EApp (EApp (EVar "omHasKey") (EIf (EBinOp "==" (EVar "sym") (ELit (LString ""))) (EVar "n") (EVar "sym"))) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants") "gsTakers") "value")) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "grant pass: '")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "' is routed to a standalone binding that takes authority grants, but inference did not type this use as that binding")))) (EVar "NoGrants"))))) (arm PWild () (EMatch (EApp (EApp (EApp (EVar "methodGrantOf") (EVar "gctx")) (EVar "iface")) (EVar "n")) (arm (PCon "None") () (EVar "NoGrants")) (arm (PCon "Some" (PVar "mg")) () (EMatch (EVar "recorded") (arm (PCon "Some" (PVar "occ")) () (EIf (EFieldAccess (EVar "occ") "goStandalone") (EApp (EApp (EVar "MethodGrants") (EFieldAccess (EVar "mg") "mgArity")) (EApp (EApp (EMethodRef "map") (ELam (PWild) (EVar "bottomGrant"))) (EFieldAccess (EVar "mg") "mgNames"))) (EApp (EApp (EVar "MethodGrants") (EFieldAccess (EVar "mg") "mgArity")) (EApp (EApp (EApp (EApp (EVar "methodTerms") (EVar "gctx")) (EVar "n")) (EVar "mg")) (EVar "occ"))))) (arm (PCon "None") () (EApp (EApp (EVar "MethodGrants") (EFieldAccess (EVar "mg") "mgArity")) (EApp (EApp (EMethodRef "map") (ELam (PWild) (EVar "bottomGrant"))) (EFieldAccess (EVar "mg") "mgNames")))))))))) (DoExpr (EMatch (EVar "use") (arm (PCon "MethodGrants" (PVar "arity") (PVar "grants")) () (EApp (EApp (EApp (EApp (EVar "setOccurrenceArity") (EVar "gctx")) (EVar "pe")) (EVar "ev")) (EBinOp "+" (EVar "arity") (EApp (EVar "listLen") (EVar "grants"))))) (arm (PCon "LeadingGrants" (PVar "arity") (PVar "grants")) () (EApp (EApp (EApp (EApp (EVar "setOccurrenceArity") (EVar "gctx")) (EVar "pe")) (EVar "ev")) (EBinOp "+" (EVar "arity") (EApp (EVar "listLen") (EVar "grants"))))) (arm (PCon "NoGrants") () (ELit LUnit)))) (DoExpr (EVar "use"))))
(DTypeSig false "setOccurrenceArity" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyCon "EvId") (TyFun (TyCon "Int") (TyCon "Unit"))))))
(DFunDef false "setOccurrenceArity" ((PVar "gctx") (PVar "pe") (PVar "ev") (PVar "arity")) (EIf (EBinOp "<" (EApp (EVar "evOrdinal") (EVar "ev")) (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "evBase")) (EApp (EApp (EApp (EVar "setServedArity") (EApp (EVar "passIndex") (EVar "pe"))) (EVar "ev")) (EVar "arity")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "cell") (EApp (EApp (EVar "methodCellOf") (EVar "gctx")) (EVar "ev"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "cell") "ecArity")) (EApp (EVar "Some") (EVar "arity"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "standaloneOcc" (TyFun (TyApp (TyCon "Option") (TyCon "GrantOcc")) (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "GrantOcc")))))
(DFunDef false "standaloneOcc" ((PCon "Some" (PVar "occ"))) (EMatch (ETuple (EFieldAccess (EVar "occ") "goStandalone") (EFieldAccess (EVar "occ") "goTrailing")) (arm (PTuple (PCon "True") (PCon "Some" (PVar "arity"))) () (EApp (EVar "Some") (ETuple (EVar "arity") (EVar "occ")))) (arm PWild () (EVar "None"))))
(DFunDef false "standaloneOcc" ((PCon "None")) (EVar "None"))
(DTypeSig false "methodTerms" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "MethodGrant") (TyFun (TyCon "GrantOcc") (TyApp (TyCon "List") (TyCon "Expr")))))))
(DFunDef false "methodTerms" ((PVar "gctx") (PVar "n") (PVar "mg") (PVar "occ")) (EBlock (DoLet false false (PVar "terms") (EApp (EApp (EVar "grantTerms") (EVar "gctx")) (EVar "occ"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "terms")) (EApp (EVar "listLen") (EFieldAccess (EVar "mg") "mgNames"))) (EVar "terms") (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "grant pass: a use of method '")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "' instantiated "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "terms"))))) (ELit (LString " authorities, but the method takes "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EFieldAccess (EVar "mg") "mgNames"))))) (ELit (LString " grants"))))))))
(DTypeSig false "bottomGrant" (TyCon "Expr"))
(DFunDef false "bottomGrant" () (EApp (EVar "EListLit") (EListLit (EApp (EVar "ELit") (EApp (EVar "LString") (ELit (LString "")))))))
(DTypeSig false "applyExprs" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Expr"))))
(DFunDef false "applyExprs" ((PVar "f") (PVar "args")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "a")) (EApp (EApp (EVar "EApp") (EVar "acc")) (EVar "a")))) (EVar "f")) (EVar "args")))
(DTypeSig false "saturateGrants" (TyFun (TyCon "GrantState") (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Expr")))))))
(DFunDef false "saturateGrants" ((PVar "st") (PVar "head") (PVar "arity") (PVar "grants") (PVar "args")) (EBlock (DoLet false false (PVar "given") (EApp (EVar "listLen") (EVar "args"))) (DoExpr (EIf (EBinOp ">=" (EVar "given") (EVar "arity")) (EApp (EApp (EVar "applyExprs") (EApp (EApp (EVar "applyExprs") (EVar "head")) (EBinOp "++" (EApp (EApp (EVar "take") (EVar "arity")) (EVar "args")) (EVar "grants")))) (EApp (EApp (EVar "drop") (EVar "arity")) (EVar "args"))) (EBlock (DoLet false false (PVar "bound") (EApp (EApp (EMethodRef "map") (ELam ((PVar "a")) (ETuple (EApp (EApp (EVar "freshGrantName") (EVar "st")) (ELit LUnit)) (EVar "a")))) (EVar "args"))) (DoLet false false (PVar "missing") (EApp (EApp (EMethodRef "map") (ELam (PWild) (EApp (EApp (EVar "freshGrantName") (EVar "st")) (ELit LUnit)))) (EApp (EApp (EVar "range") (EVar "given")) (EVar "arity")))) (DoLet false false (PVar "call") (EApp (EApp (EVar "applyExprs") (EVar "head")) (EBinOp "++" (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "b")) (EApp (EVar "EVar") (EApp (EVar "fst") (EVar "b"))))) (EVar "bound")) (EApp (EApp (EMethodRef "map") (EVar "EVar")) (EVar "missing"))) (EVar "grants")))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "body") (PVar "b")) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "noDeclLoc")) (EVar "False")) (EApp (EApp (EApp (EVar "PVar") (EApp (EVar "fst") (EVar "b"))) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (EVar "noBinderId"))) (EApp (EVar "snd") (EVar "b"))) (EVar "body")))) (EApp (EApp (EVar "ELam") (EApp (EApp (EMethodRef "map") (ELam ((PVar "x")) (EApp (EApp (EApp (EVar "PVar") (EVar "x")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (EVar "noBinderId")))) (EVar "missing"))) (EVar "call"))) (EApp (EVar "reverse") (EVar "bound")))))))))
(DTypeSig false "freshGrantName" (TyFun (TyCon "GrantState") (TyFun (TyCon "Unit") (TyCon "String"))))
(DFunDef false "freshGrantName" ((PVar "st") PWild) (EBlock (DoLet false false (PVar "k") (EFieldAccess (EFieldAccess (EVar "st") "gsFresh") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsFresh")) (EBinOp "+" (EVar "k") (ELit (LInt 1))))) (DoExpr (EBinOp "++" (EBinOp "++" (ELit (LString "$grant_arg_")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString ""))))))
(DTypeSig false "fileBoundValue" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "GrantBinder")) (TyFun (TyCon "Mono") (TyFun (TyCon "Expr") (TyCon "Expr"))))))
(DFunDef false "fileBoundValue" ((PVar "gctx") (PVar "chain") (PVar "ty") (PVar "e")) (EIf (EApp (EVar "hasFileBoundValue") (EVar "ty")) (EMatch (EApp (EVar "normalize") (EVar "ty")) (arm (PCon "TFun" PWild (PVar "row") (PVar "result")) () (EBlock (DoLet false false (PVar "fn") (EApp (EApp (EVar "freshGrantName") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (ELit LUnit))) (DoLet false false (PVar "arg") (EApp (EApp (EVar "freshGrantName") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "noDeclLoc")) (EVar "False")) (EApp (EApp (EApp (EVar "PVar") (EVar "fn")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (EVar "noBinderId"))) (EVar "e")) (EApp (EApp (EVar "ELam") (EListLit (EApp (EApp (EApp (EVar "PVar") (EVar "arg")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (EVar "noBinderId")))) (EApp (EApp (EApp (EApp (EVar "fileBoundExpr") (EVar "gctx")) (EVar "chain")) (EVar "row")) (EApp (EApp (EApp (EApp (EVar "fileBoundValue") (EVar "gctx")) (EVar "chain")) (EVar "result")) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "fn"))) (EApp (EVar "EVar") (EVar "arg")))))))))) (arm (PCon "TQual" (PVar "inner") PWild) () (EApp (EApp (EApp (EApp (EVar "fileBoundValue") (EVar "gctx")) (EVar "chain")) (EVar "inner")) (EVar "e"))) (arm PWild () (EVar "e"))) (EVar "e")))
(DTypeSig false "grantBody" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "grantBody" ((PVar "gctx") (PVar "pe") (PVar "body")) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EApp (EVar "grantExpr") (EVar "gctx")) (EVar "pe")) (EVar "body"))) (DoExpr (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants") "gsBounds") "value") (arm (PCon "Tip") () (EVar "inner")) (arm (PVar "boundsBySite") () (EBlock (DoLet false false (PVar "bounds") (EMatch (EApp (EVar "fileBodyLoc") (EVar "body")) (arm (PCon "Some" (PVar "loc")) () (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EApp (EApp (EVar "fileBoundSite") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants") "gsPassingModule") "value")) (EVar "loc"))) (EVar "boundsBySite")))) (arm (PCon "None") () (EListLit)))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "result") (PTuple (PVar "row") (PVar "chain"))) (EApp (EApp (EApp (EApp (EVar "fileBoundExpr") (EVar "gctx")) (EVar "chain")) (EVar "row")) (EVar "result")))) (EVar "inner")) (EVar "bounds")))))))))
(DTypeSig false "fileBoundExpr" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "GrantBinder")) (TyFun (TyCon "EffRow") (TyFun (TyCon "Expr") (TyCon "Expr"))))))
(DFunDef false "fileBoundExpr" ((PVar "gctx") (PVar "chain") (PVar "row") (PVar "body")) (EBlock (DoLet false false (PTuple (PVar "atoms") (PVar "tails")) (EApp (EVar "rowFlat") (EVar "row"))) (DoExpr (EIf (EApp (EVar "isNonEmptyL") (EVar "tails")) (EVar "body") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "result") (PVar "atom")) (EBlock (DoLet false false (PVar "label") (EApp (EVar "atomLabel") (EVar "atom"))) (DoExpr (EIf (EApp (EVar "narrowFileAtom") (EVar "atom")) (EApp (EApp (EVar "applyExprs") (EApp (EVar "EVar") (EBinOp "++" (EBinOp "++" (ELit (LString "$with")) (EVar "label")) (ELit (LString "Bound"))))) (EListLit (EApp (EApp (EApp (EVar "grantTerm") (EVar "gctx")) (EVar "chain")) (EApp (EVar "atomAuth") (EVar "atom"))) (EApp (EApp (EVar "ELam") (EListLit (EVar "PWild"))) (EVar "result")))) (EVar "result")))))) (EVar "body")) (EVar "atoms"))))))
(DTypeSig false "grantTerms" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "GrantOcc") (TyApp (TyCon "List") (TyCon "Expr")))))
(DFunDef false "grantTerms" ((PVar "gctx") (PVar "occ")) (EMatch (EFieldAccess (EVar "occ") "goRecIds") (arm (PList) () (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "grantTerm") (EVar "gctx")) (EFieldAccess (EVar "occ") "goChain"))) (EFieldAccess (EVar "occ") "goCells"))) (arm (PVar "ids") () (EApp (EApp (EMethodRef "map") (ELam ((PVar "i")) (EApp (EApp (EApp (EVar "grantIdTerm") (EVar "gctx")) (EFieldAccess (EVar "occ") "goChain")) (EVar "i")))) (EVar "ids")))))
(DTypeSig false "grantTerm" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "GrantBinder")) (TyFun (TyCon "Authority") (TyCon "Expr")))))
(DFunDef false "grantTerm" ((PVar "gctx") (PVar "chain") (PVar "a")) (EMatch (EApp (EVar "authGrantShape") (EVar "a")) (arm (PCon "GrantTop") () (EApp (EVar "EListLit") (EListLit))) (arm (PCon "GrantBottom") () (EVar "bottomGrant")) (arm (PCon "GrantParts" (PVar "elems") (PVar "vars")) () (EMatch (EApp (EApp (EApp (EApp (EVar "grantVarParams") (EVar "gctx")) (EVar "chain")) (EVar "vars")) (EListLit)) (arm (PCon "None") () (EApp (EVar "EListLit") (EListLit))) (arm (PCon "Some" (PVar "params")) () (EBlock (DoLet false false (PVar "parts") (EBinOp "++" (EIf (EApp (EVar "isEmptyL") (EVar "elems")) (EListLit) (EListLit (EApp (EVar "EListLit") (EApp (EApp (EMethodRef "map") (ELam ((PVar "s")) (EApp (EVar "ELit") (EApp (EVar "LString") (EVar "s"))))) (EVar "elems"))))) (EApp (EApp (EMethodRef "map") (EVar "EVar")) (EApp (EVar "dedup") (EVar "params"))))) (DoExpr (EMatch (EVar "parts") (arm (PList) () (EVar "bottomGrant")) (arm (PList (PVar "p")) () (EVar "p")) (arm (PCons (PVar "p") (PVar "rest")) () (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "param")) (EApp (EApp (EVar "topAbsorbs") (EVar "param")) (EVar "acc")))) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "q")) (EApp (EApp (EApp (EApp (EVar "EBinOp") (ELit (LString "++"))) (EVar "acc")) (EVar "q")) (EVar "unminted")))) (EApp (EVar "EListLit") (EListLit))) (EBinOp "::" (EVar "p") (EVar "rest")))) (EApp (EVar "dedup") (EVar "params"))))))))))))
(DTypeSig false "grantVarParams" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "GrantBinder")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "grantVarParams" ((PVar "_gctx") PWild (PList) (PVar "acc")) (EApp (EVar "Some") (EApp (EVar "reverse") (EVar "acc"))))
(DFunDef false "grantVarParams" ((PVar "gctx") (PVar "chain") (PCons (PVar "v") (PVar "rest")) (PVar "acc")) (EMatch (EApp (EApp (EApp (EVar "grantParamFor") (EVar "gctx")) (EVar "chain")) (EApp (EVar "authvarId") (EVar "v"))) (arm (PCon "Some" (PVar "p")) () (EApp (EApp (EApp (EApp (EVar "grantVarParams") (EVar "gctx")) (EVar "chain")) (EVar "rest")) (EBinOp "::" (EVar "p") (EVar "acc")))) (arm (PCon "None") () (EIf (EApp (EApp (EVar "isSourceless") (EVar "gctx")) (EApp (EVar "authvarId") (EVar "v"))) (EVar "None") (EApp (EApp (EApp (EApp (EVar "grantVarParams") (EVar "gctx")) (EVar "chain")) (EVar "rest")) (EVar "acc"))))))
(DTypeSig false "topAbsorbs" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "topAbsorbs" ((PVar "param") (PVar "join")) (EApp (EApp (EVar "EMatch") (EApp (EVar "EVar") (EVar "param"))) (EListLit (EApp (EApp (EApp (EVar "Arm") (EApp (EVar "PList") (EListLit))) (EListLit)) (EApp (EVar "EListLit") (EListLit))) (EApp (EApp (EApp (EVar "Arm") (EVar "PWild")) (EListLit)) (EVar "join")))))
(DTypeSig false "grantIdTerm" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "GrantBinder")) (TyFun (TyCon "Int") (TyCon "Expr")))))
(DFunDef false "grantIdTerm" ((PVar "gctx") (PVar "chain") (PVar "i")) (EMatch (EApp (EApp (EApp (EVar "grantParamFor") (EVar "gctx")) (EVar "chain")) (EVar "i")) (arm (PCon "Some" (PVar "p")) () (EApp (EVar "EVar") (EVar "p"))) (arm (PCon "None") () (EVar "bottomGrant"))))
(DTypeSig false "grantParamFor" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "GrantBinder")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "grantParamFor" ((PVar "_gctx") (PList) PWild) (EVar "None"))
(DFunDef false "grantParamFor" ((PVar "gctx") (PCons (PVar "b") (PVar "rest")) (PVar "i")) (EBlock (DoLet false false (PTuple (PVar "name") (PVar "ids")) (EMatch (EVar "b") (arm (PCon "TopGrantBinder" (PVar "mid") (PVar "n")) () (ETuple (EVar "n") (EApp (EApp (EApp (EVar "topGrantIds") (EVar "gctx")) (EVar "mid")) (EVar "n")))) (arm (PCon "LocalGrantBinder" (PVar "n")) () (ETuple (EVar "n") (EApp (EApp (EVar "localGrantIds") (EVar "gctx")) (EVar "n")))) (arm (PCon "BodyGrantBinder" (PVar "n") (PVar "bound")) () (ETuple (EVar "n") (EVar "bound"))))) (DoExpr (EMatch (EApp (EApp (EVar "elemIndex") (EVar "i")) (EVar "ids")) (arm (PCon "Some" (PVar "k")) () (EApp (EVar "Some") (EApp (EApp (EVar "grantParamName") (EVar "name")) (EVar "k")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "grantParamFor") (EVar "gctx")) (EVar "rest")) (EVar "i")))))))
(DTypeSig false "rewriteBinopExpr" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "rewriteBinopExpr" ((PVar "mctx") (PVar "pe") (PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") (PVar "ev"))) (EMatch (EApp (EApp (EVar "evSiteRouteIn") (EApp (EVar "passIndex") (EVar "pe"))) (EVar "ev")) (arm (PCon "RNone") () (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EVar "l")) (EVar "r")) (EVar "ev"))) (arm (PCon "RScalar" (PVar "tag")) () (EApp (EApp (EVar "EAnnot") (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EVar "l")) (EVar "r")) (EVar "ev"))) (EApp (EApp (EVar "tyConBuiltin") (EVar "tag")) (EVar "None")))) (arm (PVar "route") () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "binopMethodApp") (EVar "mctx")) (EVar "pe")) (EVar "op")) (EVar "l")) (EVar "r")) (EVar "route")))))
(DFunDef false "rewriteBinopExpr" ((PVar "mctx") (PVar "pe") (PCon "ENumLit" (PVar "n") (PVar "ev") PWild)) (EMatch (EApp (EApp (EVar "evSiteLitIn") (EApp (EVar "passIndex") (EVar "pe"))) (EVar "ev")) (arm (PTuple (PCon "Some" (PVar "f")) PWild) () (EApp (EVar "ELit") (EApp (EVar "LFloat") (EVar "f")))) (arm (PTuple (PCon "None") (PVar "dref")) () (EMatch (EVar "dref") (arm (PCon "RNone") () (EApp (EVar "ELit") (EApp (EVar "LInt") (EVar "n")))) (arm (PVar "route") ((GBool (EApp (EApp (EVar "fixedWidthLiteralFits") (EVar "route")) (EVar "n")))) (EApp (EVar "ELit") (EApp (EVar "LInt") (EVar "n")))) (arm (PVar "route") ((GBool (EApp (EApp (EVar "u64LiteralFits") (EVar "route")) (EVar "n")))) (EApp (EVar "ELit") (EApp (EApp (EVar "LU64") (EBinOp "/" (EVar "n") (ELit (LInt 4294967296)))) (EBinOp "%" (EVar "n") (ELit (LInt 4294967296)))))) (arm (PCon "RKey" (PVar "word") PWild PWild) ((GBool (EApp (EVar "isI64Head") (EApp (EVar "literalRouteHead") (EVar "word"))))) (EBlock (DoLet false false (PVar "halves") (EApp (EVar "int64Halves") (EVar "n"))) (DoExpr (EApp (EVar "ELit") (EApp (EApp (EVar "LI64") (EApp (EVar "fst") (EVar "halves"))) (EApp (EVar "snd") (EVar "halves"))))))) (arm (PVar "route") () (EBlock (DoLet false false (PVar "split") (EApp (EVar "binopRouteSplit") (EVar "route"))) (DoExpr (EApp (EApp (EVar "EApp") (EApp (EApp (EApp (EVar "EMethodAt") (ELit (LString "fromInt"))) (ELit (LString ""))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mintMethodCellWith") (EVar "mctx")) (EVar "pe")) (EApp (EApp (EVar "builtinMethodIfaceWord") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit (LString "fromInt")))) (ELit (LInt 1))) (EApp (EVar "fst") (EVar "split"))) (EApp (EVar "snd") (EVar "split"))))) (EApp (EVar "ELit") (EApp (EVar "LInt") (EVar "n")))))))))))
(DFunDef false "rewriteBinopExpr" ((PVar "mctx") (PVar "pe") (PCon "EUnOp" (PVar "op") (PVar "e") (PVar "ev"))) (EMatch (EApp (EApp (EVar "evSiteRouteIn") (EApp (EVar "passIndex") (EVar "pe"))) (EVar "ev")) (arm (PCon "RNone") () (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EVar "e")) (EVar "ev"))) (arm (PCon "RScalar" PWild) () (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EVar "e")) (EVar "ev"))) (arm (PCon "RKey" (PVar "word") PWild PWild) ((GBool (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "op") (ELit (LString "-"))) (EApp (EVar "isI32Head") (EApp (EVar "literalRouteHead") (EVar "word")))) (EApp (EVar "isSome") (EApp (EVar "negatedI32Lit") (EVar "e")))))) (EApp (EVar "ELit") (EApp (EVar "LInt") (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EVar "negatedI32Lit") (EVar "e")))))) (arm (PVar "route") () (EApp (EApp (EApp (EApp (EApp (EVar "unopMethodApp") (EVar "mctx")) (EVar "pe")) (EVar "op")) (EVar "e")) (EVar "route")))))
(DFunDef false "rewriteBinopExpr" ((PVar "_mctx") (PVar "pe") (PCon "EWideLit" (PVar "hi") (PVar "lo") (PVar "ev") PWild)) (EMatch (EApp (EApp (EVar "evSiteRouteIn") (EApp (EVar "passIndex") (EVar "pe"))) (EVar "ev")) (arm (PCon "RKey" (PVar "word") PWild PWild) ((GBool (EApp (EVar "isI64Head") (EApp (EVar "literalRouteHead") (EVar "word"))))) (EApp (EVar "ELit") (EApp (EApp (EVar "LI64") (EVar "hi")) (EVar "lo")))) (arm PWild () (EApp (EVar "ELit") (EApp (EApp (EVar "LU64") (EVar "hi")) (EVar "lo"))))))
(DFunDef false "rewriteBinopExpr" ((PVar "_mctx") PWild (PVar "e")) (EVar "e"))
(DTypeSig false "negatedI32Lit" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "negatedI32Lit" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "negatedI32Lit") (EVar "e")))
(DFunDef false "negatedI32Lit" ((PCon "ELit" (PCon "LInt" (PVar "n")))) (EApp (EVar "negatedInI32") (EVar "n")))
(DFunDef false "negatedI32Lit" ((PCon "EApp" (PCon "EMethodAt" (PLit (LString "fromInt")) PWild PWild) (PCon "ELit" (PCon "LInt" (PVar "n"))))) (EApp (EVar "negatedInI32") (EVar "n")))
(DFunDef false "negatedI32Lit" (PWild) (EVar "None"))
(DTypeSig false "negatedInI32" (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "negatedInI32" ((PVar "n")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (EUnOp "-" (ELit (LInt 2147483647)))) (EBinOp "<=" (EVar "n") (ELit (LInt 2147483648)))) (EApp (EVar "Some") (EBinOp "-" (ELit (LInt 0)) (EVar "n"))) (EVar "None")))
(DTypeSig false "u64LiteralFits" (TyFun (TyCon "Route") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "u64LiteralFits" ((PCon "RKey" (PVar "word") PWild PWild) (PVar "n")) (EBinOp "&&" (EApp (EVar "isU64Head") (EApp (EVar "literalRouteHead") (EVar "word"))) (EBinOp ">=" (EVar "n") (ELit (LInt 0)))))
(DFunDef false "u64LiteralFits" (PWild PWild) (EVar "False"))
(DTypeSig false "fixedWidthLiteralFits" (TyFun (TyCon "Route") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "fixedWidthLiteralFits" ((PCon "RKey" (PVar "word") PWild PWild) (PVar "n")) (EBlock (DoLet false false (PVar "head") (EApp (EVar "literalRouteHead") (EVar "word"))) (DoExpr (EMatch (EApp (EVar "taggedFixedRange") (EVar "head")) (arm (PCon "Some" (PTuple (PVar "lo") (PVar "hi"))) () (EBinOp "&&" (EBinOp ">=" (EVar "n") (EVar "lo")) (EBinOp "<=" (EVar "n") (EVar "hi")))) (arm (PCon "None") () (EVar "False"))))))
(DFunDef false "fixedWidthLiteralFits" (PWild PWild) (EVar "False"))
(DTypeSig false "literalRouteHead" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "literalRouteHead" ((PVar "word")) (EMatch (EApp (EApp (EVar "splitOnChar") (ELit (LChar "|"))) (EVar "word")) (arm (PCons PWild (PCons (PVar "ty") PWild)) () (EVar "ty")) (arm PWild () (EVar "word"))))
(DTypeSig false "binopRouteSplit" (TyFun (TyCon "Route") (TyTuple (TyCon "Route") (TyApp (TyCon "List") (TyCon "Route")))))
(DFunDef false "binopRouteSplit" ((PCon "RKey" (PVar "tag") (PVar "reqs") (PVar "sups"))) (ETuple (EApp (EApp (EApp (EVar "RKey") (EVar "tag")) (EListLit)) (EVar "sups")) (EVar "reqs")))
(DFunDef false "binopRouteSplit" ((PVar "r")) (ETuple (EVar "r") (EListLit)))
(DTypeSig false "binopMethodApp" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Route") (TyCon "Expr"))))))))
(DFunDef false "binopMethodApp" ((PVar "mctx") (PVar "pe") (PVar "op") (PVar "l") (PVar "r") (PVar "route")) (EBlock (DoLet false false (PVar "method") (EApp (EApp (EVar "optionOr") (ELit (LString "eq"))) (EApp (EVar "binopDispatchMethod") (EVar "op")))) (DoLet false false (PVar "split") (EApp (EVar "binopRouteSplit") (EVar "route"))) (DoLet false false (PVar "call") (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EApp (EApp (EVar "EMethodAt") (EVar "method")) (ELit (LString ""))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mintMethodCellWith") (EVar "mctx")) (EVar "pe")) (EApp (EApp (EVar "builtinMethodIfaceWord") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "method"))) (ELit (LInt 2))) (EApp (EVar "fst") (EVar "split"))) (EApp (EVar "snd") (EVar "split"))))) (EVar "l"))) (EVar "r"))) (DoExpr (EIf (EBinOp "==" (EVar "op") (ELit (LString "/="))) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "not")))) (EVar "call")) (EVar "call")))))
(DTypeSig false "binopDispatchMethod" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "binopDispatchMethod" ((PVar "op")) (EMatch (EApp (EVar "arithDispatchMethod") (EVar "op")) (arm (PCon "Some" (PVar "method")) () (EApp (EVar "Some") (EVar "method"))) (arm (PCon "None") () (EApp (EVar "binopMethod") (EVar "op")))))
(DTypeSig false "unopMethodApp" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Route") (TyCon "Expr")))))))
(DFunDef false "unopMethodApp" ((PVar "mctx") (PVar "pe") (PVar "op") (PVar "e") (PVar "route")) (EBlock (DoLet false false (PVar "method") (EApp (EApp (EVar "optionOr") (ELit (LString "negate"))) (EApp (EVar "unopMethod") (EVar "op")))) (DoLet false false (PVar "split") (EApp (EVar "binopRouteSplit") (EVar "route"))) (DoExpr (EApp (EApp (EVar "EApp") (EApp (EApp (EApp (EVar "EMethodAt") (EVar "method")) (ELit (LString ""))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mintMethodCellWith") (EVar "mctx")) (EVar "pe")) (EApp (EApp (EVar "builtinMethodIfaceWord") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "method"))) (ELit (LInt 1))) (EApp (EVar "fst") (EVar "split"))) (EApp (EVar "snd") (EVar "split"))))) (EVar "e")))))
(DTypeSig false "dictPassDecl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Decl") (TyCon "Decl")))))))
(DFunDef false "dictPassDecl" ((PVar "mctx") PWild (PVar "names") PWild (PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "pats") (PVar "body") (PVar "site") (PVar "bid"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "names")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "n")) (EBinOp "++" (EApp (EApp (EVar "dictParams") (EVar "n")) (EApp (EApp (EVar "dictArityOf") (EVar "mctx")) (EVar "n"))) (EVar "pats"))) (EVar "body")) (EVar "site")) (EVar "bid")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "n")) (EVar "pats")) (EVar "body")) (EVar "site")) (EVar "bid")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "dictPassDecl" ((PVar "mctx") PWild (PVar "names") PWild (PCon "DLetGroup" (PVar "pub") (PVar "binds"))) (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "dictPassLetBind") (EVar "mctx")) (EVar "names"))) (EVar "binds"))))
(DFunDef false "dictPassDecl" ((PVar "mctx") (PVar "pe") PWild PWild (PAs "d" (PRec "DImpl" ((rf "iface" None) (rf "implOrigin" None) (rf "reqs" None) (rf "methods" None)) true))) (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EApp (EApp (EApp (EApp (EApp (EVar "implDictPassMethods") (EVar "mctx")) (EVar "pe")) (ERecordCreate "IfaceRef" ((fa "irName" (EVar "iface")) (fa "irOrigin" (EVar "implOrigin"))))) (EApp (EVar "listLen") (EVar "reqs"))) (EVar "methods"))))))
(DFunDef false "dictPassDecl" ((PVar "_mctx") PWild PWild PWild (PAs "d" (PRec "DInterface" ((rf "typarams" None) (rf "methods" None)) true))) (EVariantUpdate "DInterface" (EVar "d") ((fa "methods" (EApp (EApp (EMethodRef "map") (EApp (EVar "ifaceDictPassMethod") (EVar "typarams"))) (EVar "methods"))))))
(DFunDef false "dictPassDecl" ((PVar "mctx") (PVar "pe") (PVar "names") (PVar "ret") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EApp (EApp (EApp (EVar "dictPassDecl") (EVar "mctx")) (EVar "pe")) (EVar "names")) (EVar "ret")) (EVar "d"))))
(DFunDef false "dictPassDecl" ((PVar "_mctx") PWild PWild PWild (PVar "d")) (EVar "d"))
(DTypeSig false "dictPassLetBind" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "LetBind") (TyCon "LetBind")))))
(DFunDef false "dictPassLetBind" ((PVar "mctx") (PVar "names") (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "names")) (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "prependDictClause") (EVar "n")) (EApp (EApp (EVar "dictArityOf") (EVar "mctx")) (EVar "n")))) (EVar "clauses"))) (EVar "site")) (EVar "bid")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EVar "clauses")) (EVar "site")) (EVar "bid")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "prependDictClause" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "FunClause") (TyCon "FunClause")))))
(DFunDef false "prependDictClause" ((PVar "n") (PVar "k") (PCon "FunClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EBinOp "++" (EApp (EApp (EVar "dictParams") (EVar "n")) (EVar "k")) (EVar "pats"))) (EVar "body")))
(DTypeSig false "ifaceDictPassMethod" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyCon "IfaceMethod"))))
(DFunDef false "ifaceDictPassMethod" ((PVar "typarams") (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "Some" (PCon "MethodDefault" (PVar "pats") (PVar "body"))) (PVar "mloc"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ifaceDictPassDefault") (EVar "n")) (EVar "ty")) (EVar "pats")) (EVar "body")) (EVar "mloc")) (EApp (EVar "listLen") (EApp (EApp (EVar "methodLevelConstraintVarNames") (EVar "typarams")) (EVar "ty")))))
(DFunDef false "ifaceDictPassMethod" (PWild (PVar "m")) (EVar "m"))
(DTypeSig false "ifaceDictPassDefault" (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Int") (TyCon "IfaceMethod"))))))))
(DFunDef false "ifaceDictPassDefault" ((PVar "n") (PVar "ty") (PVar "pats") (PVar "body") (PVar "mloc") (PVar "k")) (EIf (EBinOp ">" (EVar "k") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EApp (EVar "Some") (EApp (EApp (EVar "MethodDefault") (EBinOp "++" (EApp (EApp (EVar "dictParams") (EVar "n")) (EVar "k")) (EVar "pats"))) (EVar "body")))) (EVar "mloc")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EApp (EVar "Some") (EApp (EApp (EVar "MethodDefault") (EVar "pats")) (EVar "body")))) (EVar "mloc")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "implDictPassMethods" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyApp (TyCon "List") (TyCon "ImplMethod"))))))))
(DFunDef false "implDictPassMethods" ((PVar "mctx") (PVar "pe") (PVar "iface") (PVar "nReq") (PVar "methods")) (EBlock (DoLet false false (PVar "users") (EApp (EVar "dedup") (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EApp (EVar "clauseImplDictUser") (EVar "mctx")) (EVar "pe")) (EVar "iface")) (EVar "nReq"))) (EVar "methods")))) (DoExpr (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EVar "prependImplDictIfUser") (EVar "mctx")) (EVar "iface")) (EVar "nReq")) (EVar "users"))) (EVar "methods")))))
(DTypeSig false "clauseImplDictUser" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "PassEvidence") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "Int") (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "clauseImplDictUser" ((PVar "mctx") (PVar "pe") (PVar "iface") (PVar "nReq") (PCon "ImplMethod" (PVar "n") PWild (PVar "body"))) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "usesImplDict") (EVar "pe")) (EVar "n")) (EApp (EApp (EApp (EVar "implMethodDictArity") (EVar "mctx")) (EVar "iface")) (EVar "n"))) (EVar "nReq")) (EVar "body")) (EListLit (EVar "n")) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "prependImplDictIfUser" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod")))))))
(DFunDef false "prependImplDictIfUser" ((PVar "mctx") (PVar "iface") (PVar "nReq") (PVar "users") (PCon "ImplMethod" (PVar "n") (PVar "pats") (PVar "body"))) (EBlock (DoLet false false (PVar "k") (EApp (EApp (EApp (EVar "implMethodDictArity") (EVar "mctx")) (EVar "iface")) (EVar "n"))) (DoLet false false (PVar "implPats") (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "users")) (EApp (EApp (EApp (EVar "dictParamsFrom") (EVar "n")) (EVar "k")) (EVar "nReq")) (EListLit))) (DoExpr (EIf (EBinOp "&&" (EBinOp "==" (EVar "k") (ELit (LInt 0))) (EApp (EVar "isEmptyL") (EVar "implPats"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "n")) (EVar "pats")) (EVar "body")) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "n")) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "dictParams") (EVar "n")) (EVar "k")) (EVar "implPats")) (EVar "pats"))) (EVar "body"))))))
(DTypeSig false "usesImplDict" (TyFun (TyCon "PassEvidence") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Expr") (TyCon "Bool")))))))
(DFunDef false "usesImplDict" ((PVar "pe") (PVar "mname") (PVar "methodArity") (PVar "nReq") (PVar "body")) (EApp (EApp (EVar "anyMember") (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "body"))) (EApp (EApp (EApp (EVar "implDictNames") (EVar "mname")) (EVar "methodArity")) (EVar "nReq"))))
(DTypeSig false "implDictNames" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "implDictNames" ((PVar "mname") (PVar "methodArity") (PVar "nReq")) (EApp (EApp (EMethodRef "map") (EApp (EVar "dictParamName") (EVar "mname"))) (EApp (EApp (EVar "range") (EVar "methodArity")) (EBinOp "+" (EVar "methodArity") (EVar "nReq")))))
(DTypeSig false "implMethodDictArity" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "String") (TyCon "Int")))))
(DFunDef false "implMethodDictArity" ((PVar "mctx") (PVar "iface") (PVar "method")) (EApp (EApp (EApp (EVar "methodDictArityAtOrigin") (EVar "mctx")) (EFieldAccess (EVar "iface") "irOrigin")) (EApp (EApp (EVar "methodSlotKey") (EVar "iface")) (EVar "method"))))
(DTypeSig false "methodDictArityAtOrigin" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyCon "Int")))))
(DFunDef false "methodDictArityAtOrigin" ((PVar "mctx") (PCon "OriginModule" (PVar "mid")) (PVar "key")) (EMatch (EApp (EApp (EApp (EVar "lookupQualPayload") (EVar "mid")) (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "crossRun") "crossModuleMethodPredicateSlotsQualRef") "value")) (arm (PCon "Some" (PVar "slots")) () (EApp (EVar "listLen") (EVar "slots"))) (arm (PCon "None") () (EApp (EApp (EVar "methodDictArityOf") (EVar "mctx")) (EVar "key")))))
(DFunDef false "methodDictArityAtOrigin" ((PVar "mctx") PWild (PVar "key")) (EApp (EApp (EVar "methodDictArityOf") (EVar "mctx")) (EVar "key")))
(DTypeSig false "siteRDictName" (TyFun (TyCon "Route") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "siteRDictName" ((PCon "RDict" (PVar "d"))) (EListLit (EVar "d")))
(DFunDef false "siteRDictName" ((PCon "RDictFwd" (PVar "d"))) (EListLit (EVar "d")))
(DFunDef false "siteRDictName" ((PCon "RProj" (PVar "inner") PWild)) (EApp (EVar "routeRDictName") (EVar "inner")))
(DFunDef false "siteRDictName" (PWild) (EListLit))
(DTypeSig false "siteRDictNamesL" (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "siteRDictNamesL" ((PVar "rs")) (EApp (EApp (EDictApp "flatMap") (EVar "routeRDictName")) (EVar "rs")))
(DTypeSig false "routeRDictName" (TyFun (TyCon "Route") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "routeRDictName" ((PCon "RDict" (PVar "d"))) (EListLit (EVar "d")))
(DFunDef false "routeRDictName" ((PCon "RDictFwd" (PVar "d"))) (EListLit (EVar "d")))
(DFunDef false "routeRDictName" ((PCon "RKey" PWild (PVar "reqs") (PVar "sups"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "routeRDictName")) (EVar "reqs")) (EApp (EApp (EDictApp "flatMap") (EVar "routeRDictName")) (EVar "sups"))))
(DFunDef false "routeRDictName" ((PCon "RProj" (PVar "r") PWild)) (EApp (EVar "routeRDictName") (EVar "r")))
(DFunDef false "routeRDictName" (PWild) (EListLit))
(DTypeSig false "collectDictSites" (TyFun (TyCon "PassEvidence") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "EDictAt" PWild (PVar "ev"))) (EApp (EVar "siteRDictNamesL") (EApp (EApp (EVar "evDictRoutesIn") (EApp (EVar "passIndex") (EVar "pe"))) (EVar "ev"))))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "EMethodAt" PWild PWild (PVar "ev"))) (EBlock (DoLet false false (PCon "PassMethod" PWild (PVar "tag") (PVar "dicts")) (EApp (EApp (EVar "passMethodOf") (EVar "pe")) (EVar "ev"))) (DoExpr (EBinOp "++" (EApp (EVar "siteRDictName") (EVar "tag")) (EApp (EVar "siteRDictNamesL") (EVar "dicts"))))))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "ELoc" PWild (PVar "e"))) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "EApp" (PVar "f") (PVar "x"))) (EBinOp "++" (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "f")) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "x"))))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "ELam" PWild (PVar "b"))) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "b")))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "ELet" PWild PWild PWild (PVar "e1") (PVar "e2"))) (EBinOp "++" (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e1")) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e2"))))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EVar "letBindDictSites") (EVar "pe"))) (EVar "binds")) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "body"))))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "EMatch" (PVar "e") (PVar "arms"))) (EBinOp "++" (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "armDictSites") (EVar "pe"))) (EVar "arms"))))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "EIf" (PVar "c") (PVar "t") (PVar "e"))) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "c")) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "t"))) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e"))))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "EBinOp" PWild (PVar "l") (PVar "r") PWild)) (EBinOp "++" (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "l")) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "r"))))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "EUnOp" PWild (PVar "e") PWild)) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "EInfix" PWild (PVar "l") (PVar "r"))) (EBinOp "++" (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "l")) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "r"))))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "EFieldAccess" (PVar "e") PWild PWild)) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "ETuple" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "collectDictSites") (EVar "pe"))) (EVar "es")))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "EListLit" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "collectDictSites") (EVar "pe"))) (EVar "es")))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "collectDictSites") (EVar "pe"))) (EVar "es")))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "ERangeList" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "a")) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "b"))))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "ERangeArray" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "a")) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "b"))))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "ESlice" (PVar "e") (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "a"))) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "b"))))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "EIndex" (PVar "e") (PVar "i"))) (EBinOp "++" (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "i"))))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "EAnnot" (PVar "e") PWild)) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "doStmtDictSites") (EVar "pe"))) (EVar "stmts")))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "ERecordCreate" PWild (PVar "fs"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "fieldAssignDictSites") (EVar "pe"))) (EVar "fs")))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "ERecordUpdate" (PVar "e") (PVar "fs") PWild)) (EBinOp "++" (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "fieldAssignDictSites") (EVar "pe"))) (EVar "fs"))))
(DFunDef false "collectDictSites" ((PVar "pe") (PCon "EVariantUpdate" PWild (PVar "e") (PVar "fs"))) (EBinOp "++" (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "fieldAssignDictSites") (EVar "pe"))) (EVar "fs"))))
(DFunDef false "collectDictSites" (PWild PWild) (EListLit))
(DTypeSig false "letBindDictSites" (TyFun (TyCon "PassEvidence") (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "letBindDictSites" ((PVar "pe") (PCon "LetBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "funClauseDictSites") (EVar "pe"))) (EVar "clauses")))
(DTypeSig false "funClauseDictSites" (TyFun (TyCon "PassEvidence") (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "funClauseDictSites" ((PVar "pe") (PCon "FunClause" PWild (PVar "body"))) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "body")))
(DTypeSig false "armDictSites" (TyFun (TyCon "PassEvidence") (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "armDictSites" ((PVar "pe") (PCon "Arm" PWild (PVar "guards") (PVar "body"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EVar "guardDictSites") (EVar "pe"))) (EVar "guards")) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "body"))))
(DTypeSig false "guardDictSites" (TyFun (TyCon "PassEvidence") (TyFun (TyCon "Guard") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "guardDictSites" ((PVar "pe") (PCon "GBool" (PVar "e"))) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")))
(DFunDef false "guardDictSites" ((PVar "pe") (PCon "GBind" PWild (PVar "e"))) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")))
(DTypeSig false "doStmtDictSites" (TyFun (TyCon "PassEvidence") (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "doStmtDictSites" ((PVar "pe") (PCon "DoExpr" (PVar "e"))) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")))
(DFunDef false "doStmtDictSites" ((PVar "pe") (PCon "DoLet" PWild PWild PWild (PVar "e") PWild)) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")))
(DFunDef false "doStmtDictSites" ((PVar "pe") (PCon "DoBind" PWild (PVar "e"))) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")))
(DFunDef false "doStmtDictSites" ((PVar "pe") (PCon "DoAssign" PWild (PVar "e"))) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")))
(DFunDef false "doStmtDictSites" ((PVar "pe") (PCon "DoFieldAssign" PWild PWild (PVar "e"))) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")))
(DTypeSig false "fieldAssignDictSites" (TyFun (TyCon "PassEvidence") (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "fieldAssignDictSites" ((PVar "pe") (PCon "FieldAssign" PWild (PVar "e"))) (EApp (EApp (EVar "collectDictSites") (EVar "pe")) (EVar "e")))
(DTypeSig false "dictArityOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "dictArityOf" ((PVar "mctx") (PVar "n")) (EApp (EVar "listLen") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "lookupPredicateSlots") (EVar "n")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funPredicateSlotsIdxRef") "value")))))
(DTypeSig false "dictParams" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Pat")))))
(DFunDef false "dictParams" ((PVar "n") (PVar "k")) (EApp (EApp (EApp (EVar "dictParamsGo") (EVar "n")) (ELit (LInt 0))) (EVar "k")))
(DTypeSig false "dictParamsGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Pat"))))))
(DFunDef false "dictParamsGo" ((PVar "n") (PVar "slot") (PVar "k")) (EIf (EBinOp ">=" (EVar "slot") (EVar "k")) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EApp (EVar "PVar") (EApp (EApp (EVar "dictParamName") (EVar "n")) (EVar "slot"))) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (EVar "noBinderId")) (EApp (EApp (EApp (EVar "dictParamsGo") (EVar "n")) (EBinOp "+" (EVar "slot") (ELit (LInt 1)))) (EVar "k"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dictParamsFrom" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Pat"))))))
(DFunDef false "dictParamsFrom" ((PVar "n") (PVar "start") (PVar "count")) (EIf (EBinOp "<=" (EDictApp "count") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EApp (EVar "PVar") (EApp (EApp (EVar "dictParamName") (EVar "n")) (EVar "start"))) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (EVar "noBinderId")) (EApp (EApp (EApp (EVar "dictParamsFrom") (EVar "n")) (EBinOp "+" (EVar "start") (ELit (LInt 1)))) (EBinOp "-" (EDictApp "count") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "dictPassModulesIfEnabled" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))))))
(DFunDef false "dictPassModulesIfEnabled" ((PVar "mctx") (PVar "dictNames") (PVar "corePassed") (PVar "core2") (PVar "modules2")) (EBlock (DoLet false false (PVar "idx") (EApp (EVar "evIndexOf") (EApp (EApp (EVar "drivenEvidence") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit)))) (DoLet false false (PVar "promotedQ") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "crossRun") "crossModuleFunPredicateSlotsQualRef") "value")) (DoLet false false (PVar "allMods") (EApp (EApp (EVar "namesToSet") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "modules2"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "setFunPredicateSlots") (EVar "mctx")) (EApp (EApp (EApp (EVar "scopePredicateSlots") (EListLit)) (EVar "omEmpty")) (EVar "core2")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funConstraintDeclaredRef")) (EListLit))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodPredicateSlotsRef")) (EApp (EApp (EVar "scopeMethodPredicateSlots") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "crossRun") "crossModuleMethodPredicateSlotsQualRef") "value")) (EVar "allMods")))) (DoLet false false (PVar "core2'") (EIf (EVar "corePassed") (EVar "core2") (EApp (EApp (EApp (EApp (EApp (EVar "dictPass") (EVar "mctx")) (EVar "idx")) (ELit (LString ""))) (EApp (EVar "constrainedSigNames") (EVar "core2"))) (EVar "core2")))) (DoLet false false (PVar "importerReach") (EApp (EVar "importerReachIndex") (EVar "modules2"))) (DoLet false false (PVar "modules2'") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "dictPassModulesScoped") (EVar "mctx")) (EVar "idx")) (EVar "dictNames")) (EVar "promotedQ")) (EVar "importerReach")) (EVar "core2")) (EVar "modules2")) (EVar "modules2"))) (DoLet false false (PVar "r") (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "r") "evTable")) (EApp (EApp (EApp (EVar "servedEntriesFrom") (EVar "idx")) (EFieldAccess (EVar "r") "evBase")) (EFieldAccess (EFieldAccess (EVar "r") "evTable") "value")))) (DoExpr (ETuple (EVar "core2'") (EVar "modules2'")))))
(DTypeSig false "dictPassModulesScoped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "EvIndex") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "PredicateSlot")))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))))))))
(DFunDef false "dictPassModulesScoped" ((PVar "_mctx") PWild PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "dictPassModulesScoped" ((PVar "mctx") (PVar "idx") (PVar "dictNames") (PVar "promotedQ") (PVar "importerReach") (PVar "core2") (PVar "allModules") (PCons (PTuple (PVar "mid") (PVar "prog")) (PVar "rest"))) (EBlock (DoLet false false (PVar "importers") (EApp (EApp (EApp (EVar "transitiveImporters") (EVar "importerReach")) (EVar "mid")) (EVar "allModules"))) (DoLet false false (PVar "importerDecls") (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "importers"))) (DoLet false false (PVar "scope") (EBinOp "++" (EBinOp "++" (EVar "core2") (EVar "prog")) (EVar "importerDecls"))) (DoLet false false (PVar "scopeMods") (EApp (EApp (EVar "namesToSet") (EBinOp "::" (EVar "mid") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "importers")))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "setFunPredicateSlots") (EVar "mctx")) (EApp (EApp (EApp (EApp (EVar "selfDeclArities") (EVar "mid")) (EVar "prog")) (EVar "promotedQ")) (EBinOp "++" (EApp (EApp (EApp (EVar "aliasConstraintEntries") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "prog")) (EVar "promotedQ")) (EApp (EApp (EApp (EVar "scopePredicateSlots") (EVar "promotedQ")) (EVar "scopeMods")) (EVar "scope")))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funConstraintDeclaredRef")) (EListLit))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodPredicateSlotsRef")) (EApp (EApp (EVar "scopeMethodPredicateSlots") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "crossRun") "crossModuleMethodPredicateSlotsQualRef") "value")) (EVar "scopeMods")))) (DoExpr (EBinOp "::" (ETuple (EVar "mid") (EApp (EApp (EApp (EApp (EApp (EVar "dictPass") (EVar "mctx")) (EVar "idx")) (EVar "mid")) (EVar "dictNames")) (EVar "prog"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "dictPassModulesScoped") (EVar "mctx")) (EVar "idx")) (EVar "dictNames")) (EVar "promotedQ")) (EVar "importerReach")) (EVar "core2")) (EVar "allModules")) (EVar "rest"))))))
(DTypeSig false "scopePredicateSlots" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "PredicateSlot")))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "PredicateSlot"))))))))
(DFunDef false "scopePredicateSlots" ((PVar "promotedQ") (PVar "scopeMods") (PVar "scope")) (EBlock (DoLet false false (PVar "scopeNames") (EApp (EApp (EVar "namesToSet") (EApp (EVar "declTopFnNames") (EVar "scope"))) (EVar "omEmpty"))) (DoLet false false (PVar "nameInScope") (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "snd") (EApp (EVar "fst") (EVar "e")))) (EVar "scopeNames")))) (EVar "promotedQ"))) (DoLet false false (PVar "resolvedNames") (EApp (EApp (EVar "namesToSet") (EApp (EApp (EMethodRef "map") (ELam ((PVar "e")) (EApp (EVar "snd") (EApp (EVar "fst") (EVar "e"))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EApp (EVar "modInScope") (EApp (EVar "fst") (EApp (EVar "fst") (EVar "e")))) (EVar "scopeMods")))) (EVar "nameInScope")))) (EVar "omEmpty"))) (DoLet false false (PVar "inferredQ") (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EBinOp "||" (EApp (EApp (EVar "modInScope") (EApp (EVar "fst") (EApp (EVar "fst") (EVar "e")))) (EVar "scopeMods")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EApp (EVar "snd") (EApp (EVar "fst") (EVar "e")))) (EVar "resolvedNames")))))) (EVar "nameInScope"))) (DoLet false false (PVar "inferred") (EApp (EApp (EMethodRef "map") (ELam ((PVar "e")) (ETuple (EApp (EVar "snd") (EApp (EVar "fst") (EVar "e"))) (EApp (EVar "snd") (EVar "e"))))) (EVar "inferredQ"))) (DoLet false false (PVar "inferredNames") (EApp (EApp (EVar "namesToSet") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "inferred"))) (EVar "omEmpty"))) (DoLet false false (PVar "sigEntries") (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EVar "e"))) (EVar "inferredNames"))))) (EApp (EApp (EDictApp "flatMap") (EVar "constrainedSigPredicateSlots")) (EVar "scope")))) (DoExpr (EBinOp "++" (EVar "inferred") (EVar "sigEntries")))))
(DTypeSig true "selfDeclArities" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))))))
(DFunDef false "selfDeclArities" ((PVar "mid") (PVar "prog") (PVar "qual") (PVar "bare")) (EIf (EBinOp "==" (EVar "mid") (ELit (LString ""))) (EVar "bare") (EBlock (DoLet false false (PVar "own") (EApp (EApp (EVar "namesToSet") (EApp (EVar "declTopFnNames") (EVar "prog"))) (EVar "omEmpty"))) (DoExpr (EBinOp "++" (EApp (EApp (EApp (EVar "selfQualEntries") (EVar "mid")) (EVar "own")) (EVar "qual")) (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EVar "e"))) (EVar "own"))))) (EVar "bare")))))))
(DTypeSig false "selfQualEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyVar "a"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a")))))))
(DFunDef false "selfQualEntries" ((PVar "mid") (PVar "own") (PVar "qual")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "e")) (ETuple (EApp (EVar "snd") (EApp (EVar "fst") (EVar "e"))) (EApp (EVar "snd") (EVar "e"))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "fst") (EApp (EVar "fst") (EVar "e"))) (EVar "mid")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "snd") (EApp (EVar "fst") (EVar "e")))) (EVar "own"))))) (EVar "qual"))))
(DTypeSig false "scopeMethodPredicateSlots" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")))))))
(DFunDef false "scopeMethodPredicateSlots" ((PVar "promotedMQ") (PVar "scopeMods")) (EBlock (DoLet false false (PVar "resolvedNames") (EApp (EApp (EVar "namesToSet") (EApp (EApp (EMethodRef "map") (ELam ((PVar "e")) (EApp (EVar "snd") (EApp (EVar "fst") (EVar "e"))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EApp (EVar "modInScope") (EApp (EVar "fst") (EApp (EVar "fst") (EVar "e")))) (EVar "scopeMods")))) (EVar "promotedMQ")))) (EVar "omEmpty"))) (DoLet false false (PVar "kept") (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EBinOp "||" (EApp (EApp (EVar "modInScope") (EApp (EVar "fst") (EApp (EVar "fst") (EVar "e")))) (EVar "scopeMods")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EApp (EVar "snd") (EApp (EVar "fst") (EVar "e")))) (EVar "resolvedNames")))))) (EVar "promotedMQ"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "e")) (ETuple (EApp (EVar "snd") (EApp (EVar "fst") (EVar "e"))) (EApp (EVar "snd") (EVar "e"))))) (EVar "kept")))))
(DTypeSig false "modInScope" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyCon "Bool"))))
(DFunDef false "modInScope" ((PVar "mid") (PVar "scopeMods")) (EBinOp "||" (EBinOp "==" (EVar "mid") (ELit (LString ""))) (EApp (EApp (EVar "omHasKey") (EVar "mid")) (EVar "scopeMods"))))
(DTypeSig false "transitiveImporters" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))
(DFunDef false "transitiveImporters" ((PVar "reach") (PVar "mid") (PVar "modules")) (EApp (EApp (EVar "filterList") (ELam ((PVar "p")) (EBinOp "&&" (EBinOp "/=" (EApp (EVar "fst") (EVar "p")) (EVar "mid")) (EApp (EApp (EVar "omHasKey") (EVar "mid")) (EApp (EApp (EVar "optionOr") (EVar "omEmpty")) (EApp (EApp (EVar "omLookup") (EApp (EVar "fst") (EVar "p"))) (EVar "reach"))))))) (EVar "modules")))
(DTypeSig false "constrainedSigPredicateSlots" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "PredicateSlot"))))))
(DFunDef false "constrainedSigPredicateSlots" ((PCon "DTypeSig" PWild (PVar "n") (PVar "ty") PWild)) (EIf (EApp (EVar "isConstrainedTy") (EVar "ty")) (EListLit (ETuple (EVar "n") (EApp (EApp (EMethodRef "map") (EVar "sigPredicateSlot")) (EApp (EVar "sigConstraints") (EVar "ty"))))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "constrainedSigPredicateSlots" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "constrainedSigPredicateSlots") (EVar "d")))
(DFunDef false "constrainedSigPredicateSlots" (PWild) (EListLit))
(DTypeSig false "sigPredicateSlot" (TyFun (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "PredicateSlot")))
(DFunDef false "sigPredicateSlot" ((PTuple (PVar "iface") PWild)) (ERecordCreate "PredicateSlot" ((fa "psIface" (EVar "iface")) (fa "psArgs" (EVar "PSArgsUnknown")) (fa "psBoundIds" (EListLit)))))
