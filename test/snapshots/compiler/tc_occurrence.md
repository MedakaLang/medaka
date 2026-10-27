# META
source_lines=3820
stages=DESUGAR,MARK
# SOURCE
-- tc_occurrence: method, operator and literal occurrence inference and dispatch-site recording
-- (including `recordShadowStandaloneObls`), evidence-site minting, the mark pass over binding
-- groups and the write-back of its marked clauses over the declarations
-- (`rebuildGroupDecls`), the constrained-signature set, and the test-only evidence-cell and
-- method-return probes (the `cellGoalInnerAliasing` family, `cellStoreMisses`, the
-- `methodRow*Probe` and `methodReturn*Probe` rows).
--
-- Spec: DICT section 4 (occurrence half), section 5, section 8 I7; SHADOW S2-DECL.
--
-- Placement: declarations are placed by R1-R6 of the Phase 4 module table,
-- compiler/ARCHITECTURE-PLAYBOOK.md section 6.
-- Closure rule: this module may not import `types.typecheck`, nor any of `tc_groups`, `tc_pat`,
-- `tc_infer_records`, `tc_infer`, `tc_elab`, `tc_global`, `tc_module`.

import types.tc_types.{
  SiteKind(..),
  OblProjection(..),
  NumericPredicateTraceStage(..),
  MethodReturnTraceStage(..),
  GoalPayload(..),
  EvDest(..),
  BuiltinClass(..),
  EvCell(..),
  GoalKind(..),
  GraphCtx(..),
  MarkSets(..),
  MethodPredicateTemplate(..),
  MethodReturnRequest(..),
  MethodReturnResolution(..),
  MethodRowTestObservation(..),
  Obligation(..),
  PendingDictApp(..),
  PendingMethodDict(..),
  Predicate(..),
  PredicateSlot(..),
  PredicateSlotArgs(..),
  Provenance(..),
  SelectedValueOccurrence(..),
  SiteCell(..),
  UObligation(..),
  ArgRw,
  CDeclared,
  CSlot,
  MarkCtx,
  MethodInstantiationSubst,
  MethodPredicateSlot,
  MethodSchemeRow,
  MethodTrackedInstantiation,
  ModuleCtx,
  ModuleMarking,
  PendingEntry,
  PreludeMarkFacts,
  RecDictApp,
  ScopedMember,
  ShadowDicts,
  siteFor,
  TcEnv,
  ValueScheme,
}
import types.tc_mono.{
  allMethodParamsMentioned,
  argMentions,
  funArity,
  isBareTyvarMono,
  isMonoScheme,
  matchTyMono,
  nthFunDomain,
  patVarsListTc,
  patVarsTc,
  propParamNamesTc,
  rootIdOf,
  sameRootId,
  schemeBodyOf,
  schemeIds,
  stripArrows,
  stripTyConstraints,
  substMono,
  tconBuiltin,
  tconUnresolved,
  tupleMono,
  tyVarNames,
}
import types.tc_state.{
  carryModuleCtx,
  currentScopeStore,
  emptyMethodEnv,
  envAt,
  freshGraphRun,
  freshSubRecordsOf,
  initialModuleCtx,
  probeGraphCtx,
  wAll,
  wPush,
}
import types.tc_env.{
  bindingDeclared,
  buildFlatImplEnv,
  buildImplUniverse,
  builtinIfaceRef,
  declEnvModule,
  dispatchTyparams,
  envFor,
  extendMethodRow,
  extendVar,
  hasImportDefiner,
  lookupLocalFlag,
  lookupMethodRow,
  lookupVar,
  methodArgs,
  methodEnvGo,
  methodRowSameNameView,
  methodRowTestConstantDecl,
  methodRowTestConstraint,
  methodRowTestFoldMapDecl,
  methodRowTestIface,
  methodRowTestNum,
  methodRowTestSameA,
  methodRowTestSameB,
  methodRowTestUserFromInt,
  methodSlotKey,
  originMethodName,
  standaloneValueFor,
}
import types.tc_scope.{
  admittedIfaceWord,
  aliasDictNames,
  argDispatchOf,
  methodAdmittedHere,
  methodDispatchIdx,
  methodEntryHere,
  methodIfaceHere,
}
import types.tc_unify.{
  captureScope,
  declaredCrossModuleObls,
  forceInstantiation,
  freshVar,
  instantiateLegacyVarTracked,
  instantiateMethodTracked,
  instantiateTracked,
  instantiateValueTracked,
  lookupQualPayload,
  lookupSchemeObls,
  openRow,
  qualConstraintDecl,
  qualConstraintKey,
  recordObl,
  recordOblAt,
  recordSchemeCallObligations,
  unify,
  unifyIn,
  zipSlotVecs,
}
import types.tc_decls_types.{fromAstType}
import types.tc_decls.{
  constraintIface,
  constraintIsMethodLevel,
  constraintVarNames,
  ifaceMethodSchemeRows,
  methodRowNumObservation,
}
import types.tc_solve_givens.{predicateSlotIds, predicateSlotIdsAt}
import types.tc_solve_entail.{noteNumericPredicateTrace}
import types.tc_solve.{
  builtinClassPresent,
  consSiteFn,
  goalKindName,
  isLocalAbsName,
  localSourceName,
  methodPredicateTemplateHasAbsent,
  methodReturnArgs,
  methodReturnProbeGoalIfaces,
  methodReturnProbeIface,
  methodReturnProbeImpl,
  methodReturnProbeOblIfaces,
  methodReturnProbeOccurrence,
  methodReturnProbeScope,
  methodReturnProbeSpelling,
  methodReturnResolutionValid,
  methodReturnSelectedIdentity,
  methodRowRegistrySlotIds,
  methodSlotArgumentIds,
  methodSlotBoundIds,
  methodSlotIdsAtPositions,
  methodSlotPositions,
  noteMethodReturnTrace,
  numAnchorObservationView,
  pushDictApp,
  pushGoal,
  returnPosMethodNames,
  routeLocalSym,
  solveExactReturnOnce,
}
import types.tc_solve_check.{
  checkCallObligationsU, dedupSlotVecs, dispatchMonosOf
}
import types.tc_shadow.{
  buildStandaloneShadowsGraph,
  callArgVecsV,
  computeMangledShadowMap,
  constraintMonosOf,
  coreShadowMapFor,
  declaredConstraintFor,
  declaredEffectsAt,
  isDefinerShadow,
  isShadowStandalone,
  methodCellLookup,
  rejectAdmittedValueOccurrence,
  shadowDeclaredFor,
  shadowStandaloneDictSlots,
  shadowStandaloneDictSlotsAt,
  standaloneValueBinding,
  standaloneValueBindingEmit,
  standaloneValuePinned,
}
import types.tc_effects.{
  clausesOf,
  evOrdinal,
  grantNameIn,
  recordMethodGrantOcc,
  recordStandaloneGrantOcc,
}
import frontend.ast.{
  Section(..),
  Arm(..),
  Constraint(..),
  Decl(..),
  DoStmt(..),
  EvId(..),
  Expr(..),
  FieldAssign(..),
  FunClause(..),
  Guard(..),
  GuardArm(..),
  IfaceMethod(..),
  ImplMethod(..),
  InterpPart(..),
  LetBind(..),
  Loc(..),
  MethodDefault(..),
  Pat(..),
  Route(..),
  Ty(..),
  isUnminted,
  negateLiteral,
  tyConBuiltin,
}
import types.solver_contract.{SolverOutcome(..), ClassPredicate(..), Wanted(..)}
import types.repr.{
  IfaceRef(..), Mono(..), Scheme(..), lookupAssocI, normalize, ppMono
}
import types.evidence_complete.{Inner(..), innerNone}
import types.evidence.{
  SolverEvidence(..),
  PrerequisiteEvidence(..),
  RequestInstanceId(..),
  ScopeId(..),
}
import support.ordmap.{
  omEmpty, omFromNames, omHasKey, omInsert, omLookup, OrdMap
}
import support.util.{
  allList,
  anyList,
  contains,
  dedup,
  filterList,
  isEmptyL,
  isNonEmptyL,
  isSome,
  listLen,
  lookupAssoc,
  reverseL,
}
import types.chain_key.{constrainedSigName}
import list.{get, reverse}
import support.char.{isUpper}
import types.publish.{tcCode}
import map as IdMap
import types.scopes as Scopes

siteObligation : GoalKind -> Ref Inner -> PendingEntry -> Obligation
siteObligation k inner (PendingEntry name tagRef m encl site loc scope ev) = Obligation {
  oKind = k,
  oDest = EvRoute tagRef,
  oEv = ev,
  oEncl = encl,
  oLoc = loc,
  oScope = scope,
  oPayload = GPSite name m site,
  oInner = inner,
}

-- [inner] is the destination's summary: the method cell's `ecInner` when [e]'s route
-- ref is a cell's, a fresh one otherwise.
export
pushSiteGoal : GraphCtx -> GoalKind -> Ref Inner -> PendingEntry -> Unit
pushSiteGoal gctx k inner e = pushGoal gctx (siteObligation k inner e)

-- an arithmetic operator site: only its operand mono and its route cell
pushArithGoal : ModuleCtx -> Ref Route -> Mono -> EvId -> Unit
pushArithGoal mctx dref m ev = pushGoal mctx.mcGraph Obligation {
  oKind = GKArithSite,
  oDest = EvRoute dref,
  oEv = ev,
  oEncl = "",
  oLoc = None,
  oScope = captureScope mctx (),
  oPayload = GPArith m,
  oInner = Ref innerNone,
}

pushMethodDictGoal : GraphCtx -> PendingMethodDict -> Unit
pushMethodDictGoal gctx pmd = pushGoal gctx Obligation {
  oKind = GKMethodDict,
  oDest = EvRoutes pmd.pmdRoutesRef,
  oEv = pmd.pmdEv,
  oEncl = pmd.pmdEncl,
  oLoc = None,
  oScope = pmd.pmdScope,
  oPayload = GPMethodDict pmd,
  oInner = pmd.pmdInner,
}

pushRecDictAppGoal : GraphCtx -> RecDictApp -> Unit
pushRecDictAppGoal gctx (r@(RecDictApp routesRef _ encl _ scope ev)) = pushGoal
  gctx
  Obligation {
    oKind = GKRecDictApp,
    oDest = EvRoutes routesRef,
    oEv = ev,
    oEncl = encl,
    oLoc = None,
    oScope = scope,
    oPayload = GPRecDictApp r,
    oInner = Ref innerNone,
  }

-- The one and only way to add an obligation.  #991: this channel now stores the SAME
-- `UObligation` record the call channel does, with a real `Provenance` and an
-- `OpMethodOcc` projection carrying the (typarams, declared method type, occurrence
-- mono) triple the check-time `dispatchMonosOf` needs (see `OblProjection`).  The
-- pre-#838 5-tuple, and the `implOblToU` bridge that converted it, are gone.
pushPendingObl : ModuleCtx ->
  IfaceRef ->
  List String ->
  Ty ->
  Mono ->
  List (String, Mono) ->
  Provenance ->
  Option Loc ->
  Unit
pushPendingObl mctx iface typarams mty occ omitted prov loc =
  wPush
    mctx.mcCells.implObls
    (mkMethodOccObl
      iface
      typarams
      mty
      occ
      omitted
      prov
      loc
      (captureScope mctx ()))

pushExactReturnObl : ModuleCtx -> MethodReturnRequest -> Unit
pushExactReturnObl mctx request = wPush mctx.mcCells.implObls UObligation {
  pred = Predicate { iface = request.mrrIface, args = [] },
  originId = 0,
  prov = PMethodOcc,
  loc = request.mrrLoc,
  uoScope = request.mrrScope,
  oblProj = OpExactReturn request,
}

methodReturnRequest : ModuleCtx ->
  MethodSchemeRow ->
  Mono ->
  MethodInstantiationSubst ->
  Option EvId ->
  MethodReturnRequest
methodReturnRequest mctx row occurrence subst goalEv =
  let loc = mctx.mcLoc
  let scope = captureScope mctx ()
  let qualifiedBody = match row.msrScheme
    Forall _ _ _ _ _ body =>
      substMono
        mctx.mcGraph
        subst.misTypeSubst
        subst.misEffectSubst
        subst.misAuthSubst
        body
  let omitted =
    if methodPredicateTemplateHasAbsent row.msrPredicateTemplate then
      omittedParamVars mctx row.msrTyparams row.msrType
    else
      []
  MethodReturnRequest {
    mrrIface = row.msrIface,
    mrrName = row.msrName,
    mrrTyparams = row.msrTyparams,
    mrrType = row.msrType,
    mrrOccurrence = occurrence,
    mrrEnclosing = mctx.mcCells.currentFn.value,
    mrrLoc = loc,
    mrrScope = scope,
    mrrGoalEv = goalEv,
    mrrQualifiedBody = qualifiedBody,
    mrrPredicateTemplate =
      instantiateMethodPredicateTemplate
        mctx.mcGraph
        row.msrPredicateTemplate
        subst,
    mrrOmitted = omitted,
    mrrResolution = Ref None,
  }

-- the mint for an impl-channel obligation.  `pred.args` is EMPTY and must stay so:
-- the dispatch vector is `OpMethodOcc`'s to project, at check time, via `uOblArgs`.
export
mkMethodOccObl : IfaceRef ->
  List String ->
  Ty ->
  Mono ->
  List (String, Mono) ->
  Provenance ->
  Option Loc ->
  ScopeId ->
  UObligation
mkMethodOccObl iface typarams mty occ omitted prov loc scope = UObligation {
  pred = Predicate { iface = iface, args = [] },
  originId = 0,
  prov = prov,
  loc = loc,
  uoScope = scope,
  oblProj = OpMethodOcc typarams mty occ omitted,
}

pushNumLitObl : ModuleCtx ->
  ClassPredicate ->
  Mono ->
  Option Loc ->
  ScopeId ->
  Unit
pushNumLitObl mctx predicate occurrence loc scope = wPush
  mctx.mcCells.implObls
  UObligation {
    pred = Predicate {
      iface = predicate.predicateInterface,
      args = predicate.predicateArguments,
    },
    originId = 0,
    prov = PNumLit,
    loc = loc,
    uoScope = scope,
    oblProj = OpNumLit occurrence,
  }

hasPredicateSlots : String -> OrdMap (List PredicateSlot) -> Bool
hasPredicateSlots k idx = omHasKey k idx

-- the dispatch-index registry: each interface method → index of its first arg
-- mentioning the interface typaram.  Methods with NO such arg (return-position)
-- contribute nothing.  Computed structurally from interface decls.
export
argDispatchIndices : List Decl -> List (String, Int)
argDispatchIndices prog = flatMap argDispatchOfDecl prog

argDispatchOfDecl : Decl -> List (String, Int)
argDispatchOfDecl (DAttrib _ d) = argDispatchOfDecl d
argDispatchOfDecl (DInterface { typarams, methods, ... }) =
  flatMap (argDispatchOfMethod typarams) methods
argDispatchOfDecl _ = []

argDispatchOfMethod : List String -> IfaceMethod -> List (String, Int)
argDispatchOfMethod typarams (IfaceMethod mname mty _ _) =
  match firstDispatchIdx (dispatchTyparams typarams) 0 (methodArgs mty)
    Some i => [(mname, i)]
    None => []

-- #1351 L1 (EXPAND): the IDENTITY-CARRYING sibling of `argDispatchIndices` above.  Same
-- walk, same arms, same `firstDispatchIdx` classification — the ONLY difference is the
-- key: `(IfaceRef, method name)` instead of the bare method name.  `IfaceRef` is this
-- file's existing module-qualified interface identity (`irName` spelling + `irOrigin` I4
-- identity); it is already minted at the peer population site
-- `methodRowsInto` out of the SAME two `DInterface` fields, so this adds
-- no new notion of identity, only a second key-shape for an existing one.
--
-- Readers: its result is installed into `GraphCtx.argDispatchIdxByIdRef` by the
-- two drivers, and `argDispatchOf` reads that ref through `dispatchIdxScoped` (L3
-- MIGRATE, landed).  Derive the set — `grep -n argDispatchIdxByIdRef` — rather than
-- trusting a list here.
--
-- Purity note, load-bearing for L1's zero-behaviour-change property:
-- `argDispatchIndices` and everything it reaches (`argDispatchOfDecl`,
-- `argDispatchOfMethod`, `dispatchTyparams`, `firstDispatchIdx`, `argMentions`,
-- `methodArgs`) is pure and structural, so running this second walk beside it advances
-- no counter, mints no id and registers nothing.  The scheme-bearing method-row walk is
-- intentionally effectful and therefore constructs identity and scheme together.
export
argDispatchIndicesById : List Decl -> List ((IfaceRef, String), Int)
argDispatchIndicesById prog = flatMap argDispatchOfDeclById prog

argDispatchOfDeclById : Decl -> List ((IfaceRef, String), Int)
argDispatchOfDeclById (DAttrib _ d) = argDispatchOfDeclById d
argDispatchOfDeclById (DInterface { name, typarams, methods, ifaceOrigin, ... }) =
  flatMap
    (argDispatchOfMethodById
      IfaceRef { irName = name, irOrigin = ifaceOrigin }
      typarams)
    methods
argDispatchOfDeclById _ = []

argDispatchOfMethodById : IfaceRef ->
  List String ->
  IfaceMethod ->
  List ((IfaceRef, String), Int)
argDispatchOfMethodById iface typarams (IfaceMethod mname mty _ _) =
  match firstDispatchIdx (dispatchTyparams typarams) 0 (methodArgs mty)
    Some i => [((iface, mname), i)]
    None => []

firstDispatchIdx : List String -> Int -> List Ty -> Option Int
firstDispatchIdx _ _ [] = None
firstDispatchIdx typarams i (ty :: rest)
  | argMentions typarams ty = Some i
  | otherwise = firstDispatchIdx typarams (i + 1) rest

-- D3a: queue an arg-position occurrence's route ref for stamping, keyed on the
-- inferred type of its discriminating argument (the dispatch-position arg mono).
-- The cell is read later (resolveArgStamps), once inference has solved it.  D3b-1:
-- also carry [name] + the impl-dicts ref so a concrete-head site can thread the
-- element dict for a parametric `requires` impl.  [suppressed] is the caller's
-- `dcSuppressArgStamp`: a definer-shadow application head records its argument
-- itself.
recordArgStamp : ModuleCtx ->
  Bool ->
  String ->
  Ref Route ->
  Ref (List Route) ->
  Ref Inner ->
  Int ->
  Mono ->
  List (String, Mono) ->
  Unit
recordArgStamp mctx suppressed name tagRef implRef innerRef idx mono omitted
  | suppressed = ()
  | otherwise = match nthFunDomain idx mono
    Some am =>
      pushSiteGoal
        mctx.mcGraph
        GKArgStamp
        innerRef
        (PendingEntry
          name
          tagRef
          am
          mctx.mcCells.currentFn.value
          (SKArg implRef mono omitted)
          mctx.mcLoc
          (captureScope mctx ())
          (freshEvId mctx ()))
    None => ()

-- Cause-A prerequisite: an ARG-position method occurrence's discriminating-arg
-- mono, keyed by the enclosing fn (currentFn), pushed into methodSiteFns — the
-- arg-position analogue of recordSite's return-position push.  inferredConstraintIds
-- reads methodSiteFns to discover the enclosing fn's INFERRED constraint, so this
-- lets `f s = display s` promote `f` to a dict-passed fn (it had no signature, so
-- the constraint is inferred, not declared).  Idx-th arg mono = the receiver whose
-- (constraint) tyvar must be discovered.
recordArgSiteFn : ModuleCtx -> String -> Int -> Mono -> Unit
recordArgSiteFn mctx _ idx mono = match nthFunDomain idx mono
  Some am =>
    mctx.mcCells.methodSiteFns :=
      consSiteFn
        mctx.mcCells.currentFn.value
        am
        mctx.mcCells.methodSiteFns.value
  None => ()

-- #2705: mint the cells for one `EMethodAt` node and return the id the node
-- carries.  [seed] is the pre-pass seed (the mangled definer-shadow symbol, or
-- ""): a non-empty seed becomes the `RLocal <seed> []` fallback the stampers and
-- every seed reader (`routeLocalSym`) expect to find on the dispatch cell.
mintMethodCell : ModuleCtx -> String -> EvId
mintMethodCell mctx seed =
  mintMethodCellRaw
    mctx
    ""
    None
    (if seed == "" then RNone else RLocal seed [])
    []

export
mintMethodCellRaw : ModuleCtx ->
  String ->
  Option Int ->
  Route ->
  List Route ->
  EvId
mintMethodCellRaw mctx iface arity tag impls =
  let ev = freshEvId mctx ()
  let g = mctx.mcGraph.graphRun
  let i = evOrdinal ev - g.evBase
  let arr = indexWithSlot g.evCells i
  -- An occupied slot would mean two nodes minted under one ordinal — the same
  -- collision `fillEvidence` refuses at publish time — and a memo restore that
  -- rewound the counter without rewinding this index is the one way to reach it.
  -- Fail closed here, where the second mint happens, rather than at publish.
  match arrayGetUnsafe i arr
    None => ()
    Some _ => panic "method cell #\{intToString (evOrdinal ev)} minted twice"
  arraySetUnsafe
    i
    (Some EvCell {
      ecId = ev,
      ecIface = Ref iface,
      ecArity = Ref arity,
      ecTag = Ref tag,
      ecImpl = Ref impls,
      ecMeth = Ref [],
      ecLoc = Ref None,
      ecName = Ref "",
      ecInner = Ref innerNone,
    })
    arr
  ev

-- The array [index] holds, grown by doubling until slot [i] exists.
indexWithSlot : Ref (Array (Option a)) -> Int -> Array (Option a)
indexWithSlot index i =
  let arr0 = index.value
  if i < arrayLength arr0 then
    arr0
  else
    let grown = arrayMake (max 16 (2 * (i + 1))) None
    arrayBlit arr0 0 grown 0 (arrayLength arr0)
    index := grown
    grown

-- Mint the cell for one operator site, starting unrouted, and return its id.
mintOpSite : ModuleCtx -> Unit -> EvId
mintOpSite mctx _ = mintSite mctx (OpSite (Ref RNone))

-- Mint the cells for one numeric literal site: an unset float and an unrouted
-- `fromInt` route.
mintLitSite : ModuleCtx -> Unit -> EvId
mintLitSite mctx _ = mintSite mctx (LitSite (Ref None) (Ref RNone))

-- Mint the cell for one field access or record update, starting with the unknown
-- head "".
mintHeadSite : ModuleCtx -> Unit -> EvId
mintHeadSite mctx _ = mintSite mctx (HeadSite (Ref ""))

-- [ev] if it already has a site, else a freshly minted one: a body re-marked after
-- inference keeps the ids inference wrote through.
mintedOr : (Unit -> EvId) -> EvId -> EvId
mintedOr mint ev = if isUnminted ev then mint () else ev

mintSite : ModuleCtx -> SiteCell -> EvId
mintSite mctx cell =
  let ev = freshEvId mctx ()
  let g = mctx.mcGraph.graphRun
  let i = evOrdinal ev - g.evBase
  let arr = indexWithSlot g.siteCells i
  match arrayGetUnsafe i arr
    None => arraySetUnsafe i (Some (ev, cell)) arr
    Some _ => panic "site cell #\{intToString (evOrdinal ev)} minted twice"
  ev

-- The cell minted for site [ev].  Inference reaching a site the mark pass never
-- visited is a gap in marking coverage, so it panics rather than writing a cell no
-- reader would find.
siteCellOf : GraphCtx -> EvId -> SiteCell
siteCellOf gctx ev = match siteCellLookup gctx ev
  Ok c => c
  Err message => panic message

-- `siteCellOf`'s answer, or the reason it has none.
siteCellLookup : GraphCtx -> EvId -> Result String SiteCell
siteCellLookup gctx ev =
  let (EvId m n) = ev
  let g = gctx.graphRun
  let i = n - g.evBase
  let arr = g.siteCells.value
  if isUnminted ev then
    Err "site reached inference unminted"
  else if i < 0 then
    Err "site cell \{m}#\{intToString n} is from an earlier graph"
  else if i >= arrayLength arr then
    Err "site cell \{m}#\{intToString n} was never minted"
  else match arrayGetUnsafe i arr
    Some (_, c) => Ok c
    None => Err "site cell \{m}#\{intToString n} was never minted"

-- The route cell of operator or literal site [ev].
export
siteRouteCell : GraphCtx -> EvId -> Ref Route
siteRouteCell gctx ev = match siteCellOf gctx ev
  OpSite r => r
  LitSite _ r => r
  HeadSite _ => notAnOpSite ev

-- The resolved-record-head cell of field access or record update site [ev].
export
siteHeadCell : GraphCtx -> EvId -> Ref String
siteHeadCell gctx ev = match siteCellOf gctx ev
  HeadSite h => h
  OpSite _ => notAnOpSite ev
  LitSite _ _ => notAnOpSite ev

-- The defaulted-float cell of numeric literal site [ev].
siteFloatCell : GraphCtx -> EvId -> Ref (Option Float)
siteFloatCell gctx ev = match siteCellOf gctx ev
  LitSite f _ => f
  OpSite _ => notAnOpSite ev
  HeadSite _ => notAnOpSite ev

notAnOpSite : EvId -> a
notAnOpSite ev =
  panic
    "site cell \{evIdModule ev}#\{intToString (evOrdinal ev)} is not an operator site"

-- #2549 M2: the next evidence id for the module currently being inferred.  The
-- module component comes from the module's record, which `checkBodyImpl` mints once per
-- module before any body of it is inferred; the ordinal is this run's counter.
-- `evCounter` is graph-global, and `graphLineageRun` carries it across every new
-- lineage, so the ordinal alone is what makes an id unique; the module half does not
-- scope it, and `evDictRoutesIn` indexes on the ordinal without consulting it.
-- The module half is a tripwire for that lookup (see `EvId` in `frontend/ast.mdk`):
-- do not make ordinals per-module in the belief that the pair still separates them.
export
freshEvId : ModuleCtx -> Unit -> EvId
freshEvId mctx _ =
  let g = mctx.mcGraph.graphRun
  let n = g.evCounter.value
  g.evCounter := n + 1
  EvId mctx.mcCells.currentModuleRef.value n

-- The ONE numlit write, so the channel and its counter cannot drift apart.
pushNumlit : GraphCtx -> (Mono, Ref (Option Float), Int, Ref Route) -> Unit
pushNumlit gctx e =
  let g = gctx.graphRun
  g.numlitRefs := e :: g.numlitRefs.value
  g.numlitN := g.numlitN.value + 1

-- Spelled like a data constructor: uppercase-initial, or a mangled `<mid>__<Ctor>`
-- whose segment after the FIRST `__` is uppercase-initial (`private_mangle` joins
-- with one `__`, and a module id never contains one).  A spelling pre-filter only;
-- `lookupCtor` decides.
export
ctorHeadShaped : String -> Bool
ctorHeadShaped name =
  let cs = stringToChars name
  let n = arrayLength cs
  n > 0 && (isUpper (arrayGetUnsafe 0 cs) || mangledCtorShaped cs n 0)

mangledCtorShaped : Array Char -> Int -> Int -> Bool
mangledCtorShaped cs n i
  | i + 2 >= n = False
  | arrayGetUnsafe i cs == '_'
    && arrayGetUnsafe (i + 1) cs == '_'
    && isUpper (arrayGetUnsafe (i + 2) cs) = True
  | otherwise = mangledCtorShaped cs n (i + 1)

export
bindingDeclaredAt : TcEnv ->
  String ->
  MethodTrackedInstantiation ->
  Option CDeclared
bindingDeclaredAt env name inst =
  declaredEffectsAt env.teDyn.dcModule.mcGraph inst (bindingDeclared env name)

recordDeclaredBindingCall : ModuleCtx -> CDeclared -> List (Int, Mono) -> Unit
recordDeclaredBindingCall mctx dc subst =
  let expanded = dedupSlotVecs (zipSlotVecs dc.cdSlots dc.cdArgs)
  recordCallObligations
    mctx
    (map fst expanded)
    (constraintMonosOf (map (pair => (fst pair).csId) expanded) subst)
    (callArgVecsV mctx.mcGraph expanded subst)

-- a method occurrence.  Return-position: record (routeRef, result mono) so
-- resolveSites can stamp RKey/RDict.  D3a arg-position (name in
-- argDispatchIdxByIdRef): the dispatch is decided by the DISCRIMINATING-ARGUMENT type,
-- not the result, so queue recordArgStamp on the arg-position mono instead — it is
-- NOT a pendingSites/methodSiteFns return-position site.
inferMethodAt : TcEnv ->
  String ->
  Ref String ->
  Ref (Option Int) ->
  Ref Route ->
  Ref (List Route) ->
  Ref (List Route) ->
  Ref Inner ->
  Mono

export
inferMethodAtCell : TcEnv -> String -> EvCell -> Mono
inferMethodAtCell env name c =
  let st = env.teDyn.dcModule.mcGraph.graphRun.grants
  st.gsLastMethodInst := None
  st.gsLastStandalone := None
  c.ecLoc := env.teDyn.dcModule.mcLoc
  c.ecName := name
  let t =
    inferMethodAt
      env
      name
      c.ecIface
      c.ecArity
      c.ecTag
      c.ecImpl
      c.ecMeth
      c.ecInner
  match (st.gsLastStandalone.value, st.gsLastMethodInst.value)
    (Some (scheme, subst), _) =>
      recordStandaloneGrantOcc
        env.teDyn.dcModule
        name
        c.ecId
        scheme
        subst
        (optionOr 0 c.ecArity.value)
    (None, Some (scheme, subst)) =>
      recordMethodGrantOcc env.teDyn.dcModule name c.ecId scheme subst
    (None, None) => ()
  t

-- #2705: a standalone-shadow occurrence (a user fn spelled like an interface
-- method — `add x y = x + y` beside `Num`'s `add`) denotes the standalone, whose
-- scheme may carry an inferred or declared context.  Instantiate that context as
-- call obligations exactly as the plain-`EVar` path does
-- (`instantiateVarTrackedId`), so the verdict — `No impl of Num for String` on
-- `add "a" "b"` — is the obligation channel's on every driver, not something the
-- check pass supplies for the emit pass.  The shadow-dict recorders beside this
-- carry SLOTS only; obligations were never theirs.  MEASURED: without this,
-- marking the check drivers let that program through at exit 0.
-- A non-shadow method occurrence records nothing here: `lookupSchemeObls` keys by
-- binding name and a method is not a binding, and the cross-module store is only
-- consulted behind the same shadow gate.
recordShadowStandaloneObls : TcEnv -> String -> List (Int, Mono) -> Unit
recordShadowStandaloneObls env name subst
  | isDefinerShadow env.teDyn.dcModule name
    || isShadowStandalone
      env
      name =
    match (lookupSchemeObls
      name
      0
      env.teDyn.dcModule.mcCells.schemeObligationsRef.value)
      Some obs => recordSchemeCallObligations env.teDyn.dcModule 0 obs subst
      None => match declaredCrossModuleObls env.teDyn.dcModule name
        Some obs => recordSchemeCallObligations env.teDyn.dcModule 0 obs subst
        None => ()
  | otherwise = ()

inferMethodAt env name ifaceRef arityRef tagRef implRef methodRef innerRef =
  let selected = match standaloneValueBinding env name
    Some scheme => Some scheme
    None => standaloneValueBindingEmit env name tagRef
  match selected
    Some value =>
      rejectAdmittedValueOccurrence env.teDyn.dcModule name
      let sym = routeLocalSym !tagRef
      let occurrence =
        instantiateStandaloneOccurrence
          env
          name
          sym
          env.teDyn.dcModule.mcLoc
          value
      let inst = occurrence.svoInstance
      let dicts = occurrence.svoDicts
      env.teDyn.dcModule.mcGraph.graphRun.grants.gsLastStandalone :=
        Some (occurrence.svoScheme, inst.mtiSubstitution.misAuthSubst)
      arityRef := Some (funArity inst.mtiBody)
      let receiver = match methodDispatchIdx env.teDyn.dcModule name
        Some idx => optionOr inst.mtiBody (nthFunDomain idx inst.mtiBody)
        None => inst.mtiBody
      pushSiteGoal
        env.teDyn.dcModule.mcGraph
        GKRLocalSite
        innerRef
        (PendingEntry
          name
          tagRef
          receiver
          env.teDyn.dcModule.mcCells.currentFn.value
          (SKRLocal sym True dicts.sdMonos dicts.sdIfaces dicts.sdArgVecs)
          env.teDyn.dcModule.mcLoc
          (captureScope env.teDyn.dcModule ())
          (freshEvId env.teDyn.dcModule ()))
      inst.mtiBody
    None =>
      inferMethodCandidateAt
        env
        name
        ifaceRef
        arityRef
        tagRef
        implRef
        methodRef
        innerRef

-- Selection precedes instantiation: the returned value, forcing row, obligations,
-- and route slots above share one occurrence's substitution. A discarded method
-- candidate must not supply a standalone value's receiver or dictionary cells.
inferMethodCandidateAt : TcEnv ->
  String ->
  Ref String ->
  Ref (Option Int) ->
  Ref Route ->
  Ref (List Route) ->
  Ref (List Route) ->
  Ref Inner ->
  Mono
inferMethodCandidateAt env name ifaceRef arityRef tagRef implRef methodRef innerRef =
  match lookupVar env name
    -- Routed standalone recovery already ran before candidate selection.
    None => panic ("unbound method: " ++ name)
    Some s =>
      let inst = instantiateMethodTracked env.teDyn.dcModule s
      let occurrence = inst.mtiBody
      let subst = inst.mtiSubstitution
      env.teDyn.dcModule.mcGraph.graphRun.grants.gsLastMethodInst :=
        Some (s, subst.misAuthSubst)
      arityRef := Some (funArity occurrence)
      ifaceRef := admittedIfaceWord env.teDyn.dcModule name
      recordRLocalSite env name tagRef innerRef occurrence
      let ret = match argDispatchOf env.teDyn.dcModule name
        Some idx =>
          recordMethodDicts
            env.teDyn.dcModule
            name
            methodRef
            innerRef
            subst.misTypeSubst
          -- One variable per omitted typaram, shared by the goal and the route.
          let omitted = methodOmittedVars env.teDyn.dcModule name
          let _ = recordMethodObligationGuarded env name s occurrence omitted
          recordArgStamp
            env.teDyn.dcModule
            env.teDyn.dcSuppressArgStamp
            name
            tagRef
            implRef
            innerRef
            idx
            occurrence
            omitted
          recordArgSiteFn env.teDyn.dcModule name idx occurrence
          occurrence
        None =>
          recordSite
            env
            name
            s
            ifaceRef
            tagRef
            implRef
            methodRef
            innerRef
            occurrence
            subst
      let _ = forceInstantiation env.teDyn.dcModule name inst
      ret

-- C5: queue a standalone-shadow method occurrence's discriminating-arg mono cell so
-- resolveRLocalSites can stamp RLocal once inference grounds the receiver.  Only
-- shadows (standaloneValuesRef) are recorded — every other method occurrence is
-- untouched (no entry → byte-identical).  The dispatch index comes from the method's
-- declared interface type (methodDispatchIdx).
-- S-1: this is the GENERAL shadow-occurrence recorder, and it is the path that a
-- VALUE-position shadow (`map size [1,2,3]`) and an IMPORTER shadow on an UNGROUNDED
-- receiver (`size 3`, where the Num literal is not yet grounded so inferShadowApp's
-- standalone arm is never reached) both take.  Both must carry the standalone's dicts or
-- they under-apply exactly like the headline bug.  Slots only — NOT obligations; see
-- shadowStandaloneDictSlotsAt.
recordRLocalSite : TcEnv -> String -> Ref Route -> Ref Inner -> Mono -> Unit
recordRLocalSite env name tagRef innerRef inst
  | env.teDyn.dcSuppressRLocalRecord = ()
  -- #1430 (S2, row 39): a RETURN-POSITION method has NO dispatch argument, so
  -- `methodDispatchIdx` answers None and every arm below declined — no pending site, no
  -- route stamp, and the occurrence kept the method's dispatching route while
  -- `maybeStandaloneValueMono` had already pinned its TYPE to the standalone.  That is
  -- exactly the invariant `standaloneValuePinned`'s header states in bold ("⭐ THE ROUTE
  -- Must follow the arm"), violated at the one cell the dispatch-index gate hides.
  -- Measured at the parent commit on a two-verb split that cannot be read any other way:
  -- for `interface Zed a where zed : a` + `impl Zed Int` + a module-local `zed : Bool`,
  -- `check --types` reported `zed : Bool` (the standalone — the TYPE arm) at exit 0 while
  -- `run` E-PANICked `no matching impl for dispatch` (the ROUTE arm asked `Zed Bool`).
  -- With `zed : Int` the same split is SILENT: `run` printed the impl's 777.
  -- forceLocal (`True`) rather than a receiver query: under S4 there is no receiver to
  -- dispatch on, which is the same argument `standaloneValuePinned` already makes for the
  -- arg-position value cell.  Empty dict slots: `shadowStandaloneDictSlotsAt` resolves a
  -- constrained standalone's slots by unifying its scheme against `TFun receiver …`, and a
  -- return-position value standalone has no such arrow to match — an unconstrained one
  -- (the whole cell #1430 pins) short-circuits to `emptyShadowDicts` there anyway.
  | isNone (methodDispatchIdx env.teDyn.dcModule name)
    && standaloneValuePinned env name =
    pushSiteGoal
      env.teDyn.dcModule.mcGraph
      GKRLocalSite
      innerRef
      (PendingEntry
        name
        tagRef
        inst
        env.teDyn.dcModule.mcCells.currentFn.value
        (SKRLocal (routeLocalSym !tagRef) True [] [] [])
        env.teDyn.dcModule.mcLoc
        (captureScope env.teDyn.dcModule ())
        (freshEvId env.teDyn.dcModule ()))
  | not (omHasKey name env.teDyn.dcModule.mcCells.standaloneValuesRef.value) =
    ()
  | otherwise = match methodDispatchIdx env.teDyn.dcModule name
    None => ()
    Some idx => match nthFunDomain idx inst
      Some am =>
        let sym = routeLocalSym !tagRef
        let dicts =
          shadowStandaloneDictSlotsAt
            env.teDyn
            (standaloneValueFor env name sym)
            name
            (if sym == "" then name else sym)
            am
        pushSiteGoal
          env.teDyn.dcModule.mcGraph
          GKRLocalSite
          innerRef
          (PendingEntry
            name
            tagRef
            am
            env.teDyn.dcModule.mcCells.currentFn.value
            (SKRLocal
              sym
              (standaloneValuePinned env name)
              dicts.sdMonos
              dicts.sdIfaces
              dicts.sdArgVecs)
            env.teDyn.dcModule.mcLoc
            (captureScope env.teDyn.dcModule ())
            (freshEvId env.teDyn.dcModule ()))
      None => ()

-- A method-layer binding retains the standalone scheme it masks. Recover that
-- exact scheme, including forcing effects, before trying a routed symbol.
export
standaloneSchemeFor : TcEnv -> String -> String -> Option Scheme
standaloneSchemeFor env name sym =
  map (value => value.vsScheme) (standaloneValueFor env name sym)

export
standaloneOccurrence : TcEnv ->
  String ->
  String ->
  Option Loc ->
  Option SelectedValueOccurrence
standaloneOccurrence env name sym origin =
  map
    (instantiateStandaloneOccurrence env name sym origin)
    (standaloneValueFor env name sym)

-- Phase 69.x-e: if [name] is a method with method-level constraints (foldMap's
-- `Monoid m`), map each constraint's scheme id through this occurrence's
-- instantiation subst to its concrete mono and record the (methodRef, monos) so
-- resolveMethodDicts can route them after inference.  A method with no method-level
-- constraint records nothing — methodRef stays [], eval's fold is a no-op.
recordMethodDicts : ModuleCtx ->
  String ->
  Ref (List Route) ->
  Ref Inner ->
  List (Int, Mono) ->
  Unit
recordMethodDicts mctx name methodRef innerRef subst =
  match methodIfaceHere mctx name
    None => ()
    Some iface =>
      match (lookupAssoc
        (methodSlotKey iface (originMethodName mctx name))
        mctx.mcCells.methodPredicateSlotsRef.value)
        None => ()
        Some slots =>
          recordMethodDictsFromSlots mctx slots methodRef innerRef subst

-- Instantiate the authoritative method carrier for THIS occurrence.  The carrier's
-- stable positions index the occurrence's ordered substitution, avoiding any reliance
-- on allocation-local ids from an earlier discovery sweep.  A re-exported method keeps
-- its original scheme order, so the same positional projection is diamond-safe.
recordMethodDictsFromSlots : ModuleCtx ->
  List MethodPredicateSlot ->
  Ref (List Route) ->
  Ref Inner ->
  List (Int, Mono) ->
  Unit
recordMethodDictsFromSlots mctx slots methodRef innerRef subst = pushMethodDictGoal
  mctx.mcGraph
  PendingMethodDict {
    pmdRoutesRef = methodRef,
    pmdEv = freshEvId mctx (),
    pmdSlots = instantiateMethodPredicateSlots mctx.mcGraph slots subst,
    pmdEncl = mctx.mcCells.currentFn.value,
    pmdScope = captureScope mctx (),
    pmdInner = innerRef,
  }

instantiateMethodPredicateSlots : GraphCtx ->
  List MethodPredicateSlot ->
  List (Int, Mono) ->
  List PredicateSlot
instantiateMethodPredicateSlots gctx [] _ = []
instantiateMethodPredicateSlots gctx (slot :: rest) subst =
  match instantiateMethodPredicateSlot gctx slot subst
    Some pred => pred :: instantiateMethodPredicateSlots gctx rest subst
    None => instantiateMethodPredicateSlots gctx rest subst

instantiateMethodPredicateSlot : GraphCtx ->
  MethodPredicateSlot ->
  List (Int, Mono) ->
  Option PredicateSlot
instantiateMethodPredicateSlot gctx slot subst =
  map
    (instantiatedMethodPredicate gctx slot subst)
    (methodSlotSubst slot.mpsPredicate.psBoundIds slot.mpsPositions subst)

instantiatedMethodPredicate : GraphCtx ->
  MethodPredicateSlot ->
  List (Int, Mono) ->
  List (Int, Mono) ->
  PredicateSlot
instantiatedMethodPredicate gctx slot subst slotSubst =
  let args2 =
    instantiatedMethodPredicateArgs gctx slot.mpsPredicate.psArgs slotSubst
  PredicateSlot {
    psIface = slot.mpsPredicate.psIface,
    psArgs = args2,
    psBoundIds =
      map (p => optionOr (0 - 1) (get p (map fst subst))) slot.mpsPositions,
  }

instantiatedMethodPredicateArgs : GraphCtx ->
  PredicateSlotArgs ->
  List (Int, Mono) ->
  PredicateSlotArgs
instantiatedMethodPredicateArgs gctx PSArgsUnknown _ = PSArgsUnknown
instantiatedMethodPredicateArgs gctx (PSArgsKnown args) subst =
  PSArgsKnown (map (substMono gctx subst [] []) args)

methodSlotSubst : List Int ->
  List Int ->
  List (Int, Mono) ->
  Option (List (Int, Mono))
methodSlotSubst ids positions subst =
  let vals = map snd subst
  let n = listLen subst
  if listLen ids == listLen positions && allInRange positions n then
    Some (zipMethodSlotSubst ids positions vals)
  else
    None

zipMethodSlotSubst : List Int -> List Int -> List Mono -> List (Int, Mono)
zipMethodSlotSubst [] _ _ = []
zipMethodSlotSubst _ [] _ = []
zipMethodSlotSubst (id :: ids) (pos :: positions) vals =
  (id, nthMethodMono pos vals) :: zipMethodSlotSubst ids positions vals

allInRange : List Int -> Int -> Bool
allInRange [] _ = True
allInRange (p :: rest) n = p >= 0 && p < n && allInRange rest n

nthMethodMono : Int -> List Mono -> Mono
nthMethodMono _ [] = tconUnresolved "__missing_method_slot__"
nthMethodMono 0 (x :: _) = x
nthMethodMono i (_ :: xs) = nthMethodMono (i - 1) xs

-- record a return-position method occurrence: resolveSite later stamps its route
-- (RKey/RDict) once inference grounds the result mono.  An admitted-set occurrence
-- (`admittedSetOccurrence`) records the set's obligation and a site its commit
-- stamps (`resolveAdmittedSite`), both decided by the one test here.
recordSite : TcEnv ->
  String ->
  Scheme ->
  Ref String ->
  Ref Route ->
  Ref (List Route) ->
  Ref (List Route) ->
  Ref Inner ->
  Mono ->
  MethodInstantiationSubst ->
  Mono
recordSite env name scheme ifaceRef tagRef implRef methodRef innerRef methodType subst =
  let stripped = stripArrows methodType
  let ev = freshEvId env.teDyn.dcModule ()
  let exactRow = exactReturnRow env name scheme
  let admitted = isNone exactRow && admittedSetOccurrence env name scheme
  let exact =
    map
      (row =>
        methodReturnRequest env.teDyn.dcModule row methodType subst (Some ev))
      exactRow
  match (exact, exactRow)
    (Some request, Some row) =>
      recordMethodLevelSlotsOwned
        env.teDyn.dcModule
        row
        subst.misTypeSubst
        request.mrrLoc
        request.mrrScope
      let _ = recordExactMethodObligation env.teDyn.dcModule request
      if isEmptyL row.msrMethodSlots then
        ()
      else
        recordMethodDictsFromSlots
          env.teDyn.dcModule
          row.msrMethodSlots
          methodRef
          innerRef
          subst.misTypeSubst
    _ =>
      if admitted then
        pushAdmittedOccObl env.teDyn.dcModule name methodType
      else
        let _ = recordMethodObligationGuarded env name scheme methodType []
        ()
      recordMethodDicts
        env.teDyn.dcModule
        name
        methodRef
        innerRef
        subst.misTypeSubst
  let siteEv = match exact
    Some request => optionOr ev request.mrrGoalEv
    None => ev
  pushSiteGoal
    env.teDyn.dcModule.mcGraph
    GKReturnSite
    innerRef
    (PendingEntry
      name
      tagRef
      stripped
      env.teDyn.dcModule.mcCells.currentFn.value
      (match exact
        Some request => SKExactReturn implRef request
        None =>
          if admitted then
            SKAdmittedReturn ifaceRef implRef methodType
          else
            SKReturn implRef methodType)
      env.teDyn.dcModule.mcLoc
      (captureScope env.teDyn.dcModule ())
      siteEv)
  env.teDyn.dcModule.mcCells.methodSiteFns :=
    consSiteFn
      env.teDyn.dcModule.mcCells.currentFn.value
      stripped
      env.teDyn.dcModule.mcCells.methodSiteFns.value
  methodType

recordNumLitSite : ModuleCtx ->
  ClassPredicate ->
  Ref Route ->
  Mono ->
  Option Loc ->
  ScopeId ->
  Mono
recordNumLitSite mctx predicate tagRef occurrence origin scope =
  let stripped = stripArrows occurrence
  pushSiteGoal
    mctx.mcGraph
    GKReturnSite
    (Ref innerNone)
    (PendingEntry
      "fromInt"
      tagRef
      stripped
      mctx.mcCells.currentFn.value
      (SKNumReturn predicate occurrence)
      origin
      scope
      (freshEvId mctx ()))
  mctx.mcCells.methodSiteFns :=
    consSiteFn
      mctx.mcCells.currentFn.value
      stripped
      mctx.mcCells.methodSiteFns.value
  occurrence

freshLocalAbsName : GraphCtx -> String -> String
freshLocalAbsName gctx x =
  let st = gctx.graphRun.localAbs
  let (mid, k) = st.lasNext.value
  let name = "\{x}$\{mid}$\{intToString k}$lb"
  st.lasNext := (mid, k + 1)
  st.lasMinted := name :: st.lasMinted.value
  name

-- Mint a use node for a name that takes no dictionary, so its grants have an
-- identity to be recorded under.
mintGrantOnly : ModuleCtx -> String -> Expr
mintGrantOnly mctx n =
  let ev = freshEvId mctx ()
  let st = mctx.mcGraph.graphRun.grants
  st.gsGrantOnly := IdMap.set (evOrdinal ev) () st.gsGrantOnly.value
  EDictAt n ev

export
isGrantOnlyEv : GraphCtx -> EvId -> Bool
isGrantOnlyEv gctx ev =
  IdMap.has (evOrdinal ev) gctx.graphRun.grants.gsGrantOnly.value

-- A grant-only use that became a dictionary application (a recursive use of a
-- member its group just promoted).
unmarkGrantOnly : GraphCtx -> EvId -> Unit
unmarkGrantOnly gctx ev =
  let st = gctx.graphRun.grants
  st.gsGrantOnly := IdMap.delete (evOrdinal ev) st.gsGrantOnly.value

-- The callee's constraints are registered (funConstraintsRef has it) ⇒ a normal
-- call: map each constraint id through the instantiation subst to this call's
-- monos.  Absent ⇒ a self/mutually-recursive call (the callee is still inferring
-- in the same group); defer it for realizeRecDictApps to forward the enclosing
-- fn's dict.
-- A constrained callee in funConstraintsRef is reached two ways: (1) a NORMAL call
-- to an already-generalized fn — instantiateTracked pins each of its constraint ids
-- to a fresh occurrence var, so `snd inst` carries them; route via pendingDictApps.
-- (2) a SELF/MUTUALLY-RECURSIVE call — the callee is still the group's monomorphic
-- PLACEHOLDER (Forall [] [] v), so `snd inst` is empty (none of [ids] appear).  Here
-- the constraint var lives in the ENCLOSING fn's own type and the callee's REGISTERED
-- ids only become valid after this pass's registerInferredConstraints re-registers
-- them; defer to realizeRecDictApps (which forwards the enclosing dict).  We MUST NOT
-- take the normal branch here (as a stale cross-module funConstraintsRef seed makes us
-- do): constraintMonosOf maps the registered ids through the empty subst → [] → the
-- recursive call's route ref stays empty while dictPass still prepends the param → the
-- call under-applies → dispatch fails.  Detect (2) as "no registered id is pinned by
-- the instantiation subst" (mirrors the oracle's empty-`sub` self-recursion case).
-- WS-2/D2: a cross-module constrained callee's dict SLOTS (id + interface, paired) by
-- MODULE IDENTITY.  When [name] is an EXPLICITLY-imported value (currentImportDefinersRef)
-- whose import SOURCE module owns a (source,name) entry in the qualified arity tables,
-- return that entry — the definer-keyed arity, immune to the bare-name most-recent-prepend
-- collision in the jointly-seeded funConstraintsRef.  None ⇒ local fn / wildcard import /
-- re-export / check path (mid ""): inferDictAtFound falls back to the bare funConstraintsRef
-- + funConstraintIfacesRef path (today's behavior; same slots when no collision, since
-- the qual entry is the same module's same ids the bare first-match returns sans collision).
-- S-xmod-vector-supply (#1868/#1867): a PROJECTION of `qualConstraintDecl`, which is the
-- ONE qual-entry resolution, which `declaredCrossModuleObls` also reads for the entry's
-- ARGUMENT VECTORS: two readers re-deriving which entry a name resolves to is the drift
-- `qualConstraintKey` exists to prevent.
qualConstraintFor : ModuleCtx -> String -> Option (List CSlot)
qualConstraintFor mctx name =
  map (d => d.cdSlots) (qualConstraintDecl mctx name)

-- the callee's registered dict-slot ids, unpaired and untruncated.
--
-- Why this exists, and why it is not the parallel-list hazard `CSlot` removed.
-- `pairSlots` truncates to the SHORTER of (ids, ifaces), which is correct everywhere the
-- result decides dict SLOTS — that is exactly what the zips it replaced did.  But two
-- guards in `inferDictAtFound` and one in `shadowStandaloneDictSlotsAt` do not ask about
-- slots; they ask *"is this callee registered as constrained at all"* and *"did the
-- instantiation pin any of its constraint vars"*.  Reading a TRUNCATED list there changes
-- the answer whenever the arity table HITS and the iface table MISSES — a mismatch this
-- seam can manufacture by construction (see `CSlot`) — and the two arms then differ:
-- one records an empty dict app, the other skips routing (and, at the standalone site,
-- skips a `unify` side effect).  Nobody has built a witness, so the difference is
-- unmeasured, which is precisely why this unit does not take it: an obligation-identity
-- change must not smuggle in a routing change nobody asked for.
--
-- It is NOT zipped against an interface list anywhere — its only consumers are
-- `isEmptyL` and `anyIdPinned` — so it cannot mispair with one.  That is the property
-- `CSlot` protects, and it is preserved.
declaredConstraintIds : ModuleCtx -> String -> List Int
declaredConstraintIds mctx name = match qualConstraintIds mctx name
  Some ids => ids
  -- same #739 source-exact discipline as `declaredConstraintFor`'s `None` arm below:
  -- a known import with no qual entry is genuinely unconstrained, and must NOT fall
  -- through to the source-blind bare-name table.
  None =>
    if hasImportDefiner mctx name then
      []
    else
      predicateSlotIdsAt name mctx.mcCells.funPredicateSlotsIdxRef.value

qualConstraintIds : ModuleCtx -> String -> Option (List Int)
qualConstraintIds mctx name = match qualConstraintKey mctx name
  None => None
  Some (src, origin) =>
    map
      predicateSlotIds
      (lookupQualPayload
        src
        origin
        mctx.mcGraph.crossRun.crossModuleFunPredicateSlotsQualRef.value)

export
inferDictAtFound : ModuleCtx ->
  String ->
  EvId ->
  (Mono, List (Int, Mono)) ->
  Mono
inferDictAtFound mctx name ev inst =
  let q = qualConstraintFor mctx name
  -- S-xmod-vector-supply (#1868/#1867): ONE resolution, two projections.  The slots and
  -- the argument vectors `zipSlotVecs` pairs them with below MUST come from the same
  -- entry decision — reading the slots qual-resolved and the vectors off the bare-name
  -- table is precisely the cross-module gap this slice closes.
  let dc = declaredConstraintFor mctx name
  -- UNTRUNCATED on purpose — `map (s => s.csId) slots` is NOT the same list when the
  -- arity table hits and the iface table misses.  See `declaredConstraintIds`.
  let declaredIds = declaredConstraintIds mctx name
  let known = match q
    Some _ => True
    None => hasPredicateSlots name mctx.mcCells.funPredicateSlotsIdxRef.value
  -- #739: an explicitly-imported callee with NO cross-module constraint (declaredIds empty
  -- and source-exact per Fix A above) is genuinely UNCONSTRAINED — it only reached this
  -- EDictAt path because the marker's dict-name set is source-blind and a DIFFERENT module
  -- exports a same-named CONSTRAINED fn (`p.f`).  It needs NO dict routing, so [ev] is
  -- published as an application of ZERO dictionaries (a goal with no slots, which solves
  -- to `EvMany []`): `evDictRoutesIn` panics on an id with no entry, so every `EDictAt` must
  -- be represented.  Neither branch below is safe here — the
  -- `if` branch would record a phantom obligation off the bare-name collision, and the
  -- `else` (recursive) branch's realizeRecDictApps does its OWN source-blind bare-name
  -- funConstraintsRef lookup and would forward the wrong module's dict slot.
  if isEmptyL declaredIds && hasImportDefiner mctx name then
    pushDictApp mctx.mcGraph PendingDictApp {
      pdaRoutesRef = Ref [],
      pdaEv = ev,
      pdaMonos = [],
      pdaIfaces = [],
      pdaArgVecs = [],
      pdaEncl = mctx.mcCells.currentFn.value,
      pdaLoc = mctx.mcLoc,
      pdaScope = captureScope mctx (),
      pdaCallee = localSourceName name,
    }
    fst inst
  else if known
    && (anyIdPinned declaredIds (snd inst)
      || calleeIsGeneralized mctx name q (snd inst)) then
    inferDeclaredDictAt mctx name ev dc (
      fst inst,
      pinUnboundIds mctx declaredIds (snd inst),
    )
  else
    pushRecDictAppGoal
      mctx.mcGraph
      (RecDictApp
        (Ref [])
        name
        mctx.mcCells.currentFn.value
        (fst inst)
        (captureScope mctx ())
        ev)
    fst inst

export
inferDeclaredDictAt : ModuleCtx ->
  String ->
  EvId ->
  CDeclared ->
  (Mono, List (Int, Mono)) ->
  Mono
inferDeclaredDictAt mctx name ev dc inst =
  -- One dict per distinct declared slot (`dedupSlotVecs`), each carrying its argument
  -- vector — the same sequence `dedupPredicateSlotsTable` leaves on the define side,
  -- so the dict params `dictArityOf`/dictPass prepend agree slot for slot.  A slot's
  -- supers take no dict of their own: the route built for the slot carries them.
  let expandedV = dedupSlotVecs (zipSlotVecs dc.cdSlots dc.cdArgs)
  let expanded = map fst expandedV
  let ids = map (s => s.csId) expanded
  let monos = constraintMonosOf ids (snd inst)
  let argVecs = callArgVecsV mctx.mcGraph expandedV (snd inst)
  -- the ROUTING goal stays a spelling (`resolveDictApps` asks the SPELLING-keyed
  -- `KeyBuckets` a route-word question — see `dispHeadTab`); only the OBLIGATION goal
  -- below carries identity.
  pushDictApp mctx.mcGraph PendingDictApp {
    pdaRoutesRef = Ref [],
    pdaEv = ev,
    pdaMonos = monos,
    pdaIfaces = map (s => s.csIface) expanded,
    pdaArgVecs = argVecs,
    pdaEncl = mctx.mcCells.currentFn.value,
    pdaLoc = mctx.mcLoc,
    pdaScope = captureScope mctx (),
    pdaCallee = localSourceName name,
  }
  mctx.mcCells.dictAppFns :=
    consSiteFn
      mctx.mcCells.currentFn.value
      (bareVectorLeads monos argVecs)
      mctx.mcCells.dictAppFns.value
  -- #11 soundness: record this call's instantiated impl obligations (iface paired
  -- with the call's constraint mono), checked after inference by checkCallObligations.
  -- The iface list is slot-parallel to [monos]; a concrete-head mono with no impl
  -- (`Num String` from `f "hello"` where `f : Num a => a -> a`) becomes an error.
  recordCallObligations mctx expanded monos argVecs
  fst inst

-- The callee is not a member of the group being inferred: a signed binding of this
-- module is reached in its own group through its declared scheme
-- (`bindingDeclaredAt`), never here, and an imported one is never in the group.
-- So a declared constraint id its instantiation does not bind is a variable its
-- type does not mention (`plain : Sz a => Int -> Int`), not a recursive call.
-- Unless the value restriction kept the signed binding monomorphic: then its
-- signature's type mentions a variable that its scheme [subst] does not quantify,
-- and its constraints are on its own variables, posed in its own group.
calleeIsGeneralized : ModuleCtx ->
  String ->
  Option (List CSlot) ->
  List (Int, Mono) ->
  Bool
calleeIsGeneralized mctx name q subst
  | isSome q = True
  | otherwise = match omLookup name mctx.mcCells.sigTyMapRef.value
    Some ty => isNonEmptyL subst || isEmptyL (tyVarNames ty)
    None => False

-- [subst] with a fresh variable for each of [ids] it does not bind.  A declared
-- constraint whose variable the callee's type does not mention is instantiated at
-- every call all the same, so the call poses its goal and the goal gets its
-- verdict whether or not the callee's body reads the dictionary.
pinUnboundIds : ModuleCtx -> List Int -> List (Int, Mono) -> List (Int, Mono)
pinUnboundIds mctx ids subst =
  subst
    ++ map
      (id => (id, freshVar mctx ()))
      (filterList (id => isNone (lookupAssocI id subst)) ids)

-- True iff at least one of [ids] (the callee's registered constraint tyvar ids) is
-- a key of the instantiation subst — i.e. instantiateTracked actually quantified it,
-- so this is a normal generalized call.  False ⇒ the callee is a monomorphic
-- placeholder (self/mutual recursion); subst can't carry its constraint occurrence.
anyIdPinned : List Int -> List (Int, Mono) -> Bool
anyIdPinned [] _ = False
anyIdPinned (id :: rest) subst = match lookupAssocI id subst
  Some _ => True
  None => anyIdPinned rest subst

-- pair each iface with its slot-parallel instantiated constraint mono, pushing onto
-- pendingCallObligations.  Length-zips defensively (an iface list shorter than the
-- mono list — e.g. a multi-param constraint whose ifaces weren't recorded — just
-- stops, never over-rejecting).
recordCallObligations : ModuleCtx ->
  List CSlot ->
  List Mono ->
  List (List Mono) ->
  Unit
recordCallObligations mctx [] _ _ = ()
recordCallObligations mctx _ [] _ = ()
recordCallObligations mctx (s :: ss) (mono :: ms) []
  | s.csIface.irName == "" = recordCallObligations mctx ss ms []
  | otherwise =
    recordObl
      mctx
      Predicate {
        iface = s.csIface,
        args = [mono],
      }
      0
      PCallSlot
      mctx.mcLoc
    recordCallObligations mctx ss ms []
recordCallObligations mctx (s :: ss) (mono :: ms) (args :: rest)
  | s.csIface.irName == "" = recordCallObligations mctx ss ms rest
  | otherwise =
    -- 1-ary by construction: these slots are funConstraintsRef's SHATTERED
    -- per-tyvar dict slots (`Ix a i` => two slots), so each carries one mono.
    -- Widening this to a joint vector is the dict-slot=predicate change (#607
    -- punch-list item 3), which moves emitted arity and is deliberately NOT
    -- done here.  The joint obligation for such a predicate is supplied by the
    -- declared-context path (declaredSchemeOblsFor); this path stays as-is.
    -- #1161 (F-3a-ii) widened the ROUTING goal (pushDictApp's 4th component) but
    -- deliberately NOT this OBLIGATION channel — measured: making this site n-ary from
    -- the same vector still ACCEPTED an unsatisfiable `Ix a Bool =>` at exit 0, because
    -- the acceptance decision is made upstream in `declaredSchemeOblsFor` →
    -- `declaredOblOne` → `constraintArgMonos`, which returned `None` for a non-tyvar
    -- argument on an ids-only payload.  That was #1161 symptom 2, and it is CLOSED: the
    -- payload now carries the whole vector (`VecObl.voArgs`) and `declaredOblMixed`
    -- records the predicate.  This site is still 1-ary and still deliberately so —
    -- the fix landed upstream precisely so that emitted dict arity did not move.
    -- Regression: test/dict_fixtures/s3-sig-constraint-unsatisfiable-rejects.mdk.
    -- P1 (#1446) / U1b (#1482): `funConstraintIfacesRef`'s payload is `List IfaceRef`,
    -- so this site records the interface OCCURRENCE's identity instead of
    -- `OriginUnresolved`.  It was one of the two `ifaceRefBare` producers.
    let goalArgs = if isEmptyL args then [mono] else args
    recordObl
      mctx
      Predicate { iface = s.csIface, args = goalArgs }
      0
      PCallSlot
      mctx.mcLoc
    recordCallObligations mctx ss ms rest

-- The leads of a dictionary application that `dictAppFns` may record for the caller.
-- `inferredConstraintIds` reads a recorded lead as the predicate `iface lead`, which is
-- that slot's predicate only when every argument of its vector is a type variable.  A
-- slot with a structured argument (`Sub (Box b)`) reaches the caller whole on the call
-- channel (`recordCallObligations`), where it is reduced, so its lead is not recorded.
-- [monos] and [argVecs] are slot-parallel; a lead with no vector is kept.
bareVectorLeads : List Mono -> List (List Mono) -> List Mono
bareVectorLeads monos [] = monos
bareVectorLeads [] _ = []
bareVectorLeads (m :: ms) (v :: vs)
  | allList isBareTyvarMono v = m :: bareVectorLeads ms vs
  | otherwise = bareVectorLeads ms vs

-- Map a comparison/equality operator to its Eq/Ord method and stash a pending
-- binop site; non-comparison operators record nothing.  G4: snapshot
-- currentImplBody so resolveBinopSite gates the RDict element-dict route to genuine
-- in-impl-body sites (a top-level operand may collide with stale activeDictVars ids).
recordBinopSite : ModuleCtx -> String -> Ref Route -> Mono -> Unit
recordBinopSite mctx op dref m = match binopMethod op
  Some method =>
    pushSiteGoal
      mctx.mcGraph
      GKBinopSite
      (Ref innerNone)
      (PendingEntry
        method
        dref
        m
        mctx.mcCells.currentFn.value
        (SKOp mctx.mcCells.currentImplBody.value)
        mctx.mcLoc
        (captureScope mctx ())
        (freshEvId mctx ()))
  None => ()

-- Arithmetic produces one predicate-aware route goal and destination when the
-- prelude Num declaration is present; UObligation remains the checker channel.
-- Without the prelude, the same method arm retains the scalar deferred stamp.
-- Non-arithmetic operators use the legacy comparison/append recorder.
export
arithDispatchMethod : String -> Option String
arithDispatchMethod "+" = Some "add"
arithDispatchMethod "-" = Some "sub"
arithDispatchMethod "*" = Some "mul"
arithDispatchMethod "/" = Some "div"
arithDispatchMethod "%" = Some "rem"
arithDispatchMethod _ = None

export
recordBinopGoals : ModuleCtx -> String -> Ref Route -> Mono -> Unit
recordBinopGoals mctx op dref m = match arithDispatchMethod op
  Some method =>
    if builtinClassPresent mctx.mcGraph BNum then
      let predicate = ClassPredicate {
        predicateInterface = builtinIfaceRef mctx.mcGraph BNum,
        predicateArguments = [m],
      }
      let scope = captureScope mctx ()
      noteNumericPredicateTrace
        mctx.mcGraph
        NPTProduced
        predicate
        scope
        mctx.mcLoc
        None
        None
        []
      pushSiteGoal
        mctx.mcGraph
        GKBinopSite
        (Ref innerNone)
        (PendingEntry
          method
          dref
          m
          mctx.mcCells.currentFn.value
          (SKPredicateOp mctx.mcCells.currentImplBody.value predicate)
          mctx.mcLoc
          scope
          (freshEvId mctx ()))
      ()
    else
      pushArithGoal mctx dref m (freshEvId mctx ())
  None => recordBinopSite mctx op dref m

-- Roadmap #18a: `++` is the surface operator for `Semigroup`'s `append`, so it
-- joins the comparison operators on the recordBinopSite/resolveBinopSites seam —
-- a ground non-builtin operand (a user `impl Semigroup MyRope`) gets its route
-- stamped and rewriteBinopExpr turns the EBinOp into an `EMethodAt "append"`
-- application.  The builtin String/List appends never route (binopBuiltinHead) —
-- see the recursion note there.
export
binopMethod : String -> Option String
binopMethod "==" = Some "eq"
binopMethod "/=" = Some "eq"
binopMethod "<" = Some "lt"
binopMethod ">" = Some "gt"
binopMethod "<=" = Some "lte"
binopMethod ">=" = Some "gte"
binopMethod "++" = Some "append"
binopMethod _ = None

-- Roadmap #18c: `-` (unary minus) is the surface operator for `Num`'s `negate`,
-- joining `++`/comparisons on the record*Site/resolve*Sites/rewrite*Expr seam.
-- `!` never routes — Bool negation is not a typeclass method.
export
unopMethod : String -> Option String
unopMethod "-" = Some "negate"
unopMethod _ = None

-- The EUnOp analogue of recordBinopGoals: stash a pending unop site for `-`
-- (nothing for `!`).  `-` is `Num`'s `negate`, so like binary arithmetic it carries
-- its complete `Num` predicate and is answered by predicate identity, which also
-- reaches a dictionary-abstracted local's generalized operand.
export
recordUnopSite : ModuleCtx -> String -> Ref Route -> Mono -> Unit
recordUnopSite mctx op dref m = match unopMethod op
  Some method =>
    let inImpl = mctx.mcCells.currentImplBody.value
    let kind =
      if builtinClassPresent mctx.mcGraph BNum then
        SKPredicateOp inImpl ClassPredicate {
          predicateInterface = builtinIfaceRef mctx.mcGraph BNum,
          predicateArguments = [m],
        }
      else
        SKOp inImpl
    pushSiteGoal
      mctx.mcGraph
      GKUnopSite
      (Ref innerNone)
      (PendingEntry
        method
        dref
        m
        mctx.mcCells.currentFn.value
        kind
        mctx.mcLoc
        (captureScope mctx ())
        (freshEvId mctx ()))
  None => ()

-- `-2` is usually `negate 2`, not one fused literal (the parser fuses only a tight
-- argument and the 2^62 minimum), so the fixed-width range check would see only the
-- in-range `2`.  A negated literal is checked as the negative value it spells: its
-- var is the result's var, so `-2 : U8` is `L-INT-OVERFLOW` like any other literal.
-- The negated value REPLACES the literal's own entry (the one `infer` just pushed),
-- so `-300 : U8` is one error, not a second one for `300`.  The catch-all arm is
-- deliberate: any operand other than a (located) literal is ordinary arithmetic.
export
recordNegatedLitRange : ModuleCtx -> Mono -> Expr -> Unit
recordNegatedLitRange mctx t (ELoc _ e) = recordNegatedLitRange mctx t e
recordNegatedLitRange mctx t (ENumLit n _ _) =
  match mctx.mcCells.numlitRanges.value
    (_, m, loc) :: rest if m == n =>
      mctx.mcCells.numlitRanges := (t, negateLiteral n, loc) :: rest
    _ => recordNumlitRange mctx t (negateLiteral n)
recordNegatedLitRange mctx t (EWideLit _ _ _ lx) =
  match mctx.mcCells.wideLitRanges.value
    (_, l, hi, lo, _, loc) :: rest if l == lx =>
      mctx.mcCells.wideLitRanges := (t, lx, hi, lo, True, loc) :: rest
    _ => ()
recordNegatedLitRange mctx _ _ = ()

-- #146: unified operator-obligation recorder.  The arithmetic (`+ - * / %`, unary
-- `-`), comparison (`== /= < > <= >=`) and append (`++`) operators each carry an
-- interface obligation on their (unified) operand type via pushPendingObl — a
-- synthetic obligation with a bare iface-param declared type (`TyVar "a"`, typaram
-- ["a"]) so dispatchMonosOf recovers exactly the operand mono.  Gated on the PRELUDE's
-- copy of that class being present: the bare-HM no-prelude oracle (tc_probe /
-- typecheck_main.mdk) declares none of Num/Eq/Ord/Semigroup, so recording only when the
-- class exists keeps those drivers byte-identical while full check_main (prelude)
-- rejects, matching `medaka check`.  Callers: numArithOp/negateOp (BNum), eqCompareOp
-- (BEq), ordCompareOp (BOrd), appendOp (BSemigroup).
--
-- #1539 / DICT §8 I7 qualification 4: the gate is `builtinClassPresent c`, NOT
-- `ifaceRegistered (builtinClassName c)`.  The latter asked whether SOME interface
-- spelled `Num` is registered — a table any user declaration writes to — so under §7.1
-- U1 (prelude becomes a node, and a user `interface Num` stops being a within-module
-- duplicate) a user's class would be the thing that TRIGGERS the operator's obligation.
-- That is the capture I7 qualification 4 forbids, reached through the gate rather than
-- through the payload, and it is the same reason the payload half already refuses to
-- read that table (see the `§8 I7` section below, and `ModuleCtx.registeredIfacesRef`'s
-- retirement note — #1569 removed the table itself once `ifaceRegistered` had no
-- callers left).
export
recordIfaceObligation : ModuleCtx -> BuiltinClass -> Mono -> Unit
recordIfaceObligation mctx c lt
  | builtinClassPresent mctx.mcGraph c =
    pushPendingObl
      mctx
      (builtinIfaceRef mctx.mcGraph c)
      ["a"]
      (TyVar "a")
      lt
      []
      POperator
      mctx.mcLoc
  | otherwise = ()

-- PLAN.md #11 soundness arm: model an integer literal as a `fromInt n` method
-- occurrence so its route cell [dref] gets stamped (RKey ground / RDictFwd poly) by
-- resolveSites — exactly like core.mdk's `fromInt 0` in `sum`.
-- Gated on the prelude (the PRELUDE's `Num`
-- present — `builtinClassPresent BNum` since #1539, was `ifaceRegistered "Num"` — AND
-- `fromInt` bound): with no prelude (bare-HM oracle) fall back to a plain fresh
-- Num-obligated var, leaving [dref] RNone (⇒ a static Int literal at rewrite time).
-- The gate (#1539) and the anchor (#259) both ask the PRELUDE and nothing else (§11's
-- "I7 (literals)" row): the gate is `builtinClassPresent BNum`, the method is the scheme
-- `seedNumLitFromIntAnchor` selected out of the prelude `Num` DECLARATION by identity.
-- A binding spelled `fromInt` in the user's term scope is not consulted, so it cannot
-- re-anchor the literals around it (#259: `fromInt : Int -> Float` made
-- `println (7 / 2)` print `3.5` under `run` and `3` from the built binary, exit 0).
export
inferNumLit : TcEnv -> Int -> EvId -> Mono
inferNumLit env n ev =
  let a =
    inferNumLitVar
      env
      n
      (siteFloatCell env.teDyn.dcModule.mcGraph ev)
      (siteRouteCell env.teDyn.dcModule.mcGraph ev)
  recordNumlitRange env.teDyn.dcModule a n
  a

-- INTEGER-TYPES-DESIGN §3.2 item 4: a literal above 2^62 is inferred exactly as an
-- ordinary one, a `fromInt` occurrence whose type comes from context, and is
-- recorded for `checkWideLiterals` instead of the narrow range check, which accepts
-- it only where that type grounded to `U64`.  The `Int` the shared route carries is
-- a stand-in (the low half) that nothing reads for a wide literal:
-- `rewriteBinopExpr` builds its `LU64` from the node's own halves.
export
inferWideLit : TcEnv -> Int -> Int -> EvId -> String -> Mono
inferWideLit env hi lo ev lx =
  let a =
    inferNumLitVar
      env
      lo
      (Ref None)
      (siteRouteCell env.teDyn.dcModule.mcGraph ev)
  env.teDyn.dcModule.mcCells.wideLitRanges :=
    (a, lx, hi, lo, False, env.teDyn.dcModule.mcLoc)
      :: env.teDyn.dcModule.mcCells.wideLitRanges.value
  a

inferNumLitVar : TcEnv -> Int -> Ref (Option Float) -> Ref Route -> Mono
inferNumLitVar env n fref dref
  | builtinClassPresent
    env.teDyn.dcModule.mcGraph
    BNum = match env.teDyn.dcModule.mcCells.numLitFromIntAnchorRef.value
    None => inferNumLitBare env.teDyn.dcModule n fref
    Some anchor =>
      -- records the Num impl obligation + a pendingSite on [dref].
      let fromIntTy = inferNumLitMethod env.teDyn.dcModule anchor dref
      let a = freshVar env.teDyn.dcModule ()
      unifyIn
        env.teDyn
        fromIntTy
        (TFun (tconBuiltin "Int") (openRow env.teDyn.dcModule ()) a)
      pushNumlit env.teDyn.dcModule.mcGraph (a, fref, n, dref)
      recordNumlitLoc env.teDyn.dcModule a  -- Chunk D: literal provenance for Num mis-framing
      a
  | otherwise = inferNumLitBare env.teDyn.dcModule n fref

-- #259: the literal's own occurrence recorder — `inferMethodAt`'s `Some` arm MINUS every
-- shadow arm, because a numeric literal is not a shadow occurrence and cannot be one:
-- `1 + 1` mentions no identifier, so nothing about it can denote a user standalone.
--
-- Dropped, deliberately, and each is INERT on a program with no `fromInt` shadow (so this
-- is byte-identical to the old route everywhere the defect was absent):
--   • `recordRLocalSite` — gated on `standaloneValuesRef` membership / `standaloneValuePinned`,
--     both empty for an unshadowed `fromInt`.  Under a shadow it stamped the literal's route
--     RLocal at the user's binding.
--   • `maybeStandaloneValueMono` / `maybeStandaloneValueMonoEmit` — the value-position pins,
--     keyed on `definerShadowNamesRef` / the route sym; both `None` unshadowed.  These are
--     what re-typed the literal to the user binding's own scheme on the emit path.
--   • `argDispatchOf` — `fromInt` is return-position (no dispatch argument), so this answered
--     `None` and fell to `recordSite` on every path already.
--
-- A literal always records the prelude `Num` obligation (DICT §8 I7); no binding
-- spelled `fromInt`, local or standalone, suppresses it.  Only a mono-scheme anchor
-- (nothing to instantiate) skips it.
inferNumLitMethod : ModuleCtx -> MethodSchemeRow -> Ref Route -> Mono
inferNumLitMethod mctx anchor tagRef =
  let inst = instantiateTracked mctx anchor.msrScheme
  let occurrence = fst inst
  let predicate = ClassPredicate {
    predicateInterface = anchor.msrIface,
    predicateArguments =
      dispatchMonosOf anchor.msrTyparams anchor.msrType occurrence,
  }
  let origin = mctx.mcLoc
  let scope = captureScope mctx ()
  noteNumericPredicateTrace
    mctx.mcGraph
    NPTProduced
    predicate
    scope
    origin
    None
    None
    []
  recordMethodDictsFromSlots
    mctx
    anchor.msrMethodSlots
    (Ref [])
    (Ref innerNone)
    (snd inst)
  let _ =
    recordNumLitObligationGuarded mctx anchor predicate occurrence origin scope
  recordNumLitSite mctx predicate tagRef occurrence origin scope

-- no-prelude fallback: a fresh var, no route (dref untouched ⇒ stays RNone ⇒ Int).
-- PLAN.md #11 (locked §0.2): a numeric literal is ALWAYS a `fromInt n` occurrence,
-- so it carries a `Num` obligation on its var unconditionally — exactly the OCaml
-- oracle, whose ENumLit infer arm `infer env (EVar "fromInt")` records the Num
-- usage even no-prelude (`initial_env` seeds `fromInt`/`Num`).  Recording it here
-- (vs. the prelude-gated `recordIfaceObligation`) lets value-level defaulting ground
-- an AMBIGUOUS literal var to Int (`nums = [1,2,3] : List Int`) so the no-prelude
-- `typecheck_main` matches the prelude-aware oracle golden.  The matching reject is
-- SUPPRESSED no-prelude in checkOneImplObligation (no-prelude imposes no Num impl
-- constraint — see its `builtinClassPresent BNum` guard), so a literal still types Int
-- without a spurious `No impl of Num for Int`.
inferNumLitBare : ModuleCtx -> Int -> Ref (Option Float) -> Mono
inferNumLitBare mctx n fref =
  let a = freshVar mctx ()
  let predicate = ClassPredicate {
    predicateInterface = builtinIfaceRef mctx.mcGraph BNum,
    predicateArguments = [a],
  }
  let origin = mctx.mcLoc
  let scope = captureScope mctx ()
  noteNumericPredicateTrace
    mctx.mcGraph
    NPTProduced
    predicate
    scope
    origin
    None
    None
    []
  pushNumLitObl mctx predicate a origin scope
  pushNumlit mctx.mcGraph (a, fref, n, Ref RNone)
  recordNumlitLoc mctx a  -- Chunk D: literal provenance for Num mis-framing
  a

-- ── Chunk D: Num mis-framing provenance (error-path only) ──────────────────
-- Record a literal's (var, loc) so a later Num-obligation reframe can tell a bare
-- literal from an arithmetic-operator operand.  [mcLoc] is the ENumLit span.
recordNumlitRange : ModuleCtx -> Mono -> Int -> Unit
recordNumlitRange mctx a n =
  mctx.mcCells.numlitRanges :=
    (a, n, mctx.mcLoc) :: mctx.mcCells.numlitRanges.value

recordNumlitLoc : ModuleCtx -> Mono -> Unit
recordNumlitLoc mctx a = match mctx.mcLoc
  Some l =>
    mctx.mcCells.numlitVarLocs := (a, l) :: mctx.mcCells.numlitVarLocs.value
    mctx.mcCells.numlitUntainted := (a, l) :: mctx.mcCells.numlitUntainted.value
  None => ()

-- Called from recordIfaceObligation (arithmetic `+`/`-`/`*`/`/`/`%`): any recorded
-- literal whose var shares a union-find root with [m] was an operand of an op, so
-- mark its loc — the reframe then keeps `No impl of Num for T` for it.  Runs during
-- inference (vars still unbound), so `normalize` reveals the shared root regardless
-- of which operand became the root at unify time.
export
markNumlitOpTaint : ModuleCtx -> Mono -> Unit
markNumlitOpTaint mctx m =
  let id = rootIdOf m
  if id < 0 || not (anyRootMatch id mctx.mcCells.numlitUntainted.value) then
    ()
  else
    mctx.mcCells.numlitUntainted :=
      taintAndDrop mctx id mctx.mcCells.numlitUntainted.value

-- True iff SOME worklist literal shares the union-find root [id].  Short-circuits via
-- `||` and allocates nothing, so the common case (this operand taints no literal)
-- leaves the worklist alone — rebuilding it unconditionally would put back an O(N)
-- allocation per operand, which is the very thing `rootIdOf` removed.
anyRootMatch : Int -> List (Mono, Loc) -> Bool
anyRootMatch _ [] = False
anyRootMatch id ((v, _) :: rest) = sameRootId id v || anyRootMatch id rest

-- Taint every worklist literal sharing the root [id] (record its loc as
-- operator-tainted) and DROP it from the worklist; keep the others.
taintAndDrop : ModuleCtx -> Int -> List (Mono, Loc) -> List (Mono, Loc)
taintAndDrop mctx _ [] = []
taintAndDrop mctx id ((v, l) :: rest)
  | sameRootId id v =
    mctx.mcCells.numlitOpLocs := l :: mctx.mcCells.numlitOpLocs.value
    taintAndDrop mctx id rest
  | otherwise = (v, l) :: taintAndDrop mctx id rest

-- #11 soundness (native obligation hole, plain check path): a constrained binding used
-- as a plain EVar (`g = f "hello"`) instantiates its DEFERRED obligations at the call.
-- schemeObligationsRef (always-on, unlike funConstraintsRef) records each binding's
-- (iface, quantified-var-id); here we instantiate TRACKED so each obligation var maps
-- to this call's fresh mono, recorded as a call obligation checked after inference.
-- A binding with no recorded obligations takes the plain instantiate path (identical
-- mono).  Re-checks inferred constraints at every use.
-- #837: [id] is the occurrence's binding id (from EVarId).  When id /= 0 the
-- lookup keys EXACTLY (x, id) — so a top-level `g`'s use can never pick up a
-- where-helper `g`'s obligations.  id == 0 (local/where/cross-module/global, or
-- any non-EVarId caller) falls to the bare-name scan — byte-identical to today.
export
instantiateVarTrackedId : TcEnv -> String -> Int -> Scheme -> Mono
instantiateVarTrackedId env x id s =
  let inst = instantiateVarTrackedWithSubst env x id s
  inst.mtiBody

export
instantiateVarTrackedWithSubst : TcEnv ->
  String ->
  Int ->
  Scheme ->
  MethodTrackedInstantiation
instantiateVarTrackedWithSubst env x id s = match bindingDeclared env x
  Some _ =>
    let inst = instantiateValueTracked env.teDyn.dcModule x s
    match bindingDeclaredAt env x inst
      Some dc =>
        recordDeclaredBindingCall
          env.teDyn.dcModule
          dc
          inst.mtiSubstitution.misTypeSubst
      None => ()
    inst
  None => instantiateLegacyVarTracked env.teDyn.dcModule x id s

-- Error-path B4: if [x] is a registered interface method, record this occurrence's
-- (post-instantiation) mono so checkImplObligations can verify a matching impl
-- exists once the dispatch type is resolved.  Returns the mono unchanged.  A
-- non-method name records nothing (the common case).  The marked path records the
-- same via inferMethodAt; the bare typecheck_main path records here.
recordImplObligation : ModuleCtx ->
  String ->
  Mono ->
  List (String, Mono) ->
  Mono
recordImplObligation mctx x mono omitted
  -- A standalone shadow (a top-level funDef that reuses an interface-method name)
  -- resolves in-scope to that standalone, not the method — the scope-blind marker
  -- still rewrites its occurrences to EMethodAt, but a NO-IMPL receiver legitimately
  -- falls back to the standalone (resolveRLocalSite stamps RLocal), so there is no
  -- impl obligation.  Recording one surfaces a spurious `No impl of <Iface> for <T>`
  -- under checkImplObligations (the build path skips that check, so it only bites
  -- `check`).  Skip for EVERY standalone shadow — definer (`definerShadowNamesRef`)
  -- AND importer (an imported standalone; `standaloneValuesRef` holds both).  P0-18:
  -- this closes the `check`-side of the importer-shadow-on-a-no-impl-receiver residual
  -- (`size 3` where `size` is imported) which was REJECTED while `run` correctly
  -- returned the standalone.  Sound: the name genuinely has a standalone fallback, so
  -- a no-impl receiver is not an error — the route decides impl-vs-standalone per
  -- receiver; a receiver WITH an impl still dispatches (and that impl exists).
  -- Check BOTH refs: the single-file check path (checkProgram) sets only
  -- `definerShadowNamesRef`, while the multi-module path sets `standaloneValuesRef`
  -- (importer ∪ definer) — so either alone would miss one path's shadows.
  | omHasKey x mctx.mcCells.definerShadowNamesRef.value
    || omHasKey x mctx.mcCells.standaloneValuesRef.value = mono
  -- A bare spelling with two or more admitted declarations in this module's scope
  -- (S2-DECL (d), `methodAdmittedHere`) names no single interface, and
  -- `methodEntryHere` answers no declaration for it: an obligation against any one
  -- of them would be a choice the scope did not make — and the impl channel checks
  -- it on every driver (#2705).  MEASURED:
  -- `A.ff (A.mkA 0)` beside `import x1277_b as B`, both interfaces declaring `ff`,
  -- rejected `No impl of Fb for H` on `run`/`build` once the alias renamer fanned
  -- both aliases into bare `ff`.  The obligation is recorded against the whole
  -- admitted SET instead (`pushAdmittedOccObl`) and decided by (d) at module end.
  -- Dispatch is unaffected (the route is decided by receiver identity, not by
  -- this row); the occurrence carrying the identity it resolved to is #1898's.
  | listLen (methodAdmittedHere mctx x) >= 2 =
    pushAdmittedOccObl mctx x mono
    mono
  | otherwise = match methodEntryHere mctx x
    None => mono
    Some (iface, typarams, mty, _) =>
      -- U1c (#1507): pass `iface`, NOT `ifaceRefBare iface.irName`.  The live rule,
      -- not merely a citation: the class a method-occurrence goal names is the interface
      -- that DECLARES the method the occurrence resolved to, carrying that `interface`
      -- declaration's I4 identity `(originModule, name)` (`docs/spec/DICT-SEMANTICS.md`
      -- §8 I4 — identity is assigned once where it is declared, and every occurrence is
      -- resolved to one such identity before entailment runs).  There is no competing
      -- "occurrence layer": `DImpl.implOrigin` and `DInterface.ifaceOrigin` are the SAME
      -- layer — one ASSIGNED at the `interface` decl, one RESOLVED-TO at each occurrence
      -- — so comparing them is not a category error.  Discarding the identity here
      -- silently accepts #1438's cross-module collision shape; carrying it REJECTS that
      -- shape, discriminating METHOD-OCCURRENCE goals the same way the other three
      -- goal-producer call sites always did.
      --
      -- #1288 is a separate fact, and points the other way: do not weld the two.
      -- It is what carrying identity COSTS: when a re-export merge (`mid.mdk` doing
      -- `export import p.*` + `export import g.*` over two unrelated `Same` interfaces)
      -- gives an importer's `impl Same P` an `implOrigin` of `g` while the method it
      -- defines belongs to `p.Same`, the identity-carrying goal `TkIdent p Same` misses
      -- the impl's `TkIdent g Same` bucket.  That is a FALSE REJECT at exit 1 —
      -- `No impl of Same for P` on a program whose `impl Same P` is three lines up, with
      -- no syntax available to say which `Same` was meant.  #1438: identity turns a
      -- silent accept into a reject (good).  #1288: identity turns a valid program into
      -- a rejection (bad, and open).  Both are live; both belong here.
      --
      -- Do NOT reinstate a ban on foreign-interface method occurrences here on a bare
      -- assertion that the two layers are "different" — and
      -- do NOT cite "resolve already rejects the ambiguous case" as cover either: MEASURED,
      -- resolve catches a DIRECT double import of a colliding method name but does NOT
      -- diagnose a RE-EXPORT MERGE of the same collision, which reaches this line as
      -- `methodScopeAt` as two admitted declarations (the guard above), with no
      -- diagnostic either way.
      --
      -- This is not the only decl-layer goal site.  Four more
      -- (`recordIfaceObligation`, `inferNumLitBare`, `numCallObls`, `numDictObls`) build
      -- their goal from `builtinIfaceRef`; the STANDING CONDITION that keeps them safe
      -- lives at that function's own definition, where it is about them.  And "the third
      -- and last of the `ifaceRefBare` producers" is a claim about
      -- `ifaceRefBare` MINTS ONLY — the `ImplUniverse` channel has at least six goal
      -- producers in total.  Re-derive with `grep -n ifaceRefBare` rather than trust a
      -- count, and do not read the narrow claim as the broad one.
      --
      -- The reason such a ban is wrong, the re-export-merge measurement,
      -- the `builtinIfaceRef` census, and #1288's verbatim repro:
      -- `compiler/TYPECHECK-TARGET-ARCHITECTURE.md` §10.7.  Positive pair:
      -- `test/dict_fixtures/i4-xmod-method-occurrence-{foreign-iface-rejected,
      -- own-iface-control}`.
      pushPendingObl mctx iface typarams mty mono omitted PMethodOcc mctx.mcLoc
      -- #818 (#838 I3): also record each method-level `=>` constraint slot (e.g.
      -- `Ord b` on `peer : Ord b => a -> b -> b -> Bool`) as its OWN obligation, so an
      -- unsatisfiable slot (`Ord NoOrd`) is rejected by the unified checker at check
      -- time instead of silently becoming an RNone route (a wrong answer / segfault
      -- at run/build).  Recorded here so BOTH the check path (inferVarPlainId) and the
      -- emit path (inferMethodAt) — the two recordImplObligation callers — cover it.
      recordMethodLevelObls mctx typarams mty mono
      mono

-- #816/#818 (#840 step 1): the shared shadow guard around method-occurrence
-- obligation recording.  A LAMBDA/PATTERN-BOUND local shadowing a method name
-- resolves to a MONOMORPHIC local scheme (`Forall [] []`); the scope-blind marker
-- still rewrote the occurrence to EMethodAt (emit path) — or it reaches
-- inferVarPlainId as a bare EVar (check path) — but it denotes the local, and
-- recording a method obligation for it invents a predicate on whatever the local's
-- var unifies with (a prelude default `filter p t = …` under a user `interface P`
-- whose method is named `p` recorded a phantom `P elem` obligation — which the #816
-- W3 survivor check then rejected as an undeclared constraint on the method's
-- element var).  Every genuine interface method quantifies at least its interface
-- parameter, so a mono scheme is never a real method occurrence.  (Top-LEVEL shadows
-- are already suppressed INSIDE recordImplObligation via
-- definerShadowNamesRef/standaloneValuesRef; this is the local-binding sibling.)
-- BOTH occurrence recorders — inferMethodAt (emit) and inferVarPlainId (check), the
-- only two recordImplObligation callers — share this guard so the #816 predicate
-- lands ONCE.  Takes the caller's ALREADY-INSTANTIATED [mono]; it must NOT
-- re-instantiate, because each caller's own instantiation carries tracked
-- side-effects (recordMethodDicts, recordSchemeCallObligations) that must fire
-- exactly once, at the call site.  [s] is that caller's own lookupVar scheme, tested
-- for monomorphism.  Returns [mono] unchanged in every case (recordImplObligation
-- always returns its argument), so the check path's return value is byte-identical.
-- #2705 / S2-DECL (d) for OBLIGATIONS.  An occurrence whose bare spelling has two or
-- more admitted declarations records no single-interface obligation
-- (`recordImplObligation`); it is decided at the graph-end drain, after every module
-- has grounded what it can and live `Num` roots are defaulted (DICT-SEMANTICS §6.2
-- T5), by `admittedSelection`, the function its route commits through in the same
-- drain (`resolveAdmittedSite`).  Exactly one declaration selecting an instance is
-- the accept; none is the no-impl reject; two or more, or a declaration whose
-- receiver cannot be asked, is the located ambiguity reject, so no accepted
-- occurrence is left without a committed route.
pushAdmittedOccObl : ModuleCtx -> String -> Mono -> Unit
pushAdmittedOccObl mctx name mono =
  mctx.mcCells.admittedOccObls :=
    (name, mono, mctx.mcLoc) :: mctx.mcCells.admittedOccObls.value

-- An occurrence whose obligation is its admitted set's rather than one
-- declaration's: a spelling with two or more admitted declarations, written where
-- neither a local (`recordMethodObligationGuarded`) nor a standalone shadow
-- (`recordImplObligation`) binds it.
admittedSetOccurrence : TcEnv -> String -> Scheme -> Bool
admittedSetOccurrence env name s =
  not
      (lookupLocalFlag env name
        || isMonoScheme s
        || omHasKey name env.teDyn.dcModule.mcCells.definerShadowNamesRef.value
        || omHasKey name env.teDyn.dcModule.mcCells.standaloneValuesRef.value)
    && listLen (methodAdmittedHere env.teDyn.dcModule name) >= 2

export
recordMethodObligationGuarded : TcEnv ->
  String ->
  Scheme ->
  Mono ->
  List (String, Mono) ->
  Mono
recordMethodObligationGuarded env name s mono omitted =
  if lookupLocalFlag env name || isMonoScheme s then
    mono
  else
    recordImplObligation env.teDyn.dcModule name mono omitted

exactReturnRow : TcEnv -> String -> Scheme -> Option MethodSchemeRow
exactReturnRow env name scheme = match lookupMethodRow env name
  None => None
  Some row =>
    if lookupLocalFlag env name
      || isMonoScheme scheme
      || omHasKey name env.teDyn.dcModule.mcCells.definerShadowNamesRef.value
      || omHasKey name env.teDyn.dcModule.mcCells.standaloneValuesRef.value
      || isSome
        (Scopes.enclosingDefaultBody
          (currentScopeStore env.teDyn.dcModule.mcGraph ())
          (captureScope env.teDyn.dcModule ()))
      || listLen (methodAdmittedHere env.teDyn.dcModule name) >= 2 then
      None
    else
      Some row

export
recordMethodObligationOwned : TcEnv ->
  String ->
  Scheme ->
  Mono ->
  MethodInstantiationSubst ->
  Option EvId ->
  Mono
recordMethodObligationOwned env name scheme occurrence subst goalEv =
  match exactReturnRow env name scheme
    Some row =>
      let request =
        methodReturnRequest env.teDyn.dcModule row occurrence subst goalEv
      recordMethodLevelSlotsOwned
        env.teDyn.dcModule
        row
        subst.misTypeSubst
        request.mrrLoc
        request.mrrScope
      recordExactMethodObligation env.teDyn.dcModule request
    None => recordMethodObligationGuarded env name scheme occurrence []

recordExactMethodObligation : ModuleCtx -> MethodReturnRequest -> Mono
recordExactMethodObligation mctx request =
  noteMethodReturnTrace mctx MRTProduced request None []
  pushExactReturnObl mctx request
  request.mrrOccurrence

recordMethodLevelSlotsOwned : ModuleCtx ->
  MethodSchemeRow ->
  List (Int, Mono) ->
  Option Loc ->
  ScopeId ->
  Unit
recordMethodLevelSlotsOwned mctx row subst loc scope =
  recordInstantiatedMethodLevelSlots
    mctx
    (instantiateMethodPredicateSlots mctx.mcGraph row.msrMethodSlots subst)
    loc
    scope

recordInstantiatedMethodLevelSlots : ModuleCtx ->
  List PredicateSlot ->
  Option Loc ->
  ScopeId ->
  Unit
recordInstantiatedMethodLevelSlots mctx [] _ _ = ()
recordInstantiatedMethodLevelSlots mctx (slot :: rest) loc scope =
  match slot.psArgs
    PSArgsUnknown => ()
    PSArgsKnown args =>
      recordOblAt
        mctx
        Predicate { iface = slot.psIface, args = args }
        0
        PMethodLevel
        loc
        scope
  recordInstantiatedMethodLevelSlots mctx rest loc scope

-- A numeric literal's checking obligation and method-level slots come from its
-- identity-selected method row; no bare-name table reconstructs the class and no
-- binding's spelling suppresses it.
recordNumLitObligationGuarded : ModuleCtx ->
  MethodSchemeRow ->
  ClassPredicate ->
  Mono ->
  Option Loc ->
  ScopeId ->
  Mono
recordNumLitObligationGuarded mctx anchor predicate occurrence origin scope =
  if isMonoScheme anchor.msrScheme then
    occurrence
  else
    recordNumLitImplObligation mctx anchor predicate occurrence origin scope

recordNumLitImplObligation : ModuleCtx ->
  MethodSchemeRow ->
  ClassPredicate ->
  Mono ->
  Option Loc ->
  ScopeId ->
  Mono
recordNumLitImplObligation mctx anchor predicate occurrence origin scope =
  pushNumLitObl mctx predicate occurrence origin scope
  recordMethodLevelObls mctx anchor.msrTyparams anchor.msrType occurrence
  occurrence

-- #818 (#838 I3): record one PMethodLevel obligation per method-level `=>` constraint
-- slot of a method occurrence.  [mty] is the method's DECLARED type (with its `=>`);
-- [occMono] is THIS occurrence's instantiated (constraint-free) type.  Align the
-- declared function spine (constraints/effects stripped) against [occMono] with
-- matchTyMono to recover each constraint var's concrete mono, then record the
-- constraint's whole argument vector under that substitution (`Show2 (f Int)` at
-- `f := Box` poses `Show2 (Box Int)`, not `Show2 Box`).  matchTyMono captures the
-- live tyvar cell, so a slot still a fresh var at record time normalizes to its
-- solved head at check time — a ground head (`NoOrd`) with no impl is rejected
-- `T-NO-IMPL`; a still-generalized var defers into the scheme
-- (`undeterminedGoalExempt`), uniform with every other obligation.  No slots ⇒ nothing
-- recorded (the receiver-only-method common case), and a shape mismatch (matchTyMono
-- None) records nothing — never a false reject.
recordMethodLevelObls : ModuleCtx -> List String -> Ty -> Mono -> Unit
recordMethodLevelObls mctx typarams mty occMono =
  let slots = methodLevelConstraintSlots typarams mty
  if isEmptyL slots then
    ()
  else match matchTyMono (stripLeadingMethodConstraints mty) occMono
    None => ()
    Some subst => recordMethodLevelSlotObls mctx slots subst

recordMethodLevelSlotObls : ModuleCtx ->
  List Constraint ->
  List (String, Mono) ->
  Unit
recordMethodLevelSlotObls mctx [] _ = ()
recordMethodLevelSlotObls mctx (c :: rest) subst =
  if allList (v => isSome (lookupAssoc v subst)) (constraintVarNames c) then
    recordObl
      mctx
      Predicate {
        iface = IfaceRef {
          irName = constraintIface c,
          irOrigin = c.constraintOrigin,
        },
        args = map (fromAstType mctx subst) c.constraintArgs,
      }
      0
      PMethodLevel
      mctx.mcLoc
  recordMethodLevelSlotObls mctx rest subst

-- S-1 (importer half): re-record each of the importer shadow's route refs as an
-- RLocalSite carrying the imported standalone's own constraint dicts, so
-- resolveRLocalSites re-stamps the ref post-inference with the dicts filled in.
-- forceLocal=True — inferShadowApp's standalone arm already committed the site's type.
-- Inert (no dicts, same RLocal stamp) for an unconstrained imported standalone.
export
recordSelectedStandaloneRoutes : ModuleCtx ->
  String ->
  ShadowDicts ->
  List (Ref Route, Ref Inner) ->
  Mono ->
  Unit
recordSelectedStandaloneRoutes mctx _ _ [] _ = ()
-- multi-line RHS: the indented `:=` form is legal but not seed-parseable yet (#1744)
-- lint-disable-next-line rule-prefer-assign-op
recordSelectedStandaloneRoutes mctx mname dicts ((r, inner) :: rest) tx =
  pushSiteGoal
    mctx.mcGraph
    GKRLocalSite
    inner
    (PendingEntry
      mname
      r
      tx
      mctx.mcCells.currentFn.value
      (SKRLocal
        (routeLocalSym !r)
        True
        dicts.sdMonos
        dicts.sdIfaces
        dicts.sdArgVecs)
      mctx.mcLoc
      (captureScope mctx ())
      (freshEvId mctx ()))
  recordSelectedStandaloneRoutes mctx mname dicts rest tx

-- P0-19 d4b (S4): a definer-shadow occurrence in bare VALUE position (NOT the head of
-- its own application — dcShadowHeadCtx is False) denotes the STANDALONE.  Returns the
-- standalone's declared scheme freshly instantiated so a HOF sees `Int -> Int`, not the
-- permissive method scheme `a -> Int` — making `map size [Box …]` a located reject
-- (Box vs Int) while `map size [1,2,3]` still accepts.  Only fires for a single-param
-- interface-method name that is a module-local standalone WITH a declared signature;
-- everything else (app head, non-shadow, unsignatured standalone) returns None → the
-- ordinary env lookup / method scheme, unchanged.
-- #411 (row 21, S4): the IMPORTER half of the same cell.  S4 is not keyed on where the
-- standalone lives — a value-position shadow denotes the standalone whether this module
-- DEFINED it or IMPORTED it — so the definer arm below is followed by the importer arm,
-- reading the imported standalone's scheme from the lexical binding descriptor
-- (the same scheme inferShadowApp's standalone arm uses).
--
-- Fork 1 is not touched.  This arm is gated on dcShadowHeadCtx = False, i.e. bare
-- VALUE position only; every APPLIED importer occurrence goes through inferShadowApp,
-- which now flags its head (inferShadowAppHead) exactly as the definer path always did.
-- So per-receiver importer dispatch (i4's `isEmpty [1, 2]` → `Foldable.isEmpty`) is
-- unchanged — rows 15-20/22 do not move.
--
-- #54: the definer arm is gated on ifaceMethodName (typaram-agnostic) and the importer arm
-- on singleTyparamIfaceMethod (Fork 1's per-receiver scope) — the guards are per-arm,
-- not one leading singleParamIfaceMethod test shared by both.
export
maybeStandaloneValueMono : TcEnv -> String -> Option Mono
maybeStandaloneValueMono env name =
  map
    (value =>
      rejectAdmittedValueOccurrence env.teDyn.dcModule name
      (instantiateStandaloneOccurrence
        env
        name
        ""
        env.teDyn.dcModule.mcLoc
        value).svoInstance.mtiBody)
    (standaloneValueBinding env name)

export
instantiateStandaloneOccurrence : TcEnv ->
  String ->
  String ->
  Option Loc ->
  ValueScheme ->
  SelectedValueOccurrence
instantiateStandaloneOccurrence outer name sym origin value =
  let env = envAt origin outer
  let inst = instantiateValueTracked env.teDyn.dcModule name value.vsScheme
  let declared =
    declaredEffectsAt env.teDyn.dcModule.mcGraph inst value.vsDeclared
  match declared
    Some dc =>
      recordDeclaredBindingCall
        env.teDyn.dcModule
        dc
        inst.mtiSubstitution.misTypeSubst
    None =>
      recordShadowStandaloneObls env name inst.mtiSubstitution.misTypeSubst
  let key = if sym == "" then name else sym
  let dc = optionOr (shadowDeclaredFor env.teDyn.dcModule name key) declared
  SelectedValueOccurrence {
    svoScheme = value.vsScheme,
    svoInstance = inst,
    svoDicts =
      shadowStandaloneDictSlots
        env.teDyn.dcModule.mcGraph
        dc.cdSlots
        dc.cdArgs
        inst.mtiSubstitution.misTypeSubst,
  }

-- the user program's top-level functions carrying a `=>` constraint in their
-- signature — the set the graph driver dictionary-passes
export
constrainedSigNames : List Decl -> List String
constrainedSigNames prog = flatMap constrainedSigName prog

-- The `ArgRw` hook that records nothing: every marker but the group-recursive one
-- (`markRecursiveOccurrences`) reads the dict application's route out of the goal
-- inference pushes for it, so it has nothing to do at mark time.
noDictHook : String -> EvId -> Unit
noDictHook _ _ = ()

-- Mint one dict-application node and tell the hook about it.
mintDictAt : ModuleCtx -> (String -> EvId -> Unit) -> String -> Expr
mintDictAt mctx onDict n =
  let ev = freshEvId mctx ()
  onDict n ev
  EDictAt n ev

-- rewrite a decl body with its own parameters seeded into the bound set.  Mirrors
-- desugar's mapDecl coverage exactly (DFunDef / DInterface / DImpl / DProp /
-- DTest / DAttrib; everything else — incl. DLetGroup — left unchanged),
-- so with the emit path off this would degenerate to the same node set mapProg
-- visits.
prePassDeclScoped : ModuleCtx -> ArgRw -> Decl -> Decl
prePassDeclScoped mctx rw (DFunDef pub n ps e site bid) =
  DFunDef
    pub
    n
    ps
    (rewriteArgScoped mctx rw (boundOfList (patVarsListTc ps)) e)
    site
    bid
prePassDeclScoped mctx rw (d@(DInterface { methods, ... })) =
  DInterface { d | methods = map (prePassIfaceMethodScoped mctx rw) methods }
prePassDeclScoped mctx rw (d@(DImpl { methods, ... })) =
  DImpl { d | methods = map (prePassImplMethodScoped mctx rw) methods }
prePassDeclScoped mctx rw (DProp pub name params body) =
  DProp
    pub
    name
    params
    (rewriteArgScoped mctx rw (boundOfList (propParamNamesTc params)) body)
prePassDeclScoped mctx rw (DTest pub name body) =
  DTest pub name (rewriteArgScoped mctx rw omEmpty body)
prePassDeclScoped mctx rw (DAttrib attrs d) =
  DAttrib attrs (prePassDeclScoped mctx rw d)
-- Top-level `let rec … with …` (DLetGroup): mapDecl/the catch-all skip its bodies,
-- so a constrained-fn occurrence inside a group body would never be rewritten to
-- EDictAt/EMethodAt → its call site gets no dict route → the dict-passed callee is
-- under-applied at eval.  Rewrite each clause body with that clause's params scoped
-- in, exactly like the DFunDef arm.
prePassDeclScoped mctx rw (DLetGroup pub binds) =
  DLetGroup pub (map (prePassLetBindScoped mctx rw) binds)
prePassDeclScoped mctx _ d = d

prePassLetBindScoped : ModuleCtx -> ArgRw -> LetBind -> LetBind
prePassLetBindScoped mctx rw (LetBind n clauses site bid) =
  LetBind n (map (prePassFunClauseScoped mctx rw) clauses) site bid

prePassFunClauseScoped : ModuleCtx -> ArgRw -> FunClause -> FunClause
prePassFunClauseScoped mctx rw (FunClause ps e) =
  FunClause ps (rewriteArgScoped mctx rw (boundOfList (patVarsListTc ps)) e)

prePassIfaceMethodScoped : ModuleCtx -> ArgRw -> IfaceMethod -> IfaceMethod
prePassIfaceMethodScoped mctx _ (IfaceMethod n ty None mloc) =
  IfaceMethod n ty None mloc
prePassIfaceMethodScoped mctx rw (IfaceMethod n ty (Some (MethodDefault ps e)) mloc) =
  IfaceMethod
    n
    ty
    (Some
      (MethodDefault
        ps
        (rewriteArgScoped mctx rw (boundOfList (patVarsListTc ps)) e)))
    mloc

prePassImplMethodScoped : ModuleCtx -> ArgRw -> ImplMethod -> ImplMethod
prePassImplMethodScoped mctx rw (ImplMethod n ps e) =
  ImplMethod n ps (rewriteArgScoped mctx rw (boundOfList (patVarsListTc ps)) e)

-- #1031: `bound` is an OrdMap-backed SET (name -> ()), not a `List String`
-- scanned by `contains` — a deep local nesting (N sequential lets, a reference
-- to an outer binding) made `contains n bound` an O(depth) scan per EVar,
-- O(depth²) over the body (the `scoperefs` shape).  `boundInsert`/`boundOfList`
-- extend it; membership is `omHasKey`.  A name maps to "" for an ordinary binder
-- and to the renamed binder for a candidate let binder (`letPatRename`).
boundInsert : List String -> OrdMap String -> OrdMap String
boundInsert [] b = b
boundInsert (n :: rest) b = boundInsert rest (omInsert n "" b)

-- A let binder that `isNonexpansive` may generalize: every such binder must be able
-- to take dictionary parameters, since generalizing one over a class predicate without
-- abstracting it would share one dictionary between uses at different types.  This
-- runs before inference, without the constructor table, so it over-approximates
-- `isCtorAppSpine` by the head's spelling alone.  A candidate that does not generalize
-- with predicates abstracts nothing and its uses stay plain variables.
localAbsCandidate : Expr -> Bool
localAbsCandidate (ELoc _ e) = localAbsCandidate e
localAbsCandidate (EDoOrigin _ e) = localAbsCandidate e
localAbsCandidate (EAnnot e _) = localAbsCandidate e
localAbsCandidate (EHeadAnnot e _) = localAbsCandidate e
localAbsCandidate (ELit _) = True
localAbsCandidate (EVar _) = True
localAbsCandidate (EVarId _ _) = True
localAbsCandidate (EMethodAt _ _ _) = True
localAbsCandidate (EDictAt _ _) = True
localAbsCandidate (EMethodRef _) = True
localAbsCandidate (ELam _ _) = True
localAbsCandidate (ETuple es) = allList localAbsCandidate es
localAbsCandidate (EListLit es) = allList localAbsCandidate es
localAbsCandidate (app@(EApp _ _)) = localAbsCtorSpine app
localAbsCandidate (ERecordCreate _ fs) =
  allList
    (fa => match fa
      FieldAssign _ e => localAbsCandidate e)
    fs
localAbsCandidate _ = False

localAbsCtorSpine : Expr -> Bool
localAbsCtorSpine (ELoc _ e) = localAbsCtorSpine e
localAbsCtorSpine (EDoOrigin _ e) = localAbsCtorSpine e
localAbsCtorSpine (EApp f x) = localAbsCtorSpine f && localAbsCandidate x
localAbsCtorSpine (EVar name) = ctorHeadShaped name
localAbsCtorSpine (EVarId name _) = ctorHeadShaped name
localAbsCtorSpine _ = False

localAbsCandidateBind : LetBind -> Bool
localAbsCandidateBind (LetBind _ clauses _ _) =
  anyList localAbsCandidateClause clauses

localAbsCandidateClause : FunClause -> Bool
localAbsCandidateClause (FunClause [] body) = localAbsCandidate body
localAbsCandidateClause (FunClause _ _) = True

-- A candidate let binder is renamed to a name no other binder carries, so the
-- binder and every occurrence of it name ONE binding for the rest of the pipeline;
-- the bound map sends the source name to the new one, and its occurrences are
-- marked `EDictAt` so a use can carry the dictionaries the binder abstracts.  A
-- name that is already one (a tree marked a second time) is an ordinary binder.
letPatRename : GraphCtx -> Pat -> Expr -> OrdMap String -> (Pat, OrdMap String)
letPatRename gctx (PVar x l bid) e1 b
  | localAbsCandidate e1 && not (isLocalAbsName x) =
    let fresh = freshLocalAbsName gctx x
    (PVar fresh l bid, omInsert x fresh b)
letPatRename gctx p _ b = (p, boundInsert (patVarsTc p) b)

bindsRename : GraphCtx ->
  List LetBind ->
  OrdMap String ->
  (List LetBind, OrdMap String)
bindsRename gctx [] b = ([], b)
bindsRename gctx ((bind@(LetBind n clauses site bid)) :: rest) b =
  let (n2, b1) =
    if localAbsCandidateBind bind && not (isLocalAbsName n) then
      let fresh = freshLocalAbsName gctx n
      (fresh, omInsert n fresh b)
    else
      (n, boundInsert [n] b)
  let (rest2, b2) = bindsRename gctx rest b1
  (LetBind n2 clauses site bid :: rest2, b2)

boundOfList : List String -> OrdMap String
boundOfList ns = boundInsert ns omEmpty

-- the core scope-threaded rewrite.  `bound` is the set of names in scope as
-- locals at this node.  At an EVar: the rp arm is scope-blind (unchanged); the
-- arg-position (`an`) and constrained-fn (`dn`) arms fire only when the name is
-- NOT shadowed by a local.  Binders
-- (ELam/ELet/ELetGroup/EMatch arms/EBlock/EDo + the where/do/guard
-- binders) extend `bound`; every other node recurses into its children with the
-- same `bound`.
rewriteArgScoped : ModuleCtx -> ArgRw -> OrdMap String -> Expr -> Expr
rewriteArgScoped mctx (ArgRw rp dn an sm onDict granted) bound (EVar n)
  -- P0-18: `n` is a MANGLED definer-shadow standalone (`<mid>__size`).  Mark it
  -- `EMethodAt` with the BARE dispatch name (so `implFor` finds the impl when the
  -- receiver has one) and seed the route's `RLocal <n>` fallback with the mangled
  -- symbol (so a no-impl receiver still reaches the standalone `@mdk_<mid>__size`).
  | omHasKey n bound = match omLookup n bound
    Some "" => EVar n
    Some renamed => EDictAt renamed (freshEvId mctx ())
    None => EVar n
  | otherwise = match lookupAssoc n sm
    Some bare => EMethodAt bare n (mintMethodCell mctx n)
    None =>
      if omHasKey n rp || omHasKey n an then
        EMethodAt n "" (mintMethodCell mctx "")
      else if omHasKey n dn then
        mintDictAt mctx onDict n
      else if granted n then
        mintGrantOnly mctx n
      else
        EVar n
-- A grant-only use of a member its group has just promoted becomes that member's
-- dictionary application, under the same id.
rewriteArgScoped mctx (ArgRw _ dn _ _ onDict _) _ (EDictAt n ev)
  | isGrantOnlyEv mctx.mcGraph ev && omHasKey n dn =
    unmarkGrantOnly mctx.mcGraph ev
    onDict n ev
    EDictAt n ev
  | otherwise = EDictAt n ev
-- No `EVarId` arm: every marker runs BEFORE resolve's binding-id stamp (the Flat
-- arm's whole-program pre-pass, and the schedule's per-group `markGroupClauses` →
-- `stampGroupClauses`), so a stamped occurrence never reaches this rewrite.
-- binders
rewriteArgScoped mctx rw bound (ELam ps body) =
  ELam ps (rewriteArgScoped mctx rw (boundInsert (patVarsListTc ps) bound) body)
rewriteArgScoped mctx rw bound (ELet m r p e1 e2) =
  let (p2, after) = letPatRename mctx.mcGraph p e1 bound
  let b1 = if r then after else bound
  ELet
    m
    r
    p2
    (rewriteArgScoped mctx rw b1 e1)
    (rewriteArgScoped mctx rw after e2)
rewriteArgScoped mctx rw bound (ELetGroup binds e2) =
  let (binds2, bnd) = bindsRename mctx.mcGraph binds bound
  ELetGroup
    (map (rewriteArgLetBind mctx rw bnd) binds2)
    (rewriteArgScoped mctx rw bnd e2)
rewriteArgScoped mctx rw bound (EMatch e0 arms) =
  EMatch
    (rewriteArgScoped mctx rw bound e0)
    (map (rewriteArgArm mctx rw bound) arms)
rewriteArgScoped mctx rw bound (EBlock stmts) =
  EBlock (rewriteArgStmts mctx rw bound stmts)
rewriteArgScoped mctx rw bound (EDo d stmts) =
  EDo d (rewriteArgStmts mctx rw bound stmts)
-- non-binder composites: recurse children with the same bound
rewriteArgScoped mctx rw bound (ELoc l e) =
  ELoc l (rewriteArgScoped mctx rw bound e)
rewriteArgScoped mctx rw bound (EDoOrigin l e) =
  EDoOrigin l (rewriteArgScoped mctx rw bound e)
rewriteArgScoped mctx rw bound (EApp f x) =
  EApp (rewriteArgScoped mctx rw bound f) (rewriteArgScoped mctx rw bound x)
rewriteArgScoped mctx rw bound (EIf c t e) =
  EIf
    (rewriteArgScoped mctx rw bound c)
    (rewriteArgScoped mctx rw bound t)
    (rewriteArgScoped mctx rw bound e)
-- An operator site is minted once: `markRecursiveOccurrences` re-marks bodies
-- inference already wrote through these ids, so a minted id passes through.
rewriteArgScoped mctx rw bound (EBinOp op l r ev) =
  let l2 = rewriteArgScoped mctx rw bound l
  let r2 = rewriteArgScoped mctx rw bound r
  EBinOp op l2 r2 (mintedOr (mintOpSite mctx) ev)
rewriteArgScoped mctx rw bound (EUnOp op x ev) =
  let x2 = rewriteArgScoped mctx rw bound x
  EUnOp op x2 (mintedOr (mintOpSite mctx) ev)
rewriteArgScoped mctx rw bound (EInfix op l r) =
  EInfix
    op
    (rewriteArgScoped mctx rw bound l)
    (rewriteArgScoped mctx rw bound r)
rewriteArgScoped mctx rw bound (EFieldAccess e0 n ev) =
  EFieldAccess
    (rewriteArgScoped mctx rw bound e0)
    n
    (mintedOr (mintHeadSite mctx) ev)
rewriteArgScoped mctx rw bound (ETuple es) =
  ETuple (map (rewriteArgScoped mctx rw bound) es)
rewriteArgScoped mctx rw bound (EListLit es) =
  EListLit (map (rewriteArgScoped mctx rw bound) es)
rewriteArgScoped mctx rw bound (EArrayLit es) =
  EArrayLit (map (rewriteArgScoped mctx rw bound) es)
rewriteArgScoped mctx rw bound (ERangeList lo hi i) =
  ERangeList
    (rewriteArgScoped mctx rw bound lo)
    (rewriteArgScoped mctx rw bound hi)
    i
rewriteArgScoped mctx rw bound (ERangeArray lo hi i) =
  ERangeArray
    (rewriteArgScoped mctx rw bound lo)
    (rewriteArgScoped mctx rw bound hi)
    i
rewriteArgScoped mctx rw bound (ESlice e0 lo hi i) =
  ESlice
    (rewriteArgScoped mctx rw bound e0)
    (rewriteArgScoped mctx rw bound lo)
    (rewriteArgScoped mctx rw bound hi)
    i
rewriteArgScoped mctx rw bound (EIndex e0 i) =
  EIndex (rewriteArgScoped mctx rw bound e0) (rewriteArgScoped mctx rw bound i)
rewriteArgScoped mctx rw bound (EAnnot e0 t) =
  EAnnot (rewriteArgScoped mctx rw bound e0) t
rewriteArgScoped mctx rw bound (EHeadAnnot e0 t) =
  EHeadAnnot (rewriteArgScoped mctx rw bound e0) t
rewriteArgScoped mctx rw bound (ERecordCreate n fs) =
  ERecordCreate n (map (rewriteArgField mctx rw bound) fs)
rewriteArgScoped mctx rw bound (ERecordUpdate e0 fs ev) =
  ERecordUpdate
    (rewriteArgScoped mctx rw bound e0)
    (map (rewriteArgField mctx rw bound) fs)
    (mintedOr (mintHeadSite mctx) ev)
rewriteArgScoped mctx rw bound (EVariantUpdate c e0 fs) =
  EVariantUpdate
    c
    (rewriteArgScoped mctx rw bound e0)
    (map (rewriteArgField mctx rw bound) fs)
rewriteArgScoped mctx rw bound (EStringInterp parts) =
  EStringInterp (map (rewriteArgInterp mctx rw bound) parts)
rewriteArgScoped mctx rw bound (EGuards arms) =
  EGuards (map (rewriteArgGuardArm mctx rw bound) arms)
rewriteArgScoped mctx rw bound (ESection (SecRight op e0)) =
  ESection (SecRight op (rewriteArgScoped mctx rw bound e0))
rewriteArgScoped mctx rw bound (ESection (SecLeft e0 op)) =
  ESection (SecLeft (rewriteArgScoped mctx rw bound e0) op)
rewriteArgScoped mctx rw bound (EMapLit n kvs) =
  EMapLit n (map (rewriteArgKv mctx rw bound) kvs)
rewriteArgScoped mctx rw bound (ESetLit n es) =
  ESetLit n (map (rewriteArgScoped mctx rw bound) es)
rewriteArgScoped mctx rw bound (EAsPat x sub) =
  EAsPat x (rewriteArgScoped mctx rw bound sub)
-- Numeric literals carry a site id that is minted here, like operators.
rewriteArgScoped mctx _ _ (ENumLit n ev lx) =
  ENumLit n (mintedOr (mintLitSite mctx) ev) lx
rewriteArgScoped mctx _ _ (EWideLit hi lo ev lx) =
  EWideLit hi lo (mintedOr (mintOpSite mctx) ev) lx
-- leaves (ELit / EMethodRef / EDictApp / EVarAt / EMethodAt / EDictAt / SecBare)
rewriteArgScoped mctx _ _ e = e

rewriteArgField : ModuleCtx ->
  ArgRw ->
  OrdMap String ->
  FieldAssign ->
  FieldAssign
rewriteArgField mctx rw bound (FieldAssign n e) =
  FieldAssign n (rewriteArgScoped mctx rw bound e)

rewriteArgKv : ModuleCtx ->
  ArgRw ->
  OrdMap String ->
  (Expr, Expr) ->
  (Expr, Expr)
rewriteArgKv mctx rw bound (k, v) =
  (rewriteArgScoped mctx rw bound k, rewriteArgScoped mctx rw bound v)

rewriteArgInterp : ModuleCtx ->
  ArgRw ->
  OrdMap String ->
  InterpPart ->
  InterpPart
rewriteArgInterp mctx _ _ (InterpStr s) = InterpStr s
rewriteArgInterp mctx rw bound (InterpExpr e) =
  InterpExpr (rewriteArgScoped mctx rw bound e)

rewriteArgLetBind : ModuleCtx -> ArgRw -> OrdMap String -> LetBind -> LetBind
rewriteArgLetBind mctx rw bound (LetBind n clauses site bid) =
  LetBind n (map (rewriteArgFunClause mctx rw bound) clauses) site bid

rewriteArgFunClause : ModuleCtx ->
  ArgRw ->
  OrdMap String ->
  FunClause ->
  FunClause
rewriteArgFunClause mctx rw bound (FunClause ps body) =
  FunClause
    ps
    (rewriteArgScoped mctx rw (boundInsert (patVarsListTc ps) bound) body)

-- a match/function arm: the pattern binds for the guards + body; a `| p <- e`
-- guard binds for later guards + the body (threaded left-to-right).
rewriteArgArm : ModuleCtx -> ArgRw -> OrdMap String -> Arm -> Arm
rewriteArgArm mctx rw bound (Arm p gs body) =
  let b0 = boundInsert (patVarsTc p) bound
  let (gs2, bnd) = rewriteArgGuards mctx rw b0 gs
  Arm p gs2 (rewriteArgScoped mctx rw bnd body)

rewriteArgGuardArm : ModuleCtx -> ArgRw -> OrdMap String -> GuardArm -> GuardArm
rewriteArgGuardArm mctx rw bound (GuardArm gs body) =
  let (gs2, bnd) = rewriteArgGuards mctx rw bound gs
  GuardArm gs2 (rewriteArgScoped mctx rw bnd body)

rewriteArgGuards : ModuleCtx ->
  ArgRw ->
  OrdMap String ->
  List Guard ->
  (List Guard, OrdMap String)
rewriteArgGuards mctx _ bound [] = ([], bound)
rewriteArgGuards mctx rw bound ((GBool e) :: rest) =
  let e2 = rewriteArgScoped mctx rw bound e
  let (rest2, bnd) = rewriteArgGuards mctx rw bound rest
  (GBool e2 :: rest2, bnd)
rewriteArgGuards mctx rw bound ((GBind p e) :: rest) =
  let e2 = rewriteArgScoped mctx rw bound e
  let (rest2, bnd) =
    rewriteArgGuards mctx rw (boundInsert (patVarsTc p) bound) rest
  (GBind p e2 :: rest2, bnd)

-- do/block statements: a DoBind/DoLet pattern binds for SUBSEQUENT
-- statements (a recursive DoLet also for its own RHS).
rewriteArgStmts : ModuleCtx ->
  ArgRw ->
  OrdMap String ->
  List DoStmt ->
  List DoStmt
rewriteArgStmts mctx _ _ [] = []
rewriteArgStmts mctx rw bound ((DoExpr e) :: rest) =
  DoExpr (rewriteArgScoped mctx rw bound e)
    :: rewriteArgStmts mctx rw bound rest
rewriteArgStmts mctx rw bound ((DoBind p e) :: rest) =
  DoBind p (rewriteArgScoped mctx rw bound e)
    :: rewriteArgStmts mctx rw (boundInsert (patVarsTc p) bound) rest
rewriteArgStmts mctx rw bound ((DoLet m r p e site) :: rest) =
  let (p2, after) = letPatRename mctx.mcGraph p e bound
  let b1 = if r then after else bound
  DoLet m r p2 (rewriteArgScoped mctx rw b1 e) site
    :: rewriteArgStmts mctx rw after rest
rewriteArgStmts mctx rw bound ((DoAssign x e) :: rest) =
  DoAssign x (rewriteArgScoped mctx rw bound e)
    :: rewriteArgStmts mctx rw bound rest
rewriteArgStmts mctx rw bound ((DoFieldAssign x fs e) :: rest) =
  DoFieldAssign x fs (rewriteArgScoped mctx rw bound e)
    :: rewriteArgStmts mctx rw bound rest

-- interface methods carrying a method-level constraint (a `=>` in the method's own
-- signature over any tyvar, e.g. foldMap's `Monoid m`) — rewritten to EMethodAt
-- alongside the return-position methods so the method-level dict can be folded on.
-- Computed structurally before `checkBodyImpl` populates `methodPredicateSlotsRef`.
export
methodConstraintNames : List Decl -> List String
methodConstraintNames prog = flatMap methodConstraintNamesOfDecl prog

methodConstraintNamesOfDecl : Decl -> List String
methodConstraintNamesOfDecl (DAttrib _ d) = methodConstraintNamesOfDecl d
methodConstraintNamesOfDecl (DInterface { typarams, methods, ... }) =
  flatMap (methodConstraintNameOf typarams) methods
methodConstraintNamesOfDecl _ = []

methodConstraintNameOf : List String -> IfaceMethod -> List String
methodConstraintNameOf typarams (IfaceMethod mname mty _ _)
  | hasMethodLevelConstraint typarams mty = [mname]
  | otherwise = []

-- does this method type carry a leading `=>` constraint over some tyvar? (a
-- method-LEVEL constraint: the method's own context, as opposed to an impl `requires`)
hasMethodLevelConstraint : List String -> Ty -> Bool
hasMethodLevelConstraint typarams (TyConstrained cs t) =
  constraintsHaveMethodLevel typarams cs || hasMethodLevelConstraint typarams t
hasMethodLevelConstraint typarams (TyEffect _ _ t) =
  hasMethodLevelConstraint typarams t
hasMethodLevelConstraint _ _ = False

constraintsHaveMethodLevel : List String -> List Constraint -> Bool
constraintsHaveMethodLevel _ [] = False
constraintsHaveMethodLevel typarams (c :: rest) =
  constraintIsMethodLevel typarams c || constraintsHaveMethodLevel typarams rest

instantiateMethodPredicateTemplate : GraphCtx ->
  MethodPredicateTemplate ->
  MethodInstantiationSubst ->
  MethodPredicateTemplate
instantiateMethodPredicateTemplate gctx template subst = MethodPredicateTemplate {
  mptInterface = template.mptInterface,
  mptArguments =
    map (instantiateMethodPredicateArgument gctx subst) template.mptArguments,
}

instantiateMethodPredicateArgument : GraphCtx ->
  MethodInstantiationSubst ->
  Option Mono ->
  Option Mono
instantiateMethodPredicateArgument gctx subst argument =
  map
    (substMono gctx subst.misTypeSubst subst.misEffectSubst subst.misAuthSubst)
    argument

-- One fresh variable per interface parameter [mty] never mentions.  DICT-SEMANTICS
-- §5: the dispatch vector is fixed by the use site's instantiation of the whole
-- interface, wherever (or whether) a parameter appears in the method's type, so the
-- occurrence poses that position at a variable of its own for §3 to determine.
omittedParamVars : ModuleCtx -> List String -> Ty -> List (String, Mono)
omittedParamVars mctx typarams mty =
  let named = tyVarNames (stripTyConstraints mty)
  map
    (tp => (tp, freshVar mctx ()))
    (filterList (tp => not (contains tp named)) typarams)

-- `omittedParamVars` for the method [name] resolves to here, when it dispatches on
-- an argument.  None for a name with no single declaring interface, nor for a
-- return-dispatched method, whose occurrence mints its own beside its predicate
-- template (`methodReturnRequest`).
export
methodOmittedVars : ModuleCtx -> String -> List (String, Mono)
methodOmittedVars mctx name = match (
  argDispatchOf mctx name,
  methodEntryHere mctx name,
)
  (Some _, Some (_, typarams, mty, _)) => omittedParamVars mctx typarams mty
  _ => []

-- #818 (#838 I3): the method-level `=>` constraints, one per slot, in the declaration
-- order methodLevelConstraintVarNames enumerates.  recordMethodLevelObls poses each as
-- its own obligation; the slot's interface identity is the `Constraint` occurrence's
-- resolve stamp (`constraintOrigin`, #1110, P1 #1446).
methodLevelConstraintSlots : List String -> Ty -> List Constraint
methodLevelConstraintSlots typarams (TyConstrained cs t) =
  filterList (constraintIsMethodLevel typarams) cs
    ++ methodLevelConstraintSlots typarams t
methodLevelConstraintSlots typarams (TyEffect _ _ t) =
  methodLevelConstraintSlots typarams t
methodLevelConstraintSlots _ _ = []

-- #818 (#838 I3): strip the leading `=>`/effect wrappers off a method's declared type,
-- leaving the bare function spine so matchTyMono can align it against a constraint-free
-- occurrence mono (mirrors the TyConstrained/TyEffect peel in methodLevelConstraintVarNames).
stripLeadingMethodConstraints : Ty -> Ty
stripLeadingMethodConstraints (TyConstrained _ t) =
  stripLeadingMethodConstraints t
stripLeadingMethodConstraints (TyEffect _ _ t) = stripLeadingMethodConstraints t
stripLeadingMethodConstraints t = t

-- The `=>`-constrained-function dict-name set `elaborateModules` hands to prePass and
-- dictPass, which must see the same set: the prelude's constrained names, then the
-- full `constrainedSigNames` of every module (not the return-position subset:
-- dictPass gives a leading dict parameter to every function whose signature is
-- constrained, so a mark set that omitted `quad : Monoid a => a -> a` would leave
-- its call sites unmarked).  The prelude's names are the one prelude-only input, so
-- a driver with a prelude key derives them once per process.
moduleDictNames : List String -> List (String, List Decl) -> List String
moduleDictNames preludeNames modules =
  preludeNames ++ constrainedSigNames (flatMap snd modules)

argRwOf : MarkCtx ->
  OrdMap Unit ->
  (String -> EvId -> Unit) ->
  (String -> Bool) ->
  ArgRw
argRwOf mc dn onDict granted = ArgRw mc.mcRp dn mc.mcAn mc.mcSm onDict granted

-- Mark the declarations of one module that are not binding groups (impl, default,
-- prop and test bodies) with the module's final dict-name set.  Binding
-- groups were marked on the schedule (`markGroupClauses`) and are left alone.
export
markTailDecls : ModuleCtx ->
  MarkCtx ->
  OrdMap Unit ->
  (String -> Bool) ->
  List Decl ->
  List Decl
markTailDecls mctx mc dn granted decls =
  map (markTailDecl mctx (argRwOf mc dn noDictHook granted)) decls

markTailDecl : ModuleCtx -> ArgRw -> Decl -> Decl
markTailDecl mctx _ (d@(DFunDef _ _ _ _ _ _)) = d
markTailDecl mctx _ (d@(DLetGroup _ _)) = d
markTailDecl mctx rw (DAttrib attrs d) = DAttrib attrs (markTailDecl mctx rw d)
markTailDecl mctx rw d = prePassDeclScoped mctx rw d

markClauseWith : ModuleCtx -> ArgRw -> (List Pat, Expr) -> (List Pat, Expr)
markClauseWith mctx rw (ps, e) =
  (ps, rewriteArgScoped mctx rw (boundOfList (patVarsListTc ps)) e)

export
evIdModule : EvId -> String
evIdModule (EvId m _) = m

-- `allDecls` IS `coreDecls ++ flatMap snd modules` -- the envelope's
-- `deAllDecls`, see `declEnvDeclsOf` -- and every list split on that seam here is
-- a `flatMap` over decls (`returnPosMethodNames`, `methodConstraintNames`,
-- `argDispatchIndices`, `argDispatchIndicesById`), so `f (xs ++ ys)` is
-- `f xs ++ f ys` for each.  That is what makes the prelude half separable WITHOUT
-- changing the order any of them produces, and the order is observable: `dedup`
-- keeps the first occurrence.
export
markSetsOf : GraphCtx ->
  PreludeMarkFacts ->
  List Decl ->
  List (String, List Decl) ->
  List Decl ->
  MarkSets
markSetsOf gctx pmf coreDecls modules allDecls =
  -- P0-18: recover the definer-shadow map from the (already-mangled on the emit path)
  -- decls BEFORE marking/typecheck reads it.  Empty on the un-mangled path.  Set once
  -- here; per-module `freshModuleCtx` (in checkModuleFullImpl) does NOT clear it.
  let units = ("core", coreDecls) :: modules
  let userDecls = flatMap snd modules
  let shadowMap = computeMangledShadowMap allDecls units
  gctx.mangledShadowMapRef := shadowMap
  gctx.argDispatchIdxByIdRef :=
    pmf.pmfArgDispatchById ++ argDispatchIndicesById userDecls
  let rpNames = pmf.pmfReturnPos ++ returnPosMethodNames userDecls
  let markSharedNames =
    dedup
      (rpNames ++ pmf.pmfMethodConstraints ++ methodConstraintNames userDecls)
  let graphShadowNames =
    buildStandaloneShadowsGraph shadowMap allDecls userDecls
  let ms = MarkSets {
    msMarkRpNames = dedup (markSharedNames ++ graphShadowNames),
    msMarkSharedNames = markSharedNames,
    msGraphShadowNames = graphShadowNames,
    msArgNames = map fst (pmf.pmfArgDispatch ++ argDispatchIndices userDecls),
    msCoreShadowMap = coreShadowMapFor gctx coreDecls shadowMap,
    msBareDictNames = dedup (moduleDictNames pmf.pmfConstrainedNames modules),
    msUnits = units,
  }
  gctx.markSetsRef := Some ms
  ms

-- The dict-name set `dictPass` consumes: [names] (the bare set plus every promotion
-- the graph made) and its import aliases across every module.  The same names, per
-- module, are what `beginModuleMarking` marked with — the def side and the call side
-- must agree on this set or the callee is under-applied (`unbound identifier:
-- $dict_…`, the Phase-134 shape).
--
-- IMPORT ALIASING: the marker rewrites a call site `EVar n` into a dict application
-- only when `n` is in the dict-name set — a set of DEFINITION names.  An aliased call
-- site writes the LOCAL name, so unless the alias locals are added the call is never
-- marked, receives no dict arguments, and silently UNDER-APPLIES: `check` stays
-- green and `run` dies downstream with a type-confused value.
export
markDictNames : GraphCtx ->
  List String ->
  List Decl ->
  List (String, List Decl) ->
  List String
markDictNames gctx names coreDecls modules =
  dedup
    (names
      ++ aliasDictNames gctx names (("core", coreDecls) :: modules) modules)

-- Mark one binding group's clauses (in the stored, newest-first order the map keeps)
-- with the dict-name set as it stands when the schedule reaches the group.  A use
-- of a member, or of a name whose scheme in [env] quantifies an authority, is
-- given a grant identity: a member's scheme is not known until the group closes.
export
markGroupClauses : ModuleMarking ->
  TcEnv ->
  List String ->
  OrdMap (List (List Pat, Expr)) ->
  OrdMap (List (List Pat, Expr))
markGroupClauses mm env members grouped =
  let own = omFromNames members omEmpty
  mapGroupClauses
    (markClauseWith
      env.teDyn.dcModule
      (argRwOf mm.mmCtx mm.mmDictSet.value noDictHook (n =>
        omHasKey n own || grantNameIn env n)))
    members
    grouped

export
mapGroupClauses : ((List Pat, Expr) -> (List Pat, Expr)) ->
  List String ->
  OrdMap (List (List Pat, Expr)) ->
  OrdMap (List (List Pat, Expr))
-- The map keeps a name's clauses newest-first (`groupClausesGo`); `f` is applied in
-- SOURCE order (`clausesOf`) so the evidence ids it mints follow the source, and the
-- result is stored back in the map's own order.
mapGroupClauses _ [] grouped = grouped
mapGroupClauses f (m :: rest) grouped =
  mapGroupClauses
    f
    rest
    (omInsert m (reverse (map f (clausesOf m grouped))) grouped)

-- At group close: the members this group promoted join the dict-name set, and the
-- group's own occurrences of them — the recursive calls, which were still `EVar`
-- when the group was marked because their callee had not generalized — become
-- dict applications.  Each carries the goal `inferDictAtFound`'s recursive arm
-- pushes for a callee that is a placeholder of the current group (`RecDictApp`,
-- realized at the graph-end drain against the callee's now-registered slots): the
-- callee's placeholder mono is the occurrence's instantiated type, the enclosing
-- member is the clause's own.  That arm is the ONLY effect the recursive arm has
-- beyond returning the instantiated type, which the `EVar` path returned too, so
-- rewriting after inference leaves the group's inference unchanged.
export
markRecursiveOccurrences : ModuleCtx ->
  ModuleMarking ->
  List (String, Mono) ->
  List ScopedMember ->
  OrdMap (List (List Pat, Expr)) ->
  OrdMap (List (List Pat, Expr))
markRecursiveOccurrences mctx mm placeholders scopedMembers grouped =
  -- `promotedRef` is this module's promoted names so far (cumulative within the
  -- module); a member already in the dict-name set — a bare-name collision with a
  -- signatured graph name or an earlier module's promotion — was marked before
  -- inference and needs nothing here.
  let promoted = omFromNames mctx.mcCells.promotedRef.value omEmpty
  let fresh =
    filterList
      (m => omHasKey m promoted && not (omHasKey m mm.mmDictSet.value))
      (map (member => member.smName) scopedMembers)
  match fresh
    [] => grouped
    _ =>
      mm.mmDictSet := omFromNames fresh mm.mmDictSet.value
      recMarkMembers
        mctx
        (omFromNames fresh omEmpty)
        placeholders
        scopedMembers
        grouped

recMarkMembers : ModuleCtx ->
  OrdMap Unit ->
  List (String, Mono) ->
  List ScopedMember ->
  OrdMap (List (List Pat, Expr)) ->
  OrdMap (List (List Pat, Expr))
recMarkMembers mctx _ _ [] grouped = grouped
recMarkMembers mctx dn placeholders (member :: rest) grouped =
  let m = member.smName
  let onDict =
    callee ev =>
      pushRecDictAppGoal
        mctx.mcGraph
        (RecDictApp
          (Ref [])
          callee
          m
          (placeholderMonoOf callee placeholders)
          member.smScope
          ev)
  let rw = ArgRw omEmpty dn omEmpty [] onDict (_ => False)
  recMarkMembers
    mctx
    dn
    placeholders
    rest
    (mapGroupClauses (markClauseWith mctx rw) [m] grouped)

placeholderMonoOf : String -> List (String, Mono) -> Mono
placeholderMonoOf callee placeholders = match lookupAssoc callee placeholders
  Some v => v
  None =>
    panic "markRecursiveOccurrences: \{callee} is not a member of the group"

-- Write each group's marked clauses back over the declarations that produced them.
-- `funDefs` flattens `DFunDef` clauses and `DLetGroup` bindings in declaration
-- order and `clausesOf` returns a name's clauses in that order, so consuming them
-- head-first as the declarations are walked restores every clause to its own slot.
-- The arms below are `funDefs`' arms, and must stay that set: a declaration shape
-- `funDefs` collects clauses from but this walk passes through would drop those
-- clauses' marks from the returned tree without a panic (the reverse direction
-- panics in `popMarkedClause`).
export
rebuildGroupDecls : OrdMap (List (List Pat, Expr)) -> List Decl -> List Decl
rebuildGroupDecls grouped prog = fst (rebuildGroupDeclsGo grouped omEmpty prog)

rebuildGroupDeclsGo : OrdMap (List (List Pat, Expr)) ->
  OrdMap (List (List Pat, Expr)) ->
  List Decl ->
  (List Decl, OrdMap (List (List Pat, Expr)))
rebuildGroupDeclsGo _ pending [] = ([], pending)
rebuildGroupDeclsGo grouped pending ((DFunDef pub n _ _ site bid) :: rest) =
  let ((ps, e), pending2) = popMarkedClause grouped pending n
  let (ds, pending3) = rebuildGroupDeclsGo grouped pending2 rest
  (DFunDef pub n ps e site bid :: ds, pending3)
rebuildGroupDeclsGo grouped pending ((DLetGroup pub binds) :: rest) =
  let (binds2, pending2) = rebuildLetBinds grouped pending binds
  let (ds, pending3) = rebuildGroupDeclsGo grouped pending2 rest
  (DLetGroup pub binds2 :: ds, pending3)
rebuildGroupDeclsGo grouped pending ((DAttrib attrs d) :: rest) =
  let (inner, pending2) = rebuildGroupDeclsGo grouped pending [d]
  let (ds, pending3) = rebuildGroupDeclsGo grouped pending2 rest
  (map (d2 => DAttrib attrs d2) inner ++ ds, pending3)
rebuildGroupDeclsGo grouped pending (d :: rest) =
  let (ds, pending2) = rebuildGroupDeclsGo grouped pending rest
  (d :: ds, pending2)

rebuildLetBinds : OrdMap (List (List Pat, Expr)) ->
  OrdMap (List (List Pat, Expr)) ->
  List LetBind ->
  (List LetBind, OrdMap (List (List Pat, Expr)))
rebuildLetBinds _ pending [] = ([], pending)
rebuildLetBinds grouped pending ((LetBind n clauses site bid) :: rest) =
  let (clauses2, pending2) = rebuildFunClauses grouped pending n clauses
  let (binds, pending3) = rebuildLetBinds grouped pending2 rest
  (LetBind n clauses2 site bid :: binds, pending3)

rebuildFunClauses : OrdMap (List (List Pat, Expr)) ->
  OrdMap (List (List Pat, Expr)) ->
  String ->
  List FunClause ->
  (List FunClause, OrdMap (List (List Pat, Expr)))
rebuildFunClauses _ pending _ [] = ([], pending)
rebuildFunClauses grouped pending n (_ :: rest) =
  let ((ps, e), pending2) = popMarkedClause grouped pending n
  let (cs, pending3) = rebuildFunClauses grouped pending2 n rest
  (FunClause ps e :: cs, pending3)

-- The next unconsumed marked clause of [n]: `pending` holds the clauses not yet
-- written back, in source order, minted from `clausesOf` on first use.
popMarkedClause : OrdMap (List (List Pat, Expr)) ->
  OrdMap (List (List Pat, Expr)) ->
  String ->
  ((List Pat, Expr), OrdMap (List (List Pat, Expr)))
popMarkedClause grouped pending n =
  let remaining = match omLookup n pending
    Some cs => cs
    None => clausesOf n grouped
  match remaining
    c :: cs => (c, omInsert n cs pending)
    [] => panic "rebuildGroupDecls: no marked clause left for \{n}"

-- test-only observation: declarations whose only callers are tests and probes.

-- Test visibility (`typecheck_test.mdk` and `tc_occurrence_test.mdk`): each goal of
-- [gctx]'s graph that writes a method cell's route or dictionaries, by kind, with
-- whether its `oInner` is that cell's `ecInner`, so the stampers' notes reach the judgment (`judgeCells`).  Read
-- by writing a marker through the goal's refs and looking for it in the cells, then
-- restoring both.  A goal whose destination is no cell's (a throwaway) is skipped.
export
cellGoalInnerAliasing : GraphCtx -> List (String, Bool)
cellGoalInnerAliasing gctx =
  let g = gctx.graphRun
  let cells = cellsFrom g.evCells.value 0 []
  filterMap
    (o =>
      map (c => (goalKindName o.oKind, innerAliases o c)) (cellOfGoal cells o))
    g.goals.value

cellsFrom : Array (Option EvCell) -> Int -> List EvCell -> List EvCell
cellsFrom arr i acc
  | i >= arrayLength arr = reverseL acc
  | otherwise = match arrayGetUnsafe i arr
    Some c => cellsFrom arr (i + 1) (c :: acc)
    None => cellsFrom arr (i + 1) acc

cellOfGoal : List EvCell -> Obligation -> Option EvCell
cellOfGoal cells o = match o.oDest
  EvRoute r =>
    let saved = r.value
    r := RLocal aliasMarker []
    let hit = filterList (c => isAliasMarker c.ecTag.value) cells
    r := saved
    onlyCell hit
  EvRoutes rs =>
    let saved = rs.value
    rs := [RLocal aliasMarker []]
    let hit =
      filterList
        (c => anyList isAliasMarker (c.ecImpl.value ++ c.ecMeth.value))
        cells
    rs := saved
    onlyCell hit

onlyCell : List EvCell -> Option EvCell
onlyCell [c] = Some c
onlyCell _ = None

aliasMarker : String
aliasMarker = "<inner-alias-probe>"

isAliasMarker : Route -> Bool
isAliasMarker (RLocal sym _) = sym == aliasMarker
isAliasMarker _ = False

innerAliases : Obligation -> EvCell -> Bool
innerAliases o c =
  let savedGoal = o.oInner.value
  let savedCell = c.ecInner.value
  c.ecInner := innerNone
  o.oInner := Inner True True
  let hit = match c.ecInner.value
    Inner True True => True
    _ => False
  o.oInner := savedGoal
  c.ecInner := savedCell
  hit

-- Test visibility (`tc_occurrence_test.mdk`): why [gctx]'s site and method cell stores
-- hold no cell for [ev], each "" where one does.
export
cellStoreMisses : GraphCtx -> EvId -> (String, String)
cellStoreMisses gctx ev = (
  missText (siteCellLookup gctx ev),
  missText (methodCellLookup gctx ev),
)

missText : Result String a -> String
missText (Ok _) = ""
missText (Err message) = message

export
firstMethodRow : List MethodSchemeRow -> MethodSchemeRow
firstMethodRow (row :: _) = row
firstMethodRow [] = panic "method-row observer expected a row"

observeMethodSchemeRowsForTest : Unit -> MethodRowTestObservation
observeMethodSchemeRowsForTest _ =
  let graph1 = probeGraphCtx ()

  let rows1 = initialModuleCtx graph1
  let constrainedRow =
    firstMethodRow (ifaceMethodSchemeRows rows1 [methodRowTestFoldMapDecl])
  let constrainedIds = schemeIds constrainedRow.msrScheme
  let constrainedSlots = constrainedRow.msrMethodSlots
  let constrainedBoundIds = methodSlotBoundIds constrainedSlots
  let constrainedPositions = methodSlotPositions constrainedSlots
  let constrainedIdsAtPositions =
    methodSlotIdsAtPositions constrainedIds constrainedSlots
  let constrainedArgumentIds = methodSlotArgumentIds constrainedSlots

  let graph2 = freshSubRecordsOf graph1
  let rows2 = carryModuleCtx graph2 rows1
  let counterBefore = graph2.graphRun.tyvarCounter.value
  let firstRow =
    firstMethodRow (ifaceMethodSchemeRows rows2 [methodRowTestFoldMapDecl])
  let counterAfterFirst = graph2.graphRun.tyvarCounter.value
  let secondRow =
    firstMethodRow (ifaceMethodSchemeRows rows2 [methodRowTestFoldMapDecl])
  let counterAfterSecond = graph2.graphRun.tyvarCounter.value
  let firstSchemeIds = schemeIds firstRow.msrScheme
  let secondSchemeIds = schemeIds secondRow.msrScheme
  let firstRowSlotIds = methodSlotBoundIds firstRow.msrMethodSlots
  let secondRowSlotIds = methodSlotBoundIds secondRow.msrMethodSlots
  let registryAfterSecondSlotIds =
    methodRowRegistrySlotIds rows2 (methodSlotKey firstRow.msrIface "foldMap")

  let graph3 = freshSubRecordsOf graph1
  let rows3 = carryModuleCtx graph3 rows2
  let sameNameForward =
    methodRowSameNameView
      (ifaceMethodSchemeRows rows3 [methodRowTestSameA, methodRowTestSameB])
  let graph4 = freshSubRecordsOf graph1
  let rows4 = carryModuleCtx graph4 rows3
  let sameNameReverse =
    methodRowSameNameView
      (ifaceMethodSchemeRows rows4 [methodRowTestSameB, methodRowTestSameA])

  let graph5 = freshSubRecordsOf graph1
  let rows5 = carryModuleCtx graph5 rows4
  let constantRows = ifaceMethodSchemeRows rows5 [methodRowTestConstantDecl]
  let constantRow = firstMethodRow constantRows
  let constantBodyIsFunction =
    match normalize (schemeBodyOf constantRow.msrScheme)
      TFun _ _ _ => True
      _ => False

  let graph6 = freshSubRecordsOf graph1
  let rows6 = carryModuleCtx graph6 rows5
  let attributed = DAttrib [] methodRowTestFoldMapDecl
  let attributedRows = ifaceMethodSchemeRows rows6 [attributed]
  let attributedMethods =
    methodEnvGo
      graph6
      [declEnvModule graph6 0 "foldable-test" [attributed]]
      emptyMethodEnv
  let (attributedParamIface, attributedParamTyparams) =
    match optionOr [] (omLookup "foldMap" attributedMethods.meByName)
      [] => ("", [])
      r :: _ => match r.mrEntry
        (iface, typarams, _, _) => (iface.irName, typarams)

  let directNum =
    methodRowTestNum
      "direct-num"
      (TyFun (tyConBuiltin "String" None) (TyVar "a"))
  let attributedNum =
    DAttrib
      []
      (methodRowTestNum
        "attributed-num"
        (TyFun (tyConBuiltin "Int" None) (TyVar "a")))
  let builtinNum =
    methodRowTestNum "builtin-num" (TyFun (tyConBuiltin "Int" None) (TyVar "a"))
  let numAnchors = [
    methodRowNumObservation rows6 "attrOnly" [attributedNum] [attributedNum],
    methodRowNumObservation rows6 "directOnly" [directNum] [directNum],
    methodRowNumObservation
      rows6
      "attrThenDirect"
      [attributedNum, directNum]
      [attributedNum, directNum],
    methodRowNumObservation
      rows6
      "directThenAttr"
      [directNum, attributedNum]
      [directNum, attributedNum],
    methodRowNumObservation
      rows6
      "builtinThenUser"
      [builtinNum]
      [builtinNum, methodRowTestUserFromInt],
    methodRowNumObservation
      rows6
      "userThenBuiltin"
      [builtinNum]
      [methodRowTestUserFromInt, builtinNum],
  ]

  let observation = MethodRowTestObservation {
    mrtoSchemeIds = constrainedIds,
    mrtoSlotBoundIds = constrainedBoundIds,
    mrtoSlotPositions = constrainedPositions,
    mrtoSlotIdsAtPositions = constrainedIdsAtPositions,
    mrtoSlotArgumentIds = constrainedArgumentIds,
    mrtoCounterBefore = counterBefore,
    mrtoCounterAfterFirst = counterAfterFirst,
    mrtoCounterAfterSecond = counterAfterSecond,
    mrtoFirstSchemeIds = firstSchemeIds,
    mrtoSecondSchemeIds = secondSchemeIds,
    mrtoFirstRowSlotIds = firstRowSlotIds,
    mrtoSecondRowSlotIds = secondRowSlotIds,
    mrtoRegistryAfterSecondSlotIds = registryAfterSecondSlotIds,
    mrtoSameNameForward = sameNameForward,
    mrtoSameNameReverse = sameNameReverse,
    mrtoConstantRowCount = listLen constantRows,
    mrtoConstantSchemeIdCount = listLen (schemeIds constantRow.msrScheme),
    mrtoConstantBodyIsFunction = constantBodyIsFunction,
    mrtoConstantSlotCount = listLen constantRow.msrMethodSlots,
    mrtoAttributedRowCount = listLen attributedRows,
    mrtoAttributedParamIface = attributedParamIface,
    mrtoAttributedParamTyparams = attributedParamTyparams,
    mrtoNumAnchors = numAnchors,
  }
  observation

methodRowSlotAllocationProbe : Unit ->
  (List Int, List (List Int), List (List Int), List (List Int), List (List Int))
methodRowSlotAllocationProbe _ =
  let observed = observeMethodSchemeRowsForTest ()
  (
    observed.mrtoSchemeIds,
    observed.mrtoSlotBoundIds,
    observed.mrtoSlotPositions,
    observed.mrtoSlotIdsAtPositions,
    observed.mrtoSlotArgumentIds,
  )

-- > methodRowSlotAllocationProbe ()
-- ([0, 1, 2], [[1]], [[1]], [[1]], [[1]])

methodRowFreshnessProbe : Unit ->
  ((Int, Int, Int, List Int, List Int), (List (List Int), List (List Int), List (List Int)))
methodRowFreshnessProbe _ =
  let observed = observeMethodSchemeRowsForTest ()
  (
    (
      observed.mrtoCounterBefore,
      observed.mrtoCounterAfterFirst,
      observed.mrtoCounterAfterSecond,
      observed.mrtoFirstSchemeIds,
      observed.mrtoSecondSchemeIds,
    ),
    (
      observed.mrtoFirstRowSlotIds,
      observed.mrtoSecondRowSlotIds,
      observed.mrtoRegistryAfterSecondSlotIds,
    ),
  )

-- > methodRowFreshnessProbe ()
-- ((0, 3, 6, [0, 1, 2], [3, 4, 5]), ([[1]], [[4]], [[1]]))

methodRowDeclarationProbe : Unit ->
  (List (String, String, Int, Int), List (String, String, Int, Int), (Int, Int, Bool, Int))
methodRowDeclarationProbe _ =
  let observed = observeMethodSchemeRowsForTest ()
  (
    observed.mrtoSameNameForward,
    observed.mrtoSameNameReverse,
    (
      observed.mrtoConstantRowCount,
      observed.mrtoConstantSchemeIdCount,
      observed.mrtoConstantBodyIsFunction,
      observed.mrtoConstantSlotCount,
    ),
  )

-- > methodRowDeclarationProbe ()
-- ([("A", "same", 0, 0), ("A", "extra", 0, 0), ("B", "same", 1, 1)], [("B", "same", 1, 1), ("A", "same", 0, 0), ("A", "extra", 0, 0)], (1, 0, False, 0))

methodRowNumericAnchorProbe : Unit ->
  (Int, String, List String, List (String, Bool, Bool, String, String))
methodRowNumericAnchorProbe _ =
  let observed = observeMethodSchemeRowsForTest ()
  (
    observed.mrtoAttributedRowCount,
    observed.mrtoAttributedParamIface,
    observed.mrtoAttributedParamTyparams,
    map numAnchorObservationView observed.mrtoNumAnchors,
  )

-- > methodRowNumericAnchorProbe ()
-- (0, "Foldable", ["t"], [("attrOnly", False, False, "", ""), ("directOnly", True, True, "String -> a", "String -> a"), ("attrThenDirect", False, False, "", ""), ("directThenAttr", True, True, "String -> a", "String -> a"), ("builtinThenUser", True, True, "Int -> a", "Int -> a"), ("userThenBuiltin", True, True, "Int -> a", "Int -> a")])

export
methodReturnProbeRequest : ModuleCtx -> MethodSchemeRow -> MethodReturnRequest
methodReturnProbeRequest mctx row =
  let inst = methodReturnProbeOccurrence mctx row
  methodReturnRequest
    mctx
    row
    inst.mtiBody
    inst.mtiSubstitution
    (Some (freshEvId mctx ()))

methodReturnVectorCompletenessProbe : Unit ->
  (Option (List String), Option (List String), Bool, Bool)
methodReturnVectorCompletenessProbe _ =
  let gctx = probeGraphCtx ()
  let mctx = initialModuleCtx gctx
  let _ = methodReturnProbeScope mctx "return-vector"
  let zeroRow =
    firstMethodRow
      (ifaceMethodSchemeRows mctx [
        methodRowTestIface "return-zero" "Zero" [] [
          IfaceMethod
            "make"
            (TyFun (tyConBuiltin "Unit" None) (tyConBuiltin "Int" None))
            None
            None,
        ],
      ])
  let partialRow =
    firstMethodRow
      (ifaceMethodSchemeRows mctx [
        methodRowTestIface
          "return-partial"
          "Partial"
          ["a", "b"]
          [
            IfaceMethod
              "make"
              (TyFun (tyConBuiltin "Unit" None) (TyVar "a"))
              None
              None,
          ],
      ])
  let zeroArgs =
    map
      (map ppMono)
      (methodReturnArgs gctx (methodReturnProbeRequest mctx zeroRow))
  let partialArgs =
    map
      (map ppMono)
      (methodReturnArgs gctx (methodReturnProbeRequest mctx partialRow))
  let observed = (
    zeroArgs,
    partialArgs,
    allMethodParamsMentioned zeroRow.msrTyparams zeroRow.msrType,
    allMethodParamsMentioned partialRow.msrTyparams partialRow.msrType,
  )
  observed

-- The absent `b` of `Partial` reads the occurrence's own unbound variable.
-- > methodReturnVectorCompletenessProbe ()
-- (Some [], Some ["Int", "a"], True, False)

export
methodReturnTemplatePresenceProbe : Unit -> (List Bool, List Bool)
methodReturnTemplatePresenceProbe _ =
  let gctx = probeGraphCtx ()
  let mctx = initialModuleCtx gctx
  let present =
    firstMethodRow
      (ifaceMethodSchemeRows mctx [
        methodRowTestIface
          "return-template-present"
          "Present"
          ["a", "b"]
          [
            IfaceMethod
              "make"
              (TyFun
                (tyConBuiltin "Unit" None)
                (TyTuple [TyVar "a", TyVar "b"]))
              None
              None,
          ],
      ])
  let absent =
    firstMethodRow
      (ifaceMethodSchemeRows mctx [
        methodRowTestIface
          "return-template-absent"
          "Absent"
          ["a", "b"]
          [
            IfaceMethod
              "make"
              (TyFun (tyConBuiltin "Unit" None) (TyVar "a"))
              None
              None,
          ],
      ])
  let observed = (
    map isSome present.msrPredicateTemplate.mptArguments,
    map isSome absent.msrPredicateTemplate.mptArguments,
  )
  observed

-- Runs in a carry of [prev], the caller's record, in its graph record with a fresh
-- graph run, and returns it beside the codes: it is the record left current.
export
methodReturnProbeCodes : ModuleCtx ->
  MethodSchemeRow ->
  List Decl ->
  (List String, ModuleCtx)
methodReturnProbeCodes prev ownedRow impls =
  let gctx = GraphCtx { prev.mcGraph | graphRun = freshGraphRun () }
  let mctx = carryModuleCtx gctx prev
  let _ = methodReturnProbeScope mctx "return-owner-checker"
  let foreignRow =
    firstMethodRow
      (ifaceMethodSchemeRows mctx [
        methodReturnProbeIface
          "return-foreign"
          "Foreign"
          (TyFun (tyConBuiltin "Unit" None) (TyVar "a")),
      ])
  let request = methodReturnProbeRequest mctx ownedRow
  methodReturnProbeSpelling mctx foreignRow
  let _ = recordExactMethodObligation mctx request
  let universe = buildImplUniverse impls
  mctx.mcCells.bodyImplEnvRef := buildFlatImplEnv impls
  checkCallObligationsU mctx True universe (wAll mctx.mcCells.implObls)
  (map tcCode (reverseL mctx.mcCells.typeErrors.items.value), mctx)

export
methodReturnResolutionMutationProbe : Unit -> (Bool, Bool, Bool, Bool)
methodReturnResolutionMutationProbe _ =
  let gctx = probeGraphCtx ()
  let mctx = initialModuleCtx gctx
  let _ = methodReturnProbeScope mctx "return-outcome-validation"
  let ownedDecl =
    methodReturnProbeIface
      "return-owner"
      "Owner"
      (TyFun (tyConBuiltin "Unit" None) (TyVar "a"))
  let ownedRow = firstMethodRow (ifaceMethodSchemeRows mctx [ownedDecl])
  let ownedImpl = methodReturnProbeImpl "return-owner" "Owner"
  mctx.mcCells.bodyImplEnvRef := buildFlatImplEnv [ownedImpl]
  let request = methodReturnProbeRequest mctx ownedRow
  let resolution = solveExactReturnOnce (siteFor mctx) request
  let valid = methodReturnResolutionValid mctx request resolution
  let (wrongSelection, wrongPrerequisites) = match resolution.mrrOutcome
    Solved (InstanceEvidence _ args prerequisites supers) => (
      MethodReturnResolution {
        mrrWanted = resolution.mrrWanted,
        mrrOutcome =
          Solved
            (InstanceEvidence
              (RequestInstanceId (-1))
              args
              prerequisites
              supers),
        mrrSelectedRow = resolution.mrrSelectedRow,
      },
      MethodReturnResolution {
        mrrWanted = resolution.mrrWanted,
        mrrOutcome =
          Solved
            (InstanceEvidence
              (RequestInstanceId (methodReturnSelectedIdentity resolution))
              args
              (PrerequisiteEvidence {
                  prerequisiteInterface =
                    resolution.mrrWanted.predicate.predicateInterface,
                  prerequisiteArguments = args,
                }
                :: prerequisites)
              supers),
        mrrSelectedRow = resolution.mrrSelectedRow,
      },
    )
    _ => panic "ordinary return mutation probe expected instance evidence"
  let wanted = resolution.mrrWanted
  let wrongWanted = Wanted {
    id = wanted.id,
    predicate = wanted.predicate,
    origin = wanted.origin,
    scope = ScopeId 999999,
    destination = wanted.destination,
  }
  let disagreement = MethodReturnResolution {
    mrrWanted = wrongWanted,
    mrrOutcome = resolution.mrrOutcome,
    mrrSelectedRow = resolution.mrrSelectedRow,
  }
  let observed = (
    valid,
    not (methodReturnResolutionValid mctx request wrongSelection),
    not (methodReturnResolutionValid mctx request wrongPrerequisites),
    not (methodReturnResolutionValid mctx request disagreement),
  )
  observed

-- Runs in a carry of [prev], the caller's record, in its graph record with a fresh
-- graph run, and returns it beside the observation: it is the record left current.
methodReturnProbeSlotCase : ModuleCtx ->
  MethodSchemeRow ->
  MethodSchemeRow ->
  Bool ->
  ((List String, List String), ModuleCtx)
methodReturnProbeSlotCase prev ownedRow foreignRow retainOwner =
  let gctx = GraphCtx { prev.mcGraph | graphRun = freshGraphRun () }
  let mctx = carryModuleCtx gctx prev
  let _ = methodReturnProbeScope mctx "return-owner-slots"
  mctx.mcCells.methodPredicateSlotsRef :=
    [(methodSlotKey foreignRow.msrIface "make", foreignRow.msrMethodSlots)]
  methodReturnProbeSpelling mctx foreignRow
  let env =
    if retainOwner then
      extendMethodRow (envFor mctx) "make" ownedRow
    else
      extendVar (envFor mctx) "make" ownedRow.msrScheme
  let inst = instantiateMethodTracked mctx ownedRow.msrScheme
  unify
    mctx
    (stripArrows inst.mtiBody)
    (tupleMono [tconBuiltin "Int", tconBuiltin "Int"])
  let _ =
    recordSite
      env
      "make"
      ownedRow.msrScheme
      (Ref "")
      (Ref RNone)
      (Ref [])
      (Ref [])
      (Ref innerNone)
      inst.mtiBody
      inst.mtiSubstitution
  (
    (
      methodReturnProbeOblIfaces (wAll mctx.mcCells.obls),
      methodReturnProbeGoalIfaces gctx.graphRun.goals.value,
    ),
    mctx,
  )

-- The retained row owns Seed, the same-name legacy table owns Decoy, and an empty
-- retained row is a known empty answer.  Only the missing-row compatibility control
-- may fall back to Decoy.
methodReturnSlotOwnershipProbe : Unit ->
  ((List String, List String), (List String, List String), (List String, List String))
methodReturnSlotOwnershipProbe _ =
  let ownedGraph = probeGraphCtx ()
  let ownedCtx = initialModuleCtx ownedGraph
  let ownedRow =
    firstMethodRow
      (ifaceMethodSchemeRows ownedCtx [
        methodReturnProbeIface
          "return-owner-slots"
          "OwnedSlots"
          (TyConstrained
            [methodRowTestConstraint "return-seed" "Seed" [TyVar "b"]]
            (TyFun (tyConBuiltin "Unit" None) (TyTuple [TyVar "b", TyVar "a"]))),
      ])
  let emptyGraph = GraphCtx { ownedGraph | graphRun = freshGraphRun () }
  let emptyCtx = carryModuleCtx emptyGraph ownedCtx
  let emptyRow =
    firstMethodRow
      (ifaceMethodSchemeRows emptyCtx [
        methodReturnProbeIface
          "return-empty-slots"
          "EmptySlots"
          (TyFun (tyConBuiltin "Unit" None) (TyVar "a")),
      ])
  let foreignGraph = GraphCtx { ownedGraph | graphRun = freshGraphRun () }
  let foreignCtx = carryModuleCtx foreignGraph emptyCtx
  let foreignRow =
    firstMethodRow
      (ifaceMethodSchemeRows foreignCtx [
        methodReturnProbeIface
          "return-foreign-slots"
          "ForeignSlots"
          (TyConstrained
            [methodRowTestConstraint "return-decoy" "Decoy" [TyVar "b"]]
            (TyFun (tyConBuiltin "Unit" None) (TyTuple [TyVar "b", TyVar "a"]))),
      ])
  let (retained, retainedCtx) =
    methodReturnProbeSlotCase foreignCtx ownedRow foreignRow True
  let (emptied, emptiedCtx) =
    methodReturnProbeSlotCase retainedCtx emptyRow foreignRow True
  let (missing, _) =
    methodReturnProbeSlotCase emptiedCtx ownedRow foreignRow False
  let observed = (retained, emptied, missing)
  observed

-- > methodReturnSlotOwnershipProbe ()
-- ((["Seed"], ["Seed"]), ([], []), (["Decoy"], ["Decoy"]))
# DESUGAR
(DUse false (UseGroup ("types" "tc_types") ((mem "SiteKind" true) (mem "OblProjection" true) (mem "NumericPredicateTraceStage" true) (mem "MethodReturnTraceStage" true) (mem "GoalPayload" true) (mem "EvDest" true) (mem "BuiltinClass" true) (mem "EvCell" true) (mem "GoalKind" true) (mem "GraphCtx" true) (mem "MarkSets" true) (mem "MethodPredicateTemplate" true) (mem "MethodReturnRequest" true) (mem "MethodReturnResolution" true) (mem "MethodRowTestObservation" true) (mem "Obligation" true) (mem "PendingDictApp" true) (mem "PendingMethodDict" true) (mem "Predicate" true) (mem "PredicateSlot" true) (mem "PredicateSlotArgs" true) (mem "Provenance" true) (mem "SelectedValueOccurrence" true) (mem "SiteCell" true) (mem "UObligation" true) (mem "ArgRw" false) (mem "CDeclared" false) (mem "CSlot" false) (mem "MarkCtx" false) (mem "MethodInstantiationSubst" false) (mem "MethodPredicateSlot" false) (mem "MethodSchemeRow" false) (mem "MethodTrackedInstantiation" false) (mem "ModuleCtx" false) (mem "ModuleMarking" false) (mem "PendingEntry" false) (mem "PreludeMarkFacts" false) (mem "RecDictApp" false) (mem "ScopedMember" false) (mem "ShadowDicts" false) (mem "siteFor" false) (mem "TcEnv" false) (mem "ValueScheme" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "allMethodParamsMentioned" false) (mem "argMentions" false) (mem "funArity" false) (mem "isBareTyvarMono" false) (mem "isMonoScheme" false) (mem "matchTyMono" false) (mem "nthFunDomain" false) (mem "patVarsListTc" false) (mem "patVarsTc" false) (mem "propParamNamesTc" false) (mem "rootIdOf" false) (mem "sameRootId" false) (mem "schemeBodyOf" false) (mem "schemeIds" false) (mem "stripArrows" false) (mem "stripTyConstraints" false) (mem "substMono" false) (mem "tconBuiltin" false) (mem "tconUnresolved" false) (mem "tupleMono" false) (mem "tyVarNames" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "carryModuleCtx" false) (mem "currentScopeStore" false) (mem "emptyMethodEnv" false) (mem "envAt" false) (mem "freshGraphRun" false) (mem "freshSubRecordsOf" false) (mem "initialModuleCtx" false) (mem "probeGraphCtx" false) (mem "wAll" false) (mem "wPush" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "bindingDeclared" false) (mem "buildFlatImplEnv" false) (mem "buildImplUniverse" false) (mem "builtinIfaceRef" false) (mem "declEnvModule" false) (mem "dispatchTyparams" false) (mem "envFor" false) (mem "extendMethodRow" false) (mem "extendVar" false) (mem "hasImportDefiner" false) (mem "lookupLocalFlag" false) (mem "lookupMethodRow" false) (mem "lookupVar" false) (mem "methodArgs" false) (mem "methodEnvGo" false) (mem "methodRowSameNameView" false) (mem "methodRowTestConstantDecl" false) (mem "methodRowTestConstraint" false) (mem "methodRowTestFoldMapDecl" false) (mem "methodRowTestIface" false) (mem "methodRowTestNum" false) (mem "methodRowTestSameA" false) (mem "methodRowTestSameB" false) (mem "methodRowTestUserFromInt" false) (mem "methodSlotKey" false) (mem "originMethodName" false) (mem "standaloneValueFor" false))))
(DUse false (UseGroup ("types" "tc_scope") ((mem "admittedIfaceWord" false) (mem "aliasDictNames" false) (mem "argDispatchOf" false) (mem "methodAdmittedHere" false) (mem "methodDispatchIdx" false) (mem "methodEntryHere" false) (mem "methodIfaceHere" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "captureScope" false) (mem "declaredCrossModuleObls" false) (mem "forceInstantiation" false) (mem "freshVar" false) (mem "instantiateLegacyVarTracked" false) (mem "instantiateMethodTracked" false) (mem "instantiateTracked" false) (mem "instantiateValueTracked" false) (mem "lookupQualPayload" false) (mem "lookupSchemeObls" false) (mem "openRow" false) (mem "qualConstraintDecl" false) (mem "qualConstraintKey" false) (mem "recordObl" false) (mem "recordOblAt" false) (mem "recordSchemeCallObligations" false) (mem "unify" false) (mem "unifyIn" false) (mem "zipSlotVecs" false))))
(DUse false (UseGroup ("types" "tc_decls_types") ((mem "fromAstType" false))))
(DUse false (UseGroup ("types" "tc_decls") ((mem "constraintIface" false) (mem "constraintIsMethodLevel" false) (mem "constraintVarNames" false) (mem "ifaceMethodSchemeRows" false) (mem "methodRowNumObservation" false))))
(DUse false (UseGroup ("types" "tc_solve_givens") ((mem "predicateSlotIds" false) (mem "predicateSlotIdsAt" false))))
(DUse false (UseGroup ("types" "tc_solve_entail") ((mem "noteNumericPredicateTrace" false))))
(DUse false (UseGroup ("types" "tc_solve") ((mem "builtinClassPresent" false) (mem "consSiteFn" false) (mem "goalKindName" false) (mem "isLocalAbsName" false) (mem "localSourceName" false) (mem "methodPredicateTemplateHasAbsent" false) (mem "methodReturnArgs" false) (mem "methodReturnProbeGoalIfaces" false) (mem "methodReturnProbeIface" false) (mem "methodReturnProbeImpl" false) (mem "methodReturnProbeOblIfaces" false) (mem "methodReturnProbeOccurrence" false) (mem "methodReturnProbeScope" false) (mem "methodReturnProbeSpelling" false) (mem "methodReturnResolutionValid" false) (mem "methodReturnSelectedIdentity" false) (mem "methodRowRegistrySlotIds" false) (mem "methodSlotArgumentIds" false) (mem "methodSlotBoundIds" false) (mem "methodSlotIdsAtPositions" false) (mem "methodSlotPositions" false) (mem "noteMethodReturnTrace" false) (mem "numAnchorObservationView" false) (mem "pushDictApp" false) (mem "pushGoal" false) (mem "returnPosMethodNames" false) (mem "routeLocalSym" false) (mem "solveExactReturnOnce" false))))
(DUse false (UseGroup ("types" "tc_solve_check") ((mem "checkCallObligationsU" false) (mem "dedupSlotVecs" false) (mem "dispatchMonosOf" false))))
(DUse false (UseGroup ("types" "tc_shadow") ((mem "buildStandaloneShadowsGraph" false) (mem "callArgVecsV" false) (mem "computeMangledShadowMap" false) (mem "constraintMonosOf" false) (mem "coreShadowMapFor" false) (mem "declaredConstraintFor" false) (mem "declaredEffectsAt" false) (mem "isDefinerShadow" false) (mem "isShadowStandalone" false) (mem "methodCellLookup" false) (mem "rejectAdmittedValueOccurrence" false) (mem "shadowDeclaredFor" false) (mem "shadowStandaloneDictSlots" false) (mem "shadowStandaloneDictSlotsAt" false) (mem "standaloneValueBinding" false) (mem "standaloneValueBindingEmit" false) (mem "standaloneValuePinned" false))))
(DUse false (UseGroup ("types" "tc_effects") ((mem "clausesOf" false) (mem "evOrdinal" false) (mem "grantNameIn" false) (mem "recordMethodGrantOcc" false) (mem "recordStandaloneGrantOcc" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Section" true) (mem "Arm" true) (mem "Constraint" true) (mem "Decl" true) (mem "DoStmt" true) (mem "EvId" true) (mem "Expr" true) (mem "FieldAssign" true) (mem "FunClause" true) (mem "Guard" true) (mem "GuardArm" true) (mem "IfaceMethod" true) (mem "ImplMethod" true) (mem "InterpPart" true) (mem "LetBind" true) (mem "Loc" true) (mem "MethodDefault" true) (mem "Pat" true) (mem "Route" true) (mem "Ty" true) (mem "isUnminted" false) (mem "negateLiteral" false) (mem "tyConBuiltin" false))))
(DUse false (UseGroup ("types" "solver_contract") ((mem "SolverOutcome" true) (mem "ClassPredicate" true) (mem "Wanted" true))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Mono" true) (mem "Scheme" true) (mem "lookupAssocI" false) (mem "normalize" false) (mem "ppMono" false))))
(DUse false (UseGroup ("types" "evidence_complete") ((mem "Inner" true) (mem "innerNone" false))))
(DUse false (UseGroup ("types" "evidence") ((mem "SolverEvidence" true) (mem "PrerequisiteEvidence" true) (mem "RequestInstanceId" true) (mem "ScopeId" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "anyList" false) (mem "contains" false) (mem "dedup" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "isSome" false) (mem "listLen" false) (mem "lookupAssoc" false) (mem "reverseL" false))))
(DUse false (UseGroup ("types" "chain_key") ((mem "constrainedSigName" false))))
(DUse false (UseGroup ("list") ((mem "get" false) (mem "reverse" false))))
(DUse false (UseGroup ("support" "char") ((mem "isUpper" false))))
(DUse false (UseGroup ("types" "publish") ((mem "tcCode" false))))
(DUse false (UseAlias ("map") "IdMap"))
(DUse false (UseAlias ("types" "scopes") "Scopes"))
(DTypeSig false "siteObligation" (TyFun (TyCon "GoalKind") (TyFun (TyApp (TyCon "Ref") (TyCon "Inner")) (TyFun (TyCon "PendingEntry") (TyCon "Obligation")))))
(DFunDef false "siteObligation" ((PVar "k") (PVar "inner") (PCon "PendingEntry" (PVar "name") (PVar "tagRef") (PVar "m") (PVar "encl") (PVar "site") (PVar "loc") (PVar "scope") (PVar "ev"))) (ERecordCreate "Obligation" ((fa "oKind" (EVar "k")) (fa "oDest" (EApp (EVar "EvRoute") (EVar "tagRef"))) (fa "oEv" (EVar "ev")) (fa "oEncl" (EVar "encl")) (fa "oLoc" (EVar "loc")) (fa "oScope" (EVar "scope")) (fa "oPayload" (EApp (EApp (EApp (EVar "GPSite") (EVar "name")) (EVar "m")) (EVar "site"))) (fa "oInner" (EVar "inner")))))
(DTypeSig true "pushSiteGoal" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "GoalKind") (TyFun (TyApp (TyCon "Ref") (TyCon "Inner")) (TyFun (TyCon "PendingEntry") (TyCon "Unit"))))))
(DFunDef false "pushSiteGoal" ((PVar "gctx") (PVar "k") (PVar "inner") (PVar "e")) (EApp (EApp (EVar "pushGoal") (EVar "gctx")) (EApp (EApp (EApp (EVar "siteObligation") (EVar "k")) (EVar "inner")) (EVar "e"))))
(DTypeSig false "pushArithGoal" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyCon "Mono") (TyFun (TyCon "EvId") (TyCon "Unit"))))))
(DFunDef false "pushArithGoal" ((PVar "mctx") (PVar "dref") (PVar "m") (PVar "ev")) (EApp (EApp (EVar "pushGoal") (EFieldAccess (EVar "mctx") "mcGraph")) (ERecordCreate "Obligation" ((fa "oKind" (EVar "GKArithSite")) (fa "oDest" (EApp (EVar "EvRoute") (EVar "dref"))) (fa "oEv" (EVar "ev")) (fa "oEncl" (ELit (LString ""))) (fa "oLoc" (EVar "None")) (fa "oScope" (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) (fa "oPayload" (EApp (EVar "GPArith") (EVar "m"))) (fa "oInner" (EApp (EVar "Ref") (EVar "innerNone")))))))
(DTypeSig false "pushMethodDictGoal" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PendingMethodDict") (TyCon "Unit"))))
(DFunDef false "pushMethodDictGoal" ((PVar "gctx") (PVar "pmd")) (EApp (EApp (EVar "pushGoal") (EVar "gctx")) (ERecordCreate "Obligation" ((fa "oKind" (EVar "GKMethodDict")) (fa "oDest" (EApp (EVar "EvRoutes") (EFieldAccess (EVar "pmd") "pmdRoutesRef"))) (fa "oEv" (EFieldAccess (EVar "pmd") "pmdEv")) (fa "oEncl" (EFieldAccess (EVar "pmd") "pmdEncl")) (fa "oLoc" (EVar "None")) (fa "oScope" (EFieldAccess (EVar "pmd") "pmdScope")) (fa "oPayload" (EApp (EVar "GPMethodDict") (EVar "pmd"))) (fa "oInner" (EFieldAccess (EVar "pmd") "pmdInner"))))))
(DTypeSig false "pushRecDictAppGoal" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "RecDictApp") (TyCon "Unit"))))
(DFunDef false "pushRecDictAppGoal" ((PVar "gctx") (PAs "r" (PCon "RecDictApp" (PVar "routesRef") PWild (PVar "encl") PWild (PVar "scope") (PVar "ev")))) (EApp (EApp (EVar "pushGoal") (EVar "gctx")) (ERecordCreate "Obligation" ((fa "oKind" (EVar "GKRecDictApp")) (fa "oDest" (EApp (EVar "EvRoutes") (EVar "routesRef"))) (fa "oEv" (EVar "ev")) (fa "oEncl" (EVar "encl")) (fa "oLoc" (EVar "None")) (fa "oScope" (EVar "scope")) (fa "oPayload" (EApp (EVar "GPRecDictApp") (EVar "r"))) (fa "oInner" (EApp (EVar "Ref") (EVar "innerNone")))))))
(DTypeSig false "pushPendingObl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Provenance") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit"))))))))))
(DFunDef false "pushPendingObl" ((PVar "mctx") (PVar "iface") (PVar "typarams") (PVar "mty") (PVar "occ") (PVar "omitted") (PVar "prov") (PVar "loc")) (EApp (EApp (EVar "wPush") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "implObls")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkMethodOccObl") (EVar "iface")) (EVar "typarams")) (EVar "mty")) (EVar "occ")) (EVar "omitted")) (EVar "prov")) (EVar "loc")) (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit)))))
(DTypeSig false "pushExactReturnObl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodReturnRequest") (TyCon "Unit"))))
(DFunDef false "pushExactReturnObl" ((PVar "mctx") (PVar "request")) (EApp (EApp (EVar "wPush") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "implObls")) (ERecordCreate "UObligation" ((fa "pred" (ERecordCreate "Predicate" ((fa "iface" (EFieldAccess (EVar "request") "mrrIface")) (fa "args" (EListLit))))) (fa "originId" (ELit (LInt 0))) (fa "prov" (EVar "PMethodOcc")) (fa "loc" (EFieldAccess (EVar "request") "mrrLoc")) (fa "uoScope" (EFieldAccess (EVar "request") "mrrScope")) (fa "oblProj" (EApp (EVar "OpExactReturn") (EVar "request")))))))
(DTypeSig false "methodReturnRequest" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodSchemeRow") (TyFun (TyCon "Mono") (TyFun (TyCon "MethodInstantiationSubst") (TyFun (TyApp (TyCon "Option") (TyCon "EvId")) (TyCon "MethodReturnRequest")))))))
(DFunDef false "methodReturnRequest" ((PVar "mctx") (PVar "row") (PVar "occurrence") (PVar "subst") (PVar "goalEv")) (EBlock (DoLet false false (PVar "loc") (EFieldAccess (EVar "mctx") "mcLoc")) (DoLet false false (PVar "scope") (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) (DoLet false false (PVar "qualifiedBody") (EMatch (EFieldAccess (EVar "row") "msrScheme") (arm (PCon "Forall" PWild PWild PWild PWild PWild (PVar "body")) () (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EFieldAccess (EVar "mctx") "mcGraph")) (EFieldAccess (EVar "subst") "misTypeSubst")) (EFieldAccess (EVar "subst") "misEffectSubst")) (EFieldAccess (EVar "subst") "misAuthSubst")) (EVar "body"))))) (DoLet false false (PVar "omitted") (EIf (EApp (EVar "methodPredicateTemplateHasAbsent") (EFieldAccess (EVar "row") "msrPredicateTemplate")) (EApp (EApp (EApp (EVar "omittedParamVars") (EVar "mctx")) (EFieldAccess (EVar "row") "msrTyparams")) (EFieldAccess (EVar "row") "msrType")) (EListLit))) (DoExpr (ERecordCreate "MethodReturnRequest" ((fa "mrrIface" (EFieldAccess (EVar "row") "msrIface")) (fa "mrrName" (EFieldAccess (EVar "row") "msrName")) (fa "mrrTyparams" (EFieldAccess (EVar "row") "msrTyparams")) (fa "mrrType" (EFieldAccess (EVar "row") "msrType")) (fa "mrrOccurrence" (EVar "occurrence")) (fa "mrrEnclosing" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (fa "mrrLoc" (EVar "loc")) (fa "mrrScope" (EVar "scope")) (fa "mrrGoalEv" (EVar "goalEv")) (fa "mrrQualifiedBody" (EVar "qualifiedBody")) (fa "mrrPredicateTemplate" (EApp (EApp (EApp (EVar "instantiateMethodPredicateTemplate") (EFieldAccess (EVar "mctx") "mcGraph")) (EFieldAccess (EVar "row") "msrPredicateTemplate")) (EVar "subst"))) (fa "mrrOmitted" (EVar "omitted")) (fa "mrrResolution" (EApp (EVar "Ref") (EVar "None"))))))))
(DTypeSig true "mkMethodOccObl" (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Provenance") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ScopeId") (TyCon "UObligation"))))))))))
(DFunDef false "mkMethodOccObl" ((PVar "iface") (PVar "typarams") (PVar "mty") (PVar "occ") (PVar "omitted") (PVar "prov") (PVar "loc") (PVar "scope")) (ERecordCreate "UObligation" ((fa "pred" (ERecordCreate "Predicate" ((fa "iface" (EVar "iface")) (fa "args" (EListLit))))) (fa "originId" (ELit (LInt 0))) (fa "prov" (EVar "prov")) (fa "loc" (EVar "loc")) (fa "uoScope" (EVar "scope")) (fa "oblProj" (EApp (EApp (EApp (EApp (EVar "OpMethodOcc") (EVar "typarams")) (EVar "mty")) (EVar "occ")) (EVar "omitted"))))))
(DTypeSig false "pushNumLitObl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ClassPredicate") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ScopeId") (TyCon "Unit")))))))
(DFunDef false "pushNumLitObl" ((PVar "mctx") (PVar "predicate") (PVar "occurrence") (PVar "loc") (PVar "scope")) (EApp (EApp (EVar "wPush") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "implObls")) (ERecordCreate "UObligation" ((fa "pred" (ERecordCreate "Predicate" ((fa "iface" (EFieldAccess (EVar "predicate") "predicateInterface")) (fa "args" (EFieldAccess (EVar "predicate") "predicateArguments"))))) (fa "originId" (ELit (LInt 0))) (fa "prov" (EVar "PNumLit")) (fa "loc" (EVar "loc")) (fa "uoScope" (EVar "scope")) (fa "oblProj" (EApp (EVar "OpNumLit") (EVar "occurrence")))))))
(DTypeSig false "hasPredicateSlots" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "PredicateSlot"))) (TyCon "Bool"))))
(DFunDef false "hasPredicateSlots" ((PVar "k") (PVar "idx")) (EApp (EApp (EVar "omHasKey") (EVar "k")) (EVar "idx")))
(DTypeSig true "argDispatchIndices" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "argDispatchIndices" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "argDispatchOfDecl")) (EVar "prog")))
(DTypeSig false "argDispatchOfDecl" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "argDispatchOfDecl" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "argDispatchOfDecl") (EVar "d")))
(DFunDef false "argDispatchOfDecl" ((PRec "DInterface" ((rf "typarams" None) (rf "methods" None)) true)) (EApp (EApp (EVar "flatMap") (EApp (EVar "argDispatchOfMethod") (EVar "typarams"))) (EVar "methods")))
(DFunDef false "argDispatchOfDecl" (PWild) (EListLit))
(DTypeSig false "argDispatchOfMethod" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "argDispatchOfMethod" ((PVar "typarams") (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild PWild)) (EMatch (EApp (EApp (EApp (EVar "firstDispatchIdx") (EApp (EVar "dispatchTyparams") (EVar "typarams"))) (ELit (LInt 0))) (EApp (EVar "methodArgs") (EVar "mty"))) (arm (PCon "Some" (PVar "i")) () (EListLit (ETuple (EVar "mname") (EVar "i")))) (arm (PCon "None") () (EListLit))))
(DTypeSig true "argDispatchIndicesById" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "IfaceRef") (TyCon "String")) (TyCon "Int")))))
(DFunDef false "argDispatchIndicesById" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "argDispatchOfDeclById")) (EVar "prog")))
(DTypeSig false "argDispatchOfDeclById" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "IfaceRef") (TyCon "String")) (TyCon "Int")))))
(DFunDef false "argDispatchOfDeclById" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "argDispatchOfDeclById") (EVar "d")))
(DFunDef false "argDispatchOfDeclById" ((PRec "DInterface" ((rf "name" None) (rf "typarams" None) (rf "methods" None) (rf "ifaceOrigin" None)) true)) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "argDispatchOfMethodById") (ERecordCreate "IfaceRef" ((fa "irName" (EVar "name")) (fa "irOrigin" (EVar "ifaceOrigin"))))) (EVar "typarams"))) (EVar "methods")))
(DFunDef false "argDispatchOfDeclById" (PWild) (EListLit))
(DTypeSig false "argDispatchOfMethodById" (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "IfaceRef") (TyCon "String")) (TyCon "Int")))))))
(DFunDef false "argDispatchOfMethodById" ((PVar "iface") (PVar "typarams") (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild PWild)) (EMatch (EApp (EApp (EApp (EVar "firstDispatchIdx") (EApp (EVar "dispatchTyparams") (EVar "typarams"))) (ELit (LInt 0))) (EApp (EVar "methodArgs") (EVar "mty"))) (arm (PCon "Some" (PVar "i")) () (EListLit (ETuple (ETuple (EVar "iface") (EVar "mname")) (EVar "i")))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "firstDispatchIdx" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "firstDispatchIdx" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "firstDispatchIdx" ((PVar "typarams") (PVar "i") (PCons (PVar "ty") (PVar "rest"))) (EIf (EApp (EApp (EVar "argMentions") (EVar "typarams")) (EVar "ty")) (EApp (EVar "Some") (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "firstDispatchIdx") (EVar "typarams")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "recordArgStamp" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyFun (TyApp (TyCon "Ref") (TyCon "Inner")) (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyCon "Unit")))))))))))
(DFunDef false "recordArgStamp" ((PVar "mctx") (PVar "suppressed") (PVar "name") (PVar "tagRef") (PVar "implRef") (PVar "innerRef") (PVar "idx") (PVar "mono") (PVar "omitted")) (EIf (EVar "suppressed") (ELit LUnit) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "nthFunDomain") (EVar "idx")) (EVar "mono")) (arm (PCon "Some" (PVar "am")) () (EApp (EApp (EApp (EApp (EVar "pushSiteGoal") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "GKArgStamp")) (EVar "innerRef")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PendingEntry") (EVar "name")) (EVar "tagRef")) (EVar "am")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (EApp (EApp (EApp (EVar "SKArg") (EVar "implRef")) (EVar "mono")) (EVar "omitted"))) (EFieldAccess (EVar "mctx") "mcLoc")) (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit))))) (arm (PCon "None") () (ELit LUnit))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "recordArgSiteFn" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyCon "Unit"))))))
(DFunDef false "recordArgSiteFn" ((PVar "mctx") PWild (PVar "idx") (PVar "mono")) (EMatch (EApp (EApp (EVar "nthFunDomain") (EVar "idx")) (EVar "mono")) (arm (PCon "Some" (PVar "am")) () (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodSiteFns")) (EApp (EApp (EApp (EVar "consSiteFn") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (EVar "am")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodSiteFns") "value")))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig false "mintMethodCell" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "EvId"))))
(DFunDef false "mintMethodCell" ((PVar "mctx") (PVar "seed")) (EApp (EApp (EApp (EApp (EApp (EVar "mintMethodCellRaw") (EVar "mctx")) (ELit (LString ""))) (EVar "None")) (EIf (EBinOp "==" (EVar "seed") (ELit (LString ""))) (EVar "RNone") (EApp (EApp (EVar "RLocal") (EVar "seed")) (EListLit)))) (EListLit)))
(DTypeSig true "mintMethodCellRaw" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "Route") (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyCon "EvId")))))))
(DFunDef false "mintMethodCellRaw" ((PVar "mctx") (PVar "iface") (PVar "arity") (PVar "tag") (PVar "impls")) (EBlock (DoLet false false (PVar "ev") (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit))) (DoLet false false (PVar "g") (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun")) (DoLet false false (PVar "i") (EBinOp "-" (EApp (EVar "evOrdinal") (EVar "ev")) (EFieldAccess (EVar "g") "evBase"))) (DoLet false false (PVar "arr") (EApp (EApp (EVar "indexWithSlot") (EFieldAccess (EVar "g") "evCells")) (EVar "i"))) (DoExpr (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" PWild) () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "method cell #")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "evOrdinal") (EVar "ev"))))) (ELit (LString " minted twice"))))))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EApp (EVar "Some") (ERecordCreate "EvCell" ((fa "ecId" (EVar "ev")) (fa "ecIface" (EApp (EVar "Ref") (EVar "iface"))) (fa "ecArity" (EApp (EVar "Ref") (EVar "arity"))) (fa "ecTag" (EApp (EVar "Ref") (EVar "tag"))) (fa "ecImpl" (EApp (EVar "Ref") (EVar "impls"))) (fa "ecMeth" (EApp (EVar "Ref") (EListLit))) (fa "ecLoc" (EApp (EVar "Ref") (EVar "None"))) (fa "ecName" (EApp (EVar "Ref") (ELit (LString "")))) (fa "ecInner" (EApp (EVar "Ref") (EVar "innerNone"))))))) (EVar "arr"))) (DoExpr (EVar "ev"))))
(DTypeSig false "indexWithSlot" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyVar "a")))) (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyVar "a"))))))
(DFunDef false "indexWithSlot" ((PVar "index") (PVar "i")) (EBlock (DoLet false false (PVar "arr0") (EFieldAccess (EVar "index") "value")) (DoExpr (EIf (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr0"))) (EVar "arr0") (EBlock (DoLet false false (PVar "grown") (EApp (EApp (EVar "arrayMake") (EApp (EApp (EVar "max") (ELit (LInt 16))) (EBinOp "*" (ELit (LInt 2)) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EVar "None"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "arrayBlit") (EVar "arr0")) (ELit (LInt 0))) (EVar "grown")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr0")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "index")) (EVar "grown"))) (DoExpr (EVar "grown")))))))
(DTypeSig false "mintOpSite" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "EvId"))))
(DFunDef false "mintOpSite" ((PVar "mctx") PWild) (EApp (EApp (EVar "mintSite") (EVar "mctx")) (EApp (EVar "OpSite") (EApp (EVar "Ref") (EVar "RNone")))))
(DTypeSig false "mintLitSite" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "EvId"))))
(DFunDef false "mintLitSite" ((PVar "mctx") PWild) (EApp (EApp (EVar "mintSite") (EVar "mctx")) (EApp (EApp (EVar "LitSite") (EApp (EVar "Ref") (EVar "None"))) (EApp (EVar "Ref") (EVar "RNone")))))
(DTypeSig false "mintHeadSite" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "EvId"))))
(DFunDef false "mintHeadSite" ((PVar "mctx") PWild) (EApp (EApp (EVar "mintSite") (EVar "mctx")) (EApp (EVar "HeadSite") (EApp (EVar "Ref") (ELit (LString ""))))))
(DTypeSig false "mintedOr" (TyFun (TyFun (TyCon "Unit") (TyCon "EvId")) (TyFun (TyCon "EvId") (TyCon "EvId"))))
(DFunDef false "mintedOr" ((PVar "mint") (PVar "ev")) (EIf (EApp (EVar "isUnminted") (EVar "ev")) (EApp (EVar "mint") (ELit LUnit)) (EVar "ev")))
(DTypeSig false "mintSite" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SiteCell") (TyCon "EvId"))))
(DFunDef false "mintSite" ((PVar "mctx") (PVar "cell")) (EBlock (DoLet false false (PVar "ev") (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit))) (DoLet false false (PVar "g") (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun")) (DoLet false false (PVar "i") (EBinOp "-" (EApp (EVar "evOrdinal") (EVar "ev")) (EFieldAccess (EVar "g") "evBase"))) (DoLet false false (PVar "arr") (EApp (EApp (EVar "indexWithSlot") (EFieldAccess (EVar "g") "siteCells")) (EVar "i"))) (DoExpr (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EApp (EVar "Some") (ETuple (EVar "ev") (EVar "cell")))) (EVar "arr"))) (arm (PCon "Some" PWild) () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "site cell #")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "evOrdinal") (EVar "ev"))))) (ELit (LString " minted twice"))))))) (DoExpr (EVar "ev"))))
(DTypeSig false "siteCellOf" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvId") (TyCon "SiteCell"))))
(DFunDef false "siteCellOf" ((PVar "gctx") (PVar "ev")) (EMatch (EApp (EApp (EVar "siteCellLookup") (EVar "gctx")) (EVar "ev")) (arm (PCon "Ok" (PVar "c")) () (EVar "c")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "panic") (EVar "message")))))
(DTypeSig false "siteCellLookup" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvId") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "SiteCell")))))
(DFunDef false "siteCellLookup" ((PVar "gctx") (PVar "ev")) (EBlock (DoLet false false (PCon "EvId" (PVar "m") (PVar "n")) (EVar "ev")) (DoLet false false (PVar "g") (EFieldAccess (EVar "gctx") "graphRun")) (DoLet false false (PVar "i") (EBinOp "-" (EVar "n") (EFieldAccess (EVar "g") "evBase"))) (DoLet false false (PVar "arr") (EFieldAccess (EFieldAccess (EVar "g") "siteCells") "value")) (DoExpr (EIf (EApp (EVar "isUnminted") (EVar "ev")) (EApp (EVar "Err") (ELit (LString "site reached inference unminted"))) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "site cell ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " is from an earlier graph")))) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "site cell ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " was never minted")))) (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (arm (PCon "Some" (PTuple PWild (PVar "c"))) () (EApp (EVar "Ok") (EVar "c"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "site cell ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " was never minted"))))))))))))
(DTypeSig true "siteRouteCell" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvId") (TyApp (TyCon "Ref") (TyCon "Route")))))
(DFunDef false "siteRouteCell" ((PVar "gctx") (PVar "ev")) (EMatch (EApp (EApp (EVar "siteCellOf") (EVar "gctx")) (EVar "ev")) (arm (PCon "OpSite" (PVar "r")) () (EVar "r")) (arm (PCon "LitSite" PWild (PVar "r")) () (EVar "r")) (arm (PCon "HeadSite" PWild) () (EApp (EVar "notAnOpSite") (EVar "ev")))))
(DTypeSig true "siteHeadCell" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvId") (TyApp (TyCon "Ref") (TyCon "String")))))
(DFunDef false "siteHeadCell" ((PVar "gctx") (PVar "ev")) (EMatch (EApp (EApp (EVar "siteCellOf") (EVar "gctx")) (EVar "ev")) (arm (PCon "HeadSite" (PVar "h")) () (EVar "h")) (arm (PCon "OpSite" PWild) () (EApp (EVar "notAnOpSite") (EVar "ev"))) (arm (PCon "LitSite" PWild PWild) () (EApp (EVar "notAnOpSite") (EVar "ev")))))
(DTypeSig false "siteFloatCell" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvId") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Float"))))))
(DFunDef false "siteFloatCell" ((PVar "gctx") (PVar "ev")) (EMatch (EApp (EApp (EVar "siteCellOf") (EVar "gctx")) (EVar "ev")) (arm (PCon "LitSite" (PVar "f") PWild) () (EVar "f")) (arm (PCon "OpSite" PWild) () (EApp (EVar "notAnOpSite") (EVar "ev"))) (arm (PCon "HeadSite" PWild) () (EApp (EVar "notAnOpSite") (EVar "ev")))))
(DTypeSig false "notAnOpSite" (TyFun (TyCon "EvId") (TyVar "a")))
(DFunDef false "notAnOpSite" ((PVar "ev")) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "site cell ")) (EApp (EVar "display") (EApp (EVar "evIdModule") (EVar "ev")))) (ELit (LString "#"))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "evOrdinal") (EVar "ev"))))) (ELit (LString " is not an operator site")))))
(DTypeSig true "freshEvId" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "EvId"))))
(DFunDef false "freshEvId" ((PVar "mctx") PWild) (EBlock (DoLet false false (PVar "g") (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun")) (DoLet false false (PVar "n") (EFieldAccess (EFieldAccess (EVar "g") "evCounter") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "evCounter")) (EBinOp "+" (EVar "n") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EVar "EvId") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentModuleRef") "value")) (EVar "n")))))
(DTypeSig false "pushNumlit" (TyFun (TyCon "GraphCtx") (TyFun (TyTuple (TyCon "Mono") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Float"))) (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Route"))) (TyCon "Unit"))))
(DFunDef false "pushNumlit" ((PVar "gctx") (PVar "e")) (EBlock (DoLet false false (PVar "g") (EFieldAccess (EVar "gctx") "graphRun")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "numlitRefs")) (EBinOp "::" (EVar "e") (EFieldAccess (EFieldAccess (EVar "g") "numlitRefs") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "numlitN")) (EBinOp "+" (EFieldAccess (EFieldAccess (EVar "g") "numlitN") "value") (ELit (LInt 1)))))))
(DTypeSig true "ctorHeadShaped" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "ctorHeadShaped" ((PVar "name")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "name"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoExpr (EBinOp "&&" (EBinOp ">" (EVar "n") (ELit (LInt 0))) (EBinOp "||" (EApp (EVar "isUpper") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "cs"))) (EApp (EApp (EApp (EVar "mangledCtorShaped") (EVar "cs")) (EVar "n")) (ELit (LInt 0))))))))
(DTypeSig false "mangledCtorShaped" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "mangledCtorShaped" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 2))) (EVar "n")) (EVar "False") (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "_"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "cs")) (ELit (LChar "_")))) (EApp (EVar "isUpper") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "cs")))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "mangledCtorShaped") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "bindingDeclaredAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "MethodTrackedInstantiation") (TyApp (TyCon "Option") (TyCon "CDeclared"))))))
(DFunDef false "bindingDeclaredAt" ((PVar "env") (PVar "name") (PVar "inst")) (EApp (EApp (EApp (EVar "declaredEffectsAt") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "inst")) (EApp (EApp (EVar "bindingDeclared") (EVar "env")) (EVar "name"))))
(DTypeSig false "recordDeclaredBindingCall" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "CDeclared") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyCon "Unit")))))
(DFunDef false "recordDeclaredBindingCall" ((PVar "mctx") (PVar "dc") (PVar "subst")) (EBlock (DoLet false false (PVar "expanded") (EApp (EVar "dedupSlotVecs") (EApp (EApp (EVar "zipSlotVecs") (EFieldAccess (EVar "dc") "cdSlots")) (EFieldAccess (EVar "dc") "cdArgs")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordCallObligations") (EVar "mctx")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "expanded"))) (EApp (EApp (EVar "constraintMonosOf") (EApp (EApp (EVar "map") (ELam ((PVar "pair")) (EFieldAccess (EApp (EVar "fst") (EVar "pair")) "csId"))) (EVar "expanded"))) (EVar "subst"))) (EApp (EApp (EApp (EVar "callArgVecsV") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "expanded")) (EVar "subst"))))))
(DTypeSig false "inferMethodAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "String")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Int"))) (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyFun (TyApp (TyCon "Ref") (TyCon "Inner")) (TyCon "Mono"))))))))))
(DTypeSig true "inferMethodAtCell" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "EvCell") (TyCon "Mono")))))
(DFunDef false "inferMethodAtCell" ((PVar "env") (PVar "name") (PVar "c")) (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsLastMethodInst")) (EVar "None"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsLastStandalone")) (EVar "None"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "c") "ecLoc")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "c") "ecName")) (EVar "name"))) (DoLet false false (PVar "t") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferMethodAt") (EVar "env")) (EVar "name")) (EFieldAccess (EVar "c") "ecIface")) (EFieldAccess (EVar "c") "ecArity")) (EFieldAccess (EVar "c") "ecTag")) (EFieldAccess (EVar "c") "ecImpl")) (EFieldAccess (EVar "c") "ecMeth")) (EFieldAccess (EVar "c") "ecInner"))) (DoExpr (EMatch (ETuple (EFieldAccess (EFieldAccess (EVar "st") "gsLastStandalone") "value") (EFieldAccess (EFieldAccess (EVar "st") "gsLastMethodInst") "value")) (arm (PTuple (PCon "Some" (PTuple (PVar "scheme") (PVar "subst"))) PWild) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordStandaloneGrantOcc") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EFieldAccess (EVar "c") "ecId")) (EVar "scheme")) (EVar "subst")) (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EFieldAccess (EFieldAccess (EVar "c") "ecArity") "value")))) (arm (PTuple (PCon "None") (PCon "Some" (PTuple (PVar "scheme") (PVar "subst")))) () (EApp (EApp (EApp (EApp (EApp (EVar "recordMethodGrantOcc") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EFieldAccess (EVar "c") "ecId")) (EVar "scheme")) (EVar "subst"))) (arm (PTuple (PCon "None") (PCon "None")) () (ELit LUnit)))) (DoExpr (EVar "t"))))
(DTypeSig false "recordShadowStandaloneObls" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyCon "Unit")))))
(DFunDef false "recordShadowStandaloneObls" ((PVar "env") (PVar "name") (PVar "subst")) (EIf (EBinOp "||" (EApp (EApp (EVar "isDefinerShadow") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EApp (EApp (EVar "isShadowStandalone") (EVar "env")) (EVar "name"))) (EMatch (EApp (EApp (EApp (EVar "lookupSchemeObls") (EVar "name")) (ELit (LInt 0))) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "schemeObligationsRef") "value")) (arm (PCon "Some" (PVar "obs")) () (EApp (EApp (EApp (EApp (EVar "recordSchemeCallObligations") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit (LInt 0))) (EVar "obs")) (EVar "subst"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "declaredCrossModuleObls") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (arm (PCon "Some" (PVar "obs")) () (EApp (EApp (EApp (EApp (EVar "recordSchemeCallObligations") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit (LInt 0))) (EVar "obs")) (EVar "subst"))) (arm (PCon "None") () (ELit LUnit))))) (EIf (EVar "otherwise") (ELit LUnit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "inferMethodAt" ((PVar "env") (PVar "name") (PVar "ifaceRef") (PVar "arityRef") (PVar "tagRef") (PVar "implRef") (PVar "methodRef") (PVar "innerRef")) (EBlock (DoLet false false (PVar "selected") (EMatch (EApp (EApp (EVar "standaloneValueBinding") (EVar "env")) (EVar "name")) (arm (PCon "Some" (PVar "scheme")) () (EApp (EVar "Some") (EVar "scheme"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "standaloneValueBindingEmit") (EVar "env")) (EVar "name")) (EVar "tagRef"))))) (DoExpr (EMatch (EVar "selected") (arm (PCon "Some" (PVar "value")) () (EBlock (DoExpr (EApp (EApp (EVar "rejectAdmittedValueOccurrence") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name"))) (DoLet false false (PVar "sym") (EApp (EVar "routeLocalSym") (EUnOp "!" (EVar "tagRef")))) (DoLet false false (PVar "occurrence") (EApp (EApp (EApp (EApp (EApp (EVar "instantiateStandaloneOccurrence") (EVar "env")) (EVar "name")) (EVar "sym")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EVar "value"))) (DoLet false false (PVar "inst") (EFieldAccess (EVar "occurrence") "svoInstance")) (DoLet false false (PVar "dicts") (EFieldAccess (EVar "occurrence") "svoDicts")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph") "graphRun") "grants") "gsLastStandalone")) (EApp (EVar "Some") (ETuple (EFieldAccess (EVar "occurrence") "svoScheme") (EFieldAccess (EFieldAccess (EVar "inst") "mtiSubstitution") "misAuthSubst"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "arityRef")) (EApp (EVar "Some") (EApp (EVar "funArity") (EFieldAccess (EVar "inst") "mtiBody"))))) (DoLet false false (PVar "receiver") (EMatch (EApp (EApp (EVar "methodDispatchIdx") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (arm (PCon "Some" (PVar "idx")) () (EApp (EApp (EVar "optionOr") (EFieldAccess (EVar "inst") "mtiBody")) (EApp (EApp (EVar "nthFunDomain") (EVar "idx")) (EFieldAccess (EVar "inst") "mtiBody")))) (arm (PCon "None") () (EFieldAccess (EVar "inst") "mtiBody")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pushSiteGoal") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "GKRLocalSite")) (EVar "innerRef")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PendingEntry") (EVar "name")) (EVar "tagRef")) (EVar "receiver")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentFn") "value")) (EApp (EApp (EApp (EApp (EApp (EVar "SKRLocal") (EVar "sym")) (EVar "True")) (EFieldAccess (EVar "dicts") "sdMonos")) (EFieldAccess (EVar "dicts") "sdIfaces")) (EFieldAccess (EVar "dicts") "sdArgVecs"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EApp (EApp (EVar "captureScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (EApp (EApp (EVar "freshEvId") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))))) (DoExpr (EFieldAccess (EVar "inst") "mtiBody")))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferMethodCandidateAt") (EVar "env")) (EVar "name")) (EVar "ifaceRef")) (EVar "arityRef")) (EVar "tagRef")) (EVar "implRef")) (EVar "methodRef")) (EVar "innerRef")))))))
(DTypeSig false "inferMethodCandidateAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "String")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Int"))) (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyFun (TyApp (TyCon "Ref") (TyCon "Inner")) (TyCon "Mono"))))))))))
(DFunDef false "inferMethodCandidateAt" ((PVar "env") (PVar "name") (PVar "ifaceRef") (PVar "arityRef") (PVar "tagRef") (PVar "implRef") (PVar "methodRef") (PVar "innerRef")) (EMatch (EApp (EApp (EVar "lookupVar") (EVar "env")) (EVar "name")) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (ELit (LString "unbound method: ")) (EVar "name")))) (arm (PCon "Some" (PVar "s")) () (EBlock (DoLet false false (PVar "inst") (EApp (EApp (EVar "instantiateMethodTracked") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "s"))) (DoLet false false (PVar "occurrence") (EFieldAccess (EVar "inst") "mtiBody")) (DoLet false false (PVar "subst") (EFieldAccess (EVar "inst") "mtiSubstitution")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph") "graphRun") "grants") "gsLastMethodInst")) (EApp (EVar "Some") (ETuple (EVar "s") (EFieldAccess (EVar "subst") "misAuthSubst"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "arityRef")) (EApp (EVar "Some") (EApp (EVar "funArity") (EVar "occurrence"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "ifaceRef")) (EApp (EApp (EVar "admittedIfaceWord") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordRLocalSite") (EVar "env")) (EVar "name")) (EVar "tagRef")) (EVar "innerRef")) (EVar "occurrence"))) (DoLet false false (PVar "ret") (EMatch (EApp (EApp (EVar "argDispatchOf") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (arm (PCon "Some" (PVar "idx")) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordMethodDicts") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "methodRef")) (EVar "innerRef")) (EFieldAccess (EVar "subst") "misTypeSubst"))) (DoLet false false (PVar "omitted") (EApp (EApp (EVar "methodOmittedVars") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "recordMethodObligationGuarded") (EVar "env")) (EVar "name")) (EVar "s")) (EVar "occurrence")) (EVar "omitted"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordArgStamp") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcSuppressArgStamp")) (EVar "name")) (EVar "tagRef")) (EVar "implRef")) (EVar "innerRef")) (EVar "idx")) (EVar "occurrence")) (EVar "omitted"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordArgSiteFn") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "idx")) (EVar "occurrence"))) (DoExpr (EVar "occurrence")))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordSite") (EVar "env")) (EVar "name")) (EVar "s")) (EVar "ifaceRef")) (EVar "tagRef")) (EVar "implRef")) (EVar "methodRef")) (EVar "innerRef")) (EVar "occurrence")) (EVar "subst"))))) (DoLet false false PWild (EApp (EApp (EApp (EVar "forceInstantiation") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "inst"))) (DoExpr (EVar "ret"))))))
(DTypeSig false "recordRLocalSite" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyApp (TyCon "Ref") (TyCon "Inner")) (TyFun (TyCon "Mono") (TyCon "Unit")))))))
(DFunDef false "recordRLocalSite" ((PVar "env") (PVar "name") (PVar "tagRef") (PVar "innerRef") (PVar "inst")) (EIf (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcSuppressRLocalRecord") (ELit LUnit) (EIf (EBinOp "&&" (EApp (EVar "isNone") (EApp (EApp (EVar "methodDispatchIdx") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name"))) (EApp (EApp (EVar "standaloneValuePinned") (EVar "env")) (EVar "name"))) (EApp (EApp (EApp (EApp (EVar "pushSiteGoal") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "GKRLocalSite")) (EVar "innerRef")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PendingEntry") (EVar "name")) (EVar "tagRef")) (EVar "inst")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentFn") "value")) (EApp (EApp (EApp (EApp (EApp (EVar "SKRLocal") (EApp (EVar "routeLocalSym") (EUnOp "!" (EVar "tagRef")))) (EVar "True")) (EListLit)) (EListLit)) (EListLit))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EApp (EApp (EVar "captureScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (EApp (EApp (EVar "freshEvId") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit)))) (EIf (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "standaloneValuesRef") "value"))) (ELit LUnit) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "methodDispatchIdx") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "idx")) () (EMatch (EApp (EApp (EVar "nthFunDomain") (EVar "idx")) (EVar "inst")) (arm (PCon "Some" (PVar "am")) () (EBlock (DoLet false false (PVar "sym") (EApp (EVar "routeLocalSym") (EUnOp "!" (EVar "tagRef")))) (DoLet false false (PVar "dicts") (EApp (EApp (EApp (EApp (EApp (EVar "shadowStandaloneDictSlotsAt") (EFieldAccess (EVar "env") "teDyn")) (EApp (EApp (EApp (EVar "standaloneValueFor") (EVar "env")) (EVar "name")) (EVar "sym"))) (EVar "name")) (EIf (EBinOp "==" (EVar "sym") (ELit (LString ""))) (EVar "name") (EVar "sym"))) (EVar "am"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pushSiteGoal") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "GKRLocalSite")) (EVar "innerRef")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PendingEntry") (EVar "name")) (EVar "tagRef")) (EVar "am")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentFn") "value")) (EApp (EApp (EApp (EApp (EApp (EVar "SKRLocal") (EVar "sym")) (EApp (EApp (EVar "standaloneValuePinned") (EVar "env")) (EVar "name"))) (EFieldAccess (EVar "dicts") "sdMonos")) (EFieldAccess (EVar "dicts") "sdIfaces")) (EFieldAccess (EVar "dicts") "sdArgVecs"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EApp (EApp (EVar "captureScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (EApp (EApp (EVar "freshEvId") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))))))) (arm (PCon "None") () (ELit LUnit))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig true "standaloneSchemeFor" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Scheme"))))))
(DFunDef false "standaloneSchemeFor" ((PVar "env") (PVar "name") (PVar "sym")) (EApp (EApp (EVar "map") (ELam ((PVar "value")) (EFieldAccess (EVar "value") "vsScheme"))) (EApp (EApp (EApp (EVar "standaloneValueFor") (EVar "env")) (EVar "name")) (EVar "sym"))))
(DTypeSig true "standaloneOccurrence" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "Option") (TyCon "SelectedValueOccurrence")))))))
(DFunDef false "standaloneOccurrence" ((PVar "env") (PVar "name") (PVar "sym") (PVar "origin")) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EVar "instantiateStandaloneOccurrence") (EVar "env")) (EVar "name")) (EVar "sym")) (EVar "origin"))) (EApp (EApp (EApp (EVar "standaloneValueFor") (EVar "env")) (EVar "name")) (EVar "sym"))))
(DTypeSig false "recordMethodDicts" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyFun (TyApp (TyCon "Ref") (TyCon "Inner")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyCon "Unit")))))))
(DFunDef false "recordMethodDicts" ((PVar "mctx") (PVar "name") (PVar "methodRef") (PVar "innerRef") (PVar "subst")) (EMatch (EApp (EApp (EVar "methodIfaceHere") (EVar "mctx")) (EVar "name")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "iface")) () (EMatch (EApp (EApp (EVar "lookupAssoc") (EApp (EApp (EVar "methodSlotKey") (EVar "iface")) (EApp (EApp (EVar "originMethodName") (EVar "mctx")) (EVar "name")))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodPredicateSlotsRef") "value")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "slots")) () (EApp (EApp (EApp (EApp (EApp (EVar "recordMethodDictsFromSlots") (EVar "mctx")) (EVar "slots")) (EVar "methodRef")) (EVar "innerRef")) (EVar "subst")))))))
(DTypeSig false "recordMethodDictsFromSlots" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyFun (TyApp (TyCon "Ref") (TyCon "Inner")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyCon "Unit")))))))
(DFunDef false "recordMethodDictsFromSlots" ((PVar "mctx") (PVar "slots") (PVar "methodRef") (PVar "innerRef") (PVar "subst")) (EApp (EApp (EVar "pushMethodDictGoal") (EFieldAccess (EVar "mctx") "mcGraph")) (ERecordCreate "PendingMethodDict" ((fa "pmdRoutesRef" (EVar "methodRef")) (fa "pmdEv" (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit))) (fa "pmdSlots" (EApp (EApp (EApp (EVar "instantiateMethodPredicateSlots") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "slots")) (EVar "subst"))) (fa "pmdEncl" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (fa "pmdScope" (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) (fa "pmdInner" (EVar "innerRef"))))))
(DTypeSig false "instantiateMethodPredicateSlots" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "PredicateSlot"))))))
(DFunDef false "instantiateMethodPredicateSlots" ((PVar "gctx") (PList) PWild) (EListLit))
(DFunDef false "instantiateMethodPredicateSlots" ((PVar "gctx") (PCons (PVar "slot") (PVar "rest")) (PVar "subst")) (EMatch (EApp (EApp (EApp (EVar "instantiateMethodPredicateSlot") (EVar "gctx")) (EVar "slot")) (EVar "subst")) (arm (PCon "Some" (PVar "pred")) () (EBinOp "::" (EVar "pred") (EApp (EApp (EApp (EVar "instantiateMethodPredicateSlots") (EVar "gctx")) (EVar "rest")) (EVar "subst")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "instantiateMethodPredicateSlots") (EVar "gctx")) (EVar "rest")) (EVar "subst")))))
(DTypeSig false "instantiateMethodPredicateSlot" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "MethodPredicateSlot") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyCon "PredicateSlot"))))))
(DFunDef false "instantiateMethodPredicateSlot" ((PVar "gctx") (PVar "slot") (PVar "subst")) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "instantiatedMethodPredicate") (EVar "gctx")) (EVar "slot")) (EVar "subst"))) (EApp (EApp (EApp (EVar "methodSlotSubst") (EFieldAccess (EFieldAccess (EVar "slot") "mpsPredicate") "psBoundIds")) (EFieldAccess (EVar "slot") "mpsPositions")) (EVar "subst"))))
(DTypeSig false "instantiatedMethodPredicate" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "MethodPredicateSlot") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyCon "PredicateSlot"))))))
(DFunDef false "instantiatedMethodPredicate" ((PVar "gctx") (PVar "slot") (PVar "subst") (PVar "slotSubst")) (EBlock (DoLet false false (PVar "args2") (EApp (EApp (EApp (EVar "instantiatedMethodPredicateArgs") (EVar "gctx")) (EFieldAccess (EFieldAccess (EVar "slot") "mpsPredicate") "psArgs")) (EVar "slotSubst"))) (DoExpr (ERecordCreate "PredicateSlot" ((fa "psIface" (EFieldAccess (EFieldAccess (EVar "slot") "mpsPredicate") "psIface")) (fa "psArgs" (EVar "args2")) (fa "psBoundIds" (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EApp (EVar "optionOr") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EApp (EApp (EVar "get") (EVar "p")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "subst")))))) (EFieldAccess (EVar "slot") "mpsPositions"))))))))
(DTypeSig false "instantiatedMethodPredicateArgs" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PredicateSlotArgs") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyCon "PredicateSlotArgs")))))
(DFunDef false "instantiatedMethodPredicateArgs" ((PVar "gctx") (PCon "PSArgsUnknown") PWild) (EVar "PSArgsUnknown"))
(DFunDef false "instantiatedMethodPredicateArgs" ((PVar "gctx") (PCon "PSArgsKnown" (PVar "args")) (PVar "subst")) (EApp (EVar "PSArgsKnown") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EVar "subst")) (EListLit)) (EListLit))) (EVar "args"))))
(DTypeSig false "methodSlotSubst" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))))))))
(DFunDef false "methodSlotSubst" ((PVar "ids") (PVar "positions") (PVar "subst")) (EBlock (DoLet false false (PVar "vals") (EApp (EApp (EVar "map") (EVar "snd")) (EVar "subst"))) (DoLet false false (PVar "n") (EApp (EVar "listLen") (EVar "subst"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "listLen") (EVar "ids")) (EApp (EVar "listLen") (EVar "positions"))) (EApp (EApp (EVar "allInRange") (EVar "positions")) (EVar "n"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "zipMethodSlotSubst") (EVar "ids")) (EVar "positions")) (EVar "vals"))) (EVar "None")))))
(DTypeSig false "zipMethodSlotSubst" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))))))
(DFunDef false "zipMethodSlotSubst" ((PList) PWild PWild) (EListLit))
(DFunDef false "zipMethodSlotSubst" (PWild (PList) PWild) (EListLit))
(DFunDef false "zipMethodSlotSubst" ((PCons (PVar "id") (PVar "ids")) (PCons (PVar "pos") (PVar "positions")) (PVar "vals")) (EBinOp "::" (ETuple (EVar "id") (EApp (EApp (EVar "nthMethodMono") (EVar "pos")) (EVar "vals"))) (EApp (EApp (EApp (EVar "zipMethodSlotSubst") (EVar "ids")) (EVar "positions")) (EVar "vals"))))
(DTypeSig false "allInRange" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "allInRange" ((PList) PWild) (EVar "True"))
(DFunDef false "allInRange" ((PCons (PVar "p") (PVar "rest")) (PVar "n")) (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "p") (ELit (LInt 0))) (EBinOp "<" (EVar "p") (EVar "n"))) (EApp (EApp (EVar "allInRange") (EVar "rest")) (EVar "n"))))
(DTypeSig false "nthMethodMono" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Mono"))))
(DFunDef false "nthMethodMono" (PWild (PList)) (EApp (EVar "tconUnresolved") (ELit (LString "__missing_method_slot__"))))
(DFunDef false "nthMethodMono" ((PLit (LInt 0)) (PCons (PVar "x") PWild)) (EVar "x"))
(DFunDef false "nthMethodMono" ((PVar "i") (PCons PWild (PVar "xs"))) (EApp (EApp (EVar "nthMethodMono") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "xs")))
(DTypeSig false "recordSite" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Scheme") (TyFun (TyApp (TyCon "Ref") (TyCon "String")) (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyFun (TyApp (TyCon "Ref") (TyCon "Inner")) (TyFun (TyCon "Mono") (TyFun (TyCon "MethodInstantiationSubst") (TyCon "Mono"))))))))))))
(DFunDef false "recordSite" ((PVar "env") (PVar "name") (PVar "scheme") (PVar "ifaceRef") (PVar "tagRef") (PVar "implRef") (PVar "methodRef") (PVar "innerRef") (PVar "methodType") (PVar "subst")) (EBlock (DoLet false false (PVar "stripped") (EApp (EVar "stripArrows") (EVar "methodType"))) (DoLet false false (PVar "ev") (EApp (EApp (EVar "freshEvId") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "exactRow") (EApp (EApp (EApp (EVar "exactReturnRow") (EVar "env")) (EVar "name")) (EVar "scheme"))) (DoLet false false (PVar "admitted") (EBinOp "&&" (EApp (EVar "isNone") (EVar "exactRow")) (EApp (EApp (EApp (EVar "admittedSetOccurrence") (EVar "env")) (EVar "name")) (EVar "scheme")))) (DoLet false false (PVar "exact") (EApp (EApp (EVar "map") (ELam ((PVar "row")) (EApp (EApp (EApp (EApp (EApp (EVar "methodReturnRequest") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "row")) (EVar "methodType")) (EVar "subst")) (EApp (EVar "Some") (EVar "ev"))))) (EVar "exactRow"))) (DoExpr (EMatch (ETuple (EVar "exact") (EVar "exactRow")) (arm (PTuple (PCon "Some" (PVar "request")) (PCon "Some" (PVar "row"))) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordMethodLevelSlotsOwned") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "row")) (EFieldAccess (EVar "subst") "misTypeSubst")) (EFieldAccess (EVar "request") "mrrLoc")) (EFieldAccess (EVar "request") "mrrScope"))) (DoLet false false PWild (EApp (EApp (EVar "recordExactMethodObligation") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "request"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EFieldAccess (EVar "row") "msrMethodSlots")) (ELit LUnit) (EApp (EApp (EApp (EApp (EApp (EVar "recordMethodDictsFromSlots") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EVar "row") "msrMethodSlots")) (EVar "methodRef")) (EVar "innerRef")) (EFieldAccess (EVar "subst") "misTypeSubst")))))) (arm PWild () (EBlock (DoExpr (EIf (EVar "admitted") (EApp (EApp (EApp (EVar "pushAdmittedOccObl") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "methodType")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "recordMethodObligationGuarded") (EVar "env")) (EVar "name")) (EVar "scheme")) (EVar "methodType")) (EListLit))) (DoExpr (ELit LUnit))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordMethodDicts") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "methodRef")) (EVar "innerRef")) (EFieldAccess (EVar "subst") "misTypeSubst"))))))) (DoLet false false (PVar "siteEv") (EMatch (EVar "exact") (arm (PCon "Some" (PVar "request")) () (EApp (EApp (EVar "optionOr") (EVar "ev")) (EFieldAccess (EVar "request") "mrrGoalEv"))) (arm (PCon "None") () (EVar "ev")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pushSiteGoal") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "GKReturnSite")) (EVar "innerRef")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PendingEntry") (EVar "name")) (EVar "tagRef")) (EVar "stripped")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentFn") "value")) (EMatch (EVar "exact") (arm (PCon "Some" (PVar "request")) () (EApp (EApp (EVar "SKExactReturn") (EVar "implRef")) (EVar "request"))) (arm (PCon "None") () (EIf (EVar "admitted") (EApp (EApp (EApp (EVar "SKAdmittedReturn") (EVar "ifaceRef")) (EVar "implRef")) (EVar "methodType")) (EApp (EApp (EVar "SKReturn") (EVar "implRef")) (EVar "methodType")))))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EApp (EApp (EVar "captureScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (EVar "siteEv")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "methodSiteFns")) (EApp (EApp (EApp (EVar "consSiteFn") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentFn") "value")) (EVar "stripped")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "methodSiteFns") "value")))) (DoExpr (EVar "methodType"))))
(DTypeSig false "recordNumLitSite" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ClassPredicate") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ScopeId") (TyCon "Mono"))))))))
(DFunDef false "recordNumLitSite" ((PVar "mctx") (PVar "predicate") (PVar "tagRef") (PVar "occurrence") (PVar "origin") (PVar "scope")) (EBlock (DoLet false false (PVar "stripped") (EApp (EVar "stripArrows") (EVar "occurrence"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pushSiteGoal") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "GKReturnSite")) (EApp (EVar "Ref") (EVar "innerNone"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PendingEntry") (ELit (LString "fromInt"))) (EVar "tagRef")) (EVar "stripped")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (EApp (EApp (EVar "SKNumReturn") (EVar "predicate")) (EVar "occurrence"))) (EVar "origin")) (EVar "scope")) (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodSiteFns")) (EApp (EApp (EApp (EVar "consSiteFn") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (EVar "stripped")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodSiteFns") "value")))) (DoExpr (EVar "occurrence"))))
(DTypeSig false "freshLocalAbsName" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "freshLocalAbsName" ((PVar "gctx") (PVar "x")) (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "localAbs")) (DoLet false false (PTuple (PVar "mid") (PVar "k")) (EFieldAccess (EFieldAccess (EVar "st") "lasNext") "value")) (DoLet false false (PVar "name") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "x"))) (ELit (LString "$"))) (EApp (EVar "display") (EVar "mid"))) (ELit (LString "$"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString "$lb")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "lasNext")) (ETuple (EVar "mid") (EBinOp "+" (EVar "k") (ELit (LInt 1)))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "lasMinted")) (EBinOp "::" (EVar "name") (EFieldAccess (EFieldAccess (EVar "st") "lasMinted") "value")))) (DoExpr (EVar "name"))))
(DTypeSig false "mintGrantOnly" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Expr"))))
(DFunDef false "mintGrantOnly" ((PVar "mctx") (PVar "n")) (EBlock (DoLet false false (PVar "ev") (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit))) (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsGrantOnly")) (EApp (EApp (EApp (EVar "IdMap.set") (EApp (EVar "evOrdinal") (EVar "ev"))) (ELit LUnit)) (EFieldAccess (EFieldAccess (EVar "st") "gsGrantOnly") "value")))) (DoExpr (EApp (EApp (EVar "EDictAt") (EVar "n")) (EVar "ev")))))
(DTypeSig true "isGrantOnlyEv" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvId") (TyCon "Bool"))))
(DFunDef false "isGrantOnlyEv" ((PVar "gctx") (PVar "ev")) (EApp (EApp (EVar "IdMap.has") (EApp (EVar "evOrdinal") (EVar "ev"))) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants") "gsGrantOnly") "value")))
(DTypeSig false "unmarkGrantOnly" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvId") (TyCon "Unit"))))
(DFunDef false "unmarkGrantOnly" ((PVar "gctx") (PVar "ev")) (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsGrantOnly")) (EApp (EApp (EVar "IdMap.delete") (EApp (EVar "evOrdinal") (EVar "ev"))) (EFieldAccess (EFieldAccess (EVar "st") "gsGrantOnly") "value"))))))
(DTypeSig false "qualConstraintFor" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "CSlot"))))))
(DFunDef false "qualConstraintFor" ((PVar "mctx") (PVar "name")) (EApp (EApp (EVar "map") (ELam ((PVar "d")) (EFieldAccess (EVar "d") "cdSlots"))) (EApp (EApp (EVar "qualConstraintDecl") (EVar "mctx")) (EVar "name"))))
(DTypeSig false "declaredConstraintIds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "declaredConstraintIds" ((PVar "mctx") (PVar "name")) (EMatch (EApp (EApp (EVar "qualConstraintIds") (EVar "mctx")) (EVar "name")) (arm (PCon "Some" (PVar "ids")) () (EVar "ids")) (arm (PCon "None") () (EIf (EApp (EApp (EVar "hasImportDefiner") (EVar "mctx")) (EVar "name")) (EListLit) (EApp (EApp (EVar "predicateSlotIdsAt") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funPredicateSlotsIdxRef") "value"))))))
(DTypeSig false "qualConstraintIds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "qualConstraintIds" ((PVar "mctx") (PVar "name")) (EMatch (EApp (EApp (EVar "qualConstraintKey") (EVar "mctx")) (EVar "name")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple (PVar "src") (PVar "origin"))) () (EApp (EApp (EVar "map") (EVar "predicateSlotIds")) (EApp (EApp (EApp (EVar "lookupQualPayload") (EVar "src")) (EVar "origin")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "crossRun") "crossModuleFunPredicateSlotsQualRef") "value"))))))
(DTypeSig true "inferDictAtFound" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyFun (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))) (TyCon "Mono"))))))
(DFunDef false "inferDictAtFound" ((PVar "mctx") (PVar "name") (PVar "ev") (PVar "inst")) (EBlock (DoLet false false (PVar "q") (EApp (EApp (EVar "qualConstraintFor") (EVar "mctx")) (EVar "name"))) (DoLet false false (PVar "dc") (EApp (EApp (EVar "declaredConstraintFor") (EVar "mctx")) (EVar "name"))) (DoLet false false (PVar "declaredIds") (EApp (EApp (EVar "declaredConstraintIds") (EVar "mctx")) (EVar "name"))) (DoLet false false (PVar "known") (EMatch (EVar "q") (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EApp (EApp (EVar "hasPredicateSlots") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funPredicateSlotsIdxRef") "value"))))) (DoExpr (EIf (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "declaredIds")) (EApp (EApp (EVar "hasImportDefiner") (EVar "mctx")) (EVar "name"))) (EBlock (DoExpr (EApp (EApp (EVar "pushDictApp") (EFieldAccess (EVar "mctx") "mcGraph")) (ERecordCreate "PendingDictApp" ((fa "pdaRoutesRef" (EApp (EVar "Ref") (EListLit))) (fa "pdaEv" (EVar "ev")) (fa "pdaMonos" (EListLit)) (fa "pdaIfaces" (EListLit)) (fa "pdaArgVecs" (EListLit)) (fa "pdaEncl" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (fa "pdaLoc" (EFieldAccess (EVar "mctx") "mcLoc")) (fa "pdaScope" (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) (fa "pdaCallee" (EApp (EVar "localSourceName") (EVar "name"))))))) (DoExpr (EApp (EVar "fst") (EVar "inst")))) (EIf (EBinOp "&&" (EVar "known") (EBinOp "||" (EApp (EApp (EVar "anyIdPinned") (EVar "declaredIds")) (EApp (EVar "snd") (EVar "inst"))) (EApp (EApp (EApp (EApp (EVar "calleeIsGeneralized") (EVar "mctx")) (EVar "name")) (EVar "q")) (EApp (EVar "snd") (EVar "inst"))))) (EApp (EApp (EApp (EApp (EApp (EVar "inferDeclaredDictAt") (EVar "mctx")) (EVar "name")) (EVar "ev")) (EVar "dc")) (ETuple (EApp (EVar "fst") (EVar "inst")) (EApp (EApp (EApp (EVar "pinUnboundIds") (EVar "mctx")) (EVar "declaredIds")) (EApp (EVar "snd") (EVar "inst"))))) (EBlock (DoExpr (EApp (EApp (EVar "pushRecDictAppGoal") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "RecDictApp") (EApp (EVar "Ref") (EListLit))) (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (EApp (EVar "fst") (EVar "inst"))) (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) (EVar "ev")))) (DoExpr (EApp (EVar "fst") (EVar "inst")))))))))
(DTypeSig true "inferDeclaredDictAt" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyFun (TyCon "CDeclared") (TyFun (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))) (TyCon "Mono")))))))
(DFunDef false "inferDeclaredDictAt" ((PVar "mctx") (PVar "name") (PVar "ev") (PVar "dc") (PVar "inst")) (EBlock (DoLet false false (PVar "expandedV") (EApp (EVar "dedupSlotVecs") (EApp (EApp (EVar "zipSlotVecs") (EFieldAccess (EVar "dc") "cdSlots")) (EFieldAccess (EVar "dc") "cdArgs")))) (DoLet false false (PVar "expanded") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "expandedV"))) (DoLet false false (PVar "ids") (EApp (EApp (EVar "map") (ELam ((PVar "s")) (EFieldAccess (EVar "s") "csId"))) (EVar "expanded"))) (DoLet false false (PVar "monos") (EApp (EApp (EVar "constraintMonosOf") (EVar "ids")) (EApp (EVar "snd") (EVar "inst")))) (DoLet false false (PVar "argVecs") (EApp (EApp (EApp (EVar "callArgVecsV") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "expandedV")) (EApp (EVar "snd") (EVar "inst")))) (DoExpr (EApp (EApp (EVar "pushDictApp") (EFieldAccess (EVar "mctx") "mcGraph")) (ERecordCreate "PendingDictApp" ((fa "pdaRoutesRef" (EApp (EVar "Ref") (EListLit))) (fa "pdaEv" (EVar "ev")) (fa "pdaMonos" (EVar "monos")) (fa "pdaIfaces" (EApp (EApp (EVar "map") (ELam ((PVar "s")) (EFieldAccess (EVar "s") "csIface"))) (EVar "expanded"))) (fa "pdaArgVecs" (EVar "argVecs")) (fa "pdaEncl" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (fa "pdaLoc" (EFieldAccess (EVar "mctx") "mcLoc")) (fa "pdaScope" (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) (fa "pdaCallee" (EApp (EVar "localSourceName") (EVar "name"))))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dictAppFns")) (EApp (EApp (EApp (EVar "consSiteFn") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (EApp (EApp (EVar "bareVectorLeads") (EVar "monos")) (EVar "argVecs"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dictAppFns") "value")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordCallObligations") (EVar "mctx")) (EVar "expanded")) (EVar "monos")) (EVar "argVecs"))) (DoExpr (EApp (EVar "fst") (EVar "inst")))))
(DTypeSig false "calleeIsGeneralized" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "CSlot"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyCon "Bool"))))))
(DFunDef false "calleeIsGeneralized" ((PVar "mctx") (PVar "name") (PVar "q") (PVar "subst")) (EIf (EApp (EVar "isSome") (EVar "q")) (EVar "True") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "sigTyMapRef") "value")) (arm (PCon "Some" (PVar "ty")) () (EBinOp "||" (EApp (EVar "isNonEmptyL") (EVar "subst")) (EApp (EVar "isEmptyL") (EApp (EVar "tyVarNames") (EVar "ty"))))) (arm (PCon "None") () (EVar "False"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "pinUnboundIds" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))))))
(DFunDef false "pinUnboundIds" ((PVar "mctx") (PVar "ids") (PVar "subst")) (EBinOp "++" (EVar "subst") (EApp (EApp (EVar "map") (ELam ((PVar "id")) (ETuple (EVar "id") (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "id")) (EApp (EVar "isNone") (EApp (EApp (EVar "lookupAssocI") (EVar "id")) (EVar "subst"))))) (EVar "ids")))))
(DTypeSig false "anyIdPinned" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyCon "Bool"))))
(DFunDef false "anyIdPinned" ((PList) PWild) (EVar "False"))
(DFunDef false "anyIdPinned" ((PCons (PVar "id") (PVar "rest")) (PVar "subst")) (EMatch (EApp (EApp (EVar "lookupAssocI") (EVar "id")) (EVar "subst")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EApp (EApp (EVar "anyIdPinned") (EVar "rest")) (EVar "subst")))))
(DTypeSig false "recordCallObligations" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "CSlot")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Mono"))) (TyCon "Unit"))))))
(DFunDef false "recordCallObligations" ((PVar "mctx") (PList) PWild PWild) (ELit LUnit))
(DFunDef false "recordCallObligations" ((PVar "mctx") PWild (PList) PWild) (ELit LUnit))
(DFunDef false "recordCallObligations" ((PVar "mctx") (PCons (PVar "s") (PVar "ss")) (PCons (PVar "mono") (PVar "ms")) (PList)) (EIf (EBinOp "==" (EFieldAccess (EFieldAccess (EVar "s") "csIface") "irName") (ELit (LString ""))) (EApp (EApp (EApp (EApp (EVar "recordCallObligations") (EVar "mctx")) (EVar "ss")) (EVar "ms")) (EListLit)) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordObl") (EVar "mctx")) (ERecordCreate "Predicate" ((fa "iface" (EFieldAccess (EVar "s") "csIface")) (fa "args" (EListLit (EVar "mono")))))) (ELit (LInt 0))) (EVar "PCallSlot")) (EFieldAccess (EVar "mctx") "mcLoc"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordCallObligations") (EVar "mctx")) (EVar "ss")) (EVar "ms")) (EListLit)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "recordCallObligations" ((PVar "mctx") (PCons (PVar "s") (PVar "ss")) (PCons (PVar "mono") (PVar "ms")) (PCons (PVar "args") (PVar "rest"))) (EIf (EBinOp "==" (EFieldAccess (EFieldAccess (EVar "s") "csIface") "irName") (ELit (LString ""))) (EApp (EApp (EApp (EApp (EVar "recordCallObligations") (EVar "mctx")) (EVar "ss")) (EVar "ms")) (EVar "rest")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "goalArgs") (EIf (EApp (EVar "isEmptyL") (EVar "args")) (EListLit (EVar "mono")) (EVar "args"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordObl") (EVar "mctx")) (ERecordCreate "Predicate" ((fa "iface" (EFieldAccess (EVar "s") "csIface")) (fa "args" (EVar "goalArgs"))))) (ELit (LInt 0))) (EVar "PCallSlot")) (EFieldAccess (EVar "mctx") "mcLoc"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordCallObligations") (EVar "mctx")) (EVar "ss")) (EVar "ms")) (EVar "rest")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "bareVectorLeads" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "bareVectorLeads" ((PVar "monos") (PList)) (EVar "monos"))
(DFunDef false "bareVectorLeads" ((PList) PWild) (EListLit))
(DFunDef false "bareVectorLeads" ((PCons (PVar "m") (PVar "ms")) (PCons (PVar "v") (PVar "vs"))) (EIf (EApp (EApp (EVar "allList") (EVar "isBareTyvarMono")) (EVar "v")) (EBinOp "::" (EVar "m") (EApp (EApp (EVar "bareVectorLeads") (EVar "ms")) (EVar "vs"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "bareVectorLeads") (EVar "ms")) (EVar "vs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "recordBinopSite" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyCon "Mono") (TyCon "Unit"))))))
(DFunDef false "recordBinopSite" ((PVar "mctx") (PVar "op") (PVar "dref") (PVar "m")) (EMatch (EApp (EVar "binopMethod") (EVar "op")) (arm (PCon "Some" (PVar "method")) () (EApp (EApp (EApp (EApp (EVar "pushSiteGoal") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "GKBinopSite")) (EApp (EVar "Ref") (EVar "innerNone"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PendingEntry") (EVar "method")) (EVar "dref")) (EVar "m")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (EApp (EVar "SKOp") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentImplBody") "value"))) (EFieldAccess (EVar "mctx") "mcLoc")) (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit))))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig true "arithDispatchMethod" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "arithDispatchMethod" ((PLit (LString "+"))) (EApp (EVar "Some") (ELit (LString "add"))))
(DFunDef false "arithDispatchMethod" ((PLit (LString "-"))) (EApp (EVar "Some") (ELit (LString "sub"))))
(DFunDef false "arithDispatchMethod" ((PLit (LString "*"))) (EApp (EVar "Some") (ELit (LString "mul"))))
(DFunDef false "arithDispatchMethod" ((PLit (LString "/"))) (EApp (EVar "Some") (ELit (LString "div"))))
(DFunDef false "arithDispatchMethod" ((PLit (LString "%"))) (EApp (EVar "Some") (ELit (LString "rem"))))
(DFunDef false "arithDispatchMethod" (PWild) (EVar "None"))
(DTypeSig true "recordBinopGoals" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyCon "Mono") (TyCon "Unit"))))))
(DFunDef false "recordBinopGoals" ((PVar "mctx") (PVar "op") (PVar "dref") (PVar "m")) (EMatch (EApp (EVar "arithDispatchMethod") (EVar "op")) (arm (PCon "Some" (PVar "method")) () (EIf (EApp (EApp (EVar "builtinClassPresent") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "BNum")) (EBlock (DoLet false false (PVar "predicate") (ERecordCreate "ClassPredicate" ((fa "predicateInterface" (EApp (EApp (EVar "builtinIfaceRef") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "BNum"))) (fa "predicateArguments" (EListLit (EVar "m")))))) (DoLet false false (PVar "scope") (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteNumericPredicateTrace") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "NPTProduced")) (EVar "predicate")) (EVar "scope")) (EFieldAccess (EVar "mctx") "mcLoc")) (EVar "None")) (EVar "None")) (EListLit))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pushSiteGoal") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "GKBinopSite")) (EApp (EVar "Ref") (EVar "innerNone"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PendingEntry") (EVar "method")) (EVar "dref")) (EVar "m")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (EApp (EApp (EVar "SKPredicateOp") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentImplBody") "value")) (EVar "predicate"))) (EFieldAccess (EVar "mctx") "mcLoc")) (EVar "scope")) (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit))))) (DoExpr (ELit LUnit))) (EApp (EApp (EApp (EApp (EVar "pushArithGoal") (EVar "mctx")) (EVar "dref")) (EVar "m")) (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "recordBinopSite") (EVar "mctx")) (EVar "op")) (EVar "dref")) (EVar "m")))))
(DTypeSig true "binopMethod" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "binopMethod" ((PLit (LString "=="))) (EApp (EVar "Some") (ELit (LString "eq"))))
(DFunDef false "binopMethod" ((PLit (LString "/="))) (EApp (EVar "Some") (ELit (LString "eq"))))
(DFunDef false "binopMethod" ((PLit (LString "<"))) (EApp (EVar "Some") (ELit (LString "lt"))))
(DFunDef false "binopMethod" ((PLit (LString ">"))) (EApp (EVar "Some") (ELit (LString "gt"))))
(DFunDef false "binopMethod" ((PLit (LString "<="))) (EApp (EVar "Some") (ELit (LString "lte"))))
(DFunDef false "binopMethod" ((PLit (LString ">="))) (EApp (EVar "Some") (ELit (LString "gte"))))
(DFunDef false "binopMethod" ((PLit (LString "++"))) (EApp (EVar "Some") (ELit (LString "append"))))
(DFunDef false "binopMethod" (PWild) (EVar "None"))
(DTypeSig true "unopMethod" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "unopMethod" ((PLit (LString "-"))) (EApp (EVar "Some") (ELit (LString "negate"))))
(DFunDef false "unopMethod" (PWild) (EVar "None"))
(DTypeSig true "recordUnopSite" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyCon "Mono") (TyCon "Unit"))))))
(DFunDef false "recordUnopSite" ((PVar "mctx") (PVar "op") (PVar "dref") (PVar "m")) (EMatch (EApp (EVar "unopMethod") (EVar "op")) (arm (PCon "Some" (PVar "method")) () (EBlock (DoLet false false (PVar "inImpl") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentImplBody") "value")) (DoLet false false (PVar "kind") (EIf (EApp (EApp (EVar "builtinClassPresent") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "BNum")) (EApp (EApp (EVar "SKPredicateOp") (EVar "inImpl")) (ERecordCreate "ClassPredicate" ((fa "predicateInterface" (EApp (EApp (EVar "builtinIfaceRef") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "BNum"))) (fa "predicateArguments" (EListLit (EVar "m")))))) (EApp (EVar "SKOp") (EVar "inImpl")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pushSiteGoal") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "GKUnopSite")) (EApp (EVar "Ref") (EVar "innerNone"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PendingEntry") (EVar "method")) (EVar "dref")) (EVar "m")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (EVar "kind")) (EFieldAccess (EVar "mctx") "mcLoc")) (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit))))))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig true "recordNegatedLitRange" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Expr") (TyCon "Unit")))))
(DFunDef false "recordNegatedLitRange" ((PVar "mctx") (PVar "t") (PCon "ELoc" PWild (PVar "e"))) (EApp (EApp (EApp (EVar "recordNegatedLitRange") (EVar "mctx")) (EVar "t")) (EVar "e")))
(DFunDef false "recordNegatedLitRange" ((PVar "mctx") (PVar "t") (PCon "ENumLit" (PVar "n") PWild PWild)) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitRanges") "value") (arm (PCons (PTuple PWild (PVar "m") (PVar "loc")) (PVar "rest")) ((GBool (EBinOp "==" (EVar "m") (EVar "n")))) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitRanges")) (EBinOp "::" (ETuple (EVar "t") (EApp (EVar "negateLiteral") (EVar "n")) (EVar "loc")) (EVar "rest")))) (arm PWild () (EApp (EApp (EApp (EVar "recordNumlitRange") (EVar "mctx")) (EVar "t")) (EApp (EVar "negateLiteral") (EVar "n"))))))
(DFunDef false "recordNegatedLitRange" ((PVar "mctx") (PVar "t") (PCon "EWideLit" PWild PWild PWild (PVar "lx"))) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "wideLitRanges") "value") (arm (PCons (PTuple PWild (PVar "l") (PVar "hi") (PVar "lo") PWild (PVar "loc")) (PVar "rest")) ((GBool (EBinOp "==" (EVar "l") (EVar "lx")))) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "wideLitRanges")) (EBinOp "::" (ETuple (EVar "t") (EVar "lx") (EVar "hi") (EVar "lo") (EVar "True") (EVar "loc")) (EVar "rest")))) (arm PWild () (ELit LUnit))))
(DFunDef false "recordNegatedLitRange" ((PVar "mctx") PWild PWild) (ELit LUnit))
(DTypeSig true "recordIfaceObligation" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "BuiltinClass") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "recordIfaceObligation" ((PVar "mctx") (PVar "c") (PVar "lt")) (EIf (EApp (EApp (EVar "builtinClassPresent") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushPendingObl") (EVar "mctx")) (EApp (EApp (EVar "builtinIfaceRef") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "c"))) (EListLit (ELit (LString "a")))) (EApp (EVar "TyVar") (ELit (LString "a")))) (EVar "lt")) (EListLit)) (EVar "POperator")) (EFieldAccess (EVar "mctx") "mcLoc")) (EIf (EVar "otherwise") (ELit LUnit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "inferNumLit" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Int") (TyFun (TyCon "EvId") (TyCon "Mono")))))
(DFunDef false "inferNumLit" ((PVar "env") (PVar "n") (PVar "ev")) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EApp (EApp (EVar "inferNumLitVar") (EVar "env")) (EVar "n")) (EApp (EApp (EVar "siteFloatCell") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "ev"))) (EApp (EApp (EVar "siteRouteCell") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "ev")))) (DoExpr (EApp (EApp (EApp (EVar "recordNumlitRange") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "a")) (EVar "n"))) (DoExpr (EVar "a"))))
(DTypeSig true "inferWideLit" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "EvId") (TyFun (TyCon "String") (TyCon "Mono")))))))
(DFunDef false "inferWideLit" ((PVar "env") (PVar "hi") (PVar "lo") (PVar "ev") (PVar "lx")) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EApp (EApp (EVar "inferNumLitVar") (EVar "env")) (EVar "lo")) (EApp (EVar "Ref") (EVar "None"))) (EApp (EApp (EVar "siteRouteCell") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "ev")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "wideLitRanges")) (EBinOp "::" (ETuple (EVar "a") (EVar "lx") (EVar "hi") (EVar "lo") (EVar "False") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "wideLitRanges") "value")))) (DoExpr (EVar "a"))))
(DTypeSig false "inferNumLitVar" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Float"))) (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyCon "Mono"))))))
(DFunDef false "inferNumLitVar" ((PVar "env") (PVar "n") (PVar "fref") (PVar "dref")) (EIf (EApp (EApp (EVar "builtinClassPresent") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "BNum")) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "numLitFromIntAnchorRef") "value") (arm (PCon "None") () (EApp (EApp (EApp (EVar "inferNumLitBare") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "n")) (EVar "fref"))) (arm (PCon "Some" (PVar "anchor")) () (EBlock (DoLet false false (PVar "fromIntTy") (EApp (EApp (EApp (EVar "inferNumLitMethod") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "anchor")) (EVar "dref"))) (DoLet false false (PVar "a") (EApp (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EFieldAccess (EVar "env") "teDyn")) (EVar "fromIntTy")) (EApp (EApp (EApp (EVar "TFun") (EApp (EVar "tconBuiltin") (ELit (LString "Int")))) (EApp (EApp (EVar "openRow") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (EVar "a")))) (DoExpr (EApp (EApp (EVar "pushNumlit") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ETuple (EVar "a") (EVar "fref") (EVar "n") (EVar "dref")))) (DoExpr (EApp (EApp (EVar "recordNumlitLoc") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "a"))) (DoExpr (EVar "a"))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "inferNumLitBare") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "n")) (EVar "fref")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "inferNumLitMethod" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodSchemeRow") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyCon "Mono")))))
(DFunDef false "inferNumLitMethod" ((PVar "mctx") (PVar "anchor") (PVar "tagRef")) (EBlock (DoLet false false (PVar "inst") (EApp (EApp (EVar "instantiateTracked") (EVar "mctx")) (EFieldAccess (EVar "anchor") "msrScheme"))) (DoLet false false (PVar "occurrence") (EApp (EVar "fst") (EVar "inst"))) (DoLet false false (PVar "predicate") (ERecordCreate "ClassPredicate" ((fa "predicateInterface" (EFieldAccess (EVar "anchor") "msrIface")) (fa "predicateArguments" (EApp (EApp (EApp (EVar "dispatchMonosOf") (EFieldAccess (EVar "anchor") "msrTyparams")) (EFieldAccess (EVar "anchor") "msrType")) (EVar "occurrence")))))) (DoLet false false (PVar "origin") (EFieldAccess (EVar "mctx") "mcLoc")) (DoLet false false (PVar "scope") (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteNumericPredicateTrace") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "NPTProduced")) (EVar "predicate")) (EVar "scope")) (EVar "origin")) (EVar "None")) (EVar "None")) (EListLit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordMethodDictsFromSlots") (EVar "mctx")) (EFieldAccess (EVar "anchor") "msrMethodSlots")) (EApp (EVar "Ref") (EListLit))) (EApp (EVar "Ref") (EVar "innerNone"))) (EApp (EVar "snd") (EVar "inst")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordNumLitObligationGuarded") (EVar "mctx")) (EVar "anchor")) (EVar "predicate")) (EVar "occurrence")) (EVar "origin")) (EVar "scope"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordNumLitSite") (EVar "mctx")) (EVar "predicate")) (EVar "tagRef")) (EVar "occurrence")) (EVar "origin")) (EVar "scope")))))
(DTypeSig false "inferNumLitBare" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Float"))) (TyCon "Mono")))))
(DFunDef false "inferNumLitBare" ((PVar "mctx") (PVar "n") (PVar "fref")) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit))) (DoLet false false (PVar "predicate") (ERecordCreate "ClassPredicate" ((fa "predicateInterface" (EApp (EApp (EVar "builtinIfaceRef") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "BNum"))) (fa "predicateArguments" (EListLit (EVar "a")))))) (DoLet false false (PVar "origin") (EFieldAccess (EVar "mctx") "mcLoc")) (DoLet false false (PVar "scope") (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteNumericPredicateTrace") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "NPTProduced")) (EVar "predicate")) (EVar "scope")) (EVar "origin")) (EVar "None")) (EVar "None")) (EListLit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "pushNumLitObl") (EVar "mctx")) (EVar "predicate")) (EVar "a")) (EVar "origin")) (EVar "scope"))) (DoExpr (EApp (EApp (EVar "pushNumlit") (EFieldAccess (EVar "mctx") "mcGraph")) (ETuple (EVar "a") (EVar "fref") (EVar "n") (EApp (EVar "Ref") (EVar "RNone"))))) (DoExpr (EApp (EApp (EVar "recordNumlitLoc") (EVar "mctx")) (EVar "a"))) (DoExpr (EVar "a"))))
(DTypeSig false "recordNumlitRange" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Int") (TyCon "Unit")))))
(DFunDef false "recordNumlitRange" ((PVar "mctx") (PVar "a") (PVar "n")) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitRanges")) (EBinOp "::" (ETuple (EVar "a") (EVar "n") (EFieldAccess (EVar "mctx") "mcLoc")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitRanges") "value"))))
(DTypeSig false "recordNumlitLoc" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyCon "Unit"))))
(DFunDef false "recordNumlitLoc" ((PVar "mctx") (PVar "a")) (EMatch (EFieldAccess (EVar "mctx") "mcLoc") (arm (PCon "Some" (PVar "l")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitVarLocs")) (EBinOp "::" (ETuple (EVar "a") (EVar "l")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitVarLocs") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitUntainted")) (EBinOp "::" (ETuple (EVar "a") (EVar "l")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitUntainted") "value")))))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig true "markNumlitOpTaint" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyCon "Unit"))))
(DFunDef false "markNumlitOpTaint" ((PVar "mctx") (PVar "m")) (EBlock (DoLet false false (PVar "id") (EApp (EVar "rootIdOf") (EVar "m"))) (DoExpr (EIf (EBinOp "||" (EBinOp "<" (EVar "id") (ELit (LInt 0))) (EApp (EVar "not") (EApp (EApp (EVar "anyRootMatch") (EVar "id")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitUntainted") "value")))) (ELit LUnit) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitUntainted")) (EApp (EApp (EApp (EVar "taintAndDrop") (EVar "mctx")) (EVar "id")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitUntainted") "value")))))))
(DTypeSig false "anyRootMatch" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Loc"))) (TyCon "Bool"))))
(DFunDef false "anyRootMatch" (PWild (PList)) (EVar "False"))
(DFunDef false "anyRootMatch" ((PVar "id") (PCons (PTuple (PVar "v") PWild) (PVar "rest"))) (EBinOp "||" (EApp (EApp (EVar "sameRootId") (EVar "id")) (EVar "v")) (EApp (EApp (EVar "anyRootMatch") (EVar "id")) (EVar "rest"))))
(DTypeSig false "taintAndDrop" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Loc"))) (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Loc")))))))
(DFunDef false "taintAndDrop" ((PVar "mctx") PWild (PList)) (EListLit))
(DFunDef false "taintAndDrop" ((PVar "mctx") (PVar "id") (PCons (PTuple (PVar "v") (PVar "l")) (PVar "rest"))) (EIf (EApp (EApp (EVar "sameRootId") (EVar "id")) (EVar "v")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitOpLocs")) (EBinOp "::" (EVar "l") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitOpLocs") "value")))) (DoExpr (EApp (EApp (EApp (EVar "taintAndDrop") (EVar "mctx")) (EVar "id")) (EVar "rest")))) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "v") (EVar "l")) (EApp (EApp (EApp (EVar "taintAndDrop") (EVar "mctx")) (EVar "id")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "instantiateVarTrackedId" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Scheme") (TyCon "Mono"))))))
(DFunDef false "instantiateVarTrackedId" ((PVar "env") (PVar "x") (PVar "id") (PVar "s")) (EBlock (DoLet false false (PVar "inst") (EApp (EApp (EApp (EApp (EVar "instantiateVarTrackedWithSubst") (EVar "env")) (EVar "x")) (EVar "id")) (EVar "s"))) (DoExpr (EFieldAccess (EVar "inst") "mtiBody"))))
(DTypeSig true "instantiateVarTrackedWithSubst" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Scheme") (TyCon "MethodTrackedInstantiation"))))))
(DFunDef false "instantiateVarTrackedWithSubst" ((PVar "env") (PVar "x") (PVar "id") (PVar "s")) (EMatch (EApp (EApp (EVar "bindingDeclared") (EVar "env")) (EVar "x")) (arm (PCon "Some" PWild) () (EBlock (DoLet false false (PVar "inst") (EApp (EApp (EApp (EVar "instantiateValueTracked") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EVar "s"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "bindingDeclaredAt") (EVar "env")) (EVar "x")) (EVar "inst")) (arm (PCon "Some" (PVar "dc")) () (EApp (EApp (EApp (EVar "recordDeclaredBindingCall") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "dc")) (EFieldAccess (EFieldAccess (EVar "inst") "mtiSubstitution") "misTypeSubst"))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EVar "inst")))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "instantiateLegacyVarTracked") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EVar "id")) (EVar "s")))))
(DTypeSig false "recordImplObligation" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyCon "Mono"))))))
(DFunDef false "recordImplObligation" ((PVar "mctx") (PVar "x") (PVar "mono") (PVar "omitted")) (EIf (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "x")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "definerShadowNamesRef") "value")) (EApp (EApp (EVar "omHasKey") (EVar "x")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "standaloneValuesRef") "value"))) (EVar "mono") (EIf (EBinOp ">=" (EApp (EVar "listLen") (EApp (EApp (EVar "methodAdmittedHere") (EVar "mctx")) (EVar "x"))) (ELit (LInt 2))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "pushAdmittedOccObl") (EVar "mctx")) (EVar "x")) (EVar "mono"))) (DoExpr (EVar "mono"))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "methodEntryHere") (EVar "mctx")) (EVar "x")) (arm (PCon "None") () (EVar "mono")) (arm (PCon "Some" (PTuple (PVar "iface") (PVar "typarams") (PVar "mty") PWild)) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushPendingObl") (EVar "mctx")) (EVar "iface")) (EVar "typarams")) (EVar "mty")) (EVar "mono")) (EVar "omitted")) (EVar "PMethodOcc")) (EFieldAccess (EVar "mctx") "mcLoc"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordMethodLevelObls") (EVar "mctx")) (EVar "typarams")) (EVar "mty")) (EVar "mono"))) (DoExpr (EVar "mono"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "pushAdmittedOccObl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "pushAdmittedOccObl" ((PVar "mctx") (PVar "name") (PVar "mono")) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "admittedOccObls")) (EBinOp "::" (ETuple (EVar "name") (EVar "mono") (EFieldAccess (EVar "mctx") "mcLoc")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "admittedOccObls") "value"))))
(DTypeSig false "admittedSetOccurrence" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Scheme") (TyCon "Bool")))))
(DFunDef false "admittedSetOccurrence" ((PVar "env") (PVar "name") (PVar "s")) (EBinOp "&&" (EApp (EVar "not") (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "lookupLocalFlag") (EVar "env")) (EVar "name")) (EApp (EVar "isMonoScheme") (EVar "s"))) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "definerShadowNamesRef") "value"))) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "standaloneValuesRef") "value")))) (EBinOp ">=" (EApp (EVar "listLen") (EApp (EApp (EVar "methodAdmittedHere") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name"))) (ELit (LInt 2)))))
(DTypeSig true "recordMethodObligationGuarded" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Scheme") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyCon "Mono")))))))
(DFunDef false "recordMethodObligationGuarded" ((PVar "env") (PVar "name") (PVar "s") (PVar "mono") (PVar "omitted")) (EIf (EBinOp "||" (EApp (EApp (EVar "lookupLocalFlag") (EVar "env")) (EVar "name")) (EApp (EVar "isMonoScheme") (EVar "s"))) (EVar "mono") (EApp (EApp (EApp (EApp (EVar "recordImplObligation") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "mono")) (EVar "omitted"))))
(DTypeSig false "exactReturnRow" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Scheme") (TyApp (TyCon "Option") (TyCon "MethodSchemeRow"))))))
(DFunDef false "exactReturnRow" ((PVar "env") (PVar "name") (PVar "scheme")) (EMatch (EApp (EApp (EVar "lookupMethodRow") (EVar "env")) (EVar "name")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "row")) () (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "lookupLocalFlag") (EVar "env")) (EVar "name")) (EApp (EVar "isMonoScheme") (EVar "scheme"))) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "definerShadowNamesRef") "value"))) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "standaloneValuesRef") "value"))) (EApp (EVar "isSome") (EApp (EApp (EVar "Scopes.enclosingDefaultBody") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (EApp (EApp (EVar "captureScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))))) (EBinOp ">=" (EApp (EVar "listLen") (EApp (EApp (EVar "methodAdmittedHere") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name"))) (ELit (LInt 2)))) (EVar "None") (EApp (EVar "Some") (EVar "row"))))))
(DTypeSig true "recordMethodObligationOwned" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Scheme") (TyFun (TyCon "Mono") (TyFun (TyCon "MethodInstantiationSubst") (TyFun (TyApp (TyCon "Option") (TyCon "EvId")) (TyCon "Mono"))))))))
(DFunDef false "recordMethodObligationOwned" ((PVar "env") (PVar "name") (PVar "scheme") (PVar "occurrence") (PVar "subst") (PVar "goalEv")) (EMatch (EApp (EApp (EApp (EVar "exactReturnRow") (EVar "env")) (EVar "name")) (EVar "scheme")) (arm (PCon "Some" (PVar "row")) () (EBlock (DoLet false false (PVar "request") (EApp (EApp (EApp (EApp (EApp (EVar "methodReturnRequest") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "row")) (EVar "occurrence")) (EVar "subst")) (EVar "goalEv"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordMethodLevelSlotsOwned") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "row")) (EFieldAccess (EVar "subst") "misTypeSubst")) (EFieldAccess (EVar "request") "mrrLoc")) (EFieldAccess (EVar "request") "mrrScope"))) (DoExpr (EApp (EApp (EVar "recordExactMethodObligation") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "request"))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "recordMethodObligationGuarded") (EVar "env")) (EVar "name")) (EVar "scheme")) (EVar "occurrence")) (EListLit)))))
(DTypeSig false "recordExactMethodObligation" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodReturnRequest") (TyCon "Mono"))))
(DFunDef false "recordExactMethodObligation" ((PVar "mctx") (PVar "request")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "noteMethodReturnTrace") (EVar "mctx")) (EVar "MRTProduced")) (EVar "request")) (EVar "None")) (EListLit))) (DoExpr (EApp (EApp (EVar "pushExactReturnObl") (EVar "mctx")) (EVar "request"))) (DoExpr (EFieldAccess (EVar "request") "mrrOccurrence"))))
(DTypeSig false "recordMethodLevelSlotsOwned" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodSchemeRow") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ScopeId") (TyCon "Unit")))))))
(DFunDef false "recordMethodLevelSlotsOwned" ((PVar "mctx") (PVar "row") (PVar "subst") (PVar "loc") (PVar "scope")) (EApp (EApp (EApp (EApp (EVar "recordInstantiatedMethodLevelSlots") (EVar "mctx")) (EApp (EApp (EApp (EVar "instantiateMethodPredicateSlots") (EFieldAccess (EVar "mctx") "mcGraph")) (EFieldAccess (EVar "row") "msrMethodSlots")) (EVar "subst"))) (EVar "loc")) (EVar "scope")))
(DTypeSig false "recordInstantiatedMethodLevelSlots" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "PredicateSlot")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ScopeId") (TyCon "Unit"))))))
(DFunDef false "recordInstantiatedMethodLevelSlots" ((PVar "mctx") (PList) PWild PWild) (ELit LUnit))
(DFunDef false "recordInstantiatedMethodLevelSlots" ((PVar "mctx") (PCons (PVar "slot") (PVar "rest")) (PVar "loc") (PVar "scope")) (EBlock (DoExpr (EMatch (EFieldAccess (EVar "slot") "psArgs") (arm (PCon "PSArgsUnknown") () (ELit LUnit)) (arm (PCon "PSArgsKnown" (PVar "args")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordOblAt") (EVar "mctx")) (ERecordCreate "Predicate" ((fa "iface" (EFieldAccess (EVar "slot") "psIface")) (fa "args" (EVar "args"))))) (ELit (LInt 0))) (EVar "PMethodLevel")) (EVar "loc")) (EVar "scope"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordInstantiatedMethodLevelSlots") (EVar "mctx")) (EVar "rest")) (EVar "loc")) (EVar "scope")))))
(DTypeSig false "recordNumLitObligationGuarded" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodSchemeRow") (TyFun (TyCon "ClassPredicate") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ScopeId") (TyCon "Mono"))))))))
(DFunDef false "recordNumLitObligationGuarded" ((PVar "mctx") (PVar "anchor") (PVar "predicate") (PVar "occurrence") (PVar "origin") (PVar "scope")) (EIf (EApp (EVar "isMonoScheme") (EFieldAccess (EVar "anchor") "msrScheme")) (EVar "occurrence") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordNumLitImplObligation") (EVar "mctx")) (EVar "anchor")) (EVar "predicate")) (EVar "occurrence")) (EVar "origin")) (EVar "scope"))))
(DTypeSig false "recordNumLitImplObligation" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodSchemeRow") (TyFun (TyCon "ClassPredicate") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ScopeId") (TyCon "Mono"))))))))
(DFunDef false "recordNumLitImplObligation" ((PVar "mctx") (PVar "anchor") (PVar "predicate") (PVar "occurrence") (PVar "origin") (PVar "scope")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "pushNumLitObl") (EVar "mctx")) (EVar "predicate")) (EVar "occurrence")) (EVar "origin")) (EVar "scope"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordMethodLevelObls") (EVar "mctx")) (EFieldAccess (EVar "anchor") "msrTyparams")) (EFieldAccess (EVar "anchor") "msrType")) (EVar "occurrence"))) (DoExpr (EVar "occurrence"))))
(DTypeSig false "recordMethodLevelObls" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyFun (TyCon "Mono") (TyCon "Unit"))))))
(DFunDef false "recordMethodLevelObls" ((PVar "mctx") (PVar "typarams") (PVar "mty") (PVar "occMono")) (EBlock (DoLet false false (PVar "slots") (EApp (EApp (EVar "methodLevelConstraintSlots") (EVar "typarams")) (EVar "mty"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "slots")) (ELit LUnit) (EMatch (EApp (EApp (EVar "matchTyMono") (EApp (EVar "stripLeadingMethodConstraints") (EVar "mty"))) (EVar "occMono")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "subst")) () (EApp (EApp (EApp (EVar "recordMethodLevelSlotObls") (EVar "mctx")) (EVar "slots")) (EVar "subst"))))))))
(DTypeSig false "recordMethodLevelSlotObls" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Constraint")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyCon "Unit")))))
(DFunDef false "recordMethodLevelSlotObls" ((PVar "mctx") (PList) PWild) (ELit LUnit))
(DFunDef false "recordMethodLevelSlotObls" ((PVar "mctx") (PCons (PVar "c") (PVar "rest")) (PVar "subst")) (EBlock (DoExpr (EIf (EApp (EApp (EVar "allList") (ELam ((PVar "v")) (EApp (EVar "isSome") (EApp (EApp (EVar "lookupAssoc") (EVar "v")) (EVar "subst"))))) (EApp (EVar "constraintVarNames") (EVar "c"))) (EApp (EApp (EApp (EApp (EApp (EVar "recordObl") (EVar "mctx")) (ERecordCreate "Predicate" ((fa "iface" (ERecordCreate "IfaceRef" ((fa "irName" (EApp (EVar "constraintIface") (EVar "c"))) (fa "irOrigin" (EFieldAccess (EVar "c") "constraintOrigin"))))) (fa "args" (EApp (EApp (EVar "map") (EApp (EApp (EVar "fromAstType") (EVar "mctx")) (EVar "subst"))) (EFieldAccess (EVar "c") "constraintArgs")))))) (ELit (LInt 0))) (EVar "PMethodLevel")) (EFieldAccess (EVar "mctx") "mcLoc")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "recordMethodLevelSlotObls") (EVar "mctx")) (EVar "rest")) (EVar "subst")))))
(DTypeSig true "recordSelectedStandaloneRoutes" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "ShadowDicts") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Ref") (TyCon "Route")) (TyApp (TyCon "Ref") (TyCon "Inner")))) (TyFun (TyCon "Mono") (TyCon "Unit")))))))
(DFunDef false "recordSelectedStandaloneRoutes" ((PVar "mctx") PWild PWild (PList) PWild) (ELit LUnit))
(DFunDef false "recordSelectedStandaloneRoutes" ((PVar "mctx") (PVar "mname") (PVar "dicts") (PCons (PTuple (PVar "r") (PVar "inner")) (PVar "rest")) (PVar "tx")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "pushSiteGoal") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "GKRLocalSite")) (EVar "inner")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PendingEntry") (EVar "mname")) (EVar "r")) (EVar "tx")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (EApp (EApp (EApp (EApp (EApp (EVar "SKRLocal") (EApp (EVar "routeLocalSym") (EUnOp "!" (EVar "r")))) (EVar "True")) (EFieldAccess (EVar "dicts") "sdMonos")) (EFieldAccess (EVar "dicts") "sdIfaces")) (EFieldAccess (EVar "dicts") "sdArgVecs"))) (EFieldAccess (EVar "mctx") "mcLoc")) (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordSelectedStandaloneRoutes") (EVar "mctx")) (EVar "mname")) (EVar "dicts")) (EVar "rest")) (EVar "tx")))))
(DTypeSig true "maybeStandaloneValueMono" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Mono")))))
(DFunDef false "maybeStandaloneValueMono" ((PVar "env") (PVar "name")) (EApp (EApp (EVar "map") (ELam ((PVar "value")) (EBlock (DoExpr (EApp (EApp (EVar "rejectAdmittedValueOccurrence") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name"))) (DoExpr (EFieldAccess (EFieldAccess (EApp (EApp (EApp (EApp (EApp (EVar "instantiateStandaloneOccurrence") (EVar "env")) (EVar "name")) (ELit (LString ""))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EVar "value")) "svoInstance") "mtiBody"))))) (EApp (EApp (EVar "standaloneValueBinding") (EVar "env")) (EVar "name"))))
(DTypeSig true "instantiateStandaloneOccurrence" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ValueScheme") (TyCon "SelectedValueOccurrence")))))))
(DFunDef false "instantiateStandaloneOccurrence" ((PVar "outer") (PVar "name") (PVar "sym") (PVar "origin") (PVar "value")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EVar "envAt") (EVar "origin")) (EVar "outer"))) (DoLet false false (PVar "inst") (EApp (EApp (EApp (EVar "instantiateValueTracked") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EFieldAccess (EVar "value") "vsScheme"))) (DoLet false false (PVar "declared") (EApp (EApp (EApp (EVar "declaredEffectsAt") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "inst")) (EFieldAccess (EVar "value") "vsDeclared"))) (DoExpr (EMatch (EVar "declared") (arm (PCon "Some" (PVar "dc")) () (EApp (EApp (EApp (EVar "recordDeclaredBindingCall") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "dc")) (EFieldAccess (EFieldAccess (EVar "inst") "mtiSubstitution") "misTypeSubst"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "recordShadowStandaloneObls") (EVar "env")) (EVar "name")) (EFieldAccess (EFieldAccess (EVar "inst") "mtiSubstitution") "misTypeSubst"))))) (DoLet false false (PVar "key") (EIf (EBinOp "==" (EVar "sym") (ELit (LString ""))) (EVar "name") (EVar "sym"))) (DoLet false false (PVar "dc") (EApp (EApp (EVar "optionOr") (EApp (EApp (EApp (EVar "shadowDeclaredFor") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "key"))) (EVar "declared"))) (DoExpr (ERecordCreate "SelectedValueOccurrence" ((fa "svoScheme" (EFieldAccess (EVar "value") "vsScheme")) (fa "svoInstance" (EVar "inst")) (fa "svoDicts" (EApp (EApp (EApp (EApp (EVar "shadowStandaloneDictSlots") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EFieldAccess (EVar "dc") "cdSlots")) (EFieldAccess (EVar "dc") "cdArgs")) (EFieldAccess (EFieldAccess (EVar "inst") "mtiSubstitution") "misTypeSubst"))))))))
(DTypeSig true "constrainedSigNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "constrainedSigNames" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "constrainedSigName")) (EVar "prog")))
(DTypeSig false "noDictHook" (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "Unit"))))
(DFunDef false "noDictHook" (PWild PWild) (ELit LUnit))
(DTypeSig false "mintDictAt" (TyFun (TyCon "ModuleCtx") (TyFun (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "Unit"))) (TyFun (TyCon "String") (TyCon "Expr")))))
(DFunDef false "mintDictAt" ((PVar "mctx") (PVar "onDict") (PVar "n")) (EBlock (DoLet false false (PVar "ev") (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "onDict") (EVar "n")) (EVar "ev"))) (DoExpr (EApp (EApp (EVar "EDictAt") (EVar "n")) (EVar "ev")))))
(DTypeSig false "prePassDeclScoped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyCon "Decl") (TyCon "Decl")))))
(DFunDef false "prePassDeclScoped" ((PVar "mctx") (PVar "rw") (PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "ps") (PVar "e") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "n")) (EVar "ps")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EApp (EVar "boundOfList") (EApp (EVar "patVarsListTc") (EVar "ps")))) (EVar "e"))) (EVar "site")) (EVar "bid")))
(DFunDef false "prePassDeclScoped" ((PVar "mctx") (PVar "rw") (PAs "d" (PRec "DInterface" ((rf "methods" None)) true))) (EVariantUpdate "DInterface" (EVar "d") ((fa "methods" (EApp (EApp (EVar "map") (EApp (EApp (EVar "prePassIfaceMethodScoped") (EVar "mctx")) (EVar "rw"))) (EVar "methods"))))))
(DFunDef false "prePassDeclScoped" ((PVar "mctx") (PVar "rw") (PAs "d" (PRec "DImpl" ((rf "methods" None)) true))) (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EApp (EApp (EVar "map") (EApp (EApp (EVar "prePassImplMethodScoped") (EVar "mctx")) (EVar "rw"))) (EVar "methods"))))))
(DFunDef false "prePassDeclScoped" ((PVar "mctx") (PVar "rw") (PCon "DProp" (PVar "pub") (PVar "name") (PVar "params") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DProp") (EVar "pub")) (EVar "name")) (EVar "params")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EApp (EVar "boundOfList") (EApp (EVar "propParamNamesTc") (EVar "params")))) (EVar "body"))))
(DFunDef false "prePassDeclScoped" ((PVar "mctx") (PVar "rw") (PCon "DTest" (PVar "pub") (PVar "name") (PVar "body"))) (EApp (EApp (EApp (EVar "DTest") (EVar "pub")) (EVar "name")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "omEmpty")) (EVar "body"))))
(DFunDef false "prePassDeclScoped" ((PVar "mctx") (PVar "rw") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EApp (EVar "prePassDeclScoped") (EVar "mctx")) (EVar "rw")) (EVar "d"))))
(DFunDef false "prePassDeclScoped" ((PVar "mctx") (PVar "rw") (PCon "DLetGroup" (PVar "pub") (PVar "binds"))) (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "prePassLetBindScoped") (EVar "mctx")) (EVar "rw"))) (EVar "binds"))))
(DFunDef false "prePassDeclScoped" ((PVar "mctx") PWild (PVar "d")) (EVar "d"))
(DTypeSig false "prePassLetBindScoped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyCon "LetBind") (TyCon "LetBind")))))
(DFunDef false "prePassLetBindScoped" ((PVar "mctx") (PVar "rw") (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "prePassFunClauseScoped") (EVar "mctx")) (EVar "rw"))) (EVar "clauses"))) (EVar "site")) (EVar "bid")))
(DTypeSig false "prePassFunClauseScoped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyCon "FunClause") (TyCon "FunClause")))))
(DFunDef false "prePassFunClauseScoped" ((PVar "mctx") (PVar "rw") (PCon "FunClause" (PVar "ps") (PVar "e"))) (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EApp (EVar "boundOfList") (EApp (EVar "patVarsListTc") (EVar "ps")))) (EVar "e"))))
(DTypeSig false "prePassIfaceMethodScoped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyCon "IfaceMethod") (TyCon "IfaceMethod")))))
(DFunDef false "prePassIfaceMethodScoped" ((PVar "mctx") PWild (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "None") (PVar "mloc"))) (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EVar "None")) (EVar "mloc")))
(DFunDef false "prePassIfaceMethodScoped" ((PVar "mctx") (PVar "rw") (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "Some" (PCon "MethodDefault" (PVar "ps") (PVar "e"))) (PVar "mloc"))) (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EApp (EVar "Some") (EApp (EApp (EVar "MethodDefault") (EVar "ps")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EApp (EVar "boundOfList") (EApp (EVar "patVarsListTc") (EVar "ps")))) (EVar "e"))))) (EVar "mloc")))
(DTypeSig false "prePassImplMethodScoped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod")))))
(DFunDef false "prePassImplMethodScoped" ((PVar "mctx") (PVar "rw") (PCon "ImplMethod" (PVar "n") (PVar "ps") (PVar "e"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "n")) (EVar "ps")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EApp (EVar "boundOfList") (EApp (EVar "patVarsListTc") (EVar "ps")))) (EVar "e"))))
(DTypeSig false "boundInsert" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "String")))))
(DFunDef false "boundInsert" ((PList) (PVar "b")) (EVar "b"))
(DFunDef false "boundInsert" ((PCons (PVar "n") (PVar "rest")) (PVar "b")) (EApp (EApp (EVar "boundInsert") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit (LString ""))) (EVar "b"))))
(DTypeSig false "localAbsCandidate" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "localAbsCandidate" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "localAbsCandidate") (EVar "e")))
(DFunDef false "localAbsCandidate" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "localAbsCandidate") (EVar "e")))
(DFunDef false "localAbsCandidate" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "localAbsCandidate") (EVar "e")))
(DFunDef false "localAbsCandidate" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EVar "localAbsCandidate") (EVar "e")))
(DFunDef false "localAbsCandidate" ((PCon "ELit" PWild)) (EVar "True"))
(DFunDef false "localAbsCandidate" ((PCon "EVar" PWild)) (EVar "True"))
(DFunDef false "localAbsCandidate" ((PCon "EVarId" PWild PWild)) (EVar "True"))
(DFunDef false "localAbsCandidate" ((PCon "EMethodAt" PWild PWild PWild)) (EVar "True"))
(DFunDef false "localAbsCandidate" ((PCon "EDictAt" PWild PWild)) (EVar "True"))
(DFunDef false "localAbsCandidate" ((PCon "EMethodRef" PWild)) (EVar "True"))
(DFunDef false "localAbsCandidate" ((PCon "ELam" PWild PWild)) (EVar "True"))
(DFunDef false "localAbsCandidate" ((PCon "ETuple" (PVar "es"))) (EApp (EApp (EVar "allList") (EVar "localAbsCandidate")) (EVar "es")))
(DFunDef false "localAbsCandidate" ((PCon "EListLit" (PVar "es"))) (EApp (EApp (EVar "allList") (EVar "localAbsCandidate")) (EVar "es")))
(DFunDef false "localAbsCandidate" ((PAs "app" (PCon "EApp" PWild PWild))) (EApp (EVar "localAbsCtorSpine") (EVar "app")))
(DFunDef false "localAbsCandidate" ((PCon "ERecordCreate" PWild (PVar "fs"))) (EApp (EApp (EVar "allList") (ELam ((PVar "fa")) (EMatch (EVar "fa") (arm (PCon "FieldAssign" PWild (PVar "e")) () (EApp (EVar "localAbsCandidate") (EVar "e")))))) (EVar "fs")))
(DFunDef false "localAbsCandidate" (PWild) (EVar "False"))
(DTypeSig false "localAbsCtorSpine" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "localAbsCtorSpine" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "localAbsCtorSpine") (EVar "e")))
(DFunDef false "localAbsCtorSpine" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "localAbsCtorSpine") (EVar "e")))
(DFunDef false "localAbsCtorSpine" ((PCon "EApp" (PVar "f") (PVar "x"))) (EBinOp "&&" (EApp (EVar "localAbsCtorSpine") (EVar "f")) (EApp (EVar "localAbsCandidate") (EVar "x"))))
(DFunDef false "localAbsCtorSpine" ((PCon "EVar" (PVar "name"))) (EApp (EVar "ctorHeadShaped") (EVar "name")))
(DFunDef false "localAbsCtorSpine" ((PCon "EVarId" (PVar "name") PWild)) (EApp (EVar "ctorHeadShaped") (EVar "name")))
(DFunDef false "localAbsCtorSpine" (PWild) (EVar "False"))
(DTypeSig false "localAbsCandidateBind" (TyFun (TyCon "LetBind") (TyCon "Bool")))
(DFunDef false "localAbsCandidateBind" ((PCon "LetBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EVar "anyList") (EVar "localAbsCandidateClause")) (EVar "clauses")))
(DTypeSig false "localAbsCandidateClause" (TyFun (TyCon "FunClause") (TyCon "Bool")))
(DFunDef false "localAbsCandidateClause" ((PCon "FunClause" (PList) (PVar "body"))) (EApp (EVar "localAbsCandidate") (EVar "body")))
(DFunDef false "localAbsCandidateClause" ((PCon "FunClause" PWild PWild)) (EVar "True"))
(DTypeSig false "letPatRename" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyTuple (TyCon "Pat") (TyApp (TyCon "OrdMap") (TyCon "String"))))))))
(DFunDef false "letPatRename" ((PVar "gctx") (PCon "PVar" (PVar "x") (PVar "l") (PVar "bid")) (PVar "e1") (PVar "b")) (EIf (EBinOp "&&" (EApp (EVar "localAbsCandidate") (EVar "e1")) (EApp (EVar "not") (EApp (EVar "isLocalAbsName") (EVar "x")))) (EBlock (DoLet false false (PVar "fresh") (EApp (EApp (EVar "freshLocalAbsName") (EVar "gctx")) (EVar "x"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "PVar") (EVar "fresh")) (EVar "l")) (EVar "bid")) (EApp (EApp (EApp (EVar "omInsert") (EVar "x")) (EVar "fresh")) (EVar "b"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "letPatRename" ((PVar "gctx") (PVar "p") PWild (PVar "b")) (ETuple (EVar "p") (EApp (EApp (EVar "boundInsert") (EApp (EVar "patVarsTc") (EVar "p"))) (EVar "b"))))
(DTypeSig false "bindsRename" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "LetBind")) (TyApp (TyCon "OrdMap") (TyCon "String")))))))
(DFunDef false "bindsRename" ((PVar "gctx") (PList) (PVar "b")) (ETuple (EListLit) (EVar "b")))
(DFunDef false "bindsRename" ((PVar "gctx") (PCons (PAs "bind" (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (PVar "rest")) (PVar "b")) (EBlock (DoLet false false (PTuple (PVar "n2") (PVar "b1")) (EIf (EBinOp "&&" (EApp (EVar "localAbsCandidateBind") (EVar "bind")) (EApp (EVar "not") (EApp (EVar "isLocalAbsName") (EVar "n")))) (EBlock (DoLet false false (PVar "fresh") (EApp (EApp (EVar "freshLocalAbsName") (EVar "gctx")) (EVar "n"))) (DoExpr (ETuple (EVar "fresh") (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "fresh")) (EVar "b"))))) (ETuple (EVar "n") (EApp (EApp (EVar "boundInsert") (EListLit (EVar "n"))) (EVar "b"))))) (DoLet false false (PTuple (PVar "rest2") (PVar "b2")) (EApp (EApp (EApp (EVar "bindsRename") (EVar "gctx")) (EVar "rest")) (EVar "b1"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n2")) (EVar "clauses")) (EVar "site")) (EVar "bid")) (EVar "rest2")) (EVar "b2")))))
(DTypeSig false "boundOfList" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "String"))))
(DFunDef false "boundOfList" ((PVar "ns")) (EApp (EApp (EVar "boundInsert") (EVar "ns")) (EVar "omEmpty")))
(DTypeSig false "rewriteArgScoped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Expr") (TyCon "Expr"))))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PCon "ArgRw" (PVar "rp") (PVar "dn") (PVar "an") (PVar "sm") (PVar "onDict") (PVar "granted")) (PVar "bound") (PCon "EVar" (PVar "n"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "bound")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "bound")) (arm (PCon "Some" (PLit (LString ""))) () (EApp (EVar "EVar") (EVar "n"))) (arm (PCon "Some" (PVar "renamed")) () (EApp (EApp (EVar "EDictAt") (EVar "renamed")) (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit)))) (arm (PCon "None") () (EApp (EVar "EVar") (EVar "n")))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "sm")) (arm (PCon "Some" (PVar "bare")) () (EApp (EApp (EApp (EVar "EMethodAt") (EVar "bare")) (EVar "n")) (EApp (EApp (EVar "mintMethodCell") (EVar "mctx")) (EVar "n")))) (arm (PCon "None") () (EIf (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "rp")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "an"))) (EApp (EApp (EApp (EVar "EMethodAt") (EVar "n")) (ELit (LString ""))) (EApp (EApp (EVar "mintMethodCell") (EVar "mctx")) (ELit (LString "")))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "dn")) (EApp (EApp (EApp (EVar "mintDictAt") (EVar "mctx")) (EVar "onDict")) (EVar "n")) (EIf (EApp (EVar "granted") (EVar "n")) (EApp (EApp (EVar "mintGrantOnly") (EVar "mctx")) (EVar "n")) (EApp (EVar "EVar") (EVar "n"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PCon "ArgRw" PWild (PVar "dn") PWild PWild (PVar "onDict") PWild) PWild (PCon "EDictAt" (PVar "n") (PVar "ev"))) (EIf (EBinOp "&&" (EApp (EApp (EVar "isGrantOnlyEv") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ev")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "dn"))) (EBlock (DoExpr (EApp (EApp (EVar "unmarkGrantOnly") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ev"))) (DoExpr (EApp (EApp (EVar "onDict") (EVar "n")) (EVar "ev"))) (DoExpr (EApp (EApp (EVar "EDictAt") (EVar "n")) (EVar "ev")))) (EIf (EVar "otherwise") (EApp (EApp (EVar "EDictAt") (EVar "n")) (EVar "ev")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ELam" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "ELam") (EVar "ps")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EApp (EApp (EVar "boundInsert") (EApp (EVar "patVarsListTc") (EVar "ps"))) (EVar "bound"))) (EVar "body"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ELet" (PVar "m") (PVar "r") (PVar "p") (PVar "e1") (PVar "e2"))) (EBlock (DoLet false false (PTuple (PVar "p2") (PVar "after")) (EApp (EApp (EApp (EApp (EVar "letPatRename") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "p")) (EVar "e1")) (EVar "bound"))) (DoLet false false (PVar "b1") (EIf (EVar "r") (EVar "after") (EVar "bound"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "r")) (EVar "p2")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "b1")) (EVar "e1"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "after")) (EVar "e2"))))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ELetGroup" (PVar "binds") (PVar "e2"))) (EBlock (DoLet false false (PTuple (PVar "binds2") (PVar "bnd")) (EApp (EApp (EApp (EVar "bindsRename") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "binds")) (EVar "bound"))) (DoExpr (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "rewriteArgLetBind") (EVar "mctx")) (EVar "rw")) (EVar "bnd"))) (EVar "binds2"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bnd")) (EVar "e2"))))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EMatch" (PVar "e0") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "rewriteArgArm") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "arms"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EApp (EApp (EVar "rewriteArgStmts") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "stmts"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EDo" (PVar "d") (PVar "stmts"))) (EApp (EApp (EVar "EDo") (EVar "d")) (EApp (EApp (EApp (EApp (EVar "rewriteArgStmts") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "stmts"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "EApp") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "f"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "x"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "EIf") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "c"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "t"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") (PVar "ev"))) (EBlock (DoLet false false (PVar "l2") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "l"))) (DoLet false false (PVar "r2") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "r"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EVar "l2")) (EVar "r2")) (EApp (EApp (EVar "mintedOr") (EApp (EVar "mintOpSite") (EVar "mctx"))) (EVar "ev"))))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EUnOp" (PVar "op") (PVar "x") (PVar "ev"))) (EBlock (DoLet false false (PVar "x2") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "x"))) (DoExpr (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EVar "x2")) (EApp (EApp (EVar "mintedOr") (EApp (EVar "mintOpSite") (EVar "mctx"))) (EVar "ev"))))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EInfix" (PVar "op") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "l"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "r"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EFieldAccess" (PVar "e0") (PVar "n") (PVar "ev"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EVar "n")) (EApp (EApp (EVar "mintedOr") (EApp (EVar "mintHeadSite") (EVar "mctx"))) (EVar "ev"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "lo"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "lo"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "lo"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EIndex" (PVar "e0") (PVar "i"))) (EApp (EApp (EVar "EIndex") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "i"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EVar "t")))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EHeadAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EVar "t")))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "rewriteArgField") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "fs"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ERecordUpdate" (PVar "e0") (PVar "fs") (PVar "ev"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "rewriteArgField") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "fs"))) (EApp (EApp (EVar "mintedOr") (EApp (EVar "mintHeadSite") (EVar "mctx"))) (EVar "ev"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EVariantUpdate" (PVar "c") (PVar "e0") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "c")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "rewriteArgField") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "fs"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "rewriteArgInterp") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "parts"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "rewriteArgGuardArm") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "arms"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ESection" (PCon "SecRight" (PVar "op") (PVar "e0")))) (EApp (EVar "ESection") (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0")))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ESection" (PCon "SecLeft" (PVar "e0") (PVar "op")))) (EApp (EVar "ESection") (EApp (EApp (EVar "SecLeft") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EVar "op"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "rewriteArgKv") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "kvs"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EAsPat" (PVar "x") (PVar "sub"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "sub"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") PWild PWild (PCon "ENumLit" (PVar "n") (PVar "ev") (PVar "lx"))) (EApp (EApp (EApp (EVar "ENumLit") (EVar "n")) (EApp (EApp (EVar "mintedOr") (EApp (EVar "mintLitSite") (EVar "mctx"))) (EVar "ev"))) (EVar "lx")))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") PWild PWild (PCon "EWideLit" (PVar "hi") (PVar "lo") (PVar "ev") (PVar "lx"))) (EApp (EApp (EApp (EApp (EVar "EWideLit") (EVar "hi")) (EVar "lo")) (EApp (EApp (EVar "mintedOr") (EApp (EVar "mintOpSite") (EVar "mctx"))) (EVar "ev"))) (EVar "lx")))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") PWild PWild (PVar "e")) (EVar "e"))
(DTypeSig false "rewriteArgField" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign"))))))
(DFunDef false "rewriteArgField" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))))
(DTypeSig false "rewriteArgKv" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr")))))))
(DFunDef false "rewriteArgKv" ((PVar "mctx") (PVar "rw") (PVar "bound") (PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "k")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "v"))))
(DTypeSig false "rewriteArgInterp" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "InterpPart") (TyCon "InterpPart"))))))
(DFunDef false "rewriteArgInterp" ((PVar "mctx") PWild PWild (PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "rewriteArgInterp" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))))
(DTypeSig false "rewriteArgLetBind" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "LetBind") (TyCon "LetBind"))))))
(DFunDef false "rewriteArgLetBind" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "rewriteArgFunClause") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "clauses"))) (EVar "site")) (EVar "bid")))
(DTypeSig false "rewriteArgFunClause" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "FunClause") (TyCon "FunClause"))))))
(DFunDef false "rewriteArgFunClause" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "FunClause" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EApp (EApp (EVar "boundInsert") (EApp (EVar "patVarsListTc") (EVar "ps"))) (EVar "bound"))) (EVar "body"))))
(DTypeSig false "rewriteArgArm" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Arm") (TyCon "Arm"))))))
(DFunDef false "rewriteArgArm" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EBlock (DoLet false false (PVar "b0") (EApp (EApp (EVar "boundInsert") (EApp (EVar "patVarsTc") (EVar "p"))) (EVar "bound"))) (DoLet false false (PTuple (PVar "gs2") (PVar "bnd")) (EApp (EApp (EApp (EApp (EVar "rewriteArgGuards") (EVar "mctx")) (EVar "rw")) (EVar "b0")) (EVar "gs"))) (DoExpr (EApp (EApp (EApp (EVar "Arm") (EVar "p")) (EVar "gs2")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bnd")) (EVar "body"))))))
(DTypeSig false "rewriteArgGuardArm" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "GuardArm") (TyCon "GuardArm"))))))
(DFunDef false "rewriteArgGuardArm" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "GuardArm" (PVar "gs") (PVar "body"))) (EBlock (DoLet false false (PTuple (PVar "gs2") (PVar "bnd")) (EApp (EApp (EApp (EApp (EVar "rewriteArgGuards") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "gs"))) (DoExpr (EApp (EApp (EVar "GuardArm") (EVar "gs2")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bnd")) (EVar "body"))))))
(DTypeSig false "rewriteArgGuards" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyTuple (TyApp (TyCon "List") (TyCon "Guard")) (TyApp (TyCon "OrdMap") (TyCon "String"))))))))
(DFunDef false "rewriteArgGuards" ((PVar "mctx") PWild (PVar "bound") (PList)) (ETuple (EListLit) (EVar "bound")))
(DFunDef false "rewriteArgGuards" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCons (PCon "GBool" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "e2") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))) (DoLet false false (PTuple (PVar "rest2") (PVar "bnd")) (EApp (EApp (EApp (EApp (EVar "rewriteArgGuards") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EVar "GBool") (EVar "e2")) (EVar "rest2")) (EVar "bnd")))))
(DFunDef false "rewriteArgGuards" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCons (PCon "GBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "e2") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))) (DoLet false false (PTuple (PVar "rest2") (PVar "bnd")) (EApp (EApp (EApp (EApp (EVar "rewriteArgGuards") (EVar "mctx")) (EVar "rw")) (EApp (EApp (EVar "boundInsert") (EApp (EVar "patVarsTc") (EVar "p"))) (EVar "bound"))) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "GBind") (EVar "p")) (EVar "e2")) (EVar "rest2")) (EVar "bnd")))))
(DTypeSig false "rewriteArgStmts" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "List") (TyCon "DoStmt")))))))
(DFunDef false "rewriteArgStmts" ((PVar "mctx") PWild PWild (PList)) (EListLit))
(DFunDef false "rewriteArgStmts" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCons (PCon "DoExpr" (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EVar "DoExpr") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgStmts") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "rest"))))
(DFunDef false "rewriteArgStmts" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCons (PCon "DoBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DoBind") (EVar "p")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgStmts") (EVar "mctx")) (EVar "rw")) (EApp (EApp (EVar "boundInsert") (EApp (EVar "patVarsTc") (EVar "p"))) (EVar "bound"))) (EVar "rest"))))
(DFunDef false "rewriteArgStmts" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCons (PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e") (PVar "site")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "p2") (PVar "after")) (EApp (EApp (EApp (EApp (EVar "letPatRename") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "p")) (EVar "e")) (EVar "bound"))) (DoLet false false (PVar "b1") (EIf (EVar "r") (EVar "after") (EVar "bound"))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p2")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "b1")) (EVar "e"))) (EVar "site")) (EApp (EApp (EApp (EApp (EVar "rewriteArgStmts") (EVar "mctx")) (EVar "rw")) (EVar "after")) (EVar "rest"))))))
(DFunDef false "rewriteArgStmts" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCons (PCon "DoAssign" (PVar "x") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgStmts") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "rest"))))
(DFunDef false "rewriteArgStmts" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCons (PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgStmts") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "rest"))))
(DTypeSig true "methodConstraintNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "methodConstraintNames" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "methodConstraintNamesOfDecl")) (EVar "prog")))
(DTypeSig false "methodConstraintNamesOfDecl" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "methodConstraintNamesOfDecl" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "methodConstraintNamesOfDecl") (EVar "d")))
(DFunDef false "methodConstraintNamesOfDecl" ((PRec "DInterface" ((rf "typarams" None) (rf "methods" None)) true)) (EApp (EApp (EVar "flatMap") (EApp (EVar "methodConstraintNameOf") (EVar "typarams"))) (EVar "methods")))
(DFunDef false "methodConstraintNamesOfDecl" (PWild) (EListLit))
(DTypeSig false "methodConstraintNameOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "methodConstraintNameOf" ((PVar "typarams") (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild PWild)) (EIf (EApp (EApp (EVar "hasMethodLevelConstraint") (EVar "typarams")) (EVar "mty")) (EListLit (EVar "mname")) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "hasMethodLevelConstraint" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyCon "Bool"))))
(DFunDef false "hasMethodLevelConstraint" ((PVar "typarams") (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "||" (EApp (EApp (EVar "constraintsHaveMethodLevel") (EVar "typarams")) (EVar "cs")) (EApp (EApp (EVar "hasMethodLevelConstraint") (EVar "typarams")) (EVar "t"))))
(DFunDef false "hasMethodLevelConstraint" ((PVar "typarams") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EVar "hasMethodLevelConstraint") (EVar "typarams")) (EVar "t")))
(DFunDef false "hasMethodLevelConstraint" (PWild PWild) (EVar "False"))
(DTypeSig false "constraintsHaveMethodLevel" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Constraint")) (TyCon "Bool"))))
(DFunDef false "constraintsHaveMethodLevel" (PWild (PList)) (EVar "False"))
(DFunDef false "constraintsHaveMethodLevel" ((PVar "typarams") (PCons (PVar "c") (PVar "rest"))) (EBinOp "||" (EApp (EApp (EVar "constraintIsMethodLevel") (EVar "typarams")) (EVar "c")) (EApp (EApp (EVar "constraintsHaveMethodLevel") (EVar "typarams")) (EVar "rest"))))
(DTypeSig false "instantiateMethodPredicateTemplate" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "MethodPredicateTemplate") (TyFun (TyCon "MethodInstantiationSubst") (TyCon "MethodPredicateTemplate")))))
(DFunDef false "instantiateMethodPredicateTemplate" ((PVar "gctx") (PVar "template") (PVar "subst")) (ERecordCreate "MethodPredicateTemplate" ((fa "mptInterface" (EFieldAccess (EVar "template") "mptInterface")) (fa "mptArguments" (EApp (EApp (EVar "map") (EApp (EApp (EVar "instantiateMethodPredicateArgument") (EVar "gctx")) (EVar "subst"))) (EFieldAccess (EVar "template") "mptArguments"))))))
(DTypeSig false "instantiateMethodPredicateArgument" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "MethodInstantiationSubst") (TyFun (TyApp (TyCon "Option") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "Mono"))))))
(DFunDef false "instantiateMethodPredicateArgument" ((PVar "gctx") (PVar "subst") (PVar "argument")) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EFieldAccess (EVar "subst") "misTypeSubst")) (EFieldAccess (EVar "subst") "misEffectSubst")) (EFieldAccess (EVar "subst") "misAuthSubst"))) (EVar "argument")))
(DTypeSig false "omittedParamVars" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))))))
(DFunDef false "omittedParamVars" ((PVar "mctx") (PVar "typarams") (PVar "mty")) (EBlock (DoLet false false (PVar "named") (EApp (EVar "tyVarNames") (EApp (EVar "stripTyConstraints") (EVar "mty")))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "tp")) (ETuple (EVar "tp") (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "tp")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "tp")) (EVar "named"))))) (EVar "typarams"))))))
(DTypeSig true "methodOmittedVars" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))))
(DFunDef false "methodOmittedVars" ((PVar "mctx") (PVar "name")) (EMatch (ETuple (EApp (EApp (EVar "argDispatchOf") (EVar "mctx")) (EVar "name")) (EApp (EApp (EVar "methodEntryHere") (EVar "mctx")) (EVar "name"))) (arm (PTuple (PCon "Some" PWild) (PCon "Some" (PTuple PWild (PVar "typarams") (PVar "mty") PWild))) () (EApp (EApp (EApp (EVar "omittedParamVars") (EVar "mctx")) (EVar "typarams")) (EVar "mty"))) (arm PWild () (EListLit))))
(DTypeSig false "methodLevelConstraintSlots" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Constraint")))))
(DFunDef false "methodLevelConstraintSlots" ((PVar "typarams") (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "++" (EApp (EApp (EVar "filterList") (EApp (EVar "constraintIsMethodLevel") (EVar "typarams"))) (EVar "cs")) (EApp (EApp (EVar "methodLevelConstraintSlots") (EVar "typarams")) (EVar "t"))))
(DFunDef false "methodLevelConstraintSlots" ((PVar "typarams") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EVar "methodLevelConstraintSlots") (EVar "typarams")) (EVar "t")))
(DFunDef false "methodLevelConstraintSlots" (PWild PWild) (EListLit))
(DTypeSig false "stripLeadingMethodConstraints" (TyFun (TyCon "Ty") (TyCon "Ty")))
(DFunDef false "stripLeadingMethodConstraints" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "stripLeadingMethodConstraints") (EVar "t")))
(DFunDef false "stripLeadingMethodConstraints" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "stripLeadingMethodConstraints") (EVar "t")))
(DFunDef false "stripLeadingMethodConstraints" ((PVar "t")) (EVar "t"))
(DTypeSig false "moduleDictNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "moduleDictNames" ((PVar "preludeNames") (PVar "modules")) (EBinOp "++" (EVar "preludeNames") (EApp (EVar "constrainedSigNames") (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "modules")))))
(DTypeSig false "argRwOf" (TyFun (TyCon "MarkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "Unit"))) (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyCon "ArgRw"))))))
(DFunDef false "argRwOf" ((PVar "mc") (PVar "dn") (PVar "onDict") (PVar "granted")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ArgRw") (EFieldAccess (EVar "mc") "mcRp")) (EVar "dn")) (EFieldAccess (EVar "mc") "mcAn")) (EFieldAccess (EVar "mc") "mcSm")) (EVar "onDict")) (EVar "granted")))
(DTypeSig true "markTailDecls" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MarkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))))))
(DFunDef false "markTailDecls" ((PVar "mctx") (PVar "mc") (PVar "dn") (PVar "granted") (PVar "decls")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "markTailDecl") (EVar "mctx")) (EApp (EApp (EApp (EApp (EVar "argRwOf") (EVar "mc")) (EVar "dn")) (EVar "noDictHook")) (EVar "granted")))) (EVar "decls")))
(DTypeSig false "markTailDecl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyCon "Decl") (TyCon "Decl")))))
(DFunDef false "markTailDecl" ((PVar "mctx") PWild (PAs "d" (PCon "DFunDef" PWild PWild PWild PWild PWild PWild))) (EVar "d"))
(DFunDef false "markTailDecl" ((PVar "mctx") PWild (PAs "d" (PCon "DLetGroup" PWild PWild))) (EVar "d"))
(DFunDef false "markTailDecl" ((PVar "mctx") (PVar "rw") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EApp (EVar "markTailDecl") (EVar "mctx")) (EVar "rw")) (EVar "d"))))
(DFunDef false "markTailDecl" ((PVar "mctx") (PVar "rw") (PVar "d")) (EApp (EApp (EApp (EVar "prePassDeclScoped") (EVar "mctx")) (EVar "rw")) (EVar "d")))
(DTypeSig false "markClauseWith" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "markClauseWith" ((PVar "mctx") (PVar "rw") (PTuple (PVar "ps") (PVar "e"))) (ETuple (EVar "ps") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EApp (EVar "boundOfList") (EApp (EVar "patVarsListTc") (EVar "ps")))) (EVar "e"))))
(DTypeSig true "evIdModule" (TyFun (TyCon "EvId") (TyCon "String")))
(DFunDef false "evIdModule" ((PCon "EvId" (PVar "m") PWild)) (EVar "m"))
(DTypeSig true "markSetsOf" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PreludeMarkFacts") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "MarkSets")))))))
(DFunDef false "markSetsOf" ((PVar "gctx") (PVar "pmf") (PVar "coreDecls") (PVar "modules") (PVar "allDecls")) (EBlock (DoLet false false (PVar "units") (EBinOp "::" (ETuple (ELit (LString "core")) (EVar "coreDecls")) (EVar "modules"))) (DoLet false false (PVar "userDecls") (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "modules"))) (DoLet false false (PVar "shadowMap") (EApp (EApp (EVar "computeMangledShadowMap") (EVar "allDecls")) (EVar "units"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "mangledShadowMapRef")) (EVar "shadowMap"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "argDispatchIdxByIdRef")) (EBinOp "++" (EFieldAccess (EVar "pmf") "pmfArgDispatchById") (EApp (EVar "argDispatchIndicesById") (EVar "userDecls"))))) (DoLet false false (PVar "rpNames") (EBinOp "++" (EFieldAccess (EVar "pmf") "pmfReturnPos") (EApp (EVar "returnPosMethodNames") (EVar "userDecls")))) (DoLet false false (PVar "markSharedNames") (EApp (EVar "dedup") (EBinOp "++" (EBinOp "++" (EVar "rpNames") (EFieldAccess (EVar "pmf") "pmfMethodConstraints")) (EApp (EVar "methodConstraintNames") (EVar "userDecls"))))) (DoLet false false (PVar "graphShadowNames") (EApp (EApp (EApp (EVar "buildStandaloneShadowsGraph") (EVar "shadowMap")) (EVar "allDecls")) (EVar "userDecls"))) (DoLet false false (PVar "ms") (ERecordCreate "MarkSets" ((fa "msMarkRpNames" (EApp (EVar "dedup") (EBinOp "++" (EVar "markSharedNames") (EVar "graphShadowNames")))) (fa "msMarkSharedNames" (EVar "markSharedNames")) (fa "msGraphShadowNames" (EVar "graphShadowNames")) (fa "msArgNames" (EApp (EApp (EVar "map") (EVar "fst")) (EBinOp "++" (EFieldAccess (EVar "pmf") "pmfArgDispatch") (EApp (EVar "argDispatchIndices") (EVar "userDecls"))))) (fa "msCoreShadowMap" (EApp (EApp (EApp (EVar "coreShadowMapFor") (EVar "gctx")) (EVar "coreDecls")) (EVar "shadowMap"))) (fa "msBareDictNames" (EApp (EVar "dedup") (EApp (EApp (EVar "moduleDictNames") (EFieldAccess (EVar "pmf") "pmfConstrainedNames")) (EVar "modules")))) (fa "msUnits" (EVar "units"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "markSetsRef")) (EApp (EVar "Some") (EVar "ms")))) (DoExpr (EVar "ms"))))
(DTypeSig true "markDictNames" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "markDictNames" ((PVar "gctx") (PVar "names") (PVar "coreDecls") (PVar "modules")) (EApp (EVar "dedup") (EBinOp "++" (EVar "names") (EApp (EApp (EApp (EApp (EVar "aliasDictNames") (EVar "gctx")) (EVar "names")) (EBinOp "::" (ETuple (ELit (LString "core")) (EVar "coreDecls")) (EVar "modules"))) (EVar "modules")))))
(DTypeSig true "markGroupClauses" (TyFun (TyCon "ModuleMarking") (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))))
(DFunDef false "markGroupClauses" ((PVar "mm") (PVar "env") (PVar "members") (PVar "grouped")) (EBlock (DoLet false false (PVar "own") (EApp (EApp (EVar "omFromNames") (EVar "members")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EApp (EVar "mapGroupClauses") (EApp (EApp (EVar "markClauseWith") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EApp (EApp (EApp (EVar "argRwOf") (EFieldAccess (EVar "mm") "mmCtx")) (EFieldAccess (EFieldAccess (EVar "mm") "mmDictSet") "value")) (EVar "noDictHook")) (ELam ((PVar "n")) (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "own")) (EApp (EApp (EVar "grantNameIn") (EVar "env")) (EVar "n"))))))) (EVar "members")) (EVar "grouped")))))
(DTypeSig true "mapGroupClauses" (TyFun (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))))
(DFunDef false "mapGroupClauses" (PWild (PList) (PVar "grouped")) (EVar "grouped"))
(DFunDef false "mapGroupClauses" ((PVar "f") (PCons (PVar "m") (PVar "rest")) (PVar "grouped")) (EApp (EApp (EApp (EVar "mapGroupClauses") (EVar "f")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "m")) (EApp (EVar "reverse") (EApp (EApp (EVar "map") (EVar "f")) (EApp (EApp (EVar "clausesOf") (EVar "m")) (EVar "grouped"))))) (EVar "grouped"))))
(DTypeSig true "markRecursiveOccurrences" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ModuleMarking") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "ScopedMember")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))))))
(DFunDef false "markRecursiveOccurrences" ((PVar "mctx") (PVar "mm") (PVar "placeholders") (PVar "scopedMembers") (PVar "grouped")) (EBlock (DoLet false false (PVar "promoted") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "promotedRef") "value")) (EVar "omEmpty"))) (DoLet false false (PVar "fresh") (EApp (EApp (EVar "filterList") (ELam ((PVar "m")) (EBinOp "&&" (EApp (EApp (EVar "omHasKey") (EVar "m")) (EVar "promoted")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "m")) (EFieldAccess (EFieldAccess (EVar "mm") "mmDictSet") "value")))))) (EApp (EApp (EVar "map") (ELam ((PVar "member")) (EFieldAccess (EVar "member") "smName"))) (EVar "scopedMembers")))) (DoExpr (EMatch (EVar "fresh") (arm (PList) () (EVar "grouped")) (arm PWild () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "mm") "mmDictSet")) (EApp (EApp (EVar "omFromNames") (EVar "fresh")) (EFieldAccess (EFieldAccess (EVar "mm") "mmDictSet") "value")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recMarkMembers") (EVar "mctx")) (EApp (EApp (EVar "omFromNames") (EVar "fresh")) (EVar "omEmpty"))) (EVar "placeholders")) (EVar "scopedMembers")) (EVar "grouped")))))))))
(DTypeSig false "recMarkMembers" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "ScopedMember")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))))))
(DFunDef false "recMarkMembers" ((PVar "mctx") PWild PWild (PList) (PVar "grouped")) (EVar "grouped"))
(DFunDef false "recMarkMembers" ((PVar "mctx") (PVar "dn") (PVar "placeholders") (PCons (PVar "member") (PVar "rest")) (PVar "grouped")) (EBlock (DoLet false false (PVar "m") (EFieldAccess (EVar "member") "smName")) (DoLet false false (PVar "onDict") (ELam ((PVar "callee") (PVar "ev")) (EApp (EApp (EVar "pushRecDictAppGoal") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "RecDictApp") (EApp (EVar "Ref") (EListLit))) (EVar "callee")) (EVar "m")) (EApp (EApp (EVar "placeholderMonoOf") (EVar "callee")) (EVar "placeholders"))) (EFieldAccess (EVar "member") "smScope")) (EVar "ev"))))) (DoLet false false (PVar "rw") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ArgRw") (EVar "omEmpty")) (EVar "dn")) (EVar "omEmpty")) (EListLit)) (EVar "onDict")) (ELam (PWild) (EVar "False")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recMarkMembers") (EVar "mctx")) (EVar "dn")) (EVar "placeholders")) (EVar "rest")) (EApp (EApp (EApp (EVar "mapGroupClauses") (EApp (EApp (EVar "markClauseWith") (EVar "mctx")) (EVar "rw"))) (EListLit (EVar "m"))) (EVar "grouped"))))))
(DTypeSig false "placeholderMonoOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyCon "Mono"))))
(DFunDef false "placeholderMonoOf" ((PVar "callee") (PVar "placeholders")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "callee")) (EVar "placeholders")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "markRecursiveOccurrences: ")) (EApp (EVar "display") (EVar "callee"))) (ELit (LString " is not a member of the group")))))))
(DTypeSig true "rebuildGroupDecls" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "rebuildGroupDecls" ((PVar "grouped") (PVar "prog")) (EApp (EVar "fst") (EApp (EApp (EApp (EVar "rebuildGroupDeclsGo") (EVar "grouped")) (EVar "omEmpty")) (EVar "prog"))))
(DTypeSig false "rebuildGroupDeclsGo" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))))
(DFunDef false "rebuildGroupDeclsGo" (PWild (PVar "pending") (PList)) (ETuple (EListLit) (EVar "pending")))
(DFunDef false "rebuildGroupDeclsGo" ((PVar "grouped") (PVar "pending") (PCons (PCon "DFunDef" (PVar "pub") (PVar "n") PWild PWild (PVar "site") (PVar "bid")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PTuple (PVar "ps") (PVar "e")) (PVar "pending2")) (EApp (EApp (EApp (EVar "popMarkedClause") (EVar "grouped")) (EVar "pending")) (EVar "n"))) (DoLet false false (PTuple (PVar "ds") (PVar "pending3")) (EApp (EApp (EApp (EVar "rebuildGroupDeclsGo") (EVar "grouped")) (EVar "pending2")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "n")) (EVar "ps")) (EVar "e")) (EVar "site")) (EVar "bid")) (EVar "ds")) (EVar "pending3")))))
(DFunDef false "rebuildGroupDeclsGo" ((PVar "grouped") (PVar "pending") (PCons (PCon "DLetGroup" (PVar "pub") (PVar "binds")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "binds2") (PVar "pending2")) (EApp (EApp (EApp (EVar "rebuildLetBinds") (EVar "grouped")) (EVar "pending")) (EVar "binds"))) (DoLet false false (PTuple (PVar "ds") (PVar "pending3")) (EApp (EApp (EApp (EVar "rebuildGroupDeclsGo") (EVar "grouped")) (EVar "pending2")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EVar "binds2")) (EVar "ds")) (EVar "pending3")))))
(DFunDef false "rebuildGroupDeclsGo" ((PVar "grouped") (PVar "pending") (PCons (PCon "DAttrib" (PVar "attrs") (PVar "d")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "inner") (PVar "pending2")) (EApp (EApp (EApp (EVar "rebuildGroupDeclsGo") (EVar "grouped")) (EVar "pending")) (EListLit (EVar "d")))) (DoLet false false (PTuple (PVar "ds") (PVar "pending3")) (EApp (EApp (EApp (EVar "rebuildGroupDeclsGo") (EVar "grouped")) (EVar "pending2")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "d2")) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EVar "d2")))) (EVar "inner")) (EVar "ds")) (EVar "pending3")))))
(DFunDef false "rebuildGroupDeclsGo" ((PVar "grouped") (PVar "pending") (PCons (PVar "d") (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "ds") (PVar "pending2")) (EApp (EApp (EApp (EVar "rebuildGroupDeclsGo") (EVar "grouped")) (EVar "pending")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EVar "d") (EVar "ds")) (EVar "pending2")))))
(DTypeSig false "rebuildLetBinds" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyTuple (TyApp (TyCon "List") (TyCon "LetBind")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))))
(DFunDef false "rebuildLetBinds" (PWild (PVar "pending") (PList)) (ETuple (EListLit) (EVar "pending")))
(DFunDef false "rebuildLetBinds" ((PVar "grouped") (PVar "pending") (PCons (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "clauses2") (PVar "pending2")) (EApp (EApp (EApp (EApp (EVar "rebuildFunClauses") (EVar "grouped")) (EVar "pending")) (EVar "n")) (EVar "clauses"))) (DoLet false false (PTuple (PVar "binds") (PVar "pending3")) (EApp (EApp (EApp (EVar "rebuildLetBinds") (EVar "grouped")) (EVar "pending2")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EVar "clauses2")) (EVar "site")) (EVar "bid")) (EVar "binds")) (EVar "pending3")))))
(DTypeSig false "rebuildFunClauses" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyTuple (TyApp (TyCon "List") (TyCon "FunClause")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))))))
(DFunDef false "rebuildFunClauses" (PWild (PVar "pending") PWild (PList)) (ETuple (EListLit) (EVar "pending")))
(DFunDef false "rebuildFunClauses" ((PVar "grouped") (PVar "pending") (PVar "n") (PCons PWild (PVar "rest"))) (EBlock (DoLet false false (PTuple (PTuple (PVar "ps") (PVar "e")) (PVar "pending2")) (EApp (EApp (EApp (EVar "popMarkedClause") (EVar "grouped")) (EVar "pending")) (EVar "n"))) (DoLet false false (PTuple (PVar "cs") (PVar "pending3")) (EApp (EApp (EApp (EApp (EVar "rebuildFunClauses") (EVar "grouped")) (EVar "pending2")) (EVar "n")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "FunClause") (EVar "ps")) (EVar "e")) (EVar "cs")) (EVar "pending3")))))
(DTypeSig false "popMarkedClause" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyCon "String") (TyTuple (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))))
(DFunDef false "popMarkedClause" ((PVar "grouped") (PVar "pending") (PVar "n")) (EBlock (DoLet false false (PVar "remaining") (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "pending")) (arm (PCon "Some" (PVar "cs")) () (EVar "cs")) (arm (PCon "None") () (EApp (EApp (EVar "clausesOf") (EVar "n")) (EVar "grouped"))))) (DoExpr (EMatch (EVar "remaining") (arm (PCons (PVar "c") (PVar "cs")) () (ETuple (EVar "c") (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "cs")) (EVar "pending")))) (arm (PList) () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "rebuildGroupDecls: no marked clause left for ")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "")))))))))
(DTypeSig true "cellGoalInnerAliasing" (TyFun (TyCon "GraphCtx") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Bool")))))
(DFunDef false "cellGoalInnerAliasing" ((PVar "gctx")) (EBlock (DoLet false false (PVar "g") (EFieldAccess (EVar "gctx") "graphRun")) (DoLet false false (PVar "cells") (EApp (EApp (EApp (EVar "cellsFrom") (EFieldAccess (EFieldAccess (EVar "g") "evCells") "value")) (ELit (LInt 0))) (EListLit))) (DoExpr (EApp (EApp (EVar "filterMap") (ELam ((PVar "o")) (EApp (EApp (EVar "map") (ELam ((PVar "c")) (ETuple (EApp (EVar "goalKindName") (EFieldAccess (EVar "o") "oKind")) (EApp (EApp (EVar "innerAliases") (EVar "o")) (EVar "c"))))) (EApp (EApp (EVar "cellOfGoal") (EVar "cells")) (EVar "o"))))) (EFieldAccess (EFieldAccess (EVar "g") "goals") "value")))))
(DTypeSig false "cellsFrom" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvCell"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "EvCell")) (TyApp (TyCon "List") (TyCon "EvCell"))))))
(DFunDef false "cellsFrom" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "reverseL") (EVar "acc")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (arm (PCon "Some" (PVar "c")) () (EApp (EApp (EApp (EVar "cellsFrom") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EVar "c") (EVar "acc")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "cellsFrom") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "cellOfGoal" (TyFun (TyApp (TyCon "List") (TyCon "EvCell")) (TyFun (TyCon "Obligation") (TyApp (TyCon "Option") (TyCon "EvCell")))))
(DFunDef false "cellOfGoal" ((PVar "cells") (PVar "o")) (EMatch (EFieldAccess (EVar "o") "oDest") (arm (PCon "EvRoute" (PVar "r")) () (EBlock (DoLet false false (PVar "saved") (EFieldAccess (EVar "r") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EVar "r")) (EApp (EApp (EVar "RLocal") (EVar "aliasMarker")) (EListLit)))) (DoLet false false (PVar "hit") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "isAliasMarker") (EFieldAccess (EFieldAccess (EVar "c") "ecTag") "value")))) (EVar "cells"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "r")) (EVar "saved"))) (DoExpr (EApp (EVar "onlyCell") (EVar "hit"))))) (arm (PCon "EvRoutes" (PVar "rs")) () (EBlock (DoLet false false (PVar "saved") (EFieldAccess (EVar "rs") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EVar "rs")) (EListLit (EApp (EApp (EVar "RLocal") (EVar "aliasMarker")) (EListLit))))) (DoLet false false (PVar "hit") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EApp (EVar "anyList") (EVar "isAliasMarker")) (EBinOp "++" (EFieldAccess (EFieldAccess (EVar "c") "ecImpl") "value") (EFieldAccess (EFieldAccess (EVar "c") "ecMeth") "value"))))) (EVar "cells"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "rs")) (EVar "saved"))) (DoExpr (EApp (EVar "onlyCell") (EVar "hit")))))))
(DTypeSig false "onlyCell" (TyFun (TyApp (TyCon "List") (TyCon "EvCell")) (TyApp (TyCon "Option") (TyCon "EvCell"))))
(DFunDef false "onlyCell" ((PList (PVar "c"))) (EApp (EVar "Some") (EVar "c")))
(DFunDef false "onlyCell" (PWild) (EVar "None"))
(DTypeSig false "aliasMarker" (TyCon "String"))
(DFunDef false "aliasMarker" () (ELit (LString "<inner-alias-probe>")))
(DTypeSig false "isAliasMarker" (TyFun (TyCon "Route") (TyCon "Bool")))
(DFunDef false "isAliasMarker" ((PCon "RLocal" (PVar "sym") PWild)) (EBinOp "==" (EVar "sym") (EVar "aliasMarker")))
(DFunDef false "isAliasMarker" (PWild) (EVar "False"))
(DTypeSig false "innerAliases" (TyFun (TyCon "Obligation") (TyFun (TyCon "EvCell") (TyCon "Bool"))))
(DFunDef false "innerAliases" ((PVar "o") (PVar "c")) (EBlock (DoLet false false (PVar "savedGoal") (EFieldAccess (EFieldAccess (EVar "o") "oInner") "value")) (DoLet false false (PVar "savedCell") (EFieldAccess (EFieldAccess (EVar "c") "ecInner") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "c") "ecInner")) (EVar "innerNone"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "o") "oInner")) (EApp (EApp (EVar "Inner") (EVar "True")) (EVar "True")))) (DoLet false false (PVar "hit") (EMatch (EFieldAccess (EFieldAccess (EVar "c") "ecInner") "value") (arm (PCon "Inner" (PCon "True") (PCon "True")) () (EVar "True")) (arm PWild () (EVar "False")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "o") "oInner")) (EVar "savedGoal"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "c") "ecInner")) (EVar "savedCell"))) (DoExpr (EVar "hit"))))
(DTypeSig true "cellStoreMisses" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvId") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "cellStoreMisses" ((PVar "gctx") (PVar "ev")) (ETuple (EApp (EVar "missText") (EApp (EApp (EVar "siteCellLookup") (EVar "gctx")) (EVar "ev"))) (EApp (EVar "missText") (EApp (EApp (EVar "methodCellLookup") (EVar "gctx")) (EVar "ev")))))
(DTypeSig false "missText" (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a")) (TyCon "String")))
(DFunDef false "missText" ((PCon "Ok" PWild)) (ELit (LString "")))
(DFunDef false "missText" ((PCon "Err" (PVar "message"))) (EVar "message"))
(DTypeSig true "firstMethodRow" (TyFun (TyApp (TyCon "List") (TyCon "MethodSchemeRow")) (TyCon "MethodSchemeRow")))
(DFunDef false "firstMethodRow" ((PCons (PVar "row") PWild)) (EVar "row"))
(DFunDef false "firstMethodRow" ((PList)) (EApp (EVar "panic") (ELit (LString "method-row observer expected a row"))))
(DTypeSig false "observeMethodSchemeRowsForTest" (TyFun (TyCon "Unit") (TyCon "MethodRowTestObservation")))
(DFunDef false "observeMethodSchemeRowsForTest" (PWild) (EBlock (DoLet false false (PVar "graph1") (EApp (EVar "probeGraphCtx") (ELit LUnit))) (DoLet false false (PVar "rows1") (EApp (EVar "initialModuleCtx") (EVar "graph1"))) (DoLet false false (PVar "constrainedRow") (EApp (EVar "firstMethodRow") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "rows1")) (EListLit (EVar "methodRowTestFoldMapDecl"))))) (DoLet false false (PVar "constrainedIds") (EApp (EVar "schemeIds") (EFieldAccess (EVar "constrainedRow") "msrScheme"))) (DoLet false false (PVar "constrainedSlots") (EFieldAccess (EVar "constrainedRow") "msrMethodSlots")) (DoLet false false (PVar "constrainedBoundIds") (EApp (EVar "methodSlotBoundIds") (EVar "constrainedSlots"))) (DoLet false false (PVar "constrainedPositions") (EApp (EVar "methodSlotPositions") (EVar "constrainedSlots"))) (DoLet false false (PVar "constrainedIdsAtPositions") (EApp (EApp (EVar "methodSlotIdsAtPositions") (EVar "constrainedIds")) (EVar "constrainedSlots"))) (DoLet false false (PVar "constrainedArgumentIds") (EApp (EVar "methodSlotArgumentIds") (EVar "constrainedSlots"))) (DoLet false false (PVar "graph2") (EApp (EVar "freshSubRecordsOf") (EVar "graph1"))) (DoLet false false (PVar "rows2") (EApp (EApp (EVar "carryModuleCtx") (EVar "graph2")) (EVar "rows1"))) (DoLet false false (PVar "counterBefore") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "graph2") "graphRun") "tyvarCounter") "value")) (DoLet false false (PVar "firstRow") (EApp (EVar "firstMethodRow") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "rows2")) (EListLit (EVar "methodRowTestFoldMapDecl"))))) (DoLet false false (PVar "counterAfterFirst") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "graph2") "graphRun") "tyvarCounter") "value")) (DoLet false false (PVar "secondRow") (EApp (EVar "firstMethodRow") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "rows2")) (EListLit (EVar "methodRowTestFoldMapDecl"))))) (DoLet false false (PVar "counterAfterSecond") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "graph2") "graphRun") "tyvarCounter") "value")) (DoLet false false (PVar "firstSchemeIds") (EApp (EVar "schemeIds") (EFieldAccess (EVar "firstRow") "msrScheme"))) (DoLet false false (PVar "secondSchemeIds") (EApp (EVar "schemeIds") (EFieldAccess (EVar "secondRow") "msrScheme"))) (DoLet false false (PVar "firstRowSlotIds") (EApp (EVar "methodSlotBoundIds") (EFieldAccess (EVar "firstRow") "msrMethodSlots"))) (DoLet false false (PVar "secondRowSlotIds") (EApp (EVar "methodSlotBoundIds") (EFieldAccess (EVar "secondRow") "msrMethodSlots"))) (DoLet false false (PVar "registryAfterSecondSlotIds") (EApp (EApp (EVar "methodRowRegistrySlotIds") (EVar "rows2")) (EApp (EApp (EVar "methodSlotKey") (EFieldAccess (EVar "firstRow") "msrIface")) (ELit (LString "foldMap"))))) (DoLet false false (PVar "graph3") (EApp (EVar "freshSubRecordsOf") (EVar "graph1"))) (DoLet false false (PVar "rows3") (EApp (EApp (EVar "carryModuleCtx") (EVar "graph3")) (EVar "rows2"))) (DoLet false false (PVar "sameNameForward") (EApp (EVar "methodRowSameNameView") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "rows3")) (EListLit (EVar "methodRowTestSameA") (EVar "methodRowTestSameB"))))) (DoLet false false (PVar "graph4") (EApp (EVar "freshSubRecordsOf") (EVar "graph1"))) (DoLet false false (PVar "rows4") (EApp (EApp (EVar "carryModuleCtx") (EVar "graph4")) (EVar "rows3"))) (DoLet false false (PVar "sameNameReverse") (EApp (EVar "methodRowSameNameView") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "rows4")) (EListLit (EVar "methodRowTestSameB") (EVar "methodRowTestSameA"))))) (DoLet false false (PVar "graph5") (EApp (EVar "freshSubRecordsOf") (EVar "graph1"))) (DoLet false false (PVar "rows5") (EApp (EApp (EVar "carryModuleCtx") (EVar "graph5")) (EVar "rows4"))) (DoLet false false (PVar "constantRows") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "rows5")) (EListLit (EVar "methodRowTestConstantDecl")))) (DoLet false false (PVar "constantRow") (EApp (EVar "firstMethodRow") (EVar "constantRows"))) (DoLet false false (PVar "constantBodyIsFunction") (EMatch (EApp (EVar "normalize") (EApp (EVar "schemeBodyOf") (EFieldAccess (EVar "constantRow") "msrScheme"))) (arm (PCon "TFun" PWild PWild PWild) () (EVar "True")) (arm PWild () (EVar "False")))) (DoLet false false (PVar "graph6") (EApp (EVar "freshSubRecordsOf") (EVar "graph1"))) (DoLet false false (PVar "rows6") (EApp (EApp (EVar "carryModuleCtx") (EVar "graph6")) (EVar "rows5"))) (DoLet false false (PVar "attributed") (EApp (EApp (EVar "DAttrib") (EListLit)) (EVar "methodRowTestFoldMapDecl"))) (DoLet false false (PVar "attributedRows") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "rows6")) (EListLit (EVar "attributed")))) (DoLet false false (PVar "attributedMethods") (EApp (EApp (EApp (EVar "methodEnvGo") (EVar "graph6")) (EListLit (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "graph6")) (ELit (LInt 0))) (ELit (LString "foldable-test"))) (EListLit (EVar "attributed"))))) (EVar "emptyMethodEnv"))) (DoLet false false (PTuple (PVar "attributedParamIface") (PVar "attributedParamTyparams")) (EMatch (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (ELit (LString "foldMap"))) (EFieldAccess (EVar "attributedMethods") "meByName"))) (arm (PList) () (ETuple (ELit (LString "")) (EListLit))) (arm (PCons (PVar "r") PWild) () (EMatch (EFieldAccess (EVar "r") "mrEntry") (arm (PTuple (PVar "iface") (PVar "typarams") PWild PWild) () (ETuple (EFieldAccess (EVar "iface") "irName") (EVar "typarams"))))))) (DoLet false false (PVar "directNum") (EApp (EApp (EVar "methodRowTestNum") (ELit (LString "direct-num"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "String"))) (EVar "None"))) (EApp (EVar "TyVar") (ELit (LString "a")))))) (DoLet false false (PVar "attributedNum") (EApp (EApp (EVar "DAttrib") (EListLit)) (EApp (EApp (EVar "methodRowTestNum") (ELit (LString "attributed-num"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))) (EApp (EVar "TyVar") (ELit (LString "a"))))))) (DoLet false false (PVar "builtinNum") (EApp (EApp (EVar "methodRowTestNum") (ELit (LString "builtin-num"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))) (EApp (EVar "TyVar") (ELit (LString "a")))))) (DoLet false false (PVar "numAnchors") (EListLit (EApp (EApp (EApp (EApp (EVar "methodRowNumObservation") (EVar "rows6")) (ELit (LString "attrOnly"))) (EListLit (EVar "attributedNum"))) (EListLit (EVar "attributedNum"))) (EApp (EApp (EApp (EApp (EVar "methodRowNumObservation") (EVar "rows6")) (ELit (LString "directOnly"))) (EListLit (EVar "directNum"))) (EListLit (EVar "directNum"))) (EApp (EApp (EApp (EApp (EVar "methodRowNumObservation") (EVar "rows6")) (ELit (LString "attrThenDirect"))) (EListLit (EVar "attributedNum") (EVar "directNum"))) (EListLit (EVar "attributedNum") (EVar "directNum"))) (EApp (EApp (EApp (EApp (EVar "methodRowNumObservation") (EVar "rows6")) (ELit (LString "directThenAttr"))) (EListLit (EVar "directNum") (EVar "attributedNum"))) (EListLit (EVar "directNum") (EVar "attributedNum"))) (EApp (EApp (EApp (EApp (EVar "methodRowNumObservation") (EVar "rows6")) (ELit (LString "builtinThenUser"))) (EListLit (EVar "builtinNum"))) (EListLit (EVar "builtinNum") (EVar "methodRowTestUserFromInt"))) (EApp (EApp (EApp (EApp (EVar "methodRowNumObservation") (EVar "rows6")) (ELit (LString "userThenBuiltin"))) (EListLit (EVar "builtinNum"))) (EListLit (EVar "methodRowTestUserFromInt") (EVar "builtinNum"))))) (DoLet false false (PVar "observation") (ERecordCreate "MethodRowTestObservation" ((fa "mrtoSchemeIds" (EVar "constrainedIds")) (fa "mrtoSlotBoundIds" (EVar "constrainedBoundIds")) (fa "mrtoSlotPositions" (EVar "constrainedPositions")) (fa "mrtoSlotIdsAtPositions" (EVar "constrainedIdsAtPositions")) (fa "mrtoSlotArgumentIds" (EVar "constrainedArgumentIds")) (fa "mrtoCounterBefore" (EVar "counterBefore")) (fa "mrtoCounterAfterFirst" (EVar "counterAfterFirst")) (fa "mrtoCounterAfterSecond" (EVar "counterAfterSecond")) (fa "mrtoFirstSchemeIds" (EVar "firstSchemeIds")) (fa "mrtoSecondSchemeIds" (EVar "secondSchemeIds")) (fa "mrtoFirstRowSlotIds" (EVar "firstRowSlotIds")) (fa "mrtoSecondRowSlotIds" (EVar "secondRowSlotIds")) (fa "mrtoRegistryAfterSecondSlotIds" (EVar "registryAfterSecondSlotIds")) (fa "mrtoSameNameForward" (EVar "sameNameForward")) (fa "mrtoSameNameReverse" (EVar "sameNameReverse")) (fa "mrtoConstantRowCount" (EApp (EVar "listLen") (EVar "constantRows"))) (fa "mrtoConstantSchemeIdCount" (EApp (EVar "listLen") (EApp (EVar "schemeIds") (EFieldAccess (EVar "constantRow") "msrScheme")))) (fa "mrtoConstantBodyIsFunction" (EVar "constantBodyIsFunction")) (fa "mrtoConstantSlotCount" (EApp (EVar "listLen") (EFieldAccess (EVar "constantRow") "msrMethodSlots"))) (fa "mrtoAttributedRowCount" (EApp (EVar "listLen") (EVar "attributedRows"))) (fa "mrtoAttributedParamIface" (EVar "attributedParamIface")) (fa "mrtoAttributedParamTyparams" (EVar "attributedParamTyparams")) (fa "mrtoNumAnchors" (EVar "numAnchors"))))) (DoExpr (EVar "observation"))))
(DTypeSig false "methodRowSlotAllocationProbe" (TyFun (TyCon "Unit") (TyTuple (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "methodRowSlotAllocationProbe" (PWild) (EBlock (DoLet false false (PVar "observed") (EApp (EVar "observeMethodSchemeRowsForTest") (ELit LUnit))) (DoExpr (ETuple (EFieldAccess (EVar "observed") "mrtoSchemeIds") (EFieldAccess (EVar "observed") "mrtoSlotBoundIds") (EFieldAccess (EVar "observed") "mrtoSlotPositions") (EFieldAccess (EVar "observed") "mrtoSlotIdsAtPositions") (EFieldAccess (EVar "observed") "mrtoSlotArgumentIds")))))
(DTypeSig false "methodRowFreshnessProbe" (TyFun (TyCon "Unit") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))) (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "methodRowFreshnessProbe" (PWild) (EBlock (DoLet false false (PVar "observed") (EApp (EVar "observeMethodSchemeRowsForTest") (ELit LUnit))) (DoExpr (ETuple (ETuple (EFieldAccess (EVar "observed") "mrtoCounterBefore") (EFieldAccess (EVar "observed") "mrtoCounterAfterFirst") (EFieldAccess (EVar "observed") "mrtoCounterAfterSecond") (EFieldAccess (EVar "observed") "mrtoFirstSchemeIds") (EFieldAccess (EVar "observed") "mrtoSecondSchemeIds")) (ETuple (EFieldAccess (EVar "observed") "mrtoFirstRowSlotIds") (EFieldAccess (EVar "observed") "mrtoSecondRowSlotIds") (EFieldAccess (EVar "observed") "mrtoRegistryAfterSecondSlotIds"))))))
(DTypeSig false "methodRowDeclarationProbe" (TyFun (TyCon "Unit") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Int") (TyCon "Int"))) (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Bool") (TyCon "Int")))))
(DFunDef false "methodRowDeclarationProbe" (PWild) (EBlock (DoLet false false (PVar "observed") (EApp (EVar "observeMethodSchemeRowsForTest") (ELit LUnit))) (DoExpr (ETuple (EFieldAccess (EVar "observed") "mrtoSameNameForward") (EFieldAccess (EVar "observed") "mrtoSameNameReverse") (ETuple (EFieldAccess (EVar "observed") "mrtoConstantRowCount") (EFieldAccess (EVar "observed") "mrtoConstantSchemeIdCount") (EFieldAccess (EVar "observed") "mrtoConstantBodyIsFunction") (EFieldAccess (EVar "observed") "mrtoConstantSlotCount"))))))
(DTypeSig false "methodRowNumericAnchorProbe" (TyFun (TyCon "Unit") (TyTuple (TyCon "Int") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Bool") (TyCon "Bool") (TyCon "String") (TyCon "String"))))))
(DFunDef false "methodRowNumericAnchorProbe" (PWild) (EBlock (DoLet false false (PVar "observed") (EApp (EVar "observeMethodSchemeRowsForTest") (ELit LUnit))) (DoExpr (ETuple (EFieldAccess (EVar "observed") "mrtoAttributedRowCount") (EFieldAccess (EVar "observed") "mrtoAttributedParamIface") (EFieldAccess (EVar "observed") "mrtoAttributedParamTyparams") (EApp (EApp (EVar "map") (EVar "numAnchorObservationView")) (EFieldAccess (EVar "observed") "mrtoNumAnchors"))))))
(DTypeSig true "methodReturnProbeRequest" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodSchemeRow") (TyCon "MethodReturnRequest"))))
(DFunDef false "methodReturnProbeRequest" ((PVar "mctx") (PVar "row")) (EBlock (DoLet false false (PVar "inst") (EApp (EApp (EVar "methodReturnProbeOccurrence") (EVar "mctx")) (EVar "row"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "methodReturnRequest") (EVar "mctx")) (EVar "row")) (EFieldAccess (EVar "inst") "mtiBody")) (EFieldAccess (EVar "inst") "mtiSubstitution")) (EApp (EVar "Some") (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit)))))))
(DTypeSig false "methodReturnVectorCompletenessProbe" (TyFun (TyCon "Unit") (TyTuple (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Bool") (TyCon "Bool"))))
(DFunDef false "methodReturnVectorCompletenessProbe" (PWild) (EBlock (DoLet false false (PVar "gctx") (EApp (EVar "probeGraphCtx") (ELit LUnit))) (DoLet false false (PVar "mctx") (EApp (EVar "initialModuleCtx") (EVar "gctx"))) (DoLet false false PWild (EApp (EApp (EVar "methodReturnProbeScope") (EVar "mctx")) (ELit (LString "return-vector")))) (DoLet false false (PVar "zeroRow") (EApp (EVar "firstMethodRow") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "mctx")) (EListLit (EApp (EApp (EApp (EApp (EVar "methodRowTestIface") (ELit (LString "return-zero"))) (ELit (LString "Zero"))) (EListLit)) (EListLit (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (ELit (LString "make"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Unit"))) (EVar "None"))) (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None")))) (EVar "None")) (EVar "None")))))))) (DoLet false false (PVar "partialRow") (EApp (EVar "firstMethodRow") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "mctx")) (EListLit (EApp (EApp (EApp (EApp (EVar "methodRowTestIface") (ELit (LString "return-partial"))) (ELit (LString "Partial"))) (EListLit (ELit (LString "a")) (ELit (LString "b")))) (EListLit (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (ELit (LString "make"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Unit"))) (EVar "None"))) (EApp (EVar "TyVar") (ELit (LString "a"))))) (EVar "None")) (EVar "None")))))))) (DoLet false false (PVar "zeroArgs") (EApp (EApp (EVar "map") (EApp (EVar "map") (EVar "ppMono"))) (EApp (EApp (EVar "methodReturnArgs") (EVar "gctx")) (EApp (EApp (EVar "methodReturnProbeRequest") (EVar "mctx")) (EVar "zeroRow"))))) (DoLet false false (PVar "partialArgs") (EApp (EApp (EVar "map") (EApp (EVar "map") (EVar "ppMono"))) (EApp (EApp (EVar "methodReturnArgs") (EVar "gctx")) (EApp (EApp (EVar "methodReturnProbeRequest") (EVar "mctx")) (EVar "partialRow"))))) (DoLet false false (PVar "observed") (ETuple (EVar "zeroArgs") (EVar "partialArgs") (EApp (EApp (EVar "allMethodParamsMentioned") (EFieldAccess (EVar "zeroRow") "msrTyparams")) (EFieldAccess (EVar "zeroRow") "msrType")) (EApp (EApp (EVar "allMethodParamsMentioned") (EFieldAccess (EVar "partialRow") "msrTyparams")) (EFieldAccess (EVar "partialRow") "msrType")))) (DoExpr (EVar "observed"))))
(DTypeSig true "methodReturnTemplatePresenceProbe" (TyFun (TyCon "Unit") (TyTuple (TyApp (TyCon "List") (TyCon "Bool")) (TyApp (TyCon "List") (TyCon "Bool")))))
(DFunDef false "methodReturnTemplatePresenceProbe" (PWild) (EBlock (DoLet false false (PVar "gctx") (EApp (EVar "probeGraphCtx") (ELit LUnit))) (DoLet false false (PVar "mctx") (EApp (EVar "initialModuleCtx") (EVar "gctx"))) (DoLet false false (PVar "present") (EApp (EVar "firstMethodRow") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "mctx")) (EListLit (EApp (EApp (EApp (EApp (EVar "methodRowTestIface") (ELit (LString "return-template-present"))) (ELit (LString "Present"))) (EListLit (ELit (LString "a")) (ELit (LString "b")))) (EListLit (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (ELit (LString "make"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Unit"))) (EVar "None"))) (EApp (EVar "TyTuple") (EListLit (EApp (EVar "TyVar") (ELit (LString "a"))) (EApp (EVar "TyVar") (ELit (LString "b"))))))) (EVar "None")) (EVar "None")))))))) (DoLet false false (PVar "absent") (EApp (EVar "firstMethodRow") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "mctx")) (EListLit (EApp (EApp (EApp (EApp (EVar "methodRowTestIface") (ELit (LString "return-template-absent"))) (ELit (LString "Absent"))) (EListLit (ELit (LString "a")) (ELit (LString "b")))) (EListLit (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (ELit (LString "make"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Unit"))) (EVar "None"))) (EApp (EVar "TyVar") (ELit (LString "a"))))) (EVar "None")) (EVar "None")))))))) (DoLet false false (PVar "observed") (ETuple (EApp (EApp (EVar "map") (EVar "isSome")) (EFieldAccess (EFieldAccess (EVar "present") "msrPredicateTemplate") "mptArguments")) (EApp (EApp (EVar "map") (EVar "isSome")) (EFieldAccess (EFieldAccess (EVar "absent") "msrPredicateTemplate") "mptArguments")))) (DoExpr (EVar "observed"))))
(DTypeSig true "methodReturnProbeCodes" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodSchemeRow") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "ModuleCtx"))))))
(DFunDef false "methodReturnProbeCodes" ((PVar "prev") (PVar "ownedRow") (PVar "impls")) (EBlock (DoLet false false (PVar "gctx") (EVariantUpdate "GraphCtx" (EFieldAccess (EVar "prev") "mcGraph") ((fa "graphRun" (EApp (EVar "freshGraphRun") (ELit LUnit)))))) (DoLet false false (PVar "mctx") (EApp (EApp (EVar "carryModuleCtx") (EVar "gctx")) (EVar "prev"))) (DoLet false false PWild (EApp (EApp (EVar "methodReturnProbeScope") (EVar "mctx")) (ELit (LString "return-owner-checker")))) (DoLet false false (PVar "foreignRow") (EApp (EVar "firstMethodRow") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "mctx")) (EListLit (EApp (EApp (EApp (EVar "methodReturnProbeIface") (ELit (LString "return-foreign"))) (ELit (LString "Foreign"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Unit"))) (EVar "None"))) (EApp (EVar "TyVar") (ELit (LString "a"))))))))) (DoLet false false (PVar "request") (EApp (EApp (EVar "methodReturnProbeRequest") (EVar "mctx")) (EVar "ownedRow"))) (DoExpr (EApp (EApp (EVar "methodReturnProbeSpelling") (EVar "mctx")) (EVar "foreignRow"))) (DoLet false false PWild (EApp (EApp (EVar "recordExactMethodObligation") (EVar "mctx")) (EVar "request"))) (DoLet false false (PVar "universe") (EApp (EVar "buildImplUniverse") (EVar "impls"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "bodyImplEnvRef")) (EApp (EVar "buildFlatImplEnv") (EVar "impls")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkCallObligationsU") (EVar "mctx")) (EVar "True")) (EVar "universe")) (EApp (EVar "wAll") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "implObls")))) (DoExpr (ETuple (EApp (EApp (EVar "map") (EVar "tcCode")) (EApp (EVar "reverseL") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrors") "items") "value"))) (EVar "mctx")))))
(DTypeSig true "methodReturnResolutionMutationProbe" (TyFun (TyCon "Unit") (TyTuple (TyCon "Bool") (TyCon "Bool") (TyCon "Bool") (TyCon "Bool"))))
(DFunDef false "methodReturnResolutionMutationProbe" (PWild) (EBlock (DoLet false false (PVar "gctx") (EApp (EVar "probeGraphCtx") (ELit LUnit))) (DoLet false false (PVar "mctx") (EApp (EVar "initialModuleCtx") (EVar "gctx"))) (DoLet false false PWild (EApp (EApp (EVar "methodReturnProbeScope") (EVar "mctx")) (ELit (LString "return-outcome-validation")))) (DoLet false false (PVar "ownedDecl") (EApp (EApp (EApp (EVar "methodReturnProbeIface") (ELit (LString "return-owner"))) (ELit (LString "Owner"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Unit"))) (EVar "None"))) (EApp (EVar "TyVar") (ELit (LString "a")))))) (DoLet false false (PVar "ownedRow") (EApp (EVar "firstMethodRow") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "mctx")) (EListLit (EVar "ownedDecl"))))) (DoLet false false (PVar "ownedImpl") (EApp (EApp (EVar "methodReturnProbeImpl") (ELit (LString "return-owner"))) (ELit (LString "Owner")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "bodyImplEnvRef")) (EApp (EVar "buildFlatImplEnv") (EListLit (EVar "ownedImpl"))))) (DoLet false false (PVar "request") (EApp (EApp (EVar "methodReturnProbeRequest") (EVar "mctx")) (EVar "ownedRow"))) (DoLet false false (PVar "resolution") (EApp (EApp (EVar "solveExactReturnOnce") (EApp (EVar "siteFor") (EVar "mctx"))) (EVar "request"))) (DoLet false false (PVar "valid") (EApp (EApp (EApp (EVar "methodReturnResolutionValid") (EVar "mctx")) (EVar "request")) (EVar "resolution"))) (DoLet false false (PTuple (PVar "wrongSelection") (PVar "wrongPrerequisites")) (EMatch (EFieldAccess (EVar "resolution") "mrrOutcome") (arm (PCon "Solved" (PCon "InstanceEvidence" PWild (PVar "args") (PVar "prerequisites") (PVar "supers"))) () (ETuple (ERecordCreate "MethodReturnResolution" ((fa "mrrWanted" (EFieldAccess (EVar "resolution") "mrrWanted")) (fa "mrrOutcome" (EApp (EVar "Solved") (EApp (EApp (EApp (EApp (EVar "InstanceEvidence") (EApp (EVar "RequestInstanceId") (EUnOp "-" (ELit (LInt 1))))) (EVar "args")) (EVar "prerequisites")) (EVar "supers")))) (fa "mrrSelectedRow" (EFieldAccess (EVar "resolution") "mrrSelectedRow")))) (ERecordCreate "MethodReturnResolution" ((fa "mrrWanted" (EFieldAccess (EVar "resolution") "mrrWanted")) (fa "mrrOutcome" (EApp (EVar "Solved") (EApp (EApp (EApp (EApp (EVar "InstanceEvidence") (EApp (EVar "RequestInstanceId") (EApp (EVar "methodReturnSelectedIdentity") (EVar "resolution")))) (EVar "args")) (EBinOp "::" (ERecordCreate "PrerequisiteEvidence" ((fa "prerequisiteInterface" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "resolution") "mrrWanted") "predicate") "predicateInterface")) (fa "prerequisiteArguments" (EVar "args")))) (EVar "prerequisites"))) (EVar "supers")))) (fa "mrrSelectedRow" (EFieldAccess (EVar "resolution") "mrrSelectedRow")))))) (arm PWild () (EApp (EVar "panic") (ELit (LString "ordinary return mutation probe expected instance evidence")))))) (DoLet false false (PVar "wanted") (EFieldAccess (EVar "resolution") "mrrWanted")) (DoLet false false (PVar "wrongWanted") (ERecordCreate "Wanted" ((fa "id" (EFieldAccess (EVar "wanted") "id")) (fa "predicate" (EFieldAccess (EVar "wanted") "predicate")) (fa "origin" (EFieldAccess (EVar "wanted") "origin")) (fa "scope" (EApp (EVar "ScopeId") (ELit (LInt 999999)))) (fa "destination" (EFieldAccess (EVar "wanted") "destination"))))) (DoLet false false (PVar "disagreement") (ERecordCreate "MethodReturnResolution" ((fa "mrrWanted" (EVar "wrongWanted")) (fa "mrrOutcome" (EFieldAccess (EVar "resolution") "mrrOutcome")) (fa "mrrSelectedRow" (EFieldAccess (EVar "resolution") "mrrSelectedRow"))))) (DoLet false false (PVar "observed") (ETuple (EVar "valid") (EApp (EVar "not") (EApp (EApp (EApp (EVar "methodReturnResolutionValid") (EVar "mctx")) (EVar "request")) (EVar "wrongSelection"))) (EApp (EVar "not") (EApp (EApp (EApp (EVar "methodReturnResolutionValid") (EVar "mctx")) (EVar "request")) (EVar "wrongPrerequisites"))) (EApp (EVar "not") (EApp (EApp (EApp (EVar "methodReturnResolutionValid") (EVar "mctx")) (EVar "request")) (EVar "disagreement"))))) (DoExpr (EVar "observed"))))
(DTypeSig false "methodReturnProbeSlotCase" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodSchemeRow") (TyFun (TyCon "MethodSchemeRow") (TyFun (TyCon "Bool") (TyTuple (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyCon "ModuleCtx")))))))
(DFunDef false "methodReturnProbeSlotCase" ((PVar "prev") (PVar "ownedRow") (PVar "foreignRow") (PVar "retainOwner")) (EBlock (DoLet false false (PVar "gctx") (EVariantUpdate "GraphCtx" (EFieldAccess (EVar "prev") "mcGraph") ((fa "graphRun" (EApp (EVar "freshGraphRun") (ELit LUnit)))))) (DoLet false false (PVar "mctx") (EApp (EApp (EVar "carryModuleCtx") (EVar "gctx")) (EVar "prev"))) (DoLet false false PWild (EApp (EApp (EVar "methodReturnProbeScope") (EVar "mctx")) (ELit (LString "return-owner-slots")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodPredicateSlotsRef")) (EListLit (ETuple (EApp (EApp (EVar "methodSlotKey") (EFieldAccess (EVar "foreignRow") "msrIface")) (ELit (LString "make"))) (EFieldAccess (EVar "foreignRow") "msrMethodSlots"))))) (DoExpr (EApp (EApp (EVar "methodReturnProbeSpelling") (EVar "mctx")) (EVar "foreignRow"))) (DoLet false false (PVar "env") (EIf (EVar "retainOwner") (EApp (EApp (EApp (EVar "extendMethodRow") (EApp (EVar "envFor") (EVar "mctx"))) (ELit (LString "make"))) (EVar "ownedRow")) (EApp (EApp (EApp (EVar "extendVar") (EApp (EVar "envFor") (EVar "mctx"))) (ELit (LString "make"))) (EFieldAccess (EVar "ownedRow") "msrScheme")))) (DoLet false false (PVar "inst") (EApp (EApp (EVar "instantiateMethodTracked") (EVar "mctx")) (EFieldAccess (EVar "ownedRow") "msrScheme"))) (DoExpr (EApp (EApp (EApp (EVar "unify") (EVar "mctx")) (EApp (EVar "stripArrows") (EFieldAccess (EVar "inst") "mtiBody"))) (EApp (EVar "tupleMono") (EListLit (EApp (EVar "tconBuiltin") (ELit (LString "Int"))) (EApp (EVar "tconBuiltin") (ELit (LString "Int"))))))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordSite") (EVar "env")) (ELit (LString "make"))) (EFieldAccess (EVar "ownedRow") "msrScheme")) (EApp (EVar "Ref") (ELit (LString "")))) (EApp (EVar "Ref") (EVar "RNone"))) (EApp (EVar "Ref") (EListLit))) (EApp (EVar "Ref") (EListLit))) (EApp (EVar "Ref") (EVar "innerNone"))) (EFieldAccess (EVar "inst") "mtiBody")) (EFieldAccess (EVar "inst") "mtiSubstitution"))) (DoExpr (ETuple (ETuple (EApp (EVar "methodReturnProbeOblIfaces") (EApp (EVar "wAll") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "obls"))) (EApp (EVar "methodReturnProbeGoalIfaces") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "goals") "value"))) (EVar "mctx")))))
(DTypeSig false "methodReturnSlotOwnershipProbe" (TyFun (TyCon "Unit") (TyTuple (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "methodReturnSlotOwnershipProbe" (PWild) (EBlock (DoLet false false (PVar "ownedGraph") (EApp (EVar "probeGraphCtx") (ELit LUnit))) (DoLet false false (PVar "ownedCtx") (EApp (EVar "initialModuleCtx") (EVar "ownedGraph"))) (DoLet false false (PVar "ownedRow") (EApp (EVar "firstMethodRow") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "ownedCtx")) (EListLit (EApp (EApp (EApp (EVar "methodReturnProbeIface") (ELit (LString "return-owner-slots"))) (ELit (LString "OwnedSlots"))) (EApp (EApp (EVar "TyConstrained") (EListLit (EApp (EApp (EApp (EVar "methodRowTestConstraint") (ELit (LString "return-seed"))) (ELit (LString "Seed"))) (EListLit (EApp (EVar "TyVar") (ELit (LString "b"))))))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Unit"))) (EVar "None"))) (EApp (EVar "TyTuple") (EListLit (EApp (EVar "TyVar") (ELit (LString "b"))) (EApp (EVar "TyVar") (ELit (LString "a")))))))))))) (DoLet false false (PVar "emptyGraph") (EVariantUpdate "GraphCtx" (EVar "ownedGraph") ((fa "graphRun" (EApp (EVar "freshGraphRun") (ELit LUnit)))))) (DoLet false false (PVar "emptyCtx") (EApp (EApp (EVar "carryModuleCtx") (EVar "emptyGraph")) (EVar "ownedCtx"))) (DoLet false false (PVar "emptyRow") (EApp (EVar "firstMethodRow") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "emptyCtx")) (EListLit (EApp (EApp (EApp (EVar "methodReturnProbeIface") (ELit (LString "return-empty-slots"))) (ELit (LString "EmptySlots"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Unit"))) (EVar "None"))) (EApp (EVar "TyVar") (ELit (LString "a"))))))))) (DoLet false false (PVar "foreignGraph") (EVariantUpdate "GraphCtx" (EVar "ownedGraph") ((fa "graphRun" (EApp (EVar "freshGraphRun") (ELit LUnit)))))) (DoLet false false (PVar "foreignCtx") (EApp (EApp (EVar "carryModuleCtx") (EVar "foreignGraph")) (EVar "emptyCtx"))) (DoLet false false (PVar "foreignRow") (EApp (EVar "firstMethodRow") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "foreignCtx")) (EListLit (EApp (EApp (EApp (EVar "methodReturnProbeIface") (ELit (LString "return-foreign-slots"))) (ELit (LString "ForeignSlots"))) (EApp (EApp (EVar "TyConstrained") (EListLit (EApp (EApp (EApp (EVar "methodRowTestConstraint") (ELit (LString "return-decoy"))) (ELit (LString "Decoy"))) (EListLit (EApp (EVar "TyVar") (ELit (LString "b"))))))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Unit"))) (EVar "None"))) (EApp (EVar "TyTuple") (EListLit (EApp (EVar "TyVar") (ELit (LString "b"))) (EApp (EVar "TyVar") (ELit (LString "a")))))))))))) (DoLet false false (PTuple (PVar "retained") (PVar "retainedCtx")) (EApp (EApp (EApp (EApp (EVar "methodReturnProbeSlotCase") (EVar "foreignCtx")) (EVar "ownedRow")) (EVar "foreignRow")) (EVar "True"))) (DoLet false false (PTuple (PVar "emptied") (PVar "emptiedCtx")) (EApp (EApp (EApp (EApp (EVar "methodReturnProbeSlotCase") (EVar "retainedCtx")) (EVar "emptyRow")) (EVar "foreignRow")) (EVar "True"))) (DoLet false false (PTuple (PVar "missing") PWild) (EApp (EApp (EApp (EApp (EVar "methodReturnProbeSlotCase") (EVar "emptiedCtx")) (EVar "ownedRow")) (EVar "foreignRow")) (EVar "False"))) (DoLet false false (PVar "observed") (ETuple (EVar "retained") (EVar "emptied") (EVar "missing"))) (DoExpr (EVar "observed"))))
# MARK
(DUse false (UseGroup ("types" "tc_types") ((mem "SiteKind" true) (mem "OblProjection" true) (mem "NumericPredicateTraceStage" true) (mem "MethodReturnTraceStage" true) (mem "GoalPayload" true) (mem "EvDest" true) (mem "BuiltinClass" true) (mem "EvCell" true) (mem "GoalKind" true) (mem "GraphCtx" true) (mem "MarkSets" true) (mem "MethodPredicateTemplate" true) (mem "MethodReturnRequest" true) (mem "MethodReturnResolution" true) (mem "MethodRowTestObservation" true) (mem "Obligation" true) (mem "PendingDictApp" true) (mem "PendingMethodDict" true) (mem "Predicate" true) (mem "PredicateSlot" true) (mem "PredicateSlotArgs" true) (mem "Provenance" true) (mem "SelectedValueOccurrence" true) (mem "SiteCell" true) (mem "UObligation" true) (mem "ArgRw" false) (mem "CDeclared" false) (mem "CSlot" false) (mem "MarkCtx" false) (mem "MethodInstantiationSubst" false) (mem "MethodPredicateSlot" false) (mem "MethodSchemeRow" false) (mem "MethodTrackedInstantiation" false) (mem "ModuleCtx" false) (mem "ModuleMarking" false) (mem "PendingEntry" false) (mem "PreludeMarkFacts" false) (mem "RecDictApp" false) (mem "ScopedMember" false) (mem "ShadowDicts" false) (mem "siteFor" false) (mem "TcEnv" false) (mem "ValueScheme" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "allMethodParamsMentioned" false) (mem "argMentions" false) (mem "funArity" false) (mem "isBareTyvarMono" false) (mem "isMonoScheme" false) (mem "matchTyMono" false) (mem "nthFunDomain" false) (mem "patVarsListTc" false) (mem "patVarsTc" false) (mem "propParamNamesTc" false) (mem "rootIdOf" false) (mem "sameRootId" false) (mem "schemeBodyOf" false) (mem "schemeIds" false) (mem "stripArrows" false) (mem "stripTyConstraints" false) (mem "substMono" false) (mem "tconBuiltin" false) (mem "tconUnresolved" false) (mem "tupleMono" false) (mem "tyVarNames" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "carryModuleCtx" false) (mem "currentScopeStore" false) (mem "emptyMethodEnv" false) (mem "envAt" false) (mem "freshGraphRun" false) (mem "freshSubRecordsOf" false) (mem "initialModuleCtx" false) (mem "probeGraphCtx" false) (mem "wAll" false) (mem "wPush" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "bindingDeclared" false) (mem "buildFlatImplEnv" false) (mem "buildImplUniverse" false) (mem "builtinIfaceRef" false) (mem "declEnvModule" false) (mem "dispatchTyparams" false) (mem "envFor" false) (mem "extendMethodRow" false) (mem "extendVar" false) (mem "hasImportDefiner" false) (mem "lookupLocalFlag" false) (mem "lookupMethodRow" false) (mem "lookupVar" false) (mem "methodArgs" false) (mem "methodEnvGo" false) (mem "methodRowSameNameView" false) (mem "methodRowTestConstantDecl" false) (mem "methodRowTestConstraint" false) (mem "methodRowTestFoldMapDecl" false) (mem "methodRowTestIface" false) (mem "methodRowTestNum" false) (mem "methodRowTestSameA" false) (mem "methodRowTestSameB" false) (mem "methodRowTestUserFromInt" false) (mem "methodSlotKey" false) (mem "originMethodName" false) (mem "standaloneValueFor" false))))
(DUse false (UseGroup ("types" "tc_scope") ((mem "admittedIfaceWord" false) (mem "aliasDictNames" false) (mem "argDispatchOf" false) (mem "methodAdmittedHere" false) (mem "methodDispatchIdx" false) (mem "methodEntryHere" false) (mem "methodIfaceHere" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "captureScope" false) (mem "declaredCrossModuleObls" false) (mem "forceInstantiation" false) (mem "freshVar" false) (mem "instantiateLegacyVarTracked" false) (mem "instantiateMethodTracked" false) (mem "instantiateTracked" false) (mem "instantiateValueTracked" false) (mem "lookupQualPayload" false) (mem "lookupSchemeObls" false) (mem "openRow" false) (mem "qualConstraintDecl" false) (mem "qualConstraintKey" false) (mem "recordObl" false) (mem "recordOblAt" false) (mem "recordSchemeCallObligations" false) (mem "unify" false) (mem "unifyIn" false) (mem "zipSlotVecs" false))))
(DUse false (UseGroup ("types" "tc_decls_types") ((mem "fromAstType" false))))
(DUse false (UseGroup ("types" "tc_decls") ((mem "constraintIface" false) (mem "constraintIsMethodLevel" false) (mem "constraintVarNames" false) (mem "ifaceMethodSchemeRows" false) (mem "methodRowNumObservation" false))))
(DUse false (UseGroup ("types" "tc_solve_givens") ((mem "predicateSlotIds" false) (mem "predicateSlotIdsAt" false))))
(DUse false (UseGroup ("types" "tc_solve_entail") ((mem "noteNumericPredicateTrace" false))))
(DUse false (UseGroup ("types" "tc_solve") ((mem "builtinClassPresent" false) (mem "consSiteFn" false) (mem "goalKindName" false) (mem "isLocalAbsName" false) (mem "localSourceName" false) (mem "methodPredicateTemplateHasAbsent" false) (mem "methodReturnArgs" false) (mem "methodReturnProbeGoalIfaces" false) (mem "methodReturnProbeIface" false) (mem "methodReturnProbeImpl" false) (mem "methodReturnProbeOblIfaces" false) (mem "methodReturnProbeOccurrence" false) (mem "methodReturnProbeScope" false) (mem "methodReturnProbeSpelling" false) (mem "methodReturnResolutionValid" false) (mem "methodReturnSelectedIdentity" false) (mem "methodRowRegistrySlotIds" false) (mem "methodSlotArgumentIds" false) (mem "methodSlotBoundIds" false) (mem "methodSlotIdsAtPositions" false) (mem "methodSlotPositions" false) (mem "noteMethodReturnTrace" false) (mem "numAnchorObservationView" false) (mem "pushDictApp" false) (mem "pushGoal" false) (mem "returnPosMethodNames" false) (mem "routeLocalSym" false) (mem "solveExactReturnOnce" false))))
(DUse false (UseGroup ("types" "tc_solve_check") ((mem "checkCallObligationsU" false) (mem "dedupSlotVecs" false) (mem "dispatchMonosOf" false))))
(DUse false (UseGroup ("types" "tc_shadow") ((mem "buildStandaloneShadowsGraph" false) (mem "callArgVecsV" false) (mem "computeMangledShadowMap" false) (mem "constraintMonosOf" false) (mem "coreShadowMapFor" false) (mem "declaredConstraintFor" false) (mem "declaredEffectsAt" false) (mem "isDefinerShadow" false) (mem "isShadowStandalone" false) (mem "methodCellLookup" false) (mem "rejectAdmittedValueOccurrence" false) (mem "shadowDeclaredFor" false) (mem "shadowStandaloneDictSlots" false) (mem "shadowStandaloneDictSlotsAt" false) (mem "standaloneValueBinding" false) (mem "standaloneValueBindingEmit" false) (mem "standaloneValuePinned" false))))
(DUse false (UseGroup ("types" "tc_effects") ((mem "clausesOf" false) (mem "evOrdinal" false) (mem "grantNameIn" false) (mem "recordMethodGrantOcc" false) (mem "recordStandaloneGrantOcc" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Section" true) (mem "Arm" true) (mem "Constraint" true) (mem "Decl" true) (mem "DoStmt" true) (mem "EvId" true) (mem "Expr" true) (mem "FieldAssign" true) (mem "FunClause" true) (mem "Guard" true) (mem "GuardArm" true) (mem "IfaceMethod" true) (mem "ImplMethod" true) (mem "InterpPart" true) (mem "LetBind" true) (mem "Loc" true) (mem "MethodDefault" true) (mem "Pat" true) (mem "Route" true) (mem "Ty" true) (mem "isUnminted" false) (mem "negateLiteral" false) (mem "tyConBuiltin" false))))
(DUse false (UseGroup ("types" "solver_contract") ((mem "SolverOutcome" true) (mem "ClassPredicate" true) (mem "Wanted" true))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Mono" true) (mem "Scheme" true) (mem "lookupAssocI" false) (mem "normalize" false) (mem "ppMono" false))))
(DUse false (UseGroup ("types" "evidence_complete") ((mem "Inner" true) (mem "innerNone" false))))
(DUse false (UseGroup ("types" "evidence") ((mem "SolverEvidence" true) (mem "PrerequisiteEvidence" true) (mem "RequestInstanceId" true) (mem "ScopeId" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "anyList" false) (mem "contains" false) (mem "dedup" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "isSome" false) (mem "listLen" false) (mem "lookupAssoc" false) (mem "reverseL" false))))
(DUse false (UseGroup ("types" "chain_key") ((mem "constrainedSigName" false))))
(DUse false (UseGroup ("list") ((mem "get" false) (mem "reverse" false))))
(DUse false (UseGroup ("support" "char") ((mem "isUpper" false))))
(DUse false (UseGroup ("types" "publish") ((mem "tcCode" false))))
(DUse false (UseAlias ("map") "IdMap"))
(DUse false (UseAlias ("types" "scopes") "Scopes"))
(DTypeSig false "siteObligation" (TyFun (TyCon "GoalKind") (TyFun (TyApp (TyCon "Ref") (TyCon "Inner")) (TyFun (TyCon "PendingEntry") (TyCon "Obligation")))))
(DFunDef false "siteObligation" ((PVar "k") (PVar "inner") (PCon "PendingEntry" (PVar "name") (PVar "tagRef") (PVar "m") (PVar "encl") (PVar "site") (PVar "loc") (PVar "scope") (PVar "ev"))) (ERecordCreate "Obligation" ((fa "oKind" (EVar "k")) (fa "oDest" (EApp (EVar "EvRoute") (EVar "tagRef"))) (fa "oEv" (EVar "ev")) (fa "oEncl" (EVar "encl")) (fa "oLoc" (EVar "loc")) (fa "oScope" (EVar "scope")) (fa "oPayload" (EApp (EApp (EApp (EVar "GPSite") (EVar "name")) (EVar "m")) (EVar "site"))) (fa "oInner" (EVar "inner")))))
(DTypeSig true "pushSiteGoal" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "GoalKind") (TyFun (TyApp (TyCon "Ref") (TyCon "Inner")) (TyFun (TyCon "PendingEntry") (TyCon "Unit"))))))
(DFunDef false "pushSiteGoal" ((PVar "gctx") (PVar "k") (PVar "inner") (PVar "e")) (EApp (EApp (EVar "pushGoal") (EVar "gctx")) (EApp (EApp (EApp (EVar "siteObligation") (EVar "k")) (EVar "inner")) (EVar "e"))))
(DTypeSig false "pushArithGoal" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyCon "Mono") (TyFun (TyCon "EvId") (TyCon "Unit"))))))
(DFunDef false "pushArithGoal" ((PVar "mctx") (PVar "dref") (PVar "m") (PVar "ev")) (EApp (EApp (EVar "pushGoal") (EFieldAccess (EVar "mctx") "mcGraph")) (ERecordCreate "Obligation" ((fa "oKind" (EVar "GKArithSite")) (fa "oDest" (EApp (EVar "EvRoute") (EVar "dref"))) (fa "oEv" (EVar "ev")) (fa "oEncl" (ELit (LString ""))) (fa "oLoc" (EVar "None")) (fa "oScope" (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) (fa "oPayload" (EApp (EVar "GPArith") (EVar "m"))) (fa "oInner" (EApp (EVar "Ref") (EVar "innerNone")))))))
(DTypeSig false "pushMethodDictGoal" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PendingMethodDict") (TyCon "Unit"))))
(DFunDef false "pushMethodDictGoal" ((PVar "gctx") (PVar "pmd")) (EApp (EApp (EVar "pushGoal") (EVar "gctx")) (ERecordCreate "Obligation" ((fa "oKind" (EVar "GKMethodDict")) (fa "oDest" (EApp (EVar "EvRoutes") (EFieldAccess (EVar "pmd") "pmdRoutesRef"))) (fa "oEv" (EFieldAccess (EVar "pmd") "pmdEv")) (fa "oEncl" (EFieldAccess (EVar "pmd") "pmdEncl")) (fa "oLoc" (EVar "None")) (fa "oScope" (EFieldAccess (EVar "pmd") "pmdScope")) (fa "oPayload" (EApp (EVar "GPMethodDict") (EVar "pmd"))) (fa "oInner" (EFieldAccess (EVar "pmd") "pmdInner"))))))
(DTypeSig false "pushRecDictAppGoal" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "RecDictApp") (TyCon "Unit"))))
(DFunDef false "pushRecDictAppGoal" ((PVar "gctx") (PAs "r" (PCon "RecDictApp" (PVar "routesRef") PWild (PVar "encl") PWild (PVar "scope") (PVar "ev")))) (EApp (EApp (EVar "pushGoal") (EVar "gctx")) (ERecordCreate "Obligation" ((fa "oKind" (EVar "GKRecDictApp")) (fa "oDest" (EApp (EVar "EvRoutes") (EVar "routesRef"))) (fa "oEv" (EVar "ev")) (fa "oEncl" (EVar "encl")) (fa "oLoc" (EVar "None")) (fa "oScope" (EVar "scope")) (fa "oPayload" (EApp (EVar "GPRecDictApp") (EVar "r"))) (fa "oInner" (EApp (EVar "Ref") (EVar "innerNone")))))))
(DTypeSig false "pushPendingObl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Provenance") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit"))))))))))
(DFunDef false "pushPendingObl" ((PVar "mctx") (PVar "iface") (PVar "typarams") (PVar "mty") (PVar "occ") (PVar "omitted") (PVar "prov") (PVar "loc")) (EApp (EApp (EVar "wPush") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "implObls")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkMethodOccObl") (EVar "iface")) (EVar "typarams")) (EVar "mty")) (EVar "occ")) (EVar "omitted")) (EVar "prov")) (EVar "loc")) (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit)))))
(DTypeSig false "pushExactReturnObl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodReturnRequest") (TyCon "Unit"))))
(DFunDef false "pushExactReturnObl" ((PVar "mctx") (PVar "request")) (EApp (EApp (EVar "wPush") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "implObls")) (ERecordCreate "UObligation" ((fa "pred" (ERecordCreate "Predicate" ((fa "iface" (EFieldAccess (EVar "request") "mrrIface")) (fa "args" (EListLit))))) (fa "originId" (ELit (LInt 0))) (fa "prov" (EVar "PMethodOcc")) (fa "loc" (EFieldAccess (EVar "request") "mrrLoc")) (fa "uoScope" (EFieldAccess (EVar "request") "mrrScope")) (fa "oblProj" (EApp (EVar "OpExactReturn") (EVar "request")))))))
(DTypeSig false "methodReturnRequest" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodSchemeRow") (TyFun (TyCon "Mono") (TyFun (TyCon "MethodInstantiationSubst") (TyFun (TyApp (TyCon "Option") (TyCon "EvId")) (TyCon "MethodReturnRequest")))))))
(DFunDef false "methodReturnRequest" ((PVar "mctx") (PVar "row") (PVar "occurrence") (PVar "subst") (PVar "goalEv")) (EBlock (DoLet false false (PVar "loc") (EFieldAccess (EVar "mctx") "mcLoc")) (DoLet false false (PVar "scope") (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) (DoLet false false (PVar "qualifiedBody") (EMatch (EFieldAccess (EVar "row") "msrScheme") (arm (PCon "Forall" PWild PWild PWild PWild PWild (PVar "body")) () (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EFieldAccess (EVar "mctx") "mcGraph")) (EFieldAccess (EVar "subst") "misTypeSubst")) (EFieldAccess (EVar "subst") "misEffectSubst")) (EFieldAccess (EVar "subst") "misAuthSubst")) (EVar "body"))))) (DoLet false false (PVar "omitted") (EIf (EApp (EVar "methodPredicateTemplateHasAbsent") (EFieldAccess (EVar "row") "msrPredicateTemplate")) (EApp (EApp (EApp (EVar "omittedParamVars") (EVar "mctx")) (EFieldAccess (EVar "row") "msrTyparams")) (EFieldAccess (EVar "row") "msrType")) (EListLit))) (DoExpr (ERecordCreate "MethodReturnRequest" ((fa "mrrIface" (EFieldAccess (EVar "row") "msrIface")) (fa "mrrName" (EFieldAccess (EVar "row") "msrName")) (fa "mrrTyparams" (EFieldAccess (EVar "row") "msrTyparams")) (fa "mrrType" (EFieldAccess (EVar "row") "msrType")) (fa "mrrOccurrence" (EVar "occurrence")) (fa "mrrEnclosing" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (fa "mrrLoc" (EVar "loc")) (fa "mrrScope" (EVar "scope")) (fa "mrrGoalEv" (EVar "goalEv")) (fa "mrrQualifiedBody" (EVar "qualifiedBody")) (fa "mrrPredicateTemplate" (EApp (EApp (EApp (EVar "instantiateMethodPredicateTemplate") (EFieldAccess (EVar "mctx") "mcGraph")) (EFieldAccess (EVar "row") "msrPredicateTemplate")) (EVar "subst"))) (fa "mrrOmitted" (EVar "omitted")) (fa "mrrResolution" (EApp (EVar "Ref") (EVar "None"))))))))
(DTypeSig true "mkMethodOccObl" (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Provenance") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ScopeId") (TyCon "UObligation"))))))))))
(DFunDef false "mkMethodOccObl" ((PVar "iface") (PVar "typarams") (PVar "mty") (PVar "occ") (PVar "omitted") (PVar "prov") (PVar "loc") (PVar "scope")) (ERecordCreate "UObligation" ((fa "pred" (ERecordCreate "Predicate" ((fa "iface" (EVar "iface")) (fa "args" (EListLit))))) (fa "originId" (ELit (LInt 0))) (fa "prov" (EVar "prov")) (fa "loc" (EVar "loc")) (fa "uoScope" (EVar "scope")) (fa "oblProj" (EApp (EApp (EApp (EApp (EVar "OpMethodOcc") (EVar "typarams")) (EVar "mty")) (EVar "occ")) (EVar "omitted"))))))
(DTypeSig false "pushNumLitObl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ClassPredicate") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ScopeId") (TyCon "Unit")))))))
(DFunDef false "pushNumLitObl" ((PVar "mctx") (PVar "predicate") (PVar "occurrence") (PVar "loc") (PVar "scope")) (EApp (EApp (EVar "wPush") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "implObls")) (ERecordCreate "UObligation" ((fa "pred" (ERecordCreate "Predicate" ((fa "iface" (EFieldAccess (EVar "predicate") "predicateInterface")) (fa "args" (EFieldAccess (EVar "predicate") "predicateArguments"))))) (fa "originId" (ELit (LInt 0))) (fa "prov" (EVar "PNumLit")) (fa "loc" (EVar "loc")) (fa "uoScope" (EVar "scope")) (fa "oblProj" (EApp (EVar "OpNumLit") (EVar "occurrence")))))))
(DTypeSig false "hasPredicateSlots" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "PredicateSlot"))) (TyCon "Bool"))))
(DFunDef false "hasPredicateSlots" ((PVar "k") (PVar "idx")) (EApp (EApp (EVar "omHasKey") (EVar "k")) (EVar "idx")))
(DTypeSig true "argDispatchIndices" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "argDispatchIndices" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "argDispatchOfDecl")) (EVar "prog")))
(DTypeSig false "argDispatchOfDecl" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "argDispatchOfDecl" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "argDispatchOfDecl") (EVar "d")))
(DFunDef false "argDispatchOfDecl" ((PRec "DInterface" ((rf "typarams" None) (rf "methods" None)) true)) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "argDispatchOfMethod") (EVar "typarams"))) (EVar "methods")))
(DFunDef false "argDispatchOfDecl" (PWild) (EListLit))
(DTypeSig false "argDispatchOfMethod" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "argDispatchOfMethod" ((PVar "typarams") (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild PWild)) (EMatch (EApp (EApp (EApp (EVar "firstDispatchIdx") (EApp (EVar "dispatchTyparams") (EVar "typarams"))) (ELit (LInt 0))) (EApp (EVar "methodArgs") (EVar "mty"))) (arm (PCon "Some" (PVar "i")) () (EListLit (ETuple (EVar "mname") (EVar "i")))) (arm (PCon "None") () (EListLit))))
(DTypeSig true "argDispatchIndicesById" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "IfaceRef") (TyCon "String")) (TyCon "Int")))))
(DFunDef false "argDispatchIndicesById" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "argDispatchOfDeclById")) (EVar "prog")))
(DTypeSig false "argDispatchOfDeclById" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "IfaceRef") (TyCon "String")) (TyCon "Int")))))
(DFunDef false "argDispatchOfDeclById" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "argDispatchOfDeclById") (EVar "d")))
(DFunDef false "argDispatchOfDeclById" ((PRec "DInterface" ((rf "name" None) (rf "typarams" None) (rf "methods" None) (rf "ifaceOrigin" None)) true)) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "argDispatchOfMethodById") (ERecordCreate "IfaceRef" ((fa "irName" (EVar "name")) (fa "irOrigin" (EVar "ifaceOrigin"))))) (EVar "typarams"))) (EVar "methods")))
(DFunDef false "argDispatchOfDeclById" (PWild) (EListLit))
(DTypeSig false "argDispatchOfMethodById" (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "IfaceRef") (TyCon "String")) (TyCon "Int")))))))
(DFunDef false "argDispatchOfMethodById" ((PVar "iface") (PVar "typarams") (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild PWild)) (EMatch (EApp (EApp (EApp (EVar "firstDispatchIdx") (EApp (EVar "dispatchTyparams") (EVar "typarams"))) (ELit (LInt 0))) (EApp (EVar "methodArgs") (EVar "mty"))) (arm (PCon "Some" (PVar "i")) () (EListLit (ETuple (ETuple (EVar "iface") (EVar "mname")) (EVar "i")))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "firstDispatchIdx" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "firstDispatchIdx" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "firstDispatchIdx" ((PVar "typarams") (PVar "i") (PCons (PVar "ty") (PVar "rest"))) (EIf (EApp (EApp (EVar "argMentions") (EVar "typarams")) (EVar "ty")) (EApp (EVar "Some") (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "firstDispatchIdx") (EVar "typarams")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "recordArgStamp" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyFun (TyApp (TyCon "Ref") (TyCon "Inner")) (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyCon "Unit")))))))))))
(DFunDef false "recordArgStamp" ((PVar "mctx") (PVar "suppressed") (PVar "name") (PVar "tagRef") (PVar "implRef") (PVar "innerRef") (PVar "idx") (PVar "mono") (PVar "omitted")) (EIf (EVar "suppressed") (ELit LUnit) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "nthFunDomain") (EVar "idx")) (EVar "mono")) (arm (PCon "Some" (PVar "am")) () (EApp (EApp (EApp (EApp (EVar "pushSiteGoal") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "GKArgStamp")) (EVar "innerRef")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PendingEntry") (EVar "name")) (EVar "tagRef")) (EVar "am")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (EApp (EApp (EApp (EVar "SKArg") (EVar "implRef")) (EVar "mono")) (EVar "omitted"))) (EFieldAccess (EVar "mctx") "mcLoc")) (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit))))) (arm (PCon "None") () (ELit LUnit))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "recordArgSiteFn" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyCon "Unit"))))))
(DFunDef false "recordArgSiteFn" ((PVar "mctx") PWild (PVar "idx") (PVar "mono")) (EMatch (EApp (EApp (EVar "nthFunDomain") (EVar "idx")) (EVar "mono")) (arm (PCon "Some" (PVar "am")) () (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodSiteFns")) (EApp (EApp (EApp (EVar "consSiteFn") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (EVar "am")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodSiteFns") "value")))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig false "mintMethodCell" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "EvId"))))
(DFunDef false "mintMethodCell" ((PVar "mctx") (PVar "seed")) (EApp (EApp (EApp (EApp (EApp (EVar "mintMethodCellRaw") (EVar "mctx")) (ELit (LString ""))) (EVar "None")) (EIf (EBinOp "==" (EVar "seed") (ELit (LString ""))) (EVar "RNone") (EApp (EApp (EVar "RLocal") (EVar "seed")) (EListLit)))) (EListLit)))
(DTypeSig true "mintMethodCellRaw" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "Route") (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyCon "EvId")))))))
(DFunDef false "mintMethodCellRaw" ((PVar "mctx") (PVar "iface") (PVar "arity") (PVar "tag") (PVar "impls")) (EBlock (DoLet false false (PVar "ev") (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit))) (DoLet false false (PVar "g") (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun")) (DoLet false false (PVar "i") (EBinOp "-" (EApp (EVar "evOrdinal") (EVar "ev")) (EFieldAccess (EVar "g") "evBase"))) (DoLet false false (PVar "arr") (EApp (EApp (EVar "indexWithSlot") (EFieldAccess (EVar "g") "evCells")) (EVar "i"))) (DoExpr (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" PWild) () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "method cell #")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "evOrdinal") (EVar "ev"))))) (ELit (LString " minted twice"))))))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EApp (EVar "Some") (ERecordCreate "EvCell" ((fa "ecId" (EVar "ev")) (fa "ecIface" (EApp (EVar "Ref") (EVar "iface"))) (fa "ecArity" (EApp (EVar "Ref") (EVar "arity"))) (fa "ecTag" (EApp (EVar "Ref") (EVar "tag"))) (fa "ecImpl" (EApp (EVar "Ref") (EVar "impls"))) (fa "ecMeth" (EApp (EVar "Ref") (EListLit))) (fa "ecLoc" (EApp (EVar "Ref") (EVar "None"))) (fa "ecName" (EApp (EVar "Ref") (ELit (LString "")))) (fa "ecInner" (EApp (EVar "Ref") (EVar "innerNone"))))))) (EVar "arr"))) (DoExpr (EVar "ev"))))
(DTypeSig false "indexWithSlot" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyVar "a")))) (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyVar "a"))))))
(DFunDef false "indexWithSlot" ((PVar "index") (PVar "i")) (EBlock (DoLet false false (PVar "arr0") (EFieldAccess (EMethodRef "index") "value")) (DoExpr (EIf (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr0"))) (EVar "arr0") (EBlock (DoLet false false (PVar "grown") (EApp (EApp (EVar "arrayMake") (EApp (EApp (EMethodRef "max") (ELit (LInt 16))) (EBinOp "*" (ELit (LInt 2)) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EVar "None"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "arrayBlit") (EVar "arr0")) (ELit (LInt 0))) (EVar "grown")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr0")))) (DoExpr (EApp (EApp (EVar "setRef") (EMethodRef "index")) (EVar "grown"))) (DoExpr (EVar "grown")))))))
(DTypeSig false "mintOpSite" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "EvId"))))
(DFunDef false "mintOpSite" ((PVar "mctx") PWild) (EApp (EApp (EVar "mintSite") (EVar "mctx")) (EApp (EVar "OpSite") (EApp (EVar "Ref") (EVar "RNone")))))
(DTypeSig false "mintLitSite" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "EvId"))))
(DFunDef false "mintLitSite" ((PVar "mctx") PWild) (EApp (EApp (EVar "mintSite") (EVar "mctx")) (EApp (EApp (EVar "LitSite") (EApp (EVar "Ref") (EVar "None"))) (EApp (EVar "Ref") (EVar "RNone")))))
(DTypeSig false "mintHeadSite" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "EvId"))))
(DFunDef false "mintHeadSite" ((PVar "mctx") PWild) (EApp (EApp (EVar "mintSite") (EVar "mctx")) (EApp (EVar "HeadSite") (EApp (EVar "Ref") (ELit (LString ""))))))
(DTypeSig false "mintedOr" (TyFun (TyFun (TyCon "Unit") (TyCon "EvId")) (TyFun (TyCon "EvId") (TyCon "EvId"))))
(DFunDef false "mintedOr" ((PVar "mint") (PVar "ev")) (EIf (EApp (EVar "isUnminted") (EVar "ev")) (EApp (EVar "mint") (ELit LUnit)) (EVar "ev")))
(DTypeSig false "mintSite" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "SiteCell") (TyCon "EvId"))))
(DFunDef false "mintSite" ((PVar "mctx") (PVar "cell")) (EBlock (DoLet false false (PVar "ev") (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit))) (DoLet false false (PVar "g") (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun")) (DoLet false false (PVar "i") (EBinOp "-" (EApp (EVar "evOrdinal") (EVar "ev")) (EFieldAccess (EVar "g") "evBase"))) (DoLet false false (PVar "arr") (EApp (EApp (EVar "indexWithSlot") (EFieldAccess (EVar "g") "siteCells")) (EVar "i"))) (DoExpr (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EApp (EVar "Some") (ETuple (EVar "ev") (EVar "cell")))) (EVar "arr"))) (arm (PCon "Some" PWild) () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "site cell #")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "evOrdinal") (EVar "ev"))))) (ELit (LString " minted twice"))))))) (DoExpr (EVar "ev"))))
(DTypeSig false "siteCellOf" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvId") (TyCon "SiteCell"))))
(DFunDef false "siteCellOf" ((PVar "gctx") (PVar "ev")) (EMatch (EApp (EApp (EVar "siteCellLookup") (EVar "gctx")) (EVar "ev")) (arm (PCon "Ok" (PVar "c")) () (EVar "c")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "panic") (EVar "message")))))
(DTypeSig false "siteCellLookup" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvId") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "SiteCell")))))
(DFunDef false "siteCellLookup" ((PVar "gctx") (PVar "ev")) (EBlock (DoLet false false (PCon "EvId" (PVar "m") (PVar "n")) (EVar "ev")) (DoLet false false (PVar "g") (EFieldAccess (EVar "gctx") "graphRun")) (DoLet false false (PVar "i") (EBinOp "-" (EVar "n") (EFieldAccess (EVar "g") "evBase"))) (DoLet false false (PVar "arr") (EFieldAccess (EFieldAccess (EVar "g") "siteCells") "value")) (DoExpr (EIf (EApp (EVar "isUnminted") (EVar "ev")) (EApp (EVar "Err") (ELit (LString "site reached inference unminted"))) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "site cell ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " is from an earlier graph")))) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "site cell ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " was never minted")))) (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (arm (PCon "Some" (PTuple PWild (PVar "c"))) () (EApp (EVar "Ok") (EVar "c"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "site cell ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " was never minted"))))))))))))
(DTypeSig true "siteRouteCell" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvId") (TyApp (TyCon "Ref") (TyCon "Route")))))
(DFunDef false "siteRouteCell" ((PVar "gctx") (PVar "ev")) (EMatch (EApp (EApp (EVar "siteCellOf") (EVar "gctx")) (EVar "ev")) (arm (PCon "OpSite" (PVar "r")) () (EVar "r")) (arm (PCon "LitSite" PWild (PVar "r")) () (EVar "r")) (arm (PCon "HeadSite" PWild) () (EApp (EVar "notAnOpSite") (EVar "ev")))))
(DTypeSig true "siteHeadCell" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvId") (TyApp (TyCon "Ref") (TyCon "String")))))
(DFunDef false "siteHeadCell" ((PVar "gctx") (PVar "ev")) (EMatch (EApp (EApp (EVar "siteCellOf") (EVar "gctx")) (EVar "ev")) (arm (PCon "HeadSite" (PVar "h")) () (EVar "h")) (arm (PCon "OpSite" PWild) () (EApp (EVar "notAnOpSite") (EVar "ev"))) (arm (PCon "LitSite" PWild PWild) () (EApp (EVar "notAnOpSite") (EVar "ev")))))
(DTypeSig false "siteFloatCell" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvId") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Float"))))))
(DFunDef false "siteFloatCell" ((PVar "gctx") (PVar "ev")) (EMatch (EApp (EApp (EVar "siteCellOf") (EVar "gctx")) (EVar "ev")) (arm (PCon "LitSite" (PVar "f") PWild) () (EVar "f")) (arm (PCon "OpSite" PWild) () (EApp (EVar "notAnOpSite") (EVar "ev"))) (arm (PCon "HeadSite" PWild) () (EApp (EVar "notAnOpSite") (EVar "ev")))))
(DTypeSig false "notAnOpSite" (TyFun (TyCon "EvId") (TyVar "a")))
(DFunDef false "notAnOpSite" ((PVar "ev")) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "site cell ")) (EApp (EMethodRef "display") (EApp (EVar "evIdModule") (EVar "ev")))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "evOrdinal") (EVar "ev"))))) (ELit (LString " is not an operator site")))))
(DTypeSig true "freshEvId" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "EvId"))))
(DFunDef false "freshEvId" ((PVar "mctx") PWild) (EBlock (DoLet false false (PVar "g") (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun")) (DoLet false false (PVar "n") (EFieldAccess (EFieldAccess (EVar "g") "evCounter") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "evCounter")) (EBinOp "+" (EVar "n") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EVar "EvId") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentModuleRef") "value")) (EVar "n")))))
(DTypeSig false "pushNumlit" (TyFun (TyCon "GraphCtx") (TyFun (TyTuple (TyCon "Mono") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Float"))) (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Route"))) (TyCon "Unit"))))
(DFunDef false "pushNumlit" ((PVar "gctx") (PVar "e")) (EBlock (DoLet false false (PVar "g") (EFieldAccess (EVar "gctx") "graphRun")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "numlitRefs")) (EBinOp "::" (EVar "e") (EFieldAccess (EFieldAccess (EVar "g") "numlitRefs") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "numlitN")) (EBinOp "+" (EFieldAccess (EFieldAccess (EVar "g") "numlitN") "value") (ELit (LInt 1)))))))
(DTypeSig true "ctorHeadShaped" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "ctorHeadShaped" ((PVar "name")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "name"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoExpr (EBinOp "&&" (EBinOp ">" (EVar "n") (ELit (LInt 0))) (EBinOp "||" (EApp (EVar "isUpper") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "cs"))) (EApp (EApp (EApp (EVar "mangledCtorShaped") (EVar "cs")) (EVar "n")) (ELit (LInt 0))))))))
(DTypeSig false "mangledCtorShaped" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "mangledCtorShaped" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 2))) (EVar "n")) (EVar "False") (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "_"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "cs")) (ELit (LChar "_")))) (EApp (EVar "isUpper") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "cs")))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "mangledCtorShaped") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "bindingDeclaredAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "MethodTrackedInstantiation") (TyApp (TyCon "Option") (TyCon "CDeclared"))))))
(DFunDef false "bindingDeclaredAt" ((PVar "env") (PVar "name") (PVar "inst")) (EApp (EApp (EApp (EVar "declaredEffectsAt") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "inst")) (EApp (EApp (EVar "bindingDeclared") (EVar "env")) (EVar "name"))))
(DTypeSig false "recordDeclaredBindingCall" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "CDeclared") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyCon "Unit")))))
(DFunDef false "recordDeclaredBindingCall" ((PVar "mctx") (PVar "dc") (PVar "subst")) (EBlock (DoLet false false (PVar "expanded") (EApp (EVar "dedupSlotVecs") (EApp (EApp (EVar "zipSlotVecs") (EFieldAccess (EVar "dc") "cdSlots")) (EFieldAccess (EVar "dc") "cdArgs")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordCallObligations") (EVar "mctx")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "expanded"))) (EApp (EApp (EVar "constraintMonosOf") (EApp (EApp (EMethodRef "map") (ELam ((PVar "pair")) (EFieldAccess (EApp (EVar "fst") (EVar "pair")) "csId"))) (EVar "expanded"))) (EVar "subst"))) (EApp (EApp (EApp (EVar "callArgVecsV") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "expanded")) (EVar "subst"))))))
(DTypeSig false "inferMethodAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "String")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Int"))) (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyFun (TyApp (TyCon "Ref") (TyCon "Inner")) (TyCon "Mono"))))))))))
(DTypeSig true "inferMethodAtCell" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "EvCell") (TyCon "Mono")))))
(DFunDef false "inferMethodAtCell" ((PVar "env") (PVar "name") (PVar "c")) (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsLastMethodInst")) (EVar "None"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsLastStandalone")) (EVar "None"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "c") "ecLoc")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "c") "ecName")) (EVar "name"))) (DoLet false false (PVar "t") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferMethodAt") (EVar "env")) (EVar "name")) (EFieldAccess (EVar "c") "ecIface")) (EFieldAccess (EVar "c") "ecArity")) (EFieldAccess (EVar "c") "ecTag")) (EFieldAccess (EVar "c") "ecImpl")) (EFieldAccess (EVar "c") "ecMeth")) (EFieldAccess (EVar "c") "ecInner"))) (DoExpr (EMatch (ETuple (EFieldAccess (EFieldAccess (EVar "st") "gsLastStandalone") "value") (EFieldAccess (EFieldAccess (EVar "st") "gsLastMethodInst") "value")) (arm (PTuple (PCon "Some" (PTuple (PVar "scheme") (PVar "subst"))) PWild) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordStandaloneGrantOcc") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EFieldAccess (EVar "c") "ecId")) (EVar "scheme")) (EVar "subst")) (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EFieldAccess (EFieldAccess (EVar "c") "ecArity") "value")))) (arm (PTuple (PCon "None") (PCon "Some" (PTuple (PVar "scheme") (PVar "subst")))) () (EApp (EApp (EApp (EApp (EApp (EVar "recordMethodGrantOcc") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EFieldAccess (EVar "c") "ecId")) (EVar "scheme")) (EVar "subst"))) (arm (PTuple (PCon "None") (PCon "None")) () (ELit LUnit)))) (DoExpr (EVar "t"))))
(DTypeSig false "recordShadowStandaloneObls" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyCon "Unit")))))
(DFunDef false "recordShadowStandaloneObls" ((PVar "env") (PVar "name") (PVar "subst")) (EIf (EBinOp "||" (EApp (EApp (EVar "isDefinerShadow") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EApp (EApp (EVar "isShadowStandalone") (EVar "env")) (EVar "name"))) (EMatch (EApp (EApp (EApp (EVar "lookupSchemeObls") (EVar "name")) (ELit (LInt 0))) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "schemeObligationsRef") "value")) (arm (PCon "Some" (PVar "obs")) () (EApp (EApp (EApp (EApp (EVar "recordSchemeCallObligations") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit (LInt 0))) (EVar "obs")) (EVar "subst"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "declaredCrossModuleObls") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (arm (PCon "Some" (PVar "obs")) () (EApp (EApp (EApp (EApp (EVar "recordSchemeCallObligations") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit (LInt 0))) (EVar "obs")) (EVar "subst"))) (arm (PCon "None") () (ELit LUnit))))) (EIf (EVar "otherwise") (ELit LUnit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "inferMethodAt" ((PVar "env") (PVar "name") (PVar "ifaceRef") (PVar "arityRef") (PVar "tagRef") (PVar "implRef") (PVar "methodRef") (PVar "innerRef")) (EBlock (DoLet false false (PVar "selected") (EMatch (EApp (EApp (EVar "standaloneValueBinding") (EVar "env")) (EVar "name")) (arm (PCon "Some" (PVar "scheme")) () (EApp (EVar "Some") (EVar "scheme"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "standaloneValueBindingEmit") (EVar "env")) (EVar "name")) (EVar "tagRef"))))) (DoExpr (EMatch (EVar "selected") (arm (PCon "Some" (PVar "value")) () (EBlock (DoExpr (EApp (EApp (EVar "rejectAdmittedValueOccurrence") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name"))) (DoLet false false (PVar "sym") (EApp (EVar "routeLocalSym") (EUnOp "!" (EVar "tagRef")))) (DoLet false false (PVar "occurrence") (EApp (EApp (EApp (EApp (EApp (EVar "instantiateStandaloneOccurrence") (EVar "env")) (EVar "name")) (EVar "sym")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EVar "value"))) (DoLet false false (PVar "inst") (EFieldAccess (EVar "occurrence") "svoInstance")) (DoLet false false (PVar "dicts") (EFieldAccess (EVar "occurrence") "svoDicts")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph") "graphRun") "grants") "gsLastStandalone")) (EApp (EVar "Some") (ETuple (EFieldAccess (EVar "occurrence") "svoScheme") (EFieldAccess (EFieldAccess (EVar "inst") "mtiSubstitution") "misAuthSubst"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "arityRef")) (EApp (EVar "Some") (EApp (EVar "funArity") (EFieldAccess (EVar "inst") "mtiBody"))))) (DoLet false false (PVar "receiver") (EMatch (EApp (EApp (EVar "methodDispatchIdx") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (arm (PCon "Some" (PVar "idx")) () (EApp (EApp (EVar "optionOr") (EFieldAccess (EVar "inst") "mtiBody")) (EApp (EApp (EVar "nthFunDomain") (EVar "idx")) (EFieldAccess (EVar "inst") "mtiBody")))) (arm (PCon "None") () (EFieldAccess (EVar "inst") "mtiBody")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pushSiteGoal") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "GKRLocalSite")) (EVar "innerRef")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PendingEntry") (EVar "name")) (EVar "tagRef")) (EVar "receiver")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentFn") "value")) (EApp (EApp (EApp (EApp (EApp (EVar "SKRLocal") (EVar "sym")) (EVar "True")) (EFieldAccess (EVar "dicts") "sdMonos")) (EFieldAccess (EVar "dicts") "sdIfaces")) (EFieldAccess (EVar "dicts") "sdArgVecs"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EApp (EApp (EVar "captureScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (EApp (EApp (EVar "freshEvId") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))))) (DoExpr (EFieldAccess (EVar "inst") "mtiBody")))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferMethodCandidateAt") (EVar "env")) (EVar "name")) (EVar "ifaceRef")) (EVar "arityRef")) (EVar "tagRef")) (EVar "implRef")) (EVar "methodRef")) (EVar "innerRef")))))))
(DTypeSig false "inferMethodCandidateAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "String")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Int"))) (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyFun (TyApp (TyCon "Ref") (TyCon "Inner")) (TyCon "Mono"))))))))))
(DFunDef false "inferMethodCandidateAt" ((PVar "env") (PVar "name") (PVar "ifaceRef") (PVar "arityRef") (PVar "tagRef") (PVar "implRef") (PVar "methodRef") (PVar "innerRef")) (EMatch (EApp (EApp (EVar "lookupVar") (EVar "env")) (EVar "name")) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (ELit (LString "unbound method: ")) (EVar "name")))) (arm (PCon "Some" (PVar "s")) () (EBlock (DoLet false false (PVar "inst") (EApp (EApp (EVar "instantiateMethodTracked") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "s"))) (DoLet false false (PVar "occurrence") (EFieldAccess (EVar "inst") "mtiBody")) (DoLet false false (PVar "subst") (EFieldAccess (EVar "inst") "mtiSubstitution")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph") "graphRun") "grants") "gsLastMethodInst")) (EApp (EVar "Some") (ETuple (EVar "s") (EFieldAccess (EVar "subst") "misAuthSubst"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "arityRef")) (EApp (EVar "Some") (EApp (EVar "funArity") (EVar "occurrence"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "ifaceRef")) (EApp (EApp (EVar "admittedIfaceWord") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordRLocalSite") (EVar "env")) (EVar "name")) (EVar "tagRef")) (EVar "innerRef")) (EVar "occurrence"))) (DoLet false false (PVar "ret") (EMatch (EApp (EApp (EVar "argDispatchOf") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (arm (PCon "Some" (PVar "idx")) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordMethodDicts") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "methodRef")) (EVar "innerRef")) (EFieldAccess (EVar "subst") "misTypeSubst"))) (DoLet false false (PVar "omitted") (EApp (EApp (EVar "methodOmittedVars") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "recordMethodObligationGuarded") (EVar "env")) (EVar "name")) (EVar "s")) (EVar "occurrence")) (EVar "omitted"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordArgStamp") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcSuppressArgStamp")) (EVar "name")) (EVar "tagRef")) (EVar "implRef")) (EVar "innerRef")) (EVar "idx")) (EVar "occurrence")) (EVar "omitted"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordArgSiteFn") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "idx")) (EVar "occurrence"))) (DoExpr (EVar "occurrence")))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordSite") (EVar "env")) (EVar "name")) (EVar "s")) (EVar "ifaceRef")) (EVar "tagRef")) (EVar "implRef")) (EVar "methodRef")) (EVar "innerRef")) (EVar "occurrence")) (EVar "subst"))))) (DoLet false false PWild (EApp (EApp (EApp (EVar "forceInstantiation") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "inst"))) (DoExpr (EVar "ret"))))))
(DTypeSig false "recordRLocalSite" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyApp (TyCon "Ref") (TyCon "Inner")) (TyFun (TyCon "Mono") (TyCon "Unit")))))))
(DFunDef false "recordRLocalSite" ((PVar "env") (PVar "name") (PVar "tagRef") (PVar "innerRef") (PVar "inst")) (EIf (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcSuppressRLocalRecord") (ELit LUnit) (EIf (EBinOp "&&" (EApp (EVar "isNone") (EApp (EApp (EVar "methodDispatchIdx") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name"))) (EApp (EApp (EVar "standaloneValuePinned") (EVar "env")) (EVar "name"))) (EApp (EApp (EApp (EApp (EVar "pushSiteGoal") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "GKRLocalSite")) (EVar "innerRef")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PendingEntry") (EVar "name")) (EVar "tagRef")) (EVar "inst")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentFn") "value")) (EApp (EApp (EApp (EApp (EApp (EVar "SKRLocal") (EApp (EVar "routeLocalSym") (EUnOp "!" (EVar "tagRef")))) (EVar "True")) (EListLit)) (EListLit)) (EListLit))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EApp (EApp (EVar "captureScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (EApp (EApp (EVar "freshEvId") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit)))) (EIf (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "standaloneValuesRef") "value"))) (ELit LUnit) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "methodDispatchIdx") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "idx")) () (EMatch (EApp (EApp (EVar "nthFunDomain") (EVar "idx")) (EVar "inst")) (arm (PCon "Some" (PVar "am")) () (EBlock (DoLet false false (PVar "sym") (EApp (EVar "routeLocalSym") (EUnOp "!" (EVar "tagRef")))) (DoLet false false (PVar "dicts") (EApp (EApp (EApp (EApp (EApp (EVar "shadowStandaloneDictSlotsAt") (EFieldAccess (EVar "env") "teDyn")) (EApp (EApp (EApp (EVar "standaloneValueFor") (EVar "env")) (EVar "name")) (EVar "sym"))) (EVar "name")) (EIf (EBinOp "==" (EVar "sym") (ELit (LString ""))) (EVar "name") (EVar "sym"))) (EVar "am"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pushSiteGoal") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "GKRLocalSite")) (EVar "innerRef")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PendingEntry") (EVar "name")) (EVar "tagRef")) (EVar "am")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentFn") "value")) (EApp (EApp (EApp (EApp (EApp (EVar "SKRLocal") (EVar "sym")) (EApp (EApp (EVar "standaloneValuePinned") (EVar "env")) (EVar "name"))) (EFieldAccess (EVar "dicts") "sdMonos")) (EFieldAccess (EVar "dicts") "sdIfaces")) (EFieldAccess (EVar "dicts") "sdArgVecs"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EApp (EApp (EVar "captureScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (EApp (EApp (EVar "freshEvId") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))))))) (arm (PCon "None") () (ELit LUnit))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig true "standaloneSchemeFor" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Scheme"))))))
(DFunDef false "standaloneSchemeFor" ((PVar "env") (PVar "name") (PVar "sym")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "value")) (EFieldAccess (EVar "value") "vsScheme"))) (EApp (EApp (EApp (EVar "standaloneValueFor") (EVar "env")) (EVar "name")) (EVar "sym"))))
(DTypeSig true "standaloneOccurrence" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "Option") (TyCon "SelectedValueOccurrence")))))))
(DFunDef false "standaloneOccurrence" ((PVar "env") (PVar "name") (PVar "sym") (PVar "origin")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EVar "instantiateStandaloneOccurrence") (EVar "env")) (EVar "name")) (EVar "sym")) (EVar "origin"))) (EApp (EApp (EApp (EVar "standaloneValueFor") (EVar "env")) (EVar "name")) (EVar "sym"))))
(DTypeSig false "recordMethodDicts" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyFun (TyApp (TyCon "Ref") (TyCon "Inner")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyCon "Unit")))))))
(DFunDef false "recordMethodDicts" ((PVar "mctx") (PVar "name") (PVar "methodRef") (PVar "innerRef") (PVar "subst")) (EMatch (EApp (EApp (EVar "methodIfaceHere") (EVar "mctx")) (EVar "name")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "iface")) () (EMatch (EApp (EApp (EVar "lookupAssoc") (EApp (EApp (EVar "methodSlotKey") (EVar "iface")) (EApp (EApp (EVar "originMethodName") (EVar "mctx")) (EVar "name")))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodPredicateSlotsRef") "value")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "slots")) () (EApp (EApp (EApp (EApp (EApp (EVar "recordMethodDictsFromSlots") (EVar "mctx")) (EVar "slots")) (EVar "methodRef")) (EVar "innerRef")) (EVar "subst")))))))
(DTypeSig false "recordMethodDictsFromSlots" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyFun (TyApp (TyCon "Ref") (TyCon "Inner")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyCon "Unit")))))))
(DFunDef false "recordMethodDictsFromSlots" ((PVar "mctx") (PVar "slots") (PVar "methodRef") (PVar "innerRef") (PVar "subst")) (EApp (EApp (EVar "pushMethodDictGoal") (EFieldAccess (EVar "mctx") "mcGraph")) (ERecordCreate "PendingMethodDict" ((fa "pmdRoutesRef" (EVar "methodRef")) (fa "pmdEv" (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit))) (fa "pmdSlots" (EApp (EApp (EApp (EVar "instantiateMethodPredicateSlots") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "slots")) (EVar "subst"))) (fa "pmdEncl" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (fa "pmdScope" (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) (fa "pmdInner" (EVar "innerRef"))))))
(DTypeSig false "instantiateMethodPredicateSlots" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "PredicateSlot"))))))
(DFunDef false "instantiateMethodPredicateSlots" ((PVar "gctx") (PList) PWild) (EListLit))
(DFunDef false "instantiateMethodPredicateSlots" ((PVar "gctx") (PCons (PVar "slot") (PVar "rest")) (PVar "subst")) (EMatch (EApp (EApp (EApp (EVar "instantiateMethodPredicateSlot") (EVar "gctx")) (EVar "slot")) (EVar "subst")) (arm (PCon "Some" (PVar "pred")) () (EBinOp "::" (EVar "pred") (EApp (EApp (EApp (EVar "instantiateMethodPredicateSlots") (EVar "gctx")) (EVar "rest")) (EVar "subst")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "instantiateMethodPredicateSlots") (EVar "gctx")) (EVar "rest")) (EVar "subst")))))
(DTypeSig false "instantiateMethodPredicateSlot" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "MethodPredicateSlot") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyCon "PredicateSlot"))))))
(DFunDef false "instantiateMethodPredicateSlot" ((PVar "gctx") (PVar "slot") (PVar "subst")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "instantiatedMethodPredicate") (EVar "gctx")) (EVar "slot")) (EVar "subst"))) (EApp (EApp (EApp (EVar "methodSlotSubst") (EFieldAccess (EFieldAccess (EVar "slot") "mpsPredicate") "psBoundIds")) (EFieldAccess (EVar "slot") "mpsPositions")) (EVar "subst"))))
(DTypeSig false "instantiatedMethodPredicate" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "MethodPredicateSlot") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyCon "PredicateSlot"))))))
(DFunDef false "instantiatedMethodPredicate" ((PVar "gctx") (PVar "slot") (PVar "subst") (PVar "slotSubst")) (EBlock (DoLet false false (PVar "args2") (EApp (EApp (EApp (EVar "instantiatedMethodPredicateArgs") (EVar "gctx")) (EFieldAccess (EFieldAccess (EVar "slot") "mpsPredicate") "psArgs")) (EVar "slotSubst"))) (DoExpr (ERecordCreate "PredicateSlot" ((fa "psIface" (EFieldAccess (EFieldAccess (EVar "slot") "mpsPredicate") "psIface")) (fa "psArgs" (EVar "args2")) (fa "psBoundIds" (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EApp (EVar "optionOr") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EApp (EApp (EVar "get") (EVar "p")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "subst")))))) (EFieldAccess (EVar "slot") "mpsPositions"))))))))
(DTypeSig false "instantiatedMethodPredicateArgs" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PredicateSlotArgs") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyCon "PredicateSlotArgs")))))
(DFunDef false "instantiatedMethodPredicateArgs" ((PVar "gctx") (PCon "PSArgsUnknown") PWild) (EVar "PSArgsUnknown"))
(DFunDef false "instantiatedMethodPredicateArgs" ((PVar "gctx") (PCon "PSArgsKnown" (PVar "args")) (PVar "subst")) (EApp (EVar "PSArgsKnown") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EVar "subst")) (EListLit)) (EListLit))) (EVar "args"))))
(DTypeSig false "methodSlotSubst" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))))))))
(DFunDef false "methodSlotSubst" ((PVar "ids") (PVar "positions") (PVar "subst")) (EBlock (DoLet false false (PVar "vals") (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "subst"))) (DoLet false false (PVar "n") (EApp (EVar "listLen") (EVar "subst"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "listLen") (EVar "ids")) (EApp (EVar "listLen") (EVar "positions"))) (EApp (EApp (EVar "allInRange") (EVar "positions")) (EVar "n"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "zipMethodSlotSubst") (EVar "ids")) (EVar "positions")) (EVar "vals"))) (EVar "None")))))
(DTypeSig false "zipMethodSlotSubst" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))))))
(DFunDef false "zipMethodSlotSubst" ((PList) PWild PWild) (EListLit))
(DFunDef false "zipMethodSlotSubst" (PWild (PList) PWild) (EListLit))
(DFunDef false "zipMethodSlotSubst" ((PCons (PVar "id") (PVar "ids")) (PCons (PVar "pos") (PVar "positions")) (PVar "vals")) (EBinOp "::" (ETuple (EVar "id") (EApp (EApp (EVar "nthMethodMono") (EVar "pos")) (EVar "vals"))) (EApp (EApp (EApp (EVar "zipMethodSlotSubst") (EVar "ids")) (EVar "positions")) (EVar "vals"))))
(DTypeSig false "allInRange" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "allInRange" ((PList) PWild) (EVar "True"))
(DFunDef false "allInRange" ((PCons (PVar "p") (PVar "rest")) (PVar "n")) (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "p") (ELit (LInt 0))) (EBinOp "<" (EVar "p") (EVar "n"))) (EApp (EApp (EVar "allInRange") (EVar "rest")) (EVar "n"))))
(DTypeSig false "nthMethodMono" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Mono"))))
(DFunDef false "nthMethodMono" (PWild (PList)) (EApp (EVar "tconUnresolved") (ELit (LString "__missing_method_slot__"))))
(DFunDef false "nthMethodMono" ((PLit (LInt 0)) (PCons (PVar "x") PWild)) (EVar "x"))
(DFunDef false "nthMethodMono" ((PVar "i") (PCons PWild (PVar "xs"))) (EApp (EApp (EVar "nthMethodMono") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "xs")))
(DTypeSig false "recordSite" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Scheme") (TyFun (TyApp (TyCon "Ref") (TyCon "String")) (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyFun (TyApp (TyCon "Ref") (TyCon "Inner")) (TyFun (TyCon "Mono") (TyFun (TyCon "MethodInstantiationSubst") (TyCon "Mono"))))))))))))
(DFunDef false "recordSite" ((PVar "env") (PVar "name") (PVar "scheme") (PVar "ifaceRef") (PVar "tagRef") (PVar "implRef") (PVar "methodRef") (PVar "innerRef") (PVar "methodType") (PVar "subst")) (EBlock (DoLet false false (PVar "stripped") (EApp (EVar "stripArrows") (EVar "methodType"))) (DoLet false false (PVar "ev") (EApp (EApp (EVar "freshEvId") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "exactRow") (EApp (EApp (EApp (EVar "exactReturnRow") (EVar "env")) (EVar "name")) (EVar "scheme"))) (DoLet false false (PVar "admitted") (EBinOp "&&" (EApp (EVar "isNone") (EVar "exactRow")) (EApp (EApp (EApp (EVar "admittedSetOccurrence") (EVar "env")) (EVar "name")) (EVar "scheme")))) (DoLet false false (PVar "exact") (EApp (EApp (EMethodRef "map") (ELam ((PVar "row")) (EApp (EApp (EApp (EApp (EApp (EVar "methodReturnRequest") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "row")) (EVar "methodType")) (EVar "subst")) (EApp (EVar "Some") (EVar "ev"))))) (EVar "exactRow"))) (DoExpr (EMatch (ETuple (EVar "exact") (EVar "exactRow")) (arm (PTuple (PCon "Some" (PVar "request")) (PCon "Some" (PVar "row"))) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordMethodLevelSlotsOwned") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "row")) (EFieldAccess (EVar "subst") "misTypeSubst")) (EFieldAccess (EVar "request") "mrrLoc")) (EFieldAccess (EVar "request") "mrrScope"))) (DoLet false false PWild (EApp (EApp (EVar "recordExactMethodObligation") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "request"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EFieldAccess (EVar "row") "msrMethodSlots")) (ELit LUnit) (EApp (EApp (EApp (EApp (EApp (EVar "recordMethodDictsFromSlots") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EVar "row") "msrMethodSlots")) (EVar "methodRef")) (EVar "innerRef")) (EFieldAccess (EVar "subst") "misTypeSubst")))))) (arm PWild () (EBlock (DoExpr (EIf (EVar "admitted") (EApp (EApp (EApp (EVar "pushAdmittedOccObl") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "methodType")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "recordMethodObligationGuarded") (EVar "env")) (EVar "name")) (EVar "scheme")) (EVar "methodType")) (EListLit))) (DoExpr (ELit LUnit))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordMethodDicts") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "methodRef")) (EVar "innerRef")) (EFieldAccess (EVar "subst") "misTypeSubst"))))))) (DoLet false false (PVar "siteEv") (EMatch (EVar "exact") (arm (PCon "Some" (PVar "request")) () (EApp (EApp (EVar "optionOr") (EVar "ev")) (EFieldAccess (EVar "request") "mrrGoalEv"))) (arm (PCon "None") () (EVar "ev")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pushSiteGoal") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "GKReturnSite")) (EVar "innerRef")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PendingEntry") (EVar "name")) (EVar "tagRef")) (EVar "stripped")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentFn") "value")) (EMatch (EVar "exact") (arm (PCon "Some" (PVar "request")) () (EApp (EApp (EVar "SKExactReturn") (EVar "implRef")) (EVar "request"))) (arm (PCon "None") () (EIf (EVar "admitted") (EApp (EApp (EApp (EVar "SKAdmittedReturn") (EVar "ifaceRef")) (EVar "implRef")) (EVar "methodType")) (EApp (EApp (EVar "SKReturn") (EVar "implRef")) (EVar "methodType")))))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EApp (EApp (EVar "captureScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (EVar "siteEv")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "methodSiteFns")) (EApp (EApp (EApp (EVar "consSiteFn") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentFn") "value")) (EVar "stripped")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "methodSiteFns") "value")))) (DoExpr (EVar "methodType"))))
(DTypeSig false "recordNumLitSite" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ClassPredicate") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ScopeId") (TyCon "Mono"))))))))
(DFunDef false "recordNumLitSite" ((PVar "mctx") (PVar "predicate") (PVar "tagRef") (PVar "occurrence") (PVar "origin") (PVar "scope")) (EBlock (DoLet false false (PVar "stripped") (EApp (EVar "stripArrows") (EVar "occurrence"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pushSiteGoal") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "GKReturnSite")) (EApp (EVar "Ref") (EVar "innerNone"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PendingEntry") (ELit (LString "fromInt"))) (EVar "tagRef")) (EVar "stripped")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (EApp (EApp (EVar "SKNumReturn") (EVar "predicate")) (EVar "occurrence"))) (EVar "origin")) (EVar "scope")) (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodSiteFns")) (EApp (EApp (EApp (EVar "consSiteFn") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (EVar "stripped")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodSiteFns") "value")))) (DoExpr (EVar "occurrence"))))
(DTypeSig false "freshLocalAbsName" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "freshLocalAbsName" ((PVar "gctx") (PVar "x")) (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "localAbs")) (DoLet false false (PTuple (PVar "mid") (PVar "k")) (EFieldAccess (EFieldAccess (EVar "st") "lasNext") "value")) (DoLet false false (PVar "name") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString "$"))) (EApp (EMethodRef "display") (EVar "mid"))) (ELit (LString "$"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString "$lb")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "lasNext")) (ETuple (EVar "mid") (EBinOp "+" (EVar "k") (ELit (LInt 1)))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "lasMinted")) (EBinOp "::" (EVar "name") (EFieldAccess (EFieldAccess (EVar "st") "lasMinted") "value")))) (DoExpr (EVar "name"))))
(DTypeSig false "mintGrantOnly" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Expr"))))
(DFunDef false "mintGrantOnly" ((PVar "mctx") (PVar "n")) (EBlock (DoLet false false (PVar "ev") (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit))) (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsGrantOnly")) (EApp (EApp (EApp (EVar "IdMap.set") (EApp (EVar "evOrdinal") (EVar "ev"))) (ELit LUnit)) (EFieldAccess (EFieldAccess (EVar "st") "gsGrantOnly") "value")))) (DoExpr (EApp (EApp (EVar "EDictAt") (EVar "n")) (EVar "ev")))))
(DTypeSig true "isGrantOnlyEv" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvId") (TyCon "Bool"))))
(DFunDef false "isGrantOnlyEv" ((PVar "gctx") (PVar "ev")) (EApp (EApp (EVar "IdMap.has") (EApp (EVar "evOrdinal") (EVar "ev"))) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants") "gsGrantOnly") "value")))
(DTypeSig false "unmarkGrantOnly" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvId") (TyCon "Unit"))))
(DFunDef false "unmarkGrantOnly" ((PVar "gctx") (PVar "ev")) (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsGrantOnly")) (EApp (EApp (EVar "IdMap.delete") (EApp (EVar "evOrdinal") (EVar "ev"))) (EFieldAccess (EFieldAccess (EVar "st") "gsGrantOnly") "value"))))))
(DTypeSig false "qualConstraintFor" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "CSlot"))))))
(DFunDef false "qualConstraintFor" ((PVar "mctx") (PVar "name")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "d")) (EFieldAccess (EVar "d") "cdSlots"))) (EApp (EApp (EVar "qualConstraintDecl") (EVar "mctx")) (EVar "name"))))
(DTypeSig false "declaredConstraintIds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "declaredConstraintIds" ((PVar "mctx") (PVar "name")) (EMatch (EApp (EApp (EVar "qualConstraintIds") (EVar "mctx")) (EVar "name")) (arm (PCon "Some" (PVar "ids")) () (EVar "ids")) (arm (PCon "None") () (EIf (EApp (EApp (EVar "hasImportDefiner") (EVar "mctx")) (EVar "name")) (EListLit) (EApp (EApp (EVar "predicateSlotIdsAt") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funPredicateSlotsIdxRef") "value"))))))
(DTypeSig false "qualConstraintIds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "qualConstraintIds" ((PVar "mctx") (PVar "name")) (EMatch (EApp (EApp (EVar "qualConstraintKey") (EVar "mctx")) (EVar "name")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple (PVar "src") (PVar "origin"))) () (EApp (EApp (EMethodRef "map") (EVar "predicateSlotIds")) (EApp (EApp (EApp (EVar "lookupQualPayload") (EVar "src")) (EVar "origin")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "crossRun") "crossModuleFunPredicateSlotsQualRef") "value"))))))
(DTypeSig true "inferDictAtFound" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyFun (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))) (TyCon "Mono"))))))
(DFunDef false "inferDictAtFound" ((PVar "mctx") (PVar "name") (PVar "ev") (PVar "inst")) (EBlock (DoLet false false (PVar "q") (EApp (EApp (EVar "qualConstraintFor") (EVar "mctx")) (EVar "name"))) (DoLet false false (PVar "dc") (EApp (EApp (EVar "declaredConstraintFor") (EVar "mctx")) (EVar "name"))) (DoLet false false (PVar "declaredIds") (EApp (EApp (EVar "declaredConstraintIds") (EVar "mctx")) (EVar "name"))) (DoLet false false (PVar "known") (EMatch (EVar "q") (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EApp (EApp (EVar "hasPredicateSlots") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funPredicateSlotsIdxRef") "value"))))) (DoExpr (EIf (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "declaredIds")) (EApp (EApp (EVar "hasImportDefiner") (EVar "mctx")) (EVar "name"))) (EBlock (DoExpr (EApp (EApp (EVar "pushDictApp") (EFieldAccess (EVar "mctx") "mcGraph")) (ERecordCreate "PendingDictApp" ((fa "pdaRoutesRef" (EApp (EVar "Ref") (EListLit))) (fa "pdaEv" (EVar "ev")) (fa "pdaMonos" (EListLit)) (fa "pdaIfaces" (EListLit)) (fa "pdaArgVecs" (EListLit)) (fa "pdaEncl" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (fa "pdaLoc" (EFieldAccess (EVar "mctx") "mcLoc")) (fa "pdaScope" (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) (fa "pdaCallee" (EApp (EVar "localSourceName") (EVar "name"))))))) (DoExpr (EApp (EVar "fst") (EVar "inst")))) (EIf (EBinOp "&&" (EVar "known") (EBinOp "||" (EApp (EApp (EVar "anyIdPinned") (EVar "declaredIds")) (EApp (EVar "snd") (EVar "inst"))) (EApp (EApp (EApp (EApp (EVar "calleeIsGeneralized") (EVar "mctx")) (EVar "name")) (EVar "q")) (EApp (EVar "snd") (EVar "inst"))))) (EApp (EApp (EApp (EApp (EApp (EVar "inferDeclaredDictAt") (EVar "mctx")) (EVar "name")) (EVar "ev")) (EVar "dc")) (ETuple (EApp (EVar "fst") (EVar "inst")) (EApp (EApp (EApp (EVar "pinUnboundIds") (EVar "mctx")) (EVar "declaredIds")) (EApp (EVar "snd") (EVar "inst"))))) (EBlock (DoExpr (EApp (EApp (EVar "pushRecDictAppGoal") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "RecDictApp") (EApp (EVar "Ref") (EListLit))) (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (EApp (EVar "fst") (EVar "inst"))) (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) (EVar "ev")))) (DoExpr (EApp (EVar "fst") (EVar "inst")))))))))
(DTypeSig true "inferDeclaredDictAt" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyFun (TyCon "CDeclared") (TyFun (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))) (TyCon "Mono")))))))
(DFunDef false "inferDeclaredDictAt" ((PVar "mctx") (PVar "name") (PVar "ev") (PVar "dc") (PVar "inst")) (EBlock (DoLet false false (PVar "expandedV") (EApp (EVar "dedupSlotVecs") (EApp (EApp (EVar "zipSlotVecs") (EFieldAccess (EVar "dc") "cdSlots")) (EFieldAccess (EVar "dc") "cdArgs")))) (DoLet false false (PVar "expanded") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "expandedV"))) (DoLet false false (PVar "ids") (EApp (EApp (EMethodRef "map") (ELam ((PVar "s")) (EFieldAccess (EVar "s") "csId"))) (EVar "expanded"))) (DoLet false false (PVar "monos") (EApp (EApp (EVar "constraintMonosOf") (EVar "ids")) (EApp (EVar "snd") (EVar "inst")))) (DoLet false false (PVar "argVecs") (EApp (EApp (EApp (EVar "callArgVecsV") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "expandedV")) (EApp (EVar "snd") (EVar "inst")))) (DoExpr (EApp (EApp (EVar "pushDictApp") (EFieldAccess (EVar "mctx") "mcGraph")) (ERecordCreate "PendingDictApp" ((fa "pdaRoutesRef" (EApp (EVar "Ref") (EListLit))) (fa "pdaEv" (EVar "ev")) (fa "pdaMonos" (EVar "monos")) (fa "pdaIfaces" (EApp (EApp (EMethodRef "map") (ELam ((PVar "s")) (EFieldAccess (EVar "s") "csIface"))) (EVar "expanded"))) (fa "pdaArgVecs" (EVar "argVecs")) (fa "pdaEncl" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (fa "pdaLoc" (EFieldAccess (EVar "mctx") "mcLoc")) (fa "pdaScope" (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) (fa "pdaCallee" (EApp (EVar "localSourceName") (EVar "name"))))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dictAppFns")) (EApp (EApp (EApp (EVar "consSiteFn") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (EApp (EApp (EVar "bareVectorLeads") (EVar "monos")) (EVar "argVecs"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dictAppFns") "value")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordCallObligations") (EVar "mctx")) (EVar "expanded")) (EVar "monos")) (EVar "argVecs"))) (DoExpr (EApp (EVar "fst") (EVar "inst")))))
(DTypeSig false "calleeIsGeneralized" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "CSlot"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyCon "Bool"))))))
(DFunDef false "calleeIsGeneralized" ((PVar "mctx") (PVar "name") (PVar "q") (PVar "subst")) (EIf (EApp (EVar "isSome") (EVar "q")) (EVar "True") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "sigTyMapRef") "value")) (arm (PCon "Some" (PVar "ty")) () (EBinOp "||" (EApp (EVar "isNonEmptyL") (EVar "subst")) (EApp (EVar "isEmptyL") (EApp (EVar "tyVarNames") (EVar "ty"))))) (arm (PCon "None") () (EVar "False"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "pinUnboundIds" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))))))
(DFunDef false "pinUnboundIds" ((PVar "mctx") (PVar "ids") (PVar "subst")) (EBinOp "++" (EVar "subst") (EApp (EApp (EMethodRef "map") (ELam ((PVar "id")) (ETuple (EVar "id") (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "id")) (EApp (EVar "isNone") (EApp (EApp (EVar "lookupAssocI") (EVar "id")) (EVar "subst"))))) (EVar "ids")))))
(DTypeSig false "anyIdPinned" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyCon "Bool"))))
(DFunDef false "anyIdPinned" ((PList) PWild) (EVar "False"))
(DFunDef false "anyIdPinned" ((PCons (PVar "id") (PVar "rest")) (PVar "subst")) (EMatch (EApp (EApp (EVar "lookupAssocI") (EVar "id")) (EVar "subst")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EApp (EApp (EVar "anyIdPinned") (EVar "rest")) (EVar "subst")))))
(DTypeSig false "recordCallObligations" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "CSlot")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Mono"))) (TyCon "Unit"))))))
(DFunDef false "recordCallObligations" ((PVar "mctx") (PList) PWild PWild) (ELit LUnit))
(DFunDef false "recordCallObligations" ((PVar "mctx") PWild (PList) PWild) (ELit LUnit))
(DFunDef false "recordCallObligations" ((PVar "mctx") (PCons (PVar "s") (PVar "ss")) (PCons (PVar "mono") (PVar "ms")) (PList)) (EIf (EBinOp "==" (EFieldAccess (EFieldAccess (EVar "s") "csIface") "irName") (ELit (LString ""))) (EApp (EApp (EApp (EApp (EVar "recordCallObligations") (EVar "mctx")) (EVar "ss")) (EVar "ms")) (EListLit)) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordObl") (EVar "mctx")) (ERecordCreate "Predicate" ((fa "iface" (EFieldAccess (EVar "s") "csIface")) (fa "args" (EListLit (EVar "mono")))))) (ELit (LInt 0))) (EVar "PCallSlot")) (EFieldAccess (EVar "mctx") "mcLoc"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordCallObligations") (EVar "mctx")) (EVar "ss")) (EVar "ms")) (EListLit)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "recordCallObligations" ((PVar "mctx") (PCons (PVar "s") (PVar "ss")) (PCons (PVar "mono") (PVar "ms")) (PCons (PVar "args") (PVar "rest"))) (EIf (EBinOp "==" (EFieldAccess (EFieldAccess (EVar "s") "csIface") "irName") (ELit (LString ""))) (EApp (EApp (EApp (EApp (EVar "recordCallObligations") (EVar "mctx")) (EVar "ss")) (EVar "ms")) (EVar "rest")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "goalArgs") (EIf (EApp (EVar "isEmptyL") (EVar "args")) (EListLit (EVar "mono")) (EVar "args"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordObl") (EVar "mctx")) (ERecordCreate "Predicate" ((fa "iface" (EFieldAccess (EVar "s") "csIface")) (fa "args" (EVar "goalArgs"))))) (ELit (LInt 0))) (EVar "PCallSlot")) (EFieldAccess (EVar "mctx") "mcLoc"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordCallObligations") (EVar "mctx")) (EVar "ss")) (EVar "ms")) (EVar "rest")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "bareVectorLeads" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "bareVectorLeads" ((PVar "monos") (PList)) (EVar "monos"))
(DFunDef false "bareVectorLeads" ((PList) PWild) (EListLit))
(DFunDef false "bareVectorLeads" ((PCons (PVar "m") (PVar "ms")) (PCons (PVar "v") (PVar "vs"))) (EIf (EApp (EApp (EVar "allList") (EVar "isBareTyvarMono")) (EVar "v")) (EBinOp "::" (EVar "m") (EApp (EApp (EVar "bareVectorLeads") (EVar "ms")) (EVar "vs"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "bareVectorLeads") (EVar "ms")) (EVar "vs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "recordBinopSite" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyCon "Mono") (TyCon "Unit"))))))
(DFunDef false "recordBinopSite" ((PVar "mctx") (PVar "op") (PVar "dref") (PVar "m")) (EMatch (EApp (EVar "binopMethod") (EVar "op")) (arm (PCon "Some" (PVar "method")) () (EApp (EApp (EApp (EApp (EVar "pushSiteGoal") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "GKBinopSite")) (EApp (EVar "Ref") (EVar "innerNone"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PendingEntry") (EVar "method")) (EVar "dref")) (EVar "m")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (EApp (EVar "SKOp") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentImplBody") "value"))) (EFieldAccess (EVar "mctx") "mcLoc")) (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit))))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig true "arithDispatchMethod" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "arithDispatchMethod" ((PLit (LString "+"))) (EApp (EVar "Some") (ELit (LString "add"))))
(DFunDef false "arithDispatchMethod" ((PLit (LString "-"))) (EApp (EVar "Some") (ELit (LString "sub"))))
(DFunDef false "arithDispatchMethod" ((PLit (LString "*"))) (EApp (EVar "Some") (ELit (LString "mul"))))
(DFunDef false "arithDispatchMethod" ((PLit (LString "/"))) (EApp (EVar "Some") (ELit (LString "div"))))
(DFunDef false "arithDispatchMethod" ((PLit (LString "%"))) (EApp (EVar "Some") (ELit (LString "rem"))))
(DFunDef false "arithDispatchMethod" (PWild) (EVar "None"))
(DTypeSig true "recordBinopGoals" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyCon "Mono") (TyCon "Unit"))))))
(DFunDef false "recordBinopGoals" ((PVar "mctx") (PVar "op") (PVar "dref") (PVar "m")) (EMatch (EApp (EVar "arithDispatchMethod") (EVar "op")) (arm (PCon "Some" (PVar "method")) () (EIf (EApp (EApp (EVar "builtinClassPresent") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "BNum")) (EBlock (DoLet false false (PVar "predicate") (ERecordCreate "ClassPredicate" ((fa "predicateInterface" (EApp (EApp (EVar "builtinIfaceRef") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "BNum"))) (fa "predicateArguments" (EListLit (EVar "m")))))) (DoLet false false (PVar "scope") (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteNumericPredicateTrace") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "NPTProduced")) (EVar "predicate")) (EVar "scope")) (EFieldAccess (EVar "mctx") "mcLoc")) (EVar "None")) (EVar "None")) (EListLit))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pushSiteGoal") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "GKBinopSite")) (EApp (EVar "Ref") (EVar "innerNone"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PendingEntry") (EVar "method")) (EVar "dref")) (EVar "m")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (EApp (EApp (EVar "SKPredicateOp") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentImplBody") "value")) (EVar "predicate"))) (EFieldAccess (EVar "mctx") "mcLoc")) (EVar "scope")) (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit))))) (DoExpr (ELit LUnit))) (EApp (EApp (EApp (EApp (EVar "pushArithGoal") (EVar "mctx")) (EVar "dref")) (EVar "m")) (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "recordBinopSite") (EVar "mctx")) (EVar "op")) (EVar "dref")) (EVar "m")))))
(DTypeSig true "binopMethod" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "binopMethod" ((PLit (LString "=="))) (EApp (EVar "Some") (ELit (LString "eq"))))
(DFunDef false "binopMethod" ((PLit (LString "/="))) (EApp (EVar "Some") (ELit (LString "eq"))))
(DFunDef false "binopMethod" ((PLit (LString "<"))) (EApp (EVar "Some") (ELit (LString "lt"))))
(DFunDef false "binopMethod" ((PLit (LString ">"))) (EApp (EVar "Some") (ELit (LString "gt"))))
(DFunDef false "binopMethod" ((PLit (LString "<="))) (EApp (EVar "Some") (ELit (LString "lte"))))
(DFunDef false "binopMethod" ((PLit (LString ">="))) (EApp (EVar "Some") (ELit (LString "gte"))))
(DFunDef false "binopMethod" ((PLit (LString "++"))) (EApp (EVar "Some") (ELit (LString "append"))))
(DFunDef false "binopMethod" (PWild) (EVar "None"))
(DTypeSig true "unopMethod" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "unopMethod" ((PLit (LString "-"))) (EApp (EVar "Some") (ELit (LString "negate"))))
(DFunDef false "unopMethod" (PWild) (EVar "None"))
(DTypeSig true "recordUnopSite" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyCon "Mono") (TyCon "Unit"))))))
(DFunDef false "recordUnopSite" ((PVar "mctx") (PVar "op") (PVar "dref") (PVar "m")) (EMatch (EApp (EVar "unopMethod") (EVar "op")) (arm (PCon "Some" (PVar "method")) () (EBlock (DoLet false false (PVar "inImpl") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentImplBody") "value")) (DoLet false false (PVar "kind") (EIf (EApp (EApp (EVar "builtinClassPresent") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "BNum")) (EApp (EApp (EVar "SKPredicateOp") (EVar "inImpl")) (ERecordCreate "ClassPredicate" ((fa "predicateInterface" (EApp (EApp (EVar "builtinIfaceRef") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "BNum"))) (fa "predicateArguments" (EListLit (EVar "m")))))) (EApp (EVar "SKOp") (EVar "inImpl")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pushSiteGoal") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "GKUnopSite")) (EApp (EVar "Ref") (EVar "innerNone"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PendingEntry") (EVar "method")) (EVar "dref")) (EVar "m")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (EVar "kind")) (EFieldAccess (EVar "mctx") "mcLoc")) (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit))))))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig true "recordNegatedLitRange" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Expr") (TyCon "Unit")))))
(DFunDef false "recordNegatedLitRange" ((PVar "mctx") (PVar "t") (PCon "ELoc" PWild (PVar "e"))) (EApp (EApp (EApp (EVar "recordNegatedLitRange") (EVar "mctx")) (EVar "t")) (EVar "e")))
(DFunDef false "recordNegatedLitRange" ((PVar "mctx") (PVar "t") (PCon "ENumLit" (PVar "n") PWild PWild)) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitRanges") "value") (arm (PCons (PTuple PWild (PVar "m") (PVar "loc")) (PVar "rest")) ((GBool (EBinOp "==" (EVar "m") (EVar "n")))) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitRanges")) (EBinOp "::" (ETuple (EVar "t") (EApp (EVar "negateLiteral") (EVar "n")) (EVar "loc")) (EVar "rest")))) (arm PWild () (EApp (EApp (EApp (EVar "recordNumlitRange") (EVar "mctx")) (EVar "t")) (EApp (EVar "negateLiteral") (EVar "n"))))))
(DFunDef false "recordNegatedLitRange" ((PVar "mctx") (PVar "t") (PCon "EWideLit" PWild PWild PWild (PVar "lx"))) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "wideLitRanges") "value") (arm (PCons (PTuple PWild (PVar "l") (PVar "hi") (PVar "lo") PWild (PVar "loc")) (PVar "rest")) ((GBool (EBinOp "==" (EVar "l") (EVar "lx")))) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "wideLitRanges")) (EBinOp "::" (ETuple (EVar "t") (EVar "lx") (EVar "hi") (EVar "lo") (EVar "True") (EVar "loc")) (EVar "rest")))) (arm PWild () (ELit LUnit))))
(DFunDef false "recordNegatedLitRange" ((PVar "mctx") PWild PWild) (ELit LUnit))
(DTypeSig true "recordIfaceObligation" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "BuiltinClass") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "recordIfaceObligation" ((PVar "mctx") (PVar "c") (PVar "lt")) (EIf (EApp (EApp (EVar "builtinClassPresent") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushPendingObl") (EVar "mctx")) (EApp (EApp (EVar "builtinIfaceRef") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "c"))) (EListLit (ELit (LString "a")))) (EApp (EVar "TyVar") (ELit (LString "a")))) (EMethodRef "lt")) (EListLit)) (EVar "POperator")) (EFieldAccess (EVar "mctx") "mcLoc")) (EIf (EVar "otherwise") (ELit LUnit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "inferNumLit" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Int") (TyFun (TyCon "EvId") (TyCon "Mono")))))
(DFunDef false "inferNumLit" ((PVar "env") (PVar "n") (PVar "ev")) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EApp (EApp (EVar "inferNumLitVar") (EVar "env")) (EVar "n")) (EApp (EApp (EVar "siteFloatCell") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "ev"))) (EApp (EApp (EVar "siteRouteCell") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "ev")))) (DoExpr (EApp (EApp (EApp (EVar "recordNumlitRange") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "a")) (EVar "n"))) (DoExpr (EVar "a"))))
(DTypeSig true "inferWideLit" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "EvId") (TyFun (TyCon "String") (TyCon "Mono")))))))
(DFunDef false "inferWideLit" ((PVar "env") (PVar "hi") (PVar "lo") (PVar "ev") (PVar "lx")) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EApp (EApp (EVar "inferNumLitVar") (EVar "env")) (EVar "lo")) (EApp (EVar "Ref") (EVar "None"))) (EApp (EApp (EVar "siteRouteCell") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "ev")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "wideLitRanges")) (EBinOp "::" (ETuple (EVar "a") (EVar "lx") (EVar "hi") (EVar "lo") (EVar "False") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "wideLitRanges") "value")))) (DoExpr (EVar "a"))))
(DTypeSig false "inferNumLitVar" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Float"))) (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyCon "Mono"))))))
(DFunDef false "inferNumLitVar" ((PVar "env") (PVar "n") (PVar "fref") (PVar "dref")) (EIf (EApp (EApp (EVar "builtinClassPresent") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "BNum")) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "numLitFromIntAnchorRef") "value") (arm (PCon "None") () (EApp (EApp (EApp (EVar "inferNumLitBare") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "n")) (EVar "fref"))) (arm (PCon "Some" (PVar "anchor")) () (EBlock (DoLet false false (PVar "fromIntTy") (EApp (EApp (EApp (EVar "inferNumLitMethod") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "anchor")) (EVar "dref"))) (DoLet false false (PVar "a") (EApp (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EFieldAccess (EVar "env") "teDyn")) (EVar "fromIntTy")) (EApp (EApp (EApp (EVar "TFun") (EApp (EVar "tconBuiltin") (ELit (LString "Int")))) (EApp (EApp (EVar "openRow") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (EVar "a")))) (DoExpr (EApp (EApp (EVar "pushNumlit") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ETuple (EVar "a") (EVar "fref") (EVar "n") (EVar "dref")))) (DoExpr (EApp (EApp (EVar "recordNumlitLoc") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "a"))) (DoExpr (EVar "a"))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "inferNumLitBare") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "n")) (EVar "fref")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "inferNumLitMethod" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodSchemeRow") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyCon "Mono")))))
(DFunDef false "inferNumLitMethod" ((PVar "mctx") (PVar "anchor") (PVar "tagRef")) (EBlock (DoLet false false (PVar "inst") (EApp (EApp (EVar "instantiateTracked") (EVar "mctx")) (EFieldAccess (EVar "anchor") "msrScheme"))) (DoLet false false (PVar "occurrence") (EApp (EVar "fst") (EVar "inst"))) (DoLet false false (PVar "predicate") (ERecordCreate "ClassPredicate" ((fa "predicateInterface" (EFieldAccess (EVar "anchor") "msrIface")) (fa "predicateArguments" (EApp (EApp (EApp (EVar "dispatchMonosOf") (EFieldAccess (EVar "anchor") "msrTyparams")) (EFieldAccess (EVar "anchor") "msrType")) (EVar "occurrence")))))) (DoLet false false (PVar "origin") (EFieldAccess (EVar "mctx") "mcLoc")) (DoLet false false (PVar "scope") (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteNumericPredicateTrace") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "NPTProduced")) (EVar "predicate")) (EVar "scope")) (EVar "origin")) (EVar "None")) (EVar "None")) (EListLit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordMethodDictsFromSlots") (EVar "mctx")) (EFieldAccess (EVar "anchor") "msrMethodSlots")) (EApp (EVar "Ref") (EListLit))) (EApp (EVar "Ref") (EVar "innerNone"))) (EApp (EVar "snd") (EVar "inst")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordNumLitObligationGuarded") (EVar "mctx")) (EVar "anchor")) (EVar "predicate")) (EVar "occurrence")) (EVar "origin")) (EVar "scope"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordNumLitSite") (EVar "mctx")) (EVar "predicate")) (EVar "tagRef")) (EVar "occurrence")) (EVar "origin")) (EVar "scope")))))
(DTypeSig false "inferNumLitBare" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Float"))) (TyCon "Mono")))))
(DFunDef false "inferNumLitBare" ((PVar "mctx") (PVar "n") (PVar "fref")) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit))) (DoLet false false (PVar "predicate") (ERecordCreate "ClassPredicate" ((fa "predicateInterface" (EApp (EApp (EVar "builtinIfaceRef") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "BNum"))) (fa "predicateArguments" (EListLit (EVar "a")))))) (DoLet false false (PVar "origin") (EFieldAccess (EVar "mctx") "mcLoc")) (DoLet false false (PVar "scope") (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteNumericPredicateTrace") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "NPTProduced")) (EVar "predicate")) (EVar "scope")) (EVar "origin")) (EVar "None")) (EVar "None")) (EListLit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "pushNumLitObl") (EVar "mctx")) (EVar "predicate")) (EVar "a")) (EVar "origin")) (EVar "scope"))) (DoExpr (EApp (EApp (EVar "pushNumlit") (EFieldAccess (EVar "mctx") "mcGraph")) (ETuple (EVar "a") (EVar "fref") (EVar "n") (EApp (EVar "Ref") (EVar "RNone"))))) (DoExpr (EApp (EApp (EVar "recordNumlitLoc") (EVar "mctx")) (EVar "a"))) (DoExpr (EVar "a"))))
(DTypeSig false "recordNumlitRange" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Int") (TyCon "Unit")))))
(DFunDef false "recordNumlitRange" ((PVar "mctx") (PVar "a") (PVar "n")) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitRanges")) (EBinOp "::" (ETuple (EVar "a") (EVar "n") (EFieldAccess (EVar "mctx") "mcLoc")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitRanges") "value"))))
(DTypeSig false "recordNumlitLoc" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyCon "Unit"))))
(DFunDef false "recordNumlitLoc" ((PVar "mctx") (PVar "a")) (EMatch (EFieldAccess (EVar "mctx") "mcLoc") (arm (PCon "Some" (PVar "l")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitVarLocs")) (EBinOp "::" (ETuple (EVar "a") (EVar "l")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitVarLocs") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitUntainted")) (EBinOp "::" (ETuple (EVar "a") (EVar "l")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitUntainted") "value")))))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig true "markNumlitOpTaint" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyCon "Unit"))))
(DFunDef false "markNumlitOpTaint" ((PVar "mctx") (PVar "m")) (EBlock (DoLet false false (PVar "id") (EApp (EVar "rootIdOf") (EVar "m"))) (DoExpr (EIf (EBinOp "||" (EBinOp "<" (EVar "id") (ELit (LInt 0))) (EApp (EVar "not") (EApp (EApp (EVar "anyRootMatch") (EVar "id")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitUntainted") "value")))) (ELit LUnit) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitUntainted")) (EApp (EApp (EApp (EVar "taintAndDrop") (EVar "mctx")) (EVar "id")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitUntainted") "value")))))))
(DTypeSig false "anyRootMatch" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Loc"))) (TyCon "Bool"))))
(DFunDef false "anyRootMatch" (PWild (PList)) (EVar "False"))
(DFunDef false "anyRootMatch" ((PVar "id") (PCons (PTuple (PVar "v") PWild) (PVar "rest"))) (EBinOp "||" (EApp (EApp (EVar "sameRootId") (EVar "id")) (EVar "v")) (EApp (EApp (EVar "anyRootMatch") (EVar "id")) (EVar "rest"))))
(DTypeSig false "taintAndDrop" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Loc"))) (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Loc")))))))
(DFunDef false "taintAndDrop" ((PVar "mctx") PWild (PList)) (EListLit))
(DFunDef false "taintAndDrop" ((PVar "mctx") (PVar "id") (PCons (PTuple (PVar "v") (PVar "l")) (PVar "rest"))) (EIf (EApp (EApp (EVar "sameRootId") (EVar "id")) (EVar "v")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitOpLocs")) (EBinOp "::" (EVar "l") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitOpLocs") "value")))) (DoExpr (EApp (EApp (EApp (EVar "taintAndDrop") (EVar "mctx")) (EVar "id")) (EVar "rest")))) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "v") (EVar "l")) (EApp (EApp (EApp (EVar "taintAndDrop") (EVar "mctx")) (EVar "id")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "instantiateVarTrackedId" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Scheme") (TyCon "Mono"))))))
(DFunDef false "instantiateVarTrackedId" ((PVar "env") (PVar "x") (PVar "id") (PVar "s")) (EBlock (DoLet false false (PVar "inst") (EApp (EApp (EApp (EApp (EVar "instantiateVarTrackedWithSubst") (EVar "env")) (EVar "x")) (EVar "id")) (EVar "s"))) (DoExpr (EFieldAccess (EVar "inst") "mtiBody"))))
(DTypeSig true "instantiateVarTrackedWithSubst" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Scheme") (TyCon "MethodTrackedInstantiation"))))))
(DFunDef false "instantiateVarTrackedWithSubst" ((PVar "env") (PVar "x") (PVar "id") (PVar "s")) (EMatch (EApp (EApp (EVar "bindingDeclared") (EVar "env")) (EVar "x")) (arm (PCon "Some" PWild) () (EBlock (DoLet false false (PVar "inst") (EApp (EApp (EApp (EVar "instantiateValueTracked") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EVar "s"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "bindingDeclaredAt") (EVar "env")) (EVar "x")) (EVar "inst")) (arm (PCon "Some" (PVar "dc")) () (EApp (EApp (EApp (EVar "recordDeclaredBindingCall") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "dc")) (EFieldAccess (EFieldAccess (EVar "inst") "mtiSubstitution") "misTypeSubst"))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EVar "inst")))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "instantiateLegacyVarTracked") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EVar "id")) (EVar "s")))))
(DTypeSig false "recordImplObligation" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyCon "Mono"))))))
(DFunDef false "recordImplObligation" ((PVar "mctx") (PVar "x") (PVar "mono") (PVar "omitted")) (EIf (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "x")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "definerShadowNamesRef") "value")) (EApp (EApp (EVar "omHasKey") (EVar "x")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "standaloneValuesRef") "value"))) (EVar "mono") (EIf (EBinOp ">=" (EApp (EVar "listLen") (EApp (EApp (EVar "methodAdmittedHere") (EVar "mctx")) (EVar "x"))) (ELit (LInt 2))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "pushAdmittedOccObl") (EVar "mctx")) (EVar "x")) (EVar "mono"))) (DoExpr (EVar "mono"))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "methodEntryHere") (EVar "mctx")) (EVar "x")) (arm (PCon "None") () (EVar "mono")) (arm (PCon "Some" (PTuple (PVar "iface") (PVar "typarams") (PVar "mty") PWild)) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushPendingObl") (EVar "mctx")) (EVar "iface")) (EVar "typarams")) (EVar "mty")) (EVar "mono")) (EVar "omitted")) (EVar "PMethodOcc")) (EFieldAccess (EVar "mctx") "mcLoc"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordMethodLevelObls") (EVar "mctx")) (EVar "typarams")) (EVar "mty")) (EVar "mono"))) (DoExpr (EVar "mono"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "pushAdmittedOccObl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "pushAdmittedOccObl" ((PVar "mctx") (PVar "name") (PVar "mono")) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "admittedOccObls")) (EBinOp "::" (ETuple (EVar "name") (EVar "mono") (EFieldAccess (EVar "mctx") "mcLoc")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "admittedOccObls") "value"))))
(DTypeSig false "admittedSetOccurrence" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Scheme") (TyCon "Bool")))))
(DFunDef false "admittedSetOccurrence" ((PVar "env") (PVar "name") (PVar "s")) (EBinOp "&&" (EApp (EVar "not") (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "lookupLocalFlag") (EVar "env")) (EVar "name")) (EApp (EVar "isMonoScheme") (EVar "s"))) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "definerShadowNamesRef") "value"))) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "standaloneValuesRef") "value")))) (EBinOp ">=" (EApp (EVar "listLen") (EApp (EApp (EVar "methodAdmittedHere") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name"))) (ELit (LInt 2)))))
(DTypeSig true "recordMethodObligationGuarded" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Scheme") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyCon "Mono")))))))
(DFunDef false "recordMethodObligationGuarded" ((PVar "env") (PVar "name") (PVar "s") (PVar "mono") (PVar "omitted")) (EIf (EBinOp "||" (EApp (EApp (EVar "lookupLocalFlag") (EVar "env")) (EVar "name")) (EApp (EVar "isMonoScheme") (EVar "s"))) (EVar "mono") (EApp (EApp (EApp (EApp (EVar "recordImplObligation") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "mono")) (EVar "omitted"))))
(DTypeSig false "exactReturnRow" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Scheme") (TyApp (TyCon "Option") (TyCon "MethodSchemeRow"))))))
(DFunDef false "exactReturnRow" ((PVar "env") (PVar "name") (PVar "scheme")) (EMatch (EApp (EApp (EVar "lookupMethodRow") (EVar "env")) (EVar "name")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "row")) () (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "lookupLocalFlag") (EVar "env")) (EVar "name")) (EApp (EVar "isMonoScheme") (EVar "scheme"))) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "definerShadowNamesRef") "value"))) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "standaloneValuesRef") "value"))) (EApp (EVar "isSome") (EApp (EApp (EVar "Scopes.enclosingDefaultBody") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (EApp (EApp (EVar "captureScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))))) (EBinOp ">=" (EApp (EVar "listLen") (EApp (EApp (EVar "methodAdmittedHere") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name"))) (ELit (LInt 2)))) (EVar "None") (EApp (EVar "Some") (EVar "row"))))))
(DTypeSig true "recordMethodObligationOwned" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Scheme") (TyFun (TyCon "Mono") (TyFun (TyCon "MethodInstantiationSubst") (TyFun (TyApp (TyCon "Option") (TyCon "EvId")) (TyCon "Mono"))))))))
(DFunDef false "recordMethodObligationOwned" ((PVar "env") (PVar "name") (PVar "scheme") (PVar "occurrence") (PVar "subst") (PVar "goalEv")) (EMatch (EApp (EApp (EApp (EVar "exactReturnRow") (EVar "env")) (EVar "name")) (EVar "scheme")) (arm (PCon "Some" (PVar "row")) () (EBlock (DoLet false false (PVar "request") (EApp (EApp (EApp (EApp (EApp (EVar "methodReturnRequest") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "row")) (EVar "occurrence")) (EVar "subst")) (EVar "goalEv"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordMethodLevelSlotsOwned") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "row")) (EFieldAccess (EVar "subst") "misTypeSubst")) (EFieldAccess (EVar "request") "mrrLoc")) (EFieldAccess (EVar "request") "mrrScope"))) (DoExpr (EApp (EApp (EVar "recordExactMethodObligation") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "request"))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "recordMethodObligationGuarded") (EVar "env")) (EVar "name")) (EVar "scheme")) (EVar "occurrence")) (EListLit)))))
(DTypeSig false "recordExactMethodObligation" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodReturnRequest") (TyCon "Mono"))))
(DFunDef false "recordExactMethodObligation" ((PVar "mctx") (PVar "request")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "noteMethodReturnTrace") (EVar "mctx")) (EVar "MRTProduced")) (EVar "request")) (EVar "None")) (EListLit))) (DoExpr (EApp (EApp (EVar "pushExactReturnObl") (EVar "mctx")) (EVar "request"))) (DoExpr (EFieldAccess (EVar "request") "mrrOccurrence"))))
(DTypeSig false "recordMethodLevelSlotsOwned" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodSchemeRow") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ScopeId") (TyCon "Unit")))))))
(DFunDef false "recordMethodLevelSlotsOwned" ((PVar "mctx") (PVar "row") (PVar "subst") (PVar "loc") (PVar "scope")) (EApp (EApp (EApp (EApp (EVar "recordInstantiatedMethodLevelSlots") (EVar "mctx")) (EApp (EApp (EApp (EVar "instantiateMethodPredicateSlots") (EFieldAccess (EVar "mctx") "mcGraph")) (EFieldAccess (EVar "row") "msrMethodSlots")) (EVar "subst"))) (EVar "loc")) (EVar "scope")))
(DTypeSig false "recordInstantiatedMethodLevelSlots" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "PredicateSlot")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ScopeId") (TyCon "Unit"))))))
(DFunDef false "recordInstantiatedMethodLevelSlots" ((PVar "mctx") (PList) PWild PWild) (ELit LUnit))
(DFunDef false "recordInstantiatedMethodLevelSlots" ((PVar "mctx") (PCons (PVar "slot") (PVar "rest")) (PVar "loc") (PVar "scope")) (EBlock (DoExpr (EMatch (EFieldAccess (EVar "slot") "psArgs") (arm (PCon "PSArgsUnknown") () (ELit LUnit)) (arm (PCon "PSArgsKnown" (PVar "args")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordOblAt") (EVar "mctx")) (ERecordCreate "Predicate" ((fa "iface" (EFieldAccess (EVar "slot") "psIface")) (fa "args" (EVar "args"))))) (ELit (LInt 0))) (EVar "PMethodLevel")) (EVar "loc")) (EVar "scope"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordInstantiatedMethodLevelSlots") (EVar "mctx")) (EVar "rest")) (EVar "loc")) (EVar "scope")))))
(DTypeSig false "recordNumLitObligationGuarded" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodSchemeRow") (TyFun (TyCon "ClassPredicate") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ScopeId") (TyCon "Mono"))))))))
(DFunDef false "recordNumLitObligationGuarded" ((PVar "mctx") (PVar "anchor") (PVar "predicate") (PVar "occurrence") (PVar "origin") (PVar "scope")) (EIf (EApp (EVar "isMonoScheme") (EFieldAccess (EVar "anchor") "msrScheme")) (EVar "occurrence") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordNumLitImplObligation") (EVar "mctx")) (EVar "anchor")) (EVar "predicate")) (EVar "occurrence")) (EVar "origin")) (EVar "scope"))))
(DTypeSig false "recordNumLitImplObligation" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodSchemeRow") (TyFun (TyCon "ClassPredicate") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ScopeId") (TyCon "Mono"))))))))
(DFunDef false "recordNumLitImplObligation" ((PVar "mctx") (PVar "anchor") (PVar "predicate") (PVar "occurrence") (PVar "origin") (PVar "scope")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "pushNumLitObl") (EVar "mctx")) (EVar "predicate")) (EVar "occurrence")) (EVar "origin")) (EVar "scope"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordMethodLevelObls") (EVar "mctx")) (EFieldAccess (EVar "anchor") "msrTyparams")) (EFieldAccess (EVar "anchor") "msrType")) (EVar "occurrence"))) (DoExpr (EVar "occurrence"))))
(DTypeSig false "recordMethodLevelObls" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyFun (TyCon "Mono") (TyCon "Unit"))))))
(DFunDef false "recordMethodLevelObls" ((PVar "mctx") (PVar "typarams") (PVar "mty") (PVar "occMono")) (EBlock (DoLet false false (PVar "slots") (EApp (EApp (EVar "methodLevelConstraintSlots") (EVar "typarams")) (EVar "mty"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "slots")) (ELit LUnit) (EMatch (EApp (EApp (EVar "matchTyMono") (EApp (EVar "stripLeadingMethodConstraints") (EVar "mty"))) (EVar "occMono")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "subst")) () (EApp (EApp (EApp (EVar "recordMethodLevelSlotObls") (EVar "mctx")) (EVar "slots")) (EVar "subst"))))))))
(DTypeSig false "recordMethodLevelSlotObls" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Constraint")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyCon "Unit")))))
(DFunDef false "recordMethodLevelSlotObls" ((PVar "mctx") (PList) PWild) (ELit LUnit))
(DFunDef false "recordMethodLevelSlotObls" ((PVar "mctx") (PCons (PVar "c") (PVar "rest")) (PVar "subst")) (EBlock (DoExpr (EIf (EApp (EApp (EVar "allList") (ELam ((PVar "v")) (EApp (EVar "isSome") (EApp (EApp (EVar "lookupAssoc") (EVar "v")) (EVar "subst"))))) (EApp (EVar "constraintVarNames") (EVar "c"))) (EApp (EApp (EApp (EApp (EApp (EVar "recordObl") (EVar "mctx")) (ERecordCreate "Predicate" ((fa "iface" (ERecordCreate "IfaceRef" ((fa "irName" (EApp (EVar "constraintIface") (EVar "c"))) (fa "irOrigin" (EFieldAccess (EVar "c") "constraintOrigin"))))) (fa "args" (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "fromAstType") (EVar "mctx")) (EVar "subst"))) (EFieldAccess (EVar "c") "constraintArgs")))))) (ELit (LInt 0))) (EVar "PMethodLevel")) (EFieldAccess (EVar "mctx") "mcLoc")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "recordMethodLevelSlotObls") (EVar "mctx")) (EVar "rest")) (EVar "subst")))))
(DTypeSig true "recordSelectedStandaloneRoutes" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "ShadowDicts") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Ref") (TyCon "Route")) (TyApp (TyCon "Ref") (TyCon "Inner")))) (TyFun (TyCon "Mono") (TyCon "Unit")))))))
(DFunDef false "recordSelectedStandaloneRoutes" ((PVar "mctx") PWild PWild (PList) PWild) (ELit LUnit))
(DFunDef false "recordSelectedStandaloneRoutes" ((PVar "mctx") (PVar "mname") (PVar "dicts") (PCons (PTuple (PVar "r") (PVar "inner")) (PVar "rest")) (PVar "tx")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "pushSiteGoal") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "GKRLocalSite")) (EVar "inner")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PendingEntry") (EVar "mname")) (EVar "r")) (EVar "tx")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (EApp (EApp (EApp (EApp (EApp (EVar "SKRLocal") (EApp (EVar "routeLocalSym") (EUnOp "!" (EVar "r")))) (EVar "True")) (EFieldAccess (EVar "dicts") "sdMonos")) (EFieldAccess (EVar "dicts") "sdIfaces")) (EFieldAccess (EVar "dicts") "sdArgVecs"))) (EFieldAccess (EVar "mctx") "mcLoc")) (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordSelectedStandaloneRoutes") (EVar "mctx")) (EVar "mname")) (EVar "dicts")) (EVar "rest")) (EVar "tx")))))
(DTypeSig true "maybeStandaloneValueMono" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Mono")))))
(DFunDef false "maybeStandaloneValueMono" ((PVar "env") (PVar "name")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "value")) (EBlock (DoExpr (EApp (EApp (EVar "rejectAdmittedValueOccurrence") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name"))) (DoExpr (EFieldAccess (EFieldAccess (EApp (EApp (EApp (EApp (EApp (EVar "instantiateStandaloneOccurrence") (EVar "env")) (EVar "name")) (ELit (LString ""))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EVar "value")) "svoInstance") "mtiBody"))))) (EApp (EApp (EVar "standaloneValueBinding") (EVar "env")) (EVar "name"))))
(DTypeSig true "instantiateStandaloneOccurrence" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ValueScheme") (TyCon "SelectedValueOccurrence")))))))
(DFunDef false "instantiateStandaloneOccurrence" ((PVar "outer") (PVar "name") (PVar "sym") (PVar "origin") (PVar "value")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EVar "envAt") (EVar "origin")) (EVar "outer"))) (DoLet false false (PVar "inst") (EApp (EApp (EApp (EVar "instantiateValueTracked") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EFieldAccess (EVar "value") "vsScheme"))) (DoLet false false (PVar "declared") (EApp (EApp (EApp (EVar "declaredEffectsAt") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "inst")) (EFieldAccess (EVar "value") "vsDeclared"))) (DoExpr (EMatch (EVar "declared") (arm (PCon "Some" (PVar "dc")) () (EApp (EApp (EApp (EVar "recordDeclaredBindingCall") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "dc")) (EFieldAccess (EFieldAccess (EVar "inst") "mtiSubstitution") "misTypeSubst"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "recordShadowStandaloneObls") (EVar "env")) (EVar "name")) (EFieldAccess (EFieldAccess (EVar "inst") "mtiSubstitution") "misTypeSubst"))))) (DoLet false false (PVar "key") (EIf (EBinOp "==" (EVar "sym") (ELit (LString ""))) (EVar "name") (EVar "sym"))) (DoLet false false (PVar "dc") (EApp (EApp (EVar "optionOr") (EApp (EApp (EApp (EVar "shadowDeclaredFor") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "key"))) (EVar "declared"))) (DoExpr (ERecordCreate "SelectedValueOccurrence" ((fa "svoScheme" (EFieldAccess (EVar "value") "vsScheme")) (fa "svoInstance" (EVar "inst")) (fa "svoDicts" (EApp (EApp (EApp (EApp (EVar "shadowStandaloneDictSlots") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EFieldAccess (EVar "dc") "cdSlots")) (EFieldAccess (EVar "dc") "cdArgs")) (EFieldAccess (EFieldAccess (EVar "inst") "mtiSubstitution") "misTypeSubst"))))))))
(DTypeSig true "constrainedSigNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "constrainedSigNames" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "constrainedSigName")) (EVar "prog")))
(DTypeSig false "noDictHook" (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "Unit"))))
(DFunDef false "noDictHook" (PWild PWild) (ELit LUnit))
(DTypeSig false "mintDictAt" (TyFun (TyCon "ModuleCtx") (TyFun (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "Unit"))) (TyFun (TyCon "String") (TyCon "Expr")))))
(DFunDef false "mintDictAt" ((PVar "mctx") (PVar "onDict") (PVar "n")) (EBlock (DoLet false false (PVar "ev") (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "onDict") (EVar "n")) (EVar "ev"))) (DoExpr (EApp (EApp (EVar "EDictAt") (EVar "n")) (EVar "ev")))))
(DTypeSig false "prePassDeclScoped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyCon "Decl") (TyCon "Decl")))))
(DFunDef false "prePassDeclScoped" ((PVar "mctx") (PVar "rw") (PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "ps") (PVar "e") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "n")) (EVar "ps")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EApp (EVar "boundOfList") (EApp (EVar "patVarsListTc") (EVar "ps")))) (EVar "e"))) (EVar "site")) (EVar "bid")))
(DFunDef false "prePassDeclScoped" ((PVar "mctx") (PVar "rw") (PAs "d" (PRec "DInterface" ((rf "methods" None)) true))) (EVariantUpdate "DInterface" (EVar "d") ((fa "methods" (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "prePassIfaceMethodScoped") (EVar "mctx")) (EVar "rw"))) (EVar "methods"))))))
(DFunDef false "prePassDeclScoped" ((PVar "mctx") (PVar "rw") (PAs "d" (PRec "DImpl" ((rf "methods" None)) true))) (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "prePassImplMethodScoped") (EVar "mctx")) (EVar "rw"))) (EVar "methods"))))))
(DFunDef false "prePassDeclScoped" ((PVar "mctx") (PVar "rw") (PCon "DProp" (PVar "pub") (PVar "name") (PVar "params") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DProp") (EVar "pub")) (EVar "name")) (EVar "params")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EApp (EVar "boundOfList") (EApp (EVar "propParamNamesTc") (EVar "params")))) (EVar "body"))))
(DFunDef false "prePassDeclScoped" ((PVar "mctx") (PVar "rw") (PCon "DTest" (PVar "pub") (PVar "name") (PVar "body"))) (EApp (EApp (EApp (EVar "DTest") (EVar "pub")) (EVar "name")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "omEmpty")) (EVar "body"))))
(DFunDef false "prePassDeclScoped" ((PVar "mctx") (PVar "rw") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EApp (EVar "prePassDeclScoped") (EVar "mctx")) (EVar "rw")) (EVar "d"))))
(DFunDef false "prePassDeclScoped" ((PVar "mctx") (PVar "rw") (PCon "DLetGroup" (PVar "pub") (PVar "binds"))) (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "prePassLetBindScoped") (EVar "mctx")) (EVar "rw"))) (EVar "binds"))))
(DFunDef false "prePassDeclScoped" ((PVar "mctx") PWild (PVar "d")) (EVar "d"))
(DTypeSig false "prePassLetBindScoped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyCon "LetBind") (TyCon "LetBind")))))
(DFunDef false "prePassLetBindScoped" ((PVar "mctx") (PVar "rw") (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "prePassFunClauseScoped") (EVar "mctx")) (EVar "rw"))) (EVar "clauses"))) (EVar "site")) (EVar "bid")))
(DTypeSig false "prePassFunClauseScoped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyCon "FunClause") (TyCon "FunClause")))))
(DFunDef false "prePassFunClauseScoped" ((PVar "mctx") (PVar "rw") (PCon "FunClause" (PVar "ps") (PVar "e"))) (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EApp (EVar "boundOfList") (EApp (EVar "patVarsListTc") (EVar "ps")))) (EVar "e"))))
(DTypeSig false "prePassIfaceMethodScoped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyCon "IfaceMethod") (TyCon "IfaceMethod")))))
(DFunDef false "prePassIfaceMethodScoped" ((PVar "mctx") PWild (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "None") (PVar "mloc"))) (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EVar "None")) (EVar "mloc")))
(DFunDef false "prePassIfaceMethodScoped" ((PVar "mctx") (PVar "rw") (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "Some" (PCon "MethodDefault" (PVar "ps") (PVar "e"))) (PVar "mloc"))) (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EApp (EVar "Some") (EApp (EApp (EVar "MethodDefault") (EVar "ps")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EApp (EVar "boundOfList") (EApp (EVar "patVarsListTc") (EVar "ps")))) (EVar "e"))))) (EVar "mloc")))
(DTypeSig false "prePassImplMethodScoped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod")))))
(DFunDef false "prePassImplMethodScoped" ((PVar "mctx") (PVar "rw") (PCon "ImplMethod" (PVar "n") (PVar "ps") (PVar "e"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "n")) (EVar "ps")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EApp (EVar "boundOfList") (EApp (EVar "patVarsListTc") (EVar "ps")))) (EVar "e"))))
(DTypeSig false "boundInsert" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "String")))))
(DFunDef false "boundInsert" ((PList) (PVar "b")) (EVar "b"))
(DFunDef false "boundInsert" ((PCons (PVar "n") (PVar "rest")) (PVar "b")) (EApp (EApp (EVar "boundInsert") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit (LString ""))) (EVar "b"))))
(DTypeSig false "localAbsCandidate" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "localAbsCandidate" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "localAbsCandidate") (EVar "e")))
(DFunDef false "localAbsCandidate" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "localAbsCandidate") (EVar "e")))
(DFunDef false "localAbsCandidate" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "localAbsCandidate") (EVar "e")))
(DFunDef false "localAbsCandidate" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EVar "localAbsCandidate") (EVar "e")))
(DFunDef false "localAbsCandidate" ((PCon "ELit" PWild)) (EVar "True"))
(DFunDef false "localAbsCandidate" ((PCon "EVar" PWild)) (EVar "True"))
(DFunDef false "localAbsCandidate" ((PCon "EVarId" PWild PWild)) (EVar "True"))
(DFunDef false "localAbsCandidate" ((PCon "EMethodAt" PWild PWild PWild)) (EVar "True"))
(DFunDef false "localAbsCandidate" ((PCon "EDictAt" PWild PWild)) (EVar "True"))
(DFunDef false "localAbsCandidate" ((PCon "EMethodRef" PWild)) (EVar "True"))
(DFunDef false "localAbsCandidate" ((PCon "ELam" PWild PWild)) (EVar "True"))
(DFunDef false "localAbsCandidate" ((PCon "ETuple" (PVar "es"))) (EApp (EApp (EVar "allList") (EVar "localAbsCandidate")) (EVar "es")))
(DFunDef false "localAbsCandidate" ((PCon "EListLit" (PVar "es"))) (EApp (EApp (EVar "allList") (EVar "localAbsCandidate")) (EVar "es")))
(DFunDef false "localAbsCandidate" ((PAs "app" (PCon "EApp" PWild PWild))) (EApp (EVar "localAbsCtorSpine") (EVar "app")))
(DFunDef false "localAbsCandidate" ((PCon "ERecordCreate" PWild (PVar "fs"))) (EApp (EApp (EVar "allList") (ELam ((PVar "fa")) (EMatch (EVar "fa") (arm (PCon "FieldAssign" PWild (PVar "e")) () (EApp (EVar "localAbsCandidate") (EVar "e")))))) (EVar "fs")))
(DFunDef false "localAbsCandidate" (PWild) (EVar "False"))
(DTypeSig false "localAbsCtorSpine" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "localAbsCtorSpine" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "localAbsCtorSpine") (EVar "e")))
(DFunDef false "localAbsCtorSpine" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "localAbsCtorSpine") (EVar "e")))
(DFunDef false "localAbsCtorSpine" ((PCon "EApp" (PVar "f") (PVar "x"))) (EBinOp "&&" (EApp (EVar "localAbsCtorSpine") (EVar "f")) (EApp (EVar "localAbsCandidate") (EVar "x"))))
(DFunDef false "localAbsCtorSpine" ((PCon "EVar" (PVar "name"))) (EApp (EVar "ctorHeadShaped") (EVar "name")))
(DFunDef false "localAbsCtorSpine" ((PCon "EVarId" (PVar "name") PWild)) (EApp (EVar "ctorHeadShaped") (EVar "name")))
(DFunDef false "localAbsCtorSpine" (PWild) (EVar "False"))
(DTypeSig false "localAbsCandidateBind" (TyFun (TyCon "LetBind") (TyCon "Bool")))
(DFunDef false "localAbsCandidateBind" ((PCon "LetBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EVar "anyList") (EVar "localAbsCandidateClause")) (EVar "clauses")))
(DTypeSig false "localAbsCandidateClause" (TyFun (TyCon "FunClause") (TyCon "Bool")))
(DFunDef false "localAbsCandidateClause" ((PCon "FunClause" (PList) (PVar "body"))) (EApp (EVar "localAbsCandidate") (EVar "body")))
(DFunDef false "localAbsCandidateClause" ((PCon "FunClause" PWild PWild)) (EVar "True"))
(DTypeSig false "letPatRename" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyTuple (TyCon "Pat") (TyApp (TyCon "OrdMap") (TyCon "String"))))))))
(DFunDef false "letPatRename" ((PVar "gctx") (PCon "PVar" (PVar "x") (PVar "l") (PVar "bid")) (PVar "e1") (PVar "b")) (EIf (EBinOp "&&" (EApp (EVar "localAbsCandidate") (EVar "e1")) (EApp (EVar "not") (EApp (EVar "isLocalAbsName") (EVar "x")))) (EBlock (DoLet false false (PVar "fresh") (EApp (EApp (EVar "freshLocalAbsName") (EVar "gctx")) (EVar "x"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "PVar") (EVar "fresh")) (EVar "l")) (EVar "bid")) (EApp (EApp (EApp (EVar "omInsert") (EVar "x")) (EVar "fresh")) (EVar "b"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "letPatRename" ((PVar "gctx") (PVar "p") PWild (PVar "b")) (ETuple (EVar "p") (EApp (EApp (EVar "boundInsert") (EApp (EVar "patVarsTc") (EVar "p"))) (EVar "b"))))
(DTypeSig false "bindsRename" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "LetBind")) (TyApp (TyCon "OrdMap") (TyCon "String")))))))
(DFunDef false "bindsRename" ((PVar "gctx") (PList) (PVar "b")) (ETuple (EListLit) (EVar "b")))
(DFunDef false "bindsRename" ((PVar "gctx") (PCons (PAs "bind" (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (PVar "rest")) (PVar "b")) (EBlock (DoLet false false (PTuple (PVar "n2") (PVar "b1")) (EIf (EBinOp "&&" (EApp (EVar "localAbsCandidateBind") (EVar "bind")) (EApp (EVar "not") (EApp (EVar "isLocalAbsName") (EVar "n")))) (EBlock (DoLet false false (PVar "fresh") (EApp (EApp (EVar "freshLocalAbsName") (EVar "gctx")) (EVar "n"))) (DoExpr (ETuple (EVar "fresh") (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "fresh")) (EVar "b"))))) (ETuple (EVar "n") (EApp (EApp (EVar "boundInsert") (EListLit (EVar "n"))) (EVar "b"))))) (DoLet false false (PTuple (PVar "rest2") (PVar "b2")) (EApp (EApp (EApp (EVar "bindsRename") (EVar "gctx")) (EVar "rest")) (EVar "b1"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n2")) (EVar "clauses")) (EVar "site")) (EVar "bid")) (EVar "rest2")) (EVar "b2")))))
(DTypeSig false "boundOfList" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "String"))))
(DFunDef false "boundOfList" ((PVar "ns")) (EApp (EApp (EVar "boundInsert") (EVar "ns")) (EVar "omEmpty")))
(DTypeSig false "rewriteArgScoped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Expr") (TyCon "Expr"))))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PCon "ArgRw" (PVar "rp") (PVar "dn") (PVar "an") (PVar "sm") (PVar "onDict") (PVar "granted")) (PVar "bound") (PCon "EVar" (PVar "n"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "bound")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "bound")) (arm (PCon "Some" (PLit (LString ""))) () (EApp (EVar "EVar") (EVar "n"))) (arm (PCon "Some" (PVar "renamed")) () (EApp (EApp (EVar "EDictAt") (EVar "renamed")) (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit)))) (arm (PCon "None") () (EApp (EVar "EVar") (EVar "n")))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "sm")) (arm (PCon "Some" (PVar "bare")) () (EApp (EApp (EApp (EVar "EMethodAt") (EVar "bare")) (EVar "n")) (EApp (EApp (EVar "mintMethodCell") (EVar "mctx")) (EVar "n")))) (arm (PCon "None") () (EIf (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "rp")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "an"))) (EApp (EApp (EApp (EVar "EMethodAt") (EVar "n")) (ELit (LString ""))) (EApp (EApp (EVar "mintMethodCell") (EVar "mctx")) (ELit (LString "")))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "dn")) (EApp (EApp (EApp (EVar "mintDictAt") (EVar "mctx")) (EVar "onDict")) (EVar "n")) (EIf (EApp (EVar "granted") (EVar "n")) (EApp (EApp (EVar "mintGrantOnly") (EVar "mctx")) (EVar "n")) (EApp (EVar "EVar") (EVar "n"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PCon "ArgRw" PWild (PVar "dn") PWild PWild (PVar "onDict") PWild) PWild (PCon "EDictAt" (PVar "n") (PVar "ev"))) (EIf (EBinOp "&&" (EApp (EApp (EVar "isGrantOnlyEv") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ev")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "dn"))) (EBlock (DoExpr (EApp (EApp (EVar "unmarkGrantOnly") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ev"))) (DoExpr (EApp (EApp (EVar "onDict") (EVar "n")) (EVar "ev"))) (DoExpr (EApp (EApp (EVar "EDictAt") (EVar "n")) (EVar "ev")))) (EIf (EVar "otherwise") (EApp (EApp (EVar "EDictAt") (EVar "n")) (EVar "ev")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ELam" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "ELam") (EVar "ps")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EApp (EApp (EVar "boundInsert") (EApp (EVar "patVarsListTc") (EVar "ps"))) (EVar "bound"))) (EVar "body"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ELet" (PVar "m") (PVar "r") (PVar "p") (PVar "e1") (PVar "e2"))) (EBlock (DoLet false false (PTuple (PVar "p2") (PVar "after")) (EApp (EApp (EApp (EApp (EVar "letPatRename") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "p")) (EVar "e1")) (EVar "bound"))) (DoLet false false (PVar "b1") (EIf (EVar "r") (EVar "after") (EVar "bound"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "r")) (EVar "p2")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "b1")) (EVar "e1"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "after")) (EVar "e2"))))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ELetGroup" (PVar "binds") (PVar "e2"))) (EBlock (DoLet false false (PTuple (PVar "binds2") (PVar "bnd")) (EApp (EApp (EApp (EVar "bindsRename") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "binds")) (EVar "bound"))) (DoExpr (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "rewriteArgLetBind") (EVar "mctx")) (EVar "rw")) (EVar "bnd"))) (EVar "binds2"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bnd")) (EVar "e2"))))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EMatch" (PVar "e0") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "rewriteArgArm") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "arms"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EApp (EApp (EVar "rewriteArgStmts") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "stmts"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EDo" (PVar "d") (PVar "stmts"))) (EApp (EApp (EVar "EDo") (EVar "d")) (EApp (EApp (EApp (EApp (EVar "rewriteArgStmts") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "stmts"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "EApp") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "f"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "x"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "EIf") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "c"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "t"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") (PVar "ev"))) (EBlock (DoLet false false (PVar "l2") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "l"))) (DoLet false false (PVar "r2") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "r"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EVar "l2")) (EVar "r2")) (EApp (EApp (EVar "mintedOr") (EApp (EVar "mintOpSite") (EVar "mctx"))) (EVar "ev"))))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EUnOp" (PVar "op") (PVar "x") (PVar "ev"))) (EBlock (DoLet false false (PVar "x2") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "x"))) (DoExpr (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EVar "x2")) (EApp (EApp (EVar "mintedOr") (EApp (EVar "mintOpSite") (EVar "mctx"))) (EVar "ev"))))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EInfix" (PVar "op") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "l"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "r"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EFieldAccess" (PVar "e0") (PVar "n") (PVar "ev"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EVar "n")) (EApp (EApp (EVar "mintedOr") (EApp (EVar "mintHeadSite") (EVar "mctx"))) (EVar "ev"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "lo"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "lo"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "lo"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EIndex" (PVar "e0") (PVar "i"))) (EApp (EApp (EVar "EIndex") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "i"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EVar "t")))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EHeadAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EVar "t")))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "rewriteArgField") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "fs"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ERecordUpdate" (PVar "e0") (PVar "fs") (PVar "ev"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "rewriteArgField") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "fs"))) (EApp (EApp (EVar "mintedOr") (EApp (EVar "mintHeadSite") (EVar "mctx"))) (EVar "ev"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EVariantUpdate" (PVar "c") (PVar "e0") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "c")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "rewriteArgField") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "fs"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "rewriteArgInterp") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "parts"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "rewriteArgGuardArm") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "arms"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ESection" (PCon "SecRight" (PVar "op") (PVar "e0")))) (EApp (EVar "ESection") (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0")))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ESection" (PCon "SecLeft" (PVar "e0") (PVar "op")))) (EApp (EVar "ESection") (EApp (EApp (EVar "SecLeft") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e0"))) (EVar "op"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "rewriteArgKv") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "kvs"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "EAsPat" (PVar "x") (PVar "sub"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EMethodRef "sub"))))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") PWild PWild (PCon "ENumLit" (PVar "n") (PVar "ev") (PVar "lx"))) (EApp (EApp (EApp (EVar "ENumLit") (EVar "n")) (EApp (EApp (EVar "mintedOr") (EApp (EVar "mintLitSite") (EVar "mctx"))) (EVar "ev"))) (EVar "lx")))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") PWild PWild (PCon "EWideLit" (PVar "hi") (PVar "lo") (PVar "ev") (PVar "lx"))) (EApp (EApp (EApp (EApp (EVar "EWideLit") (EVar "hi")) (EVar "lo")) (EApp (EApp (EVar "mintedOr") (EApp (EVar "mintOpSite") (EVar "mctx"))) (EVar "ev"))) (EVar "lx")))
(DFunDef false "rewriteArgScoped" ((PVar "mctx") PWild PWild (PVar "e")) (EVar "e"))
(DTypeSig false "rewriteArgField" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign"))))))
(DFunDef false "rewriteArgField" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))))
(DTypeSig false "rewriteArgKv" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr")))))))
(DFunDef false "rewriteArgKv" ((PVar "mctx") (PVar "rw") (PVar "bound") (PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "k")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "v"))))
(DTypeSig false "rewriteArgInterp" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "InterpPart") (TyCon "InterpPart"))))))
(DFunDef false "rewriteArgInterp" ((PVar "mctx") PWild PWild (PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "rewriteArgInterp" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))))
(DTypeSig false "rewriteArgLetBind" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "LetBind") (TyCon "LetBind"))))))
(DFunDef false "rewriteArgLetBind" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "rewriteArgFunClause") (EVar "mctx")) (EVar "rw")) (EVar "bound"))) (EVar "clauses"))) (EVar "site")) (EVar "bid")))
(DTypeSig false "rewriteArgFunClause" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "FunClause") (TyCon "FunClause"))))))
(DFunDef false "rewriteArgFunClause" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "FunClause" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EApp (EApp (EVar "boundInsert") (EApp (EVar "patVarsListTc") (EVar "ps"))) (EVar "bound"))) (EVar "body"))))
(DTypeSig false "rewriteArgArm" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Arm") (TyCon "Arm"))))))
(DFunDef false "rewriteArgArm" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EBlock (DoLet false false (PVar "b0") (EApp (EApp (EVar "boundInsert") (EApp (EVar "patVarsTc") (EVar "p"))) (EVar "bound"))) (DoLet false false (PTuple (PVar "gs2") (PVar "bnd")) (EApp (EApp (EApp (EApp (EVar "rewriteArgGuards") (EVar "mctx")) (EVar "rw")) (EVar "b0")) (EVar "gs"))) (DoExpr (EApp (EApp (EApp (EVar "Arm") (EVar "p")) (EVar "gs2")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bnd")) (EVar "body"))))))
(DTypeSig false "rewriteArgGuardArm" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "GuardArm") (TyCon "GuardArm"))))))
(DFunDef false "rewriteArgGuardArm" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCon "GuardArm" (PVar "gs") (PVar "body"))) (EBlock (DoLet false false (PTuple (PVar "gs2") (PVar "bnd")) (EApp (EApp (EApp (EApp (EVar "rewriteArgGuards") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "gs"))) (DoExpr (EApp (EApp (EVar "GuardArm") (EVar "gs2")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bnd")) (EVar "body"))))))
(DTypeSig false "rewriteArgGuards" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyTuple (TyApp (TyCon "List") (TyCon "Guard")) (TyApp (TyCon "OrdMap") (TyCon "String"))))))))
(DFunDef false "rewriteArgGuards" ((PVar "mctx") PWild (PVar "bound") (PList)) (ETuple (EListLit) (EVar "bound")))
(DFunDef false "rewriteArgGuards" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCons (PCon "GBool" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "e2") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))) (DoLet false false (PTuple (PVar "rest2") (PVar "bnd")) (EApp (EApp (EApp (EApp (EVar "rewriteArgGuards") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EVar "GBool") (EVar "e2")) (EVar "rest2")) (EVar "bnd")))))
(DFunDef false "rewriteArgGuards" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCons (PCon "GBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "e2") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))) (DoLet false false (PTuple (PVar "rest2") (PVar "bnd")) (EApp (EApp (EApp (EApp (EVar "rewriteArgGuards") (EVar "mctx")) (EVar "rw")) (EApp (EApp (EVar "boundInsert") (EApp (EVar "patVarsTc") (EVar "p"))) (EVar "bound"))) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "GBind") (EVar "p")) (EVar "e2")) (EVar "rest2")) (EVar "bnd")))))
(DTypeSig false "rewriteArgStmts" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "List") (TyCon "DoStmt")))))))
(DFunDef false "rewriteArgStmts" ((PVar "mctx") PWild PWild (PList)) (EListLit))
(DFunDef false "rewriteArgStmts" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCons (PCon "DoExpr" (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EVar "DoExpr") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgStmts") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "rest"))))
(DFunDef false "rewriteArgStmts" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCons (PCon "DoBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DoBind") (EVar "p")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgStmts") (EVar "mctx")) (EVar "rw")) (EApp (EApp (EVar "boundInsert") (EApp (EVar "patVarsTc") (EVar "p"))) (EVar "bound"))) (EVar "rest"))))
(DFunDef false "rewriteArgStmts" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCons (PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e") (PVar "site")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "p2") (PVar "after")) (EApp (EApp (EApp (EApp (EVar "letPatRename") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "p")) (EVar "e")) (EVar "bound"))) (DoLet false false (PVar "b1") (EIf (EVar "r") (EVar "after") (EVar "bound"))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p2")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "b1")) (EVar "e"))) (EVar "site")) (EApp (EApp (EApp (EApp (EVar "rewriteArgStmts") (EVar "mctx")) (EVar "rw")) (EVar "after")) (EVar "rest"))))))
(DFunDef false "rewriteArgStmts" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCons (PCon "DoAssign" (PVar "x") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgStmts") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "rest"))))
(DFunDef false "rewriteArgStmts" ((PVar "mctx") (PVar "rw") (PVar "bound") (PCons (PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EApp (EVar "rewriteArgStmts") (EVar "mctx")) (EVar "rw")) (EVar "bound")) (EVar "rest"))))
(DTypeSig true "methodConstraintNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "methodConstraintNames" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "methodConstraintNamesOfDecl")) (EVar "prog")))
(DTypeSig false "methodConstraintNamesOfDecl" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "methodConstraintNamesOfDecl" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "methodConstraintNamesOfDecl") (EVar "d")))
(DFunDef false "methodConstraintNamesOfDecl" ((PRec "DInterface" ((rf "typarams" None) (rf "methods" None)) true)) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "methodConstraintNameOf") (EVar "typarams"))) (EVar "methods")))
(DFunDef false "methodConstraintNamesOfDecl" (PWild) (EListLit))
(DTypeSig false "methodConstraintNameOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "methodConstraintNameOf" ((PVar "typarams") (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild PWild)) (EIf (EApp (EApp (EVar "hasMethodLevelConstraint") (EVar "typarams")) (EVar "mty")) (EListLit (EVar "mname")) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "hasMethodLevelConstraint" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyCon "Bool"))))
(DFunDef false "hasMethodLevelConstraint" ((PVar "typarams") (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "||" (EApp (EApp (EVar "constraintsHaveMethodLevel") (EVar "typarams")) (EVar "cs")) (EApp (EApp (EVar "hasMethodLevelConstraint") (EVar "typarams")) (EVar "t"))))
(DFunDef false "hasMethodLevelConstraint" ((PVar "typarams") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EVar "hasMethodLevelConstraint") (EVar "typarams")) (EVar "t")))
(DFunDef false "hasMethodLevelConstraint" (PWild PWild) (EVar "False"))
(DTypeSig false "constraintsHaveMethodLevel" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Constraint")) (TyCon "Bool"))))
(DFunDef false "constraintsHaveMethodLevel" (PWild (PList)) (EVar "False"))
(DFunDef false "constraintsHaveMethodLevel" ((PVar "typarams") (PCons (PVar "c") (PVar "rest"))) (EBinOp "||" (EApp (EApp (EVar "constraintIsMethodLevel") (EVar "typarams")) (EVar "c")) (EApp (EApp (EVar "constraintsHaveMethodLevel") (EVar "typarams")) (EVar "rest"))))
(DTypeSig false "instantiateMethodPredicateTemplate" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "MethodPredicateTemplate") (TyFun (TyCon "MethodInstantiationSubst") (TyCon "MethodPredicateTemplate")))))
(DFunDef false "instantiateMethodPredicateTemplate" ((PVar "gctx") (PVar "template") (PVar "subst")) (ERecordCreate "MethodPredicateTemplate" ((fa "mptInterface" (EFieldAccess (EVar "template") "mptInterface")) (fa "mptArguments" (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "instantiateMethodPredicateArgument") (EVar "gctx")) (EVar "subst"))) (EFieldAccess (EVar "template") "mptArguments"))))))
(DTypeSig false "instantiateMethodPredicateArgument" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "MethodInstantiationSubst") (TyFun (TyApp (TyCon "Option") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "Mono"))))))
(DFunDef false "instantiateMethodPredicateArgument" ((PVar "gctx") (PVar "subst") (PVar "argument")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EFieldAccess (EVar "subst") "misTypeSubst")) (EFieldAccess (EVar "subst") "misEffectSubst")) (EFieldAccess (EVar "subst") "misAuthSubst"))) (EVar "argument")))
(DTypeSig false "omittedParamVars" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))))))
(DFunDef false "omittedParamVars" ((PVar "mctx") (PVar "typarams") (PVar "mty")) (EBlock (DoLet false false (PVar "named") (EApp (EVar "tyVarNames") (EApp (EVar "stripTyConstraints") (EVar "mty")))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "tp")) (ETuple (EVar "tp") (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "tp")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "tp")) (EVar "named"))))) (EVar "typarams"))))))
(DTypeSig true "methodOmittedVars" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))))
(DFunDef false "methodOmittedVars" ((PVar "mctx") (PVar "name")) (EMatch (ETuple (EApp (EApp (EVar "argDispatchOf") (EVar "mctx")) (EVar "name")) (EApp (EApp (EVar "methodEntryHere") (EVar "mctx")) (EVar "name"))) (arm (PTuple (PCon "Some" PWild) (PCon "Some" (PTuple PWild (PVar "typarams") (PVar "mty") PWild))) () (EApp (EApp (EApp (EVar "omittedParamVars") (EVar "mctx")) (EVar "typarams")) (EVar "mty"))) (arm PWild () (EListLit))))
(DTypeSig false "methodLevelConstraintSlots" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Constraint")))))
(DFunDef false "methodLevelConstraintSlots" ((PVar "typarams") (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "++" (EApp (EApp (EVar "filterList") (EApp (EVar "constraintIsMethodLevel") (EVar "typarams"))) (EVar "cs")) (EApp (EApp (EVar "methodLevelConstraintSlots") (EVar "typarams")) (EVar "t"))))
(DFunDef false "methodLevelConstraintSlots" ((PVar "typarams") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EVar "methodLevelConstraintSlots") (EVar "typarams")) (EVar "t")))
(DFunDef false "methodLevelConstraintSlots" (PWild PWild) (EListLit))
(DTypeSig false "stripLeadingMethodConstraints" (TyFun (TyCon "Ty") (TyCon "Ty")))
(DFunDef false "stripLeadingMethodConstraints" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "stripLeadingMethodConstraints") (EVar "t")))
(DFunDef false "stripLeadingMethodConstraints" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "stripLeadingMethodConstraints") (EVar "t")))
(DFunDef false "stripLeadingMethodConstraints" ((PVar "t")) (EVar "t"))
(DTypeSig false "moduleDictNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "moduleDictNames" ((PVar "preludeNames") (PVar "modules")) (EBinOp "++" (EVar "preludeNames") (EApp (EVar "constrainedSigNames") (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "modules")))))
(DTypeSig false "argRwOf" (TyFun (TyCon "MarkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "Unit"))) (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyCon "ArgRw"))))))
(DFunDef false "argRwOf" ((PVar "mc") (PVar "dn") (PVar "onDict") (PVar "granted")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ArgRw") (EFieldAccess (EVar "mc") "mcRp")) (EVar "dn")) (EFieldAccess (EVar "mc") "mcAn")) (EFieldAccess (EVar "mc") "mcSm")) (EVar "onDict")) (EVar "granted")))
(DTypeSig true "markTailDecls" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MarkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))))))
(DFunDef false "markTailDecls" ((PVar "mctx") (PVar "mc") (PVar "dn") (PVar "granted") (PVar "decls")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "markTailDecl") (EVar "mctx")) (EApp (EApp (EApp (EApp (EVar "argRwOf") (EVar "mc")) (EVar "dn")) (EVar "noDictHook")) (EVar "granted")))) (EVar "decls")))
(DTypeSig false "markTailDecl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyCon "Decl") (TyCon "Decl")))))
(DFunDef false "markTailDecl" ((PVar "mctx") PWild (PAs "d" (PCon "DFunDef" PWild PWild PWild PWild PWild PWild))) (EVar "d"))
(DFunDef false "markTailDecl" ((PVar "mctx") PWild (PAs "d" (PCon "DLetGroup" PWild PWild))) (EVar "d"))
(DFunDef false "markTailDecl" ((PVar "mctx") (PVar "rw") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EApp (EVar "markTailDecl") (EVar "mctx")) (EVar "rw")) (EVar "d"))))
(DFunDef false "markTailDecl" ((PVar "mctx") (PVar "rw") (PVar "d")) (EApp (EApp (EApp (EVar "prePassDeclScoped") (EVar "mctx")) (EVar "rw")) (EVar "d")))
(DTypeSig false "markClauseWith" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ArgRw") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "markClauseWith" ((PVar "mctx") (PVar "rw") (PTuple (PVar "ps") (PVar "e"))) (ETuple (EVar "ps") (EApp (EApp (EApp (EApp (EVar "rewriteArgScoped") (EVar "mctx")) (EVar "rw")) (EApp (EVar "boundOfList") (EApp (EVar "patVarsListTc") (EVar "ps")))) (EVar "e"))))
(DTypeSig true "evIdModule" (TyFun (TyCon "EvId") (TyCon "String")))
(DFunDef false "evIdModule" ((PCon "EvId" (PVar "m") PWild)) (EVar "m"))
(DTypeSig true "markSetsOf" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PreludeMarkFacts") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "MarkSets")))))))
(DFunDef false "markSetsOf" ((PVar "gctx") (PVar "pmf") (PVar "coreDecls") (PVar "modules") (PVar "allDecls")) (EBlock (DoLet false false (PVar "units") (EBinOp "::" (ETuple (ELit (LString "core")) (EVar "coreDecls")) (EVar "modules"))) (DoLet false false (PVar "userDecls") (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "modules"))) (DoLet false false (PVar "shadowMap") (EApp (EApp (EVar "computeMangledShadowMap") (EVar "allDecls")) (EVar "units"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "mangledShadowMapRef")) (EVar "shadowMap"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "argDispatchIdxByIdRef")) (EBinOp "++" (EFieldAccess (EVar "pmf") "pmfArgDispatchById") (EApp (EVar "argDispatchIndicesById") (EVar "userDecls"))))) (DoLet false false (PVar "rpNames") (EBinOp "++" (EFieldAccess (EVar "pmf") "pmfReturnPos") (EApp (EVar "returnPosMethodNames") (EVar "userDecls")))) (DoLet false false (PVar "markSharedNames") (EApp (EVar "dedup") (EBinOp "++" (EBinOp "++" (EVar "rpNames") (EFieldAccess (EVar "pmf") "pmfMethodConstraints")) (EApp (EVar "methodConstraintNames") (EVar "userDecls"))))) (DoLet false false (PVar "graphShadowNames") (EApp (EApp (EApp (EVar "buildStandaloneShadowsGraph") (EVar "shadowMap")) (EVar "allDecls")) (EVar "userDecls"))) (DoLet false false (PVar "ms") (ERecordCreate "MarkSets" ((fa "msMarkRpNames" (EApp (EVar "dedup") (EBinOp "++" (EVar "markSharedNames") (EVar "graphShadowNames")))) (fa "msMarkSharedNames" (EVar "markSharedNames")) (fa "msGraphShadowNames" (EVar "graphShadowNames")) (fa "msArgNames" (EApp (EApp (EMethodRef "map") (EVar "fst")) (EBinOp "++" (EFieldAccess (EVar "pmf") "pmfArgDispatch") (EApp (EVar "argDispatchIndices") (EVar "userDecls"))))) (fa "msCoreShadowMap" (EApp (EApp (EApp (EVar "coreShadowMapFor") (EVar "gctx")) (EVar "coreDecls")) (EVar "shadowMap"))) (fa "msBareDictNames" (EApp (EVar "dedup") (EApp (EApp (EVar "moduleDictNames") (EFieldAccess (EVar "pmf") "pmfConstrainedNames")) (EVar "modules")))) (fa "msUnits" (EVar "units"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "markSetsRef")) (EApp (EVar "Some") (EVar "ms")))) (DoExpr (EVar "ms"))))
(DTypeSig true "markDictNames" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "markDictNames" ((PVar "gctx") (PVar "names") (PVar "coreDecls") (PVar "modules")) (EApp (EVar "dedup") (EBinOp "++" (EVar "names") (EApp (EApp (EApp (EApp (EVar "aliasDictNames") (EVar "gctx")) (EVar "names")) (EBinOp "::" (ETuple (ELit (LString "core")) (EVar "coreDecls")) (EVar "modules"))) (EVar "modules")))))
(DTypeSig true "markGroupClauses" (TyFun (TyCon "ModuleMarking") (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))))
(DFunDef false "markGroupClauses" ((PVar "mm") (PVar "env") (PVar "members") (PVar "grouped")) (EBlock (DoLet false false (PVar "own") (EApp (EApp (EVar "omFromNames") (EVar "members")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EApp (EVar "mapGroupClauses") (EApp (EApp (EVar "markClauseWith") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EApp (EApp (EApp (EVar "argRwOf") (EFieldAccess (EVar "mm") "mmCtx")) (EFieldAccess (EFieldAccess (EVar "mm") "mmDictSet") "value")) (EVar "noDictHook")) (ELam ((PVar "n")) (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "own")) (EApp (EApp (EVar "grantNameIn") (EVar "env")) (EVar "n"))))))) (EVar "members")) (EVar "grouped")))))
(DTypeSig true "mapGroupClauses" (TyFun (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))))
(DFunDef false "mapGroupClauses" (PWild (PList) (PVar "grouped")) (EVar "grouped"))
(DFunDef false "mapGroupClauses" ((PVar "f") (PCons (PVar "m") (PVar "rest")) (PVar "grouped")) (EApp (EApp (EApp (EVar "mapGroupClauses") (EVar "f")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "m")) (EApp (EVar "reverse") (EApp (EApp (EMethodRef "map") (EVar "f")) (EApp (EApp (EVar "clausesOf") (EVar "m")) (EVar "grouped"))))) (EVar "grouped"))))
(DTypeSig true "markRecursiveOccurrences" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ModuleMarking") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "ScopedMember")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))))))
(DFunDef false "markRecursiveOccurrences" ((PVar "mctx") (PVar "mm") (PVar "placeholders") (PVar "scopedMembers") (PVar "grouped")) (EBlock (DoLet false false (PVar "promoted") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "promotedRef") "value")) (EVar "omEmpty"))) (DoLet false false (PVar "fresh") (EApp (EApp (EVar "filterList") (ELam ((PVar "m")) (EBinOp "&&" (EApp (EApp (EVar "omHasKey") (EVar "m")) (EVar "promoted")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "m")) (EFieldAccess (EFieldAccess (EVar "mm") "mmDictSet") "value")))))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "member")) (EFieldAccess (EVar "member") "smName"))) (EVar "scopedMembers")))) (DoExpr (EMatch (EVar "fresh") (arm (PList) () (EVar "grouped")) (arm PWild () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "mm") "mmDictSet")) (EApp (EApp (EVar "omFromNames") (EVar "fresh")) (EFieldAccess (EFieldAccess (EVar "mm") "mmDictSet") "value")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recMarkMembers") (EVar "mctx")) (EApp (EApp (EVar "omFromNames") (EVar "fresh")) (EVar "omEmpty"))) (EVar "placeholders")) (EVar "scopedMembers")) (EVar "grouped")))))))))
(DTypeSig false "recMarkMembers" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "ScopedMember")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))))))
(DFunDef false "recMarkMembers" ((PVar "mctx") PWild PWild (PList) (PVar "grouped")) (EVar "grouped"))
(DFunDef false "recMarkMembers" ((PVar "mctx") (PVar "dn") (PVar "placeholders") (PCons (PVar "member") (PVar "rest")) (PVar "grouped")) (EBlock (DoLet false false (PVar "m") (EFieldAccess (EVar "member") "smName")) (DoLet false false (PVar "onDict") (ELam ((PVar "callee") (PVar "ev")) (EApp (EApp (EVar "pushRecDictAppGoal") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "RecDictApp") (EApp (EVar "Ref") (EListLit))) (EVar "callee")) (EVar "m")) (EApp (EApp (EVar "placeholderMonoOf") (EVar "callee")) (EVar "placeholders"))) (EFieldAccess (EVar "member") "smScope")) (EVar "ev"))))) (DoLet false false (PVar "rw") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ArgRw") (EVar "omEmpty")) (EVar "dn")) (EVar "omEmpty")) (EListLit)) (EVar "onDict")) (ELam (PWild) (EVar "False")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recMarkMembers") (EVar "mctx")) (EVar "dn")) (EVar "placeholders")) (EVar "rest")) (EApp (EApp (EApp (EVar "mapGroupClauses") (EApp (EApp (EVar "markClauseWith") (EVar "mctx")) (EVar "rw"))) (EListLit (EVar "m"))) (EVar "grouped"))))))
(DTypeSig false "placeholderMonoOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyCon "Mono"))))
(DFunDef false "placeholderMonoOf" ((PVar "callee") (PVar "placeholders")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "callee")) (EVar "placeholders")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "markRecursiveOccurrences: ")) (EApp (EMethodRef "display") (EVar "callee"))) (ELit (LString " is not a member of the group")))))))
(DTypeSig true "rebuildGroupDecls" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "rebuildGroupDecls" ((PVar "grouped") (PVar "prog")) (EApp (EVar "fst") (EApp (EApp (EApp (EVar "rebuildGroupDeclsGo") (EVar "grouped")) (EVar "omEmpty")) (EVar "prog"))))
(DTypeSig false "rebuildGroupDeclsGo" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))))
(DFunDef false "rebuildGroupDeclsGo" (PWild (PVar "pending") (PList)) (ETuple (EListLit) (EVar "pending")))
(DFunDef false "rebuildGroupDeclsGo" ((PVar "grouped") (PVar "pending") (PCons (PCon "DFunDef" (PVar "pub") (PVar "n") PWild PWild (PVar "site") (PVar "bid")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PTuple (PVar "ps") (PVar "e")) (PVar "pending2")) (EApp (EApp (EApp (EVar "popMarkedClause") (EVar "grouped")) (EVar "pending")) (EVar "n"))) (DoLet false false (PTuple (PVar "ds") (PVar "pending3")) (EApp (EApp (EApp (EVar "rebuildGroupDeclsGo") (EVar "grouped")) (EVar "pending2")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "n")) (EVar "ps")) (EVar "e")) (EVar "site")) (EVar "bid")) (EVar "ds")) (EVar "pending3")))))
(DFunDef false "rebuildGroupDeclsGo" ((PVar "grouped") (PVar "pending") (PCons (PCon "DLetGroup" (PVar "pub") (PVar "binds")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "binds2") (PVar "pending2")) (EApp (EApp (EApp (EVar "rebuildLetBinds") (EVar "grouped")) (EVar "pending")) (EVar "binds"))) (DoLet false false (PTuple (PVar "ds") (PVar "pending3")) (EApp (EApp (EApp (EVar "rebuildGroupDeclsGo") (EVar "grouped")) (EVar "pending2")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EVar "binds2")) (EVar "ds")) (EVar "pending3")))))
(DFunDef false "rebuildGroupDeclsGo" ((PVar "grouped") (PVar "pending") (PCons (PCon "DAttrib" (PVar "attrs") (PVar "d")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "inner") (PVar "pending2")) (EApp (EApp (EApp (EVar "rebuildGroupDeclsGo") (EVar "grouped")) (EVar "pending")) (EListLit (EVar "d")))) (DoLet false false (PTuple (PVar "ds") (PVar "pending3")) (EApp (EApp (EApp (EVar "rebuildGroupDeclsGo") (EVar "grouped")) (EVar "pending2")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "d2")) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EVar "d2")))) (EVar "inner")) (EVar "ds")) (EVar "pending3")))))
(DFunDef false "rebuildGroupDeclsGo" ((PVar "grouped") (PVar "pending") (PCons (PVar "d") (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "ds") (PVar "pending2")) (EApp (EApp (EApp (EVar "rebuildGroupDeclsGo") (EVar "grouped")) (EVar "pending")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EVar "d") (EVar "ds")) (EVar "pending2")))))
(DTypeSig false "rebuildLetBinds" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyTuple (TyApp (TyCon "List") (TyCon "LetBind")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))))
(DFunDef false "rebuildLetBinds" (PWild (PVar "pending") (PList)) (ETuple (EListLit) (EVar "pending")))
(DFunDef false "rebuildLetBinds" ((PVar "grouped") (PVar "pending") (PCons (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "clauses2") (PVar "pending2")) (EApp (EApp (EApp (EApp (EVar "rebuildFunClauses") (EVar "grouped")) (EVar "pending")) (EVar "n")) (EVar "clauses"))) (DoLet false false (PTuple (PVar "binds") (PVar "pending3")) (EApp (EApp (EApp (EVar "rebuildLetBinds") (EVar "grouped")) (EVar "pending2")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EVar "clauses2")) (EVar "site")) (EVar "bid")) (EVar "binds")) (EVar "pending3")))))
(DTypeSig false "rebuildFunClauses" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyTuple (TyApp (TyCon "List") (TyCon "FunClause")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))))))
(DFunDef false "rebuildFunClauses" (PWild (PVar "pending") PWild (PList)) (ETuple (EListLit) (EVar "pending")))
(DFunDef false "rebuildFunClauses" ((PVar "grouped") (PVar "pending") (PVar "n") (PCons PWild (PVar "rest"))) (EBlock (DoLet false false (PTuple (PTuple (PVar "ps") (PVar "e")) (PVar "pending2")) (EApp (EApp (EApp (EVar "popMarkedClause") (EVar "grouped")) (EVar "pending")) (EVar "n"))) (DoLet false false (PTuple (PVar "cs") (PVar "pending3")) (EApp (EApp (EApp (EApp (EVar "rebuildFunClauses") (EVar "grouped")) (EVar "pending2")) (EVar "n")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "FunClause") (EVar "ps")) (EVar "e")) (EVar "cs")) (EVar "pending3")))))
(DTypeSig false "popMarkedClause" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyCon "String") (TyTuple (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))))
(DFunDef false "popMarkedClause" ((PVar "grouped") (PVar "pending") (PVar "n")) (EBlock (DoLet false false (PVar "remaining") (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "pending")) (arm (PCon "Some" (PVar "cs")) () (EVar "cs")) (arm (PCon "None") () (EApp (EApp (EVar "clausesOf") (EVar "n")) (EVar "grouped"))))) (DoExpr (EMatch (EVar "remaining") (arm (PCons (PVar "c") (PVar "cs")) () (ETuple (EVar "c") (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "cs")) (EVar "pending")))) (arm (PList) () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "rebuildGroupDecls: no marked clause left for ")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "")))))))))
(DTypeSig true "cellGoalInnerAliasing" (TyFun (TyCon "GraphCtx") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Bool")))))
(DFunDef false "cellGoalInnerAliasing" ((PVar "gctx")) (EBlock (DoLet false false (PVar "g") (EFieldAccess (EVar "gctx") "graphRun")) (DoLet false false (PVar "cells") (EApp (EApp (EApp (EVar "cellsFrom") (EFieldAccess (EFieldAccess (EVar "g") "evCells") "value")) (ELit (LInt 0))) (EListLit))) (DoExpr (EApp (EApp (EMethodRef "filterMap") (ELam ((PVar "o")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "c")) (ETuple (EApp (EVar "goalKindName") (EFieldAccess (EVar "o") "oKind")) (EApp (EApp (EVar "innerAliases") (EVar "o")) (EVar "c"))))) (EApp (EApp (EVar "cellOfGoal") (EVar "cells")) (EVar "o"))))) (EFieldAccess (EFieldAccess (EVar "g") "goals") "value")))))
(DTypeSig false "cellsFrom" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvCell"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "EvCell")) (TyApp (TyCon "List") (TyCon "EvCell"))))))
(DFunDef false "cellsFrom" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "reverseL") (EVar "acc")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (arm (PCon "Some" (PVar "c")) () (EApp (EApp (EApp (EVar "cellsFrom") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EVar "c") (EVar "acc")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "cellsFrom") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "cellOfGoal" (TyFun (TyApp (TyCon "List") (TyCon "EvCell")) (TyFun (TyCon "Obligation") (TyApp (TyCon "Option") (TyCon "EvCell")))))
(DFunDef false "cellOfGoal" ((PVar "cells") (PVar "o")) (EMatch (EFieldAccess (EVar "o") "oDest") (arm (PCon "EvRoute" (PVar "r")) () (EBlock (DoLet false false (PVar "saved") (EFieldAccess (EVar "r") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EVar "r")) (EApp (EApp (EVar "RLocal") (EVar "aliasMarker")) (EListLit)))) (DoLet false false (PVar "hit") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "isAliasMarker") (EFieldAccess (EFieldAccess (EVar "c") "ecTag") "value")))) (EVar "cells"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "r")) (EVar "saved"))) (DoExpr (EApp (EVar "onlyCell") (EVar "hit"))))) (arm (PCon "EvRoutes" (PVar "rs")) () (EBlock (DoLet false false (PVar "saved") (EFieldAccess (EVar "rs") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EVar "rs")) (EListLit (EApp (EApp (EVar "RLocal") (EVar "aliasMarker")) (EListLit))))) (DoLet false false (PVar "hit") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EApp (EVar "anyList") (EVar "isAliasMarker")) (EBinOp "++" (EFieldAccess (EFieldAccess (EVar "c") "ecImpl") "value") (EFieldAccess (EFieldAccess (EVar "c") "ecMeth") "value"))))) (EVar "cells"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "rs")) (EVar "saved"))) (DoExpr (EApp (EVar "onlyCell") (EVar "hit")))))))
(DTypeSig false "onlyCell" (TyFun (TyApp (TyCon "List") (TyCon "EvCell")) (TyApp (TyCon "Option") (TyCon "EvCell"))))
(DFunDef false "onlyCell" ((PList (PVar "c"))) (EApp (EVar "Some") (EVar "c")))
(DFunDef false "onlyCell" (PWild) (EVar "None"))
(DTypeSig false "aliasMarker" (TyCon "String"))
(DFunDef false "aliasMarker" () (ELit (LString "<inner-alias-probe>")))
(DTypeSig false "isAliasMarker" (TyFun (TyCon "Route") (TyCon "Bool")))
(DFunDef false "isAliasMarker" ((PCon "RLocal" (PVar "sym") PWild)) (EBinOp "==" (EVar "sym") (EVar "aliasMarker")))
(DFunDef false "isAliasMarker" (PWild) (EVar "False"))
(DTypeSig false "innerAliases" (TyFun (TyCon "Obligation") (TyFun (TyCon "EvCell") (TyCon "Bool"))))
(DFunDef false "innerAliases" ((PVar "o") (PVar "c")) (EBlock (DoLet false false (PVar "savedGoal") (EFieldAccess (EFieldAccess (EVar "o") "oInner") "value")) (DoLet false false (PVar "savedCell") (EFieldAccess (EFieldAccess (EVar "c") "ecInner") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "c") "ecInner")) (EVar "innerNone"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "o") "oInner")) (EApp (EApp (EVar "Inner") (EVar "True")) (EVar "True")))) (DoLet false false (PVar "hit") (EMatch (EFieldAccess (EFieldAccess (EVar "c") "ecInner") "value") (arm (PCon "Inner" (PCon "True") (PCon "True")) () (EVar "True")) (arm PWild () (EVar "False")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "o") "oInner")) (EVar "savedGoal"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "c") "ecInner")) (EVar "savedCell"))) (DoExpr (EVar "hit"))))
(DTypeSig true "cellStoreMisses" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvId") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "cellStoreMisses" ((PVar "gctx") (PVar "ev")) (ETuple (EApp (EVar "missText") (EApp (EApp (EVar "siteCellLookup") (EVar "gctx")) (EVar "ev"))) (EApp (EVar "missText") (EApp (EApp (EVar "methodCellLookup") (EVar "gctx")) (EVar "ev")))))
(DTypeSig false "missText" (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a")) (TyCon "String")))
(DFunDef false "missText" ((PCon "Ok" PWild)) (ELit (LString "")))
(DFunDef false "missText" ((PCon "Err" (PVar "message"))) (EVar "message"))
(DTypeSig true "firstMethodRow" (TyFun (TyApp (TyCon "List") (TyCon "MethodSchemeRow")) (TyCon "MethodSchemeRow")))
(DFunDef false "firstMethodRow" ((PCons (PVar "row") PWild)) (EVar "row"))
(DFunDef false "firstMethodRow" ((PList)) (EApp (EVar "panic") (ELit (LString "method-row observer expected a row"))))
(DTypeSig false "observeMethodSchemeRowsForTest" (TyFun (TyCon "Unit") (TyCon "MethodRowTestObservation")))
(DFunDef false "observeMethodSchemeRowsForTest" (PWild) (EBlock (DoLet false false (PVar "graph1") (EApp (EVar "probeGraphCtx") (ELit LUnit))) (DoLet false false (PVar "rows1") (EApp (EVar "initialModuleCtx") (EVar "graph1"))) (DoLet false false (PVar "constrainedRow") (EApp (EVar "firstMethodRow") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "rows1")) (EListLit (EVar "methodRowTestFoldMapDecl"))))) (DoLet false false (PVar "constrainedIds") (EApp (EVar "schemeIds") (EFieldAccess (EVar "constrainedRow") "msrScheme"))) (DoLet false false (PVar "constrainedSlots") (EFieldAccess (EVar "constrainedRow") "msrMethodSlots")) (DoLet false false (PVar "constrainedBoundIds") (EApp (EVar "methodSlotBoundIds") (EVar "constrainedSlots"))) (DoLet false false (PVar "constrainedPositions") (EApp (EVar "methodSlotPositions") (EVar "constrainedSlots"))) (DoLet false false (PVar "constrainedIdsAtPositions") (EApp (EApp (EVar "methodSlotIdsAtPositions") (EVar "constrainedIds")) (EVar "constrainedSlots"))) (DoLet false false (PVar "constrainedArgumentIds") (EApp (EVar "methodSlotArgumentIds") (EVar "constrainedSlots"))) (DoLet false false (PVar "graph2") (EApp (EVar "freshSubRecordsOf") (EVar "graph1"))) (DoLet false false (PVar "rows2") (EApp (EApp (EVar "carryModuleCtx") (EVar "graph2")) (EVar "rows1"))) (DoLet false false (PVar "counterBefore") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "graph2") "graphRun") "tyvarCounter") "value")) (DoLet false false (PVar "firstRow") (EApp (EVar "firstMethodRow") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "rows2")) (EListLit (EVar "methodRowTestFoldMapDecl"))))) (DoLet false false (PVar "counterAfterFirst") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "graph2") "graphRun") "tyvarCounter") "value")) (DoLet false false (PVar "secondRow") (EApp (EVar "firstMethodRow") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "rows2")) (EListLit (EVar "methodRowTestFoldMapDecl"))))) (DoLet false false (PVar "counterAfterSecond") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "graph2") "graphRun") "tyvarCounter") "value")) (DoLet false false (PVar "firstSchemeIds") (EApp (EVar "schemeIds") (EFieldAccess (EVar "firstRow") "msrScheme"))) (DoLet false false (PVar "secondSchemeIds") (EApp (EVar "schemeIds") (EFieldAccess (EVar "secondRow") "msrScheme"))) (DoLet false false (PVar "firstRowSlotIds") (EApp (EVar "methodSlotBoundIds") (EFieldAccess (EVar "firstRow") "msrMethodSlots"))) (DoLet false false (PVar "secondRowSlotIds") (EApp (EVar "methodSlotBoundIds") (EFieldAccess (EVar "secondRow") "msrMethodSlots"))) (DoLet false false (PVar "registryAfterSecondSlotIds") (EApp (EApp (EVar "methodRowRegistrySlotIds") (EVar "rows2")) (EApp (EApp (EVar "methodSlotKey") (EFieldAccess (EVar "firstRow") "msrIface")) (ELit (LString "foldMap"))))) (DoLet false false (PVar "graph3") (EApp (EVar "freshSubRecordsOf") (EVar "graph1"))) (DoLet false false (PVar "rows3") (EApp (EApp (EVar "carryModuleCtx") (EVar "graph3")) (EVar "rows2"))) (DoLet false false (PVar "sameNameForward") (EApp (EVar "methodRowSameNameView") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "rows3")) (EListLit (EVar "methodRowTestSameA") (EVar "methodRowTestSameB"))))) (DoLet false false (PVar "graph4") (EApp (EVar "freshSubRecordsOf") (EVar "graph1"))) (DoLet false false (PVar "rows4") (EApp (EApp (EVar "carryModuleCtx") (EVar "graph4")) (EVar "rows3"))) (DoLet false false (PVar "sameNameReverse") (EApp (EVar "methodRowSameNameView") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "rows4")) (EListLit (EVar "methodRowTestSameB") (EVar "methodRowTestSameA"))))) (DoLet false false (PVar "graph5") (EApp (EVar "freshSubRecordsOf") (EVar "graph1"))) (DoLet false false (PVar "rows5") (EApp (EApp (EVar "carryModuleCtx") (EVar "graph5")) (EVar "rows4"))) (DoLet false false (PVar "constantRows") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "rows5")) (EListLit (EVar "methodRowTestConstantDecl")))) (DoLet false false (PVar "constantRow") (EApp (EVar "firstMethodRow") (EVar "constantRows"))) (DoLet false false (PVar "constantBodyIsFunction") (EMatch (EApp (EVar "normalize") (EApp (EVar "schemeBodyOf") (EFieldAccess (EVar "constantRow") "msrScheme"))) (arm (PCon "TFun" PWild PWild PWild) () (EVar "True")) (arm PWild () (EVar "False")))) (DoLet false false (PVar "graph6") (EApp (EVar "freshSubRecordsOf") (EVar "graph1"))) (DoLet false false (PVar "rows6") (EApp (EApp (EVar "carryModuleCtx") (EVar "graph6")) (EVar "rows5"))) (DoLet false false (PVar "attributed") (EApp (EApp (EVar "DAttrib") (EListLit)) (EVar "methodRowTestFoldMapDecl"))) (DoLet false false (PVar "attributedRows") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "rows6")) (EListLit (EVar "attributed")))) (DoLet false false (PVar "attributedMethods") (EApp (EApp (EApp (EVar "methodEnvGo") (EVar "graph6")) (EListLit (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "graph6")) (ELit (LInt 0))) (ELit (LString "foldable-test"))) (EListLit (EVar "attributed"))))) (EVar "emptyMethodEnv"))) (DoLet false false (PTuple (PVar "attributedParamIface") (PVar "attributedParamTyparams")) (EMatch (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (ELit (LString "foldMap"))) (EFieldAccess (EVar "attributedMethods") "meByName"))) (arm (PList) () (ETuple (ELit (LString "")) (EListLit))) (arm (PCons (PVar "r") PWild) () (EMatch (EFieldAccess (EVar "r") "mrEntry") (arm (PTuple (PVar "iface") (PVar "typarams") PWild PWild) () (ETuple (EFieldAccess (EVar "iface") "irName") (EVar "typarams"))))))) (DoLet false false (PVar "directNum") (EApp (EApp (EVar "methodRowTestNum") (ELit (LString "direct-num"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "String"))) (EVar "None"))) (EApp (EVar "TyVar") (ELit (LString "a")))))) (DoLet false false (PVar "attributedNum") (EApp (EApp (EVar "DAttrib") (EListLit)) (EApp (EApp (EVar "methodRowTestNum") (ELit (LString "attributed-num"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))) (EApp (EVar "TyVar") (ELit (LString "a"))))))) (DoLet false false (PVar "builtinNum") (EApp (EApp (EVar "methodRowTestNum") (ELit (LString "builtin-num"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))) (EApp (EVar "TyVar") (ELit (LString "a")))))) (DoLet false false (PVar "numAnchors") (EListLit (EApp (EApp (EApp (EApp (EVar "methodRowNumObservation") (EVar "rows6")) (ELit (LString "attrOnly"))) (EListLit (EVar "attributedNum"))) (EListLit (EVar "attributedNum"))) (EApp (EApp (EApp (EApp (EVar "methodRowNumObservation") (EVar "rows6")) (ELit (LString "directOnly"))) (EListLit (EVar "directNum"))) (EListLit (EVar "directNum"))) (EApp (EApp (EApp (EApp (EVar "methodRowNumObservation") (EVar "rows6")) (ELit (LString "attrThenDirect"))) (EListLit (EVar "attributedNum") (EVar "directNum"))) (EListLit (EVar "attributedNum") (EVar "directNum"))) (EApp (EApp (EApp (EApp (EVar "methodRowNumObservation") (EVar "rows6")) (ELit (LString "directThenAttr"))) (EListLit (EVar "directNum") (EVar "attributedNum"))) (EListLit (EVar "directNum") (EVar "attributedNum"))) (EApp (EApp (EApp (EApp (EVar "methodRowNumObservation") (EVar "rows6")) (ELit (LString "builtinThenUser"))) (EListLit (EVar "builtinNum"))) (EListLit (EVar "builtinNum") (EVar "methodRowTestUserFromInt"))) (EApp (EApp (EApp (EApp (EVar "methodRowNumObservation") (EVar "rows6")) (ELit (LString "userThenBuiltin"))) (EListLit (EVar "builtinNum"))) (EListLit (EVar "methodRowTestUserFromInt") (EVar "builtinNum"))))) (DoLet false false (PVar "observation") (ERecordCreate "MethodRowTestObservation" ((fa "mrtoSchemeIds" (EVar "constrainedIds")) (fa "mrtoSlotBoundIds" (EVar "constrainedBoundIds")) (fa "mrtoSlotPositions" (EVar "constrainedPositions")) (fa "mrtoSlotIdsAtPositions" (EVar "constrainedIdsAtPositions")) (fa "mrtoSlotArgumentIds" (EVar "constrainedArgumentIds")) (fa "mrtoCounterBefore" (EVar "counterBefore")) (fa "mrtoCounterAfterFirst" (EVar "counterAfterFirst")) (fa "mrtoCounterAfterSecond" (EVar "counterAfterSecond")) (fa "mrtoFirstSchemeIds" (EVar "firstSchemeIds")) (fa "mrtoSecondSchemeIds" (EVar "secondSchemeIds")) (fa "mrtoFirstRowSlotIds" (EVar "firstRowSlotIds")) (fa "mrtoSecondRowSlotIds" (EVar "secondRowSlotIds")) (fa "mrtoRegistryAfterSecondSlotIds" (EVar "registryAfterSecondSlotIds")) (fa "mrtoSameNameForward" (EVar "sameNameForward")) (fa "mrtoSameNameReverse" (EVar "sameNameReverse")) (fa "mrtoConstantRowCount" (EApp (EVar "listLen") (EVar "constantRows"))) (fa "mrtoConstantSchemeIdCount" (EApp (EVar "listLen") (EApp (EVar "schemeIds") (EFieldAccess (EVar "constantRow") "msrScheme")))) (fa "mrtoConstantBodyIsFunction" (EVar "constantBodyIsFunction")) (fa "mrtoConstantSlotCount" (EApp (EVar "listLen") (EFieldAccess (EVar "constantRow") "msrMethodSlots"))) (fa "mrtoAttributedRowCount" (EApp (EVar "listLen") (EVar "attributedRows"))) (fa "mrtoAttributedParamIface" (EVar "attributedParamIface")) (fa "mrtoAttributedParamTyparams" (EVar "attributedParamTyparams")) (fa "mrtoNumAnchors" (EVar "numAnchors"))))) (DoExpr (EVar "observation"))))
(DTypeSig false "methodRowSlotAllocationProbe" (TyFun (TyCon "Unit") (TyTuple (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "methodRowSlotAllocationProbe" (PWild) (EBlock (DoLet false false (PVar "observed") (EApp (EVar "observeMethodSchemeRowsForTest") (ELit LUnit))) (DoExpr (ETuple (EFieldAccess (EVar "observed") "mrtoSchemeIds") (EFieldAccess (EVar "observed") "mrtoSlotBoundIds") (EFieldAccess (EVar "observed") "mrtoSlotPositions") (EFieldAccess (EVar "observed") "mrtoSlotIdsAtPositions") (EFieldAccess (EVar "observed") "mrtoSlotArgumentIds")))))
(DTypeSig false "methodRowFreshnessProbe" (TyFun (TyCon "Unit") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))) (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "methodRowFreshnessProbe" (PWild) (EBlock (DoLet false false (PVar "observed") (EApp (EVar "observeMethodSchemeRowsForTest") (ELit LUnit))) (DoExpr (ETuple (ETuple (EFieldAccess (EVar "observed") "mrtoCounterBefore") (EFieldAccess (EVar "observed") "mrtoCounterAfterFirst") (EFieldAccess (EVar "observed") "mrtoCounterAfterSecond") (EFieldAccess (EVar "observed") "mrtoFirstSchemeIds") (EFieldAccess (EVar "observed") "mrtoSecondSchemeIds")) (ETuple (EFieldAccess (EVar "observed") "mrtoFirstRowSlotIds") (EFieldAccess (EVar "observed") "mrtoSecondRowSlotIds") (EFieldAccess (EVar "observed") "mrtoRegistryAfterSecondSlotIds"))))))
(DTypeSig false "methodRowDeclarationProbe" (TyFun (TyCon "Unit") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Int") (TyCon "Int"))) (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Bool") (TyCon "Int")))))
(DFunDef false "methodRowDeclarationProbe" (PWild) (EBlock (DoLet false false (PVar "observed") (EApp (EVar "observeMethodSchemeRowsForTest") (ELit LUnit))) (DoExpr (ETuple (EFieldAccess (EVar "observed") "mrtoSameNameForward") (EFieldAccess (EVar "observed") "mrtoSameNameReverse") (ETuple (EFieldAccess (EVar "observed") "mrtoConstantRowCount") (EFieldAccess (EVar "observed") "mrtoConstantSchemeIdCount") (EFieldAccess (EVar "observed") "mrtoConstantBodyIsFunction") (EFieldAccess (EVar "observed") "mrtoConstantSlotCount"))))))
(DTypeSig false "methodRowNumericAnchorProbe" (TyFun (TyCon "Unit") (TyTuple (TyCon "Int") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Bool") (TyCon "Bool") (TyCon "String") (TyCon "String"))))))
(DFunDef false "methodRowNumericAnchorProbe" (PWild) (EBlock (DoLet false false (PVar "observed") (EApp (EVar "observeMethodSchemeRowsForTest") (ELit LUnit))) (DoExpr (ETuple (EFieldAccess (EVar "observed") "mrtoAttributedRowCount") (EFieldAccess (EVar "observed") "mrtoAttributedParamIface") (EFieldAccess (EVar "observed") "mrtoAttributedParamTyparams") (EApp (EApp (EMethodRef "map") (EVar "numAnchorObservationView")) (EFieldAccess (EVar "observed") "mrtoNumAnchors"))))))
(DTypeSig true "methodReturnProbeRequest" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodSchemeRow") (TyCon "MethodReturnRequest"))))
(DFunDef false "methodReturnProbeRequest" ((PVar "mctx") (PVar "row")) (EBlock (DoLet false false (PVar "inst") (EApp (EApp (EVar "methodReturnProbeOccurrence") (EVar "mctx")) (EVar "row"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "methodReturnRequest") (EVar "mctx")) (EVar "row")) (EFieldAccess (EVar "inst") "mtiBody")) (EFieldAccess (EVar "inst") "mtiSubstitution")) (EApp (EVar "Some") (EApp (EApp (EVar "freshEvId") (EVar "mctx")) (ELit LUnit)))))))
(DTypeSig false "methodReturnVectorCompletenessProbe" (TyFun (TyCon "Unit") (TyTuple (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Bool") (TyCon "Bool"))))
(DFunDef false "methodReturnVectorCompletenessProbe" (PWild) (EBlock (DoLet false false (PVar "gctx") (EApp (EVar "probeGraphCtx") (ELit LUnit))) (DoLet false false (PVar "mctx") (EApp (EVar "initialModuleCtx") (EVar "gctx"))) (DoLet false false PWild (EApp (EApp (EVar "methodReturnProbeScope") (EVar "mctx")) (ELit (LString "return-vector")))) (DoLet false false (PVar "zeroRow") (EApp (EVar "firstMethodRow") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "mctx")) (EListLit (EApp (EApp (EApp (EApp (EVar "methodRowTestIface") (ELit (LString "return-zero"))) (ELit (LString "Zero"))) (EListLit)) (EListLit (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (ELit (LString "make"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Unit"))) (EVar "None"))) (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None")))) (EVar "None")) (EVar "None")))))))) (DoLet false false (PVar "partialRow") (EApp (EVar "firstMethodRow") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "mctx")) (EListLit (EApp (EApp (EApp (EApp (EVar "methodRowTestIface") (ELit (LString "return-partial"))) (ELit (LString "Partial"))) (EListLit (ELit (LString "a")) (ELit (LString "b")))) (EListLit (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (ELit (LString "make"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Unit"))) (EVar "None"))) (EApp (EVar "TyVar") (ELit (LString "a"))))) (EVar "None")) (EVar "None")))))))) (DoLet false false (PVar "zeroArgs") (EApp (EApp (EMethodRef "map") (EApp (EMethodRef "map") (EVar "ppMono"))) (EApp (EApp (EVar "methodReturnArgs") (EVar "gctx")) (EApp (EApp (EVar "methodReturnProbeRequest") (EVar "mctx")) (EVar "zeroRow"))))) (DoLet false false (PVar "partialArgs") (EApp (EApp (EMethodRef "map") (EApp (EMethodRef "map") (EVar "ppMono"))) (EApp (EApp (EVar "methodReturnArgs") (EVar "gctx")) (EApp (EApp (EVar "methodReturnProbeRequest") (EVar "mctx")) (EVar "partialRow"))))) (DoLet false false (PVar "observed") (ETuple (EVar "zeroArgs") (EVar "partialArgs") (EApp (EApp (EVar "allMethodParamsMentioned") (EFieldAccess (EVar "zeroRow") "msrTyparams")) (EFieldAccess (EVar "zeroRow") "msrType")) (EApp (EApp (EVar "allMethodParamsMentioned") (EFieldAccess (EVar "partialRow") "msrTyparams")) (EFieldAccess (EVar "partialRow") "msrType")))) (DoExpr (EVar "observed"))))
(DTypeSig true "methodReturnTemplatePresenceProbe" (TyFun (TyCon "Unit") (TyTuple (TyApp (TyCon "List") (TyCon "Bool")) (TyApp (TyCon "List") (TyCon "Bool")))))
(DFunDef false "methodReturnTemplatePresenceProbe" (PWild) (EBlock (DoLet false false (PVar "gctx") (EApp (EVar "probeGraphCtx") (ELit LUnit))) (DoLet false false (PVar "mctx") (EApp (EVar "initialModuleCtx") (EVar "gctx"))) (DoLet false false (PVar "present") (EApp (EVar "firstMethodRow") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "mctx")) (EListLit (EApp (EApp (EApp (EApp (EVar "methodRowTestIface") (ELit (LString "return-template-present"))) (ELit (LString "Present"))) (EListLit (ELit (LString "a")) (ELit (LString "b")))) (EListLit (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (ELit (LString "make"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Unit"))) (EVar "None"))) (EApp (EVar "TyTuple") (EListLit (EApp (EVar "TyVar") (ELit (LString "a"))) (EApp (EVar "TyVar") (ELit (LString "b"))))))) (EVar "None")) (EVar "None")))))))) (DoLet false false (PVar "absent") (EApp (EVar "firstMethodRow") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "mctx")) (EListLit (EApp (EApp (EApp (EApp (EVar "methodRowTestIface") (ELit (LString "return-template-absent"))) (ELit (LString "Absent"))) (EListLit (ELit (LString "a")) (ELit (LString "b")))) (EListLit (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (ELit (LString "make"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Unit"))) (EVar "None"))) (EApp (EVar "TyVar") (ELit (LString "a"))))) (EVar "None")) (EVar "None")))))))) (DoLet false false (PVar "observed") (ETuple (EApp (EApp (EMethodRef "map") (EVar "isSome")) (EFieldAccess (EFieldAccess (EVar "present") "msrPredicateTemplate") "mptArguments")) (EApp (EApp (EMethodRef "map") (EVar "isSome")) (EFieldAccess (EFieldAccess (EVar "absent") "msrPredicateTemplate") "mptArguments")))) (DoExpr (EVar "observed"))))
(DTypeSig true "methodReturnProbeCodes" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodSchemeRow") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "ModuleCtx"))))))
(DFunDef false "methodReturnProbeCodes" ((PVar "prev") (PVar "ownedRow") (PVar "impls")) (EBlock (DoLet false false (PVar "gctx") (EVariantUpdate "GraphCtx" (EFieldAccess (EVar "prev") "mcGraph") ((fa "graphRun" (EApp (EVar "freshGraphRun") (ELit LUnit)))))) (DoLet false false (PVar "mctx") (EApp (EApp (EVar "carryModuleCtx") (EVar "gctx")) (EVar "prev"))) (DoLet false false PWild (EApp (EApp (EVar "methodReturnProbeScope") (EVar "mctx")) (ELit (LString "return-owner-checker")))) (DoLet false false (PVar "foreignRow") (EApp (EVar "firstMethodRow") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "mctx")) (EListLit (EApp (EApp (EApp (EVar "methodReturnProbeIface") (ELit (LString "return-foreign"))) (ELit (LString "Foreign"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Unit"))) (EVar "None"))) (EApp (EVar "TyVar") (ELit (LString "a"))))))))) (DoLet false false (PVar "request") (EApp (EApp (EVar "methodReturnProbeRequest") (EVar "mctx")) (EVar "ownedRow"))) (DoExpr (EApp (EApp (EVar "methodReturnProbeSpelling") (EVar "mctx")) (EVar "foreignRow"))) (DoLet false false PWild (EApp (EApp (EVar "recordExactMethodObligation") (EVar "mctx")) (EVar "request"))) (DoLet false false (PVar "universe") (EApp (EVar "buildImplUniverse") (EVar "impls"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "bodyImplEnvRef")) (EApp (EVar "buildFlatImplEnv") (EVar "impls")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkCallObligationsU") (EVar "mctx")) (EVar "True")) (EVar "universe")) (EApp (EVar "wAll") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "implObls")))) (DoExpr (ETuple (EApp (EApp (EMethodRef "map") (EVar "tcCode")) (EApp (EVar "reverseL") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrors") "items") "value"))) (EVar "mctx")))))
(DTypeSig true "methodReturnResolutionMutationProbe" (TyFun (TyCon "Unit") (TyTuple (TyCon "Bool") (TyCon "Bool") (TyCon "Bool") (TyCon "Bool"))))
(DFunDef false "methodReturnResolutionMutationProbe" (PWild) (EBlock (DoLet false false (PVar "gctx") (EApp (EVar "probeGraphCtx") (ELit LUnit))) (DoLet false false (PVar "mctx") (EApp (EVar "initialModuleCtx") (EVar "gctx"))) (DoLet false false PWild (EApp (EApp (EVar "methodReturnProbeScope") (EVar "mctx")) (ELit (LString "return-outcome-validation")))) (DoLet false false (PVar "ownedDecl") (EApp (EApp (EApp (EVar "methodReturnProbeIface") (ELit (LString "return-owner"))) (ELit (LString "Owner"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Unit"))) (EVar "None"))) (EApp (EVar "TyVar") (ELit (LString "a")))))) (DoLet false false (PVar "ownedRow") (EApp (EVar "firstMethodRow") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "mctx")) (EListLit (EVar "ownedDecl"))))) (DoLet false false (PVar "ownedImpl") (EApp (EApp (EVar "methodReturnProbeImpl") (ELit (LString "return-owner"))) (ELit (LString "Owner")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "bodyImplEnvRef")) (EApp (EVar "buildFlatImplEnv") (EListLit (EVar "ownedImpl"))))) (DoLet false false (PVar "request") (EApp (EApp (EVar "methodReturnProbeRequest") (EVar "mctx")) (EVar "ownedRow"))) (DoLet false false (PVar "resolution") (EApp (EApp (EVar "solveExactReturnOnce") (EApp (EVar "siteFor") (EVar "mctx"))) (EVar "request"))) (DoLet false false (PVar "valid") (EApp (EApp (EApp (EVar "methodReturnResolutionValid") (EVar "mctx")) (EVar "request")) (EVar "resolution"))) (DoLet false false (PTuple (PVar "wrongSelection") (PVar "wrongPrerequisites")) (EMatch (EFieldAccess (EVar "resolution") "mrrOutcome") (arm (PCon "Solved" (PCon "InstanceEvidence" PWild (PVar "args") (PVar "prerequisites") (PVar "supers"))) () (ETuple (ERecordCreate "MethodReturnResolution" ((fa "mrrWanted" (EFieldAccess (EVar "resolution") "mrrWanted")) (fa "mrrOutcome" (EApp (EVar "Solved") (EApp (EApp (EApp (EApp (EVar "InstanceEvidence") (EApp (EVar "RequestInstanceId") (EUnOp "-" (ELit (LInt 1))))) (EVar "args")) (EVar "prerequisites")) (EVar "supers")))) (fa "mrrSelectedRow" (EFieldAccess (EVar "resolution") "mrrSelectedRow")))) (ERecordCreate "MethodReturnResolution" ((fa "mrrWanted" (EFieldAccess (EVar "resolution") "mrrWanted")) (fa "mrrOutcome" (EApp (EVar "Solved") (EApp (EApp (EApp (EApp (EVar "InstanceEvidence") (EApp (EVar "RequestInstanceId") (EApp (EVar "methodReturnSelectedIdentity") (EVar "resolution")))) (EVar "args")) (EBinOp "::" (ERecordCreate "PrerequisiteEvidence" ((fa "prerequisiteInterface" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "resolution") "mrrWanted") "predicate") "predicateInterface")) (fa "prerequisiteArguments" (EVar "args")))) (EVar "prerequisites"))) (EVar "supers")))) (fa "mrrSelectedRow" (EFieldAccess (EVar "resolution") "mrrSelectedRow")))))) (arm PWild () (EApp (EVar "panic") (ELit (LString "ordinary return mutation probe expected instance evidence")))))) (DoLet false false (PVar "wanted") (EFieldAccess (EVar "resolution") "mrrWanted")) (DoLet false false (PVar "wrongWanted") (ERecordCreate "Wanted" ((fa "id" (EFieldAccess (EVar "wanted") "id")) (fa "predicate" (EFieldAccess (EVar "wanted") "predicate")) (fa "origin" (EFieldAccess (EVar "wanted") "origin")) (fa "scope" (EApp (EVar "ScopeId") (ELit (LInt 999999)))) (fa "destination" (EFieldAccess (EVar "wanted") "destination"))))) (DoLet false false (PVar "disagreement") (ERecordCreate "MethodReturnResolution" ((fa "mrrWanted" (EVar "wrongWanted")) (fa "mrrOutcome" (EFieldAccess (EVar "resolution") "mrrOutcome")) (fa "mrrSelectedRow" (EFieldAccess (EVar "resolution") "mrrSelectedRow"))))) (DoLet false false (PVar "observed") (ETuple (EVar "valid") (EApp (EVar "not") (EApp (EApp (EApp (EVar "methodReturnResolutionValid") (EVar "mctx")) (EVar "request")) (EVar "wrongSelection"))) (EApp (EVar "not") (EApp (EApp (EApp (EVar "methodReturnResolutionValid") (EVar "mctx")) (EVar "request")) (EVar "wrongPrerequisites"))) (EApp (EVar "not") (EApp (EApp (EApp (EVar "methodReturnResolutionValid") (EVar "mctx")) (EVar "request")) (EVar "disagreement"))))) (DoExpr (EVar "observed"))))
(DTypeSig false "methodReturnProbeSlotCase" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodSchemeRow") (TyFun (TyCon "MethodSchemeRow") (TyFun (TyCon "Bool") (TyTuple (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyCon "ModuleCtx")))))))
(DFunDef false "methodReturnProbeSlotCase" ((PVar "prev") (PVar "ownedRow") (PVar "foreignRow") (PVar "retainOwner")) (EBlock (DoLet false false (PVar "gctx") (EVariantUpdate "GraphCtx" (EFieldAccess (EVar "prev") "mcGraph") ((fa "graphRun" (EApp (EVar "freshGraphRun") (ELit LUnit)))))) (DoLet false false (PVar "mctx") (EApp (EApp (EVar "carryModuleCtx") (EVar "gctx")) (EVar "prev"))) (DoLet false false PWild (EApp (EApp (EVar "methodReturnProbeScope") (EVar "mctx")) (ELit (LString "return-owner-slots")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodPredicateSlotsRef")) (EListLit (ETuple (EApp (EApp (EVar "methodSlotKey") (EFieldAccess (EVar "foreignRow") "msrIface")) (ELit (LString "make"))) (EFieldAccess (EVar "foreignRow") "msrMethodSlots"))))) (DoExpr (EApp (EApp (EVar "methodReturnProbeSpelling") (EVar "mctx")) (EVar "foreignRow"))) (DoLet false false (PVar "env") (EIf (EVar "retainOwner") (EApp (EApp (EApp (EVar "extendMethodRow") (EApp (EVar "envFor") (EVar "mctx"))) (ELit (LString "make"))) (EVar "ownedRow")) (EApp (EApp (EApp (EVar "extendVar") (EApp (EVar "envFor") (EVar "mctx"))) (ELit (LString "make"))) (EFieldAccess (EVar "ownedRow") "msrScheme")))) (DoLet false false (PVar "inst") (EApp (EApp (EVar "instantiateMethodTracked") (EVar "mctx")) (EFieldAccess (EVar "ownedRow") "msrScheme"))) (DoExpr (EApp (EApp (EApp (EVar "unify") (EVar "mctx")) (EApp (EVar "stripArrows") (EFieldAccess (EVar "inst") "mtiBody"))) (EApp (EVar "tupleMono") (EListLit (EApp (EVar "tconBuiltin") (ELit (LString "Int"))) (EApp (EVar "tconBuiltin") (ELit (LString "Int"))))))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordSite") (EVar "env")) (ELit (LString "make"))) (EFieldAccess (EVar "ownedRow") "msrScheme")) (EApp (EVar "Ref") (ELit (LString "")))) (EApp (EVar "Ref") (EVar "RNone"))) (EApp (EVar "Ref") (EListLit))) (EApp (EVar "Ref") (EListLit))) (EApp (EVar "Ref") (EVar "innerNone"))) (EFieldAccess (EVar "inst") "mtiBody")) (EFieldAccess (EVar "inst") "mtiSubstitution"))) (DoExpr (ETuple (ETuple (EApp (EVar "methodReturnProbeOblIfaces") (EApp (EVar "wAll") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "obls"))) (EApp (EVar "methodReturnProbeGoalIfaces") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "goals") "value"))) (EVar "mctx")))))
(DTypeSig false "methodReturnSlotOwnershipProbe" (TyFun (TyCon "Unit") (TyTuple (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "methodReturnSlotOwnershipProbe" (PWild) (EBlock (DoLet false false (PVar "ownedGraph") (EApp (EVar "probeGraphCtx") (ELit LUnit))) (DoLet false false (PVar "ownedCtx") (EApp (EVar "initialModuleCtx") (EVar "ownedGraph"))) (DoLet false false (PVar "ownedRow") (EApp (EVar "firstMethodRow") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "ownedCtx")) (EListLit (EApp (EApp (EApp (EVar "methodReturnProbeIface") (ELit (LString "return-owner-slots"))) (ELit (LString "OwnedSlots"))) (EApp (EApp (EVar "TyConstrained") (EListLit (EApp (EApp (EApp (EVar "methodRowTestConstraint") (ELit (LString "return-seed"))) (ELit (LString "Seed"))) (EListLit (EApp (EVar "TyVar") (ELit (LString "b"))))))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Unit"))) (EVar "None"))) (EApp (EVar "TyTuple") (EListLit (EApp (EVar "TyVar") (ELit (LString "b"))) (EApp (EVar "TyVar") (ELit (LString "a")))))))))))) (DoLet false false (PVar "emptyGraph") (EVariantUpdate "GraphCtx" (EVar "ownedGraph") ((fa "graphRun" (EApp (EVar "freshGraphRun") (ELit LUnit)))))) (DoLet false false (PVar "emptyCtx") (EApp (EApp (EVar "carryModuleCtx") (EVar "emptyGraph")) (EVar "ownedCtx"))) (DoLet false false (PVar "emptyRow") (EApp (EVar "firstMethodRow") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "emptyCtx")) (EListLit (EApp (EApp (EApp (EVar "methodReturnProbeIface") (ELit (LString "return-empty-slots"))) (ELit (LString "EmptySlots"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Unit"))) (EVar "None"))) (EApp (EVar "TyVar") (ELit (LString "a"))))))))) (DoLet false false (PVar "foreignGraph") (EVariantUpdate "GraphCtx" (EVar "ownedGraph") ((fa "graphRun" (EApp (EVar "freshGraphRun") (ELit LUnit)))))) (DoLet false false (PVar "foreignCtx") (EApp (EApp (EVar "carryModuleCtx") (EVar "foreignGraph")) (EVar "emptyCtx"))) (DoLet false false (PVar "foreignRow") (EApp (EVar "firstMethodRow") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "foreignCtx")) (EListLit (EApp (EApp (EApp (EVar "methodReturnProbeIface") (ELit (LString "return-foreign-slots"))) (ELit (LString "ForeignSlots"))) (EApp (EApp (EVar "TyConstrained") (EListLit (EApp (EApp (EApp (EVar "methodRowTestConstraint") (ELit (LString "return-decoy"))) (ELit (LString "Decoy"))) (EListLit (EApp (EVar "TyVar") (ELit (LString "b"))))))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Unit"))) (EVar "None"))) (EApp (EVar "TyTuple") (EListLit (EApp (EVar "TyVar") (ELit (LString "b"))) (EApp (EVar "TyVar") (ELit (LString "a")))))))))))) (DoLet false false (PTuple (PVar "retained") (PVar "retainedCtx")) (EApp (EApp (EApp (EApp (EVar "methodReturnProbeSlotCase") (EVar "foreignCtx")) (EVar "ownedRow")) (EVar "foreignRow")) (EVar "True"))) (DoLet false false (PTuple (PVar "emptied") (PVar "emptiedCtx")) (EApp (EApp (EApp (EApp (EVar "methodReturnProbeSlotCase") (EVar "retainedCtx")) (EVar "emptyRow")) (EVar "foreignRow")) (EVar "True"))) (DoLet false false (PTuple (PVar "missing") PWild) (EApp (EApp (EApp (EApp (EVar "methodReturnProbeSlotCase") (EVar "emptiedCtx")) (EVar "ownedRow")) (EVar "foreignRow")) (EVar "False"))) (DoLet false false (PVar "observed") (ETuple (EVar "retained") (EVar "emptied") (EVar "missing"))) (DoExpr (EVar "observed"))))
