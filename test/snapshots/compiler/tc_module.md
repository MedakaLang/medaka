# META
source_lines=4476
stages=DESUGAR,MARK
# SOURCE
-- tc_module: the per-module check in one order: declarations, top-level groups, test and prop
-- bodies, final checks, the stamp queue and its drain (`enqueueStampCtx`, `stampCtxOf`,
-- `stampNoting`, `stampEach`, `checkGraphFinish`), the binding-id stamping of a module's clauses
-- and tail declarations (`stampGroupClauses`, `stampTailDecls`), the plural site resolution
-- (`resolveSites`, `resolveRLocalSites`, `resolveArithSites`, `resolveOpSites`), the
-- evidence-observation writer (`noteEvidenceObservation` and its entry builders), binder-type
-- materialization, and the registration of imported declarations (the import-overlay rows:
-- `registerImportOverlay`, `overlay*`, `cached*`, `importOverlayDecls`, `oracleImportDecls*`,
-- `reexported*Decl`, `useDefinerRows`); the mark pass's module begin and finish rows
-- (`beginModuleMarking`, `finishModuleMarking`) stay here because `tc_occurrence` is at the A8
-- band when extracted, and a `tc_mark` module would hold them with `methodMarkCtx` and
-- `moduleMarkCtx` (owed, Val).
--
-- Spec: TYPECHECK-CONTRACTS section 3 (scoped scheduling); DICT section 4.2, section 7.1; HM-CORE
-- section 5 (owed, #2555).
--
-- Placement: declarations are placed by R1-R6 of the Phase 4 module table,
-- compiler/ARCHITECTURE-PLAYBOOK.md section 6.
-- Closure rule: this module may not import `types.typecheck`.

import support.diag_codes.{DiagCode(..)}
import frontend.ast.{
  BinderId(..),
  ConPayload(..),
  Decl(..),
  EvEntry(..),
  EvVal(..),
  Expr(..),
  ExternDecl(..),
  FunClause(..),
  Ident(..),
  LetBind(..),
  Loc(..),
  Ns(..),
  Pat(..),
  PropParam(..),
  Route(..),
  Super(..),
  Ty(..),
  TyConOrigin(..),
  UseMember(..),
  UsePath(..),
  Variant(..),
  EvTable,
  identOriginFold,
  mkIdent,
  tyConBuiltin,
}
import types.runtime_types.{
  BinderRow(..), RuntimeType(..), addBinderRow, runtimeTypeOf
}
import types.scopes.{ScopeOwner(..)}
import types.tc_types.{
  BuiltinClasses(..),
  CeRow(..),
  CheckRunSeed(..),
  ClassEnv(..),
  ConstraintReg(..),
  DeclaringBinder(..),
  DeclEnvModule(..),
  DrainFinding(..),
  EnvBinding(..),
  EvCell(..),
  EvDest(..),
  EvidenceObservationEntry(..),
  EvidenceOutcomeKind(..),
  GoalKind(..),
  GoalPayload(..),
  GraphCtx(..),
  GraphMarks(..),
  GroupCtx(..),
  ImplEnv(..),
  LiveGoal(..),
  MethodPredicateSlot(..),
  MethodSchemeRow(..),
  ModuleBindings(..),
  ModuleCtx(..),
  ModuleMarking(..),
  ModuleSeed(..),
  NumBoundary(..),
  NumBoundaryDisposition(..),
  NumGuard(..),
  Obligation(..),
  ObligationSite(..),
  PendingBinder(..),
  PendingEntry(..),
  RecDictApp(..),
  RecordInfo(..),
  ScopedMember(..),
  ScopedScheme(..),
  SiteCtx(..),
  SiteKind(..),
  StampCtx(..),
  StampStep(..),
  StandaloneOrigin(..),
  TcEnv(..),
  dynFor,
  siteFor,
}
import types.evidence_complete.{
  EvidenceRow(..), Inner(..), innerNone, innerOr, rowHoleWith
}
import types.repr.{
  IfaceRef(..), Mono(..), Scheme(..), VecObl(..), normalize, ppMono
}
import map.{Map(..)}
import support.ordmap.{
  omDelete,
  omEmpty,
  omFromNames,
  omFromPairs,
  omHasKey,
  omInsert,
  omKeys,
  omLookup,
  omMapValues,
  OrdMap,
}
import types.evidence.{ScopeId(..)}
import types.registry.{
  regEmpty,
  regKeyOfTab,
  regKeyRender,
  SpellingPop,
  spEmpty,
  spFloor,
  spLookupIdent,
}
import types.effect_solver.{SummaryFailure}
import types.publish.{TcDiag(..), tcLoc}
import types.tc_env.{
  addCtor,
  attachStandaloneSources,
  bindingWithStandalone,
  buildFlatImplEnv,
  ceLookupAt,
  ceRowDoneKey,
  ceRowIface,
  ceRowIfaceName,
  ceRowLoc,
  ceRowOrd,
  ceRowSupers,
  ceRowsVisibleAt,
  ctorExportsIndex,
  declEnvRowVisible,
  declEnvsOrdOf,
  declTopFnNames,
  emptyMethodModulePredicateSlots,
  extendBindings,
  extendLocalVar,
  extendMethodRows,
  extendTermBindings,
  extendVars,
  funDefs,
  graphPubDefiners,
  ieUniverseAt,
  ifaceMethodNames,
  ifaceTabKey,
  importedBindings,
  importLocFor,
  importTableMid,
  legacyMethodSchemes,
  methodRowsByIdentity,
  methodSlotKey,
  namesToSet,
  ordinaryEnvBinding,
  publicDataDecl,
  publicDataDecls,
  withCtors,
}
import types.tc_decls.{
  addFieldOwners,
  builtinClassesGo,
  builtinClassesOf,
  declEnvSeedDataUniverse,
  ifaceMethodSchemeRows,
  isAliasDecl,
  loadDataUniverse,
  recordDeclKinds,
  registerAllData,
  registerAllDataScoped,
  registerData,
  rejectCyclicAliases,
  seedNumLitFromIntAnchor,
  sigToScheme,
}
import types.tc_scope.{
  aliasConstraintEntries,
  aliasDictNames,
  aliasMethodSpellings,
  aliasQualifiedMethodEntries,
  annotateImportedMethodRows,
  applyCtorScopeOverrides,
  applyRecordScopeOverrides,
  declCtorNamed,
  importedMemberBindingNames,
  insertCtorPop,
  insertRecordPop,
  methodNameDeclaredAt,
  pickSchemesByDecl,
  reportAmbiguousImportsIn,
  resolveMemberRows,
  schemeOblEntriesFor,
}
import types.tc_mono.{
  containsI,
  dedupI,
  findTvarInMonos,
  monoArgUnboundIds,
  monoScheme,
  monoUnboundIds,
  resultAfterArrows,
  schemeMono,
  stripArrows,
  tconBuiltin,
  tconUnresolved,
  tyVarNames,
  unquantifiedAuthIds,
}
import support.util.{
  anyList,
  dedup,
  dedupBy,
  filterList,
  isEmptyL,
  isNonEmptyL,
  isSome,
  joinWith,
  lenKey,
  listLen,
  orElseOpt,
  reverseL,
}
import types.tc_occurrence.{
  argDispatchIndicesById,
  constrainedSigNames,
  evIdModule,
  firstMethodRow,
  mapGroupClauses,
  markGroupClauses,
  markRecursiveOccurrences,
  markTailDecls,
  methodReturnProbeCodes,
  methodReturnProbeRequest,
  rebuildGroupDecls,
}
import types.tc_solve.{
  arithEntry,
  currentModuleMarks,
  determineByUniqueInstance,
  dictAppEntry,
  dropGoalsSince,
  goalKindName,
  goalKindTag,
  goalMonos,
  goalsMark,
  goalsOfKindIn,
  goalsSince,
  improveByUniqueImpl,
  methodDictEntry,
  methodReturnArgs,
  methodReturnProbeIface,
  methodReturnProbeImpl,
  methodReturnProbeRouteKey,
  methodReturnProbeScope,
  methodReturnProbeSpelling,
  openScope,
  outerRigidIds,
  recDictAppEntry,
  refileDeterminedRows,
  returnPosMethodNames,
  routesOfMonosTopV,
  siteEntry,
  uOblArgs,
}
import types.effect_authority.{authvarId, authVars}
import types.tc_effects.{
  beginEffectSummaryScope,
  borrowedEffectCells,
  checkEffectEscape,
  checkUndeterminedRetEffVars,
  clausesOf,
  finishEffectSummaryScopeKeeping,
  flushPendingEscapes,
  freshEffectSummary,
  grantNameIn,
  memberEffectRoots,
  recordFileBound,
  recordMethodGrants,
  recordTopGrants,
  reportEffectSummaryFailures,
}
import types.tc_state.{
  blankModuleCtx,
  callUOblsWindow,
  carryModuleCtx,
  checkRunResidue,
  currentScopeStore,
  dynAtIfSome,
  enterStampCtx,
  envAtIfSome,
  freshGraphRun,
  freshModuleCtx,
  initialModuleCtx,
  mctxAt,
  moduleCtxFrom,
  moduleWindow,
  plainModuleSeed,
  probeGraphCtx,
  seedCheckRun,
  wMark,
  wWindow,
}
import types.tc_solve_check.{
  callOblsWindow,
  checkCallObligationsU,
  checkSigVarGoals,
  dedupPredicateSlotsTable,
  defaultLiveNumRoots,
  finalizeNumBoundary,
  liveNumVarGo,
  numConstrainedIds,
  predicateSlotTableWithoutArgs,
  registerConstraintRegs,
  registerInferredConstraints,
  rejectUndeterminedVectors,
  rejectWithheldAmbiguity,
  setFunPredicateSlots,
  tiedSurvivors,
  undeterminedVectorVerdict,
}
import types.tc_global.{
  calleeNumObls,
  checkCoherence,
  checkGradedImplHeads,
  checkImplCompletenessMap,
  checkPhantomMethods,
  checkSuperImpls,
  inferDefaultBodies,
  inferUserImplBodies,
  numCallObls,
}
import types.tc_unify.{
  captureScope,
  closeScope,
  enterLevel,
  exitLevel,
  freshTvMap,
  freshVar,
  generalize,
  resolvePendingJoins,
  rowInto,
  unifyIn,
  unifyInto,
  widenOpenedFor,
}
import types.tc_shadow.{
  checkAdmittedOccObls,
  definerShadowsFromSet,
  isPreludeMid,
  moduleMarkCtx,
  nameableIfaceMethodSet,
  nameableIfaceRows,
  nameableIfaceShadows,
  resolveRLocalSite,
  standaloneShadowsFromSet,
}
import types.tc_decls_types.{
  checkDeclaredKinds,
  checkDeclAuthorityUses,
  checkEffectParams,
  fromAstType,
}
import types.tc_infer.{
  checkDeferredMatches,
  checkFixedWidthLiterals,
  checkWideLiterals,
  declareRigidVars,
  infer,
  inferMemberClauses,
  preunifySigsEx,
  valueSpanLoc,
}
import types.tc_groups.{
  checkLetRecDecls,
  checkRecursiveValue,
  checkSigConstraintCoverage,
  checkSigsFixedByExpansive,
  checkSigsOverExpansive,
  checkSigsTooGeneral,
  declRefNames,
  depGraphMap,
  groupClauses,
  groupNames,
  isLetrecGroup,
  memberForce,
  nestedRequireGoals,
  quantifiableAuthorities,
  registerSchemeObligations,
  sccProtectedSignatureIds,
  sccSchemes,
}
import types.tc_diag_text.{
  cyclicSuperIfaceMsg, locGoalKey, locKey, ordinalSentinelMsg
}
import types.effect_rows.{effrowNorm, pureRow}
import frontend.desugar.{exprSpanLoc, joinLocs}
import types.tc_foreign.{
  declExternNames,
  directExternSigs,
  externDecls,
  ffiCheckExternsCatalogRow,
  ffiCheckExternsCrossable,
  ffiCheckExternsLabelled,
  ffiCheckExternsShadow,
  ffiStampMode,
}
import frontend.resolve.{
  externTyOriginScope,
  firstExprLoc,
  stampClauseWith,
  stampDeclWith,
  stampTopScope,
  stampTyOrigins,
}
import list.{findMap, sortOn}
import types.tc_solve_entail.{ieSelectRowByIface, rowRouteKey}
import types.effect_bindings.{newBindingSummary}
import types.tc_diag.{pushTypeError, pushTypeErrorAt}
import types.tc_elab.{
  realizeRecDictApps,
  resolveAdmittedSite,
  resolveArgStamps,
  resolveArithSite,
  resolveDictApps,
  resolveExactReturnSite,
  resolveMethodDicts,
  resolveNumLitSite,
  resolveOpSite,
  resolvePredicateOpSite,
  resolveSite,
  selfDeclArities,
}
import types.tc_pat.{recordBinderType, settleDeferredPatLits}
import types.tc_infer_records.{recordFieldNames}
import types.invocation_basis.{recordInvocationView}
import types.tc_decls_variance.{seedParamPolarityFixpointScoped}
import support.scc.{tarjanSCCs}
import frontend.visibility.{useModId}
import map as IdMap
import types.effect_solver as EffectSolver
import types.scopes as Scopes

-- Every route a goal carries, in slot order — one for a site, one per slot for
-- a dictionary application.
obligationRoutes : Obligation -> List Route
obligationRoutes o = match o.oDest
  EvRoute r => [r.value]
  EvRoutes rs => rs.value

-- The predicate mono behind each slot, aligned by position with
-- `obligationRoutes`'s answer for the SAME obligation. `GKMethodDict`'s slots
-- carry an `IfaceRef`/`PredicateSlotArgs` pair rather than a `Mono` (#8251), so
-- it answers `None` per slot rather than reconstructing one.
obligationPredicateMonos : Obligation -> List (Option Mono)
obligationPredicateMonos o = match o.oPayload
  GPSite _ m _ => [Some m]
  GPArith m => [Some m]
  GPDictApp app => map Some app.pdaMonos
  GPMethodDict pmd => map (_ => None) pmd.pmdSlots
  GPRecDictApp (RecDictApp _ _ _ m _ _) => [Some m]

routeOutcomeKind : Route -> EvidenceOutcomeKind
routeOutcomeKind RNone = EOKNone
routeOutcomeKind (RKey _ _ _) = EOKInstance
routeOutcomeKind (RDict _) = EOKGiven
routeOutcomeKind (RDictFwd _) = EOKGiven
routeOutcomeKind (RLocal _ _) = EOKLocal
routeOutcomeKind (RScalar _) = EOKScalar
routeOutcomeKind (RProj r _) = routeOutcomeKind r

routeGivenBinder : Route -> Option String
routeGivenBinder (RDict n) = Some n
routeGivenBinder (RDictFwd n) = Some n
routeGivenBinder (RProj r _) = routeGivenBinder r
routeGivenBinder _ = None

routeInstanceKey : Route -> Option String
routeInstanceKey (RKey k _ _) = Some k
routeInstanceKey _ = None

-- The nested route list an `RKey`/`RLocal` packs at this slot: the packed
-- `requires`, exactly as `entailInst` produces them.
routePrerequisiteRoutes : Route -> List Route
routePrerequisiteRoutes (RKey _ rs _) = rs
routePrerequisiteRoutes (RLocal _ rs) = rs
routePrerequisiteRoutes _ = []

renderRouteIdentity : Route -> String
renderRouteIdentity RNone = "RNone"
renderRouteIdentity (RKey k _ _) = "RKey " ++ k
renderRouteIdentity (RDict n) = "RDict " ++ n
renderRouteIdentity (RDictFwd n) = "RDictFwd " ++ n
renderRouteIdentity (RLocal n _) = "RLocal " ++ n
renderRouteIdentity (RScalar n) = "RScalar " ++ n
renderRouteIdentity (RProj r path) =
  "RProj (\{renderRouteIdentity r}) \{joinWith "." (map intToString path)}"

noteEvidenceObservation : GraphCtx -> Obligation -> Unit
noteEvidenceObservation gctx o = match gctx.trace
  Some sink =>
    if sink.tsEvidenceObservationEnabled then
      let routes = obligationRoutes o
      let predicates = obligationPredicateMonos o
      let arity = listLen routes
      sink.tsEvidenceObservationEntries :=
        evidenceObservationEntriesGo o routes predicates arity 0
          ++ sink.tsEvidenceObservationEntries.value
  None => ()

evidenceObservationEntriesGo : Obligation ->
  List Route ->
  List (Option Mono) ->
  Int ->
  Int ->
  List EvidenceObservationEntry
evidenceObservationEntriesGo _ [] _ _ _ = []
evidenceObservationEntriesGo o (r :: rs) preds arity slot =
  let (predHere, predsRest) = match preds
    p :: ptail => (p, ptail)
    [] => (None, [])
  EvidenceObservationEntry {
      eoeEv = o.oEv,
      eoeGoalKind = goalKindName o.oKind,
      eoeSlot = slot,
      eoeArity = arity,
      eoePredicate = map ppMono predHere,
      eoeOutcome = routeOutcomeKind r,
      eoeGivenBinder = routeGivenBinder r,
      eoeInstanceKey = routeInstanceKey r,
      eoePrerequisites = map renderRouteIdentity (routePrerequisiteRoutes r),
      eoeScope = o.oScope,
    }
    :: evidenceObservationEntriesGo o rs predsRest arity (slot + 1)

-- Each channel's length as this module begins.
graphMarksNow : GraphCtx -> Unit -> GraphMarks
graphMarksNow gctx _ = GraphMarks {
  mGoals = gctx.graphRun.goalsN.value,
  mNumlit = gctx.graphRun.numlitN.value,
}

recordModuleStart : GraphCtx -> String -> Unit
recordModuleStart gctx mid =
  gctx.graphRun.moduleRanges :=
    (mid, graphMarksNow gctx ()) :: gctx.graphRun.moduleRanges.value

-- Generalize each captured local binding's (now-solved) mono into a Scheme for
-- the LSP hover fallback (see localBindRefs).  Runs at the end of inference when
-- currentLevel is back at the top, so a still-free local var quantifies cleanly
-- to `a`; a ground var (e.g. a `let` bound to a String) renders concretely.
mapLocalSchemes : ModuleCtx ->
  List (String, Option Loc, Mono) ->
  List (String, Option Loc, Scheme)
mapLocalSchemes mctx [] = []
mapLocalSchemes mctx ((n, l, m) :: rest) =
  (n, l, generalize mctx m) :: mapLocalSchemes mctx rest

-- Seed the table from the declaration list THIS pass treats as the prelude, so that a
-- synthetic occurrence's key and the prelude's own `impl Num Int` key agree.
--
-- The source list is chosen for symmetry with `insertUnivImpl`, which is what
-- correctness depends on — not for tidiness.  `insertUnivImpl` keys the impl side off
-- `DImpl.implOrigin`, so this side must read the origin of the interface declaration
-- that lives in the SAME universe:
--   * With a real prelude, the prelude pass installs all four identities from `core`.
--   * Once a non-empty prelude has been seeded, a later module contributes nothing: a
--     program interface spelled `Eq` is not the prelude's, whatever the prelude lacks.
--   * In a prelude-free graph, builtin declarations can be split across modules.
--     Each module contributes only identities not already present, so Eq→Num and
--     Num→Eq module orders retain both identities without allowing a later duplicate
--     declaration to replace an earlier one.
seedBuiltinClasses : GraphCtx -> String -> List Decl -> Unit
-- Both spellings of the prelude's module id are tested, for the same reason
-- `declEnvsOrdOf` indexes it twice: the export indexes (`meExports`,
-- `deCtorExports`) key the prelude under `"core"`, but the `mid` `graphPreamble`
-- actually PASSES for the core pass is `""` on both output selections
-- (`GOutDiags`: `checkModuleFull` → `checkModuleFullImpl ""`;
-- `GOutTrees`: `elabModuleStamp ""`).  Testing
-- only `"core"` would silently never fire on either selection — and the miss is silent
-- because an unseeded table yields `OriginUnresolved`, i.e. a `TkBare` goal key against
-- `TkIdent` impls: a false REJECT of the prelude, which is the #1112 prototype's
-- 634-diagnostic signature.
seedBuiltinClasses gctx mid prog =
  if isPreludeMid mid then
    let seeded = builtinClassesOf prog
    gctx.crossRun.builtinClassesRef :=
      BuiltinClasses { seeded | bcPreludeSeeded = isNonEmptyL prog }
  else if gctx.crossRun.builtinClassesRef.value.bcPreludeSeeded then
    ()
  else
    gctx.crossRun.builtinClassesRef :=
      builtinClassesGo prog gctx.crossRun.builtinClassesRef.value

-- Publish every top-level function clause and top-level let-group member under
-- the scheme its group generalized to, mirroring the decl shapes `funDefs`
-- flattens.  Each clause of a multi-clause function has its own id and records
-- the one scheme, and whether the module declares a signature for its name.
recordTopBinderTypes : GraphCtx -> OrdMap Scheme -> List Decl -> Unit
recordTopBinderTypes gctx schemes decls =
  let signed = signedTopNames decls omEmpty
  each (recordTopDeclBinderTypes gctx schemes signed) decls

-- The names a top-level type signature declares, an annotated one included.
signedTopNames : List Decl -> OrdMap Unit -> OrdMap Unit
signedTopNames [] acc = acc
signedTopNames ((DTypeSig _ n _ _) :: rest) acc =
  signedTopNames rest (omInsert n () acc)
signedTopNames ((DAttrib _ d) :: rest) acc = signedTopNames (d :: rest) acc
signedTopNames (_ :: rest) acc = signedTopNames rest acc

recordTopDeclBinderTypes : GraphCtx ->
  OrdMap Scheme ->
  OrdMap Unit ->
  Decl ->
  Unit
recordTopDeclBinderTypes gctx schemes signed (DFunDef _ n ps _ _ bid) =
  recordTopFunBinderType gctx schemes signed n bid (listLen ps)
recordTopDeclBinderTypes gctx schemes signed (DLetGroup _ binds) =
  fold
    (_ b => match b
      LetBind n clauses _ bid => match clauses
        (FunClause ps _) :: _ =>
          recordTopFunBinderType gctx schemes signed n bid (listLen ps)
        [] => recordTopFunBinderType gctx schemes signed n bid 0)
    ()
    binds
recordTopDeclBinderTypes gctx schemes signed (DAttrib _ d) =
  recordTopDeclBinderTypes gctx schemes signed d
recordTopDeclBinderTypes gctx _ _ _ = ()

recordTopFunBinderType : GraphCtx ->
  OrdMap Scheme ->
  OrdMap Unit ->
  String ->
  BinderId ->
  Int ->
  Unit
recordTopFunBinderType gctx schemes signed n bid arity =
  match omLookup n schemes
    Some sch =>
      recordBinderType
        gctx
        bid
        n
        (schemeMono sch)
        (Some arity)
        (omHasKey n signed)
    None => ()

resolveSites : SiteCtx -> OrdMap Unit -> List PendingEntry -> Unit
resolveSites sx _ [] = ()
resolveSites sx rpNames ((PendingEntry name tagRef resultMono encl kind loc scope _) :: rest) =
  let sx = { sx | sxSite = loc }
  match kind
    SKReturn implRef fullMono =>
      resolveSite
        sx
        rpNames
        name
        tagRef
        implRef
        resultMono
        fullMono
        encl
        loc
        scope
    SKAdmittedReturn ifaceRef implRef fullMono =>
      resolveAdmittedSite sx name ifaceRef tagRef implRef fullMono encl scope
    SKExactReturn implRef request =>
      resolveExactReturnSite
        sx
        rpNames
        name
        tagRef
        implRef
        resultMono
        request
        encl
        loc
        scope
    SKNumReturn predicate fullMono =>
      resolveNumLitSite
        sx
        rpNames
        name
        tagRef
        resultMono
        fullMono
        predicate
        encl
        loc
        scope
    _ => ()
  resolveSites sx rpNames rest

-- C5: stamp RLocal on each recorded standalone-shadow arg-position site whose
-- receiver mono now grounds to a concrete head tycon with NO impl of the method.
-- The receiver HAS an impl (the genuine-method case, e.g. `toList (Some 7)`) → leave
-- the route untouched (RNone → eval arg-tag-dispatches to the real impl).  An
-- ungrounded receiver (still a tyvar) → leave it (polymorphic, deferred).
-- RLocal only when no impl exists.
-- S-1: the stamp calls routesOfMonosTop — a PURE
-- function of the (union-find-solved) constraint monos — to fill the standalone's own
-- dict routes IN PLACE.  Deliberately NOT routed through pendingDictApps: that list is
-- resolved by resolveDictApps, which runs AFTER this in `moduleStampOrder`, so the stamp
-- would read `[]`.  Resolving inside the stamp is ordering-immune.  An unconstrained
-- standalone has no monos ⇒ routesOfMonosTop returns [] immediately (it cannot even
-- reach its AmbiguousImpl arm) ⇒ `RLocal sym []` ⇒ byte-identical to the pre-S1 stamp.
-- #156 S3d — resolveRLocalSites is DELIBERATELY NOT routed through `entail`, and DICT-
-- SEMANTICS §3 conformance REQUIRES that, rather than merely permitting it.  This pass
-- implements §4 `(var)`'s FIRST premise — binding selection: does this occurrence denote the
-- module's own standalone `sym` or a shadowed interface method?  (Keyed on the solved receiver
-- mono, which is why it runs post-inference.)  That decision reads shadow facts — isDefinerShadow,
-- definerShadowNamesRef — that are NOT components of entailment's domain `(IE, CE, P, π)` (§3
-- resolution-determinism); they are facts about Γ.  Folding them into the one entailment function
-- would make it depend on inputs outside its spec-given domain — violating the very law a merge
-- would invoke.  The tell: the `Some tag` arm treats "a live impl exists" as DO-NOTHING (the name
-- is a genuine method, dispatched elsewhere) and emits RLocal for the NO-impl case — the inverse of
-- `entailInst`'s success condition.  "No π to discharge; the name denotes another binding" is not an
-- evidence statement.  §4 `(var)`'s SECOND premise — the chosen standalone's actual entailment
-- obligations — IS routed through the one engine: every RLocal payload is filled by routesOfMonosTop
-- → entail (EKNestedTop).  So the single-entailment-function law holds at 4-of-5 BY CONSTRUCTION; what
-- stays out is exactly the binding-selection axis §3 never claimed (cf. §8 I1: identity keyed by
-- binding, not bare name).  "Does an impl exist" and "which impl entails" must agree on ONE
-- impl table — a drift between them would be a real dispatch bug.  The agreement is
-- STRUCTURAL, not a standing obligation: both reads name ONE population, the graph-global
-- `ModuleCells.mcCells.bodyImplEnvRef`.  `ieImplExistsForHead …bodyImplEnvRef…` answers
-- existence directly, and `keyForSite` (also on `bodyImplEnvRef`) selects via
-- routesOfMonosTop → routeOf → entail (EKNestedTop) → entailInst.  It is enforced by a
-- shared REF, not by a threaded parameter: no impl list is threaded through this signature
-- or through `routesOfMonosTop`'s subtree.  The check on any edit here is "does the thing I
-- am reading answer over the same population `keyForSite` selects from?".  A split is
-- observable: existence answered True off the whole graph while `routesOfMonosTop` had no
-- row to select turns a located reject into exit 0 printing a garbage pointer.
-- The inference-time existence reads in `inferShadowApp` / `definerReceiverDispatches` are
-- the same decision at an earlier PHASE and read the same ref: a phase split of one decision
-- is as fatal as a table split.
-- Do not describe the population as "GLOBAL by design — local ∪ imported ∪ prelude":
-- `SHADOW-SEMANTICS.md:242-245` retires that phrase as a false synonym for graph-global.
resolveRLocalSites : SiteCtx -> List PendingEntry -> Unit
resolveRLocalSites sx [] = ()
resolveRLocalSites sx ((PendingEntry name tagRef am encl kind loc scope _) :: rest) =
  let sx = { sx | sxSite = loc }
  match kind
    SKRLocal sym forceLocal monos ifaces argVecs =>
      if forceLocal then
        tagRef :=
          RLocal sym (routesOfMonosTopV sx encl scope monos ifaces argVecs)
      else
        resolveRLocalSite sx name tagRef am encl scope sym monos ifaces argVecs
    _ => ()
  resolveRLocalSites sx rest

-- After the module is inferred, classify each recorded arithmetic operand mono and
-- stamp the supported concrete scalar tag on the node's route. Grounded-only,
-- exactly like resolveBinopSite: a still-
-- polymorphic operand (headTyconMono None) is left untouched (RNone → dict path),
-- so polymorphic-Num arithmetic keeps routing through the runtime Num dict. Never
-- overwrite a route another pass already set (a comparison op has a different
-- node/ref; an arithmetic route starts RNone).
resolveArithSites : List (Ref Route, Mono) -> Unit
resolveArithSites [] = ()
resolveArithSites ((dref, m) :: rest) =
  resolveArithSite dref m
  resolveArithSites rest

-- EBinOp and EUnOp share ONE dict-route resolution family
-- (resolveOpSites/resolveOpSite/stampOpRouteVal/opDictVarOf), selected by an `isBinop`
-- flag (Roadmap #18c collapsed the binop/unop mirror pair — unopMethodApp already
-- reused binopRouteSplit, proving the shapes unify).  The two paths differ in exactly
-- two flag-keyed places: the dict-var-of policy (opDictVarOf) and the RKey stamp
-- (stampOpRouteVal — its builtin-head guard and Ord-style innerDefaultMethod reduction).
-- #156 S3c: resolveOpSite is now a thin adapter over `entail` (EKOp kind); the inst
-- route is stampOpRouteVal, a pure Route-returning extraction of the old stampOpRoute.
resolveOpSites : SiteCtx -> Bool -> List PendingEntry -> Unit
resolveOpSites sx _ [] = ()
resolveOpSites sx isBinop ((PendingEntry method tagRef operandMono encl kind loc scope _) :: rest) =
  let sx = { sx | sxSite = loc }
  match kind
    SKOp inImpl =>
      resolveOpSite sx isBinop method tagRef operandMono inImpl encl scope
    SKPredicateOp inImpl predicate =>
      resolvePredicateOpSite
        sx
        isBinop
        method
        tagRef
        operandMono
        inImpl
        predicate
        encl
        scope
    _ => ()
  resolveOpSites sx isBinop rest

-- ── WS-4a: cyclic superinterface detection ────────────────────────────────
-- A cyclic `interface A requires B; interface B requires A` is ill-formed: no
-- impl can ever be constructed (each demands the other) and the transitive
-- evidence resolver would diverge.  DFS over the `requires` graph; if any node
-- is re-encountered on the current DFS stack, report the cycle.
-- Runs over ALL interfaces in scope (prelude + user) — a prelude cycle would
-- be equally ill-formed.  The `done` ref tracks fully-explored nodes to avoid
-- redundant traversal and re-reporting multi-root cycles.
-- Nodes are `CeRow`s of stage K's `CE`, and an edge is followed by IDENTITY:
-- `ceLookupAt (regKeyOfTab (ifaceTabKey superOrigin superHead))`.  A bare-name scan of a decl
-- list would resolve a superinterface edge to whichever same-spelled interface appeared first
-- in the concatenation of every module's decls: two unrelated modules each declaring `Same`
-- would collapse into one node, `mod_a.Same requires mod_b.Same` could be reported as a
-- self-cycle it is not, and a genuine cycle could be masked by the other module's row
-- winning the scan, with import order selecting the symptom.  `Super` carries `superOrigin`
-- and `resolve.mdk` stamps it through the SAME `mapSuperOcc`/`tyOriginScope` walk that stamps
-- a `DImpl`'s `implOrigin`, so the occurrence and the `DInterface`'s `ifaceOrigin`
-- declaration layer meet for the same reason `ifaceTabKey`'s header argues for the
-- impl-head key.  The `done` set and the DFS `path` are keyed on `regKeyRender` rather than
-- the bare name for the identical reason.
--
-- The miss arm is an abstention, and it is the one place this could go
-- LOUD→SILENT.  An edge whose target is not in `CE` at this ordinal yields `None` and
-- the walk stops — the same disposition `ifaceSupersOf`'s `None` arm already had
-- ("unknown interface, reported elsewhere"), and resolve rejects an interface naming
-- an unknown superinterface before typecheck runs.  A super whose identity fails to
-- resolve MISSES where a bare name would hit.  That is
-- why the abstention arm needs a POSITIVE control -- a shape whose edge MUST still be
-- followed -- rather than only a negative one.
--
-- Cite fixtures that exist, and check what actually consumes them.  The gate
-- for this arm is `test/diff_compiler_fmt_test.mdk`'s `typecheckErrorFailures`,
-- which walks its fixture directory RECURSIVELY via `fixtureFiles` -- so a
-- directory-nested fixture IS discovered and consumed.  No gate catches a wrong
-- citation here: `make docs-links` and `make agent-doc-symbols` do not scan
-- compiler comments.  It matters more than a typo because this is the one
-- sentence answering "is the abstention arm covered?", and a citation like
-- that gets relayed into the next unit's design as an established fact.  The
-- real controls, both verified to reject on this binary:
--   * MULTI-MODULE: `test/analyze_project_fixtures/1557_a35c_cycle_masked_by_samespelled/`
--     (consumed by `test/diff_compiler_fmt_test.mdk`'s `analyzeProjectFixtureFailures`)
--     -- its edge must resolve BY IDENTITY for the fixture to pass at all, so
--     an abstention that swallowed a real edge reds it.
--   * FLAT: `test/dict_fixtures/s3-w1-cyclic-superinterface-rejected.mdk` (no imports)
--     and `test/typecheck_error_fixtures/cyclic_superinterface.mdk`.
-- The negative direction -- an edge that must NOT be followed -- is
-- `1557_a35c_samespelled_iface_bystander/`.  The set is the assertion; no member is.
--
-- ROOTS are `ceRowsVisibleAt` — the reading module's whole ordinal prefix: {prelude} ∪
-- {every earlier module in full} ∪ {this module}, members and order.  `accAll` is
-- seeded with the WHOLE `coreDecls` and grown `accAll ++ prog` (not `publicDataDecls
-- prog`; only `accData` is public-filtered) and every Module-arm driver runs
-- `AccumulateBoth`, so the prefix is the full set.  `CE` at this ordinal is that set in
-- ordinal order.
--
-- `accAll` is not public-filtered, so a PRIVATE interface of an earlier module is a
-- root: a module declaring a PRIVATE cyclic interface pair has that cycle reported in
-- a sibling module with NO import path to it.  The root set is the full prefix, with
-- no widening or narrowing by visibility.
checkInterfaceCycles : ModuleCtx -> List Decl -> ClassEnv -> Int -> Unit
checkInterfaceCycles mctx prog ce cur =
  -- #973: `done` is an OrdMap-backed SET (omHasKey/omInsert), NOT a growing `List` scanned
  -- by `contains`.  The membership test ran once per interface over the fully-explored
  -- set, which grows to the interface count → O(interfaces^2), the flat-path
  -- `manyifaces:typecheck` op-count quadratic (independent of use sites — it surfaces on a
  -- file of N cycle-free interfaces).  Keyed into a set it is O(log n): `done` only prunes
  -- already-explored nodes (set membership is order-insensitive), and the DFS order +
  -- cycle messages are driven by `path`/the root list.  The key is `regKeyRender`, not a
  -- bare name.
  let done = Ref omEmpty
  each (checkOneIfaceCycle mctx prog ce cur done) (ceRowsVisibleAt cur ce)

-- #152: the whole-program final-checks tail, shared by all five entry points
-- (the `checkOne*` projections and `checkModuleFullDiags`). [cohDecls] feeds coherence and
-- checkSuperImpls's impl-iteration argument.
-- trap #5: coherence must see USER decls only, so
-- this helper has NO access to `prog` — the caller decides [cohDecls] explicitly
-- (never a `prog` fallback).  Call ORDER is load-bearing (all push into typeErrors).
--
-- Two of the four members read stage K's `CE` instead of a decl list.  [ownCe]/[cycCe] are
-- the class environments the caller is entitled to read and [cur] is the READING module's
-- ordinal — Module passes the whole-graph `deIfaces` twice with its own ordinal; Flat passes
-- two single-module envs built from the very lists it hands
-- `checkPhantomMethods`/`checkInterfaceCycles`, at ordinal 0 in the standalone-list
-- compatibility helper; reading a graph envelope there would switch both checks silently OFF.
--
-- Call order is load-bearing and deliberate: coherence runs first, then cycles, then
-- phantom, then super-impls, so no diagnostic changes rank against another family.  Pulling
-- a member OUT of this sequence re-orders every accumulated diagnostic after it.
-- The super-impl check reads stage K too, taking [cycCe] and [cycIe] at the same ordinal.
-- Both envs must be built over the same population: the whole-graph `deImpls` with the
-- reader's own ordinal on the Module arm, `buildFlatImplEnv` of the one list the Flat callers
-- hand `cycCe`'s peer.
-- Coherence reads stage K too, so this helper carries TWO `IE`s for the same reason it
-- carries two `CE`s — [cohIe] is the env over the population [cohDecls] names (the USER
-- boundary, trap #5) and [cycIe] is built over the whole-graph population.  They are the
-- same env only on the paths where those two populations are already the same.  [cohIe] must
-- contain the prelude at ordinal 0, since coherence pairs the module's own rows with the
-- prelude's.
--
-- The `-1` sentinel is fail-closed here, and it has to be announced at this reader.  [cur]
-- is `declEnvsOrdOf mid` on the Module arm, whose miss
-- value is `0 - 1` (see that function: a miss is documented fail-CLOSED, and it says in
-- so many words that the remedy for a stray id is at the READER — "abstain loudly / fail
-- the pass" — never a sentinel that means "everything").  All four members below take
-- [cur], and at `-1` they abstain in OPPOSITE directions: `checkCoherence` takes
-- `cohRowsOwnedBy -1` → no rows → **it checks nothing, silently**;
-- `checkInterfaceCycles`/`checkPhantomMethods` take
-- `ceRowsVisibleAt -1`/`ceRowsOwnedBy -1` → likewise nothing; and `checkSuperImpls`,
-- whose row read is `ieCandidacyVisibleAt`, still finds no SUPERS
-- (`ceLookupAt … -1`) and so also reports nothing.  So the whole tail degrades to a
-- SILENT ACCEPT — a loud→silent transition, which this repo ranks as a severity increase
-- even while unreachable.
-- Unreachable today, and the guard is still right.  The three drivers pass either a
-- literal `0` (both Flat entries) or `declEnvsOrdOf mid` over the very list
-- `buildDeclEnvs` indexed, so no live path can arrive at `-1`; a fourth Module-mode
-- driver, or any path stamping a mid `buildDeclEnvs` did not index, makes it live.  It
-- cannot fire spuriously, because `cur < 0` is exactly and only the miss sentinel and no
-- caller can construct a negative ordinal otherwise.
-- 🎯 What this does *not* cover, stated because it is the near miss: a driver that
-- threads a VALID-but-WRONG ordinal (some other module's) is undetectable here — the
-- sentinel is the only self-identifying failure — and `globalCoherenceConflict` takes no
-- ordinal at all (`cohRowsOf`, whole graph), so it is outside this guard entirely.
runFinalChecks : ModuleCtx ->
  List Decl ->
  ClassEnv ->
  ClassEnv ->
  ImplEnv ->
  ImplEnv ->
  Int ->
  Unit
runFinalChecks mctx cohDecls ownCe cycCe cohIe cycIe cur =
  ordinalSentinelGuard mctx cur
  checkCoherence mctx cohIe cur
  checkInterfaceCycles mctx cohDecls cycCe cur
  checkPhantomMethods mctx ownCe cur
  checkSuperImpls mctx cohDecls cycCe cycIe cur

-- The sentinel guard is split out so the arm is a guard and not a `whenL`.  Medaka is strict:
-- `whenL (cur < 0) (pushTypeError …)` would evaluate the push on EVERY call — the
-- documented not-a-stub trap.  A guarded function does not.
ordinalSentinelGuard : ModuleCtx -> Int -> Unit
ordinalSentinelGuard mctx cur
  | ordinalIsSentinel cur =
    pushTypeError mctx TInternalOrdinal ordinalSentinelMsg
  | otherwise = ()

-- is [cur] `declEnvsOrdOf`'s miss sentinel?  A real ordinal is an index into the list
-- `buildDeclEnvs` was handed, so it is >= 0 by construction; `0 - 1` is the only negative
-- value any producer in this file yields.
-- > ordinalIsSentinel (0 - 1)
-- True
-- > ordinalIsSentinel 0
-- False
-- > ordinalIsSentinel 3
-- False
ordinalIsSentinel : Int -> Bool
ordinalIsSentinel cur = cur < 0

checkOneIfaceCycle : ModuleCtx ->
  List Decl ->
  ClassEnv ->
  Int ->
  Ref (OrdMap Unit) ->
  CeRow ->
  Unit
checkOneIfaceCycle mctx prog ce cur done row =
  if not (omHasKey (ceRowDoneKey row) !done) then
    each
      (pushTypeError
        (mctxAt
          (cycleReportLoc mctx.mcGraph.declEnvsRef.value.deReach prog cur row)
          mctx)
        TCyclicSuperinterface)
      (ifaceDfsCycle ce cur done [row] row)

-- A cycle is reported at the name of the interface its walk started from when
-- the reading module [cur] declares it.  A module that only sees it reports it
-- at its import of the declaring module, or else at its first import of a
-- module that reaches the declaring one ([reach], each module's import
-- closure): the interface's span is in another file.  A module with no import
-- path to it reports it with no span.
cycleReportLoc : OrdMap (OrdMap Unit) -> List Decl -> Int -> CeRow -> Option Loc
cycleReportLoc reach prog cur row
  | ceRowOrd row == cur = ceRowLoc row
  | otherwise = match (ceRowIface row).irOrigin
    OriginModule owner => importLocFor reach prog owner
    _ => None

-- DFS from [current]; [path] is the stack of ROWS visited so far (including
-- [current] as its last element, from which the cycle message is reconstructed).
-- Marks [current] as done after all its supers are explored.
ifaceDfsCycle : ClassEnv ->
  Int ->
  Ref (OrdMap Unit) ->
  List CeRow ->
  CeRow ->
  List String
ifaceDfsCycle ce cur done path current =
  let msgs = ifaceDfsCycleSupers ce cur done path (ceRowSupers current)
  done := omInsert (ceRowDoneKey current) () !done
  msgs

ifaceDfsCycleSupers : ClassEnv ->
  Int ->
  Ref (OrdMap Unit) ->
  List CeRow ->
  List Super ->
  List String
ifaceDfsCycleSupers _ _ _ _ [] = []
ifaceDfsCycleSupers ce cur done path ((Super { superHead = superName, superOrigin = so }) :: rest) =
  let msgs1 = ifaceDfsCycleOneSuper ce cur done path so superName
  msgs1 ++ ifaceDfsCycleSupers ce cur done path rest

-- check one super edge: cycle if the super's IDENTITY is on the DFS path; skip if
-- done; else recurse into the row that identity names.  A super naming no visible
-- interface abstains (see the miss-arm note at `checkInterfaceCycles`).
ifaceDfsCycleOneSuper : ClassEnv ->
  Int ->
  Ref (OrdMap Unit) ->
  List CeRow ->
  TyConOrigin ->
  String ->
  List String
ifaceDfsCycleOneSuper ce cur done path so superName =
  let key = regKeyOfTab (ifaceTabKey so superName)
  let rendered = regKeyRender key
  if containsRowKey rendered path then
    [cyclicSuperIfaceMsg (map ceRowIfaceName path ++ [superName])]
  else if omHasKey rendered !done then
    []
  else match ceLookupAt key cur ce
    None => []
    Some r => ifaceDfsCycle ce cur done (path ++ [r]) r

containsRowKey : String -> List CeRow -> Bool
containsRowKey _ [] = False
containsRowKey k (r :: rest)
  | ceRowDoneKey r == k = True
  | otherwise = containsRowKey k rest

-- #80: the single per-module typecheck body, reached from the graph driver through
-- `checkModuleFullImpl`. DICT-SEMANTICS §7's single-evaluator law means one
-- elaboration decision serves check, run, and emit. `mid` and `implDecls` carry the
-- current module's identity and graph-visible impl universe; single-file callers use
-- the same function through the one-module graph projections.
--
-- The module's `ModuleCtx` is minted here, before anything else runs, and returned
-- beside the bindings: the driver continues from it.  [gctx] is the drive's graph
-- record, which the driver passes (the previous record's `mcGraph`).  [runSeed] is its
-- match oracle and warnings (`seedCheckRun`); a driver that does not seed
-- (`cmCheckWorker`, the core passes) passes the previous record's (`checkRunResidue`).
export
checkBodyImpl : GraphCtx ->
  CheckRunSeed ->
  ModuleSeed ->
  String ->
  List Decl ->
  List Decl ->
  (ModuleBindings, List Decl, ModuleCtx)
-- multi-line RHS: the indented `:=` form is legal but not seed-parseable yet (#1744)
-- lint-disable-next-line rule-prefer-assign-op
checkBodyImpl gctx runSeed moduleSeed mid implDecls prog0 =
  let seed = moduleSeed.msSchemes
  let mctx = freshModuleCtx gctx runSeed mid
  let moduleScope =
    Scopes.freshScope
      (currentScopeStore gctx ())
      None
      mctx.mcCells.currentLevel.value
      mid
      ModuleOwner
  openScope mctx moduleScope
  recordModuleStart gctx mid
  -- #1675: this module's own `import`/`export import` decls, checked for a name the
  -- named dependency exports under two different definitions.  Here rather than in
  -- `importSeed` because the seed is built BEFORE this `freshModuleCtx` — see
  -- `reportAmbiguousImports`.  Reads only `deAmbigValues`, so a driver with no graph
  -- envelope (Flat, single-file) is a no-op.
  reportAmbiguousImports mctx prog0
  let prog = prog0
  let aliasSpellings = aliasMethodSpellings gctx prog
  -- P1 (#1446) / DICT §8 I7: the four operator-and-literal classes' identities, read
  -- off the PRELUDE's own `DInterface` decls before any body is inferred (the operator
  -- handlers consult them during inference).  See `seedBuiltinClasses`.
  seedBuiltinClasses gctx mid prog
  -- #837: stamp binding ids on the program the bodies are INFERRED from.  `prog`
  -- itself stays unstamped for the pre-inference analyses (shadows/key table/…),
  -- which do not need ids; only the inferred bodies (defs + impl/default/prop/test)
  -- carry EVarId, and schemeDefIdsRef feeds registerSchemeObligations the top-level
  -- members' ids.  Flat: a single walk (top-level frame built over the whole `prog`,
  -- so a user body referencing a prelude fn gets the prelude fn's id), then split
  -- back into core/user slices for the two-phase Flat inference.  Module: the
  -- scope alone is minted here; each binding group is MARKED and then stamped as the
  -- schedule reaches it (`processSCC`), and the tail bodies after the groups, so
  -- `progS` is the module's UNMARKED, unstamped tree and `progT` below its inferred
  -- twin.  The Flat callers marked their whole program before this call.
  let stampRes =
    let (top, ids) = stampTopScope prog
    beginModuleMarking mctx mid prog top moduleSeed
    (prog, ids)
  let progS = fst stampRes
  -- #907: index name→id as an OrdMap (was a List scanned linearly per rendered
  -- scheme in ownContext / per SCC member in registerSchemeObligations → O(decls²)).
  -- Built from the REVERSED pairs so omFromPairs' last-write-wins reproduces the old
  -- `lookupAssoc` first-match-wins on a duplicated binder name (same pattern as sigTyMapRef).
  mctx.mcCells.schemeDefIdsRef := omFromPairs (reverseL (snd stampRes)) omEmpty
  -- the full visible universe (shadows / key table /
  -- completeness / obligations): Flat = whole flattened program; Module = imported
  -- data + impl universe + this module.
  -- Every consumer of `fullUniverse` is a `Flat _ =>` arm (buildDefinerShadows,
  -- checkImplObligations, checkCallObligations).  Impl-completeness takes no decl list: it
  -- reads `classEnvHere`, which carries this universe on the Flat arm.  Medaka is STRICT, so
  -- binding `accData ++ implDecls ++ prog0` on the Module arm would allocate an O(|accData|)
  -- list every module and discard it unread.  Bind `[]` on Module.
  -- registerAllData universe (#154 PR-A): the Module path no longer builds `accData ++ prog0`
  -- here — prior modules' public data lives in the persistent DATA-universe accumulators
  -- (universeCtorPop/universeRecordPop), loaded+overlaid at the `dataEnv` binding below.
  -- (#6, #1457) superDeclsRef: unified body OWNS it — Flat = coreProg ++ userProg, Module =
  -- `prog ++ implDecls`.  [implDecls] is core + every EARLIER module ONLY (foldModules never
  -- folds a module into its own universe), so binding it alone EXCLUDED this module's own
  -- `interface F t requires L t` decl from ifaceSelfAndSupers/survivorObligationEntailed and
  -- false-rejected every legal superclass-default body (#1457).  Folding `prog` in matches the
  -- graph path, whose universe includes this module itself.
  -- Operand order is load-bearing, BOTH ways:
  --   * cost — Medaka is strict, so `xs ++ ys` copies xs and shares ys.  [implDecls] is the
  --     growing accumulator, so it MUST be the right operand: `prog ++ implDecls` is O(|prog|)
  --     per module = O(N) overall, whereas `implDecls ++ prog` would resurrect #154 PR-C's
  --     O(modules²) per-module concat.
  --   * meaning — ifaceSupersOf/ifaceSelfAndSupers is a FIRST-MATCH scan, so `prog` first makes
  --     THIS module's own same-spelled interface decl outrank an earlier module's, which is the
  --     precedence the old single-program path had.
  let superDecls = prog ++ implDecls
  mctx.mcCells.superDeclsRef := superDecls
  -- (BREAK #3) effect domains: FLAT populates inline; MODULE relies on the driver
  -- preamble (checkModulesPreambleK / elaborateModules) populating ONCE over the whole
  -- import graph — a per-module populate would wipe another module's domains.
  checkEffectParams mctx prog
  -- D2: reject non-function members of a top-level `let rec` group (the LetRecNonFunction
  -- guard, which fires for the is_letrec=true groups that come from DLetGroup) before the
  -- DFunDef groups are typechecked.
  checkLetRecDecls mctx prog
  -- On the Module path, grow the persistent universe accumulators by THIS module's decls
  -- BEFORE the shadow/key reads below consult them — so they see the same universe
  -- `fullUniverse` (which appended prog0) did.  Flat is untouched and rebuilds over its whole
  -- `prog` (already O(N)).  `appendUniverseAccums` grows no impl universe: the impl
  -- population is `IE`, bound below as `moduleImplUniv`.
  -- #1499 clause (b) / S1-PRELUDE (a): `mid` is BOUND here now — `appendUniverseAccums`
  -- must know whether this pass is the PRELUDE's, because the prelude contributes to
  -- S1's INTERFACE operand but NOT to its STANDALONE one.  See its header.
  appendUniverseAccums gctx mid prog0
  -- THE `IE` READER: a production read of stage K's `IE`.  A second production read,
  -- `ieRowsVisibleAt`, exists: do NOT describe this one as "the ONE place".  No `obUniv*`
  -- `CrossRun` accumulator exists beside it: two sources of truth for "what impls exist" is
  -- what design law L1 forbids.  The migration narrative and the whole-prefix equality
  -- measurement are in `compiler/TYPECHECK-TARGET-ARCHITECTURE.md` §9.5a; what stays here
  -- are the facts a reader of this line needs.
  --
  -- This is not filtered to this module's ordinal prefix.  `ieSnapAt` routes through
  -- `ieCandidacyVisibleAt`, which is `True`, so this binding is the WHOLE GRAPH's impl
  -- universe regardless of `mid`'s ordinal.  This line is where C4/I2 is cashed: every
  -- obligation check on the multi-module path knows the same impl population in every
  -- module — *"import scoping never decides which instances exist"*
  -- (`docs/spec/DICT-SEMANTICS.md` §8 I5).  It WIDENS the same-spelled-interface reach that
  -- topological prefix scoping narrowed by accident; expected and licensed, but an
  -- acceptance delta.  The pin that graded that delta no longer exists:
  -- `test/must_fail_fixtures/1072-overlap-xmod-bare-head-arm-order` is gone from the tree
  -- (derive: `ls test/must_fail_fixtures | grep 1072`) — see §9.5a; do not read its absence
  -- as "already drained".
  --
  -- `declEnvsOrdOf mid` is still passed and is now inert on this path.  It is
  -- kept so the call site does not move and so re-scoping candidacy later is a
  -- one-line change; do not "simplify" it away, and do not read its presence as
  -- evidence a filter is still applied.  Its `-1` miss sentinel is likewise vacuous
  -- here — an unknown module id now gains the whole graph rather than losing
  -- everything, the opposite of the fail-CLOSED story `declEnvsOrdOf` documents for
  -- the NAME axis.
  --
  -- Bound once, read twice, and the "once" is load-bearing.  There are TWO Module-arm
  -- consumers — `residualUnivRef` just below, and the end-of-body obligation `obUniv`.  Do
  -- not re-derive the projection at the second site: it is a whole-prefix rebuild, so a
  -- second call doubles this binding's already-measured per-module cost for a value that
  -- cannot have changed (both `ord` and `IE` are immutable for the whole module).  A third
  -- consumer should take this binding too, or say in writing why it needs a different
  -- ordinal.
  let moduleImplUniv =
    let envs = gctx.declEnvsRef.value
    ieUniverseAt (declEnvsOrdOf mid envs) envs.deImpls
  -- Stash the impl universe the RESIDUAL REDUCER entails against (`residualPredsOf`, called
  -- from each generalizing group's close).  This is NOT a third source: it is the SAME two
  -- arm-gated sources the end-of-body obligation checkers consume — `buildImplUniverse prog`
  -- on Flat, and the `IE` projection on Module (which carries this module's own impls, its
  -- ordinal being included by `declEnvVisibleAt`).  Built ONCE per module rather than per
  -- group: rebuilding it inside the reducer would be O(decls) per SCC, i.e. quadratic.
  setRef mctx.mcCells.residualUnivRef moduleImplUniv
  -- (#4) shadows.  definerShadows uses the SHARED form — buildDefinerShadows over the
  -- full visible universe, scoped to THIS module's decls (prog0).  On Flat, prog0 =
  -- userProg and fullUniverse = prog, so this is exactly the old flat `buildDefinerShadows
  -- prog userProg`.  The method-name test, `isMethod`, reads `deMethods` at this module's
  -- ordinal: every interface method a module at or before it declares, whatever its
  -- export.  importerShadows exist only across a module boundary; the `Module _ _ []` arm
  -- (cmCheckWorker / core pass, implDecls = []) keeps the old empty result — `funDefs []
  -- = []` gave no imported fns there.
  -- #1354 unit A (#1353): that test is not scoped to what this module can name, so the
  -- intersection alone implements only S1's LEFT operand.  `nameableIfaceShadows` supplies
  -- the RIGHT one — the interface must be nameable in THIS module.  Applied to the RESULT,
  -- never inside either filter (the result is single-digit; `fnSet` is every fn name in
  -- the graph), and fail-open when the graph index is absent.  See `nameableIfaceShadows`.
  -- The Flat arms are untouched: a single file is one module and its own interfaces are
  -- nameable in it.
  let isMethod =
    let envs = gctx.declEnvsRef.value
    methodNameDeclaredAt (declEnvsOrdOf mid envs) envs.deMethods
  let definerShadows =
    nameableIfaceShadows gctx prog0 (definerShadowsFromSet gctx isMethod prog0)
  let importerShadows =
    if isEmptyL implDecls then
      []
    else
      nameableIfaceShadows
        gctx
        prog0
        (standaloneShadowsFromSet
          gctx
          isMethod
          (omMapValues (_ => ()) moduleSeed.msImportedValues)
          prog0)
  let sigs = sigsOf prog
  mctx.mcCells.definerShadowNamesRef := namesToSet definerShadows omEmpty
  mctx.mcCells.definerShadowSigsRef := omFromPairs (reverseL sigs) omEmpty
  -- Impl existence is read from ONE graph-global table, `bodyImplEnvRef`, seeded just below
  -- (`ieImplExistsForHead`).  Do not add a prefix-keyed existence table here: a cumulative
  -- TOPOLOGICAL PREFIX disagrees with S2's impl universe, which is graph-global
  -- (`SHADOW-SEMANTICS.md:183-186`, `:226`), so an importer shadow whose receiver's impl sat
  -- in a topologically later module would answer "no impl" and call the standalone — a
  -- located reject became exit 0 printing a `Box` pointer fed to `n + 1`, discriminated by
  -- the order of two `import` lines.  One substrate, one decision.
  -- `bodyImplEnvRef` holds the impl population seated on `IE`'s shape, on BOTH arms: one ref,
  -- so every reader has one substrate rather than an arm gate (see `buildFlatImplEnv` for the
  -- measured hazard on a path where `IE` is empty).  Its readers are the three selection
  -- legs, the route word and the shadow existence reads.  Derive the set:
  -- `grep -n bodyImplEnvRef compiler/types/*.mdk`.
  -- The Module arm is a pointer copy of the env `buildDeclEnvs` already built; it
  -- deliberately does NOT re-derive, for the reason `moduleImplUniv` gives above.
  mctx.mcCells.bodyImplEnvRef := gctx.declEnvsRef.value.deImpls
  -- (#4 + #3-restore) mode-specific pre-inference ref setup (all pure/independent of the
  -- register+globalS block below, so order-safe).  Module installs importer-shadow state and restores the cross-module dict
  -- accumulators `freshModuleCtx` just wiped.
  -- multi-line RHS: the indented `:=` form is legal but not seed-parseable yet (#1744)
  -- lint-disable-next-line rule-prefer-assign-op

  -- #1425 site 2: `mid` is BOUND here now — the three lockstep re-keys at the end of this
  -- arm need this module's identity, and the arm can no longer discard it.

  -- C5: compute this module's standalone-shadow set BEFORE inference, so the inferMethodAt
  -- arg-position record can gate on it (`freshModuleCtx` cleared it via pendingRLocalSites, but
  -- standaloneValuesRef is set fresh here per module).
  --
  -- Two flavours of standalone-shadow, BOTH needing RLocal recording so a method call on a
  -- no-impl receiver routes to the standalone instead of mis-dispatching:
  --   * IMPORTER shadow (`importerShadows`): a name imported from a sibling that is also an
  --     interface method (box importing map's `toList`).  Its scheme must be REBOUND to the
  --     interface-method scheme (`shadowMethodSchemes`) so the call site types polymorphically;
  --     RLocal then redirects the no-impl receiver back.
  --   * DEFINER shadow (`definerShadows`): a name THIS module defines as a top-level funDef that
  --     ALSO names an interface method (map-as-root's own `toList` / `isEmpty`).  The MARK pass
  --     (`buildStandaloneShadowsGraph`) rewrites these to `EMethodAt`, so without a matching
  --     RLocal record the route falls back to the result-type `RKey` (e.g. `toList`'s `List`
  --     result), dispatching the method on the WRONG impl (List's `toList = identity`) and
  --     `debug`/`display` recurse on the unchanged receiver forever (Map Debug/Eq/Ord impl
  --     bodies call standalone `toList`).  These must be RECORDED for RLocal but must NOT be
  --     rebound to the method scheme: their local standalone scheme (`Map k v -> ...`) is what
  --     the impl body types against.
  mctx.mcCells.standaloneValuesRef :=
    namesToSet (importerShadows ++ definerShadows) omEmpty
  -- #1351: the per-module copy of the identity-keyed dispatch-index universe, read by
  -- `methodDispatchIdx` through `dispatchIdxScoped`.  Its bare-name peer was retired at L5.
  mctx.mcCells.methodDispatchIdxByIdRef :=
    gctx.crossRun.universeMethodDispatchIdxByIdRef.value
  -- The list alone is seeded here and re-keyed twice below; nothing reads the
  -- name index until the final `setFunPredicateSlots` of this arm rebuilds it.
  mctx.mcCells.funPredicateSlotsRef :=
    gctx.crossRun.crossModuleFunPredicateSlotsRef.value
  -- The declared-prefix sidecar rides the IDS table — every
  -- whole-table replacement of `funConstraintsRef` owes one of these.
  mctx.mcCells.funConstraintDeclaredRef :=
    gctx.crossRun.crossModuleFunConstraintDeclaredRef.value
  -- A module alias (`import m as A`) has no `currentImportDefinersRef` row for
  -- each dotted member, so its call sites resolve through these alias-local rows.
  -- The source is nevertheless exact: `aliasConstraintEntries` selects only the
  -- `(defining module, exported name)` row admitted by that alias. Preserve the
  -- complete predicate vectors here; stripping them reduces distinct predicates
  -- such as `Tweak a Int` and `Tweak a Bool` to the ambiguous goal `Tweak a`.
  -- The graph-wide bare-name snapshot below remains vector-free because it lacks
  -- this source identity.
  setRef
    mctx.mcCells.funPredicateSlotsRef
    (aliasConstraintEntries
        gctx
        prog
        gctx.crossRun.crossModuleFunPredicateSlotsQualRef.value
      ++ mctx.mcCells.funPredicateSlotsRef.value)
  setRef
    mctx.mcCells.funConstraintDeclaredRef
    (aliasConstraintEntries
        gctx
        prog
        gctx.crossRun.crossModuleFunConstraintDeclaredQualRef.value
      ++ mctx.mcCells.funConstraintDeclaredRef.value)
  -- #1425 site 2: the three tables above were just seeded WHOLESALE from graph-wide
  -- BARE-NAME accumulators, so every name this module declares is currently answered by
  -- whichever module's same-named binding the topological order happened to put first.
  -- Re-key those names — and only those — onto this module's own `(mid, name)` rows.
  -- Three writes, in lockstep: the declared-prefix sidecar rides the
  -- IDS table, and this is a whole-table replacement of all three.
  setFunPredicateSlots
    mctx
    (selfDeclArities
      mid
      prog
      gctx.crossRun.crossModuleFunPredicateSlotsQualRef.value
      mctx.mcCells.funPredicateSlotsRef.value)
  setRef
    mctx.mcCells.funConstraintDeclaredRef
    (selfDeclArities
      mid
      prog
      gctx.crossRun.crossModuleFunConstraintDeclaredQualRef.value
      mctx.mcCells.funConstraintDeclaredRef.value)
  -- ONE derivation, two projections.  The two refs are read together
  -- (`qualConstraintKey` assembles a `(definer, origin)` key out of both), so they
  -- must not be derived by two independent walks that could admit different rows.
  let admitted = importDefinersOf gctx prog
  mctx.mcCells.currentImportDefinersRef :=
    omFromPairs (reverseL (definerRowsOf admitted)) omEmpty
  mctx.mcCells.currentImportOriginsRef :=
    omFromPairs (reverseL (originRowsOf admitted)) omEmpty
  -- #1114 (#845): this module's imported SCHEME CONTEXTS, keyed by local spelling.
  -- `reverseL` before `omFromPairs` so the FIRST entry wins a duplicate key, matching
  -- the first-match policy of the sibling tables set just above
  -- (`omFromPairs` is last-write-wins; see its own note in support/ordmap.mdk).
  setRef
    mctx.mcCells.importedSchemeOblsRef
    (omFromPairs
      (reverseL
        (importedSchemeOblEntries
          prog
          gctx.crossRun.crossModuleSchemeOblsQualRef.value))
      omEmpty)
  -- #2563: install THIS module's method scope — its decls and ordinal, the inputs
  -- `methodScopeHere` answers from on first read of each spelling (stage K's
  -- `deMethods` is the whole graph; nothing is copied per module).

  mctx.mcCells.methodScopeCtxRef :=
    Some (prog, declEnvsOrdOf mid gctx.declEnvsRef.value)
  -- #1386: the alias-qualified spellings (`A.mth`) this module's imports supply.
  -- Built eagerly, here, because a key that names two declarations is reported
  -- (`T-AMBIGUOUS-ALIAS-METHOD`) whether or not the module ever spells it.
  mctx.mcCells.methodAliasEntriesRef :=
    aliasQualifiedMethodEntries mctx prog omEmpty
  -- #1386: the ORIGIN name behind each of those alias-qualified keys, from the
  -- same rows, in the same module scope, on the same line as the supply they
  -- accompany — `originMethodName`'s source.
  mctx.mcCells.aliasMethodOriginsRef := omFromPairs aliasSpellings omEmpty
  -- Module arm: copy the seven persistent DATA-universe accumulators (prior modules'
  -- public data + ctor env, each minted exactly once) into the `freshModuleCtx`-wiped
  -- working refs, then register ONLY this module's `prog0` as a transient FRONT
  -- overlay — O(|prog0|) per module, O(N) total. Ordering must stay [prog0,
  -- pub_{k-1}..pub_1] to preserve lookupAssoc (first-wins) / omInsert (last-write-wins)
  -- semantics.
  let dataEnv =
    -- `mid` is BOUND here: the overlay pool below is read at this module's own ordinal.
    -- `envs`/`cur` are bound BEFORE the reload because the reload's alias half is a
    -- projection of `envs` at `cur`.  Both bindings are pure reads of `GraphCtx`, so
    -- hoisting them above `loadDataUniverse` changes nothing else.
    let envs = gctx.declEnvsRef.value
    let cur = declEnvsOrdOf mid envs
    loadDataUniverse mctx cur
    -- #674: OVERLAY the ctors of the types THIS module imports so a bare ctor name
    -- resolves to the module the unit imports it from, not the universe's load-order
    -- winner.  Reads the persistent universe DECLS (not the Module `accData` field —
    -- that is dead `[]` on the elaborate/emit path, #154 PR-C), so the overlay fires
    -- on the run/build gate too, not just `check`.
    --
    --     universe  <  imported-ctor overlay  <  this module's OWN `prog0`.
    -- The overlay registers AFTER the universe (that is #674's requirement — it must
    -- win the `omInsert` tie-break over the load-order winner) and BEFORE `prog0`
    -- (this module's own declarations outrank anything it imports — ordinary
    -- shadowing, and the SHADOW spec's S1 per-module scoping).
    --
    -- one: an imported decl's constructors then beat locally-declared ones, so
    -- `import json.{Json, JNull}` + a local `data Tok = JString String` was rejected
    -- `Type mismatch: Json vs Tok` — clobbered by a SIBLING constructor of `Json`
    -- that the program never imported.  It reaches the stdlib and it is not narrow:
    -- every selective constructor-naming import carries it.  Pinned by
    -- `test/engine_fixtures/ctor_scope_local_ctor_beats_stdlib_import.mdk` (the
    -- stdlib `json` shape, on all three engines) and
    -- `test/llvm_fixtures_modules/ctor_scope_local_decl_wins/` (`{Ext, Other}` plus
    -- a local decl, prelude-free).
    --
    -- cause was exactly two of them disagreeing, and a FUTURE edit re-creates that by
    -- moving ONE.
    --
    -- Registration order here is  universe < overlay < prog0.  Under it:
    --   * the `TcEnv` ctor scheme map (`addCtor` → `omInsert`, BARE ctor name) —
    --     LAST-write-wins → prog0.  BARE-keyed, so two modules genuinely collide here;
    --     this is #1259's table and the one the overlay exists for.
    --   * `recordByNameRef` (`registerRecordInfoKeyed` → `omInsert`, BARE ctor name) —
    --     LAST-write-wins → prog0.  #1256's table, same keying, same hazard.
    --   * `dataParamKindsRef` (`recordParamKinds`, a consed list read FIRST-match) —
    --     IDENTITY-keyed (`tyTabKey o name`), so two modules' same-named
    --     types get DIFFERENT keys and registration order cannot decide between them
    --     at all.  It is order-observable only for a decl registered twice, where it
    --     agrees.  It is NOT evidence about the bare-keyed tables above.
    --     (`checkModuleFullDiags`: `seedCheckRun (prog ++ importedCtorTypeDeclsFirstWins prog …
    --     ++ accData)`), from a LIST, with `oracleMap` = `omFromPairs (reverseL …)`,
    --     i.e. FIRST-wins on that list → prog0 > overlay > universe.  Same verdict,
    --     opposite mechanism, and reached through none of the code on this line.
    --     THIS is the one a future edit can silently flip, so check it too.
    -- All four land on prog0 > overlay > universe.  Getting any two to disagree is
    -- #674's root cause.
    -- A FIFTH layer, and it is a per-NAME overlay rather
    -- than a fifth registration — `applyCtorScopeOverrides` re-points the (normally
    -- empty) set of COLLIDED constructor names at the declaration THIS module's import
    -- scope selects.  It sits ABOVE prog0 and declines for any name prog0 declares, so
    -- the ladder above is unchanged: own > import scope > import overlay > universe.
    -- A collision-free program returns this very env unchanged and unallocated.
    -- The two RECORD-table overlays are the same fifth
    -- layer one namespace-half over, and they must run HERE — after `registerAllData …
    -- prog0` has written the floor into `recordByNameRef` / `fieldOwnersRef` — for the
    -- same reason `applyCtorScopeOverrides` wraps that call.  They are statements rather
    -- than an env transform only because those two tables are per-run REFS, not `TcEnv`
    -- fields; the ladder they implement is identical.  See applyRecordScopeOverrides.
    -- No positional `List Decl` accumulator carries the pool: it is the
    -- whole-graph envelope read at THIS module's ordinal through
    -- `declEnvRowVisible`/`declEnvVisibleTo`.
    --
    -- `buildDeclEnvs` indexed the row under, threaded here by the driver
    -- (`elabModuleStamp mid` on the emit path; `cmCheckWorker mid` since #1508).  It
    -- is NOT re-derived from import syntax, which is why the emit path's
    -- `private_mangle` rewriting cannot break it: mangling renames top-level
    -- bindings, never a loader module id, and the decls in the pool are the very
    -- objects the accumulator held before.  (Re-deriving a read key by re-walking
    -- `DUse` syntax is what made #1425's four-site change resolve on eval and MISS on
    -- emit — `DUse` decls are never mangled.  This key does not go through that
    -- channel.)
    -- The KIND and FIELD-OWNER halves of the seed, read
    -- from one ordinal-aware source.  Position in the ladder: the UNIVERSE layer, under
    -- the overlay and under `prog0`.  See `declEnvSeedChain` for
    -- why the reader's OWN row is excluded here and registered by the two
    -- `registerAllData` calls below instead.
    declEnvSeedDataUniverse mctx mid envs
    -- `omInsert` tables, so the LAST row wins, and the overlay's named-outranks-wildcard
    -- rule therefore needs the `UseGroup` rows LAST.  The oracle call site takes the
    -- opposite order for the opposite reason — see the partition note at
    -- `importedCtorTypeDeclsFirstWins`.  Swapping these two inverts the rule silently.
    let base =
      registerImportOverlay
        (withCtors mctx (spFloor gctx.crossRun.universeCtorPop.value))
        prog0
        (importedCtorTypeDeclsLastWins prog0 cur envs.deModules)
    let env0 = registerAllData base prog0
    applyRecordScopeOverrides mctx prog0
    applyCtorScopeOverrides prog0 env0
  recordInvocationView dataEnv
  -- #784: reject under-determined return-only effect vars on interface methods.
  -- MUST run AFTER `dataEnv` above populated `dataParamKindsRef` — the kind-aware
  -- predicate (rowArgNames) reads that table to distinguish a row-kinded ctor arg
  -- (`Async e a`, pins the effect) from a type-kinded one (`List e`, does not).
  checkUndeterminedRetEffVars mctx prog
  -- EFFECTS-SEMANTICS §6.4/§6.5: declared-kind consistency.  Same placement — the
  -- slot-kind reads consult the table `dataEnv` just populated.
  checkDeclaredKinds mctx prog
  -- One authority, one domain, for a declaration's `Authority` parameters.
  -- Same placement: an index slot's domain is read from that table.
  checkDeclAuthorityUses mctx prog
  -- #822: instance-head kind check for graded interfaces.  Same placement rationale
  -- as the line above for the HEAD-constructor half, which still reads
  -- `dataParamKindsRef` that `dataEnv` above has just populated.
  -- The INTERFACE-slot half reads stage K's `CE` at this module's ordinal.  This pair is
  -- BOUND ONCE and read by TWO consumers — the graded impl-head check here and
  -- impl-completeness at the end of the body — hence the neutral name: a second construction
  -- at the completeness site could drift from this one.
  let classEnvHere =
    let envs = gctx.declEnvsRef.value
    (envs.deIfaces, declEnvsOrdOf mid envs)
  checkGradedImplHeads mctx (fst classEnvHere) (snd classEnvHere) prog
  rejectCyclicAliases mctx prog
  -- #1280: `prog` reached here through a driver's stamping walk already, and
  -- `stampTyHead` is first-write-immune, so the builtins-only scope can only fill
  -- a head no driver could attribute — an `extern` written in a FLAT user file,
  -- where there is no module id and the primitive heads are all that is knowable.
  -- #2072: `userExternSchemes`, not `externSchemes` — this is the extern
  -- DECLARATION site (the program under check).  It builds the declared type
  -- verbatim; the two guards below are what hold a user extern to its row.
  let currentMethodRows = ifaceMethodSchemeRows mctx prog
  recordMethodGrants gctx currentMethodRows
  let visibleMethodRows = ifaceMethodSchemeRows mctx implDecls
  let visibleMethodRowIndex =
    methodRowsByIdentity
      (isNonEmptyL importerShadows)
      visibleMethodRows
      regEmpty
  let externS = userExternSchemes mctx (externTyOriginScope []) prog
  let globalS = legacyMethodSchemes currentMethodRows ++ externS
  -- #2074 / F1 (epic #2070): the USER-EXTERN DECLARATION guards, all gated on
  -- the same `ffiStampMode` ownership Bool — a stdlib-owned program's externs ARE
  -- the vocabulary and none of these rules owns them.  They run AFTER
  -- `rejectCyclicAliases` (`tc_decls`) so `expandAliasHeadTy` cannot recurse forever on a
  -- cyclic alias.  Order between them is not significant: diagnostics
  -- accumulate ([T-ERRORS-ACCUM]) and a signature can honestly fail more than one.
  --
  -- Four sibling loops rather than four arms inside one walk: each has its own
  -- exemption discipline (the crossable rule exempts a catalog-name
  -- redeclaration, the label and binding rules hold one to its `bind` clauses
  -- only, the shadow rule IS that exemption's admission test, and the
  -- catalog-row rule fires ONLY on a catalog name), and folding them together
  -- would force one `if` to speak for four notions of "this declaration is not
  -- mine".
  ffiCheckExternsCrossable mctx (ffiStampMode gctx mid) prog
  ffiCheckExternsLabelled mctx (ffiStampMode gctx mid) prog
  ffiCheckExternsShadow mctx (ffiStampMode gctx mid) prog
  ffiCheckExternsCatalogRow mctx (ffiStampMode gctx mid) prog
  -- (#4 cont) post-globalS mode setup.  Module: shadowMethodSchemes env layer (rebinding
  -- imported method names to the interface-method scheme) + the method-constraint cross
  -- seed (AFTER globalS's row registration, per installMethodPredicateSlots).
  let envSeed = extendVars dataEnv seed
  let shadowLayer =
    -- The rows remain local: they carry live scheme cells needed only by setup and
    -- must not become another graph-lived authority.
    let ifaceSchemes = legacyMethodSchemes visibleMethodRows
    -- #259/#2157: seed both halves from the same already-minted row selection.
    seedNumLitFromIntAnchor mctx visibleMethodRows
    -- #1351 L2 MIGRATE.  The importer-shadow layer now binds each shadowed method
    -- name to the scheme of the declaration THIS module's import scope admits
    -- (`methodScopeAt`), not to `lookupAssoc`'s decl-walk first match.
    -- Falls back to the bare-name answer on a miss — see `pickSchemesByDecl`.
    let sm =
      pickSchemesByDecl
        mctx
        importerShadows
        ifaceSchemes
        visibleMethodRowIndex
        moduleSeed.msImportedValues
    mctx.mcCells.methodPredicateSlotsRef :=
      mctx.mcCells.methodPredicateSlotsRef.value
        ++ gctx.crossRun.crossModuleMethodPredicateSlotsRef.value
    attachStandaloneSources moduleSeed.msImportedValues sm
  let envImported =
    annotateImportedMethodRows
      envSeed
      (importedMethodBindingNames gctx prog0 aliasSpellings)
      (nameableIfaceMethodSet gctx prog0)
      (namesToSet importerShadows omEmpty)
      visibleMethodRowIndex
  let envGlobal =
    extendVars (extendMethodRows envImported currentMethodRows) externS
  let env1 = extendBindings envGlobal shadowLayer
  let defs = funDefs progS
  let (topSchemes, groupedOut) =
    processTopGroups
      env1
      sigs
      defs
      (groupNames defs omEmpty)
      (namesToSet (publicValNames prog) omEmpty)
  recordTopBinderTypes gctx (omFromPairs topSchemes omEmpty) progS
  -- The tail bodies (impl, default, prop and test bodies) see the top-level
  -- bindings as the binding groups do (`processTopGroups`' result env): each
  -- binding keeps its standalone descriptor, so an occurrence of a top-level value
  -- spelled like a method resolves to the value in a tail body too.  Marking and
  -- inference read this one env.
  let tailEnv = extendTermBindings env1 topSchemes
  -- Module: the marked tree this call returns (the groups' marked clauses written
  -- back, the tail bodies marked with the module's final dict-name set) and its
  -- stamped twin, which the tail-body inference below reads.  Flat: `progS` is both.
  let progOut = match mctx.mcCells.markingRef.value
    Some mm => finishModuleMarking mm tailEnv groupedOut progS
    None => progS
  let progT = match mctx.mcCells.markingRef.value
    Some mm => stampTailDecls mm.mmTop progOut
    None => progS
  -- The module path runs a single inference pass; core is checked as its own
  -- invocation, which isolates the prelude's method bodies from a user binding
  -- that shadows an interface method (List Int vs Int).

  -- Unified impl-body inference form (Module arm, both drivers): inferUserImplBodies
  -- infers parametric heads and preserves diagnostics. allProg = implDecls
  -- (interfaces + accumulated impls) grounds the field types. See
  -- compiler/TYPECHECK-TARGET-ARCHITECTURE.md § "SA-10a. Landing log" (#2546, ARCH Q3a).

  inferUserImplBodies
    tailEnv
    implDecls
    (fst classEnvHere)
    (snd classEnvHere)
    progT
  inferDefaultBodies tailEnv progT
  inferPropBodies tailEnv progT
  inferTestBodies tailEnv progT
  -- (#3) cross-module dict-threading SNAPSHOT — MODULE ONLY (flat SKIPS: running it would
  -- pollute the cross-module accumulators with a phantom single-file attribution).

  dedupPredicateSlotsTable mctx ()
  -- #1425: restore the rows the per-module view masked (see `selfNameRows`) — the view
  -- must not propagate as a graph-wide deletion into the next module's seed.
  setRef
    gctx.crossRun.crossModuleFunPredicateSlotsRef
    (predicateSlotTableWithoutArgs
      (mctx.mcCells.funPredicateSlotsRef.value
        ++ selfNameRows
          prog
          gctx.crossRun.crossModuleFunPredicateSlotsRef.value))
  setRef
    gctx.crossRun.crossModuleFunPredicateSlotsQualRef
    (attributeModuleEntries mid prog mctx.mcCells.funPredicateSlotsRef.value
      ++ gctx.crossRun.crossModuleFunPredicateSlotsQualRef.value)
  -- The sidecar's two snapshots, paired with the ids snapshots above.
  setRef
    gctx.crossRun.crossModuleFunConstraintDeclaredRef
    (mctx.mcCells.funConstraintDeclaredRef.value
      ++ selfNameRows
        prog
        gctx.crossRun.crossModuleFunConstraintDeclaredRef.value)
  setRef
    gctx.crossRun.crossModuleFunConstraintDeclaredQualRef
    (attributeModuleEntries mid prog mctx.mcCells.funConstraintDeclaredRef.value
      ++ gctx.crossRun.crossModuleFunConstraintDeclaredQualRef.value)
  gctx.crossRun.crossModuleMethodPredicateSlotsRef :=
    mctx.mcCells.methodPredicateSlotsRef.value
  setRef
    gctx.crossRun.crossModuleMethodPredicateSlotsQualRef
    (emptyMethodModulePredicateSlots mid prog
      ++ attributeMethodModulePredicateSlots
        mid
        prog
        mctx.mcCells.methodPredicateSlotsRef.value
      ++ gctx.crossRun.crossModuleMethodPredicateSlotsQualRef.value)
  -- #1114 (#845, DICT-SEMANTICS §4.2 D6(a)): snapshot THIS module's scheme contexts
  -- alongside the three arity tables above.  The arity tables carry only what
  -- `funConstraintsRef` holds, whose INFERRED half is gated on `dictEligibleSetRef`
  -- and is therefore EMPTY on the check path (see that ref's comment) — so an
  -- UNSIGNATURED constrained export was invisible to every importer at check time
  -- while `run`/`build` threaded its dict anyway.  `schemeObligationsRef` is the
  -- always-on store of the same fact and is what the SAME-module use site already
  -- reads; this makes the cross-module use site read it too, under the same
  -- source-exact (mid, name) key.
  setRef
    gctx.crossRun.crossModuleSchemeOblsQualRef
    (attributeModuleSchemeObls
        mid
        prog
        gctx.crossRun.crossModuleSchemeOblsQualRef.value
        mctx.mcCells.schemeObligationsRef.value
      ++ gctx.crossRun.crossModuleSchemeOblsQualRef.value)
  -- Impl missing a required method: reads `classEnvHere` above, stage K's `CE` at this
  -- module's ordinal.  The miss arm of `ceRequiredAt` is `[]`, so an envelope that lacks an
  -- interface's row turns every live rejection here into a silent accept: `declEnvsRef` must
  -- hold the graph envelope of this run before the first module is checked.
  checkImplCompletenessMap mctx (fst classEnvHere) (snd classEnvHere) prog
  -- (#5 / BREAK #2) obligation channels.  FLAT runs both channels + setNumlitFloatsGo
  -- here so the per-module pass can
  -- stamp the Float-typed int literals, and a Flat consumer that read them unstamped
  -- would get Int cells where the inference said Float.  MODULE runs both channels
  -- here and leaves the Float stamp to the graph-end drain (`SSNumlitFloats`), on
  -- every driver (#2705).

  -- The obligation universe is the `IE` projection bound ONCE as `moduleImplUniv` far above
  -- (see its block for why re-deriving it here would be a second whole-prefix rebuild for a
  -- value that cannot have changed).

  let obUniv = moduleImplUniv
  -- #838 I4: unified checker, same `obUniv`.  Impl channel = (deferNonGround=True);
  -- call channel = (deferNonGround=False).
  -- #2705: BOTH channels run on EVERY driver.  A driver that infers impl
  -- bodies without checking their obligations lets a program `check` rejects
  -- reach codegen through `build`'s own elaboration.  `setNumlitFloatsGo` is not called
  -- here on any driver any more: the Float literal stamp is `SSNumlitFloats`,
  -- first step of the graph-end drain every Module-arm driver now runs.
  recordLiveRoots mctx ()
  judgeQuiescentGoals mctx ()
  refileDeterminedRows mctx ()
  checkCallObligationsU mctx True obUniv mctx.mcCells.implObls.items.value
  checkCallObligationsU mctx False obUniv mctx.mcCells.obls.items.value
  settleDeferredPatLits mctx ()
  checkDeferredMatches mctx (reverseL mctx.mcCells.matchChecksDeferred.value)
  checkFixedWidthLiterals mctx mctx.mcCells.numlitRanges.value
  checkWideLiterals mctx mctx.mcCells.wideLitRanges.value
  mctx.mcCells.localSchemesOut :=
    mapLocalSchemes mctx mctx.mcCells.localBindRefs.value
  mctx.mcCells.seedSchemesOut := seed
  -- #154 PR-A: grow the persistent DATA-universe by THIS module's PUBLIC data, AFTER the
  -- module's inference is complete (so the copy+overlay above saw pub 1..k-1 and NEVER this
  -- module's own pub twice) — the register-time mirror of foldModules' `accData ++
  -- publicDataDecls prog` threading.  appendDataUniverse clobbers the working table refs,
  -- which are DEAD here (the next module's `freshModuleCtx` wipes them).  Flat leaves it untouched.
  -- `mid` is BOUND here: `appendDataUniverse`'s reload reads the alias universe at this
  -- module's own ordinal.
  appendDataUniverse mctx mid prog0
  let result = (
    ModuleBindings {
      mbSchemes = globalS ++ topSchemes,
      mbStandaloneSchemes = omFromPairs (reverseL topSchemes) omEmpty,
    },
    progOut,
    mctx,
  )
  closeScope mctx ()
  result

-- Phase 4.55: infer each prop body with its declared params in scope, so the
-- prepass-marked EDictAt/EMethodAt route refs inside resolve.
-- Runs unconditionally (props are eval-only; the
-- emit/golden paths have no props): infer prop_body; unify t_bool.
-- A prop body is eval-only and is NOT dict-passed for operator dispatch: like the
-- OCaml oracle (which evals raw prop bodies against the marked env), its comparison
-- operators must stay PRIMITIVE EBinOps the eval builtin handles structurally, not
-- get stamped and rewritten to eq/lt method apps (whose dict route would then be
-- applied to a non-dict-passed comparison, panic: applied non-function).  So
-- bracket the goal channel around prop inference (`dropGoalsSince`): the routes
-- the prop body NEEDS (EDictAt for the file's promoted constrained fns, via the
-- dictionary-application and return-site goals) are still collected; only the
-- operator-rewrite goals the prop body would otherwise contribute are dropped.
inferPropBodies : TcEnv -> List Decl -> Unit
inferPropBodies env prog =
  let mark = goalsMark env.teDyn.dcModule.mcGraph ()
  inferPropBodiesGo env prog
  dropGoalsSince env.teDyn.dcModule.mcGraph mark [
    GKBinopSite, GKUnopSite, GKArithSite
  ]

inferPropBodiesGo : TcEnv -> List Decl -> Unit
inferPropBodiesGo env [] = ()
inferPropBodiesGo outer ((DProp _ name params body) :: rest) =
  -- The body's checks are located at the body (the declaration has no span),
  -- and its type at the value it returns.
  let env = envAtIfSome (exprSpanLoc body) outer
  let local = extendPropParams env params
  enterLevel env.teDyn.dcModule ()
  let parentScope = captureScope env.teDyn.dcModule ()
  let bodyScope =
    Scopes.freshScope
      (currentScopeStore env.teDyn.dcModule.mcGraph ())
      (Some parentScope)
      env.teDyn.dcModule.mcCells.currentLevel.value
      (Scopes.scopeFrame
        (currentScopeStore env.teDyn.dcModule.mcGraph ())
        parentScope).sfModuleId
      (PropOwner name)
  openScope env.teDyn.dcModule bodyScope
  let oblMark = wMark env.teDyn.dcModule.mcCells.implObls
  let callMark = wMark env.teDyn.dcModule.mcCells.obls
  let dictMark = goalsMark env.teDyn.dcModule.mcGraph ()
  unifyIn
    (dynAtIfSome (valueSpanLoc body) env.teDyn)
    (infer local body)
    (tconBuiltin "Bool")
  exitLevel env.teDyn.dcModule ()
  settleClosedBody
    env.teDyn.dcModule
    (tconBuiltin "Bool")
    oblMark
    callMark
    dictMark
  closeScope env.teDyn.dcModule ()
  inferPropBodiesGo outer rest
inferPropBodiesGo env (_ :: rest) = inferPropBodiesGo env rest

-- Phase 127 (restored 2026-07-11): typecheck each `test "…" = body` body,
-- requiring it to have type `Expectation` (a nullary TCon, so a plain nominal
-- unify).  Unlike props, test bodies ARE dict-passed (their `expectEqual`/… calls
-- come from `import test`), so this runs on the normal inference path with binop
-- stamping enabled (no snapshot/restore).  Without this, `test "x" = 1 + "str"`
-- and `test "x" = 42` slipped through `check` with zero diagnostics.
inferTestBodies : TcEnv -> List Decl -> Unit
inferTestBodies env [] = ()
inferTestBodies outer ((DTest _ name body) :: rest) =
  -- The body's checks are located at the body (the declaration has no span),
  -- and its type at the value it returns.
  let env = envAtIfSome (exprSpanLoc body) outer
  enterLevel env.teDyn.dcModule ()
  let parentScope = captureScope env.teDyn.dcModule ()
  let bodyScope =
    Scopes.freshScope
      (currentScopeStore env.teDyn.dcModule.mcGraph ())
      (Some parentScope)
      env.teDyn.dcModule.mcCells.currentLevel.value
      (Scopes.scopeFrame
        (currentScopeStore env.teDyn.dcModule.mcGraph ())
        parentScope).sfModuleId
      (TestOwner name)
  openScope env.teDyn.dcModule bodyScope
  let oblMark = wMark env.teDyn.dcModule.mcCells.implObls
  let callMark = wMark env.teDyn.dcModule.mcCells.obls
  let dictMark = goalsMark env.teDyn.dcModule.mcGraph ()
  -- #1110: `Expectation` is declared by `stdlib/test.mdk`, a USER-SPACE module —
  -- the checker fabricates this head from a literal and has no decl in view, so
  -- there is no identity to acquire.  `tconUnresolved`, not `tconBuiltin`: the
  -- language does not provide `Expectation`, and claiming §8 I6.2's
  -- program-global identity for a type some module declares would be a lie the
  -- shared carrier type cannot object to.
  unifyIn
    (dynAtIfSome (valueSpanLoc body) env.teDyn)
    (infer env body)
    (tconUnresolved "Expectation")
  exitLevel env.teDyn.dcModule ()
  settleClosedBody
    env.teDyn.dcModule
    (tconUnresolved "Expectation")
    oblMark
    callMark
    dictMark
  closeScope env.teDyn.dcModule ()
  inferTestBodies outer rest
inferTestBodies env (_ :: rest) = inferTestBodies env rest

-- A test or property body is a numeric boundary that publishes no polymorphic
-- result: nothing after it can determine its variables.  A variable below the
-- body's level (a property parameter, a value-restricted outer binding) belongs
-- to its enclosing binder and is held rigid, judged where it lives.  The body runs
-- the method-body settle sequence with an empty surviving set, then the verdict,
-- so a goal the body leaves open is judged here as a top-level binding's is.
-- [bodyTy] is the closed type the body was unified with.
export
settleClosedBody : ModuleCtx -> Mono -> Int -> Int -> Int -> Unit
settleClosedBody mctx bodyTy oblMark callMark dictMark =
  let level = mctx.mcCells.currentLevel.value + 1
  let addedObls = wWindow mctx.mcCells.implObls oblMark
  let bodyObls = addedObls ++ callUOblsWindow mctx callMark
  let rigidIds =
    outerRigidIds
      (Some level)
      (flatMap (uOblArgs mctx.mcGraph) bodyObls)
      omEmpty
  improveByUniqueImpl (dynFor mctx) rigidIds bodyObls
  determineByUniqueInstance mctx rigidIds bodyObls
  let withheld = finalizeNumBoundary (dynFor mctx) NumBoundary {
    nbDisposition = NumBoundaryOwnedMethodBody level,
    nbMembers = [bodyTy],
    nbSurvivingIds = omEmpty,
    nbDefaultObls = addedObls ++ calleeNumObls mctx callMark dictMark,
    nbAmbiguityObls = addedObls,
    nbGuard = NumGuard {
      ngGoals = bodyObls,
      ngRigidIds = rigidIds,
      ngOuterBelow = Some level,
    },
  }
  improveByUniqueImpl (dynFor mctx) rigidIds bodyObls
  determineByUniqueInstance mctx rigidIds bodyObls
  rejectUndeterminedVectors
    mctx
    rigidIds
    omEmpty
    addedObls
    (callUOblsWindow mctx callMark
      ++ nestedRequireGoals mctx rigidIds omEmpty bodyObls)
  rejectWithheldAmbiguity mctx rigidIds withheld bodyObls

-- bind each prop param `x : ty` as a monomorphic scheme in the env (fresh tyvars
-- for any free type variable in ty; props are normally concrete, e.g. `List Int`).
extendPropParams : TcEnv -> List PropParam -> TcEnv
extendPropParams env [] = env
extendPropParams env ((PropParam x _ ty) :: rest) =
  let scheme =
    monoScheme
      (fromAstType
        env.teDyn.dcModule
        (freshTvMap env.teDyn.dcModule (dedup (tyVarNames ty)))
        ty)
  extendPropParams (extendLocalVar env x scheme) rest

-- PLAN.md #11: after HM + defaulting every source integer literal's type var is
-- ground (or a genuine `Num a` survivor).  Decide each literal's runtime rep
-- (3-way):
--   • ground Float ⇒ stamp the float cell + CLEAR the fromInt route (dref RNone) ⇒
--     dictPass emits `ELit (LFloat f)` (eval is value-tagged; eval_arith rejects
--     mixed int/float tags, so a Float literal must carry a real float).
--   • ground Int (incl. via ambiguous→Int defaulting) ⇒ clear both cells ⇒
--     `ELit (LInt n)`, no dict dispatch.
--   • NOT a primitive head (a still-polymorphic `Num a` — the soundness case, `1`
--     in `inc x = x + 1` — or an exotic user numeric type) ⇒ leave [dref]'s
--     resolveSites-stamped route in place ⇒ dictPass emits
--     `EApp (EMethodAt "fromInt" …) (ELit (LInt n))` so the literal dispatches
--     through the runtime Num dict (Int→identity, Float→intToFloat).  A dref left
--     RNone (route never filled, e.g. unreachable position) falls to Int below.
-- Reads numlitRefs (populated by inferNumLit during THIS run/module's inference).
setNumlitFloatsGo : List (Mono, Ref (Option Float), Int, Ref Route) -> Unit
setNumlitFloatsGo [] = ()
setNumlitFloatsGo ((var, fref, n, dref) :: rest) =
  match normalize var
    TCon "Float" _ =>
      fref := Some (intToFloat n)
      dref := RNone
    TCon "Int" _ => dref := RNone
    _ => ()
  setNumlitFloatsGo rest

-- Records, at the module's end, the variables its non-generalized members still
-- leave open, for the graph-end drain (`GraphRun.liveRoots`).
recordLiveRoots : ModuleCtx -> Unit -> Unit
recordLiveRoots mctx _ =
  let members = mctx.mcCells.liveMemberMonosRef.value
  let liveIds = dedupI (flatMap (liveVarIdsOf mctx) members)
  if isNonEmptyL liveIds then
    let goals =
      mctx.mcCells.implObls.items.value ++ mctx.mcCells.obls.items.value
    let numObls =
      mctx.mcCells.implObls.items.value
        ++ numCallObls mctx.mcGraph mctx.mcCells.obls.items.value
    let numIds =
      filterList (i => containsI i liveIds) (numConstrainedIds numObls)
    let numRoots = filterMap (i => liveNumVarGo i numObls) (dedupI numIds)
    let g = mctx.mcGraph.graphRun
    g.liveRoots :=
      filterMap (findTvarInMonos members) liveIds ++ g.liveRoots.value
    g.liveGoals := reverseL (liveGoalsOf mctx members) ++ g.liveGoals.value
    if isNonEmptyL numRoots then
      g.liveNumRoots := numRoots ++ g.liveNumRoots.value
      g.liveNumGoals :=
        filterList
            (o =>
              any
                (i => elem i numIds)
                (flatMap monoUnboundIds (uOblArgs mctx.mcGraph o)))
            goals
          ++ g.liveNumGoals.value

-- The module's held goals that a live root still leaves open, in the order they
-- were held, each under the first of [members] whose type mentions one of its live
-- variables.  A goal a later group grounded is the module's obligation check's.
liveGoalsOf : ModuleCtx -> List Mono -> List LiveGoal
liveGoalsOf mctx members =
  let mid = mctx.mcCells.currentModuleRef.value
  let owners = memberOfIds mctx members
  filterMap
    ((rigidIds, window, o) =>
      let ids = flatMap monoUnboundIds (uOblArgs mctx.mcGraph o)
      map
        (k => LiveGoal {
          lgModule = mid,
          lgBinding = k,
          lgRigidIds =
            fold
              (acc i =>
                if IdMap.has i owners then
                  omDelete (intToString i) acc
                else
                  acc)
              rigidIds
              ids,
          lgWindow = window,
          lgGoal = o,
        })
        (findMap (i => IdMap.get i owners) ids))
    (reverseL mctx.mcCells.heldLiveGoalsRef.value)

-- Each live variable of [members] under the index of the first member whose type
-- mentions it.
memberOfIds : ModuleCtx -> List Mono -> Map Int Int
memberOfIds mctx members =
  fst
    (fold
      ((owners, k) m => (
        fold
          (acc i => if IdMap.has i acc then acc else IdMap.set i k acc)
          owners
          (liveVarIdsOf mctx m),
        k + 1,
      ))
      (Tip, 0)
      members)

-- The verdict on the goals boundaries held for live roots, at the drain, after the
-- live `Num` roots are defaulted: every module has closed, so nothing is left to
-- ground them, and each is judged as its boundary would have judged it had it owned
-- the live variables (DICT-SEMANTICS §6.2 T4, R-SC3), in its own module's context.
-- A binding gets one verdict: the first of its goals that draws one.
judgeLiveGoals : ModuleCtx -> List StampCtx -> List DrainFinding
judgeLiveGoals saved ctxs =
  let g = saved.mcGraph.graphRun
  let goals = reverseL g.liveGoals.value
  g.liveGoals := []
  if isEmptyL goals then
    []
  else
    let byModule = omFromPairs (map (c => (c.scModule, c)) ctxs) omEmpty
    reverseL (fst (fold (judgeLiveGoal saved byModule) ([], omEmpty) goals))

-- [saved] is the record the drain began with, which each entered stamp context takes
-- its drain tables from (`enterStampCtx`).
judgeLiveGoal : ModuleCtx ->
  OrdMap StampCtx ->
  (List DrainFinding, OrdMap Unit) ->
  LiveGoal ->
  (List DrainFinding, OrdMap Unit)
judgeLiveGoal saved byModule (found, judged) lg =
  let binding = "\{lg.lgModule}\t\{intToString lg.lgBinding}"
  match (omHasKey binding judged, omLookup lg.lgModule byModule)
    (False, Some ctx) =>
      let stamp = enterStampCtx saved ctx
      let rigidIds = lg.lgRigidIds
      let diags = captureTypeErrors stamp (_ =>
        each
          (undeterminedVectorVerdict stamp rigidIds omEmpty lg.lgWindow)
          (lg.lgGoal :: nestedRequireGoals stamp rigidIds omEmpty [lg.lgGoal]))
      match diags
        [] => (found, judged)
        _ => (
          reverseL (map (verdictFinding lg.lgModule True) diags) ++ found,
          omInsert binding () judged,
        )
    _ => (found, judged)

-- The verdict on the goals boundaries left to quiescence, once every group of the
-- module has closed: no later group is left to ground their variables, so each is
-- judged as its boundary would have judged it, and so are the prerequisites its
-- boundary left to this point (`nestedRequireGoals`).
judgeQuiescentGoals : ModuleCtx -> Unit -> Unit
judgeQuiescentGoals mctx _ =
  let goals = reverseL mctx.mcCells.quiescentGoalsRef.value
  mctx.mcCells.quiescentGoalsRef := []
  each
    ((rigidIds, window, o) =>
      each
        (undeterminedVectorVerdict mctx rigidIds omEmpty window)
        (o :: nestedRequireGoals mctx rigidIds omEmpty [o]))
    goals

-- The variables a later group can still ground (§6.2 T2): those no scheme
-- quantifies in the types of this group's members [monos] and of every earlier
-- top-level member of the module.  The members that still carry one are kept for
-- the groups after this one; a member grounded since is dropped.
liveMemberIds : ModuleCtx -> List Mono -> OrdMap Unit
liveMemberIds mctx monos =
  let open =
    filterList
      (m => isNonEmptyL (liveVarIdsOf mctx m))
      (monos ++ mctx.mcCells.liveMemberMonosRef.value)
  mctx.mcCells.liveMemberMonosRef := open
  omFromNames
    (map intToString (dedupI (flatMap (liveVarIdsOf mctx) open)))
    omEmpty

liveVarIdsOf : ModuleCtx -> Mono -> List Int
liveVarIdsOf mctx m =
  filterList
    (i => not (IdMap.has i mctx.mcCells.deferrableVarIds.value))
    (monoUnboundIds m)

-- #2072 (epic #2070, R2): the DECLARATION-site sibling of `externSchemes`.
--
-- The `externSchemes … runtimeDecls` call sites (`types/typecheck.mdk`) build the STDLIB EXTERN
-- CATALOG's schemes: `stdlib/runtime.mdk`'s 138 `extern` lines (derived: `grep -c
-- '^extern ' stdlib/runtime.mdk`), whose written rows ARE the effect vocabulary.
-- They must stay byte-identical.
--
-- THIS one is the `checkBodyImpl` call, which processes whichever program is under
-- check — normally a USER file, where an `extern f : Int -> <> Int` would type as
-- a pure `Int -> Int`: a one-line escape hatch through the whole effect system.
--
-- This function does not rewrite a declared row: stamping `FFI` into the terminal row
-- whenever the label was absent would mean the declared row was never checked against
-- what is enforced — `<Net "a.com/*">` silently becoming `<FFI, Net "a.com/*">` exactly
-- as `<>` silently becoming `<FFI>`.  A signature that says one thing and types as another
-- is the defect, not the missing atom.  The honesty requirement is a CHECK
-- (`ffiCheckExternsLabelled`, run beside the crossable guard at the same
-- `checkBodyImpl` seam): a user extern's terminal row must ALREADY name `FFI`,
-- whatever else it names, or the declaration is a located type error.  The scheme
-- built here is the declaration verbatim.
userExternSchemes : ModuleCtx ->
  OrdMap TyConOrigin ->
  List Decl ->
  List (String, Scheme)
userExternSchemes mctx scope decls =
  externSchemesGo mctx (stampTyOrigins scope (externDecls decls))

-- The pre-#1280 body, unchanged, over the ORIGIN-STAMPED list.  It is split out
-- rather than folded into `externSchemes` so that the recursion cannot re-enter
-- the origin-stamping walk on its own tail — the shape that turns a one-pass `map`
-- into a quadratic, which is the defect class `compiler/AGENTS.md` opens with.
--
-- It took a `stamp : Bool` until F1 (epic #2070), selecting whether to rewrite the
-- declared type with an `FFI` atom.  Both call sites now pass the declaration
-- through verbatim — the stdlib catalog always did, and the user-declaration site
-- checks the row instead of rewriting it (`ffiCheckExternsLabelled`) — so the
-- parameter is gone rather than left as a constant nobody may vary.
export
externSchemesGo : ModuleCtx -> List Decl -> List (String, Scheme)
externSchemesGo mctx decls =
  map ((n, ty) => (n, sigToScheme mctx ty)) (directExternSigs decls)

sigsOf : List Decl -> List (String, Ty)
sigsOf [] = []
sigsOf ((DTypeSig _ n ty _) :: rest) = (n, ty) :: sigsOf rest
sigsOf ((DAttrib _ d) :: rest) = sigsOf (d :: rest)
sigsOf (_ :: rest) = sigsOf rest

-- The Module arm's import overlay, registered over [env] without elaborating a
-- second time what the populations already hold.  A public data declaration is
-- elaborated once, by `appendDataUniverse` at the end of its own module's arm, and
-- an importer reads that payload back by declaration identity.  The overlay's other
-- decls (aliases, newtypes, attributed or private data, a declaration with no
-- identity) are registered exactly as `registerAllData` registers them.
--
-- A served declaration skips `recordDeclKinds` and `registerVariants`' kind, atom
-- and variance rows: it is public data of an earlier module, so stage K's seed
-- (`declEnvSeedDataUniverse`) already holds those rows under the same identity keys.
-- Its field-owner keys are still added, as `registerRecordInfoKeyed` adds them.
-- The overlay is folded in list order, because its tables are last-write-wins and
-- its named rows come last (`importedCtorTypeDeclsLastWins`).
-- [prog] is the reading module's own declarations.
registerImportOverlay : TcEnv -> List Decl -> List Decl -> TcEnv
registerImportOverlay env prog overlay =
  seedParamPolarityFixpointScoped env.teDyn.dcModule overlay overlay
  let ctorPop = env.teDyn.dcModule.mcGraph.crossRun.universeCtorPop.value
  let recordPop = env.teDyn.dcModule.mcGraph.crossRun.universeRecordPop.value
  let served = map (d => (d, overlayCachedRows ctorPop recordPop d)) overlay
  each
    (p => match snd p
      None => recordDeclKinds env.teDyn.dcModule (fst p)
      Some _ => ())
    served
  let env1 =
    fold
      (e p => if isAliasDecl (fst p) then registerData e (fst p) else e)
      env
      served
  -- Cycles out before any field elaborates, as in `registerDeclsAliasesFirst`.
  rejectCyclicAliases env.teDyn.dcModule prog
  fold
    (e p => match snd p
      None => if isAliasDecl (fst p) then e else registerData e (fst p)
      Some rows => registerCachedRows e rows)
    env1
    served

-- The cached constructor schemes and record infos of [d], in variant order, when
-- every one of its constructors has a population row under its own identity; any
-- miss declines for the whole declaration.  Only `DData` has rows to serve, and
-- declining is never wrong: a declined decl is registered by `registerData`,
-- which is where a new `Decl` constructor has to be decided, so the final
-- clause covers every other constructor rather than naming each.
overlayCachedRows : SpellingPop Scheme ->
  SpellingPop RecordInfo ->
  Decl ->
  Option (List (String, Scheme), List (String, RecordInfo))
overlayCachedRows ctorPop recordPop (DData { dataCtors, dataOrigin, ... }) =
  cachedVariantRows ctorPop recordPop dataOrigin dataCtors
overlayCachedRows _ _ _ = None

cachedVariantRows : SpellingPop Scheme ->
  SpellingPop RecordInfo ->
  TyConOrigin ->
  List Variant ->
  Option (List (String, Scheme), List (String, RecordInfo))
cachedVariantRows _ _ _ [] = Some ([], [])
cachedVariantRows ctorPop recordPop o ((Variant cn payload) :: rest) = do
  ident <- mkIdent NsCtor o cn
  s <- spLookupIdent ident cn ctorPop
  recs <- cachedRecordRow recordPop ident cn payload
  later <- cachedVariantRows ctorPop recordPop o rest
  Some ((cn, s) :: fst later, recs ++ snd later)

-- A named-field variant's cached `RecordInfo`, as a zero- or one-row list; a
-- positional variant has none to look up.
cachedRecordRow : SpellingPop RecordInfo ->
  Ident ->
  String ->
  ConPayload ->
  Option (List (String, RecordInfo))
cachedRecordRow recordPop ident cn (ConNamed _ _) =
  map (ri => [(cn, ri)]) (spLookupIdent ident cn recordPop)
cachedRecordRow _ _ _ _ = Some []

registerCachedRows : TcEnv ->
  (List (String, Scheme), List (String, RecordInfo)) ->
  TcEnv
registerCachedRows env (ctors, recs) =
  each (r => registerCachedRecord env.teDyn.dcModule (fst r) (snd r)) recs
  fold (e c => addCtor e (fst c) (snd c)) env ctors

registerCachedRecord : ModuleCtx -> String -> RecordInfo -> Unit
registerCachedRecord mctx key ri =
  mctx.mcCells.recordByNameRef :=
    omInsert key ri mctx.mcCells.recordByNameRef.value
  mctx.mcCells.fieldOwnersRef :=
    addFieldOwners key (recordFieldNames ri) mctx.mcCells.fieldOwnersRef.value

sigNamesToSet : List (String, Ty) -> OrdMap Unit -> OrdMap Unit
sigNamesToSet [] m = m
sigNamesToSet ((n, _) :: rest) m = sigNamesToSet rest (omInsert n () m)

processTopGroups : TcEnv ->
  List (String, Ty) ->
  List (String, (List Pat, Expr)) ->
  List String ->
  OrdMap Unit ->
  (List (String, Scheme), OrdMap (List (List Pat, Expr)))
processTopGroups env sigs defs names exported =
  env.teDyn.dcModule.mcCells.sigNameSetRef := sigNamesToSet sigs omEmpty
  env.teDyn.dcModule.mcCells.sigTyMapRef := omFromPairs (reverseL sigs) omEmpty
  let grouped = groupClauses defs
  let ordered = tarjanSCCs names (depGraphMap names grouped)
  let result = processSCCs env sigs grouped ordered
  resolvePendingJoins env.teDyn 0
  let failures =
    EffectSolver.closeRootAuthorities
      env.teDyn.dcModule.mcCells.effectSummaries
      env.teDyn.dcModule.mcCells.rigidAuthvarsRef.value
      (exportedRootCells exported (fst result))
      (widenOpenedFor env.teDyn.dcModule)
  -- read again after the close: a cell the root solved no longer appears
  let unsolved = rootCellsOf exported (fst result)
  let unsolvedIds = fold (acc (_, ids) => IdMap.union acc ids) Tip unsolved
  reportEffectSummaryFailures
    env.teDyn.dcModule
    (filterList (f => not (failureMentions unsolvedIds f)) failures)
  let _ =
    fold
      (seen u => reportUnsolvedExport env.teDyn.dcModule grouped seen u)
      Tip
      unsolved
  result

-- The authority cells an exported binding's published type holds unquantified:
-- a binding the value restriction keeps monomorphic leaves its type's cells to
-- the module root.
exportedRootCells : OrdMap Unit -> List (String, Scheme) -> Map Int Unit
exportedRootCells exported schemes =
  fold (acc (_, ids) => IdMap.union acc ids) Tip (rootCellsOf exported schemes)

rootCellsOf : OrdMap Unit ->
  List (String, Scheme) ->
  List (String, Map Int Unit)
rootCellsOf exported schemes =
  flatMap
    ((name, scheme) =>
      if omHasKey name exported then match unquantifiedAuthIds scheme
        Tip => []
        ids => [(name, ids)]
      else
        [])
    schemes

failureMentions : Map Int Unit -> SummaryFailure ObligationSite -> Bool
failureMentions Tip _ = False
failureMentions ids failure = match failure.esfAuthority
  Some (lo, hi) =>
    anyList (c => IdMap.has (authvarId c) ids) (authVars lo ++ authVars hi)
  None => False

-- An exported binding whose published type (or residual context) still holds
-- a cell after the root solved: nothing in its module bounds it below, and an
-- importer cannot supply it later.  Each cell is reported once, at the first
-- exported binding that holds it; the obligations over it are this failure,
-- not separate ones.  Located at the binding's first located expression.
reportUnsolvedExport : ModuleCtx ->
  OrdMap (List (List Pat, Expr)) ->
  Map Int Unit ->
  (String, Map Int Unit) ->
  Map Int Unit
reportUnsolvedExport mctx grouped seen (name, ids) =
  if IdMap.foldlWithKey (acc id _ => acc && IdMap.has id seen) True ids then
    seen
  else
    let loc = match clausesOf name grouped
      (_, body) :: _ => firstExprLoc body
      [] => None
    pushTypeErrorAt
      mctx
      TExportUnsolvedAuthority
      loc
      "exported binding `\{name}` has an authority in its type that nothing in this module determines; give `\{name}`, or the value it uses, a type signature that names the authority"
    IdMap.union seen ids

-- process each SCC as a letrec group in topological order.  The clause map is
-- threaded through and returned: a Module-arm group's clauses come back MARKED
-- (`processSCC`), and `checkBodyImpl` writes them back into the module's tree.
processSCCs : TcEnv ->
  List (String, Ty) ->
  OrdMap (List (List Pat, Expr)) ->
  List (List String) ->
  (List (String, Scheme), OrdMap (List (List Pat, Expr)))
processSCCs env _ grouped [] = ([], grouped)
processSCCs env sigs grouped (scc :: rest) =
  let (env2, schemes, grouped2) = processSCC env sigs grouped scc
  let (restSchemes, grouped3) = processSCCs env2 sigs grouped2 rest
  (schemes ++ restSchemes, grouped3)

processSCC : TcEnv ->
  List (String, Ty) ->
  OrdMap (List (List Pat, Expr)) ->
  List String ->
  (TcEnv, List (String, Scheme), OrdMap (List (List Pat, Expr)))
processSCC outer sigs grouped0 members =
  -- The group's own checks (generalization, defaulting, its signatures'
  -- coverage) are located at its members' clause bodies.
  let env = envAtIfSome (membersSpanLoc grouped0 members) outer
  -- Marking on the schedule (ARCH §E): a Module-arm group is marked HERE, after
  -- every group it depends on has generalized, with the dict-name set as it stands;
  -- inference reads the stamped twin of the marked clauses.  Flat (`None`): the
  -- caller marked and stamped the whole program, the map is used as given.
  let marking = env.teDyn.dcModule.mcCells.markingRef.value
  let grouped = match marking
    Some mm => markGroupClauses mm env members grouped0
    None => grouped0
  let groupedStamped = match marking
    Some mm => stampGroupClauses mm members grouped
    None => grouped
  enterLevel env.teDyn.dcModule ()
  beginEffectSummaryScope env.teDyn.dcModule ()
  let oblN0 = wMark env.teDyn.dcModule.mcCells.implObls
  let callN0 = wMark env.teDyn.dcModule.mcCells.obls
  let dictN0 = goalsMark env.teDyn.dcModule.mcGraph ()
  let placeholders = map (m => (m, freshVar env.teDyn.dcModule ())) members
  let scopedMembers =
    scopeMembers
      env.teDyn.dcModule
      (captureScope env.teDyn.dcModule ())
      groupedStamped
      placeholders
  let (regs, sigTvMaps) = preunifySigsEx env.teDyn.dcModule sigs scopedMembers
  let savedRigidEffects = env.teDyn.dcModule.mcCells.rigidEffvarsRef.value
  let savedRigidAuths = env.teDyn.dcModule.mcCells.rigidAuthvarsRef.value
  env.teDyn.dcModule.mcCells.rigidEffvarsRef :=
    fold
      (roots member =>
        IdMap.foldlWithKey
          (acc id _ => IdMap.set id () acc)
          roots
          member.smDeclaredRoots.value)
      savedRigidEffects
      scopedMembers
  env.teDyn.dcModule.mcCells.rigidAuthvarsRef :=
    fold
      (roots member =>
        IdMap.foldlWithKey
          (acc id _ => IdMap.set id () acc)
          roots
          member.smDeclaredAuths.value)
      savedRigidAuths
      scopedMembers
  let env2 = extendBindings env (map scopedMemberBinding scopedMembers)
  -- P0-19 (constrained-receiver arm): publish THIS group's `=>`-constraint vars for
  -- the duration of body inference, so a definer-shadow method occurrence on one of
  -- them (`neq x y = not (eq x y)` under `neq : Eq a => …`) is seen as a DISPATCH and
  -- not monomorphised to the shadowing standalone's declared domain.
  -- `gcMonos` answers a SPELLING question (`dictVarSatisfiesIface`
  -- compares interface NAMES), so U1b (#1482) projects back to the name here rather than
  -- widening a second ref for a reader that would only throw the identity away.
  let groupCtx = GroupCtx {
    gcMonos = flatMap (r => flatMap ifaceMonoName (regIfaceMonosOf r)) regs,
    gcPendingEscapes = Ref [],
  }
  let groupEnv = { env2 | teDyn = { env2.teDyn | dcGroup = Some groupCtx } }
  -- #837: the schemeObligationsRef snapshot/restore window is RETIRED.  It existed
  -- because registerLocalScheme entries were NAME-KEYED and body-scoped: a prelude
  -- where-helper named `g` (core's `find`) leaked obligations onto an unrelated
  -- top-level `g` in a later body (a phantom `Num a =>` on types/numlit_bidir's
  -- signed fn).  Registration/lookup now key by (name, binding-id), so a top-level
  -- `g`'s use keys (g, its-id) and can never match a where-helper `g`'s (g, 0) entry.
  inferMembers groupEnv sigs groupedStamped scopedMembers
  each (member => checkRecursiveValue env.teDyn member.smOwned) scopedMembers
  resolvePendingJoins env.teDyn env.teDyn.dcModule.mcCells.currentLevel.value
  let residuals =
    finishEffectSummaryScopeKeeping
      env.teDyn.dcModule
      (quantifiableAuthorities env2 groupedStamped scopedMembers)
      (fold (acc member => memberEffectRoots member acc) Tip scopedMembers)
      (fold
        (acc member =>
          borrowedEffectCells env.teDyn.dcModule member.smOwned.bsValue acc)
        Tip
        scopedMembers)
  env.teDyn.dcModule.mcCells.rigidEffvarsRef := savedRigidEffects
  env.teDyn.dcModule.mcCells.rigidAuthvarsRef := savedRigidAuths
  checkSigsTooGeneral env.teDyn.dcModule sigTvMaps
  checkSigsFixedByExpansive env2 groupedStamped scopedMembers sigTvMaps
  registerConstraintRegs env.teDyn.dcModule regs
  flushPendingEscapes env.teDyn.dcModule (Some groupCtx)
  exitLevel env.teDyn.dcModule ()
  -- PLAN.md #11 (locked §0.2): GROUP-LEVEL + per-binding Num defaulting.  Ground
  -- every ambiguous Num-only var to Int before this group generalizes.  A live var
  -- carried by a declared signature stays caller-determined across both passes;
  -- an argument-reachable var also stays polymorphic.  Body-only vars (`n = tag [1,2,3]`) still ground.  Scoped to
  -- THIS group's newly-added obligations (prepended at the front) so an earlier
  -- group's already-generalized var is never touched.
  let protectedSigIds = sccProtectedSignatureIds sigTvMaps
  let addedObls = wWindow env.teDyn.dcModule.mcCells.implObls oblN0
  let groupObls = addedObls ++ callUOblsWindow env.teDyn.dcModule callN0
  -- Determination holds rigid exactly the variables this group does not own: the
  -- declared ones and those in an argument position of a member's type, which the
  -- caller supplies.  A result-position or body-local variable is the group's.
  let unownedIds =
    omFromNames
      (map intToString (flatMap monoArgUnboundIds (map snd placeholders)))
      protectedSigIds
  improveByUniqueImpl env.teDyn protectedSigIds addedObls
  improveByUniqueImpl
    env.teDyn
    protectedSigIds
    (callUOblsWindow env.teDyn.dcModule callN0)
  determineByUniqueInstance env.teDyn.dcModule unownedIds groupObls
  -- #23: also ground an ambiguous Num var that reaches this group ONLY through a
  -- constrained-callee instantiation (its Num obligation lives on the call/dict deltas,
  -- not the impl obligation channel).  See numCallObls/numDictObls.  The synthetic entries
  -- feed ONLY the Num-defaulting search; addedObls alone still drives the
  -- ambiguous-constraint/scheme-obligation registration below.
  let defaultObls = addedObls ++ calleeNumObls env.teDyn.dcModule callN0 dictN0
  let sccGuard = NumGuard {
    ngGoals = groupObls,
    ngRigidIds = protectedSigIds,
    ngOuterBelow = None,
  }
  let withheld = finalizeNumBoundary
    env.teDyn
    NumBoundary {
      nbDisposition =
        NumBoundaryOwnedScc (env.teDyn.dcModule.mcCells.currentLevel.value + 1),
      nbMembers = map snd placeholders,
      nbSurvivingIds =
        tiedSurvivors
          env.teDyn.dcModule.mcGraph
          (map snd placeholders)
          sccGuard
          protectedSigIds,
      nbDefaultObls = defaultObls,
      nbAmbiguityObls = addedObls,
      nbGuard = sccGuard,
    }  -- RETPOS soundness
  -- Defaulting is a substitution like any other, so the goals it changed are
  -- improved and determined once more.
  improveByUniqueImpl env.teDyn protectedSigIds groupObls
  determineByUniqueInstance env.teDyn.dcModule unownedIds groupObls
  checkSigVarGoals
    env.teDyn.dcModule
    DeclaredBySignature
    protectedSigIds
    sigTvMaps
    groupObls
  let schemes =
    sccSchemes
      env2
      sigs
      groupedStamped
      (isLetrecGroup members)
      residuals
      0
      scopedMembers
  let scopedSchemes = alignScopedSchemes scopedMembers schemes
  checkSigsOverExpansive env2 groupedStamped sigTvMaps
  -- #23 two-hop forward: also record constraints FORWARDED from a constrained
  -- callee (living on the call delta, never in addedObls) into schemeObligationsRef,
  -- so a caller of this group re-instantiates them and its own group can ground the
  -- shared ambiguous var.
  -- The CALL delta is passed RAW (it already carries each predicate's joint `List
  -- Mono`); registerSchemeObligations maps it with forwardedVecObls so a multi-param
  -- predicate survives whole.  #838 I5: a constrained callee's DICT slot is forwarded
  -- through THIS same call delta — inferDictAtFound records it as a 1-ary PCallSlot
  -- obligation (recordCallObligations, beside pushDictApp), so no separate re-derivation off
  -- the dict delta exists; addedObls carries only the real impl-obligation delta.
  let callOblsDelta = callOblsWindow env.teDyn.dcModule callN0
  registerSchemeObligations
    env.teDyn.dcModule
    env.teDyn.dcModule.mcCells.schemeDefIdsRef.value
    sigTvMaps
    callOblsDelta
    addedObls
    schemes
  let liveIds = liveMemberIds env.teDyn.dcModule (map snd placeholders)
  rejectUndeterminedVectors
    env.teDyn.dcModule
    unownedIds
    liveIds
    addedObls
    (callUOblsWindow env.teDyn.dcModule callN0
      ++ nestedRequireGoals env.teDyn.dcModule unownedIds liveIds groupObls)
  rejectWithheldAmbiguity env.teDyn.dcModule unownedIds withheld groupObls
  -- Signature constraint soundness: a signed member whose body induces an
  -- interface constraint on one of its own quantified vars that its declared `=>`
  -- context (superclass-closed) does NOT cover severs the constraint for callers
  -- → wrong-dictionary dispatch (a silent wrong answer).  Reject at the def-site.
  -- Runs on every path; the census over compiler+stdlib+sqlite was 0 new failures.
  checkSigConstraintCoverage
    env.teDyn.dcModule
    regs
    sigs
    sigTvMaps
    callOblsDelta
    addedObls
    schemes
  registerInferredConstraints
    env.teDyn.dcModule
    sigs
    callOblsDelta
    addedObls
    scopedSchemes
  -- From here on every instance-head matcher holds this group's declared variables
  -- rigid; the group's own generalization above reads them as free variables, so a
  -- goal `checkSigVarGoals` rejected is not reported a second time.
  declareRigidVars env.teDyn.dcModule (omKeys protectedSigIds)
  -- The group's own occurrences of the members it just promoted (see
  -- `markRecursiveOccurrences`); Flat marks nothing here.
  let groupedOut = match marking
    Some mm =>
      markRecursiveOccurrences
        env.teDyn.dcModule
        mm
        placeholders
        scopedMembers
        grouped
    None => grouped
  match marking
    Some _ =>
      recordTopGrants
        env.teDyn.dcModule.mcGraph
        env.teDyn.dcModule.mcCells.currentModuleRef.value
        schemes
        groupedOut
    None => ()
  (extendTermBindings outer schemes, schemes, groupedOut)

scopedMemberBinding : ScopedMember -> (String, EnvBinding)
scopedMemberBinding member =
  let binding =
    optionOr
      (ordinaryEnvBinding
        (Forall
          []
          []
          []
          []
          (memberForce member)
          member.smOwned.bsRecursiveValue))
      member.smRecursive.value
  (
    member.smName,
    bindingWithStandalone binding (LocalStandalone, binding.ebValue),
  )

scopeMembers : ModuleCtx ->
  ScopeId ->
  OrdMap (List (List Pat, Expr)) ->
  List (String, Mono) ->
  List ScopedMember
scopeMembers mctx _ _ [] = []
scopeMembers mctx parent grouped ((name, mono) :: rest) =
  let sid =
    Scopes.freshScope
      (currentScopeStore mctx.mcGraph ())
      (Some parent)
      mctx.mcCells.currentLevel.value
      (Scopes.scopeFrame (currentScopeStore mctx.mcGraph ()) parent).sfModuleId
      (BindingOwner name)
  -- This is the evaluator's topGroupValue distinction: a singleton nullary
  -- clause is a thunk, including a thunk whose result happens to be a function.
  let clauses = clausesOf name grouped
  let arity = match clauses
    (pats, _) :: _ => listLen pats
    [] => 0
  let owned = newBindingSummary arity (freshVar mctx) (freshEffectSummary mctx)
  let force = match clauses
    [([], _)] => Some owned.bsForce
    _ => None
  ScopedMember {
      smName = name,
      smMono = mono,
      smOwned = owned,
      smDeclaredRoots = Ref Tip,
      smDeclaredAuths = Ref Tip,
      smSigned = Ref False,
      smRecursive = Ref None,
      smForce = force,
      smForceBound = Ref None,
      smScope = sid,
    }
    :: scopeMembers mctx parent grouped rest

alignScopedSchemes : List ScopedMember ->
  List (String, Scheme) ->
  List ScopedScheme
alignScopedSchemes [] [] = []
alignScopedSchemes (member :: members) ((name, scheme) :: schemes)
  | member.smName == name =
    ScopedScheme {
        ssName = name,
        ssScheme = scheme,
        ssScope = member.smScope,
      }
      :: alignScopedSchemes members schemes
  | otherwise = panic "scope/member scheme alignment mismatch"
alignScopedSchemes _ _ = panic "scope/member scheme arity mismatch"

-- Pass B: infer each member's clauses, unifying with its placeholder.
-- Phase 73 (bidirectional, signature-driven parameter typing): a member WITH a
-- signature peels its declared arrow types onto the clause parameter patterns
-- BEFORE inferring the body, so the body sees concrete parameter types (a
-- receiver-directed field access `f p = p.x` or a `String`-indexed `s.[0]`
-- resolves from the signature alone).  [peel] is Some(placeholder) for a signed
-- member, None otherwise; the placeholder already holds the sig instantiation
-- (preunifySigsEx unified it), and its shared tyvars accumulate unifications
-- across clauses exactly as the oracle's `sig_t` does.  Purely additive: the
-- per-clause `unify v arrow` below imposes the same equalities anyway.
inferMembers : TcEnv ->
  List (String, Ty) ->
  OrdMap (List (List Pat, Expr)) ->
  List ScopedMember ->
  Unit
inferMembers env _ _ [] = ()
inferMembers outer sigs grouped (member :: rest) =
  let m = member.smName
  -- A member's own checks (its signature against its value, its forcing
  -- bound, its effect escape) are located at its clauses' bodies.
  let env = envAtIfSome (membersSpanLoc grouped [m]) outer
  let v = member.smMono
  openScope env.teDyn.dcModule member.smScope
  env.teDyn.dcModule.mcCells.currentFn := m
  let peel = memberPeelSource env.teDyn.dcModule sigs m v
  let effs = inferMemberClauses env peel member.smOwned (clausesOf m grouped)
  -- The signature is checked against the value the clauses return.
  if member.smSigned.value then
    unifyInto
      (dynAtIfSome (joinLocs (clauseSpans valueSpanLoc grouped [m])) env.teDyn)
      True
      member.smMono
      member.smOwned.bsValue
  match member.smForceBound.value
    Some bound =>
      fold
        (_ cl => recordFileBound env.teDyn.dcModule (snd cl) bound)
        ()
        (clausesOf m grouped)
      rowInto
        env.teDyn
        True
        (effrowNorm bound)
        (effrowNorm (optionOr pureRow member.smForce))
    None => ()
  env.teDyn.dcModule.mcCells.currentFn := ""
  closeScope env.teDyn.dcModule ()
  -- A value signature constrains the returned value, not the cost of forcing
  -- its initializer. That cost travels on the binding and is checked at uses.
  match member.smForce
    None => checkEffectEscape env.teDyn sigs m effs
    Some _ => ()
  inferMembers outer sigs grouped rest

-- The span of the named members' clause bodies (`exprSpanLoc`), joined.
membersSpanLoc : OrdMap (List (List Pat, Expr)) -> List String -> Option Loc
membersSpanLoc grouped names = joinLocs (clauseSpans exprSpanLoc grouped names)

-- [span] of each clause body of the named members.
clauseSpans : (Expr -> Option Loc) ->
  OrdMap (List (List Pat, Expr)) ->
  List String ->
  List Loc
clauseSpans span grouped names =
  flatMap
    (m =>
      flatMap
        (cl => option [] (l => [l]) (span (snd cl)))
        (clausesOf m grouped))
    names

-- the peel source for a member: Some placeholder if it has a signature (peel the
-- declared arrow domains onto the clause params), None otherwise
memberPeelSource : ModuleCtx ->
  List (String, Ty) ->
  String ->
  Mono ->
  Option Mono
memberPeelSource mctx sigs m v =
  map (_ => v) (omLookup m mctx.mcCells.sigNameSetRef.value)

regIfaceMonosOf : ConstraintReg -> List (IfaceRef, List Mono)
regIfaceMonosOf reg = reg.crIfaceMonos

-- U1b (#1482): project a reg's (interface occurrence, mono) pair back to the SPELLING
-- for `gcMonos`, whose only reader (`dictVarSatisfiesIface`) compares
-- interface NAMES.
-- S-dict-arity-contract: a reg entry is now ONE PREDICATE carrying ALL its bare-tyvar
-- monos, so this fans back out to one (name, mono) pair per variable.  Collapsing the
-- SLOT must not collapse the READ-ONLY census this and `declaredPairOne` feed: they
-- answer "is this variable declared at this interface", not "how many dicts", and
-- dropping `b` from `Ix a b =>` would make a body use at `b` UNCOVERED — an
-- over-rejection of a program that type-checks today.
ifaceMonoName : (IfaceRef, List Mono) -> List (String, Mono)
ifaceMonoName (ir, monos) = map (mono => (ir.irName, mono)) monos

-- typecheck one program with seeded value schemes + accumulated data decls, as
-- the prelude's core pass.  Re-registers prior modules' public data declarations
-- (`accData ++ prog`) so imported constructors AND named-field-variant record
-- info (e.g. ast's DInterface) resolve.  The program's own impls are its impl
-- universe, as the tree arm's core pass (`elabModuleStamp`) has them: an impl
-- body's occurrence then routes through the impl's `requires` given on both arms.
-- Returns the module's own value schemes.  [prev] is the record current before the
-- pass, whose oracle and warnings the unseeded pass carries.
export
checkModuleFull : ModuleCtx ->
  List (String, Scheme) ->
  List Decl ->
  List Decl ->
  (ModuleBindings, List Decl, ModuleCtx)
checkModuleFull prev seedVars accData prog =
  checkModuleFullImpl
    prev.mcGraph
    (checkRunResidue prev)
    ""
    (plainModuleSeed seedVars)
    accData
    prog
    prog

-- E5: like checkModuleFull but takes [implDecls] (core + every EARLIER module — NOT this
-- module: foldModules only grows the accumulator for LATER modules, so a module is never in
-- its own [implDecls]; a caller that needs this module's own decls too must fold [prog] in
-- itself, as the `superDecls` binding in checkBodyImpl does for #1457) as the impl-body
-- inference universe.  It ALSO infers THIS module's parametric impl
-- bodies, so their
-- ARG-position ELEMENT dispatch (`eq`/`compare`/… on the impl head tyvar) reaches
-- inferMethodAt and lands in pendingArgStamps, which elabModuleStamp's
-- resolveArgStamps then stamps RDict (via the requires dict registered by
-- registerImplRequires).  The stage-K ClassEnv gives body inference the interface
-- declarations, while [implDecls] lets a body dispatch against an earlier module's impl.
-- [gctx] and [runSeed] are the drive's graph record and the module's check-run seed,
-- passed to its mint (see `checkBodyImpl`), and the module's record is returned beside
-- its bindings.
checkModuleFullImpl : GraphCtx ->
  CheckRunSeed ->
  String ->
  ModuleSeed ->
  List Decl ->
  List Decl ->
  List Decl ->
  (ModuleBindings, List Decl, ModuleCtx)
checkModuleFullImpl gctx runSeed mid seedVars _accData implDecls prog =
  let (schemes, marked, mctx) =
    checkBodyImpl gctx runSeed seedVars mid implDecls prog
  -- #2705 (M2 phase 2): solving is not optional.  Every module a Module-arm driver
  -- checks — `check`, `run`, `build`, the LSP alike — cuts its stamping context
  -- here, for the one graph-end drain
  -- (`drainStampQueue`, DICT §6.2 T4).  A driver that queues and never drains
  -- leaves the queue for the next driver entry, so every Module-arm driver ends
  -- with a drain (`driveGraphK`'s, or `checkGraphFinish` on a memo path).
  enqueueStampCtx mctx mid implDecls
  (schemes, marked, mctx)

-- public top-level value names (the pub flag may sit on the sig, def, or extern).
-- C8(a): a PUBLIC interface ALSO exports its method names so an importer can see
-- their schemes — methods of an `export interface` are appended to the exported value
-- schemes.
export
publicValNames : List Decl -> List String
publicValNames [] = []
publicValNames ((DAttrib _ d) :: rest) =
  publicValNames [d] ++ publicValNames rest
publicValNames ((DFunDef True n _ _ _ _) :: rest) = n :: publicValNames rest
publicValNames ((DTypeSig True n _ _) :: rest) = n :: publicValNames rest
publicValNames ((DExtern (ExternDecl { edPub = True, edName = n, ... })) :: rest) =
  n :: publicValNames rest
publicValNames ((DInterface { pub = True, methods, ... }) :: rest) =
  ifaceMethodNames methods ++ publicValNames rest
publicValNames (_ :: rest) = publicValNames rest

-- Impl-completeness is not part of this fold: it reads stage K's `CE`, whose rows carry
-- their declaring module's ordinal, and `declEnvVisibleAt cur o` (`o <= cur`) admits the
-- reader's OWN row.  The ordering guarantee of this fold, which `checkBodyImpl`'s Module
-- arm calls BEFORE the shadow reads so that this module's own decls are visible at the
-- read, is therefore not what impl-completeness depends on.  Do not add a completeness
-- accumulator to restore an ordering property that lives on the ordinal predicate.
appendUniverseAccums : GraphCtx -> String -> List Decl -> Unit
appendUniverseAccums gctx mid prog =
  -- SHADOW-SEMANTICS S1-PRELUDE (a), RULED 2026-08-10 (#1375 item 2, #1499 clause (b)):
  -- The prelude is not S1's left (standalone) operand.  The asymmetry with the shadow
  -- builders' interface-method test, `methodNameDeclaredAt`, which counts the prelude's
  -- interfaces at ordinal 0, is deliberate and is S1-PRELUDE's own
  -- (`SHADOW-SEMANTICS.md:225`): S1's INTERFACE operand is the wider "nameable in M",
  -- which INCLUDES the prelude, while its STANDALONE operand is pinned by the
  -- definer/importer kind partition — and a standalone reaching M only as an implicit
  -- prelude export is NEITHER kind, so it creates no shadow in M.
  -- This ref's ONE reader is the `importerShadows` binding in `checkBodyImpl`
  -- (`standaloneShadowsFromSet`'s `fnSet`), i.e. exactly that left operand; folding the
  -- prelude's own funDefs in admitted every prelude standalone as an IMPORTER shadow —
  -- the reading S1-PRELUDE names and REJECTS by consequence — so a user interface method
  -- colliding with `isEven`/`count` fell back to the prelude function at any receiver head
  -- carrying no impl, ACCEPTING at exit 0 where the ruling requires a located reject
  -- (`test/shadow_fixtures/x1_prelude_standalone_not_left_operand.mdk`, x2, matrix rows
  -- 46-48).  SUBTRACTING the prelude's names at the READ site instead would be WRONG:
  -- a name the prelude AND a real user module both define IS imported into M by the user
  -- module and DOES create a shadow there.  Not folding is what expresses "contributes
  -- nothing"; the union still carries the name via whichever user module defines it.
  if isPreludeMid mid then
    ()
  else
    gctx.crossRun.universeFunNamesRef :=
      namesToSet
        (map fst (funDefs prog))
        gctx.crossRun.universeFunNamesRef.value
  -- #154 PR-B: grow the dispatch-index accumulator by THIS module's interface indices.
  -- APPEND (universe first) so the accumulated list stays in core-first order.  #1351 L5
  -- (CONTRACT): `dispatchIdxScoped` is identity-keyed only, so a prior-module entry this
  -- module never names cannot be queried by spelling at all.
  gctx.crossRun.universeMethodDispatchIdxByIdRef :=
    gctx.crossRun.universeMethodDispatchIdxByIdRef.value
      ++ argDispatchIndicesById prog
  -- No impl universe is grown here: the Module arm's `obUniv` projects stage K's `IE` at the
  -- reader's ordinal (`ieUniverseAt`), so this function no longer answers "what impls exist"
  -- at all; every line here is an interface/method/name-side accumulator.  Do not add an
  -- impl accumulator — `IE` is the one answer, and a second one is design law L1's
  -- divergence.
  ()

-- Takes this module's whole decl list, not a pre-filtered one.  The polarity
-- fixpoint runs over all of it (#2112), and filtering at the CALL SITE is what once let
-- the opaque-kind half go missing.
--
-- `fieldOwnersRef` arrives holding the K seed PLUS everything this module registered
-- during inference, and `registerAllDataScoped … pubDecls` below registers this module's
-- PUBLIC records a SECOND time.  `addFieldOwners` conses without dedupe, so every own
-- public record is DOUBLE-listed in `fieldOwnersRef` from that line until the next
-- `freshModuleCtx`.  Unobservable today only because nothing reads the multimap in between
-- (the two population walkers read `env2` and `recordByNameRef`).  A doubled owner key is
-- the shape `declEnvSeedChain`'s own-row note exists to prevent.  `fieldOwnerNames`
-- `sortUniqS`es on read, so the doubling does not move an answer; a new reader of
-- `fieldOwnersRef` after this point must de-duplicate first or restore a reset.
-- (`dataParamKindsRef` gets the same
-- doubling; it is inert there because `lookupTab` is first-match over identity-bearing
-- keys whose two copies are equal.)
appendDataUniverse : ModuleCtx -> String -> List Decl -> Unit
appendDataUniverse mctx mid prog0 =
  let pubDecls = publicDataDecls prog0
  -- The alias half of the reload is a stage-K projection, so it takes THIS module's
  -- ordinal, strictly BELOW-this-module (`aliasUniverseAt`'s `<`): the registration
  -- below is what puts this module's own aliases, public and private, in front.
  loadDataUniverse mctx (declEnvsOrdOf mid mctx.mcGraph.declEnvsRef.value)
  -- #2112: the polarity fixpoint sees the WHOLE module (`prog0`), the universe
  -- receives only the public keys — see `registerAllDataScoped`.
  let env2 =
    registerAllDataScoped
      (withCtors mctx (spFloor mctx.mcGraph.crossRun.universeCtorPop.value))
      (publicDataScopeDecls prog0)
      prog0
  -- Both walkers read the payloads this registration just made back out of `env2` and
  -- `recordByNameRef`, so each population row holds the very object its floor holds.
  mctx.mcGraph.crossRun.universeCtorPop :=
    insertCtorPop env2 pubDecls mctx.mcGraph.crossRun.universeCtorPop.value
  mctx.mcGraph.crossRun.universeRecordPop :=
    insertRecordPop mctx pubDecls mctx.mcGraph.crossRun.universeRecordPop.value
  mctx.mcCells.ownPopsRef :=
    (insertCtorPop env2 pubDecls spEmpty, insertRecordPop mctx pubDecls spEmpty)

-- What `appendDataUniverse` registers to elaborate a module's public data: the
-- public declarations plus every alias the module declares, private ones
-- included.  A public field may name a private alias, and the scheme it
-- elaborates to here is the one every importer reads back, so it expands under
-- the declaring module's aliases.  The private aliases reach only the working
-- alias table, which the next module's arm reloads; the populations take
-- `pubDecls` alone.
publicDataScopeDecls : List Decl -> List Decl
publicDataScopeDecls prog0 =
  filterList (d => publicDataDecl d || isAliasDecl d) prog0

-- Candidate spellings come from the same three binding sources the environment sees:
-- nameable bare methods (including the implicit core row), selective-import local
-- names, and module-alias-qualified names.  `lookupBinding` below remains the final
-- no-new-name gate, while this bounded list avoids walking every ordinary seed binding.
importedMethodBindingNames : GraphCtx ->
  List Decl ->
  List (String, String) ->
  List String
importedMethodBindingNames gctx prog aliases =
  flatMap snd (nameableIfaceRows gctx prog)
    ++ importedMemberBindingNames prog
    ++ map fst aliases

-- ── import aliasing: re-key the dict-arity / dict-iface tables ───────────────────
-- Both tables (funConstraintsRef, funConstraintIfacesRef) are keyed by the name a CALL
-- SITE writes.  An alias makes that name differ from the definition's, so without this
-- an aliased constrained callee gets zero dict routes and under-applies.  Generic over
-- the payload so the arity table (List Int) and the iface table (List String) share it.
--
-- [qual] is the (definerMid, name)-keyed table, which is what makes this exact: an
-- entry is copied only when its DEFINER is the very module the alias names.
-- #1114 (#845): THIS module's imported bindings' SCHEME CONTEXTS, keyed by the local
-- spelling the importer writes.  Structurally the sibling of `aliasConstraintEntries`
-- below — same `DUse` walk, same "copy an entry only when its DEFINER is the very module
-- this import names" precision, and the payload is likewise taken from the
-- `(definerMid, name)`-keyed qual table.
--
-- TWO deliberate differences from `aliasConstraintEntries`, both because that function
-- serves the DICT-ARITY tables on the emit path and this one serves the CHECK-time
-- obligation channel:
--   * it has a `UseWild` arm.  `aliasConstraintEntries` needs none — on the emit path a
--     wildcard-imported name keeps its own spelling and `funConstraintsRef` is re-seeded
--     from the bare `crossModuleFunConstraintsRef` accumulator, which already covers it.
--     The check path has no such bare re-seed (that ref is the emit path's), so without
--     this arm `import m.*` would be the one spelling that still dropped the obligation.
--   * it emits the UNALIASED member of a `UseGroup` too (`useMemberLocal`, not
--     `useMemberAlias`), because plain `import m.{f}` is the common spelling and is
--     exactly what #845 pins.
--
-- Kept SEPARATE from `aliasConstraintEntries` rather than generalizing it. Adding a
-- `UseWild` arm there would change what `funConstraintsRef` holds on the emit path, i.e.
-- dict-passing arity — a different judgment, with a different blast radius, reached from
-- here only by the coincidence that both read the same qual-table shape.
importedSchemeOblEntries : List Decl ->
  List ((String, String), List VecObl) ->
  List (String, List VecObl)
importedSchemeOblEntries [] _ = []
importedSchemeOblEntries ((DAttrib _ d) :: rest) qual =
  importedSchemeOblEntries [d] qual ++ importedSchemeOblEntries rest qual
importedSchemeOblEntries ((DUse _ path _) :: rest) qual =
  schemeOblEntriesFor (importTableMid path) path qual
    ++ importedSchemeOblEntries rest qual
importedSchemeOblEntries (_ :: rest) qual = importedSchemeOblEntries rest qual

-- build THIS module's import-scoped seed: walk its DUse decls, and for each one
-- pick the imported names out of the named dependency's public schemes (held in
-- depEnv, keyed by the dotted module id that useModId yields == the loader's
-- mid).  `core` DUse decls are skipped — core is always seeded via baseSeed.
-- ── #1675: reject an import that admits a name with more than one denotation ──────
-- The hub `export import lib.pa.{g}` + `export import lib.pb.{g}` exports ONE spelling
-- `g` standing for TWO definitions.  Downstream, `resolveMemberRows`' `lookupAssoc`
-- took the first of them and every verb exited 0, so which function ran was decided by
-- the order of two `export import` lines — a semantically null edit moving the printed
-- value from `2` to `10`.  This is the reject.
--
-- The mechanism is the exact-key arm, not the `__<name>` suffix fallback, and the
-- distinction decides where the check can live.  #1675's body cites the suffix `filter`
-- ("cited, not instrumented", per its own pin's claim) — but `types/private_mangle`
-- runs ONLY in the emit drivers, so on `check`/`run` the hub's rows are keyed by the
-- BARE name, `lookupAssoc origin` HITS, and the fallback is never reached.  A guard
-- written on "the filter returned more than one candidate" is green on the whole repro.
-- The ambiguity is a property of the DEPENDENCY'S EXPORT TABLE, which is where
-- `deAmbigValues` records it, on both paths at once.
--
-- Reported at the IMPORT DECL (that is where the location points, and where the fix
-- belongs), but keyed on an OCCURRENCE: a name is rejected only if this module actually
-- WRITES it, in the spelling the form binds it under — bare for `import m.*` and for a
-- selective `{g}`, alias-qualified (`A.g`) for `import m as A`.  A hub may re-export a
-- hundred names under two denotations; an importer that never mentions any of them has
-- no ambiguity to resolve and must not be rejected.  This is the USE-SITE model taken
-- literally (#1070's reject-at-declaration stays superseded; the hub itself is still
-- legal).  It also keeps the verdict from depending on which definer came first: the
-- moment the name IS written, the import is rejected rather than silently resolved.
--
-- The reject is at USE, not at ADMISSION: `import lib.hub.*` / `import lib.hub as H`
-- stay legal when the importer never mentions the colliding name, as the selective form
-- does.  `T-AMBIGUOUS-ALIAS-METHOD`, which rejects at admission, is a DIFFERENT
-- namespace: methods are dispatched by argument type, where "admitted into scope" and
-- "used" are hard to pull apart because having the method callable is often the point.
-- Whether the method side wants the same narrowing is a separate question, deliberately
-- not answered here.
--
-- The chain is not weakened by narrowing to an occurrence.  `reexportDefiners` takes
-- a wildcard `export import`'s rows WHOLESALE, so a module that re-exports an ambiguous
-- hub without mentioning the name carries the ambiguity into its OWN export table, and
-- the first module downstream that does write the name is rejected there.  Nothing is
-- laundered clean by passing through a silent hop.
--
-- Called from `checkBodyImpl`, after its module mint, and not from `importSeed`.
-- `importSeed` is where the member resolution lives and was the first home for this, but
-- the seed is computed in `foldModules` BEFORE the module's worker runs, and
-- `checkBodyImpl` opens with `freshModuleCtx` — which clears `typeErrors`.  MEASURED on
-- that version: `run` exited 1 with the unlocated "detected during elaboration … see
-- issue #1812" fallback (the sticky flag survives the reset, the diagnostic does not)
-- and `check`/`check --json` were both still SILENT at exit 0 on the whole repro.  A
-- diagnostic pushed while a seed is being built cannot be reported.  Everything this
-- needs is on the module's own `DUse` decls plus the graph table, so nothing is lost by
-- moving it inside the window; `checkBodyImpl` is the ONE body all four drivers share
-- (`checkModuleFullImpl` and `elabModuleStamp` both route through it), which is what
-- keeps `check` and the run/build elaboration pass answering alike.
reportAmbiguousImports : ModuleCtx -> List Decl -> Unit
reportAmbiguousImports mctx prog0 =
  reportAmbiguousImportsIn mctx (moduleRefNameSet prog0) prog0

-- every name this module's own decl bodies REFERENCE, as a set.  Parallels `groupRefs`'
-- collector (`freeEVars`, which skips locally bound names; `allEVars` here keeps every
-- occurrence) one level up, at the decl layer: the top-level clause bodies plus
-- the impl/default/prop/test bodies, which is every place a user program can spell
-- an imported value.  Alias-qualified references arrive here already flattened into a
-- single dotted `EVar "A.g"` by desugar's `rewriteAliasQual` (via `qualifiedLocal`), so
-- the alias spelling is a plain string lookup and needs no separate walk.
--
-- `allEVars` has no `EMethodRef` arm and does not need one: no production verb ever
-- constructs that node (it does carry `EMethodAt`/`EDictAt`, the shapes the elaborate
-- driver's dict pre-pass actually mints).  Independently of shape, the rows being filtered
-- come from `ambiguousExportRows` → `modulePubDefiners` → `pubTopFnNames`, i.e.
-- `declTopFnNames` ∩ exports — so an interface method name can never be in `amb` at all.
moduleRefNameSet : List Decl -> OrdMap Unit
moduleRefNameSet decls = namesToSet (flatMap declRefNames decls) omEmpty

-- WS-2/D2: THIS module's imported value name → import-source module id, from its DUse
-- decls.  Mirrors importSeed's walk but records (localName, depId) for EXPLICIT imports
-- only (importedBindings = Some bindings); a wildcard `import mod.*` (None) is skipped —
-- it can't enumerate names here, so those names fall back to the bare arity table at the
-- call site.  `core` is skipped (core fns route via the prelude dict machinery, never the
-- cross-module qual tables).  depId == useModId == the loader mid == the qual
-- tables' definer key for a DIRECT import; a re-exported fn's depId is the intermediate
-- (≠ definer), so its qual lookup misses and it too falls back to bare (correct).
--
-- Keyed by the LOCAL name, because that is the name the CALL SITE writes: under a member
-- alias (`import m.{a as b}`) the call site says `b`, so `b` is what must map to m.
--
-- A whole-module alias (`import m as A`) contributes nothing, for the same reason a
-- wildcard doesn't: its locals are one-per-export and this walk has no depEnv to
-- enumerate them.  Those call sites take the same documented bare-table fallback as
-- every wildcard import does today.  The dict ARGS themselves are unaffected — they are
-- stamped from the callee's SCHEME, which importSeed binds under the alias local — so
-- this costs only the cross-module arity DISAMBIGUATION, and only when two modules
-- export same-named constrained fns of differing dict arity.
-- ── import-scoped constructor overlay ─────────────────────────────────────────
-- The `data`/`newtype` decls (from the surrounding universe `pool`) whose
-- CONSTRUCTORS this module binds by name, read from its own DUse decls.  They
-- OVERLAY the whole-universe ctor tables (the typecheck scheme table, the
-- record-info table AND the exhaust oracle) so a bare ctor / record name resolves
-- to the SPECIFIC module this unit imports it from — instead of the universe's
-- arbitrary load-order winner, the #674 root cause where the check side
-- (last-loaded-wins) and the native mangler (first-import-wins) DISAGREED.
--
-- A `UseGroup` member contributes its owning decl when EITHER
--   (a) it carries the `(..)` flag and names the decl's TYPE (`import m.{T(..)}`) —
--       the original #674 rule; or
--   (b) it names one of the decl's constructors (`import m.{T, C}` — and, because a
--       record's sole variant carries the type's own name, `import m.{Cfg}` for a
--       `data Cfg = { … }`).  (b) is the half that drains #1259 (the
--       ctor-scheme env) and #1256 (the record-info table).
--
-- Rule (b) is a CONSTRUCTOR-name test, not a "not a type name" test, and the
-- difference is observable.  A member spelled like a TYPE contributes nothing only when
-- no decl of `mid` happens to have a constructor of that spelling; if one does, the
-- member matches by rule (b) and that SIBLING decl is overlaid.  Measured: `pmod` with
-- `data Wrap = T Int`, `import pmod.{T, pf}`, and a local `data Loc = T String` —
-- pinned as `test/llvm_fixtures_modules/ctor_scope_type_only_sibling_decl/`.
--
-- That contribution is harmless BECAUSE of the layering at the registration site
-- (`dataEnv`, `Module` arm): the overlay sits BELOW this module's own `prog0`, so a
-- sibling decl riding along can never clobber a locally-declared constructor.  What it
-- can still do is out-rank a ctor the unit names from a DIFFERENT module in an EARLIER
-- import clause, decided by source order.  It is the pre-existing `(..)` hazard
-- (#674's remainder), also reachable via (b), and it is order-dependent on `main` too.
--
-- This is #1284 (#1283 is the RE-EXPORT spelling; #733 item 1a is marked FIXED and
-- item 1c is wildcards only).  The must-fail fixture that pinned it is gone from the tree
-- (derive: `ls test/must_fail_fixtures | grep 1284`, empty), so its absence is not evidence
-- that the sibling case is drained: the non-sibling case is rejected on `main` and accepted
-- here, and the sibling one is what remains.
--
-- The pool lookup is IDENTITY-scoped, not bare-name.  The pool is the WHOLE
-- universe, so two modules declaring the same TYPE name (#1256's two `Cfg`s) made the
-- old bare-name first-match a LOAD-ORDER coin flip inside the very overlay that exists
-- to defeat load order.  The pool is appended in LOAD order and searched FIRST-match
-- while the tables it overlays are `omInsert` LAST-write-wins, so the two orders are
-- OPPOSITE: an unscoped lookup picks right only when the wanted module is loaded
-- FIRST, and `test/eval_typed_modules_fixtures/ctor_scope_load_order/` is the measured
-- counterexample (stubbing `declOwnedBy` to `True` regresses it to `7.0`, an answer
-- pristine `main` gets right).  `declOwnedBy` compares the decl's own identity against
-- `OriginModule <this import's module id>`; `useModId` yields exactly the loader
-- mid that `stampDeclOrigins` stamped with (see `aliasDictNamesOfPath`'s note, which
-- states the same equality for the qual tables).
--
-- PERF (issue #154) — the real bound, stated for the WORK and not just the RESULT.
-- The RESULT is bounded by import count x per-module public decl count: at most one
-- overlay decl per UseGroup member, and — since `wildOverlayDecls` — the wildcard-named
-- module's whole published row per `UseWild`.  It is still a per-module VIEW (the row is
-- the envelope's own memoized `demPubDecls`, not a copy), never a per-module rebuild of
-- the global universe.  A module importing no constructors AND no wildcard overlays
-- NOTHING and stays byte-identical.  A bare `import mod` (UseName) still contributes no
-- overlay: the bare form binds no ctors at all, so no ctor occurrence in the reader can
-- mean that module's declaration by that import.  A wildcard `import mod.*` DOES
-- contribute, as of `wildOverlayDecls` below — it cannot name its owning type, but it
-- does not need to: every decl the module publishes is in scope by construction, and
-- leaving it to the universe-fallback made import-clause ORDER decide which declaration
-- a ctor occurrence meant, in both the spurious-warning and the lost-warning direction.
--
-- The WORK is NOT import-count bounded, and saying it is has already shipped a
-- regression.  `pool` is the WHOLE accumulated universe and it is SCANNED — so the cost
-- is O(members x |pool|) per module, i.e. O(modules x universe) across a run, the same
-- shape `main` has paid since #674 for its `(..)` members.  What keeps that acceptable
-- is entirely the CONSTANT, and the constant has exactly two load-bearing parts, both
-- enforced downstream and both measured:
--   * ONE traversal per member, not three (see `findOverlayDecl`/`overlayScan`); and
--   * ZERO allocation per visited decl (see `overlayNote` — name tests before the
--     identity mint).
-- Break either and the perf gate's `modules` shape goes superlinear: measured at
-- typecheck TIME r2=3.24 (hard threshold 3.0) with net allocation 306/744/2013 MB
-- against 242/491/1010 for the single-walk form.  A cheaper bound is
-- available if it is ever needed — index `pool` by owning module id, which would make
-- the owned passes O(log n) — but it does not exist today, so do not cite one.
--
-- The pool is not a materialised accumulator (which would carry no record of which module
-- contributed what, and no key beyond list position).  It is the whole-graph envelope
-- (`DeclEnvs.deModules`, stage K) read at the READER'S OWN ORDINAL through
-- `declEnvRowVisible`, i.e. through `declEnvVisibleTo`'s two conjuncts.  `cur` is
-- `declEnvsOrdOf mid` for the module being checked — a LOADER-derived identity, not a
-- spelling re-derived from import syntax, which is what makes it survive the emit path
-- (see the call site in `checkBodyImpl`).
--
-- The pool includes one row an accumulator over strictly earlier modules would not: the
-- READER'S OWN module.  `declEnvVisibleTo` admits it, privately, because `entryOrd == cur`
-- short-circuits the publicity conjunct.  That is the ruled predicate and it is
-- deliberately not special-cased away here.  Its reach is bounded: `ownedType`/`ownedCtor`
-- are scoped by `declOwnedBy mid` where `mid` comes from a `DUse` path, and no module
-- imports itself, so an own-module decl can only ever fill the `bareType` fallback — LAST
-- in a FIRST-wins walk, so it can only add a candidate where every earlier row supplied
-- none, never displace one.
-- The result is partitioned: named (`UseGroup`) rows and wildcard (`UseWild`) rows
-- are two separate halves, and which half a consumer must see FIRST depends on that
-- consumer's own tie-break direction.  This is not a style choice; a single flat
-- source-ordered list shipped an S1.
--
-- WHY.  Before `wildOverlayDecls`, only `UseGroup` contributed, and every row was ONE
-- precisely-named decl.  A wildcard row is the module's WHOLE published set, so once
-- `UseWild` was enrolled the flat `flatMap` over the unit's decls in SOURCE ORDER made
-- import-clause order decide same-named-type collisions BETWEEN the two spellings: with
-- `import zzcol.*` written above `import aacol.{Red, Blue}`, a non-exhaustive match over
-- `aacol.Col` was reported as `Missing case: 'Green'` — a constructor of `zzcol.Col`,
-- the wrong type entirely — and the real missing case went unreported, so the program
-- then died at runtime on the case nobody warned about.  Swapping the two clauses fixed
-- it.  Measured on af6e0414 (broken) vs c7c879b7 (correct in BOTH orders).
--
-- The rule, and it is the ordinary scoping one: an explicitly named member outranks a
-- wildcard.  "You named this type" beats "you imported everything and it happened to be
-- in there", whichever clause is written first.
--
-- The two consumers tie-break in opposite directions, so they take opposite orders.
-- Enumerated, because a future edit that routes one of them through the other's wrapper
-- silently inverts the rule for that consumer with no diagnostic anywhere:
--   * `registerAllData` (the `dataEnv` overlay) folds the list LEFT and its bare-keyed
--     tables are `omInsert`, i.e. LAST-WRITE-WINS  -> named rows must come LAST
--     -> `importedCtorTypeDeclsLastWins`.
--   * `seedCheckRun` (the exhaustiveness ctor ORACLE) builds `oracleMap` =
--     `omFromPairs (reverseL …)`, i.e. FIRST-WINS   -> named rows must come FIRST
--     -> `importedCtorTypeDeclsFirstWins`.
-- Same rule, both sites; only the list order differs.  The big note at the `dataEnv`
-- call site enumerates the full set of order-observable structures — this pair is the
-- overlay's own contribution to it.
--
-- What this deliberately does **not** decide: named-vs-named.  Two `UseGroup` clauses
-- each naming a same-spelled type from a different module are still resolved by
-- import-clause order, exactly as before this partition — within each half the walk is
-- the same `flatMap` over `unitDecls` in source order, and neither consumer's tie-break
-- direction moved.  That case is a SEPARATE, PRE-EXISTING defect (it reproduces on
-- c7c879b7, before the wildcard arm existed) and fixing it needs the overlay keyed by
-- resolved declaration identity rather than by bare type name — #1319/#1185 territory,
-- not an ordering change.  Do not "while you are here" it: an ordering answer for
-- named-vs-named would freeze a guess into the oracle.
--
-- PERF: the unit's decl list is walked TWICE (once per half) instead of once, but the
-- POOL — the expensive part, see `the real bound` above — is scanned exactly as many
-- times as before: each clause yields its rows in whichever half claims it and `[]` in
-- the other, so the total member/wildcard lookups are unchanged.  The extra cost is one
-- linear pass over `unitDecls`, which is import-clause bounded, not universe bounded.
importedCtorTypeDeclsFirstWins : List Decl ->
  Int ->
  List DeclEnvModule ->
  List Decl
importedCtorTypeDeclsFirstWins unitDecls cur rows =
  overlayHalf False unitDecls cur rows ++ overlayHalf True unitDecls cur rows

importedCtorTypeDeclsLastWins : List Decl ->
  Int ->
  List DeclEnvModule ->
  List Decl
importedCtorTypeDeclsLastWins unitDecls cur rows =
  overlayHalf True unitDecls cur rows ++ overlayHalf False unitDecls cur rows

-- One half of the partition, in the unit's own source order.  `wildHalf` selects which:
-- True = `UseWild` rows only, False = `UseGroup` rows only.
overlayHalf : Bool -> List Decl -> Int -> List DeclEnvModule -> List Decl
overlayHalf wildHalf unitDecls cur rows =
  flatMap (importOverlayDecls wildHalf cur rows) unitDecls

importOverlayDecls : Bool -> Int -> List DeclEnvModule -> Decl -> List Decl
importOverlayDecls wildHalf cur rows (DAttrib _ d) =
  importOverlayDecls wildHalf cur rows d
importOverlayDecls wildHalf cur rows (DUse _ (p@(UseGroup _ ms)) _) =
  if wildHalf then [] else flatMap (memberOverlayDecl cur rows (useModId p)) ms
importOverlayDecls wildHalf cur rows (DUse _ (p@(UseWild _)) _) =
  if wildHalf then wildOverlayDecls cur rows (useModId p) else []
importOverlayDecls _ _ _ _ = []

-- The exhaustiveness oracle's import rows beyond `importedCtorTypeDeclsFirstWins`:
-- every decl a module ALIAS import's module publishes, and the declarations of the
-- constructors a wildcard or alias import reaches through that module's own
-- `export import`.  The oracle reads constructors by bare name (resolve strips `A.`
-- before inference), so without these rows a same-spelled constructor of a module
-- loaded earlier answers for them (#1185).  They follow both halves of
-- `importedCtorTypeDeclsFirstWins` because a bare occurrence means an unaliased
-- import's constructor.  Kept out of `importOverlayDecls`, whose other reader is the
-- `dataEnv` overlay.  A selective `import m.{…}` is already one of those rows, and no
-- decl other than a `DUse` imports anything, so `oracleImportDeclsOf` adds nothing for
-- either.
oracleImportDecls : GraphCtx ->
  List Decl ->
  Int ->
  List DeclEnvModule ->
  List Decl
oracleImportDecls gctx unitDecls cur rows =
  flatMap (oracleImportDeclsOf gctx cur rows) unitDecls

oracleImportDeclsOf : GraphCtx -> Int -> List DeclEnvModule -> Decl -> List Decl
oracleImportDeclsOf gctx cur rows (DAttrib _ d) =
  oracleImportDeclsOf gctx cur rows d
oracleImportDeclsOf gctx cur rows (DUse _ (p@(UseAlias _ _)) _) =
  let dep = useModId p
  wildOverlayDecls cur rows dep ++ reexportedCtorDecls gctx cur rows dep
oracleImportDeclsOf gctx cur rows (DUse _ (p@(UseWild _)) _) =
  reexportedCtorDecls gctx cur rows (useModId p)
oracleImportDeclsOf gctx _ _ _ = []

-- The decls declaring the constructors `dep` re-exports from other modules, found
-- through the graph's constructor export index, whose rows carry each constructor's
-- declaring identity across any chain of `export import`.  One decl per (declaring
-- module, type), however many of its constructors are re-exported.
reexportedCtorDecls : GraphCtx ->
  Int ->
  List DeclEnvModule ->
  String ->
  List Decl
reexportedCtorDecls gctx cur rows dep =
  match omLookup dep (ctorExportsIndex gctx ())
    None => []
    Some es =>
      flatMap
        (k => reexportedTypeDecl cur rows (fst k) (snd k))
        (dedupBy (k => "\{fst k}.\{snd k}") (flatMap (reexportedOwner dep) es))

-- (declaring module, owning type) of an export row declared outside `dep`.
reexportedOwner : String -> (String, String, Ident) -> List (String, String)
reexportedOwner dep (_, owner, Ident _ io _) =
  identOriginFold [] (m => if m == dep then [] else [(m, owner)]) io

reexportedTypeDecl : Int -> List DeclEnvModule -> String -> String -> List Decl
reexportedTypeDecl _ [] _ _ = []
reexportedTypeDecl cur (m :: rest) declarer tyName =
  if m.demId == declarer then
    filterList (declIsOwnedType declarer tyName) (declEnvRowVisible cur m)
  else
    reexportedTypeDecl cur rest declarer tyName

-- Only a `data` or `newtype` declaration declares constructors, so no other decl owns
-- a type whose constructors a re-export reaches.
declIsOwnedType : String -> String -> Decl -> Bool
declIsOwnedType mid tyName (DAttrib _ d) = declIsOwnedType mid tyName d
declIsOwnedType mid tyName (DData { dataName = tn, dataOrigin = o }) =
  tn == tyName && declOwnedBy mid tn o
declIsOwnedType mid tyName (DNewtype { newtypeName = tn, newtypeOrigin = o }) =
  tn == tyName && declOwnedBy mid tn o
declIsOwnedType _ _ _ = False

-- A wildcard import's overlay: EVERY decl the named module publishes, as the reader at
-- ordinal `cur` may see it.  A wildcard names no member, so there is nothing to look up
-- by name — the whole published row IS the answer, and one row is all a module id can
-- have (`deOrdIndex` keys rows by `demId`), hence the stop at the first match.
--
-- `declEnvRowVisible`, NEVER `m.demDecls`.  The visible projection is what confines
-- this to `publicDataDecl`s — public `DData`/`DInterface`/`DImpl`/`DTypeAlias` — and
-- `DNewtype`'s ABSENCE from that predicate is deliberate (see `publicDataDecl`): reading
-- `demDecls` here would leak a wildcard-imported module's PRIVATE and NEWTYPE
-- constructors across the module boundary, draining #1311/#1305 in the loud→silent
-- direction, i.e. a severity INCREASE.  A wildcard-imported `newtype`'s ctors are
-- consequently NOT overlaid; that is the ruled behaviour, not an oversight.
--
-- The private branch of `declEnvRowVisible` (`entryOrd == cur`, the reader's own row) is
-- UNREACHABLE from here for the reason the pool note above already gives: `mid` comes
-- from a `DUse` path, and no module imports itself.
--
-- PERF: this returns the row's OWN memoized `demPubDecls` list — no filtered copy is
-- materialised, per `declEnvRowVisible`'s zero-allocation contract.  It does move the
-- RESULT bound: see the `the real bound` note above.
wildOverlayDecls : Int -> List DeclEnvModule -> String -> List Decl
wildOverlayDecls _ [] _ = []
wildOverlayDecls cur (m :: rest) mid =
  if m.demId == mid then
    declEnvRowVisible cur m
  else
    wildOverlayDecls cur rest mid

-- One member's overlay decl.  The bare-name fallback is kept for the `(..)` spelling
-- ALONE, so no overlay that fired on the bare name is lost where the identity cannot
-- match — a RE-EXPORTED type's decl names the ORIGINAL module, not the re-exporter
-- this import path names.  The (b) spellings are new, so they get no fallback: an
-- unscoped guess there would be the load-order coin flip this unit is removing.
-- (The fallback is not a second pass over `pool` — `overlayScan` collects it in the
-- same walk as the two identity-scoped candidates; see `findOverlayDecl`.)
memberOverlayDecl : Int ->
  List DeclEnvModule ->
  String ->
  UseMember ->
  List Decl
memberOverlayDecl cur rows mid (UseMember n ctors _ _) =
  match findOverlayDecl mid n ctors cur rows
    Some d => [d]
    None => []

-- The pool decl DECLARED BY `mid` that this member names.
--
-- TWO PASSES, not one first-match, and the order between them is the point.  A
-- module may declare BOTH a type `T` and, in an earlier decl, a constructor spelled
-- `T` (`data Wrap = T Int` above `data T = A | B`).  For `import m.{T(..)}` the member
-- means the TYPE — `(..)` is what makes it a type spelling — so the type-name match
-- must be tried over the WHOLE pool before any constructor-name match is considered.
--
-- A single first-match pass that accepted `variantNamed n vs || ctors && tn == n`
-- shipped and was wrong: `import m.{T(..)}` selected `Wrap` (whose ctor is `T`), so
-- `T`'s own `A`/`B` were never overlaid and a universe collision on `A` won instead —
-- `Type mismatch: T vs Other`.  `declOwnedBy` had removed the CROSS-module first-match
-- hazard; this WITHIN-module one is what `variantNamed` newly made reachable.  Pinned
-- by `test/llvm_fixtures_modules/ctor_scope_ctors_prefer_type_name/`.
--
-- The constructor pass is still the fallback for `(..)`, not dead: `import m.{C(..)}`
-- where `C` is a constructor and not a type name of `m` keeps its constructor meaning.
--
-- The three passes share one traversal, and that is a measured perf contract.
-- `pool` is the WHOLE accumulated universe and this runs once per UseGroup member of
-- every module, so each independent pass over it is an O(modules x universe) term.
-- Three passes (type-owned, then ctor-owned, then the bare fallback) would put the
-- perf gate's `modules` shape at typecheck TIME r2=3.24 — over the hard 3.0
-- threshold.  `overlayScan` collects all
-- three candidates in a SINGLE walk (their predicates are independent, so first-wins
-- per candidate is unchanged) and stops the instant the DECIDING candidate is found,
-- which is the early exit the three-pass form had.  See `overlayScan`.
findOverlayDecl : String ->
  String ->
  Bool ->
  Int ->
  List DeclEnvModule ->
  Option Decl
findOverlayDecl mid n ctors cur rows =
  match overlayScanRows mid n ctors cur (None, None, None) rows
    (ownedType, ownedCtor, bareType) =>
      if ctors then
        orElseOpt (orElseOpt ownedType ownedCtor) bareType
      else
        ownedCtor

-- ONE walk of the pool, THREE first-wins candidates, in the precedence order
-- `findOverlayDecl` applies:
--
--   ownedType — first decl DECLARED BY `mid` whose TYPE name is `n`   (the `(..)` rule)
--   ownedCtor — first decl DECLARED BY `mid` with a CONSTRUCTOR named `n`  (rule (b))
--   bareType  — first decl of ANY owner whose TYPE name is `n`  (the `(..)` fallback,
--               `dataDeclForType`'s old job: a RE-EXPORTED type's decl names the
--               ORIGINAL module, so no identity-scoped pass can ever match it)
--
-- Each is recorded independently and FIRST-wins, which is exactly what three separate
-- first-match passes computed; a decl can legitimately fill two of them at once (a
-- record's sole variant carries the type's own name), so they are collected with
-- INDEPENDENT tests and never with an `else`.
--
-- The early exit is `ctors`-dependent and must stay that way.  With `(..)` the
-- deciding candidate is `ownedType` (it outranks both others), so finding it ends the
-- walk; WITHOUT `(..)` only `ownedCtor` is ever read, so exiting on `ownedType` would
-- abandon the walk before the answer was found.  Exiting on "all three filled" is
-- likewise wrong for the second case.
-- The OUTER half of the same one-traversal walk, over the envelope's per-module rows in
-- ORDINAL order, which is dependency-first, the order the pool's decls are laid out in, so
-- every FIRST-wins candidate below sees the sequence it is specified against.
--
-- The early exit must be checked at both levels.  `overlayScan` stops mid-row on
-- the deciding candidate; without the identical test here the walk would continue into
-- every LATER row having already decided, which is the O(modules x universe) term this
-- whole neighbourhood is written to avoid.  `declEnvRowVisible` allocates nothing, so
-- a skipped row costs one comparison.
overlayScanRows : String ->
  String ->
  Bool ->
  Int ->
  (Option Decl, Option Decl, Option Decl) ->
  List DeclEnvModule ->
  (Option Decl, Option Decl, Option Decl)
overlayScanRows _ _ _ _ acc [] = acc
overlayScanRows mid n ctors cur acc (m :: rest) =
  let acc2 = overlayScan mid n ctors acc (declEnvRowVisible cur m)
  if overlayDecided ctors acc2 then
    acc2
  else
    overlayScanRows mid n ctors cur acc2 rest

overlayScan : String ->
  String ->
  Bool ->
  (Option Decl, Option Decl, Option Decl) ->
  List Decl ->
  (Option Decl, Option Decl, Option Decl)
overlayScan _ _ _ acc [] = acc
overlayScan mid n ctors acc (d :: rest) =
  let acc2 = overlayScanOne mid n acc d
  if overlayDecided ctors acc2 then acc2 else overlayScan mid n ctors acc2 rest

overlayDecided : Bool -> (Option Decl, Option Decl, Option Decl) -> Bool
overlayDecided ctors (ownedType, ownedCtor, _) =
  if ctors then isSome ownedType else isSome ownedCtor

overlayScanOne : String ->
  String ->
  (Option Decl, Option Decl, Option Decl) ->
  Decl ->
  (Option Decl, Option Decl, Option Decl)
overlayScanOne mid n acc (DAttrib _ d) = overlayScanOne mid n acc d
overlayScanOne mid n acc (d@(DData { dataName = tn, dataOrigin = o })) =
  overlayNote mid n tn o d acc
overlayScanOne mid n acc (d@(DNewtype { newtypeName = tn, newtypeOrigin = o })) =
  overlayNote mid n tn o d acc
overlayScanOne _ _ acc _ = acc

-- Name tests first, identity second — a MEASURED perf contract, not style.
-- `tn == n` / `declCtorNamed` are string compares over fields already in hand and
-- ALLOCATE NOTHING; `declOwnedBy` MINTS an identity on both sides (`OriginModule`,
-- `IdentModule`, the `map` closure, the `Ident`, the `Some` — five objects per call).
-- This runs once per pool decl, i.e. over the whole universe per member per module, so
-- minting unconditionally is O(modules x universe) ALLOCATION — `compiler/AGENTS.md`'s
-- named exception ("when the KEY PROJECTION allocates"), and it re-created the #154
-- quadratic that `modules` was promoted out of `KNOWN_SUPERLINEAR` for.  Measured on
-- the gate's own `modules` shape (N=100/200/400, K=8, one worktree, one emitter,
-- interleaved): mint-first 306/744/2013 MB net (r2=2.71) vs name-first 242/491/1010 MB
-- (r2=2.06), which is `main`'s figure to 0.1 MB.  A name test matches at most the
-- handful of pool decls sharing that spelling, so the mint is O(1) per member.
--
-- The unchanged `acc` is returned BY IDENTITY when neither name matches — the common
-- case — so the walk allocates nothing at all until it actually finds something.
overlayNote : String ->
  String ->
  String ->
  TyConOrigin ->
  Decl ->
  (Option Decl, Option Decl, Option Decl) ->
  (Option Decl, Option Decl, Option Decl)
overlayNote mid n tn o d acc = match acc
  (ownedType, ownedCtor, bareType) =>
    let hitType = tn == n
    let hitCtor = declCtorNamed n d
    if hitType || hitCtor then
      let owned = declOwnedBy mid tn o
      (
        if hitType && owned then orElseOpt ownedType (Some d) else ownedType,
        if hitCtor && owned then orElseOpt ownedCtor (Some d) else ownedCtor,
        if hitType then orElseOpt bareType (Some d) else bareType,
      )
    else
      acc

-- Does this decl's DECLARATION identity name module `mid`?  Both sides go through
-- `mkIdent`, so an ABSENT identity matches NOTHING — not even another absence.  That
-- polarity is deliberate: this answers a LOOKUP, where a
-- miss is recoverable (the universe fallback stands, i.e. today's behaviour) and a
-- false hit would silently overlay the wrong module's constructors.  It is why `mid`
-- being `""` (the I6.3 "origin not recorded" sentinel, which `identOriginOf` refuses)
-- cannot pair with an `OriginUnresolved` decl.
declOwnedBy : String -> String -> TyConOrigin -> Bool
declOwnedBy mid tyName o = match mkIdent NsType (OriginModule mid) tyName
  Some want => mkIdent NsType o tyName == Some want
  None => False

-- ── the local-spelling → DEFINER map, for EVERY import form ─────────────────────
-- This is the ONE representation the dict-arity identity seam resolves through:
-- `qualConstraintKey` turns a name into a `(definer, origin)` key with it, and
-- `hasImportDefiner` reads the same rows to decide that a qual MISS means "genuinely
-- unconstrained in its source module" rather than "look in the source-blind bare
-- table".  Every reader of that decision — `declaredConstraintFor`,
-- `declaredConstraintIds`, the pinned-var guard — takes its answer from here, and
-- none of them knows which import FORM produced a row.  So the forms are normalized
-- here, once, and a form whose rows are missing is not a gap in one arm: it is a
-- silent fall-through to bare-name first-match for that whole spelling.
--
-- `import m.*` must contribute rows.  `importedBindings` answers `None` for `UseWild`
-- because a wildcard's member list cannot be read off the `DUse` decl alone — it is every
-- public top-level binding the DEPENDENCY declares — so a walk over `DUse` decls alone
-- skips it and every wildcard-imported name falls to the bare table.  The bare table is
-- wrong on both sides of a same-name collision (a foreign constrained row sizes the define
-- AND the call), so the two errors cancel and the spelling looks correct; but once
-- `selfDeclArities` answers the DEFINE side by identity, the call side on the bare table
-- applies a dict its callee no longer abstracts — `E-NOT-A-FUNCTION: applied non-function:
-- <dict:>` on ordinary 3-line stdlib programs, in both import orders, behind a `check` that
-- exits 0.  An arm of this seam with no rows is a defect even when the other arm's rows
-- are right.
--
-- The graph is what supplies the missing member list, and it is already built and
-- already keyed by module id: `declEnvsRef.deModules`.  On the Flat/loader-less paths
-- that envelope is EMPTY, so the wildcard rows are empty and this is byte-identically
-- today's behaviour — the same fail-closed-on-absent-identity discipline
-- `selfDeclArities` takes for `mid == ""`.
--
-- Order and shadowing.  Named-form rows come FIRST (every reader is first-match), and a
-- wildcard row is dropped when the name is already spoken for — by a named import of
-- this module, or by this module's OWN top-level declaration, which shadows the
-- wildcard binding and whose arity `selfDeclArities` answers from its own qual row.
--
-- The supply side does not enumerate.  Separate walks for the named and the wildcard form,
-- each deciding for itself what a dependency "makes available", answer with the names a
-- dependency DECLARES, so a name it RE-EXPORTS (`export import u.{pick}` /
-- `export import u.*`, at any depth) would get no row and fall to the source-blind bare
-- table — the same `E-NOT-A-FUNCTION: applied non-function: <dict:>` on a well-typed
-- program, one hop further out.  The rows are DERIVED: `graphPubDefiners` answers "what
-- does module m export, and who DEFINED each of those names" (declared publics, plus
-- re-exports resolved through the same predicate, transitively), and `importFormRows` — the
-- one admission predicate, shared with `importFormSchemes` — answers "which of those does
-- this import form admit, under which local key".  A form or a re-export shape this seam
-- has never seen is covered by construction, not by a case.
--
-- The payload is a PAIR: `(definer module, origin name at the definer)`,
-- because an IMPORTER can rename a re-exported member (`import r1.{pick as pk}` — an
-- ordinary import with an as-alias on a name that happens to be re-exported).  A
-- RE-EXPORT hop itself cannot rename: `export import u.{pick as pk}` is a hard parse
-- error (`parser.mdk:2379`), so that is not the motivating shape.  The qual tables are
-- keyed `(definer, ORIGINAL exported name)`, so carrying only the definer would key them
-- with the local spelling, MISS, and — via `hasImportDefiner` — read that miss as
-- "genuinely unconstrained", silently dropping the callee's dict.  Both halves of the
-- key come out of one derivation; they cannot disagree.
importDefinersOf : GraphCtx -> List Decl -> List (String, (String, String))
importDefinersOf gctx prog =
  let named = useAdmittedRows gctx False prog
  let taken = namesToSet (map fst named ++ declTopFnNames prog) omEmpty
  named
    ++ filterList
      (e => not (omHasKey (fst e) taken))
      (useAdmittedRows gctx True prog)

-- one precedence TIER of the walk above — [wild] selects the wildcard-form rows or the
-- named-form rows.  This is a precedence split, not a re-enumeration of the forms:
-- WHICH names a form admits is `importFormRows`' answer in both tiers.
useAdmittedRows : GraphCtx ->
  Bool ->
  List Decl ->
  List (String, (String, String))
useAdmittedRows gctx _ [] = []
useAdmittedRows gctx wild ((DAttrib _ d) :: rest) =
  useAdmittedRows gctx wild [d] ++ useAdmittedRows gctx wild rest
useAdmittedRows gctx wild ((DUse _ path _) :: rest) =
  useDefinerRows gctx wild path ++ useAdmittedRows gctx wild rest
useAdmittedRows gctx wild (_ :: rest) = useAdmittedRows gctx wild rest

-- `core` is skipped: the implicit prelude is never an explicit provenance (every reader
-- of these rows relies on that — see `declaredConstraintFor`).
useDefinerRows : GraphCtx -> Bool -> UsePath -> List (String, (String, String))
useDefinerRows gctx wild path =
  let depId = useModId path
  if depId == "core" then
    []
  else match importedBindings path
    None => if wild then graphPubDefiners gctx depId else []
    Some bindings =>
      if wild then
        []
      else
        flatMap (memberDefinerRow depId (graphPubDefiners gctx depId)) bindings

-- resolve ONE named member against the dependency's export table.  The fallback is the
-- load-bearing part: on the Flat / loader-less drivers `deModules` is EMPTY, so the
-- table is silent about every dependency, and a named import must keep contributing its
-- row (attributed to the SPELLED module, which is what it contributed before this
-- derivation existed) rather than vanish.  The wildcard form has no such fallback — it
-- cannot enumerate without the graph — which is the same fail-closed-on-absent-identity
-- discipline `selfDeclArities` takes for `mid == ""`.
memberDefinerRow : String ->
  List (String, (String, String)) ->
  (String, String) ->
  List (String, (String, String))
memberDefinerRow depId pubs (origin, local) =
  match resolveMemberRows (origin, local) pubs
    [] => [(local, (depId, origin))]
    rows => rows

-- #739 fix follow-up: local-import-name → ORIGINAL exported name.  `importedBindings`
-- yields (origin, local) pairs, so an aliased member `{x as y}` gives (y ↦ x) and a plain
-- `{f}` gives (f ↦ f).  qualConstraintFor keys the (source, name) qual tables by the ORIGIN,
-- not the surface alias — the tables are attributed under the DEFINING name — so a constrained
-- aliased import (`hash_map.{set as hmSet}`) resolves its `Hash`/`Eq` dict instead of being
-- misclassified as unconstrained and short-circuited (which DROPPED the dict → dispatch panic).
--
-- This is a PROJECTION of `importDefinersOf`'s rows rather than its own
-- `DUse` walk.  Two walks over the import forms could disagree about which rows exist —
-- and a `(definer, origin)` key assembled from two disagreeing walks is exactly the
-- silent misroute this seam pays for.  `definerRowsOf` is its sibling projection; both
-- take the SAME rows, computed once at the single write site.
originRowsOf : List (String, (String, String)) -> List (String, String)
originRowsOf rows = map (e => (fst e, snd (snd e))) rows

definerRowsOf : List (String, (String, String)) -> List (String, String)
definerRowsOf rows = map (e => (fst e, fst (snd e))) rows

-- ── per-module ISOLATED diagnostics (the analyzeProject typecheck stage) ────
-- Like checkModuleFull but ALSO harvests THIS module's type diagnostics: it shares the
-- flat paths' seeding via `seedCheckRun` (matchOracle/matchWarnings)
-- and runs coherence over the module's OWN decls, while keeping the
-- module ISOLATED — only
-- PUBLIC schemes/data of earlier modules are seeded (via seedVars/accData), so a
-- private same-named helper in another module never collides (the bug the old
-- flat prefix-concat diagnostics path had).  checkModuleFull calls `freshModuleCtx`,
-- which clears typeErrors at module start, so the post-call typeErrors snapshot is
-- exactly this module's contribution; matchWarnings starts from the seed's empty list
-- (`seedCheckRun`).  Returns (own value schemes, errs, warns) so the
-- driver can thread accV/accData exactly as foldModules does.
--
-- Precondition: this is per-module, and the Module path consults the
-- persistent universe accumulators (`universeFunNamesRef` / …), which survive the
-- per-module `freshModuleCtx`.  They are grown by `appendUniverseAccums prog0` per module but
-- must be cleared once per run by `mintGraphCtx` (and seeded by the core pass)
-- before the first module.  Every existing caller goes through a driver that does exactly
-- that (`driveGraphK`, via `graphPreamble`'s `mintGraphCtx`); a future standalone
-- caller that skips it would leak the previous run's universe into this one.
--
-- The stage-K envelope (`GraphCtx.declEnvsRef`, which carries the method namespace
-- `deMethods`) runs the other way: it is not a `CrossRun` accumulator and
-- `mintGraphCtx` does not clear it, deliberately — it is derived once from the
-- whole graph with no per-module re-seed, so clearing it mid-run is the defect that put
-- the method index on `GraphCtx` (`check` clean while `run`/`build` reported a
-- type error).  For it the precondition is "overwrite with this run's graph before the
-- first module":
--     gctx.declEnvsRef := declEnvs
-- which `graphPreamble` — the one Module-mode driver entry — does.  The failure modes
-- differ in kind: skipping `mintGraphCtx` leaks the previous run's universe;
-- skipping this write leaves the previous run's envelope in place, and a stale method
-- namespace can pick a wrong interface where an empty one finds nothing.  A standalone
-- caller must do both.
export
checkModuleFullDiags : GraphCtx ->
  String ->
  ModuleSeed ->
  List Decl ->
  List Decl ->
  List Decl ->
  (ModuleBindings, List Decl, List TcDiag, List TcDiag, ModuleCtx)
checkModuleFullDiags gctx mid seedVars accData accAll prog =
  -- Same seeding preamble as the flat entry points (one body), but the
  -- oracle decls are THIS module's own first.
  -- P0-9: THIS module's own decls (`prog`) come FIRST so its constructors win
  -- the oracle's first-wins bare-name tables.  Another loaded module (in accData)
  -- can define a same-named ctor at a different arity (`map`'s arity-5 `Bin` vs
  -- `set`'s arity-4 `Bin`); with accData first, the type-aware `check_match` reads
  -- the WRONG arity/type for this module's own `Bin` in a match and false-warns
  -- W-NONEXHAUSTIVE.  buildOracle is duplicate-tolerant, and accData still
  -- supplies prelude Option/Result ctors (this module never redefines them).
  -- The decls whose CONSTRUCTORS this module binds by name are
  -- prepended BEFORE accData so their ctors win the oracle's first-wins bare-name
  -- tables over any same-named ctor a non-imported module contributes by load order —
  -- the exhaustiveness peer of the typecheck-scheme overlay.  Own-module `prog` still
  -- wins first.  The overlay decls come from the persistent universe (same source the
  -- dataEnv overlay uses), which equals accData here but keeps the two overlays in
  -- lockstep.
  --
  -- Two tempting claims are false under rule (b) of the import-scoped overlay:
  --   * NOT "the types this module imports with `(..)`" — EVERY selective
  --     constructor-naming member contributes now (`import m.{T, C}`, and a record's
  --     `import m.{Cfg}`), not only the `(..)` spelling.
  --   * NOT "a module with no `T(..)` import is byte-identical" — only a module that
  --     names no constructor at all AND carries no wildcard import is.  A wildcard
  --     (`import m.*`) contributes m's whole published row without naming any
  --     constructor, since `wildOverlayDecls`; before that arm existed it fell to the
  --     universe fallback and import-clause ORDER decided the oracle's answer.
  -- The PERF claim is corrected at `importedCtorTypeDeclsFirstWins` itself (the result is bounded
  -- by import count x per-module public decl count; the WORK is O(members x |universe|),
  -- held down by one zero-allocation traversal per member).  Do not restate it as "no
  -- O(N²)" here: this
  -- call site is the SECOND per-module scan of the same pool, so it doubles whatever
  -- that constant is.
  -- The SECOND consumer of the whole-graph envelope pool, in lockstep with the `dataEnv`
  -- overlay: the two must stay on the same pool ("keeps the two overlays in lockstep",
  -- above), and `mid` is this function's own parameter, so the same loader-derived key
  -- reaches both.
  let declEnvsHere = gctx.declEnvsRef.value
  -- `…FirstWins`: `oracleMap` is `omFromPairs (reverseL …)`, so the FIRST row wins and
  -- the `UseGroup` rows must come FIRST for an explicitly named member to outrank a
  -- wildcard.  The `dataEnv` overlay takes `…LastWins` — opposite order, same rule,
  -- because that consumer is last-write-wins.  See `importedCtorTypeDeclsFirstWins`.
  let runSeed =
    seedCheckRun
      (prog
        ++ importedCtorTypeDeclsFirstWins
          prog
          (declEnvsOrdOf mid declEnvsHere)
          declEnvsHere.deModules
        ++ oracleImportDecls
          gctx
          prog
          (declEnvsOrdOf mid declEnvsHere)
          declEnvsHere.deModules
        ++ accData)
  -- Bug C: pass the cumulative full impl universe (core + earlier modules) as
  -- implDecls so buildStandaloneShadows sees
  -- an imported standalone funDef that shadows an interface method (`map`'s `isEmpty`
  -- vs Foldable's): without it the importer-shadow set is EMPTY on the CHECK path and
  -- `isEmpty m` routes to method dispatch rather than to the standalone the importer
  -- named.
  -- It feeds the shadow/dispatch-index/key tables and the impl-body inference
  -- universe alike, matching the eval path's elabModuleStamp (which passes
  -- accAll ++ prog too).
  -- #749: thread the REAL module id (not "") so this module's constrained fns are
  -- attributed into crossModuleFunConstraintsQualRef under their OWN source module —
  -- SOURCE-EXACT, exactly as the emit path (elabModuleStamp mid) does.  With mid=""
  -- every module attributed under "", so qualConstraintFor (which keys by the import's
  -- real source module via currentImportDefinersRef) always MISSED for a user-module
  -- constrained callee → declaredCrossModuleObls dropped its obligation → `check`
  -- false-greened on `p.f Z` (Display Z missing) while run/build rejected (the #673
  -- residual #738 fixed only for the prelude/core coreSchemeObligationsRef flow).  The
  -- source-exact keying makes it MISS for a genuinely-unconstrained same-name import
  -- (#739's `q.f`, attributed nowhere), so no over-rejection is reintroduced.
  let (schemes, marked, mctx) =
    checkModuleFullImpl gctx runSeed mid seedVars accData accAll prog
  -- The whole-graph `CE`, read at THIS module's ordinal — the same `declEnvsOrdOf mid` key
  -- `seedCheckRun`'s overlay pool (`types/tc_state.mdk`) and `moduleImplUniv`
  -- (`checkBodyImpl`) read at.  ONE env for both members; they differ only in which
  -- population they take from it (`ceRowsOwnedBy` vs `ceRowsVisibleAt`).
  let ceHere = declEnvsHere.deIfaces
  let ordHere = declEnvsOrdOf mid declEnvsHere
  -- The whole-graph `IE`, read at the SAME `ordHere` — the same key `ceHere` and
  -- `moduleImplUniv` (`checkBodyImpl`) read at.
  -- Coherence reads the SAME whole-graph `IE` at the SAME `ordHere`, and takes this
  -- module's OWN rows from it (`cohRowsOwnedBy`) — the population `prog` named, derived in
  -- `checkCoherence`'s header.  This env came from `buildDeclEnvs`, which seats the prelude
  -- at ordinal 0, so the module's rows are also paired with the prelude's.
  runFinalChecks
    mctx
    prog
    ceHere
    ceHere
    declEnvsHere.deImpls
    declEnvsHere.deImpls
    ordHere
  (
    schemes,
    marked,
    reverseL mctx.mcCells.typeErrors.items.value,
    reverseL mctx.mcCells.matchWarnings.value,
    mctx,
  )

-- [lo, hi) less the ranges a scoped drain judged, as sub-ranges in order.
unjudgedRanges : Int -> Int -> List (Int, Int) -> List (Int, Int)
unjudgedRanges lo hi skips =
  cutRanges lo hi (sortOn fst (filterList ((a, b) => b > lo && a < hi) skips))

cutRanges : Int -> Int -> List (Int, Int) -> List (Int, Int)
cutRanges lo hi [] = if lo < hi then [(lo, hi)] else []
cutRanges lo hi ((a, b) :: rest) =
  (if a > lo then [(lo, a)] else []) ++ cutRanges (max lo b) hi rest

-- ── the other half of `selfDeclArities`, and it is NOT optional ──────────────
-- `selfDeclArities` is a per-module VIEW; the ref it is written to is ALSO the ref the
-- cross-module accumulator is snapshotted FROM at the end of the same body
-- (`crossModuleFunConstraintsRef` ← `ModuleCtx.funConstraintsRef`).  Without this restore the
-- view becomes a graph-wide LOSS: the rows masked while checking module `mid` never reach
-- the modules processed after it.
--
-- Masking `count` while checking `vector` (which declares an unconstrained `count`) deleted the
-- PRELUDE's constrained `count` row from the accumulator, so every later module lost it and
-- an ordinary `count (x => x > 1) [1, 2, 3]` in the entry panicked at `run`.  Prelude names
-- are the ones that expose it, because `importDefinersOf` skips `core` — a prelude name is
-- never an "explicit import", so it can only ever be answered by this bare table.
--
-- Restores by NAME from the accumulator's own previous value (still unwritten at the
-- snapshot, which is this ref's only writer), appended AFTER the module's rows so
-- first-match still prefers the identity-resolved answer.  Content-preserving: the view
-- removed exactly these rows, so appending them back is not duplication.
selfNameRows : List Decl -> List (String, a) -> List (String, a)
selfNameRows prog old =
  let own = namesToSet (declTopFnNames prog) omEmpty
  filterList (e => omHasKey (fst e) own) old

-- attribute each fn DEFINED in [prog] that carries a per-fn table entry to [mid] —
-- the source-exact `(mid, name)` key every cross-module fn table is read under.
--
-- Used for all three of the fn-side qual snapshots: the constraint ARITIES
-- (`funConstraintsRef`), the slot-parallel IFACES (`funConstraintIfacesRef`) and the
-- per-entry DECLARED-PREFIX scalar.  The payload is polymorphic (`a`) because the sidecar's
-- SCALAR payload does not fit a `List X` signature.
attributeModuleEntries : String ->
  List Decl ->
  List (String, a) ->
  List ((String, String), a)
attributeModuleEntries mid prog entries =
  let progNames = namesToSet (declTopFnNames prog) omEmpty
  map
    (e => ((mid, fst e), snd e))
    (filterList (e => omHasKey (fst e) progNames) entries)

-- #1114 (#845): attribute each TOP-LEVEL binding of [prog] that carries a
-- `schemeObligationsRef` entry to [mid], source-exactly keyed `(mid, name)` — the same
-- key discipline as `attributeModuleEntries` above, and for the same #739 reason (a
-- bare-name cross-module table misattributes a same-named export of another module).
--
-- Unlike the arity tables, `schemeObligationsRef` is keyed `(name, binding-id)` and
-- holds LOCAL/`where` binders too (registerSchemeObligations is called from the local
-- sites with `omEmpty` member ids, so those key under id 0).  Two filters make the
-- projection to a bare exported name safe:
--   (1) [progNames] keeps only names this module defines at TOP LEVEL, so a `where`
--       helper whose name matches nothing at top level never enters the table at all;
--   (2) FIRST-occurrence-wins within a name, which resolves the one residual case — a
--       `where` helper that happens to SHARE a top-level name.  `schemeObligationsRef`
--       is consed, and a group's top-level members are registered AFTER the locals
--       inferred inside their bodies, so the head-most entry for a name is the
--       top-level one.  That is byte-identically the policy the SAME-module use site
--       already applies (`lookupSchemeOblsByName`'s first match), which is the point:
--       an importer must see what a same-module caller sees.
--
-- A module's contribution is what it declares *plus what it re-exports*, and the second
-- half is not optional — it is the recurrence `.claude/workstreams/TYPECHECK.md` records for
-- #1283 and `renameAliasedMethods` (`types/typecheck.mdk`) already learned for the METHOD
-- tables: "the decl's origin names the DECLARING module and the import path names the
-- RE-EXPORTER, so the identity test misses."  Attributing only `declTopFnNames prog` means
-- a pure re-exporter (`export import lib.def.{f}`, whose `prog` has no function definitions at
-- all) contributes NOTHING, so `import lib.reexp.{f}` found no entry and #845's whole
-- failure came back one hop out — `check` 0, `build` 0, and the built binary SEGFAULTED.
-- Adversarial review produced exactly that program; this arm is the answer to it.
--
-- [qual] is the ALREADY-ACCUMULATED cross-module table, and dependency-first module order
-- is what makes reading it correct here: every module this one re-exports FROM has been
-- processed already, so its entries are present. That also makes a multi-hop chain resolve
-- without special-casing — each hop re-attributes under its own mid as it is processed,
-- exactly as `reexportedMethodNames` folds the method sets.
--
-- Re-export entries come SECOND so the module's own top-level binding wins the first-match
-- dedup below if a module somehow both defines and re-exports one name.
attributeModuleSchemeObls : String ->
  List Decl ->
  List ((String, String), List VecObl) ->
  List ((String, Int), List VecObl) ->
  List ((String, String), List VecObl)
attributeModuleSchemeObls mid prog qual entries =
  attributeSchemeOblsGo
      mid
      (namesToSet (publicValNames prog) omEmpty)
      omEmpty
      entries
    ++ map (e => ((mid, fst e), snd e)) (reexportSchemeOblEntries prog qual)

-- the scheme contexts a module RE-EXPORTS (`export import src.{…}` / `export import src.*`),
-- each under the name it re-exports it as.  Reuses `schemeOblEntriesFor` — the same
-- spelling table the IMPORT side uses — so re-export and import can never disagree about
-- what a spelling binds; that is one table, not two kept in step by hand.
-- `export import src as A` contributes entries keyed `A.<name>`, which no importer of
-- THIS module can name (an alias is local to the file that writes it).  They are inert
-- rather than wrong, and excluding them would mean a second spelling table.
reexportSchemeOblEntries : List Decl ->
  List ((String, String), List VecObl) ->
  List (String, List VecObl)
reexportSchemeOblEntries [] _ = []
reexportSchemeOblEntries ((DAttrib _ d) :: rest) qual =
  reexportSchemeOblEntries [d] qual ++ reexportSchemeOblEntries rest qual
reexportSchemeOblEntries ((DUse True path _) :: rest) qual =
  schemeOblEntriesFor (useModId path) path qual
    ++ reexportSchemeOblEntries rest qual
reexportSchemeOblEntries (_ :: rest) qual = reexportSchemeOblEntries rest qual

attributeSchemeOblsGo : String ->
  OrdMap Unit ->
  OrdMap Unit ->
  List ((String, Int), List VecObl) ->
  List ((String, String), List VecObl)
attributeSchemeOblsGo _ _ _ [] = []
attributeSchemeOblsGo mid progNames seen (e :: rest)
  | not (omHasKey (fst (fst e)) progNames) =
    attributeSchemeOblsGo mid progNames seen rest
  | omHasKey (fst (fst e)) seen = attributeSchemeOblsGo mid progNames seen rest
  | otherwise =
    ((mid, fst (fst e)), snd e)
      :: attributeSchemeOblsGo
        mid
        progNames
        (omInsert (fst (fst e)) () seen)
        rest

-- WS-2/D2 method analog: attribute each method whose INTERFACE is declared in [prog]
-- (carrying a methodPredicateSlotsRef entry) to [mid].  Keyed by the interface's module —
-- the arity is a property of the method signature, registered during that module's
-- method-row construction pass.  The per-run table also holds the rows imported
-- modules contributed; only keys of [prog]'s own interfaces are attributed here.
attributeMethodModulePredicateSlots : String ->
  List Decl ->
  List (String, List MethodPredicateSlot) ->
  List ((String, String), List MethodPredicateSlot)
attributeMethodModulePredicateSlots mid prog entries =
  let progMethods = namesToSet (ifaceMethodSlotKeys prog) omEmpty
  map
    (e => ((mid, fst e), snd e))
    (filterList (e => omHasKey (fst e) progMethods) entries)

-- The `methodSlotKey` of every method of every interface [prog] declares.
ifaceMethodSlotKeys : List Decl -> List String
ifaceMethodSlotKeys [] = []
ifaceMethodSlotKeys ((DAttrib _ d) :: rest) =
  ifaceMethodSlotKeys [d] ++ ifaceMethodSlotKeys rest
ifaceMethodSlotKeys ((DInterface { name, methods, ifaceOrigin, ... }) :: rest) =
  map
      (methodSlotKey IfaceRef { irName = name, irOrigin = ifaceOrigin })
      (ifaceMethodNames methods)
    ++ ifaceMethodSlotKeys rest
ifaceMethodSlotKeys (_ :: rest) = ifaceMethodSlotKeys rest

-- typecheck one module (seeded like checkModuleFull) AND immediately stamp the
-- EMethodAt route refs it just recorded.  `recordModuleStart` marks the goal channel
-- before inference, so on return the module's window holds exactly THIS module's
-- sites; the tyvar cells are still bound (the next module's `freshModuleCtx` hasn't run
-- yet), so resolveSites reads each site's resolved result type.
-- E4: ALSO stamp this module's ARG-position sites
-- (the `GKArgStamp` goals in the same window) from their now-
-- resolved discriminating-argument monos — the multi-module analogue of
-- the shared `resolveArgStamps`. [implDecls] is core + every earlier module +
-- this module, so a cross-module parametric `requires` element dict resolves; a
-- still-unresolvable case stays RNone (arg-tag fallback).  activeDictVars (the
-- constraint-var → dict-param map registerConstraintRegs built in checkModuleFull)
-- is also still bound, so a tyvar receiver routes RDict.
export
elabModuleStamp : ModuleCtx ->
  String ->
  List (String, Scheme) ->
  List Decl ->
  List Decl ->
  List Decl ->
  (ModuleBindings, List Decl, ModuleCtx)
-- multi-line RHS: the indented `:=` form is legal but not seed-parseable yet (#1744)
-- lint-disable-next-line rule-prefer-assign-op
elabModuleStamp prev mid seedVars accData implDecls prog =
  -- Stampers execute after graph inference via `drainStampQueue`, not here.
  -- See `StampCtx` and `moduleStampOrder` for the replay mechanism.
  checkModuleFullImpl
    prev.mcGraph
    (checkRunResidue prev)
    mid
    (plainModuleSeed seedVars)
    accData
    implDecls
    prog

-- THE stamper order, run once per module by `drainStampQueue`.
-- `SSRLocalSites` must stay after `SSReturnSites` and `SSArgStamps`: it overwrites the route
-- they stamp on the same ref with the receiver-grounded RLocal/RNone a standalone-shadow site needs.
moduleStampOrder : List StampStep
moduleStampOrder = [
  SSNumlitFloats,
  SSReturnSites,
  SSBinopSites,
  SSUnopSites,
  SSArithSites,
  SSArgStamps,
  SSRLocalSites,
  SSRecDictApps,
  SSDictApps,
  SSMethodDicts,
]

-- Whether a finding at [loc] is live: it is located, at one of [live]'s spans.
export
isLiveSpan : OrdMap Unit -> Option Loc -> Bool
isLiveSpan _ None = False
isLiveSpan live loc = omHasKey (locKey loc) live

-- [stamp] is the record the drain entered for [ctx].
runStampSteps : ModuleCtx -> StampCtx -> List StampStep -> Unit
runStampSteps stamp ctx steps = each (runStampStep stamp ctx) steps

-- the numeric-literal channel's window, the counterpart of `goalsSince`
numlitSince : GraphCtx -> Int -> List (Mono, Ref (Option Float), Int, Ref Route)
numlitSince gctx mark =
  moduleWindow gctx.graphRun.numlitN.value mark gctx.graphRun.numlitRefs.value

-- The stamp context of the module [mid] whose record is [mctx]: the module's run
-- fields, and its tables dropped (`moduleCtxFrom`).
stampCtxOf : ModuleCtx ->
  String ->
  List Decl ->
  List Obligation ->
  List (Mono, Ref (Option Float), Int, Ref Route) ->
  StampCtx
stampCtxOf mctx mid implDecls goals numlits =
  let dropped = blankModuleCtx mctx.mcGraph mid
  dropped.mcCells.superDeclsRef := filterList isInterfaceDecl implDecls
  StampCtx {
    scModule = mid,
    scModuleCtx = moduleCtxFrom False mctx dropped dropped dropped,
    scRpNames = returnPosMethodNames implDecls,
    scGoals = goals,
    scNumlits = numlits,
    scLiveLocs = liveLocsOf mctx goals,
  }

-- The spans of [goals] and of the module's admitted-set occurrences whose types
-- mention a variable of a live root (`GraphRun.liveRoots`): their evidence and
-- verdicts rest on what quiescence leaves that variable.
liveLocsOf : ModuleCtx -> List Obligation -> List String
liveLocsOf mctx goals =
  let ids = flatMap monoUnboundIds mctx.mcGraph.graphRun.liveRoots.value
  if isEmptyL ids then
    []
  else
    let live = fold (acc i => IdMap.set i () acc) Tip ids
    let mentions =
      ms => anyList (m => anyList (i => IdMap.has i live) (monoUnboundIds m)) ms
    spanKeys
      (map (o => o.oLoc) (filterList (o => mentions (goalMonos o)) goals)
        ++ filterMap
          ((_, m, loc) => if mentions [m] then Some loc else None)
          mctx.mcCells.admittedOccObls.value)

-- The span keys (`locKey`) of the located [locs].  An unlocated goal or occurrence
-- names no span, so no unlocated finding is joined to it (`isLiveSpan`).
export
spanKeys : List (Option Loc) -> List String
spanKeys [] = []
spanKeys (None :: rest) = spanKeys rest
spanKeys (loc :: rest) = locKey loc :: spanKeys rest

isInterfaceDecl : Decl -> Bool
isInterfaceDecl (DAttrib _ d) = isInterfaceDecl d
isInterfaceDecl (DInterface {  }) = True
isInterfaceDecl _ = False

-- This module's windows, cut now — see `goalsOfKindIn`.  [mctx] is the record the
-- module was checked in.
enqueueStampCtx : ModuleCtx -> String -> List Decl -> Unit
enqueueStampCtx mctx mid implDecls =
  let mk = currentModuleMarks mctx.mcGraph ()
  let ctx =
    stampCtxOf
      mctx
      mid
      implDecls
      (goalsSince mctx.mcGraph mk.mGoals)
      (numlitSince mctx.mcGraph mk.mNumlit)
  mctx.mcGraph.graphRun.stampCtxs :=
    ctx :: mctx.mcGraph.graphRun.stampCtxs.value

stampNoting : ModuleCtx -> (SiteCtx -> Obligation -> Unit) -> Obligation -> Unit
stampNoting stamp resolve o =
  let acc = Ref innerNone
  resolve { siteFor stamp | sxInner = Some acc } o
  o.oInner := innerOr o.oInner.value acc.value

runStampStep : ModuleCtx -> StampCtx -> StampStep -> Unit
runStampStep mctx ctx SSNumlitFloats = setNumlitFloatsGo ctx.scNumlits
runStampStep stamp ctx SSReturnSites =
  let rpNames = omFromNames ctx.scRpNames omEmpty
  stampEach
    stamp
    (sx o => resolveSites sx rpNames (siteEntry o))
    GKReturnSite
    ctx
runStampStep stamp ctx SSBinopSites =
  stampEach stamp (sx o => resolveOpSites sx True (siteEntry o)) GKBinopSite ctx
runStampStep stamp ctx SSUnopSites =
  stampEach stamp (sx o => resolveOpSites sx False (siteEntry o)) GKUnopSite ctx
runStampStep stamp ctx SSArithSites =
  stampEach stamp (_ o => resolveArithSites (arithEntry o)) GKArithSite ctx
runStampStep stamp ctx SSArgStamps =
  stampEach stamp (sx o => resolveArgStamps sx (siteEntry o)) GKArgStamp ctx
runStampStep stamp ctx SSRLocalSites =
  stampEach stamp (sx o => resolveRLocalSites sx (siteEntry o)) GKRLocalSite ctx
runStampStep stamp ctx SSRecDictApps =
  stampEach
    stamp
    (sx o => realizeRecDictApps sx (recDictAppEntry o))
    GKRecDictApp
    ctx
runStampStep stamp ctx SSDictApps =
  stampEach stamp (sx o => resolveDictApps sx (dictAppEntry o)) GKDictApp ctx
runStampStep stamp ctx SSMethodDicts =
  stampEach
    stamp
    (sx o => resolveMethodDicts sx (methodDictEntry o))
    GKMethodDict
    ctx

-- Stamps [ctx]'s goals of kind [k] one at a time, in channel order, and ORs what
-- each stamp noted below its destination's top level into that goal's `oInner`.
stampEach : ModuleCtx ->
  (SiteCtx -> Obligation -> Unit) ->
  GoalKind ->
  StampCtx ->
  Unit
stampEach stamp resolve k ctx =
  each (stampNoting stamp resolve) (goalsOfKindIn k ctx.scGoals)

export
verdictFinding : String -> Bool -> TcDiag -> DrainFinding
verdictFinding mid live d = DrainFinding {
  dfModule = mid,
  dfDiag = d,
  dfVerdict = True,
  dfLive = live,
}

-- What [act] records in the type-error channel of [mctx], the current record, taken
-- back out of it and out of the sticky one: a drain runs after every module's
-- diagnostics list closed, so its caller attaches them (`attachDrainFindings`).  The
-- dedup state [act] reads and writes stays, so a verdict the module already reported is
-- not repeated.
export
captureTypeErrors : ModuleCtx -> (Unit -> Unit) -> List TcDiag
captureTypeErrors mctx act =
  let w = mctx.mcCells.typeErrors
  let items = w.items.value
  let mark = wMark w
  let sticky = mctx.mcGraph.typeErrorsSticky.value
  let stickyDiags = mctx.mcGraph.typeErrorsStickyDiags.value
  act ()
  let added = wWindow w mark
  w.items := items
  w.n := mark
  mctx.mcGraph.typeErrorsSticky := sticky
  mctx.mcGraph.typeErrorsStickyDiags := stickyDiags
  reverseL added

-- Runs every queued stamping context, then judges the evidence they finished.
-- Returns the verdicts the drain decides (held live-root goals, admitted-set
-- occurrences) and one `T-UNROUTED-DISPATCH` per hole, each under its module.
-- [saved] is the record the drain begins with; each stamp context's walk runs in the
-- record the drain enters for it (`enterStampCtx`).
export
drainStampQueue : ModuleCtx -> List DrainFinding
drainStampQueue saved =
  let ctxs = reverseL saved.mcGraph.graphRun.stampCtxs.value
  defaultLiveNumRoots saved
  let held = judgeLiveGoals saved ctxs
  let verdicts = runStampCtxs saved ctxs
  let liveLocs = omFromNames (flatMap (c => c.scLiveLocs) ctxs) omEmpty
  let holes =
    map
      ((mid, d) => DrainFinding {
        dfModule = mid,
        dfDiag = d,
        dfVerdict = False,
        dfLive = isLiveSpan liveLocs (tcLoc d),
      })
      (judgeEvidence saved.mcGraph ctxs)
  materializeBinderTypes saved.mcGraph ()
  saved.mcGraph.graphRun.stampCtxs := []
  held ++ verdicts ++ holes

-- #2705: the drain at the core pass's freeze (`checkCoreMemoized`), at a recording
-- module's end and at a keyed drive's graph end (`diagsServe`).  Nothing is
-- published: a check driver has no reader of the evidence table.
--
-- The sticky type-error cells are saved before the drain and restored after it, so
-- a recorded interface never carries a drain's diagnostics.  An unkeyed drive
-- (`driveGraphK`) keeps them instead; the two agree because the drain raises none on
-- an accepted program.  The drain's evidence holes are returned, not recorded: a
-- per-module diagnostics list is closed before any drain, so the caller attaches
-- them to it (`attachDrainFindings`).
export
checkGraphFinish : ModuleCtx -> List DrainFinding
checkGraphFinish mctx =
  let savedSticky = mctx.mcGraph.typeErrorsSticky.value
  let savedStickyDiags = mctx.mcGraph.typeErrorsStickyDiags.value
  let holes = drainStampQueue mctx
  mctx.mcGraph.typeErrorsSticky := savedSticky
  mctx.mcGraph.typeErrorsStickyDiags := savedStickyDiags
  holes

-- The completeness judgment (`types/evidence_complete.mdk`) over the evidence this
-- drain finished: every method cell minted since the last drain, and the goals of
-- [ctxs] whose destination is not a method cell.  A return-site, arg-stamp or
-- RLocal goal writes its cell's dispatch route and a method-dict goal its method
-- dictionaries, so those are judged once, as the cell.
judgeEvidence : GraphCtx -> List StampCtx -> List (String, TcDiag)
judgeEvidence gctx ctxs =
  let g = gctx.graphRun
  let lo = g.evJudged.value
  g.evJudged := g.evCounter.value
  let base = g.evBase
  let cellHoles =
    flatMap
      ((a, b) => judgeCells g.evCells.value (a - base) (b - base) [])
      (unjudgedRanges lo g.evCounter.value g.evScopedJudged.value)
  let goalHoles = flatMap (c => flatMap (judgeGoal c.scModule) c.scGoals) ctxs
  dedupBy holeKey (cellHoles ++ goalHoles)

holeKey : (String, TcDiag) -> String
holeKey (m, TcDiag _ _ loc msg _ _) =
  "\{lenKey m}\{lenKey (locGoalKey loc)}\{msg}"

-- The cells in slots [i, hi) (ordinals less `evBase`), last first onto [acc].  A
-- cell no inference reached (no arity) carries no answer to judge.
judgeCells : Array (Option EvCell) ->
  Int ->
  Int ->
  List (String, TcDiag) ->
  List (String, TcDiag)
judgeCells arr i hi acc
  | i >= hi || i >= arrayLength arr = acc
  | otherwise = match arrayGetUnsafe i arr
    Some c => match c.ecArity.value
      Some _ =>
        let row =
          OccurrenceRow
            c.ecName.value
            c.ecIface.value
            c.ecTag.value
            c.ecImpl.value
            c.ecMeth.value
        judgeCells
          arr
          (i + 1)
          hi
          (holeDiags (evIdModule c.ecId) c.ecLoc.value c.ecInner.value row
            ++ acc)
      None => judgeCells arr (i + 1) hi acc
    None => judgeCells arr (i + 1) hi acc

judgeGoal : String -> Obligation -> List (String, TcDiag)
judgeGoal mid o = match (o.oPayload, evValueOf o.oDest)
  (GPDictApp app, EvMany rs) =>
    holeDiags
      mid
      o.oLoc
      o.oInner.value
      (DictAppRow app.pdaCallee (map (r => r.irName) app.pdaIfaces) rs)
  (GPRecDictApp (RecDictApp _ callee _ _ _ _), EvMany rs) =>
    holeDiags mid o.oLoc o.oInner.value (DictAppRow callee [] rs)
  (GPArith _, EvOne r) => holeDiags mid o.oLoc o.oInner.value (SiteRow r)
  (GPSite _ _ _, EvOne r) =>
    if goalKindTag o.oKind == goalKindTag GKBinopSite
      || goalKindTag o.oKind == goalKindTag GKUnopSite then
      holeDiags mid o.oLoc o.oInner.value (SiteRow r)
    else
      []
  _ => []

holeDiags : String ->
  Option Loc ->
  Inner ->
  EvidenceRow ->
  List (String, TcDiag)
holeDiags mid loc inner row = match rowHoleWith inner row
  None => []
  Some (_, msg) => [(mid, TcDiag TUnroutedDispatch 1 loc msg None None)]

-- Read every queued binder's type cell into the graph's runtime-type table, now
-- that the stampers have run and nothing left in the graph can refine a drained
-- module's types.  Runs at every drain, including the one before a memo snapshot,
-- so a snapshot carries only materialized rows.
materializeBinderTypes : GraphCtx -> Unit -> Unit
materializeBinderTypes gctx _ =
  let g = gctx.graphRun
  match g.binderPending.value
    [] => ()
    pending =>
      let cells = cellTypeHeads gctx.declEnvsRef.value.deAllDecls
      let isCell = n o => omHasKey (cellHeadKey n o) cells
      g.binderRows :=
        fold
          (acc p => addBinderRow (materializeBinder isCell p) acc)
          g.binderRows.value
          (reverseL pending)
      g.binderPending := []

materializeBinder : (String -> TyConOrigin -> Bool) ->
  PendingBinder ->
  BinderRow
materializeBinder isCell (PendingBinder bid name t arity signed) = BinderRow {
  brId = bid,
  brName = name,
  brType = runtimeTypeOf isCell t,
  -- A solved type with fewer arrows than the declared parameters fixes nothing.
  brReturns =
    map
      (n =>
        optionOr RTValue (map (runtimeTypeOf isCell) (resultAfterArrows n t)))
      arity,
  brSigned = signed,
}

-- The type heads whose values are constructor cells: every `data` and `newtype`
-- declaration in the graph except an `extern data` one, keyed by identity.
cellTypeHeads : List Decl -> OrdMap Unit
cellTypeHeads decls = fold (acc d => addCellHead d acc) omEmpty decls

addCellHead : Decl -> OrdMap Unit -> OrdMap Unit
addCellHead (DData { dataName = n, dataOrigin = o, dataExtern = ext, ... }) acc =
  if ext then acc else omInsert (cellHeadKey n o) () acc
addCellHead (DNewtype { newtypeName = n, newtypeOrigin = o, ... }) acc =
  omInsert (cellHeadKey n o) () acc
addCellHead (DAttrib _ d) acc = addCellHead d acc
addCellHead _ acc = acc

cellHeadKey : String -> TyConOrigin -> String
cellHeadKey n OriginBuiltin = "builtin|\{n}"
cellHeadKey n OriginUnresolved = "unresolved|\{n}"
cellHeadKey n (OriginModule m) = "module \{m}|\{n}"

-- Stamps each context in turn and decides its admitted-set occurrences
-- (`checkAdmittedOccObls`), with the selector their routes commit through, against
-- the same final solution.
runStampCtxs : ModuleCtx -> List StampCtx -> List DrainFinding
runStampCtxs saved ctxs =
  reverseL (fold (acc ctx => reverseL (runStampCtx saved ctx) ++ acc) [] ctxs)

runStampCtx : ModuleCtx -> StampCtx -> List DrainFinding
runStampCtx saved ctx =
  let stamp = enterStampCtx saved ctx
  refileDeterminedRows stamp ()
  runStampSteps stamp ctx moduleStampOrder
  recordEvidence saved.mcGraph ctx.scGoals
  let liveSpans = omFromNames ctx.scLiveLocs omEmpty
  map
    (d => verdictFinding ctx.scModule (isLiveSpan liveSpans (tcLoc d)) d)
    (captureTypeErrors stamp (_ => checkAdmittedOccObls stamp ()))

-- #2549 M2: publish this module's solved evidence, AFTER its stampers have run and
-- read back out of the cells they wrote.  Deriving the table any other way would make
-- it a second answer that can disagree with the cells; derived this way it cannot.
recordEvidence : GraphCtx -> List Obligation -> Unit
recordEvidence gctx gs =
  let g = gctx.graphRun
  each (noteEvidenceObservation gctx) gs
  g.evTable := evEntriesOf gs ++ g.evTable.value

evEntriesOf : List Obligation -> EvTable
evEntriesOf gs = map (o => EvEntry o.oEv (evValueOf o.oDest)) gs

evValueOf : EvDest -> EvVal
evValueOf (EvRoute r) = EvOne !r
evValueOf (EvRoutes rs) = EvMany !rs

-- Install the module's marking state at module start.  Reads the graph's mark sets
-- off the driver preamble; a Module arm reached without one is a driver bug, and
-- fails loud rather than marking nothing.
beginModuleMarking : ModuleCtx ->
  String ->
  List Decl ->
  OrdMap Int ->
  ModuleSeed ->
  Unit
beginModuleMarking mctx mid prog top seed =
  let ms = match mctx.mcGraph.markSetsRef.value
    Some s => s
    None =>
      panic
        "checkBodyImpl: Module arm entered with no mark sets (no driver preamble ran)"
  -- Core imports nothing, so the dict names nameable in it are its own `=>`
  -- signatures, the set its `dictPass` gives parameters to.  A user definition that
  -- shares a bare name with a core one is a different definition.
  let known = match mid
    "" => constrainedSigNames prog
    _ => dedup (ms.msBareDictNames ++ mctx.mcGraph.promotionHarvestRef.value)
  let aliases = aliasDictNames mctx.mcGraph known ms.msUnits [(mid, prog)]
  mctx.mcGraph.graphRun.localAbs.lasNext := (mid, 0)
  mctx.mcGraph.graphRun.localAbs.lasMinted := []
  mctx.mcCells.markingRef := Some ModuleMarking {
    mmCtx = moduleMarkCtx mctx.mcGraph ms mid prog seed.msImportedValues,
    mmTop = top,
    mmDictSet = Ref (omFromNames (known ++ aliases) omEmpty),
    mmUserNames = omFromNames (declTopFnNames prog) seed.msImportedNames,
    mmExterns = omFromNames (declExternNames prog) seed.msImportedExterns,
  }

-- The stamped twin of the group's marked clauses — what inference reads.  Binding
-- ids are minted over the module's declaration heads (`stampTopScope`), so stamping
-- one group at a time yields the ids `stampBindingIds` would have.
stampGroupClauses : ModuleMarking ->
  List String ->
  OrdMap (List (List Pat, Expr)) ->
  OrdMap (List (List Pat, Expr))
stampGroupClauses mm members grouped =
  mapGroupClauses (stampClauseWith mm.mmTop) members grouped

-- The module's marked tree: its binding groups' marked clauses written back into the
-- declarations in source order, then the remaining bodies (impl, default, prop,
-- test) marked with the module's final dict-name set — they are inferred
-- after every group, so every promotion the module made is in the set by then.
finishModuleMarking : ModuleMarking ->
  TcEnv ->
  OrdMap (List (List Pat, Expr)) ->
  List Decl ->
  List Decl
finishModuleMarking mm env grouped prog =
  markTailDecls
    env.teDyn.dcModule
    mm.mmCtx
    mm.mmDictSet.value
    (grantNameIn env)
    (rebuildGroupDecls grouped prog)

-- The stamped twin of the tail declarations, for their inference; binding groups
-- were stamped as the schedule reached them and are not walked again.
stampTailDecls : OrdMap Int -> List Decl -> List Decl
stampTailDecls top decls = map (stampTailDecl top) decls

stampTailDecl : OrdMap Int -> Decl -> Decl
stampTailDecl _ (d@(DFunDef _ _ _ _ _ _)) = d
stampTailDecl _ (d@(DLetGroup _ _)) = d
stampTailDecl top (DAttrib attrs d) = DAttrib attrs (stampTailDecl top d)
stampTailDecl top d = stampDeclWith top d

-- test-only observation: declarations whose only callers are tests and probes.

-- Runs in a carry of [prev], the caller's record, in its graph record with a fresh
-- graph run.
methodReturnProbeStamp : ModuleCtx ->
  MethodSchemeRow ->
  MethodSchemeRow ->
  List Decl ->
  (String, String, String)
methodReturnProbeStamp prev ownedRow foreignRow impls =
  let gctx = GraphCtx { prev.mcGraph | graphRun = freshGraphRun () }
  let mctx = carryModuleCtx gctx prev
  let scope = methodReturnProbeScope mctx "return-owner-stamper"
  let request = methodReturnProbeRequest mctx ownedRow
  methodReturnProbeSpelling mctx foreignRow
  let env = buildFlatImplEnv impls
  mctx.mcCells.bodyImplEnvRef := env
  let tagRef = Ref RNone
  let implRef = Ref []
  let resultMono = stripArrows request.mrrOccurrence
  resolveExactReturnSite
    (siteFor mctx)
    omEmpty
    "make"
    tagRef
    implRef
    resultMono
    request
    ""
    None
    scope
  let goals = optionOr [] (methodReturnArgs gctx request)
  let ownedKey =
    match ieSelectRowByIface (siteFor mctx) env ownedRow.msrIface goals
      Some selected => rowRouteKey selected
      None => ""
  let foreignKey =
    match ieSelectRowByIface (siteFor mctx) env foreignRow.msrIface goals
      Some selected => rowRouteKey selected
      None => ""
  (methodReturnProbeRouteKey tagRef.value, ownedKey, foreignKey)

-- The request is created before the spelling table is pointed at Foreign.  The checker
-- must still reject a graph containing only Foreign's impl, its positive control must
-- accept Owner's impl, and the stamper must select Owner's distinct route.
methodReturnOwnershipProbe : Unit -> (List String, List String, Bool, Bool)
methodReturnOwnershipProbe _ =
  let ownedGraph = probeGraphCtx ()
  let ownedDecl =
    methodReturnProbeIface
      "return-owner"
      "Owner"
      (TyFun (tyConBuiltin "Unit" None) (TyVar "a"))
  let foreignDecl =
    methodReturnProbeIface
      "return-foreign"
      "Foreign"
      (TyFun (tyConBuiltin "Unit" None) (TyVar "a"))
  let ownedCtx = initialModuleCtx ownedGraph
  let ownedRow = firstMethodRow (ifaceMethodSchemeRows ownedCtx [ownedDecl])
  let foreignGraph = GraphCtx { ownedGraph | graphRun = freshGraphRun () }
  let foreignCtx = carryModuleCtx foreignGraph ownedCtx
  let foreignRow =
    firstMethodRow (ifaceMethodSchemeRows foreignCtx [foreignDecl])
  let ownedImpl = methodReturnProbeImpl "return-owner" "Owner"
  let foreignImpl = methodReturnProbeImpl "return-foreign" "Foreign"
  let (rejected, rejectedCtx) =
    methodReturnProbeCodes foreignCtx ownedRow [foreignImpl]
  let (accepted, acceptedCtx) =
    methodReturnProbeCodes rejectedCtx ownedRow [foreignImpl, ownedImpl]
  let (actualKey, ownedKey, foreignKey) = methodReturnProbeStamp
    acceptedCtx
    ownedRow
    foreignRow
    [foreignImpl, ownedImpl]
  let observed = (
    rejected,
    accepted,
    actualKey == ownedKey,
    actualKey /= foreignKey,
  )
  observed

-- > methodReturnOwnershipProbe ()
-- (["T-NO-IMPL"], [], True, True)
# DESUGAR
(DUse false (UseGroup ("support" "diag_codes") ((mem "DiagCode" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "BinderId" true) (mem "ConPayload" true) (mem "Decl" true) (mem "EvEntry" true) (mem "EvVal" true) (mem "Expr" true) (mem "ExternDecl" true) (mem "FunClause" true) (mem "Ident" true) (mem "LetBind" true) (mem "Loc" true) (mem "Ns" true) (mem "Pat" true) (mem "PropParam" true) (mem "Route" true) (mem "Super" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "UseMember" true) (mem "UsePath" true) (mem "Variant" true) (mem "EvTable" false) (mem "identOriginFold" false) (mem "mkIdent" false) (mem "tyConBuiltin" false))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderRow" true) (mem "RuntimeType" true) (mem "addBinderRow" false) (mem "runtimeTypeOf" false))))
(DUse false (UseGroup ("types" "scopes") ((mem "ScopeOwner" true))))
(DUse false (UseGroup ("types" "tc_types") ((mem "BuiltinClasses" true) (mem "CeRow" true) (mem "CheckRunSeed" true) (mem "ClassEnv" true) (mem "ConstraintReg" true) (mem "DeclaringBinder" true) (mem "DeclEnvModule" true) (mem "DrainFinding" true) (mem "EnvBinding" true) (mem "EvCell" true) (mem "EvDest" true) (mem "EvidenceObservationEntry" true) (mem "EvidenceOutcomeKind" true) (mem "GoalKind" true) (mem "GoalPayload" true) (mem "GraphCtx" true) (mem "GraphMarks" true) (mem "GroupCtx" true) (mem "ImplEnv" true) (mem "LiveGoal" true) (mem "MethodPredicateSlot" true) (mem "MethodSchemeRow" true) (mem "ModuleBindings" true) (mem "ModuleCtx" true) (mem "ModuleMarking" true) (mem "ModuleSeed" true) (mem "NumBoundary" true) (mem "NumBoundaryDisposition" true) (mem "NumGuard" true) (mem "Obligation" true) (mem "ObligationSite" true) (mem "PendingBinder" true) (mem "PendingEntry" true) (mem "RecDictApp" true) (mem "RecordInfo" true) (mem "ScopedMember" true) (mem "ScopedScheme" true) (mem "SiteCtx" true) (mem "SiteKind" true) (mem "StampCtx" true) (mem "StampStep" true) (mem "StandaloneOrigin" true) (mem "TcEnv" true) (mem "dynFor" false) (mem "siteFor" false))))
(DUse false (UseGroup ("types" "evidence_complete") ((mem "EvidenceRow" true) (mem "Inner" true) (mem "innerNone" false) (mem "innerOr" false) (mem "rowHoleWith" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Mono" true) (mem "Scheme" true) (mem "VecObl" true) (mem "normalize" false) (mem "ppMono" false))))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omDelete" false) (mem "omEmpty" false) (mem "omFromNames" false) (mem "omFromPairs" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omKeys" false) (mem "omLookup" false) (mem "omMapValues" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("types" "evidence") ((mem "ScopeId" true))))
(DUse false (UseGroup ("types" "registry") ((mem "regEmpty" false) (mem "regKeyOfTab" false) (mem "regKeyRender" false) (mem "SpellingPop" false) (mem "spEmpty" false) (mem "spFloor" false) (mem "spLookupIdent" false))))
(DUse false (UseGroup ("types" "effect_solver") ((mem "SummaryFailure" false))))
(DUse false (UseGroup ("types" "publish") ((mem "TcDiag" true) (mem "tcLoc" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "addCtor" false) (mem "attachStandaloneSources" false) (mem "bindingWithStandalone" false) (mem "buildFlatImplEnv" false) (mem "ceLookupAt" false) (mem "ceRowDoneKey" false) (mem "ceRowIface" false) (mem "ceRowIfaceName" false) (mem "ceRowLoc" false) (mem "ceRowOrd" false) (mem "ceRowSupers" false) (mem "ceRowsVisibleAt" false) (mem "ctorExportsIndex" false) (mem "declEnvRowVisible" false) (mem "declEnvsOrdOf" false) (mem "declTopFnNames" false) (mem "emptyMethodModulePredicateSlots" false) (mem "extendBindings" false) (mem "extendLocalVar" false) (mem "extendMethodRows" false) (mem "extendTermBindings" false) (mem "extendVars" false) (mem "funDefs" false) (mem "graphPubDefiners" false) (mem "ieUniverseAt" false) (mem "ifaceMethodNames" false) (mem "ifaceTabKey" false) (mem "importedBindings" false) (mem "importLocFor" false) (mem "importTableMid" false) (mem "legacyMethodSchemes" false) (mem "methodRowsByIdentity" false) (mem "methodSlotKey" false) (mem "namesToSet" false) (mem "ordinaryEnvBinding" false) (mem "publicDataDecl" false) (mem "publicDataDecls" false) (mem "withCtors" false))))
(DUse false (UseGroup ("types" "tc_decls") ((mem "addFieldOwners" false) (mem "builtinClassesGo" false) (mem "builtinClassesOf" false) (mem "declEnvSeedDataUniverse" false) (mem "ifaceMethodSchemeRows" false) (mem "isAliasDecl" false) (mem "loadDataUniverse" false) (mem "recordDeclKinds" false) (mem "registerAllData" false) (mem "registerAllDataScoped" false) (mem "registerData" false) (mem "rejectCyclicAliases" false) (mem "seedNumLitFromIntAnchor" false) (mem "sigToScheme" false))))
(DUse false (UseGroup ("types" "tc_scope") ((mem "aliasConstraintEntries" false) (mem "aliasDictNames" false) (mem "aliasMethodSpellings" false) (mem "aliasQualifiedMethodEntries" false) (mem "annotateImportedMethodRows" false) (mem "applyCtorScopeOverrides" false) (mem "applyRecordScopeOverrides" false) (mem "declCtorNamed" false) (mem "importedMemberBindingNames" false) (mem "insertCtorPop" false) (mem "insertRecordPop" false) (mem "methodNameDeclaredAt" false) (mem "pickSchemesByDecl" false) (mem "reportAmbiguousImportsIn" false) (mem "resolveMemberRows" false) (mem "schemeOblEntriesFor" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "containsI" false) (mem "dedupI" false) (mem "findTvarInMonos" false) (mem "monoArgUnboundIds" false) (mem "monoScheme" false) (mem "monoUnboundIds" false) (mem "resultAfterArrows" false) (mem "schemeMono" false) (mem "stripArrows" false) (mem "tconBuiltin" false) (mem "tconUnresolved" false) (mem "tyVarNames" false) (mem "unquantifiedAuthIds" false))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "dedup" false) (mem "dedupBy" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "isSome" false) (mem "joinWith" false) (mem "lenKey" false) (mem "listLen" false) (mem "orElseOpt" false) (mem "reverseL" false))))
(DUse false (UseGroup ("types" "tc_occurrence") ((mem "argDispatchIndicesById" false) (mem "constrainedSigNames" false) (mem "evIdModule" false) (mem "firstMethodRow" false) (mem "mapGroupClauses" false) (mem "markGroupClauses" false) (mem "markRecursiveOccurrences" false) (mem "markTailDecls" false) (mem "methodReturnProbeCodes" false) (mem "methodReturnProbeRequest" false) (mem "rebuildGroupDecls" false))))
(DUse false (UseGroup ("types" "tc_solve") ((mem "arithEntry" false) (mem "currentModuleMarks" false) (mem "determineByUniqueInstance" false) (mem "dictAppEntry" false) (mem "dropGoalsSince" false) (mem "goalKindName" false) (mem "goalKindTag" false) (mem "goalMonos" false) (mem "goalsMark" false) (mem "goalsOfKindIn" false) (mem "goalsSince" false) (mem "improveByUniqueImpl" false) (mem "methodDictEntry" false) (mem "methodReturnArgs" false) (mem "methodReturnProbeIface" false) (mem "methodReturnProbeImpl" false) (mem "methodReturnProbeRouteKey" false) (mem "methodReturnProbeScope" false) (mem "methodReturnProbeSpelling" false) (mem "openScope" false) (mem "outerRigidIds" false) (mem "recDictAppEntry" false) (mem "refileDeterminedRows" false) (mem "returnPosMethodNames" false) (mem "routesOfMonosTopV" false) (mem "siteEntry" false) (mem "uOblArgs" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "authvarId" false) (mem "authVars" false))))
(DUse false (UseGroup ("types" "tc_effects") ((mem "beginEffectSummaryScope" false) (mem "borrowedEffectCells" false) (mem "checkEffectEscape" false) (mem "checkUndeterminedRetEffVars" false) (mem "clausesOf" false) (mem "finishEffectSummaryScopeKeeping" false) (mem "flushPendingEscapes" false) (mem "freshEffectSummary" false) (mem "grantNameIn" false) (mem "memberEffectRoots" false) (mem "recordFileBound" false) (mem "recordMethodGrants" false) (mem "recordTopGrants" false) (mem "reportEffectSummaryFailures" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "blankModuleCtx" false) (mem "callUOblsWindow" false) (mem "carryModuleCtx" false) (mem "checkRunResidue" false) (mem "currentScopeStore" false) (mem "dynAtIfSome" false) (mem "enterStampCtx" false) (mem "envAtIfSome" false) (mem "freshGraphRun" false) (mem "freshModuleCtx" false) (mem "initialModuleCtx" false) (mem "mctxAt" false) (mem "moduleCtxFrom" false) (mem "moduleWindow" false) (mem "plainModuleSeed" false) (mem "probeGraphCtx" false) (mem "seedCheckRun" false) (mem "wMark" false) (mem "wWindow" false))))
(DUse false (UseGroup ("types" "tc_solve_check") ((mem "callOblsWindow" false) (mem "checkCallObligationsU" false) (mem "checkSigVarGoals" false) (mem "dedupPredicateSlotsTable" false) (mem "defaultLiveNumRoots" false) (mem "finalizeNumBoundary" false) (mem "liveNumVarGo" false) (mem "numConstrainedIds" false) (mem "predicateSlotTableWithoutArgs" false) (mem "registerConstraintRegs" false) (mem "registerInferredConstraints" false) (mem "rejectUndeterminedVectors" false) (mem "rejectWithheldAmbiguity" false) (mem "setFunPredicateSlots" false) (mem "tiedSurvivors" false) (mem "undeterminedVectorVerdict" false))))
(DUse false (UseGroup ("types" "tc_global") ((mem "calleeNumObls" false) (mem "checkCoherence" false) (mem "checkGradedImplHeads" false) (mem "checkImplCompletenessMap" false) (mem "checkPhantomMethods" false) (mem "checkSuperImpls" false) (mem "inferDefaultBodies" false) (mem "inferUserImplBodies" false) (mem "numCallObls" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "captureScope" false) (mem "closeScope" false) (mem "enterLevel" false) (mem "exitLevel" false) (mem "freshTvMap" false) (mem "freshVar" false) (mem "generalize" false) (mem "resolvePendingJoins" false) (mem "rowInto" false) (mem "unifyIn" false) (mem "unifyInto" false) (mem "widenOpenedFor" false))))
(DUse false (UseGroup ("types" "tc_shadow") ((mem "checkAdmittedOccObls" false) (mem "definerShadowsFromSet" false) (mem "isPreludeMid" false) (mem "moduleMarkCtx" false) (mem "nameableIfaceMethodSet" false) (mem "nameableIfaceRows" false) (mem "nameableIfaceShadows" false) (mem "resolveRLocalSite" false) (mem "standaloneShadowsFromSet" false))))
(DUse false (UseGroup ("types" "tc_decls_types") ((mem "checkDeclaredKinds" false) (mem "checkDeclAuthorityUses" false) (mem "checkEffectParams" false) (mem "fromAstType" false))))
(DUse false (UseGroup ("types" "tc_infer") ((mem "checkDeferredMatches" false) (mem "checkFixedWidthLiterals" false) (mem "checkWideLiterals" false) (mem "declareRigidVars" false) (mem "infer" false) (mem "inferMemberClauses" false) (mem "preunifySigsEx" false) (mem "valueSpanLoc" false))))
(DUse false (UseGroup ("types" "tc_groups") ((mem "checkLetRecDecls" false) (mem "checkRecursiveValue" false) (mem "checkSigConstraintCoverage" false) (mem "checkSigsFixedByExpansive" false) (mem "checkSigsOverExpansive" false) (mem "checkSigsTooGeneral" false) (mem "declRefNames" false) (mem "depGraphMap" false) (mem "groupClauses" false) (mem "groupNames" false) (mem "isLetrecGroup" false) (mem "memberForce" false) (mem "nestedRequireGoals" false) (mem "quantifiableAuthorities" false) (mem "registerSchemeObligations" false) (mem "sccProtectedSignatureIds" false) (mem "sccSchemes" false))))
(DUse false (UseGroup ("types" "tc_diag_text") ((mem "cyclicSuperIfaceMsg" false) (mem "locGoalKey" false) (mem "locKey" false) (mem "ordinalSentinelMsg" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "effrowNorm" false) (mem "pureRow" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "exprSpanLoc" false) (mem "joinLocs" false))))
(DUse false (UseGroup ("types" "tc_foreign") ((mem "declExternNames" false) (mem "directExternSigs" false) (mem "externDecls" false) (mem "ffiCheckExternsCatalogRow" false) (mem "ffiCheckExternsCrossable" false) (mem "ffiCheckExternsLabelled" false) (mem "ffiCheckExternsShadow" false) (mem "ffiStampMode" false))))
(DUse false (UseGroup ("frontend" "resolve") ((mem "externTyOriginScope" false) (mem "firstExprLoc" false) (mem "stampClauseWith" false) (mem "stampDeclWith" false) (mem "stampTopScope" false) (mem "stampTyOrigins" false))))
(DUse false (UseGroup ("list") ((mem "findMap" false) (mem "sortOn" false))))
(DUse false (UseGroup ("types" "tc_solve_entail") ((mem "ieSelectRowByIface" false) (mem "rowRouteKey" false))))
(DUse false (UseGroup ("types" "effect_bindings") ((mem "newBindingSummary" false))))
(DUse false (UseGroup ("types" "tc_diag") ((mem "pushTypeError" false) (mem "pushTypeErrorAt" false))))
(DUse false (UseGroup ("types" "tc_elab") ((mem "realizeRecDictApps" false) (mem "resolveAdmittedSite" false) (mem "resolveArgStamps" false) (mem "resolveArithSite" false) (mem "resolveDictApps" false) (mem "resolveExactReturnSite" false) (mem "resolveMethodDicts" false) (mem "resolveNumLitSite" false) (mem "resolveOpSite" false) (mem "resolvePredicateOpSite" false) (mem "resolveSite" false) (mem "selfDeclArities" false))))
(DUse false (UseGroup ("types" "tc_pat") ((mem "recordBinderType" false) (mem "settleDeferredPatLits" false))))
(DUse false (UseGroup ("types" "tc_infer_records") ((mem "recordFieldNames" false))))
(DUse false (UseGroup ("types" "invocation_basis") ((mem "recordInvocationView" false))))
(DUse false (UseGroup ("types" "tc_decls_variance") ((mem "seedParamPolarityFixpointScoped" false))))
(DUse false (UseGroup ("support" "scc") ((mem "tarjanSCCs" false))))
(DUse false (UseGroup ("frontend" "visibility") ((mem "useModId" false))))
(DUse false (UseAlias ("map") "IdMap"))
(DUse false (UseAlias ("types" "effect_solver") "EffectSolver"))
(DUse false (UseAlias ("types" "scopes") "Scopes"))
(DTypeSig false "obligationRoutes" (TyFun (TyCon "Obligation") (TyApp (TyCon "List") (TyCon "Route"))))
(DFunDef false "obligationRoutes" ((PVar "o")) (EMatch (EFieldAccess (EVar "o") "oDest") (arm (PCon "EvRoute" (PVar "r")) () (EListLit (EFieldAccess (EVar "r") "value"))) (arm (PCon "EvRoutes" (PVar "rs")) () (EFieldAccess (EVar "rs") "value"))))
(DTypeSig false "obligationPredicateMonos" (TyFun (TyCon "Obligation") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Mono")))))
(DFunDef false "obligationPredicateMonos" ((PVar "o")) (EMatch (EFieldAccess (EVar "o") "oPayload") (arm (PCon "GPSite" PWild (PVar "m") PWild) () (EListLit (EApp (EVar "Some") (EVar "m")))) (arm (PCon "GPArith" (PVar "m")) () (EListLit (EApp (EVar "Some") (EVar "m")))) (arm (PCon "GPDictApp" (PVar "app")) () (EApp (EApp (EVar "map") (EVar "Some")) (EFieldAccess (EVar "app") "pdaMonos"))) (arm (PCon "GPMethodDict" (PVar "pmd")) () (EApp (EApp (EVar "map") (ELam (PWild) (EVar "None"))) (EFieldAccess (EVar "pmd") "pmdSlots"))) (arm (PCon "GPRecDictApp" (PCon "RecDictApp" PWild PWild PWild (PVar "m") PWild PWild)) () (EListLit (EApp (EVar "Some") (EVar "m"))))))
(DTypeSig false "routeOutcomeKind" (TyFun (TyCon "Route") (TyCon "EvidenceOutcomeKind")))
(DFunDef false "routeOutcomeKind" ((PCon "RNone")) (EVar "EOKNone"))
(DFunDef false "routeOutcomeKind" ((PCon "RKey" PWild PWild PWild)) (EVar "EOKInstance"))
(DFunDef false "routeOutcomeKind" ((PCon "RDict" PWild)) (EVar "EOKGiven"))
(DFunDef false "routeOutcomeKind" ((PCon "RDictFwd" PWild)) (EVar "EOKGiven"))
(DFunDef false "routeOutcomeKind" ((PCon "RLocal" PWild PWild)) (EVar "EOKLocal"))
(DFunDef false "routeOutcomeKind" ((PCon "RScalar" PWild)) (EVar "EOKScalar"))
(DFunDef false "routeOutcomeKind" ((PCon "RProj" (PVar "r") PWild)) (EApp (EVar "routeOutcomeKind") (EVar "r")))
(DTypeSig false "routeGivenBinder" (TyFun (TyCon "Route") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "routeGivenBinder" ((PCon "RDict" (PVar "n"))) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "routeGivenBinder" ((PCon "RDictFwd" (PVar "n"))) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "routeGivenBinder" ((PCon "RProj" (PVar "r") PWild)) (EApp (EVar "routeGivenBinder") (EVar "r")))
(DFunDef false "routeGivenBinder" (PWild) (EVar "None"))
(DTypeSig false "routeInstanceKey" (TyFun (TyCon "Route") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "routeInstanceKey" ((PCon "RKey" (PVar "k") PWild PWild)) (EApp (EVar "Some") (EVar "k")))
(DFunDef false "routeInstanceKey" (PWild) (EVar "None"))
(DTypeSig false "routePrerequisiteRoutes" (TyFun (TyCon "Route") (TyApp (TyCon "List") (TyCon "Route"))))
(DFunDef false "routePrerequisiteRoutes" ((PCon "RKey" PWild (PVar "rs") PWild)) (EVar "rs"))
(DFunDef false "routePrerequisiteRoutes" ((PCon "RLocal" PWild (PVar "rs"))) (EVar "rs"))
(DFunDef false "routePrerequisiteRoutes" (PWild) (EListLit))
(DTypeSig false "renderRouteIdentity" (TyFun (TyCon "Route") (TyCon "String")))
(DFunDef false "renderRouteIdentity" ((PCon "RNone")) (ELit (LString "RNone")))
(DFunDef false "renderRouteIdentity" ((PCon "RKey" (PVar "k") PWild PWild)) (EBinOp "++" (ELit (LString "RKey ")) (EVar "k")))
(DFunDef false "renderRouteIdentity" ((PCon "RDict" (PVar "n"))) (EBinOp "++" (ELit (LString "RDict ")) (EVar "n")))
(DFunDef false "renderRouteIdentity" ((PCon "RDictFwd" (PVar "n"))) (EBinOp "++" (ELit (LString "RDictFwd ")) (EVar "n")))
(DFunDef false "renderRouteIdentity" ((PCon "RLocal" (PVar "n") PWild)) (EBinOp "++" (ELit (LString "RLocal ")) (EVar "n")))
(DFunDef false "renderRouteIdentity" ((PCon "RScalar" (PVar "n"))) (EBinOp "++" (ELit (LString "RScalar ")) (EVar "n")))
(DFunDef false "renderRouteIdentity" ((PCon "RProj" (PVar "r") (PVar "path"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "RProj (")) (EApp (EVar "display") (EApp (EVar "renderRouteIdentity") (EVar "r")))) (ELit (LString ") "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EApp (EApp (EVar "map") (EVar "intToString")) (EVar "path"))))) (ELit (LString ""))))
(DTypeSig false "noteEvidenceObservation" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Obligation") (TyCon "Unit"))))
(DFunDef false "noteEvidenceObservation" ((PVar "gctx") (PVar "o")) (EMatch (EFieldAccess (EVar "gctx") "trace") (arm (PCon "Some" (PVar "sink")) () (EIf (EFieldAccess (EVar "sink") "tsEvidenceObservationEnabled") (EBlock (DoLet false false (PVar "routes") (EApp (EVar "obligationRoutes") (EVar "o"))) (DoLet false false (PVar "predicates") (EApp (EVar "obligationPredicateMonos") (EVar "o"))) (DoLet false false (PVar "arity") (EApp (EVar "listLen") (EVar "routes"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "sink") "tsEvidenceObservationEntries")) (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EVar "evidenceObservationEntriesGo") (EVar "o")) (EVar "routes")) (EVar "predicates")) (EVar "arity")) (ELit (LInt 0))) (EFieldAccess (EFieldAccess (EVar "sink") "tsEvidenceObservationEntries") "value"))))) (ELit LUnit))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig false "evidenceObservationEntriesGo" (TyFun (TyCon "Obligation") (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Mono"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "EvidenceObservationEntry"))))))))
(DFunDef false "evidenceObservationEntriesGo" (PWild (PList) PWild PWild PWild) (EListLit))
(DFunDef false "evidenceObservationEntriesGo" ((PVar "o") (PCons (PVar "r") (PVar "rs")) (PVar "preds") (PVar "arity") (PVar "slot")) (EBlock (DoLet false false (PTuple (PVar "predHere") (PVar "predsRest")) (EMatch (EVar "preds") (arm (PCons (PVar "p") (PVar "ptail")) () (ETuple (EVar "p") (EVar "ptail"))) (arm (PList) () (ETuple (EVar "None") (EListLit))))) (DoExpr (EBinOp "::" (ERecordCreate "EvidenceObservationEntry" ((fa "eoeEv" (EFieldAccess (EVar "o") "oEv")) (fa "eoeGoalKind" (EApp (EVar "goalKindName") (EFieldAccess (EVar "o") "oKind"))) (fa "eoeSlot" (EVar "slot")) (fa "eoeArity" (EVar "arity")) (fa "eoePredicate" (EApp (EApp (EVar "map") (EVar "ppMono")) (EVar "predHere"))) (fa "eoeOutcome" (EApp (EVar "routeOutcomeKind") (EVar "r"))) (fa "eoeGivenBinder" (EApp (EVar "routeGivenBinder") (EVar "r"))) (fa "eoeInstanceKey" (EApp (EVar "routeInstanceKey") (EVar "r"))) (fa "eoePrerequisites" (EApp (EApp (EVar "map") (EVar "renderRouteIdentity")) (EApp (EVar "routePrerequisiteRoutes") (EVar "r")))) (fa "eoeScope" (EFieldAccess (EVar "o") "oScope")))) (EApp (EApp (EApp (EApp (EApp (EVar "evidenceObservationEntriesGo") (EVar "o")) (EVar "rs")) (EVar "predsRest")) (EVar "arity")) (EBinOp "+" (EVar "slot") (ELit (LInt 1))))))))
(DTypeSig false "graphMarksNow" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyCon "GraphMarks"))))
(DFunDef false "graphMarksNow" ((PVar "gctx") PWild) (ERecordCreate "GraphMarks" ((fa "mGoals" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "goalsN") "value")) (fa "mNumlit" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "numlitN") "value")))))
(DTypeSig false "recordModuleStart" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyCon "Unit"))))
(DFunDef false "recordModuleStart" ((PVar "gctx") (PVar "mid")) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "moduleRanges")) (EBinOp "::" (ETuple (EVar "mid") (EApp (EApp (EVar "graphMarksNow") (EVar "gctx")) (ELit LUnit))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "moduleRanges") "value"))))
(DTypeSig false "mapLocalSchemes" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Scheme"))))))
(DFunDef false "mapLocalSchemes" ((PVar "mctx") (PList)) (EListLit))
(DFunDef false "mapLocalSchemes" ((PVar "mctx") (PCons (PTuple (PVar "n") (PVar "l") (PVar "m")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EVar "l") (EApp (EApp (EVar "generalize") (EVar "mctx")) (EVar "m"))) (EApp (EApp (EVar "mapLocalSchemes") (EVar "mctx")) (EVar "rest"))))
(DTypeSig false "seedBuiltinClasses" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))))
(DFunDef false "seedBuiltinClasses" ((PVar "gctx") (PVar "mid") (PVar "prog")) (EIf (EApp (EVar "isPreludeMid") (EVar "mid")) (EBlock (DoLet false false (PVar "seeded") (EApp (EVar "builtinClassesOf") (EVar "prog"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "builtinClassesRef")) (EVariantUpdate "BuiltinClasses" (EVar "seeded") ((fa "bcPreludeSeeded" (EApp (EVar "isNonEmptyL") (EVar "prog")))))))) (EIf (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "builtinClassesRef") "value") "bcPreludeSeeded") (ELit LUnit) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "builtinClassesRef")) (EApp (EApp (EVar "builtinClassesGo") (EVar "prog")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "builtinClassesRef") "value"))))))
(DTypeSig false "recordTopBinderTypes" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Scheme")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))))
(DFunDef false "recordTopBinderTypes" ((PVar "gctx") (PVar "schemes") (PVar "decls")) (EBlock (DoLet false false (PVar "signed") (EApp (EApp (EVar "signedTopNames") (EVar "decls")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "each") (EApp (EApp (EApp (EVar "recordTopDeclBinderTypes") (EVar "gctx")) (EVar "schemes")) (EVar "signed"))) (EVar "decls")))))
(DTypeSig false "signedTopNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "signedTopNames" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "signedTopNames" ((PCons (PCon "DTypeSig" PWild (PVar "n") PWild PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "signedTopNames") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "acc"))))
(DFunDef false "signedTopNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "signedTopNames") (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "acc")))
(DFunDef false "signedTopNames" ((PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "signedTopNames") (EVar "rest")) (EVar "acc")))
(DTypeSig false "recordTopDeclBinderTypes" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Scheme")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Decl") (TyCon "Unit"))))))
(DFunDef false "recordTopDeclBinderTypes" ((PVar "gctx") (PVar "schemes") (PVar "signed") (PCon "DFunDef" PWild (PVar "n") (PVar "ps") PWild PWild (PVar "bid"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordTopFunBinderType") (EVar "gctx")) (EVar "schemes")) (EVar "signed")) (EVar "n")) (EVar "bid")) (EApp (EVar "listLen") (EVar "ps"))))
(DFunDef false "recordTopDeclBinderTypes" ((PVar "gctx") (PVar "schemes") (PVar "signed") (PCon "DLetGroup" PWild (PVar "binds"))) (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "b")) (EMatch (EVar "b") (arm (PCon "LetBind" (PVar "n") (PVar "clauses") PWild (PVar "bid")) () (EMatch (EVar "clauses") (arm (PCons (PCon "FunClause" (PVar "ps") PWild) PWild) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordTopFunBinderType") (EVar "gctx")) (EVar "schemes")) (EVar "signed")) (EVar "n")) (EVar "bid")) (EApp (EVar "listLen") (EVar "ps")))) (arm (PList) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordTopFunBinderType") (EVar "gctx")) (EVar "schemes")) (EVar "signed")) (EVar "n")) (EVar "bid")) (ELit (LInt 0))))))))) (ELit LUnit)) (EVar "binds")))
(DFunDef false "recordTopDeclBinderTypes" ((PVar "gctx") (PVar "schemes") (PVar "signed") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EVar "recordTopDeclBinderTypes") (EVar "gctx")) (EVar "schemes")) (EVar "signed")) (EVar "d")))
(DFunDef false "recordTopDeclBinderTypes" ((PVar "gctx") PWild PWild PWild) (ELit LUnit))
(DTypeSig false "recordTopFunBinderType" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Scheme")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyCon "BinderId") (TyFun (TyCon "Int") (TyCon "Unit"))))))))
(DFunDef false "recordTopFunBinderType" ((PVar "gctx") (PVar "schemes") (PVar "signed") (PVar "n") (PVar "bid") (PVar "arity")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "schemes")) (arm (PCon "Some" (PVar "sch")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordBinderType") (EVar "gctx")) (EVar "bid")) (EVar "n")) (EApp (EVar "schemeMono") (EVar "sch"))) (EApp (EVar "Some") (EVar "arity"))) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "signed")))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig false "resolveSites" (TyFun (TyCon "SiteCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "PendingEntry")) (TyCon "Unit")))))
(DFunDef false "resolveSites" ((PVar "sx") PWild (PList)) (ELit LUnit))
(DFunDef false "resolveSites" ((PVar "sx") (PVar "rpNames") (PCons (PCon "PendingEntry" (PVar "name") (PVar "tagRef") (PVar "resultMono") (PVar "encl") (PVar "kind") (PVar "loc") (PVar "scope") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "sx") (ERecordUpdate (EVar "sx") ((fa "sxSite" (EVar "loc"))))) (DoExpr (EMatch (EVar "kind") (arm (PCon "SKReturn" (PVar "implRef") (PVar "fullMono")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveSite") (EVar "sx")) (EVar "rpNames")) (EVar "name")) (EVar "tagRef")) (EVar "implRef")) (EVar "resultMono")) (EVar "fullMono")) (EVar "encl")) (EVar "loc")) (EVar "scope"))) (arm (PCon "SKAdmittedReturn" (PVar "ifaceRef") (PVar "implRef") (PVar "fullMono")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveAdmittedSite") (EVar "sx")) (EVar "name")) (EVar "ifaceRef")) (EVar "tagRef")) (EVar "implRef")) (EVar "fullMono")) (EVar "encl")) (EVar "scope"))) (arm (PCon "SKExactReturn" (PVar "implRef") (PVar "request")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveExactReturnSite") (EVar "sx")) (EVar "rpNames")) (EVar "name")) (EVar "tagRef")) (EVar "implRef")) (EVar "resultMono")) (EVar "request")) (EVar "encl")) (EVar "loc")) (EVar "scope"))) (arm (PCon "SKNumReturn" (PVar "predicate") (PVar "fullMono")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveNumLitSite") (EVar "sx")) (EVar "rpNames")) (EVar "name")) (EVar "tagRef")) (EVar "resultMono")) (EVar "fullMono")) (EVar "predicate")) (EVar "encl")) (EVar "loc")) (EVar "scope"))) (arm PWild () (ELit LUnit)))) (DoExpr (EApp (EApp (EApp (EVar "resolveSites") (EVar "sx")) (EVar "rpNames")) (EVar "rest")))))
(DTypeSig false "resolveRLocalSites" (TyFun (TyCon "SiteCtx") (TyFun (TyApp (TyCon "List") (TyCon "PendingEntry")) (TyCon "Unit"))))
(DFunDef false "resolveRLocalSites" ((PVar "sx") (PList)) (ELit LUnit))
(DFunDef false "resolveRLocalSites" ((PVar "sx") (PCons (PCon "PendingEntry" (PVar "name") (PVar "tagRef") (PVar "am") (PVar "encl") (PVar "kind") (PVar "loc") (PVar "scope") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "sx") (ERecordUpdate (EVar "sx") ((fa "sxSite" (EVar "loc"))))) (DoExpr (EMatch (EVar "kind") (arm (PCon "SKRLocal" (PVar "sym") (PVar "forceLocal") (PVar "monos") (PVar "ifaces") (PVar "argVecs")) () (EIf (EVar "forceLocal") (EApp (EApp (EVar "setRef") (EVar "tagRef")) (EApp (EApp (EVar "RLocal") (EVar "sym")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routesOfMonosTopV") (EVar "sx")) (EVar "encl")) (EVar "scope")) (EVar "monos")) (EVar "ifaces")) (EVar "argVecs")))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveRLocalSite") (EVar "sx")) (EVar "name")) (EVar "tagRef")) (EVar "am")) (EVar "encl")) (EVar "scope")) (EVar "sym")) (EVar "monos")) (EVar "ifaces")) (EVar "argVecs")))) (arm PWild () (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "resolveRLocalSites") (EVar "sx")) (EVar "rest")))))
(DTypeSig false "resolveArithSites" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Ref") (TyCon "Route")) (TyCon "Mono"))) (TyCon "Unit")))
(DFunDef false "resolveArithSites" ((PList)) (ELit LUnit))
(DFunDef false "resolveArithSites" ((PCons (PTuple (PVar "dref") (PVar "m")) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EVar "resolveArithSite") (EVar "dref")) (EVar "m"))) (DoExpr (EApp (EVar "resolveArithSites") (EVar "rest")))))
(DTypeSig false "resolveOpSites" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "PendingEntry")) (TyCon "Unit")))))
(DFunDef false "resolveOpSites" ((PVar "sx") PWild (PList)) (ELit LUnit))
(DFunDef false "resolveOpSites" ((PVar "sx") (PVar "isBinop") (PCons (PCon "PendingEntry" (PVar "method") (PVar "tagRef") (PVar "operandMono") (PVar "encl") (PVar "kind") (PVar "loc") (PVar "scope") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "sx") (ERecordUpdate (EVar "sx") ((fa "sxSite" (EVar "loc"))))) (DoExpr (EMatch (EVar "kind") (arm (PCon "SKOp" (PVar "inImpl")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveOpSite") (EVar "sx")) (EVar "isBinop")) (EVar "method")) (EVar "tagRef")) (EVar "operandMono")) (EVar "inImpl")) (EVar "encl")) (EVar "scope"))) (arm (PCon "SKPredicateOp" (PVar "inImpl") (PVar "predicate")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolvePredicateOpSite") (EVar "sx")) (EVar "isBinop")) (EVar "method")) (EVar "tagRef")) (EVar "operandMono")) (EVar "inImpl")) (EVar "predicate")) (EVar "encl")) (EVar "scope"))) (arm PWild () (ELit LUnit)))) (DoExpr (EApp (EApp (EApp (EVar "resolveOpSites") (EVar "sx")) (EVar "isBinop")) (EVar "rest")))))
(DTypeSig false "checkInterfaceCycles" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyCon "Unit"))))))
(DFunDef false "checkInterfaceCycles" ((PVar "mctx") (PVar "prog") (PVar "ce") (PVar "cur")) (EBlock (DoLet false false (PVar "done") (EApp (EVar "Ref") (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "each") (EApp (EApp (EApp (EApp (EApp (EVar "checkOneIfaceCycle") (EVar "mctx")) (EVar "prog")) (EVar "ce")) (EVar "cur")) (EVar "done"))) (EApp (EApp (EVar "ceRowsVisibleAt") (EVar "cur")) (EVar "ce"))))))
(DTypeSig false "runFinalChecks" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "ClassEnv") (TyFun (TyCon "ClassEnv") (TyFun (TyCon "ImplEnv") (TyFun (TyCon "ImplEnv") (TyFun (TyCon "Int") (TyCon "Unit")))))))))
(DFunDef false "runFinalChecks" ((PVar "mctx") (PVar "cohDecls") (PVar "ownCe") (PVar "cycCe") (PVar "cohIe") (PVar "cycIe") (PVar "cur")) (EBlock (DoExpr (EApp (EApp (EVar "ordinalSentinelGuard") (EVar "mctx")) (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "checkCoherence") (EVar "mctx")) (EVar "cohIe")) (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkInterfaceCycles") (EVar "mctx")) (EVar "cohDecls")) (EVar "cycCe")) (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "checkPhantomMethods") (EVar "mctx")) (EVar "ownCe")) (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "checkSuperImpls") (EVar "mctx")) (EVar "cohDecls")) (EVar "cycCe")) (EVar "cycIe")) (EVar "cur")))))
(DTypeSig false "ordinalSentinelGuard" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyCon "Unit"))))
(DFunDef false "ordinalSentinelGuard" ((PVar "mctx") (PVar "cur")) (EIf (EApp (EVar "ordinalIsSentinel") (EVar "cur")) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (EVar "TInternalOrdinal")) (EVar "ordinalSentinelMsg")) (EIf (EVar "otherwise") (ELit LUnit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ordinalIsSentinel" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "ordinalIsSentinel" ((PVar "cur")) (EBinOp "<" (EVar "cur") (ELit (LInt 0))))
(DTypeSig false "checkOneIfaceCycle" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyCon "CeRow") (TyCon "Unit"))))))))
(DFunDef false "checkOneIfaceCycle" ((PVar "mctx") (PVar "prog") (PVar "ce") (PVar "cur") (PVar "done") (PVar "row")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EApp (EVar "ceRowDoneKey") (EVar "row"))) (EUnOp "!" (EVar "done")))) (EApp (EApp (EVar "each") (EApp (EApp (EVar "pushTypeError") (EApp (EApp (EVar "mctxAt") (EApp (EApp (EApp (EApp (EVar "cycleReportLoc") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "declEnvsRef") "value") "deReach")) (EVar "prog")) (EVar "cur")) (EVar "row"))) (EVar "mctx"))) (EVar "TCyclicSuperinterface"))) (EApp (EApp (EApp (EApp (EApp (EVar "ifaceDfsCycle") (EVar "ce")) (EVar "cur")) (EVar "done")) (EListLit (EVar "row"))) (EVar "row"))) (ELit LUnit)))
(DTypeSig false "cycleReportLoc" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyCon "CeRow") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "cycleReportLoc" ((PVar "reach") (PVar "prog") (PVar "cur") (PVar "row")) (EIf (EBinOp "==" (EApp (EVar "ceRowOrd") (EVar "row")) (EVar "cur")) (EApp (EVar "ceRowLoc") (EVar "row")) (EIf (EVar "otherwise") (EMatch (EFieldAccess (EApp (EVar "ceRowIface") (EVar "row")) "irOrigin") (arm (PCon "OriginModule" (PVar "owner")) () (EApp (EApp (EApp (EVar "importLocFor") (EVar "reach")) (EVar "prog")) (EVar "owner"))) (arm PWild () (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ifaceDfsCycle" (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "List") (TyCon "CeRow")) (TyFun (TyCon "CeRow") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "ifaceDfsCycle" ((PVar "ce") (PVar "cur") (PVar "done") (PVar "path") (PVar "current")) (EBlock (DoLet false false (PVar "msgs") (EApp (EApp (EApp (EApp (EApp (EVar "ifaceDfsCycleSupers") (EVar "ce")) (EVar "cur")) (EVar "done")) (EVar "path")) (EApp (EVar "ceRowSupers") (EVar "current")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "done")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "ceRowDoneKey") (EVar "current"))) (ELit LUnit)) (EUnOp "!" (EVar "done"))))) (DoExpr (EVar "msgs"))))
(DTypeSig false "ifaceDfsCycleSupers" (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "List") (TyCon "CeRow")) (TyFun (TyApp (TyCon "List") (TyCon "Super")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "ifaceDfsCycleSupers" (PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "ifaceDfsCycleSupers" ((PVar "ce") (PVar "cur") (PVar "done") (PVar "path") (PCons (PRec "Super" ((rf "superHead" (PVar "superName")) (rf "superOrigin" (PVar "so"))) false) (PVar "rest"))) (EBlock (DoLet false false (PVar "msgs1") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ifaceDfsCycleOneSuper") (EVar "ce")) (EVar "cur")) (EVar "done")) (EVar "path")) (EVar "so")) (EVar "superName"))) (DoExpr (EBinOp "++" (EVar "msgs1") (EApp (EApp (EApp (EApp (EApp (EVar "ifaceDfsCycleSupers") (EVar "ce")) (EVar "cur")) (EVar "done")) (EVar "path")) (EVar "rest"))))))
(DTypeSig false "ifaceDfsCycleOneSuper" (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "List") (TyCon "CeRow")) (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "ifaceDfsCycleOneSuper" ((PVar "ce") (PVar "cur") (PVar "done") (PVar "path") (PVar "so") (PVar "superName")) (EBlock (DoLet false false (PVar "key") (EApp (EVar "regKeyOfTab") (EApp (EApp (EVar "ifaceTabKey") (EVar "so")) (EVar "superName")))) (DoLet false false (PVar "rendered") (EApp (EVar "regKeyRender") (EVar "key"))) (DoExpr (EIf (EApp (EApp (EVar "containsRowKey") (EVar "rendered")) (EVar "path")) (EListLit (EApp (EVar "cyclicSuperIfaceMsg") (EBinOp "++" (EApp (EApp (EVar "map") (EVar "ceRowIfaceName")) (EVar "path")) (EListLit (EVar "superName"))))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "rendered")) (EUnOp "!" (EVar "done"))) (EListLit) (EMatch (EApp (EApp (EApp (EVar "ceLookupAt") (EVar "key")) (EVar "cur")) (EVar "ce")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "r")) () (EApp (EApp (EApp (EApp (EApp (EVar "ifaceDfsCycle") (EVar "ce")) (EVar "cur")) (EVar "done")) (EBinOp "++" (EVar "path") (EListLit (EVar "r")))) (EVar "r")))))))))
(DTypeSig false "containsRowKey" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CeRow")) (TyCon "Bool"))))
(DFunDef false "containsRowKey" (PWild (PList)) (EVar "False"))
(DFunDef false "containsRowKey" ((PVar "k") (PCons (PVar "r") (PVar "rest"))) (EIf (EBinOp "==" (EApp (EVar "ceRowDoneKey") (EVar "r")) (EVar "k")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "containsRowKey") (EVar "k")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "checkBodyImpl" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "CheckRunSeed") (TyFun (TyCon "ModuleSeed") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "ModuleBindings") (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "ModuleCtx")))))))))
(DFunDef false "checkBodyImpl" ((PVar "gctx") (PVar "runSeed") (PVar "moduleSeed") (PVar "mid") (PVar "implDecls") (PVar "prog0")) (EBlock (DoLet false false (PVar "seed") (EFieldAccess (EVar "moduleSeed") "msSchemes")) (DoLet false false (PVar "mctx") (EApp (EApp (EApp (EVar "freshModuleCtx") (EVar "gctx")) (EVar "runSeed")) (EVar "mid"))) (DoLet false false (PVar "moduleScope") (EApp (EApp (EApp (EApp (EApp (EVar "Scopes.freshScope") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))) (EVar "None")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (EVar "mid")) (EVar "ModuleOwner"))) (DoExpr (EApp (EApp (EVar "openScope") (EVar "mctx")) (EVar "moduleScope"))) (DoExpr (EApp (EApp (EVar "recordModuleStart") (EVar "gctx")) (EVar "mid"))) (DoExpr (EApp (EApp (EVar "reportAmbiguousImports") (EVar "mctx")) (EVar "prog0"))) (DoLet false false (PVar "prog") (EVar "prog0")) (DoLet false false (PVar "aliasSpellings") (EApp (EApp (EVar "aliasMethodSpellings") (EVar "gctx")) (EVar "prog"))) (DoExpr (EApp (EApp (EApp (EVar "seedBuiltinClasses") (EVar "gctx")) (EVar "mid")) (EVar "prog"))) (DoLet false false (PVar "stampRes") (EBlock (DoLet false false (PTuple (PVar "top") (PVar "ids")) (EApp (EVar "stampTopScope") (EVar "prog"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "beginModuleMarking") (EVar "mctx")) (EVar "mid")) (EVar "prog")) (EVar "top")) (EVar "moduleSeed"))) (DoExpr (ETuple (EVar "prog") (EVar "ids"))))) (DoLet false false (PVar "progS") (EApp (EVar "fst") (EVar "stampRes"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "schemeDefIdsRef")) (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EVar "snd") (EVar "stampRes")))) (EVar "omEmpty")))) (DoLet false false (PVar "superDecls") (EBinOp "++" (EVar "prog") (EVar "implDecls"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "superDeclsRef")) (EVar "superDecls"))) (DoExpr (EApp (EApp (EVar "checkEffectParams") (EVar "mctx")) (EVar "prog"))) (DoExpr (EApp (EApp (EVar "checkLetRecDecls") (EVar "mctx")) (EVar "prog"))) (DoExpr (EApp (EApp (EApp (EVar "appendUniverseAccums") (EVar "gctx")) (EVar "mid")) (EVar "prog0"))) (DoLet false false (PVar "moduleImplUniv") (EBlock (DoLet false false (PVar "envs") (EFieldAccess (EFieldAccess (EVar "gctx") "declEnvsRef") "value")) (DoExpr (EApp (EApp (EVar "ieUniverseAt") (EApp (EApp (EVar "declEnvsOrdOf") (EVar "mid")) (EVar "envs"))) (EFieldAccess (EVar "envs") "deImpls"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "residualUnivRef")) (EVar "moduleImplUniv"))) (DoLet false false (PVar "isMethod") (EBlock (DoLet false false (PVar "envs") (EFieldAccess (EFieldAccess (EVar "gctx") "declEnvsRef") "value")) (DoExpr (EApp (EApp (EVar "methodNameDeclaredAt") (EApp (EApp (EVar "declEnvsOrdOf") (EVar "mid")) (EVar "envs"))) (EFieldAccess (EVar "envs") "deMethods"))))) (DoLet false false (PVar "definerShadows") (EApp (EApp (EApp (EVar "nameableIfaceShadows") (EVar "gctx")) (EVar "prog0")) (EApp (EApp (EApp (EVar "definerShadowsFromSet") (EVar "gctx")) (EVar "isMethod")) (EVar "prog0")))) (DoLet false false (PVar "importerShadows") (EIf (EApp (EVar "isEmptyL") (EVar "implDecls")) (EListLit) (EApp (EApp (EApp (EVar "nameableIfaceShadows") (EVar "gctx")) (EVar "prog0")) (EApp (EApp (EApp (EApp (EVar "standaloneShadowsFromSet") (EVar "gctx")) (EVar "isMethod")) (EApp (EApp (EVar "omMapValues") (ELam (PWild) (ELit LUnit))) (EFieldAccess (EVar "moduleSeed") "msImportedValues"))) (EVar "prog0"))))) (DoLet false false (PVar "sigs") (EApp (EVar "sigsOf") (EVar "prog"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "definerShadowNamesRef")) (EApp (EApp (EVar "namesToSet") (EVar "definerShadows")) (EVar "omEmpty")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "definerShadowSigsRef")) (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "sigs"))) (EVar "omEmpty")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "bodyImplEnvRef")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "declEnvsRef") "value") "deImpls"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "standaloneValuesRef")) (EApp (EApp (EVar "namesToSet") (EBinOp "++" (EVar "importerShadows") (EVar "definerShadows"))) (EVar "omEmpty")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodDispatchIdxByIdRef")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "universeMethodDispatchIdxByIdRef") "value"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funPredicateSlotsRef")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleFunPredicateSlotsRef") "value"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funConstraintDeclaredRef")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleFunConstraintDeclaredRef") "value"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funPredicateSlotsRef")) (EBinOp "++" (EApp (EApp (EApp (EVar "aliasConstraintEntries") (EVar "gctx")) (EVar "prog")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleFunPredicateSlotsQualRef") "value")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funPredicateSlotsRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funConstraintDeclaredRef")) (EBinOp "++" (EApp (EApp (EApp (EVar "aliasConstraintEntries") (EVar "gctx")) (EVar "prog")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleFunConstraintDeclaredQualRef") "value")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funConstraintDeclaredRef") "value")))) (DoExpr (EApp (EApp (EVar "setFunPredicateSlots") (EVar "mctx")) (EApp (EApp (EApp (EApp (EVar "selfDeclArities") (EVar "mid")) (EVar "prog")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleFunPredicateSlotsQualRef") "value")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funPredicateSlotsRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funConstraintDeclaredRef")) (EApp (EApp (EApp (EApp (EVar "selfDeclArities") (EVar "mid")) (EVar "prog")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleFunConstraintDeclaredQualRef") "value")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funConstraintDeclaredRef") "value")))) (DoLet false false (PVar "admitted") (EApp (EApp (EVar "importDefinersOf") (EVar "gctx")) (EVar "prog"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentImportDefinersRef")) (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EVar "definerRowsOf") (EVar "admitted")))) (EVar "omEmpty")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentImportOriginsRef")) (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EVar "originRowsOf") (EVar "admitted")))) (EVar "omEmpty")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "importedSchemeOblsRef")) (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EApp (EVar "importedSchemeOblEntries") (EVar "prog")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleSchemeOblsQualRef") "value")))) (EVar "omEmpty")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodScopeCtxRef")) (EApp (EVar "Some") (ETuple (EVar "prog") (EApp (EApp (EVar "declEnvsOrdOf") (EVar "mid")) (EFieldAccess (EFieldAccess (EVar "gctx") "declEnvsRef") "value")))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodAliasEntriesRef")) (EApp (EApp (EApp (EVar "aliasQualifiedMethodEntries") (EVar "mctx")) (EVar "prog")) (EVar "omEmpty")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "aliasMethodOriginsRef")) (EApp (EApp (EVar "omFromPairs") (EVar "aliasSpellings")) (EVar "omEmpty")))) (DoLet false false (PVar "dataEnv") (EBlock (DoLet false false (PVar "envs") (EFieldAccess (EFieldAccess (EVar "gctx") "declEnvsRef") "value")) (DoLet false false (PVar "cur") (EApp (EApp (EVar "declEnvsOrdOf") (EVar "mid")) (EVar "envs"))) (DoExpr (EApp (EApp (EVar "loadDataUniverse") (EVar "mctx")) (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "declEnvSeedDataUniverse") (EVar "mctx")) (EVar "mid")) (EVar "envs"))) (DoLet false false (PVar "base") (EApp (EApp (EApp (EVar "registerImportOverlay") (EApp (EApp (EVar "withCtors") (EVar "mctx")) (EApp (EVar "spFloor") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "universeCtorPop") "value")))) (EVar "prog0")) (EApp (EApp (EApp (EVar "importedCtorTypeDeclsLastWins") (EVar "prog0")) (EVar "cur")) (EFieldAccess (EVar "envs") "deModules")))) (DoLet false false (PVar "env0") (EApp (EApp (EVar "registerAllData") (EVar "base")) (EVar "prog0"))) (DoExpr (EApp (EApp (EVar "applyRecordScopeOverrides") (EVar "mctx")) (EVar "prog0"))) (DoExpr (EApp (EApp (EVar "applyCtorScopeOverrides") (EVar "prog0")) (EVar "env0"))))) (DoExpr (EApp (EVar "recordInvocationView") (EVar "dataEnv"))) (DoExpr (EApp (EApp (EVar "checkUndeterminedRetEffVars") (EVar "mctx")) (EVar "prog"))) (DoExpr (EApp (EApp (EVar "checkDeclaredKinds") (EVar "mctx")) (EVar "prog"))) (DoExpr (EApp (EApp (EVar "checkDeclAuthorityUses") (EVar "mctx")) (EVar "prog"))) (DoLet false false (PVar "classEnvHere") (EBlock (DoLet false false (PVar "envs") (EFieldAccess (EFieldAccess (EVar "gctx") "declEnvsRef") "value")) (DoExpr (ETuple (EFieldAccess (EVar "envs") "deIfaces") (EApp (EApp (EVar "declEnvsOrdOf") (EVar "mid")) (EVar "envs")))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkGradedImplHeads") (EVar "mctx")) (EApp (EVar "fst") (EVar "classEnvHere"))) (EApp (EVar "snd") (EVar "classEnvHere"))) (EVar "prog"))) (DoExpr (EApp (EApp (EVar "rejectCyclicAliases") (EVar "mctx")) (EVar "prog"))) (DoLet false false (PVar "currentMethodRows") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "mctx")) (EVar "prog"))) (DoExpr (EApp (EApp (EVar "recordMethodGrants") (EVar "gctx")) (EVar "currentMethodRows"))) (DoLet false false (PVar "visibleMethodRows") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "mctx")) (EVar "implDecls"))) (DoLet false false (PVar "visibleMethodRowIndex") (EApp (EApp (EApp (EVar "methodRowsByIdentity") (EApp (EVar "isNonEmptyL") (EVar "importerShadows"))) (EVar "visibleMethodRows")) (EVar "regEmpty"))) (DoLet false false (PVar "externS") (EApp (EApp (EApp (EVar "userExternSchemes") (EVar "mctx")) (EApp (EVar "externTyOriginScope") (EListLit))) (EVar "prog"))) (DoLet false false (PVar "globalS") (EBinOp "++" (EApp (EVar "legacyMethodSchemes") (EVar "currentMethodRows")) (EVar "externS"))) (DoExpr (EApp (EApp (EApp (EVar "ffiCheckExternsCrossable") (EVar "mctx")) (EApp (EApp (EVar "ffiStampMode") (EVar "gctx")) (EVar "mid"))) (EVar "prog"))) (DoExpr (EApp (EApp (EApp (EVar "ffiCheckExternsLabelled") (EVar "mctx")) (EApp (EApp (EVar "ffiStampMode") (EVar "gctx")) (EVar "mid"))) (EVar "prog"))) (DoExpr (EApp (EApp (EApp (EVar "ffiCheckExternsShadow") (EVar "mctx")) (EApp (EApp (EVar "ffiStampMode") (EVar "gctx")) (EVar "mid"))) (EVar "prog"))) (DoExpr (EApp (EApp (EApp (EVar "ffiCheckExternsCatalogRow") (EVar "mctx")) (EApp (EApp (EVar "ffiStampMode") (EVar "gctx")) (EVar "mid"))) (EVar "prog"))) (DoLet false false (PVar "envSeed") (EApp (EApp (EVar "extendVars") (EVar "dataEnv")) (EVar "seed"))) (DoLet false false (PVar "shadowLayer") (EBlock (DoLet false false (PVar "ifaceSchemes") (EApp (EVar "legacyMethodSchemes") (EVar "visibleMethodRows"))) (DoExpr (EApp (EApp (EVar "seedNumLitFromIntAnchor") (EVar "mctx")) (EVar "visibleMethodRows"))) (DoLet false false (PVar "sm") (EApp (EApp (EApp (EApp (EApp (EVar "pickSchemesByDecl") (EVar "mctx")) (EVar "importerShadows")) (EVar "ifaceSchemes")) (EVar "visibleMethodRowIndex")) (EFieldAccess (EVar "moduleSeed") "msImportedValues"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodPredicateSlotsRef")) (EBinOp "++" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodPredicateSlotsRef") "value") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleMethodPredicateSlotsRef") "value")))) (DoExpr (EApp (EApp (EVar "attachStandaloneSources") (EFieldAccess (EVar "moduleSeed") "msImportedValues")) (EVar "sm"))))) (DoLet false false (PVar "envImported") (EApp (EApp (EApp (EApp (EApp (EVar "annotateImportedMethodRows") (EVar "envSeed")) (EApp (EApp (EApp (EVar "importedMethodBindingNames") (EVar "gctx")) (EVar "prog0")) (EVar "aliasSpellings"))) (EApp (EApp (EVar "nameableIfaceMethodSet") (EVar "gctx")) (EVar "prog0"))) (EApp (EApp (EVar "namesToSet") (EVar "importerShadows")) (EVar "omEmpty"))) (EVar "visibleMethodRowIndex"))) (DoLet false false (PVar "envGlobal") (EApp (EApp (EVar "extendVars") (EApp (EApp (EVar "extendMethodRows") (EVar "envImported")) (EVar "currentMethodRows"))) (EVar "externS"))) (DoLet false false (PVar "env1") (EApp (EApp (EVar "extendBindings") (EVar "envGlobal")) (EVar "shadowLayer"))) (DoLet false false (PVar "defs") (EApp (EVar "funDefs") (EVar "progS"))) (DoLet false false (PTuple (PVar "topSchemes") (PVar "groupedOut")) (EApp (EApp (EApp (EApp (EApp (EVar "processTopGroups") (EVar "env1")) (EVar "sigs")) (EVar "defs")) (EApp (EApp (EVar "groupNames") (EVar "defs")) (EVar "omEmpty"))) (EApp (EApp (EVar "namesToSet") (EApp (EVar "publicValNames") (EVar "prog"))) (EVar "omEmpty")))) (DoExpr (EApp (EApp (EApp (EVar "recordTopBinderTypes") (EVar "gctx")) (EApp (EApp (EVar "omFromPairs") (EVar "topSchemes")) (EVar "omEmpty"))) (EVar "progS"))) (DoLet false false (PVar "tailEnv") (EApp (EApp (EVar "extendTermBindings") (EVar "env1")) (EVar "topSchemes"))) (DoLet false false (PVar "progOut") (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "markingRef") "value") (arm (PCon "Some" (PVar "mm")) () (EApp (EApp (EApp (EApp (EVar "finishModuleMarking") (EVar "mm")) (EVar "tailEnv")) (EVar "groupedOut")) (EVar "progS"))) (arm (PCon "None") () (EVar "progS")))) (DoLet false false (PVar "progT") (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "markingRef") "value") (arm (PCon "Some" (PVar "mm")) () (EApp (EApp (EVar "stampTailDecls") (EFieldAccess (EVar "mm") "mmTop")) (EVar "progOut"))) (arm (PCon "None") () (EVar "progS")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "inferUserImplBodies") (EVar "tailEnv")) (EVar "implDecls")) (EApp (EVar "fst") (EVar "classEnvHere"))) (EApp (EVar "snd") (EVar "classEnvHere"))) (EVar "progT"))) (DoExpr (EApp (EApp (EVar "inferDefaultBodies") (EVar "tailEnv")) (EVar "progT"))) (DoExpr (EApp (EApp (EVar "inferPropBodies") (EVar "tailEnv")) (EVar "progT"))) (DoExpr (EApp (EApp (EVar "inferTestBodies") (EVar "tailEnv")) (EVar "progT"))) (DoExpr (EApp (EApp (EVar "dedupPredicateSlotsTable") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleFunPredicateSlotsRef")) (EApp (EVar "predicateSlotTableWithoutArgs") (EBinOp "++" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funPredicateSlotsRef") "value") (EApp (EApp (EVar "selfNameRows") (EVar "prog")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleFunPredicateSlotsRef") "value")))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleFunPredicateSlotsQualRef")) (EBinOp "++" (EApp (EApp (EApp (EVar "attributeModuleEntries") (EVar "mid")) (EVar "prog")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funPredicateSlotsRef") "value")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleFunPredicateSlotsQualRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleFunConstraintDeclaredRef")) (EBinOp "++" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funConstraintDeclaredRef") "value") (EApp (EApp (EVar "selfNameRows") (EVar "prog")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleFunConstraintDeclaredRef") "value"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleFunConstraintDeclaredQualRef")) (EBinOp "++" (EApp (EApp (EApp (EVar "attributeModuleEntries") (EVar "mid")) (EVar "prog")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funConstraintDeclaredRef") "value")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleFunConstraintDeclaredQualRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleMethodPredicateSlotsRef")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodPredicateSlotsRef") "value"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleMethodPredicateSlotsQualRef")) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "emptyMethodModulePredicateSlots") (EVar "mid")) (EVar "prog")) (EApp (EApp (EApp (EVar "attributeMethodModulePredicateSlots") (EVar "mid")) (EVar "prog")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodPredicateSlotsRef") "value"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleMethodPredicateSlotsQualRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleSchemeOblsQualRef")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "attributeModuleSchemeObls") (EVar "mid")) (EVar "prog")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleSchemeOblsQualRef") "value")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "schemeObligationsRef") "value")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleSchemeOblsQualRef") "value")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkImplCompletenessMap") (EVar "mctx")) (EApp (EVar "fst") (EVar "classEnvHere"))) (EApp (EVar "snd") (EVar "classEnvHere"))) (EVar "prog"))) (DoLet false false (PVar "obUniv") (EVar "moduleImplUniv")) (DoExpr (EApp (EApp (EVar "recordLiveRoots") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "judgeQuiescentGoals") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "refileDeterminedRows") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkCallObligationsU") (EVar "mctx")) (EVar "True")) (EVar "obUniv")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "implObls") "items") "value"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkCallObligationsU") (EVar "mctx")) (EVar "False")) (EVar "obUniv")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "obls") "items") "value"))) (DoExpr (EApp (EApp (EVar "settleDeferredPatLits") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "checkDeferredMatches") (EVar "mctx")) (EApp (EVar "reverseL") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchChecksDeferred") "value")))) (DoExpr (EApp (EApp (EVar "checkFixedWidthLiterals") (EVar "mctx")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitRanges") "value"))) (DoExpr (EApp (EApp (EVar "checkWideLiterals") (EVar "mctx")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "wideLitRanges") "value"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "localSchemesOut")) (EApp (EApp (EVar "mapLocalSchemes") (EVar "mctx")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "localBindRefs") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "seedSchemesOut")) (EVar "seed"))) (DoExpr (EApp (EApp (EApp (EVar "appendDataUniverse") (EVar "mctx")) (EVar "mid")) (EVar "prog0"))) (DoLet false false (PVar "result") (ETuple (ERecordCreate "ModuleBindings" ((fa "mbSchemes" (EBinOp "++" (EVar "globalS") (EVar "topSchemes"))) (fa "mbStandaloneSchemes" (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "topSchemes"))) (EVar "omEmpty"))))) (EVar "progOut") (EVar "mctx"))) (DoExpr (EApp (EApp (EVar "closeScope") (EVar "mctx")) (ELit LUnit))) (DoExpr (EVar "result"))))
(DTypeSig false "inferPropBodies" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "inferPropBodies" ((PVar "env") (PVar "prog")) (EBlock (DoLet false false (PVar "mark") (EApp (EApp (EVar "goalsMark") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "inferPropBodiesGo") (EVar "env")) (EVar "prog"))) (DoExpr (EApp (EApp (EApp (EVar "dropGoalsSince") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "mark")) (EListLit (EVar "GKBinopSite") (EVar "GKUnopSite") (EVar "GKArithSite"))))))
(DTypeSig false "inferPropBodiesGo" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "inferPropBodiesGo" ((PVar "env") (PList)) (ELit LUnit))
(DFunDef false "inferPropBodiesGo" ((PVar "outer") (PCons (PCon "DProp" PWild (PVar "name") (PVar "params") (PVar "body")) (PVar "rest"))) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EVar "envAtIfSome") (EApp (EVar "exprSpanLoc") (EVar "body"))) (EVar "outer"))) (DoLet false false (PVar "local") (EApp (EApp (EVar "extendPropParams") (EVar "env")) (EVar "params"))) (DoExpr (EApp (EApp (EVar "enterLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "parentScope") (EApp (EApp (EVar "captureScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "bodyScope") (EApp (EApp (EApp (EApp (EApp (EVar "Scopes.freshScope") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (EApp (EVar "Some") (EVar "parentScope"))) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentLevel") "value")) (EFieldAccess (EApp (EApp (EVar "Scopes.scopeFrame") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (EVar "parentScope")) "sfModuleId")) (EApp (EVar "PropOwner") (EVar "name")))) (DoExpr (EApp (EApp (EVar "openScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "bodyScope"))) (DoLet false false (PVar "oblMark") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls"))) (DoLet false false (PVar "callMark") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "obls"))) (DoLet false false (PVar "dictMark") (EApp (EApp (EVar "goalsMark") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EApp (EApp (EVar "dynAtIfSome") (EApp (EVar "valueSpanLoc") (EVar "body"))) (EFieldAccess (EVar "env") "teDyn"))) (EApp (EApp (EVar "infer") (EVar "local")) (EVar "body"))) (EApp (EVar "tconBuiltin") (ELit (LString "Bool"))))) (DoExpr (EApp (EApp (EVar "exitLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "settleClosedBody") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EVar "tconBuiltin") (ELit (LString "Bool")))) (EVar "oblMark")) (EVar "callMark")) (EVar "dictMark"))) (DoExpr (EApp (EApp (EVar "closeScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "inferPropBodiesGo") (EVar "outer")) (EVar "rest")))))
(DFunDef false "inferPropBodiesGo" ((PVar "env") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "inferPropBodiesGo") (EVar "env")) (EVar "rest")))
(DTypeSig false "inferTestBodies" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "inferTestBodies" ((PVar "env") (PList)) (ELit LUnit))
(DFunDef false "inferTestBodies" ((PVar "outer") (PCons (PCon "DTest" PWild (PVar "name") (PVar "body")) (PVar "rest"))) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EVar "envAtIfSome") (EApp (EVar "exprSpanLoc") (EVar "body"))) (EVar "outer"))) (DoExpr (EApp (EApp (EVar "enterLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "parentScope") (EApp (EApp (EVar "captureScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "bodyScope") (EApp (EApp (EApp (EApp (EApp (EVar "Scopes.freshScope") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (EApp (EVar "Some") (EVar "parentScope"))) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentLevel") "value")) (EFieldAccess (EApp (EApp (EVar "Scopes.scopeFrame") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (EVar "parentScope")) "sfModuleId")) (EApp (EVar "TestOwner") (EVar "name")))) (DoExpr (EApp (EApp (EVar "openScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "bodyScope"))) (DoLet false false (PVar "oblMark") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls"))) (DoLet false false (PVar "callMark") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "obls"))) (DoLet false false (PVar "dictMark") (EApp (EApp (EVar "goalsMark") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EApp (EApp (EVar "dynAtIfSome") (EApp (EVar "valueSpanLoc") (EVar "body"))) (EFieldAccess (EVar "env") "teDyn"))) (EApp (EApp (EVar "infer") (EVar "env")) (EVar "body"))) (EApp (EVar "tconUnresolved") (ELit (LString "Expectation"))))) (DoExpr (EApp (EApp (EVar "exitLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "settleClosedBody") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EVar "tconUnresolved") (ELit (LString "Expectation")))) (EVar "oblMark")) (EVar "callMark")) (EVar "dictMark"))) (DoExpr (EApp (EApp (EVar "closeScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "inferTestBodies") (EVar "outer")) (EVar "rest")))))
(DFunDef false "inferTestBodies" ((PVar "env") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "inferTestBodies") (EVar "env")) (EVar "rest")))
(DTypeSig true "settleClosedBody" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Unit")))))))
(DFunDef false "settleClosedBody" ((PVar "mctx") (PVar "bodyTy") (PVar "oblMark") (PVar "callMark") (PVar "dictMark")) (EBlock (DoLet false false (PVar "level") (EBinOp "+" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value") (ELit (LInt 1)))) (DoLet false false (PVar "addedObls") (EApp (EApp (EVar "wWindow") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "implObls")) (EVar "oblMark"))) (DoLet false false (PVar "bodyObls") (EBinOp "++" (EVar "addedObls") (EApp (EApp (EVar "callUOblsWindow") (EVar "mctx")) (EVar "callMark")))) (DoLet false false (PVar "rigidIds") (EApp (EApp (EApp (EVar "outerRigidIds") (EApp (EVar "Some") (EVar "level"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "uOblArgs") (EFieldAccess (EVar "mctx") "mcGraph"))) (EVar "bodyObls"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EApp (EVar "improveByUniqueImpl") (EApp (EVar "dynFor") (EVar "mctx"))) (EVar "rigidIds")) (EVar "bodyObls"))) (DoExpr (EApp (EApp (EApp (EVar "determineByUniqueInstance") (EVar "mctx")) (EVar "rigidIds")) (EVar "bodyObls"))) (DoLet false false (PVar "withheld") (EApp (EApp (EVar "finalizeNumBoundary") (EApp (EVar "dynFor") (EVar "mctx"))) (ERecordCreate "NumBoundary" ((fa "nbDisposition" (EApp (EVar "NumBoundaryOwnedMethodBody") (EVar "level"))) (fa "nbMembers" (EListLit (EVar "bodyTy"))) (fa "nbSurvivingIds" (EVar "omEmpty")) (fa "nbDefaultObls" (EBinOp "++" (EVar "addedObls") (EApp (EApp (EApp (EVar "calleeNumObls") (EVar "mctx")) (EVar "callMark")) (EVar "dictMark")))) (fa "nbAmbiguityObls" (EVar "addedObls")) (fa "nbGuard" (ERecordCreate "NumGuard" ((fa "ngGoals" (EVar "bodyObls")) (fa "ngRigidIds" (EVar "rigidIds")) (fa "ngOuterBelow" (EApp (EVar "Some") (EVar "level")))))))))) (DoExpr (EApp (EApp (EApp (EVar "improveByUniqueImpl") (EApp (EVar "dynFor") (EVar "mctx"))) (EVar "rigidIds")) (EVar "bodyObls"))) (DoExpr (EApp (EApp (EApp (EVar "determineByUniqueInstance") (EVar "mctx")) (EVar "rigidIds")) (EVar "bodyObls"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "rejectUndeterminedVectors") (EVar "mctx")) (EVar "rigidIds")) (EVar "omEmpty")) (EVar "addedObls")) (EBinOp "++" (EApp (EApp (EVar "callUOblsWindow") (EVar "mctx")) (EVar "callMark")) (EApp (EApp (EApp (EApp (EVar "nestedRequireGoals") (EVar "mctx")) (EVar "rigidIds")) (EVar "omEmpty")) (EVar "bodyObls"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "rejectWithheldAmbiguity") (EVar "mctx")) (EVar "rigidIds")) (EVar "withheld")) (EVar "bodyObls")))))
(DTypeSig false "extendPropParams" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyCon "TcEnv"))))
(DFunDef false "extendPropParams" ((PVar "env") (PList)) (EVar "env"))
(DFunDef false "extendPropParams" ((PVar "env") (PCons (PCon "PropParam" (PVar "x") PWild (PVar "ty")) (PVar "rest"))) (EBlock (DoLet false false (PVar "scheme") (EApp (EVar "monoScheme") (EApp (EApp (EApp (EVar "fromAstType") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EApp (EVar "freshTvMap") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EVar "dedup") (EApp (EVar "tyVarNames") (EVar "ty"))))) (EVar "ty")))) (DoExpr (EApp (EApp (EVar "extendPropParams") (EApp (EApp (EApp (EVar "extendLocalVar") (EVar "env")) (EVar "x")) (EVar "scheme"))) (EVar "rest")))))
(DTypeSig false "setNumlitFloatsGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Float"))) (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Route")))) (TyCon "Unit")))
(DFunDef false "setNumlitFloatsGo" ((PList)) (ELit LUnit))
(DFunDef false "setNumlitFloatsGo" ((PCons (PTuple (PVar "var") (PVar "fref") (PVar "n") (PVar "dref")) (PVar "rest"))) (EBlock (DoExpr (EMatch (EApp (EVar "normalize") (EVar "var")) (arm (PCon "TCon" (PLit (LString "Float")) PWild) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "fref")) (EApp (EVar "Some") (EApp (EVar "intToFloat") (EVar "n"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "dref")) (EVar "RNone"))))) (arm (PCon "TCon" (PLit (LString "Int")) PWild) () (EApp (EApp (EVar "setRef") (EVar "dref")) (EVar "RNone"))) (arm PWild () (ELit LUnit)))) (DoExpr (EApp (EVar "setNumlitFloatsGo") (EVar "rest")))))
(DTypeSig false "recordLiveRoots" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "Unit"))))
(DFunDef false "recordLiveRoots" ((PVar "mctx") PWild) (EBlock (DoLet false false (PVar "members") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "liveMemberMonosRef") "value")) (DoLet false false (PVar "liveIds") (EApp (EVar "dedupI") (EApp (EApp (EVar "flatMap") (EApp (EVar "liveVarIdsOf") (EVar "mctx"))) (EVar "members")))) (DoExpr (EIf (EApp (EVar "isNonEmptyL") (EVar "liveIds")) (EBlock (DoLet false false (PVar "goals") (EBinOp "++" (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "implObls") "items") "value") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "obls") "items") "value"))) (DoLet false false (PVar "numObls") (EBinOp "++" (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "implObls") "items") "value") (EApp (EApp (EVar "numCallObls") (EFieldAccess (EVar "mctx") "mcGraph")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "obls") "items") "value")))) (DoLet false false (PVar "numIds") (EApp (EApp (EVar "filterList") (ELam ((PVar "i")) (EApp (EApp (EVar "containsI") (EVar "i")) (EVar "liveIds")))) (EApp (EVar "numConstrainedIds") (EVar "numObls")))) (DoLet false false (PVar "numRoots") (EApp (EApp (EVar "filterMap") (ELam ((PVar "i")) (EApp (EApp (EVar "liveNumVarGo") (EVar "i")) (EVar "numObls")))) (EApp (EVar "dedupI") (EVar "numIds")))) (DoLet false false (PVar "g") (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "liveRoots")) (EBinOp "++" (EApp (EApp (EVar "filterMap") (EApp (EVar "findTvarInMonos") (EVar "members"))) (EVar "liveIds")) (EFieldAccess (EFieldAccess (EVar "g") "liveRoots") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "liveGoals")) (EBinOp "++" (EApp (EVar "reverseL") (EApp (EApp (EVar "liveGoalsOf") (EVar "mctx")) (EVar "members"))) (EFieldAccess (EFieldAccess (EVar "g") "liveGoals") "value")))) (DoExpr (EIf (EApp (EVar "isNonEmptyL") (EVar "numRoots")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "liveNumRoots")) (EBinOp "++" (EVar "numRoots") (EFieldAccess (EFieldAccess (EVar "g") "liveNumRoots") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "liveNumGoals")) (EBinOp "++" (EApp (EApp (EVar "filterList") (ELam ((PVar "o")) (EApp (EApp (EVar "any") (ELam ((PVar "i")) (EApp (EApp (EVar "elem") (EVar "i")) (EVar "numIds")))) (EApp (EApp (EVar "flatMap") (EVar "monoUnboundIds")) (EApp (EApp (EVar "uOblArgs") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "o")))))) (EVar "goals")) (EFieldAccess (EFieldAccess (EVar "g") "liveNumGoals") "value"))))) (ELit LUnit)))) (ELit LUnit)))))
(DTypeSig false "liveGoalsOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "LiveGoal")))))
(DFunDef false "liveGoalsOf" ((PVar "mctx") (PVar "members")) (EBlock (DoLet false false (PVar "mid") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentModuleRef") "value")) (DoLet false false (PVar "owners") (EApp (EApp (EVar "memberOfIds") (EVar "mctx")) (EVar "members"))) (DoExpr (EApp (EApp (EVar "filterMap") (ELam ((PTuple (PVar "rigidIds") (PVar "window") (PVar "o"))) (EBlock (DoLet false false (PVar "ids") (EApp (EApp (EVar "flatMap") (EVar "monoUnboundIds")) (EApp (EApp (EVar "uOblArgs") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "o")))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "k")) (ERecordCreate "LiveGoal" ((fa "lgModule" (EVar "mid")) (fa "lgBinding" (EVar "k")) (fa "lgRigidIds" (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "i")) (EIf (EApp (EApp (EVar "IdMap.has") (EVar "i")) (EVar "owners")) (EApp (EApp (EVar "omDelete") (EApp (EVar "intToString") (EVar "i"))) (EVar "acc")) (EVar "acc")))) (EVar "rigidIds")) (EVar "ids"))) (fa "lgWindow" (EVar "window")) (fa "lgGoal" (EVar "o")))))) (EApp (EApp (EVar "findMap") (ELam ((PVar "i")) (EApp (EApp (EVar "IdMap.get") (EVar "i")) (EVar "owners")))) (EVar "ids"))))))) (EApp (EVar "reverseL") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "heldLiveGoalsRef") "value"))))))
(DTypeSig false "memberOfIds" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Int")))))
(DFunDef false "memberOfIds" ((PVar "mctx") (PVar "members")) (EApp (EVar "fst") (EApp (EApp (EApp (EVar "fold") (ELam ((PTuple (PVar "owners") (PVar "k")) (PVar "m")) (ETuple (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "i")) (EIf (EApp (EApp (EVar "IdMap.has") (EVar "i")) (EVar "acc")) (EVar "acc") (EApp (EApp (EApp (EVar "IdMap.set") (EVar "i")) (EVar "k")) (EVar "acc"))))) (EVar "owners")) (EApp (EApp (EVar "liveVarIdsOf") (EVar "mctx")) (EVar "m"))) (EBinOp "+" (EVar "k") (ELit (LInt 1)))))) (ETuple (EVar "Tip") (ELit (LInt 0)))) (EVar "members"))))
(DTypeSig false "judgeLiveGoals" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "StampCtx")) (TyApp (TyCon "List") (TyCon "DrainFinding")))))
(DFunDef false "judgeLiveGoals" ((PVar "saved") (PVar "ctxs")) (EBlock (DoLet false false (PVar "g") (EFieldAccess (EFieldAccess (EVar "saved") "mcGraph") "graphRun")) (DoLet false false (PVar "goals") (EApp (EVar "reverseL") (EFieldAccess (EFieldAccess (EVar "g") "liveGoals") "value"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "liveGoals")) (EListLit))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "goals")) (EListLit) (EBlock (DoLet false false (PVar "byModule") (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EVar "map") (ELam ((PVar "c")) (ETuple (EFieldAccess (EVar "c") "scModule") (EVar "c")))) (EVar "ctxs"))) (EVar "omEmpty"))) (DoExpr (EApp (EVar "reverseL") (EApp (EVar "fst") (EApp (EApp (EApp (EVar "fold") (EApp (EApp (EVar "judgeLiveGoal") (EVar "saved")) (EVar "byModule"))) (ETuple (EListLit) (EVar "omEmpty"))) (EVar "goals"))))))))))
(DTypeSig false "judgeLiveGoal" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "StampCtx")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "DrainFinding")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyCon "LiveGoal") (TyTuple (TyApp (TyCon "List") (TyCon "DrainFinding")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))))
(DFunDef false "judgeLiveGoal" ((PVar "saved") (PVar "byModule") (PTuple (PVar "found") (PVar "judged")) (PVar "lg")) (EBlock (DoLet false false (PVar "binding") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "lg") "lgModule"))) (ELit (LString "\t"))) (EApp (EVar "display") (EApp (EVar "intToString") (EFieldAccess (EVar "lg") "lgBinding")))) (ELit (LString "")))) (DoExpr (EMatch (ETuple (EApp (EApp (EVar "omHasKey") (EVar "binding")) (EVar "judged")) (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "lg") "lgModule")) (EVar "byModule"))) (arm (PTuple (PCon "False") (PCon "Some" (PVar "ctx"))) () (EBlock (DoLet false false (PVar "stamp") (EApp (EApp (EVar "enterStampCtx") (EVar "saved")) (EVar "ctx"))) (DoLet false false (PVar "rigidIds") (EFieldAccess (EVar "lg") "lgRigidIds")) (DoLet false false (PVar "diags") (EApp (EApp (EVar "captureTypeErrors") (EVar "stamp")) (ELam (PWild) (EApp (EApp (EVar "each") (EApp (EApp (EApp (EApp (EVar "undeterminedVectorVerdict") (EVar "stamp")) (EVar "rigidIds")) (EVar "omEmpty")) (EFieldAccess (EVar "lg") "lgWindow"))) (EBinOp "::" (EFieldAccess (EVar "lg") "lgGoal") (EApp (EApp (EApp (EApp (EVar "nestedRequireGoals") (EVar "stamp")) (EVar "rigidIds")) (EVar "omEmpty")) (EListLit (EFieldAccess (EVar "lg") "lgGoal")))))))) (DoExpr (EMatch (EVar "diags") (arm (PList) () (ETuple (EVar "found") (EVar "judged"))) (arm PWild () (ETuple (EBinOp "++" (EApp (EVar "reverseL") (EApp (EApp (EVar "map") (EApp (EApp (EVar "verdictFinding") (EFieldAccess (EVar "lg") "lgModule")) (EVar "True"))) (EVar "diags"))) (EVar "found")) (EApp (EApp (EApp (EVar "omInsert") (EVar "binding")) (ELit LUnit)) (EVar "judged")))))))) (arm PWild () (ETuple (EVar "found") (EVar "judged")))))))
(DTypeSig false "judgeQuiescentGoals" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "Unit"))))
(DFunDef false "judgeQuiescentGoals" ((PVar "mctx") PWild) (EBlock (DoLet false false (PVar "goals") (EApp (EVar "reverseL") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "quiescentGoalsRef") "value"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "quiescentGoalsRef")) (EListLit))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PTuple (PVar "rigidIds") (PVar "window") (PVar "o"))) (EApp (EApp (EVar "each") (EApp (EApp (EApp (EApp (EVar "undeterminedVectorVerdict") (EVar "mctx")) (EVar "rigidIds")) (EVar "omEmpty")) (EVar "window"))) (EBinOp "::" (EVar "o") (EApp (EApp (EApp (EApp (EVar "nestedRequireGoals") (EVar "mctx")) (EVar "rigidIds")) (EVar "omEmpty")) (EListLit (EVar "o"))))))) (EVar "goals")))))
(DTypeSig false "liveMemberIds" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "liveMemberIds" ((PVar "mctx") (PVar "monos")) (EBlock (DoLet false false (PVar "open") (EApp (EApp (EVar "filterList") (ELam ((PVar "m")) (EApp (EVar "isNonEmptyL") (EApp (EApp (EVar "liveVarIdsOf") (EVar "mctx")) (EVar "m"))))) (EBinOp "++" (EVar "monos") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "liveMemberMonosRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "liveMemberMonosRef")) (EVar "open"))) (DoExpr (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (EVar "intToString")) (EApp (EVar "dedupI") (EApp (EApp (EVar "flatMap") (EApp (EVar "liveVarIdsOf") (EVar "mctx"))) (EVar "open"))))) (EVar "omEmpty")))))
(DTypeSig false "liveVarIdsOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "liveVarIdsOf" ((PVar "mctx") (PVar "m")) (EApp (EApp (EVar "filterList") (ELam ((PVar "i")) (EApp (EVar "not") (EApp (EApp (EVar "IdMap.has") (EVar "i")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "deferrableVarIds") "value"))))) (EApp (EVar "monoUnboundIds") (EVar "m"))))
(DTypeSig false "userExternSchemes" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "TyConOrigin")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))
(DFunDef false "userExternSchemes" ((PVar "mctx") (PVar "scope") (PVar "decls")) (EApp (EApp (EVar "externSchemesGo") (EVar "mctx")) (EApp (EApp (EVar "stampTyOrigins") (EVar "scope")) (EApp (EVar "externDecls") (EVar "decls")))))
(DTypeSig true "externSchemesGo" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))
(DFunDef false "externSchemesGo" ((PVar "mctx") (PVar "decls")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "n") (PVar "ty"))) (ETuple (EVar "n") (EApp (EApp (EVar "sigToScheme") (EVar "mctx")) (EVar "ty"))))) (EApp (EVar "directExternSigs") (EVar "decls"))))
(DTypeSig false "sigsOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty")))))
(DFunDef false "sigsOf" ((PList)) (EListLit))
(DFunDef false "sigsOf" ((PCons (PCon "DTypeSig" PWild (PVar "n") (PVar "ty") PWild) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EVar "ty")) (EApp (EVar "sigsOf") (EVar "rest"))))
(DFunDef false "sigsOf" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "sigsOf") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "sigsOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "sigsOf") (EVar "rest")))
(DTypeSig false "registerImportOverlay" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "TcEnv")))))
(DFunDef false "registerImportOverlay" ((PVar "env") (PVar "prog") (PVar "overlay")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "seedParamPolarityFixpointScoped") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "overlay")) (EVar "overlay"))) (DoLet false false (PVar "ctorPop") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph") "crossRun") "universeCtorPop") "value")) (DoLet false false (PVar "recordPop") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph") "crossRun") "universeRecordPop") "value")) (DoLet false false (PVar "served") (EApp (EApp (EVar "map") (ELam ((PVar "d")) (ETuple (EVar "d") (EApp (EApp (EApp (EVar "overlayCachedRows") (EVar "ctorPop")) (EVar "recordPop")) (EVar "d"))))) (EVar "overlay"))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PVar "p")) (EMatch (EApp (EVar "snd") (EVar "p")) (arm (PCon "None") () (EApp (EApp (EVar "recordDeclKinds") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EVar "fst") (EVar "p")))) (arm (PCon "Some" PWild) () (ELit LUnit))))) (EVar "served"))) (DoLet false false (PVar "env1") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "e") (PVar "p")) (EIf (EApp (EVar "isAliasDecl") (EApp (EVar "fst") (EVar "p"))) (EApp (EApp (EVar "registerData") (EVar "e")) (EApp (EVar "fst") (EVar "p"))) (EVar "e")))) (EVar "env")) (EVar "served"))) (DoExpr (EApp (EApp (EVar "rejectCyclicAliases") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "prog"))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "e") (PVar "p")) (EMatch (EApp (EVar "snd") (EVar "p")) (arm (PCon "None") () (EIf (EApp (EVar "isAliasDecl") (EApp (EVar "fst") (EVar "p"))) (EVar "e") (EApp (EApp (EVar "registerData") (EVar "e")) (EApp (EVar "fst") (EVar "p"))))) (arm (PCon "Some" (PVar "rows")) () (EApp (EApp (EVar "registerCachedRows") (EVar "e")) (EVar "rows")))))) (EVar "env1")) (EVar "served")))))
(DTypeSig false "overlayCachedRows" (TyFun (TyApp (TyCon "SpellingPop") (TyCon "Scheme")) (TyFun (TyApp (TyCon "SpellingPop") (TyCon "RecordInfo")) (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "RecordInfo")))))))))
(DFunDef false "overlayCachedRows" ((PVar "ctorPop") (PVar "recordPop") (PRec "DData" ((rf "dataCtors" None) (rf "dataOrigin" None)) true)) (EApp (EApp (EApp (EApp (EVar "cachedVariantRows") (EVar "ctorPop")) (EVar "recordPop")) (EVar "dataOrigin")) (EVar "dataCtors")))
(DFunDef false "overlayCachedRows" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "cachedVariantRows" (TyFun (TyApp (TyCon "SpellingPop") (TyCon "Scheme")) (TyFun (TyApp (TyCon "SpellingPop") (TyCon "RecordInfo")) (TyFun (TyCon "TyConOrigin") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "RecordInfo"))))))))))
(DFunDef false "cachedVariantRows" (PWild PWild PWild (PList)) (EApp (EVar "Some") (ETuple (EListLit) (EListLit))))
(DFunDef false "cachedVariantRows" ((PVar "ctorPop") (PVar "recordPop") (PVar "o") (PCons (PCon "Variant" (PVar "cn") (PVar "payload")) (PVar "rest"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "mkIdent") (EVar "NsCtor")) (EVar "o")) (EVar "cn"))) (ELam ((PVar "ident")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "spLookupIdent") (EVar "ident")) (EVar "cn")) (EVar "ctorPop"))) (ELam ((PVar "s")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EVar "cachedRecordRow") (EVar "recordPop")) (EVar "ident")) (EVar "cn")) (EVar "payload"))) (ELam ((PVar "recs")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EVar "cachedVariantRows") (EVar "ctorPop")) (EVar "recordPop")) (EVar "o")) (EVar "rest"))) (ELam ((PVar "later")) (EApp (EVar "Some") (ETuple (EBinOp "::" (ETuple (EVar "cn") (EVar "s")) (EApp (EVar "fst") (EVar "later"))) (EBinOp "++" (EVar "recs") (EApp (EVar "snd") (EVar "later"))))))))))))))
(DTypeSig false "cachedRecordRow" (TyFun (TyApp (TyCon "SpellingPop") (TyCon "RecordInfo")) (TyFun (TyCon "Ident") (TyFun (TyCon "String") (TyFun (TyCon "ConPayload") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "RecordInfo")))))))))
(DFunDef false "cachedRecordRow" ((PVar "recordPop") (PVar "ident") (PVar "cn") (PCon "ConNamed" PWild PWild)) (EApp (EApp (EVar "map") (ELam ((PVar "ri")) (EListLit (ETuple (EVar "cn") (EVar "ri"))))) (EApp (EApp (EApp (EVar "spLookupIdent") (EVar "ident")) (EVar "cn")) (EVar "recordPop"))))
(DFunDef false "cachedRecordRow" (PWild PWild PWild PWild) (EApp (EVar "Some") (EListLit)))
(DTypeSig false "registerCachedRows" (TyFun (TyCon "TcEnv") (TyFun (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "RecordInfo")))) (TyCon "TcEnv"))))
(DFunDef false "registerCachedRows" ((PVar "env") (PTuple (PVar "ctors") (PVar "recs"))) (EBlock (DoExpr (EApp (EApp (EVar "each") (ELam ((PVar "r")) (EApp (EApp (EApp (EVar "registerCachedRecord") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EVar "fst") (EVar "r"))) (EApp (EVar "snd") (EVar "r"))))) (EVar "recs"))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "e") (PVar "c")) (EApp (EApp (EApp (EVar "addCtor") (EVar "e")) (EApp (EVar "fst") (EVar "c"))) (EApp (EVar "snd") (EVar "c"))))) (EVar "env")) (EVar "ctors")))))
(DTypeSig false "registerCachedRecord" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "RecordInfo") (TyCon "Unit")))))
(DFunDef false "registerCachedRecord" ((PVar "mctx") (PVar "key") (PVar "ri")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "recordByNameRef")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "ri")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "recordByNameRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fieldOwnersRef")) (EApp (EApp (EApp (EVar "addFieldOwners") (EVar "key")) (EApp (EVar "recordFieldNames") (EVar "ri"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fieldOwnersRef") "value"))))))
(DTypeSig false "sigNamesToSet" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "sigNamesToSet" ((PList) (PVar "m")) (EVar "m"))
(DFunDef false "sigNamesToSet" ((PCons (PTuple (PVar "n") PWild) (PVar "rest")) (PVar "m")) (EApp (EApp (EVar "sigNamesToSet") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "m"))))
(DTypeSig false "processTopGroups" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))))))
(DFunDef false "processTopGroups" ((PVar "env") (PVar "sigs") (PVar "defs") (PVar "names") (PVar "exported")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "sigNameSetRef")) (EApp (EApp (EVar "sigNamesToSet") (EVar "sigs")) (EVar "omEmpty")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "sigTyMapRef")) (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "sigs"))) (EVar "omEmpty")))) (DoLet false false (PVar "grouped") (EApp (EVar "groupClauses") (EVar "defs"))) (DoLet false false (PVar "ordered") (EApp (EApp (EVar "tarjanSCCs") (EVar "names")) (EApp (EApp (EVar "depGraphMap") (EVar "names")) (EVar "grouped")))) (DoLet false false (PVar "result") (EApp (EApp (EApp (EApp (EVar "processSCCs") (EVar "env")) (EVar "sigs")) (EVar "grouped")) (EVar "ordered"))) (DoExpr (EApp (EApp (EVar "resolvePendingJoins") (EFieldAccess (EVar "env") "teDyn")) (ELit (LInt 0)))) (DoLet false false (PVar "failures") (EApp (EApp (EApp (EApp (EVar "EffectSolver.closeRootAuthorities") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "effectSummaries")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "rigidAuthvarsRef") "value")) (EApp (EApp (EVar "exportedRootCells") (EVar "exported")) (EApp (EVar "fst") (EVar "result")))) (EApp (EVar "widenOpenedFor") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")))) (DoLet false false (PVar "unsolved") (EApp (EApp (EVar "rootCellsOf") (EVar "exported")) (EApp (EVar "fst") (EVar "result")))) (DoLet false false (PVar "unsolvedIds") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PTuple PWild (PVar "ids"))) (EApp (EApp (EVar "IdMap.union") (EVar "acc")) (EVar "ids")))) (EVar "Tip")) (EVar "unsolved"))) (DoExpr (EApp (EApp (EVar "reportEffectSummaryFailures") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EApp (EVar "filterList") (ELam ((PVar "f")) (EApp (EVar "not") (EApp (EApp (EVar "failureMentions") (EVar "unsolvedIds")) (EVar "f"))))) (EVar "failures")))) (DoLet false false PWild (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "seen") (PVar "u")) (EApp (EApp (EApp (EApp (EVar "reportUnsolvedExport") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "grouped")) (EVar "seen")) (EVar "u")))) (EVar "Tip")) (EVar "unsolved"))) (DoExpr (EVar "result"))))
(DTypeSig false "exportedRootCells" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "exportedRootCells" ((PVar "exported") (PVar "schemes")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PTuple PWild (PVar "ids"))) (EApp (EApp (EVar "IdMap.union") (EVar "acc")) (EVar "ids")))) (EVar "Tip")) (EApp (EApp (EVar "rootCellsOf") (EVar "exported")) (EVar "schemes"))))
(DTypeSig false "rootCellsOf" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))))
(DFunDef false "rootCellsOf" ((PVar "exported") (PVar "schemes")) (EApp (EApp (EVar "flatMap") (ELam ((PTuple (PVar "name") (PVar "scheme"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "exported")) (EMatch (EApp (EVar "unquantifiedAuthIds") (EVar "scheme")) (arm (PCon "Tip") () (EListLit)) (arm (PVar "ids") () (EListLit (ETuple (EVar "name") (EVar "ids"))))) (EListLit)))) (EVar "schemes")))
(DTypeSig false "failureMentions" (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyCon "SummaryFailure") (TyCon "ObligationSite")) (TyCon "Bool"))))
(DFunDef false "failureMentions" ((PCon "Tip") PWild) (EVar "False"))
(DFunDef false "failureMentions" ((PVar "ids") (PVar "failure")) (EMatch (EFieldAccess (EVar "failure") "esfAuthority") (arm (PCon "Some" (PTuple (PVar "lo") (PVar "hi"))) () (EApp (EApp (EVar "anyList") (ELam ((PVar "c")) (EApp (EApp (EVar "IdMap.has") (EApp (EVar "authvarId") (EVar "c"))) (EVar "ids")))) (EBinOp "++" (EApp (EVar "authVars") (EVar "lo")) (EApp (EVar "authVars") (EVar "hi"))))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "reportUnsolvedExport" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyTuple (TyCon "String") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))))
(DFunDef false "reportUnsolvedExport" ((PVar "mctx") (PVar "grouped") (PVar "seen") (PTuple (PVar "name") (PVar "ids"))) (EIf (EApp (EApp (EApp (EVar "IdMap.foldlWithKey") (ELam ((PVar "acc") (PVar "id") PWild) (EBinOp "&&" (EVar "acc") (EApp (EApp (EVar "IdMap.has") (EVar "id")) (EVar "seen"))))) (EVar "True")) (EVar "ids")) (EVar "seen") (EBlock (DoLet false false (PVar "loc") (EMatch (EApp (EApp (EVar "clausesOf") (EVar "name")) (EVar "grouped")) (arm (PCons (PTuple PWild (PVar "body")) PWild) () (EApp (EVar "firstExprLoc") (EVar "body"))) (arm (PList) () (EVar "None")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (EVar "TExportUnsolvedAuthority")) (EVar "loc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "exported binding `")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` has an authority in its type that nothing in this module determines; give `"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "`, or the value it uses, a type signature that names the authority"))))) (DoExpr (EApp (EApp (EVar "IdMap.union") (EVar "seen")) (EVar "ids"))))))
(DTypeSig false "processSCCs" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))))))
(DFunDef false "processSCCs" ((PVar "env") PWild (PVar "grouped") (PList)) (ETuple (EListLit) (EVar "grouped")))
(DFunDef false "processSCCs" ((PVar "env") (PVar "sigs") (PVar "grouped") (PCons (PVar "scc") (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "env2") (PVar "schemes") (PVar "grouped2")) (EApp (EApp (EApp (EApp (EVar "processSCC") (EVar "env")) (EVar "sigs")) (EVar "grouped")) (EVar "scc"))) (DoLet false false (PTuple (PVar "restSchemes") (PVar "grouped3")) (EApp (EApp (EApp (EApp (EVar "processSCCs") (EVar "env2")) (EVar "sigs")) (EVar "grouped2")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "++" (EVar "schemes") (EVar "restSchemes")) (EVar "grouped3")))))
(DTypeSig false "processSCC" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyCon "TcEnv") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))))))
(DFunDef false "processSCC" ((PVar "outer") (PVar "sigs") (PVar "grouped0") (PVar "members")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EVar "envAtIfSome") (EApp (EApp (EVar "membersSpanLoc") (EVar "grouped0")) (EVar "members"))) (EVar "outer"))) (DoLet false false (PVar "marking") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "markingRef") "value")) (DoLet false false (PVar "grouped") (EMatch (EVar "marking") (arm (PCon "Some" (PVar "mm")) () (EApp (EApp (EApp (EApp (EVar "markGroupClauses") (EVar "mm")) (EVar "env")) (EVar "members")) (EVar "grouped0"))) (arm (PCon "None") () (EVar "grouped0")))) (DoLet false false (PVar "groupedStamped") (EMatch (EVar "marking") (arm (PCon "Some" (PVar "mm")) () (EApp (EApp (EApp (EVar "stampGroupClauses") (EVar "mm")) (EVar "members")) (EVar "grouped"))) (arm (PCon "None") () (EVar "grouped")))) (DoExpr (EApp (EApp (EVar "enterLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "beginEffectSummaryScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "oblN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls"))) (DoLet false false (PVar "callN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "obls"))) (DoLet false false (PVar "dictN0") (EApp (EApp (EVar "goalsMark") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (DoLet false false (PVar "placeholders") (EApp (EApp (EVar "map") (ELam ((PVar "m")) (ETuple (EVar "m") (EApp (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))))) (EVar "members"))) (DoLet false false (PVar "scopedMembers") (EApp (EApp (EApp (EApp (EVar "scopeMembers") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EApp (EVar "captureScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (EVar "groupedStamped")) (EVar "placeholders"))) (DoLet false false (PTuple (PVar "regs") (PVar "sigTvMaps")) (EApp (EApp (EApp (EVar "preunifySigsEx") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "sigs")) (EVar "scopedMembers"))) (DoLet false false (PVar "savedRigidEffects") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "rigidEffvarsRef") "value")) (DoLet false false (PVar "savedRigidAuths") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "rigidAuthvarsRef") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "rigidEffvarsRef")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "roots") (PVar "member")) (EApp (EApp (EApp (EVar "IdMap.foldlWithKey") (ELam ((PVar "acc") (PVar "id") PWild) (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (ELit LUnit)) (EVar "acc")))) (EVar "roots")) (EFieldAccess (EFieldAccess (EVar "member") "smDeclaredRoots") "value")))) (EVar "savedRigidEffects")) (EVar "scopedMembers")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "rigidAuthvarsRef")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "roots") (PVar "member")) (EApp (EApp (EApp (EVar "IdMap.foldlWithKey") (ELam ((PVar "acc") (PVar "id") PWild) (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (ELit LUnit)) (EVar "acc")))) (EVar "roots")) (EFieldAccess (EFieldAccess (EVar "member") "smDeclaredAuths") "value")))) (EVar "savedRigidAuths")) (EVar "scopedMembers")))) (DoLet false false (PVar "env2") (EApp (EApp (EVar "extendBindings") (EVar "env")) (EApp (EApp (EVar "map") (EVar "scopedMemberBinding")) (EVar "scopedMembers")))) (DoLet false false (PVar "groupCtx") (ERecordCreate "GroupCtx" ((fa "gcMonos" (EApp (EApp (EVar "flatMap") (ELam ((PVar "r")) (EApp (EApp (EVar "flatMap") (EVar "ifaceMonoName")) (EApp (EVar "regIfaceMonosOf") (EVar "r"))))) (EVar "regs"))) (fa "gcPendingEscapes" (EApp (EVar "Ref") (EListLit)))))) (DoLet false false (PVar "groupEnv") (ERecordUpdate (EVar "env2") ((fa "teDyn" (ERecordUpdate (EFieldAccess (EVar "env2") "teDyn") ((fa "dcGroup" (EApp (EVar "Some") (EVar "groupCtx"))))))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "inferMembers") (EVar "groupEnv")) (EVar "sigs")) (EVar "groupedStamped")) (EVar "scopedMembers"))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PVar "member")) (EApp (EApp (EVar "checkRecursiveValue") (EFieldAccess (EVar "env") "teDyn")) (EFieldAccess (EVar "member") "smOwned")))) (EVar "scopedMembers"))) (DoExpr (EApp (EApp (EVar "resolvePendingJoins") (EFieldAccess (EVar "env") "teDyn")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentLevel") "value"))) (DoLet false false (PVar "residuals") (EApp (EApp (EApp (EApp (EVar "finishEffectSummaryScopeKeeping") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EApp (EApp (EVar "quantifiableAuthorities") (EVar "env2")) (EVar "groupedStamped")) (EVar "scopedMembers"))) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "member")) (EApp (EApp (EVar "memberEffectRoots") (EVar "member")) (EVar "acc")))) (EVar "Tip")) (EVar "scopedMembers"))) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "member")) (EApp (EApp (EApp (EVar "borrowedEffectCells") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EFieldAccess (EVar "member") "smOwned") "bsValue")) (EVar "acc")))) (EVar "Tip")) (EVar "scopedMembers")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "rigidEffvarsRef")) (EVar "savedRigidEffects"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "rigidAuthvarsRef")) (EVar "savedRigidAuths"))) (DoExpr (EApp (EApp (EVar "checkSigsTooGeneral") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "sigTvMaps"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkSigsFixedByExpansive") (EVar "env2")) (EVar "groupedStamped")) (EVar "scopedMembers")) (EVar "sigTvMaps"))) (DoExpr (EApp (EApp (EVar "registerConstraintRegs") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "regs"))) (DoExpr (EApp (EApp (EVar "flushPendingEscapes") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EVar "Some") (EVar "groupCtx")))) (DoExpr (EApp (EApp (EVar "exitLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "protectedSigIds") (EApp (EVar "sccProtectedSignatureIds") (EVar "sigTvMaps"))) (DoLet false false (PVar "addedObls") (EApp (EApp (EVar "wWindow") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls")) (EVar "oblN0"))) (DoLet false false (PVar "groupObls") (EBinOp "++" (EVar "addedObls") (EApp (EApp (EVar "callUOblsWindow") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "callN0")))) (DoLet false false (PVar "unownedIds") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (EVar "intToString")) (EApp (EApp (EVar "flatMap") (EVar "monoArgUnboundIds")) (EApp (EApp (EVar "map") (EVar "snd")) (EVar "placeholders"))))) (EVar "protectedSigIds"))) (DoExpr (EApp (EApp (EApp (EVar "improveByUniqueImpl") (EFieldAccess (EVar "env") "teDyn")) (EVar "protectedSigIds")) (EVar "addedObls"))) (DoExpr (EApp (EApp (EApp (EVar "improveByUniqueImpl") (EFieldAccess (EVar "env") "teDyn")) (EVar "protectedSigIds")) (EApp (EApp (EVar "callUOblsWindow") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "callN0")))) (DoExpr (EApp (EApp (EApp (EVar "determineByUniqueInstance") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "unownedIds")) (EVar "groupObls"))) (DoLet false false (PVar "defaultObls") (EBinOp "++" (EVar "addedObls") (EApp (EApp (EApp (EVar "calleeNumObls") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "callN0")) (EVar "dictN0")))) (DoLet false false (PVar "sccGuard") (ERecordCreate "NumGuard" ((fa "ngGoals" (EVar "groupObls")) (fa "ngRigidIds" (EVar "protectedSigIds")) (fa "ngOuterBelow" (EVar "None"))))) (DoLet false false (PVar "withheld") (EApp (EApp (EVar "finalizeNumBoundary") (EFieldAccess (EVar "env") "teDyn")) (ERecordCreate "NumBoundary" ((fa "nbDisposition" (EApp (EVar "NumBoundaryOwnedScc") (EBinOp "+" (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentLevel") "value") (ELit (LInt 1))))) (fa "nbMembers" (EApp (EApp (EVar "map") (EVar "snd")) (EVar "placeholders"))) (fa "nbSurvivingIds" (EApp (EApp (EApp (EApp (EVar "tiedSurvivors") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EApp (EApp (EVar "map") (EVar "snd")) (EVar "placeholders"))) (EVar "sccGuard")) (EVar "protectedSigIds"))) (fa "nbDefaultObls" (EVar "defaultObls")) (fa "nbAmbiguityObls" (EVar "addedObls")) (fa "nbGuard" (EVar "sccGuard")))))) (DoExpr (EApp (EApp (EApp (EVar "improveByUniqueImpl") (EFieldAccess (EVar "env") "teDyn")) (EVar "protectedSigIds")) (EVar "groupObls"))) (DoExpr (EApp (EApp (EApp (EVar "determineByUniqueInstance") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "unownedIds")) (EVar "groupObls"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "checkSigVarGoals") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "DeclaredBySignature")) (EVar "protectedSigIds")) (EVar "sigTvMaps")) (EVar "groupObls"))) (DoLet false false (PVar "schemes") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "sccSchemes") (EVar "env2")) (EVar "sigs")) (EVar "groupedStamped")) (EApp (EVar "isLetrecGroup") (EVar "members"))) (EVar "residuals")) (ELit (LInt 0))) (EVar "scopedMembers"))) (DoLet false false (PVar "scopedSchemes") (EApp (EApp (EVar "alignScopedSchemes") (EVar "scopedMembers")) (EVar "schemes"))) (DoExpr (EApp (EApp (EApp (EVar "checkSigsOverExpansive") (EVar "env2")) (EVar "groupedStamped")) (EVar "sigTvMaps"))) (DoLet false false (PVar "callOblsDelta") (EApp (EApp (EVar "callOblsWindow") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "callN0"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerSchemeObligations") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "schemeDefIdsRef") "value")) (EVar "sigTvMaps")) (EVar "callOblsDelta")) (EVar "addedObls")) (EVar "schemes"))) (DoLet false false (PVar "liveIds") (EApp (EApp (EVar "liveMemberIds") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EApp (EVar "map") (EVar "snd")) (EVar "placeholders")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "rejectUndeterminedVectors") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "unownedIds")) (EVar "liveIds")) (EVar "addedObls")) (EBinOp "++" (EApp (EApp (EVar "callUOblsWindow") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "callN0")) (EApp (EApp (EApp (EApp (EVar "nestedRequireGoals") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "unownedIds")) (EVar "liveIds")) (EVar "groupObls"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "rejectWithheldAmbiguity") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "unownedIds")) (EVar "withheld")) (EVar "groupObls"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkSigConstraintCoverage") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "regs")) (EVar "sigs")) (EVar "sigTvMaps")) (EVar "callOblsDelta")) (EVar "addedObls")) (EVar "schemes"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "registerInferredConstraints") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "sigs")) (EVar "callOblsDelta")) (EVar "addedObls")) (EVar "scopedSchemes"))) (DoExpr (EApp (EApp (EVar "declareRigidVars") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EVar "omKeys") (EVar "protectedSigIds")))) (DoLet false false (PVar "groupedOut") (EMatch (EVar "marking") (arm (PCon "Some" (PVar "mm")) () (EApp (EApp (EApp (EApp (EApp (EVar "markRecursiveOccurrences") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "mm")) (EVar "placeholders")) (EVar "scopedMembers")) (EVar "grouped"))) (arm (PCon "None") () (EVar "grouped")))) (DoExpr (EMatch (EVar "marking") (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EApp (EVar "recordTopGrants") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentModuleRef") "value")) (EVar "schemes")) (EVar "groupedOut"))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (ETuple (EApp (EApp (EVar "extendTermBindings") (EVar "outer")) (EVar "schemes")) (EVar "schemes") (EVar "groupedOut")))))
(DTypeSig false "scopedMemberBinding" (TyFun (TyCon "ScopedMember") (TyTuple (TyCon "String") (TyCon "EnvBinding"))))
(DFunDef false "scopedMemberBinding" ((PVar "member")) (EBlock (DoLet false false (PVar "binding") (EApp (EApp (EVar "optionOr") (EApp (EVar "ordinaryEnvBinding") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Forall") (EListLit)) (EListLit)) (EListLit)) (EListLit)) (EApp (EVar "memberForce") (EVar "member"))) (EFieldAccess (EFieldAccess (EVar "member") "smOwned") "bsRecursiveValue")))) (EFieldAccess (EFieldAccess (EVar "member") "smRecursive") "value"))) (DoExpr (ETuple (EFieldAccess (EVar "member") "smName") (EApp (EApp (EVar "bindingWithStandalone") (EVar "binding")) (ETuple (EVar "LocalStandalone") (EFieldAccess (EVar "binding") "ebValue")))))))
(DTypeSig false "scopeMembers" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "ScopedMember")))))))
(DFunDef false "scopeMembers" ((PVar "mctx") PWild PWild (PList)) (EListLit))
(DFunDef false "scopeMembers" ((PVar "mctx") (PVar "parent") (PVar "grouped") (PCons (PTuple (PVar "name") (PVar "mono")) (PVar "rest"))) (EBlock (DoLet false false (PVar "sid") (EApp (EApp (EApp (EApp (EApp (EVar "Scopes.freshScope") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EApp (EVar "Some") (EVar "parent"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (EFieldAccess (EApp (EApp (EVar "Scopes.scopeFrame") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EVar "parent")) "sfModuleId")) (EApp (EVar "BindingOwner") (EVar "name")))) (DoLet false false (PVar "clauses") (EApp (EApp (EVar "clausesOf") (EVar "name")) (EVar "grouped"))) (DoLet false false (PVar "arity") (EMatch (EVar "clauses") (arm (PCons (PTuple (PVar "pats") PWild) PWild) () (EApp (EVar "listLen") (EVar "pats"))) (arm (PList) () (ELit (LInt 0))))) (DoLet false false (PVar "owned") (EApp (EApp (EApp (EVar "newBindingSummary") (EVar "arity")) (EApp (EVar "freshVar") (EVar "mctx"))) (EApp (EVar "freshEffectSummary") (EVar "mctx")))) (DoLet false false (PVar "force") (EMatch (EVar "clauses") (arm (PList (PTuple (PList) PWild)) () (EApp (EVar "Some") (EFieldAccess (EVar "owned") "bsForce"))) (arm PWild () (EVar "None")))) (DoExpr (EBinOp "::" (ERecordCreate "ScopedMember" ((fa "smName" (EVar "name")) (fa "smMono" (EVar "mono")) (fa "smOwned" (EVar "owned")) (fa "smDeclaredRoots" (EApp (EVar "Ref") (EVar "Tip"))) (fa "smDeclaredAuths" (EApp (EVar "Ref") (EVar "Tip"))) (fa "smSigned" (EApp (EVar "Ref") (EVar "False"))) (fa "smRecursive" (EApp (EVar "Ref") (EVar "None"))) (fa "smForce" (EVar "force")) (fa "smForceBound" (EApp (EVar "Ref") (EVar "None"))) (fa "smScope" (EVar "sid")))) (EApp (EApp (EApp (EApp (EVar "scopeMembers") (EVar "mctx")) (EVar "parent")) (EVar "grouped")) (EVar "rest"))))))
(DTypeSig false "alignScopedSchemes" (TyFun (TyApp (TyCon "List") (TyCon "ScopedMember")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyCon "ScopedScheme")))))
(DFunDef false "alignScopedSchemes" ((PList) (PList)) (EListLit))
(DFunDef false "alignScopedSchemes" ((PCons (PVar "member") (PVar "members")) (PCons (PTuple (PVar "name") (PVar "scheme")) (PVar "schemes"))) (EIf (EBinOp "==" (EFieldAccess (EVar "member") "smName") (EVar "name")) (EBinOp "::" (ERecordCreate "ScopedScheme" ((fa "ssName" (EVar "name")) (fa "ssScheme" (EVar "scheme")) (fa "ssScope" (EFieldAccess (EVar "member") "smScope")))) (EApp (EApp (EVar "alignScopedSchemes") (EVar "members")) (EVar "schemes"))) (EIf (EVar "otherwise") (EApp (EVar "panic") (ELit (LString "scope/member scheme alignment mismatch"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "alignScopedSchemes" (PWild PWild) (EApp (EVar "panic") (ELit (LString "scope/member scheme arity mismatch"))))
(DTypeSig false "inferMembers" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyCon "ScopedMember")) (TyCon "Unit"))))))
(DFunDef false "inferMembers" ((PVar "env") PWild PWild (PList)) (ELit LUnit))
(DFunDef false "inferMembers" ((PVar "outer") (PVar "sigs") (PVar "grouped") (PCons (PVar "member") (PVar "rest"))) (EBlock (DoLet false false (PVar "m") (EFieldAccess (EVar "member") "smName")) (DoLet false false (PVar "env") (EApp (EApp (EVar "envAtIfSome") (EApp (EApp (EVar "membersSpanLoc") (EVar "grouped")) (EListLit (EVar "m")))) (EVar "outer"))) (DoLet false false (PVar "v") (EFieldAccess (EVar "member") "smMono")) (DoExpr (EApp (EApp (EVar "openScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EVar "member") "smScope"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentFn")) (EVar "m"))) (DoLet false false (PVar "peel") (EApp (EApp (EApp (EApp (EVar "memberPeelSource") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "sigs")) (EVar "m")) (EVar "v"))) (DoLet false false (PVar "effs") (EApp (EApp (EApp (EApp (EVar "inferMemberClauses") (EVar "env")) (EVar "peel")) (EFieldAccess (EVar "member") "smOwned")) (EApp (EApp (EVar "clausesOf") (EVar "m")) (EVar "grouped")))) (DoExpr (EIf (EFieldAccess (EFieldAccess (EVar "member") "smSigned") "value") (EApp (EApp (EApp (EApp (EVar "unifyInto") (EApp (EApp (EVar "dynAtIfSome") (EApp (EVar "joinLocs") (EApp (EApp (EApp (EVar "clauseSpans") (EVar "valueSpanLoc")) (EVar "grouped")) (EListLit (EVar "m"))))) (EFieldAccess (EVar "env") "teDyn"))) (EVar "True")) (EFieldAccess (EVar "member") "smMono")) (EFieldAccess (EFieldAccess (EVar "member") "smOwned") "bsValue")) (ELit LUnit))) (DoExpr (EMatch (EFieldAccess (EFieldAccess (EVar "member") "smForceBound") "value") (arm (PCon "Some" (PVar "bound")) () (EBlock (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "cl")) (EApp (EApp (EApp (EVar "recordFileBound") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EVar "snd") (EVar "cl"))) (EVar "bound")))) (ELit LUnit)) (EApp (EApp (EVar "clausesOf") (EVar "m")) (EVar "grouped")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "rowInto") (EFieldAccess (EVar "env") "teDyn")) (EVar "True")) (EApp (EVar "effrowNorm") (EVar "bound"))) (EApp (EVar "effrowNorm") (EApp (EApp (EVar "optionOr") (EVar "pureRow")) (EFieldAccess (EVar "member") "smForce"))))))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentFn")) (ELit (LString "")))) (DoExpr (EApp (EApp (EVar "closeScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoExpr (EMatch (EFieldAccess (EVar "member") "smForce") (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "checkEffectEscape") (EFieldAccess (EVar "env") "teDyn")) (EVar "sigs")) (EVar "m")) (EVar "effs"))) (arm (PCon "Some" PWild) () (ELit LUnit)))) (DoExpr (EApp (EApp (EApp (EApp (EVar "inferMembers") (EVar "outer")) (EVar "sigs")) (EVar "grouped")) (EVar "rest")))))
(DTypeSig false "membersSpanLoc" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "membersSpanLoc" ((PVar "grouped") (PVar "names")) (EApp (EVar "joinLocs") (EApp (EApp (EApp (EVar "clauseSpans") (EVar "exprSpanLoc")) (EVar "grouped")) (EVar "names"))))
(DTypeSig false "clauseSpans" (TyFun (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Loc"))))))
(DFunDef false "clauseSpans" ((PVar "span") (PVar "grouped") (PVar "names")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "m")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "cl")) (EApp (EApp (EApp (EVar "option") (EListLit)) (ELam ((PVar "l")) (EListLit (EVar "l")))) (EApp (EVar "span") (EApp (EVar "snd") (EVar "cl")))))) (EApp (EApp (EVar "clausesOf") (EVar "m")) (EVar "grouped"))))) (EVar "names")))
(DTypeSig false "memberPeelSource" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "Mono")))))))
(DFunDef false "memberPeelSource" ((PVar "mctx") (PVar "sigs") (PVar "m") (PVar "v")) (EApp (EApp (EVar "map") (ELam (PWild) (EVar "v"))) (EApp (EApp (EVar "omLookup") (EVar "m")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "sigNameSetRef") "value"))))
(DTypeSig false "regIfaceMonosOf" (TyFun (TyCon "ConstraintReg") (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))))))
(DFunDef false "regIfaceMonosOf" ((PVar "reg")) (EFieldAccess (EVar "reg") "crIfaceMonos"))
(DTypeSig false "ifaceMonoName" (TyFun (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))))
(DFunDef false "ifaceMonoName" ((PTuple (PVar "ir") (PVar "monos"))) (EApp (EApp (EVar "map") (ELam ((PVar "mono")) (ETuple (EFieldAccess (EVar "ir") "irName") (EVar "mono")))) (EVar "monos")))
(DTypeSig true "checkModuleFull" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "ModuleBindings") (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "ModuleCtx")))))))
(DFunDef false "checkModuleFull" ((PVar "prev") (PVar "seedVars") (PVar "accData") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkModuleFullImpl") (EFieldAccess (EVar "prev") "mcGraph")) (EApp (EVar "checkRunResidue") (EVar "prev"))) (ELit (LString ""))) (EApp (EVar "plainModuleSeed") (EVar "seedVars"))) (EVar "accData")) (EVar "prog")) (EVar "prog")))
(DTypeSig false "checkModuleFullImpl" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "CheckRunSeed") (TyFun (TyCon "String") (TyFun (TyCon "ModuleSeed") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "ModuleBindings") (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "ModuleCtx"))))))))))
(DFunDef false "checkModuleFullImpl" ((PVar "gctx") (PVar "runSeed") (PVar "mid") (PVar "seedVars") (PVar "_accData") (PVar "implDecls") (PVar "prog")) (EBlock (DoLet false false (PTuple (PVar "schemes") (PVar "marked") (PVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkBodyImpl") (EVar "gctx")) (EVar "runSeed")) (EVar "seedVars")) (EVar "mid")) (EVar "implDecls")) (EVar "prog"))) (DoExpr (EApp (EApp (EApp (EVar "enqueueStampCtx") (EVar "mctx")) (EVar "mid")) (EVar "implDecls"))) (DoExpr (ETuple (EVar "schemes") (EVar "marked") (EVar "mctx")))))
(DTypeSig true "publicValNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "publicValNames" ((PList)) (EListLit))
(DFunDef false "publicValNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "publicValNames") (EListLit (EVar "d"))) (EApp (EVar "publicValNames") (EVar "rest"))))
(DFunDef false "publicValNames" ((PCons (PCon "DFunDef" (PCon "True") (PVar "n") PWild PWild PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "publicValNames") (EVar "rest"))))
(DFunDef false "publicValNames" ((PCons (PCon "DTypeSig" (PCon "True") (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "publicValNames") (EVar "rest"))))
(DFunDef false "publicValNames" ((PCons (PCon "DExtern" (PRec "ExternDecl" ((rf "edPub" (PCon "True")) (rf "edName" (PVar "n"))) true)) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "publicValNames") (EVar "rest"))))
(DFunDef false "publicValNames" ((PCons (PRec "DInterface" ((rf "pub" (PCon "True")) (rf "methods" None)) true) (PVar "rest"))) (EBinOp "++" (EApp (EVar "ifaceMethodNames") (EVar "methods")) (EApp (EVar "publicValNames") (EVar "rest"))))
(DFunDef false "publicValNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "publicValNames") (EVar "rest")))
(DTypeSig false "appendUniverseAccums" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))))
(DFunDef false "appendUniverseAccums" ((PVar "gctx") (PVar "mid") (PVar "prog")) (EBlock (DoExpr (EIf (EApp (EVar "isPreludeMid") (EVar "mid")) (ELit LUnit) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "universeFunNamesRef")) (EApp (EApp (EVar "namesToSet") (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "funDefs") (EVar "prog")))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "universeFunNamesRef") "value"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "universeMethodDispatchIdxByIdRef")) (EBinOp "++" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "universeMethodDispatchIdxByIdRef") "value") (EApp (EVar "argDispatchIndicesById") (EVar "prog"))))) (DoExpr (ELit LUnit))))
(DTypeSig false "appendDataUniverse" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))))
(DFunDef false "appendDataUniverse" ((PVar "mctx") (PVar "mid") (PVar "prog0")) (EBlock (DoLet false false (PVar "pubDecls") (EApp (EVar "publicDataDecls") (EVar "prog0"))) (DoExpr (EApp (EApp (EVar "loadDataUniverse") (EVar "mctx")) (EApp (EApp (EVar "declEnvsOrdOf") (EVar "mid")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "declEnvsRef") "value")))) (DoLet false false (PVar "env2") (EApp (EApp (EApp (EVar "registerAllDataScoped") (EApp (EApp (EVar "withCtors") (EVar "mctx")) (EApp (EVar "spFloor") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "crossRun") "universeCtorPop") "value")))) (EApp (EVar "publicDataScopeDecls") (EVar "prog0"))) (EVar "prog0"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "crossRun") "universeCtorPop")) (EApp (EApp (EApp (EVar "insertCtorPop") (EVar "env2")) (EVar "pubDecls")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "crossRun") "universeCtorPop") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "crossRun") "universeRecordPop")) (EApp (EApp (EApp (EVar "insertRecordPop") (EVar "mctx")) (EVar "pubDecls")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "crossRun") "universeRecordPop") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "ownPopsRef")) (ETuple (EApp (EApp (EApp (EVar "insertCtorPop") (EVar "env2")) (EVar "pubDecls")) (EVar "spEmpty")) (EApp (EApp (EApp (EVar "insertRecordPop") (EVar "mctx")) (EVar "pubDecls")) (EVar "spEmpty")))))))
(DTypeSig false "publicDataScopeDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "publicDataScopeDecls" ((PVar "prog0")) (EApp (EApp (EVar "filterList") (ELam ((PVar "d")) (EBinOp "||" (EApp (EVar "publicDataDecl") (EVar "d")) (EApp (EVar "isAliasDecl") (EVar "d"))))) (EVar "prog0")))
(DTypeSig false "importedMethodBindingNames" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "importedMethodBindingNames" ((PVar "gctx") (PVar "prog") (PVar "aliases")) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "snd")) (EApp (EApp (EVar "nameableIfaceRows") (EVar "gctx")) (EVar "prog"))) (EApp (EVar "importedMemberBindingNames") (EVar "prog"))) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "aliases"))))
(DTypeSig false "importedSchemeOblEntries" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "VecObl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "VecObl")))))))
(DFunDef false "importedSchemeOblEntries" ((PList) PWild) (EListLit))
(DFunDef false "importedSchemeOblEntries" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "qual")) (EBinOp "++" (EApp (EApp (EVar "importedSchemeOblEntries") (EListLit (EVar "d"))) (EVar "qual")) (EApp (EApp (EVar "importedSchemeOblEntries") (EVar "rest")) (EVar "qual"))))
(DFunDef false "importedSchemeOblEntries" ((PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest")) (PVar "qual")) (EBinOp "++" (EApp (EApp (EApp (EVar "schemeOblEntriesFor") (EApp (EVar "importTableMid") (EVar "path"))) (EVar "path")) (EVar "qual")) (EApp (EApp (EVar "importedSchemeOblEntries") (EVar "rest")) (EVar "qual"))))
(DFunDef false "importedSchemeOblEntries" ((PCons PWild (PVar "rest")) (PVar "qual")) (EApp (EApp (EVar "importedSchemeOblEntries") (EVar "rest")) (EVar "qual")))
(DTypeSig false "reportAmbiguousImports" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "reportAmbiguousImports" ((PVar "mctx") (PVar "prog0")) (EApp (EApp (EApp (EVar "reportAmbiguousImportsIn") (EVar "mctx")) (EApp (EVar "moduleRefNameSet") (EVar "prog0"))) (EVar "prog0")))
(DTypeSig false "moduleRefNameSet" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))
(DFunDef false "moduleRefNameSet" ((PVar "decls")) (EApp (EApp (EVar "namesToSet") (EApp (EApp (EVar "flatMap") (EVar "declRefNames")) (EVar "decls"))) (EVar "omEmpty")))
(DTypeSig false "importedCtorTypeDeclsFirstWins" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "importedCtorTypeDeclsFirstWins" ((PVar "unitDecls") (PVar "cur") (PVar "rows")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "overlayHalf") (EVar "False")) (EVar "unitDecls")) (EVar "cur")) (EVar "rows")) (EApp (EApp (EApp (EApp (EVar "overlayHalf") (EVar "True")) (EVar "unitDecls")) (EVar "cur")) (EVar "rows"))))
(DTypeSig false "importedCtorTypeDeclsLastWins" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "importedCtorTypeDeclsLastWins" ((PVar "unitDecls") (PVar "cur") (PVar "rows")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "overlayHalf") (EVar "True")) (EVar "unitDecls")) (EVar "cur")) (EVar "rows")) (EApp (EApp (EApp (EApp (EVar "overlayHalf") (EVar "False")) (EVar "unitDecls")) (EVar "cur")) (EVar "rows"))))
(DTypeSig false "overlayHalf" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "overlayHalf" ((PVar "wildHalf") (PVar "unitDecls") (PVar "cur") (PVar "rows")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "importOverlayDecls") (EVar "wildHalf")) (EVar "cur")) (EVar "rows"))) (EVar "unitDecls")))
(DTypeSig false "importOverlayDecls" (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "importOverlayDecls" ((PVar "wildHalf") (PVar "cur") (PVar "rows") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EVar "importOverlayDecls") (EVar "wildHalf")) (EVar "cur")) (EVar "rows")) (EVar "d")))
(DFunDef false "importOverlayDecls" ((PVar "wildHalf") (PVar "cur") (PVar "rows") (PCon "DUse" PWild (PAs "p" (PCon "UseGroup" PWild (PVar "ms"))) PWild)) (EIf (EVar "wildHalf") (EListLit) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "memberOverlayDecl") (EVar "cur")) (EVar "rows")) (EApp (EVar "useModId") (EVar "p")))) (EVar "ms"))))
(DFunDef false "importOverlayDecls" ((PVar "wildHalf") (PVar "cur") (PVar "rows") (PCon "DUse" PWild (PAs "p" (PCon "UseWild" PWild)) PWild)) (EIf (EVar "wildHalf") (EApp (EApp (EApp (EVar "wildOverlayDecls") (EVar "cur")) (EVar "rows")) (EApp (EVar "useModId") (EVar "p"))) (EListLit)))
(DFunDef false "importOverlayDecls" (PWild PWild PWild PWild) (EListLit))
(DTypeSig false "oracleImportDecls" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "oracleImportDecls" ((PVar "gctx") (PVar "unitDecls") (PVar "cur") (PVar "rows")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "oracleImportDeclsOf") (EVar "gctx")) (EVar "cur")) (EVar "rows"))) (EVar "unitDecls")))
(DTypeSig false "oracleImportDeclsOf" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "oracleImportDeclsOf" ((PVar "gctx") (PVar "cur") (PVar "rows") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EVar "oracleImportDeclsOf") (EVar "gctx")) (EVar "cur")) (EVar "rows")) (EVar "d")))
(DFunDef false "oracleImportDeclsOf" ((PVar "gctx") (PVar "cur") (PVar "rows") (PCon "DUse" PWild (PAs "p" (PCon "UseAlias" PWild PWild)) PWild)) (EBlock (DoLet false false (PVar "dep") (EApp (EVar "useModId") (EVar "p"))) (DoExpr (EBinOp "++" (EApp (EApp (EApp (EVar "wildOverlayDecls") (EVar "cur")) (EVar "rows")) (EVar "dep")) (EApp (EApp (EApp (EApp (EVar "reexportedCtorDecls") (EVar "gctx")) (EVar "cur")) (EVar "rows")) (EVar "dep"))))))
(DFunDef false "oracleImportDeclsOf" ((PVar "gctx") (PVar "cur") (PVar "rows") (PCon "DUse" PWild (PAs "p" (PCon "UseWild" PWild)) PWild)) (EApp (EApp (EApp (EApp (EVar "reexportedCtorDecls") (EVar "gctx")) (EVar "cur")) (EVar "rows")) (EApp (EVar "useModId") (EVar "p"))))
(DFunDef false "oracleImportDeclsOf" ((PVar "gctx") PWild PWild PWild) (EListLit))
(DTypeSig false "reexportedCtorDecls" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "reexportedCtorDecls" ((PVar "gctx") (PVar "cur") (PVar "rows") (PVar "dep")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "dep")) (EApp (EApp (EVar "ctorExportsIndex") (EVar "gctx")) (ELit LUnit))) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "es")) () (EApp (EApp (EVar "flatMap") (ELam ((PVar "k")) (EApp (EApp (EApp (EApp (EVar "reexportedTypeDecl") (EVar "cur")) (EVar "rows")) (EApp (EVar "fst") (EVar "k"))) (EApp (EVar "snd") (EVar "k"))))) (EApp (EApp (EVar "dedupBy") (ELam ((PVar "k")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "fst") (EVar "k")))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "snd") (EVar "k")))) (ELit (LString ""))))) (EApp (EApp (EVar "flatMap") (EApp (EVar "reexportedOwner") (EVar "dep"))) (EVar "es")))))))
(DTypeSig false "reexportedOwner" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reexportedOwner" ((PVar "dep") (PTuple PWild (PVar "owner") (PCon "Ident" PWild (PVar "io") PWild))) (EApp (EApp (EApp (EVar "identOriginFold") (EListLit)) (ELam ((PVar "m")) (EIf (EBinOp "==" (EVar "m") (EVar "dep")) (EListLit) (EListLit (ETuple (EVar "m") (EVar "owner")))))) (EVar "io")))
(DTypeSig false "reexportedTypeDecl" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "reexportedTypeDecl" (PWild (PList) PWild PWild) (EListLit))
(DFunDef false "reexportedTypeDecl" ((PVar "cur") (PCons (PVar "m") (PVar "rest")) (PVar "declarer") (PVar "tyName")) (EIf (EBinOp "==" (EFieldAccess (EVar "m") "demId") (EVar "declarer")) (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "declIsOwnedType") (EVar "declarer")) (EVar "tyName"))) (EApp (EApp (EVar "declEnvRowVisible") (EVar "cur")) (EVar "m"))) (EApp (EApp (EApp (EApp (EVar "reexportedTypeDecl") (EVar "cur")) (EVar "rest")) (EVar "declarer")) (EVar "tyName"))))
(DTypeSig false "declIsOwnedType" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyCon "Bool")))))
(DFunDef false "declIsOwnedType" ((PVar "mid") (PVar "tyName") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EVar "declIsOwnedType") (EVar "mid")) (EVar "tyName")) (EVar "d")))
(DFunDef false "declIsOwnedType" ((PVar "mid") (PVar "tyName") (PRec "DData" ((rf "dataName" (PVar "tn")) (rf "dataOrigin" (PVar "o"))) false)) (EBinOp "&&" (EBinOp "==" (EVar "tn") (EVar "tyName")) (EApp (EApp (EApp (EVar "declOwnedBy") (EVar "mid")) (EVar "tn")) (EVar "o"))))
(DFunDef false "declIsOwnedType" ((PVar "mid") (PVar "tyName") (PRec "DNewtype" ((rf "newtypeName" (PVar "tn")) (rf "newtypeOrigin" (PVar "o"))) false)) (EBinOp "&&" (EBinOp "==" (EVar "tn") (EVar "tyName")) (EApp (EApp (EApp (EVar "declOwnedBy") (EVar "mid")) (EVar "tn")) (EVar "o"))))
(DFunDef false "declIsOwnedType" (PWild PWild PWild) (EVar "False"))
(DTypeSig false "wildOverlayDecls" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "wildOverlayDecls" (PWild (PList) PWild) (EListLit))
(DFunDef false "wildOverlayDecls" ((PVar "cur") (PCons (PVar "m") (PVar "rest")) (PVar "mid")) (EIf (EBinOp "==" (EFieldAccess (EVar "m") "demId") (EVar "mid")) (EApp (EApp (EVar "declEnvRowVisible") (EVar "cur")) (EVar "m")) (EApp (EApp (EApp (EVar "wildOverlayDecls") (EVar "cur")) (EVar "rest")) (EVar "mid"))))
(DTypeSig false "memberOverlayDecl" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyCon "String") (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "memberOverlayDecl" ((PVar "cur") (PVar "rows") (PVar "mid") (PCon "UseMember" (PVar "n") (PVar "ctors") PWild PWild)) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "findOverlayDecl") (EVar "mid")) (EVar "n")) (EVar "ctors")) (EVar "cur")) (EVar "rows")) (arm (PCon "Some" (PVar "d")) () (EListLit (EVar "d"))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "findOverlayDecl" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyApp (TyCon "Option") (TyCon "Decl"))))))))
(DFunDef false "findOverlayDecl" ((PVar "mid") (PVar "n") (PVar "ctors") (PVar "cur") (PVar "rows")) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "overlayScanRows") (EVar "mid")) (EVar "n")) (EVar "ctors")) (EVar "cur")) (ETuple (EVar "None") (EVar "None") (EVar "None"))) (EVar "rows")) (arm (PTuple (PVar "ownedType") (PVar "ownedCtor") (PVar "bareType")) () (EIf (EVar "ctors") (EApp (EApp (EVar "orElseOpt") (EApp (EApp (EVar "orElseOpt") (EVar "ownedType")) (EVar "ownedCtor"))) (EVar "bareType")) (EVar "ownedCtor")))))
(DTypeSig false "overlayScanRows" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyFun (TyTuple (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl"))) (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyTuple (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl"))))))))))
(DFunDef false "overlayScanRows" (PWild PWild PWild PWild (PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "overlayScanRows" ((PVar "mid") (PVar "n") (PVar "ctors") (PVar "cur") (PVar "acc") (PCons (PVar "m") (PVar "rest"))) (EBlock (DoLet false false (PVar "acc2") (EApp (EApp (EApp (EApp (EApp (EVar "overlayScan") (EVar "mid")) (EVar "n")) (EVar "ctors")) (EVar "acc")) (EApp (EApp (EVar "declEnvRowVisible") (EVar "cur")) (EVar "m")))) (DoExpr (EIf (EApp (EApp (EVar "overlayDecided") (EVar "ctors")) (EVar "acc2")) (EVar "acc2") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "overlayScanRows") (EVar "mid")) (EVar "n")) (EVar "ctors")) (EVar "cur")) (EVar "acc2")) (EVar "rest"))))))
(DTypeSig false "overlayScan" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyTuple (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl")))))))))
(DFunDef false "overlayScan" (PWild PWild PWild (PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "overlayScan" ((PVar "mid") (PVar "n") (PVar "ctors") (PVar "acc") (PCons (PVar "d") (PVar "rest"))) (EBlock (DoLet false false (PVar "acc2") (EApp (EApp (EApp (EApp (EVar "overlayScanOne") (EVar "mid")) (EVar "n")) (EVar "acc")) (EVar "d"))) (DoExpr (EIf (EApp (EApp (EVar "overlayDecided") (EVar "ctors")) (EVar "acc2")) (EVar "acc2") (EApp (EApp (EApp (EApp (EApp (EVar "overlayScan") (EVar "mid")) (EVar "n")) (EVar "ctors")) (EVar "acc2")) (EVar "rest"))))))
(DTypeSig false "overlayDecided" (TyFun (TyCon "Bool") (TyFun (TyTuple (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl"))) (TyCon "Bool"))))
(DFunDef false "overlayDecided" ((PVar "ctors") (PTuple (PVar "ownedType") (PVar "ownedCtor") PWild)) (EIf (EVar "ctors") (EApp (EVar "isSome") (EVar "ownedType")) (EApp (EVar "isSome") (EVar "ownedCtor"))))
(DTypeSig false "overlayScanOne" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyTuple (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl"))) (TyFun (TyCon "Decl") (TyTuple (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl"))))))))
(DFunDef false "overlayScanOne" ((PVar "mid") (PVar "n") (PVar "acc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EVar "overlayScanOne") (EVar "mid")) (EVar "n")) (EVar "acc")) (EVar "d")))
(DFunDef false "overlayScanOne" ((PVar "mid") (PVar "n") (PVar "acc") (PAs "d" (PRec "DData" ((rf "dataName" (PVar "tn")) (rf "dataOrigin" (PVar "o"))) false))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "overlayNote") (EVar "mid")) (EVar "n")) (EVar "tn")) (EVar "o")) (EVar "d")) (EVar "acc")))
(DFunDef false "overlayScanOne" ((PVar "mid") (PVar "n") (PVar "acc") (PAs "d" (PRec "DNewtype" ((rf "newtypeName" (PVar "tn")) (rf "newtypeOrigin" (PVar "o"))) false))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "overlayNote") (EVar "mid")) (EVar "n")) (EVar "tn")) (EVar "o")) (EVar "d")) (EVar "acc")))
(DFunDef false "overlayScanOne" (PWild PWild (PVar "acc") PWild) (EVar "acc"))
(DTypeSig false "overlayNote" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "Decl") (TyFun (TyTuple (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl"))) (TyTuple (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl"))))))))))
(DFunDef false "overlayNote" ((PVar "mid") (PVar "n") (PVar "tn") (PVar "o") (PVar "d") (PVar "acc")) (EMatch (EVar "acc") (arm (PTuple (PVar "ownedType") (PVar "ownedCtor") (PVar "bareType")) () (EBlock (DoLet false false (PVar "hitType") (EBinOp "==" (EVar "tn") (EVar "n"))) (DoLet false false (PVar "hitCtor") (EApp (EApp (EVar "declCtorNamed") (EVar "n")) (EVar "d"))) (DoExpr (EIf (EBinOp "||" (EVar "hitType") (EVar "hitCtor")) (EBlock (DoLet false false (PVar "owned") (EApp (EApp (EApp (EVar "declOwnedBy") (EVar "mid")) (EVar "tn")) (EVar "o"))) (DoExpr (ETuple (EIf (EBinOp "&&" (EVar "hitType") (EVar "owned")) (EApp (EApp (EVar "orElseOpt") (EVar "ownedType")) (EApp (EVar "Some") (EVar "d"))) (EVar "ownedType")) (EIf (EBinOp "&&" (EVar "hitCtor") (EVar "owned")) (EApp (EApp (EVar "orElseOpt") (EVar "ownedCtor")) (EApp (EVar "Some") (EVar "d"))) (EVar "ownedCtor")) (EIf (EVar "hitType") (EApp (EApp (EVar "orElseOpt") (EVar "bareType")) (EApp (EVar "Some") (EVar "d"))) (EVar "bareType"))))) (EVar "acc")))))))
(DTypeSig false "declOwnedBy" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyCon "Bool")))))
(DFunDef false "declOwnedBy" ((PVar "mid") (PVar "tyName") (PVar "o")) (EMatch (EApp (EApp (EApp (EVar "mkIdent") (EVar "NsType")) (EApp (EVar "OriginModule") (EVar "mid"))) (EVar "tyName")) (arm (PCon "Some" (PVar "want")) () (EBinOp "==" (EApp (EApp (EApp (EVar "mkIdent") (EVar "NsType")) (EVar "o")) (EVar "tyName")) (EApp (EVar "Some") (EVar "want")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "importDefinersOf" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "importDefinersOf" ((PVar "gctx") (PVar "prog")) (EBlock (DoLet false false (PVar "named") (EApp (EApp (EApp (EVar "useAdmittedRows") (EVar "gctx")) (EVar "False")) (EVar "prog"))) (DoLet false false (PVar "taken") (EApp (EApp (EVar "namesToSet") (EBinOp "++" (EApp (EApp (EVar "map") (EVar "fst")) (EVar "named")) (EApp (EVar "declTopFnNames") (EVar "prog")))) (EVar "omEmpty"))) (DoExpr (EBinOp "++" (EVar "named") (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EVar "e"))) (EVar "taken"))))) (EApp (EApp (EApp (EVar "useAdmittedRows") (EVar "gctx")) (EVar "True")) (EVar "prog")))))))
(DTypeSig false "useAdmittedRows" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "useAdmittedRows" ((PVar "gctx") PWild (PList)) (EListLit))
(DFunDef false "useAdmittedRows" ((PVar "gctx") (PVar "wild") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EApp (EVar "useAdmittedRows") (EVar "gctx")) (EVar "wild")) (EListLit (EVar "d"))) (EApp (EApp (EApp (EVar "useAdmittedRows") (EVar "gctx")) (EVar "wild")) (EVar "rest"))))
(DFunDef false "useAdmittedRows" ((PVar "gctx") (PVar "wild") (PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EApp (EVar "useDefinerRows") (EVar "gctx")) (EVar "wild")) (EVar "path")) (EApp (EApp (EApp (EVar "useAdmittedRows") (EVar "gctx")) (EVar "wild")) (EVar "rest"))))
(DFunDef false "useAdmittedRows" ((PVar "gctx") (PVar "wild") (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EVar "useAdmittedRows") (EVar "gctx")) (EVar "wild")) (EVar "rest")))
(DTypeSig false "useDefinerRows" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Bool") (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "useDefinerRows" ((PVar "gctx") (PVar "wild") (PVar "path")) (EBlock (DoLet false false (PVar "depId") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "depId") (ELit (LString "core"))) (EListLit) (EMatch (EApp (EVar "importedBindings") (EVar "path")) (arm (PCon "None") () (EIf (EVar "wild") (EApp (EApp (EVar "graphPubDefiners") (EVar "gctx")) (EVar "depId")) (EListLit))) (arm (PCon "Some" (PVar "bindings")) () (EIf (EVar "wild") (EListLit) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "memberDefinerRow") (EVar "depId")) (EApp (EApp (EVar "graphPubDefiners") (EVar "gctx")) (EVar "depId")))) (EVar "bindings")))))))))
(DTypeSig false "memberDefinerRow" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "memberDefinerRow" ((PVar "depId") (PVar "pubs") (PTuple (PVar "origin") (PVar "local"))) (EMatch (EApp (EApp (EVar "resolveMemberRows") (ETuple (EVar "origin") (EVar "local"))) (EVar "pubs")) (arm (PList) () (EListLit (ETuple (EVar "local") (ETuple (EVar "depId") (EVar "origin"))))) (arm (PVar "rows") () (EVar "rows"))))
(DTypeSig false "originRowsOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "originRowsOf" ((PVar "rows")) (EApp (EApp (EVar "map") (ELam ((PVar "e")) (ETuple (EApp (EVar "fst") (EVar "e")) (EApp (EVar "snd") (EApp (EVar "snd") (EVar "e")))))) (EVar "rows")))
(DTypeSig false "definerRowsOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "definerRowsOf" ((PVar "rows")) (EApp (EApp (EVar "map") (ELam ((PVar "e")) (ETuple (EApp (EVar "fst") (EVar "e")) (EApp (EVar "fst") (EApp (EVar "snd") (EVar "e")))))) (EVar "rows")))
(DTypeSig true "checkModuleFullDiags" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "ModuleSeed") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "ModuleBindings") (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyCon "ModuleCtx")))))))))
(DFunDef false "checkModuleFullDiags" ((PVar "gctx") (PVar "mid") (PVar "seedVars") (PVar "accData") (PVar "accAll") (PVar "prog")) (EBlock (DoLet false false (PVar "declEnvsHere") (EFieldAccess (EFieldAccess (EVar "gctx") "declEnvsRef") "value")) (DoLet false false (PVar "runSeed") (EApp (EVar "seedCheckRun") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EVar "prog") (EApp (EApp (EApp (EVar "importedCtorTypeDeclsFirstWins") (EVar "prog")) (EApp (EApp (EVar "declEnvsOrdOf") (EVar "mid")) (EVar "declEnvsHere"))) (EFieldAccess (EVar "declEnvsHere") "deModules"))) (EApp (EApp (EApp (EApp (EVar "oracleImportDecls") (EVar "gctx")) (EVar "prog")) (EApp (EApp (EVar "declEnvsOrdOf") (EVar "mid")) (EVar "declEnvsHere"))) (EFieldAccess (EVar "declEnvsHere") "deModules"))) (EVar "accData")))) (DoLet false false (PTuple (PVar "schemes") (PVar "marked") (PVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkModuleFullImpl") (EVar "gctx")) (EVar "runSeed")) (EVar "mid")) (EVar "seedVars")) (EVar "accData")) (EVar "accAll")) (EVar "prog"))) (DoLet false false (PVar "ceHere") (EFieldAccess (EVar "declEnvsHere") "deIfaces")) (DoLet false false (PVar "ordHere") (EApp (EApp (EVar "declEnvsOrdOf") (EVar "mid")) (EVar "declEnvsHere"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runFinalChecks") (EVar "mctx")) (EVar "prog")) (EVar "ceHere")) (EVar "ceHere")) (EFieldAccess (EVar "declEnvsHere") "deImpls")) (EFieldAccess (EVar "declEnvsHere") "deImpls")) (EVar "ordHere"))) (DoExpr (ETuple (EVar "schemes") (EVar "marked") (EApp (EVar "reverseL") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrors") "items") "value")) (EApp (EVar "reverseL") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchWarnings") "value")) (EVar "mctx")))))
(DTypeSig false "unjudgedRanges" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "unjudgedRanges" ((PVar "lo") (PVar "hi") (PVar "skips")) (EApp (EApp (EApp (EVar "cutRanges") (EVar "lo")) (EVar "hi")) (EApp (EApp (EVar "sortOn") (EVar "fst")) (EApp (EApp (EVar "filterList") (ELam ((PTuple (PVar "a") (PVar "b"))) (EBinOp "&&" (EBinOp ">" (EVar "b") (EVar "lo")) (EBinOp "<" (EVar "a") (EVar "hi"))))) (EVar "skips")))))
(DTypeSig false "cutRanges" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "cutRanges" ((PVar "lo") (PVar "hi") (PList)) (EIf (EBinOp "<" (EVar "lo") (EVar "hi")) (EListLit (ETuple (EVar "lo") (EVar "hi"))) (EListLit)))
(DFunDef false "cutRanges" ((PVar "lo") (PVar "hi") (PCons (PTuple (PVar "a") (PVar "b")) (PVar "rest"))) (EBinOp "++" (EIf (EBinOp ">" (EVar "a") (EVar "lo")) (EListLit (ETuple (EVar "lo") (EVar "a"))) (EListLit)) (EApp (EApp (EApp (EVar "cutRanges") (EApp (EApp (EVar "max") (EVar "lo")) (EVar "b"))) (EVar "hi")) (EVar "rest"))))
(DTypeSig false "selfNameRows" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))))
(DFunDef false "selfNameRows" ((PVar "prog") (PVar "old")) (EBlock (DoLet false false (PVar "own") (EApp (EApp (EVar "namesToSet") (EApp (EVar "declTopFnNames") (EVar "prog"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EVar "e"))) (EVar "own")))) (EVar "old")))))
(DTypeSig false "attributeModuleEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyVar "a")))))))
(DFunDef false "attributeModuleEntries" ((PVar "mid") (PVar "prog") (PVar "entries")) (EBlock (DoLet false false (PVar "progNames") (EApp (EApp (EVar "namesToSet") (EApp (EVar "declTopFnNames") (EVar "prog"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "e")) (ETuple (ETuple (EVar "mid") (EApp (EVar "fst") (EVar "e"))) (EApp (EVar "snd") (EVar "e"))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EVar "e"))) (EVar "progNames")))) (EVar "entries"))))))
(DTypeSig false "attributeModuleSchemeObls" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "VecObl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "VecObl")))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "VecObl")))))))))
(DFunDef false "attributeModuleSchemeObls" ((PVar "mid") (PVar "prog") (PVar "qual") (PVar "entries")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "attributeSchemeOblsGo") (EVar "mid")) (EApp (EApp (EVar "namesToSet") (EApp (EVar "publicValNames") (EVar "prog"))) (EVar "omEmpty"))) (EVar "omEmpty")) (EVar "entries")) (EApp (EApp (EVar "map") (ELam ((PVar "e")) (ETuple (ETuple (EVar "mid") (EApp (EVar "fst") (EVar "e"))) (EApp (EVar "snd") (EVar "e"))))) (EApp (EApp (EVar "reexportSchemeOblEntries") (EVar "prog")) (EVar "qual")))))
(DTypeSig false "reexportSchemeOblEntries" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "VecObl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "VecObl")))))))
(DFunDef false "reexportSchemeOblEntries" ((PList) PWild) (EListLit))
(DFunDef false "reexportSchemeOblEntries" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "qual")) (EBinOp "++" (EApp (EApp (EVar "reexportSchemeOblEntries") (EListLit (EVar "d"))) (EVar "qual")) (EApp (EApp (EVar "reexportSchemeOblEntries") (EVar "rest")) (EVar "qual"))))
(DFunDef false "reexportSchemeOblEntries" ((PCons (PCon "DUse" (PCon "True") (PVar "path") PWild) (PVar "rest")) (PVar "qual")) (EBinOp "++" (EApp (EApp (EApp (EVar "schemeOblEntriesFor") (EApp (EVar "useModId") (EVar "path"))) (EVar "path")) (EVar "qual")) (EApp (EApp (EVar "reexportSchemeOblEntries") (EVar "rest")) (EVar "qual"))))
(DFunDef false "reexportSchemeOblEntries" ((PCons PWild (PVar "rest")) (PVar "qual")) (EApp (EApp (EVar "reexportSchemeOblEntries") (EVar "rest")) (EVar "qual")))
(DTypeSig false "attributeSchemeOblsGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "VecObl")))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "VecObl")))))))))
(DFunDef false "attributeSchemeOblsGo" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "attributeSchemeOblsGo" ((PVar "mid") (PVar "progNames") (PVar "seen") (PCons (PVar "e") (PVar "rest"))) (EIf (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EApp (EVar "fst") (EVar "e")))) (EVar "progNames"))) (EApp (EApp (EApp (EApp (EVar "attributeSchemeOblsGo") (EVar "mid")) (EVar "progNames")) (EVar "seen")) (EVar "rest")) (EIf (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EApp (EVar "fst") (EVar "e")))) (EVar "seen")) (EApp (EApp (EApp (EApp (EVar "attributeSchemeOblsGo") (EVar "mid")) (EVar "progNames")) (EVar "seen")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (ETuple (EVar "mid") (EApp (EVar "fst") (EApp (EVar "fst") (EVar "e")))) (EApp (EVar "snd") (EVar "e"))) (EApp (EApp (EApp (EApp (EVar "attributeSchemeOblsGo") (EVar "mid")) (EVar "progNames")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "fst") (EApp (EVar "fst") (EVar "e")))) (ELit LUnit)) (EVar "seen"))) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "attributeMethodModulePredicateSlots" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "MethodPredicateSlot"))))))))
(DFunDef false "attributeMethodModulePredicateSlots" ((PVar "mid") (PVar "prog") (PVar "entries")) (EBlock (DoLet false false (PVar "progMethods") (EApp (EApp (EVar "namesToSet") (EApp (EVar "ifaceMethodSlotKeys") (EVar "prog"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "e")) (ETuple (ETuple (EVar "mid") (EApp (EVar "fst") (EVar "e"))) (EApp (EVar "snd") (EVar "e"))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EVar "e"))) (EVar "progMethods")))) (EVar "entries"))))))
(DTypeSig false "ifaceMethodSlotKeys" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ifaceMethodSlotKeys" ((PList)) (EListLit))
(DFunDef false "ifaceMethodSlotKeys" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "ifaceMethodSlotKeys") (EListLit (EVar "d"))) (EApp (EVar "ifaceMethodSlotKeys") (EVar "rest"))))
(DFunDef false "ifaceMethodSlotKeys" ((PCons (PRec "DInterface" ((rf "name" None) (rf "methods" None) (rf "ifaceOrigin" None)) true) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (EApp (EVar "methodSlotKey") (ERecordCreate "IfaceRef" ((fa "irName" (EVar "name")) (fa "irOrigin" (EVar "ifaceOrigin")))))) (EApp (EVar "ifaceMethodNames") (EVar "methods"))) (EApp (EVar "ifaceMethodSlotKeys") (EVar "rest"))))
(DFunDef false "ifaceMethodSlotKeys" ((PCons PWild (PVar "rest"))) (EApp (EVar "ifaceMethodSlotKeys") (EVar "rest")))
(DTypeSig true "elabModuleStamp" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "ModuleBindings") (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "ModuleCtx")))))))))
(DFunDef false "elabModuleStamp" ((PVar "prev") (PVar "mid") (PVar "seedVars") (PVar "accData") (PVar "implDecls") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkModuleFullImpl") (EFieldAccess (EVar "prev") "mcGraph")) (EApp (EVar "checkRunResidue") (EVar "prev"))) (EVar "mid")) (EApp (EVar "plainModuleSeed") (EVar "seedVars"))) (EVar "accData")) (EVar "implDecls")) (EVar "prog")))
(DTypeSig false "moduleStampOrder" (TyApp (TyCon "List") (TyCon "StampStep")))
(DFunDef false "moduleStampOrder" () (EListLit (EVar "SSNumlitFloats") (EVar "SSReturnSites") (EVar "SSBinopSites") (EVar "SSUnopSites") (EVar "SSArithSites") (EVar "SSArgStamps") (EVar "SSRLocalSites") (EVar "SSRecDictApps") (EVar "SSDictApps") (EVar "SSMethodDicts")))
(DTypeSig true "isLiveSpan" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Bool"))))
(DFunDef false "isLiveSpan" (PWild (PCon "None")) (EVar "False"))
(DFunDef false "isLiveSpan" ((PVar "live") (PVar "loc")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "locKey") (EVar "loc"))) (EVar "live")))
(DTypeSig false "runStampSteps" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "StampCtx") (TyFun (TyApp (TyCon "List") (TyCon "StampStep")) (TyCon "Unit")))))
(DFunDef false "runStampSteps" ((PVar "stamp") (PVar "ctx") (PVar "steps")) (EApp (EApp (EVar "each") (EApp (EApp (EVar "runStampStep") (EVar "stamp")) (EVar "ctx"))) (EVar "steps")))
(DTypeSig false "numlitSince" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Float"))) (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Route")))))))
(DFunDef false "numlitSince" ((PVar "gctx") (PVar "mark")) (EApp (EApp (EApp (EVar "moduleWindow") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "numlitN") "value")) (EVar "mark")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "numlitRefs") "value")))
(DTypeSig false "stampCtxOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Obligation")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Float"))) (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Route")))) (TyCon "StampCtx")))))))
(DFunDef false "stampCtxOf" ((PVar "mctx") (PVar "mid") (PVar "implDecls") (PVar "goals") (PVar "numlits")) (EBlock (DoLet false false (PVar "dropped") (EApp (EApp (EVar "blankModuleCtx") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "mid"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "dropped") "mcCells") "superDeclsRef")) (EApp (EApp (EVar "filterList") (EVar "isInterfaceDecl")) (EVar "implDecls")))) (DoExpr (ERecordCreate "StampCtx" ((fa "scModule" (EVar "mid")) (fa "scModuleCtx" (EApp (EApp (EApp (EApp (EApp (EVar "moduleCtxFrom") (EVar "False")) (EVar "mctx")) (EVar "dropped")) (EVar "dropped")) (EVar "dropped"))) (fa "scRpNames" (EApp (EVar "returnPosMethodNames") (EVar "implDecls"))) (fa "scGoals" (EVar "goals")) (fa "scNumlits" (EVar "numlits")) (fa "scLiveLocs" (EApp (EApp (EVar "liveLocsOf") (EVar "mctx")) (EVar "goals"))))))))
(DTypeSig false "liveLocsOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Obligation")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "liveLocsOf" ((PVar "mctx") (PVar "goals")) (EBlock (DoLet false false (PVar "ids") (EApp (EApp (EVar "flatMap") (EVar "monoUnboundIds")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "liveRoots") "value"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "ids")) (EListLit) (EBlock (DoLet false false (PVar "live") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "i")) (EApp (EApp (EApp (EVar "IdMap.set") (EVar "i")) (ELit LUnit)) (EVar "acc")))) (EVar "Tip")) (EVar "ids"))) (DoLet false false (PVar "mentions") (ELam ((PVar "ms")) (EApp (EApp (EVar "anyList") (ELam ((PVar "m")) (EApp (EApp (EVar "anyList") (ELam ((PVar "i")) (EApp (EApp (EVar "IdMap.has") (EVar "i")) (EVar "live")))) (EApp (EVar "monoUnboundIds") (EVar "m"))))) (EVar "ms")))) (DoExpr (EApp (EVar "spanKeys") (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "o")) (EFieldAccess (EVar "o") "oLoc"))) (EApp (EApp (EVar "filterList") (ELam ((PVar "o")) (EApp (EVar "mentions") (EApp (EVar "goalMonos") (EVar "o"))))) (EVar "goals"))) (EApp (EApp (EVar "filterMap") (ELam ((PTuple PWild (PVar "m") (PVar "loc"))) (EIf (EApp (EVar "mentions") (EListLit (EVar "m"))) (EApp (EVar "Some") (EVar "loc")) (EVar "None")))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "admittedOccObls") "value"))))))))))
(DTypeSig true "spanKeys" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "spanKeys" ((PList)) (EListLit))
(DFunDef false "spanKeys" ((PCons (PCon "None") (PVar "rest"))) (EApp (EVar "spanKeys") (EVar "rest")))
(DFunDef false "spanKeys" ((PCons (PVar "loc") (PVar "rest"))) (EBinOp "::" (EApp (EVar "locKey") (EVar "loc")) (EApp (EVar "spanKeys") (EVar "rest"))))
(DTypeSig false "isInterfaceDecl" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isInterfaceDecl" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "isInterfaceDecl") (EVar "d")))
(DFunDef false "isInterfaceDecl" ((PRec "DInterface" () false)) (EVar "True"))
(DFunDef false "isInterfaceDecl" (PWild) (EVar "False"))
(DTypeSig false "enqueueStampCtx" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))))
(DFunDef false "enqueueStampCtx" ((PVar "mctx") (PVar "mid") (PVar "implDecls")) (EBlock (DoLet false false (PVar "mk") (EApp (EApp (EVar "currentModuleMarks") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (DoLet false false (PVar "ctx") (EApp (EApp (EApp (EApp (EApp (EVar "stampCtxOf") (EVar "mctx")) (EVar "mid")) (EVar "implDecls")) (EApp (EApp (EVar "goalsSince") (EFieldAccess (EVar "mctx") "mcGraph")) (EFieldAccess (EVar "mk") "mGoals"))) (EApp (EApp (EVar "numlitSince") (EFieldAccess (EVar "mctx") "mcGraph")) (EFieldAccess (EVar "mk") "mNumlit")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "stampCtxs")) (EBinOp "::" (EVar "ctx") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "stampCtxs") "value"))))))
(DTypeSig false "stampNoting" (TyFun (TyCon "ModuleCtx") (TyFun (TyFun (TyCon "SiteCtx") (TyFun (TyCon "Obligation") (TyCon "Unit"))) (TyFun (TyCon "Obligation") (TyCon "Unit")))))
(DFunDef false "stampNoting" ((PVar "stamp") (PVar "resolve") (PVar "o")) (EBlock (DoLet false false (PVar "acc") (EApp (EVar "Ref") (EVar "innerNone"))) (DoExpr (EApp (EApp (EVar "resolve") (ERecordUpdate (EApp (EVar "siteFor") (EVar "stamp")) ((fa "sxInner" (EApp (EVar "Some") (EVar "acc")))))) (EVar "o"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "o") "oInner")) (EApp (EApp (EVar "innerOr") (EFieldAccess (EFieldAccess (EVar "o") "oInner") "value")) (EFieldAccess (EVar "acc") "value"))))))
(DTypeSig false "runStampStep" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "StampCtx") (TyFun (TyCon "StampStep") (TyCon "Unit")))))
(DFunDef false "runStampStep" ((PVar "mctx") (PVar "ctx") (PCon "SSNumlitFloats")) (EApp (EVar "setNumlitFloatsGo") (EFieldAccess (EVar "ctx") "scNumlits")))
(DFunDef false "runStampStep" ((PVar "stamp") (PVar "ctx") (PCon "SSReturnSites")) (EBlock (DoLet false false (PVar "rpNames") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "ctx") "scRpNames")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "stampEach") (EVar "stamp")) (ELam ((PVar "sx") (PVar "o")) (EApp (EApp (EApp (EVar "resolveSites") (EVar "sx")) (EVar "rpNames")) (EApp (EVar "siteEntry") (EVar "o"))))) (EVar "GKReturnSite")) (EVar "ctx")))))
(DFunDef false "runStampStep" ((PVar "stamp") (PVar "ctx") (PCon "SSBinopSites")) (EApp (EApp (EApp (EApp (EVar "stampEach") (EVar "stamp")) (ELam ((PVar "sx") (PVar "o")) (EApp (EApp (EApp (EVar "resolveOpSites") (EVar "sx")) (EVar "True")) (EApp (EVar "siteEntry") (EVar "o"))))) (EVar "GKBinopSite")) (EVar "ctx")))
(DFunDef false "runStampStep" ((PVar "stamp") (PVar "ctx") (PCon "SSUnopSites")) (EApp (EApp (EApp (EApp (EVar "stampEach") (EVar "stamp")) (ELam ((PVar "sx") (PVar "o")) (EApp (EApp (EApp (EVar "resolveOpSites") (EVar "sx")) (EVar "False")) (EApp (EVar "siteEntry") (EVar "o"))))) (EVar "GKUnopSite")) (EVar "ctx")))
(DFunDef false "runStampStep" ((PVar "stamp") (PVar "ctx") (PCon "SSArithSites")) (EApp (EApp (EApp (EApp (EVar "stampEach") (EVar "stamp")) (ELam (PWild (PVar "o")) (EApp (EVar "resolveArithSites") (EApp (EVar "arithEntry") (EVar "o"))))) (EVar "GKArithSite")) (EVar "ctx")))
(DFunDef false "runStampStep" ((PVar "stamp") (PVar "ctx") (PCon "SSArgStamps")) (EApp (EApp (EApp (EApp (EVar "stampEach") (EVar "stamp")) (ELam ((PVar "sx") (PVar "o")) (EApp (EApp (EVar "resolveArgStamps") (EVar "sx")) (EApp (EVar "siteEntry") (EVar "o"))))) (EVar "GKArgStamp")) (EVar "ctx")))
(DFunDef false "runStampStep" ((PVar "stamp") (PVar "ctx") (PCon "SSRLocalSites")) (EApp (EApp (EApp (EApp (EVar "stampEach") (EVar "stamp")) (ELam ((PVar "sx") (PVar "o")) (EApp (EApp (EVar "resolveRLocalSites") (EVar "sx")) (EApp (EVar "siteEntry") (EVar "o"))))) (EVar "GKRLocalSite")) (EVar "ctx")))
(DFunDef false "runStampStep" ((PVar "stamp") (PVar "ctx") (PCon "SSRecDictApps")) (EApp (EApp (EApp (EApp (EVar "stampEach") (EVar "stamp")) (ELam ((PVar "sx") (PVar "o")) (EApp (EApp (EVar "realizeRecDictApps") (EVar "sx")) (EApp (EVar "recDictAppEntry") (EVar "o"))))) (EVar "GKRecDictApp")) (EVar "ctx")))
(DFunDef false "runStampStep" ((PVar "stamp") (PVar "ctx") (PCon "SSDictApps")) (EApp (EApp (EApp (EApp (EVar "stampEach") (EVar "stamp")) (ELam ((PVar "sx") (PVar "o")) (EApp (EApp (EVar "resolveDictApps") (EVar "sx")) (EApp (EVar "dictAppEntry") (EVar "o"))))) (EVar "GKDictApp")) (EVar "ctx")))
(DFunDef false "runStampStep" ((PVar "stamp") (PVar "ctx") (PCon "SSMethodDicts")) (EApp (EApp (EApp (EApp (EVar "stampEach") (EVar "stamp")) (ELam ((PVar "sx") (PVar "o")) (EApp (EApp (EVar "resolveMethodDicts") (EVar "sx")) (EApp (EVar "methodDictEntry") (EVar "o"))))) (EVar "GKMethodDict")) (EVar "ctx")))
(DTypeSig false "stampEach" (TyFun (TyCon "ModuleCtx") (TyFun (TyFun (TyCon "SiteCtx") (TyFun (TyCon "Obligation") (TyCon "Unit"))) (TyFun (TyCon "GoalKind") (TyFun (TyCon "StampCtx") (TyCon "Unit"))))))
(DFunDef false "stampEach" ((PVar "stamp") (PVar "resolve") (PVar "k") (PVar "ctx")) (EApp (EApp (EVar "each") (EApp (EApp (EVar "stampNoting") (EVar "stamp")) (EVar "resolve"))) (EApp (EApp (EVar "goalsOfKindIn") (EVar "k")) (EFieldAccess (EVar "ctx") "scGoals"))))
(DTypeSig true "verdictFinding" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "TcDiag") (TyCon "DrainFinding")))))
(DFunDef false "verdictFinding" ((PVar "mid") (PVar "live") (PVar "d")) (ERecordCreate "DrainFinding" ((fa "dfModule" (EVar "mid")) (fa "dfDiag" (EVar "d")) (fa "dfVerdict" (EVar "True")) (fa "dfLive" (EVar "live")))))
(DTypeSig true "captureTypeErrors" (TyFun (TyCon "ModuleCtx") (TyFun (TyFun (TyCon "Unit") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "TcDiag")))))
(DFunDef false "captureTypeErrors" ((PVar "mctx") (PVar "act")) (EBlock (DoLet false false (PVar "w") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrors")) (DoLet false false (PVar "items") (EFieldAccess (EFieldAccess (EVar "w") "items") "value")) (DoLet false false (PVar "mark") (EApp (EVar "wMark") (EVar "w"))) (DoLet false false (PVar "sticky") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "typeErrorsSticky") "value")) (DoLet false false (PVar "stickyDiags") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "typeErrorsStickyDiags") "value")) (DoExpr (EApp (EVar "act") (ELit LUnit))) (DoLet false false (PVar "added") (EApp (EApp (EVar "wWindow") (EVar "w")) (EVar "mark"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "w") "items")) (EVar "items"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "w") "n")) (EVar "mark"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "typeErrorsSticky")) (EVar "sticky"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "typeErrorsStickyDiags")) (EVar "stickyDiags"))) (DoExpr (EApp (EVar "reverseL") (EVar "added")))))
(DTypeSig true "drainStampQueue" (TyFun (TyCon "ModuleCtx") (TyApp (TyCon "List") (TyCon "DrainFinding"))))
(DFunDef false "drainStampQueue" ((PVar "saved")) (EBlock (DoLet false false (PVar "ctxs") (EApp (EVar "reverseL") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "saved") "mcGraph") "graphRun") "stampCtxs") "value"))) (DoExpr (EApp (EVar "defaultLiveNumRoots") (EVar "saved"))) (DoLet false false (PVar "held") (EApp (EApp (EVar "judgeLiveGoals") (EVar "saved")) (EVar "ctxs"))) (DoLet false false (PVar "verdicts") (EApp (EApp (EVar "runStampCtxs") (EVar "saved")) (EVar "ctxs"))) (DoLet false false (PVar "liveLocs") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "flatMap") (ELam ((PVar "c")) (EFieldAccess (EVar "c") "scLiveLocs"))) (EVar "ctxs"))) (EVar "omEmpty"))) (DoLet false false (PVar "holes") (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "mid") (PVar "d"))) (ERecordCreate "DrainFinding" ((fa "dfModule" (EVar "mid")) (fa "dfDiag" (EVar "d")) (fa "dfVerdict" (EVar "False")) (fa "dfLive" (EApp (EApp (EVar "isLiveSpan") (EVar "liveLocs")) (EApp (EVar "tcLoc") (EVar "d")))))))) (EApp (EApp (EVar "judgeEvidence") (EFieldAccess (EVar "saved") "mcGraph")) (EVar "ctxs")))) (DoExpr (EApp (EApp (EVar "materializeBinderTypes") (EFieldAccess (EVar "saved") "mcGraph")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "saved") "mcGraph") "graphRun") "stampCtxs")) (EListLit))) (DoExpr (EBinOp "++" (EBinOp "++" (EVar "held") (EVar "verdicts")) (EVar "holes")))))
(DTypeSig true "checkGraphFinish" (TyFun (TyCon "ModuleCtx") (TyApp (TyCon "List") (TyCon "DrainFinding"))))
(DFunDef false "checkGraphFinish" ((PVar "mctx")) (EBlock (DoLet false false (PVar "savedSticky") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "typeErrorsSticky") "value")) (DoLet false false (PVar "savedStickyDiags") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "typeErrorsStickyDiags") "value")) (DoLet false false (PVar "holes") (EApp (EVar "drainStampQueue") (EVar "mctx"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "typeErrorsSticky")) (EVar "savedSticky"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "typeErrorsStickyDiags")) (EVar "savedStickyDiags"))) (DoExpr (EVar "holes"))))
(DTypeSig false "judgeEvidence" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "StampCtx")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))))))
(DFunDef false "judgeEvidence" ((PVar "gctx") (PVar "ctxs")) (EBlock (DoLet false false (PVar "g") (EFieldAccess (EVar "gctx") "graphRun")) (DoLet false false (PVar "lo") (EFieldAccess (EFieldAccess (EVar "g") "evJudged") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "evJudged")) (EFieldAccess (EFieldAccess (EVar "g") "evCounter") "value"))) (DoLet false false (PVar "base") (EFieldAccess (EVar "g") "evBase")) (DoLet false false (PVar "cellHoles") (EApp (EApp (EVar "flatMap") (ELam ((PTuple (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EApp (EVar "judgeCells") (EFieldAccess (EFieldAccess (EVar "g") "evCells") "value")) (EBinOp "-" (EVar "a") (EVar "base"))) (EBinOp "-" (EVar "b") (EVar "base"))) (EListLit)))) (EApp (EApp (EApp (EVar "unjudgedRanges") (EVar "lo")) (EFieldAccess (EFieldAccess (EVar "g") "evCounter") "value")) (EFieldAccess (EFieldAccess (EVar "g") "evScopedJudged") "value")))) (DoLet false false (PVar "goalHoles") (EApp (EApp (EVar "flatMap") (ELam ((PVar "c")) (EApp (EApp (EVar "flatMap") (EApp (EVar "judgeGoal") (EFieldAccess (EVar "c") "scModule"))) (EFieldAccess (EVar "c") "scGoals")))) (EVar "ctxs"))) (DoExpr (EApp (EApp (EVar "dedupBy") (EVar "holeKey")) (EBinOp "++" (EVar "cellHoles") (EVar "goalHoles"))))))
(DTypeSig false "holeKey" (TyFun (TyTuple (TyCon "String") (TyCon "TcDiag")) (TyCon "String")))
(DFunDef false "holeKey" ((PTuple (PVar "m") (PCon "TcDiag" PWild PWild (PVar "loc") (PVar "msg") PWild PWild))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "lenKey") (EVar "m")))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EVar "lenKey") (EApp (EVar "locGoalKey") (EVar "loc"))))) (ELit (LString ""))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))
(DTypeSig false "judgeCells" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvCell"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))))))))
(DFunDef false "judgeCells" ((PVar "arr") (PVar "i") (PVar "hi") (PVar "acc")) (EIf (EBinOp "||" (EBinOp ">=" (EVar "i") (EVar "hi")) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr")))) (EVar "acc") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (arm (PCon "Some" (PVar "c")) () (EMatch (EFieldAccess (EFieldAccess (EVar "c") "ecArity") "value") (arm (PCon "Some" PWild) () (EBlock (DoLet false false (PVar "row") (EApp (EApp (EApp (EApp (EApp (EVar "OccurrenceRow") (EFieldAccess (EFieldAccess (EVar "c") "ecName") "value")) (EFieldAccess (EFieldAccess (EVar "c") "ecIface") "value")) (EFieldAccess (EFieldAccess (EVar "c") "ecTag") "value")) (EFieldAccess (EFieldAccess (EVar "c") "ecImpl") "value")) (EFieldAccess (EFieldAccess (EVar "c") "ecMeth") "value"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "judgeCells") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "hi")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "holeDiags") (EApp (EVar "evIdModule") (EFieldAccess (EVar "c") "ecId"))) (EFieldAccess (EFieldAccess (EVar "c") "ecLoc") "value")) (EFieldAccess (EFieldAccess (EVar "c") "ecInner") "value")) (EVar "row")) (EVar "acc")))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "judgeCells") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "hi")) (EVar "acc"))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "judgeCells") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "hi")) (EVar "acc")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "judgeGoal" (TyFun (TyCon "String") (TyFun (TyCon "Obligation") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))))))
(DFunDef false "judgeGoal" ((PVar "mid") (PVar "o")) (EMatch (ETuple (EFieldAccess (EVar "o") "oPayload") (EApp (EVar "evValueOf") (EFieldAccess (EVar "o") "oDest"))) (arm (PTuple (PCon "GPDictApp" (PVar "app")) (PCon "EvMany" (PVar "rs"))) () (EApp (EApp (EApp (EApp (EVar "holeDiags") (EVar "mid")) (EFieldAccess (EVar "o") "oLoc")) (EFieldAccess (EFieldAccess (EVar "o") "oInner") "value")) (EApp (EApp (EApp (EVar "DictAppRow") (EFieldAccess (EVar "app") "pdaCallee")) (EApp (EApp (EVar "map") (ELam ((PVar "r")) (EFieldAccess (EVar "r") "irName"))) (EFieldAccess (EVar "app") "pdaIfaces"))) (EVar "rs")))) (arm (PTuple (PCon "GPRecDictApp" (PCon "RecDictApp" PWild (PVar "callee") PWild PWild PWild PWild)) (PCon "EvMany" (PVar "rs"))) () (EApp (EApp (EApp (EApp (EVar "holeDiags") (EVar "mid")) (EFieldAccess (EVar "o") "oLoc")) (EFieldAccess (EFieldAccess (EVar "o") "oInner") "value")) (EApp (EApp (EApp (EVar "DictAppRow") (EVar "callee")) (EListLit)) (EVar "rs")))) (arm (PTuple (PCon "GPArith" PWild) (PCon "EvOne" (PVar "r"))) () (EApp (EApp (EApp (EApp (EVar "holeDiags") (EVar "mid")) (EFieldAccess (EVar "o") "oLoc")) (EFieldAccess (EFieldAccess (EVar "o") "oInner") "value")) (EApp (EVar "SiteRow") (EVar "r")))) (arm (PTuple (PCon "GPSite" PWild PWild PWild) (PCon "EvOne" (PVar "r"))) () (EIf (EBinOp "||" (EBinOp "==" (EApp (EVar "goalKindTag") (EFieldAccess (EVar "o") "oKind")) (EApp (EVar "goalKindTag") (EVar "GKBinopSite"))) (EBinOp "==" (EApp (EVar "goalKindTag") (EFieldAccess (EVar "o") "oKind")) (EApp (EVar "goalKindTag") (EVar "GKUnopSite")))) (EApp (EApp (EApp (EApp (EVar "holeDiags") (EVar "mid")) (EFieldAccess (EVar "o") "oLoc")) (EFieldAccess (EFieldAccess (EVar "o") "oInner") "value")) (EApp (EVar "SiteRow") (EVar "r"))) (EListLit))) (arm PWild () (EListLit))))
(DTypeSig false "holeDiags" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Inner") (TyFun (TyCon "EvidenceRow") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))))))))
(DFunDef false "holeDiags" ((PVar "mid") (PVar "loc") (PVar "inner") (PVar "row")) (EMatch (EApp (EApp (EVar "rowHoleWith") (EVar "inner")) (EVar "row")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple PWild (PVar "msg"))) () (EListLit (ETuple (EVar "mid") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (EVar "TUnroutedDispatch")) (ELit (LInt 1))) (EVar "loc")) (EVar "msg")) (EVar "None")) (EVar "None")))))))
(DTypeSig false "materializeBinderTypes" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyCon "Unit"))))
(DFunDef false "materializeBinderTypes" ((PVar "gctx") PWild) (EBlock (DoLet false false (PVar "g") (EFieldAccess (EVar "gctx") "graphRun")) (DoExpr (EMatch (EFieldAccess (EFieldAccess (EVar "g") "binderPending") "value") (arm (PList) () (ELit LUnit)) (arm (PVar "pending") () (EBlock (DoLet false false (PVar "cells") (EApp (EVar "cellTypeHeads") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "declEnvsRef") "value") "deAllDecls"))) (DoLet false false (PVar "isCell") (ELam ((PVar "n") (PVar "o")) (EApp (EApp (EVar "omHasKey") (EApp (EApp (EVar "cellHeadKey") (EVar "n")) (EVar "o"))) (EVar "cells")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "binderRows")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "p")) (EApp (EApp (EVar "addBinderRow") (EApp (EApp (EVar "materializeBinder") (EVar "isCell")) (EVar "p"))) (EVar "acc")))) (EFieldAccess (EFieldAccess (EVar "g") "binderRows") "value")) (EApp (EVar "reverseL") (EVar "pending"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "binderPending")) (EListLit)))))))))
(DTypeSig false "materializeBinder" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyCon "Bool"))) (TyFun (TyCon "PendingBinder") (TyCon "BinderRow"))))
(DFunDef false "materializeBinder" ((PVar "isCell") (PCon "PendingBinder" (PVar "bid") (PVar "name") (PVar "t") (PVar "arity") (PVar "signed"))) (ERecordCreate "BinderRow" ((fa "brId" (EVar "bid")) (fa "brName" (EVar "name")) (fa "brType" (EApp (EApp (EVar "runtimeTypeOf") (EVar "isCell")) (EVar "t"))) (fa "brReturns" (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EApp (EApp (EVar "optionOr") (EVar "RTValue")) (EApp (EApp (EVar "map") (EApp (EVar "runtimeTypeOf") (EVar "isCell"))) (EApp (EApp (EVar "resultAfterArrows") (EVar "n")) (EVar "t")))))) (EVar "arity"))) (fa "brSigned" (EVar "signed")))))
(DTypeSig false "cellTypeHeads" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))
(DFunDef false "cellTypeHeads" ((PVar "decls")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "d")) (EApp (EApp (EVar "addCellHead") (EVar "d")) (EVar "acc")))) (EVar "omEmpty")) (EVar "decls")))
(DTypeSig false "addCellHead" (TyFun (TyCon "Decl") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "addCellHead" ((PRec "DData" ((rf "dataName" (PVar "n")) (rf "dataOrigin" (PVar "o")) (rf "dataExtern" (PVar "ext"))) true) (PVar "acc")) (EIf (EVar "ext") (EVar "acc") (EApp (EApp (EApp (EVar "omInsert") (EApp (EApp (EVar "cellHeadKey") (EVar "n")) (EVar "o"))) (ELit LUnit)) (EVar "acc"))))
(DFunDef false "addCellHead" ((PRec "DNewtype" ((rf "newtypeName" (PVar "n")) (rf "newtypeOrigin" (PVar "o"))) true) (PVar "acc")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EApp (EVar "cellHeadKey") (EVar "n")) (EVar "o"))) (ELit LUnit)) (EVar "acc")))
(DFunDef false "addCellHead" ((PCon "DAttrib" PWild (PVar "d")) (PVar "acc")) (EApp (EApp (EVar "addCellHead") (EVar "d")) (EVar "acc")))
(DFunDef false "addCellHead" (PWild (PVar "acc")) (EVar "acc"))
(DTypeSig false "cellHeadKey" (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyCon "String"))))
(DFunDef false "cellHeadKey" ((PVar "n") (PCon "OriginBuiltin")) (EBinOp "++" (EBinOp "++" (ELit (LString "builtin|")) (EApp (EVar "display") (EVar "n"))) (ELit (LString ""))))
(DFunDef false "cellHeadKey" ((PVar "n") (PCon "OriginUnresolved")) (EBinOp "++" (EBinOp "++" (ELit (LString "unresolved|")) (EApp (EVar "display") (EVar "n"))) (ELit (LString ""))))
(DFunDef false "cellHeadKey" ((PVar "n") (PCon "OriginModule" (PVar "m"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "module ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "|"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString ""))))
(DTypeSig false "runStampCtxs" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "StampCtx")) (TyApp (TyCon "List") (TyCon "DrainFinding")))))
(DFunDef false "runStampCtxs" ((PVar "saved") (PVar "ctxs")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "ctx")) (EBinOp "++" (EApp (EVar "reverseL") (EApp (EApp (EVar "runStampCtx") (EVar "saved")) (EVar "ctx"))) (EVar "acc")))) (EListLit)) (EVar "ctxs"))))
(DTypeSig false "runStampCtx" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "StampCtx") (TyApp (TyCon "List") (TyCon "DrainFinding")))))
(DFunDef false "runStampCtx" ((PVar "saved") (PVar "ctx")) (EBlock (DoLet false false (PVar "stamp") (EApp (EApp (EVar "enterStampCtx") (EVar "saved")) (EVar "ctx"))) (DoExpr (EApp (EApp (EVar "refileDeterminedRows") (EVar "stamp")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "runStampSteps") (EVar "stamp")) (EVar "ctx")) (EVar "moduleStampOrder"))) (DoExpr (EApp (EApp (EVar "recordEvidence") (EFieldAccess (EVar "saved") "mcGraph")) (EFieldAccess (EVar "ctx") "scGoals"))) (DoLet false false (PVar "liveSpans") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "ctx") "scLiveLocs")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "d")) (EApp (EApp (EApp (EVar "verdictFinding") (EFieldAccess (EVar "ctx") "scModule")) (EApp (EApp (EVar "isLiveSpan") (EVar "liveSpans")) (EApp (EVar "tcLoc") (EVar "d")))) (EVar "d")))) (EApp (EApp (EVar "captureTypeErrors") (EVar "stamp")) (ELam (PWild) (EApp (EApp (EVar "checkAdmittedOccObls") (EVar "stamp")) (ELit LUnit))))))))
(DTypeSig false "recordEvidence" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Obligation")) (TyCon "Unit"))))
(DFunDef false "recordEvidence" ((PVar "gctx") (PVar "gs")) (EBlock (DoLet false false (PVar "g") (EFieldAccess (EVar "gctx") "graphRun")) (DoExpr (EApp (EApp (EVar "each") (EApp (EVar "noteEvidenceObservation") (EVar "gctx"))) (EVar "gs"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "evTable")) (EBinOp "++" (EApp (EVar "evEntriesOf") (EVar "gs")) (EFieldAccess (EFieldAccess (EVar "g") "evTable") "value"))))))
(DTypeSig false "evEntriesOf" (TyFun (TyApp (TyCon "List") (TyCon "Obligation")) (TyCon "EvTable")))
(DFunDef false "evEntriesOf" ((PVar "gs")) (EApp (EApp (EVar "map") (ELam ((PVar "o")) (EApp (EApp (EVar "EvEntry") (EFieldAccess (EVar "o") "oEv")) (EApp (EVar "evValueOf") (EFieldAccess (EVar "o") "oDest"))))) (EVar "gs")))
(DTypeSig false "evValueOf" (TyFun (TyCon "EvDest") (TyCon "EvVal")))
(DFunDef false "evValueOf" ((PCon "EvRoute" (PVar "r"))) (EApp (EVar "EvOne") (EUnOp "!" (EVar "r"))))
(DFunDef false "evValueOf" ((PCon "EvRoutes" (PVar "rs"))) (EApp (EVar "EvMany") (EUnOp "!" (EVar "rs"))))
(DTypeSig false "beginModuleMarking" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "ModuleSeed") (TyCon "Unit")))))))
(DFunDef false "beginModuleMarking" ((PVar "mctx") (PVar "mid") (PVar "prog") (PVar "top") (PVar "seed")) (EBlock (DoLet false false (PVar "ms") (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "markSetsRef") "value") (arm (PCon "Some" (PVar "s")) () (EVar "s")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "checkBodyImpl: Module arm entered with no mark sets (no driver preamble ran)")))))) (DoLet false false (PVar "known") (EMatch (EVar "mid") (arm (PLit (LString "")) () (EApp (EVar "constrainedSigNames") (EVar "prog"))) (arm PWild () (EApp (EVar "dedup") (EBinOp "++" (EFieldAccess (EVar "ms") "msBareDictNames") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "promotionHarvestRef") "value")))))) (DoLet false false (PVar "aliases") (EApp (EApp (EApp (EApp (EVar "aliasDictNames") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "known")) (EFieldAccess (EVar "ms") "msUnits")) (EListLit (ETuple (EVar "mid") (EVar "prog"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "localAbs") "lasNext")) (ETuple (EVar "mid") (ELit (LInt 0))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "localAbs") "lasMinted")) (EListLit))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "markingRef")) (EApp (EVar "Some") (ERecordCreate "ModuleMarking" ((fa "mmCtx" (EApp (EApp (EApp (EApp (EApp (EVar "moduleMarkCtx") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ms")) (EVar "mid")) (EVar "prog")) (EFieldAccess (EVar "seed") "msImportedValues"))) (fa "mmTop" (EVar "top")) (fa "mmDictSet" (EApp (EVar "Ref") (EApp (EApp (EVar "omFromNames") (EBinOp "++" (EVar "known") (EVar "aliases"))) (EVar "omEmpty")))) (fa "mmUserNames" (EApp (EApp (EVar "omFromNames") (EApp (EVar "declTopFnNames") (EVar "prog"))) (EFieldAccess (EVar "seed") "msImportedNames"))) (fa "mmExterns" (EApp (EApp (EVar "omFromNames") (EApp (EVar "declExternNames") (EVar "prog"))) (EFieldAccess (EVar "seed") "msImportedExterns"))))))))))
(DTypeSig false "stampGroupClauses" (TyFun (TyCon "ModuleMarking") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))))
(DFunDef false "stampGroupClauses" ((PVar "mm") (PVar "members") (PVar "grouped")) (EApp (EApp (EApp (EVar "mapGroupClauses") (EApp (EVar "stampClauseWith") (EFieldAccess (EVar "mm") "mmTop"))) (EVar "members")) (EVar "grouped")))
(DTypeSig false "finishModuleMarking" (TyFun (TyCon "ModuleMarking") (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "finishModuleMarking" ((PVar "mm") (PVar "env") (PVar "grouped") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EVar "markTailDecls") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EVar "mm") "mmCtx")) (EFieldAccess (EFieldAccess (EVar "mm") "mmDictSet") "value")) (EApp (EVar "grantNameIn") (EVar "env"))) (EApp (EApp (EVar "rebuildGroupDecls") (EVar "grouped")) (EVar "prog"))))
(DTypeSig false "stampTailDecls" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "stampTailDecls" ((PVar "top") (PVar "decls")) (EApp (EApp (EVar "map") (EApp (EVar "stampTailDecl") (EVar "top"))) (EVar "decls")))
(DTypeSig false "stampTailDecl" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "stampTailDecl" (PWild (PAs "d" (PCon "DFunDef" PWild PWild PWild PWild PWild PWild))) (EVar "d"))
(DFunDef false "stampTailDecl" (PWild (PAs "d" (PCon "DLetGroup" PWild PWild))) (EVar "d"))
(DFunDef false "stampTailDecl" ((PVar "top") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EVar "stampTailDecl") (EVar "top")) (EVar "d"))))
(DFunDef false "stampTailDecl" ((PVar "top") (PVar "d")) (EApp (EApp (EVar "stampDeclWith") (EVar "top")) (EVar "d")))
(DTypeSig false "methodReturnProbeStamp" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodSchemeRow") (TyFun (TyCon "MethodSchemeRow") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")))))))
(DFunDef false "methodReturnProbeStamp" ((PVar "prev") (PVar "ownedRow") (PVar "foreignRow") (PVar "impls")) (EBlock (DoLet false false (PVar "gctx") (EVariantUpdate "GraphCtx" (EFieldAccess (EVar "prev") "mcGraph") ((fa "graphRun" (EApp (EVar "freshGraphRun") (ELit LUnit)))))) (DoLet false false (PVar "mctx") (EApp (EApp (EVar "carryModuleCtx") (EVar "gctx")) (EVar "prev"))) (DoLet false false (PVar "scope") (EApp (EApp (EVar "methodReturnProbeScope") (EVar "mctx")) (ELit (LString "return-owner-stamper")))) (DoLet false false (PVar "request") (EApp (EApp (EVar "methodReturnProbeRequest") (EVar "mctx")) (EVar "ownedRow"))) (DoExpr (EApp (EApp (EVar "methodReturnProbeSpelling") (EVar "mctx")) (EVar "foreignRow"))) (DoLet false false (PVar "env") (EApp (EVar "buildFlatImplEnv") (EVar "impls"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "bodyImplEnvRef")) (EVar "env"))) (DoLet false false (PVar "tagRef") (EApp (EVar "Ref") (EVar "RNone"))) (DoLet false false (PVar "implRef") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "resultMono") (EApp (EVar "stripArrows") (EFieldAccess (EVar "request") "mrrOccurrence"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveExactReturnSite") (EApp (EVar "siteFor") (EVar "mctx"))) (EVar "omEmpty")) (ELit (LString "make"))) (EVar "tagRef")) (EVar "implRef")) (EVar "resultMono")) (EVar "request")) (ELit (LString ""))) (EVar "None")) (EVar "scope"))) (DoLet false false (PVar "goals") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "methodReturnArgs") (EVar "gctx")) (EVar "request")))) (DoLet false false (PVar "ownedKey") (EMatch (EApp (EApp (EApp (EApp (EVar "ieSelectRowByIface") (EApp (EVar "siteFor") (EVar "mctx"))) (EVar "env")) (EFieldAccess (EVar "ownedRow") "msrIface")) (EVar "goals")) (arm (PCon "Some" (PVar "selected")) () (EApp (EVar "rowRouteKey") (EVar "selected"))) (arm (PCon "None") () (ELit (LString ""))))) (DoLet false false (PVar "foreignKey") (EMatch (EApp (EApp (EApp (EApp (EVar "ieSelectRowByIface") (EApp (EVar "siteFor") (EVar "mctx"))) (EVar "env")) (EFieldAccess (EVar "foreignRow") "msrIface")) (EVar "goals")) (arm (PCon "Some" (PVar "selected")) () (EApp (EVar "rowRouteKey") (EVar "selected"))) (arm (PCon "None") () (ELit (LString ""))))) (DoExpr (ETuple (EApp (EVar "methodReturnProbeRouteKey") (EFieldAccess (EVar "tagRef") "value")) (EVar "ownedKey") (EVar "foreignKey")))))
(DTypeSig false "methodReturnOwnershipProbe" (TyFun (TyCon "Unit") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool") (TyCon "Bool"))))
(DFunDef false "methodReturnOwnershipProbe" (PWild) (EBlock (DoLet false false (PVar "ownedGraph") (EApp (EVar "probeGraphCtx") (ELit LUnit))) (DoLet false false (PVar "ownedDecl") (EApp (EApp (EApp (EVar "methodReturnProbeIface") (ELit (LString "return-owner"))) (ELit (LString "Owner"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Unit"))) (EVar "None"))) (EApp (EVar "TyVar") (ELit (LString "a")))))) (DoLet false false (PVar "foreignDecl") (EApp (EApp (EApp (EVar "methodReturnProbeIface") (ELit (LString "return-foreign"))) (ELit (LString "Foreign"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Unit"))) (EVar "None"))) (EApp (EVar "TyVar") (ELit (LString "a")))))) (DoLet false false (PVar "ownedCtx") (EApp (EVar "initialModuleCtx") (EVar "ownedGraph"))) (DoLet false false (PVar "ownedRow") (EApp (EVar "firstMethodRow") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "ownedCtx")) (EListLit (EVar "ownedDecl"))))) (DoLet false false (PVar "foreignGraph") (EVariantUpdate "GraphCtx" (EVar "ownedGraph") ((fa "graphRun" (EApp (EVar "freshGraphRun") (ELit LUnit)))))) (DoLet false false (PVar "foreignCtx") (EApp (EApp (EVar "carryModuleCtx") (EVar "foreignGraph")) (EVar "ownedCtx"))) (DoLet false false (PVar "foreignRow") (EApp (EVar "firstMethodRow") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "foreignCtx")) (EListLit (EVar "foreignDecl"))))) (DoLet false false (PVar "ownedImpl") (EApp (EApp (EVar "methodReturnProbeImpl") (ELit (LString "return-owner"))) (ELit (LString "Owner")))) (DoLet false false (PVar "foreignImpl") (EApp (EApp (EVar "methodReturnProbeImpl") (ELit (LString "return-foreign"))) (ELit (LString "Foreign")))) (DoLet false false (PTuple (PVar "rejected") (PVar "rejectedCtx")) (EApp (EApp (EApp (EVar "methodReturnProbeCodes") (EVar "foreignCtx")) (EVar "ownedRow")) (EListLit (EVar "foreignImpl")))) (DoLet false false (PTuple (PVar "accepted") (PVar "acceptedCtx")) (EApp (EApp (EApp (EVar "methodReturnProbeCodes") (EVar "rejectedCtx")) (EVar "ownedRow")) (EListLit (EVar "foreignImpl") (EVar "ownedImpl")))) (DoLet false false (PTuple (PVar "actualKey") (PVar "ownedKey") (PVar "foreignKey")) (EApp (EApp (EApp (EApp (EVar "methodReturnProbeStamp") (EVar "acceptedCtx")) (EVar "ownedRow")) (EVar "foreignRow")) (EListLit (EVar "foreignImpl") (EVar "ownedImpl")))) (DoLet false false (PVar "observed") (ETuple (EVar "rejected") (EVar "accepted") (EBinOp "==" (EVar "actualKey") (EVar "ownedKey")) (EBinOp "/=" (EVar "actualKey") (EVar "foreignKey")))) (DoExpr (EVar "observed"))))
# MARK
(DUse false (UseGroup ("support" "diag_codes") ((mem "DiagCode" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "BinderId" true) (mem "ConPayload" true) (mem "Decl" true) (mem "EvEntry" true) (mem "EvVal" true) (mem "Expr" true) (mem "ExternDecl" true) (mem "FunClause" true) (mem "Ident" true) (mem "LetBind" true) (mem "Loc" true) (mem "Ns" true) (mem "Pat" true) (mem "PropParam" true) (mem "Route" true) (mem "Super" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "UseMember" true) (mem "UsePath" true) (mem "Variant" true) (mem "EvTable" false) (mem "identOriginFold" false) (mem "mkIdent" false) (mem "tyConBuiltin" false))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderRow" true) (mem "RuntimeType" true) (mem "addBinderRow" false) (mem "runtimeTypeOf" false))))
(DUse false (UseGroup ("types" "scopes") ((mem "ScopeOwner" true))))
(DUse false (UseGroup ("types" "tc_types") ((mem "BuiltinClasses" true) (mem "CeRow" true) (mem "CheckRunSeed" true) (mem "ClassEnv" true) (mem "ConstraintReg" true) (mem "DeclaringBinder" true) (mem "DeclEnvModule" true) (mem "DrainFinding" true) (mem "EnvBinding" true) (mem "EvCell" true) (mem "EvDest" true) (mem "EvidenceObservationEntry" true) (mem "EvidenceOutcomeKind" true) (mem "GoalKind" true) (mem "GoalPayload" true) (mem "GraphCtx" true) (mem "GraphMarks" true) (mem "GroupCtx" true) (mem "ImplEnv" true) (mem "LiveGoal" true) (mem "MethodPredicateSlot" true) (mem "MethodSchemeRow" true) (mem "ModuleBindings" true) (mem "ModuleCtx" true) (mem "ModuleMarking" true) (mem "ModuleSeed" true) (mem "NumBoundary" true) (mem "NumBoundaryDisposition" true) (mem "NumGuard" true) (mem "Obligation" true) (mem "ObligationSite" true) (mem "PendingBinder" true) (mem "PendingEntry" true) (mem "RecDictApp" true) (mem "RecordInfo" true) (mem "ScopedMember" true) (mem "ScopedScheme" true) (mem "SiteCtx" true) (mem "SiteKind" true) (mem "StampCtx" true) (mem "StampStep" true) (mem "StandaloneOrigin" true) (mem "TcEnv" true) (mem "dynFor" false) (mem "siteFor" false))))
(DUse false (UseGroup ("types" "evidence_complete") ((mem "EvidenceRow" true) (mem "Inner" true) (mem "innerNone" false) (mem "innerOr" false) (mem "rowHoleWith" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Mono" true) (mem "Scheme" true) (mem "VecObl" true) (mem "normalize" false) (mem "ppMono" false))))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omDelete" false) (mem "omEmpty" false) (mem "omFromNames" false) (mem "omFromPairs" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omKeys" false) (mem "omLookup" false) (mem "omMapValues" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("types" "evidence") ((mem "ScopeId" true))))
(DUse false (UseGroup ("types" "registry") ((mem "regEmpty" false) (mem "regKeyOfTab" false) (mem "regKeyRender" false) (mem "SpellingPop" false) (mem "spEmpty" false) (mem "spFloor" false) (mem "spLookupIdent" false))))
(DUse false (UseGroup ("types" "effect_solver") ((mem "SummaryFailure" false))))
(DUse false (UseGroup ("types" "publish") ((mem "TcDiag" true) (mem "tcLoc" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "addCtor" false) (mem "attachStandaloneSources" false) (mem "bindingWithStandalone" false) (mem "buildFlatImplEnv" false) (mem "ceLookupAt" false) (mem "ceRowDoneKey" false) (mem "ceRowIface" false) (mem "ceRowIfaceName" false) (mem "ceRowLoc" false) (mem "ceRowOrd" false) (mem "ceRowSupers" false) (mem "ceRowsVisibleAt" false) (mem "ctorExportsIndex" false) (mem "declEnvRowVisible" false) (mem "declEnvsOrdOf" false) (mem "declTopFnNames" false) (mem "emptyMethodModulePredicateSlots" false) (mem "extendBindings" false) (mem "extendLocalVar" false) (mem "extendMethodRows" false) (mem "extendTermBindings" false) (mem "extendVars" false) (mem "funDefs" false) (mem "graphPubDefiners" false) (mem "ieUniverseAt" false) (mem "ifaceMethodNames" false) (mem "ifaceTabKey" false) (mem "importedBindings" false) (mem "importLocFor" false) (mem "importTableMid" false) (mem "legacyMethodSchemes" false) (mem "methodRowsByIdentity" false) (mem "methodSlotKey" false) (mem "namesToSet" false) (mem "ordinaryEnvBinding" false) (mem "publicDataDecl" false) (mem "publicDataDecls" false) (mem "withCtors" false))))
(DUse false (UseGroup ("types" "tc_decls") ((mem "addFieldOwners" false) (mem "builtinClassesGo" false) (mem "builtinClassesOf" false) (mem "declEnvSeedDataUniverse" false) (mem "ifaceMethodSchemeRows" false) (mem "isAliasDecl" false) (mem "loadDataUniverse" false) (mem "recordDeclKinds" false) (mem "registerAllData" false) (mem "registerAllDataScoped" false) (mem "registerData" false) (mem "rejectCyclicAliases" false) (mem "seedNumLitFromIntAnchor" false) (mem "sigToScheme" false))))
(DUse false (UseGroup ("types" "tc_scope") ((mem "aliasConstraintEntries" false) (mem "aliasDictNames" false) (mem "aliasMethodSpellings" false) (mem "aliasQualifiedMethodEntries" false) (mem "annotateImportedMethodRows" false) (mem "applyCtorScopeOverrides" false) (mem "applyRecordScopeOverrides" false) (mem "declCtorNamed" false) (mem "importedMemberBindingNames" false) (mem "insertCtorPop" false) (mem "insertRecordPop" false) (mem "methodNameDeclaredAt" false) (mem "pickSchemesByDecl" false) (mem "reportAmbiguousImportsIn" false) (mem "resolveMemberRows" false) (mem "schemeOblEntriesFor" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "containsI" false) (mem "dedupI" false) (mem "findTvarInMonos" false) (mem "monoArgUnboundIds" false) (mem "monoScheme" false) (mem "monoUnboundIds" false) (mem "resultAfterArrows" false) (mem "schemeMono" false) (mem "stripArrows" false) (mem "tconBuiltin" false) (mem "tconUnresolved" false) (mem "tyVarNames" false) (mem "unquantifiedAuthIds" false))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "dedup" false) (mem "dedupBy" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "isSome" false) (mem "joinWith" false) (mem "lenKey" false) (mem "listLen" false) (mem "orElseOpt" false) (mem "reverseL" false))))
(DUse false (UseGroup ("types" "tc_occurrence") ((mem "argDispatchIndicesById" false) (mem "constrainedSigNames" false) (mem "evIdModule" false) (mem "firstMethodRow" false) (mem "mapGroupClauses" false) (mem "markGroupClauses" false) (mem "markRecursiveOccurrences" false) (mem "markTailDecls" false) (mem "methodReturnProbeCodes" false) (mem "methodReturnProbeRequest" false) (mem "rebuildGroupDecls" false))))
(DUse false (UseGroup ("types" "tc_solve") ((mem "arithEntry" false) (mem "currentModuleMarks" false) (mem "determineByUniqueInstance" false) (mem "dictAppEntry" false) (mem "dropGoalsSince" false) (mem "goalKindName" false) (mem "goalKindTag" false) (mem "goalMonos" false) (mem "goalsMark" false) (mem "goalsOfKindIn" false) (mem "goalsSince" false) (mem "improveByUniqueImpl" false) (mem "methodDictEntry" false) (mem "methodReturnArgs" false) (mem "methodReturnProbeIface" false) (mem "methodReturnProbeImpl" false) (mem "methodReturnProbeRouteKey" false) (mem "methodReturnProbeScope" false) (mem "methodReturnProbeSpelling" false) (mem "openScope" false) (mem "outerRigidIds" false) (mem "recDictAppEntry" false) (mem "refileDeterminedRows" false) (mem "returnPosMethodNames" false) (mem "routesOfMonosTopV" false) (mem "siteEntry" false) (mem "uOblArgs" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "authvarId" false) (mem "authVars" false))))
(DUse false (UseGroup ("types" "tc_effects") ((mem "beginEffectSummaryScope" false) (mem "borrowedEffectCells" false) (mem "checkEffectEscape" false) (mem "checkUndeterminedRetEffVars" false) (mem "clausesOf" false) (mem "finishEffectSummaryScopeKeeping" false) (mem "flushPendingEscapes" false) (mem "freshEffectSummary" false) (mem "grantNameIn" false) (mem "memberEffectRoots" false) (mem "recordFileBound" false) (mem "recordMethodGrants" false) (mem "recordTopGrants" false) (mem "reportEffectSummaryFailures" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "blankModuleCtx" false) (mem "callUOblsWindow" false) (mem "carryModuleCtx" false) (mem "checkRunResidue" false) (mem "currentScopeStore" false) (mem "dynAtIfSome" false) (mem "enterStampCtx" false) (mem "envAtIfSome" false) (mem "freshGraphRun" false) (mem "freshModuleCtx" false) (mem "initialModuleCtx" false) (mem "mctxAt" false) (mem "moduleCtxFrom" false) (mem "moduleWindow" false) (mem "plainModuleSeed" false) (mem "probeGraphCtx" false) (mem "seedCheckRun" false) (mem "wMark" false) (mem "wWindow" false))))
(DUse false (UseGroup ("types" "tc_solve_check") ((mem "callOblsWindow" false) (mem "checkCallObligationsU" false) (mem "checkSigVarGoals" false) (mem "dedupPredicateSlotsTable" false) (mem "defaultLiveNumRoots" false) (mem "finalizeNumBoundary" false) (mem "liveNumVarGo" false) (mem "numConstrainedIds" false) (mem "predicateSlotTableWithoutArgs" false) (mem "registerConstraintRegs" false) (mem "registerInferredConstraints" false) (mem "rejectUndeterminedVectors" false) (mem "rejectWithheldAmbiguity" false) (mem "setFunPredicateSlots" false) (mem "tiedSurvivors" false) (mem "undeterminedVectorVerdict" false))))
(DUse false (UseGroup ("types" "tc_global") ((mem "calleeNumObls" false) (mem "checkCoherence" false) (mem "checkGradedImplHeads" false) (mem "checkImplCompletenessMap" false) (mem "checkPhantomMethods" false) (mem "checkSuperImpls" false) (mem "inferDefaultBodies" false) (mem "inferUserImplBodies" false) (mem "numCallObls" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "captureScope" false) (mem "closeScope" false) (mem "enterLevel" false) (mem "exitLevel" false) (mem "freshTvMap" false) (mem "freshVar" false) (mem "generalize" false) (mem "resolvePendingJoins" false) (mem "rowInto" false) (mem "unifyIn" false) (mem "unifyInto" false) (mem "widenOpenedFor" false))))
(DUse false (UseGroup ("types" "tc_shadow") ((mem "checkAdmittedOccObls" false) (mem "definerShadowsFromSet" false) (mem "isPreludeMid" false) (mem "moduleMarkCtx" false) (mem "nameableIfaceMethodSet" false) (mem "nameableIfaceRows" false) (mem "nameableIfaceShadows" false) (mem "resolveRLocalSite" false) (mem "standaloneShadowsFromSet" false))))
(DUse false (UseGroup ("types" "tc_decls_types") ((mem "checkDeclaredKinds" false) (mem "checkDeclAuthorityUses" false) (mem "checkEffectParams" false) (mem "fromAstType" false))))
(DUse false (UseGroup ("types" "tc_infer") ((mem "checkDeferredMatches" false) (mem "checkFixedWidthLiterals" false) (mem "checkWideLiterals" false) (mem "declareRigidVars" false) (mem "infer" false) (mem "inferMemberClauses" false) (mem "preunifySigsEx" false) (mem "valueSpanLoc" false))))
(DUse false (UseGroup ("types" "tc_groups") ((mem "checkLetRecDecls" false) (mem "checkRecursiveValue" false) (mem "checkSigConstraintCoverage" false) (mem "checkSigsFixedByExpansive" false) (mem "checkSigsOverExpansive" false) (mem "checkSigsTooGeneral" false) (mem "declRefNames" false) (mem "depGraphMap" false) (mem "groupClauses" false) (mem "groupNames" false) (mem "isLetrecGroup" false) (mem "memberForce" false) (mem "nestedRequireGoals" false) (mem "quantifiableAuthorities" false) (mem "registerSchemeObligations" false) (mem "sccProtectedSignatureIds" false) (mem "sccSchemes" false))))
(DUse false (UseGroup ("types" "tc_diag_text") ((mem "cyclicSuperIfaceMsg" false) (mem "locGoalKey" false) (mem "locKey" false) (mem "ordinalSentinelMsg" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "effrowNorm" false) (mem "pureRow" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "exprSpanLoc" false) (mem "joinLocs" false))))
(DUse false (UseGroup ("types" "tc_foreign") ((mem "declExternNames" false) (mem "directExternSigs" false) (mem "externDecls" false) (mem "ffiCheckExternsCatalogRow" false) (mem "ffiCheckExternsCrossable" false) (mem "ffiCheckExternsLabelled" false) (mem "ffiCheckExternsShadow" false) (mem "ffiStampMode" false))))
(DUse false (UseGroup ("frontend" "resolve") ((mem "externTyOriginScope" false) (mem "firstExprLoc" false) (mem "stampClauseWith" false) (mem "stampDeclWith" false) (mem "stampTopScope" false) (mem "stampTyOrigins" false))))
(DUse false (UseGroup ("list") ((mem "findMap" false) (mem "sortOn" false))))
(DUse false (UseGroup ("types" "tc_solve_entail") ((mem "ieSelectRowByIface" false) (mem "rowRouteKey" false))))
(DUse false (UseGroup ("types" "effect_bindings") ((mem "newBindingSummary" false))))
(DUse false (UseGroup ("types" "tc_diag") ((mem "pushTypeError" false) (mem "pushTypeErrorAt" false))))
(DUse false (UseGroup ("types" "tc_elab") ((mem "realizeRecDictApps" false) (mem "resolveAdmittedSite" false) (mem "resolveArgStamps" false) (mem "resolveArithSite" false) (mem "resolveDictApps" false) (mem "resolveExactReturnSite" false) (mem "resolveMethodDicts" false) (mem "resolveNumLitSite" false) (mem "resolveOpSite" false) (mem "resolvePredicateOpSite" false) (mem "resolveSite" false) (mem "selfDeclArities" false))))
(DUse false (UseGroup ("types" "tc_pat") ((mem "recordBinderType" false) (mem "settleDeferredPatLits" false))))
(DUse false (UseGroup ("types" "tc_infer_records") ((mem "recordFieldNames" false))))
(DUse false (UseGroup ("types" "invocation_basis") ((mem "recordInvocationView" false))))
(DUse false (UseGroup ("types" "tc_decls_variance") ((mem "seedParamPolarityFixpointScoped" false))))
(DUse false (UseGroup ("support" "scc") ((mem "tarjanSCCs" false))))
(DUse false (UseGroup ("frontend" "visibility") ((mem "useModId" false))))
(DUse false (UseAlias ("map") "IdMap"))
(DUse false (UseAlias ("types" "effect_solver") "EffectSolver"))
(DUse false (UseAlias ("types" "scopes") "Scopes"))
(DTypeSig false "obligationRoutes" (TyFun (TyCon "Obligation") (TyApp (TyCon "List") (TyCon "Route"))))
(DFunDef false "obligationRoutes" ((PVar "o")) (EMatch (EFieldAccess (EVar "o") "oDest") (arm (PCon "EvRoute" (PVar "r")) () (EListLit (EFieldAccess (EVar "r") "value"))) (arm (PCon "EvRoutes" (PVar "rs")) () (EFieldAccess (EVar "rs") "value"))))
(DTypeSig false "obligationPredicateMonos" (TyFun (TyCon "Obligation") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Mono")))))
(DFunDef false "obligationPredicateMonos" ((PVar "o")) (EMatch (EFieldAccess (EVar "o") "oPayload") (arm (PCon "GPSite" PWild (PVar "m") PWild) () (EListLit (EApp (EVar "Some") (EVar "m")))) (arm (PCon "GPArith" (PVar "m")) () (EListLit (EApp (EVar "Some") (EVar "m")))) (arm (PCon "GPDictApp" (PVar "app")) () (EApp (EApp (EMethodRef "map") (EVar "Some")) (EFieldAccess (EVar "app") "pdaMonos"))) (arm (PCon "GPMethodDict" (PVar "pmd")) () (EApp (EApp (EMethodRef "map") (ELam (PWild) (EVar "None"))) (EFieldAccess (EVar "pmd") "pmdSlots"))) (arm (PCon "GPRecDictApp" (PCon "RecDictApp" PWild PWild PWild (PVar "m") PWild PWild)) () (EListLit (EApp (EVar "Some") (EVar "m"))))))
(DTypeSig false "routeOutcomeKind" (TyFun (TyCon "Route") (TyCon "EvidenceOutcomeKind")))
(DFunDef false "routeOutcomeKind" ((PCon "RNone")) (EVar "EOKNone"))
(DFunDef false "routeOutcomeKind" ((PCon "RKey" PWild PWild PWild)) (EVar "EOKInstance"))
(DFunDef false "routeOutcomeKind" ((PCon "RDict" PWild)) (EVar "EOKGiven"))
(DFunDef false "routeOutcomeKind" ((PCon "RDictFwd" PWild)) (EVar "EOKGiven"))
(DFunDef false "routeOutcomeKind" ((PCon "RLocal" PWild PWild)) (EVar "EOKLocal"))
(DFunDef false "routeOutcomeKind" ((PCon "RScalar" PWild)) (EVar "EOKScalar"))
(DFunDef false "routeOutcomeKind" ((PCon "RProj" (PVar "r") PWild)) (EApp (EVar "routeOutcomeKind") (EVar "r")))
(DTypeSig false "routeGivenBinder" (TyFun (TyCon "Route") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "routeGivenBinder" ((PCon "RDict" (PVar "n"))) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "routeGivenBinder" ((PCon "RDictFwd" (PVar "n"))) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "routeGivenBinder" ((PCon "RProj" (PVar "r") PWild)) (EApp (EVar "routeGivenBinder") (EVar "r")))
(DFunDef false "routeGivenBinder" (PWild) (EVar "None"))
(DTypeSig false "routeInstanceKey" (TyFun (TyCon "Route") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "routeInstanceKey" ((PCon "RKey" (PVar "k") PWild PWild)) (EApp (EVar "Some") (EVar "k")))
(DFunDef false "routeInstanceKey" (PWild) (EVar "None"))
(DTypeSig false "routePrerequisiteRoutes" (TyFun (TyCon "Route") (TyApp (TyCon "List") (TyCon "Route"))))
(DFunDef false "routePrerequisiteRoutes" ((PCon "RKey" PWild (PVar "rs") PWild)) (EVar "rs"))
(DFunDef false "routePrerequisiteRoutes" ((PCon "RLocal" PWild (PVar "rs"))) (EVar "rs"))
(DFunDef false "routePrerequisiteRoutes" (PWild) (EListLit))
(DTypeSig false "renderRouteIdentity" (TyFun (TyCon "Route") (TyCon "String")))
(DFunDef false "renderRouteIdentity" ((PCon "RNone")) (ELit (LString "RNone")))
(DFunDef false "renderRouteIdentity" ((PCon "RKey" (PVar "k") PWild PWild)) (EBinOp "++" (ELit (LString "RKey ")) (EVar "k")))
(DFunDef false "renderRouteIdentity" ((PCon "RDict" (PVar "n"))) (EBinOp "++" (ELit (LString "RDict ")) (EVar "n")))
(DFunDef false "renderRouteIdentity" ((PCon "RDictFwd" (PVar "n"))) (EBinOp "++" (ELit (LString "RDictFwd ")) (EVar "n")))
(DFunDef false "renderRouteIdentity" ((PCon "RLocal" (PVar "n") PWild)) (EBinOp "++" (ELit (LString "RLocal ")) (EVar "n")))
(DFunDef false "renderRouteIdentity" ((PCon "RScalar" (PVar "n"))) (EBinOp "++" (ELit (LString "RScalar ")) (EVar "n")))
(DFunDef false "renderRouteIdentity" ((PCon "RProj" (PVar "r") (PVar "path"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "RProj (")) (EApp (EMethodRef "display") (EApp (EVar "renderRouteIdentity") (EVar "r")))) (ELit (LString ") "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EApp (EApp (EMethodRef "map") (EVar "intToString")) (EVar "path"))))) (ELit (LString ""))))
(DTypeSig false "noteEvidenceObservation" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Obligation") (TyCon "Unit"))))
(DFunDef false "noteEvidenceObservation" ((PVar "gctx") (PVar "o")) (EMatch (EFieldAccess (EVar "gctx") "trace") (arm (PCon "Some" (PVar "sink")) () (EIf (EFieldAccess (EVar "sink") "tsEvidenceObservationEnabled") (EBlock (DoLet false false (PVar "routes") (EApp (EVar "obligationRoutes") (EVar "o"))) (DoLet false false (PVar "predicates") (EApp (EVar "obligationPredicateMonos") (EVar "o"))) (DoLet false false (PVar "arity") (EApp (EVar "listLen") (EVar "routes"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "sink") "tsEvidenceObservationEntries")) (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EVar "evidenceObservationEntriesGo") (EVar "o")) (EVar "routes")) (EVar "predicates")) (EVar "arity")) (ELit (LInt 0))) (EFieldAccess (EFieldAccess (EVar "sink") "tsEvidenceObservationEntries") "value"))))) (ELit LUnit))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig false "evidenceObservationEntriesGo" (TyFun (TyCon "Obligation") (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Mono"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "EvidenceObservationEntry"))))))))
(DFunDef false "evidenceObservationEntriesGo" (PWild (PList) PWild PWild PWild) (EListLit))
(DFunDef false "evidenceObservationEntriesGo" ((PVar "o") (PCons (PVar "r") (PVar "rs")) (PVar "preds") (PVar "arity") (PVar "slot")) (EBlock (DoLet false false (PTuple (PVar "predHere") (PVar "predsRest")) (EMatch (EVar "preds") (arm (PCons (PVar "p") (PVar "ptail")) () (ETuple (EVar "p") (EVar "ptail"))) (arm (PList) () (ETuple (EVar "None") (EListLit))))) (DoExpr (EBinOp "::" (ERecordCreate "EvidenceObservationEntry" ((fa "eoeEv" (EFieldAccess (EVar "o") "oEv")) (fa "eoeGoalKind" (EApp (EVar "goalKindName") (EFieldAccess (EVar "o") "oKind"))) (fa "eoeSlot" (EVar "slot")) (fa "eoeArity" (EVar "arity")) (fa "eoePredicate" (EApp (EApp (EMethodRef "map") (EVar "ppMono")) (EVar "predHere"))) (fa "eoeOutcome" (EApp (EVar "routeOutcomeKind") (EVar "r"))) (fa "eoeGivenBinder" (EApp (EVar "routeGivenBinder") (EVar "r"))) (fa "eoeInstanceKey" (EApp (EVar "routeInstanceKey") (EVar "r"))) (fa "eoePrerequisites" (EApp (EApp (EMethodRef "map") (EVar "renderRouteIdentity")) (EApp (EVar "routePrerequisiteRoutes") (EVar "r")))) (fa "eoeScope" (EFieldAccess (EVar "o") "oScope")))) (EApp (EApp (EApp (EApp (EApp (EVar "evidenceObservationEntriesGo") (EVar "o")) (EVar "rs")) (EVar "predsRest")) (EVar "arity")) (EBinOp "+" (EVar "slot") (ELit (LInt 1))))))))
(DTypeSig false "graphMarksNow" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyCon "GraphMarks"))))
(DFunDef false "graphMarksNow" ((PVar "gctx") PWild) (ERecordCreate "GraphMarks" ((fa "mGoals" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "goalsN") "value")) (fa "mNumlit" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "numlitN") "value")))))
(DTypeSig false "recordModuleStart" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyCon "Unit"))))
(DFunDef false "recordModuleStart" ((PVar "gctx") (PVar "mid")) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "moduleRanges")) (EBinOp "::" (ETuple (EVar "mid") (EApp (EApp (EVar "graphMarksNow") (EVar "gctx")) (ELit LUnit))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "moduleRanges") "value"))))
(DTypeSig false "mapLocalSchemes" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Scheme"))))))
(DFunDef false "mapLocalSchemes" ((PVar "mctx") (PList)) (EListLit))
(DFunDef false "mapLocalSchemes" ((PVar "mctx") (PCons (PTuple (PVar "n") (PVar "l") (PVar "m")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EVar "l") (EApp (EApp (EVar "generalize") (EVar "mctx")) (EVar "m"))) (EApp (EApp (EVar "mapLocalSchemes") (EVar "mctx")) (EVar "rest"))))
(DTypeSig false "seedBuiltinClasses" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))))
(DFunDef false "seedBuiltinClasses" ((PVar "gctx") (PVar "mid") (PVar "prog")) (EIf (EApp (EVar "isPreludeMid") (EVar "mid")) (EBlock (DoLet false false (PVar "seeded") (EApp (EVar "builtinClassesOf") (EVar "prog"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "builtinClassesRef")) (EVariantUpdate "BuiltinClasses" (EVar "seeded") ((fa "bcPreludeSeeded" (EApp (EVar "isNonEmptyL") (EVar "prog")))))))) (EIf (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "builtinClassesRef") "value") "bcPreludeSeeded") (ELit LUnit) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "builtinClassesRef")) (EApp (EApp (EVar "builtinClassesGo") (EVar "prog")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "builtinClassesRef") "value"))))))
(DTypeSig false "recordTopBinderTypes" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Scheme")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))))
(DFunDef false "recordTopBinderTypes" ((PVar "gctx") (PVar "schemes") (PVar "decls")) (EBlock (DoLet false false (PVar "signed") (EApp (EApp (EVar "signedTopNames") (EVar "decls")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "each") (EApp (EApp (EApp (EVar "recordTopDeclBinderTypes") (EVar "gctx")) (EVar "schemes")) (EVar "signed"))) (EVar "decls")))))
(DTypeSig false "signedTopNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "signedTopNames" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "signedTopNames" ((PCons (PCon "DTypeSig" PWild (PVar "n") PWild PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "signedTopNames") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "acc"))))
(DFunDef false "signedTopNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "signedTopNames") (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "acc")))
(DFunDef false "signedTopNames" ((PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "signedTopNames") (EVar "rest")) (EVar "acc")))
(DTypeSig false "recordTopDeclBinderTypes" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Scheme")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Decl") (TyCon "Unit"))))))
(DFunDef false "recordTopDeclBinderTypes" ((PVar "gctx") (PVar "schemes") (PVar "signed") (PCon "DFunDef" PWild (PVar "n") (PVar "ps") PWild PWild (PVar "bid"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordTopFunBinderType") (EVar "gctx")) (EVar "schemes")) (EVar "signed")) (EVar "n")) (EVar "bid")) (EApp (EVar "listLen") (EVar "ps"))))
(DFunDef false "recordTopDeclBinderTypes" ((PVar "gctx") (PVar "schemes") (PVar "signed") (PCon "DLetGroup" PWild (PVar "binds"))) (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "b")) (EMatch (EVar "b") (arm (PCon "LetBind" (PVar "n") (PVar "clauses") PWild (PVar "bid")) () (EMatch (EVar "clauses") (arm (PCons (PCon "FunClause" (PVar "ps") PWild) PWild) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordTopFunBinderType") (EVar "gctx")) (EVar "schemes")) (EVar "signed")) (EVar "n")) (EVar "bid")) (EApp (EVar "listLen") (EVar "ps")))) (arm (PList) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordTopFunBinderType") (EVar "gctx")) (EVar "schemes")) (EVar "signed")) (EVar "n")) (EVar "bid")) (ELit (LInt 0))))))))) (ELit LUnit)) (EVar "binds")))
(DFunDef false "recordTopDeclBinderTypes" ((PVar "gctx") (PVar "schemes") (PVar "signed") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EVar "recordTopDeclBinderTypes") (EVar "gctx")) (EVar "schemes")) (EVar "signed")) (EVar "d")))
(DFunDef false "recordTopDeclBinderTypes" ((PVar "gctx") PWild PWild PWild) (ELit LUnit))
(DTypeSig false "recordTopFunBinderType" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Scheme")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyCon "BinderId") (TyFun (TyCon "Int") (TyCon "Unit"))))))))
(DFunDef false "recordTopFunBinderType" ((PVar "gctx") (PVar "schemes") (PVar "signed") (PVar "n") (PVar "bid") (PVar "arity")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "schemes")) (arm (PCon "Some" (PVar "sch")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordBinderType") (EVar "gctx")) (EVar "bid")) (EVar "n")) (EApp (EVar "schemeMono") (EVar "sch"))) (EApp (EVar "Some") (EVar "arity"))) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "signed")))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig false "resolveSites" (TyFun (TyCon "SiteCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "PendingEntry")) (TyCon "Unit")))))
(DFunDef false "resolveSites" ((PVar "sx") PWild (PList)) (ELit LUnit))
(DFunDef false "resolveSites" ((PVar "sx") (PVar "rpNames") (PCons (PCon "PendingEntry" (PVar "name") (PVar "tagRef") (PVar "resultMono") (PVar "encl") (PVar "kind") (PVar "loc") (PVar "scope") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "sx") (ERecordUpdate (EVar "sx") ((fa "sxSite" (EVar "loc"))))) (DoExpr (EMatch (EVar "kind") (arm (PCon "SKReturn" (PVar "implRef") (PVar "fullMono")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveSite") (EVar "sx")) (EVar "rpNames")) (EVar "name")) (EVar "tagRef")) (EVar "implRef")) (EVar "resultMono")) (EVar "fullMono")) (EVar "encl")) (EVar "loc")) (EVar "scope"))) (arm (PCon "SKAdmittedReturn" (PVar "ifaceRef") (PVar "implRef") (PVar "fullMono")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveAdmittedSite") (EVar "sx")) (EVar "name")) (EVar "ifaceRef")) (EVar "tagRef")) (EVar "implRef")) (EVar "fullMono")) (EVar "encl")) (EVar "scope"))) (arm (PCon "SKExactReturn" (PVar "implRef") (PVar "request")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveExactReturnSite") (EVar "sx")) (EVar "rpNames")) (EVar "name")) (EVar "tagRef")) (EVar "implRef")) (EVar "resultMono")) (EVar "request")) (EVar "encl")) (EVar "loc")) (EVar "scope"))) (arm (PCon "SKNumReturn" (PVar "predicate") (PVar "fullMono")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveNumLitSite") (EVar "sx")) (EVar "rpNames")) (EVar "name")) (EVar "tagRef")) (EVar "resultMono")) (EVar "fullMono")) (EVar "predicate")) (EVar "encl")) (EVar "loc")) (EVar "scope"))) (arm PWild () (ELit LUnit)))) (DoExpr (EApp (EApp (EApp (EVar "resolveSites") (EVar "sx")) (EVar "rpNames")) (EVar "rest")))))
(DTypeSig false "resolveRLocalSites" (TyFun (TyCon "SiteCtx") (TyFun (TyApp (TyCon "List") (TyCon "PendingEntry")) (TyCon "Unit"))))
(DFunDef false "resolveRLocalSites" ((PVar "sx") (PList)) (ELit LUnit))
(DFunDef false "resolveRLocalSites" ((PVar "sx") (PCons (PCon "PendingEntry" (PVar "name") (PVar "tagRef") (PVar "am") (PVar "encl") (PVar "kind") (PVar "loc") (PVar "scope") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "sx") (ERecordUpdate (EVar "sx") ((fa "sxSite" (EVar "loc"))))) (DoExpr (EMatch (EVar "kind") (arm (PCon "SKRLocal" (PVar "sym") (PVar "forceLocal") (PVar "monos") (PVar "ifaces") (PVar "argVecs")) () (EIf (EVar "forceLocal") (EApp (EApp (EVar "setRef") (EVar "tagRef")) (EApp (EApp (EVar "RLocal") (EVar "sym")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routesOfMonosTopV") (EVar "sx")) (EVar "encl")) (EVar "scope")) (EVar "monos")) (EVar "ifaces")) (EVar "argVecs")))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveRLocalSite") (EVar "sx")) (EVar "name")) (EVar "tagRef")) (EVar "am")) (EVar "encl")) (EVar "scope")) (EVar "sym")) (EVar "monos")) (EVar "ifaces")) (EVar "argVecs")))) (arm PWild () (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "resolveRLocalSites") (EVar "sx")) (EVar "rest")))))
(DTypeSig false "resolveArithSites" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Ref") (TyCon "Route")) (TyCon "Mono"))) (TyCon "Unit")))
(DFunDef false "resolveArithSites" ((PList)) (ELit LUnit))
(DFunDef false "resolveArithSites" ((PCons (PTuple (PVar "dref") (PVar "m")) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EVar "resolveArithSite") (EVar "dref")) (EVar "m"))) (DoExpr (EApp (EVar "resolveArithSites") (EVar "rest")))))
(DTypeSig false "resolveOpSites" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "PendingEntry")) (TyCon "Unit")))))
(DFunDef false "resolveOpSites" ((PVar "sx") PWild (PList)) (ELit LUnit))
(DFunDef false "resolveOpSites" ((PVar "sx") (PVar "isBinop") (PCons (PCon "PendingEntry" (PVar "method") (PVar "tagRef") (PVar "operandMono") (PVar "encl") (PVar "kind") (PVar "loc") (PVar "scope") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "sx") (ERecordUpdate (EVar "sx") ((fa "sxSite" (EVar "loc"))))) (DoExpr (EMatch (EVar "kind") (arm (PCon "SKOp" (PVar "inImpl")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveOpSite") (EVar "sx")) (EVar "isBinop")) (EVar "method")) (EVar "tagRef")) (EVar "operandMono")) (EVar "inImpl")) (EVar "encl")) (EVar "scope"))) (arm (PCon "SKPredicateOp" (PVar "inImpl") (PVar "predicate")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolvePredicateOpSite") (EVar "sx")) (EVar "isBinop")) (EVar "method")) (EVar "tagRef")) (EVar "operandMono")) (EVar "inImpl")) (EVar "predicate")) (EVar "encl")) (EVar "scope"))) (arm PWild () (ELit LUnit)))) (DoExpr (EApp (EApp (EApp (EVar "resolveOpSites") (EVar "sx")) (EVar "isBinop")) (EVar "rest")))))
(DTypeSig false "checkInterfaceCycles" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyCon "Unit"))))))
(DFunDef false "checkInterfaceCycles" ((PVar "mctx") (PVar "prog") (PVar "ce") (PVar "cur")) (EBlock (DoLet false false (PVar "done") (EApp (EVar "Ref") (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "each") (EApp (EApp (EApp (EApp (EApp (EVar "checkOneIfaceCycle") (EVar "mctx")) (EVar "prog")) (EVar "ce")) (EVar "cur")) (EVar "done"))) (EApp (EApp (EVar "ceRowsVisibleAt") (EVar "cur")) (EVar "ce"))))))
(DTypeSig false "runFinalChecks" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "ClassEnv") (TyFun (TyCon "ClassEnv") (TyFun (TyCon "ImplEnv") (TyFun (TyCon "ImplEnv") (TyFun (TyCon "Int") (TyCon "Unit")))))))))
(DFunDef false "runFinalChecks" ((PVar "mctx") (PVar "cohDecls") (PVar "ownCe") (PVar "cycCe") (PVar "cohIe") (PVar "cycIe") (PVar "cur")) (EBlock (DoExpr (EApp (EApp (EVar "ordinalSentinelGuard") (EVar "mctx")) (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "checkCoherence") (EVar "mctx")) (EVar "cohIe")) (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkInterfaceCycles") (EVar "mctx")) (EVar "cohDecls")) (EVar "cycCe")) (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "checkPhantomMethods") (EVar "mctx")) (EVar "ownCe")) (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "checkSuperImpls") (EVar "mctx")) (EVar "cohDecls")) (EVar "cycCe")) (EVar "cycIe")) (EVar "cur")))))
(DTypeSig false "ordinalSentinelGuard" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyCon "Unit"))))
(DFunDef false "ordinalSentinelGuard" ((PVar "mctx") (PVar "cur")) (EIf (EApp (EVar "ordinalIsSentinel") (EVar "cur")) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (EVar "TInternalOrdinal")) (EVar "ordinalSentinelMsg")) (EIf (EVar "otherwise") (ELit LUnit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ordinalIsSentinel" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "ordinalIsSentinel" ((PVar "cur")) (EBinOp "<" (EVar "cur") (ELit (LInt 0))))
(DTypeSig false "checkOneIfaceCycle" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyCon "CeRow") (TyCon "Unit"))))))))
(DFunDef false "checkOneIfaceCycle" ((PVar "mctx") (PVar "prog") (PVar "ce") (PVar "cur") (PVar "done") (PVar "row")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EApp (EVar "ceRowDoneKey") (EVar "row"))) (EUnOp "!" (EVar "done")))) (EApp (EApp (EVar "each") (EApp (EApp (EVar "pushTypeError") (EApp (EApp (EVar "mctxAt") (EApp (EApp (EApp (EApp (EVar "cycleReportLoc") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "declEnvsRef") "value") "deReach")) (EVar "prog")) (EVar "cur")) (EVar "row"))) (EVar "mctx"))) (EVar "TCyclicSuperinterface"))) (EApp (EApp (EApp (EApp (EApp (EVar "ifaceDfsCycle") (EVar "ce")) (EVar "cur")) (EVar "done")) (EListLit (EVar "row"))) (EVar "row"))) (ELit LUnit)))
(DTypeSig false "cycleReportLoc" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyCon "CeRow") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "cycleReportLoc" ((PVar "reach") (PVar "prog") (PVar "cur") (PVar "row")) (EIf (EBinOp "==" (EApp (EVar "ceRowOrd") (EVar "row")) (EVar "cur")) (EApp (EVar "ceRowLoc") (EVar "row")) (EIf (EVar "otherwise") (EMatch (EFieldAccess (EApp (EVar "ceRowIface") (EVar "row")) "irOrigin") (arm (PCon "OriginModule" (PVar "owner")) () (EApp (EApp (EApp (EVar "importLocFor") (EVar "reach")) (EVar "prog")) (EVar "owner"))) (arm PWild () (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ifaceDfsCycle" (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "List") (TyCon "CeRow")) (TyFun (TyCon "CeRow") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "ifaceDfsCycle" ((PVar "ce") (PVar "cur") (PVar "done") (PVar "path") (PVar "current")) (EBlock (DoLet false false (PVar "msgs") (EApp (EApp (EApp (EApp (EApp (EVar "ifaceDfsCycleSupers") (EVar "ce")) (EVar "cur")) (EVar "done")) (EVar "path")) (EApp (EVar "ceRowSupers") (EVar "current")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "done")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "ceRowDoneKey") (EVar "current"))) (ELit LUnit)) (EUnOp "!" (EVar "done"))))) (DoExpr (EVar "msgs"))))
(DTypeSig false "ifaceDfsCycleSupers" (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "List") (TyCon "CeRow")) (TyFun (TyApp (TyCon "List") (TyCon "Super")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "ifaceDfsCycleSupers" (PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "ifaceDfsCycleSupers" ((PVar "ce") (PVar "cur") (PVar "done") (PVar "path") (PCons (PRec "Super" ((rf "superHead" (PVar "superName")) (rf "superOrigin" (PVar "so"))) false) (PVar "rest"))) (EBlock (DoLet false false (PVar "msgs1") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ifaceDfsCycleOneSuper") (EVar "ce")) (EVar "cur")) (EVar "done")) (EVar "path")) (EVar "so")) (EVar "superName"))) (DoExpr (EBinOp "++" (EVar "msgs1") (EApp (EApp (EApp (EApp (EApp (EVar "ifaceDfsCycleSupers") (EVar "ce")) (EVar "cur")) (EVar "done")) (EVar "path")) (EVar "rest"))))))
(DTypeSig false "ifaceDfsCycleOneSuper" (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "List") (TyCon "CeRow")) (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "ifaceDfsCycleOneSuper" ((PVar "ce") (PVar "cur") (PVar "done") (PVar "path") (PVar "so") (PVar "superName")) (EBlock (DoLet false false (PVar "key") (EApp (EVar "regKeyOfTab") (EApp (EApp (EVar "ifaceTabKey") (EVar "so")) (EVar "superName")))) (DoLet false false (PVar "rendered") (EApp (EVar "regKeyRender") (EVar "key"))) (DoExpr (EIf (EApp (EApp (EVar "containsRowKey") (EVar "rendered")) (EVar "path")) (EListLit (EApp (EVar "cyclicSuperIfaceMsg") (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "ceRowIfaceName")) (EVar "path")) (EListLit (EVar "superName"))))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "rendered")) (EUnOp "!" (EVar "done"))) (EListLit) (EMatch (EApp (EApp (EApp (EVar "ceLookupAt") (EVar "key")) (EVar "cur")) (EVar "ce")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "r")) () (EApp (EApp (EApp (EApp (EApp (EVar "ifaceDfsCycle") (EVar "ce")) (EVar "cur")) (EVar "done")) (EBinOp "++" (EVar "path") (EListLit (EVar "r")))) (EVar "r")))))))))
(DTypeSig false "containsRowKey" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CeRow")) (TyCon "Bool"))))
(DFunDef false "containsRowKey" (PWild (PList)) (EVar "False"))
(DFunDef false "containsRowKey" ((PVar "k") (PCons (PVar "r") (PVar "rest"))) (EIf (EBinOp "==" (EApp (EVar "ceRowDoneKey") (EVar "r")) (EVar "k")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "containsRowKey") (EVar "k")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "checkBodyImpl" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "CheckRunSeed") (TyFun (TyCon "ModuleSeed") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "ModuleBindings") (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "ModuleCtx")))))))))
(DFunDef false "checkBodyImpl" ((PVar "gctx") (PVar "runSeed") (PVar "moduleSeed") (PVar "mid") (PVar "implDecls") (PVar "prog0")) (EBlock (DoLet false false (PVar "seed") (EFieldAccess (EVar "moduleSeed") "msSchemes")) (DoLet false false (PVar "mctx") (EApp (EApp (EApp (EVar "freshModuleCtx") (EVar "gctx")) (EVar "runSeed")) (EVar "mid"))) (DoLet false false (PVar "moduleScope") (EApp (EApp (EApp (EApp (EApp (EVar "Scopes.freshScope") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))) (EVar "None")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (EVar "mid")) (EVar "ModuleOwner"))) (DoExpr (EApp (EApp (EVar "openScope") (EVar "mctx")) (EVar "moduleScope"))) (DoExpr (EApp (EApp (EVar "recordModuleStart") (EVar "gctx")) (EVar "mid"))) (DoExpr (EApp (EApp (EVar "reportAmbiguousImports") (EVar "mctx")) (EVar "prog0"))) (DoLet false false (PVar "prog") (EVar "prog0")) (DoLet false false (PVar "aliasSpellings") (EApp (EApp (EVar "aliasMethodSpellings") (EVar "gctx")) (EVar "prog"))) (DoExpr (EApp (EApp (EApp (EVar "seedBuiltinClasses") (EVar "gctx")) (EVar "mid")) (EVar "prog"))) (DoLet false false (PVar "stampRes") (EBlock (DoLet false false (PTuple (PVar "top") (PVar "ids")) (EApp (EVar "stampTopScope") (EVar "prog"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "beginModuleMarking") (EVar "mctx")) (EVar "mid")) (EVar "prog")) (EVar "top")) (EVar "moduleSeed"))) (DoExpr (ETuple (EVar "prog") (EVar "ids"))))) (DoLet false false (PVar "progS") (EApp (EVar "fst") (EVar "stampRes"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "schemeDefIdsRef")) (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EVar "snd") (EVar "stampRes")))) (EVar "omEmpty")))) (DoLet false false (PVar "superDecls") (EBinOp "++" (EVar "prog") (EVar "implDecls"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "superDeclsRef")) (EVar "superDecls"))) (DoExpr (EApp (EApp (EVar "checkEffectParams") (EVar "mctx")) (EVar "prog"))) (DoExpr (EApp (EApp (EVar "checkLetRecDecls") (EVar "mctx")) (EVar "prog"))) (DoExpr (EApp (EApp (EApp (EVar "appendUniverseAccums") (EVar "gctx")) (EVar "mid")) (EVar "prog0"))) (DoLet false false (PVar "moduleImplUniv") (EBlock (DoLet false false (PVar "envs") (EFieldAccess (EFieldAccess (EVar "gctx") "declEnvsRef") "value")) (DoExpr (EApp (EApp (EVar "ieUniverseAt") (EApp (EApp (EVar "declEnvsOrdOf") (EVar "mid")) (EVar "envs"))) (EFieldAccess (EVar "envs") "deImpls"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "residualUnivRef")) (EVar "moduleImplUniv"))) (DoLet false false (PVar "isMethod") (EBlock (DoLet false false (PVar "envs") (EFieldAccess (EFieldAccess (EVar "gctx") "declEnvsRef") "value")) (DoExpr (EApp (EApp (EVar "methodNameDeclaredAt") (EApp (EApp (EVar "declEnvsOrdOf") (EVar "mid")) (EVar "envs"))) (EFieldAccess (EVar "envs") "deMethods"))))) (DoLet false false (PVar "definerShadows") (EApp (EApp (EApp (EVar "nameableIfaceShadows") (EVar "gctx")) (EVar "prog0")) (EApp (EApp (EApp (EVar "definerShadowsFromSet") (EVar "gctx")) (EVar "isMethod")) (EVar "prog0")))) (DoLet false false (PVar "importerShadows") (EIf (EApp (EVar "isEmptyL") (EVar "implDecls")) (EListLit) (EApp (EApp (EApp (EVar "nameableIfaceShadows") (EVar "gctx")) (EVar "prog0")) (EApp (EApp (EApp (EApp (EVar "standaloneShadowsFromSet") (EVar "gctx")) (EVar "isMethod")) (EApp (EApp (EVar "omMapValues") (ELam (PWild) (ELit LUnit))) (EFieldAccess (EVar "moduleSeed") "msImportedValues"))) (EVar "prog0"))))) (DoLet false false (PVar "sigs") (EApp (EVar "sigsOf") (EVar "prog"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "definerShadowNamesRef")) (EApp (EApp (EVar "namesToSet") (EVar "definerShadows")) (EVar "omEmpty")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "definerShadowSigsRef")) (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "sigs"))) (EVar "omEmpty")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "bodyImplEnvRef")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "declEnvsRef") "value") "deImpls"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "standaloneValuesRef")) (EApp (EApp (EVar "namesToSet") (EBinOp "++" (EVar "importerShadows") (EVar "definerShadows"))) (EVar "omEmpty")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodDispatchIdxByIdRef")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "universeMethodDispatchIdxByIdRef") "value"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funPredicateSlotsRef")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleFunPredicateSlotsRef") "value"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funConstraintDeclaredRef")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleFunConstraintDeclaredRef") "value"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funPredicateSlotsRef")) (EBinOp "++" (EApp (EApp (EApp (EVar "aliasConstraintEntries") (EVar "gctx")) (EVar "prog")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleFunPredicateSlotsQualRef") "value")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funPredicateSlotsRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funConstraintDeclaredRef")) (EBinOp "++" (EApp (EApp (EApp (EVar "aliasConstraintEntries") (EVar "gctx")) (EVar "prog")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleFunConstraintDeclaredQualRef") "value")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funConstraintDeclaredRef") "value")))) (DoExpr (EApp (EApp (EVar "setFunPredicateSlots") (EVar "mctx")) (EApp (EApp (EApp (EApp (EVar "selfDeclArities") (EVar "mid")) (EVar "prog")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleFunPredicateSlotsQualRef") "value")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funPredicateSlotsRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funConstraintDeclaredRef")) (EApp (EApp (EApp (EApp (EVar "selfDeclArities") (EVar "mid")) (EVar "prog")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleFunConstraintDeclaredQualRef") "value")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funConstraintDeclaredRef") "value")))) (DoLet false false (PVar "admitted") (EApp (EApp (EVar "importDefinersOf") (EVar "gctx")) (EVar "prog"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentImportDefinersRef")) (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EVar "definerRowsOf") (EVar "admitted")))) (EVar "omEmpty")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentImportOriginsRef")) (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EVar "originRowsOf") (EVar "admitted")))) (EVar "omEmpty")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "importedSchemeOblsRef")) (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EApp (EVar "importedSchemeOblEntries") (EVar "prog")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleSchemeOblsQualRef") "value")))) (EVar "omEmpty")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodScopeCtxRef")) (EApp (EVar "Some") (ETuple (EVar "prog") (EApp (EApp (EVar "declEnvsOrdOf") (EVar "mid")) (EFieldAccess (EFieldAccess (EVar "gctx") "declEnvsRef") "value")))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodAliasEntriesRef")) (EApp (EApp (EApp (EVar "aliasQualifiedMethodEntries") (EVar "mctx")) (EVar "prog")) (EVar "omEmpty")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "aliasMethodOriginsRef")) (EApp (EApp (EVar "omFromPairs") (EVar "aliasSpellings")) (EVar "omEmpty")))) (DoLet false false (PVar "dataEnv") (EBlock (DoLet false false (PVar "envs") (EFieldAccess (EFieldAccess (EVar "gctx") "declEnvsRef") "value")) (DoLet false false (PVar "cur") (EApp (EApp (EVar "declEnvsOrdOf") (EVar "mid")) (EVar "envs"))) (DoExpr (EApp (EApp (EVar "loadDataUniverse") (EVar "mctx")) (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EVar "declEnvSeedDataUniverse") (EVar "mctx")) (EVar "mid")) (EVar "envs"))) (DoLet false false (PVar "base") (EApp (EApp (EApp (EVar "registerImportOverlay") (EApp (EApp (EVar "withCtors") (EVar "mctx")) (EApp (EVar "spFloor") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "universeCtorPop") "value")))) (EVar "prog0")) (EApp (EApp (EApp (EVar "importedCtorTypeDeclsLastWins") (EVar "prog0")) (EVar "cur")) (EFieldAccess (EVar "envs") "deModules")))) (DoLet false false (PVar "env0") (EApp (EApp (EVar "registerAllData") (EVar "base")) (EVar "prog0"))) (DoExpr (EApp (EApp (EVar "applyRecordScopeOverrides") (EVar "mctx")) (EVar "prog0"))) (DoExpr (EApp (EApp (EVar "applyCtorScopeOverrides") (EVar "prog0")) (EVar "env0"))))) (DoExpr (EApp (EVar "recordInvocationView") (EVar "dataEnv"))) (DoExpr (EApp (EApp (EVar "checkUndeterminedRetEffVars") (EVar "mctx")) (EVar "prog"))) (DoExpr (EApp (EApp (EVar "checkDeclaredKinds") (EVar "mctx")) (EVar "prog"))) (DoExpr (EApp (EApp (EVar "checkDeclAuthorityUses") (EVar "mctx")) (EVar "prog"))) (DoLet false false (PVar "classEnvHere") (EBlock (DoLet false false (PVar "envs") (EFieldAccess (EFieldAccess (EVar "gctx") "declEnvsRef") "value")) (DoExpr (ETuple (EFieldAccess (EVar "envs") "deIfaces") (EApp (EApp (EVar "declEnvsOrdOf") (EVar "mid")) (EVar "envs")))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkGradedImplHeads") (EVar "mctx")) (EApp (EVar "fst") (EVar "classEnvHere"))) (EApp (EVar "snd") (EVar "classEnvHere"))) (EVar "prog"))) (DoExpr (EApp (EApp (EVar "rejectCyclicAliases") (EVar "mctx")) (EVar "prog"))) (DoLet false false (PVar "currentMethodRows") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "mctx")) (EVar "prog"))) (DoExpr (EApp (EApp (EVar "recordMethodGrants") (EVar "gctx")) (EVar "currentMethodRows"))) (DoLet false false (PVar "visibleMethodRows") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "mctx")) (EVar "implDecls"))) (DoLet false false (PVar "visibleMethodRowIndex") (EApp (EApp (EApp (EVar "methodRowsByIdentity") (EApp (EVar "isNonEmptyL") (EVar "importerShadows"))) (EVar "visibleMethodRows")) (EVar "regEmpty"))) (DoLet false false (PVar "externS") (EApp (EApp (EApp (EVar "userExternSchemes") (EVar "mctx")) (EApp (EVar "externTyOriginScope") (EListLit))) (EVar "prog"))) (DoLet false false (PVar "globalS") (EBinOp "++" (EApp (EVar "legacyMethodSchemes") (EVar "currentMethodRows")) (EVar "externS"))) (DoExpr (EApp (EApp (EApp (EVar "ffiCheckExternsCrossable") (EVar "mctx")) (EApp (EApp (EVar "ffiStampMode") (EVar "gctx")) (EVar "mid"))) (EVar "prog"))) (DoExpr (EApp (EApp (EApp (EVar "ffiCheckExternsLabelled") (EVar "mctx")) (EApp (EApp (EVar "ffiStampMode") (EVar "gctx")) (EVar "mid"))) (EVar "prog"))) (DoExpr (EApp (EApp (EApp (EVar "ffiCheckExternsShadow") (EVar "mctx")) (EApp (EApp (EVar "ffiStampMode") (EVar "gctx")) (EVar "mid"))) (EVar "prog"))) (DoExpr (EApp (EApp (EApp (EVar "ffiCheckExternsCatalogRow") (EVar "mctx")) (EApp (EApp (EVar "ffiStampMode") (EVar "gctx")) (EVar "mid"))) (EVar "prog"))) (DoLet false false (PVar "envSeed") (EApp (EApp (EVar "extendVars") (EVar "dataEnv")) (EVar "seed"))) (DoLet false false (PVar "shadowLayer") (EBlock (DoLet false false (PVar "ifaceSchemes") (EApp (EVar "legacyMethodSchemes") (EVar "visibleMethodRows"))) (DoExpr (EApp (EApp (EVar "seedNumLitFromIntAnchor") (EVar "mctx")) (EVar "visibleMethodRows"))) (DoLet false false (PVar "sm") (EApp (EApp (EApp (EApp (EApp (EVar "pickSchemesByDecl") (EVar "mctx")) (EVar "importerShadows")) (EVar "ifaceSchemes")) (EVar "visibleMethodRowIndex")) (EFieldAccess (EVar "moduleSeed") "msImportedValues"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodPredicateSlotsRef")) (EBinOp "++" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodPredicateSlotsRef") "value") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleMethodPredicateSlotsRef") "value")))) (DoExpr (EApp (EApp (EVar "attachStandaloneSources") (EFieldAccess (EVar "moduleSeed") "msImportedValues")) (EVar "sm"))))) (DoLet false false (PVar "envImported") (EApp (EApp (EApp (EApp (EApp (EVar "annotateImportedMethodRows") (EVar "envSeed")) (EApp (EApp (EApp (EVar "importedMethodBindingNames") (EVar "gctx")) (EVar "prog0")) (EVar "aliasSpellings"))) (EApp (EApp (EVar "nameableIfaceMethodSet") (EVar "gctx")) (EVar "prog0"))) (EApp (EApp (EVar "namesToSet") (EVar "importerShadows")) (EVar "omEmpty"))) (EVar "visibleMethodRowIndex"))) (DoLet false false (PVar "envGlobal") (EApp (EApp (EVar "extendVars") (EApp (EApp (EVar "extendMethodRows") (EVar "envImported")) (EVar "currentMethodRows"))) (EVar "externS"))) (DoLet false false (PVar "env1") (EApp (EApp (EVar "extendBindings") (EVar "envGlobal")) (EVar "shadowLayer"))) (DoLet false false (PVar "defs") (EApp (EVar "funDefs") (EVar "progS"))) (DoLet false false (PTuple (PVar "topSchemes") (PVar "groupedOut")) (EApp (EApp (EApp (EApp (EApp (EVar "processTopGroups") (EVar "env1")) (EVar "sigs")) (EVar "defs")) (EApp (EApp (EVar "groupNames") (EVar "defs")) (EVar "omEmpty"))) (EApp (EApp (EVar "namesToSet") (EApp (EVar "publicValNames") (EVar "prog"))) (EVar "omEmpty")))) (DoExpr (EApp (EApp (EApp (EVar "recordTopBinderTypes") (EVar "gctx")) (EApp (EApp (EVar "omFromPairs") (EVar "topSchemes")) (EVar "omEmpty"))) (EVar "progS"))) (DoLet false false (PVar "tailEnv") (EApp (EApp (EVar "extendTermBindings") (EVar "env1")) (EVar "topSchemes"))) (DoLet false false (PVar "progOut") (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "markingRef") "value") (arm (PCon "Some" (PVar "mm")) () (EApp (EApp (EApp (EApp (EVar "finishModuleMarking") (EVar "mm")) (EVar "tailEnv")) (EVar "groupedOut")) (EVar "progS"))) (arm (PCon "None") () (EVar "progS")))) (DoLet false false (PVar "progT") (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "markingRef") "value") (arm (PCon "Some" (PVar "mm")) () (EApp (EApp (EVar "stampTailDecls") (EFieldAccess (EVar "mm") "mmTop")) (EVar "progOut"))) (arm (PCon "None") () (EVar "progS")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "inferUserImplBodies") (EVar "tailEnv")) (EVar "implDecls")) (EApp (EVar "fst") (EVar "classEnvHere"))) (EApp (EVar "snd") (EVar "classEnvHere"))) (EVar "progT"))) (DoExpr (EApp (EApp (EVar "inferDefaultBodies") (EVar "tailEnv")) (EVar "progT"))) (DoExpr (EApp (EApp (EVar "inferPropBodies") (EVar "tailEnv")) (EVar "progT"))) (DoExpr (EApp (EApp (EVar "inferTestBodies") (EVar "tailEnv")) (EVar "progT"))) (DoExpr (EApp (EApp (EVar "dedupPredicateSlotsTable") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleFunPredicateSlotsRef")) (EApp (EVar "predicateSlotTableWithoutArgs") (EBinOp "++" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funPredicateSlotsRef") "value") (EApp (EApp (EVar "selfNameRows") (EVar "prog")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleFunPredicateSlotsRef") "value")))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleFunPredicateSlotsQualRef")) (EBinOp "++" (EApp (EApp (EApp (EVar "attributeModuleEntries") (EVar "mid")) (EVar "prog")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funPredicateSlotsRef") "value")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleFunPredicateSlotsQualRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleFunConstraintDeclaredRef")) (EBinOp "++" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funConstraintDeclaredRef") "value") (EApp (EApp (EVar "selfNameRows") (EVar "prog")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleFunConstraintDeclaredRef") "value"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleFunConstraintDeclaredQualRef")) (EBinOp "++" (EApp (EApp (EApp (EVar "attributeModuleEntries") (EVar "mid")) (EVar "prog")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funConstraintDeclaredRef") "value")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleFunConstraintDeclaredQualRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleMethodPredicateSlotsRef")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodPredicateSlotsRef") "value"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleMethodPredicateSlotsQualRef")) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "emptyMethodModulePredicateSlots") (EVar "mid")) (EVar "prog")) (EApp (EApp (EApp (EVar "attributeMethodModulePredicateSlots") (EVar "mid")) (EVar "prog")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodPredicateSlotsRef") "value"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleMethodPredicateSlotsQualRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleSchemeOblsQualRef")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "attributeModuleSchemeObls") (EVar "mid")) (EVar "prog")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleSchemeOblsQualRef") "value")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "schemeObligationsRef") "value")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleSchemeOblsQualRef") "value")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkImplCompletenessMap") (EVar "mctx")) (EApp (EVar "fst") (EVar "classEnvHere"))) (EApp (EVar "snd") (EVar "classEnvHere"))) (EVar "prog"))) (DoLet false false (PVar "obUniv") (EVar "moduleImplUniv")) (DoExpr (EApp (EApp (EVar "recordLiveRoots") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "judgeQuiescentGoals") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "refileDeterminedRows") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkCallObligationsU") (EVar "mctx")) (EVar "True")) (EVar "obUniv")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "implObls") "items") "value"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkCallObligationsU") (EVar "mctx")) (EVar "False")) (EVar "obUniv")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "obls") "items") "value"))) (DoExpr (EApp (EApp (EVar "settleDeferredPatLits") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "checkDeferredMatches") (EVar "mctx")) (EApp (EVar "reverseL") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchChecksDeferred") "value")))) (DoExpr (EApp (EApp (EVar "checkFixedWidthLiterals") (EVar "mctx")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitRanges") "value"))) (DoExpr (EApp (EApp (EVar "checkWideLiterals") (EVar "mctx")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "wideLitRanges") "value"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "localSchemesOut")) (EApp (EApp (EVar "mapLocalSchemes") (EVar "mctx")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "localBindRefs") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "seedSchemesOut")) (EVar "seed"))) (DoExpr (EApp (EApp (EApp (EVar "appendDataUniverse") (EVar "mctx")) (EVar "mid")) (EVar "prog0"))) (DoLet false false (PVar "result") (ETuple (ERecordCreate "ModuleBindings" ((fa "mbSchemes" (EBinOp "++" (EVar "globalS") (EVar "topSchemes"))) (fa "mbStandaloneSchemes" (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "topSchemes"))) (EVar "omEmpty"))))) (EVar "progOut") (EVar "mctx"))) (DoExpr (EApp (EApp (EVar "closeScope") (EVar "mctx")) (ELit LUnit))) (DoExpr (EVar "result"))))
(DTypeSig false "inferPropBodies" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "inferPropBodies" ((PVar "env") (PVar "prog")) (EBlock (DoLet false false (PVar "mark") (EApp (EApp (EVar "goalsMark") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "inferPropBodiesGo") (EVar "env")) (EVar "prog"))) (DoExpr (EApp (EApp (EApp (EVar "dropGoalsSince") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "mark")) (EListLit (EVar "GKBinopSite") (EVar "GKUnopSite") (EVar "GKArithSite"))))))
(DTypeSig false "inferPropBodiesGo" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "inferPropBodiesGo" ((PVar "env") (PList)) (ELit LUnit))
(DFunDef false "inferPropBodiesGo" ((PVar "outer") (PCons (PCon "DProp" PWild (PVar "name") (PVar "params") (PVar "body")) (PVar "rest"))) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EVar "envAtIfSome") (EApp (EVar "exprSpanLoc") (EVar "body"))) (EVar "outer"))) (DoLet false false (PVar "local") (EApp (EApp (EVar "extendPropParams") (EVar "env")) (EVar "params"))) (DoExpr (EApp (EApp (EVar "enterLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "parentScope") (EApp (EApp (EVar "captureScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "bodyScope") (EApp (EApp (EApp (EApp (EApp (EVar "Scopes.freshScope") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (EApp (EVar "Some") (EVar "parentScope"))) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentLevel") "value")) (EFieldAccess (EApp (EApp (EVar "Scopes.scopeFrame") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (EVar "parentScope")) "sfModuleId")) (EApp (EVar "PropOwner") (EVar "name")))) (DoExpr (EApp (EApp (EVar "openScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "bodyScope"))) (DoLet false false (PVar "oblMark") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls"))) (DoLet false false (PVar "callMark") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "obls"))) (DoLet false false (PVar "dictMark") (EApp (EApp (EVar "goalsMark") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EApp (EApp (EVar "dynAtIfSome") (EApp (EVar "valueSpanLoc") (EVar "body"))) (EFieldAccess (EVar "env") "teDyn"))) (EApp (EApp (EVar "infer") (EVar "local")) (EVar "body"))) (EApp (EVar "tconBuiltin") (ELit (LString "Bool"))))) (DoExpr (EApp (EApp (EVar "exitLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "settleClosedBody") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EVar "tconBuiltin") (ELit (LString "Bool")))) (EVar "oblMark")) (EVar "callMark")) (EVar "dictMark"))) (DoExpr (EApp (EApp (EVar "closeScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "inferPropBodiesGo") (EVar "outer")) (EVar "rest")))))
(DFunDef false "inferPropBodiesGo" ((PVar "env") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "inferPropBodiesGo") (EVar "env")) (EVar "rest")))
(DTypeSig false "inferTestBodies" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "inferTestBodies" ((PVar "env") (PList)) (ELit LUnit))
(DFunDef false "inferTestBodies" ((PVar "outer") (PCons (PCon "DTest" PWild (PVar "name") (PVar "body")) (PVar "rest"))) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EVar "envAtIfSome") (EApp (EVar "exprSpanLoc") (EVar "body"))) (EVar "outer"))) (DoExpr (EApp (EApp (EVar "enterLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "parentScope") (EApp (EApp (EVar "captureScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "bodyScope") (EApp (EApp (EApp (EApp (EApp (EVar "Scopes.freshScope") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (EApp (EVar "Some") (EVar "parentScope"))) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentLevel") "value")) (EFieldAccess (EApp (EApp (EVar "Scopes.scopeFrame") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (EVar "parentScope")) "sfModuleId")) (EApp (EVar "TestOwner") (EVar "name")))) (DoExpr (EApp (EApp (EVar "openScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "bodyScope"))) (DoLet false false (PVar "oblMark") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls"))) (DoLet false false (PVar "callMark") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "obls"))) (DoLet false false (PVar "dictMark") (EApp (EApp (EVar "goalsMark") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EApp (EApp (EVar "dynAtIfSome") (EApp (EVar "valueSpanLoc") (EVar "body"))) (EFieldAccess (EVar "env") "teDyn"))) (EApp (EApp (EVar "infer") (EVar "env")) (EVar "body"))) (EApp (EVar "tconUnresolved") (ELit (LString "Expectation"))))) (DoExpr (EApp (EApp (EVar "exitLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "settleClosedBody") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EVar "tconUnresolved") (ELit (LString "Expectation")))) (EVar "oblMark")) (EVar "callMark")) (EVar "dictMark"))) (DoExpr (EApp (EApp (EVar "closeScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "inferTestBodies") (EVar "outer")) (EVar "rest")))))
(DFunDef false "inferTestBodies" ((PVar "env") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "inferTestBodies") (EVar "env")) (EVar "rest")))
(DTypeSig true "settleClosedBody" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Unit")))))))
(DFunDef false "settleClosedBody" ((PVar "mctx") (PVar "bodyTy") (PVar "oblMark") (PVar "callMark") (PVar "dictMark")) (EBlock (DoLet false false (PVar "level") (EBinOp "+" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value") (ELit (LInt 1)))) (DoLet false false (PVar "addedObls") (EApp (EApp (EVar "wWindow") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "implObls")) (EVar "oblMark"))) (DoLet false false (PVar "bodyObls") (EBinOp "++" (EVar "addedObls") (EApp (EApp (EVar "callUOblsWindow") (EVar "mctx")) (EVar "callMark")))) (DoLet false false (PVar "rigidIds") (EApp (EApp (EApp (EVar "outerRigidIds") (EApp (EVar "Some") (EVar "level"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "uOblArgs") (EFieldAccess (EVar "mctx") "mcGraph"))) (EVar "bodyObls"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EApp (EVar "improveByUniqueImpl") (EApp (EVar "dynFor") (EVar "mctx"))) (EVar "rigidIds")) (EVar "bodyObls"))) (DoExpr (EApp (EApp (EApp (EVar "determineByUniqueInstance") (EVar "mctx")) (EVar "rigidIds")) (EVar "bodyObls"))) (DoLet false false (PVar "withheld") (EApp (EApp (EVar "finalizeNumBoundary") (EApp (EVar "dynFor") (EVar "mctx"))) (ERecordCreate "NumBoundary" ((fa "nbDisposition" (EApp (EVar "NumBoundaryOwnedMethodBody") (EVar "level"))) (fa "nbMembers" (EListLit (EVar "bodyTy"))) (fa "nbSurvivingIds" (EVar "omEmpty")) (fa "nbDefaultObls" (EBinOp "++" (EVar "addedObls") (EApp (EApp (EApp (EVar "calleeNumObls") (EVar "mctx")) (EVar "callMark")) (EVar "dictMark")))) (fa "nbAmbiguityObls" (EVar "addedObls")) (fa "nbGuard" (ERecordCreate "NumGuard" ((fa "ngGoals" (EVar "bodyObls")) (fa "ngRigidIds" (EVar "rigidIds")) (fa "ngOuterBelow" (EApp (EVar "Some") (EVar "level")))))))))) (DoExpr (EApp (EApp (EApp (EVar "improveByUniqueImpl") (EApp (EVar "dynFor") (EVar "mctx"))) (EVar "rigidIds")) (EVar "bodyObls"))) (DoExpr (EApp (EApp (EApp (EVar "determineByUniqueInstance") (EVar "mctx")) (EVar "rigidIds")) (EVar "bodyObls"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "rejectUndeterminedVectors") (EVar "mctx")) (EVar "rigidIds")) (EVar "omEmpty")) (EVar "addedObls")) (EBinOp "++" (EApp (EApp (EVar "callUOblsWindow") (EVar "mctx")) (EVar "callMark")) (EApp (EApp (EApp (EApp (EVar "nestedRequireGoals") (EVar "mctx")) (EVar "rigidIds")) (EVar "omEmpty")) (EVar "bodyObls"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "rejectWithheldAmbiguity") (EVar "mctx")) (EVar "rigidIds")) (EVar "withheld")) (EVar "bodyObls")))))
(DTypeSig false "extendPropParams" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyCon "TcEnv"))))
(DFunDef false "extendPropParams" ((PVar "env") (PList)) (EVar "env"))
(DFunDef false "extendPropParams" ((PVar "env") (PCons (PCon "PropParam" (PVar "x") PWild (PVar "ty")) (PVar "rest"))) (EBlock (DoLet false false (PVar "scheme") (EApp (EVar "monoScheme") (EApp (EApp (EApp (EVar "fromAstType") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EApp (EVar "freshTvMap") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EVar "dedup") (EApp (EVar "tyVarNames") (EVar "ty"))))) (EVar "ty")))) (DoExpr (EApp (EApp (EVar "extendPropParams") (EApp (EApp (EApp (EVar "extendLocalVar") (EVar "env")) (EVar "x")) (EVar "scheme"))) (EVar "rest")))))
(DTypeSig false "setNumlitFloatsGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Float"))) (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Route")))) (TyCon "Unit")))
(DFunDef false "setNumlitFloatsGo" ((PList)) (ELit LUnit))
(DFunDef false "setNumlitFloatsGo" ((PCons (PTuple (PVar "var") (PVar "fref") (PVar "n") (PVar "dref")) (PVar "rest"))) (EBlock (DoExpr (EMatch (EApp (EVar "normalize") (EVar "var")) (arm (PCon "TCon" (PLit (LString "Float")) PWild) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "fref")) (EApp (EVar "Some") (EApp (EVar "intToFloat") (EVar "n"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "dref")) (EVar "RNone"))))) (arm (PCon "TCon" (PLit (LString "Int")) PWild) () (EApp (EApp (EVar "setRef") (EVar "dref")) (EVar "RNone"))) (arm PWild () (ELit LUnit)))) (DoExpr (EApp (EVar "setNumlitFloatsGo") (EVar "rest")))))
(DTypeSig false "recordLiveRoots" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "Unit"))))
(DFunDef false "recordLiveRoots" ((PVar "mctx") PWild) (EBlock (DoLet false false (PVar "members") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "liveMemberMonosRef") "value")) (DoLet false false (PVar "liveIds") (EApp (EVar "dedupI") (EApp (EApp (EDictApp "flatMap") (EApp (EVar "liveVarIdsOf") (EVar "mctx"))) (EVar "members")))) (DoExpr (EIf (EApp (EVar "isNonEmptyL") (EVar "liveIds")) (EBlock (DoLet false false (PVar "goals") (EBinOp "++" (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "implObls") "items") "value") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "obls") "items") "value"))) (DoLet false false (PVar "numObls") (EBinOp "++" (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "implObls") "items") "value") (EApp (EApp (EVar "numCallObls") (EFieldAccess (EVar "mctx") "mcGraph")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "obls") "items") "value")))) (DoLet false false (PVar "numIds") (EApp (EApp (EVar "filterList") (ELam ((PVar "i")) (EApp (EApp (EVar "containsI") (EVar "i")) (EVar "liveIds")))) (EApp (EVar "numConstrainedIds") (EVar "numObls")))) (DoLet false false (PVar "numRoots") (EApp (EApp (EMethodRef "filterMap") (ELam ((PVar "i")) (EApp (EApp (EVar "liveNumVarGo") (EVar "i")) (EVar "numObls")))) (EApp (EVar "dedupI") (EVar "numIds")))) (DoLet false false (PVar "g") (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "liveRoots")) (EBinOp "++" (EApp (EApp (EMethodRef "filterMap") (EApp (EVar "findTvarInMonos") (EVar "members"))) (EVar "liveIds")) (EFieldAccess (EFieldAccess (EVar "g") "liveRoots") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "liveGoals")) (EBinOp "++" (EApp (EVar "reverseL") (EApp (EApp (EVar "liveGoalsOf") (EVar "mctx")) (EVar "members"))) (EFieldAccess (EFieldAccess (EVar "g") "liveGoals") "value")))) (DoExpr (EIf (EApp (EVar "isNonEmptyL") (EVar "numRoots")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "liveNumRoots")) (EBinOp "++" (EVar "numRoots") (EFieldAccess (EFieldAccess (EVar "g") "liveNumRoots") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "liveNumGoals")) (EBinOp "++" (EApp (EApp (EVar "filterList") (ELam ((PVar "o")) (EApp (EApp (EDictApp "any") (ELam ((PVar "i")) (EApp (EApp (EDictApp "elem") (EVar "i")) (EVar "numIds")))) (EApp (EApp (EDictApp "flatMap") (EVar "monoUnboundIds")) (EApp (EApp (EVar "uOblArgs") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "o")))))) (EVar "goals")) (EFieldAccess (EFieldAccess (EVar "g") "liveNumGoals") "value"))))) (ELit LUnit)))) (ELit LUnit)))))
(DTypeSig false "liveGoalsOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "LiveGoal")))))
(DFunDef false "liveGoalsOf" ((PVar "mctx") (PVar "members")) (EBlock (DoLet false false (PVar "mid") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentModuleRef") "value")) (DoLet false false (PVar "owners") (EApp (EApp (EVar "memberOfIds") (EVar "mctx")) (EVar "members"))) (DoExpr (EApp (EApp (EMethodRef "filterMap") (ELam ((PTuple (PVar "rigidIds") (PVar "window") (PVar "o"))) (EBlock (DoLet false false (PVar "ids") (EApp (EApp (EDictApp "flatMap") (EVar "monoUnboundIds")) (EApp (EApp (EVar "uOblArgs") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "o")))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "k")) (ERecordCreate "LiveGoal" ((fa "lgModule" (EVar "mid")) (fa "lgBinding" (EVar "k")) (fa "lgRigidIds" (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "i")) (EIf (EApp (EApp (EVar "IdMap.has") (EVar "i")) (EVar "owners")) (EApp (EApp (EVar "omDelete") (EApp (EVar "intToString") (EVar "i"))) (EVar "acc")) (EVar "acc")))) (EVar "rigidIds")) (EVar "ids"))) (fa "lgWindow" (EVar "window")) (fa "lgGoal" (EVar "o")))))) (EApp (EApp (EVar "findMap") (ELam ((PVar "i")) (EApp (EApp (EVar "IdMap.get") (EVar "i")) (EVar "owners")))) (EVar "ids"))))))) (EApp (EVar "reverseL") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "heldLiveGoalsRef") "value"))))))
(DTypeSig false "memberOfIds" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Int")))))
(DFunDef false "memberOfIds" ((PVar "mctx") (PVar "members")) (EApp (EVar "fst") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PTuple (PVar "owners") (PVar "k")) (PVar "m")) (ETuple (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "i")) (EIf (EApp (EApp (EVar "IdMap.has") (EVar "i")) (EVar "acc")) (EVar "acc") (EApp (EApp (EApp (EVar "IdMap.set") (EVar "i")) (EVar "k")) (EVar "acc"))))) (EVar "owners")) (EApp (EApp (EVar "liveVarIdsOf") (EVar "mctx")) (EVar "m"))) (EBinOp "+" (EVar "k") (ELit (LInt 1)))))) (ETuple (EVar "Tip") (ELit (LInt 0)))) (EVar "members"))))
(DTypeSig false "judgeLiveGoals" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "StampCtx")) (TyApp (TyCon "List") (TyCon "DrainFinding")))))
(DFunDef false "judgeLiveGoals" ((PVar "saved") (PVar "ctxs")) (EBlock (DoLet false false (PVar "g") (EFieldAccess (EFieldAccess (EVar "saved") "mcGraph") "graphRun")) (DoLet false false (PVar "goals") (EApp (EVar "reverseL") (EFieldAccess (EFieldAccess (EVar "g") "liveGoals") "value"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "liveGoals")) (EListLit))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "goals")) (EListLit) (EBlock (DoLet false false (PVar "byModule") (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EMethodRef "map") (ELam ((PVar "c")) (ETuple (EFieldAccess (EVar "c") "scModule") (EVar "c")))) (EVar "ctxs"))) (EVar "omEmpty"))) (DoExpr (EApp (EVar "reverseL") (EApp (EVar "fst") (EApp (EApp (EApp (EMethodRef "fold") (EApp (EApp (EVar "judgeLiveGoal") (EVar "saved")) (EVar "byModule"))) (ETuple (EListLit) (EVar "omEmpty"))) (EVar "goals"))))))))))
(DTypeSig false "judgeLiveGoal" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "StampCtx")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "DrainFinding")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyCon "LiveGoal") (TyTuple (TyApp (TyCon "List") (TyCon "DrainFinding")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))))
(DFunDef false "judgeLiveGoal" ((PVar "saved") (PVar "byModule") (PTuple (PVar "found") (PVar "judged")) (PVar "lg")) (EBlock (DoLet false false (PVar "binding") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "lg") "lgModule"))) (ELit (LString "\t"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EFieldAccess (EVar "lg") "lgBinding")))) (ELit (LString "")))) (DoExpr (EMatch (ETuple (EApp (EApp (EVar "omHasKey") (EVar "binding")) (EVar "judged")) (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "lg") "lgModule")) (EVar "byModule"))) (arm (PTuple (PCon "False") (PCon "Some" (PVar "ctx"))) () (EBlock (DoLet false false (PVar "stamp") (EApp (EApp (EVar "enterStampCtx") (EVar "saved")) (EVar "ctx"))) (DoLet false false (PVar "rigidIds") (EFieldAccess (EVar "lg") "lgRigidIds")) (DoLet false false (PVar "diags") (EApp (EApp (EVar "captureTypeErrors") (EVar "stamp")) (ELam (PWild) (EApp (EApp (EVar "each") (EApp (EApp (EApp (EApp (EVar "undeterminedVectorVerdict") (EVar "stamp")) (EVar "rigidIds")) (EVar "omEmpty")) (EFieldAccess (EVar "lg") "lgWindow"))) (EBinOp "::" (EFieldAccess (EVar "lg") "lgGoal") (EApp (EApp (EApp (EApp (EVar "nestedRequireGoals") (EVar "stamp")) (EVar "rigidIds")) (EVar "omEmpty")) (EListLit (EFieldAccess (EVar "lg") "lgGoal")))))))) (DoExpr (EMatch (EVar "diags") (arm (PList) () (ETuple (EVar "found") (EVar "judged"))) (arm PWild () (ETuple (EBinOp "++" (EApp (EVar "reverseL") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "verdictFinding") (EFieldAccess (EVar "lg") "lgModule")) (EVar "True"))) (EVar "diags"))) (EVar "found")) (EApp (EApp (EApp (EVar "omInsert") (EVar "binding")) (ELit LUnit)) (EVar "judged")))))))) (arm PWild () (ETuple (EVar "found") (EVar "judged")))))))
(DTypeSig false "judgeQuiescentGoals" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "Unit"))))
(DFunDef false "judgeQuiescentGoals" ((PVar "mctx") PWild) (EBlock (DoLet false false (PVar "goals") (EApp (EVar "reverseL") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "quiescentGoalsRef") "value"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "quiescentGoalsRef")) (EListLit))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PTuple (PVar "rigidIds") (PVar "window") (PVar "o"))) (EApp (EApp (EVar "each") (EApp (EApp (EApp (EApp (EVar "undeterminedVectorVerdict") (EVar "mctx")) (EVar "rigidIds")) (EVar "omEmpty")) (EVar "window"))) (EBinOp "::" (EVar "o") (EApp (EApp (EApp (EApp (EVar "nestedRequireGoals") (EVar "mctx")) (EVar "rigidIds")) (EVar "omEmpty")) (EListLit (EVar "o"))))))) (EVar "goals")))))
(DTypeSig false "liveMemberIds" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "liveMemberIds" ((PVar "mctx") (PVar "monos")) (EBlock (DoLet false false (PVar "open") (EApp (EApp (EVar "filterList") (ELam ((PVar "m")) (EApp (EVar "isNonEmptyL") (EApp (EApp (EVar "liveVarIdsOf") (EVar "mctx")) (EVar "m"))))) (EBinOp "++" (EVar "monos") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "liveMemberMonosRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "liveMemberMonosRef")) (EVar "open"))) (DoExpr (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (EVar "intToString")) (EApp (EVar "dedupI") (EApp (EApp (EDictApp "flatMap") (EApp (EVar "liveVarIdsOf") (EVar "mctx"))) (EVar "open"))))) (EVar "omEmpty")))))
(DTypeSig false "liveVarIdsOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "liveVarIdsOf" ((PVar "mctx") (PVar "m")) (EApp (EApp (EVar "filterList") (ELam ((PVar "i")) (EApp (EVar "not") (EApp (EApp (EVar "IdMap.has") (EVar "i")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "deferrableVarIds") "value"))))) (EApp (EVar "monoUnboundIds") (EVar "m"))))
(DTypeSig false "userExternSchemes" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "TyConOrigin")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))
(DFunDef false "userExternSchemes" ((PVar "mctx") (PVar "scope") (PVar "decls")) (EApp (EApp (EVar "externSchemesGo") (EVar "mctx")) (EApp (EApp (EVar "stampTyOrigins") (EVar "scope")) (EApp (EVar "externDecls") (EVar "decls")))))
(DTypeSig true "externSchemesGo" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))
(DFunDef false "externSchemesGo" ((PVar "mctx") (PVar "decls")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "n") (PVar "ty"))) (ETuple (EVar "n") (EApp (EApp (EVar "sigToScheme") (EVar "mctx")) (EVar "ty"))))) (EApp (EVar "directExternSigs") (EVar "decls"))))
(DTypeSig false "sigsOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty")))))
(DFunDef false "sigsOf" ((PList)) (EListLit))
(DFunDef false "sigsOf" ((PCons (PCon "DTypeSig" PWild (PVar "n") (PVar "ty") PWild) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EVar "ty")) (EApp (EVar "sigsOf") (EVar "rest"))))
(DFunDef false "sigsOf" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "sigsOf") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "sigsOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "sigsOf") (EVar "rest")))
(DTypeSig false "registerImportOverlay" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "TcEnv")))))
(DFunDef false "registerImportOverlay" ((PVar "env") (PVar "prog") (PVar "overlay")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "seedParamPolarityFixpointScoped") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "overlay")) (EVar "overlay"))) (DoLet false false (PVar "ctorPop") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph") "crossRun") "universeCtorPop") "value")) (DoLet false false (PVar "recordPop") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph") "crossRun") "universeRecordPop") "value")) (DoLet false false (PVar "served") (EApp (EApp (EMethodRef "map") (ELam ((PVar "d")) (ETuple (EVar "d") (EApp (EApp (EApp (EVar "overlayCachedRows") (EVar "ctorPop")) (EVar "recordPop")) (EVar "d"))))) (EVar "overlay"))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PVar "p")) (EMatch (EApp (EVar "snd") (EVar "p")) (arm (PCon "None") () (EApp (EApp (EVar "recordDeclKinds") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EVar "fst") (EVar "p")))) (arm (PCon "Some" PWild) () (ELit LUnit))))) (EVar "served"))) (DoLet false false (PVar "env1") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "e") (PVar "p")) (EIf (EApp (EVar "isAliasDecl") (EApp (EVar "fst") (EVar "p"))) (EApp (EApp (EVar "registerData") (EVar "e")) (EApp (EVar "fst") (EVar "p"))) (EVar "e")))) (EVar "env")) (EVar "served"))) (DoExpr (EApp (EApp (EVar "rejectCyclicAliases") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "prog"))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "e") (PVar "p")) (EMatch (EApp (EVar "snd") (EVar "p")) (arm (PCon "None") () (EIf (EApp (EVar "isAliasDecl") (EApp (EVar "fst") (EVar "p"))) (EVar "e") (EApp (EApp (EVar "registerData") (EVar "e")) (EApp (EVar "fst") (EVar "p"))))) (arm (PCon "Some" (PVar "rows")) () (EApp (EApp (EVar "registerCachedRows") (EVar "e")) (EVar "rows")))))) (EVar "env1")) (EVar "served")))))
(DTypeSig false "overlayCachedRows" (TyFun (TyApp (TyCon "SpellingPop") (TyCon "Scheme")) (TyFun (TyApp (TyCon "SpellingPop") (TyCon "RecordInfo")) (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "RecordInfo")))))))))
(DFunDef false "overlayCachedRows" ((PVar "ctorPop") (PVar "recordPop") (PRec "DData" ((rf "dataCtors" None) (rf "dataOrigin" None)) true)) (EApp (EApp (EApp (EApp (EVar "cachedVariantRows") (EVar "ctorPop")) (EVar "recordPop")) (EVar "dataOrigin")) (EVar "dataCtors")))
(DFunDef false "overlayCachedRows" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "cachedVariantRows" (TyFun (TyApp (TyCon "SpellingPop") (TyCon "Scheme")) (TyFun (TyApp (TyCon "SpellingPop") (TyCon "RecordInfo")) (TyFun (TyCon "TyConOrigin") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "RecordInfo"))))))))))
(DFunDef false "cachedVariantRows" (PWild PWild PWild (PList)) (EApp (EVar "Some") (ETuple (EListLit) (EListLit))))
(DFunDef false "cachedVariantRows" ((PVar "ctorPop") (PVar "recordPop") (PVar "o") (PCons (PCon "Variant" (PVar "cn") (PVar "payload")) (PVar "rest"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "mkIdent") (EVar "NsCtor")) (EVar "o")) (EVar "cn"))) (ELam ((PVar "ident")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "spLookupIdent") (EVar "ident")) (EVar "cn")) (EVar "ctorPop"))) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EVar "cachedRecordRow") (EVar "recordPop")) (EVar "ident")) (EVar "cn")) (EVar "payload"))) (ELam ((PVar "recs")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EVar "cachedVariantRows") (EVar "ctorPop")) (EVar "recordPop")) (EVar "o")) (EVar "rest"))) (ELam ((PVar "later")) (EApp (EVar "Some") (ETuple (EBinOp "::" (ETuple (EVar "cn") (EVar "s")) (EApp (EVar "fst") (EVar "later"))) (EBinOp "++" (EVar "recs") (EApp (EVar "snd") (EVar "later"))))))))))))))
(DTypeSig false "cachedRecordRow" (TyFun (TyApp (TyCon "SpellingPop") (TyCon "RecordInfo")) (TyFun (TyCon "Ident") (TyFun (TyCon "String") (TyFun (TyCon "ConPayload") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "RecordInfo")))))))))
(DFunDef false "cachedRecordRow" ((PVar "recordPop") (PVar "ident") (PVar "cn") (PCon "ConNamed" PWild PWild)) (EApp (EApp (EMethodRef "map") (ELam ((PVar "ri")) (EListLit (ETuple (EVar "cn") (EVar "ri"))))) (EApp (EApp (EApp (EVar "spLookupIdent") (EVar "ident")) (EVar "cn")) (EVar "recordPop"))))
(DFunDef false "cachedRecordRow" (PWild PWild PWild PWild) (EApp (EVar "Some") (EListLit)))
(DTypeSig false "registerCachedRows" (TyFun (TyCon "TcEnv") (TyFun (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "RecordInfo")))) (TyCon "TcEnv"))))
(DFunDef false "registerCachedRows" ((PVar "env") (PTuple (PVar "ctors") (PVar "recs"))) (EBlock (DoExpr (EApp (EApp (EVar "each") (ELam ((PVar "r")) (EApp (EApp (EApp (EVar "registerCachedRecord") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EVar "fst") (EVar "r"))) (EApp (EVar "snd") (EVar "r"))))) (EVar "recs"))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "e") (PVar "c")) (EApp (EApp (EApp (EVar "addCtor") (EVar "e")) (EApp (EVar "fst") (EVar "c"))) (EApp (EVar "snd") (EVar "c"))))) (EVar "env")) (EVar "ctors")))))
(DTypeSig false "registerCachedRecord" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "RecordInfo") (TyCon "Unit")))))
(DFunDef false "registerCachedRecord" ((PVar "mctx") (PVar "key") (PVar "ri")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "recordByNameRef")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "ri")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "recordByNameRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fieldOwnersRef")) (EApp (EApp (EApp (EVar "addFieldOwners") (EVar "key")) (EApp (EVar "recordFieldNames") (EVar "ri"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fieldOwnersRef") "value"))))))
(DTypeSig false "sigNamesToSet" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "sigNamesToSet" ((PList) (PVar "m")) (EVar "m"))
(DFunDef false "sigNamesToSet" ((PCons (PTuple (PVar "n") PWild) (PVar "rest")) (PVar "m")) (EApp (EApp (EVar "sigNamesToSet") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "m"))))
(DTypeSig false "processTopGroups" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))))))
(DFunDef false "processTopGroups" ((PVar "env") (PVar "sigs") (PVar "defs") (PVar "names") (PVar "exported")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "sigNameSetRef")) (EApp (EApp (EVar "sigNamesToSet") (EVar "sigs")) (EVar "omEmpty")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "sigTyMapRef")) (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "sigs"))) (EVar "omEmpty")))) (DoLet false false (PVar "grouped") (EApp (EVar "groupClauses") (EVar "defs"))) (DoLet false false (PVar "ordered") (EApp (EApp (EVar "tarjanSCCs") (EVar "names")) (EApp (EApp (EVar "depGraphMap") (EVar "names")) (EVar "grouped")))) (DoLet false false (PVar "result") (EApp (EApp (EApp (EApp (EVar "processSCCs") (EVar "env")) (EVar "sigs")) (EVar "grouped")) (EVar "ordered"))) (DoExpr (EApp (EApp (EVar "resolvePendingJoins") (EFieldAccess (EVar "env") "teDyn")) (ELit (LInt 0)))) (DoLet false false (PVar "failures") (EApp (EApp (EApp (EApp (EVar "EffectSolver.closeRootAuthorities") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "effectSummaries")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "rigidAuthvarsRef") "value")) (EApp (EApp (EVar "exportedRootCells") (EVar "exported")) (EApp (EVar "fst") (EVar "result")))) (EApp (EVar "widenOpenedFor") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")))) (DoLet false false (PVar "unsolved") (EApp (EApp (EVar "rootCellsOf") (EVar "exported")) (EApp (EVar "fst") (EVar "result")))) (DoLet false false (PVar "unsolvedIds") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PTuple PWild (PVar "ids"))) (EApp (EApp (EVar "IdMap.union") (EVar "acc")) (EVar "ids")))) (EVar "Tip")) (EVar "unsolved"))) (DoExpr (EApp (EApp (EVar "reportEffectSummaryFailures") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EApp (EVar "filterList") (ELam ((PVar "f")) (EApp (EVar "not") (EApp (EApp (EVar "failureMentions") (EVar "unsolvedIds")) (EVar "f"))))) (EVar "failures")))) (DoLet false false PWild (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "seen") (PVar "u")) (EApp (EApp (EApp (EApp (EVar "reportUnsolvedExport") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "grouped")) (EVar "seen")) (EVar "u")))) (EVar "Tip")) (EVar "unsolved"))) (DoExpr (EVar "result"))))
(DTypeSig false "exportedRootCells" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "exportedRootCells" ((PVar "exported") (PVar "schemes")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PTuple PWild (PVar "ids"))) (EApp (EApp (EVar "IdMap.union") (EVar "acc")) (EVar "ids")))) (EVar "Tip")) (EApp (EApp (EVar "rootCellsOf") (EVar "exported")) (EVar "schemes"))))
(DTypeSig false "rootCellsOf" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))))
(DFunDef false "rootCellsOf" ((PVar "exported") (PVar "schemes")) (EApp (EApp (EDictApp "flatMap") (ELam ((PTuple (PVar "name") (PVar "scheme"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "exported")) (EMatch (EApp (EVar "unquantifiedAuthIds") (EVar "scheme")) (arm (PCon "Tip") () (EListLit)) (arm (PVar "ids") () (EListLit (ETuple (EVar "name") (EVar "ids"))))) (EListLit)))) (EVar "schemes")))
(DTypeSig false "failureMentions" (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyCon "SummaryFailure") (TyCon "ObligationSite")) (TyCon "Bool"))))
(DFunDef false "failureMentions" ((PCon "Tip") PWild) (EVar "False"))
(DFunDef false "failureMentions" ((PVar "ids") (PVar "failure")) (EMatch (EFieldAccess (EVar "failure") "esfAuthority") (arm (PCon "Some" (PTuple (PVar "lo") (PVar "hi"))) () (EApp (EApp (EVar "anyList") (ELam ((PVar "c")) (EApp (EApp (EVar "IdMap.has") (EApp (EVar "authvarId") (EVar "c"))) (EVar "ids")))) (EBinOp "++" (EApp (EVar "authVars") (EVar "lo")) (EApp (EVar "authVars") (EVar "hi"))))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "reportUnsolvedExport" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyTuple (TyCon "String") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))))
(DFunDef false "reportUnsolvedExport" ((PVar "mctx") (PVar "grouped") (PVar "seen") (PTuple (PVar "name") (PVar "ids"))) (EIf (EApp (EApp (EApp (EVar "IdMap.foldlWithKey") (ELam ((PVar "acc") (PVar "id") PWild) (EBinOp "&&" (EVar "acc") (EApp (EApp (EVar "IdMap.has") (EVar "id")) (EVar "seen"))))) (EVar "True")) (EVar "ids")) (EVar "seen") (EBlock (DoLet false false (PVar "loc") (EMatch (EApp (EApp (EVar "clausesOf") (EVar "name")) (EVar "grouped")) (arm (PCons (PTuple PWild (PVar "body")) PWild) () (EApp (EVar "firstExprLoc") (EVar "body"))) (arm (PList) () (EVar "None")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (EVar "TExportUnsolvedAuthority")) (EVar "loc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "exported binding `")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` has an authority in its type that nothing in this module determines; give `"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "`, or the value it uses, a type signature that names the authority"))))) (DoExpr (EApp (EApp (EVar "IdMap.union") (EVar "seen")) (EVar "ids"))))))
(DTypeSig false "processSCCs" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))))))
(DFunDef false "processSCCs" ((PVar "env") PWild (PVar "grouped") (PList)) (ETuple (EListLit) (EVar "grouped")))
(DFunDef false "processSCCs" ((PVar "env") (PVar "sigs") (PVar "grouped") (PCons (PVar "scc") (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "env2") (PVar "schemes") (PVar "grouped2")) (EApp (EApp (EApp (EApp (EVar "processSCC") (EVar "env")) (EVar "sigs")) (EVar "grouped")) (EVar "scc"))) (DoLet false false (PTuple (PVar "restSchemes") (PVar "grouped3")) (EApp (EApp (EApp (EApp (EVar "processSCCs") (EVar "env2")) (EVar "sigs")) (EVar "grouped2")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "++" (EVar "schemes") (EVar "restSchemes")) (EVar "grouped3")))))
(DTypeSig false "processSCC" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyCon "TcEnv") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))))))
(DFunDef false "processSCC" ((PVar "outer") (PVar "sigs") (PVar "grouped0") (PVar "members")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EVar "envAtIfSome") (EApp (EApp (EVar "membersSpanLoc") (EVar "grouped0")) (EVar "members"))) (EVar "outer"))) (DoLet false false (PVar "marking") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "markingRef") "value")) (DoLet false false (PVar "grouped") (EMatch (EVar "marking") (arm (PCon "Some" (PVar "mm")) () (EApp (EApp (EApp (EApp (EVar "markGroupClauses") (EVar "mm")) (EVar "env")) (EVar "members")) (EVar "grouped0"))) (arm (PCon "None") () (EVar "grouped0")))) (DoLet false false (PVar "groupedStamped") (EMatch (EVar "marking") (arm (PCon "Some" (PVar "mm")) () (EApp (EApp (EApp (EVar "stampGroupClauses") (EVar "mm")) (EVar "members")) (EVar "grouped"))) (arm (PCon "None") () (EVar "grouped")))) (DoExpr (EApp (EApp (EVar "enterLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "beginEffectSummaryScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "oblN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls"))) (DoLet false false (PVar "callN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "obls"))) (DoLet false false (PVar "dictN0") (EApp (EApp (EVar "goalsMark") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (DoLet false false (PVar "placeholders") (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (ETuple (EVar "m") (EApp (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))))) (EVar "members"))) (DoLet false false (PVar "scopedMembers") (EApp (EApp (EApp (EApp (EVar "scopeMembers") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EApp (EVar "captureScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (EVar "groupedStamped")) (EVar "placeholders"))) (DoLet false false (PTuple (PVar "regs") (PVar "sigTvMaps")) (EApp (EApp (EApp (EVar "preunifySigsEx") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "sigs")) (EVar "scopedMembers"))) (DoLet false false (PVar "savedRigidEffects") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "rigidEffvarsRef") "value")) (DoLet false false (PVar "savedRigidAuths") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "rigidAuthvarsRef") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "rigidEffvarsRef")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "roots") (PVar "member")) (EApp (EApp (EApp (EVar "IdMap.foldlWithKey") (ELam ((PVar "acc") (PVar "id") PWild) (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (ELit LUnit)) (EVar "acc")))) (EVar "roots")) (EFieldAccess (EFieldAccess (EVar "member") "smDeclaredRoots") "value")))) (EVar "savedRigidEffects")) (EVar "scopedMembers")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "rigidAuthvarsRef")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "roots") (PVar "member")) (EApp (EApp (EApp (EVar "IdMap.foldlWithKey") (ELam ((PVar "acc") (PVar "id") PWild) (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (ELit LUnit)) (EVar "acc")))) (EVar "roots")) (EFieldAccess (EFieldAccess (EVar "member") "smDeclaredAuths") "value")))) (EVar "savedRigidAuths")) (EVar "scopedMembers")))) (DoLet false false (PVar "env2") (EApp (EApp (EVar "extendBindings") (EVar "env")) (EApp (EApp (EMethodRef "map") (EVar "scopedMemberBinding")) (EVar "scopedMembers")))) (DoLet false false (PVar "groupCtx") (ERecordCreate "GroupCtx" ((fa "gcMonos" (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "r")) (EApp (EApp (EDictApp "flatMap") (EVar "ifaceMonoName")) (EApp (EVar "regIfaceMonosOf") (EVar "r"))))) (EVar "regs"))) (fa "gcPendingEscapes" (EApp (EVar "Ref") (EListLit)))))) (DoLet false false (PVar "groupEnv") (ERecordUpdate (EVar "env2") ((fa "teDyn" (ERecordUpdate (EFieldAccess (EVar "env2") "teDyn") ((fa "dcGroup" (EApp (EVar "Some") (EVar "groupCtx"))))))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "inferMembers") (EVar "groupEnv")) (EVar "sigs")) (EVar "groupedStamped")) (EVar "scopedMembers"))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PVar "member")) (EApp (EApp (EVar "checkRecursiveValue") (EFieldAccess (EVar "env") "teDyn")) (EFieldAccess (EVar "member") "smOwned")))) (EVar "scopedMembers"))) (DoExpr (EApp (EApp (EVar "resolvePendingJoins") (EFieldAccess (EVar "env") "teDyn")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentLevel") "value"))) (DoLet false false (PVar "residuals") (EApp (EApp (EApp (EApp (EVar "finishEffectSummaryScopeKeeping") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EApp (EApp (EVar "quantifiableAuthorities") (EVar "env2")) (EVar "groupedStamped")) (EVar "scopedMembers"))) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "member")) (EApp (EApp (EVar "memberEffectRoots") (EVar "member")) (EVar "acc")))) (EVar "Tip")) (EVar "scopedMembers"))) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "member")) (EApp (EApp (EApp (EVar "borrowedEffectCells") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EFieldAccess (EVar "member") "smOwned") "bsValue")) (EVar "acc")))) (EVar "Tip")) (EVar "scopedMembers")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "rigidEffvarsRef")) (EVar "savedRigidEffects"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "rigidAuthvarsRef")) (EVar "savedRigidAuths"))) (DoExpr (EApp (EApp (EVar "checkSigsTooGeneral") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "sigTvMaps"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkSigsFixedByExpansive") (EVar "env2")) (EVar "groupedStamped")) (EVar "scopedMembers")) (EVar "sigTvMaps"))) (DoExpr (EApp (EApp (EVar "registerConstraintRegs") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "regs"))) (DoExpr (EApp (EApp (EVar "flushPendingEscapes") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EVar "Some") (EVar "groupCtx")))) (DoExpr (EApp (EApp (EVar "exitLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "protectedSigIds") (EApp (EVar "sccProtectedSignatureIds") (EVar "sigTvMaps"))) (DoLet false false (PVar "addedObls") (EApp (EApp (EVar "wWindow") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls")) (EVar "oblN0"))) (DoLet false false (PVar "groupObls") (EBinOp "++" (EVar "addedObls") (EApp (EApp (EVar "callUOblsWindow") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "callN0")))) (DoLet false false (PVar "unownedIds") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (EVar "intToString")) (EApp (EApp (EDictApp "flatMap") (EVar "monoArgUnboundIds")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "placeholders"))))) (EVar "protectedSigIds"))) (DoExpr (EApp (EApp (EApp (EVar "improveByUniqueImpl") (EFieldAccess (EVar "env") "teDyn")) (EVar "protectedSigIds")) (EVar "addedObls"))) (DoExpr (EApp (EApp (EApp (EVar "improveByUniqueImpl") (EFieldAccess (EVar "env") "teDyn")) (EVar "protectedSigIds")) (EApp (EApp (EVar "callUOblsWindow") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "callN0")))) (DoExpr (EApp (EApp (EApp (EVar "determineByUniqueInstance") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "unownedIds")) (EVar "groupObls"))) (DoLet false false (PVar "defaultObls") (EBinOp "++" (EVar "addedObls") (EApp (EApp (EApp (EVar "calleeNumObls") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "callN0")) (EVar "dictN0")))) (DoLet false false (PVar "sccGuard") (ERecordCreate "NumGuard" ((fa "ngGoals" (EVar "groupObls")) (fa "ngRigidIds" (EVar "protectedSigIds")) (fa "ngOuterBelow" (EVar "None"))))) (DoLet false false (PVar "withheld") (EApp (EApp (EVar "finalizeNumBoundary") (EFieldAccess (EVar "env") "teDyn")) (ERecordCreate "NumBoundary" ((fa "nbDisposition" (EApp (EVar "NumBoundaryOwnedScc") (EBinOp "+" (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentLevel") "value") (ELit (LInt 1))))) (fa "nbMembers" (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "placeholders"))) (fa "nbSurvivingIds" (EApp (EApp (EApp (EApp (EVar "tiedSurvivors") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "placeholders"))) (EVar "sccGuard")) (EVar "protectedSigIds"))) (fa "nbDefaultObls" (EVar "defaultObls")) (fa "nbAmbiguityObls" (EVar "addedObls")) (fa "nbGuard" (EVar "sccGuard")))))) (DoExpr (EApp (EApp (EApp (EVar "improveByUniqueImpl") (EFieldAccess (EVar "env") "teDyn")) (EVar "protectedSigIds")) (EVar "groupObls"))) (DoExpr (EApp (EApp (EApp (EVar "determineByUniqueInstance") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "unownedIds")) (EVar "groupObls"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "checkSigVarGoals") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "DeclaredBySignature")) (EVar "protectedSigIds")) (EVar "sigTvMaps")) (EVar "groupObls"))) (DoLet false false (PVar "schemes") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "sccSchemes") (EVar "env2")) (EVar "sigs")) (EVar "groupedStamped")) (EApp (EVar "isLetrecGroup") (EVar "members"))) (EVar "residuals")) (ELit (LInt 0))) (EVar "scopedMembers"))) (DoLet false false (PVar "scopedSchemes") (EApp (EApp (EVar "alignScopedSchemes") (EVar "scopedMembers")) (EVar "schemes"))) (DoExpr (EApp (EApp (EApp (EVar "checkSigsOverExpansive") (EVar "env2")) (EVar "groupedStamped")) (EVar "sigTvMaps"))) (DoLet false false (PVar "callOblsDelta") (EApp (EApp (EVar "callOblsWindow") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "callN0"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerSchemeObligations") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "schemeDefIdsRef") "value")) (EVar "sigTvMaps")) (EVar "callOblsDelta")) (EVar "addedObls")) (EVar "schemes"))) (DoLet false false (PVar "liveIds") (EApp (EApp (EVar "liveMemberIds") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "placeholders")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "rejectUndeterminedVectors") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "unownedIds")) (EVar "liveIds")) (EVar "addedObls")) (EBinOp "++" (EApp (EApp (EVar "callUOblsWindow") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "callN0")) (EApp (EApp (EApp (EApp (EVar "nestedRequireGoals") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "unownedIds")) (EVar "liveIds")) (EVar "groupObls"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "rejectWithheldAmbiguity") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "unownedIds")) (EVar "withheld")) (EVar "groupObls"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkSigConstraintCoverage") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "regs")) (EVar "sigs")) (EVar "sigTvMaps")) (EVar "callOblsDelta")) (EVar "addedObls")) (EVar "schemes"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "registerInferredConstraints") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "sigs")) (EVar "callOblsDelta")) (EVar "addedObls")) (EVar "scopedSchemes"))) (DoExpr (EApp (EApp (EVar "declareRigidVars") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EVar "omKeys") (EVar "protectedSigIds")))) (DoLet false false (PVar "groupedOut") (EMatch (EVar "marking") (arm (PCon "Some" (PVar "mm")) () (EApp (EApp (EApp (EApp (EApp (EVar "markRecursiveOccurrences") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "mm")) (EVar "placeholders")) (EVar "scopedMembers")) (EVar "grouped"))) (arm (PCon "None") () (EVar "grouped")))) (DoExpr (EMatch (EVar "marking") (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EApp (EVar "recordTopGrants") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentModuleRef") "value")) (EVar "schemes")) (EVar "groupedOut"))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (ETuple (EApp (EApp (EVar "extendTermBindings") (EVar "outer")) (EVar "schemes")) (EVar "schemes") (EVar "groupedOut")))))
(DTypeSig false "scopedMemberBinding" (TyFun (TyCon "ScopedMember") (TyTuple (TyCon "String") (TyCon "EnvBinding"))))
(DFunDef false "scopedMemberBinding" ((PVar "member")) (EBlock (DoLet false false (PVar "binding") (EApp (EApp (EVar "optionOr") (EApp (EVar "ordinaryEnvBinding") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Forall") (EListLit)) (EListLit)) (EListLit)) (EListLit)) (EApp (EVar "memberForce") (EVar "member"))) (EFieldAccess (EFieldAccess (EVar "member") "smOwned") "bsRecursiveValue")))) (EFieldAccess (EFieldAccess (EVar "member") "smRecursive") "value"))) (DoExpr (ETuple (EFieldAccess (EVar "member") "smName") (EApp (EApp (EVar "bindingWithStandalone") (EVar "binding")) (ETuple (EVar "LocalStandalone") (EFieldAccess (EVar "binding") "ebValue")))))))
(DTypeSig false "scopeMembers" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "ScopedMember")))))))
(DFunDef false "scopeMembers" ((PVar "mctx") PWild PWild (PList)) (EListLit))
(DFunDef false "scopeMembers" ((PVar "mctx") (PVar "parent") (PVar "grouped") (PCons (PTuple (PVar "name") (PVar "mono")) (PVar "rest"))) (EBlock (DoLet false false (PVar "sid") (EApp (EApp (EApp (EApp (EApp (EVar "Scopes.freshScope") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EApp (EVar "Some") (EVar "parent"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (EFieldAccess (EApp (EApp (EVar "Scopes.scopeFrame") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EVar "parent")) "sfModuleId")) (EApp (EVar "BindingOwner") (EVar "name")))) (DoLet false false (PVar "clauses") (EApp (EApp (EVar "clausesOf") (EVar "name")) (EVar "grouped"))) (DoLet false false (PVar "arity") (EMatch (EVar "clauses") (arm (PCons (PTuple (PVar "pats") PWild) PWild) () (EApp (EVar "listLen") (EVar "pats"))) (arm (PList) () (ELit (LInt 0))))) (DoLet false false (PVar "owned") (EApp (EApp (EApp (EVar "newBindingSummary") (EVar "arity")) (EApp (EVar "freshVar") (EVar "mctx"))) (EApp (EVar "freshEffectSummary") (EVar "mctx")))) (DoLet false false (PVar "force") (EMatch (EVar "clauses") (arm (PList (PTuple (PList) PWild)) () (EApp (EVar "Some") (EFieldAccess (EVar "owned") "bsForce"))) (arm PWild () (EVar "None")))) (DoExpr (EBinOp "::" (ERecordCreate "ScopedMember" ((fa "smName" (EVar "name")) (fa "smMono" (EVar "mono")) (fa "smOwned" (EVar "owned")) (fa "smDeclaredRoots" (EApp (EVar "Ref") (EVar "Tip"))) (fa "smDeclaredAuths" (EApp (EVar "Ref") (EVar "Tip"))) (fa "smSigned" (EApp (EVar "Ref") (EVar "False"))) (fa "smRecursive" (EApp (EVar "Ref") (EVar "None"))) (fa "smForce" (EVar "force")) (fa "smForceBound" (EApp (EVar "Ref") (EVar "None"))) (fa "smScope" (EVar "sid")))) (EApp (EApp (EApp (EApp (EVar "scopeMembers") (EVar "mctx")) (EVar "parent")) (EVar "grouped")) (EVar "rest"))))))
(DTypeSig false "alignScopedSchemes" (TyFun (TyApp (TyCon "List") (TyCon "ScopedMember")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyCon "ScopedScheme")))))
(DFunDef false "alignScopedSchemes" ((PList) (PList)) (EListLit))
(DFunDef false "alignScopedSchemes" ((PCons (PVar "member") (PVar "members")) (PCons (PTuple (PVar "name") (PVar "scheme")) (PVar "schemes"))) (EIf (EBinOp "==" (EFieldAccess (EVar "member") "smName") (EVar "name")) (EBinOp "::" (ERecordCreate "ScopedScheme" ((fa "ssName" (EVar "name")) (fa "ssScheme" (EVar "scheme")) (fa "ssScope" (EFieldAccess (EVar "member") "smScope")))) (EApp (EApp (EVar "alignScopedSchemes") (EVar "members")) (EVar "schemes"))) (EIf (EVar "otherwise") (EApp (EVar "panic") (ELit (LString "scope/member scheme alignment mismatch"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "alignScopedSchemes" (PWild PWild) (EApp (EVar "panic") (ELit (LString "scope/member scheme arity mismatch"))))
(DTypeSig false "inferMembers" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyCon "ScopedMember")) (TyCon "Unit"))))))
(DFunDef false "inferMembers" ((PVar "env") PWild PWild (PList)) (ELit LUnit))
(DFunDef false "inferMembers" ((PVar "outer") (PVar "sigs") (PVar "grouped") (PCons (PVar "member") (PVar "rest"))) (EBlock (DoLet false false (PVar "m") (EFieldAccess (EVar "member") "smName")) (DoLet false false (PVar "env") (EApp (EApp (EVar "envAtIfSome") (EApp (EApp (EVar "membersSpanLoc") (EVar "grouped")) (EListLit (EVar "m")))) (EVar "outer"))) (DoLet false false (PVar "v") (EFieldAccess (EVar "member") "smMono")) (DoExpr (EApp (EApp (EVar "openScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EVar "member") "smScope"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentFn")) (EVar "m"))) (DoLet false false (PVar "peel") (EApp (EApp (EApp (EApp (EVar "memberPeelSource") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "sigs")) (EVar "m")) (EVar "v"))) (DoLet false false (PVar "effs") (EApp (EApp (EApp (EApp (EVar "inferMemberClauses") (EVar "env")) (EVar "peel")) (EFieldAccess (EVar "member") "smOwned")) (EApp (EApp (EVar "clausesOf") (EVar "m")) (EVar "grouped")))) (DoExpr (EIf (EFieldAccess (EFieldAccess (EVar "member") "smSigned") "value") (EApp (EApp (EApp (EApp (EVar "unifyInto") (EApp (EApp (EVar "dynAtIfSome") (EApp (EVar "joinLocs") (EApp (EApp (EApp (EVar "clauseSpans") (EVar "valueSpanLoc")) (EVar "grouped")) (EListLit (EVar "m"))))) (EFieldAccess (EVar "env") "teDyn"))) (EVar "True")) (EFieldAccess (EVar "member") "smMono")) (EFieldAccess (EFieldAccess (EVar "member") "smOwned") "bsValue")) (ELit LUnit))) (DoExpr (EMatch (EFieldAccess (EFieldAccess (EVar "member") "smForceBound") "value") (arm (PCon "Some" (PVar "bound")) () (EBlock (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "cl")) (EApp (EApp (EApp (EVar "recordFileBound") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EVar "snd") (EVar "cl"))) (EVar "bound")))) (ELit LUnit)) (EApp (EApp (EVar "clausesOf") (EVar "m")) (EVar "grouped")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "rowInto") (EFieldAccess (EVar "env") "teDyn")) (EVar "True")) (EApp (EVar "effrowNorm") (EVar "bound"))) (EApp (EVar "effrowNorm") (EApp (EApp (EVar "optionOr") (EVar "pureRow")) (EFieldAccess (EVar "member") "smForce"))))))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentFn")) (ELit (LString "")))) (DoExpr (EApp (EApp (EVar "closeScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoExpr (EMatch (EFieldAccess (EVar "member") "smForce") (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "checkEffectEscape") (EFieldAccess (EVar "env") "teDyn")) (EVar "sigs")) (EVar "m")) (EVar "effs"))) (arm (PCon "Some" PWild) () (ELit LUnit)))) (DoExpr (EApp (EApp (EApp (EApp (EVar "inferMembers") (EVar "outer")) (EVar "sigs")) (EVar "grouped")) (EVar "rest")))))
(DTypeSig false "membersSpanLoc" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "membersSpanLoc" ((PVar "grouped") (PVar "names")) (EApp (EVar "joinLocs") (EApp (EApp (EApp (EVar "clauseSpans") (EVar "exprSpanLoc")) (EVar "grouped")) (EVar "names"))))
(DTypeSig false "clauseSpans" (TyFun (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Loc"))))))
(DFunDef false "clauseSpans" ((PVar "span") (PVar "grouped") (PVar "names")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "m")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "cl")) (EApp (EApp (EApp (EVar "option") (EListLit)) (ELam ((PVar "l")) (EListLit (EVar "l")))) (EApp (EVar "span") (EApp (EVar "snd") (EVar "cl")))))) (EApp (EApp (EVar "clausesOf") (EVar "m")) (EVar "grouped"))))) (EVar "names")))
(DTypeSig false "memberPeelSource" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "Mono")))))))
(DFunDef false "memberPeelSource" ((PVar "mctx") (PVar "sigs") (PVar "m") (PVar "v")) (EApp (EApp (EMethodRef "map") (ELam (PWild) (EVar "v"))) (EApp (EApp (EVar "omLookup") (EVar "m")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "sigNameSetRef") "value"))))
(DTypeSig false "regIfaceMonosOf" (TyFun (TyCon "ConstraintReg") (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))))))
(DFunDef false "regIfaceMonosOf" ((PVar "reg")) (EFieldAccess (EVar "reg") "crIfaceMonos"))
(DTypeSig false "ifaceMonoName" (TyFun (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))))
(DFunDef false "ifaceMonoName" ((PTuple (PVar "ir") (PVar "monos"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "mono")) (ETuple (EFieldAccess (EVar "ir") "irName") (EVar "mono")))) (EVar "monos")))
(DTypeSig true "checkModuleFull" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "ModuleBindings") (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "ModuleCtx")))))))
(DFunDef false "checkModuleFull" ((PVar "prev") (PVar "seedVars") (PVar "accData") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkModuleFullImpl") (EFieldAccess (EVar "prev") "mcGraph")) (EApp (EVar "checkRunResidue") (EVar "prev"))) (ELit (LString ""))) (EApp (EVar "plainModuleSeed") (EVar "seedVars"))) (EVar "accData")) (EVar "prog")) (EVar "prog")))
(DTypeSig false "checkModuleFullImpl" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "CheckRunSeed") (TyFun (TyCon "String") (TyFun (TyCon "ModuleSeed") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "ModuleBindings") (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "ModuleCtx"))))))))))
(DFunDef false "checkModuleFullImpl" ((PVar "gctx") (PVar "runSeed") (PVar "mid") (PVar "seedVars") (PVar "_accData") (PVar "implDecls") (PVar "prog")) (EBlock (DoLet false false (PTuple (PVar "schemes") (PVar "marked") (PVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkBodyImpl") (EVar "gctx")) (EVar "runSeed")) (EVar "seedVars")) (EVar "mid")) (EVar "implDecls")) (EVar "prog"))) (DoExpr (EApp (EApp (EApp (EVar "enqueueStampCtx") (EVar "mctx")) (EVar "mid")) (EVar "implDecls"))) (DoExpr (ETuple (EVar "schemes") (EVar "marked") (EVar "mctx")))))
(DTypeSig true "publicValNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "publicValNames" ((PList)) (EListLit))
(DFunDef false "publicValNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "publicValNames") (EListLit (EVar "d"))) (EApp (EVar "publicValNames") (EVar "rest"))))
(DFunDef false "publicValNames" ((PCons (PCon "DFunDef" (PCon "True") (PVar "n") PWild PWild PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "publicValNames") (EVar "rest"))))
(DFunDef false "publicValNames" ((PCons (PCon "DTypeSig" (PCon "True") (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "publicValNames") (EVar "rest"))))
(DFunDef false "publicValNames" ((PCons (PCon "DExtern" (PRec "ExternDecl" ((rf "edPub" (PCon "True")) (rf "edName" (PVar "n"))) true)) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "publicValNames") (EVar "rest"))))
(DFunDef false "publicValNames" ((PCons (PRec "DInterface" ((rf "pub" (PCon "True")) (rf "methods" None)) true) (PVar "rest"))) (EBinOp "++" (EApp (EVar "ifaceMethodNames") (EVar "methods")) (EApp (EVar "publicValNames") (EVar "rest"))))
(DFunDef false "publicValNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "publicValNames") (EVar "rest")))
(DTypeSig false "appendUniverseAccums" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))))
(DFunDef false "appendUniverseAccums" ((PVar "gctx") (PVar "mid") (PVar "prog")) (EBlock (DoExpr (EIf (EApp (EVar "isPreludeMid") (EVar "mid")) (ELit LUnit) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "universeFunNamesRef")) (EApp (EApp (EVar "namesToSet") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "funDefs") (EVar "prog")))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "universeFunNamesRef") "value"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "universeMethodDispatchIdxByIdRef")) (EBinOp "++" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "universeMethodDispatchIdxByIdRef") "value") (EApp (EVar "argDispatchIndicesById") (EVar "prog"))))) (DoExpr (ELit LUnit))))
(DTypeSig false "appendDataUniverse" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))))
(DFunDef false "appendDataUniverse" ((PVar "mctx") (PVar "mid") (PVar "prog0")) (EBlock (DoLet false false (PVar "pubDecls") (EApp (EVar "publicDataDecls") (EVar "prog0"))) (DoExpr (EApp (EApp (EVar "loadDataUniverse") (EVar "mctx")) (EApp (EApp (EVar "declEnvsOrdOf") (EVar "mid")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "declEnvsRef") "value")))) (DoLet false false (PVar "env2") (EApp (EApp (EApp (EVar "registerAllDataScoped") (EApp (EApp (EVar "withCtors") (EVar "mctx")) (EApp (EVar "spFloor") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "crossRun") "universeCtorPop") "value")))) (EApp (EVar "publicDataScopeDecls") (EVar "prog0"))) (EVar "prog0"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "crossRun") "universeCtorPop")) (EApp (EApp (EApp (EVar "insertCtorPop") (EVar "env2")) (EVar "pubDecls")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "crossRun") "universeCtorPop") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "crossRun") "universeRecordPop")) (EApp (EApp (EApp (EVar "insertRecordPop") (EVar "mctx")) (EVar "pubDecls")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "crossRun") "universeRecordPop") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "ownPopsRef")) (ETuple (EApp (EApp (EApp (EVar "insertCtorPop") (EVar "env2")) (EVar "pubDecls")) (EVar "spEmpty")) (EApp (EApp (EApp (EVar "insertRecordPop") (EVar "mctx")) (EVar "pubDecls")) (EVar "spEmpty")))))))
(DTypeSig false "publicDataScopeDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "publicDataScopeDecls" ((PVar "prog0")) (EApp (EApp (EVar "filterList") (ELam ((PVar "d")) (EBinOp "||" (EApp (EVar "publicDataDecl") (EVar "d")) (EApp (EVar "isAliasDecl") (EVar "d"))))) (EVar "prog0")))
(DTypeSig false "importedMethodBindingNames" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "importedMethodBindingNames" ((PVar "gctx") (PVar "prog") (PVar "aliases")) (EBinOp "++" (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EApp (EApp (EVar "nameableIfaceRows") (EVar "gctx")) (EVar "prog"))) (EApp (EVar "importedMemberBindingNames") (EVar "prog"))) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "aliases"))))
(DTypeSig false "importedSchemeOblEntries" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "VecObl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "VecObl")))))))
(DFunDef false "importedSchemeOblEntries" ((PList) PWild) (EListLit))
(DFunDef false "importedSchemeOblEntries" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "qual")) (EBinOp "++" (EApp (EApp (EVar "importedSchemeOblEntries") (EListLit (EVar "d"))) (EVar "qual")) (EApp (EApp (EVar "importedSchemeOblEntries") (EVar "rest")) (EVar "qual"))))
(DFunDef false "importedSchemeOblEntries" ((PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest")) (PVar "qual")) (EBinOp "++" (EApp (EApp (EApp (EVar "schemeOblEntriesFor") (EApp (EVar "importTableMid") (EVar "path"))) (EVar "path")) (EVar "qual")) (EApp (EApp (EVar "importedSchemeOblEntries") (EVar "rest")) (EVar "qual"))))
(DFunDef false "importedSchemeOblEntries" ((PCons PWild (PVar "rest")) (PVar "qual")) (EApp (EApp (EVar "importedSchemeOblEntries") (EVar "rest")) (EVar "qual")))
(DTypeSig false "reportAmbiguousImports" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "reportAmbiguousImports" ((PVar "mctx") (PVar "prog0")) (EApp (EApp (EApp (EVar "reportAmbiguousImportsIn") (EVar "mctx")) (EApp (EVar "moduleRefNameSet") (EVar "prog0"))) (EVar "prog0")))
(DTypeSig false "moduleRefNameSet" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))
(DFunDef false "moduleRefNameSet" ((PVar "decls")) (EApp (EApp (EVar "namesToSet") (EApp (EApp (EDictApp "flatMap") (EVar "declRefNames")) (EVar "decls"))) (EVar "omEmpty")))
(DTypeSig false "importedCtorTypeDeclsFirstWins" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "importedCtorTypeDeclsFirstWins" ((PVar "unitDecls") (PVar "cur") (PVar "rows")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "overlayHalf") (EVar "False")) (EVar "unitDecls")) (EVar "cur")) (EVar "rows")) (EApp (EApp (EApp (EApp (EVar "overlayHalf") (EVar "True")) (EVar "unitDecls")) (EVar "cur")) (EVar "rows"))))
(DTypeSig false "importedCtorTypeDeclsLastWins" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "importedCtorTypeDeclsLastWins" ((PVar "unitDecls") (PVar "cur") (PVar "rows")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "overlayHalf") (EVar "True")) (EVar "unitDecls")) (EVar "cur")) (EVar "rows")) (EApp (EApp (EApp (EApp (EVar "overlayHalf") (EVar "False")) (EVar "unitDecls")) (EVar "cur")) (EVar "rows"))))
(DTypeSig false "overlayHalf" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "overlayHalf" ((PVar "wildHalf") (PVar "unitDecls") (PVar "cur") (PVar "rows")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "importOverlayDecls") (EVar "wildHalf")) (EVar "cur")) (EVar "rows"))) (EVar "unitDecls")))
(DTypeSig false "importOverlayDecls" (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "importOverlayDecls" ((PVar "wildHalf") (PVar "cur") (PVar "rows") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EVar "importOverlayDecls") (EVar "wildHalf")) (EVar "cur")) (EVar "rows")) (EVar "d")))
(DFunDef false "importOverlayDecls" ((PVar "wildHalf") (PVar "cur") (PVar "rows") (PCon "DUse" PWild (PAs "p" (PCon "UseGroup" PWild (PVar "ms"))) PWild)) (EIf (EVar "wildHalf") (EListLit) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "memberOverlayDecl") (EVar "cur")) (EVar "rows")) (EApp (EVar "useModId") (EVar "p")))) (EVar "ms"))))
(DFunDef false "importOverlayDecls" ((PVar "wildHalf") (PVar "cur") (PVar "rows") (PCon "DUse" PWild (PAs "p" (PCon "UseWild" PWild)) PWild)) (EIf (EVar "wildHalf") (EApp (EApp (EApp (EVar "wildOverlayDecls") (EVar "cur")) (EVar "rows")) (EApp (EVar "useModId") (EVar "p"))) (EListLit)))
(DFunDef false "importOverlayDecls" (PWild PWild PWild PWild) (EListLit))
(DTypeSig false "oracleImportDecls" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "oracleImportDecls" ((PVar "gctx") (PVar "unitDecls") (PVar "cur") (PVar "rows")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "oracleImportDeclsOf") (EVar "gctx")) (EVar "cur")) (EVar "rows"))) (EVar "unitDecls")))
(DTypeSig false "oracleImportDeclsOf" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "oracleImportDeclsOf" ((PVar "gctx") (PVar "cur") (PVar "rows") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EVar "oracleImportDeclsOf") (EVar "gctx")) (EVar "cur")) (EVar "rows")) (EVar "d")))
(DFunDef false "oracleImportDeclsOf" ((PVar "gctx") (PVar "cur") (PVar "rows") (PCon "DUse" PWild (PAs "p" (PCon "UseAlias" PWild PWild)) PWild)) (EBlock (DoLet false false (PVar "dep") (EApp (EVar "useModId") (EVar "p"))) (DoExpr (EBinOp "++" (EApp (EApp (EApp (EVar "wildOverlayDecls") (EVar "cur")) (EVar "rows")) (EVar "dep")) (EApp (EApp (EApp (EApp (EVar "reexportedCtorDecls") (EVar "gctx")) (EVar "cur")) (EVar "rows")) (EVar "dep"))))))
(DFunDef false "oracleImportDeclsOf" ((PVar "gctx") (PVar "cur") (PVar "rows") (PCon "DUse" PWild (PAs "p" (PCon "UseWild" PWild)) PWild)) (EApp (EApp (EApp (EApp (EVar "reexportedCtorDecls") (EVar "gctx")) (EVar "cur")) (EVar "rows")) (EApp (EVar "useModId") (EVar "p"))))
(DFunDef false "oracleImportDeclsOf" ((PVar "gctx") PWild PWild PWild) (EListLit))
(DTypeSig false "reexportedCtorDecls" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "reexportedCtorDecls" ((PVar "gctx") (PVar "cur") (PVar "rows") (PVar "dep")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "dep")) (EApp (EApp (EVar "ctorExportsIndex") (EVar "gctx")) (ELit LUnit))) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "es")) () (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "k")) (EApp (EApp (EApp (EApp (EVar "reexportedTypeDecl") (EVar "cur")) (EVar "rows")) (EApp (EVar "fst") (EVar "k"))) (EApp (EVar "snd") (EVar "k"))))) (EApp (EApp (EVar "dedupBy") (ELam ((PVar "k")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "fst") (EVar "k")))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "snd") (EVar "k")))) (ELit (LString ""))))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "reexportedOwner") (EVar "dep"))) (EVar "es")))))))
(DTypeSig false "reexportedOwner" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reexportedOwner" ((PVar "dep") (PTuple PWild (PVar "owner") (PCon "Ident" PWild (PVar "io") PWild))) (EApp (EApp (EApp (EVar "identOriginFold") (EListLit)) (ELam ((PVar "m")) (EIf (EBinOp "==" (EVar "m") (EVar "dep")) (EListLit) (EListLit (ETuple (EVar "m") (EVar "owner")))))) (EVar "io")))
(DTypeSig false "reexportedTypeDecl" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "reexportedTypeDecl" (PWild (PList) PWild PWild) (EListLit))
(DFunDef false "reexportedTypeDecl" ((PVar "cur") (PCons (PVar "m") (PVar "rest")) (PVar "declarer") (PVar "tyName")) (EIf (EBinOp "==" (EFieldAccess (EVar "m") "demId") (EVar "declarer")) (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "declIsOwnedType") (EVar "declarer")) (EVar "tyName"))) (EApp (EApp (EVar "declEnvRowVisible") (EVar "cur")) (EVar "m"))) (EApp (EApp (EApp (EApp (EVar "reexportedTypeDecl") (EVar "cur")) (EVar "rest")) (EVar "declarer")) (EVar "tyName"))))
(DTypeSig false "declIsOwnedType" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyCon "Bool")))))
(DFunDef false "declIsOwnedType" ((PVar "mid") (PVar "tyName") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EVar "declIsOwnedType") (EVar "mid")) (EVar "tyName")) (EVar "d")))
(DFunDef false "declIsOwnedType" ((PVar "mid") (PVar "tyName") (PRec "DData" ((rf "dataName" (PVar "tn")) (rf "dataOrigin" (PVar "o"))) false)) (EBinOp "&&" (EBinOp "==" (EVar "tn") (EVar "tyName")) (EApp (EApp (EApp (EVar "declOwnedBy") (EVar "mid")) (EVar "tn")) (EVar "o"))))
(DFunDef false "declIsOwnedType" ((PVar "mid") (PVar "tyName") (PRec "DNewtype" ((rf "newtypeName" (PVar "tn")) (rf "newtypeOrigin" (PVar "o"))) false)) (EBinOp "&&" (EBinOp "==" (EVar "tn") (EVar "tyName")) (EApp (EApp (EApp (EVar "declOwnedBy") (EVar "mid")) (EVar "tn")) (EVar "o"))))
(DFunDef false "declIsOwnedType" (PWild PWild PWild) (EVar "False"))
(DTypeSig false "wildOverlayDecls" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "wildOverlayDecls" (PWild (PList) PWild) (EListLit))
(DFunDef false "wildOverlayDecls" ((PVar "cur") (PCons (PVar "m") (PVar "rest")) (PVar "mid")) (EIf (EBinOp "==" (EFieldAccess (EVar "m") "demId") (EVar "mid")) (EApp (EApp (EVar "declEnvRowVisible") (EVar "cur")) (EVar "m")) (EApp (EApp (EApp (EVar "wildOverlayDecls") (EVar "cur")) (EVar "rest")) (EVar "mid"))))
(DTypeSig false "memberOverlayDecl" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyCon "String") (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "memberOverlayDecl" ((PVar "cur") (PVar "rows") (PVar "mid") (PCon "UseMember" (PVar "n") (PVar "ctors") PWild PWild)) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "findOverlayDecl") (EVar "mid")) (EVar "n")) (EVar "ctors")) (EVar "cur")) (EVar "rows")) (arm (PCon "Some" (PVar "d")) () (EListLit (EVar "d"))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "findOverlayDecl" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyApp (TyCon "Option") (TyCon "Decl"))))))))
(DFunDef false "findOverlayDecl" ((PVar "mid") (PVar "n") (PVar "ctors") (PVar "cur") (PVar "rows")) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "overlayScanRows") (EVar "mid")) (EVar "n")) (EVar "ctors")) (EVar "cur")) (ETuple (EVar "None") (EVar "None") (EVar "None"))) (EVar "rows")) (arm (PTuple (PVar "ownedType") (PVar "ownedCtor") (PVar "bareType")) () (EIf (EVar "ctors") (EApp (EApp (EVar "orElseOpt") (EApp (EApp (EVar "orElseOpt") (EVar "ownedType")) (EVar "ownedCtor"))) (EVar "bareType")) (EVar "ownedCtor")))))
(DTypeSig false "overlayScanRows" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyFun (TyTuple (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl"))) (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyTuple (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl"))))))))))
(DFunDef false "overlayScanRows" (PWild PWild PWild PWild (PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "overlayScanRows" ((PVar "mid") (PVar "n") (PVar "ctors") (PVar "cur") (PVar "acc") (PCons (PVar "m") (PVar "rest"))) (EBlock (DoLet false false (PVar "acc2") (EApp (EApp (EApp (EApp (EApp (EVar "overlayScan") (EVar "mid")) (EVar "n")) (EVar "ctors")) (EVar "acc")) (EApp (EApp (EVar "declEnvRowVisible") (EVar "cur")) (EVar "m")))) (DoExpr (EIf (EApp (EApp (EVar "overlayDecided") (EVar "ctors")) (EVar "acc2")) (EVar "acc2") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "overlayScanRows") (EVar "mid")) (EVar "n")) (EVar "ctors")) (EVar "cur")) (EVar "acc2")) (EVar "rest"))))))
(DTypeSig false "overlayScan" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyTuple (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl")))))))))
(DFunDef false "overlayScan" (PWild PWild PWild (PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "overlayScan" ((PVar "mid") (PVar "n") (PVar "ctors") (PVar "acc") (PCons (PVar "d") (PVar "rest"))) (EBlock (DoLet false false (PVar "acc2") (EApp (EApp (EApp (EApp (EVar "overlayScanOne") (EVar "mid")) (EVar "n")) (EVar "acc")) (EVar "d"))) (DoExpr (EIf (EApp (EApp (EVar "overlayDecided") (EVar "ctors")) (EVar "acc2")) (EVar "acc2") (EApp (EApp (EApp (EApp (EApp (EVar "overlayScan") (EVar "mid")) (EVar "n")) (EVar "ctors")) (EVar "acc2")) (EVar "rest"))))))
(DTypeSig false "overlayDecided" (TyFun (TyCon "Bool") (TyFun (TyTuple (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl"))) (TyCon "Bool"))))
(DFunDef false "overlayDecided" ((PVar "ctors") (PTuple (PVar "ownedType") (PVar "ownedCtor") PWild)) (EIf (EVar "ctors") (EApp (EVar "isSome") (EVar "ownedType")) (EApp (EVar "isSome") (EVar "ownedCtor"))))
(DTypeSig false "overlayScanOne" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyTuple (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl"))) (TyFun (TyCon "Decl") (TyTuple (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl"))))))))
(DFunDef false "overlayScanOne" ((PVar "mid") (PVar "n") (PVar "acc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EVar "overlayScanOne") (EVar "mid")) (EVar "n")) (EVar "acc")) (EVar "d")))
(DFunDef false "overlayScanOne" ((PVar "mid") (PVar "n") (PVar "acc") (PAs "d" (PRec "DData" ((rf "dataName" (PVar "tn")) (rf "dataOrigin" (PVar "o"))) false))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "overlayNote") (EVar "mid")) (EVar "n")) (EVar "tn")) (EVar "o")) (EVar "d")) (EVar "acc")))
(DFunDef false "overlayScanOne" ((PVar "mid") (PVar "n") (PVar "acc") (PAs "d" (PRec "DNewtype" ((rf "newtypeName" (PVar "tn")) (rf "newtypeOrigin" (PVar "o"))) false))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "overlayNote") (EVar "mid")) (EVar "n")) (EVar "tn")) (EVar "o")) (EVar "d")) (EVar "acc")))
(DFunDef false "overlayScanOne" (PWild PWild (PVar "acc") PWild) (EVar "acc"))
(DTypeSig false "overlayNote" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "Decl") (TyFun (TyTuple (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl"))) (TyTuple (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Decl"))))))))))
(DFunDef false "overlayNote" ((PVar "mid") (PVar "n") (PVar "tn") (PVar "o") (PVar "d") (PVar "acc")) (EMatch (EVar "acc") (arm (PTuple (PVar "ownedType") (PVar "ownedCtor") (PVar "bareType")) () (EBlock (DoLet false false (PVar "hitType") (EBinOp "==" (EVar "tn") (EVar "n"))) (DoLet false false (PVar "hitCtor") (EApp (EApp (EVar "declCtorNamed") (EVar "n")) (EVar "d"))) (DoExpr (EIf (EBinOp "||" (EVar "hitType") (EVar "hitCtor")) (EBlock (DoLet false false (PVar "owned") (EApp (EApp (EApp (EVar "declOwnedBy") (EVar "mid")) (EVar "tn")) (EVar "o"))) (DoExpr (ETuple (EIf (EBinOp "&&" (EVar "hitType") (EVar "owned")) (EApp (EApp (EVar "orElseOpt") (EVar "ownedType")) (EApp (EVar "Some") (EVar "d"))) (EVar "ownedType")) (EIf (EBinOp "&&" (EVar "hitCtor") (EVar "owned")) (EApp (EApp (EVar "orElseOpt") (EVar "ownedCtor")) (EApp (EVar "Some") (EVar "d"))) (EVar "ownedCtor")) (EIf (EVar "hitType") (EApp (EApp (EVar "orElseOpt") (EVar "bareType")) (EApp (EVar "Some") (EVar "d"))) (EVar "bareType"))))) (EVar "acc")))))))
(DTypeSig false "declOwnedBy" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyCon "Bool")))))
(DFunDef false "declOwnedBy" ((PVar "mid") (PVar "tyName") (PVar "o")) (EMatch (EApp (EApp (EApp (EVar "mkIdent") (EVar "NsType")) (EApp (EVar "OriginModule") (EVar "mid"))) (EVar "tyName")) (arm (PCon "Some" (PVar "want")) () (EBinOp "==" (EApp (EApp (EApp (EVar "mkIdent") (EVar "NsType")) (EVar "o")) (EVar "tyName")) (EApp (EVar "Some") (EVar "want")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "importDefinersOf" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "importDefinersOf" ((PVar "gctx") (PVar "prog")) (EBlock (DoLet false false (PVar "named") (EApp (EApp (EApp (EVar "useAdmittedRows") (EVar "gctx")) (EVar "False")) (EVar "prog"))) (DoLet false false (PVar "taken") (EApp (EApp (EVar "namesToSet") (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "named")) (EApp (EVar "declTopFnNames") (EVar "prog")))) (EVar "omEmpty"))) (DoExpr (EBinOp "++" (EVar "named") (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EVar "e"))) (EVar "taken"))))) (EApp (EApp (EApp (EVar "useAdmittedRows") (EVar "gctx")) (EVar "True")) (EVar "prog")))))))
(DTypeSig false "useAdmittedRows" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "useAdmittedRows" ((PVar "gctx") PWild (PList)) (EListLit))
(DFunDef false "useAdmittedRows" ((PVar "gctx") (PVar "wild") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EApp (EVar "useAdmittedRows") (EVar "gctx")) (EVar "wild")) (EListLit (EVar "d"))) (EApp (EApp (EApp (EVar "useAdmittedRows") (EVar "gctx")) (EVar "wild")) (EVar "rest"))))
(DFunDef false "useAdmittedRows" ((PVar "gctx") (PVar "wild") (PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EApp (EVar "useDefinerRows") (EVar "gctx")) (EVar "wild")) (EVar "path")) (EApp (EApp (EApp (EVar "useAdmittedRows") (EVar "gctx")) (EVar "wild")) (EVar "rest"))))
(DFunDef false "useAdmittedRows" ((PVar "gctx") (PVar "wild") (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EVar "useAdmittedRows") (EVar "gctx")) (EVar "wild")) (EVar "rest")))
(DTypeSig false "useDefinerRows" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Bool") (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "useDefinerRows" ((PVar "gctx") (PVar "wild") (PVar "path")) (EBlock (DoLet false false (PVar "depId") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "depId") (ELit (LString "core"))) (EListLit) (EMatch (EApp (EVar "importedBindings") (EVar "path")) (arm (PCon "None") () (EIf (EVar "wild") (EApp (EApp (EVar "graphPubDefiners") (EVar "gctx")) (EVar "depId")) (EListLit))) (arm (PCon "Some" (PVar "bindings")) () (EIf (EVar "wild") (EListLit) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "memberDefinerRow") (EVar "depId")) (EApp (EApp (EVar "graphPubDefiners") (EVar "gctx")) (EVar "depId")))) (EVar "bindings")))))))))
(DTypeSig false "memberDefinerRow" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "memberDefinerRow" ((PVar "depId") (PVar "pubs") (PTuple (PVar "origin") (PVar "local"))) (EMatch (EApp (EApp (EVar "resolveMemberRows") (ETuple (EVar "origin") (EVar "local"))) (EVar "pubs")) (arm (PList) () (EListLit (ETuple (EVar "local") (ETuple (EVar "depId") (EVar "origin"))))) (arm (PVar "rows") () (EVar "rows"))))
(DTypeSig false "originRowsOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "originRowsOf" ((PVar "rows")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "e")) (ETuple (EApp (EVar "fst") (EVar "e")) (EApp (EVar "snd") (EApp (EVar "snd") (EVar "e")))))) (EVar "rows")))
(DTypeSig false "definerRowsOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "definerRowsOf" ((PVar "rows")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "e")) (ETuple (EApp (EVar "fst") (EVar "e")) (EApp (EVar "fst") (EApp (EVar "snd") (EVar "e")))))) (EVar "rows")))
(DTypeSig true "checkModuleFullDiags" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "ModuleSeed") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "ModuleBindings") (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyCon "ModuleCtx")))))))))
(DFunDef false "checkModuleFullDiags" ((PVar "gctx") (PVar "mid") (PVar "seedVars") (PVar "accData") (PVar "accAll") (PVar "prog")) (EBlock (DoLet false false (PVar "declEnvsHere") (EFieldAccess (EFieldAccess (EVar "gctx") "declEnvsRef") "value")) (DoLet false false (PVar "runSeed") (EApp (EVar "seedCheckRun") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EVar "prog") (EApp (EApp (EApp (EVar "importedCtorTypeDeclsFirstWins") (EVar "prog")) (EApp (EApp (EVar "declEnvsOrdOf") (EVar "mid")) (EVar "declEnvsHere"))) (EFieldAccess (EVar "declEnvsHere") "deModules"))) (EApp (EApp (EApp (EApp (EVar "oracleImportDecls") (EVar "gctx")) (EVar "prog")) (EApp (EApp (EVar "declEnvsOrdOf") (EVar "mid")) (EVar "declEnvsHere"))) (EFieldAccess (EVar "declEnvsHere") "deModules"))) (EVar "accData")))) (DoLet false false (PTuple (PVar "schemes") (PVar "marked") (PVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkModuleFullImpl") (EVar "gctx")) (EVar "runSeed")) (EVar "mid")) (EVar "seedVars")) (EVar "accData")) (EVar "accAll")) (EVar "prog"))) (DoLet false false (PVar "ceHere") (EFieldAccess (EVar "declEnvsHere") "deIfaces")) (DoLet false false (PVar "ordHere") (EApp (EApp (EVar "declEnvsOrdOf") (EVar "mid")) (EVar "declEnvsHere"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runFinalChecks") (EVar "mctx")) (EVar "prog")) (EVar "ceHere")) (EVar "ceHere")) (EFieldAccess (EVar "declEnvsHere") "deImpls")) (EFieldAccess (EVar "declEnvsHere") "deImpls")) (EVar "ordHere"))) (DoExpr (ETuple (EVar "schemes") (EVar "marked") (EApp (EVar "reverseL") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrors") "items") "value")) (EApp (EVar "reverseL") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchWarnings") "value")) (EVar "mctx")))))
(DTypeSig false "unjudgedRanges" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "unjudgedRanges" ((PVar "lo") (PVar "hi") (PVar "skips")) (EApp (EApp (EApp (EVar "cutRanges") (EVar "lo")) (EVar "hi")) (EApp (EApp (EVar "sortOn") (EVar "fst")) (EApp (EApp (EVar "filterList") (ELam ((PTuple (PVar "a") (PVar "b"))) (EBinOp "&&" (EBinOp ">" (EVar "b") (EVar "lo")) (EBinOp "<" (EVar "a") (EVar "hi"))))) (EVar "skips")))))
(DTypeSig false "cutRanges" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "cutRanges" ((PVar "lo") (PVar "hi") (PList)) (EIf (EBinOp "<" (EVar "lo") (EVar "hi")) (EListLit (ETuple (EVar "lo") (EVar "hi"))) (EListLit)))
(DFunDef false "cutRanges" ((PVar "lo") (PVar "hi") (PCons (PTuple (PVar "a") (PVar "b")) (PVar "rest"))) (EBinOp "++" (EIf (EBinOp ">" (EVar "a") (EVar "lo")) (EListLit (ETuple (EVar "lo") (EVar "a"))) (EListLit)) (EApp (EApp (EApp (EVar "cutRanges") (EApp (EApp (EMethodRef "max") (EVar "lo")) (EVar "b"))) (EVar "hi")) (EVar "rest"))))
(DTypeSig false "selfNameRows" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))))
(DFunDef false "selfNameRows" ((PVar "prog") (PVar "old")) (EBlock (DoLet false false (PVar "own") (EApp (EApp (EVar "namesToSet") (EApp (EVar "declTopFnNames") (EVar "prog"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EVar "e"))) (EVar "own")))) (EVar "old")))))
(DTypeSig false "attributeModuleEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyVar "a")))))))
(DFunDef false "attributeModuleEntries" ((PVar "mid") (PVar "prog") (PVar "entries")) (EBlock (DoLet false false (PVar "progNames") (EApp (EApp (EVar "namesToSet") (EApp (EVar "declTopFnNames") (EVar "prog"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "e")) (ETuple (ETuple (EVar "mid") (EApp (EVar "fst") (EVar "e"))) (EApp (EVar "snd") (EVar "e"))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EVar "e"))) (EVar "progNames")))) (EVar "entries"))))))
(DTypeSig false "attributeModuleSchemeObls" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "VecObl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "VecObl")))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "VecObl")))))))))
(DFunDef false "attributeModuleSchemeObls" ((PVar "mid") (PVar "prog") (PVar "qual") (PVar "entries")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "attributeSchemeOblsGo") (EVar "mid")) (EApp (EApp (EVar "namesToSet") (EApp (EVar "publicValNames") (EVar "prog"))) (EVar "omEmpty"))) (EVar "omEmpty")) (EVar "entries")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "e")) (ETuple (ETuple (EVar "mid") (EApp (EVar "fst") (EVar "e"))) (EApp (EVar "snd") (EVar "e"))))) (EApp (EApp (EVar "reexportSchemeOblEntries") (EVar "prog")) (EVar "qual")))))
(DTypeSig false "reexportSchemeOblEntries" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "VecObl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "VecObl")))))))
(DFunDef false "reexportSchemeOblEntries" ((PList) PWild) (EListLit))
(DFunDef false "reexportSchemeOblEntries" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "qual")) (EBinOp "++" (EApp (EApp (EVar "reexportSchemeOblEntries") (EListLit (EVar "d"))) (EVar "qual")) (EApp (EApp (EVar "reexportSchemeOblEntries") (EVar "rest")) (EVar "qual"))))
(DFunDef false "reexportSchemeOblEntries" ((PCons (PCon "DUse" (PCon "True") (PVar "path") PWild) (PVar "rest")) (PVar "qual")) (EBinOp "++" (EApp (EApp (EApp (EVar "schemeOblEntriesFor") (EApp (EVar "useModId") (EVar "path"))) (EVar "path")) (EVar "qual")) (EApp (EApp (EVar "reexportSchemeOblEntries") (EVar "rest")) (EVar "qual"))))
(DFunDef false "reexportSchemeOblEntries" ((PCons PWild (PVar "rest")) (PVar "qual")) (EApp (EApp (EVar "reexportSchemeOblEntries") (EVar "rest")) (EVar "qual")))
(DTypeSig false "attributeSchemeOblsGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "VecObl")))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "VecObl")))))))))
(DFunDef false "attributeSchemeOblsGo" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "attributeSchemeOblsGo" ((PVar "mid") (PVar "progNames") (PVar "seen") (PCons (PVar "e") (PVar "rest"))) (EIf (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EApp (EVar "fst") (EVar "e")))) (EVar "progNames"))) (EApp (EApp (EApp (EApp (EVar "attributeSchemeOblsGo") (EVar "mid")) (EVar "progNames")) (EVar "seen")) (EVar "rest")) (EIf (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EApp (EVar "fst") (EVar "e")))) (EVar "seen")) (EApp (EApp (EApp (EApp (EVar "attributeSchemeOblsGo") (EVar "mid")) (EVar "progNames")) (EVar "seen")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (ETuple (EVar "mid") (EApp (EVar "fst") (EApp (EVar "fst") (EVar "e")))) (EApp (EVar "snd") (EVar "e"))) (EApp (EApp (EApp (EApp (EVar "attributeSchemeOblsGo") (EVar "mid")) (EVar "progNames")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "fst") (EApp (EVar "fst") (EVar "e")))) (ELit LUnit)) (EVar "seen"))) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "attributeMethodModulePredicateSlots" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "MethodPredicateSlot"))))))))
(DFunDef false "attributeMethodModulePredicateSlots" ((PVar "mid") (PVar "prog") (PVar "entries")) (EBlock (DoLet false false (PVar "progMethods") (EApp (EApp (EVar "namesToSet") (EApp (EVar "ifaceMethodSlotKeys") (EVar "prog"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "e")) (ETuple (ETuple (EVar "mid") (EApp (EVar "fst") (EVar "e"))) (EApp (EVar "snd") (EVar "e"))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EVar "e"))) (EVar "progMethods")))) (EVar "entries"))))))
(DTypeSig false "ifaceMethodSlotKeys" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ifaceMethodSlotKeys" ((PList)) (EListLit))
(DFunDef false "ifaceMethodSlotKeys" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "ifaceMethodSlotKeys") (EListLit (EVar "d"))) (EApp (EVar "ifaceMethodSlotKeys") (EVar "rest"))))
(DFunDef false "ifaceMethodSlotKeys" ((PCons (PRec "DInterface" ((rf "name" None) (rf "methods" None) (rf "ifaceOrigin" None)) true) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EApp (EVar "methodSlotKey") (ERecordCreate "IfaceRef" ((fa "irName" (EVar "name")) (fa "irOrigin" (EVar "ifaceOrigin")))))) (EApp (EVar "ifaceMethodNames") (EVar "methods"))) (EApp (EVar "ifaceMethodSlotKeys") (EVar "rest"))))
(DFunDef false "ifaceMethodSlotKeys" ((PCons PWild (PVar "rest"))) (EApp (EVar "ifaceMethodSlotKeys") (EVar "rest")))
(DTypeSig true "elabModuleStamp" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "ModuleBindings") (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "ModuleCtx")))))))))
(DFunDef false "elabModuleStamp" ((PVar "prev") (PVar "mid") (PVar "seedVars") (PVar "accData") (PVar "implDecls") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkModuleFullImpl") (EFieldAccess (EVar "prev") "mcGraph")) (EApp (EVar "checkRunResidue") (EVar "prev"))) (EVar "mid")) (EApp (EVar "plainModuleSeed") (EVar "seedVars"))) (EVar "accData")) (EVar "implDecls")) (EVar "prog")))
(DTypeSig false "moduleStampOrder" (TyApp (TyCon "List") (TyCon "StampStep")))
(DFunDef false "moduleStampOrder" () (EListLit (EVar "SSNumlitFloats") (EVar "SSReturnSites") (EVar "SSBinopSites") (EVar "SSUnopSites") (EVar "SSArithSites") (EVar "SSArgStamps") (EVar "SSRLocalSites") (EVar "SSRecDictApps") (EVar "SSDictApps") (EVar "SSMethodDicts")))
(DTypeSig true "isLiveSpan" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Bool"))))
(DFunDef false "isLiveSpan" (PWild (PCon "None")) (EVar "False"))
(DFunDef false "isLiveSpan" ((PVar "live") (PVar "loc")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "locKey") (EVar "loc"))) (EVar "live")))
(DTypeSig false "runStampSteps" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "StampCtx") (TyFun (TyApp (TyCon "List") (TyCon "StampStep")) (TyCon "Unit")))))
(DFunDef false "runStampSteps" ((PVar "stamp") (PVar "ctx") (PVar "steps")) (EApp (EApp (EVar "each") (EApp (EApp (EVar "runStampStep") (EVar "stamp")) (EVar "ctx"))) (EVar "steps")))
(DTypeSig false "numlitSince" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Float"))) (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Route")))))))
(DFunDef false "numlitSince" ((PVar "gctx") (PVar "mark")) (EApp (EApp (EApp (EVar "moduleWindow") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "numlitN") "value")) (EVar "mark")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "numlitRefs") "value")))
(DTypeSig false "stampCtxOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Obligation")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Float"))) (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Route")))) (TyCon "StampCtx")))))))
(DFunDef false "stampCtxOf" ((PVar "mctx") (PVar "mid") (PVar "implDecls") (PVar "goals") (PVar "numlits")) (EBlock (DoLet false false (PVar "dropped") (EApp (EApp (EVar "blankModuleCtx") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "mid"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "dropped") "mcCells") "superDeclsRef")) (EApp (EApp (EVar "filterList") (EVar "isInterfaceDecl")) (EVar "implDecls")))) (DoExpr (ERecordCreate "StampCtx" ((fa "scModule" (EVar "mid")) (fa "scModuleCtx" (EApp (EApp (EApp (EApp (EApp (EVar "moduleCtxFrom") (EVar "False")) (EVar "mctx")) (EVar "dropped")) (EVar "dropped")) (EVar "dropped"))) (fa "scRpNames" (EApp (EVar "returnPosMethodNames") (EVar "implDecls"))) (fa "scGoals" (EVar "goals")) (fa "scNumlits" (EVar "numlits")) (fa "scLiveLocs" (EApp (EApp (EVar "liveLocsOf") (EVar "mctx")) (EVar "goals"))))))))
(DTypeSig false "liveLocsOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Obligation")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "liveLocsOf" ((PVar "mctx") (PVar "goals")) (EBlock (DoLet false false (PVar "ids") (EApp (EApp (EDictApp "flatMap") (EVar "monoUnboundIds")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "liveRoots") "value"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "ids")) (EListLit) (EBlock (DoLet false false (PVar "live") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "i")) (EApp (EApp (EApp (EVar "IdMap.set") (EVar "i")) (ELit LUnit)) (EVar "acc")))) (EVar "Tip")) (EVar "ids"))) (DoLet false false (PVar "mentions") (ELam ((PVar "ms")) (EApp (EApp (EVar "anyList") (ELam ((PVar "m")) (EApp (EApp (EVar "anyList") (ELam ((PVar "i")) (EApp (EApp (EVar "IdMap.has") (EVar "i")) (EVar "live")))) (EApp (EVar "monoUnboundIds") (EVar "m"))))) (EVar "ms")))) (DoExpr (EApp (EVar "spanKeys") (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "o")) (EFieldAccess (EVar "o") "oLoc"))) (EApp (EApp (EVar "filterList") (ELam ((PVar "o")) (EApp (EVar "mentions") (EApp (EVar "goalMonos") (EVar "o"))))) (EVar "goals"))) (EApp (EApp (EMethodRef "filterMap") (ELam ((PTuple PWild (PVar "m") (PVar "loc"))) (EIf (EApp (EVar "mentions") (EListLit (EVar "m"))) (EApp (EVar "Some") (EVar "loc")) (EVar "None")))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "admittedOccObls") "value"))))))))))
(DTypeSig true "spanKeys" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "spanKeys" ((PList)) (EListLit))
(DFunDef false "spanKeys" ((PCons (PCon "None") (PVar "rest"))) (EApp (EVar "spanKeys") (EVar "rest")))
(DFunDef false "spanKeys" ((PCons (PVar "loc") (PVar "rest"))) (EBinOp "::" (EApp (EVar "locKey") (EVar "loc")) (EApp (EVar "spanKeys") (EVar "rest"))))
(DTypeSig false "isInterfaceDecl" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isInterfaceDecl" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "isInterfaceDecl") (EVar "d")))
(DFunDef false "isInterfaceDecl" ((PRec "DInterface" () false)) (EVar "True"))
(DFunDef false "isInterfaceDecl" (PWild) (EVar "False"))
(DTypeSig false "enqueueStampCtx" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))))
(DFunDef false "enqueueStampCtx" ((PVar "mctx") (PVar "mid") (PVar "implDecls")) (EBlock (DoLet false false (PVar "mk") (EApp (EApp (EVar "currentModuleMarks") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (DoLet false false (PVar "ctx") (EApp (EApp (EApp (EApp (EApp (EVar "stampCtxOf") (EVar "mctx")) (EVar "mid")) (EVar "implDecls")) (EApp (EApp (EVar "goalsSince") (EFieldAccess (EVar "mctx") "mcGraph")) (EFieldAccess (EVar "mk") "mGoals"))) (EApp (EApp (EVar "numlitSince") (EFieldAccess (EVar "mctx") "mcGraph")) (EFieldAccess (EVar "mk") "mNumlit")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "stampCtxs")) (EBinOp "::" (EVar "ctx") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "stampCtxs") "value"))))))
(DTypeSig false "stampNoting" (TyFun (TyCon "ModuleCtx") (TyFun (TyFun (TyCon "SiteCtx") (TyFun (TyCon "Obligation") (TyCon "Unit"))) (TyFun (TyCon "Obligation") (TyCon "Unit")))))
(DFunDef false "stampNoting" ((PVar "stamp") (PVar "resolve") (PVar "o")) (EBlock (DoLet false false (PVar "acc") (EApp (EVar "Ref") (EVar "innerNone"))) (DoExpr (EApp (EApp (EVar "resolve") (ERecordUpdate (EApp (EVar "siteFor") (EVar "stamp")) ((fa "sxInner" (EApp (EVar "Some") (EVar "acc")))))) (EVar "o"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "o") "oInner")) (EApp (EApp (EVar "innerOr") (EFieldAccess (EFieldAccess (EVar "o") "oInner") "value")) (EFieldAccess (EVar "acc") "value"))))))
(DTypeSig false "runStampStep" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "StampCtx") (TyFun (TyCon "StampStep") (TyCon "Unit")))))
(DFunDef false "runStampStep" ((PVar "mctx") (PVar "ctx") (PCon "SSNumlitFloats")) (EApp (EVar "setNumlitFloatsGo") (EFieldAccess (EVar "ctx") "scNumlits")))
(DFunDef false "runStampStep" ((PVar "stamp") (PVar "ctx") (PCon "SSReturnSites")) (EBlock (DoLet false false (PVar "rpNames") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "ctx") "scRpNames")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "stampEach") (EVar "stamp")) (ELam ((PVar "sx") (PVar "o")) (EApp (EApp (EApp (EVar "resolveSites") (EVar "sx")) (EVar "rpNames")) (EApp (EVar "siteEntry") (EVar "o"))))) (EVar "GKReturnSite")) (EVar "ctx")))))
(DFunDef false "runStampStep" ((PVar "stamp") (PVar "ctx") (PCon "SSBinopSites")) (EApp (EApp (EApp (EApp (EVar "stampEach") (EVar "stamp")) (ELam ((PVar "sx") (PVar "o")) (EApp (EApp (EApp (EVar "resolveOpSites") (EVar "sx")) (EVar "True")) (EApp (EVar "siteEntry") (EVar "o"))))) (EVar "GKBinopSite")) (EVar "ctx")))
(DFunDef false "runStampStep" ((PVar "stamp") (PVar "ctx") (PCon "SSUnopSites")) (EApp (EApp (EApp (EApp (EVar "stampEach") (EVar "stamp")) (ELam ((PVar "sx") (PVar "o")) (EApp (EApp (EApp (EVar "resolveOpSites") (EVar "sx")) (EVar "False")) (EApp (EVar "siteEntry") (EVar "o"))))) (EVar "GKUnopSite")) (EVar "ctx")))
(DFunDef false "runStampStep" ((PVar "stamp") (PVar "ctx") (PCon "SSArithSites")) (EApp (EApp (EApp (EApp (EVar "stampEach") (EVar "stamp")) (ELam (PWild (PVar "o")) (EApp (EVar "resolveArithSites") (EApp (EVar "arithEntry") (EVar "o"))))) (EVar "GKArithSite")) (EVar "ctx")))
(DFunDef false "runStampStep" ((PVar "stamp") (PVar "ctx") (PCon "SSArgStamps")) (EApp (EApp (EApp (EApp (EVar "stampEach") (EVar "stamp")) (ELam ((PVar "sx") (PVar "o")) (EApp (EApp (EVar "resolveArgStamps") (EVar "sx")) (EApp (EVar "siteEntry") (EVar "o"))))) (EVar "GKArgStamp")) (EVar "ctx")))
(DFunDef false "runStampStep" ((PVar "stamp") (PVar "ctx") (PCon "SSRLocalSites")) (EApp (EApp (EApp (EApp (EVar "stampEach") (EVar "stamp")) (ELam ((PVar "sx") (PVar "o")) (EApp (EApp (EVar "resolveRLocalSites") (EVar "sx")) (EApp (EVar "siteEntry") (EVar "o"))))) (EVar "GKRLocalSite")) (EVar "ctx")))
(DFunDef false "runStampStep" ((PVar "stamp") (PVar "ctx") (PCon "SSRecDictApps")) (EApp (EApp (EApp (EApp (EVar "stampEach") (EVar "stamp")) (ELam ((PVar "sx") (PVar "o")) (EApp (EApp (EVar "realizeRecDictApps") (EVar "sx")) (EApp (EVar "recDictAppEntry") (EVar "o"))))) (EVar "GKRecDictApp")) (EVar "ctx")))
(DFunDef false "runStampStep" ((PVar "stamp") (PVar "ctx") (PCon "SSDictApps")) (EApp (EApp (EApp (EApp (EVar "stampEach") (EVar "stamp")) (ELam ((PVar "sx") (PVar "o")) (EApp (EApp (EVar "resolveDictApps") (EVar "sx")) (EApp (EVar "dictAppEntry") (EVar "o"))))) (EVar "GKDictApp")) (EVar "ctx")))
(DFunDef false "runStampStep" ((PVar "stamp") (PVar "ctx") (PCon "SSMethodDicts")) (EApp (EApp (EApp (EApp (EVar "stampEach") (EVar "stamp")) (ELam ((PVar "sx") (PVar "o")) (EApp (EApp (EVar "resolveMethodDicts") (EVar "sx")) (EApp (EVar "methodDictEntry") (EVar "o"))))) (EVar "GKMethodDict")) (EVar "ctx")))
(DTypeSig false "stampEach" (TyFun (TyCon "ModuleCtx") (TyFun (TyFun (TyCon "SiteCtx") (TyFun (TyCon "Obligation") (TyCon "Unit"))) (TyFun (TyCon "GoalKind") (TyFun (TyCon "StampCtx") (TyCon "Unit"))))))
(DFunDef false "stampEach" ((PVar "stamp") (PVar "resolve") (PVar "k") (PVar "ctx")) (EApp (EApp (EVar "each") (EApp (EApp (EVar "stampNoting") (EVar "stamp")) (EVar "resolve"))) (EApp (EApp (EVar "goalsOfKindIn") (EVar "k")) (EFieldAccess (EVar "ctx") "scGoals"))))
(DTypeSig true "verdictFinding" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "TcDiag") (TyCon "DrainFinding")))))
(DFunDef false "verdictFinding" ((PVar "mid") (PVar "live") (PVar "d")) (ERecordCreate "DrainFinding" ((fa "dfModule" (EVar "mid")) (fa "dfDiag" (EVar "d")) (fa "dfVerdict" (EVar "True")) (fa "dfLive" (EVar "live")))))
(DTypeSig true "captureTypeErrors" (TyFun (TyCon "ModuleCtx") (TyFun (TyFun (TyCon "Unit") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "TcDiag")))))
(DFunDef false "captureTypeErrors" ((PVar "mctx") (PVar "act")) (EBlock (DoLet false false (PVar "w") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrors")) (DoLet false false (PVar "items") (EFieldAccess (EFieldAccess (EVar "w") "items") "value")) (DoLet false false (PVar "mark") (EApp (EVar "wMark") (EVar "w"))) (DoLet false false (PVar "sticky") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "typeErrorsSticky") "value")) (DoLet false false (PVar "stickyDiags") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "typeErrorsStickyDiags") "value")) (DoExpr (EApp (EVar "act") (ELit LUnit))) (DoLet false false (PVar "added") (EApp (EApp (EVar "wWindow") (EVar "w")) (EVar "mark"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "w") "items")) (EVar "items"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "w") "n")) (EVar "mark"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "typeErrorsSticky")) (EVar "sticky"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "typeErrorsStickyDiags")) (EVar "stickyDiags"))) (DoExpr (EApp (EVar "reverseL") (EVar "added")))))
(DTypeSig true "drainStampQueue" (TyFun (TyCon "ModuleCtx") (TyApp (TyCon "List") (TyCon "DrainFinding"))))
(DFunDef false "drainStampQueue" ((PVar "saved")) (EBlock (DoLet false false (PVar "ctxs") (EApp (EVar "reverseL") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "saved") "mcGraph") "graphRun") "stampCtxs") "value"))) (DoExpr (EApp (EVar "defaultLiveNumRoots") (EVar "saved"))) (DoLet false false (PVar "held") (EApp (EApp (EVar "judgeLiveGoals") (EVar "saved")) (EVar "ctxs"))) (DoLet false false (PVar "verdicts") (EApp (EApp (EVar "runStampCtxs") (EVar "saved")) (EVar "ctxs"))) (DoLet false false (PVar "liveLocs") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "c")) (EFieldAccess (EVar "c") "scLiveLocs"))) (EVar "ctxs"))) (EVar "omEmpty"))) (DoLet false false (PVar "holes") (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "mid") (PVar "d"))) (ERecordCreate "DrainFinding" ((fa "dfModule" (EVar "mid")) (fa "dfDiag" (EVar "d")) (fa "dfVerdict" (EVar "False")) (fa "dfLive" (EApp (EApp (EVar "isLiveSpan") (EVar "liveLocs")) (EApp (EVar "tcLoc") (EVar "d")))))))) (EApp (EApp (EVar "judgeEvidence") (EFieldAccess (EVar "saved") "mcGraph")) (EVar "ctxs")))) (DoExpr (EApp (EApp (EVar "materializeBinderTypes") (EFieldAccess (EVar "saved") "mcGraph")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "saved") "mcGraph") "graphRun") "stampCtxs")) (EListLit))) (DoExpr (EBinOp "++" (EBinOp "++" (EVar "held") (EVar "verdicts")) (EVar "holes")))))
(DTypeSig true "checkGraphFinish" (TyFun (TyCon "ModuleCtx") (TyApp (TyCon "List") (TyCon "DrainFinding"))))
(DFunDef false "checkGraphFinish" ((PVar "mctx")) (EBlock (DoLet false false (PVar "savedSticky") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "typeErrorsSticky") "value")) (DoLet false false (PVar "savedStickyDiags") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "typeErrorsStickyDiags") "value")) (DoLet false false (PVar "holes") (EApp (EVar "drainStampQueue") (EVar "mctx"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "typeErrorsSticky")) (EVar "savedSticky"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "typeErrorsStickyDiags")) (EVar "savedStickyDiags"))) (DoExpr (EVar "holes"))))
(DTypeSig false "judgeEvidence" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "StampCtx")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))))))
(DFunDef false "judgeEvidence" ((PVar "gctx") (PVar "ctxs")) (EBlock (DoLet false false (PVar "g") (EFieldAccess (EVar "gctx") "graphRun")) (DoLet false false (PVar "lo") (EFieldAccess (EFieldAccess (EVar "g") "evJudged") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "evJudged")) (EFieldAccess (EFieldAccess (EVar "g") "evCounter") "value"))) (DoLet false false (PVar "base") (EFieldAccess (EVar "g") "evBase")) (DoLet false false (PVar "cellHoles") (EApp (EApp (EDictApp "flatMap") (ELam ((PTuple (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EApp (EVar "judgeCells") (EFieldAccess (EFieldAccess (EVar "g") "evCells") "value")) (EBinOp "-" (EVar "a") (EVar "base"))) (EBinOp "-" (EVar "b") (EVar "base"))) (EListLit)))) (EApp (EApp (EApp (EVar "unjudgedRanges") (EVar "lo")) (EFieldAccess (EFieldAccess (EVar "g") "evCounter") "value")) (EFieldAccess (EFieldAccess (EVar "g") "evScopedJudged") "value")))) (DoLet false false (PVar "goalHoles") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "c")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "judgeGoal") (EFieldAccess (EVar "c") "scModule"))) (EFieldAccess (EVar "c") "scGoals")))) (EVar "ctxs"))) (DoExpr (EApp (EApp (EVar "dedupBy") (EVar "holeKey")) (EBinOp "++" (EVar "cellHoles") (EVar "goalHoles"))))))
(DTypeSig false "holeKey" (TyFun (TyTuple (TyCon "String") (TyCon "TcDiag")) (TyCon "String")))
(DFunDef false "holeKey" ((PTuple (PVar "m") (PCon "TcDiag" PWild PWild (PVar "loc") (PVar "msg") PWild PWild))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "lenKey") (EVar "m")))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EVar "lenKey") (EApp (EVar "locGoalKey") (EVar "loc"))))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))
(DTypeSig false "judgeCells" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvCell"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))))))))
(DFunDef false "judgeCells" ((PVar "arr") (PVar "i") (PVar "hi") (PVar "acc")) (EIf (EBinOp "||" (EBinOp ">=" (EVar "i") (EVar "hi")) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr")))) (EVar "acc") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (arm (PCon "Some" (PVar "c")) () (EMatch (EFieldAccess (EFieldAccess (EVar "c") "ecArity") "value") (arm (PCon "Some" PWild) () (EBlock (DoLet false false (PVar "row") (EApp (EApp (EApp (EApp (EApp (EVar "OccurrenceRow") (EFieldAccess (EFieldAccess (EVar "c") "ecName") "value")) (EFieldAccess (EFieldAccess (EVar "c") "ecIface") "value")) (EFieldAccess (EFieldAccess (EVar "c") "ecTag") "value")) (EFieldAccess (EFieldAccess (EVar "c") "ecImpl") "value")) (EFieldAccess (EFieldAccess (EVar "c") "ecMeth") "value"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "judgeCells") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "hi")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "holeDiags") (EApp (EVar "evIdModule") (EFieldAccess (EVar "c") "ecId"))) (EFieldAccess (EFieldAccess (EVar "c") "ecLoc") "value")) (EFieldAccess (EFieldAccess (EVar "c") "ecInner") "value")) (EVar "row")) (EVar "acc")))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "judgeCells") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "hi")) (EVar "acc"))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "judgeCells") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "hi")) (EVar "acc")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "judgeGoal" (TyFun (TyCon "String") (TyFun (TyCon "Obligation") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))))))
(DFunDef false "judgeGoal" ((PVar "mid") (PVar "o")) (EMatch (ETuple (EFieldAccess (EVar "o") "oPayload") (EApp (EVar "evValueOf") (EFieldAccess (EVar "o") "oDest"))) (arm (PTuple (PCon "GPDictApp" (PVar "app")) (PCon "EvMany" (PVar "rs"))) () (EApp (EApp (EApp (EApp (EVar "holeDiags") (EVar "mid")) (EFieldAccess (EVar "o") "oLoc")) (EFieldAccess (EFieldAccess (EVar "o") "oInner") "value")) (EApp (EApp (EApp (EVar "DictAppRow") (EFieldAccess (EVar "app") "pdaCallee")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "r")) (EFieldAccess (EVar "r") "irName"))) (EFieldAccess (EVar "app") "pdaIfaces"))) (EVar "rs")))) (arm (PTuple (PCon "GPRecDictApp" (PCon "RecDictApp" PWild (PVar "callee") PWild PWild PWild PWild)) (PCon "EvMany" (PVar "rs"))) () (EApp (EApp (EApp (EApp (EVar "holeDiags") (EVar "mid")) (EFieldAccess (EVar "o") "oLoc")) (EFieldAccess (EFieldAccess (EVar "o") "oInner") "value")) (EApp (EApp (EApp (EVar "DictAppRow") (EVar "callee")) (EListLit)) (EVar "rs")))) (arm (PTuple (PCon "GPArith" PWild) (PCon "EvOne" (PVar "r"))) () (EApp (EApp (EApp (EApp (EVar "holeDiags") (EVar "mid")) (EFieldAccess (EVar "o") "oLoc")) (EFieldAccess (EFieldAccess (EVar "o") "oInner") "value")) (EApp (EVar "SiteRow") (EVar "r")))) (arm (PTuple (PCon "GPSite" PWild PWild PWild) (PCon "EvOne" (PVar "r"))) () (EIf (EBinOp "||" (EBinOp "==" (EApp (EVar "goalKindTag") (EFieldAccess (EVar "o") "oKind")) (EApp (EVar "goalKindTag") (EVar "GKBinopSite"))) (EBinOp "==" (EApp (EVar "goalKindTag") (EFieldAccess (EVar "o") "oKind")) (EApp (EVar "goalKindTag") (EVar "GKUnopSite")))) (EApp (EApp (EApp (EApp (EVar "holeDiags") (EVar "mid")) (EFieldAccess (EVar "o") "oLoc")) (EFieldAccess (EFieldAccess (EVar "o") "oInner") "value")) (EApp (EVar "SiteRow") (EVar "r"))) (EListLit))) (arm PWild () (EListLit))))
(DTypeSig false "holeDiags" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Inner") (TyFun (TyCon "EvidenceRow") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))))))))
(DFunDef false "holeDiags" ((PVar "mid") (PVar "loc") (PVar "inner") (PVar "row")) (EMatch (EApp (EApp (EVar "rowHoleWith") (EVar "inner")) (EVar "row")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple PWild (PVar "msg"))) () (EListLit (ETuple (EVar "mid") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (EVar "TUnroutedDispatch")) (ELit (LInt 1))) (EVar "loc")) (EVar "msg")) (EVar "None")) (EVar "None")))))))
(DTypeSig false "materializeBinderTypes" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyCon "Unit"))))
(DFunDef false "materializeBinderTypes" ((PVar "gctx") PWild) (EBlock (DoLet false false (PVar "g") (EFieldAccess (EVar "gctx") "graphRun")) (DoExpr (EMatch (EFieldAccess (EFieldAccess (EVar "g") "binderPending") "value") (arm (PList) () (ELit LUnit)) (arm (PVar "pending") () (EBlock (DoLet false false (PVar "cells") (EApp (EVar "cellTypeHeads") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "declEnvsRef") "value") "deAllDecls"))) (DoLet false false (PVar "isCell") (ELam ((PVar "n") (PVar "o")) (EApp (EApp (EVar "omHasKey") (EApp (EApp (EVar "cellHeadKey") (EVar "n")) (EVar "o"))) (EVar "cells")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "binderRows")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "p")) (EApp (EApp (EVar "addBinderRow") (EApp (EApp (EVar "materializeBinder") (EVar "isCell")) (EVar "p"))) (EVar "acc")))) (EFieldAccess (EFieldAccess (EVar "g") "binderRows") "value")) (EApp (EVar "reverseL") (EVar "pending"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "binderPending")) (EListLit)))))))))
(DTypeSig false "materializeBinder" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyCon "Bool"))) (TyFun (TyCon "PendingBinder") (TyCon "BinderRow"))))
(DFunDef false "materializeBinder" ((PVar "isCell") (PCon "PendingBinder" (PVar "bid") (PVar "name") (PVar "t") (PVar "arity") (PVar "signed"))) (ERecordCreate "BinderRow" ((fa "brId" (EVar "bid")) (fa "brName" (EVar "name")) (fa "brType" (EApp (EApp (EVar "runtimeTypeOf") (EVar "isCell")) (EVar "t"))) (fa "brReturns" (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EApp (EApp (EVar "optionOr") (EVar "RTValue")) (EApp (EApp (EMethodRef "map") (EApp (EVar "runtimeTypeOf") (EVar "isCell"))) (EApp (EApp (EVar "resultAfterArrows") (EVar "n")) (EVar "t")))))) (EVar "arity"))) (fa "brSigned" (EVar "signed")))))
(DTypeSig false "cellTypeHeads" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))
(DFunDef false "cellTypeHeads" ((PVar "decls")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "d")) (EApp (EApp (EVar "addCellHead") (EVar "d")) (EVar "acc")))) (EVar "omEmpty")) (EVar "decls")))
(DTypeSig false "addCellHead" (TyFun (TyCon "Decl") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "addCellHead" ((PRec "DData" ((rf "dataName" (PVar "n")) (rf "dataOrigin" (PVar "o")) (rf "dataExtern" (PVar "ext"))) true) (PVar "acc")) (EIf (EVar "ext") (EVar "acc") (EApp (EApp (EApp (EVar "omInsert") (EApp (EApp (EVar "cellHeadKey") (EVar "n")) (EVar "o"))) (ELit LUnit)) (EVar "acc"))))
(DFunDef false "addCellHead" ((PRec "DNewtype" ((rf "newtypeName" (PVar "n")) (rf "newtypeOrigin" (PVar "o"))) true) (PVar "acc")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EApp (EVar "cellHeadKey") (EVar "n")) (EVar "o"))) (ELit LUnit)) (EVar "acc")))
(DFunDef false "addCellHead" ((PCon "DAttrib" PWild (PVar "d")) (PVar "acc")) (EApp (EApp (EVar "addCellHead") (EVar "d")) (EVar "acc")))
(DFunDef false "addCellHead" (PWild (PVar "acc")) (EVar "acc"))
(DTypeSig false "cellHeadKey" (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyCon "String"))))
(DFunDef false "cellHeadKey" ((PVar "n") (PCon "OriginBuiltin")) (EBinOp "++" (EBinOp "++" (ELit (LString "builtin|")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ""))))
(DFunDef false "cellHeadKey" ((PVar "n") (PCon "OriginUnresolved")) (EBinOp "++" (EBinOp "++" (ELit (LString "unresolved|")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ""))))
(DFunDef false "cellHeadKey" ((PVar "n") (PCon "OriginModule" (PVar "m"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "module ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "|"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ""))))
(DTypeSig false "runStampCtxs" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "StampCtx")) (TyApp (TyCon "List") (TyCon "DrainFinding")))))
(DFunDef false "runStampCtxs" ((PVar "saved") (PVar "ctxs")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "ctx")) (EBinOp "++" (EApp (EVar "reverseL") (EApp (EApp (EVar "runStampCtx") (EVar "saved")) (EVar "ctx"))) (EVar "acc")))) (EListLit)) (EVar "ctxs"))))
(DTypeSig false "runStampCtx" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "StampCtx") (TyApp (TyCon "List") (TyCon "DrainFinding")))))
(DFunDef false "runStampCtx" ((PVar "saved") (PVar "ctx")) (EBlock (DoLet false false (PVar "stamp") (EApp (EApp (EVar "enterStampCtx") (EVar "saved")) (EVar "ctx"))) (DoExpr (EApp (EApp (EVar "refileDeterminedRows") (EVar "stamp")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "runStampSteps") (EVar "stamp")) (EVar "ctx")) (EVar "moduleStampOrder"))) (DoExpr (EApp (EApp (EVar "recordEvidence") (EFieldAccess (EVar "saved") "mcGraph")) (EFieldAccess (EVar "ctx") "scGoals"))) (DoLet false false (PVar "liveSpans") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "ctx") "scLiveLocs")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "d")) (EApp (EApp (EApp (EVar "verdictFinding") (EFieldAccess (EVar "ctx") "scModule")) (EApp (EApp (EVar "isLiveSpan") (EVar "liveSpans")) (EApp (EVar "tcLoc") (EVar "d")))) (EVar "d")))) (EApp (EApp (EVar "captureTypeErrors") (EVar "stamp")) (ELam (PWild) (EApp (EApp (EVar "checkAdmittedOccObls") (EVar "stamp")) (ELit LUnit))))))))
(DTypeSig false "recordEvidence" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Obligation")) (TyCon "Unit"))))
(DFunDef false "recordEvidence" ((PVar "gctx") (PVar "gs")) (EBlock (DoLet false false (PVar "g") (EFieldAccess (EVar "gctx") "graphRun")) (DoExpr (EApp (EApp (EVar "each") (EApp (EVar "noteEvidenceObservation") (EVar "gctx"))) (EVar "gs"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "evTable")) (EBinOp "++" (EApp (EVar "evEntriesOf") (EVar "gs")) (EFieldAccess (EFieldAccess (EVar "g") "evTable") "value"))))))
(DTypeSig false "evEntriesOf" (TyFun (TyApp (TyCon "List") (TyCon "Obligation")) (TyCon "EvTable")))
(DFunDef false "evEntriesOf" ((PVar "gs")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "o")) (EApp (EApp (EVar "EvEntry") (EFieldAccess (EVar "o") "oEv")) (EApp (EVar "evValueOf") (EFieldAccess (EVar "o") "oDest"))))) (EVar "gs")))
(DTypeSig false "evValueOf" (TyFun (TyCon "EvDest") (TyCon "EvVal")))
(DFunDef false "evValueOf" ((PCon "EvRoute" (PVar "r"))) (EApp (EVar "EvOne") (EUnOp "!" (EVar "r"))))
(DFunDef false "evValueOf" ((PCon "EvRoutes" (PVar "rs"))) (EApp (EVar "EvMany") (EUnOp "!" (EVar "rs"))))
(DTypeSig false "beginModuleMarking" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "ModuleSeed") (TyCon "Unit")))))))
(DFunDef false "beginModuleMarking" ((PVar "mctx") (PVar "mid") (PVar "prog") (PVar "top") (PVar "seed")) (EBlock (DoLet false false (PVar "ms") (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "markSetsRef") "value") (arm (PCon "Some" (PVar "s")) () (EVar "s")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "checkBodyImpl: Module arm entered with no mark sets (no driver preamble ran)")))))) (DoLet false false (PVar "known") (EMatch (EVar "mid") (arm (PLit (LString "")) () (EApp (EVar "constrainedSigNames") (EVar "prog"))) (arm PWild () (EApp (EVar "dedup") (EBinOp "++" (EFieldAccess (EVar "ms") "msBareDictNames") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "promotionHarvestRef") "value")))))) (DoLet false false (PVar "aliases") (EApp (EApp (EApp (EApp (EVar "aliasDictNames") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "known")) (EFieldAccess (EVar "ms") "msUnits")) (EListLit (ETuple (EVar "mid") (EVar "prog"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "localAbs") "lasNext")) (ETuple (EVar "mid") (ELit (LInt 0))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "localAbs") "lasMinted")) (EListLit))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "markingRef")) (EApp (EVar "Some") (ERecordCreate "ModuleMarking" ((fa "mmCtx" (EApp (EApp (EApp (EApp (EApp (EVar "moduleMarkCtx") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ms")) (EVar "mid")) (EVar "prog")) (EFieldAccess (EVar "seed") "msImportedValues"))) (fa "mmTop" (EVar "top")) (fa "mmDictSet" (EApp (EVar "Ref") (EApp (EApp (EVar "omFromNames") (EBinOp "++" (EVar "known") (EVar "aliases"))) (EVar "omEmpty")))) (fa "mmUserNames" (EApp (EApp (EVar "omFromNames") (EApp (EVar "declTopFnNames") (EVar "prog"))) (EFieldAccess (EVar "seed") "msImportedNames"))) (fa "mmExterns" (EApp (EApp (EVar "omFromNames") (EApp (EVar "declExternNames") (EVar "prog"))) (EFieldAccess (EVar "seed") "msImportedExterns"))))))))))
(DTypeSig false "stampGroupClauses" (TyFun (TyCon "ModuleMarking") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))))
(DFunDef false "stampGroupClauses" ((PVar "mm") (PVar "members") (PVar "grouped")) (EApp (EApp (EApp (EVar "mapGroupClauses") (EApp (EVar "stampClauseWith") (EFieldAccess (EVar "mm") "mmTop"))) (EVar "members")) (EVar "grouped")))
(DTypeSig false "finishModuleMarking" (TyFun (TyCon "ModuleMarking") (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "finishModuleMarking" ((PVar "mm") (PVar "env") (PVar "grouped") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EVar "markTailDecls") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EVar "mm") "mmCtx")) (EFieldAccess (EFieldAccess (EVar "mm") "mmDictSet") "value")) (EApp (EVar "grantNameIn") (EVar "env"))) (EApp (EApp (EVar "rebuildGroupDecls") (EVar "grouped")) (EVar "prog"))))
(DTypeSig false "stampTailDecls" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "stampTailDecls" ((PVar "top") (PVar "decls")) (EApp (EApp (EMethodRef "map") (EApp (EVar "stampTailDecl") (EVar "top"))) (EVar "decls")))
(DTypeSig false "stampTailDecl" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "stampTailDecl" (PWild (PAs "d" (PCon "DFunDef" PWild PWild PWild PWild PWild PWild))) (EVar "d"))
(DFunDef false "stampTailDecl" (PWild (PAs "d" (PCon "DLetGroup" PWild PWild))) (EVar "d"))
(DFunDef false "stampTailDecl" ((PVar "top") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EVar "stampTailDecl") (EVar "top")) (EVar "d"))))
(DFunDef false "stampTailDecl" ((PVar "top") (PVar "d")) (EApp (EApp (EVar "stampDeclWith") (EVar "top")) (EVar "d")))
(DTypeSig false "methodReturnProbeStamp" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodSchemeRow") (TyFun (TyCon "MethodSchemeRow") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")))))))
(DFunDef false "methodReturnProbeStamp" ((PVar "prev") (PVar "ownedRow") (PVar "foreignRow") (PVar "impls")) (EBlock (DoLet false false (PVar "gctx") (EVariantUpdate "GraphCtx" (EFieldAccess (EVar "prev") "mcGraph") ((fa "graphRun" (EApp (EVar "freshGraphRun") (ELit LUnit)))))) (DoLet false false (PVar "mctx") (EApp (EApp (EVar "carryModuleCtx") (EVar "gctx")) (EVar "prev"))) (DoLet false false (PVar "scope") (EApp (EApp (EVar "methodReturnProbeScope") (EVar "mctx")) (ELit (LString "return-owner-stamper")))) (DoLet false false (PVar "request") (EApp (EApp (EVar "methodReturnProbeRequest") (EVar "mctx")) (EVar "ownedRow"))) (DoExpr (EApp (EApp (EVar "methodReturnProbeSpelling") (EVar "mctx")) (EVar "foreignRow"))) (DoLet false false (PVar "env") (EApp (EVar "buildFlatImplEnv") (EVar "impls"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "bodyImplEnvRef")) (EVar "env"))) (DoLet false false (PVar "tagRef") (EApp (EVar "Ref") (EVar "RNone"))) (DoLet false false (PVar "implRef") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "resultMono") (EApp (EVar "stripArrows") (EFieldAccess (EVar "request") "mrrOccurrence"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveExactReturnSite") (EApp (EVar "siteFor") (EVar "mctx"))) (EVar "omEmpty")) (ELit (LString "make"))) (EVar "tagRef")) (EVar "implRef")) (EVar "resultMono")) (EVar "request")) (ELit (LString ""))) (EVar "None")) (EVar "scope"))) (DoLet false false (PVar "goals") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "methodReturnArgs") (EVar "gctx")) (EVar "request")))) (DoLet false false (PVar "ownedKey") (EMatch (EApp (EApp (EApp (EApp (EVar "ieSelectRowByIface") (EApp (EVar "siteFor") (EVar "mctx"))) (EVar "env")) (EFieldAccess (EVar "ownedRow") "msrIface")) (EVar "goals")) (arm (PCon "Some" (PVar "selected")) () (EApp (EVar "rowRouteKey") (EVar "selected"))) (arm (PCon "None") () (ELit (LString ""))))) (DoLet false false (PVar "foreignKey") (EMatch (EApp (EApp (EApp (EApp (EVar "ieSelectRowByIface") (EApp (EVar "siteFor") (EVar "mctx"))) (EVar "env")) (EFieldAccess (EVar "foreignRow") "msrIface")) (EVar "goals")) (arm (PCon "Some" (PVar "selected")) () (EApp (EVar "rowRouteKey") (EVar "selected"))) (arm (PCon "None") () (ELit (LString ""))))) (DoExpr (ETuple (EApp (EVar "methodReturnProbeRouteKey") (EFieldAccess (EVar "tagRef") "value")) (EVar "ownedKey") (EVar "foreignKey")))))
(DTypeSig false "methodReturnOwnershipProbe" (TyFun (TyCon "Unit") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool") (TyCon "Bool"))))
(DFunDef false "methodReturnOwnershipProbe" (PWild) (EBlock (DoLet false false (PVar "ownedGraph") (EApp (EVar "probeGraphCtx") (ELit LUnit))) (DoLet false false (PVar "ownedDecl") (EApp (EApp (EApp (EVar "methodReturnProbeIface") (ELit (LString "return-owner"))) (ELit (LString "Owner"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Unit"))) (EVar "None"))) (EApp (EVar "TyVar") (ELit (LString "a")))))) (DoLet false false (PVar "foreignDecl") (EApp (EApp (EApp (EVar "methodReturnProbeIface") (ELit (LString "return-foreign"))) (ELit (LString "Foreign"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Unit"))) (EVar "None"))) (EApp (EVar "TyVar") (ELit (LString "a")))))) (DoLet false false (PVar "ownedCtx") (EApp (EVar "initialModuleCtx") (EVar "ownedGraph"))) (DoLet false false (PVar "ownedRow") (EApp (EVar "firstMethodRow") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "ownedCtx")) (EListLit (EVar "ownedDecl"))))) (DoLet false false (PVar "foreignGraph") (EVariantUpdate "GraphCtx" (EVar "ownedGraph") ((fa "graphRun" (EApp (EVar "freshGraphRun") (ELit LUnit)))))) (DoLet false false (PVar "foreignCtx") (EApp (EApp (EVar "carryModuleCtx") (EVar "foreignGraph")) (EVar "ownedCtx"))) (DoLet false false (PVar "foreignRow") (EApp (EVar "firstMethodRow") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "foreignCtx")) (EListLit (EVar "foreignDecl"))))) (DoLet false false (PVar "ownedImpl") (EApp (EApp (EVar "methodReturnProbeImpl") (ELit (LString "return-owner"))) (ELit (LString "Owner")))) (DoLet false false (PVar "foreignImpl") (EApp (EApp (EVar "methodReturnProbeImpl") (ELit (LString "return-foreign"))) (ELit (LString "Foreign")))) (DoLet false false (PTuple (PVar "rejected") (PVar "rejectedCtx")) (EApp (EApp (EApp (EVar "methodReturnProbeCodes") (EVar "foreignCtx")) (EVar "ownedRow")) (EListLit (EVar "foreignImpl")))) (DoLet false false (PTuple (PVar "accepted") (PVar "acceptedCtx")) (EApp (EApp (EApp (EVar "methodReturnProbeCodes") (EVar "rejectedCtx")) (EVar "ownedRow")) (EListLit (EVar "foreignImpl") (EVar "ownedImpl")))) (DoLet false false (PTuple (PVar "actualKey") (PVar "ownedKey") (PVar "foreignKey")) (EApp (EApp (EApp (EApp (EVar "methodReturnProbeStamp") (EVar "acceptedCtx")) (EVar "ownedRow")) (EVar "foreignRow")) (EListLit (EVar "foreignImpl") (EVar "ownedImpl")))) (DoLet false false (PVar "observed") (ETuple (EVar "rejected") (EVar "accepted") (EBinOp "==" (EVar "actualKey") (EVar "ownedKey")) (EBinOp "/=" (EVar "actualKey") (EVar "foreignKey")))) (DoExpr (EVar "observed"))))
