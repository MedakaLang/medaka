# META
source_lines=2490
stages=DESUGAR,MARK
# SOURCE
-- tc_solve: one solving judgment over one goal store, above the entailment core: the exact-return
-- and method-return solver (`solveExactReturn*`, the method-return predicate and its templates);
-- improvement and determination by the unique instance, with the module-end refiling of the
-- determined rows (`refileDeterminedRows`); instance selection for the judgments above entailment
-- (the three rows `rigidHeadInstanceContext`, `answeredOnlyByBindingHead`,
-- `residualSelectionStable`); the goal store, its dict-application reads (`dictAppsSince`) and the
-- solving walks' discharge memo (`pushGoal`, `walkGoalDischarged`, `walkGoalFollowed`); and the
-- evidence routes a solved goal answers with (the call-slot route family `routeOf`,
-- `routesOfMonosTop`, `routesOfMonosTopV`, `topRouteV`; the method-predicate, recursive-dictionary,
-- exact-return and numeric-return routes). Entailment and the route walk are `tc_solve_entail`;
-- predicate-slot, dict-arity and constraint registration and the residual walk at binders are
-- `tc_solve_check`.
--
-- Spec: DICT section 3, section 4.2, section 5; TYPECHECK-CONTRACTS section 3.
--
-- Placement: declarations are placed by R1-R6 of the Phase 4 module table,
-- compiler/ARCHITECTURE-PLAYBOOK.md section 6.
-- Closure rule: this module may not import `types.typecheck`, nor any of `tc_solve_check`,
-- `tc_shadow`, `tc_effects`, `tc_occurrence`, `tc_groups`, `tc_pat`, `tc_infer_records`,
-- `tc_infer`, `tc_elab`, `tc_global`, `tc_module`.

import types.tc_types.{
  Provenance(..),
  OblProjection(..),
  GoalReach(..),
  GoalPayload(..),
  GivenScope(..),
  GivenProvenance(..),
  GivenMatch(..),
  AdmittedAnswer(..),
  AssumAnswer(..),
  BuiltinClass(..),
  EvDest(..),
  GoalKind(..),
  GoalWindow(..),
  GraphMarks(..),
  MethodReturnMemoView(..),
  MethodReturnResolution(..),
  MethodReturnTraceEntry(..),
  MethodReturnTraceStage(..),
  MethodTemplateGivenResult(..),
  Obligation(..),
  PendingDictApp(..),
  PredicateRequest(..),
  PredicateSlot(..),
  PredicateSlotArgs(..),
  SiteCtx(..),
  SiteKind(..),
  SolvedGoalEntry(..),
  Undetermined(..),
  UObligation(..),
  DynCtx,
  dynFor,
  GivenEntry,
  GraphCtx,
  ImplEnv,
  ImplRow,
  LocalAbs,
  MethodPredicateSlot,
  MethodPredicateTemplate,
  MethodReturnRequest,
  MethodRow,
  MethodSchemeRow,
  MethodTrackedInstantiation,
  ModuleCtx,
  NumAnchorTestObservation,
  PendingEntry,
  PendingMethodDict,
  RecDictApp,
  ReqWalk,
  TraceSink,
}
import types.tc_mono.{
  allConcreteHeads,
  anyListM,
  cohApply,
  cohOverlap,
  cohOverlapGo,
  containsI,
  dedupI,
  exactReturnRequestOfGoal,
  findTvarInMono,
  headTyconMono,
  matchEqMono,
  matchOneSided,
  matchStep,
  matchTyMono,
  monoHeadIsDecl,
  monoMintedBefore,
  monoSameGiven,
  monoSizes,
  monoTyvarIds,
  monoUnboundIds,
  monoVarCells,
  monoVecSameGiven,
  monoVectorClosed,
  peelQual,
  rigidSigPairs,
  sigCellsOf,
  sigRigidBindings,
  stripArrows,
  stripTyConstraints,
  substMono,
  tconBuiltin,
  tyvarId,
  tyVarNames,
  walkMonosSame,
  unrigidSig,
}
import types.tc_state.{
  callUOblsWindow,
  currentScopeStore,
  initialModuleCtx,
  moduleWindow,
  probeGraphCtx,
}
import types.tc_env.{
  anyArgMentions,
  dispatchTyparams,
  ieHeadRows,
  ieRowIfaceMatches,
  ieRowOfIface,
  ieRowsAll,
  ieRowTys,
  instRefSeq,
  methodArgs,
  methodRowIface,
  methodRowTestIface,
  methodSlotKey,
  originMethodName,
  sameIfaceDecl,
}
import types.tc_diag.{erredDuring}
import types.tc_scope.{methodAdmittedHere, methodVisibleHere}
import types.tc_unify.{
  enterLevel,
  exitLevel,
  freshEffvar,
  freshTvMap,
  freshVar,
  instantiateMethodTracked,
  monoUnboundVarLevels,
  predicateSlotArgs,
  unify,
  unifyIn,
}
import types.tc_decls_types.{fromAstType, reqTyToMono}
import types.tc_solve_givens.{
  activeDictPredOf,
  activeDictVarOfEncl,
  anyGivenMatches,
  assumAnswerEvidence,
  assumAnswerRoute,
  enclSlot,
  firstPredForEncl,
  firstPredForEnclAt,
  firstPredForEnclResidual,
  givenInScope,
  givenRoute,
  givensForScope,
  goalMatchesGiven,
  noteAssumption,
  predicateRequestMatchesSlot,
  projectedGivenOf,
  pushGiven,
}
import types.tc_solve_entail.{
  determinedGoalInstance,
  directSuperGoals,
  enteredGoalKey,
  freshRowHeads,
  goalCandidates,
  goalHeadCon,
  goalIsProjection,
  goalRows,
  ieSelectRowByIface,
  paramMonoOf,
  positionBindings,
  repeatedBindings,
  reqWalkMemo,
  reqWalkStart,
  routeOfD,
  rowCountsFor,
  rowHeadMatches,
  rowRouteKey,
  selectedCallSupers,
  selectedRowReqMatch,
  stableGoalReach,
  superRoutesAt,
  findMatchingImplReqsU,
}
import types.solver_contract.{
  SolverFailure(..),
  ClassPredicate(..),
  GoalOrigin(..),
  Instantiation(..),
  InstantiationArgument(..),
  SolverBlocker(..),
  SolverOutcome(..),
  Wanted(..),
}
import frontend.ast.{
  TyConOrigin(..),
  Ns(..),
  Lit(..),
  Expr(..),
  Decl(..),
  EvEntry(..),
  EvId(..),
  EvVal(..),
  IfaceMethod(..),
  ImplMethod(..),
  Loc(..),
  Require(..),
  Route(..),
  Ty(..),
  EvTable,
  ifaceIdentity,
  mkIdent,
  tyConBuiltin,
}
import types.effect_rows.{EffRow(..), pureRow}
import types.evidence.{
  SolverEvidence(..),
  PrerequisiteEvidence(..),
  RequestInstanceId(..),
  ScopeId(..),
  SuperEvidence(..),
  goalIdForDestination,
}
import types.registry.{
  HeadKey(..),
  headKeyTag,
}
import types.repr.{
  IfaceRef(..),
  Mono(..),
  lookupAssocI,
  normalize,
  ppMono,
  tupleSpine,
}
import map.{Map(..)}
import support.ordmap.{
  omEmpty, omFromNames, omHasKey, omInsert, omLookup, OrdMap
}
import support.util.{
  allList,
  anyList,
  contains,
  dedup,
  endsWith,
  eqStr,
  filterList,
  isEmptyL,
  isNonEmptyL,
  isSome,
  listLen,
  lookupAssoc,
  orElseOpt,
  reverseL,
  splitOnChar,
}
import list.{drop, get, head, indexed, reverse, take, zip}
import string.{join}
import types.evidence_complete.{innerNone}
import types.scopes as Scopes
import map as IdMap
import types.scopes.{ScopeOwner(..)}

export
goalKindTag : GoalKind -> Int
goalKindTag GKReturnSite = 0
goalKindTag GKArgStamp = 1
goalKindTag GKRLocalSite = 2
goalKindTag GKBinopSite = 3
goalKindTag GKUnopSite = 4
goalKindTag GKArithSite = 5
goalKindTag GKDictApp = 6
goalKindTag GKMethodDict = 7
goalKindTag GKRecDictApp = 8

export
pushGoal : GraphCtx -> Obligation -> Unit
pushGoal gctx o =
  let g = gctx.graphRun
  g.goals := o :: g.goals.value
  g.goalsN := g.goalsN.value + 1

export
pushDictApp : GraphCtx -> PendingDictApp -> Unit
pushDictApp gctx app = pushGoal gctx Obligation {
  oKind = GKDictApp,
  oDest = EvRoutes app.pdaRoutesRef,
  oEv = app.pdaEv,
  oEncl = app.pdaEncl,
  oLoc = app.pdaLoc,
  oScope = app.pdaScope,
  oPayload = GPDictApp app,
  oInner = Ref innerNone,
}

-- the goals recorded since `mark` (a length of the channel: a module's start mark
-- from `GraphMarks`, or a `let`/SCC bracket's own), newest first
export
goalsSince : GraphCtx -> Int -> List Obligation
goalsSince gctx mark =
  moduleWindow gctx.graphRun.goalsN.value mark gctx.graphRun.goals.value

export
goalsOfKindIn : GoalKind -> List Obligation -> List Obligation
goalsOfKindIn k gs = filterList (o => goalKindTag o.oKind == goalKindTag k) gs

export
siteEntry : Obligation -> List PendingEntry
siteEntry o = match o.oPayload
  GPSite name m site =>
    [PendingEntry name (evCell o.oDest) m o.oEncl site o.oLoc o.oScope o.oEv]
  _ => []

evCell : EvDest -> Ref Route
evCell (EvRoute r) = r
evCell (EvRoutes _) = Ref RNone

export
arithEntry : Obligation -> List (Ref Route, Mono)
arithEntry o = match o.oPayload
  GPArith m => [(evCell o.oDest, m)]
  _ => []

export
dictAppsSince : GraphCtx -> Int -> List PendingDictApp
dictAppsSince gctx mark = dictAppsIn (goalsSince gctx mark)

dictAppsIn : List Obligation -> List PendingDictApp
dictAppsIn gs = flatMap dictAppEntry gs

export
dictAppEntry : Obligation -> List PendingDictApp
dictAppEntry o = match o.oPayload
  GPDictApp a => [a]
  _ => []

export
methodDictEntry : Obligation -> List PendingMethodDict
methodDictEntry o = match o.oPayload
  GPMethodDict d => [d]
  _ => []

export
recDictAppEntry : Obligation -> List RecDictApp
recDictAppEntry o = match o.oPayload
  GPRecDictApp r => [r]
  _ => []

-- a bracket's mark: the channel's length now (what `wMark` was for `dictApps`)
export
goalsMark : GraphCtx -> Unit -> Int
goalsMark gctx _ = gctx.graphRun.goalsN.value

-- drop the goals of `kinds` recorded since `mark`, keeping every other goal
-- (`inferPropBodies`' bracket: a prop body's operator sites must not be stamped)
export
dropGoalsSince : GraphCtx -> Int -> List GoalKind -> Unit
dropGoalsSince gctx mark kinds =
  let g = gctx.graphRun
  let now = g.goals.value
  let n = g.goalsN.value - mark
  let tags = map goalKindTag kinds
  let kept =
    filterList (o => not (containsI (goalKindTag o.oKind) tags)) (take n now)
  g.goals := kept ++ drop n now
  g.goalsN := mark + listLen kept

-- the MANGLED standalone symbol a route's RLocal fallback should call, or "" for
-- the bare-name (un-mangled) case.  Read off the marked EMethodAt route at record
-- time (before resolveArgStamps may overwrite the ref with an RKey) so the mangled
-- symbol survives into the pendingRLocalSites entry.
export
routeLocalSym : Route -> String
routeLocalSym (RLocal s _) = s
routeLocalSym _ = ""

methodReturnOrigin : ModuleCtx -> Option Loc -> GoalOrigin
methodReturnOrigin mctx loc =
  let moduleId = mctx.mcCells.currentModuleRef.value
  let binding =
    if mctx.mcCells.currentFn.value == "" then
      None
    else
      mkIdent NsValue (OriginModule moduleId) mctx.mcCells.currentFn.value
  GoalOrigin {
    location = loc,
    moduleId = moduleId,
    binding = binding,
  }

methodReturnInstantiation : ModuleCtx ->
  MethodReturnRequest ->
  Option Instantiation
methodReturnInstantiation mctx request = match (
  methodReturnPredicate mctx.mcGraph request,
  request.mrrGoalEv,
)
  (Some predicate, Some destination) => Some Instantiation {
    body = request.mrrQualifiedBody,
    force = pureRow,
    arguments = [
      InstantiationArgument {
        formal = Scopes.binderAt request.mrrScope 0,
        wanted = Wanted {
          id = goalIdForDestination destination,
          predicate = predicate,
          origin = methodReturnOrigin mctx request.mrrLoc,
          scope = request.mrrScope,
          destination = destination,
        },
      },
    ],
  }
  _ => None

methodReturnPredicate : GraphCtx -> MethodReturnRequest -> Option ClassPredicate
methodReturnPredicate gctx request =
  methodReturnPredicateFromTemplate
    gctx
    request.mrrPredicateTemplate
    request.mrrTyparams
    request.mrrOmitted
    request.mrrScope

-- A complete template is the goal.  An incomplete one is answered first by the
-- unique given matching its present positions; failing that, each absent position
-- is the occurrence's own [omitted] variable (DICT-SEMANTICS §5), for §3 to
-- determine or the boundary to reject.
methodReturnPredicateFromTemplate : GraphCtx ->
  MethodPredicateTemplate ->
  List String ->
  List (String, Mono) ->
  ScopeId ->
  Option ClassPredicate
methodReturnPredicateFromTemplate gctx template typarams omitted scope =
  match methodPredicateTemplateArgs template.mptArguments
    Some arguments => Some ClassPredicate {
      predicateInterface = template.mptInterface,
      predicateArguments = arguments,
    }
    None =>
      match (uniqueMethodTemplateGiven
        gctx
        template
        scope
        (givensForScope gctx scope))
        Some given => Some ClassPredicate {
          predicateInterface = template.mptInterface,
          predicateArguments = predicateSlotKnownArgs given.geSlot.psArgs,
        }
        None =>
          map
            (arguments => ClassPredicate {
              predicateInterface = template.mptInterface,
              predicateArguments = arguments,
            })
            (methodPredicateTemplateArgs
              (fillOmittedTemplateArgs typarams template.mptArguments omitted))

-- [arguments] with each absent position read from [omitted] by its typaram name.
fillOmittedTemplateArgs : List String ->
  List (Option Mono) ->
  List (String, Mono) ->
  List (Option Mono)
fillOmittedTemplateArgs (param :: params) (argument :: arguments) omitted =
  orElseOpt argument (lookupAssoc param omitted)
    :: fillOmittedTemplateArgs params arguments omitted
fillOmittedTemplateArgs _ arguments _ = arguments

export
methodReturnArgs : GraphCtx -> MethodReturnRequest -> Option (List Mono)
methodReturnArgs gctx request =
  map
    (predicate => predicate.predicateArguments)
    (methodReturnPredicate gctx request)

export
methodReturnWanted : ModuleCtx -> MethodReturnRequest -> Option Wanted
methodReturnWanted mctx request = match methodReturnInstantiation mctx request
  Some (Instantiation { arguments = [argument], ... }) => Some argument.wanted
  _ => None

-- an interface occurrence whose identity is not (yet) recoverable at the site.
--
-- `recordCallObligations` and `recordSchemeCallObligations` carry an `IfaceRef`
-- end to end (a `funPredicateSlotsRef` slot names its `IfaceRef`,
-- `schemeObligationsRef`'s payload is `List VecObl`), so neither mints a bare goal.
-- What is LEFT — grep this name for the live worklist, do not trust this list:
--   * `recordImplObligation`'s METHOD-OCCURRENCE goal, which is a decl-layer /
--     occurrence-layer reconciliation and not a table widening.  Owned by #1507, and
--     it is the LAST condition on deleting the bare compatibility leg;
--   * `ifaceForInferredId`'s third fallback, which recovers a slot's interface from
--     `pendingDictApps` — a SPELLING-keyed routing channel (see `resolveDictApps` /
--     `dispHeadTab`) whose iface component must stay a route word, so the recovery is
--     bare by construction rather than by omission.
export
ifaceRefBare : String -> IfaceRef
ifaceRefBare n = IfaceRef { irName = n, irOrigin = OriginUnresolved }

-- The ABSENT-interface sentinel: the empty name means "this slot has no recoverable
-- interface" (see `ifaceForInferredId`), and every reader tests it and skips.  It is
-- deliberately NOT spelled `ifaceRefBare ""`: that name is the residual worklist for a
-- goal whose identity is UNRECOVERABLE, and "no interface at all" is a different fact
-- that must not pollute the grep.
export
ifaceRefNone : IfaceRef
ifaceRefNone = IfaceRef { irName = "", irOrigin = OriginUnresolved }

-- THE ONLY legal reader of an obligation's dispatch vector — total over both
-- `OblProjection` arms.  See `OblProjection` for why the impl channel's projection
-- cannot be hoisted to record time.
export
uOblArgs : GraphCtx -> UObligation -> List Mono
uOblArgs gctx o = match o.oblProj
  OpProjected => o.pred.args
  OpMethodOcc typarams mty occ omitted =>
    occurrenceDispatchMonos typarams mty occ omitted
  OpExactReturn request => optionOr [] (methodReturnArgs gctx request)
  OpNumLit _ => o.pred.args

-- cons [x] onto the entry for [fn] (absent ⇒ a fresh single-element entry)
export
consSiteFn : String -> a -> OrdMap (List a) -> OrdMap (List a)
consSiteFn fn x idx = omInsert fn (x :: sitesFor fn idx) idx

-- the sites recorded for [fn], most-recent-first
export
sitesFor : String -> OrdMap (List a) -> List a
sitesFor fn idx = optionOr [] (omLookup fn idx)

sameTraceEvId : EvId -> EvId -> Bool
sameTraceEvId (EvId moduleA ordinalA) (EvId moduleB ordinalB) =
  moduleA == moduleB && ordinalA == ordinalB

export
noteMethodReturnTrace : ModuleCtx ->
  MethodReturnTraceStage ->
  MethodReturnRequest ->
  Option Route ->
  List Route ->
  Unit
noteMethodReturnTrace mctx stage request route prerequisites =
  match mctx.mcGraph.trace
    Some sink =>
      if sink.tsMethodReturnEnabled then
        let (qualifiedBody, wanted) =
          match methodReturnInstantiation mctx request
            Some (Instantiation { body = body, arguments = [InstantiationArgument { wanted = carried, ... }], ... }) =>
              (Some body, Some carried)
            _ => (None, None)
        sink.tsMethodReturnEntries :=
          MethodReturnTraceEntry {
              mrtStage = stage,
              mrtInterface = request.mrrIface,
              mrtMethod = request.mrrName,
              mrtArguments = methodReturnArgs mctx.mcGraph request,
              mrtScope = request.mrrScope,
              mrtOrigin = request.mrrLoc,
              mrtGoal = request.mrrGoalEv,
              mrtPublished = None,
              mrtQualifiedBody = qualifiedBody,
              mrtWanted = wanted,
              mrtOutcome =
                map
                  (resolution => resolution.mrrOutcome)
                  request.mrrResolution.value,
              mrtRoute = route,
              mrtPrerequisites = prerequisites,
            }
            :: sink.tsMethodReturnEntries.value
    None => ()

export
goalKindName : GoalKind -> String
goalKindName GKReturnSite = "GKReturnSite"
goalKindName GKArgStamp = "GKArgStamp"
goalKindName GKRLocalSite = "GKRLocalSite"
goalKindName GKBinopSite = "GKBinopSite"
goalKindName GKUnopSite = "GKUnopSite"
goalKindName GKArithSite = "GKArithSite"
goalKindName GKDictApp = "GKDictApp"
goalKindName GKMethodDict = "GKMethodDict"
goalKindName GKRecDictApp = "GKRecDictApp"

export
openScope : ModuleCtx -> ScopeId -> Unit
openScope mctx sid = mctx.mcCells.currentScope := Scopes.openScopeCursor sid

-- The marks of the module being processed (the head of `moduleRanges`); all zeros
-- before any module started, which is the whole graph.
export
currentModuleMarks : GraphCtx -> Unit -> GraphMarks
currentModuleMarks gctx _ = match gctx.graphRun.moduleRanges.value
  (_, m) :: _ => m
  [] => GraphMarks { mGoals = 0, mNumlit = 0 }

-- Has the obligation walk [walk] already checked goal [iface] [args], entered with
-- the fuel [walk] has left, without an error?
export
walkGoalDischarged : ReqWalk -> IfaceRef -> List Mono -> Bool
walkGoalDischarged walk iface args =
  let memo = reqWalkMemo walk
  anyListM
    ((otherIface, otherArgs) =>
      sameIfaceDecl otherIface iface && monoVecSameGiven otherArgs args)
    (optionOr [] (omLookup (enteredGoalKey walk) memo.wmDischarged.value))

export
noteWalkGoalDischarged : ReqWalk -> IfaceRef -> List Mono -> Unit
noteWalkGoalDischarged walk iface args =
  let memo = reqWalkMemo walk
  let key = enteredGoalKey walk
  memo.wmDischarged :=
    omInsert
      key
      ((iface, args) :: optionOr [] (omLookup key memo.wmDischarged.value))
      memo.wmDischarged.value

-- The residuals [solve] finds below the goal [iface] [args], which [walk] has just
-- entered: the recorded ones if this walk already solved that goal, otherwise
-- [solve]'s, deduplicated and recorded when they came out clean.  Deduplicating
-- keeps the first occurrence of each goal, so a goal the walk reaches along many
-- paths is one residual and the result stays as large as the distinct goals.
export
solvedOnWalk : ModuleCtx ->
  ReqWalk ->
  IfaceRef ->
  List Mono ->
  (Unit -> List (IfaceRef, List Mono)) ->
  List (IfaceRef, List Mono)
solvedOnWalk mctx walk iface args solve =
  let memo = reqWalkMemo walk
  let key = enteredGoalKey walk
  let entries = optionOr [] (omLookup key memo.wmSolved.value)
  match filterList (e => walkGoalSame e.sgeIface e.sgeGoals iface args) entries
    entry :: _ => entry.sgeResiduals
    [] =>
      let (clean, found) = solvedCleanly mctx (goals => flatMap snd goals) solve
      let residuals = dedupWalkGoals found
      if clean then
        let entry = SolvedGoalEntry {
          sgeIface = iface,
          sgeGoals = args,
          sgeResiduals = residuals,
        }
        memo.wmSolved :=
          omInsert
            key
            (entry :: optionOr [] (omLookup key memo.wmSolved.value))
            memo.wmSolved.value
      residuals

-- Runs [act] and says whether its result can stand for running it again: it
-- detected no error (`erredDuring`), and no type or effect variable it minted is in
-- the types [monosOf] reads off the result.  A second run would mint fresh ones in
-- their place.  Variables minted only to test a unification do not reach the result.
export
solvedCleanly : ModuleCtx -> (a -> List Mono) -> (Unit -> a) -> (Bool, a)
solvedCleanly mctx monosOf act =
  let tyvars = mctx.mcGraph.graphRun.tyvarCounter.value
  let effvars = mctx.mcGraph.graphRun.effvarCounter.value
  let (erred, result) = erredDuring mctx act
  (
    not erred && allList (monoMintedBefore tyvars effvars) (monosOf result),
    result,
  )

-- [goals] with each goal kept at its first occurrence (`walkGoalSame`).
dedupWalkGoals : List (IfaceRef, List Mono) -> List (IfaceRef, List Mono)
dedupWalkGoals goals = dedupWalkGoalsGo goals omEmpty []

dedupWalkGoalsGo : List (IfaceRef, List Mono) ->
  OrdMap (List (IfaceRef, List Mono)) ->
  List (IfaceRef, List Mono) ->
  List (IfaceRef, List Mono)
dedupWalkGoalsGo [] _ acc = reverse acc
dedupWalkGoalsGo ((iface, args) :: rest) seen acc =
  let key = "\{iface.irName}#\{intToString (monoSizes args)}"
  let bucket = optionOr [] (omLookup key seen)
  if anyListM (g => walkGoalSame (fst g) (snd g) iface args) bucket then
    dedupWalkGoalsGo rest seen acc
  else
    dedupWalkGoalsGo
      rest
      (omInsert key ((iface, args) :: bucket) seen)
      ((iface, args) :: acc)

-- Has the prerequisite walk [walk] already followed the goal [iface] [args] it has
-- just entered?
export
walkGoalFollowed : ReqWalk -> IfaceRef -> List Mono -> Bool
walkGoalFollowed walk iface args =
  let memo = reqWalkMemo walk
  anyListM
    ((otherIface, otherArgs) => walkGoalSame otherIface otherArgs iface args)
    (optionOr [] (omLookup (enteredGoalKey walk) memo.wmFollowed.value))

export
noteWalkGoalFollowed : ReqWalk -> IfaceRef -> List Mono -> Unit
noteWalkGoalFollowed walk iface args =
  let memo = reqWalkMemo walk
  let key = enteredGoalKey walk
  memo.wmFollowed :=
    omInsert
      key
      ((iface, args) :: optionOr [] (omLookup key memo.wmFollowed.value))
      memo.wmFollowed.value

-- Two goals are one entry of a solving walk's memo when they are one predicate
-- (`monoVecSameGiven`) with the same effect rows and authorities as well.  A recorded
-- residual is built from its goal's own types, and `monoSameGiven` equates every row,
-- so a goal that differs only in a row must not be answered by another's entry.
walkGoalSame : IfaceRef -> List Mono -> IfaceRef -> List Mono -> Bool
walkGoalSame iface args otherIface otherArgs =
  sameIfaceDecl iface otherIface && walkMonosSame args otherArgs

export
isLocalAbsName : String -> Bool
isLocalAbsName n = endsWith "$lb" n

-- The name a candidate local was written with (`f` for `f$m$3$lb`); `$` never occurs in
-- a source identifier.
export
localSourceName : String -> String
localSourceName name
  | isLocalAbsName name = match splitOnChar '$' name
    first :: _ => first
    [] => name
  | otherwise = name

-- One dictionary application of a local: each slot's predicate at the occurrence's
-- instantiation [subst] (empty for a recursive use, whose predicate is the binder's
-- own), solved in the occurrence's scope.
export
pushLocalDictApp : ModuleCtx ->
  String ->
  EvId ->
  LocalAbs ->
  List (Int, Mono) ->
  ScopeId ->
  Unit
pushLocalDictApp mctx name ev la subst useScope =
  let monos = map (localSlotLead mctx subst) la.laSlots
  pushDictApp mctx.mcGraph PendingDictApp {
    pdaRoutesRef = Ref [],
    pdaEv = ev,
    pdaMonos = monos,
    pdaIfaces = map (s => s.psIface) la.laSlots,
    pdaArgVecs = map (localSlotArgs mctx subst) la.laSlots,
    pdaEncl = mctx.mcCells.currentFn.value,
    pdaLoc = mctx.mcLoc,
    pdaScope = useScope,
    pdaCallee = localSourceName name,
  }
  mctx.mcCells.dictAppFns :=
    consSiteFn mctx.mcCells.currentFn.value monos mctx.mcCells.dictAppFns.value

localSlotArgs : ModuleCtx -> List (Int, Mono) -> PredicateSlot -> List Mono
localSlotArgs mctx subst slot = match slot.psArgs
  PSArgsKnown args => map (substMono mctx.mcGraph subst [] []) args
  PSArgsUnknown => [localSlotLead mctx subst slot]

localSlotLead : ModuleCtx -> List (Int, Mono) -> PredicateSlot -> Mono
localSlotLead mctx subst slot = match slot.psArgs
  PSArgsKnown (a :: _) => substMono mctx.mcGraph subst [] [] a
  _ => match slot.psBoundIds
    id :: _ => optionOrElse (_ => freshVar mctx ()) (lookupAssocI id subst)
    [] => freshVar mctx ()

-- #1539 / DICT §8 I7 qualification 4: THE GATE.  True iff the declaration list this
-- pass treats as the PRELUDE declares this built-in class (with ≥1 method — see
-- `builtinClassesGo`).  This is the question I7 qualification 4 requires before a
-- synthetic operator/literal predicate may be synthesized at all; `ifaceRegistered`,
-- which the three gate sites asked until #1539, answers the *different* question "is
-- SOME interface spelled `Num` registered anywhere in this program", over a table any
-- user declaration writes to.
--
-- It is a record projection, so it is strictly CHEAPER than the `omHasKey` it
-- replaces — `ifaceRegistered`'s own doc-comment records that it is on the
-- per-operator / per-numeric-literal hot path (#147), and this change moves it from
-- O(log n) to O(1) rather than the other way.
export
builtinClassPresent : GraphCtx -> BuiltinClass -> Bool
builtinClassPresent gctx BNum =
  gctx.crossRun.builtinClassesRef.value.bcNumPresent
builtinClassPresent gctx BEq = gctx.crossRun.builtinClassesRef.value.bcEqPresent
builtinClassPresent gctx BOrd =
  gctx.crossRun.builtinClassesRef.value.bcOrdPresent
builtinClassPresent gctx BSemigroup =
  gctx.crossRun.builtinClassesRef.value.bcSemigroupPresent

-- S2-DECL (d) at the occurrence of [name] whose instantiated method type is [mono]:
-- each admitted declaration asked through its own parameter vector, read off its own
-- declared method type, and its own interface's instances (the (b) pairing).
export
admittedSelection : SiteCtx -> ImplEnv -> String -> Mono -> AdmittedAnswer
admittedSelection sx env name mono =
  let visible = methodVisibleHere sx.sxModule name
  let answers =
    map
      (admittedDeclAnswer sx env visible mono)
      (methodAdmittedHere sx.sxModule name)
  if anyList isUndecided answers then
    Undecided
  else match filterList isSelection answers
    [] => SelectsNothing
    [one] => routableSelection sx.sxModule name one
    _ => Undecided

-- A selected declaration with its own method-level constraints is unroutable: an
-- admitted-set occurrence records no method dictionaries (`recordMethodDicts` reads
-- the one declaration `methodIfaceHere` names, and an admitted spelling names none),
-- so committing to it would leave those constraints unrouted for every engine.
routableSelection : ModuleCtx -> String -> AdmittedAnswer -> AdmittedAnswer
routableSelection mctx name (answer@(Selects iface _ _)) =
  let key = methodSlotKey iface (originMethodName mctx name)
  match lookupAssoc key mctx.mcCells.methodPredicateSlotsRef.value
    Some (_ :: _) => Unroutable iface
    _ => answer
routableSelection mctx _ answer = answer

admittedDeclAnswer : SiteCtx ->
  ImplEnv ->
  List MethodRow ->
  Mono ->
  IfaceRef ->
  AdmittedAnswer
admittedDeclAnswer sx env visible mono ir =
  match filterList (r => ieRowIfaceMatches (methodRowIface r) ir) visible
    r :: _ => match r.mrEntry
      (iface, typarams, mty, _) => match matchTyMono mty mono
        Some subst =>
          let goals = map (paramMonoOf subst) typarams
          match goalHeadCon goals
            None => Undecided
            Some _ => match ieSelectRowByIface sx env iface goals
              Some row => Selects iface row goals
              None => SelectsNothing
        None => Undecided
    [] => Undecided

isUndecided : AdmittedAnswer -> Bool
isUndecided Undecided = True
isUndecided _ = False

isSelection : AdmittedAnswer -> Bool
isSelection (Selects _ _ _) = True
isSelection _ = False

-- [base] plus each variable of [args] whose level is below [level].
export
outerRigidIds : Option Int -> List Mono -> OrdMap Unit -> OrdMap Unit
outerRigidIds outerBelow args base =
  omFromNames (map intToString (enclosingVarIds outerBelow args)) base

-- The variables of [args] an enclosing binder owns: those below [outerBelow].
-- A boundary with no enclosing binder (`None`) has none.
export
enclosingVarIds : Option Int -> List Mono -> List Int
enclosingVarIds None _ = []
enclosingVarIds (Some level) args =
  map fst (filterList (p => snd p < level) (flatMap monoUnboundVarLevels args))

-- A local boundary's goals are improved before it generalizes, as a top-level
-- group's are (DICT-SEMANTICS §3 "When"), so its scheme is built from the improved
-- type.  A variable below the just-exited level is an enclosing binder's to settle,
-- so it takes part as a constant.
export
improveLocalGoals : DynCtx -> List UObligation -> Int -> Unit
improveLocalGoals dyn addedObls callN0 =
  let goals = addedObls ++ callUOblsWindow dyn.dcModule callN0
  let outer =
    outerRigidIds
      (Some (dyn.dcModule.mcCells.currentLevel.value + 1))
      (flatMap (uOblArgs dyn.dcModule.mcGraph) goals)
      omEmpty
  improveByUniqueImpl dyn outer goals

-- methods whose interface type param appears ONLY in the result (no argument
-- mentions it) — pure/empty/minBound/maxBound/fromInt/… — are return-position
export
returnPosMethodNames : List Decl -> List String
returnPosMethodNames prog = flatMap returnPosOfDecl prog

returnPosOfDecl : Decl -> List String
returnPosOfDecl (DInterface { typarams, methods, ... }) =
  flatMap (returnPosMethod typarams) methods
returnPosOfDecl _ = []

returnPosMethod : List String -> IfaceMethod -> List String
returnPosMethod typarams (IfaceMethod mname mty _ _)
  | not (anyArgMentions (dispatchTyparams typarams) (methodArgs mty)) = [mname]
  | otherwise = []

export
exactReturnRoutes : SiteCtx ->
  String ->
  String ->
  ScopeId ->
  Bool ->
  MethodReturnResolution ->
  (Route, List Route)
exactReturnRoutes sx name encl scope isReturnPosition resolution = match (
  resolution.mrrOutcome,
  resolution.mrrSelectedRow,
)
  (Solved (GivenEvidence binder), None) => (
    givenRoute sx.sxModule.mcGraph isReturnPosition binder,
    [],
  )
  (Solved (SuperclassEvidence parent path), None) => (
    RProj (givenRoute sx.sxModule.mcGraph isReturnPosition parent) path,
    [],
  )
  (Solved (InstanceEvidence _ args prerequisites _), Some row) => (
    RKey
      (rowRouteKey row)
      []
      (selectedCallSupers sx name (Some row) encl scope args),
    methodReturnEvidenceRoutes sx encl scope prerequisites,
  )
  -- No instance was selected: the site keeps no route, never the occurrence's head
  -- tag, which names no instance.
  (Deferred _ _, None) => (RNone, [])
  (Insoluble _ _, None) => (RNone, [])
  _ => panic "ordinary return outcome and selected row disagree"

methodReturnEvidenceRoutes : SiteCtx ->
  String ->
  ScopeId ->
  List PrerequisiteEvidence ->
  List Route
methodReturnEvidenceRoutes sx encl scope prerequisites =
  map (methodReturnEvidenceRoute sx encl scope) prerequisites

methodReturnEvidenceRoute : SiteCtx ->
  String ->
  ScopeId ->
  PrerequisiteEvidence ->
  Route
methodReturnEvidenceRoute sx encl scope prerequisite =
  match prerequisite.prerequisiteArguments
    first :: more =>
      routeOfD
        sx
        prerequisite.prerequisiteInterface
        encl
        scope
        KeepNone
        first
        more
        (reqWalkStart ())
    [] => RNone

export
numericReturnRoute : Route -> List Route -> Route
numericReturnRoute (RKey key _ sups) routes = RKey key routes sups
numericReturnRoute route _ = route

export
predicateSlotKnownArgs : PredicateSlotArgs -> List Mono
predicateSlotKnownArgs PSArgsUnknown = []
predicateSlotKnownArgs (PSArgsKnown args) = args

methodPredicateTemplateArgs : List (Option Mono) -> Option (List Mono)
methodPredicateTemplateArgs [] = Some []
methodPredicateTemplateArgs ((Some argument) :: rest) =
  map (argument :: _) (methodPredicateTemplateArgs rest)
methodPredicateTemplateArgs (None :: _) = None

uniqueMethodTemplateGiven : GraphCtx ->
  MethodPredicateTemplate ->
  ScopeId ->
  List GivenEntry ->
  Option GivenEntry
uniqueMethodTemplateGiven gctx template useScope givens =
  let chain = Scopes.visibleChain (currentScopeStore gctx ()) useScope
  match methodTemplateGivenScan template chain givens MethodTemplateGivenNone
    MethodTemplateGivenOne given => Some given
    _ => None

methodTemplateGivenScan : MethodPredicateTemplate ->
  List Int ->
  List GivenEntry ->
  MethodTemplateGivenResult ->
  MethodTemplateGivenResult
methodTemplateGivenScan _ _ [] result = result
methodTemplateGivenScan template chain (given :: rest) result =
  let result2 =
    if givenInScope GSPredicateOnly given
      && Scopes.visibleOnChain chain (Scopes.binderScope given.geBinder)
      && methodPredicateTemplateMatchesSlot
        template
        given.geSlot then match result
      MethodTemplateGivenNone => MethodTemplateGivenOne given
      _ => MethodTemplateGivenMany
    else
      result
  match result2
    MethodTemplateGivenMany => MethodTemplateGivenMany
    _ => methodTemplateGivenScan template chain rest result2

methodPredicateTemplateMatchesSlot : MethodPredicateTemplate ->
  PredicateSlot ->
  Bool
methodPredicateTemplateMatchesSlot template slot =
  sameIfaceDecl template.mptInterface slot.psIface
    && (match slot.psArgs
      PSArgsUnknown => False
      PSArgsKnown arguments =>
        methodPredicateTemplateArgumentsMatch template.mptArguments arguments)

methodPredicateTemplateArgumentsMatch : List (Option Mono) -> List Mono -> Bool
methodPredicateTemplateArgumentsMatch [] [] = True
methodPredicateTemplateArgumentsMatch ((Some expected) :: rest) (actual :: arguments) =
  monoSameGiven expected actual
    && methodPredicateTemplateArgumentsMatch rest arguments
methodPredicateTemplateArgumentsMatch (None :: rest) (_ :: arguments) =
  methodPredicateTemplateArgumentsMatch rest arguments
methodPredicateTemplateArgumentsMatch _ _ = False

-- The context of the instance [iface] [args] selects with the head variables
-- [headIds] held rigid (`sigRigidBindings`), as goals over those variables again.
export
rigidHeadInstanceContext : SiteCtx ->
  OrdMap Unit ->
  IfaceRef ->
  List Mono ->
  Option (List (IfaceRef, List Mono))
rigidHeadInstanceContext sx headIds iface args =
  let cells = sigCellsOf headIds (flatMap monoVarCells args)
  let toRigid = sigRigidBindings headIds cells
  map
    (m =>
      map
        (r => match reqToObligation sx.sxModule (fst m) r
          (ri, rargs) => (ri, map (unrigidSig cells) rargs))
        (snd m))
    (findMatchingImplReqsU
      sx
      sx.sxModule.mcCells.residualUnivRef.value
      iface
      (map (substMono sx.sxModule.mcGraph toRigid [] []) args))

-- ONE constrained-call-arg route resolver — collapses routeOfMono (encl="",
-- KeepNone) / routeOfMonoEncl (KeepNone) / routeOfMonoTop (encl="", CountImpls).
-- Only a non-empty [encl] can supply an active dict, and only from that owner's
-- constraint-var slots.  [policy] decides the undetermined arm (see Undetermined).
routeOf : SiteCtx ->
  IfaceRef ->
  String ->
  ScopeId ->
  Undetermined ->
  Mono ->
  Route
routeOf sx iface encl useScope policy m =
  routeOfD sx iface encl useScope policy m [] (reqWalkStart ())

-- TOP-LEVEL constraint routes (a constrained-fn CALL site, e.g. `roundtrip 10`).
-- Like routesOfMonos but passes the CountImpls policy to routeOf, so the UNDETERMINED
-- case resolves via routeUndeterminedTop instead of the nested-recursion RNone (which
-- yields an empty dict → runtime `intToString: not an Int` / a null build dict): the
-- instances the slot's goal can still reach decide it:
--   • one, or a stable minimum → stamp that instance's RKey (deterministic
--                    dispatch on both run and build);
--   • two or more otherwise → genuinely ambiguous → `T-AMBIGUOUS-INSTANCE`, unless a
--                    scheme quantifies the goal (no route; the boundary verdict reports it);
--   • none         → keep RNone (existing no-impl behaviour/error).
-- #1161 (F-3a-ii): the vector-aware form.  Slot COUNT, slot ORDER and the number of
-- Routes produced are IDENTICAL to routesOfMonosTop's — the ONLY difference is the
-- GOAL each slot is selected with.  That is what keeps the change arity-neutral:
-- dictArityOf, dictPass, scopePredicateSlots, and the cross-module snapshot all read
-- the same predicate carrier, whose slot count this leaves untouched.
--
-- The invariant (#1909).  There is no length gate; `vectorGoal` declines only an EMPTY
-- vector or an unknown interface.  Byte-identity with routesOfMonosTop is now a property
-- of the VECTOR'S CONTENT, not of its length:
--   • vector `[m]` where the recorded argument IS the slot's own mono (every bare-tyvar
--     `=>` constraint — which is still every `=>` constraint in compiler + stdlib +
--     sqlite): `routeOfD … g0 [] 0 0` with `g0 == m` is `routeOf … m` term for term, so
--     those callers are byte-identical BY CONSTRUCTION exactly as before;
--   • vector `[Wrap a]` against slot mono `a` (a structured single-subject predicate):
--     routes on `Wrap a`, which is the whole point — see `vectorGoal`;
--   • no vector at all: the `[]` arm below, still the untouched scalar router.
-- Slot COUNT, slot ORDER and the number of Routes produced are unchanged either way,
-- which is what still keeps this arity-neutral.  The self-compile fixpoint proves
-- absence-of-regression, never correctness of the new path — as before.
export
routesOfMonosTopV : SiteCtx ->
  String ->
  ScopeId ->
  List Mono ->
  List IfaceRef ->
  List (List Mono) ->
  List Route
-- no vectors at all (a caller with nothing to offer) ⇒ the scalar router, unchanged.
routesOfMonosTopV sx encl useScope monos ifaces [] =
  routesOfMonosTop sx encl useScope monos ifaces
routesOfMonosTopV sx _ _ [] _ _ = []
routesOfMonosTopV sx encl useScope (m :: rest) [] (_ :: vs) =
  routeOf sx ifaceRefNone encl useScope (CountImpls ifaceRefNone) m
    :: routesOfMonosTopV sx encl useScope rest [] vs
routesOfMonosTopV sx encl useScope (m :: rest) (iface :: ifacesRest) (v :: vs) =
  topRouteV sx encl useScope iface m v
    :: routesOfMonosTopV sx encl useScope rest ifacesRest vs

-- one slot.  A multi-argument predicate hands `routeOfD` the goal TAIL (arg 0 stays in
-- `routeOfD`'s own `m`, exactly as EKNestedTop documents), so the selector sees
-- `Ix Int Char` instead of the shattered `Ix Int _` and `ieEntriesForIface`
-- returns a singleton.
-- The vector's arg 0 — NOT this slot's own mono — is the predicate head.  The two
-- differ whenever a predicate shatters into more than one slot (`Ix a b` gives the `b`
-- slot the mono of `b`, while the predicate's arg 0 is `a`'s): both slots are evidence
-- for the SAME predicate, so both must select on the same goal.  That is what
-- `vectorGoal` returning the head separately encodes; the scalar arm keeps [m].
topRouteV : SiteCtx ->
  String ->
  ScopeId ->
  IfaceRef ->
  Mono ->
  List Mono ->
  Route
topRouteV sx encl useScope iface m goals = match vectorGoal iface goals
  Some (g0, gs) =>
    routeOfD sx iface encl useScope (CountImpls iface) g0 gs (reqWalkStart ())
  None => routeOf sx iface encl useScope (CountImpls iface) m

-- `Some (arg0, tail)` exactly when the widening applies: a NON-EMPTY argument vector
-- under a KNOWN interface.  Everything else is None ⇒ the scalar route.
-- #1909: the length-1 declining clause (`vectorGoal _ [_] = None`) is GONE.  It made a
-- 1-ary predicate select on the SLOT's mono instead of on the vector's own argument —
-- byte-identical while the two coincide (`Shw a => …` records `[a]`, so arg 0 IS the
-- slot mono) and WRONG the moment they do not (`Tag (Wrap a) => …` records `[Wrap a]`
-- against slot mono `a`, so the call site keyed its dict on `Bool` where the predicate
-- is `Tag (Wrap Bool)`).  Arity is not what makes a vector meaningful; a recorded
-- argument that differs from the slot's own mono is.
-- `iface == ""` is pinned scalar deliberately: with no interface there is no arity
-- to give a vector meaning (#1168).  Dropping the length-1
-- clause does not touch that pin: it only widens WHICH non-empty vectors get past it.
vectorGoal : IfaceRef -> List Mono -> Option (Mono, List Mono)
vectorGoal _ [] = None
vectorGoal iface (g0 :: gs) = if iface.irName == "" then None else Some (g0, gs)

routesOfMonosTop : SiteCtx ->
  String ->
  ScopeId ->
  List Mono ->
  List IfaceRef ->
  List Route
routesOfMonosTop sx _ _ [] _ = []
routesOfMonosTop sx encl useScope (m :: rest) [] =
  routeOf sx ifaceRefNone encl useScope (CountImpls ifaceRefNone) m
    :: routesOfMonosTop sx encl useScope rest []
routesOfMonosTop sx encl useScope (m :: rest) (iface :: ifacesRest) =
  routeOf sx iface encl useScope (CountImpls iface) m
    :: routesOfMonosTop sx encl useScope rest ifacesRest

export
methodPredicateRoutes : SiteCtx ->
  String ->
  ScopeId ->
  List PredicateSlot ->
  List Route
methodPredicateRoutes sx encl scope slots =
  map (methodPredicateRoute sx encl scope) slots

methodPredicateRoute : SiteCtx -> String -> ScopeId -> PredicateSlot -> Route
methodPredicateRoute sx encl scope slot = match slot.psArgs
  PSArgsKnown (g0 :: gs) =>
    routeOfD sx slot.psIface encl scope KeepNone g0 gs (reqWalkStart ())
  _ => RNone

-- ── recursive dict-app realization (self/mutual recursion) ──────────────────
export
recRoutes : SiteCtx ->
  String ->
  ScopeId ->
  Mono ->
  List PredicateSlot ->
  List Route
recRoutes sx encl scope mono slots = map (recRoute sx encl scope mono) slots

-- For one of the callee's constraint ids, recover the live occurrence type from
-- [mono] (the var the body unified it to).  Concrete head → RKey; still a
-- constraint variable that is one of [encl]'s own → forward [encl]'s dict param
-- (RDict, the slot it sits at); otherwise leave the route unresolved.
recRoute : SiteCtx -> String -> ScopeId -> Mono -> PredicateSlot -> Route
recRoute sx encl scope mono slot =
  match recPredicateArgs sx.sxModule.mcGraph mono slot
    Some (g0 :: gs) =>
      routeOfD sx slot.psIface encl scope KeepNone g0 gs (reqWalkStart ())
    _ => match slot.psBoundIds
      id :: _ => match findTvarInMono mono id
        None => RNone
        Some m => resolveRecMono sx encl scope slot.psIface m
      [] => RNone

recPredicateArgs : GraphCtx -> Mono -> PredicateSlot -> Option (List Mono)
recPredicateArgs gctx mono slot = match slot.psArgs
  PSArgsUnknown => None
  PSArgsKnown args =>
    map
      (subst => map (substMono gctx subst [] []) args)
      (recSlotSubst mono slot.psBoundIds)

recSlotSubst : Mono -> List Int -> Option (List (Int, Mono))
recSlotSubst _ [] = Some []
recSlotSubst mono (id :: rest) = match findTvarInMono mono id
  None => None
  Some m => map ((id, m) :: _) (recSlotSubst mono rest)

resolveRecMono : SiteCtx -> String -> ScopeId -> IfaceRef -> Mono -> Route
resolveRecMono sx encl scope iface m = match headTyconMono m
  -- a rigid variable names no instance, so its spelled head is left as it was
  Some (hk@(HkRigid _)) =>
    RKey
      (headKeyTag hk)
      []
      (superRoutesAt sx iface encl scope [m] (reqWalkStart ()))
  -- a concrete head names an instance: select it like any other predicate goal, so
  -- the dictionary carries that instance's word and `requires`
  Some _ => routeOfD sx iface encl scope KeepNone m [] (reqWalkStart ())
  -- the enclosing slot is found by tyvar alone, so it may hold a SUB-interface of
  -- the callee's predicate: read the super out of it
  None => match enclSlot sx.sxModule encl m
    Some slot =>
      let binder =
        Scopes.binderAt
          (Scopes.declarationScope
            (currentScopeStore sx.sxModule.mcGraph ())
            scope)
          slot
      assumAnswerRoute
        sx.sxModule.mcGraph
        (LegacyScalar binder)
        (Some iface)
        scope
        RDict
    None => routeOf sx ifaceRefNone "" scope KeepNone m

-- The sole production decision for a complete ordinary return.  The request keeps
-- the result so checking and route publication cannot observe different selections.
export
solveExactReturnOnce : SiteCtx -> MethodReturnRequest -> MethodReturnResolution
solveExactReturnOnce sx request = match request.mrrResolution.value
  Some resolution => resolution
  None =>
    let resolution = solveExactReturn sx request
    request.mrrResolution := Some resolution
    resolution

export
methodReturnAmbiguousWithoutGiven : ModuleCtx -> MethodReturnRequest -> Bool
methodReturnAmbiguousWithoutGiven mctx request =
  methodPredicateTemplateHasAbsent request.mrrPredicateTemplate
    && isNone
      (uniqueMethodTemplateGiven
        mctx.mcGraph
        request.mrrPredicateTemplate
        request.mrrScope
        (givensForScope mctx.mcGraph request.mrrScope))
    && methodPredicateTemplateCandidateCount
        request.mrrPredicateTemplate
        (ieRowsAll mctx.mcCells.bodyImplEnvRef.value)
        0
      >= 2

export
methodPredicateTemplateHasAbsent : MethodPredicateTemplate -> Bool
methodPredicateTemplateHasAbsent template =
  anyListM isNone template.mptArguments

methodPredicateTemplateCandidateCount : MethodPredicateTemplate ->
  List ImplRow ->
  Int ->
  Int
methodPredicateTemplateCandidateCount _ _ count
  | count >= 2 = count
methodPredicateTemplateCandidateCount _ [] count = count
methodPredicateTemplateCandidateCount template (row :: rest) count = methodPredicateTemplateCandidateCount
  template
  rest
  (if methodPredicateTemplateMatchesRow template row then count + 1 else count)

methodPredicateTemplateMatchesRow : MethodPredicateTemplate -> ImplRow -> Bool
methodPredicateTemplateMatchesRow template (ImplRow _ _ iface tys _ _ _) =
  sameIfaceDecl template.mptInterface iface
    && (match methodPredicateTemplateHeadPairs template.mptArguments tys
      Some pairs =>
        let subst = Ref []
        isSome (matchOneSided matchStep eqStr (matchEqMono subst) pairs [])
      None => False)

methodPredicateTemplateHeadPairs : List (Option Mono) ->
  List Ty ->
  Option (List (Ty, Mono))
methodPredicateTemplateHeadPairs [] [] = Some []
methodPredicateTemplateHeadPairs ((Some argument) :: rest) (head :: heads) =
  map ((head, argument) :: _) (methodPredicateTemplateHeadPairs rest heads)
methodPredicateTemplateHeadPairs (None :: rest) (_ :: heads) =
  methodPredicateTemplateHeadPairs rest heads
methodPredicateTemplateHeadPairs _ _ = None

solveExactReturn : SiteCtx -> MethodReturnRequest -> MethodReturnResolution
solveExactReturn sx request = match methodReturnWanted sx.sxModule request
  None => panic "complete return solver received a legacy request"
  Some wanted =>
    let predicate = wanted.predicate
    let args = map normalize predicate.predicateArguments
    let predRequest = PredicateRequest {
      prIface = predicate.predicateInterface,
      prArgs = PSArgsKnown args,
    }
    let resultMono = stripArrows request.mrrOccurrence
    let given =
      orElseOpt
        (activeDictVarOfEncl
          sx.sxModule
          (Some predRequest)
          resultMono
          request.mrrEnclosing
          wanted.scope)
        (activeDictPredOf
          sx.sxModule.mcGraph
          predRequest
          resultMono
          wanted.scope)
    match given
      Some answer =>
        noteAssumption sx.sxModule.mcGraph wanted.scope answer
        MethodReturnResolution {
          mrrWanted = wanted,
          mrrOutcome = Solved (assumAnswerEvidence answer),
          mrrSelectedRow = None,
        }
      None => solveExactReturnInstance sx request wanted args

solveExactReturnInstance : SiteCtx ->
  MethodReturnRequest ->
  Wanted ->
  List Mono ->
  MethodReturnResolution
solveExactReturnInstance sx request wanted [] = MethodReturnResolution {
  mrrWanted = wanted,
  mrrOutcome = Deferred wanted [BlockingFinalization],
  mrrSelectedRow = None,
}
solveExactReturnInstance sx request wanted args =
  let env = sx.sxModule.mcCells.bodyImplEnvRef.value
  let iface = wanted.predicate.predicateInterface
  let selected =
    orElseOpt
      (ieSelectRowByIface sx env iface args)
      (determinedGoalInstance sx.sxModule iface args)
  match selected
    Some (row@(ImplRow _ inst selectedIface _ _ _ _)) =>
      let prerequisites = methodReturnPrerequisites sx.sxModule args row
      MethodReturnResolution {
        mrrWanted = wanted,
        mrrOutcome =
          Solved
            (InstanceEvidence
              (RequestInstanceId (instRefSeq inst))
              args
              prerequisites
              (instanceSuperEvidence sx.sxModule.mcGraph selectedIface args)),
        mrrSelectedRow = Some row,
      }
    None =>
      let outcome =
        if exactReturnDefers sx.sxModule wanted args then
          Deferred wanted (exactReturnBlockers args)
        else
          Insoluble wanted MissingInstance
      MethodReturnResolution {
        mrrWanted = wanted,
        mrrOutcome = outcome,
        mrrSelectedRow = None,
      }

exactReturnDefers : ModuleCtx -> Wanted -> List Mono -> Bool
exactReturnDefers mctx wanted args =
  wanted.predicate.predicateInterface.irName == "Num"
      && not (builtinClassPresent mctx.mcGraph BNum)
    || not (allConcreteHeads args)
    || goalDefersOpenWorld
      mctx
      wanted.scope
      wanted.predicate.predicateInterface
      args

exactReturnBlockers : List Mono -> List SolverBlocker
exactReturnBlockers args =
  map BlockingTypeVariable (flatMap monoUnboundIds args)

methodReturnPrerequisites : ModuleCtx ->
  List Mono ->
  ImplRow ->
  List PrerequisiteEvidence
methodReturnPrerequisites mctx args row =
  match selectedRowReqMatch mctx args row
    Some (subst, reqs) =>
      map (reqToObligation mctx subst >> prerequisiteEvidence) reqs
    None => []

-- The direct supers of [iface] at [args], as the predicates a dictionary for that
-- goal carries in its super segment (declaration order).
instanceSuperEvidence : GraphCtx -> IfaceRef -> List Mono -> List SuperEvidence
instanceSuperEvidence gctx iface args =
  map
    ((superIface, superArgs) => SuperEvidence {
      superInterface = superIface,
      superArguments = optionOr [] superArgs,
    })
    (directSuperGoals gctx iface args)

prerequisiteEvidence : (IfaceRef, List Mono) -> PrerequisiteEvidence
prerequisiteEvidence (iface, args) = PrerequisiteEvidence {
  prerequisiteInterface = iface,
  prerequisiteArguments = args,
}

export
methodReturnResolutionValid : ModuleCtx ->
  MethodReturnRequest ->
  MethodReturnResolution ->
  Bool
methodReturnResolutionValid mctx request resolution =
  methodReturnWantedMatches mctx request resolution.mrrWanted
    && (match (resolution.mrrOutcome, resolution.mrrSelectedRow)
      (Solved (GivenEvidence _), None) => True
      (Solved (SuperclassEvidence parent path), None) =>
        match projectedGivenOf mctx.mcGraph parent path
          Some g =>
            predicateRequestMatchesSlot
              PredicateRequest {
                prIface = resolution.mrrWanted.predicate.predicateInterface,
                prArgs =
                  PSArgsKnown resolution.mrrWanted.predicate.predicateArguments,
              }
              g.geSlot
          None => False
      (Solved (InstanceEvidence identity args prerequisites _), Some row) =>
        methodReturnInstanceMatches identity row
          && monoVecSameGiven
            args
            resolution.mrrWanted.predicate.predicateArguments
          && methodReturnPrerequisitesMatch
            prerequisites
            (methodReturnPrerequisites mctx args row)
      (Deferred wanted _, None) => wantedMatches wanted resolution.mrrWanted
      (Insoluble wanted _, None) => wantedMatches wanted resolution.mrrWanted
      _ => False)

methodReturnWantedMatches : ModuleCtx -> MethodReturnRequest -> Wanted -> Bool
methodReturnWantedMatches mctx request wanted =
  match methodReturnWanted mctx request
    Some carried => wantedMatches carried wanted
    None => False

wantedMatches : Wanted -> Wanted -> Bool
wantedMatches left right =
  left.id == right.id
    && sameTraceEvId left.destination right.destination
    && left.scope == right.scope
    && sameIfaceDecl
      left.predicate.predicateInterface
      right.predicate.predicateInterface
    && monoVecSameGiven
      left.predicate.predicateArguments
      right.predicate.predicateArguments

methodReturnInstanceMatches : RequestInstanceId -> ImplRow -> Bool
methodReturnInstanceMatches (RequestInstanceId identity) (ImplRow _ inst _ _ _ _ _) =
  identity == instRefSeq inst

methodReturnPrerequisitesMatch : List PrerequisiteEvidence ->
  List PrerequisiteEvidence ->
  Bool
methodReturnPrerequisitesMatch [] [] = True
methodReturnPrerequisitesMatch (left :: ls) (right :: rs) =
  sameIfaceDecl left.prerequisiteInterface right.prerequisiteInterface
    && monoVecSameGiven left.prerequisiteArguments right.prerequisiteArguments
    && methodReturnPrerequisitesMatch ls rs
methodReturnPrerequisitesMatch _ _ = False

-- Impl-based improvement (DICT-SEMANTICS §3 "Improvement by the one matching
-- instance"): when the head matcher (`implHeadSubst`) accepts a goal by binding
-- the goal's own free variables through a repeated head variable, and that
-- instance is the only one of the interface whose head unifies with the goal,
-- the binding is committed, so selection sees the goal the instance determined.
-- `Pick (List t) (List Int) (List Int)` against the only instance `impl Pick a a a`
-- fixes `t = Int`.  A second instance that unifies with the goal (an overlap,
-- including one a later binding of a goal variable would make match) or none
-- leaves the goal as it is.
--
-- It runs at a top-level binding group's close (`processSCC`) and at a method
-- body's (`inferMethodBody`), before that boundary's Num defaulting and once more
-- after it, each time ahead of
-- `determineByUniqueInstance`, which commits a goal to its one unifying instance
-- even where no repeated head variable ties the goal to itself.  A local boundary
-- runs it once, before its Num defaulting (`improveLocalGoals`).
--
-- [sigIds] are the group's declared-signature variables still free at its close
-- (at a method body, its instance head's and declared signature's variables).
-- The commit never binds one: they take part as constants, and a goal that would
-- need one bound is left as it is, for `checkSigsTooGeneral` has already run.
export
improveByUniqueImpl : DynCtx -> OrdMap Unit -> List UObligation -> Unit
improveByUniqueImpl dyn _ [] = ()
improveByUniqueImpl dyn sigIds (o :: rest) =
  improveGoal
    dyn
    sigIds
    o.pred.iface
    (map normalize (uOblArgs dyn.dcModule.mcGraph o))
  improveByUniqueImpl dyn sigIds rest

-- Determination by the unique unifying instance (DICT-SEMANTICS §3, the settle
-- sequence's second step).  A goal of any arity that is not closed is unified with
-- a fresh instance of the one instance head that unifies with it, every variable in
-- [rigidIds] held rigid.  [rigidIds] are the variables the boundary does not own:
-- at a group, the declared signatures' variables and the variables in an argument
-- position of a member's type; at a method body, the instance head's and declared
-- signature's.  Any other variable of the goal is the boundary's, and the unique
-- instance is the only type the program can have there.
--
-- The candidates are `goalCandidates`', kept only if a commit leaves every sibling
-- goal on a variable it binds satisfiable: a sibling the commit closes must have an
-- instance in the table.  A projection of a wider goal is not determined: the
-- positions it drops can still tell its candidates apart.
--
-- Sweeps repeat until one commits nothing, so a goal that another goal's commit
-- makes unique is determined in the same pass whatever order the window lists
-- them in.  What stays open gets its verdict from `rejectUndeterminedVectors`.
export
determineByUniqueInstance : ModuleCtx -> OrdMap Unit -> List UObligation -> Unit
determineByUniqueInstance mctx rigidIds obls =
  if isNonEmptyL obls then
    determineSweeps
      mctx
      rigidIds
      (goalWindowOf mctx.mcGraph obls)
      (listLen obls + 1)

-- The fuel only bounds the loop: every sweep but the last changes some goal's
-- shape.
determineSweeps : ModuleCtx -> OrdMap Unit -> GoalWindow -> Int -> Unit
determineSweeps mctx rigidIds window fuel =
  if fuel > 0
    && determineByUniqueInstanceGo
      mctx
      rigidIds
      window
      False
      window.gwGoals then
    determineSweeps mctx rigidIds window (fuel - 1)

-- One sweep over the window; True when some goal took its instance's shape.
determineByUniqueInstanceGo : ModuleCtx ->
  OrdMap Unit ->
  GoalWindow ->
  Bool ->
  List (Int, UObligation) ->
  Bool
determineByUniqueInstanceGo mctx _ _ changed [] = changed
determineByUniqueInstanceGo mctx rigidIds window changed ((_, o) :: rest) =
  let args = map normalize (uOblArgs mctx.mcGraph o)
  let now = determineGoal mctx rigidIds window o args
  determineByUniqueInstanceGo mctx rigidIds window (now || changed) rest

-- True when the commit changed the goal's shape.  A commit that only renames the
-- goal's variables to the instance's fresh ones leaves the goal's size and its
-- count of distinct variables as they were; the window is re-filed either way,
-- since the goal's variables are no longer the ones it was filed under.
determineGoal : ModuleCtx ->
  OrdMap Unit ->
  GoalWindow ->
  UObligation ->
  List Mono ->
  Bool
determineGoal mctx rigidIds0 window o args =
  let rigidIds = withDeclaredVars mctx rigidIds0 args
  determineHeldGoal mctx rigidIds window o args

-- [rigidIds] plus each variable of [args] a closed binder declared: determination
-- commits a binding, and a declared variable is rigid in every matcher that does.
withDeclaredVars : ModuleCtx -> OrdMap Unit -> List Mono -> OrdMap Unit
withDeclaredVars mctx rigidIds args =
  let declared = mctx.mcCells.declaredSigVarIds.value
  omFromNames
    (filterList
      (k => omHasKey k declared)
      (map intToString (flatMap monoUnboundIds args)))
    rigidIds

determineHeldGoal : ModuleCtx ->
  OrdMap Unit ->
  GoalWindow ->
  UObligation ->
  List Mono ->
  Bool
determineHeldGoal mctx rigidIds window o args
  | monoVectorClosed args || goalVarsAllHeld rigidIds args = False
  | otherwise =
    let rows = goalRows mctx o.pred.iface args
    let unifying =
      if goalIsProjection args rows then
        []
      else
        goalCandidates mctx rigidIds args rows
    match determinationCandidates mctx window args unifying
      [(row, _)] =>
        let oldIds = dedupI (flatMap monoUnboundIds args)
        let sizeBefore = monoSizes args
        -- Minted inside the boundary's level: a goal variable unified with one
        -- of these keeps its level and still generalizes.
        enterLevel mctx ()
        let heads = freshRowHeads mctx row
        exitLevel mctx ()
        commitImprovement (dynFor mctx) rigidIds (zip args heads)
        fileDeterminedRow mctx row args
        refileGoals mctx.mcGraph window oldIds
        monoSizes args /= sizeBefore
          || listLen (dedupI (flatMap monoUnboundIds args)) /= listLen oldIds
      _ => False

-- Files a commit's instance under the variable heading the committed goal, the
-- one `determinedGoalInstance` reads when selection by head finds nothing.
fileDeterminedRow : ModuleCtx -> ImplRow -> List Mono -> Unit
fileDeterminedRow mctx _ [] = ()
fileDeterminedRow mctx row (first :: rest) = match normalize first
  TVar cell =>
    let table = mctx.mcCells.determinedRowsRef.value
    let filed = optionOr [] (IdMap.get (tyvarId cell) table)
    let entry = (row, map normalize (first :: rest))
    mctx.mcCells.determinedRowsRef :=
      IdMap.set (tyvarId cell) (entry :: filed) table
  _ => ()

-- Files every commit again under the variable now heading its goal.  A later group
-- or module that unified the committed variable moved its representative, and a
-- lookup reads the representative.  Called where the lookups run: the module's end
-- and each module's stamping in the drain.
export
refileDeterminedRows : ModuleCtx -> Unit -> Unit
refileDeterminedRows mctx _ =
  let table = mctx.mcCells.determinedRowsRef.value
  if not (IdMap.isEmpty table) then
    let entries = reverseL (flatMap identity (IdMap.values table))
    mctx.mcCells.determinedRowsRef := Tip
    fold (_ entry => fileDeterminedRow mctx (fst entry) (snd entry)) () entries

-- Every variable of the goal is one the boundary holds rigid, so a commit could
-- bind none of them.
export
goalVarsAllHeld : OrdMap Unit -> List Mono -> Bool
goalVarsAllHeld rigidIds args =
  allList
    (c => omHasKey (intToString (tyvarId c)) rigidIds)
    (flatMap monoVarCells args)

-- The candidates that count toward a commitment or an ambiguity: `rowCountsFor`'s,
-- each kept only if its commit leaves every sibling goal on a variable it binds
-- satisfiable.
export
determinationCandidates : ModuleCtx ->
  GoalWindow ->
  List Mono ->
  List (ImplRow, List (Int, Mono)) ->
  List (ImplRow, List (Int, Mono))
determinationCandidates mctx window args unifying =
  filterList
    (cand =>
      rowCountsFor args (fst cand)
        && siblingsStaySatisfiable mctx window (snd cand))
    unifying

export
goalWindowOf : GraphCtx -> List UObligation -> GoalWindow
goalWindowOf gctx obls =
  let goals = indexed obls
  GoalWindow {
    gwGoals = goals,
    gwByIndex = fold (m (i, o) => IdMap.set i o m) Tip goals,
    gwByVar = Ref (fold (m (i, o) => fileGoal gctx i o m) Tip goals),
  }

fileGoal : GraphCtx ->
  Int ->
  UObligation ->
  Map Int (List Int) ->
  Map Int (List Int)
fileGoal gctx i o byVar =
  fold
    (m id => IdMap.set id (i :: optionOr [] (IdMap.get id m)) m)
    byVar
    (dedupI (flatMap monoUnboundIds (uOblArgs gctx o)))

export
goalsOnVar : GoalWindow -> Int -> List Int
goalsOnVar window id = optionOr [] (IdMap.get id window.gwByVar.value)

-- A commit binds only variables of the committed goal and of the instance's fresh
-- head, so the goals whose variables it can change are the ones filed under the
-- committed goal's variables.
refileGoals : GraphCtx -> GoalWindow -> List Int -> Unit
refileGoals gctx window oldIds =
  window.gwByVar :=
    fold
      (acc i => match IdMap.get i window.gwByIndex
        Some g => fileGoal gctx i g acc
        None => acc)
      window.gwByVar.value
      (dedupI (flatMap (goalsOnVar window) oldIds))

-- [row]'s head, freshened, unified with [args] in a scratch substitution with
-- every variable in [rigidIds] held rigid; the substitution, or None.
rowHeadSubstRigid : ModuleCtx ->
  OrdMap Unit ->
  List Mono ->
  ImplRow ->
  Option (List (Int, Mono))
rowHeadSubstRigid mctx rigidIds args row =
  let heads = freshRowHeads mctx row
  let scratch = Ref []
  if listLen heads == listLen args
    && cohOverlapGo
      scratch
      (rigidSigPairs mctx.mcGraph rigidIds (zip args heads)) then
    Some !scratch
  else
    None

siblingsStaySatisfiable : ModuleCtx -> GoalWindow -> List (Int, Mono) -> Bool
siblingsStaySatisfiable mctx window subst =
  let bound = map fst subst
  let scratch = Ref subst
  allList
    (i => match IdMap.get i window.gwByIndex
      Some s => siblingStaysSatisfiable mctx scratch bound s
      None => True)
    (dedupI (flatMap (goalsOnVar window) bound))

-- A sibling the commit leaves open stays satisfiable, and a closed one needs an
-- instance whose head matches it.  A sibling with fewer arguments than some
-- instance of its interface has heads is a truncation, the projection of a wider
-- goal onto its first positions (a per-slot goal `recordCallObligations` shatters
-- a predicate into), so matching rows cannot refute it and it stays satisfiable.
siblingStaysSatisfiable : ModuleCtx ->
  Ref (List (Int, Mono)) ->
  List Int ->
  UObligation ->
  Bool
siblingStaysSatisfiable mctx scratch bound s =
  let args = map normalize (uOblArgs mctx.mcGraph s)
  if not (any (i => elem i bound) (flatMap monoUnboundIds args)) then
    True
  else
    let after = map (cohApply scratch) args
    not (monoVectorClosed after)
      || anyList
        (row =>
          listLen (ieRowTys row) > listLen after
            || rowHeadMatches mctx after row)
        (filterList (ieRowOfIface s.pred.iface) (improvementPool mctx after))

improveGoal : DynCtx -> OrdMap Unit -> IfaceRef -> List Mono -> Unit
improveGoal dyn sigIds iface args
  | isEmptyL args || monoVectorClosed args = ()
  | otherwise =
    let rows =
      filterList (ieRowOfIface iface) (improvementPool dyn.dcModule args)
    match filterList (rowHeadMatches dyn.dcModule args) rows
      [row] => match repeatedGoalPairs (ieRowTys row) args
        [] => ()
        pairs =>
          if listLen (filterList (rowHeadUnifies dyn.dcModule args) rows)
            == 1 then
            commitImprovement dyn sigIds pairs
      _ => ()

-- Solve [pairs] in a scratch substitution with every signature variable held
-- rigid, then bind each variable that substitution solved, in the direction it
-- solved it: `unify (TVar cell) m` links `cell`, so a fresh variable is linked
-- to a signature variable and never the other way round.
commitImprovement : DynCtx -> OrdMap Unit -> List (Mono, Mono) -> Unit
commitImprovement dyn sigIds pairs =
  let cells = flatMap (p => monoVarCells (fst p) ++ monoVarCells (snd p)) pairs
  let sigCells = sigCellsOf sigIds cells
  let scratch = Ref []
  let rigidPairs = rigidSigPairs dyn.dcModule.mcGraph sigIds pairs
  let cellsById = map (c => (tyvarId c, c)) cells
  if cohOverlapGo scratch rigidPairs then
    each
      (binding => match lookupAssocI (fst binding) cellsById
        Some cell => unifyIn dyn (TVar cell) (unrigidSig sigCells (snd binding))
        None => ())
      (reverse !scratch)

-- Every row that can unify with [args]: the graph-global `IE` rows route selection
-- reads (`ieSelectRowByIface`).  A goal whose first position has a head constructor
-- is unified only by rows filed under that head or under none; a multi-position
-- goal whose first position is a variable, by any row.  A one-position goal that
-- is a bare variable binds no repeated head variable, so it gets no candidates.
export
improvementPool : ModuleCtx -> List Mono -> List ImplRow
improvementPool mctx args =
  let env = mctx.mcCells.bodyImplEnvRef.value
  match goalHeadCon args
    Some hk => ieHeadRows (Some hk) env ++ ieHeadRows None env
    None => if listLen args > 1 then ieRowsAll env else []

-- Coherence's overlap question (`cohOverlap`), asked of the row's head, freshened,
-- and the goal: both sides' variables are wildcards, nothing is committed.
rowHeadUnifies : ModuleCtx -> List Mono -> ImplRow -> Bool
rowHeadUnifies mctx args row =
  let tys = ieRowTys row
  let tvs = freshTvMap mctx (dedup (flatMap tyVarNames tys))
  cohOverlap (map (fromAstType mctx tvs) tys) args

-- The pairs a repeated head variable binds, each of which the matcher found
-- unifiable in its scratch `cohOverlapGo`.
repeatedGoalPairs : List Ty -> List Mono -> List (Mono, Mono)
repeatedGoalPairs tys args = match positionBindings tys args []
  Some binds => repeatedBindings binds []
  None => []

-- Whether one of [answered], or one of its supers at its arguments, is the goal.
export
goalAnsweredBy : GraphCtx ->
  List (IfaceRef, List Mono) ->
  IfaceRef ->
  List Mono ->
  Bool
goalAnsweredBy gctx answered iface args =
  anyList
    (g =>
      walkGoalSame (fst g) (snd g) iface args
        || anyList
          (s => walkGoalSame (fst s) (snd s) iface args)
          (superGoalClosure gctx (fst g) (snd g)))
    answered

-- The goals of [iface]'s supers at [args], transitively, each interface once, so a
-- cyclic super graph (rejected by W1) still ends.
export
superGoalClosure : GraphCtx ->
  IfaceRef ->
  List Mono ->
  List (IfaceRef, List Mono)
superGoalClosure gctx iface args =
  superGoalClosureGo gctx [(iface, args)] [iface] []

superGoalClosureGo : GraphCtx ->
  List (IfaceRef, List Mono) ->
  List IfaceRef ->
  List (IfaceRef, List Mono) ->
  List (IfaceRef, List Mono)
superGoalClosureGo gctx [] _ acc = reverse acc
superGoalClosureGo gctx ((iface, args) :: rest) seen acc =
  let step =
    st sg => match sg
      (sup, Some supArgs) if not (anyList (sameIfaceDecl sup) (fst st)) =>
        (sup :: fst st, (sup, supArgs) :: snd st)
      _ => st
  let (seen2, found) = fold step (seen, []) (directSuperGoals gctx iface args)
  let fresh = reverse found
  superGoalClosureGo gctx (rest ++ fresh) seen2 (found ++ acc)

export
reqToObligation : ModuleCtx ->
  List (String, Mono) ->
  Require ->
  (IfaceRef, List Mono)
reqToObligation mctx subst (Require { requireHead = ifaceR, requireArgs = tysR, requireOrigin = o }) = (
  IfaceRef { irName = ifaceR, irOrigin = o },
  map (reqTyToMono mctx subst) tysR,
)

-- `dispatchMonosOf` over a method occurrence's whole interface vector: a typaram
-- the declared type never mentions reads the occurrence's own variable for it
-- ([omitted]), so the goal keeps every position (DICT-SEMANTICS §5).
export
occurrenceDispatchMonos : List String ->
  Ty ->
  Mono ->
  List (String, Mono) ->
  List Mono
occurrenceDispatchMonos typarams mty occ omitted =
  collectByParam
    typarams
    (walkDispatch typarams (stripTyConstraints mty) occ ++ omitted)

-- parallel structural walk collecting (paramName, mono) wherever the declared
-- type is a bare iface-param tyvar.  Other positions recurse; a shape mismatch
-- (declared has structure the occurrence lacks) simply stops that branch.
export
walkDispatch : List String -> Ty -> Mono -> List (String, Mono)
walkDispatch typarams (TyVar n) m
  | contains n typarams = [(n, normalize m)]
  | otherwise = []
walkDispatch typarams (TyFun a b) m = match peelQual m
  TFun ma _ mb =>
    walkDispatch typarams (stripTyConstraints a) ma
      ++ walkDispatch typarams (stripTyConstraints b) mb
  _ => []
walkDispatch typarams (TyApp a b) m = match peelQual m
  TApp ma mb => walkDispatch typarams a ma ++ walkDispatch typarams b mb
  _ => []
walkDispatch typarams (TyTuple ts) m = match tupleSpine m
  Some ms => flatMap (p => walkDispatch typarams (fst p) (snd p)) (zip ts ms)
  _ => []
walkDispatch _ _ _ = []

-- one mono per interface param, in declaration order; if ANY param has no
-- recovered binding the whole obligation is abandoned (return [] → caller skips).
export
collectByParam : List String -> List (String, Mono) -> List Mono
collectByParam typarams pairs = match collectByParamGo typarams pairs
  None => []
  Some ms => ms

collectByParamGo : List String -> List (String, Mono) -> Option (List Mono)
collectByParamGo [] _ = Some []
collectByParamGo (p :: rest) pairs = match lookupAssoc p pairs
  None => None
  Some m => map (m :: _) (collectByParamGo rest pairs)

-- An instance answers the goal only by fixing a head variable: some instance head
-- unifies with it while the head variables are free, and none does while they are
-- held rigid.  Unification rather than matching, because the instance may need the
-- goal's other variables bound as well (`Conv a String` against
-- `impl Conv Int String`, `Get (Box (List t)) b` against `impl Get (Box a) a`).
export
answeredOnlyByBindingHead : ModuleCtx ->
  OrdMap Unit ->
  IfaceRef ->
  List Mono ->
  Bool
answeredOnlyByBindingHead mctx headIds iface args =
  let rows = filterList (ieRowOfIface iface) (improvementPool mctx args)
  anyList (rowHeadUnifies mctx args) rows
    && not
      (anyList (row => isSome (rowHeadSubstRigid mctx headIds args row)) rows)

-- Whether every use of the binder builds the dictionary the goal's reduction builds
-- now (DICT-SEMANTICS §6.1.3): the goal mentions no variable the uses choose, or the
-- goal is stable (`goalSelectionStable`) and so is each of its super goals
-- (`superGoalClosure`) that selects.  [context] is the matched instance's context
-- at the goal; a super goal it answers (`goalAnsweredBy`) is built from that context,
-- not selected, and the context's goals are reduced under this same test.  Every
-- other super goal is a selection and is tested, whatever its arguments are
-- (constructed, arrows or variables alone): a super goal over variables alone that a
-- blanket instance answers now is unstable when a more specific instance unifies.
export
residualSelectionStable : ModuleCtx ->
  List Int ->
  List (IfaceRef, List Mono) ->
  IfaceRef ->
  List Mono ->
  Bool
residualSelectionStable mctx chosen context iface args
  | not (any (i => elem i chosen) (flatMap monoUnboundIds args)) = True
  | otherwise =
    goalSelectionStable mctx chosen iface args
      && allList
        (sg =>
          goalAnsweredBy mctx.mcGraph context (fst sg) (snd sg)
            || goalSelectionStable mctx chosen (fst sg) (snd sg))
        (superGoalClosure mctx.mcGraph iface args)

-- Whether every use of the binder selects the instance the goal matches now: the goal
-- mentions no variable the uses choose, or among the instance heads that unify with
-- it, one matches it and is ⊑ every other (`goalReach`'s stable minimum).  Only a
-- variable some binder declared (`declaredSigVarIds`) is held rigid in that
-- unification: an enclosing binder's variable that is not generalized yet can still
-- become a type another instance head needs.
goalSelectionStable : ModuleCtx -> List Int -> IfaceRef -> List Mono -> Bool
goalSelectionStable mctx chosen iface args =
  if not (any (i => elem i chosen) (flatMap monoUnboundIds args)) then
    True
  else match stableGoalReach mctx chosen iface args
    ReachMany => False
    ReachOne _ => True
    ReachNone => True

-- The OPEN-WORLD defer test for the two OBLIGATION checkers (`checkOneCallObligation`,
-- `checkReqOne`), as opposed to `residualRefutableNow`'s bare `monoVectorClosed`.  The
-- residual site sits INSIDE a generalizing binding by construction — producing that
-- binding's context is its whole job — so an open goal there always has a scheme to
-- land on, and it never sees a bare-rigid receiver either (`goalHeadCon` is read for
-- candidacy, not for concreteness).  An obligation checker has neither guarantee, so it
-- asks all five questions.  Each conjunct's counterexample is on
-- `checkOneCallObligation`'s arm.
--
-- CONJUNCTS 3 AND 5 are the fix-ROUND ADDITIONS (review S0-2 / S0-1 / S2-5), AND
-- They ask the one question the three-conjunct form never did: *does this goal have a
-- landing site that will actually be given a dict?*  "Defer" means "forward this
-- predicate outward to the binder that quantifies its variables, and let each use site
-- discharge it".  Where no such binder will carry it, "defer" means DROP, and a dropped
-- goal is a type-confused dict at exit 0 — MEASURED, three ways, all against the sprint
-- merge-base `0944ca9d` where every one of them was a located reject:
--   * S0-2 — `g : Tag (Wrap a) => a -> String ; g x = "…\{tagOf (Box x)}"`.  The goal
--     `Tag (Box a)` is NOT the declared context and a declared context cannot grow, so
--     it lands nowhere; HEAD printed `wrapChar|boxInt=123`, `Box Int`'s body applied to
--     a `Char`.  Conjunct 5.
--   * S0-1 — `f : Conv (Wrap a) Int => a -> String`.  The MULTI-PARAMETER goal has a
--     landing site (the declared context IS the goal) but no CONSUMPTION-side answer:
--     `registerPredGiven` matches `[subject]` only and registers nothing for a longer
--     vector, so `entailAssum` can never see it, `entail` falls to `entailInst`, and the
--     body is statically committed to whichever impl was most specific at ABSTRACTION
--     time while the caller's correct dict goes unread.  HEAD printed `T/T` for
--     `"\{f True}/\{f 41}"` (expected `T/n=42`), and swapping the two `impl` blocks
--     changed the answer to `intInt/intInt` — selection by declaration order, which
--     DICT-SEMANTICS §3 forbids outright.  Conjunct 5, via `goalMatchesGiven`, which is
--     deliberately `registerPredGiven`'s OWN shape: this gate admits exactly what that
--     registry can answer, so the two cannot drift into another silent accept.
--     SUPERSEDED AS A reject, not as A RULE (#1956).  `registerPredGiven` is now keyed
--     on the WHOLE argument vector, so this exact program HAS a consumption-side answer:
--     `entailAssum` finds the declared context's dict and S0-1 is ACCEPTED, printing
--     `T/n=42` — the answer DICT-SEMANTICS §3 requires (assum before inst; the caller's
--     dict is used, not an abstraction-time commitment).  The invariant above is
--     unchanged and is what made the reject safe to lift: the gate still admits exactly
--     what the registry answers — the registry simply answers more.
--   * S2-5 — `data Bad = Bad zzz ; use (Bad v) = qq (Wrap v)`.  `zzz` is a `TRigid` no
--     scheme quantifies, so `monoUnboundIds` is empty and conjunct 4 passed VACUOUSLY —
--     the rigid-head forgery `monoHeadIsDecl` catches at the top level, leaking through
--     as soon as the rigid is NESTED inside a structure.  Conjunct 3 is the groundness
--     half made non-vacuous: a goal with no unbound variable at all has nothing for any
--     scheme to generalize, hence nowhere to defer TO.
--
-- CONJUNCT 5 fails open on purpose, and that is what keeps #1939 shape (2) accepted.
-- `not (goalIdsClaimed …)` is the INFERRED-binding arm: `describe x = tag (Wrap x)` in a
-- library module reaches this gate BEFORE its own generalization has registered anything
-- (MEASURED on `test/dict_fixtures/s-open-world-library-dependent-impl/lib.mdk`: the
-- second check pass reaches the goal `Tag (Wrap α)` with an EMPTY given registry and no
-- `funPredicateSlotsRef` row for `describe`), so its scheme is still open and the goal
-- is what will populate it.  A binding whose constraint set is already REGISTERED is
-- fixed — declared or inferred — and a goal claiming its variables must be in it.
--
-- Measured correction to the review'S STATED MECHANISM (report S0-2): a declared
-- context's variables are NOT `TRigid` at this site.  They are ordinary unbound `TVar`s
-- (`i2_unsound.mdk`'s `g` carries `Tag (Wrap TVar#736)` and its goal is
-- `Tag (Box TVar#736)` — the SAME cell), so conjunct 4 was never vacuous for S0-2; it
-- passed because the id genuinely IS deferrable.  The review's conclusion stands, its
-- mechanism does not, and conjunct 5 is keyed on the fact that was actually there.
export
goalDefersOpenWorld : ModuleCtx -> ScopeId -> IfaceRef -> List Mono -> Bool
goalDefersOpenWorld mctx scope iface args =
  not (monoVectorClosed args)
    && allList monoHeadIsDecl args
    && isNonEmptyL (flatMap monoUnboundIds args)
    && allList
      (i => IdMap.has i mctx.mcCells.deferrableVarIds.value)
      (flatMap monoUnboundIds args)
    && (goalMatchesGiven mctx.mcGraph scope iface args
      || goalSlotStillOpen mctx args)

-- COULD a given for this goal still be registered, once the enclosing binding finishes
-- generalizing?  Both conditions are `registerPredGiven`'s own, because it is the only
-- writer that can ever answer a structured goal:
--   * NON-EMPTY.  It returns `()` for the empty vector and registers nothing, so an
--     empty goal can never acquire an answer.  (The registry matches the whole argument
--     vector on all three channels (`requires`, declared, inferred), so a MULTI-PARAMETER
--     structured goal has a consumption-side answer and this arm withholds none.
--     `e1_inf_multi.mdk` (`h x = conv (Wrap x) 0`, no signature) and its signatured twin
--     `a2_twoarg.mdk` pin it.)
--   * UNCLAIMED.  See below; this is the arm that keeps #1939 shape (2) accepted.
--     Asked of the vector's WHOLE unbound-id set, for the same reason the match above is
--     pointwise: a slot is open only if NO binding has already fixed a context claiming
--     any variable this predicate mentions, at any position.
goalSlotStillOpen : ModuleCtx -> List Mono -> Bool
goalSlotStillOpen mctx [] = False
goalSlotStillOpen mctx args =
  not (goalIdsClaimed mctx (flatMap monoUnboundIds args))

-- has some binding's constraint set ALREADY been registered against one of [ids]?  If
-- so that binding's context is fixed and this goal must be part of it; if not, the
-- binding is still generalizing and this goal is what will open its slot.  Reads
-- `funPredicateSlotsRef`, which both channels write (`registerMember` for a declared
-- context, `registerInferredFor` for an inferred one), so the test does not distinguish
-- them — the fixedness, not the channel, is what decides.
goalIdsClaimed : ModuleCtx -> List Int -> Bool
goalIdsClaimed mctx [] = False
goalIdsClaimed mctx ids =
  anyClaimRow ids mctx.mcCells.funPredicateSlotsRef.value

anyClaimRow : List Int -> List (String, List PredicateSlot) -> Bool
anyClaimRow _ [] = False
anyClaimRow ids ((_, slots) :: rest) =
  anyList
      (v => anyList (m => any (i => elem i ids) (monoTyvarIds m)) v)
      (predicateSlotArgs slots)
    || anyClaimRow ids rest

-- The types a goal is posed at.
export
goalMonos : Obligation -> List Mono
goalMonos o = match o.oPayload
  GPSite _ m site => m :: siteKindMonos site
  GPArith m => [m]
  GPDictApp app => app.pdaMonos ++ flatMap identity app.pdaArgVecs
  GPMethodDict _ => []
  GPRecDictApp (RecDictApp _ _ _ m _ _) => [m]

siteKindMonos : SiteKind -> List Mono
siteKindMonos (SKReturn _ m) = [m]
siteKindMonos (SKAdmittedReturn _ _ m) = [m]
siteKindMonos (SKExactReturn _ request) = [request.mrrOccurrence]
siteKindMonos (SKNumReturn _ m) = [m]
siteKindMonos (SKArg _ m omitted) = m :: map snd omitted
siteKindMonos (SKOp _) = []
siteKindMonos (SKPredicateOp _ _) = []
siteKindMonos (SKRLocal _ _ ms _ vecs) = ms ++ flatMap identity vecs

-- Observation declarations exported for readers outside this module: the method-return trace and
-- memo views for the drive-level `typecheck_test`, and the method-slot and method-return probes
-- `tc_occurrence` and `tc_module` read.

-- Each entry with the evidence its goal published in [evidence], the table of the
-- drive that recorded it.
export
finishMethodReturnTrace : TraceSink -> EvTable -> List MethodReturnTraceEntry
finishMethodReturnTrace sink evidence =
  map
    (publishMethodReturnTrace evidence)
    (reverse sink.tsMethodReturnEntries.value)

publishMethodReturnTrace : EvTable ->
  MethodReturnTraceEntry ->
  MethodReturnTraceEntry
publishMethodReturnTrace evidence entry =
  let published = match entry.mrtGoal
    Some goal => lookupTraceEvidence goal evidence
    None => None
  MethodReturnTraceEntry {
    mrtStage = entry.mrtStage,
    mrtInterface = entry.mrtInterface,
    mrtMethod = entry.mrtMethod,
    mrtArguments = entry.mrtArguments,
    mrtScope = entry.mrtScope,
    mrtOrigin = entry.mrtOrigin,
    mrtGoal = entry.mrtGoal,
    mrtPublished = published,
    mrtQualifiedBody = entry.mrtQualifiedBody,
    mrtWanted = entry.mrtWanted,
    mrtOutcome = entry.mrtOutcome,
    mrtRoute = entry.mrtRoute,
    mrtPrerequisites = entry.mrtPrerequisites,
  }

lookupTraceEvidence : EvId -> EvTable -> Option EvVal
lookupTraceEvidence _ [] = None
lookupTraceEvidence goal ((EvEntry candidate value) :: rest) =
  if sameTraceEvId goal candidate then
    Some value
  else
    lookupTraceEvidence goal rest

sealMethodReturnGoals : GraphCtx ->
  EvTable ->
  List Obligation ->
  (List Obligation, List MethodReturnMemoView)
sealMethodReturnGoals gctx evidence goals =
  sealMethodReturnGoalsFrom gctx evidence (reverse goals) ([], [])

-- Walks the goals last to first so each result list is built in input order, with
-- no recursion before the cons: the goal list of a program that imports `async` is
-- long enough to overflow the baseline-tier wasm stack in a browser worker.
sealMethodReturnGoalsFrom : GraphCtx ->
  EvTable ->
  List Obligation ->
  (List Obligation, List MethodReturnMemoView) ->
  (List Obligation, List MethodReturnMemoView)
sealMethodReturnGoalsFrom gctx _ [] acc = acc
sealMethodReturnGoalsFrom gctx evidence (goal :: rest) (goals, views) =
  match exactReturnRequestOfGoal goal
    Some request => sealMethodReturnGoalsFrom gctx evidence rest (
      goals,
      methodReturnMemoView gctx evidence goal request :: views,
    )
    None => sealMethodReturnGoalsFrom gctx evidence rest (goal :: goals, views)

methodReturnMemoView : GraphCtx ->
  EvTable ->
  Obligation ->
  MethodReturnRequest ->
  MethodReturnMemoView
methodReturnMemoView gctx evidence goal request =
  let (outcome, prerequisites) = match request.mrrResolution.value
    None => ("legacy", [])
    Some resolution => (
      methodReturnMemoOutcome resolution.mrrOutcome,
      methodReturnMemoPrerequisites resolution.mrrOutcome,
    )
  MethodReturnMemoView {
    mrmvInterface = methodReturnMemoIface request.mrrIface,
    mrmvMethod = request.mrrName,
    mrmvArguments =
      map methodReturnMemoArguments (methodReturnArgs gctx request),
    mrmvOutcome = outcome,
    mrmvPrerequisites = prerequisites,
    mrmvEvidence = methodReturnMemoEvidence goal.oEv evidence,
  }

methodReturnMemoArguments : List Mono -> List String
methodReturnMemoArguments arguments = map ppMono arguments

methodReturnMemoIface : IfaceRef -> String
methodReturnMemoIface iface =
  let identity = ifaceIdentity iface.irOrigin iface.irName
  if identity == "" then iface.irName else identity

methodReturnMemoOutcome : SolverOutcome -> String
methodReturnMemoOutcome (Solved (GivenEvidence _)) = "given"
methodReturnMemoOutcome (Solved (InstanceEvidence _ _ _ _)) = "instance"
methodReturnMemoOutcome (Solved (SuperclassEvidence _ _)) = "superclass"
methodReturnMemoOutcome (Deferred _ _) = "deferred"
methodReturnMemoOutcome (Insoluble _ MissingInstance) = "missing"
methodReturnMemoOutcome (Insoluble _ (AmbiguousInstances _)) = "ambiguous"
methodReturnMemoOutcome (Insoluble _ (ResolutionCycle _)) = "cycle"

methodReturnMemoPrerequisites : SolverOutcome -> List (String, List String)
methodReturnMemoPrerequisites (Solved (InstanceEvidence _ _ prerequisites _)) =
  map
    (prerequisite => (
      methodReturnMemoIface prerequisite.prerequisiteInterface,
      map ppMono prerequisite.prerequisiteArguments,
    ))
    prerequisites
methodReturnMemoPrerequisites _ = []

methodReturnMemoEvidence : EvId -> EvTable -> String
methodReturnMemoEvidence goal evidence = match lookupTraceEvidence goal evidence
  Some (EvOne route) => methodReturnMemoRoute route
  Some (EvMany routes) => join "," (map methodReturnMemoRoute routes)
  Some (EvLit _ route) => methodReturnMemoRoute route
  Some (EvHead head) => "head:\{head}"
  None => "unpublished"

methodReturnMemoRoute : Route -> String
methodReturnMemoRoute RNone = "none"
methodReturnMemoRoute (RKey key prerequisites supers) =
  "key:\{key}[\{join "," (map methodReturnMemoRoute prerequisites)}]\{methodReturnMemoSupers supers}"
methodReturnMemoRoute (RDict name) = "given:\{name}"
methodReturnMemoRoute (RDictFwd name) = "forwarded:\{name}"
methodReturnMemoRoute (RLocal name _) = "local:\{name}"
methodReturnMemoRoute (RScalar name) = "scalar:\{name}"
methodReturnMemoRoute (RProj r path) =
  "projected:\{methodReturnMemoRoute r}.\{join "." (map intToString path)}"

methodReturnMemoSupers : List Route -> String
methodReturnMemoSupers [] = ""
methodReturnMemoSupers supers =
  "{\{join "," (map methodReturnMemoRoute supers)}}"

isSemanticGivenAnswer : Option AssumAnswer -> Bool
isSemanticGivenAnswer (Some (SemanticGiven (GivenEvidence _))) = True
isSemanticGivenAnswer _ = False

isLegacyPredicateAnswer : Option AssumAnswer -> Bool
isLegacyPredicateAnswer (Some (LegacyPredicate _)) = True
isLegacyPredicateAnswer _ = False

-- Private service check for the selection half of the scope adapter.  It keeps
-- the full-vector and id-witness eligibility rules observable independently of
-- production examples, and its sibling query fails if lexical filtering is
-- removed from `anyGivenMatches`.
scopeGivenProbe : Unit -> List Bool
scopeGivenProbe _ =
  let gctx = probeGraphCtx ()
  let store = currentScopeStore gctx ()
  let root = Scopes.freshScope store None 0 "given-probe" ModuleOwner
  let owner =
    Scopes.freshScope store (Some root) 1 "given-probe" (BindingOwner "owner")
  let sibling =
    Scopes.freshScope store (Some root) 1 "given-probe" (BindingOwner "sibling")
  let iface =
    IfaceRef { irName = "PairGiven", irOrigin = OriginModule "given-probe" }
  let args = [tconBuiltin "Int", tconBuiltin "Bool"]
  let slot = PredicateSlot {
    psIface = iface,
    psArgs = PSArgsKnown args,
    psBoundIds = [41],
  }
  pushGiven gctx GMPredicate DirectGiven slot (Scopes.binderAt owner 0)
  let exact = PredicateRequest { prIface = iface, prArgs = PSArgsKnown args }
  let unknown = PredicateRequest { prIface = iface, prArgs = PSArgsUnknown }
  let truncated = PredicateRequest {
    prIface = iface,
    prArgs = PSArgsKnown [tconBuiltin "Int"],
  }
  let witnessIface = IfaceRef {
    irName = "WitnessGiven",
    irOrigin = OriginModule "given-probe",
  }
  let witnessSlot = PredicateSlot {
    psIface = witnessIface,
    psArgs = PSArgsKnown [tconBuiltin "Int"],
    psBoundIds = [73],
  }
  let witnessRequest = PredicateRequest {
    prIface = witnessIface,
    prArgs = PSArgsKnown [tconBuiltin "Int"],
  }
  pushGiven gctx GMIdWitnessed DirectGiven witnessSlot (Scopes.binderAt owner 1)
  let compatibleIface = IfaceRef {
    irName = "CompatibleGiven",
    irOrigin = OriginModule "given-probe",
  }
  let compatibleSlot = PredicateSlot {
    psIface = compatibleIface,
    psArgs = PSArgsUnknown,
    psBoundIds = [89],
  }
  let compatibleRequest = PredicateRequest {
    prIface = compatibleIface,
    prArgs = PSArgsKnown [tconBuiltin "Int"],
  }
  pushGiven
    gctx
    GMPredicate
    DirectGiven
    compatibleSlot
    (Scopes.binderAt owner 2)
  let givens = givensForScope gctx owner
  let result = [
    anyGivenMatches gctx exact owner givens,
    not (anyGivenMatches gctx exact sibling givens),
    not (anyGivenMatches gctx truncated owner givens),
    not (anyGivenMatches gctx witnessRequest owner givens),
    isSome
      (firstPredForEnclAt gctx GSImplRequires 73 witnessRequest owner givens),
    isNone
      (firstPredForEnclAt gctx GSImplRequires 74 witnessRequest owner givens),
    isSemanticGivenAnswer (firstPredForEncl gctx exact owner givens),
    isLegacyPredicateAnswer
      (firstPredForEnclAt gctx GSPredicateOnly 41 unknown owner givens),
    isLegacyPredicateAnswer
      (firstPredForEnclResidual gctx "PairGiven" args owner givens),
    isLegacyPredicateAnswer
      (firstPredForEncl gctx compatibleRequest owner givens),
  ]
  result

-- > scopeGivenProbe ()
-- [True, True, True, True, True, True, True, True, True, True]

export
methodSlotBoundIds : List MethodPredicateSlot -> List (List Int)
methodSlotBoundIds slots = map (slot => slot.mpsPredicate.psBoundIds) slots

export
methodSlotPositions : List MethodPredicateSlot -> List (List Int)
methodSlotPositions slots = map (slot => slot.mpsPositions) slots

export
methodSlotIdsAtPositions : List Int ->
  List MethodPredicateSlot ->
  List (List Int)
methodSlotIdsAtPositions ids slots =
  map
    (slot => map (pos => optionOr (0 - 1) (get pos ids)) slot.mpsPositions)
    slots

export
methodSlotArgumentIds : List MethodPredicateSlot -> List (List Int)
methodSlotArgumentIds slots = map methodSlotArgumentIdsOne slots

methodSlotArgumentIdsOne : MethodPredicateSlot -> List Int
methodSlotArgumentIdsOne slot = match slot.mpsPredicate.psArgs
  PSArgsUnknown => []
  PSArgsKnown args => flatMap monoTyvarIds args

export
methodRowRegistrySlotIds : ModuleCtx -> String -> List (List Int)
methodRowRegistrySlotIds mctx key =
  match lookupAssoc key mctx.mcCells.methodPredicateSlotsRef.value
    None => []
    Some slots => methodSlotBoundIds slots

export
numAnchorObservationView : NumAnchorTestObservation ->
  (String, Bool, Bool, String, String)
numAnchorObservationView observation = (
  observation.natoCase,
  observation.natoHasRow,
  observation.natoIface == "Num",
  observation.natoSchemeBody,
  observation.natoDeclaredType,
)

export
methodReturnProbeIface : String -> String -> Ty -> Decl
methodReturnProbeIface moduleId ifaceName methodTy =
  methodRowTestIface
    moduleId
    ifaceName
    ["a"]
    [IfaceMethod "make" methodTy None None]

export
methodReturnProbeImpl : String -> String -> Decl
methodReturnProbeImpl moduleId ifaceName = DImpl {
  pub = False,
  iface = ifaceName,
  tys = [tyConBuiltin "Int" None],
  reqs = [],
  methods = [ImplMethod "make" [] (ELit LUnit)],
  implOrigin = OriginModule moduleId,
  implIfaceLoc = None,
}

export
methodReturnProbeScope : ModuleCtx -> String -> ScopeId
methodReturnProbeScope mctx moduleId =
  let scope =
    Scopes.freshScope
      (currentScopeStore mctx.mcGraph ())
      None
      0
      moduleId
      ModuleOwner
  openScope mctx scope
  scope

export
methodReturnProbeOccurrence : ModuleCtx ->
  MethodSchemeRow ->
  MethodTrackedInstantiation
methodReturnProbeOccurrence mctx row =
  let inst = instantiateMethodTracked mctx row.msrScheme
  unify mctx (stripArrows inst.mtiBody) (tconBuiltin "Int")
  inst

export
methodReturnProbeSpelling : ModuleCtx -> MethodSchemeRow -> Unit
methodReturnProbeSpelling mctx row =
  mctx.mcCells.methodAliasEntriesRef :=
    omInsert "make" (row.msrIface, row.msrTyparams, row.msrType, []) omEmpty

export
methodReturnProbeRouteKey : Route -> String
methodReturnProbeRouteKey (RKey key _ _) = key
methodReturnProbeRouteKey _ = ""

export
methodReturnSelectedIdentity : MethodReturnResolution -> Int
methodReturnSelectedIdentity resolution = match resolution.mrrOutcome
  Solved (InstanceEvidence (RequestInstanceId identity) _ _ _) => identity
  _ => -1

methodReturnProbeSlotIfaces : List PredicateSlot -> List String
methodReturnProbeSlotIfaces slots = map (slot => slot.psIface.irName) slots

export
methodReturnProbeGoalIfaces : List Obligation -> List String
methodReturnProbeGoalIfaces [] = []
methodReturnProbeGoalIfaces (goal :: rest) = match goal.oPayload
  GPMethodDict pending =>
    methodReturnProbeSlotIfaces pending.pmdSlots
      ++ methodReturnProbeGoalIfaces rest
  _ => methodReturnProbeGoalIfaces rest

export
methodReturnProbeOblIfaces : List UObligation -> List String
methodReturnProbeOblIfaces [] = []
methodReturnProbeOblIfaces (obl :: rest) =
  let here = match obl.prov
    PMethodLevel => [obl.pred.iface.irName]
    _ => []
  here ++ methodReturnProbeOblIfaces rest

-- The method-return views of [gctx]: its live exact-return goals, sealed.
export
methodReturnMemoCurrentViews : GraphCtx -> List MethodReturnMemoView
methodReturnMemoCurrentViews gctx =
  snd
    (sealMethodReturnGoals
      gctx
      gctx.graphRun.evTable.value
      gctx.graphRun.goals.value)
# DESUGAR
(DUse false (UseGroup ("types" "tc_types") ((mem "Provenance" true) (mem "OblProjection" true) (mem "GoalReach" true) (mem "GoalPayload" true) (mem "GivenScope" true) (mem "GivenProvenance" true) (mem "GivenMatch" true) (mem "AdmittedAnswer" true) (mem "AssumAnswer" true) (mem "BuiltinClass" true) (mem "EvDest" true) (mem "GoalKind" true) (mem "GoalWindow" true) (mem "GraphMarks" true) (mem "MethodReturnMemoView" true) (mem "MethodReturnResolution" true) (mem "MethodReturnTraceEntry" true) (mem "MethodReturnTraceStage" true) (mem "MethodTemplateGivenResult" true) (mem "Obligation" true) (mem "PendingDictApp" true) (mem "PredicateRequest" true) (mem "PredicateSlot" true) (mem "PredicateSlotArgs" true) (mem "SiteCtx" true) (mem "SiteKind" true) (mem "SolvedGoalEntry" true) (mem "Undetermined" true) (mem "UObligation" true) (mem "DynCtx" false) (mem "dynFor" false) (mem "GivenEntry" false) (mem "GraphCtx" false) (mem "ImplEnv" false) (mem "ImplRow" false) (mem "LocalAbs" false) (mem "MethodPredicateSlot" false) (mem "MethodPredicateTemplate" false) (mem "MethodReturnRequest" false) (mem "MethodRow" false) (mem "MethodSchemeRow" false) (mem "MethodTrackedInstantiation" false) (mem "ModuleCtx" false) (mem "NumAnchorTestObservation" false) (mem "PendingEntry" false) (mem "PendingMethodDict" false) (mem "RecDictApp" false) (mem "ReqWalk" false) (mem "TraceSink" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "allConcreteHeads" false) (mem "anyListM" false) (mem "cohApply" false) (mem "cohOverlap" false) (mem "cohOverlapGo" false) (mem "containsI" false) (mem "dedupI" false) (mem "exactReturnRequestOfGoal" false) (mem "findTvarInMono" false) (mem "headTyconMono" false) (mem "matchEqMono" false) (mem "matchOneSided" false) (mem "matchStep" false) (mem "matchTyMono" false) (mem "monoHeadIsDecl" false) (mem "monoMintedBefore" false) (mem "monoSameGiven" false) (mem "monoSizes" false) (mem "monoTyvarIds" false) (mem "monoUnboundIds" false) (mem "monoVarCells" false) (mem "monoVecSameGiven" false) (mem "monoVectorClosed" false) (mem "peelQual" false) (mem "rigidSigPairs" false) (mem "sigCellsOf" false) (mem "sigRigidBindings" false) (mem "stripArrows" false) (mem "stripTyConstraints" false) (mem "substMono" false) (mem "tconBuiltin" false) (mem "tyvarId" false) (mem "tyVarNames" false) (mem "walkMonosSame" false) (mem "unrigidSig" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "callUOblsWindow" false) (mem "currentScopeStore" false) (mem "initialModuleCtx" false) (mem "moduleWindow" false) (mem "probeGraphCtx" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "anyArgMentions" false) (mem "dispatchTyparams" false) (mem "ieHeadRows" false) (mem "ieRowIfaceMatches" false) (mem "ieRowOfIface" false) (mem "ieRowsAll" false) (mem "ieRowTys" false) (mem "instRefSeq" false) (mem "methodArgs" false) (mem "methodRowIface" false) (mem "methodRowTestIface" false) (mem "methodSlotKey" false) (mem "originMethodName" false) (mem "sameIfaceDecl" false))))
(DUse false (UseGroup ("types" "tc_diag") ((mem "erredDuring" false))))
(DUse false (UseGroup ("types" "tc_scope") ((mem "methodAdmittedHere" false) (mem "methodVisibleHere" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "enterLevel" false) (mem "exitLevel" false) (mem "freshEffvar" false) (mem "freshTvMap" false) (mem "freshVar" false) (mem "instantiateMethodTracked" false) (mem "monoUnboundVarLevels" false) (mem "predicateSlotArgs" false) (mem "unify" false) (mem "unifyIn" false))))
(DUse false (UseGroup ("types" "tc_decls_types") ((mem "fromAstType" false) (mem "reqTyToMono" false))))
(DUse false (UseGroup ("types" "tc_solve_givens") ((mem "activeDictPredOf" false) (mem "activeDictVarOfEncl" false) (mem "anyGivenMatches" false) (mem "assumAnswerEvidence" false) (mem "assumAnswerRoute" false) (mem "enclSlot" false) (mem "firstPredForEncl" false) (mem "firstPredForEnclAt" false) (mem "firstPredForEnclResidual" false) (mem "givenInScope" false) (mem "givenRoute" false) (mem "givensForScope" false) (mem "goalMatchesGiven" false) (mem "noteAssumption" false) (mem "predicateRequestMatchesSlot" false) (mem "projectedGivenOf" false) (mem "pushGiven" false))))
(DUse false (UseGroup ("types" "tc_solve_entail") ((mem "determinedGoalInstance" false) (mem "directSuperGoals" false) (mem "enteredGoalKey" false) (mem "freshRowHeads" false) (mem "goalCandidates" false) (mem "goalHeadCon" false) (mem "goalIsProjection" false) (mem "goalRows" false) (mem "ieSelectRowByIface" false) (mem "paramMonoOf" false) (mem "positionBindings" false) (mem "repeatedBindings" false) (mem "reqWalkMemo" false) (mem "reqWalkStart" false) (mem "routeOfD" false) (mem "rowCountsFor" false) (mem "rowHeadMatches" false) (mem "rowRouteKey" false) (mem "selectedCallSupers" false) (mem "selectedRowReqMatch" false) (mem "stableGoalReach" false) (mem "superRoutesAt" false) (mem "findMatchingImplReqsU" false))))
(DUse false (UseGroup ("types" "solver_contract") ((mem "SolverFailure" true) (mem "ClassPredicate" true) (mem "GoalOrigin" true) (mem "Instantiation" true) (mem "InstantiationArgument" true) (mem "SolverBlocker" true) (mem "SolverOutcome" true) (mem "Wanted" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "TyConOrigin" true) (mem "Ns" true) (mem "Lit" true) (mem "Expr" true) (mem "Decl" true) (mem "EvEntry" true) (mem "EvId" true) (mem "EvVal" true) (mem "IfaceMethod" true) (mem "ImplMethod" true) (mem "Loc" true) (mem "Require" true) (mem "Route" true) (mem "Ty" true) (mem "EvTable" false) (mem "ifaceIdentity" false) (mem "mkIdent" false) (mem "tyConBuiltin" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffRow" true) (mem "pureRow" false))))
(DUse false (UseGroup ("types" "evidence") ((mem "SolverEvidence" true) (mem "PrerequisiteEvidence" true) (mem "RequestInstanceId" true) (mem "ScopeId" true) (mem "SuperEvidence" true) (mem "goalIdForDestination" false))))
(DUse false (UseGroup ("types" "registry") ((mem "HeadKey" true) (mem "headKeyTag" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Mono" true) (mem "lookupAssocI" false) (mem "normalize" false) (mem "ppMono" false) (mem "tupleSpine" false))))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "anyList" false) (mem "contains" false) (mem "dedup" false) (mem "endsWith" false) (mem "eqStr" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "isSome" false) (mem "listLen" false) (mem "lookupAssoc" false) (mem "orElseOpt" false) (mem "reverseL" false) (mem "splitOnChar" false))))
(DUse false (UseGroup ("list") ((mem "drop" false) (mem "get" false) (mem "head" false) (mem "indexed" false) (mem "reverse" false) (mem "take" false) (mem "zip" false))))
(DUse false (UseGroup ("string") ((mem "join" false))))
(DUse false (UseGroup ("types" "evidence_complete") ((mem "innerNone" false))))
(DUse false (UseAlias ("types" "scopes") "Scopes"))
(DUse false (UseAlias ("map") "IdMap"))
(DUse false (UseGroup ("types" "scopes") ((mem "ScopeOwner" true))))
(DTypeSig true "goalKindTag" (TyFun (TyCon "GoalKind") (TyCon "Int")))
(DFunDef false "goalKindTag" ((PCon "GKReturnSite")) (ELit (LInt 0)))
(DFunDef false "goalKindTag" ((PCon "GKArgStamp")) (ELit (LInt 1)))
(DFunDef false "goalKindTag" ((PCon "GKRLocalSite")) (ELit (LInt 2)))
(DFunDef false "goalKindTag" ((PCon "GKBinopSite")) (ELit (LInt 3)))
(DFunDef false "goalKindTag" ((PCon "GKUnopSite")) (ELit (LInt 4)))
(DFunDef false "goalKindTag" ((PCon "GKArithSite")) (ELit (LInt 5)))
(DFunDef false "goalKindTag" ((PCon "GKDictApp")) (ELit (LInt 6)))
(DFunDef false "goalKindTag" ((PCon "GKMethodDict")) (ELit (LInt 7)))
(DFunDef false "goalKindTag" ((PCon "GKRecDictApp")) (ELit (LInt 8)))
(DTypeSig true "pushGoal" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Obligation") (TyCon "Unit"))))
(DFunDef false "pushGoal" ((PVar "gctx") (PVar "o")) (EBlock (DoLet false false (PVar "g") (EFieldAccess (EVar "gctx") "graphRun")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "goals")) (EBinOp "::" (EVar "o") (EFieldAccess (EFieldAccess (EVar "g") "goals") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "goalsN")) (EBinOp "+" (EFieldAccess (EFieldAccess (EVar "g") "goalsN") "value") (ELit (LInt 1)))))))
(DTypeSig true "pushDictApp" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PendingDictApp") (TyCon "Unit"))))
(DFunDef false "pushDictApp" ((PVar "gctx") (PVar "app")) (EApp (EApp (EVar "pushGoal") (EVar "gctx")) (ERecordCreate "Obligation" ((fa "oKind" (EVar "GKDictApp")) (fa "oDest" (EApp (EVar "EvRoutes") (EFieldAccess (EVar "app") "pdaRoutesRef"))) (fa "oEv" (EFieldAccess (EVar "app") "pdaEv")) (fa "oEncl" (EFieldAccess (EVar "app") "pdaEncl")) (fa "oLoc" (EFieldAccess (EVar "app") "pdaLoc")) (fa "oScope" (EFieldAccess (EVar "app") "pdaScope")) (fa "oPayload" (EApp (EVar "GPDictApp") (EVar "app"))) (fa "oInner" (EApp (EVar "Ref") (EVar "innerNone")))))))
(DTypeSig true "goalsSince" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Obligation")))))
(DFunDef false "goalsSince" ((PVar "gctx") (PVar "mark")) (EApp (EApp (EApp (EVar "moduleWindow") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "goalsN") "value")) (EVar "mark")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "goals") "value")))
(DTypeSig true "goalsOfKindIn" (TyFun (TyCon "GoalKind") (TyFun (TyApp (TyCon "List") (TyCon "Obligation")) (TyApp (TyCon "List") (TyCon "Obligation")))))
(DFunDef false "goalsOfKindIn" ((PVar "k") (PVar "gs")) (EApp (EApp (EVar "filterList") (ELam ((PVar "o")) (EBinOp "==" (EApp (EVar "goalKindTag") (EFieldAccess (EVar "o") "oKind")) (EApp (EVar "goalKindTag") (EVar "k"))))) (EVar "gs")))
(DTypeSig true "siteEntry" (TyFun (TyCon "Obligation") (TyApp (TyCon "List") (TyCon "PendingEntry"))))
(DFunDef false "siteEntry" ((PVar "o")) (EMatch (EFieldAccess (EVar "o") "oPayload") (arm (PCon "GPSite" (PVar "name") (PVar "m") (PVar "site")) () (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PendingEntry") (EVar "name")) (EApp (EVar "evCell") (EFieldAccess (EVar "o") "oDest"))) (EVar "m")) (EFieldAccess (EVar "o") "oEncl")) (EVar "site")) (EFieldAccess (EVar "o") "oLoc")) (EFieldAccess (EVar "o") "oScope")) (EFieldAccess (EVar "o") "oEv")))) (arm PWild () (EListLit))))
(DTypeSig false "evCell" (TyFun (TyCon "EvDest") (TyApp (TyCon "Ref") (TyCon "Route"))))
(DFunDef false "evCell" ((PCon "EvRoute" (PVar "r"))) (EVar "r"))
(DFunDef false "evCell" ((PCon "EvRoutes" PWild)) (EApp (EVar "Ref") (EVar "RNone")))
(DTypeSig true "arithEntry" (TyFun (TyCon "Obligation") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Ref") (TyCon "Route")) (TyCon "Mono")))))
(DFunDef false "arithEntry" ((PVar "o")) (EMatch (EFieldAccess (EVar "o") "oPayload") (arm (PCon "GPArith" (PVar "m")) () (EListLit (ETuple (EApp (EVar "evCell") (EFieldAccess (EVar "o") "oDest")) (EVar "m")))) (arm PWild () (EListLit))))
(DTypeSig true "dictAppsSince" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "PendingDictApp")))))
(DFunDef false "dictAppsSince" ((PVar "gctx") (PVar "mark")) (EApp (EVar "dictAppsIn") (EApp (EApp (EVar "goalsSince") (EVar "gctx")) (EVar "mark"))))
(DTypeSig false "dictAppsIn" (TyFun (TyApp (TyCon "List") (TyCon "Obligation")) (TyApp (TyCon "List") (TyCon "PendingDictApp"))))
(DFunDef false "dictAppsIn" ((PVar "gs")) (EApp (EApp (EVar "flatMap") (EVar "dictAppEntry")) (EVar "gs")))
(DTypeSig true "dictAppEntry" (TyFun (TyCon "Obligation") (TyApp (TyCon "List") (TyCon "PendingDictApp"))))
(DFunDef false "dictAppEntry" ((PVar "o")) (EMatch (EFieldAccess (EVar "o") "oPayload") (arm (PCon "GPDictApp" (PVar "a")) () (EListLit (EVar "a"))) (arm PWild () (EListLit))))
(DTypeSig true "methodDictEntry" (TyFun (TyCon "Obligation") (TyApp (TyCon "List") (TyCon "PendingMethodDict"))))
(DFunDef false "methodDictEntry" ((PVar "o")) (EMatch (EFieldAccess (EVar "o") "oPayload") (arm (PCon "GPMethodDict" (PVar "d")) () (EListLit (EVar "d"))) (arm PWild () (EListLit))))
(DTypeSig true "recDictAppEntry" (TyFun (TyCon "Obligation") (TyApp (TyCon "List") (TyCon "RecDictApp"))))
(DFunDef false "recDictAppEntry" ((PVar "o")) (EMatch (EFieldAccess (EVar "o") "oPayload") (arm (PCon "GPRecDictApp" (PVar "r")) () (EListLit (EVar "r"))) (arm PWild () (EListLit))))
(DTypeSig true "goalsMark" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyCon "Int"))))
(DFunDef false "goalsMark" ((PVar "gctx") PWild) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "goalsN") "value"))
(DTypeSig true "dropGoalsSince" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "GoalKind")) (TyCon "Unit")))))
(DFunDef false "dropGoalsSince" ((PVar "gctx") (PVar "mark") (PVar "kinds")) (EBlock (DoLet false false (PVar "g") (EFieldAccess (EVar "gctx") "graphRun")) (DoLet false false (PVar "now") (EFieldAccess (EFieldAccess (EVar "g") "goals") "value")) (DoLet false false (PVar "n") (EBinOp "-" (EFieldAccess (EFieldAccess (EVar "g") "goalsN") "value") (EVar "mark"))) (DoLet false false (PVar "tags") (EApp (EApp (EVar "map") (EVar "goalKindTag")) (EVar "kinds"))) (DoLet false false (PVar "kept") (EApp (EApp (EVar "filterList") (ELam ((PVar "o")) (EApp (EVar "not") (EApp (EApp (EVar "containsI") (EApp (EVar "goalKindTag") (EFieldAccess (EVar "o") "oKind"))) (EVar "tags"))))) (EApp (EApp (EVar "take") (EVar "n")) (EVar "now")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "goals")) (EBinOp "++" (EVar "kept") (EApp (EApp (EVar "drop") (EVar "n")) (EVar "now"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "goalsN")) (EBinOp "+" (EVar "mark") (EApp (EVar "listLen") (EVar "kept")))))))
(DTypeSig true "routeLocalSym" (TyFun (TyCon "Route") (TyCon "String")))
(DFunDef false "routeLocalSym" ((PCon "RLocal" (PVar "s") PWild)) (EVar "s"))
(DFunDef false "routeLocalSym" (PWild) (ELit (LString "")))
(DTypeSig false "methodReturnOrigin" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "GoalOrigin"))))
(DFunDef false "methodReturnOrigin" ((PVar "mctx") (PVar "loc")) (EBlock (DoLet false false (PVar "moduleId") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentModuleRef") "value")) (DoLet false false (PVar "binding") (EIf (EBinOp "==" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value") (ELit (LString ""))) (EVar "None") (EApp (EApp (EApp (EVar "mkIdent") (EVar "NsValue")) (EApp (EVar "OriginModule") (EVar "moduleId"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")))) (DoExpr (ERecordCreate "GoalOrigin" ((fa "location" (EVar "loc")) (fa "moduleId" (EVar "moduleId")) (fa "binding" (EVar "binding")))))))
(DTypeSig false "methodReturnInstantiation" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodReturnRequest") (TyApp (TyCon "Option") (TyCon "Instantiation")))))
(DFunDef false "methodReturnInstantiation" ((PVar "mctx") (PVar "request")) (EMatch (ETuple (EApp (EApp (EVar "methodReturnPredicate") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "request")) (EFieldAccess (EVar "request") "mrrGoalEv")) (arm (PTuple (PCon "Some" (PVar "predicate")) (PCon "Some" (PVar "destination"))) () (EApp (EVar "Some") (ERecordCreate "Instantiation" ((fa "body" (EFieldAccess (EVar "request") "mrrQualifiedBody")) (fa "force" (EVar "pureRow")) (fa "arguments" (EListLit (ERecordCreate "InstantiationArgument" ((fa "formal" (EApp (EApp (EVar "Scopes.binderAt") (EFieldAccess (EVar "request") "mrrScope")) (ELit (LInt 0)))) (fa "wanted" (ERecordCreate "Wanted" ((fa "id" (EApp (EVar "goalIdForDestination") (EVar "destination"))) (fa "predicate" (EVar "predicate")) (fa "origin" (EApp (EApp (EVar "methodReturnOrigin") (EVar "mctx")) (EFieldAccess (EVar "request") "mrrLoc"))) (fa "scope" (EFieldAccess (EVar "request") "mrrScope")) (fa "destination" (EVar "destination"))))))))))))) (arm PWild () (EVar "None"))))
(DTypeSig false "methodReturnPredicate" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "MethodReturnRequest") (TyApp (TyCon "Option") (TyCon "ClassPredicate")))))
(DFunDef false "methodReturnPredicate" ((PVar "gctx") (PVar "request")) (EApp (EApp (EApp (EApp (EApp (EVar "methodReturnPredicateFromTemplate") (EVar "gctx")) (EFieldAccess (EVar "request") "mrrPredicateTemplate")) (EFieldAccess (EVar "request") "mrrTyparams")) (EFieldAccess (EVar "request") "mrrOmitted")) (EFieldAccess (EVar "request") "mrrScope")))
(DTypeSig false "methodReturnPredicateFromTemplate" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "MethodPredicateTemplate") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "ScopeId") (TyApp (TyCon "Option") (TyCon "ClassPredicate"))))))))
(DFunDef false "methodReturnPredicateFromTemplate" ((PVar "gctx") (PVar "template") (PVar "typarams") (PVar "omitted") (PVar "scope")) (EMatch (EApp (EVar "methodPredicateTemplateArgs") (EFieldAccess (EVar "template") "mptArguments")) (arm (PCon "Some" (PVar "arguments")) () (EApp (EVar "Some") (ERecordCreate "ClassPredicate" ((fa "predicateInterface" (EFieldAccess (EVar "template") "mptInterface")) (fa "predicateArguments" (EVar "arguments")))))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EApp (EVar "uniqueMethodTemplateGiven") (EVar "gctx")) (EVar "template")) (EVar "scope")) (EApp (EApp (EVar "givensForScope") (EVar "gctx")) (EVar "scope"))) (arm (PCon "Some" (PVar "given")) () (EApp (EVar "Some") (ERecordCreate "ClassPredicate" ((fa "predicateInterface" (EFieldAccess (EVar "template") "mptInterface")) (fa "predicateArguments" (EApp (EVar "predicateSlotKnownArgs") (EFieldAccess (EFieldAccess (EVar "given") "geSlot") "psArgs"))))))) (arm (PCon "None") () (EApp (EApp (EVar "map") (ELam ((PVar "arguments")) (ERecordCreate "ClassPredicate" ((fa "predicateInterface" (EFieldAccess (EVar "template") "mptInterface")) (fa "predicateArguments" (EVar "arguments")))))) (EApp (EVar "methodPredicateTemplateArgs") (EApp (EApp (EApp (EVar "fillOmittedTemplateArgs") (EVar "typarams")) (EFieldAccess (EVar "template") "mptArguments")) (EVar "omitted")))))))))
(DTypeSig false "fillOmittedTemplateArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Mono")))))))
(DFunDef false "fillOmittedTemplateArgs" ((PCons (PVar "param") (PVar "params")) (PCons (PVar "argument") (PVar "arguments")) (PVar "omitted")) (EBinOp "::" (EApp (EApp (EVar "orElseOpt") (EVar "argument")) (EApp (EApp (EVar "lookupAssoc") (EVar "param")) (EVar "omitted"))) (EApp (EApp (EApp (EVar "fillOmittedTemplateArgs") (EVar "params")) (EVar "arguments")) (EVar "omitted"))))
(DFunDef false "fillOmittedTemplateArgs" (PWild (PVar "arguments") PWild) (EVar "arguments"))
(DTypeSig true "methodReturnArgs" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "MethodReturnRequest") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Mono"))))))
(DFunDef false "methodReturnArgs" ((PVar "gctx") (PVar "request")) (EApp (EApp (EVar "map") (ELam ((PVar "predicate")) (EFieldAccess (EVar "predicate") "predicateArguments"))) (EApp (EApp (EVar "methodReturnPredicate") (EVar "gctx")) (EVar "request"))))
(DTypeSig true "methodReturnWanted" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodReturnRequest") (TyApp (TyCon "Option") (TyCon "Wanted")))))
(DFunDef false "methodReturnWanted" ((PVar "mctx") (PVar "request")) (EMatch (EApp (EApp (EVar "methodReturnInstantiation") (EVar "mctx")) (EVar "request")) (arm (PCon "Some" (PRec "Instantiation" ((rf "arguments" (PList (PVar "argument")))) true)) () (EApp (EVar "Some") (EFieldAccess (EVar "argument") "wanted"))) (arm PWild () (EVar "None"))))
(DTypeSig true "ifaceRefBare" (TyFun (TyCon "String") (TyCon "IfaceRef")))
(DFunDef false "ifaceRefBare" ((PVar "n")) (ERecordCreate "IfaceRef" ((fa "irName" (EVar "n")) (fa "irOrigin" (EVar "OriginUnresolved")))))
(DTypeSig true "ifaceRefNone" (TyCon "IfaceRef"))
(DFunDef false "ifaceRefNone" () (ERecordCreate "IfaceRef" ((fa "irName" (ELit (LString ""))) (fa "irOrigin" (EVar "OriginUnresolved")))))
(DTypeSig true "uOblArgs" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "UObligation") (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "uOblArgs" ((PVar "gctx") (PVar "o")) (EMatch (EFieldAccess (EVar "o") "oblProj") (arm (PCon "OpProjected") () (EFieldAccess (EFieldAccess (EVar "o") "pred") "args")) (arm (PCon "OpMethodOcc" (PVar "typarams") (PVar "mty") (PVar "occ") (PVar "omitted")) () (EApp (EApp (EApp (EApp (EVar "occurrenceDispatchMonos") (EVar "typarams")) (EVar "mty")) (EVar "occ")) (EVar "omitted"))) (arm (PCon "OpExactReturn" (PVar "request")) () (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "methodReturnArgs") (EVar "gctx")) (EVar "request")))) (arm (PCon "OpNumLit" PWild) () (EFieldAccess (EFieldAccess (EVar "o") "pred") "args"))))
(DTypeSig true "consSiteFn" (TyFun (TyCon "String") (TyFun (TyVar "a") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyVar "a"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "consSiteFn" ((PVar "fn") (PVar "x") (PVar "idx")) (EApp (EApp (EApp (EVar "omInsert") (EVar "fn")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "sitesFor") (EVar "fn")) (EVar "idx")))) (EVar "idx")))
(DTypeSig true "sitesFor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyVar "a"))) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "sitesFor" ((PVar "fn") (PVar "idx")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "fn")) (EVar "idx"))))
(DTypeSig false "sameTraceEvId" (TyFun (TyCon "EvId") (TyFun (TyCon "EvId") (TyCon "Bool"))))
(DFunDef false "sameTraceEvId" ((PCon "EvId" (PVar "moduleA") (PVar "ordinalA")) (PCon "EvId" (PVar "moduleB") (PVar "ordinalB"))) (EBinOp "&&" (EBinOp "==" (EVar "moduleA") (EVar "moduleB")) (EBinOp "==" (EVar "ordinalA") (EVar "ordinalB"))))
(DTypeSig true "noteMethodReturnTrace" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodReturnTraceStage") (TyFun (TyCon "MethodReturnRequest") (TyFun (TyApp (TyCon "Option") (TyCon "Route")) (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyCon "Unit")))))))
(DFunDef false "noteMethodReturnTrace" ((PVar "mctx") (PVar "stage") (PVar "request") (PVar "route") (PVar "prerequisites")) (EMatch (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "trace") (arm (PCon "Some" (PVar "sink")) () (EIf (EFieldAccess (EVar "sink") "tsMethodReturnEnabled") (EBlock (DoLet false false (PTuple (PVar "qualifiedBody") (PVar "wanted")) (EMatch (EApp (EApp (EVar "methodReturnInstantiation") (EVar "mctx")) (EVar "request")) (arm (PCon "Some" (PRec "Instantiation" ((rf "body" (PVar "body")) (rf "arguments" (PList (PRec "InstantiationArgument" ((rf "wanted" (PVar "carried"))) true)))) true)) () (ETuple (EApp (EVar "Some") (EVar "body")) (EApp (EVar "Some") (EVar "carried")))) (arm PWild () (ETuple (EVar "None") (EVar "None"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "sink") "tsMethodReturnEntries")) (EBinOp "::" (ERecordCreate "MethodReturnTraceEntry" ((fa "mrtStage" (EVar "stage")) (fa "mrtInterface" (EFieldAccess (EVar "request") "mrrIface")) (fa "mrtMethod" (EFieldAccess (EVar "request") "mrrName")) (fa "mrtArguments" (EApp (EApp (EVar "methodReturnArgs") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "request"))) (fa "mrtScope" (EFieldAccess (EVar "request") "mrrScope")) (fa "mrtOrigin" (EFieldAccess (EVar "request") "mrrLoc")) (fa "mrtGoal" (EFieldAccess (EVar "request") "mrrGoalEv")) (fa "mrtPublished" (EVar "None")) (fa "mrtQualifiedBody" (EVar "qualifiedBody")) (fa "mrtWanted" (EVar "wanted")) (fa "mrtOutcome" (EApp (EApp (EVar "map") (ELam ((PVar "resolution")) (EFieldAccess (EVar "resolution") "mrrOutcome"))) (EFieldAccess (EFieldAccess (EVar "request") "mrrResolution") "value"))) (fa "mrtRoute" (EVar "route")) (fa "mrtPrerequisites" (EVar "prerequisites")))) (EFieldAccess (EFieldAccess (EVar "sink") "tsMethodReturnEntries") "value"))))) (ELit LUnit))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig true "goalKindName" (TyFun (TyCon "GoalKind") (TyCon "String")))
(DFunDef false "goalKindName" ((PCon "GKReturnSite")) (ELit (LString "GKReturnSite")))
(DFunDef false "goalKindName" ((PCon "GKArgStamp")) (ELit (LString "GKArgStamp")))
(DFunDef false "goalKindName" ((PCon "GKRLocalSite")) (ELit (LString "GKRLocalSite")))
(DFunDef false "goalKindName" ((PCon "GKBinopSite")) (ELit (LString "GKBinopSite")))
(DFunDef false "goalKindName" ((PCon "GKUnopSite")) (ELit (LString "GKUnopSite")))
(DFunDef false "goalKindName" ((PCon "GKArithSite")) (ELit (LString "GKArithSite")))
(DFunDef false "goalKindName" ((PCon "GKDictApp")) (ELit (LString "GKDictApp")))
(DFunDef false "goalKindName" ((PCon "GKMethodDict")) (ELit (LString "GKMethodDict")))
(DFunDef false "goalKindName" ((PCon "GKRecDictApp")) (ELit (LString "GKRecDictApp")))
(DTypeSig true "openScope" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ScopeId") (TyCon "Unit"))))
(DFunDef false "openScope" ((PVar "mctx") (PVar "sid")) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentScope")) (EApp (EVar "Scopes.openScopeCursor") (EVar "sid"))))
(DTypeSig true "currentModuleMarks" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyCon "GraphMarks"))))
(DFunDef false "currentModuleMarks" ((PVar "gctx") PWild) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "moduleRanges") "value") (arm (PCons (PTuple PWild (PVar "m")) PWild) () (EVar "m")) (arm (PList) () (ERecordCreate "GraphMarks" ((fa "mGoals" (ELit (LInt 0))) (fa "mNumlit" (ELit (LInt 0))))))))
(DTypeSig true "walkGoalDischarged" (TyFun (TyCon "ReqWalk") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool")))))
(DFunDef false "walkGoalDischarged" ((PVar "walk") (PVar "iface") (PVar "args")) (EBlock (DoLet false false (PVar "memo") (EApp (EVar "reqWalkMemo") (EVar "walk"))) (DoExpr (EApp (EApp (EVar "anyListM") (ELam ((PTuple (PVar "otherIface") (PVar "otherArgs"))) (EBinOp "&&" (EApp (EApp (EVar "sameIfaceDecl") (EVar "otherIface")) (EVar "iface")) (EApp (EApp (EVar "monoVecSameGiven") (EVar "otherArgs")) (EVar "args"))))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EApp (EVar "enteredGoalKey") (EVar "walk"))) (EFieldAccess (EFieldAccess (EVar "memo") "wmDischarged") "value")))))))
(DTypeSig true "noteWalkGoalDischarged" (TyFun (TyCon "ReqWalk") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Unit")))))
(DFunDef false "noteWalkGoalDischarged" ((PVar "walk") (PVar "iface") (PVar "args")) (EBlock (DoLet false false (PVar "memo") (EApp (EVar "reqWalkMemo") (EVar "walk"))) (DoLet false false (PVar "key") (EApp (EVar "enteredGoalKey") (EVar "walk"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "memo") "wmDischarged")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "::" (ETuple (EVar "iface") (EVar "args")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EFieldAccess (EVar "memo") "wmDischarged") "value"))))) (EFieldAccess (EFieldAccess (EVar "memo") "wmDischarged") "value"))))))
(DTypeSig true "solvedOnWalk" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ReqWalk") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyFun (TyCon "Unit") (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))))) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))))))))))
(DFunDef false "solvedOnWalk" ((PVar "mctx") (PVar "walk") (PVar "iface") (PVar "args") (PVar "solve")) (EBlock (DoLet false false (PVar "memo") (EApp (EVar "reqWalkMemo") (EVar "walk"))) (DoLet false false (PVar "key") (EApp (EVar "enteredGoalKey") (EVar "walk"))) (DoLet false false (PVar "entries") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EFieldAccess (EVar "memo") "wmSolved") "value")))) (DoExpr (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EApp (EApp (EApp (EVar "walkGoalSame") (EFieldAccess (EVar "e") "sgeIface")) (EFieldAccess (EVar "e") "sgeGoals")) (EVar "iface")) (EVar "args")))) (EVar "entries")) (arm (PCons (PVar "entry") PWild) () (EFieldAccess (EVar "entry") "sgeResiduals")) (arm (PList) () (EBlock (DoLet false false (PTuple (PVar "clean") (PVar "found")) (EApp (EApp (EApp (EVar "solvedCleanly") (EVar "mctx")) (ELam ((PVar "goals")) (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "goals")))) (EVar "solve"))) (DoLet false false (PVar "residuals") (EApp (EVar "dedupWalkGoals") (EVar "found"))) (DoExpr (EIf (EVar "clean") (EBlock (DoLet false false (PVar "entry") (ERecordCreate "SolvedGoalEntry" ((fa "sgeIface" (EVar "iface")) (fa "sgeGoals" (EVar "args")) (fa "sgeResiduals" (EVar "residuals"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "memo") "wmSolved")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "::" (EVar "entry") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EFieldAccess (EVar "memo") "wmSolved") "value"))))) (EFieldAccess (EFieldAccess (EVar "memo") "wmSolved") "value"))))) (ELit LUnit))) (DoExpr (EVar "residuals"))))))))
(DTypeSig true "solvedCleanly" (TyFun (TyCon "ModuleCtx") (TyFun (TyFun (TyVar "a") (TyApp (TyCon "List") (TyCon "Mono"))) (TyFun (TyFun (TyCon "Unit") (TyVar "a")) (TyTuple (TyCon "Bool") (TyVar "a"))))))
(DFunDef false "solvedCleanly" ((PVar "mctx") (PVar "monosOf") (PVar "act")) (EBlock (DoLet false false (PVar "tyvars") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "tyvarCounter") "value")) (DoLet false false (PVar "effvars") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "effvarCounter") "value")) (DoLet false false (PTuple (PVar "erred") (PVar "result")) (EApp (EApp (EVar "erredDuring") (EVar "mctx")) (EVar "act"))) (DoExpr (ETuple (EBinOp "&&" (EApp (EVar "not") (EVar "erred")) (EApp (EApp (EVar "allList") (EApp (EApp (EVar "monoMintedBefore") (EVar "tyvars")) (EVar "effvars"))) (EApp (EVar "monosOf") (EVar "result")))) (EVar "result")))))
(DTypeSig false "dedupWalkGoals" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")))) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))))))
(DFunDef false "dedupWalkGoals" ((PVar "goals")) (EApp (EApp (EApp (EVar "dedupWalkGoalsGo") (EVar "goals")) (EVar "omEmpty")) (EListLit)))
(DTypeSig false "dedupWalkGoalsGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")))) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))))))))
(DFunDef false "dedupWalkGoalsGo" ((PList) PWild (PVar "acc")) (EApp (EVar "reverse") (EVar "acc")))
(DFunDef false "dedupWalkGoalsGo" ((PCons (PTuple (PVar "iface") (PVar "args")) (PVar "rest")) (PVar "seen") (PVar "acc")) (EBlock (DoLet false false (PVar "key") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "iface") "irName"))) (ELit (LString "#"))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "monoSizes") (EVar "args"))))) (ELit (LString "")))) (DoLet false false (PVar "bucket") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "seen")))) (DoExpr (EIf (EApp (EApp (EVar "anyListM") (ELam ((PVar "g")) (EApp (EApp (EApp (EApp (EVar "walkGoalSame") (EApp (EVar "fst") (EVar "g"))) (EApp (EVar "snd") (EVar "g"))) (EVar "iface")) (EVar "args")))) (EVar "bucket")) (EApp (EApp (EApp (EVar "dedupWalkGoalsGo") (EVar "rest")) (EVar "seen")) (EVar "acc")) (EApp (EApp (EApp (EVar "dedupWalkGoalsGo") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "::" (ETuple (EVar "iface") (EVar "args")) (EVar "bucket"))) (EVar "seen"))) (EBinOp "::" (ETuple (EVar "iface") (EVar "args")) (EVar "acc")))))))
(DTypeSig true "walkGoalFollowed" (TyFun (TyCon "ReqWalk") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool")))))
(DFunDef false "walkGoalFollowed" ((PVar "walk") (PVar "iface") (PVar "args")) (EBlock (DoLet false false (PVar "memo") (EApp (EVar "reqWalkMemo") (EVar "walk"))) (DoExpr (EApp (EApp (EVar "anyListM") (ELam ((PTuple (PVar "otherIface") (PVar "otherArgs"))) (EApp (EApp (EApp (EApp (EVar "walkGoalSame") (EVar "otherIface")) (EVar "otherArgs")) (EVar "iface")) (EVar "args")))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EApp (EVar "enteredGoalKey") (EVar "walk"))) (EFieldAccess (EFieldAccess (EVar "memo") "wmFollowed") "value")))))))
(DTypeSig true "noteWalkGoalFollowed" (TyFun (TyCon "ReqWalk") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Unit")))))
(DFunDef false "noteWalkGoalFollowed" ((PVar "walk") (PVar "iface") (PVar "args")) (EBlock (DoLet false false (PVar "memo") (EApp (EVar "reqWalkMemo") (EVar "walk"))) (DoLet false false (PVar "key") (EApp (EVar "enteredGoalKey") (EVar "walk"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "memo") "wmFollowed")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "::" (ETuple (EVar "iface") (EVar "args")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EFieldAccess (EVar "memo") "wmFollowed") "value"))))) (EFieldAccess (EFieldAccess (EVar "memo") "wmFollowed") "value"))))))
(DTypeSig false "walkGoalSame" (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))))
(DFunDef false "walkGoalSame" ((PVar "iface") (PVar "args") (PVar "otherIface") (PVar "otherArgs")) (EBinOp "&&" (EApp (EApp (EVar "sameIfaceDecl") (EVar "iface")) (EVar "otherIface")) (EApp (EApp (EVar "walkMonosSame") (EVar "args")) (EVar "otherArgs"))))
(DTypeSig true "isLocalAbsName" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isLocalAbsName" ((PVar "n")) (EApp (EApp (EVar "endsWith") (ELit (LString "$lb"))) (EVar "n")))
(DTypeSig true "localSourceName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "localSourceName" ((PVar "name")) (EIf (EApp (EVar "isLocalAbsName") (EVar "name")) (EMatch (EApp (EApp (EVar "splitOnChar") (ELit (LChar "$"))) (EVar "name")) (arm (PCons (PVar "first") PWild) () (EVar "first")) (arm (PList) () (EVar "name"))) (EIf (EVar "otherwise") (EVar "name") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "pushLocalDictApp" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyFun (TyCon "LocalAbs") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyFun (TyCon "ScopeId") (TyCon "Unit"))))))))
(DFunDef false "pushLocalDictApp" ((PVar "mctx") (PVar "name") (PVar "ev") (PVar "la") (PVar "subst") (PVar "useScope")) (EBlock (DoLet false false (PVar "monos") (EApp (EApp (EVar "map") (EApp (EApp (EVar "localSlotLead") (EVar "mctx")) (EVar "subst"))) (EFieldAccess (EVar "la") "laSlots"))) (DoExpr (EApp (EApp (EVar "pushDictApp") (EFieldAccess (EVar "mctx") "mcGraph")) (ERecordCreate "PendingDictApp" ((fa "pdaRoutesRef" (EApp (EVar "Ref") (EListLit))) (fa "pdaEv" (EVar "ev")) (fa "pdaMonos" (EVar "monos")) (fa "pdaIfaces" (EApp (EApp (EVar "map") (ELam ((PVar "s")) (EFieldAccess (EVar "s") "psIface"))) (EFieldAccess (EVar "la") "laSlots"))) (fa "pdaArgVecs" (EApp (EApp (EVar "map") (EApp (EApp (EVar "localSlotArgs") (EVar "mctx")) (EVar "subst"))) (EFieldAccess (EVar "la") "laSlots"))) (fa "pdaEncl" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (fa "pdaLoc" (EFieldAccess (EVar "mctx") "mcLoc")) (fa "pdaScope" (EVar "useScope")) (fa "pdaCallee" (EApp (EVar "localSourceName") (EVar "name"))))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dictAppFns")) (EApp (EApp (EApp (EVar "consSiteFn") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (EVar "monos")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dictAppFns") "value"))))))
(DTypeSig false "localSlotArgs" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyFun (TyCon "PredicateSlot") (TyApp (TyCon "List") (TyCon "Mono"))))))
(DFunDef false "localSlotArgs" ((PVar "mctx") (PVar "subst") (PVar "slot")) (EMatch (EFieldAccess (EVar "slot") "psArgs") (arm (PCon "PSArgsKnown" (PVar "args")) () (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EVar "substMono") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "subst")) (EListLit)) (EListLit))) (EVar "args"))) (arm (PCon "PSArgsUnknown") () (EListLit (EApp (EApp (EApp (EVar "localSlotLead") (EVar "mctx")) (EVar "subst")) (EVar "slot"))))))
(DTypeSig false "localSlotLead" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyFun (TyCon "PredicateSlot") (TyCon "Mono")))))
(DFunDef false "localSlotLead" ((PVar "mctx") (PVar "subst") (PVar "slot")) (EMatch (EFieldAccess (EVar "slot") "psArgs") (arm (PCon "PSArgsKnown" (PCons (PVar "a") PWild)) () (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "subst")) (EListLit)) (EListLit)) (EVar "a"))) (arm PWild () (EMatch (EFieldAccess (EVar "slot") "psBoundIds") (arm (PCons (PVar "id") PWild) () (EApp (EApp (EVar "optionOrElse") (ELam (PWild) (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit)))) (EApp (EApp (EVar "lookupAssocI") (EVar "id")) (EVar "subst")))) (arm (PList) () (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit)))))))
(DTypeSig true "builtinClassPresent" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "BuiltinClass") (TyCon "Bool"))))
(DFunDef false "builtinClassPresent" ((PVar "gctx") (PCon "BNum")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "builtinClassesRef") "value") "bcNumPresent"))
(DFunDef false "builtinClassPresent" ((PVar "gctx") (PCon "BEq")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "builtinClassesRef") "value") "bcEqPresent"))
(DFunDef false "builtinClassPresent" ((PVar "gctx") (PCon "BOrd")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "builtinClassesRef") "value") "bcOrdPresent"))
(DFunDef false "builtinClassPresent" ((PVar "gctx") (PCon "BSemigroup")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "builtinClassesRef") "value") "bcSemigroupPresent"))
(DTypeSig true "admittedSelection" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "ImplEnv") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyCon "AdmittedAnswer"))))))
(DFunDef false "admittedSelection" ((PVar "sx") (PVar "env") (PVar "name") (PVar "mono")) (EBlock (DoLet false false (PVar "visible") (EApp (EApp (EVar "methodVisibleHere") (EFieldAccess (EVar "sx") "sxModule")) (EVar "name"))) (DoLet false false (PVar "answers") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EVar "admittedDeclAnswer") (EVar "sx")) (EVar "env")) (EVar "visible")) (EVar "mono"))) (EApp (EApp (EVar "methodAdmittedHere") (EFieldAccess (EVar "sx") "sxModule")) (EVar "name")))) (DoExpr (EIf (EApp (EApp (EVar "anyList") (EVar "isUndecided")) (EVar "answers")) (EVar "Undecided") (EMatch (EApp (EApp (EVar "filterList") (EVar "isSelection")) (EVar "answers")) (arm (PList) () (EVar "SelectsNothing")) (arm (PList (PVar "one")) () (EApp (EApp (EApp (EVar "routableSelection") (EFieldAccess (EVar "sx") "sxModule")) (EVar "name")) (EVar "one"))) (arm PWild () (EVar "Undecided")))))))
(DTypeSig false "routableSelection" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "AdmittedAnswer") (TyCon "AdmittedAnswer")))))
(DFunDef false "routableSelection" ((PVar "mctx") (PVar "name") (PAs "answer" (PCon "Selects" (PVar "iface") PWild PWild))) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "methodSlotKey") (EVar "iface")) (EApp (EApp (EVar "originMethodName") (EVar "mctx")) (EVar "name")))) (DoExpr (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodPredicateSlotsRef") "value")) (arm (PCon "Some" (PCons PWild PWild)) () (EApp (EVar "Unroutable") (EVar "iface"))) (arm PWild () (EVar "answer"))))))
(DFunDef false "routableSelection" ((PVar "mctx") PWild (PVar "answer")) (EVar "answer"))
(DTypeSig false "admittedDeclAnswer" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "ImplEnv") (TyFun (TyApp (TyCon "List") (TyCon "MethodRow")) (TyFun (TyCon "Mono") (TyFun (TyCon "IfaceRef") (TyCon "AdmittedAnswer")))))))
(DFunDef false "admittedDeclAnswer" ((PVar "sx") (PVar "env") (PVar "visible") (PVar "mono") (PVar "ir")) (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EVar "ieRowIfaceMatches") (EApp (EVar "methodRowIface") (EVar "r"))) (EVar "ir")))) (EVar "visible")) (arm (PCons (PVar "r") PWild) () (EMatch (EFieldAccess (EVar "r") "mrEntry") (arm (PTuple (PVar "iface") (PVar "typarams") (PVar "mty") PWild) () (EMatch (EApp (EApp (EVar "matchTyMono") (EVar "mty")) (EVar "mono")) (arm (PCon "Some" (PVar "subst")) () (EBlock (DoLet false false (PVar "goals") (EApp (EApp (EVar "map") (EApp (EVar "paramMonoOf") (EVar "subst"))) (EVar "typarams"))) (DoExpr (EMatch (EApp (EVar "goalHeadCon") (EVar "goals")) (arm (PCon "None") () (EVar "Undecided")) (arm (PCon "Some" PWild) () (EMatch (EApp (EApp (EApp (EApp (EVar "ieSelectRowByIface") (EVar "sx")) (EVar "env")) (EVar "iface")) (EVar "goals")) (arm (PCon "Some" (PVar "row")) () (EApp (EApp (EApp (EVar "Selects") (EVar "iface")) (EVar "row")) (EVar "goals"))) (arm (PCon "None") () (EVar "SelectsNothing")))))))) (arm (PCon "None") () (EVar "Undecided")))))) (arm (PList) () (EVar "Undecided"))))
(DTypeSig false "isUndecided" (TyFun (TyCon "AdmittedAnswer") (TyCon "Bool")))
(DFunDef false "isUndecided" ((PCon "Undecided")) (EVar "True"))
(DFunDef false "isUndecided" (PWild) (EVar "False"))
(DTypeSig false "isSelection" (TyFun (TyCon "AdmittedAnswer") (TyCon "Bool")))
(DFunDef false "isSelection" ((PCon "Selects" PWild PWild PWild)) (EVar "True"))
(DFunDef false "isSelection" (PWild) (EVar "False"))
(DTypeSig true "outerRigidIds" (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "outerRigidIds" ((PVar "outerBelow") (PVar "args") (PVar "base")) (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (EVar "intToString")) (EApp (EApp (EVar "enclosingVarIds") (EVar "outerBelow")) (EVar "args")))) (EVar "base")))
(DTypeSig true "enclosingVarIds" (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "enclosingVarIds" ((PCon "None") PWild) (EListLit))
(DFunDef false "enclosingVarIds" ((PCon "Some" (PVar "level")) (PVar "args")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EVar "filterList") (ELam ((PVar "p")) (EBinOp "<" (EApp (EVar "snd") (EVar "p")) (EVar "level")))) (EApp (EApp (EVar "flatMap") (EVar "monoUnboundVarLevels")) (EVar "args")))))
(DTypeSig true "improveLocalGoals" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyFun (TyCon "Int") (TyCon "Unit")))))
(DFunDef false "improveLocalGoals" ((PVar "dyn") (PVar "addedObls") (PVar "callN0")) (EBlock (DoLet false false (PVar "goals") (EBinOp "++" (EVar "addedObls") (EApp (EApp (EVar "callUOblsWindow") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "callN0")))) (DoLet false false (PVar "outer") (EApp (EApp (EApp (EVar "outerRigidIds") (EApp (EVar "Some") (EBinOp "+" (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "currentLevel") "value") (ELit (LInt 1))))) (EApp (EApp (EVar "flatMap") (EApp (EVar "uOblArgs") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph"))) (EVar "goals"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EApp (EVar "improveByUniqueImpl") (EVar "dyn")) (EVar "outer")) (EVar "goals")))))
(DTypeSig true "returnPosMethodNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "returnPosMethodNames" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "returnPosOfDecl")) (EVar "prog")))
(DTypeSig false "returnPosOfDecl" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "returnPosOfDecl" ((PRec "DInterface" ((rf "typarams" None) (rf "methods" None)) true)) (EApp (EApp (EVar "flatMap") (EApp (EVar "returnPosMethod") (EVar "typarams"))) (EVar "methods")))
(DFunDef false "returnPosOfDecl" (PWild) (EListLit))
(DTypeSig false "returnPosMethod" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "returnPosMethod" ((PVar "typarams") (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild PWild)) (EIf (EApp (EVar "not") (EApp (EApp (EVar "anyArgMentions") (EApp (EVar "dispatchTyparams") (EVar "typarams"))) (EApp (EVar "methodArgs") (EVar "mty")))) (EListLit (EVar "mname")) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "exactReturnRoutes" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "Bool") (TyFun (TyCon "MethodReturnResolution") (TyTuple (TyCon "Route") (TyApp (TyCon "List") (TyCon "Route"))))))))))
(DFunDef false "exactReturnRoutes" ((PVar "sx") (PVar "name") (PVar "encl") (PVar "scope") (PVar "isReturnPosition") (PVar "resolution")) (EMatch (ETuple (EFieldAccess (EVar "resolution") "mrrOutcome") (EFieldAccess (EVar "resolution") "mrrSelectedRow")) (arm (PTuple (PCon "Solved" (PCon "GivenEvidence" (PVar "binder"))) (PCon "None")) () (ETuple (EApp (EApp (EApp (EVar "givenRoute") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "isReturnPosition")) (EVar "binder")) (EListLit))) (arm (PTuple (PCon "Solved" (PCon "SuperclassEvidence" (PVar "parent") (PVar "path"))) (PCon "None")) () (ETuple (EApp (EApp (EVar "RProj") (EApp (EApp (EApp (EVar "givenRoute") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "isReturnPosition")) (EVar "parent"))) (EVar "path")) (EListLit))) (arm (PTuple (PCon "Solved" (PCon "InstanceEvidence" PWild (PVar "args") (PVar "prerequisites") PWild)) (PCon "Some" (PVar "row"))) () (ETuple (EApp (EApp (EApp (EVar "RKey") (EApp (EVar "rowRouteKey") (EVar "row"))) (EListLit)) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "selectedCallSupers") (EVar "sx")) (EVar "name")) (EApp (EVar "Some") (EVar "row"))) (EVar "encl")) (EVar "scope")) (EVar "args"))) (EApp (EApp (EApp (EApp (EVar "methodReturnEvidenceRoutes") (EVar "sx")) (EVar "encl")) (EVar "scope")) (EVar "prerequisites")))) (arm (PTuple (PCon "Deferred" PWild PWild) (PCon "None")) () (ETuple (EVar "RNone") (EListLit))) (arm (PTuple (PCon "Insoluble" PWild PWild) (PCon "None")) () (ETuple (EVar "RNone") (EListLit))) (arm PWild () (EApp (EVar "panic") (ELit (LString "ordinary return outcome and selected row disagree"))))))
(DTypeSig false "methodReturnEvidenceRoutes" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyCon "PrerequisiteEvidence")) (TyApp (TyCon "List") (TyCon "Route")))))))
(DFunDef false "methodReturnEvidenceRoutes" ((PVar "sx") (PVar "encl") (PVar "scope") (PVar "prerequisites")) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "methodReturnEvidenceRoute") (EVar "sx")) (EVar "encl")) (EVar "scope"))) (EVar "prerequisites")))
(DTypeSig false "methodReturnEvidenceRoute" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "PrerequisiteEvidence") (TyCon "Route"))))))
(DFunDef false "methodReturnEvidenceRoute" ((PVar "sx") (PVar "encl") (PVar "scope") (PVar "prerequisite")) (EMatch (EFieldAccess (EVar "prerequisite") "prerequisiteArguments") (arm (PCons (PVar "first") (PVar "more")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeOfD") (EVar "sx")) (EFieldAccess (EVar "prerequisite") "prerequisiteInterface")) (EVar "encl")) (EVar "scope")) (EVar "KeepNone")) (EVar "first")) (EVar "more")) (EApp (EVar "reqWalkStart") (ELit LUnit)))) (arm (PList) () (EVar "RNone"))))
(DTypeSig true "numericReturnRoute" (TyFun (TyCon "Route") (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyCon "Route"))))
(DFunDef false "numericReturnRoute" ((PCon "RKey" (PVar "key") PWild (PVar "sups")) (PVar "routes")) (EApp (EApp (EApp (EVar "RKey") (EVar "key")) (EVar "routes")) (EVar "sups")))
(DFunDef false "numericReturnRoute" ((PVar "route") PWild) (EVar "route"))
(DTypeSig true "predicateSlotKnownArgs" (TyFun (TyCon "PredicateSlotArgs") (TyApp (TyCon "List") (TyCon "Mono"))))
(DFunDef false "predicateSlotKnownArgs" ((PCon "PSArgsUnknown")) (EListLit))
(DFunDef false "predicateSlotKnownArgs" ((PCon "PSArgsKnown" (PVar "args"))) (EVar "args"))
(DTypeSig false "methodPredicateTemplateArgs" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "methodPredicateTemplateArgs" ((PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "methodPredicateTemplateArgs" ((PCons (PCon "Some" (PVar "argument")) (PVar "rest"))) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "argument") (EVar "_s")))) (EApp (EVar "methodPredicateTemplateArgs") (EVar "rest"))))
(DFunDef false "methodPredicateTemplateArgs" ((PCons (PCon "None") PWild)) (EVar "None"))
(DTypeSig false "uniqueMethodTemplateGiven" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "MethodPredicateTemplate") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyCon "GivenEntry")) (TyApp (TyCon "Option") (TyCon "GivenEntry")))))))
(DFunDef false "uniqueMethodTemplateGiven" ((PVar "gctx") (PVar "template") (PVar "useScope") (PVar "givens")) (EBlock (DoLet false false (PVar "chain") (EApp (EApp (EVar "Scopes.visibleChain") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))) (EVar "useScope"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "methodTemplateGivenScan") (EVar "template")) (EVar "chain")) (EVar "givens")) (EVar "MethodTemplateGivenNone")) (arm (PCon "MethodTemplateGivenOne" (PVar "given")) () (EApp (EVar "Some") (EVar "given"))) (arm PWild () (EVar "None"))))))
(DTypeSig false "methodTemplateGivenScan" (TyFun (TyCon "MethodPredicateTemplate") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "GivenEntry")) (TyFun (TyCon "MethodTemplateGivenResult") (TyCon "MethodTemplateGivenResult"))))))
(DFunDef false "methodTemplateGivenScan" (PWild PWild (PList) (PVar "result")) (EVar "result"))
(DFunDef false "methodTemplateGivenScan" ((PVar "template") (PVar "chain") (PCons (PVar "given") (PVar "rest")) (PVar "result")) (EBlock (DoLet false false (PVar "result2") (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "givenInScope") (EVar "GSPredicateOnly")) (EVar "given")) (EApp (EApp (EVar "Scopes.visibleOnChain") (EVar "chain")) (EApp (EVar "Scopes.binderScope") (EFieldAccess (EVar "given") "geBinder")))) (EApp (EApp (EVar "methodPredicateTemplateMatchesSlot") (EVar "template")) (EFieldAccess (EVar "given") "geSlot"))) (EMatch (EVar "result") (arm (PCon "MethodTemplateGivenNone") () (EApp (EVar "MethodTemplateGivenOne") (EVar "given"))) (arm PWild () (EVar "MethodTemplateGivenMany"))) (EVar "result"))) (DoExpr (EMatch (EVar "result2") (arm (PCon "MethodTemplateGivenMany") () (EVar "MethodTemplateGivenMany")) (arm PWild () (EApp (EApp (EApp (EApp (EVar "methodTemplateGivenScan") (EVar "template")) (EVar "chain")) (EVar "rest")) (EVar "result2")))))))
(DTypeSig false "methodPredicateTemplateMatchesSlot" (TyFun (TyCon "MethodPredicateTemplate") (TyFun (TyCon "PredicateSlot") (TyCon "Bool"))))
(DFunDef false "methodPredicateTemplateMatchesSlot" ((PVar "template") (PVar "slot")) (EBinOp "&&" (EApp (EApp (EVar "sameIfaceDecl") (EFieldAccess (EVar "template") "mptInterface")) (EFieldAccess (EVar "slot") "psIface")) (EMatch (EFieldAccess (EVar "slot") "psArgs") (arm (PCon "PSArgsUnknown") () (EVar "False")) (arm (PCon "PSArgsKnown" (PVar "arguments")) () (EApp (EApp (EVar "methodPredicateTemplateArgumentsMatch") (EFieldAccess (EVar "template") "mptArguments")) (EVar "arguments"))))))
(DTypeSig false "methodPredicateTemplateArgumentsMatch" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))
(DFunDef false "methodPredicateTemplateArgumentsMatch" ((PList) (PList)) (EVar "True"))
(DFunDef false "methodPredicateTemplateArgumentsMatch" ((PCons (PCon "Some" (PVar "expected")) (PVar "rest")) (PCons (PVar "actual") (PVar "arguments"))) (EBinOp "&&" (EApp (EApp (EVar "monoSameGiven") (EVar "expected")) (EVar "actual")) (EApp (EApp (EVar "methodPredicateTemplateArgumentsMatch") (EVar "rest")) (EVar "arguments"))))
(DFunDef false "methodPredicateTemplateArgumentsMatch" ((PCons (PCon "None") (PVar "rest")) (PCons PWild (PVar "arguments"))) (EApp (EApp (EVar "methodPredicateTemplateArgumentsMatch") (EVar "rest")) (EVar "arguments")))
(DFunDef false "methodPredicateTemplateArgumentsMatch" (PWild PWild) (EVar "False"))
(DTypeSig true "rigidHeadInstanceContext" (TyFun (TyCon "SiteCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))))))))))
(DFunDef false "rigidHeadInstanceContext" ((PVar "sx") (PVar "headIds") (PVar "iface") (PVar "args")) (EBlock (DoLet false false (PVar "cells") (EApp (EApp (EVar "sigCellsOf") (EVar "headIds")) (EApp (EApp (EVar "flatMap") (EVar "monoVarCells")) (EVar "args")))) (DoLet false false (PVar "toRigid") (EApp (EApp (EVar "sigRigidBindings") (EVar "headIds")) (EVar "cells"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EApp (EApp (EVar "map") (ELam ((PVar "r")) (EMatch (EApp (EApp (EApp (EVar "reqToObligation") (EFieldAccess (EVar "sx") "sxModule")) (EApp (EVar "fst") (EVar "m"))) (EVar "r")) (arm (PTuple (PVar "ri") (PVar "rargs")) () (ETuple (EVar "ri") (EApp (EApp (EVar "map") (EApp (EVar "unrigidSig") (EVar "cells"))) (EVar "rargs"))))))) (EApp (EVar "snd") (EVar "m"))))) (EApp (EApp (EApp (EApp (EVar "findMatchingImplReqsU") (EVar "sx")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "residualUnivRef") "value")) (EVar "iface")) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EVar "substMono") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "toRigid")) (EListLit)) (EListLit))) (EVar "args")))))))
(DTypeSig false "routeOf" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "Undetermined") (TyFun (TyCon "Mono") (TyCon "Route"))))))))
(DFunDef false "routeOf" ((PVar "sx") (PVar "iface") (PVar "encl") (PVar "useScope") (PVar "policy") (PVar "m")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeOfD") (EVar "sx")) (EVar "iface")) (EVar "encl")) (EVar "useScope")) (EVar "policy")) (EVar "m")) (EListLit)) (EApp (EVar "reqWalkStart") (ELit LUnit))))
(DTypeSig true "routesOfMonosTopV" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "IfaceRef")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "Route")))))))))
(DFunDef false "routesOfMonosTopV" ((PVar "sx") (PVar "encl") (PVar "useScope") (PVar "monos") (PVar "ifaces") (PList)) (EApp (EApp (EApp (EApp (EApp (EVar "routesOfMonosTop") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "monos")) (EVar "ifaces")))
(DFunDef false "routesOfMonosTopV" ((PVar "sx") PWild PWild (PList) PWild PWild) (EListLit))
(DFunDef false "routesOfMonosTopV" ((PVar "sx") (PVar "encl") (PVar "useScope") (PCons (PVar "m") (PVar "rest")) (PList) (PCons PWild (PVar "vs"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeOf") (EVar "sx")) (EVar "ifaceRefNone")) (EVar "encl")) (EVar "useScope")) (EApp (EVar "CountImpls") (EVar "ifaceRefNone"))) (EVar "m")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routesOfMonosTopV") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "rest")) (EListLit)) (EVar "vs"))))
(DFunDef false "routesOfMonosTopV" ((PVar "sx") (PVar "encl") (PVar "useScope") (PCons (PVar "m") (PVar "rest")) (PCons (PVar "iface") (PVar "ifacesRest")) (PCons (PVar "v") (PVar "vs"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "topRouteV") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "iface")) (EVar "m")) (EVar "v")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routesOfMonosTopV") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "rest")) (EVar "ifacesRest")) (EVar "vs"))))
(DTypeSig false "topRouteV" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Route"))))))))
(DFunDef false "topRouteV" ((PVar "sx") (PVar "encl") (PVar "useScope") (PVar "iface") (PVar "m") (PVar "goals")) (EMatch (EApp (EApp (EVar "vectorGoal") (EVar "iface")) (EVar "goals")) (arm (PCon "Some" (PTuple (PVar "g0") (PVar "gs"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeOfD") (EVar "sx")) (EVar "iface")) (EVar "encl")) (EVar "useScope")) (EApp (EVar "CountImpls") (EVar "iface"))) (EVar "g0")) (EVar "gs")) (EApp (EVar "reqWalkStart") (ELit LUnit)))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeOf") (EVar "sx")) (EVar "iface")) (EVar "encl")) (EVar "useScope")) (EApp (EVar "CountImpls") (EVar "iface"))) (EVar "m")))))
(DTypeSig false "vectorGoal" (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Mono")))))))
(DFunDef false "vectorGoal" (PWild (PList)) (EVar "None"))
(DFunDef false "vectorGoal" ((PVar "iface") (PCons (PVar "g0") (PVar "gs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "iface") "irName") (ELit (LString ""))) (EVar "None") (EApp (EVar "Some") (ETuple (EVar "g0") (EVar "gs")))))
(DTypeSig false "routesOfMonosTop" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "IfaceRef")) (TyApp (TyCon "List") (TyCon "Route"))))))))
(DFunDef false "routesOfMonosTop" ((PVar "sx") PWild PWild (PList) PWild) (EListLit))
(DFunDef false "routesOfMonosTop" ((PVar "sx") (PVar "encl") (PVar "useScope") (PCons (PVar "m") (PVar "rest")) (PList)) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeOf") (EVar "sx")) (EVar "ifaceRefNone")) (EVar "encl")) (EVar "useScope")) (EApp (EVar "CountImpls") (EVar "ifaceRefNone"))) (EVar "m")) (EApp (EApp (EApp (EApp (EApp (EVar "routesOfMonosTop") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "rest")) (EListLit))))
(DFunDef false "routesOfMonosTop" ((PVar "sx") (PVar "encl") (PVar "useScope") (PCons (PVar "m") (PVar "rest")) (PCons (PVar "iface") (PVar "ifacesRest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeOf") (EVar "sx")) (EVar "iface")) (EVar "encl")) (EVar "useScope")) (EApp (EVar "CountImpls") (EVar "iface"))) (EVar "m")) (EApp (EApp (EApp (EApp (EApp (EVar "routesOfMonosTop") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "rest")) (EVar "ifacesRest"))))
(DTypeSig true "methodPredicateRoutes" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyCon "PredicateSlot")) (TyApp (TyCon "List") (TyCon "Route")))))))
(DFunDef false "methodPredicateRoutes" ((PVar "sx") (PVar "encl") (PVar "scope") (PVar "slots")) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "methodPredicateRoute") (EVar "sx")) (EVar "encl")) (EVar "scope"))) (EVar "slots")))
(DTypeSig false "methodPredicateRoute" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "PredicateSlot") (TyCon "Route"))))))
(DFunDef false "methodPredicateRoute" ((PVar "sx") (PVar "encl") (PVar "scope") (PVar "slot")) (EMatch (EFieldAccess (EVar "slot") "psArgs") (arm (PCon "PSArgsKnown" (PCons (PVar "g0") (PVar "gs"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeOfD") (EVar "sx")) (EFieldAccess (EVar "slot") "psIface")) (EVar "encl")) (EVar "scope")) (EVar "KeepNone")) (EVar "g0")) (EVar "gs")) (EApp (EVar "reqWalkStart") (ELit LUnit)))) (arm PWild () (EVar "RNone"))))
(DTypeSig true "recRoutes" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "PredicateSlot")) (TyApp (TyCon "List") (TyCon "Route"))))))))
(DFunDef false "recRoutes" ((PVar "sx") (PVar "encl") (PVar "scope") (PVar "mono") (PVar "slots")) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EVar "recRoute") (EVar "sx")) (EVar "encl")) (EVar "scope")) (EVar "mono"))) (EVar "slots")))
(DTypeSig false "recRoute" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "Mono") (TyFun (TyCon "PredicateSlot") (TyCon "Route")))))))
(DFunDef false "recRoute" ((PVar "sx") (PVar "encl") (PVar "scope") (PVar "mono") (PVar "slot")) (EMatch (EApp (EApp (EApp (EVar "recPredicateArgs") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "mono")) (EVar "slot")) (arm (PCon "Some" (PCons (PVar "g0") (PVar "gs"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeOfD") (EVar "sx")) (EFieldAccess (EVar "slot") "psIface")) (EVar "encl")) (EVar "scope")) (EVar "KeepNone")) (EVar "g0")) (EVar "gs")) (EApp (EVar "reqWalkStart") (ELit LUnit)))) (arm PWild () (EMatch (EFieldAccess (EVar "slot") "psBoundIds") (arm (PCons (PVar "id") PWild) () (EMatch (EApp (EApp (EVar "findTvarInMono") (EVar "mono")) (EVar "id")) (arm (PCon "None") () (EVar "RNone")) (arm (PCon "Some" (PVar "m")) () (EApp (EApp (EApp (EApp (EApp (EVar "resolveRecMono") (EVar "sx")) (EVar "encl")) (EVar "scope")) (EFieldAccess (EVar "slot") "psIface")) (EVar "m"))))) (arm (PList) () (EVar "RNone"))))))
(DTypeSig false "recPredicateArgs" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "PredicateSlot") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Mono")))))))
(DFunDef false "recPredicateArgs" ((PVar "gctx") (PVar "mono") (PVar "slot")) (EMatch (EFieldAccess (EVar "slot") "psArgs") (arm (PCon "PSArgsUnknown") () (EVar "None")) (arm (PCon "PSArgsKnown" (PVar "args")) () (EApp (EApp (EVar "map") (ELam ((PVar "subst")) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EVar "subst")) (EListLit)) (EListLit))) (EVar "args")))) (EApp (EApp (EVar "recSlotSubst") (EVar "mono")) (EFieldAccess (EVar "slot") "psBoundIds"))))))
(DTypeSig false "recSlotSubst" (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))))))
(DFunDef false "recSlotSubst" (PWild (PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "recSlotSubst" ((PVar "mono") (PCons (PVar "id") (PVar "rest"))) (EMatch (EApp (EApp (EVar "findTvarInMono") (EVar "mono")) (EVar "id")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "m")) () (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (ETuple (EVar "id") (EVar "m")) (EVar "_s")))) (EApp (EApp (EVar "recSlotSubst") (EVar "mono")) (EVar "rest"))))))
(DTypeSig false "resolveRecMono" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "Mono") (TyCon "Route")))))))
(DFunDef false "resolveRecMono" ((PVar "sx") (PVar "encl") (PVar "scope") (PVar "iface") (PVar "m")) (EMatch (EApp (EVar "headTyconMono") (EVar "m")) (arm (PCon "Some" (PAs "hk" (PCon "HkRigid" PWild))) () (EApp (EApp (EApp (EVar "RKey") (EApp (EVar "headKeyTag") (EVar "hk"))) (EListLit)) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "superRoutesAt") (EVar "sx")) (EVar "iface")) (EVar "encl")) (EVar "scope")) (EListLit (EVar "m"))) (EApp (EVar "reqWalkStart") (ELit LUnit))))) (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeOfD") (EVar "sx")) (EVar "iface")) (EVar "encl")) (EVar "scope")) (EVar "KeepNone")) (EVar "m")) (EListLit)) (EApp (EVar "reqWalkStart") (ELit LUnit)))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EVar "enclSlot") (EFieldAccess (EVar "sx") "sxModule")) (EVar "encl")) (EVar "m")) (arm (PCon "Some" (PVar "slot")) () (EBlock (DoLet false false (PVar "binder") (EApp (EApp (EVar "Scopes.binderAt") (EApp (EApp (EVar "Scopes.declarationScope") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (ELit LUnit))) (EVar "scope"))) (EVar "slot"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "assumAnswerRoute") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EApp (EVar "LegacyScalar") (EVar "binder"))) (EApp (EVar "Some") (EVar "iface"))) (EVar "scope")) (EVar "RDict"))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeOf") (EVar "sx")) (EVar "ifaceRefNone")) (ELit (LString ""))) (EVar "scope")) (EVar "KeepNone")) (EVar "m")))))))
(DTypeSig true "solveExactReturnOnce" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "MethodReturnRequest") (TyCon "MethodReturnResolution"))))
(DFunDef false "solveExactReturnOnce" ((PVar "sx") (PVar "request")) (EMatch (EFieldAccess (EFieldAccess (EVar "request") "mrrResolution") "value") (arm (PCon "Some" (PVar "resolution")) () (EVar "resolution")) (arm (PCon "None") () (EBlock (DoLet false false (PVar "resolution") (EApp (EApp (EVar "solveExactReturn") (EVar "sx")) (EVar "request"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "request") "mrrResolution")) (EApp (EVar "Some") (EVar "resolution")))) (DoExpr (EVar "resolution"))))))
(DTypeSig true "methodReturnAmbiguousWithoutGiven" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodReturnRequest") (TyCon "Bool"))))
(DFunDef false "methodReturnAmbiguousWithoutGiven" ((PVar "mctx") (PVar "request")) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "methodPredicateTemplateHasAbsent") (EFieldAccess (EVar "request") "mrrPredicateTemplate")) (EApp (EVar "isNone") (EApp (EApp (EApp (EApp (EVar "uniqueMethodTemplateGiven") (EFieldAccess (EVar "mctx") "mcGraph")) (EFieldAccess (EVar "request") "mrrPredicateTemplate")) (EFieldAccess (EVar "request") "mrrScope")) (EApp (EApp (EVar "givensForScope") (EFieldAccess (EVar "mctx") "mcGraph")) (EFieldAccess (EVar "request") "mrrScope"))))) (EBinOp ">=" (EApp (EApp (EApp (EVar "methodPredicateTemplateCandidateCount") (EFieldAccess (EVar "request") "mrrPredicateTemplate")) (EApp (EVar "ieRowsAll") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "bodyImplEnvRef") "value"))) (ELit (LInt 0))) (ELit (LInt 2)))))
(DTypeSig true "methodPredicateTemplateHasAbsent" (TyFun (TyCon "MethodPredicateTemplate") (TyCon "Bool")))
(DFunDef false "methodPredicateTemplateHasAbsent" ((PVar "template")) (EApp (EApp (EVar "anyListM") (EVar "isNone")) (EFieldAccess (EVar "template") "mptArguments")))
(DTypeSig false "methodPredicateTemplateCandidateCount" (TyFun (TyCon "MethodPredicateTemplate") (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "methodPredicateTemplateCandidateCount" (PWild PWild (PVar "count")) (EIf (EBinOp ">=" (EVar "count") (ELit (LInt 2))) (EVar "count") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "methodPredicateTemplateCandidateCount" (PWild (PList) (PVar "count")) (EVar "count"))
(DFunDef false "methodPredicateTemplateCandidateCount" ((PVar "template") (PCons (PVar "row") (PVar "rest")) (PVar "count")) (EApp (EApp (EApp (EVar "methodPredicateTemplateCandidateCount") (EVar "template")) (EVar "rest")) (EIf (EApp (EApp (EVar "methodPredicateTemplateMatchesRow") (EVar "template")) (EVar "row")) (EBinOp "+" (EVar "count") (ELit (LInt 1))) (EVar "count"))))
(DTypeSig false "methodPredicateTemplateMatchesRow" (TyFun (TyCon "MethodPredicateTemplate") (TyFun (TyCon "ImplRow") (TyCon "Bool"))))
(DFunDef false "methodPredicateTemplateMatchesRow" ((PVar "template") (PCon "ImplRow" PWild PWild (PVar "iface") (PVar "tys") PWild PWild PWild)) (EBinOp "&&" (EApp (EApp (EVar "sameIfaceDecl") (EFieldAccess (EVar "template") "mptInterface")) (EVar "iface")) (EMatch (EApp (EApp (EVar "methodPredicateTemplateHeadPairs") (EFieldAccess (EVar "template") "mptArguments")) (EVar "tys")) (arm (PCon "Some" (PVar "pairs")) () (EBlock (DoLet false false (PVar "subst") (EApp (EVar "Ref") (EListLit))) (DoExpr (EApp (EVar "isSome") (EApp (EApp (EApp (EApp (EApp (EVar "matchOneSided") (EVar "matchStep")) (EVar "eqStr")) (EApp (EVar "matchEqMono") (EVar "subst"))) (EVar "pairs")) (EListLit)))))) (arm (PCon "None") () (EVar "False")))))
(DTypeSig false "methodPredicateTemplateHeadPairs" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "Ty") (TyCon "Mono")))))))
(DFunDef false "methodPredicateTemplateHeadPairs" ((PList) (PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "methodPredicateTemplateHeadPairs" ((PCons (PCon "Some" (PVar "argument")) (PVar "rest")) (PCons (PVar "head") (PVar "heads"))) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (ETuple (EVar "head") (EVar "argument")) (EVar "_s")))) (EApp (EApp (EVar "methodPredicateTemplateHeadPairs") (EVar "rest")) (EVar "heads"))))
(DFunDef false "methodPredicateTemplateHeadPairs" ((PCons (PCon "None") (PVar "rest")) (PCons PWild (PVar "heads"))) (EApp (EApp (EVar "methodPredicateTemplateHeadPairs") (EVar "rest")) (EVar "heads")))
(DFunDef false "methodPredicateTemplateHeadPairs" (PWild PWild) (EVar "None"))
(DTypeSig false "solveExactReturn" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "MethodReturnRequest") (TyCon "MethodReturnResolution"))))
(DFunDef false "solveExactReturn" ((PVar "sx") (PVar "request")) (EMatch (EApp (EApp (EVar "methodReturnWanted") (EFieldAccess (EVar "sx") "sxModule")) (EVar "request")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "complete return solver received a legacy request")))) (arm (PCon "Some" (PVar "wanted")) () (EBlock (DoLet false false (PVar "predicate") (EFieldAccess (EVar "wanted") "predicate")) (DoLet false false (PVar "args") (EApp (EApp (EVar "map") (EVar "normalize")) (EFieldAccess (EVar "predicate") "predicateArguments"))) (DoLet false false (PVar "predRequest") (ERecordCreate "PredicateRequest" ((fa "prIface" (EFieldAccess (EVar "predicate") "predicateInterface")) (fa "prArgs" (EApp (EVar "PSArgsKnown") (EVar "args")))))) (DoLet false false (PVar "resultMono") (EApp (EVar "stripArrows") (EFieldAccess (EVar "request") "mrrOccurrence"))) (DoLet false false (PVar "given") (EApp (EApp (EVar "orElseOpt") (EApp (EApp (EApp (EApp (EApp (EVar "activeDictVarOfEncl") (EFieldAccess (EVar "sx") "sxModule")) (EApp (EVar "Some") (EVar "predRequest"))) (EVar "resultMono")) (EFieldAccess (EVar "request") "mrrEnclosing")) (EFieldAccess (EVar "wanted") "scope"))) (EApp (EApp (EApp (EApp (EVar "activeDictPredOf") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "predRequest")) (EVar "resultMono")) (EFieldAccess (EVar "wanted") "scope")))) (DoExpr (EMatch (EVar "given") (arm (PCon "Some" (PVar "answer")) () (EBlock (DoExpr (EApp (EApp (EApp (EVar "noteAssumption") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EFieldAccess (EVar "wanted") "scope")) (EVar "answer"))) (DoExpr (ERecordCreate "MethodReturnResolution" ((fa "mrrWanted" (EVar "wanted")) (fa "mrrOutcome" (EApp (EVar "Solved") (EApp (EVar "assumAnswerEvidence") (EVar "answer")))) (fa "mrrSelectedRow" (EVar "None"))))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "solveExactReturnInstance") (EVar "sx")) (EVar "request")) (EVar "wanted")) (EVar "args")))))))))
(DTypeSig false "solveExactReturnInstance" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "MethodReturnRequest") (TyFun (TyCon "Wanted") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "MethodReturnResolution"))))))
(DFunDef false "solveExactReturnInstance" ((PVar "sx") (PVar "request") (PVar "wanted") (PList)) (ERecordCreate "MethodReturnResolution" ((fa "mrrWanted" (EVar "wanted")) (fa "mrrOutcome" (EApp (EApp (EVar "Deferred") (EVar "wanted")) (EListLit (EVar "BlockingFinalization")))) (fa "mrrSelectedRow" (EVar "None")))))
(DFunDef false "solveExactReturnInstance" ((PVar "sx") (PVar "request") (PVar "wanted") (PVar "args")) (EBlock (DoLet false false (PVar "env") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "bodyImplEnvRef") "value")) (DoLet false false (PVar "iface") (EFieldAccess (EFieldAccess (EVar "wanted") "predicate") "predicateInterface")) (DoLet false false (PVar "selected") (EApp (EApp (EVar "orElseOpt") (EApp (EApp (EApp (EApp (EVar "ieSelectRowByIface") (EVar "sx")) (EVar "env")) (EVar "iface")) (EVar "args"))) (EApp (EApp (EApp (EVar "determinedGoalInstance") (EFieldAccess (EVar "sx") "sxModule")) (EVar "iface")) (EVar "args")))) (DoExpr (EMatch (EVar "selected") (arm (PCon "Some" (PAs "row" (PCon "ImplRow" PWild (PVar "inst") (PVar "selectedIface") PWild PWild PWild PWild))) () (EBlock (DoLet false false (PVar "prerequisites") (EApp (EApp (EApp (EVar "methodReturnPrerequisites") (EFieldAccess (EVar "sx") "sxModule")) (EVar "args")) (EVar "row"))) (DoExpr (ERecordCreate "MethodReturnResolution" ((fa "mrrWanted" (EVar "wanted")) (fa "mrrOutcome" (EApp (EVar "Solved") (EApp (EApp (EApp (EApp (EVar "InstanceEvidence") (EApp (EVar "RequestInstanceId") (EApp (EVar "instRefSeq") (EVar "inst")))) (EVar "args")) (EVar "prerequisites")) (EApp (EApp (EApp (EVar "instanceSuperEvidence") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "selectedIface")) (EVar "args"))))) (fa "mrrSelectedRow" (EApp (EVar "Some") (EVar "row")))))))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "outcome") (EIf (EApp (EApp (EApp (EVar "exactReturnDefers") (EFieldAccess (EVar "sx") "sxModule")) (EVar "wanted")) (EVar "args")) (EApp (EApp (EVar "Deferred") (EVar "wanted")) (EApp (EVar "exactReturnBlockers") (EVar "args"))) (EApp (EApp (EVar "Insoluble") (EVar "wanted")) (EVar "MissingInstance")))) (DoExpr (ERecordCreate "MethodReturnResolution" ((fa "mrrWanted" (EVar "wanted")) (fa "mrrOutcome" (EVar "outcome")) (fa "mrrSelectedRow" (EVar "None")))))))))))
(DTypeSig false "exactReturnDefers" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Wanted") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool")))))
(DFunDef false "exactReturnDefers" ((PVar "mctx") (PVar "wanted") (PVar "args")) (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EBinOp "==" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "wanted") "predicate") "predicateInterface") "irName") (ELit (LString "Num"))) (EApp (EVar "not") (EApp (EApp (EVar "builtinClassPresent") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "BNum")))) (EApp (EVar "not") (EApp (EVar "allConcreteHeads") (EVar "args")))) (EApp (EApp (EApp (EApp (EVar "goalDefersOpenWorld") (EVar "mctx")) (EFieldAccess (EVar "wanted") "scope")) (EFieldAccess (EFieldAccess (EVar "wanted") "predicate") "predicateInterface")) (EVar "args"))))
(DTypeSig false "exactReturnBlockers" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "SolverBlocker"))))
(DFunDef false "exactReturnBlockers" ((PVar "args")) (EApp (EApp (EVar "map") (EVar "BlockingTypeVariable")) (EApp (EApp (EVar "flatMap") (EVar "monoUnboundIds")) (EVar "args"))))
(DTypeSig false "methodReturnPrerequisites" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ImplRow") (TyApp (TyCon "List") (TyCon "PrerequisiteEvidence"))))))
(DFunDef false "methodReturnPrerequisites" ((PVar "mctx") (PVar "args") (PVar "row")) (EMatch (EApp (EApp (EApp (EVar "selectedRowReqMatch") (EVar "mctx")) (EVar "args")) (EVar "row")) (arm (PCon "Some" (PTuple (PVar "subst") (PVar "reqs"))) () (EApp (EApp (EVar "map") (EBinOp ">>" (EApp (EApp (EVar "reqToObligation") (EVar "mctx")) (EVar "subst")) (EVar "prerequisiteEvidence"))) (EVar "reqs"))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "instanceSuperEvidence" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "SuperEvidence"))))))
(DFunDef false "instanceSuperEvidence" ((PVar "gctx") (PVar "iface") (PVar "args")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "superIface") (PVar "superArgs"))) (ERecordCreate "SuperEvidence" ((fa "superInterface" (EVar "superIface")) (fa "superArguments" (EApp (EApp (EVar "optionOr") (EListLit)) (EVar "superArgs"))))))) (EApp (EApp (EApp (EVar "directSuperGoals") (EVar "gctx")) (EVar "iface")) (EVar "args"))))
(DTypeSig false "prerequisiteEvidence" (TyFun (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))) (TyCon "PrerequisiteEvidence")))
(DFunDef false "prerequisiteEvidence" ((PTuple (PVar "iface") (PVar "args"))) (ERecordCreate "PrerequisiteEvidence" ((fa "prerequisiteInterface" (EVar "iface")) (fa "prerequisiteArguments" (EVar "args")))))
(DTypeSig true "methodReturnResolutionValid" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodReturnRequest") (TyFun (TyCon "MethodReturnResolution") (TyCon "Bool")))))
(DFunDef false "methodReturnResolutionValid" ((PVar "mctx") (PVar "request") (PVar "resolution")) (EBinOp "&&" (EApp (EApp (EApp (EVar "methodReturnWantedMatches") (EVar "mctx")) (EVar "request")) (EFieldAccess (EVar "resolution") "mrrWanted")) (EMatch (ETuple (EFieldAccess (EVar "resolution") "mrrOutcome") (EFieldAccess (EVar "resolution") "mrrSelectedRow")) (arm (PTuple (PCon "Solved" (PCon "GivenEvidence" PWild)) (PCon "None")) () (EVar "True")) (arm (PTuple (PCon "Solved" (PCon "SuperclassEvidence" (PVar "parent") (PVar "path"))) (PCon "None")) () (EMatch (EApp (EApp (EApp (EVar "projectedGivenOf") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "parent")) (EVar "path")) (arm (PCon "Some" (PVar "g")) () (EApp (EApp (EVar "predicateRequestMatchesSlot") (ERecordCreate "PredicateRequest" ((fa "prIface" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "resolution") "mrrWanted") "predicate") "predicateInterface")) (fa "prArgs" (EApp (EVar "PSArgsKnown") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "resolution") "mrrWanted") "predicate") "predicateArguments")))))) (EFieldAccess (EVar "g") "geSlot"))) (arm (PCon "None") () (EVar "False")))) (arm (PTuple (PCon "Solved" (PCon "InstanceEvidence" (PVar "identity") (PVar "args") (PVar "prerequisites") PWild)) (PCon "Some" (PVar "row"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "methodReturnInstanceMatches") (EVar "identity")) (EVar "row")) (EApp (EApp (EVar "monoVecSameGiven") (EVar "args")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "resolution") "mrrWanted") "predicate") "predicateArguments"))) (EApp (EApp (EVar "methodReturnPrerequisitesMatch") (EVar "prerequisites")) (EApp (EApp (EApp (EVar "methodReturnPrerequisites") (EVar "mctx")) (EVar "args")) (EVar "row"))))) (arm (PTuple (PCon "Deferred" (PVar "wanted") PWild) (PCon "None")) () (EApp (EApp (EVar "wantedMatches") (EVar "wanted")) (EFieldAccess (EVar "resolution") "mrrWanted"))) (arm (PTuple (PCon "Insoluble" (PVar "wanted") PWild) (PCon "None")) () (EApp (EApp (EVar "wantedMatches") (EVar "wanted")) (EFieldAccess (EVar "resolution") "mrrWanted"))) (arm PWild () (EVar "False")))))
(DTypeSig false "methodReturnWantedMatches" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodReturnRequest") (TyFun (TyCon "Wanted") (TyCon "Bool")))))
(DFunDef false "methodReturnWantedMatches" ((PVar "mctx") (PVar "request") (PVar "wanted")) (EMatch (EApp (EApp (EVar "methodReturnWanted") (EVar "mctx")) (EVar "request")) (arm (PCon "Some" (PVar "carried")) () (EApp (EApp (EVar "wantedMatches") (EVar "carried")) (EVar "wanted"))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "wantedMatches" (TyFun (TyCon "Wanted") (TyFun (TyCon "Wanted") (TyCon "Bool"))))
(DFunDef false "wantedMatches" ((PVar "left") (PVar "right")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "left") "id") (EFieldAccess (EVar "right") "id")) (EApp (EApp (EVar "sameTraceEvId") (EFieldAccess (EVar "left") "destination")) (EFieldAccess (EVar "right") "destination"))) (EBinOp "==" (EFieldAccess (EVar "left") "scope") (EFieldAccess (EVar "right") "scope"))) (EApp (EApp (EVar "sameIfaceDecl") (EFieldAccess (EFieldAccess (EVar "left") "predicate") "predicateInterface")) (EFieldAccess (EFieldAccess (EVar "right") "predicate") "predicateInterface"))) (EApp (EApp (EVar "monoVecSameGiven") (EFieldAccess (EFieldAccess (EVar "left") "predicate") "predicateArguments")) (EFieldAccess (EFieldAccess (EVar "right") "predicate") "predicateArguments"))))
(DTypeSig false "methodReturnInstanceMatches" (TyFun (TyCon "RequestInstanceId") (TyFun (TyCon "ImplRow") (TyCon "Bool"))))
(DFunDef false "methodReturnInstanceMatches" ((PCon "RequestInstanceId" (PVar "identity")) (PCon "ImplRow" PWild (PVar "inst") PWild PWild PWild PWild PWild)) (EBinOp "==" (EVar "identity") (EApp (EVar "instRefSeq") (EVar "inst"))))
(DTypeSig false "methodReturnPrerequisitesMatch" (TyFun (TyApp (TyCon "List") (TyCon "PrerequisiteEvidence")) (TyFun (TyApp (TyCon "List") (TyCon "PrerequisiteEvidence")) (TyCon "Bool"))))
(DFunDef false "methodReturnPrerequisitesMatch" ((PList) (PList)) (EVar "True"))
(DFunDef false "methodReturnPrerequisitesMatch" ((PCons (PVar "left") (PVar "ls")) (PCons (PVar "right") (PVar "rs"))) (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "sameIfaceDecl") (EFieldAccess (EVar "left") "prerequisiteInterface")) (EFieldAccess (EVar "right") "prerequisiteInterface")) (EApp (EApp (EVar "monoVecSameGiven") (EFieldAccess (EVar "left") "prerequisiteArguments")) (EFieldAccess (EVar "right") "prerequisiteArguments"))) (EApp (EApp (EVar "methodReturnPrerequisitesMatch") (EVar "ls")) (EVar "rs"))))
(DFunDef false "methodReturnPrerequisitesMatch" (PWild PWild) (EVar "False"))
(DTypeSig true "improveByUniqueImpl" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyCon "Unit")))))
(DFunDef false "improveByUniqueImpl" ((PVar "dyn") PWild (PList)) (ELit LUnit))
(DFunDef false "improveByUniqueImpl" ((PVar "dyn") (PVar "sigIds") (PCons (PVar "o") (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "improveGoal") (EVar "dyn")) (EVar "sigIds")) (EFieldAccess (EFieldAccess (EVar "o") "pred") "iface")) (EApp (EApp (EVar "map") (EVar "normalize")) (EApp (EApp (EVar "uOblArgs") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph")) (EVar "o"))))) (DoExpr (EApp (EApp (EApp (EVar "improveByUniqueImpl") (EVar "dyn")) (EVar "sigIds")) (EVar "rest")))))
(DTypeSig true "determineByUniqueInstance" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyCon "Unit")))))
(DFunDef false "determineByUniqueInstance" ((PVar "mctx") (PVar "rigidIds") (PVar "obls")) (EIf (EApp (EVar "isNonEmptyL") (EVar "obls")) (EApp (EApp (EApp (EApp (EVar "determineSweeps") (EVar "mctx")) (EVar "rigidIds")) (EApp (EApp (EVar "goalWindowOf") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "obls"))) (EBinOp "+" (EApp (EVar "listLen") (EVar "obls")) (ELit (LInt 1)))) (ELit LUnit)))
(DTypeSig false "determineSweeps" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GoalWindow") (TyFun (TyCon "Int") (TyCon "Unit"))))))
(DFunDef false "determineSweeps" ((PVar "mctx") (PVar "rigidIds") (PVar "window") (PVar "fuel")) (EIf (EBinOp "&&" (EBinOp ">" (EVar "fuel") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EApp (EVar "determineByUniqueInstanceGo") (EVar "mctx")) (EVar "rigidIds")) (EVar "window")) (EVar "False")) (EFieldAccess (EVar "window") "gwGoals"))) (EApp (EApp (EApp (EApp (EVar "determineSweeps") (EVar "mctx")) (EVar "rigidIds")) (EVar "window")) (EBinOp "-" (EVar "fuel") (ELit (LInt 1)))) (ELit LUnit)))
(DTypeSig false "determineByUniqueInstanceGo" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GoalWindow") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "UObligation"))) (TyCon "Bool")))))))
(DFunDef false "determineByUniqueInstanceGo" ((PVar "mctx") PWild PWild (PVar "changed") (PList)) (EVar "changed"))
(DFunDef false "determineByUniqueInstanceGo" ((PVar "mctx") (PVar "rigidIds") (PVar "window") (PVar "changed") (PCons (PTuple PWild (PVar "o")) (PVar "rest"))) (EBlock (DoLet false false (PVar "args") (EApp (EApp (EVar "map") (EVar "normalize")) (EApp (EApp (EVar "uOblArgs") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "o")))) (DoLet false false (PVar "now") (EApp (EApp (EApp (EApp (EApp (EVar "determineGoal") (EVar "mctx")) (EVar "rigidIds")) (EVar "window")) (EVar "o")) (EVar "args"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "determineByUniqueInstanceGo") (EVar "mctx")) (EVar "rigidIds")) (EVar "window")) (EBinOp "||" (EVar "now") (EVar "changed"))) (EVar "rest")))))
(DTypeSig false "determineGoal" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GoalWindow") (TyFun (TyCon "UObligation") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool")))))))
(DFunDef false "determineGoal" ((PVar "mctx") (PVar "rigidIds0") (PVar "window") (PVar "o") (PVar "args")) (EBlock (DoLet false false (PVar "rigidIds") (EApp (EApp (EApp (EVar "withDeclaredVars") (EVar "mctx")) (EVar "rigidIds0")) (EVar "args"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "determineHeldGoal") (EVar "mctx")) (EVar "rigidIds")) (EVar "window")) (EVar "o")) (EVar "args")))))
(DTypeSig false "withDeclaredVars" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "withDeclaredVars" ((PVar "mctx") (PVar "rigidIds") (PVar "args")) (EBlock (DoLet false false (PVar "declared") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "declaredSigVarIds") "value")) (DoExpr (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "filterList") (ELam ((PVar "k")) (EApp (EApp (EVar "omHasKey") (EVar "k")) (EVar "declared")))) (EApp (EApp (EVar "map") (EVar "intToString")) (EApp (EApp (EVar "flatMap") (EVar "monoUnboundIds")) (EVar "args"))))) (EVar "rigidIds")))))
(DTypeSig false "determineHeldGoal" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GoalWindow") (TyFun (TyCon "UObligation") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool")))))))
(DFunDef false "determineHeldGoal" ((PVar "mctx") (PVar "rigidIds") (PVar "window") (PVar "o") (PVar "args")) (EIf (EBinOp "||" (EApp (EVar "monoVectorClosed") (EVar "args")) (EApp (EApp (EVar "goalVarsAllHeld") (EVar "rigidIds")) (EVar "args"))) (EVar "False") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EApp (EVar "goalRows") (EVar "mctx")) (EFieldAccess (EFieldAccess (EVar "o") "pred") "iface")) (EVar "args"))) (DoLet false false (PVar "unifying") (EIf (EApp (EApp (EVar "goalIsProjection") (EVar "args")) (EVar "rows")) (EListLit) (EApp (EApp (EApp (EApp (EVar "goalCandidates") (EVar "mctx")) (EVar "rigidIds")) (EVar "args")) (EVar "rows")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "determinationCandidates") (EVar "mctx")) (EVar "window")) (EVar "args")) (EVar "unifying")) (arm (PList (PTuple (PVar "row") PWild)) () (EBlock (DoLet false false (PVar "oldIds") (EApp (EVar "dedupI") (EApp (EApp (EVar "flatMap") (EVar "monoUnboundIds")) (EVar "args")))) (DoLet false false (PVar "sizeBefore") (EApp (EVar "monoSizes") (EVar "args"))) (DoExpr (EApp (EApp (EVar "enterLevel") (EVar "mctx")) (ELit LUnit))) (DoLet false false (PVar "heads") (EApp (EApp (EVar "freshRowHeads") (EVar "mctx")) (EVar "row"))) (DoExpr (EApp (EApp (EVar "exitLevel") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "commitImprovement") (EApp (EVar "dynFor") (EVar "mctx"))) (EVar "rigidIds")) (EApp (EApp (EVar "zip") (EVar "args")) (EVar "heads")))) (DoExpr (EApp (EApp (EApp (EVar "fileDeterminedRow") (EVar "mctx")) (EVar "row")) (EVar "args"))) (DoExpr (EApp (EApp (EApp (EVar "refileGoals") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "window")) (EVar "oldIds"))) (DoExpr (EBinOp "||" (EBinOp "/=" (EApp (EVar "monoSizes") (EVar "args")) (EVar "sizeBefore")) (EBinOp "/=" (EApp (EVar "listLen") (EApp (EVar "dedupI") (EApp (EApp (EVar "flatMap") (EVar "monoUnboundIds")) (EVar "args")))) (EApp (EVar "listLen") (EVar "oldIds"))))))) (arm PWild () (EVar "False"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "fileDeterminedRow" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ImplRow") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Unit")))))
(DFunDef false "fileDeterminedRow" ((PVar "mctx") PWild (PList)) (ELit LUnit))
(DFunDef false "fileDeterminedRow" ((PVar "mctx") (PVar "row") (PCons (PVar "first") (PVar "rest"))) (EMatch (EApp (EVar "normalize") (EVar "first")) (arm (PCon "TVar" (PVar "cell")) () (EBlock (DoLet false false (PVar "table") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "determinedRowsRef") "value")) (DoLet false false (PVar "filed") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "IdMap.get") (EApp (EVar "tyvarId") (EVar "cell"))) (EVar "table")))) (DoLet false false (PVar "entry") (ETuple (EVar "row") (EApp (EApp (EVar "map") (EVar "normalize")) (EBinOp "::" (EVar "first") (EVar "rest"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "determinedRowsRef")) (EApp (EApp (EApp (EVar "IdMap.set") (EApp (EVar "tyvarId") (EVar "cell"))) (EBinOp "::" (EVar "entry") (EVar "filed"))) (EVar "table")))))) (arm PWild () (ELit LUnit))))
(DTypeSig true "refileDeterminedRows" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "Unit"))))
(DFunDef false "refileDeterminedRows" ((PVar "mctx") PWild) (EBlock (DoLet false false (PVar "table") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "determinedRowsRef") "value")) (DoExpr (EIf (EApp (EVar "not") (EApp (EVar "IdMap.isEmpty") (EVar "table"))) (EBlock (DoLet false false (PVar "entries") (EApp (EVar "reverseL") (EApp (EApp (EVar "flatMap") (EVar "identity")) (EApp (EVar "IdMap.values") (EVar "table"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "determinedRowsRef")) (EVar "Tip"))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "entry")) (EApp (EApp (EApp (EVar "fileDeterminedRow") (EVar "mctx")) (EApp (EVar "fst") (EVar "entry"))) (EApp (EVar "snd") (EVar "entry"))))) (ELit LUnit)) (EVar "entries")))) (ELit LUnit)))))
(DTypeSig true "goalVarsAllHeld" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))
(DFunDef false "goalVarsAllHeld" ((PVar "rigidIds") (PVar "args")) (EApp (EApp (EVar "allList") (ELam ((PVar "c")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "intToString") (EApp (EVar "tyvarId") (EVar "c")))) (EVar "rigidIds")))) (EApp (EApp (EVar "flatMap") (EVar "monoVarCells")) (EVar "args"))))
(DTypeSig true "determinationCandidates" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "GoalWindow") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "ImplRow") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))))) (TyApp (TyCon "List") (TyTuple (TyCon "ImplRow") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))))))))))
(DFunDef false "determinationCandidates" ((PVar "mctx") (PVar "window") (PVar "args") (PVar "unifying")) (EApp (EApp (EVar "filterList") (ELam ((PVar "cand")) (EBinOp "&&" (EApp (EApp (EVar "rowCountsFor") (EVar "args")) (EApp (EVar "fst") (EVar "cand"))) (EApp (EApp (EApp (EVar "siblingsStaySatisfiable") (EVar "mctx")) (EVar "window")) (EApp (EVar "snd") (EVar "cand")))))) (EVar "unifying")))
(DTypeSig true "goalWindowOf" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyCon "GoalWindow"))))
(DFunDef false "goalWindowOf" ((PVar "gctx") (PVar "obls")) (EBlock (DoLet false false (PVar "goals") (EApp (EVar "indexed") (EVar "obls"))) (DoExpr (ERecordCreate "GoalWindow" ((fa "gwGoals" (EVar "goals")) (fa "gwByIndex" (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PTuple (PVar "i") (PVar "o"))) (EApp (EApp (EApp (EVar "IdMap.set") (EVar "i")) (EVar "o")) (EVar "m")))) (EVar "Tip")) (EVar "goals"))) (fa "gwByVar" (EApp (EVar "Ref") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PTuple (PVar "i") (PVar "o"))) (EApp (EApp (EApp (EApp (EVar "fileGoal") (EVar "gctx")) (EVar "i")) (EVar "o")) (EVar "m")))) (EVar "Tip")) (EVar "goals")))))))))
(DTypeSig false "fileGoal" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyFun (TyCon "UObligation") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "fileGoal" ((PVar "gctx") (PVar "i") (PVar "o") (PVar "byVar")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PVar "id")) (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (EBinOp "::" (EVar "i") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EVar "m"))))) (EVar "m")))) (EVar "byVar")) (EApp (EVar "dedupI") (EApp (EApp (EVar "flatMap") (EVar "monoUnboundIds")) (EApp (EApp (EVar "uOblArgs") (EVar "gctx")) (EVar "o"))))))
(DTypeSig true "goalsOnVar" (TyFun (TyCon "GoalWindow") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "goalsOnVar" ((PVar "window") (PVar "id")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EFieldAccess (EFieldAccess (EVar "window") "gwByVar") "value"))))
(DTypeSig false "refileGoals" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "GoalWindow") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "refileGoals" ((PVar "gctx") (PVar "window") (PVar "oldIds")) (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "window") "gwByVar")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "i")) (EMatch (EApp (EApp (EVar "IdMap.get") (EVar "i")) (EFieldAccess (EVar "window") "gwByIndex")) (arm (PCon "Some" (PVar "g")) () (EApp (EApp (EApp (EApp (EVar "fileGoal") (EVar "gctx")) (EVar "i")) (EVar "g")) (EVar "acc"))) (arm (PCon "None") () (EVar "acc"))))) (EFieldAccess (EFieldAccess (EVar "window") "gwByVar") "value")) (EApp (EVar "dedupI") (EApp (EApp (EVar "flatMap") (EApp (EVar "goalsOnVar") (EVar "window"))) (EVar "oldIds"))))))
(DTypeSig false "rowHeadSubstRigid" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ImplRow") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))))))))
(DFunDef false "rowHeadSubstRigid" ((PVar "mctx") (PVar "rigidIds") (PVar "args") (PVar "row")) (EBlock (DoLet false false (PVar "heads") (EApp (EApp (EVar "freshRowHeads") (EVar "mctx")) (EVar "row"))) (DoLet false false (PVar "scratch") (EApp (EVar "Ref") (EListLit))) (DoExpr (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "listLen") (EVar "heads")) (EApp (EVar "listLen") (EVar "args"))) (EApp (EApp (EVar "cohOverlapGo") (EVar "scratch")) (EApp (EApp (EApp (EVar "rigidSigPairs") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "rigidIds")) (EApp (EApp (EVar "zip") (EVar "args")) (EVar "heads"))))) (EApp (EVar "Some") (EUnOp "!" (EVar "scratch"))) (EVar "None")))))
(DTypeSig false "siblingsStaySatisfiable" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "GoalWindow") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyCon "Bool")))))
(DFunDef false "siblingsStaySatisfiable" ((PVar "mctx") (PVar "window") (PVar "subst")) (EBlock (DoLet false false (PVar "bound") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "subst"))) (DoLet false false (PVar "scratch") (EApp (EVar "Ref") (EVar "subst"))) (DoExpr (EApp (EApp (EVar "allList") (ELam ((PVar "i")) (EMatch (EApp (EApp (EVar "IdMap.get") (EVar "i")) (EFieldAccess (EVar "window") "gwByIndex")) (arm (PCon "Some" (PVar "s")) () (EApp (EApp (EApp (EApp (EVar "siblingStaysSatisfiable") (EVar "mctx")) (EVar "scratch")) (EVar "bound")) (EVar "s"))) (arm (PCon "None") () (EVar "True"))))) (EApp (EVar "dedupI") (EApp (EApp (EVar "flatMap") (EApp (EVar "goalsOnVar") (EVar "window"))) (EVar "bound")))))))
(DTypeSig false "siblingStaysSatisfiable" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "UObligation") (TyCon "Bool"))))))
(DFunDef false "siblingStaysSatisfiable" ((PVar "mctx") (PVar "scratch") (PVar "bound") (PVar "s")) (EBlock (DoLet false false (PVar "args") (EApp (EApp (EVar "map") (EVar "normalize")) (EApp (EApp (EVar "uOblArgs") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "s")))) (DoExpr (EIf (EApp (EVar "not") (EApp (EApp (EVar "any") (ELam ((PVar "i")) (EApp (EApp (EVar "elem") (EVar "i")) (EVar "bound")))) (EApp (EApp (EVar "flatMap") (EVar "monoUnboundIds")) (EVar "args")))) (EVar "True") (EBlock (DoLet false false (PVar "after") (EApp (EApp (EVar "map") (EApp (EVar "cohApply") (EVar "scratch"))) (EVar "args"))) (DoExpr (EBinOp "||" (EApp (EVar "not") (EApp (EVar "monoVectorClosed") (EVar "after"))) (EApp (EApp (EVar "anyList") (ELam ((PVar "row")) (EBinOp "||" (EBinOp ">" (EApp (EVar "listLen") (EApp (EVar "ieRowTys") (EVar "row"))) (EApp (EVar "listLen") (EVar "after"))) (EApp (EApp (EApp (EVar "rowHeadMatches") (EVar "mctx")) (EVar "after")) (EVar "row"))))) (EApp (EApp (EVar "filterList") (EApp (EVar "ieRowOfIface") (EFieldAccess (EFieldAccess (EVar "s") "pred") "iface"))) (EApp (EApp (EVar "improvementPool") (EVar "mctx")) (EVar "after")))))))))))
(DTypeSig false "improveGoal" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Unit"))))))
(DFunDef false "improveGoal" ((PVar "dyn") (PVar "sigIds") (PVar "iface") (PVar "args")) (EIf (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "args")) (EApp (EVar "monoVectorClosed") (EVar "args"))) (ELit LUnit) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EVar "filterList") (EApp (EVar "ieRowOfIface") (EVar "iface"))) (EApp (EApp (EVar "improvementPool") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "args")))) (DoExpr (EMatch (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "rowHeadMatches") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "args"))) (EVar "rows")) (arm (PList (PVar "row")) () (EMatch (EApp (EApp (EVar "repeatedGoalPairs") (EApp (EVar "ieRowTys") (EVar "row"))) (EVar "args")) (arm (PList) () (ELit LUnit)) (arm (PVar "pairs") () (EIf (EBinOp "==" (EApp (EVar "listLen") (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "rowHeadUnifies") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "args"))) (EVar "rows"))) (ELit (LInt 1))) (EApp (EApp (EApp (EVar "commitImprovement") (EVar "dyn")) (EVar "sigIds")) (EVar "pairs")) (ELit LUnit))))) (arm PWild () (ELit LUnit))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "commitImprovement" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Mono"))) (TyCon "Unit")))))
(DFunDef false "commitImprovement" ((PVar "dyn") (PVar "sigIds") (PVar "pairs")) (EBlock (DoLet false false (PVar "cells") (EApp (EApp (EVar "flatMap") (ELam ((PVar "p")) (EBinOp "++" (EApp (EVar "monoVarCells") (EApp (EVar "fst") (EVar "p"))) (EApp (EVar "monoVarCells") (EApp (EVar "snd") (EVar "p")))))) (EVar "pairs"))) (DoLet false false (PVar "sigCells") (EApp (EApp (EVar "sigCellsOf") (EVar "sigIds")) (EVar "cells"))) (DoLet false false (PVar "scratch") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "rigidPairs") (EApp (EApp (EApp (EVar "rigidSigPairs") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph")) (EVar "sigIds")) (EVar "pairs"))) (DoLet false false (PVar "cellsById") (EApp (EApp (EVar "map") (ELam ((PVar "c")) (ETuple (EApp (EVar "tyvarId") (EVar "c")) (EVar "c")))) (EVar "cells"))) (DoExpr (EIf (EApp (EApp (EVar "cohOverlapGo") (EVar "scratch")) (EVar "rigidPairs")) (EApp (EApp (EVar "each") (ELam ((PVar "binding")) (EMatch (EApp (EApp (EVar "lookupAssocI") (EApp (EVar "fst") (EVar "binding"))) (EVar "cellsById")) (arm (PCon "Some" (PVar "cell")) () (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EApp (EVar "TVar") (EVar "cell"))) (EApp (EApp (EVar "unrigidSig") (EVar "sigCells")) (EApp (EVar "snd") (EVar "binding"))))) (arm (PCon "None") () (ELit LUnit))))) (EApp (EVar "reverse") (EUnOp "!" (EVar "scratch")))) (ELit LUnit)))))
(DTypeSig true "improvementPool" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "ImplRow")))))
(DFunDef false "improvementPool" ((PVar "mctx") (PVar "args")) (EBlock (DoLet false false (PVar "env") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "bodyImplEnvRef") "value")) (DoExpr (EMatch (EApp (EVar "goalHeadCon") (EVar "args")) (arm (PCon "Some" (PVar "hk")) () (EBinOp "++" (EApp (EApp (EVar "ieHeadRows") (EApp (EVar "Some") (EVar "hk"))) (EVar "env")) (EApp (EApp (EVar "ieHeadRows") (EVar "None")) (EVar "env")))) (arm (PCon "None") () (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "args")) (ELit (LInt 1))) (EApp (EVar "ieRowsAll") (EVar "env")) (EListLit)))))))
(DTypeSig false "rowHeadUnifies" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ImplRow") (TyCon "Bool")))))
(DFunDef false "rowHeadUnifies" ((PVar "mctx") (PVar "args") (PVar "row")) (EBlock (DoLet false false (PVar "tys") (EApp (EVar "ieRowTys") (EVar "row"))) (DoLet false false (PVar "tvs") (EApp (EApp (EVar "freshTvMap") (EVar "mctx")) (EApp (EVar "dedup") (EApp (EApp (EVar "flatMap") (EVar "tyVarNames")) (EVar "tys"))))) (DoExpr (EApp (EApp (EVar "cohOverlap") (EApp (EApp (EVar "map") (EApp (EApp (EVar "fromAstType") (EVar "mctx")) (EVar "tvs"))) (EVar "tys"))) (EVar "args")))))
(DTypeSig false "repeatedGoalPairs" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Mono"))))))
(DFunDef false "repeatedGoalPairs" ((PVar "tys") (PVar "args")) (EMatch (EApp (EApp (EApp (EVar "positionBindings") (EVar "tys")) (EVar "args")) (EListLit)) (arm (PCon "Some" (PVar "binds")) () (EApp (EApp (EVar "repeatedBindings") (EVar "binds")) (EListLit))) (arm (PCon "None") () (EListLit))))
(DTypeSig true "goalAnsweredBy" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")))) (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))))
(DFunDef false "goalAnsweredBy" ((PVar "gctx") (PVar "answered") (PVar "iface") (PVar "args")) (EApp (EApp (EVar "anyList") (ELam ((PVar "g")) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "walkGoalSame") (EApp (EVar "fst") (EVar "g"))) (EApp (EVar "snd") (EVar "g"))) (EVar "iface")) (EVar "args")) (EApp (EApp (EVar "anyList") (ELam ((PVar "s")) (EApp (EApp (EApp (EApp (EVar "walkGoalSame") (EApp (EVar "fst") (EVar "s"))) (EApp (EVar "snd") (EVar "s"))) (EVar "iface")) (EVar "args")))) (EApp (EApp (EApp (EVar "superGoalClosure") (EVar "gctx")) (EApp (EVar "fst") (EVar "g"))) (EApp (EVar "snd") (EVar "g"))))))) (EVar "answered")))
(DTypeSig true "superGoalClosure" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))))))))
(DFunDef false "superGoalClosure" ((PVar "gctx") (PVar "iface") (PVar "args")) (EApp (EApp (EApp (EApp (EVar "superGoalClosureGo") (EVar "gctx")) (EListLit (ETuple (EVar "iface") (EVar "args")))) (EListLit (EVar "iface"))) (EListLit)))
(DTypeSig false "superGoalClosureGo" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")))) (TyFun (TyApp (TyCon "List") (TyCon "IfaceRef")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")))) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")))))))))
(DFunDef false "superGoalClosureGo" ((PVar "gctx") (PList) PWild (PVar "acc")) (EApp (EVar "reverse") (EVar "acc")))
(DFunDef false "superGoalClosureGo" ((PVar "gctx") (PCons (PTuple (PVar "iface") (PVar "args")) (PVar "rest")) (PVar "seen") (PVar "acc")) (EBlock (DoLet false false (PVar "step") (ELam ((PVar "st") (PVar "sg")) (EMatch (EVar "sg") (arm (PTuple (PVar "sup") (PCon "Some" (PVar "supArgs"))) ((GBool (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EApp (EVar "sameIfaceDecl") (EVar "sup"))) (EApp (EVar "fst") (EVar "st")))))) (ETuple (EBinOp "::" (EVar "sup") (EApp (EVar "fst") (EVar "st"))) (EBinOp "::" (ETuple (EVar "sup") (EVar "supArgs")) (EApp (EVar "snd") (EVar "st"))))) (arm PWild () (EVar "st"))))) (DoLet false false (PTuple (PVar "seen2") (PVar "found")) (EApp (EApp (EApp (EVar "fold") (EVar "step")) (ETuple (EVar "seen") (EListLit))) (EApp (EApp (EApp (EVar "directSuperGoals") (EVar "gctx")) (EVar "iface")) (EVar "args")))) (DoLet false false (PVar "fresh") (EApp (EVar "reverse") (EVar "found"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "superGoalClosureGo") (EVar "gctx")) (EBinOp "++" (EVar "rest") (EVar "fresh"))) (EVar "seen2")) (EBinOp "++" (EVar "found") (EVar "acc"))))))
(DTypeSig true "reqToObligation" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Require") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")))))))
(DFunDef false "reqToObligation" ((PVar "mctx") (PVar "subst") (PRec "Require" ((rf "requireHead" (PVar "ifaceR")) (rf "requireArgs" (PVar "tysR")) (rf "requireOrigin" (PVar "o"))) false)) (ETuple (ERecordCreate "IfaceRef" ((fa "irName" (EVar "ifaceR")) (fa "irOrigin" (EVar "o")))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "reqTyToMono") (EVar "mctx")) (EVar "subst"))) (EVar "tysR"))))
(DTypeSig true "occurrenceDispatchMonos" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "Mono")))))))
(DFunDef false "occurrenceDispatchMonos" ((PVar "typarams") (PVar "mty") (PVar "occ") (PVar "omitted")) (EApp (EApp (EVar "collectByParam") (EVar "typarams")) (EBinOp "++" (EApp (EApp (EApp (EVar "walkDispatch") (EVar "typarams")) (EApp (EVar "stripTyConstraints") (EVar "mty"))) (EVar "occ")) (EVar "omitted"))))
(DTypeSig true "walkDispatch" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))))))
(DFunDef false "walkDispatch" ((PVar "typarams") (PCon "TyVar" (PVar "n")) (PVar "m")) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "typarams")) (EListLit (ETuple (EVar "n") (EApp (EVar "normalize") (EVar "m")))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "walkDispatch" ((PVar "typarams") (PCon "TyFun" (PVar "a") (PVar "b")) (PVar "m")) (EMatch (EApp (EVar "peelQual") (EVar "m")) (arm (PCon "TFun" (PVar "ma") PWild (PVar "mb")) () (EBinOp "++" (EApp (EApp (EApp (EVar "walkDispatch") (EVar "typarams")) (EApp (EVar "stripTyConstraints") (EVar "a"))) (EVar "ma")) (EApp (EApp (EApp (EVar "walkDispatch") (EVar "typarams")) (EApp (EVar "stripTyConstraints") (EVar "b"))) (EVar "mb")))) (arm PWild () (EListLit))))
(DFunDef false "walkDispatch" ((PVar "typarams") (PCon "TyApp" (PVar "a") (PVar "b")) (PVar "m")) (EMatch (EApp (EVar "peelQual") (EVar "m")) (arm (PCon "TApp" (PVar "ma") (PVar "mb")) () (EBinOp "++" (EApp (EApp (EApp (EVar "walkDispatch") (EVar "typarams")) (EVar "a")) (EVar "ma")) (EApp (EApp (EApp (EVar "walkDispatch") (EVar "typarams")) (EVar "b")) (EVar "mb")))) (arm PWild () (EListLit))))
(DFunDef false "walkDispatch" ((PVar "typarams") (PCon "TyTuple" (PVar "ts")) (PVar "m")) (EMatch (EApp (EVar "tupleSpine") (EVar "m")) (arm (PCon "Some" (PVar "ms")) () (EApp (EApp (EVar "flatMap") (ELam ((PVar "p")) (EApp (EApp (EApp (EVar "walkDispatch") (EVar "typarams")) (EApp (EVar "fst") (EVar "p"))) (EApp (EVar "snd") (EVar "p"))))) (EApp (EApp (EVar "zip") (EVar "ts")) (EVar "ms")))) (arm PWild () (EListLit))))
(DFunDef false "walkDispatch" (PWild PWild PWild) (EListLit))
(DTypeSig true "collectByParam" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "collectByParam" ((PVar "typarams") (PVar "pairs")) (EMatch (EApp (EApp (EVar "collectByParamGo") (EVar "typarams")) (EVar "pairs")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "ms")) () (EVar "ms"))))
(DTypeSig false "collectByParamGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Mono"))))))
(DFunDef false "collectByParamGo" ((PList) PWild) (EApp (EVar "Some") (EListLit)))
(DFunDef false "collectByParamGo" ((PCons (PVar "p") (PVar "rest")) (PVar "pairs")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "p")) (EVar "pairs")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "m")) () (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "m") (EVar "_s")))) (EApp (EApp (EVar "collectByParamGo") (EVar "rest")) (EVar "pairs"))))))
(DTypeSig true "answeredOnlyByBindingHead" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))))
(DFunDef false "answeredOnlyByBindingHead" ((PVar "mctx") (PVar "headIds") (PVar "iface") (PVar "args")) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EVar "filterList") (EApp (EVar "ieRowOfIface") (EVar "iface"))) (EApp (EApp (EVar "improvementPool") (EVar "mctx")) (EVar "args")))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "anyList") (EApp (EApp (EVar "rowHeadUnifies") (EVar "mctx")) (EVar "args"))) (EVar "rows")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "row")) (EApp (EVar "isSome") (EApp (EApp (EApp (EApp (EVar "rowHeadSubstRigid") (EVar "mctx")) (EVar "headIds")) (EVar "args")) (EVar "row"))))) (EVar "rows")))))))
(DTypeSig true "residualSelectionStable" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")))) (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool")))))))
(DFunDef false "residualSelectionStable" ((PVar "mctx") (PVar "chosen") (PVar "context") (PVar "iface") (PVar "args")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "any") (ELam ((PVar "i")) (EApp (EApp (EVar "elem") (EVar "i")) (EVar "chosen")))) (EApp (EApp (EVar "flatMap") (EVar "monoUnboundIds")) (EVar "args")))) (EVar "True") (EIf (EVar "otherwise") (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "goalSelectionStable") (EVar "mctx")) (EVar "chosen")) (EVar "iface")) (EVar "args")) (EApp (EApp (EVar "allList") (ELam ((PVar "sg")) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "goalAnsweredBy") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "context")) (EApp (EVar "fst") (EVar "sg"))) (EApp (EVar "snd") (EVar "sg"))) (EApp (EApp (EApp (EApp (EVar "goalSelectionStable") (EVar "mctx")) (EVar "chosen")) (EApp (EVar "fst") (EVar "sg"))) (EApp (EVar "snd") (EVar "sg")))))) (EApp (EApp (EApp (EVar "superGoalClosure") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "iface")) (EVar "args")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "goalSelectionStable" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))))
(DFunDef false "goalSelectionStable" ((PVar "mctx") (PVar "chosen") (PVar "iface") (PVar "args")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "any") (ELam ((PVar "i")) (EApp (EApp (EVar "elem") (EVar "i")) (EVar "chosen")))) (EApp (EApp (EVar "flatMap") (EVar "monoUnboundIds")) (EVar "args")))) (EVar "True") (EMatch (EApp (EApp (EApp (EApp (EVar "stableGoalReach") (EVar "mctx")) (EVar "chosen")) (EVar "iface")) (EVar "args")) (arm (PCon "ReachMany") () (EVar "False")) (arm (PCon "ReachOne" PWild) () (EVar "True")) (arm (PCon "ReachNone") () (EVar "True")))))
(DTypeSig true "goalDefersOpenWorld" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ScopeId") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))))
(DFunDef false "goalDefersOpenWorld" ((PVar "mctx") (PVar "scope") (PVar "iface") (PVar "args")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "monoVectorClosed") (EVar "args"))) (EApp (EApp (EVar "allList") (EVar "monoHeadIsDecl")) (EVar "args"))) (EApp (EVar "isNonEmptyL") (EApp (EApp (EVar "flatMap") (EVar "monoUnboundIds")) (EVar "args")))) (EApp (EApp (EVar "allList") (ELam ((PVar "i")) (EApp (EApp (EVar "IdMap.has") (EVar "i")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "deferrableVarIds") "value")))) (EApp (EApp (EVar "flatMap") (EVar "monoUnboundIds")) (EVar "args")))) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "goalMatchesGiven") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "scope")) (EVar "iface")) (EVar "args")) (EApp (EApp (EVar "goalSlotStillOpen") (EVar "mctx")) (EVar "args")))))
(DTypeSig false "goalSlotStillOpen" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))
(DFunDef false "goalSlotStillOpen" ((PVar "mctx") (PList)) (EVar "False"))
(DFunDef false "goalSlotStillOpen" ((PVar "mctx") (PVar "args")) (EApp (EVar "not") (EApp (EApp (EVar "goalIdsClaimed") (EVar "mctx")) (EApp (EApp (EVar "flatMap") (EVar "monoUnboundIds")) (EVar "args")))))
(DTypeSig false "goalIdsClaimed" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool"))))
(DFunDef false "goalIdsClaimed" ((PVar "mctx") (PList)) (EVar "False"))
(DFunDef false "goalIdsClaimed" ((PVar "mctx") (PVar "ids")) (EApp (EApp (EVar "anyClaimRow") (EVar "ids")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funPredicateSlotsRef") "value")))
(DTypeSig false "anyClaimRow" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "PredicateSlot")))) (TyCon "Bool"))))
(DFunDef false "anyClaimRow" (PWild (PList)) (EVar "False"))
(DFunDef false "anyClaimRow" ((PVar "ids") (PCons (PTuple PWild (PVar "slots")) (PVar "rest"))) (EBinOp "||" (EApp (EApp (EVar "anyList") (ELam ((PVar "v")) (EApp (EApp (EVar "anyList") (ELam ((PVar "m")) (EApp (EApp (EVar "any") (ELam ((PVar "i")) (EApp (EApp (EVar "elem") (EVar "i")) (EVar "ids")))) (EApp (EVar "monoTyvarIds") (EVar "m"))))) (EVar "v")))) (EApp (EVar "predicateSlotArgs") (EVar "slots"))) (EApp (EApp (EVar "anyClaimRow") (EVar "ids")) (EVar "rest"))))
(DTypeSig true "goalMonos" (TyFun (TyCon "Obligation") (TyApp (TyCon "List") (TyCon "Mono"))))
(DFunDef false "goalMonos" ((PVar "o")) (EMatch (EFieldAccess (EVar "o") "oPayload") (arm (PCon "GPSite" PWild (PVar "m") (PVar "site")) () (EBinOp "::" (EVar "m") (EApp (EVar "siteKindMonos") (EVar "site")))) (arm (PCon "GPArith" (PVar "m")) () (EListLit (EVar "m"))) (arm (PCon "GPDictApp" (PVar "app")) () (EBinOp "++" (EFieldAccess (EVar "app") "pdaMonos") (EApp (EApp (EVar "flatMap") (EVar "identity")) (EFieldAccess (EVar "app") "pdaArgVecs")))) (arm (PCon "GPMethodDict" PWild) () (EListLit)) (arm (PCon "GPRecDictApp" (PCon "RecDictApp" PWild PWild PWild (PVar "m") PWild PWild)) () (EListLit (EVar "m")))))
(DTypeSig false "siteKindMonos" (TyFun (TyCon "SiteKind") (TyApp (TyCon "List") (TyCon "Mono"))))
(DFunDef false "siteKindMonos" ((PCon "SKReturn" PWild (PVar "m"))) (EListLit (EVar "m")))
(DFunDef false "siteKindMonos" ((PCon "SKAdmittedReturn" PWild PWild (PVar "m"))) (EListLit (EVar "m")))
(DFunDef false "siteKindMonos" ((PCon "SKExactReturn" PWild (PVar "request"))) (EListLit (EFieldAccess (EVar "request") "mrrOccurrence")))
(DFunDef false "siteKindMonos" ((PCon "SKNumReturn" PWild (PVar "m"))) (EListLit (EVar "m")))
(DFunDef false "siteKindMonos" ((PCon "SKArg" PWild (PVar "m") (PVar "omitted"))) (EBinOp "::" (EVar "m") (EApp (EApp (EVar "map") (EVar "snd")) (EVar "omitted"))))
(DFunDef false "siteKindMonos" ((PCon "SKOp" PWild)) (EListLit))
(DFunDef false "siteKindMonos" ((PCon "SKPredicateOp" PWild PWild)) (EListLit))
(DFunDef false "siteKindMonos" ((PCon "SKRLocal" PWild PWild (PVar "ms") PWild (PVar "vecs"))) (EBinOp "++" (EVar "ms") (EApp (EApp (EVar "flatMap") (EVar "identity")) (EVar "vecs"))))
(DTypeSig true "finishMethodReturnTrace" (TyFun (TyCon "TraceSink") (TyFun (TyCon "EvTable") (TyApp (TyCon "List") (TyCon "MethodReturnTraceEntry")))))
(DFunDef false "finishMethodReturnTrace" ((PVar "sink") (PVar "evidence")) (EApp (EApp (EVar "map") (EApp (EVar "publishMethodReturnTrace") (EVar "evidence"))) (EApp (EVar "reverse") (EFieldAccess (EFieldAccess (EVar "sink") "tsMethodReturnEntries") "value"))))
(DTypeSig false "publishMethodReturnTrace" (TyFun (TyCon "EvTable") (TyFun (TyCon "MethodReturnTraceEntry") (TyCon "MethodReturnTraceEntry"))))
(DFunDef false "publishMethodReturnTrace" ((PVar "evidence") (PVar "entry")) (EBlock (DoLet false false (PVar "published") (EMatch (EFieldAccess (EVar "entry") "mrtGoal") (arm (PCon "Some" (PVar "goal")) () (EApp (EApp (EVar "lookupTraceEvidence") (EVar "goal")) (EVar "evidence"))) (arm (PCon "None") () (EVar "None")))) (DoExpr (ERecordCreate "MethodReturnTraceEntry" ((fa "mrtStage" (EFieldAccess (EVar "entry") "mrtStage")) (fa "mrtInterface" (EFieldAccess (EVar "entry") "mrtInterface")) (fa "mrtMethod" (EFieldAccess (EVar "entry") "mrtMethod")) (fa "mrtArguments" (EFieldAccess (EVar "entry") "mrtArguments")) (fa "mrtScope" (EFieldAccess (EVar "entry") "mrtScope")) (fa "mrtOrigin" (EFieldAccess (EVar "entry") "mrtOrigin")) (fa "mrtGoal" (EFieldAccess (EVar "entry") "mrtGoal")) (fa "mrtPublished" (EVar "published")) (fa "mrtQualifiedBody" (EFieldAccess (EVar "entry") "mrtQualifiedBody")) (fa "mrtWanted" (EFieldAccess (EVar "entry") "mrtWanted")) (fa "mrtOutcome" (EFieldAccess (EVar "entry") "mrtOutcome")) (fa "mrtRoute" (EFieldAccess (EVar "entry") "mrtRoute")) (fa "mrtPrerequisites" (EFieldAccess (EVar "entry") "mrtPrerequisites")))))))
(DTypeSig false "lookupTraceEvidence" (TyFun (TyCon "EvId") (TyFun (TyCon "EvTable") (TyApp (TyCon "Option") (TyCon "EvVal")))))
(DFunDef false "lookupTraceEvidence" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupTraceEvidence" ((PVar "goal") (PCons (PCon "EvEntry" (PVar "candidate") (PVar "value")) (PVar "rest"))) (EIf (EApp (EApp (EVar "sameTraceEvId") (EVar "goal")) (EVar "candidate")) (EApp (EVar "Some") (EVar "value")) (EApp (EApp (EVar "lookupTraceEvidence") (EVar "goal")) (EVar "rest"))))
(DTypeSig false "sealMethodReturnGoals" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvTable") (TyFun (TyApp (TyCon "List") (TyCon "Obligation")) (TyTuple (TyApp (TyCon "List") (TyCon "Obligation")) (TyApp (TyCon "List") (TyCon "MethodReturnMemoView")))))))
(DFunDef false "sealMethodReturnGoals" ((PVar "gctx") (PVar "evidence") (PVar "goals")) (EApp (EApp (EApp (EApp (EVar "sealMethodReturnGoalsFrom") (EVar "gctx")) (EVar "evidence")) (EApp (EVar "reverse") (EVar "goals"))) (ETuple (EListLit) (EListLit))))
(DTypeSig false "sealMethodReturnGoalsFrom" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvTable") (TyFun (TyApp (TyCon "List") (TyCon "Obligation")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Obligation")) (TyApp (TyCon "List") (TyCon "MethodReturnMemoView"))) (TyTuple (TyApp (TyCon "List") (TyCon "Obligation")) (TyApp (TyCon "List") (TyCon "MethodReturnMemoView"))))))))
(DFunDef false "sealMethodReturnGoalsFrom" ((PVar "gctx") PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "sealMethodReturnGoalsFrom" ((PVar "gctx") (PVar "evidence") (PCons (PVar "goal") (PVar "rest")) (PTuple (PVar "goals") (PVar "views"))) (EMatch (EApp (EVar "exactReturnRequestOfGoal") (EVar "goal")) (arm (PCon "Some" (PVar "request")) () (EApp (EApp (EApp (EApp (EVar "sealMethodReturnGoalsFrom") (EVar "gctx")) (EVar "evidence")) (EVar "rest")) (ETuple (EVar "goals") (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "methodReturnMemoView") (EVar "gctx")) (EVar "evidence")) (EVar "goal")) (EVar "request")) (EVar "views"))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "sealMethodReturnGoalsFrom") (EVar "gctx")) (EVar "evidence")) (EVar "rest")) (ETuple (EBinOp "::" (EVar "goal") (EVar "goals")) (EVar "views"))))))
(DTypeSig false "methodReturnMemoView" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvTable") (TyFun (TyCon "Obligation") (TyFun (TyCon "MethodReturnRequest") (TyCon "MethodReturnMemoView"))))))
(DFunDef false "methodReturnMemoView" ((PVar "gctx") (PVar "evidence") (PVar "goal") (PVar "request")) (EBlock (DoLet false false (PTuple (PVar "outcome") (PVar "prerequisites")) (EMatch (EFieldAccess (EFieldAccess (EVar "request") "mrrResolution") "value") (arm (PCon "None") () (ETuple (ELit (LString "legacy")) (EListLit))) (arm (PCon "Some" (PVar "resolution")) () (ETuple (EApp (EVar "methodReturnMemoOutcome") (EFieldAccess (EVar "resolution") "mrrOutcome")) (EApp (EVar "methodReturnMemoPrerequisites") (EFieldAccess (EVar "resolution") "mrrOutcome")))))) (DoExpr (ERecordCreate "MethodReturnMemoView" ((fa "mrmvInterface" (EApp (EVar "methodReturnMemoIface") (EFieldAccess (EVar "request") "mrrIface"))) (fa "mrmvMethod" (EFieldAccess (EVar "request") "mrrName")) (fa "mrmvArguments" (EApp (EApp (EVar "map") (EVar "methodReturnMemoArguments")) (EApp (EApp (EVar "methodReturnArgs") (EVar "gctx")) (EVar "request")))) (fa "mrmvOutcome" (EVar "outcome")) (fa "mrmvPrerequisites" (EVar "prerequisites")) (fa "mrmvEvidence" (EApp (EApp (EVar "methodReturnMemoEvidence") (EFieldAccess (EVar "goal") "oEv")) (EVar "evidence"))))))))
(DTypeSig false "methodReturnMemoArguments" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "methodReturnMemoArguments" ((PVar "arguments")) (EApp (EApp (EVar "map") (EVar "ppMono")) (EVar "arguments")))
(DTypeSig false "methodReturnMemoIface" (TyFun (TyCon "IfaceRef") (TyCon "String")))
(DFunDef false "methodReturnMemoIface" ((PVar "iface")) (EBlock (DoLet false false (PVar "identity") (EApp (EApp (EVar "ifaceIdentity") (EFieldAccess (EVar "iface") "irOrigin")) (EFieldAccess (EVar "iface") "irName"))) (DoExpr (EIf (EBinOp "==" (EVar "identity") (ELit (LString ""))) (EFieldAccess (EVar "iface") "irName") (EVar "identity")))))
(DTypeSig false "methodReturnMemoOutcome" (TyFun (TyCon "SolverOutcome") (TyCon "String")))
(DFunDef false "methodReturnMemoOutcome" ((PCon "Solved" (PCon "GivenEvidence" PWild))) (ELit (LString "given")))
(DFunDef false "methodReturnMemoOutcome" ((PCon "Solved" (PCon "InstanceEvidence" PWild PWild PWild PWild))) (ELit (LString "instance")))
(DFunDef false "methodReturnMemoOutcome" ((PCon "Solved" (PCon "SuperclassEvidence" PWild PWild))) (ELit (LString "superclass")))
(DFunDef false "methodReturnMemoOutcome" ((PCon "Deferred" PWild PWild)) (ELit (LString "deferred")))
(DFunDef false "methodReturnMemoOutcome" ((PCon "Insoluble" PWild (PCon "MissingInstance"))) (ELit (LString "missing")))
(DFunDef false "methodReturnMemoOutcome" ((PCon "Insoluble" PWild (PCon "AmbiguousInstances" PWild))) (ELit (LString "ambiguous")))
(DFunDef false "methodReturnMemoOutcome" ((PCon "Insoluble" PWild (PCon "ResolutionCycle" PWild))) (ELit (LString "cycle")))
(DTypeSig false "methodReturnMemoPrerequisites" (TyFun (TyCon "SolverOutcome") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "methodReturnMemoPrerequisites" ((PCon "Solved" (PCon "InstanceEvidence" PWild PWild (PVar "prerequisites") PWild))) (EApp (EApp (EVar "map") (ELam ((PVar "prerequisite")) (ETuple (EApp (EVar "methodReturnMemoIface") (EFieldAccess (EVar "prerequisite") "prerequisiteInterface")) (EApp (EApp (EVar "map") (EVar "ppMono")) (EFieldAccess (EVar "prerequisite") "prerequisiteArguments"))))) (EVar "prerequisites")))
(DFunDef false "methodReturnMemoPrerequisites" (PWild) (EListLit))
(DTypeSig false "methodReturnMemoEvidence" (TyFun (TyCon "EvId") (TyFun (TyCon "EvTable") (TyCon "String"))))
(DFunDef false "methodReturnMemoEvidence" ((PVar "goal") (PVar "evidence")) (EMatch (EApp (EApp (EVar "lookupTraceEvidence") (EVar "goal")) (EVar "evidence")) (arm (PCon "Some" (PCon "EvOne" (PVar "route"))) () (EApp (EVar "methodReturnMemoRoute") (EVar "route"))) (arm (PCon "Some" (PCon "EvMany" (PVar "routes"))) () (EApp (EApp (EVar "join") (ELit (LString ","))) (EApp (EApp (EVar "map") (EVar "methodReturnMemoRoute")) (EVar "routes")))) (arm (PCon "Some" (PCon "EvLit" PWild (PVar "route"))) () (EApp (EVar "methodReturnMemoRoute") (EVar "route"))) (arm (PCon "Some" (PCon "EvHead" (PVar "head"))) () (EBinOp "++" (EBinOp "++" (ELit (LString "head:")) (EApp (EVar "display") (EVar "head"))) (ELit (LString "")))) (arm (PCon "None") () (ELit (LString "unpublished")))))
(DTypeSig false "methodReturnMemoRoute" (TyFun (TyCon "Route") (TyCon "String")))
(DFunDef false "methodReturnMemoRoute" ((PCon "RNone")) (ELit (LString "none")))
(DFunDef false "methodReturnMemoRoute" ((PCon "RKey" (PVar "key") (PVar "prerequisites") (PVar "supers"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "key:")) (EApp (EVar "display") (EVar "key"))) (ELit (LString "["))) (EApp (EVar "display") (EApp (EApp (EVar "join") (ELit (LString ","))) (EApp (EApp (EVar "map") (EVar "methodReturnMemoRoute")) (EVar "prerequisites"))))) (ELit (LString "]"))) (EApp (EVar "display") (EApp (EVar "methodReturnMemoSupers") (EVar "supers")))) (ELit (LString ""))))
(DFunDef false "methodReturnMemoRoute" ((PCon "RDict" (PVar "name"))) (EBinOp "++" (EBinOp "++" (ELit (LString "given:")) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "methodReturnMemoRoute" ((PCon "RDictFwd" (PVar "name"))) (EBinOp "++" (EBinOp "++" (ELit (LString "forwarded:")) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "methodReturnMemoRoute" ((PCon "RLocal" (PVar "name") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "local:")) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "methodReturnMemoRoute" ((PCon "RScalar" (PVar "name"))) (EBinOp "++" (EBinOp "++" (ELit (LString "scalar:")) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "methodReturnMemoRoute" ((PCon "RProj" (PVar "r") (PVar "path"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "projected:")) (EApp (EVar "display") (EApp (EVar "methodReturnMemoRoute") (EVar "r")))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EApp (EVar "join") (ELit (LString "."))) (EApp (EApp (EVar "map") (EVar "intToString")) (EVar "path"))))) (ELit (LString ""))))
(DTypeSig false "methodReturnMemoSupers" (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyCon "String")))
(DFunDef false "methodReturnMemoSupers" ((PList)) (ELit (LString "")))
(DFunDef false "methodReturnMemoSupers" ((PVar "supers")) (EBinOp "++" (EBinOp "++" (ELit (LString "{")) (EApp (EVar "display") (EApp (EApp (EVar "join") (ELit (LString ","))) (EApp (EApp (EVar "map") (EVar "methodReturnMemoRoute")) (EVar "supers"))))) (ELit (LString "}"))))
(DTypeSig false "isSemanticGivenAnswer" (TyFun (TyApp (TyCon "Option") (TyCon "AssumAnswer")) (TyCon "Bool")))
(DFunDef false "isSemanticGivenAnswer" ((PCon "Some" (PCon "SemanticGiven" (PCon "GivenEvidence" PWild)))) (EVar "True"))
(DFunDef false "isSemanticGivenAnswer" (PWild) (EVar "False"))
(DTypeSig false "isLegacyPredicateAnswer" (TyFun (TyApp (TyCon "Option") (TyCon "AssumAnswer")) (TyCon "Bool")))
(DFunDef false "isLegacyPredicateAnswer" ((PCon "Some" (PCon "LegacyPredicate" PWild))) (EVar "True"))
(DFunDef false "isLegacyPredicateAnswer" (PWild) (EVar "False"))
(DTypeSig false "scopeGivenProbe" (TyFun (TyCon "Unit") (TyApp (TyCon "List") (TyCon "Bool"))))
(DFunDef false "scopeGivenProbe" (PWild) (EBlock (DoLet false false (PVar "gctx") (EApp (EVar "probeGraphCtx") (ELit LUnit))) (DoLet false false (PVar "store") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))) (DoLet false false (PVar "root") (EApp (EApp (EApp (EApp (EApp (EVar "Scopes.freshScope") (EVar "store")) (EVar "None")) (ELit (LInt 0))) (ELit (LString "given-probe"))) (EVar "ModuleOwner"))) (DoLet false false (PVar "owner") (EApp (EApp (EApp (EApp (EApp (EVar "Scopes.freshScope") (EVar "store")) (EApp (EVar "Some") (EVar "root"))) (ELit (LInt 1))) (ELit (LString "given-probe"))) (EApp (EVar "BindingOwner") (ELit (LString "owner"))))) (DoLet false false (PVar "sibling") (EApp (EApp (EApp (EApp (EApp (EVar "Scopes.freshScope") (EVar "store")) (EApp (EVar "Some") (EVar "root"))) (ELit (LInt 1))) (ELit (LString "given-probe"))) (EApp (EVar "BindingOwner") (ELit (LString "sibling"))))) (DoLet false false (PVar "iface") (ERecordCreate "IfaceRef" ((fa "irName" (ELit (LString "PairGiven"))) (fa "irOrigin" (EApp (EVar "OriginModule") (ELit (LString "given-probe"))))))) (DoLet false false (PVar "args") (EListLit (EApp (EVar "tconBuiltin") (ELit (LString "Int"))) (EApp (EVar "tconBuiltin") (ELit (LString "Bool"))))) (DoLet false false (PVar "slot") (ERecordCreate "PredicateSlot" ((fa "psIface" (EVar "iface")) (fa "psArgs" (EApp (EVar "PSArgsKnown") (EVar "args"))) (fa "psBoundIds" (EListLit (ELit (LInt 41))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "pushGiven") (EVar "gctx")) (EVar "GMPredicate")) (EVar "DirectGiven")) (EVar "slot")) (EApp (EApp (EVar "Scopes.binderAt") (EVar "owner")) (ELit (LInt 0))))) (DoLet false false (PVar "exact") (ERecordCreate "PredicateRequest" ((fa "prIface" (EVar "iface")) (fa "prArgs" (EApp (EVar "PSArgsKnown") (EVar "args")))))) (DoLet false false (PVar "unknown") (ERecordCreate "PredicateRequest" ((fa "prIface" (EVar "iface")) (fa "prArgs" (EVar "PSArgsUnknown"))))) (DoLet false false (PVar "truncated") (ERecordCreate "PredicateRequest" ((fa "prIface" (EVar "iface")) (fa "prArgs" (EApp (EVar "PSArgsKnown") (EListLit (EApp (EVar "tconBuiltin") (ELit (LString "Int"))))))))) (DoLet false false (PVar "witnessIface") (ERecordCreate "IfaceRef" ((fa "irName" (ELit (LString "WitnessGiven"))) (fa "irOrigin" (EApp (EVar "OriginModule") (ELit (LString "given-probe"))))))) (DoLet false false (PVar "witnessSlot") (ERecordCreate "PredicateSlot" ((fa "psIface" (EVar "witnessIface")) (fa "psArgs" (EApp (EVar "PSArgsKnown") (EListLit (EApp (EVar "tconBuiltin") (ELit (LString "Int")))))) (fa "psBoundIds" (EListLit (ELit (LInt 73))))))) (DoLet false false (PVar "witnessRequest") (ERecordCreate "PredicateRequest" ((fa "prIface" (EVar "witnessIface")) (fa "prArgs" (EApp (EVar "PSArgsKnown") (EListLit (EApp (EVar "tconBuiltin") (ELit (LString "Int"))))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "pushGiven") (EVar "gctx")) (EVar "GMIdWitnessed")) (EVar "DirectGiven")) (EVar "witnessSlot")) (EApp (EApp (EVar "Scopes.binderAt") (EVar "owner")) (ELit (LInt 1))))) (DoLet false false (PVar "compatibleIface") (ERecordCreate "IfaceRef" ((fa "irName" (ELit (LString "CompatibleGiven"))) (fa "irOrigin" (EApp (EVar "OriginModule") (ELit (LString "given-probe"))))))) (DoLet false false (PVar "compatibleSlot") (ERecordCreate "PredicateSlot" ((fa "psIface" (EVar "compatibleIface")) (fa "psArgs" (EVar "PSArgsUnknown")) (fa "psBoundIds" (EListLit (ELit (LInt 89))))))) (DoLet false false (PVar "compatibleRequest") (ERecordCreate "PredicateRequest" ((fa "prIface" (EVar "compatibleIface")) (fa "prArgs" (EApp (EVar "PSArgsKnown") (EListLit (EApp (EVar "tconBuiltin") (ELit (LString "Int"))))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "pushGiven") (EVar "gctx")) (EVar "GMPredicate")) (EVar "DirectGiven")) (EVar "compatibleSlot")) (EApp (EApp (EVar "Scopes.binderAt") (EVar "owner")) (ELit (LInt 2))))) (DoLet false false (PVar "givens") (EApp (EApp (EVar "givensForScope") (EVar "gctx")) (EVar "owner"))) (DoLet false false (PVar "result") (EListLit (EApp (EApp (EApp (EApp (EVar "anyGivenMatches") (EVar "gctx")) (EVar "exact")) (EVar "owner")) (EVar "givens")) (EApp (EVar "not") (EApp (EApp (EApp (EApp (EVar "anyGivenMatches") (EVar "gctx")) (EVar "exact")) (EVar "sibling")) (EVar "givens"))) (EApp (EVar "not") (EApp (EApp (EApp (EApp (EVar "anyGivenMatches") (EVar "gctx")) (EVar "truncated")) (EVar "owner")) (EVar "givens"))) (EApp (EVar "not") (EApp (EApp (EApp (EApp (EVar "anyGivenMatches") (EVar "gctx")) (EVar "witnessRequest")) (EVar "owner")) (EVar "givens"))) (EApp (EVar "isSome") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "firstPredForEnclAt") (EVar "gctx")) (EVar "GSImplRequires")) (ELit (LInt 73))) (EVar "witnessRequest")) (EVar "owner")) (EVar "givens"))) (EApp (EVar "isNone") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "firstPredForEnclAt") (EVar "gctx")) (EVar "GSImplRequires")) (ELit (LInt 74))) (EVar "witnessRequest")) (EVar "owner")) (EVar "givens"))) (EApp (EVar "isSemanticGivenAnswer") (EApp (EApp (EApp (EApp (EVar "firstPredForEncl") (EVar "gctx")) (EVar "exact")) (EVar "owner")) (EVar "givens"))) (EApp (EVar "isLegacyPredicateAnswer") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "firstPredForEnclAt") (EVar "gctx")) (EVar "GSPredicateOnly")) (ELit (LInt 41))) (EVar "unknown")) (EVar "owner")) (EVar "givens"))) (EApp (EVar "isLegacyPredicateAnswer") (EApp (EApp (EApp (EApp (EApp (EVar "firstPredForEnclResidual") (EVar "gctx")) (ELit (LString "PairGiven"))) (EVar "args")) (EVar "owner")) (EVar "givens"))) (EApp (EVar "isLegacyPredicateAnswer") (EApp (EApp (EApp (EApp (EVar "firstPredForEncl") (EVar "gctx")) (EVar "compatibleRequest")) (EVar "owner")) (EVar "givens"))))) (DoExpr (EVar "result"))))
(DTypeSig true "methodSlotBoundIds" (TyFun (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "methodSlotBoundIds" ((PVar "slots")) (EApp (EApp (EVar "map") (ELam ((PVar "slot")) (EFieldAccess (EFieldAccess (EVar "slot") "mpsPredicate") "psBoundIds"))) (EVar "slots")))
(DTypeSig true "methodSlotPositions" (TyFun (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "methodSlotPositions" ((PVar "slots")) (EApp (EApp (EVar "map") (ELam ((PVar "slot")) (EFieldAccess (EVar "slot") "mpsPositions"))) (EVar "slots")))
(DTypeSig true "methodSlotIdsAtPositions" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "methodSlotIdsAtPositions" ((PVar "ids") (PVar "slots")) (EApp (EApp (EVar "map") (ELam ((PVar "slot")) (EApp (EApp (EVar "map") (ELam ((PVar "pos")) (EApp (EApp (EVar "optionOr") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EApp (EApp (EVar "get") (EVar "pos")) (EVar "ids"))))) (EFieldAccess (EVar "slot") "mpsPositions")))) (EVar "slots")))
(DTypeSig true "methodSlotArgumentIds" (TyFun (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "methodSlotArgumentIds" ((PVar "slots")) (EApp (EApp (EVar "map") (EVar "methodSlotArgumentIdsOne")) (EVar "slots")))
(DTypeSig false "methodSlotArgumentIdsOne" (TyFun (TyCon "MethodPredicateSlot") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "methodSlotArgumentIdsOne" ((PVar "slot")) (EMatch (EFieldAccess (EFieldAccess (EVar "slot") "mpsPredicate") "psArgs") (arm (PCon "PSArgsUnknown") () (EListLit)) (arm (PCon "PSArgsKnown" (PVar "args")) () (EApp (EApp (EVar "flatMap") (EVar "monoTyvarIds")) (EVar "args")))))
(DTypeSig true "methodRowRegistrySlotIds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "methodRowRegistrySlotIds" ((PVar "mctx") (PVar "key")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodPredicateSlotsRef") "value")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "slots")) () (EApp (EVar "methodSlotBoundIds") (EVar "slots")))))
(DTypeSig true "numAnchorObservationView" (TyFun (TyCon "NumAnchorTestObservation") (TyTuple (TyCon "String") (TyCon "Bool") (TyCon "Bool") (TyCon "String") (TyCon "String"))))
(DFunDef false "numAnchorObservationView" ((PVar "observation")) (ETuple (EFieldAccess (EVar "observation") "natoCase") (EFieldAccess (EVar "observation") "natoHasRow") (EBinOp "==" (EFieldAccess (EVar "observation") "natoIface") (ELit (LString "Num"))) (EFieldAccess (EVar "observation") "natoSchemeBody") (EFieldAccess (EVar "observation") "natoDeclaredType")))
(DTypeSig true "methodReturnProbeIface" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyCon "Decl")))))
(DFunDef false "methodReturnProbeIface" ((PVar "moduleId") (PVar "ifaceName") (PVar "methodTy")) (EApp (EApp (EApp (EApp (EVar "methodRowTestIface") (EVar "moduleId")) (EVar "ifaceName")) (EListLit (ELit (LString "a")))) (EListLit (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (ELit (LString "make"))) (EVar "methodTy")) (EVar "None")) (EVar "None")))))
(DTypeSig true "methodReturnProbeImpl" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Decl"))))
(DFunDef false "methodReturnProbeImpl" ((PVar "moduleId") (PVar "ifaceName")) (ERecordCreate "DImpl" ((fa "pub" (EVar "False")) (fa "iface" (EVar "ifaceName")) (fa "tys" (EListLit (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None")))) (fa "reqs" (EListLit)) (fa "methods" (EListLit (EApp (EApp (EApp (EVar "ImplMethod") (ELit (LString "make"))) (EListLit)) (EApp (EVar "ELit") (EVar "LUnit"))))) (fa "implOrigin" (EApp (EVar "OriginModule") (EVar "moduleId"))) (fa "implIfaceLoc" (EVar "None")))))
(DTypeSig true "methodReturnProbeScope" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "ScopeId"))))
(DFunDef false "methodReturnProbeScope" ((PVar "mctx") (PVar "moduleId")) (EBlock (DoLet false false (PVar "scope") (EApp (EApp (EApp (EApp (EApp (EVar "Scopes.freshScope") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EVar "None")) (ELit (LInt 0))) (EVar "moduleId")) (EVar "ModuleOwner"))) (DoExpr (EApp (EApp (EVar "openScope") (EVar "mctx")) (EVar "scope"))) (DoExpr (EVar "scope"))))
(DTypeSig true "methodReturnProbeOccurrence" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodSchemeRow") (TyCon "MethodTrackedInstantiation"))))
(DFunDef false "methodReturnProbeOccurrence" ((PVar "mctx") (PVar "row")) (EBlock (DoLet false false (PVar "inst") (EApp (EApp (EVar "instantiateMethodTracked") (EVar "mctx")) (EFieldAccess (EVar "row") "msrScheme"))) (DoExpr (EApp (EApp (EApp (EVar "unify") (EVar "mctx")) (EApp (EVar "stripArrows") (EFieldAccess (EVar "inst") "mtiBody"))) (EApp (EVar "tconBuiltin") (ELit (LString "Int"))))) (DoExpr (EVar "inst"))))
(DTypeSig true "methodReturnProbeSpelling" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodSchemeRow") (TyCon "Unit"))))
(DFunDef false "methodReturnProbeSpelling" ((PVar "mctx") (PVar "row")) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodAliasEntriesRef")) (EApp (EApp (EApp (EVar "omInsert") (ELit (LString "make"))) (ETuple (EFieldAccess (EVar "row") "msrIface") (EFieldAccess (EVar "row") "msrTyparams") (EFieldAccess (EVar "row") "msrType") (EListLit))) (EVar "omEmpty"))))
(DTypeSig true "methodReturnProbeRouteKey" (TyFun (TyCon "Route") (TyCon "String")))
(DFunDef false "methodReturnProbeRouteKey" ((PCon "RKey" (PVar "key") PWild PWild)) (EVar "key"))
(DFunDef false "methodReturnProbeRouteKey" (PWild) (ELit (LString "")))
(DTypeSig true "methodReturnSelectedIdentity" (TyFun (TyCon "MethodReturnResolution") (TyCon "Int")))
(DFunDef false "methodReturnSelectedIdentity" ((PVar "resolution")) (EMatch (EFieldAccess (EVar "resolution") "mrrOutcome") (arm (PCon "Solved" (PCon "InstanceEvidence" (PCon "RequestInstanceId" (PVar "identity")) PWild PWild PWild)) () (EVar "identity")) (arm PWild () (EUnOp "-" (ELit (LInt 1))))))
(DTypeSig false "methodReturnProbeSlotIfaces" (TyFun (TyApp (TyCon "List") (TyCon "PredicateSlot")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "methodReturnProbeSlotIfaces" ((PVar "slots")) (EApp (EApp (EVar "map") (ELam ((PVar "slot")) (EFieldAccess (EFieldAccess (EVar "slot") "psIface") "irName"))) (EVar "slots")))
(DTypeSig true "methodReturnProbeGoalIfaces" (TyFun (TyApp (TyCon "List") (TyCon "Obligation")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "methodReturnProbeGoalIfaces" ((PList)) (EListLit))
(DFunDef false "methodReturnProbeGoalIfaces" ((PCons (PVar "goal") (PVar "rest"))) (EMatch (EFieldAccess (EVar "goal") "oPayload") (arm (PCon "GPMethodDict" (PVar "pending")) () (EBinOp "++" (EApp (EVar "methodReturnProbeSlotIfaces") (EFieldAccess (EVar "pending") "pmdSlots")) (EApp (EVar "methodReturnProbeGoalIfaces") (EVar "rest")))) (arm PWild () (EApp (EVar "methodReturnProbeGoalIfaces") (EVar "rest")))))
(DTypeSig true "methodReturnProbeOblIfaces" (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "methodReturnProbeOblIfaces" ((PList)) (EListLit))
(DFunDef false "methodReturnProbeOblIfaces" ((PCons (PVar "obl") (PVar "rest"))) (EBlock (DoLet false false (PVar "here") (EMatch (EFieldAccess (EVar "obl") "prov") (arm (PCon "PMethodLevel") () (EListLit (EFieldAccess (EFieldAccess (EFieldAccess (EVar "obl") "pred") "iface") "irName"))) (arm PWild () (EListLit)))) (DoExpr (EBinOp "++" (EVar "here") (EApp (EVar "methodReturnProbeOblIfaces") (EVar "rest"))))))
(DTypeSig true "methodReturnMemoCurrentViews" (TyFun (TyCon "GraphCtx") (TyApp (TyCon "List") (TyCon "MethodReturnMemoView"))))
(DFunDef false "methodReturnMemoCurrentViews" ((PVar "gctx")) (EApp (EVar "snd") (EApp (EApp (EApp (EVar "sealMethodReturnGoals") (EVar "gctx")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "evTable") "value")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "goals") "value"))))
# MARK
(DUse false (UseGroup ("types" "tc_types") ((mem "Provenance" true) (mem "OblProjection" true) (mem "GoalReach" true) (mem "GoalPayload" true) (mem "GivenScope" true) (mem "GivenProvenance" true) (mem "GivenMatch" true) (mem "AdmittedAnswer" true) (mem "AssumAnswer" true) (mem "BuiltinClass" true) (mem "EvDest" true) (mem "GoalKind" true) (mem "GoalWindow" true) (mem "GraphMarks" true) (mem "MethodReturnMemoView" true) (mem "MethodReturnResolution" true) (mem "MethodReturnTraceEntry" true) (mem "MethodReturnTraceStage" true) (mem "MethodTemplateGivenResult" true) (mem "Obligation" true) (mem "PendingDictApp" true) (mem "PredicateRequest" true) (mem "PredicateSlot" true) (mem "PredicateSlotArgs" true) (mem "SiteCtx" true) (mem "SiteKind" true) (mem "SolvedGoalEntry" true) (mem "Undetermined" true) (mem "UObligation" true) (mem "DynCtx" false) (mem "dynFor" false) (mem "GivenEntry" false) (mem "GraphCtx" false) (mem "ImplEnv" false) (mem "ImplRow" false) (mem "LocalAbs" false) (mem "MethodPredicateSlot" false) (mem "MethodPredicateTemplate" false) (mem "MethodReturnRequest" false) (mem "MethodRow" false) (mem "MethodSchemeRow" false) (mem "MethodTrackedInstantiation" false) (mem "ModuleCtx" false) (mem "NumAnchorTestObservation" false) (mem "PendingEntry" false) (mem "PendingMethodDict" false) (mem "RecDictApp" false) (mem "ReqWalk" false) (mem "TraceSink" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "allConcreteHeads" false) (mem "anyListM" false) (mem "cohApply" false) (mem "cohOverlap" false) (mem "cohOverlapGo" false) (mem "containsI" false) (mem "dedupI" false) (mem "exactReturnRequestOfGoal" false) (mem "findTvarInMono" false) (mem "headTyconMono" false) (mem "matchEqMono" false) (mem "matchOneSided" false) (mem "matchStep" false) (mem "matchTyMono" false) (mem "monoHeadIsDecl" false) (mem "monoMintedBefore" false) (mem "monoSameGiven" false) (mem "monoSizes" false) (mem "monoTyvarIds" false) (mem "monoUnboundIds" false) (mem "monoVarCells" false) (mem "monoVecSameGiven" false) (mem "monoVectorClosed" false) (mem "peelQual" false) (mem "rigidSigPairs" false) (mem "sigCellsOf" false) (mem "sigRigidBindings" false) (mem "stripArrows" false) (mem "stripTyConstraints" false) (mem "substMono" false) (mem "tconBuiltin" false) (mem "tyvarId" false) (mem "tyVarNames" false) (mem "walkMonosSame" false) (mem "unrigidSig" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "callUOblsWindow" false) (mem "currentScopeStore" false) (mem "initialModuleCtx" false) (mem "moduleWindow" false) (mem "probeGraphCtx" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "anyArgMentions" false) (mem "dispatchTyparams" false) (mem "ieHeadRows" false) (mem "ieRowIfaceMatches" false) (mem "ieRowOfIface" false) (mem "ieRowsAll" false) (mem "ieRowTys" false) (mem "instRefSeq" false) (mem "methodArgs" false) (mem "methodRowIface" false) (mem "methodRowTestIface" false) (mem "methodSlotKey" false) (mem "originMethodName" false) (mem "sameIfaceDecl" false))))
(DUse false (UseGroup ("types" "tc_diag") ((mem "erredDuring" false))))
(DUse false (UseGroup ("types" "tc_scope") ((mem "methodAdmittedHere" false) (mem "methodVisibleHere" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "enterLevel" false) (mem "exitLevel" false) (mem "freshEffvar" false) (mem "freshTvMap" false) (mem "freshVar" false) (mem "instantiateMethodTracked" false) (mem "monoUnboundVarLevels" false) (mem "predicateSlotArgs" false) (mem "unify" false) (mem "unifyIn" false))))
(DUse false (UseGroup ("types" "tc_decls_types") ((mem "fromAstType" false) (mem "reqTyToMono" false))))
(DUse false (UseGroup ("types" "tc_solve_givens") ((mem "activeDictPredOf" false) (mem "activeDictVarOfEncl" false) (mem "anyGivenMatches" false) (mem "assumAnswerEvidence" false) (mem "assumAnswerRoute" false) (mem "enclSlot" false) (mem "firstPredForEncl" false) (mem "firstPredForEnclAt" false) (mem "firstPredForEnclResidual" false) (mem "givenInScope" false) (mem "givenRoute" false) (mem "givensForScope" false) (mem "goalMatchesGiven" false) (mem "noteAssumption" false) (mem "predicateRequestMatchesSlot" false) (mem "projectedGivenOf" false) (mem "pushGiven" false))))
(DUse false (UseGroup ("types" "tc_solve_entail") ((mem "determinedGoalInstance" false) (mem "directSuperGoals" false) (mem "enteredGoalKey" false) (mem "freshRowHeads" false) (mem "goalCandidates" false) (mem "goalHeadCon" false) (mem "goalIsProjection" false) (mem "goalRows" false) (mem "ieSelectRowByIface" false) (mem "paramMonoOf" false) (mem "positionBindings" false) (mem "repeatedBindings" false) (mem "reqWalkMemo" false) (mem "reqWalkStart" false) (mem "routeOfD" false) (mem "rowCountsFor" false) (mem "rowHeadMatches" false) (mem "rowRouteKey" false) (mem "selectedCallSupers" false) (mem "selectedRowReqMatch" false) (mem "stableGoalReach" false) (mem "superRoutesAt" false) (mem "findMatchingImplReqsU" false))))
(DUse false (UseGroup ("types" "solver_contract") ((mem "SolverFailure" true) (mem "ClassPredicate" true) (mem "GoalOrigin" true) (mem "Instantiation" true) (mem "InstantiationArgument" true) (mem "SolverBlocker" true) (mem "SolverOutcome" true) (mem "Wanted" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "TyConOrigin" true) (mem "Ns" true) (mem "Lit" true) (mem "Expr" true) (mem "Decl" true) (mem "EvEntry" true) (mem "EvId" true) (mem "EvVal" true) (mem "IfaceMethod" true) (mem "ImplMethod" true) (mem "Loc" true) (mem "Require" true) (mem "Route" true) (mem "Ty" true) (mem "EvTable" false) (mem "ifaceIdentity" false) (mem "mkIdent" false) (mem "tyConBuiltin" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffRow" true) (mem "pureRow" false))))
(DUse false (UseGroup ("types" "evidence") ((mem "SolverEvidence" true) (mem "PrerequisiteEvidence" true) (mem "RequestInstanceId" true) (mem "ScopeId" true) (mem "SuperEvidence" true) (mem "goalIdForDestination" false))))
(DUse false (UseGroup ("types" "registry") ((mem "HeadKey" true) (mem "headKeyTag" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Mono" true) (mem "lookupAssocI" false) (mem "normalize" false) (mem "ppMono" false) (mem "tupleSpine" false))))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "anyList" false) (mem "contains" false) (mem "dedup" false) (mem "endsWith" false) (mem "eqStr" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "isSome" false) (mem "listLen" false) (mem "lookupAssoc" false) (mem "orElseOpt" false) (mem "reverseL" false) (mem "splitOnChar" false))))
(DUse false (UseGroup ("list") ((mem "drop" false) (mem "get" false) (mem "head" false) (mem "indexed" false) (mem "reverse" false) (mem "take" false) (mem "zip" false))))
(DUse false (UseGroup ("string") ((mem "join" false))))
(DUse false (UseGroup ("types" "evidence_complete") ((mem "innerNone" false))))
(DUse false (UseAlias ("types" "scopes") "Scopes"))
(DUse false (UseAlias ("map") "IdMap"))
(DUse false (UseGroup ("types" "scopes") ((mem "ScopeOwner" true))))
(DTypeSig true "goalKindTag" (TyFun (TyCon "GoalKind") (TyCon "Int")))
(DFunDef false "goalKindTag" ((PCon "GKReturnSite")) (ELit (LInt 0)))
(DFunDef false "goalKindTag" ((PCon "GKArgStamp")) (ELit (LInt 1)))
(DFunDef false "goalKindTag" ((PCon "GKRLocalSite")) (ELit (LInt 2)))
(DFunDef false "goalKindTag" ((PCon "GKBinopSite")) (ELit (LInt 3)))
(DFunDef false "goalKindTag" ((PCon "GKUnopSite")) (ELit (LInt 4)))
(DFunDef false "goalKindTag" ((PCon "GKArithSite")) (ELit (LInt 5)))
(DFunDef false "goalKindTag" ((PCon "GKDictApp")) (ELit (LInt 6)))
(DFunDef false "goalKindTag" ((PCon "GKMethodDict")) (ELit (LInt 7)))
(DFunDef false "goalKindTag" ((PCon "GKRecDictApp")) (ELit (LInt 8)))
(DTypeSig true "pushGoal" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Obligation") (TyCon "Unit"))))
(DFunDef false "pushGoal" ((PVar "gctx") (PVar "o")) (EBlock (DoLet false false (PVar "g") (EFieldAccess (EVar "gctx") "graphRun")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "goals")) (EBinOp "::" (EVar "o") (EFieldAccess (EFieldAccess (EVar "g") "goals") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "goalsN")) (EBinOp "+" (EFieldAccess (EFieldAccess (EVar "g") "goalsN") "value") (ELit (LInt 1)))))))
(DTypeSig true "pushDictApp" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PendingDictApp") (TyCon "Unit"))))
(DFunDef false "pushDictApp" ((PVar "gctx") (PVar "app")) (EApp (EApp (EVar "pushGoal") (EVar "gctx")) (ERecordCreate "Obligation" ((fa "oKind" (EVar "GKDictApp")) (fa "oDest" (EApp (EVar "EvRoutes") (EFieldAccess (EVar "app") "pdaRoutesRef"))) (fa "oEv" (EFieldAccess (EVar "app") "pdaEv")) (fa "oEncl" (EFieldAccess (EVar "app") "pdaEncl")) (fa "oLoc" (EFieldAccess (EVar "app") "pdaLoc")) (fa "oScope" (EFieldAccess (EVar "app") "pdaScope")) (fa "oPayload" (EApp (EVar "GPDictApp") (EVar "app"))) (fa "oInner" (EApp (EVar "Ref") (EVar "innerNone")))))))
(DTypeSig true "goalsSince" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Obligation")))))
(DFunDef false "goalsSince" ((PVar "gctx") (PVar "mark")) (EApp (EApp (EApp (EVar "moduleWindow") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "goalsN") "value")) (EVar "mark")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "goals") "value")))
(DTypeSig true "goalsOfKindIn" (TyFun (TyCon "GoalKind") (TyFun (TyApp (TyCon "List") (TyCon "Obligation")) (TyApp (TyCon "List") (TyCon "Obligation")))))
(DFunDef false "goalsOfKindIn" ((PVar "k") (PVar "gs")) (EApp (EApp (EVar "filterList") (ELam ((PVar "o")) (EBinOp "==" (EApp (EVar "goalKindTag") (EFieldAccess (EVar "o") "oKind")) (EApp (EVar "goalKindTag") (EVar "k"))))) (EVar "gs")))
(DTypeSig true "siteEntry" (TyFun (TyCon "Obligation") (TyApp (TyCon "List") (TyCon "PendingEntry"))))
(DFunDef false "siteEntry" ((PVar "o")) (EMatch (EFieldAccess (EVar "o") "oPayload") (arm (PCon "GPSite" (PVar "name") (PVar "m") (PVar "site")) () (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PendingEntry") (EVar "name")) (EApp (EVar "evCell") (EFieldAccess (EVar "o") "oDest"))) (EVar "m")) (EFieldAccess (EVar "o") "oEncl")) (EVar "site")) (EFieldAccess (EVar "o") "oLoc")) (EFieldAccess (EVar "o") "oScope")) (EFieldAccess (EVar "o") "oEv")))) (arm PWild () (EListLit))))
(DTypeSig false "evCell" (TyFun (TyCon "EvDest") (TyApp (TyCon "Ref") (TyCon "Route"))))
(DFunDef false "evCell" ((PCon "EvRoute" (PVar "r"))) (EVar "r"))
(DFunDef false "evCell" ((PCon "EvRoutes" PWild)) (EApp (EVar "Ref") (EVar "RNone")))
(DTypeSig true "arithEntry" (TyFun (TyCon "Obligation") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Ref") (TyCon "Route")) (TyCon "Mono")))))
(DFunDef false "arithEntry" ((PVar "o")) (EMatch (EFieldAccess (EVar "o") "oPayload") (arm (PCon "GPArith" (PVar "m")) () (EListLit (ETuple (EApp (EVar "evCell") (EFieldAccess (EVar "o") "oDest")) (EVar "m")))) (arm PWild () (EListLit))))
(DTypeSig true "dictAppsSince" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "PendingDictApp")))))
(DFunDef false "dictAppsSince" ((PVar "gctx") (PVar "mark")) (EApp (EVar "dictAppsIn") (EApp (EApp (EVar "goalsSince") (EVar "gctx")) (EVar "mark"))))
(DTypeSig false "dictAppsIn" (TyFun (TyApp (TyCon "List") (TyCon "Obligation")) (TyApp (TyCon "List") (TyCon "PendingDictApp"))))
(DFunDef false "dictAppsIn" ((PVar "gs")) (EApp (EApp (EDictApp "flatMap") (EVar "dictAppEntry")) (EVar "gs")))
(DTypeSig true "dictAppEntry" (TyFun (TyCon "Obligation") (TyApp (TyCon "List") (TyCon "PendingDictApp"))))
(DFunDef false "dictAppEntry" ((PVar "o")) (EMatch (EFieldAccess (EVar "o") "oPayload") (arm (PCon "GPDictApp" (PVar "a")) () (EListLit (EVar "a"))) (arm PWild () (EListLit))))
(DTypeSig true "methodDictEntry" (TyFun (TyCon "Obligation") (TyApp (TyCon "List") (TyCon "PendingMethodDict"))))
(DFunDef false "methodDictEntry" ((PVar "o")) (EMatch (EFieldAccess (EVar "o") "oPayload") (arm (PCon "GPMethodDict" (PVar "d")) () (EListLit (EVar "d"))) (arm PWild () (EListLit))))
(DTypeSig true "recDictAppEntry" (TyFun (TyCon "Obligation") (TyApp (TyCon "List") (TyCon "RecDictApp"))))
(DFunDef false "recDictAppEntry" ((PVar "o")) (EMatch (EFieldAccess (EVar "o") "oPayload") (arm (PCon "GPRecDictApp" (PVar "r")) () (EListLit (EVar "r"))) (arm PWild () (EListLit))))
(DTypeSig true "goalsMark" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyCon "Int"))))
(DFunDef false "goalsMark" ((PVar "gctx") PWild) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "goalsN") "value"))
(DTypeSig true "dropGoalsSince" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "GoalKind")) (TyCon "Unit")))))
(DFunDef false "dropGoalsSince" ((PVar "gctx") (PVar "mark") (PVar "kinds")) (EBlock (DoLet false false (PVar "g") (EFieldAccess (EVar "gctx") "graphRun")) (DoLet false false (PVar "now") (EFieldAccess (EFieldAccess (EVar "g") "goals") "value")) (DoLet false false (PVar "n") (EBinOp "-" (EFieldAccess (EFieldAccess (EVar "g") "goalsN") "value") (EVar "mark"))) (DoLet false false (PVar "tags") (EApp (EApp (EMethodRef "map") (EVar "goalKindTag")) (EVar "kinds"))) (DoLet false false (PVar "kept") (EApp (EApp (EVar "filterList") (ELam ((PVar "o")) (EApp (EVar "not") (EApp (EApp (EVar "containsI") (EApp (EVar "goalKindTag") (EFieldAccess (EVar "o") "oKind"))) (EVar "tags"))))) (EApp (EApp (EVar "take") (EVar "n")) (EVar "now")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "goals")) (EBinOp "++" (EVar "kept") (EApp (EApp (EVar "drop") (EVar "n")) (EVar "now"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "goalsN")) (EBinOp "+" (EVar "mark") (EApp (EVar "listLen") (EVar "kept")))))))
(DTypeSig true "routeLocalSym" (TyFun (TyCon "Route") (TyCon "String")))
(DFunDef false "routeLocalSym" ((PCon "RLocal" (PVar "s") PWild)) (EVar "s"))
(DFunDef false "routeLocalSym" (PWild) (ELit (LString "")))
(DTypeSig false "methodReturnOrigin" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "GoalOrigin"))))
(DFunDef false "methodReturnOrigin" ((PVar "mctx") (PVar "loc")) (EBlock (DoLet false false (PVar "moduleId") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentModuleRef") "value")) (DoLet false false (PVar "binding") (EIf (EBinOp "==" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value") (ELit (LString ""))) (EVar "None") (EApp (EApp (EApp (EVar "mkIdent") (EVar "NsValue")) (EApp (EVar "OriginModule") (EVar "moduleId"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")))) (DoExpr (ERecordCreate "GoalOrigin" ((fa "location" (EVar "loc")) (fa "moduleId" (EVar "moduleId")) (fa "binding" (EVar "binding")))))))
(DTypeSig false "methodReturnInstantiation" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodReturnRequest") (TyApp (TyCon "Option") (TyCon "Instantiation")))))
(DFunDef false "methodReturnInstantiation" ((PVar "mctx") (PVar "request")) (EMatch (ETuple (EApp (EApp (EVar "methodReturnPredicate") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "request")) (EFieldAccess (EVar "request") "mrrGoalEv")) (arm (PTuple (PCon "Some" (PVar "predicate")) (PCon "Some" (PVar "destination"))) () (EApp (EVar "Some") (ERecordCreate "Instantiation" ((fa "body" (EFieldAccess (EVar "request") "mrrQualifiedBody")) (fa "force" (EVar "pureRow")) (fa "arguments" (EListLit (ERecordCreate "InstantiationArgument" ((fa "formal" (EApp (EApp (EVar "Scopes.binderAt") (EFieldAccess (EVar "request") "mrrScope")) (ELit (LInt 0)))) (fa "wanted" (ERecordCreate "Wanted" ((fa "id" (EApp (EVar "goalIdForDestination") (EVar "destination"))) (fa "predicate" (EVar "predicate")) (fa "origin" (EApp (EApp (EVar "methodReturnOrigin") (EVar "mctx")) (EFieldAccess (EVar "request") "mrrLoc"))) (fa "scope" (EFieldAccess (EVar "request") "mrrScope")) (fa "destination" (EVar "destination"))))))))))))) (arm PWild () (EVar "None"))))
(DTypeSig false "methodReturnPredicate" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "MethodReturnRequest") (TyApp (TyCon "Option") (TyCon "ClassPredicate")))))
(DFunDef false "methodReturnPredicate" ((PVar "gctx") (PVar "request")) (EApp (EApp (EApp (EApp (EApp (EVar "methodReturnPredicateFromTemplate") (EVar "gctx")) (EFieldAccess (EVar "request") "mrrPredicateTemplate")) (EFieldAccess (EVar "request") "mrrTyparams")) (EFieldAccess (EVar "request") "mrrOmitted")) (EFieldAccess (EVar "request") "mrrScope")))
(DTypeSig false "methodReturnPredicateFromTemplate" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "MethodPredicateTemplate") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "ScopeId") (TyApp (TyCon "Option") (TyCon "ClassPredicate"))))))))
(DFunDef false "methodReturnPredicateFromTemplate" ((PVar "gctx") (PVar "template") (PVar "typarams") (PVar "omitted") (PVar "scope")) (EMatch (EApp (EVar "methodPredicateTemplateArgs") (EFieldAccess (EVar "template") "mptArguments")) (arm (PCon "Some" (PVar "arguments")) () (EApp (EVar "Some") (ERecordCreate "ClassPredicate" ((fa "predicateInterface" (EFieldAccess (EVar "template") "mptInterface")) (fa "predicateArguments" (EVar "arguments")))))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EApp (EVar "uniqueMethodTemplateGiven") (EVar "gctx")) (EVar "template")) (EVar "scope")) (EApp (EApp (EVar "givensForScope") (EVar "gctx")) (EVar "scope"))) (arm (PCon "Some" (PVar "given")) () (EApp (EVar "Some") (ERecordCreate "ClassPredicate" ((fa "predicateInterface" (EFieldAccess (EVar "template") "mptInterface")) (fa "predicateArguments" (EApp (EVar "predicateSlotKnownArgs") (EFieldAccess (EFieldAccess (EVar "given") "geSlot") "psArgs"))))))) (arm (PCon "None") () (EApp (EApp (EMethodRef "map") (ELam ((PVar "arguments")) (ERecordCreate "ClassPredicate" ((fa "predicateInterface" (EFieldAccess (EVar "template") "mptInterface")) (fa "predicateArguments" (EVar "arguments")))))) (EApp (EVar "methodPredicateTemplateArgs") (EApp (EApp (EApp (EVar "fillOmittedTemplateArgs") (EVar "typarams")) (EFieldAccess (EVar "template") "mptArguments")) (EVar "omitted")))))))))
(DTypeSig false "fillOmittedTemplateArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Mono")))))))
(DFunDef false "fillOmittedTemplateArgs" ((PCons (PVar "param") (PVar "params")) (PCons (PVar "argument") (PVar "arguments")) (PVar "omitted")) (EBinOp "::" (EApp (EApp (EVar "orElseOpt") (EVar "argument")) (EApp (EApp (EVar "lookupAssoc") (EVar "param")) (EVar "omitted"))) (EApp (EApp (EApp (EVar "fillOmittedTemplateArgs") (EVar "params")) (EVar "arguments")) (EVar "omitted"))))
(DFunDef false "fillOmittedTemplateArgs" (PWild (PVar "arguments") PWild) (EVar "arguments"))
(DTypeSig true "methodReturnArgs" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "MethodReturnRequest") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Mono"))))))
(DFunDef false "methodReturnArgs" ((PVar "gctx") (PVar "request")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "predicate")) (EFieldAccess (EVar "predicate") "predicateArguments"))) (EApp (EApp (EVar "methodReturnPredicate") (EVar "gctx")) (EVar "request"))))
(DTypeSig true "methodReturnWanted" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodReturnRequest") (TyApp (TyCon "Option") (TyCon "Wanted")))))
(DFunDef false "methodReturnWanted" ((PVar "mctx") (PVar "request")) (EMatch (EApp (EApp (EVar "methodReturnInstantiation") (EVar "mctx")) (EVar "request")) (arm (PCon "Some" (PRec "Instantiation" ((rf "arguments" (PList (PVar "argument")))) true)) () (EApp (EVar "Some") (EFieldAccess (EVar "argument") "wanted"))) (arm PWild () (EVar "None"))))
(DTypeSig true "ifaceRefBare" (TyFun (TyCon "String") (TyCon "IfaceRef")))
(DFunDef false "ifaceRefBare" ((PVar "n")) (ERecordCreate "IfaceRef" ((fa "irName" (EVar "n")) (fa "irOrigin" (EVar "OriginUnresolved")))))
(DTypeSig true "ifaceRefNone" (TyCon "IfaceRef"))
(DFunDef false "ifaceRefNone" () (ERecordCreate "IfaceRef" ((fa "irName" (ELit (LString ""))) (fa "irOrigin" (EVar "OriginUnresolved")))))
(DTypeSig true "uOblArgs" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "UObligation") (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "uOblArgs" ((PVar "gctx") (PVar "o")) (EMatch (EFieldAccess (EVar "o") "oblProj") (arm (PCon "OpProjected") () (EFieldAccess (EFieldAccess (EVar "o") "pred") "args")) (arm (PCon "OpMethodOcc" (PVar "typarams") (PVar "mty") (PVar "occ") (PVar "omitted")) () (EApp (EApp (EApp (EApp (EVar "occurrenceDispatchMonos") (EVar "typarams")) (EVar "mty")) (EVar "occ")) (EVar "omitted"))) (arm (PCon "OpExactReturn" (PVar "request")) () (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "methodReturnArgs") (EVar "gctx")) (EVar "request")))) (arm (PCon "OpNumLit" PWild) () (EFieldAccess (EFieldAccess (EVar "o") "pred") "args"))))
(DTypeSig true "consSiteFn" (TyFun (TyCon "String") (TyFun (TyVar "a") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyVar "a"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "consSiteFn" ((PVar "fn") (PVar "x") (PVar "idx")) (EApp (EApp (EApp (EVar "omInsert") (EVar "fn")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "sitesFor") (EVar "fn")) (EVar "idx")))) (EVar "idx")))
(DTypeSig true "sitesFor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyVar "a"))) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "sitesFor" ((PVar "fn") (PVar "idx")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "fn")) (EVar "idx"))))
(DTypeSig false "sameTraceEvId" (TyFun (TyCon "EvId") (TyFun (TyCon "EvId") (TyCon "Bool"))))
(DFunDef false "sameTraceEvId" ((PCon "EvId" (PVar "moduleA") (PVar "ordinalA")) (PCon "EvId" (PVar "moduleB") (PVar "ordinalB"))) (EBinOp "&&" (EBinOp "==" (EVar "moduleA") (EVar "moduleB")) (EBinOp "==" (EVar "ordinalA") (EVar "ordinalB"))))
(DTypeSig true "noteMethodReturnTrace" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodReturnTraceStage") (TyFun (TyCon "MethodReturnRequest") (TyFun (TyApp (TyCon "Option") (TyCon "Route")) (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyCon "Unit")))))))
(DFunDef false "noteMethodReturnTrace" ((PVar "mctx") (PVar "stage") (PVar "request") (PVar "route") (PVar "prerequisites")) (EMatch (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "trace") (arm (PCon "Some" (PVar "sink")) () (EIf (EFieldAccess (EVar "sink") "tsMethodReturnEnabled") (EBlock (DoLet false false (PTuple (PVar "qualifiedBody") (PVar "wanted")) (EMatch (EApp (EApp (EVar "methodReturnInstantiation") (EVar "mctx")) (EVar "request")) (arm (PCon "Some" (PRec "Instantiation" ((rf "body" (PVar "body")) (rf "arguments" (PList (PRec "InstantiationArgument" ((rf "wanted" (PVar "carried"))) true)))) true)) () (ETuple (EApp (EVar "Some") (EVar "body")) (EApp (EVar "Some") (EVar "carried")))) (arm PWild () (ETuple (EVar "None") (EVar "None"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "sink") "tsMethodReturnEntries")) (EBinOp "::" (ERecordCreate "MethodReturnTraceEntry" ((fa "mrtStage" (EVar "stage")) (fa "mrtInterface" (EFieldAccess (EVar "request") "mrrIface")) (fa "mrtMethod" (EFieldAccess (EVar "request") "mrrName")) (fa "mrtArguments" (EApp (EApp (EVar "methodReturnArgs") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "request"))) (fa "mrtScope" (EFieldAccess (EVar "request") "mrrScope")) (fa "mrtOrigin" (EFieldAccess (EVar "request") "mrrLoc")) (fa "mrtGoal" (EFieldAccess (EVar "request") "mrrGoalEv")) (fa "mrtPublished" (EVar "None")) (fa "mrtQualifiedBody" (EVar "qualifiedBody")) (fa "mrtWanted" (EVar "wanted")) (fa "mrtOutcome" (EApp (EApp (EMethodRef "map") (ELam ((PVar "resolution")) (EFieldAccess (EVar "resolution") "mrrOutcome"))) (EFieldAccess (EFieldAccess (EVar "request") "mrrResolution") "value"))) (fa "mrtRoute" (EVar "route")) (fa "mrtPrerequisites" (EVar "prerequisites")))) (EFieldAccess (EFieldAccess (EVar "sink") "tsMethodReturnEntries") "value"))))) (ELit LUnit))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig true "goalKindName" (TyFun (TyCon "GoalKind") (TyCon "String")))
(DFunDef false "goalKindName" ((PCon "GKReturnSite")) (ELit (LString "GKReturnSite")))
(DFunDef false "goalKindName" ((PCon "GKArgStamp")) (ELit (LString "GKArgStamp")))
(DFunDef false "goalKindName" ((PCon "GKRLocalSite")) (ELit (LString "GKRLocalSite")))
(DFunDef false "goalKindName" ((PCon "GKBinopSite")) (ELit (LString "GKBinopSite")))
(DFunDef false "goalKindName" ((PCon "GKUnopSite")) (ELit (LString "GKUnopSite")))
(DFunDef false "goalKindName" ((PCon "GKArithSite")) (ELit (LString "GKArithSite")))
(DFunDef false "goalKindName" ((PCon "GKDictApp")) (ELit (LString "GKDictApp")))
(DFunDef false "goalKindName" ((PCon "GKMethodDict")) (ELit (LString "GKMethodDict")))
(DFunDef false "goalKindName" ((PCon "GKRecDictApp")) (ELit (LString "GKRecDictApp")))
(DTypeSig true "openScope" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ScopeId") (TyCon "Unit"))))
(DFunDef false "openScope" ((PVar "mctx") (PVar "sid")) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentScope")) (EApp (EVar "Scopes.openScopeCursor") (EVar "sid"))))
(DTypeSig true "currentModuleMarks" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyCon "GraphMarks"))))
(DFunDef false "currentModuleMarks" ((PVar "gctx") PWild) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "moduleRanges") "value") (arm (PCons (PTuple PWild (PVar "m")) PWild) () (EVar "m")) (arm (PList) () (ERecordCreate "GraphMarks" ((fa "mGoals" (ELit (LInt 0))) (fa "mNumlit" (ELit (LInt 0))))))))
(DTypeSig true "walkGoalDischarged" (TyFun (TyCon "ReqWalk") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool")))))
(DFunDef false "walkGoalDischarged" ((PVar "walk") (PVar "iface") (PVar "args")) (EBlock (DoLet false false (PVar "memo") (EApp (EVar "reqWalkMemo") (EVar "walk"))) (DoExpr (EApp (EApp (EVar "anyListM") (ELam ((PTuple (PVar "otherIface") (PVar "otherArgs"))) (EBinOp "&&" (EApp (EApp (EVar "sameIfaceDecl") (EVar "otherIface")) (EVar "iface")) (EApp (EApp (EVar "monoVecSameGiven") (EVar "otherArgs")) (EVar "args"))))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EApp (EVar "enteredGoalKey") (EVar "walk"))) (EFieldAccess (EFieldAccess (EVar "memo") "wmDischarged") "value")))))))
(DTypeSig true "noteWalkGoalDischarged" (TyFun (TyCon "ReqWalk") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Unit")))))
(DFunDef false "noteWalkGoalDischarged" ((PVar "walk") (PVar "iface") (PVar "args")) (EBlock (DoLet false false (PVar "memo") (EApp (EVar "reqWalkMemo") (EVar "walk"))) (DoLet false false (PVar "key") (EApp (EVar "enteredGoalKey") (EVar "walk"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "memo") "wmDischarged")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "::" (ETuple (EVar "iface") (EVar "args")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EFieldAccess (EVar "memo") "wmDischarged") "value"))))) (EFieldAccess (EFieldAccess (EVar "memo") "wmDischarged") "value"))))))
(DTypeSig true "solvedOnWalk" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ReqWalk") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyFun (TyCon "Unit") (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))))) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))))))))))
(DFunDef false "solvedOnWalk" ((PVar "mctx") (PVar "walk") (PVar "iface") (PVar "args") (PVar "solve")) (EBlock (DoLet false false (PVar "memo") (EApp (EVar "reqWalkMemo") (EVar "walk"))) (DoLet false false (PVar "key") (EApp (EVar "enteredGoalKey") (EVar "walk"))) (DoLet false false (PVar "entries") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EFieldAccess (EVar "memo") "wmSolved") "value")))) (DoExpr (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EApp (EApp (EApp (EVar "walkGoalSame") (EFieldAccess (EVar "e") "sgeIface")) (EFieldAccess (EVar "e") "sgeGoals")) (EVar "iface")) (EVar "args")))) (EVar "entries")) (arm (PCons (PVar "entry") PWild) () (EFieldAccess (EVar "entry") "sgeResiduals")) (arm (PList) () (EBlock (DoLet false false (PTuple (PVar "clean") (PVar "found")) (EApp (EApp (EApp (EVar "solvedCleanly") (EVar "mctx")) (ELam ((PVar "goals")) (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "goals")))) (EVar "solve"))) (DoLet false false (PVar "residuals") (EApp (EVar "dedupWalkGoals") (EVar "found"))) (DoExpr (EIf (EVar "clean") (EBlock (DoLet false false (PVar "entry") (ERecordCreate "SolvedGoalEntry" ((fa "sgeIface" (EVar "iface")) (fa "sgeGoals" (EVar "args")) (fa "sgeResiduals" (EVar "residuals"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "memo") "wmSolved")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "::" (EVar "entry") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EFieldAccess (EVar "memo") "wmSolved") "value"))))) (EFieldAccess (EFieldAccess (EVar "memo") "wmSolved") "value"))))) (ELit LUnit))) (DoExpr (EVar "residuals"))))))))
(DTypeSig true "solvedCleanly" (TyFun (TyCon "ModuleCtx") (TyFun (TyFun (TyVar "a") (TyApp (TyCon "List") (TyCon "Mono"))) (TyFun (TyFun (TyCon "Unit") (TyVar "a")) (TyTuple (TyCon "Bool") (TyVar "a"))))))
(DFunDef false "solvedCleanly" ((PVar "mctx") (PVar "monosOf") (PVar "act")) (EBlock (DoLet false false (PVar "tyvars") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "tyvarCounter") "value")) (DoLet false false (PVar "effvars") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "effvarCounter") "value")) (DoLet false false (PTuple (PVar "erred") (PVar "result")) (EApp (EApp (EVar "erredDuring") (EVar "mctx")) (EVar "act"))) (DoExpr (ETuple (EBinOp "&&" (EApp (EVar "not") (EVar "erred")) (EApp (EApp (EVar "allList") (EApp (EApp (EVar "monoMintedBefore") (EVar "tyvars")) (EVar "effvars"))) (EApp (EVar "monosOf") (EVar "result")))) (EVar "result")))))
(DTypeSig false "dedupWalkGoals" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")))) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))))))
(DFunDef false "dedupWalkGoals" ((PVar "goals")) (EApp (EApp (EApp (EVar "dedupWalkGoalsGo") (EVar "goals")) (EVar "omEmpty")) (EListLit)))
(DTypeSig false "dedupWalkGoalsGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")))) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))))))))
(DFunDef false "dedupWalkGoalsGo" ((PList) PWild (PVar "acc")) (EApp (EVar "reverse") (EVar "acc")))
(DFunDef false "dedupWalkGoalsGo" ((PCons (PTuple (PVar "iface") (PVar "args")) (PVar "rest")) (PVar "seen") (PVar "acc")) (EBlock (DoLet false false (PVar "key") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "iface") "irName"))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "monoSizes") (EVar "args"))))) (ELit (LString "")))) (DoLet false false (PVar "bucket") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "seen")))) (DoExpr (EIf (EApp (EApp (EVar "anyListM") (ELam ((PVar "g")) (EApp (EApp (EApp (EApp (EVar "walkGoalSame") (EApp (EVar "fst") (EVar "g"))) (EApp (EVar "snd") (EVar "g"))) (EVar "iface")) (EVar "args")))) (EVar "bucket")) (EApp (EApp (EApp (EVar "dedupWalkGoalsGo") (EVar "rest")) (EVar "seen")) (EVar "acc")) (EApp (EApp (EApp (EVar "dedupWalkGoalsGo") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "::" (ETuple (EVar "iface") (EVar "args")) (EVar "bucket"))) (EVar "seen"))) (EBinOp "::" (ETuple (EVar "iface") (EVar "args")) (EVar "acc")))))))
(DTypeSig true "walkGoalFollowed" (TyFun (TyCon "ReqWalk") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool")))))
(DFunDef false "walkGoalFollowed" ((PVar "walk") (PVar "iface") (PVar "args")) (EBlock (DoLet false false (PVar "memo") (EApp (EVar "reqWalkMemo") (EVar "walk"))) (DoExpr (EApp (EApp (EVar "anyListM") (ELam ((PTuple (PVar "otherIface") (PVar "otherArgs"))) (EApp (EApp (EApp (EApp (EVar "walkGoalSame") (EVar "otherIface")) (EVar "otherArgs")) (EVar "iface")) (EVar "args")))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EApp (EVar "enteredGoalKey") (EVar "walk"))) (EFieldAccess (EFieldAccess (EVar "memo") "wmFollowed") "value")))))))
(DTypeSig true "noteWalkGoalFollowed" (TyFun (TyCon "ReqWalk") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Unit")))))
(DFunDef false "noteWalkGoalFollowed" ((PVar "walk") (PVar "iface") (PVar "args")) (EBlock (DoLet false false (PVar "memo") (EApp (EVar "reqWalkMemo") (EVar "walk"))) (DoLet false false (PVar "key") (EApp (EVar "enteredGoalKey") (EVar "walk"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "memo") "wmFollowed")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "::" (ETuple (EVar "iface") (EVar "args")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EFieldAccess (EVar "memo") "wmFollowed") "value"))))) (EFieldAccess (EFieldAccess (EVar "memo") "wmFollowed") "value"))))))
(DTypeSig false "walkGoalSame" (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))))
(DFunDef false "walkGoalSame" ((PVar "iface") (PVar "args") (PVar "otherIface") (PVar "otherArgs")) (EBinOp "&&" (EApp (EApp (EVar "sameIfaceDecl") (EVar "iface")) (EVar "otherIface")) (EApp (EApp (EVar "walkMonosSame") (EVar "args")) (EVar "otherArgs"))))
(DTypeSig true "isLocalAbsName" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isLocalAbsName" ((PVar "n")) (EApp (EApp (EVar "endsWith") (ELit (LString "$lb"))) (EVar "n")))
(DTypeSig true "localSourceName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "localSourceName" ((PVar "name")) (EIf (EApp (EVar "isLocalAbsName") (EVar "name")) (EMatch (EApp (EApp (EVar "splitOnChar") (ELit (LChar "$"))) (EVar "name")) (arm (PCons (PVar "first") PWild) () (EVar "first")) (arm (PList) () (EVar "name"))) (EIf (EVar "otherwise") (EVar "name") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "pushLocalDictApp" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyFun (TyCon "LocalAbs") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyFun (TyCon "ScopeId") (TyCon "Unit"))))))))
(DFunDef false "pushLocalDictApp" ((PVar "mctx") (PVar "name") (PVar "ev") (PVar "la") (PVar "subst") (PVar "useScope")) (EBlock (DoLet false false (PVar "monos") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "localSlotLead") (EVar "mctx")) (EVar "subst"))) (EFieldAccess (EVar "la") "laSlots"))) (DoExpr (EApp (EApp (EVar "pushDictApp") (EFieldAccess (EVar "mctx") "mcGraph")) (ERecordCreate "PendingDictApp" ((fa "pdaRoutesRef" (EApp (EVar "Ref") (EListLit))) (fa "pdaEv" (EVar "ev")) (fa "pdaMonos" (EVar "monos")) (fa "pdaIfaces" (EApp (EApp (EMethodRef "map") (ELam ((PVar "s")) (EFieldAccess (EVar "s") "psIface"))) (EFieldAccess (EVar "la") "laSlots"))) (fa "pdaArgVecs" (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "localSlotArgs") (EVar "mctx")) (EVar "subst"))) (EFieldAccess (EVar "la") "laSlots"))) (fa "pdaEncl" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (fa "pdaLoc" (EFieldAccess (EVar "mctx") "mcLoc")) (fa "pdaScope" (EVar "useScope")) (fa "pdaCallee" (EApp (EVar "localSourceName") (EVar "name"))))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dictAppFns")) (EApp (EApp (EApp (EVar "consSiteFn") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (EVar "monos")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dictAppFns") "value"))))))
(DTypeSig false "localSlotArgs" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyFun (TyCon "PredicateSlot") (TyApp (TyCon "List") (TyCon "Mono"))))))
(DFunDef false "localSlotArgs" ((PVar "mctx") (PVar "subst") (PVar "slot")) (EMatch (EFieldAccess (EVar "slot") "psArgs") (arm (PCon "PSArgsKnown" (PVar "args")) () (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EVar "substMono") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "subst")) (EListLit)) (EListLit))) (EVar "args"))) (arm (PCon "PSArgsUnknown") () (EListLit (EApp (EApp (EApp (EVar "localSlotLead") (EVar "mctx")) (EVar "subst")) (EVar "slot"))))))
(DTypeSig false "localSlotLead" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyFun (TyCon "PredicateSlot") (TyCon "Mono")))))
(DFunDef false "localSlotLead" ((PVar "mctx") (PVar "subst") (PVar "slot")) (EMatch (EFieldAccess (EVar "slot") "psArgs") (arm (PCon "PSArgsKnown" (PCons (PVar "a") PWild)) () (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "subst")) (EListLit)) (EListLit)) (EVar "a"))) (arm PWild () (EMatch (EFieldAccess (EVar "slot") "psBoundIds") (arm (PCons (PVar "id") PWild) () (EApp (EApp (EVar "optionOrElse") (ELam (PWild) (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit)))) (EApp (EApp (EVar "lookupAssocI") (EVar "id")) (EVar "subst")))) (arm (PList) () (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit)))))))
(DTypeSig true "builtinClassPresent" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "BuiltinClass") (TyCon "Bool"))))
(DFunDef false "builtinClassPresent" ((PVar "gctx") (PCon "BNum")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "builtinClassesRef") "value") "bcNumPresent"))
(DFunDef false "builtinClassPresent" ((PVar "gctx") (PCon "BEq")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "builtinClassesRef") "value") "bcEqPresent"))
(DFunDef false "builtinClassPresent" ((PVar "gctx") (PCon "BOrd")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "builtinClassesRef") "value") "bcOrdPresent"))
(DFunDef false "builtinClassPresent" ((PVar "gctx") (PCon "BSemigroup")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "builtinClassesRef") "value") "bcSemigroupPresent"))
(DTypeSig true "admittedSelection" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "ImplEnv") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyCon "AdmittedAnswer"))))))
(DFunDef false "admittedSelection" ((PVar "sx") (PVar "env") (PVar "name") (PVar "mono")) (EBlock (DoLet false false (PVar "visible") (EApp (EApp (EVar "methodVisibleHere") (EFieldAccess (EVar "sx") "sxModule")) (EVar "name"))) (DoLet false false (PVar "answers") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EVar "admittedDeclAnswer") (EVar "sx")) (EVar "env")) (EVar "visible")) (EVar "mono"))) (EApp (EApp (EVar "methodAdmittedHere") (EFieldAccess (EVar "sx") "sxModule")) (EVar "name")))) (DoExpr (EIf (EApp (EApp (EVar "anyList") (EVar "isUndecided")) (EVar "answers")) (EVar "Undecided") (EMatch (EApp (EApp (EVar "filterList") (EVar "isSelection")) (EVar "answers")) (arm (PList) () (EVar "SelectsNothing")) (arm (PList (PVar "one")) () (EApp (EApp (EApp (EVar "routableSelection") (EFieldAccess (EVar "sx") "sxModule")) (EVar "name")) (EVar "one"))) (arm PWild () (EVar "Undecided")))))))
(DTypeSig false "routableSelection" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "AdmittedAnswer") (TyCon "AdmittedAnswer")))))
(DFunDef false "routableSelection" ((PVar "mctx") (PVar "name") (PAs "answer" (PCon "Selects" (PVar "iface") PWild PWild))) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "methodSlotKey") (EVar "iface")) (EApp (EApp (EVar "originMethodName") (EVar "mctx")) (EVar "name")))) (DoExpr (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodPredicateSlotsRef") "value")) (arm (PCon "Some" (PCons PWild PWild)) () (EApp (EVar "Unroutable") (EVar "iface"))) (arm PWild () (EVar "answer"))))))
(DFunDef false "routableSelection" ((PVar "mctx") PWild (PVar "answer")) (EVar "answer"))
(DTypeSig false "admittedDeclAnswer" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "ImplEnv") (TyFun (TyApp (TyCon "List") (TyCon "MethodRow")) (TyFun (TyCon "Mono") (TyFun (TyCon "IfaceRef") (TyCon "AdmittedAnswer")))))))
(DFunDef false "admittedDeclAnswer" ((PVar "sx") (PVar "env") (PVar "visible") (PVar "mono") (PVar "ir")) (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EVar "ieRowIfaceMatches") (EApp (EVar "methodRowIface") (EVar "r"))) (EVar "ir")))) (EVar "visible")) (arm (PCons (PVar "r") PWild) () (EMatch (EFieldAccess (EVar "r") "mrEntry") (arm (PTuple (PVar "iface") (PVar "typarams") (PVar "mty") PWild) () (EMatch (EApp (EApp (EVar "matchTyMono") (EVar "mty")) (EVar "mono")) (arm (PCon "Some" (PVar "subst")) () (EBlock (DoLet false false (PVar "goals") (EApp (EApp (EMethodRef "map") (EApp (EVar "paramMonoOf") (EVar "subst"))) (EVar "typarams"))) (DoExpr (EMatch (EApp (EVar "goalHeadCon") (EVar "goals")) (arm (PCon "None") () (EVar "Undecided")) (arm (PCon "Some" PWild) () (EMatch (EApp (EApp (EApp (EApp (EVar "ieSelectRowByIface") (EVar "sx")) (EVar "env")) (EVar "iface")) (EVar "goals")) (arm (PCon "Some" (PVar "row")) () (EApp (EApp (EApp (EVar "Selects") (EVar "iface")) (EVar "row")) (EVar "goals"))) (arm (PCon "None") () (EVar "SelectsNothing")))))))) (arm (PCon "None") () (EVar "Undecided")))))) (arm (PList) () (EVar "Undecided"))))
(DTypeSig false "isUndecided" (TyFun (TyCon "AdmittedAnswer") (TyCon "Bool")))
(DFunDef false "isUndecided" ((PCon "Undecided")) (EVar "True"))
(DFunDef false "isUndecided" (PWild) (EVar "False"))
(DTypeSig false "isSelection" (TyFun (TyCon "AdmittedAnswer") (TyCon "Bool")))
(DFunDef false "isSelection" ((PCon "Selects" PWild PWild PWild)) (EVar "True"))
(DFunDef false "isSelection" (PWild) (EVar "False"))
(DTypeSig true "outerRigidIds" (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "outerRigidIds" ((PVar "outerBelow") (PVar "args") (PVar "base")) (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (EVar "intToString")) (EApp (EApp (EVar "enclosingVarIds") (EVar "outerBelow")) (EVar "args")))) (EVar "base")))
(DTypeSig true "enclosingVarIds" (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "enclosingVarIds" ((PCon "None") PWild) (EListLit))
(DFunDef false "enclosingVarIds" ((PCon "Some" (PVar "level")) (PVar "args")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EVar "filterList") (ELam ((PVar "p")) (EBinOp "<" (EApp (EVar "snd") (EVar "p")) (EVar "level")))) (EApp (EApp (EDictApp "flatMap") (EVar "monoUnboundVarLevels")) (EVar "args")))))
(DTypeSig true "improveLocalGoals" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyFun (TyCon "Int") (TyCon "Unit")))))
(DFunDef false "improveLocalGoals" ((PVar "dyn") (PVar "addedObls") (PVar "callN0")) (EBlock (DoLet false false (PVar "goals") (EBinOp "++" (EVar "addedObls") (EApp (EApp (EVar "callUOblsWindow") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "callN0")))) (DoLet false false (PVar "outer") (EApp (EApp (EApp (EVar "outerRigidIds") (EApp (EVar "Some") (EBinOp "+" (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "currentLevel") "value") (ELit (LInt 1))))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "uOblArgs") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph"))) (EVar "goals"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EApp (EVar "improveByUniqueImpl") (EVar "dyn")) (EVar "outer")) (EVar "goals")))))
(DTypeSig true "returnPosMethodNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "returnPosMethodNames" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "returnPosOfDecl")) (EVar "prog")))
(DTypeSig false "returnPosOfDecl" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "returnPosOfDecl" ((PRec "DInterface" ((rf "typarams" None) (rf "methods" None)) true)) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "returnPosMethod") (EVar "typarams"))) (EVar "methods")))
(DFunDef false "returnPosOfDecl" (PWild) (EListLit))
(DTypeSig false "returnPosMethod" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "returnPosMethod" ((PVar "typarams") (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild PWild)) (EIf (EApp (EVar "not") (EApp (EApp (EVar "anyArgMentions") (EApp (EVar "dispatchTyparams") (EVar "typarams"))) (EApp (EVar "methodArgs") (EVar "mty")))) (EListLit (EVar "mname")) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "exactReturnRoutes" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "Bool") (TyFun (TyCon "MethodReturnResolution") (TyTuple (TyCon "Route") (TyApp (TyCon "List") (TyCon "Route"))))))))))
(DFunDef false "exactReturnRoutes" ((PVar "sx") (PVar "name") (PVar "encl") (PVar "scope") (PVar "isReturnPosition") (PVar "resolution")) (EMatch (ETuple (EFieldAccess (EVar "resolution") "mrrOutcome") (EFieldAccess (EVar "resolution") "mrrSelectedRow")) (arm (PTuple (PCon "Solved" (PCon "GivenEvidence" (PVar "binder"))) (PCon "None")) () (ETuple (EApp (EApp (EApp (EVar "givenRoute") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "isReturnPosition")) (EVar "binder")) (EListLit))) (arm (PTuple (PCon "Solved" (PCon "SuperclassEvidence" (PVar "parent") (PVar "path"))) (PCon "None")) () (ETuple (EApp (EApp (EVar "RProj") (EApp (EApp (EApp (EVar "givenRoute") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "isReturnPosition")) (EVar "parent"))) (EVar "path")) (EListLit))) (arm (PTuple (PCon "Solved" (PCon "InstanceEvidence" PWild (PVar "args") (PVar "prerequisites") PWild)) (PCon "Some" (PVar "row"))) () (ETuple (EApp (EApp (EApp (EVar "RKey") (EApp (EVar "rowRouteKey") (EVar "row"))) (EListLit)) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "selectedCallSupers") (EVar "sx")) (EVar "name")) (EApp (EVar "Some") (EVar "row"))) (EVar "encl")) (EVar "scope")) (EVar "args"))) (EApp (EApp (EApp (EApp (EVar "methodReturnEvidenceRoutes") (EVar "sx")) (EVar "encl")) (EVar "scope")) (EVar "prerequisites")))) (arm (PTuple (PCon "Deferred" PWild PWild) (PCon "None")) () (ETuple (EVar "RNone") (EListLit))) (arm (PTuple (PCon "Insoluble" PWild PWild) (PCon "None")) () (ETuple (EVar "RNone") (EListLit))) (arm PWild () (EApp (EVar "panic") (ELit (LString "ordinary return outcome and selected row disagree"))))))
(DTypeSig false "methodReturnEvidenceRoutes" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyCon "PrerequisiteEvidence")) (TyApp (TyCon "List") (TyCon "Route")))))))
(DFunDef false "methodReturnEvidenceRoutes" ((PVar "sx") (PVar "encl") (PVar "scope") (PVar "prerequisites")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "methodReturnEvidenceRoute") (EVar "sx")) (EVar "encl")) (EVar "scope"))) (EVar "prerequisites")))
(DTypeSig false "methodReturnEvidenceRoute" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "PrerequisiteEvidence") (TyCon "Route"))))))
(DFunDef false "methodReturnEvidenceRoute" ((PVar "sx") (PVar "encl") (PVar "scope") (PVar "prerequisite")) (EMatch (EFieldAccess (EVar "prerequisite") "prerequisiteArguments") (arm (PCons (PVar "first") (PVar "more")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeOfD") (EVar "sx")) (EFieldAccess (EVar "prerequisite") "prerequisiteInterface")) (EVar "encl")) (EVar "scope")) (EVar "KeepNone")) (EVar "first")) (EVar "more")) (EApp (EVar "reqWalkStart") (ELit LUnit)))) (arm (PList) () (EVar "RNone"))))
(DTypeSig true "numericReturnRoute" (TyFun (TyCon "Route") (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyCon "Route"))))
(DFunDef false "numericReturnRoute" ((PCon "RKey" (PVar "key") PWild (PVar "sups")) (PVar "routes")) (EApp (EApp (EApp (EVar "RKey") (EVar "key")) (EVar "routes")) (EVar "sups")))
(DFunDef false "numericReturnRoute" ((PVar "route") PWild) (EVar "route"))
(DTypeSig true "predicateSlotKnownArgs" (TyFun (TyCon "PredicateSlotArgs") (TyApp (TyCon "List") (TyCon "Mono"))))
(DFunDef false "predicateSlotKnownArgs" ((PCon "PSArgsUnknown")) (EListLit))
(DFunDef false "predicateSlotKnownArgs" ((PCon "PSArgsKnown" (PVar "args"))) (EVar "args"))
(DTypeSig false "methodPredicateTemplateArgs" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "methodPredicateTemplateArgs" ((PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "methodPredicateTemplateArgs" ((PCons (PCon "Some" (PVar "argument")) (PVar "rest"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "argument") (EVar "_s")))) (EApp (EVar "methodPredicateTemplateArgs") (EVar "rest"))))
(DFunDef false "methodPredicateTemplateArgs" ((PCons (PCon "None") PWild)) (EVar "None"))
(DTypeSig false "uniqueMethodTemplateGiven" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "MethodPredicateTemplate") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyCon "GivenEntry")) (TyApp (TyCon "Option") (TyCon "GivenEntry")))))))
(DFunDef false "uniqueMethodTemplateGiven" ((PVar "gctx") (PVar "template") (PVar "useScope") (PVar "givens")) (EBlock (DoLet false false (PVar "chain") (EApp (EApp (EVar "Scopes.visibleChain") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))) (EVar "useScope"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "methodTemplateGivenScan") (EVar "template")) (EVar "chain")) (EVar "givens")) (EVar "MethodTemplateGivenNone")) (arm (PCon "MethodTemplateGivenOne" (PVar "given")) () (EApp (EVar "Some") (EVar "given"))) (arm PWild () (EVar "None"))))))
(DTypeSig false "methodTemplateGivenScan" (TyFun (TyCon "MethodPredicateTemplate") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "GivenEntry")) (TyFun (TyCon "MethodTemplateGivenResult") (TyCon "MethodTemplateGivenResult"))))))
(DFunDef false "methodTemplateGivenScan" (PWild PWild (PList) (PVar "result")) (EVar "result"))
(DFunDef false "methodTemplateGivenScan" ((PVar "template") (PVar "chain") (PCons (PVar "given") (PVar "rest")) (PVar "result")) (EBlock (DoLet false false (PVar "result2") (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "givenInScope") (EVar "GSPredicateOnly")) (EVar "given")) (EApp (EApp (EVar "Scopes.visibleOnChain") (EVar "chain")) (EApp (EVar "Scopes.binderScope") (EFieldAccess (EVar "given") "geBinder")))) (EApp (EApp (EVar "methodPredicateTemplateMatchesSlot") (EVar "template")) (EFieldAccess (EVar "given") "geSlot"))) (EMatch (EVar "result") (arm (PCon "MethodTemplateGivenNone") () (EApp (EVar "MethodTemplateGivenOne") (EVar "given"))) (arm PWild () (EVar "MethodTemplateGivenMany"))) (EVar "result"))) (DoExpr (EMatch (EVar "result2") (arm (PCon "MethodTemplateGivenMany") () (EVar "MethodTemplateGivenMany")) (arm PWild () (EApp (EApp (EApp (EApp (EVar "methodTemplateGivenScan") (EVar "template")) (EVar "chain")) (EVar "rest")) (EVar "result2")))))))
(DTypeSig false "methodPredicateTemplateMatchesSlot" (TyFun (TyCon "MethodPredicateTemplate") (TyFun (TyCon "PredicateSlot") (TyCon "Bool"))))
(DFunDef false "methodPredicateTemplateMatchesSlot" ((PVar "template") (PVar "slot")) (EBinOp "&&" (EApp (EApp (EVar "sameIfaceDecl") (EFieldAccess (EVar "template") "mptInterface")) (EFieldAccess (EVar "slot") "psIface")) (EMatch (EFieldAccess (EVar "slot") "psArgs") (arm (PCon "PSArgsUnknown") () (EVar "False")) (arm (PCon "PSArgsKnown" (PVar "arguments")) () (EApp (EApp (EVar "methodPredicateTemplateArgumentsMatch") (EFieldAccess (EVar "template") "mptArguments")) (EVar "arguments"))))))
(DTypeSig false "methodPredicateTemplateArgumentsMatch" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))
(DFunDef false "methodPredicateTemplateArgumentsMatch" ((PList) (PList)) (EVar "True"))
(DFunDef false "methodPredicateTemplateArgumentsMatch" ((PCons (PCon "Some" (PVar "expected")) (PVar "rest")) (PCons (PVar "actual") (PVar "arguments"))) (EBinOp "&&" (EApp (EApp (EVar "monoSameGiven") (EVar "expected")) (EVar "actual")) (EApp (EApp (EVar "methodPredicateTemplateArgumentsMatch") (EVar "rest")) (EVar "arguments"))))
(DFunDef false "methodPredicateTemplateArgumentsMatch" ((PCons (PCon "None") (PVar "rest")) (PCons PWild (PVar "arguments"))) (EApp (EApp (EVar "methodPredicateTemplateArgumentsMatch") (EVar "rest")) (EVar "arguments")))
(DFunDef false "methodPredicateTemplateArgumentsMatch" (PWild PWild) (EVar "False"))
(DTypeSig true "rigidHeadInstanceContext" (TyFun (TyCon "SiteCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))))))))))
(DFunDef false "rigidHeadInstanceContext" ((PVar "sx") (PVar "headIds") (PVar "iface") (PVar "args")) (EBlock (DoLet false false (PVar "cells") (EApp (EApp (EVar "sigCellsOf") (EVar "headIds")) (EApp (EApp (EDictApp "flatMap") (EVar "monoVarCells")) (EVar "args")))) (DoLet false false (PVar "toRigid") (EApp (EApp (EVar "sigRigidBindings") (EVar "headIds")) (EVar "cells"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "r")) (EMatch (EApp (EApp (EApp (EVar "reqToObligation") (EFieldAccess (EVar "sx") "sxModule")) (EApp (EVar "fst") (EVar "m"))) (EVar "r")) (arm (PTuple (PVar "ri") (PVar "rargs")) () (ETuple (EVar "ri") (EApp (EApp (EMethodRef "map") (EApp (EVar "unrigidSig") (EVar "cells"))) (EVar "rargs"))))))) (EApp (EVar "snd") (EVar "m"))))) (EApp (EApp (EApp (EApp (EVar "findMatchingImplReqsU") (EVar "sx")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "residualUnivRef") "value")) (EVar "iface")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EVar "substMono") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "toRigid")) (EListLit)) (EListLit))) (EVar "args")))))))
(DTypeSig false "routeOf" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "Undetermined") (TyFun (TyCon "Mono") (TyCon "Route"))))))))
(DFunDef false "routeOf" ((PVar "sx") (PVar "iface") (PVar "encl") (PVar "useScope") (PVar "policy") (PVar "m")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeOfD") (EVar "sx")) (EVar "iface")) (EVar "encl")) (EVar "useScope")) (EVar "policy")) (EVar "m")) (EListLit)) (EApp (EVar "reqWalkStart") (ELit LUnit))))
(DTypeSig true "routesOfMonosTopV" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "IfaceRef")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "Route")))))))))
(DFunDef false "routesOfMonosTopV" ((PVar "sx") (PVar "encl") (PVar "useScope") (PVar "monos") (PVar "ifaces") (PList)) (EApp (EApp (EApp (EApp (EApp (EVar "routesOfMonosTop") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "monos")) (EVar "ifaces")))
(DFunDef false "routesOfMonosTopV" ((PVar "sx") PWild PWild (PList) PWild PWild) (EListLit))
(DFunDef false "routesOfMonosTopV" ((PVar "sx") (PVar "encl") (PVar "useScope") (PCons (PVar "m") (PVar "rest")) (PList) (PCons PWild (PVar "vs"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeOf") (EVar "sx")) (EVar "ifaceRefNone")) (EVar "encl")) (EVar "useScope")) (EApp (EVar "CountImpls") (EVar "ifaceRefNone"))) (EVar "m")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routesOfMonosTopV") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "rest")) (EListLit)) (EVar "vs"))))
(DFunDef false "routesOfMonosTopV" ((PVar "sx") (PVar "encl") (PVar "useScope") (PCons (PVar "m") (PVar "rest")) (PCons (PVar "iface") (PVar "ifacesRest")) (PCons (PVar "v") (PVar "vs"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "topRouteV") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "iface")) (EVar "m")) (EVar "v")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routesOfMonosTopV") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "rest")) (EVar "ifacesRest")) (EVar "vs"))))
(DTypeSig false "topRouteV" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Route"))))))))
(DFunDef false "topRouteV" ((PVar "sx") (PVar "encl") (PVar "useScope") (PVar "iface") (PVar "m") (PVar "goals")) (EMatch (EApp (EApp (EVar "vectorGoal") (EVar "iface")) (EVar "goals")) (arm (PCon "Some" (PTuple (PVar "g0") (PVar "gs"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeOfD") (EVar "sx")) (EVar "iface")) (EVar "encl")) (EVar "useScope")) (EApp (EVar "CountImpls") (EVar "iface"))) (EVar "g0")) (EVar "gs")) (EApp (EVar "reqWalkStart") (ELit LUnit)))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeOf") (EVar "sx")) (EVar "iface")) (EVar "encl")) (EVar "useScope")) (EApp (EVar "CountImpls") (EVar "iface"))) (EVar "m")))))
(DTypeSig false "vectorGoal" (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Mono")))))))
(DFunDef false "vectorGoal" (PWild (PList)) (EVar "None"))
(DFunDef false "vectorGoal" ((PVar "iface") (PCons (PVar "g0") (PVar "gs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "iface") "irName") (ELit (LString ""))) (EVar "None") (EApp (EVar "Some") (ETuple (EVar "g0") (EVar "gs")))))
(DTypeSig false "routesOfMonosTop" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "IfaceRef")) (TyApp (TyCon "List") (TyCon "Route"))))))))
(DFunDef false "routesOfMonosTop" ((PVar "sx") PWild PWild (PList) PWild) (EListLit))
(DFunDef false "routesOfMonosTop" ((PVar "sx") (PVar "encl") (PVar "useScope") (PCons (PVar "m") (PVar "rest")) (PList)) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeOf") (EVar "sx")) (EVar "ifaceRefNone")) (EVar "encl")) (EVar "useScope")) (EApp (EVar "CountImpls") (EVar "ifaceRefNone"))) (EVar "m")) (EApp (EApp (EApp (EApp (EApp (EVar "routesOfMonosTop") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "rest")) (EListLit))))
(DFunDef false "routesOfMonosTop" ((PVar "sx") (PVar "encl") (PVar "useScope") (PCons (PVar "m") (PVar "rest")) (PCons (PVar "iface") (PVar "ifacesRest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeOf") (EVar "sx")) (EVar "iface")) (EVar "encl")) (EVar "useScope")) (EApp (EVar "CountImpls") (EVar "iface"))) (EVar "m")) (EApp (EApp (EApp (EApp (EApp (EVar "routesOfMonosTop") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "rest")) (EVar "ifacesRest"))))
(DTypeSig true "methodPredicateRoutes" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyCon "PredicateSlot")) (TyApp (TyCon "List") (TyCon "Route")))))))
(DFunDef false "methodPredicateRoutes" ((PVar "sx") (PVar "encl") (PVar "scope") (PVar "slots")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "methodPredicateRoute") (EVar "sx")) (EVar "encl")) (EVar "scope"))) (EVar "slots")))
(DTypeSig false "methodPredicateRoute" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "PredicateSlot") (TyCon "Route"))))))
(DFunDef false "methodPredicateRoute" ((PVar "sx") (PVar "encl") (PVar "scope") (PVar "slot")) (EMatch (EFieldAccess (EVar "slot") "psArgs") (arm (PCon "PSArgsKnown" (PCons (PVar "g0") (PVar "gs"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeOfD") (EVar "sx")) (EFieldAccess (EVar "slot") "psIface")) (EVar "encl")) (EVar "scope")) (EVar "KeepNone")) (EVar "g0")) (EVar "gs")) (EApp (EVar "reqWalkStart") (ELit LUnit)))) (arm PWild () (EVar "RNone"))))
(DTypeSig true "recRoutes" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "PredicateSlot")) (TyApp (TyCon "List") (TyCon "Route"))))))))
(DFunDef false "recRoutes" ((PVar "sx") (PVar "encl") (PVar "scope") (PVar "mono") (PVar "slots")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EVar "recRoute") (EVar "sx")) (EVar "encl")) (EVar "scope")) (EVar "mono"))) (EVar "slots")))
(DTypeSig false "recRoute" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "Mono") (TyFun (TyCon "PredicateSlot") (TyCon "Route")))))))
(DFunDef false "recRoute" ((PVar "sx") (PVar "encl") (PVar "scope") (PVar "mono") (PVar "slot")) (EMatch (EApp (EApp (EApp (EVar "recPredicateArgs") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "mono")) (EVar "slot")) (arm (PCon "Some" (PCons (PVar "g0") (PVar "gs"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeOfD") (EVar "sx")) (EFieldAccess (EVar "slot") "psIface")) (EVar "encl")) (EVar "scope")) (EVar "KeepNone")) (EVar "g0")) (EVar "gs")) (EApp (EVar "reqWalkStart") (ELit LUnit)))) (arm PWild () (EMatch (EFieldAccess (EVar "slot") "psBoundIds") (arm (PCons (PVar "id") PWild) () (EMatch (EApp (EApp (EVar "findTvarInMono") (EVar "mono")) (EVar "id")) (arm (PCon "None") () (EVar "RNone")) (arm (PCon "Some" (PVar "m")) () (EApp (EApp (EApp (EApp (EApp (EVar "resolveRecMono") (EVar "sx")) (EVar "encl")) (EVar "scope")) (EFieldAccess (EVar "slot") "psIface")) (EVar "m"))))) (arm (PList) () (EVar "RNone"))))))
(DTypeSig false "recPredicateArgs" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "PredicateSlot") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Mono")))))))
(DFunDef false "recPredicateArgs" ((PVar "gctx") (PVar "mono") (PVar "slot")) (EMatch (EFieldAccess (EVar "slot") "psArgs") (arm (PCon "PSArgsUnknown") () (EVar "None")) (arm (PCon "PSArgsKnown" (PVar "args")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "subst")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EVar "subst")) (EListLit)) (EListLit))) (EVar "args")))) (EApp (EApp (EVar "recSlotSubst") (EVar "mono")) (EFieldAccess (EVar "slot") "psBoundIds"))))))
(DTypeSig false "recSlotSubst" (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))))))
(DFunDef false "recSlotSubst" (PWild (PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "recSlotSubst" ((PVar "mono") (PCons (PVar "id") (PVar "rest"))) (EMatch (EApp (EApp (EVar "findTvarInMono") (EVar "mono")) (EVar "id")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "m")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (ETuple (EVar "id") (EVar "m")) (EVar "_s")))) (EApp (EApp (EVar "recSlotSubst") (EVar "mono")) (EVar "rest"))))))
(DTypeSig false "resolveRecMono" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "Mono") (TyCon "Route")))))))
(DFunDef false "resolveRecMono" ((PVar "sx") (PVar "encl") (PVar "scope") (PVar "iface") (PVar "m")) (EMatch (EApp (EVar "headTyconMono") (EVar "m")) (arm (PCon "Some" (PAs "hk" (PCon "HkRigid" PWild))) () (EApp (EApp (EApp (EVar "RKey") (EApp (EVar "headKeyTag") (EVar "hk"))) (EListLit)) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "superRoutesAt") (EVar "sx")) (EVar "iface")) (EVar "encl")) (EVar "scope")) (EListLit (EVar "m"))) (EApp (EVar "reqWalkStart") (ELit LUnit))))) (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeOfD") (EVar "sx")) (EVar "iface")) (EVar "encl")) (EVar "scope")) (EVar "KeepNone")) (EVar "m")) (EListLit)) (EApp (EVar "reqWalkStart") (ELit LUnit)))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EVar "enclSlot") (EFieldAccess (EVar "sx") "sxModule")) (EVar "encl")) (EVar "m")) (arm (PCon "Some" (PVar "slot")) () (EBlock (DoLet false false (PVar "binder") (EApp (EApp (EVar "Scopes.binderAt") (EApp (EApp (EVar "Scopes.declarationScope") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (ELit LUnit))) (EVar "scope"))) (EVar "slot"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "assumAnswerRoute") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EApp (EVar "LegacyScalar") (EVar "binder"))) (EApp (EVar "Some") (EVar "iface"))) (EVar "scope")) (EVar "RDict"))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeOf") (EVar "sx")) (EVar "ifaceRefNone")) (ELit (LString ""))) (EVar "scope")) (EVar "KeepNone")) (EVar "m")))))))
(DTypeSig true "solveExactReturnOnce" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "MethodReturnRequest") (TyCon "MethodReturnResolution"))))
(DFunDef false "solveExactReturnOnce" ((PVar "sx") (PVar "request")) (EMatch (EFieldAccess (EFieldAccess (EVar "request") "mrrResolution") "value") (arm (PCon "Some" (PVar "resolution")) () (EVar "resolution")) (arm (PCon "None") () (EBlock (DoLet false false (PVar "resolution") (EApp (EApp (EVar "solveExactReturn") (EVar "sx")) (EVar "request"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "request") "mrrResolution")) (EApp (EVar "Some") (EVar "resolution")))) (DoExpr (EVar "resolution"))))))
(DTypeSig true "methodReturnAmbiguousWithoutGiven" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodReturnRequest") (TyCon "Bool"))))
(DFunDef false "methodReturnAmbiguousWithoutGiven" ((PVar "mctx") (PVar "request")) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "methodPredicateTemplateHasAbsent") (EFieldAccess (EVar "request") "mrrPredicateTemplate")) (EApp (EVar "isNone") (EApp (EApp (EApp (EApp (EVar "uniqueMethodTemplateGiven") (EFieldAccess (EVar "mctx") "mcGraph")) (EFieldAccess (EVar "request") "mrrPredicateTemplate")) (EFieldAccess (EVar "request") "mrrScope")) (EApp (EApp (EVar "givensForScope") (EFieldAccess (EVar "mctx") "mcGraph")) (EFieldAccess (EVar "request") "mrrScope"))))) (EBinOp ">=" (EApp (EApp (EApp (EVar "methodPredicateTemplateCandidateCount") (EFieldAccess (EVar "request") "mrrPredicateTemplate")) (EApp (EVar "ieRowsAll") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "bodyImplEnvRef") "value"))) (ELit (LInt 0))) (ELit (LInt 2)))))
(DTypeSig true "methodPredicateTemplateHasAbsent" (TyFun (TyCon "MethodPredicateTemplate") (TyCon "Bool")))
(DFunDef false "methodPredicateTemplateHasAbsent" ((PVar "template")) (EApp (EApp (EVar "anyListM") (EVar "isNone")) (EFieldAccess (EVar "template") "mptArguments")))
(DTypeSig false "methodPredicateTemplateCandidateCount" (TyFun (TyCon "MethodPredicateTemplate") (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "methodPredicateTemplateCandidateCount" (PWild PWild (PVar "count")) (EIf (EBinOp ">=" (EDictApp "count") (ELit (LInt 2))) (EDictApp "count") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "methodPredicateTemplateCandidateCount" (PWild (PList) (PVar "count")) (EDictApp "count"))
(DFunDef false "methodPredicateTemplateCandidateCount" ((PVar "template") (PCons (PVar "row") (PVar "rest")) (PVar "count")) (EApp (EApp (EApp (EVar "methodPredicateTemplateCandidateCount") (EVar "template")) (EVar "rest")) (EIf (EApp (EApp (EVar "methodPredicateTemplateMatchesRow") (EVar "template")) (EVar "row")) (EBinOp "+" (EDictApp "count") (ELit (LInt 1))) (EDictApp "count"))))
(DTypeSig false "methodPredicateTemplateMatchesRow" (TyFun (TyCon "MethodPredicateTemplate") (TyFun (TyCon "ImplRow") (TyCon "Bool"))))
(DFunDef false "methodPredicateTemplateMatchesRow" ((PVar "template") (PCon "ImplRow" PWild PWild (PVar "iface") (PVar "tys") PWild PWild PWild)) (EBinOp "&&" (EApp (EApp (EVar "sameIfaceDecl") (EFieldAccess (EVar "template") "mptInterface")) (EVar "iface")) (EMatch (EApp (EApp (EVar "methodPredicateTemplateHeadPairs") (EFieldAccess (EVar "template") "mptArguments")) (EVar "tys")) (arm (PCon "Some" (PVar "pairs")) () (EBlock (DoLet false false (PVar "subst") (EApp (EVar "Ref") (EListLit))) (DoExpr (EApp (EVar "isSome") (EApp (EApp (EApp (EApp (EApp (EVar "matchOneSided") (EVar "matchStep")) (EVar "eqStr")) (EApp (EVar "matchEqMono") (EVar "subst"))) (EVar "pairs")) (EListLit)))))) (arm (PCon "None") () (EVar "False")))))
(DTypeSig false "methodPredicateTemplateHeadPairs" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "Ty") (TyCon "Mono")))))))
(DFunDef false "methodPredicateTemplateHeadPairs" ((PList) (PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "methodPredicateTemplateHeadPairs" ((PCons (PCon "Some" (PVar "argument")) (PVar "rest")) (PCons (PVar "head") (PVar "heads"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (ETuple (EVar "head") (EVar "argument")) (EVar "_s")))) (EApp (EApp (EVar "methodPredicateTemplateHeadPairs") (EVar "rest")) (EVar "heads"))))
(DFunDef false "methodPredicateTemplateHeadPairs" ((PCons (PCon "None") (PVar "rest")) (PCons PWild (PVar "heads"))) (EApp (EApp (EVar "methodPredicateTemplateHeadPairs") (EVar "rest")) (EVar "heads")))
(DFunDef false "methodPredicateTemplateHeadPairs" (PWild PWild) (EVar "None"))
(DTypeSig false "solveExactReturn" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "MethodReturnRequest") (TyCon "MethodReturnResolution"))))
(DFunDef false "solveExactReturn" ((PVar "sx") (PVar "request")) (EMatch (EApp (EApp (EVar "methodReturnWanted") (EFieldAccess (EVar "sx") "sxModule")) (EVar "request")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "complete return solver received a legacy request")))) (arm (PCon "Some" (PVar "wanted")) () (EBlock (DoLet false false (PVar "predicate") (EFieldAccess (EVar "wanted") "predicate")) (DoLet false false (PVar "args") (EApp (EApp (EMethodRef "map") (EVar "normalize")) (EFieldAccess (EVar "predicate") "predicateArguments"))) (DoLet false false (PVar "predRequest") (ERecordCreate "PredicateRequest" ((fa "prIface" (EFieldAccess (EVar "predicate") "predicateInterface")) (fa "prArgs" (EApp (EVar "PSArgsKnown") (EVar "args")))))) (DoLet false false (PVar "resultMono") (EApp (EVar "stripArrows") (EFieldAccess (EVar "request") "mrrOccurrence"))) (DoLet false false (PVar "given") (EApp (EApp (EVar "orElseOpt") (EApp (EApp (EApp (EApp (EApp (EVar "activeDictVarOfEncl") (EFieldAccess (EVar "sx") "sxModule")) (EApp (EVar "Some") (EVar "predRequest"))) (EVar "resultMono")) (EFieldAccess (EVar "request") "mrrEnclosing")) (EFieldAccess (EVar "wanted") "scope"))) (EApp (EApp (EApp (EApp (EVar "activeDictPredOf") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "predRequest")) (EVar "resultMono")) (EFieldAccess (EVar "wanted") "scope")))) (DoExpr (EMatch (EVar "given") (arm (PCon "Some" (PVar "answer")) () (EBlock (DoExpr (EApp (EApp (EApp (EVar "noteAssumption") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EFieldAccess (EVar "wanted") "scope")) (EVar "answer"))) (DoExpr (ERecordCreate "MethodReturnResolution" ((fa "mrrWanted" (EVar "wanted")) (fa "mrrOutcome" (EApp (EVar "Solved") (EApp (EVar "assumAnswerEvidence") (EVar "answer")))) (fa "mrrSelectedRow" (EVar "None"))))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "solveExactReturnInstance") (EVar "sx")) (EVar "request")) (EVar "wanted")) (EVar "args")))))))))
(DTypeSig false "solveExactReturnInstance" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "MethodReturnRequest") (TyFun (TyCon "Wanted") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "MethodReturnResolution"))))))
(DFunDef false "solveExactReturnInstance" ((PVar "sx") (PVar "request") (PVar "wanted") (PList)) (ERecordCreate "MethodReturnResolution" ((fa "mrrWanted" (EVar "wanted")) (fa "mrrOutcome" (EApp (EApp (EVar "Deferred") (EVar "wanted")) (EListLit (EVar "BlockingFinalization")))) (fa "mrrSelectedRow" (EVar "None")))))
(DFunDef false "solveExactReturnInstance" ((PVar "sx") (PVar "request") (PVar "wanted") (PVar "args")) (EBlock (DoLet false false (PVar "env") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "bodyImplEnvRef") "value")) (DoLet false false (PVar "iface") (EFieldAccess (EFieldAccess (EVar "wanted") "predicate") "predicateInterface")) (DoLet false false (PVar "selected") (EApp (EApp (EVar "orElseOpt") (EApp (EApp (EApp (EApp (EVar "ieSelectRowByIface") (EVar "sx")) (EVar "env")) (EVar "iface")) (EVar "args"))) (EApp (EApp (EApp (EVar "determinedGoalInstance") (EFieldAccess (EVar "sx") "sxModule")) (EVar "iface")) (EVar "args")))) (DoExpr (EMatch (EVar "selected") (arm (PCon "Some" (PAs "row" (PCon "ImplRow" PWild (PVar "inst") (PVar "selectedIface") PWild PWild PWild PWild))) () (EBlock (DoLet false false (PVar "prerequisites") (EApp (EApp (EApp (EVar "methodReturnPrerequisites") (EFieldAccess (EVar "sx") "sxModule")) (EVar "args")) (EVar "row"))) (DoExpr (ERecordCreate "MethodReturnResolution" ((fa "mrrWanted" (EVar "wanted")) (fa "mrrOutcome" (EApp (EVar "Solved") (EApp (EApp (EApp (EApp (EVar "InstanceEvidence") (EApp (EVar "RequestInstanceId") (EApp (EVar "instRefSeq") (EVar "inst")))) (EVar "args")) (EVar "prerequisites")) (EApp (EApp (EApp (EVar "instanceSuperEvidence") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "selectedIface")) (EVar "args"))))) (fa "mrrSelectedRow" (EApp (EVar "Some") (EVar "row")))))))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "outcome") (EIf (EApp (EApp (EApp (EVar "exactReturnDefers") (EFieldAccess (EVar "sx") "sxModule")) (EVar "wanted")) (EVar "args")) (EApp (EApp (EVar "Deferred") (EVar "wanted")) (EApp (EVar "exactReturnBlockers") (EVar "args"))) (EApp (EApp (EVar "Insoluble") (EVar "wanted")) (EVar "MissingInstance")))) (DoExpr (ERecordCreate "MethodReturnResolution" ((fa "mrrWanted" (EVar "wanted")) (fa "mrrOutcome" (EVar "outcome")) (fa "mrrSelectedRow" (EVar "None")))))))))))
(DTypeSig false "exactReturnDefers" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Wanted") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool")))))
(DFunDef false "exactReturnDefers" ((PVar "mctx") (PVar "wanted") (PVar "args")) (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EBinOp "==" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "wanted") "predicate") "predicateInterface") "irName") (ELit (LString "Num"))) (EApp (EVar "not") (EApp (EApp (EVar "builtinClassPresent") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "BNum")))) (EApp (EVar "not") (EApp (EVar "allConcreteHeads") (EVar "args")))) (EApp (EApp (EApp (EApp (EVar "goalDefersOpenWorld") (EVar "mctx")) (EFieldAccess (EVar "wanted") "scope")) (EFieldAccess (EFieldAccess (EVar "wanted") "predicate") "predicateInterface")) (EVar "args"))))
(DTypeSig false "exactReturnBlockers" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "SolverBlocker"))))
(DFunDef false "exactReturnBlockers" ((PVar "args")) (EApp (EApp (EMethodRef "map") (EVar "BlockingTypeVariable")) (EApp (EApp (EDictApp "flatMap") (EVar "monoUnboundIds")) (EVar "args"))))
(DTypeSig false "methodReturnPrerequisites" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ImplRow") (TyApp (TyCon "List") (TyCon "PrerequisiteEvidence"))))))
(DFunDef false "methodReturnPrerequisites" ((PVar "mctx") (PVar "args") (PVar "row")) (EMatch (EApp (EApp (EApp (EVar "selectedRowReqMatch") (EVar "mctx")) (EVar "args")) (EVar "row")) (arm (PCon "Some" (PTuple (PVar "subst") (PVar "reqs"))) () (EApp (EApp (EMethodRef "map") (EBinOp ">>" (EApp (EApp (EVar "reqToObligation") (EVar "mctx")) (EVar "subst")) (EVar "prerequisiteEvidence"))) (EVar "reqs"))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "instanceSuperEvidence" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "SuperEvidence"))))))
(DFunDef false "instanceSuperEvidence" ((PVar "gctx") (PVar "iface") (PVar "args")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "superIface") (PVar "superArgs"))) (ERecordCreate "SuperEvidence" ((fa "superInterface" (EVar "superIface")) (fa "superArguments" (EApp (EApp (EVar "optionOr") (EListLit)) (EVar "superArgs"))))))) (EApp (EApp (EApp (EVar "directSuperGoals") (EVar "gctx")) (EVar "iface")) (EVar "args"))))
(DTypeSig false "prerequisiteEvidence" (TyFun (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))) (TyCon "PrerequisiteEvidence")))
(DFunDef false "prerequisiteEvidence" ((PTuple (PVar "iface") (PVar "args"))) (ERecordCreate "PrerequisiteEvidence" ((fa "prerequisiteInterface" (EVar "iface")) (fa "prerequisiteArguments" (EVar "args")))))
(DTypeSig true "methodReturnResolutionValid" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodReturnRequest") (TyFun (TyCon "MethodReturnResolution") (TyCon "Bool")))))
(DFunDef false "methodReturnResolutionValid" ((PVar "mctx") (PVar "request") (PVar "resolution")) (EBinOp "&&" (EApp (EApp (EApp (EVar "methodReturnWantedMatches") (EVar "mctx")) (EVar "request")) (EFieldAccess (EVar "resolution") "mrrWanted")) (EMatch (ETuple (EFieldAccess (EVar "resolution") "mrrOutcome") (EFieldAccess (EVar "resolution") "mrrSelectedRow")) (arm (PTuple (PCon "Solved" (PCon "GivenEvidence" PWild)) (PCon "None")) () (EVar "True")) (arm (PTuple (PCon "Solved" (PCon "SuperclassEvidence" (PVar "parent") (PVar "path"))) (PCon "None")) () (EMatch (EApp (EApp (EApp (EVar "projectedGivenOf") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "parent")) (EVar "path")) (arm (PCon "Some" (PVar "g")) () (EApp (EApp (EVar "predicateRequestMatchesSlot") (ERecordCreate "PredicateRequest" ((fa "prIface" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "resolution") "mrrWanted") "predicate") "predicateInterface")) (fa "prArgs" (EApp (EVar "PSArgsKnown") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "resolution") "mrrWanted") "predicate") "predicateArguments")))))) (EFieldAccess (EVar "g") "geSlot"))) (arm (PCon "None") () (EVar "False")))) (arm (PTuple (PCon "Solved" (PCon "InstanceEvidence" (PVar "identity") (PVar "args") (PVar "prerequisites") PWild)) (PCon "Some" (PVar "row"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "methodReturnInstanceMatches") (EVar "identity")) (EVar "row")) (EApp (EApp (EVar "monoVecSameGiven") (EVar "args")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "resolution") "mrrWanted") "predicate") "predicateArguments"))) (EApp (EApp (EVar "methodReturnPrerequisitesMatch") (EVar "prerequisites")) (EApp (EApp (EApp (EVar "methodReturnPrerequisites") (EVar "mctx")) (EVar "args")) (EVar "row"))))) (arm (PTuple (PCon "Deferred" (PVar "wanted") PWild) (PCon "None")) () (EApp (EApp (EVar "wantedMatches") (EVar "wanted")) (EFieldAccess (EVar "resolution") "mrrWanted"))) (arm (PTuple (PCon "Insoluble" (PVar "wanted") PWild) (PCon "None")) () (EApp (EApp (EVar "wantedMatches") (EVar "wanted")) (EFieldAccess (EVar "resolution") "mrrWanted"))) (arm PWild () (EVar "False")))))
(DTypeSig false "methodReturnWantedMatches" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodReturnRequest") (TyFun (TyCon "Wanted") (TyCon "Bool")))))
(DFunDef false "methodReturnWantedMatches" ((PVar "mctx") (PVar "request") (PVar "wanted")) (EMatch (EApp (EApp (EVar "methodReturnWanted") (EVar "mctx")) (EVar "request")) (arm (PCon "Some" (PVar "carried")) () (EApp (EApp (EVar "wantedMatches") (EVar "carried")) (EVar "wanted"))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "wantedMatches" (TyFun (TyCon "Wanted") (TyFun (TyCon "Wanted") (TyCon "Bool"))))
(DFunDef false "wantedMatches" ((PVar "left") (PVar "right")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "left") "id") (EFieldAccess (EVar "right") "id")) (EApp (EApp (EVar "sameTraceEvId") (EFieldAccess (EVar "left") "destination")) (EFieldAccess (EVar "right") "destination"))) (EBinOp "==" (EFieldAccess (EVar "left") "scope") (EFieldAccess (EVar "right") "scope"))) (EApp (EApp (EVar "sameIfaceDecl") (EFieldAccess (EFieldAccess (EVar "left") "predicate") "predicateInterface")) (EFieldAccess (EFieldAccess (EVar "right") "predicate") "predicateInterface"))) (EApp (EApp (EVar "monoVecSameGiven") (EFieldAccess (EFieldAccess (EVar "left") "predicate") "predicateArguments")) (EFieldAccess (EFieldAccess (EVar "right") "predicate") "predicateArguments"))))
(DTypeSig false "methodReturnInstanceMatches" (TyFun (TyCon "RequestInstanceId") (TyFun (TyCon "ImplRow") (TyCon "Bool"))))
(DFunDef false "methodReturnInstanceMatches" ((PCon "RequestInstanceId" (PVar "identity")) (PCon "ImplRow" PWild (PVar "inst") PWild PWild PWild PWild PWild)) (EBinOp "==" (EVar "identity") (EApp (EVar "instRefSeq") (EVar "inst"))))
(DTypeSig false "methodReturnPrerequisitesMatch" (TyFun (TyApp (TyCon "List") (TyCon "PrerequisiteEvidence")) (TyFun (TyApp (TyCon "List") (TyCon "PrerequisiteEvidence")) (TyCon "Bool"))))
(DFunDef false "methodReturnPrerequisitesMatch" ((PList) (PList)) (EVar "True"))
(DFunDef false "methodReturnPrerequisitesMatch" ((PCons (PVar "left") (PVar "ls")) (PCons (PVar "right") (PVar "rs"))) (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "sameIfaceDecl") (EFieldAccess (EVar "left") "prerequisiteInterface")) (EFieldAccess (EVar "right") "prerequisiteInterface")) (EApp (EApp (EVar "monoVecSameGiven") (EFieldAccess (EVar "left") "prerequisiteArguments")) (EFieldAccess (EVar "right") "prerequisiteArguments"))) (EApp (EApp (EVar "methodReturnPrerequisitesMatch") (EVar "ls")) (EVar "rs"))))
(DFunDef false "methodReturnPrerequisitesMatch" (PWild PWild) (EVar "False"))
(DTypeSig true "improveByUniqueImpl" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyCon "Unit")))))
(DFunDef false "improveByUniqueImpl" ((PVar "dyn") PWild (PList)) (ELit LUnit))
(DFunDef false "improveByUniqueImpl" ((PVar "dyn") (PVar "sigIds") (PCons (PVar "o") (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "improveGoal") (EVar "dyn")) (EVar "sigIds")) (EFieldAccess (EFieldAccess (EVar "o") "pred") "iface")) (EApp (EApp (EMethodRef "map") (EVar "normalize")) (EApp (EApp (EVar "uOblArgs") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph")) (EVar "o"))))) (DoExpr (EApp (EApp (EApp (EVar "improveByUniqueImpl") (EVar "dyn")) (EVar "sigIds")) (EVar "rest")))))
(DTypeSig true "determineByUniqueInstance" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyCon "Unit")))))
(DFunDef false "determineByUniqueInstance" ((PVar "mctx") (PVar "rigidIds") (PVar "obls")) (EIf (EApp (EVar "isNonEmptyL") (EVar "obls")) (EApp (EApp (EApp (EApp (EVar "determineSweeps") (EVar "mctx")) (EVar "rigidIds")) (EApp (EApp (EVar "goalWindowOf") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "obls"))) (EBinOp "+" (EApp (EVar "listLen") (EVar "obls")) (ELit (LInt 1)))) (ELit LUnit)))
(DTypeSig false "determineSweeps" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GoalWindow") (TyFun (TyCon "Int") (TyCon "Unit"))))))
(DFunDef false "determineSweeps" ((PVar "mctx") (PVar "rigidIds") (PVar "window") (PVar "fuel")) (EIf (EBinOp "&&" (EBinOp ">" (EVar "fuel") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EApp (EVar "determineByUniqueInstanceGo") (EVar "mctx")) (EVar "rigidIds")) (EVar "window")) (EVar "False")) (EFieldAccess (EVar "window") "gwGoals"))) (EApp (EApp (EApp (EApp (EVar "determineSweeps") (EVar "mctx")) (EVar "rigidIds")) (EVar "window")) (EBinOp "-" (EVar "fuel") (ELit (LInt 1)))) (ELit LUnit)))
(DTypeSig false "determineByUniqueInstanceGo" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GoalWindow") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "UObligation"))) (TyCon "Bool")))))))
(DFunDef false "determineByUniqueInstanceGo" ((PVar "mctx") PWild PWild (PVar "changed") (PList)) (EVar "changed"))
(DFunDef false "determineByUniqueInstanceGo" ((PVar "mctx") (PVar "rigidIds") (PVar "window") (PVar "changed") (PCons (PTuple PWild (PVar "o")) (PVar "rest"))) (EBlock (DoLet false false (PVar "args") (EApp (EApp (EMethodRef "map") (EVar "normalize")) (EApp (EApp (EVar "uOblArgs") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "o")))) (DoLet false false (PVar "now") (EApp (EApp (EApp (EApp (EApp (EVar "determineGoal") (EVar "mctx")) (EVar "rigidIds")) (EVar "window")) (EVar "o")) (EVar "args"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "determineByUniqueInstanceGo") (EVar "mctx")) (EVar "rigidIds")) (EVar "window")) (EBinOp "||" (EVar "now") (EVar "changed"))) (EVar "rest")))))
(DTypeSig false "determineGoal" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GoalWindow") (TyFun (TyCon "UObligation") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool")))))))
(DFunDef false "determineGoal" ((PVar "mctx") (PVar "rigidIds0") (PVar "window") (PVar "o") (PVar "args")) (EBlock (DoLet false false (PVar "rigidIds") (EApp (EApp (EApp (EVar "withDeclaredVars") (EVar "mctx")) (EVar "rigidIds0")) (EVar "args"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "determineHeldGoal") (EVar "mctx")) (EVar "rigidIds")) (EVar "window")) (EVar "o")) (EVar "args")))))
(DTypeSig false "withDeclaredVars" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "withDeclaredVars" ((PVar "mctx") (PVar "rigidIds") (PVar "args")) (EBlock (DoLet false false (PVar "declared") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "declaredSigVarIds") "value")) (DoExpr (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "filterList") (ELam ((PVar "k")) (EApp (EApp (EVar "omHasKey") (EVar "k")) (EVar "declared")))) (EApp (EApp (EMethodRef "map") (EVar "intToString")) (EApp (EApp (EDictApp "flatMap") (EVar "monoUnboundIds")) (EVar "args"))))) (EVar "rigidIds")))))
(DTypeSig false "determineHeldGoal" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GoalWindow") (TyFun (TyCon "UObligation") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool")))))))
(DFunDef false "determineHeldGoal" ((PVar "mctx") (PVar "rigidIds") (PVar "window") (PVar "o") (PVar "args")) (EIf (EBinOp "||" (EApp (EVar "monoVectorClosed") (EVar "args")) (EApp (EApp (EVar "goalVarsAllHeld") (EVar "rigidIds")) (EVar "args"))) (EVar "False") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EApp (EVar "goalRows") (EVar "mctx")) (EFieldAccess (EFieldAccess (EVar "o") "pred") "iface")) (EVar "args"))) (DoLet false false (PVar "unifying") (EIf (EApp (EApp (EVar "goalIsProjection") (EVar "args")) (EVar "rows")) (EListLit) (EApp (EApp (EApp (EApp (EVar "goalCandidates") (EVar "mctx")) (EVar "rigidIds")) (EVar "args")) (EVar "rows")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "determinationCandidates") (EVar "mctx")) (EVar "window")) (EVar "args")) (EVar "unifying")) (arm (PList (PTuple (PVar "row") PWild)) () (EBlock (DoLet false false (PVar "oldIds") (EApp (EVar "dedupI") (EApp (EApp (EDictApp "flatMap") (EVar "monoUnboundIds")) (EVar "args")))) (DoLet false false (PVar "sizeBefore") (EApp (EVar "monoSizes") (EVar "args"))) (DoExpr (EApp (EApp (EVar "enterLevel") (EVar "mctx")) (ELit LUnit))) (DoLet false false (PVar "heads") (EApp (EApp (EVar "freshRowHeads") (EVar "mctx")) (EVar "row"))) (DoExpr (EApp (EApp (EVar "exitLevel") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "commitImprovement") (EApp (EVar "dynFor") (EVar "mctx"))) (EVar "rigidIds")) (EApp (EApp (EVar "zip") (EVar "args")) (EVar "heads")))) (DoExpr (EApp (EApp (EApp (EVar "fileDeterminedRow") (EVar "mctx")) (EVar "row")) (EVar "args"))) (DoExpr (EApp (EApp (EApp (EVar "refileGoals") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "window")) (EVar "oldIds"))) (DoExpr (EBinOp "||" (EBinOp "/=" (EApp (EVar "monoSizes") (EVar "args")) (EVar "sizeBefore")) (EBinOp "/=" (EApp (EVar "listLen") (EApp (EVar "dedupI") (EApp (EApp (EDictApp "flatMap") (EVar "monoUnboundIds")) (EVar "args")))) (EApp (EVar "listLen") (EVar "oldIds"))))))) (arm PWild () (EVar "False"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "fileDeterminedRow" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ImplRow") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Unit")))))
(DFunDef false "fileDeterminedRow" ((PVar "mctx") PWild (PList)) (ELit LUnit))
(DFunDef false "fileDeterminedRow" ((PVar "mctx") (PVar "row") (PCons (PVar "first") (PVar "rest"))) (EMatch (EApp (EVar "normalize") (EVar "first")) (arm (PCon "TVar" (PVar "cell")) () (EBlock (DoLet false false (PVar "table") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "determinedRowsRef") "value")) (DoLet false false (PVar "filed") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "IdMap.get") (EApp (EVar "tyvarId") (EVar "cell"))) (EVar "table")))) (DoLet false false (PVar "entry") (ETuple (EVar "row") (EApp (EApp (EMethodRef "map") (EVar "normalize")) (EBinOp "::" (EVar "first") (EVar "rest"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "determinedRowsRef")) (EApp (EApp (EApp (EVar "IdMap.set") (EApp (EVar "tyvarId") (EVar "cell"))) (EBinOp "::" (EVar "entry") (EVar "filed"))) (EVar "table")))))) (arm PWild () (ELit LUnit))))
(DTypeSig true "refileDeterminedRows" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "Unit"))))
(DFunDef false "refileDeterminedRows" ((PVar "mctx") PWild) (EBlock (DoLet false false (PVar "table") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "determinedRowsRef") "value")) (DoExpr (EIf (EApp (EVar "not") (EApp (EVar "IdMap.isEmpty") (EVar "table"))) (EBlock (DoLet false false (PVar "entries") (EApp (EVar "reverseL") (EApp (EApp (EDictApp "flatMap") (EVar "identity")) (EApp (EVar "IdMap.values") (EVar "table"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "determinedRowsRef")) (EVar "Tip"))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "entry")) (EApp (EApp (EApp (EVar "fileDeterminedRow") (EVar "mctx")) (EApp (EVar "fst") (EVar "entry"))) (EApp (EVar "snd") (EVar "entry"))))) (ELit LUnit)) (EVar "entries")))) (ELit LUnit)))))
(DTypeSig true "goalVarsAllHeld" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))
(DFunDef false "goalVarsAllHeld" ((PVar "rigidIds") (PVar "args")) (EApp (EApp (EVar "allList") (ELam ((PVar "c")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "intToString") (EApp (EVar "tyvarId") (EVar "c")))) (EVar "rigidIds")))) (EApp (EApp (EDictApp "flatMap") (EVar "monoVarCells")) (EVar "args"))))
(DTypeSig true "determinationCandidates" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "GoalWindow") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "ImplRow") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))))) (TyApp (TyCon "List") (TyTuple (TyCon "ImplRow") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))))))))))
(DFunDef false "determinationCandidates" ((PVar "mctx") (PVar "window") (PVar "args") (PVar "unifying")) (EApp (EApp (EVar "filterList") (ELam ((PVar "cand")) (EBinOp "&&" (EApp (EApp (EVar "rowCountsFor") (EVar "args")) (EApp (EVar "fst") (EVar "cand"))) (EApp (EApp (EApp (EVar "siblingsStaySatisfiable") (EVar "mctx")) (EVar "window")) (EApp (EVar "snd") (EVar "cand")))))) (EVar "unifying")))
(DTypeSig true "goalWindowOf" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyCon "GoalWindow"))))
(DFunDef false "goalWindowOf" ((PVar "gctx") (PVar "obls")) (EBlock (DoLet false false (PVar "goals") (EApp (EVar "indexed") (EVar "obls"))) (DoExpr (ERecordCreate "GoalWindow" ((fa "gwGoals" (EVar "goals")) (fa "gwByIndex" (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PTuple (PVar "i") (PVar "o"))) (EApp (EApp (EApp (EVar "IdMap.set") (EVar "i")) (EVar "o")) (EVar "m")))) (EVar "Tip")) (EVar "goals"))) (fa "gwByVar" (EApp (EVar "Ref") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PTuple (PVar "i") (PVar "o"))) (EApp (EApp (EApp (EApp (EVar "fileGoal") (EVar "gctx")) (EVar "i")) (EVar "o")) (EVar "m")))) (EVar "Tip")) (EVar "goals")))))))))
(DTypeSig false "fileGoal" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyFun (TyCon "UObligation") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "fileGoal" ((PVar "gctx") (PVar "i") (PVar "o") (PVar "byVar")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PVar "id")) (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (EBinOp "::" (EVar "i") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EVar "m"))))) (EVar "m")))) (EVar "byVar")) (EApp (EVar "dedupI") (EApp (EApp (EDictApp "flatMap") (EVar "monoUnboundIds")) (EApp (EApp (EVar "uOblArgs") (EVar "gctx")) (EVar "o"))))))
(DTypeSig true "goalsOnVar" (TyFun (TyCon "GoalWindow") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "goalsOnVar" ((PVar "window") (PVar "id")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EFieldAccess (EFieldAccess (EVar "window") "gwByVar") "value"))))
(DTypeSig false "refileGoals" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "GoalWindow") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "refileGoals" ((PVar "gctx") (PVar "window") (PVar "oldIds")) (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "window") "gwByVar")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "i")) (EMatch (EApp (EApp (EVar "IdMap.get") (EVar "i")) (EFieldAccess (EVar "window") "gwByIndex")) (arm (PCon "Some" (PVar "g")) () (EApp (EApp (EApp (EApp (EVar "fileGoal") (EVar "gctx")) (EVar "i")) (EVar "g")) (EVar "acc"))) (arm (PCon "None") () (EVar "acc"))))) (EFieldAccess (EFieldAccess (EVar "window") "gwByVar") "value")) (EApp (EVar "dedupI") (EApp (EApp (EDictApp "flatMap") (EApp (EVar "goalsOnVar") (EVar "window"))) (EVar "oldIds"))))))
(DTypeSig false "rowHeadSubstRigid" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ImplRow") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))))))))
(DFunDef false "rowHeadSubstRigid" ((PVar "mctx") (PVar "rigidIds") (PVar "args") (PVar "row")) (EBlock (DoLet false false (PVar "heads") (EApp (EApp (EVar "freshRowHeads") (EVar "mctx")) (EVar "row"))) (DoLet false false (PVar "scratch") (EApp (EVar "Ref") (EListLit))) (DoExpr (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "listLen") (EVar "heads")) (EApp (EVar "listLen") (EVar "args"))) (EApp (EApp (EVar "cohOverlapGo") (EVar "scratch")) (EApp (EApp (EApp (EVar "rigidSigPairs") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "rigidIds")) (EApp (EApp (EVar "zip") (EVar "args")) (EVar "heads"))))) (EApp (EVar "Some") (EUnOp "!" (EVar "scratch"))) (EVar "None")))))
(DTypeSig false "siblingsStaySatisfiable" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "GoalWindow") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyCon "Bool")))))
(DFunDef false "siblingsStaySatisfiable" ((PVar "mctx") (PVar "window") (PVar "subst")) (EBlock (DoLet false false (PVar "bound") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "subst"))) (DoLet false false (PVar "scratch") (EApp (EVar "Ref") (EVar "subst"))) (DoExpr (EApp (EApp (EVar "allList") (ELam ((PVar "i")) (EMatch (EApp (EApp (EVar "IdMap.get") (EVar "i")) (EFieldAccess (EVar "window") "gwByIndex")) (arm (PCon "Some" (PVar "s")) () (EApp (EApp (EApp (EApp (EVar "siblingStaysSatisfiable") (EVar "mctx")) (EVar "scratch")) (EVar "bound")) (EVar "s"))) (arm (PCon "None") () (EVar "True"))))) (EApp (EVar "dedupI") (EApp (EApp (EDictApp "flatMap") (EApp (EVar "goalsOnVar") (EVar "window"))) (EVar "bound")))))))
(DTypeSig false "siblingStaysSatisfiable" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "UObligation") (TyCon "Bool"))))))
(DFunDef false "siblingStaysSatisfiable" ((PVar "mctx") (PVar "scratch") (PVar "bound") (PVar "s")) (EBlock (DoLet false false (PVar "args") (EApp (EApp (EMethodRef "map") (EVar "normalize")) (EApp (EApp (EVar "uOblArgs") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "s")))) (DoExpr (EIf (EApp (EVar "not") (EApp (EApp (EDictApp "any") (ELam ((PVar "i")) (EApp (EApp (EDictApp "elem") (EVar "i")) (EVar "bound")))) (EApp (EApp (EDictApp "flatMap") (EVar "monoUnboundIds")) (EVar "args")))) (EVar "True") (EBlock (DoLet false false (PVar "after") (EApp (EApp (EMethodRef "map") (EApp (EVar "cohApply") (EVar "scratch"))) (EVar "args"))) (DoExpr (EBinOp "||" (EApp (EVar "not") (EApp (EVar "monoVectorClosed") (EVar "after"))) (EApp (EApp (EVar "anyList") (ELam ((PVar "row")) (EBinOp "||" (EBinOp ">" (EApp (EVar "listLen") (EApp (EVar "ieRowTys") (EVar "row"))) (EApp (EVar "listLen") (EVar "after"))) (EApp (EApp (EApp (EVar "rowHeadMatches") (EVar "mctx")) (EVar "after")) (EVar "row"))))) (EApp (EApp (EVar "filterList") (EApp (EVar "ieRowOfIface") (EFieldAccess (EFieldAccess (EVar "s") "pred") "iface"))) (EApp (EApp (EVar "improvementPool") (EVar "mctx")) (EVar "after")))))))))))
(DTypeSig false "improveGoal" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Unit"))))))
(DFunDef false "improveGoal" ((PVar "dyn") (PVar "sigIds") (PVar "iface") (PVar "args")) (EIf (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "args")) (EApp (EVar "monoVectorClosed") (EVar "args"))) (ELit LUnit) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EVar "filterList") (EApp (EVar "ieRowOfIface") (EVar "iface"))) (EApp (EApp (EVar "improvementPool") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "args")))) (DoExpr (EMatch (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "rowHeadMatches") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "args"))) (EVar "rows")) (arm (PList (PVar "row")) () (EMatch (EApp (EApp (EVar "repeatedGoalPairs") (EApp (EVar "ieRowTys") (EVar "row"))) (EVar "args")) (arm (PList) () (ELit LUnit)) (arm (PVar "pairs") () (EIf (EBinOp "==" (EApp (EVar "listLen") (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "rowHeadUnifies") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "args"))) (EVar "rows"))) (ELit (LInt 1))) (EApp (EApp (EApp (EVar "commitImprovement") (EVar "dyn")) (EVar "sigIds")) (EVar "pairs")) (ELit LUnit))))) (arm PWild () (ELit LUnit))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "commitImprovement" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Mono"))) (TyCon "Unit")))))
(DFunDef false "commitImprovement" ((PVar "dyn") (PVar "sigIds") (PVar "pairs")) (EBlock (DoLet false false (PVar "cells") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "p")) (EBinOp "++" (EApp (EVar "monoVarCells") (EApp (EVar "fst") (EVar "p"))) (EApp (EVar "monoVarCells") (EApp (EVar "snd") (EVar "p")))))) (EVar "pairs"))) (DoLet false false (PVar "sigCells") (EApp (EApp (EVar "sigCellsOf") (EVar "sigIds")) (EVar "cells"))) (DoLet false false (PVar "scratch") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "rigidPairs") (EApp (EApp (EApp (EVar "rigidSigPairs") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph")) (EVar "sigIds")) (EVar "pairs"))) (DoLet false false (PVar "cellsById") (EApp (EApp (EMethodRef "map") (ELam ((PVar "c")) (ETuple (EApp (EVar "tyvarId") (EVar "c")) (EVar "c")))) (EVar "cells"))) (DoExpr (EIf (EApp (EApp (EVar "cohOverlapGo") (EVar "scratch")) (EVar "rigidPairs")) (EApp (EApp (EVar "each") (ELam ((PVar "binding")) (EMatch (EApp (EApp (EVar "lookupAssocI") (EApp (EVar "fst") (EVar "binding"))) (EVar "cellsById")) (arm (PCon "Some" (PVar "cell")) () (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EApp (EVar "TVar") (EVar "cell"))) (EApp (EApp (EVar "unrigidSig") (EVar "sigCells")) (EApp (EVar "snd") (EVar "binding"))))) (arm (PCon "None") () (ELit LUnit))))) (EApp (EVar "reverse") (EUnOp "!" (EVar "scratch")))) (ELit LUnit)))))
(DTypeSig true "improvementPool" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "ImplRow")))))
(DFunDef false "improvementPool" ((PVar "mctx") (PVar "args")) (EBlock (DoLet false false (PVar "env") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "bodyImplEnvRef") "value")) (DoExpr (EMatch (EApp (EVar "goalHeadCon") (EVar "args")) (arm (PCon "Some" (PVar "hk")) () (EBinOp "++" (EApp (EApp (EVar "ieHeadRows") (EApp (EVar "Some") (EVar "hk"))) (EVar "env")) (EApp (EApp (EVar "ieHeadRows") (EVar "None")) (EVar "env")))) (arm (PCon "None") () (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "args")) (ELit (LInt 1))) (EApp (EVar "ieRowsAll") (EVar "env")) (EListLit)))))))
(DTypeSig false "rowHeadUnifies" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ImplRow") (TyCon "Bool")))))
(DFunDef false "rowHeadUnifies" ((PVar "mctx") (PVar "args") (PVar "row")) (EBlock (DoLet false false (PVar "tys") (EApp (EVar "ieRowTys") (EVar "row"))) (DoLet false false (PVar "tvs") (EApp (EApp (EVar "freshTvMap") (EVar "mctx")) (EApp (EVar "dedup") (EApp (EApp (EDictApp "flatMap") (EVar "tyVarNames")) (EVar "tys"))))) (DoExpr (EApp (EApp (EVar "cohOverlap") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "fromAstType") (EVar "mctx")) (EVar "tvs"))) (EVar "tys"))) (EVar "args")))))
(DTypeSig false "repeatedGoalPairs" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Mono"))))))
(DFunDef false "repeatedGoalPairs" ((PVar "tys") (PVar "args")) (EMatch (EApp (EApp (EApp (EVar "positionBindings") (EVar "tys")) (EVar "args")) (EListLit)) (arm (PCon "Some" (PVar "binds")) () (EApp (EApp (EVar "repeatedBindings") (EVar "binds")) (EListLit))) (arm (PCon "None") () (EListLit))))
(DTypeSig true "goalAnsweredBy" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")))) (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))))
(DFunDef false "goalAnsweredBy" ((PVar "gctx") (PVar "answered") (PVar "iface") (PVar "args")) (EApp (EApp (EVar "anyList") (ELam ((PVar "g")) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "walkGoalSame") (EApp (EVar "fst") (EVar "g"))) (EApp (EVar "snd") (EVar "g"))) (EVar "iface")) (EVar "args")) (EApp (EApp (EVar "anyList") (ELam ((PVar "s")) (EApp (EApp (EApp (EApp (EVar "walkGoalSame") (EApp (EVar "fst") (EVar "s"))) (EApp (EVar "snd") (EVar "s"))) (EVar "iface")) (EVar "args")))) (EApp (EApp (EApp (EVar "superGoalClosure") (EVar "gctx")) (EApp (EVar "fst") (EVar "g"))) (EApp (EVar "snd") (EVar "g"))))))) (EVar "answered")))
(DTypeSig true "superGoalClosure" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))))))))
(DFunDef false "superGoalClosure" ((PVar "gctx") (PVar "iface") (PVar "args")) (EApp (EApp (EApp (EApp (EVar "superGoalClosureGo") (EVar "gctx")) (EListLit (ETuple (EVar "iface") (EVar "args")))) (EListLit (EVar "iface"))) (EListLit)))
(DTypeSig false "superGoalClosureGo" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")))) (TyFun (TyApp (TyCon "List") (TyCon "IfaceRef")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")))) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")))))))))
(DFunDef false "superGoalClosureGo" ((PVar "gctx") (PList) PWild (PVar "acc")) (EApp (EVar "reverse") (EVar "acc")))
(DFunDef false "superGoalClosureGo" ((PVar "gctx") (PCons (PTuple (PVar "iface") (PVar "args")) (PVar "rest")) (PVar "seen") (PVar "acc")) (EBlock (DoLet false false (PVar "step") (ELam ((PVar "st") (PVar "sg")) (EMatch (EVar "sg") (arm (PTuple (PVar "sup") (PCon "Some" (PVar "supArgs"))) ((GBool (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EApp (EVar "sameIfaceDecl") (EVar "sup"))) (EApp (EVar "fst") (EVar "st")))))) (ETuple (EBinOp "::" (EVar "sup") (EApp (EVar "fst") (EVar "st"))) (EBinOp "::" (ETuple (EVar "sup") (EVar "supArgs")) (EApp (EVar "snd") (EVar "st"))))) (arm PWild () (EVar "st"))))) (DoLet false false (PTuple (PVar "seen2") (PVar "found")) (EApp (EApp (EApp (EMethodRef "fold") (EVar "step")) (ETuple (EVar "seen") (EListLit))) (EApp (EApp (EApp (EVar "directSuperGoals") (EVar "gctx")) (EVar "iface")) (EVar "args")))) (DoLet false false (PVar "fresh") (EApp (EVar "reverse") (EVar "found"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "superGoalClosureGo") (EVar "gctx")) (EBinOp "++" (EVar "rest") (EVar "fresh"))) (EVar "seen2")) (EBinOp "++" (EVar "found") (EVar "acc"))))))
(DTypeSig true "reqToObligation" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Require") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")))))))
(DFunDef false "reqToObligation" ((PVar "mctx") (PVar "subst") (PRec "Require" ((rf "requireHead" (PVar "ifaceR")) (rf "requireArgs" (PVar "tysR")) (rf "requireOrigin" (PVar "o"))) false)) (ETuple (ERecordCreate "IfaceRef" ((fa "irName" (EVar "ifaceR")) (fa "irOrigin" (EVar "o")))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "reqTyToMono") (EVar "mctx")) (EVar "subst"))) (EVar "tysR"))))
(DTypeSig true "occurrenceDispatchMonos" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "Mono")))))))
(DFunDef false "occurrenceDispatchMonos" ((PVar "typarams") (PVar "mty") (PVar "occ") (PVar "omitted")) (EApp (EApp (EVar "collectByParam") (EVar "typarams")) (EBinOp "++" (EApp (EApp (EApp (EVar "walkDispatch") (EVar "typarams")) (EApp (EVar "stripTyConstraints") (EVar "mty"))) (EVar "occ")) (EVar "omitted"))))
(DTypeSig true "walkDispatch" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))))))
(DFunDef false "walkDispatch" ((PVar "typarams") (PCon "TyVar" (PVar "n")) (PVar "m")) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "typarams")) (EListLit (ETuple (EVar "n") (EApp (EVar "normalize") (EVar "m")))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "walkDispatch" ((PVar "typarams") (PCon "TyFun" (PVar "a") (PVar "b")) (PVar "m")) (EMatch (EApp (EVar "peelQual") (EVar "m")) (arm (PCon "TFun" (PVar "ma") PWild (PVar "mb")) () (EBinOp "++" (EApp (EApp (EApp (EVar "walkDispatch") (EVar "typarams")) (EApp (EVar "stripTyConstraints") (EVar "a"))) (EVar "ma")) (EApp (EApp (EApp (EVar "walkDispatch") (EVar "typarams")) (EApp (EVar "stripTyConstraints") (EVar "b"))) (EVar "mb")))) (arm PWild () (EListLit))))
(DFunDef false "walkDispatch" ((PVar "typarams") (PCon "TyApp" (PVar "a") (PVar "b")) (PVar "m")) (EMatch (EApp (EVar "peelQual") (EVar "m")) (arm (PCon "TApp" (PVar "ma") (PVar "mb")) () (EBinOp "++" (EApp (EApp (EApp (EVar "walkDispatch") (EVar "typarams")) (EVar "a")) (EVar "ma")) (EApp (EApp (EApp (EVar "walkDispatch") (EVar "typarams")) (EVar "b")) (EVar "mb")))) (arm PWild () (EListLit))))
(DFunDef false "walkDispatch" ((PVar "typarams") (PCon "TyTuple" (PVar "ts")) (PVar "m")) (EMatch (EApp (EVar "tupleSpine") (EVar "m")) (arm (PCon "Some" (PVar "ms")) () (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "p")) (EApp (EApp (EApp (EVar "walkDispatch") (EVar "typarams")) (EApp (EVar "fst") (EVar "p"))) (EApp (EVar "snd") (EVar "p"))))) (EApp (EApp (EVar "zip") (EVar "ts")) (EVar "ms")))) (arm PWild () (EListLit))))
(DFunDef false "walkDispatch" (PWild PWild PWild) (EListLit))
(DTypeSig true "collectByParam" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "collectByParam" ((PVar "typarams") (PVar "pairs")) (EMatch (EApp (EApp (EVar "collectByParamGo") (EVar "typarams")) (EVar "pairs")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "ms")) () (EVar "ms"))))
(DTypeSig false "collectByParamGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Mono"))))))
(DFunDef false "collectByParamGo" ((PList) PWild) (EApp (EVar "Some") (EListLit)))
(DFunDef false "collectByParamGo" ((PCons (PVar "p") (PVar "rest")) (PVar "pairs")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "p")) (EVar "pairs")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "m")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "m") (EVar "_s")))) (EApp (EApp (EVar "collectByParamGo") (EVar "rest")) (EVar "pairs"))))))
(DTypeSig true "answeredOnlyByBindingHead" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))))
(DFunDef false "answeredOnlyByBindingHead" ((PVar "mctx") (PVar "headIds") (PVar "iface") (PVar "args")) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EVar "filterList") (EApp (EVar "ieRowOfIface") (EVar "iface"))) (EApp (EApp (EVar "improvementPool") (EVar "mctx")) (EVar "args")))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "anyList") (EApp (EApp (EVar "rowHeadUnifies") (EVar "mctx")) (EVar "args"))) (EVar "rows")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "row")) (EApp (EVar "isSome") (EApp (EApp (EApp (EApp (EVar "rowHeadSubstRigid") (EVar "mctx")) (EVar "headIds")) (EVar "args")) (EVar "row"))))) (EVar "rows")))))))
(DTypeSig true "residualSelectionStable" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")))) (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool")))))))
(DFunDef false "residualSelectionStable" ((PVar "mctx") (PVar "chosen") (PVar "context") (PVar "iface") (PVar "args")) (EIf (EApp (EVar "not") (EApp (EApp (EDictApp "any") (ELam ((PVar "i")) (EApp (EApp (EDictApp "elem") (EVar "i")) (EVar "chosen")))) (EApp (EApp (EDictApp "flatMap") (EVar "monoUnboundIds")) (EVar "args")))) (EVar "True") (EIf (EVar "otherwise") (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "goalSelectionStable") (EVar "mctx")) (EVar "chosen")) (EVar "iface")) (EVar "args")) (EApp (EApp (EVar "allList") (ELam ((PVar "sg")) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "goalAnsweredBy") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "context")) (EApp (EVar "fst") (EVar "sg"))) (EApp (EVar "snd") (EVar "sg"))) (EApp (EApp (EApp (EApp (EVar "goalSelectionStable") (EVar "mctx")) (EVar "chosen")) (EApp (EVar "fst") (EVar "sg"))) (EApp (EVar "snd") (EVar "sg")))))) (EApp (EApp (EApp (EVar "superGoalClosure") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "iface")) (EVar "args")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "goalSelectionStable" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))))
(DFunDef false "goalSelectionStable" ((PVar "mctx") (PVar "chosen") (PVar "iface") (PVar "args")) (EIf (EApp (EVar "not") (EApp (EApp (EDictApp "any") (ELam ((PVar "i")) (EApp (EApp (EDictApp "elem") (EVar "i")) (EVar "chosen")))) (EApp (EApp (EDictApp "flatMap") (EVar "monoUnboundIds")) (EVar "args")))) (EVar "True") (EMatch (EApp (EApp (EApp (EApp (EVar "stableGoalReach") (EVar "mctx")) (EVar "chosen")) (EVar "iface")) (EVar "args")) (arm (PCon "ReachMany") () (EVar "False")) (arm (PCon "ReachOne" PWild) () (EVar "True")) (arm (PCon "ReachNone") () (EVar "True")))))
(DTypeSig true "goalDefersOpenWorld" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ScopeId") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))))
(DFunDef false "goalDefersOpenWorld" ((PVar "mctx") (PVar "scope") (PVar "iface") (PVar "args")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "monoVectorClosed") (EVar "args"))) (EApp (EApp (EVar "allList") (EVar "monoHeadIsDecl")) (EVar "args"))) (EApp (EVar "isNonEmptyL") (EApp (EApp (EDictApp "flatMap") (EVar "monoUnboundIds")) (EVar "args")))) (EApp (EApp (EVar "allList") (ELam ((PVar "i")) (EApp (EApp (EVar "IdMap.has") (EVar "i")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "deferrableVarIds") "value")))) (EApp (EApp (EDictApp "flatMap") (EVar "monoUnboundIds")) (EVar "args")))) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "goalMatchesGiven") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "scope")) (EVar "iface")) (EVar "args")) (EApp (EApp (EVar "goalSlotStillOpen") (EVar "mctx")) (EVar "args")))))
(DTypeSig false "goalSlotStillOpen" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))
(DFunDef false "goalSlotStillOpen" ((PVar "mctx") (PList)) (EVar "False"))
(DFunDef false "goalSlotStillOpen" ((PVar "mctx") (PVar "args")) (EApp (EVar "not") (EApp (EApp (EVar "goalIdsClaimed") (EVar "mctx")) (EApp (EApp (EDictApp "flatMap") (EVar "monoUnboundIds")) (EVar "args")))))
(DTypeSig false "goalIdsClaimed" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool"))))
(DFunDef false "goalIdsClaimed" ((PVar "mctx") (PList)) (EVar "False"))
(DFunDef false "goalIdsClaimed" ((PVar "mctx") (PVar "ids")) (EApp (EApp (EVar "anyClaimRow") (EVar "ids")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funPredicateSlotsRef") "value")))
(DTypeSig false "anyClaimRow" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "PredicateSlot")))) (TyCon "Bool"))))
(DFunDef false "anyClaimRow" (PWild (PList)) (EVar "False"))
(DFunDef false "anyClaimRow" ((PVar "ids") (PCons (PTuple PWild (PVar "slots")) (PVar "rest"))) (EBinOp "||" (EApp (EApp (EVar "anyList") (ELam ((PVar "v")) (EApp (EApp (EVar "anyList") (ELam ((PVar "m")) (EApp (EApp (EDictApp "any") (ELam ((PVar "i")) (EApp (EApp (EDictApp "elem") (EVar "i")) (EVar "ids")))) (EApp (EVar "monoTyvarIds") (EVar "m"))))) (EVar "v")))) (EApp (EVar "predicateSlotArgs") (EVar "slots"))) (EApp (EApp (EVar "anyClaimRow") (EVar "ids")) (EVar "rest"))))
(DTypeSig true "goalMonos" (TyFun (TyCon "Obligation") (TyApp (TyCon "List") (TyCon "Mono"))))
(DFunDef false "goalMonos" ((PVar "o")) (EMatch (EFieldAccess (EVar "o") "oPayload") (arm (PCon "GPSite" PWild (PVar "m") (PVar "site")) () (EBinOp "::" (EVar "m") (EApp (EVar "siteKindMonos") (EVar "site")))) (arm (PCon "GPArith" (PVar "m")) () (EListLit (EVar "m"))) (arm (PCon "GPDictApp" (PVar "app")) () (EBinOp "++" (EFieldAccess (EVar "app") "pdaMonos") (EApp (EApp (EDictApp "flatMap") (EVar "identity")) (EFieldAccess (EVar "app") "pdaArgVecs")))) (arm (PCon "GPMethodDict" PWild) () (EListLit)) (arm (PCon "GPRecDictApp" (PCon "RecDictApp" PWild PWild PWild (PVar "m") PWild PWild)) () (EListLit (EVar "m")))))
(DTypeSig false "siteKindMonos" (TyFun (TyCon "SiteKind") (TyApp (TyCon "List") (TyCon "Mono"))))
(DFunDef false "siteKindMonos" ((PCon "SKReturn" PWild (PVar "m"))) (EListLit (EVar "m")))
(DFunDef false "siteKindMonos" ((PCon "SKAdmittedReturn" PWild PWild (PVar "m"))) (EListLit (EVar "m")))
(DFunDef false "siteKindMonos" ((PCon "SKExactReturn" PWild (PVar "request"))) (EListLit (EFieldAccess (EVar "request") "mrrOccurrence")))
(DFunDef false "siteKindMonos" ((PCon "SKNumReturn" PWild (PVar "m"))) (EListLit (EVar "m")))
(DFunDef false "siteKindMonos" ((PCon "SKArg" PWild (PVar "m") (PVar "omitted"))) (EBinOp "::" (EVar "m") (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "omitted"))))
(DFunDef false "siteKindMonos" ((PCon "SKOp" PWild)) (EListLit))
(DFunDef false "siteKindMonos" ((PCon "SKPredicateOp" PWild PWild)) (EListLit))
(DFunDef false "siteKindMonos" ((PCon "SKRLocal" PWild PWild (PVar "ms") PWild (PVar "vecs"))) (EBinOp "++" (EVar "ms") (EApp (EApp (EDictApp "flatMap") (EVar "identity")) (EVar "vecs"))))
(DTypeSig true "finishMethodReturnTrace" (TyFun (TyCon "TraceSink") (TyFun (TyCon "EvTable") (TyApp (TyCon "List") (TyCon "MethodReturnTraceEntry")))))
(DFunDef false "finishMethodReturnTrace" ((PVar "sink") (PVar "evidence")) (EApp (EApp (EMethodRef "map") (EApp (EVar "publishMethodReturnTrace") (EVar "evidence"))) (EApp (EVar "reverse") (EFieldAccess (EFieldAccess (EVar "sink") "tsMethodReturnEntries") "value"))))
(DTypeSig false "publishMethodReturnTrace" (TyFun (TyCon "EvTable") (TyFun (TyCon "MethodReturnTraceEntry") (TyCon "MethodReturnTraceEntry"))))
(DFunDef false "publishMethodReturnTrace" ((PVar "evidence") (PVar "entry")) (EBlock (DoLet false false (PVar "published") (EMatch (EFieldAccess (EVar "entry") "mrtGoal") (arm (PCon "Some" (PVar "goal")) () (EApp (EApp (EVar "lookupTraceEvidence") (EVar "goal")) (EVar "evidence"))) (arm (PCon "None") () (EVar "None")))) (DoExpr (ERecordCreate "MethodReturnTraceEntry" ((fa "mrtStage" (EFieldAccess (EVar "entry") "mrtStage")) (fa "mrtInterface" (EFieldAccess (EVar "entry") "mrtInterface")) (fa "mrtMethod" (EFieldAccess (EVar "entry") "mrtMethod")) (fa "mrtArguments" (EFieldAccess (EVar "entry") "mrtArguments")) (fa "mrtScope" (EFieldAccess (EVar "entry") "mrtScope")) (fa "mrtOrigin" (EFieldAccess (EVar "entry") "mrtOrigin")) (fa "mrtGoal" (EFieldAccess (EVar "entry") "mrtGoal")) (fa "mrtPublished" (EVar "published")) (fa "mrtQualifiedBody" (EFieldAccess (EVar "entry") "mrtQualifiedBody")) (fa "mrtWanted" (EFieldAccess (EVar "entry") "mrtWanted")) (fa "mrtOutcome" (EFieldAccess (EVar "entry") "mrtOutcome")) (fa "mrtRoute" (EFieldAccess (EVar "entry") "mrtRoute")) (fa "mrtPrerequisites" (EFieldAccess (EVar "entry") "mrtPrerequisites")))))))
(DTypeSig false "lookupTraceEvidence" (TyFun (TyCon "EvId") (TyFun (TyCon "EvTable") (TyApp (TyCon "Option") (TyCon "EvVal")))))
(DFunDef false "lookupTraceEvidence" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupTraceEvidence" ((PVar "goal") (PCons (PCon "EvEntry" (PVar "candidate") (PVar "value")) (PVar "rest"))) (EIf (EApp (EApp (EVar "sameTraceEvId") (EVar "goal")) (EVar "candidate")) (EApp (EVar "Some") (EVar "value")) (EApp (EApp (EVar "lookupTraceEvidence") (EVar "goal")) (EVar "rest"))))
(DTypeSig false "sealMethodReturnGoals" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvTable") (TyFun (TyApp (TyCon "List") (TyCon "Obligation")) (TyTuple (TyApp (TyCon "List") (TyCon "Obligation")) (TyApp (TyCon "List") (TyCon "MethodReturnMemoView")))))))
(DFunDef false "sealMethodReturnGoals" ((PVar "gctx") (PVar "evidence") (PVar "goals")) (EApp (EApp (EApp (EApp (EVar "sealMethodReturnGoalsFrom") (EVar "gctx")) (EVar "evidence")) (EApp (EVar "reverse") (EVar "goals"))) (ETuple (EListLit) (EListLit))))
(DTypeSig false "sealMethodReturnGoalsFrom" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvTable") (TyFun (TyApp (TyCon "List") (TyCon "Obligation")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Obligation")) (TyApp (TyCon "List") (TyCon "MethodReturnMemoView"))) (TyTuple (TyApp (TyCon "List") (TyCon "Obligation")) (TyApp (TyCon "List") (TyCon "MethodReturnMemoView"))))))))
(DFunDef false "sealMethodReturnGoalsFrom" ((PVar "gctx") PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "sealMethodReturnGoalsFrom" ((PVar "gctx") (PVar "evidence") (PCons (PVar "goal") (PVar "rest")) (PTuple (PVar "goals") (PVar "views"))) (EMatch (EApp (EVar "exactReturnRequestOfGoal") (EVar "goal")) (arm (PCon "Some" (PVar "request")) () (EApp (EApp (EApp (EApp (EVar "sealMethodReturnGoalsFrom") (EVar "gctx")) (EVar "evidence")) (EVar "rest")) (ETuple (EVar "goals") (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "methodReturnMemoView") (EVar "gctx")) (EVar "evidence")) (EVar "goal")) (EVar "request")) (EVar "views"))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "sealMethodReturnGoalsFrom") (EVar "gctx")) (EVar "evidence")) (EVar "rest")) (ETuple (EBinOp "::" (EVar "goal") (EVar "goals")) (EVar "views"))))))
(DTypeSig false "methodReturnMemoView" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvTable") (TyFun (TyCon "Obligation") (TyFun (TyCon "MethodReturnRequest") (TyCon "MethodReturnMemoView"))))))
(DFunDef false "methodReturnMemoView" ((PVar "gctx") (PVar "evidence") (PVar "goal") (PVar "request")) (EBlock (DoLet false false (PTuple (PVar "outcome") (PVar "prerequisites")) (EMatch (EFieldAccess (EFieldAccess (EVar "request") "mrrResolution") "value") (arm (PCon "None") () (ETuple (ELit (LString "legacy")) (EListLit))) (arm (PCon "Some" (PVar "resolution")) () (ETuple (EApp (EVar "methodReturnMemoOutcome") (EFieldAccess (EVar "resolution") "mrrOutcome")) (EApp (EVar "methodReturnMemoPrerequisites") (EFieldAccess (EVar "resolution") "mrrOutcome")))))) (DoExpr (ERecordCreate "MethodReturnMemoView" ((fa "mrmvInterface" (EApp (EVar "methodReturnMemoIface") (EFieldAccess (EVar "request") "mrrIface"))) (fa "mrmvMethod" (EFieldAccess (EVar "request") "mrrName")) (fa "mrmvArguments" (EApp (EApp (EMethodRef "map") (EVar "methodReturnMemoArguments")) (EApp (EApp (EVar "methodReturnArgs") (EVar "gctx")) (EVar "request")))) (fa "mrmvOutcome" (EVar "outcome")) (fa "mrmvPrerequisites" (EVar "prerequisites")) (fa "mrmvEvidence" (EApp (EApp (EVar "methodReturnMemoEvidence") (EFieldAccess (EVar "goal") "oEv")) (EVar "evidence"))))))))
(DTypeSig false "methodReturnMemoArguments" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "methodReturnMemoArguments" ((PVar "arguments")) (EApp (EApp (EMethodRef "map") (EVar "ppMono")) (EVar "arguments")))
(DTypeSig false "methodReturnMemoIface" (TyFun (TyCon "IfaceRef") (TyCon "String")))
(DFunDef false "methodReturnMemoIface" ((PVar "iface")) (EBlock (DoLet false false (PVar "identity") (EApp (EApp (EVar "ifaceIdentity") (EFieldAccess (EVar "iface") "irOrigin")) (EFieldAccess (EVar "iface") "irName"))) (DoExpr (EIf (EBinOp "==" (EVar "identity") (ELit (LString ""))) (EFieldAccess (EVar "iface") "irName") (EVar "identity")))))
(DTypeSig false "methodReturnMemoOutcome" (TyFun (TyCon "SolverOutcome") (TyCon "String")))
(DFunDef false "methodReturnMemoOutcome" ((PCon "Solved" (PCon "GivenEvidence" PWild))) (ELit (LString "given")))
(DFunDef false "methodReturnMemoOutcome" ((PCon "Solved" (PCon "InstanceEvidence" PWild PWild PWild PWild))) (ELit (LString "instance")))
(DFunDef false "methodReturnMemoOutcome" ((PCon "Solved" (PCon "SuperclassEvidence" PWild PWild))) (ELit (LString "superclass")))
(DFunDef false "methodReturnMemoOutcome" ((PCon "Deferred" PWild PWild)) (ELit (LString "deferred")))
(DFunDef false "methodReturnMemoOutcome" ((PCon "Insoluble" PWild (PCon "MissingInstance"))) (ELit (LString "missing")))
(DFunDef false "methodReturnMemoOutcome" ((PCon "Insoluble" PWild (PCon "AmbiguousInstances" PWild))) (ELit (LString "ambiguous")))
(DFunDef false "methodReturnMemoOutcome" ((PCon "Insoluble" PWild (PCon "ResolutionCycle" PWild))) (ELit (LString "cycle")))
(DTypeSig false "methodReturnMemoPrerequisites" (TyFun (TyCon "SolverOutcome") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "methodReturnMemoPrerequisites" ((PCon "Solved" (PCon "InstanceEvidence" PWild PWild (PVar "prerequisites") PWild))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "prerequisite")) (ETuple (EApp (EVar "methodReturnMemoIface") (EFieldAccess (EVar "prerequisite") "prerequisiteInterface")) (EApp (EApp (EMethodRef "map") (EVar "ppMono")) (EFieldAccess (EVar "prerequisite") "prerequisiteArguments"))))) (EVar "prerequisites")))
(DFunDef false "methodReturnMemoPrerequisites" (PWild) (EListLit))
(DTypeSig false "methodReturnMemoEvidence" (TyFun (TyCon "EvId") (TyFun (TyCon "EvTable") (TyCon "String"))))
(DFunDef false "methodReturnMemoEvidence" ((PVar "goal") (PVar "evidence")) (EMatch (EApp (EApp (EVar "lookupTraceEvidence") (EVar "goal")) (EVar "evidence")) (arm (PCon "Some" (PCon "EvOne" (PVar "route"))) () (EApp (EVar "methodReturnMemoRoute") (EVar "route"))) (arm (PCon "Some" (PCon "EvMany" (PVar "routes"))) () (EApp (EApp (EVar "join") (ELit (LString ","))) (EApp (EApp (EMethodRef "map") (EVar "methodReturnMemoRoute")) (EVar "routes")))) (arm (PCon "Some" (PCon "EvLit" PWild (PVar "route"))) () (EApp (EVar "methodReturnMemoRoute") (EVar "route"))) (arm (PCon "Some" (PCon "EvHead" (PVar "head"))) () (EBinOp "++" (EBinOp "++" (ELit (LString "head:")) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString "")))) (arm (PCon "None") () (ELit (LString "unpublished")))))
(DTypeSig false "methodReturnMemoRoute" (TyFun (TyCon "Route") (TyCon "String")))
(DFunDef false "methodReturnMemoRoute" ((PCon "RNone")) (ELit (LString "none")))
(DFunDef false "methodReturnMemoRoute" ((PCon "RKey" (PVar "key") (PVar "prerequisites") (PVar "supers"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "key:")) (EApp (EMethodRef "display") (EVar "key"))) (ELit (LString "["))) (EApp (EMethodRef "display") (EApp (EApp (EVar "join") (ELit (LString ","))) (EApp (EApp (EMethodRef "map") (EVar "methodReturnMemoRoute")) (EVar "prerequisites"))))) (ELit (LString "]"))) (EApp (EMethodRef "display") (EApp (EVar "methodReturnMemoSupers") (EVar "supers")))) (ELit (LString ""))))
(DFunDef false "methodReturnMemoRoute" ((PCon "RDict" (PVar "name"))) (EBinOp "++" (EBinOp "++" (ELit (LString "given:")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "methodReturnMemoRoute" ((PCon "RDictFwd" (PVar "name"))) (EBinOp "++" (EBinOp "++" (ELit (LString "forwarded:")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "methodReturnMemoRoute" ((PCon "RLocal" (PVar "name") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "local:")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "methodReturnMemoRoute" ((PCon "RScalar" (PVar "name"))) (EBinOp "++" (EBinOp "++" (ELit (LString "scalar:")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "methodReturnMemoRoute" ((PCon "RProj" (PVar "r") (PVar "path"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "projected:")) (EApp (EMethodRef "display") (EApp (EVar "methodReturnMemoRoute") (EVar "r")))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EApp (EVar "join") (ELit (LString "."))) (EApp (EApp (EMethodRef "map") (EVar "intToString")) (EVar "path"))))) (ELit (LString ""))))
(DTypeSig false "methodReturnMemoSupers" (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyCon "String")))
(DFunDef false "methodReturnMemoSupers" ((PList)) (ELit (LString "")))
(DFunDef false "methodReturnMemoSupers" ((PVar "supers")) (EBinOp "++" (EBinOp "++" (ELit (LString "{")) (EApp (EMethodRef "display") (EApp (EApp (EVar "join") (ELit (LString ","))) (EApp (EApp (EMethodRef "map") (EVar "methodReturnMemoRoute")) (EVar "supers"))))) (ELit (LString "}"))))
(DTypeSig false "isSemanticGivenAnswer" (TyFun (TyApp (TyCon "Option") (TyCon "AssumAnswer")) (TyCon "Bool")))
(DFunDef false "isSemanticGivenAnswer" ((PCon "Some" (PCon "SemanticGiven" (PCon "GivenEvidence" PWild)))) (EVar "True"))
(DFunDef false "isSemanticGivenAnswer" (PWild) (EVar "False"))
(DTypeSig false "isLegacyPredicateAnswer" (TyFun (TyApp (TyCon "Option") (TyCon "AssumAnswer")) (TyCon "Bool")))
(DFunDef false "isLegacyPredicateAnswer" ((PCon "Some" (PCon "LegacyPredicate" PWild))) (EVar "True"))
(DFunDef false "isLegacyPredicateAnswer" (PWild) (EVar "False"))
(DTypeSig false "scopeGivenProbe" (TyFun (TyCon "Unit") (TyApp (TyCon "List") (TyCon "Bool"))))
(DFunDef false "scopeGivenProbe" (PWild) (EBlock (DoLet false false (PVar "gctx") (EApp (EVar "probeGraphCtx") (ELit LUnit))) (DoLet false false (PVar "store") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))) (DoLet false false (PVar "root") (EApp (EApp (EApp (EApp (EApp (EVar "Scopes.freshScope") (EVar "store")) (EVar "None")) (ELit (LInt 0))) (ELit (LString "given-probe"))) (EVar "ModuleOwner"))) (DoLet false false (PVar "owner") (EApp (EApp (EApp (EApp (EApp (EVar "Scopes.freshScope") (EVar "store")) (EApp (EVar "Some") (EVar "root"))) (ELit (LInt 1))) (ELit (LString "given-probe"))) (EApp (EVar "BindingOwner") (ELit (LString "owner"))))) (DoLet false false (PVar "sibling") (EApp (EApp (EApp (EApp (EApp (EVar "Scopes.freshScope") (EVar "store")) (EApp (EVar "Some") (EVar "root"))) (ELit (LInt 1))) (ELit (LString "given-probe"))) (EApp (EVar "BindingOwner") (ELit (LString "sibling"))))) (DoLet false false (PVar "iface") (ERecordCreate "IfaceRef" ((fa "irName" (ELit (LString "PairGiven"))) (fa "irOrigin" (EApp (EVar "OriginModule") (ELit (LString "given-probe"))))))) (DoLet false false (PVar "args") (EListLit (EApp (EVar "tconBuiltin") (ELit (LString "Int"))) (EApp (EVar "tconBuiltin") (ELit (LString "Bool"))))) (DoLet false false (PVar "slot") (ERecordCreate "PredicateSlot" ((fa "psIface" (EVar "iface")) (fa "psArgs" (EApp (EVar "PSArgsKnown") (EVar "args"))) (fa "psBoundIds" (EListLit (ELit (LInt 41))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "pushGiven") (EVar "gctx")) (EVar "GMPredicate")) (EVar "DirectGiven")) (EVar "slot")) (EApp (EApp (EVar "Scopes.binderAt") (EVar "owner")) (ELit (LInt 0))))) (DoLet false false (PVar "exact") (ERecordCreate "PredicateRequest" ((fa "prIface" (EVar "iface")) (fa "prArgs" (EApp (EVar "PSArgsKnown") (EVar "args")))))) (DoLet false false (PVar "unknown") (ERecordCreate "PredicateRequest" ((fa "prIface" (EVar "iface")) (fa "prArgs" (EVar "PSArgsUnknown"))))) (DoLet false false (PVar "truncated") (ERecordCreate "PredicateRequest" ((fa "prIface" (EVar "iface")) (fa "prArgs" (EApp (EVar "PSArgsKnown") (EListLit (EApp (EVar "tconBuiltin") (ELit (LString "Int"))))))))) (DoLet false false (PVar "witnessIface") (ERecordCreate "IfaceRef" ((fa "irName" (ELit (LString "WitnessGiven"))) (fa "irOrigin" (EApp (EVar "OriginModule") (ELit (LString "given-probe"))))))) (DoLet false false (PVar "witnessSlot") (ERecordCreate "PredicateSlot" ((fa "psIface" (EVar "witnessIface")) (fa "psArgs" (EApp (EVar "PSArgsKnown") (EListLit (EApp (EVar "tconBuiltin") (ELit (LString "Int")))))) (fa "psBoundIds" (EListLit (ELit (LInt 73))))))) (DoLet false false (PVar "witnessRequest") (ERecordCreate "PredicateRequest" ((fa "prIface" (EVar "witnessIface")) (fa "prArgs" (EApp (EVar "PSArgsKnown") (EListLit (EApp (EVar "tconBuiltin") (ELit (LString "Int"))))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "pushGiven") (EVar "gctx")) (EVar "GMIdWitnessed")) (EVar "DirectGiven")) (EVar "witnessSlot")) (EApp (EApp (EVar "Scopes.binderAt") (EVar "owner")) (ELit (LInt 1))))) (DoLet false false (PVar "compatibleIface") (ERecordCreate "IfaceRef" ((fa "irName" (ELit (LString "CompatibleGiven"))) (fa "irOrigin" (EApp (EVar "OriginModule") (ELit (LString "given-probe"))))))) (DoLet false false (PVar "compatibleSlot") (ERecordCreate "PredicateSlot" ((fa "psIface" (EVar "compatibleIface")) (fa "psArgs" (EVar "PSArgsUnknown")) (fa "psBoundIds" (EListLit (ELit (LInt 89))))))) (DoLet false false (PVar "compatibleRequest") (ERecordCreate "PredicateRequest" ((fa "prIface" (EVar "compatibleIface")) (fa "prArgs" (EApp (EVar "PSArgsKnown") (EListLit (EApp (EVar "tconBuiltin") (ELit (LString "Int"))))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "pushGiven") (EVar "gctx")) (EVar "GMPredicate")) (EVar "DirectGiven")) (EVar "compatibleSlot")) (EApp (EApp (EVar "Scopes.binderAt") (EVar "owner")) (ELit (LInt 2))))) (DoLet false false (PVar "givens") (EApp (EApp (EVar "givensForScope") (EVar "gctx")) (EVar "owner"))) (DoLet false false (PVar "result") (EListLit (EApp (EApp (EApp (EApp (EVar "anyGivenMatches") (EVar "gctx")) (EVar "exact")) (EVar "owner")) (EVar "givens")) (EApp (EVar "not") (EApp (EApp (EApp (EApp (EVar "anyGivenMatches") (EVar "gctx")) (EVar "exact")) (EVar "sibling")) (EVar "givens"))) (EApp (EVar "not") (EApp (EApp (EApp (EApp (EVar "anyGivenMatches") (EVar "gctx")) (EVar "truncated")) (EVar "owner")) (EVar "givens"))) (EApp (EVar "not") (EApp (EApp (EApp (EApp (EVar "anyGivenMatches") (EVar "gctx")) (EVar "witnessRequest")) (EVar "owner")) (EVar "givens"))) (EApp (EVar "isSome") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "firstPredForEnclAt") (EVar "gctx")) (EVar "GSImplRequires")) (ELit (LInt 73))) (EVar "witnessRequest")) (EVar "owner")) (EVar "givens"))) (EApp (EVar "isNone") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "firstPredForEnclAt") (EVar "gctx")) (EVar "GSImplRequires")) (ELit (LInt 74))) (EVar "witnessRequest")) (EVar "owner")) (EVar "givens"))) (EApp (EVar "isSemanticGivenAnswer") (EApp (EApp (EApp (EApp (EVar "firstPredForEncl") (EVar "gctx")) (EVar "exact")) (EVar "owner")) (EVar "givens"))) (EApp (EVar "isLegacyPredicateAnswer") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "firstPredForEnclAt") (EVar "gctx")) (EVar "GSPredicateOnly")) (ELit (LInt 41))) (EVar "unknown")) (EVar "owner")) (EVar "givens"))) (EApp (EVar "isLegacyPredicateAnswer") (EApp (EApp (EApp (EApp (EApp (EVar "firstPredForEnclResidual") (EVar "gctx")) (ELit (LString "PairGiven"))) (EVar "args")) (EVar "owner")) (EVar "givens"))) (EApp (EVar "isLegacyPredicateAnswer") (EApp (EApp (EApp (EApp (EVar "firstPredForEncl") (EVar "gctx")) (EVar "compatibleRequest")) (EVar "owner")) (EVar "givens"))))) (DoExpr (EVar "result"))))
(DTypeSig true "methodSlotBoundIds" (TyFun (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "methodSlotBoundIds" ((PVar "slots")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "slot")) (EFieldAccess (EFieldAccess (EVar "slot") "mpsPredicate") "psBoundIds"))) (EVar "slots")))
(DTypeSig true "methodSlotPositions" (TyFun (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "methodSlotPositions" ((PVar "slots")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "slot")) (EFieldAccess (EVar "slot") "mpsPositions"))) (EVar "slots")))
(DTypeSig true "methodSlotIdsAtPositions" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "methodSlotIdsAtPositions" ((PVar "ids") (PVar "slots")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "slot")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "pos")) (EApp (EApp (EVar "optionOr") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EApp (EApp (EVar "get") (EVar "pos")) (EVar "ids"))))) (EFieldAccess (EVar "slot") "mpsPositions")))) (EVar "slots")))
(DTypeSig true "methodSlotArgumentIds" (TyFun (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "methodSlotArgumentIds" ((PVar "slots")) (EApp (EApp (EMethodRef "map") (EVar "methodSlotArgumentIdsOne")) (EVar "slots")))
(DTypeSig false "methodSlotArgumentIdsOne" (TyFun (TyCon "MethodPredicateSlot") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "methodSlotArgumentIdsOne" ((PVar "slot")) (EMatch (EFieldAccess (EFieldAccess (EVar "slot") "mpsPredicate") "psArgs") (arm (PCon "PSArgsUnknown") () (EListLit)) (arm (PCon "PSArgsKnown" (PVar "args")) () (EApp (EApp (EDictApp "flatMap") (EVar "monoTyvarIds")) (EVar "args")))))
(DTypeSig true "methodRowRegistrySlotIds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "methodRowRegistrySlotIds" ((PVar "mctx") (PVar "key")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodPredicateSlotsRef") "value")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "slots")) () (EApp (EVar "methodSlotBoundIds") (EVar "slots")))))
(DTypeSig true "numAnchorObservationView" (TyFun (TyCon "NumAnchorTestObservation") (TyTuple (TyCon "String") (TyCon "Bool") (TyCon "Bool") (TyCon "String") (TyCon "String"))))
(DFunDef false "numAnchorObservationView" ((PVar "observation")) (ETuple (EFieldAccess (EVar "observation") "natoCase") (EFieldAccess (EVar "observation") "natoHasRow") (EBinOp "==" (EFieldAccess (EVar "observation") "natoIface") (ELit (LString "Num"))) (EFieldAccess (EVar "observation") "natoSchemeBody") (EFieldAccess (EVar "observation") "natoDeclaredType")))
(DTypeSig true "methodReturnProbeIface" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyCon "Decl")))))
(DFunDef false "methodReturnProbeIface" ((PVar "moduleId") (PVar "ifaceName") (PVar "methodTy")) (EApp (EApp (EApp (EApp (EVar "methodRowTestIface") (EVar "moduleId")) (EVar "ifaceName")) (EListLit (ELit (LString "a")))) (EListLit (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (ELit (LString "make"))) (EVar "methodTy")) (EVar "None")) (EVar "None")))))
(DTypeSig true "methodReturnProbeImpl" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Decl"))))
(DFunDef false "methodReturnProbeImpl" ((PVar "moduleId") (PVar "ifaceName")) (ERecordCreate "DImpl" ((fa "pub" (EVar "False")) (fa "iface" (EVar "ifaceName")) (fa "tys" (EListLit (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None")))) (fa "reqs" (EListLit)) (fa "methods" (EListLit (EApp (EApp (EApp (EVar "ImplMethod") (ELit (LString "make"))) (EListLit)) (EApp (EVar "ELit") (EVar "LUnit"))))) (fa "implOrigin" (EApp (EVar "OriginModule") (EVar "moduleId"))) (fa "implIfaceLoc" (EVar "None")))))
(DTypeSig true "methodReturnProbeScope" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "ScopeId"))))
(DFunDef false "methodReturnProbeScope" ((PVar "mctx") (PVar "moduleId")) (EBlock (DoLet false false (PVar "scope") (EApp (EApp (EApp (EApp (EApp (EVar "Scopes.freshScope") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EVar "None")) (ELit (LInt 0))) (EVar "moduleId")) (EVar "ModuleOwner"))) (DoExpr (EApp (EApp (EVar "openScope") (EVar "mctx")) (EVar "scope"))) (DoExpr (EVar "scope"))))
(DTypeSig true "methodReturnProbeOccurrence" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodSchemeRow") (TyCon "MethodTrackedInstantiation"))))
(DFunDef false "methodReturnProbeOccurrence" ((PVar "mctx") (PVar "row")) (EBlock (DoLet false false (PVar "inst") (EApp (EApp (EVar "instantiateMethodTracked") (EVar "mctx")) (EFieldAccess (EVar "row") "msrScheme"))) (DoExpr (EApp (EApp (EApp (EVar "unify") (EVar "mctx")) (EApp (EVar "stripArrows") (EFieldAccess (EVar "inst") "mtiBody"))) (EApp (EVar "tconBuiltin") (ELit (LString "Int"))))) (DoExpr (EVar "inst"))))
(DTypeSig true "methodReturnProbeSpelling" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodSchemeRow") (TyCon "Unit"))))
(DFunDef false "methodReturnProbeSpelling" ((PVar "mctx") (PVar "row")) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodAliasEntriesRef")) (EApp (EApp (EApp (EVar "omInsert") (ELit (LString "make"))) (ETuple (EFieldAccess (EVar "row") "msrIface") (EFieldAccess (EVar "row") "msrTyparams") (EFieldAccess (EVar "row") "msrType") (EListLit))) (EVar "omEmpty"))))
(DTypeSig true "methodReturnProbeRouteKey" (TyFun (TyCon "Route") (TyCon "String")))
(DFunDef false "methodReturnProbeRouteKey" ((PCon "RKey" (PVar "key") PWild PWild)) (EVar "key"))
(DFunDef false "methodReturnProbeRouteKey" (PWild) (ELit (LString "")))
(DTypeSig true "methodReturnSelectedIdentity" (TyFun (TyCon "MethodReturnResolution") (TyCon "Int")))
(DFunDef false "methodReturnSelectedIdentity" ((PVar "resolution")) (EMatch (EFieldAccess (EVar "resolution") "mrrOutcome") (arm (PCon "Solved" (PCon "InstanceEvidence" (PCon "RequestInstanceId" (PVar "identity")) PWild PWild PWild)) () (EVar "identity")) (arm PWild () (EUnOp "-" (ELit (LInt 1))))))
(DTypeSig false "methodReturnProbeSlotIfaces" (TyFun (TyApp (TyCon "List") (TyCon "PredicateSlot")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "methodReturnProbeSlotIfaces" ((PVar "slots")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "slot")) (EFieldAccess (EFieldAccess (EVar "slot") "psIface") "irName"))) (EVar "slots")))
(DTypeSig true "methodReturnProbeGoalIfaces" (TyFun (TyApp (TyCon "List") (TyCon "Obligation")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "methodReturnProbeGoalIfaces" ((PList)) (EListLit))
(DFunDef false "methodReturnProbeGoalIfaces" ((PCons (PVar "goal") (PVar "rest"))) (EMatch (EFieldAccess (EVar "goal") "oPayload") (arm (PCon "GPMethodDict" (PVar "pending")) () (EBinOp "++" (EApp (EVar "methodReturnProbeSlotIfaces") (EFieldAccess (EVar "pending") "pmdSlots")) (EApp (EVar "methodReturnProbeGoalIfaces") (EVar "rest")))) (arm PWild () (EApp (EVar "methodReturnProbeGoalIfaces") (EVar "rest")))))
(DTypeSig true "methodReturnProbeOblIfaces" (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "methodReturnProbeOblIfaces" ((PList)) (EListLit))
(DFunDef false "methodReturnProbeOblIfaces" ((PCons (PVar "obl") (PVar "rest"))) (EBlock (DoLet false false (PVar "here") (EMatch (EFieldAccess (EVar "obl") "prov") (arm (PCon "PMethodLevel") () (EListLit (EFieldAccess (EFieldAccess (EFieldAccess (EVar "obl") "pred") "iface") "irName"))) (arm PWild () (EListLit)))) (DoExpr (EBinOp "++" (EVar "here") (EApp (EVar "methodReturnProbeOblIfaces") (EVar "rest"))))))
(DTypeSig true "methodReturnMemoCurrentViews" (TyFun (TyCon "GraphCtx") (TyApp (TyCon "List") (TyCon "MethodReturnMemoView"))))
(DFunDef false "methodReturnMemoCurrentViews" ((PVar "gctx")) (EApp (EVar "snd") (EApp (EApp (EApp (EVar "sealMethodReturnGoals") (EVar "gctx")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "evTable") "value")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "goals") "value"))))
