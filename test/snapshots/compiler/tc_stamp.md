# META
source_lines=761
stages=DESUGAR,MARK
# SOURCE
-- tc_stamp: the graph-end stamp queue: enqueue a module's stamping context, drain it after the
-- graph, and report what the drain found (`enqueueStampCtx`, `stampCtxOf`, `drainStampQueue`,
-- `DrainFinding`'s verdicts); the stamper order and its plural site resolution (`moduleStampOrder`,
-- `stampNoting`, `stampEach`, `resolveSites`, `resolveRLocalSites`, `resolveArithSites`,
-- `resolveOpSites`), the evidence-observation writer (`noteEvidenceObservation` and its entry
-- builders), the live-goal and evidence judgments, and binder-type materialization.
--
-- Spec: TYPECHECK-CONTRACTS section 3 (scoped scheduling); DICT section 4.2, section 7.1; HM-CORE
-- section 5 (owed, #2555).
--
-- Placement: declarations are placed by R1-R6 of the Phase 4 module table,
-- compiler/ARCHITECTURE-PLAYBOOK.md section 6.
-- Closure rule: this module may not import `types.typecheck`, nor any of `tc_module`.

import support.diag_codes.{DiagCode(..)}
import frontend.ast.{
  BinderId(..), ConPayload(..), Decl(..), EvEntry(..), EvVal(..), Expr(..),
  ExternDecl(..), FunClause(..), Ident(..), LetBind(..), Loc(..), Ns(..),
  Pat(..), PropParam(..), Route(..), Super(..), Ty(..), TyConOrigin(..),
  UseMember(..), UsePath(..), Variant(..), EvTable
}
import types.runtime_types.{
  BinderRow(..), RuntimeType(..), addBinderRow, runtimeTypeOf
}
import types.scopes.{ScopeOwner(..)}
import types.tc_types.{
  BuiltinClasses(..), CeRow(..), CheckRunSeed(..), ClassEnv(..),
  ConstraintReg(..), DeclaringBinder(..), DeclEnvModule(..), DrainFinding(..),
  EnvBinding(..), EvCell(..), EvDest(..), EvidenceObservationEntry(..),
  EvidenceOutcomeKind(..), GoalKind(..), GoalPayload(..), GraphCtx(..),
  GraphMarks(..), GroupCtx(..), ImplEnv(..), LiveGoal(..),
  MethodPredicateSlot(..), MethodSchemeRow(..), ModuleBindings(..),
  ModuleCtx(..), ModuleMarking(..), ModuleSeed(..), NumBoundary(..),
  NumBoundaryDisposition(..), NumGuard(..), Obligation(..), ObligationSite(..),
  PendingBinder(..), PendingEntry(..), RecDictApp(..), RecordInfo(..),
  ScopedMember(..), ScopedScheme(..), SiteCtx(..), SiteKind(..), StampCtx(..),
  StampStep(..), StandaloneOrigin(..), TcEnv(..), siteFor
}
import types.evidence_complete.{
  EvidenceRow(..), Inner(..), innerNone, innerOr, rowHoleWith
}
import types.repr.{
  IfaceRef(..), Mono(..), Scheme(..), VecObl(..), normalize, ppMono
}
import map.{Map(..)}
import support.ordmap.{
  omEmpty, omFromNames, omFromPairs, omHasKey, omInsert, omLookup, OrdMap
}
import types.evidence.{ScopeId(..)}
import types.publish.{TcDiag(..), tcLoc}
import types.tc_mono.{monoUnboundIds, resultAfterArrows}
import support.util.{
  anyList, dedupBy, filterList, isEmptyL, joinWith, lenKey, listLen, reverseL
}
import types.tc_occurrence.{evIdModule}
import types.tc_solve.{
  arithEntry, currentModuleMarks, dictAppEntry, goalKindName, goalKindTag,
  goalMonos, goalsOfKindIn, goalsSince, methodDictEntry, recDictAppEntry,
  refileDeterminedRows, returnPosMethodNames, routesOfMonosTopV, siteEntry
}
import types.tc_state.{
  blankModuleCtx, enterStampCtx, moduleCtxFrom, moduleWindow, wMark, wWindow
}
import types.tc_solve_check.{defaultLiveNumRoots, undeterminedVectorVerdict}
import types.tc_shadow.{checkAdmittedOccObls, resolveRLocalSite}
import types.tc_groups.{nestedRequireGoals}
import types.tc_diag_text.{locGoalKey, locKey}
import list.{sortOn}
import types.tc_elab.{
  realizeRecDictApps, resolveAdmittedSite, resolveArgStamps, resolveArithSite,
  resolveDictApps, resolveExactReturnSite, resolveMethodDicts,
  resolveNumLitSite, resolveOpSite, resolvePredicateOpSite, resolveSite
}
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
-- Bound: list built in tail position modulo cons: a where-local go loses the constant-stack loop until the lambda-lift pass (#4878); convert then.
-- lint-disable-next-line rule-threaded-invariant
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

resolveSites : SiteCtx -> OrdMap Unit -> List PendingEntry -> Unit
resolveSites _sx _ [] = ()
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
-- resolveRLocalSites is DELIBERATELY NOT routed through `entail`, and DICT-
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
resolveRLocalSites _sx [] = ()
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
-- resolveOpSite is now a thin adapter over `entail` (EKOp kind); the inst
-- route is stampOpRouteVal, a pure Route-returning extraction of the old stampOpRoute.
resolveOpSites : SiteCtx -> Bool -> List PendingEntry -> Unit
resolveOpSites _sx _ [] = ()
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

-- [lo, hi) less the ranges a scoped drain judged, as sub-ranges in order.
unjudgedRanges : Int -> Int -> List (Int, Int) -> List (Int, Int)
unjudgedRanges lo hi skips =
  cutRanges lo hi (sortOn fst (filterList ((a, b) => b > lo && a < hi) skips))

cutRanges : Int -> Int -> List (Int, Int) -> List (Int, Int)
cutRanges lo hi [] = if lo < hi then [(lo, hi)] else []
cutRanges lo hi ((a, b) :: rest) =
  (if a > lo then [(lo, a)] else []) ++ cutRanges (max lo b) hi rest

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
export
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
runStampStep _mctx ctx SSNumlitFloats = setNumlitFloatsGo ctx.scNumlits
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
judgeCells arr i0 hi acc0 = go i0 acc0
  where
    go i acc
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
            go
              (i + 1)
              (holeDiags (evIdModule c.ecId) c.ecLoc.value c.ecInner.value row
                ++ acc)
          None => go (i + 1) acc
        None => go (i + 1) acc

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

-- Publish this module's solved evidence, AFTER its stampers have run and
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
# DESUGAR
(DUse false (UseAlias ("core") "$core"))
(DUse false (UseGroup ("support" "diag_codes") ((mem "DiagCode" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "BinderId" true) (mem "ConPayload" true) (mem "Decl" true) (mem "EvEntry" true) (mem "EvVal" true) (mem "Expr" true) (mem "ExternDecl" true) (mem "FunClause" true) (mem "Ident" true) (mem "LetBind" true) (mem "Loc" true) (mem "Ns" true) (mem "Pat" true) (mem "PropParam" true) (mem "Route" true) (mem "Super" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "UseMember" true) (mem "UsePath" true) (mem "Variant" true) (mem "EvTable" false))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderRow" true) (mem "RuntimeType" true) (mem "addBinderRow" false) (mem "runtimeTypeOf" false))))
(DUse false (UseGroup ("types" "scopes") ((mem "ScopeOwner" true))))
(DUse false (UseGroup ("types" "tc_types") ((mem "BuiltinClasses" true) (mem "CeRow" true) (mem "CheckRunSeed" true) (mem "ClassEnv" true) (mem "ConstraintReg" true) (mem "DeclaringBinder" true) (mem "DeclEnvModule" true) (mem "DrainFinding" true) (mem "EnvBinding" true) (mem "EvCell" true) (mem "EvDest" true) (mem "EvidenceObservationEntry" true) (mem "EvidenceOutcomeKind" true) (mem "GoalKind" true) (mem "GoalPayload" true) (mem "GraphCtx" true) (mem "GraphMarks" true) (mem "GroupCtx" true) (mem "ImplEnv" true) (mem "LiveGoal" true) (mem "MethodPredicateSlot" true) (mem "MethodSchemeRow" true) (mem "ModuleBindings" true) (mem "ModuleCtx" true) (mem "ModuleMarking" true) (mem "ModuleSeed" true) (mem "NumBoundary" true) (mem "NumBoundaryDisposition" true) (mem "NumGuard" true) (mem "Obligation" true) (mem "ObligationSite" true) (mem "PendingBinder" true) (mem "PendingEntry" true) (mem "RecDictApp" true) (mem "RecordInfo" true) (mem "ScopedMember" true) (mem "ScopedScheme" true) (mem "SiteCtx" true) (mem "SiteKind" true) (mem "StampCtx" true) (mem "StampStep" true) (mem "StandaloneOrigin" true) (mem "TcEnv" true) (mem "siteFor" false))))
(DUse false (UseGroup ("types" "evidence_complete") ((mem "EvidenceRow" true) (mem "Inner" true) (mem "innerNone" false) (mem "innerOr" false) (mem "rowHoleWith" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Mono" true) (mem "Scheme" true) (mem "VecObl" true) (mem "normalize" false) (mem "ppMono" false))))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omFromNames" false) (mem "omFromPairs" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("types" "evidence") ((mem "ScopeId" true))))
(DUse false (UseGroup ("types" "publish") ((mem "TcDiag" true) (mem "tcLoc" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "monoUnboundIds" false) (mem "resultAfterArrows" false))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "dedupBy" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "joinWith" false) (mem "lenKey" false) (mem "listLen" false) (mem "reverseL" false))))
(DUse false (UseGroup ("types" "tc_occurrence") ((mem "evIdModule" false))))
(DUse false (UseGroup ("types" "tc_solve") ((mem "arithEntry" false) (mem "currentModuleMarks" false) (mem "dictAppEntry" false) (mem "goalKindName" false) (mem "goalKindTag" false) (mem "goalMonos" false) (mem "goalsOfKindIn" false) (mem "goalsSince" false) (mem "methodDictEntry" false) (mem "recDictAppEntry" false) (mem "refileDeterminedRows" false) (mem "returnPosMethodNames" false) (mem "routesOfMonosTopV" false) (mem "siteEntry" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "blankModuleCtx" false) (mem "enterStampCtx" false) (mem "moduleCtxFrom" false) (mem "moduleWindow" false) (mem "wMark" false) (mem "wWindow" false))))
(DUse false (UseGroup ("types" "tc_solve_check") ((mem "defaultLiveNumRoots" false) (mem "undeterminedVectorVerdict" false))))
(DUse false (UseGroup ("types" "tc_shadow") ((mem "checkAdmittedOccObls" false) (mem "resolveRLocalSite" false))))
(DUse false (UseGroup ("types" "tc_groups") ((mem "nestedRequireGoals" false))))
(DUse false (UseGroup ("types" "tc_diag_text") ((mem "locGoalKey" false) (mem "locKey" false))))
(DUse false (UseGroup ("list") ((mem "sortOn" false))))
(DUse false (UseGroup ("types" "tc_elab") ((mem "realizeRecDictApps" false) (mem "resolveAdmittedSite" false) (mem "resolveArgStamps" false) (mem "resolveArithSite" false) (mem "resolveDictApps" false) (mem "resolveExactReturnSite" false) (mem "resolveMethodDicts" false) (mem "resolveNumLitSite" false) (mem "resolveOpSite" false) (mem "resolvePredicateOpSite" false) (mem "resolveSite" false))))
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
(DFunDef false "renderRouteIdentity" ((PCon "RProj" (PVar "r") (PVar "path"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "RProj (")) (EApp (EVar "$core.display") (EApp (EVar "renderRouteIdentity") (EVar "r")))) (ELit (LString ") "))) (EApp (EVar "$core.display") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EApp (EApp (EVar "map") (EVar "intToString")) (EVar "path"))))) (ELit (LString ""))))
(DTypeSig false "noteEvidenceObservation" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Obligation") (TyCon "Unit"))))
(DFunDef false "noteEvidenceObservation" ((PVar "gctx") (PVar "o")) (EMatch (EFieldAccess (EVar "gctx") "trace") (arm (PCon "Some" (PVar "sink")) () (EIf (EFieldAccess (EVar "sink") "tsEvidenceObservationEnabled") (EBlock (DoLet false false (PVar "routes") (EApp (EVar "obligationRoutes") (EVar "o"))) (DoLet false false (PVar "predicates") (EApp (EVar "obligationPredicateMonos") (EVar "o"))) (DoLet false false (PVar "arity") (EApp (EVar "listLen") (EVar "routes"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "sink") "tsEvidenceObservationEntries")) (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EVar "evidenceObservationEntriesGo") (EVar "o")) (EVar "routes")) (EVar "predicates")) (EVar "arity")) (ELit (LInt 0))) (EFieldAccess (EFieldAccess (EVar "sink") "tsEvidenceObservationEntries") "value"))))) (ELit LUnit))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig false "evidenceObservationEntriesGo" (TyFun (TyCon "Obligation") (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Mono"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "EvidenceObservationEntry"))))))))
(DFunDef false "evidenceObservationEntriesGo" (PWild (PList) PWild PWild PWild) (EListLit))
(DFunDef false "evidenceObservationEntriesGo" ((PVar "o") (PCons (PVar "r") (PVar "rs")) (PVar "preds") (PVar "arity") (PVar "slot")) (EBlock (DoLet false false (PTuple (PVar "predHere") (PVar "predsRest")) (EMatch (EVar "preds") (arm (PCons (PVar "p") (PVar "ptail")) () (ETuple (EVar "p") (EVar "ptail"))) (arm (PList) () (ETuple (EVar "None") (EListLit))))) (DoExpr (EBinOp "::" (ERecordCreate "EvidenceObservationEntry" ((fa "eoeEv" (EFieldAccess (EVar "o") "oEv")) (fa "eoeGoalKind" (EApp (EVar "goalKindName") (EFieldAccess (EVar "o") "oKind"))) (fa "eoeSlot" (EVar "slot")) (fa "eoeArity" (EVar "arity")) (fa "eoePredicate" (EApp (EApp (EVar "map") (EVar "ppMono")) (EVar "predHere"))) (fa "eoeOutcome" (EApp (EVar "routeOutcomeKind") (EVar "r"))) (fa "eoeGivenBinder" (EApp (EVar "routeGivenBinder") (EVar "r"))) (fa "eoeInstanceKey" (EApp (EVar "routeInstanceKey") (EVar "r"))) (fa "eoePrerequisites" (EApp (EApp (EVar "map") (EVar "renderRouteIdentity")) (EApp (EVar "routePrerequisiteRoutes") (EVar "r")))) (fa "eoeScope" (EFieldAccess (EVar "o") "oScope")))) (EApp (EApp (EApp (EApp (EApp (EVar "evidenceObservationEntriesGo") (EVar "o")) (EVar "rs")) (EVar "predsRest")) (EVar "arity")) (EBinOp "+" (EVar "slot") (ELit (LInt 1))))))))
(DTypeSig false "resolveSites" (TyFun (TyCon "SiteCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "PendingEntry")) (TyCon "Unit")))))
(DFunDef false "resolveSites" ((PVar "_sx") PWild (PList)) (ELit LUnit))
(DFunDef false "resolveSites" ((PVar "sx") (PVar "rpNames") (PCons (PCon "PendingEntry" (PVar "name") (PVar "tagRef") (PVar "resultMono") (PVar "encl") (PVar "kind") (PVar "loc") (PVar "scope") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "sx") (ERecordUpdate (EVar "sx") ((fa "sxSite" (EVar "loc"))))) (DoExpr (EMatch (EVar "kind") (arm (PCon "SKReturn" (PVar "implRef") (PVar "fullMono")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveSite") (EVar "sx")) (EVar "rpNames")) (EVar "name")) (EVar "tagRef")) (EVar "implRef")) (EVar "resultMono")) (EVar "fullMono")) (EVar "encl")) (EVar "loc")) (EVar "scope"))) (arm (PCon "SKAdmittedReturn" (PVar "ifaceRef") (PVar "implRef") (PVar "fullMono")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveAdmittedSite") (EVar "sx")) (EVar "name")) (EVar "ifaceRef")) (EVar "tagRef")) (EVar "implRef")) (EVar "fullMono")) (EVar "encl")) (EVar "scope"))) (arm (PCon "SKExactReturn" (PVar "implRef") (PVar "request")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveExactReturnSite") (EVar "sx")) (EVar "rpNames")) (EVar "name")) (EVar "tagRef")) (EVar "implRef")) (EVar "resultMono")) (EVar "request")) (EVar "encl")) (EVar "loc")) (EVar "scope"))) (arm (PCon "SKNumReturn" (PVar "predicate") (PVar "fullMono")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveNumLitSite") (EVar "sx")) (EVar "rpNames")) (EVar "name")) (EVar "tagRef")) (EVar "resultMono")) (EVar "fullMono")) (EVar "predicate")) (EVar "encl")) (EVar "loc")) (EVar "scope"))) (arm PWild () (ELit LUnit)))) (DoExpr (EApp (EApp (EApp (EVar "resolveSites") (EVar "sx")) (EVar "rpNames")) (EVar "rest")))))
(DTypeSig false "resolveRLocalSites" (TyFun (TyCon "SiteCtx") (TyFun (TyApp (TyCon "List") (TyCon "PendingEntry")) (TyCon "Unit"))))
(DFunDef false "resolveRLocalSites" ((PVar "_sx") (PList)) (ELit LUnit))
(DFunDef false "resolveRLocalSites" ((PVar "sx") (PCons (PCon "PendingEntry" (PVar "name") (PVar "tagRef") (PVar "am") (PVar "encl") (PVar "kind") (PVar "loc") (PVar "scope") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "sx") (ERecordUpdate (EVar "sx") ((fa "sxSite" (EVar "loc"))))) (DoExpr (EMatch (EVar "kind") (arm (PCon "SKRLocal" (PVar "sym") (PVar "forceLocal") (PVar "monos") (PVar "ifaces") (PVar "argVecs")) () (EIf (EVar "forceLocal") (EApp (EApp (EVar "setRef") (EVar "tagRef")) (EApp (EApp (EVar "RLocal") (EVar "sym")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routesOfMonosTopV") (EVar "sx")) (EVar "encl")) (EVar "scope")) (EVar "monos")) (EVar "ifaces")) (EVar "argVecs")))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveRLocalSite") (EVar "sx")) (EVar "name")) (EVar "tagRef")) (EVar "am")) (EVar "encl")) (EVar "scope")) (EVar "sym")) (EVar "monos")) (EVar "ifaces")) (EVar "argVecs")))) (arm PWild () (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "resolveRLocalSites") (EVar "sx")) (EVar "rest")))))
(DTypeSig false "resolveArithSites" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Ref") (TyCon "Route")) (TyCon "Mono"))) (TyCon "Unit")))
(DFunDef false "resolveArithSites" ((PList)) (ELit LUnit))
(DFunDef false "resolveArithSites" ((PCons (PTuple (PVar "dref") (PVar "m")) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EVar "resolveArithSite") (EVar "dref")) (EVar "m"))) (DoExpr (EApp (EVar "resolveArithSites") (EVar "rest")))))
(DTypeSig false "resolveOpSites" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "PendingEntry")) (TyCon "Unit")))))
(DFunDef false "resolveOpSites" ((PVar "_sx") PWild (PList)) (ELit LUnit))
(DFunDef false "resolveOpSites" ((PVar "sx") (PVar "isBinop") (PCons (PCon "PendingEntry" (PVar "method") (PVar "tagRef") (PVar "operandMono") (PVar "encl") (PVar "kind") (PVar "loc") (PVar "scope") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "sx") (ERecordUpdate (EVar "sx") ((fa "sxSite" (EVar "loc"))))) (DoExpr (EMatch (EVar "kind") (arm (PCon "SKOp" (PVar "inImpl")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveOpSite") (EVar "sx")) (EVar "isBinop")) (EVar "method")) (EVar "tagRef")) (EVar "operandMono")) (EVar "inImpl")) (EVar "encl")) (EVar "scope"))) (arm (PCon "SKPredicateOp" (PVar "inImpl") (PVar "predicate")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolvePredicateOpSite") (EVar "sx")) (EVar "isBinop")) (EVar "method")) (EVar "tagRef")) (EVar "operandMono")) (EVar "inImpl")) (EVar "predicate")) (EVar "encl")) (EVar "scope"))) (arm PWild () (ELit LUnit)))) (DoExpr (EApp (EApp (EApp (EVar "resolveOpSites") (EVar "sx")) (EVar "isBinop")) (EVar "rest")))))
(DTypeSig false "setNumlitFloatsGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Float"))) (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Route")))) (TyCon "Unit")))
(DFunDef false "setNumlitFloatsGo" ((PList)) (ELit LUnit))
(DFunDef false "setNumlitFloatsGo" ((PCons (PTuple (PVar "var") (PVar "fref") (PVar "n") (PVar "dref")) (PVar "rest"))) (EBlock (DoExpr (EMatch (EApp (EVar "normalize") (EVar "var")) (arm (PCon "TCon" (PLit (LString "Float")) PWild) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "fref")) (EApp (EVar "Some") (EApp (EVar "intToFloat") (EVar "n"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "dref")) (EVar "RNone"))))) (arm (PCon "TCon" (PLit (LString "Int")) PWild) () (EApp (EApp (EVar "setRef") (EVar "dref")) (EVar "RNone"))) (arm PWild () (ELit LUnit)))) (DoExpr (EApp (EVar "setNumlitFloatsGo") (EVar "rest")))))
(DTypeSig false "judgeLiveGoals" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "StampCtx")) (TyApp (TyCon "List") (TyCon "DrainFinding")))))
(DFunDef false "judgeLiveGoals" ((PVar "saved") (PVar "ctxs")) (EBlock (DoLet false false (PVar "g") (EFieldAccess (EFieldAccess (EVar "saved") "mcGraph") "graphRun")) (DoLet false false (PVar "goals") (EApp (EVar "reverseL") (EFieldAccess (EFieldAccess (EVar "g") "liveGoals") "value"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "liveGoals")) (EListLit))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "goals")) (EListLit) (EBlock (DoLet false false (PVar "byModule") (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EVar "map") (ELam ((PVar "c")) (ETuple (EFieldAccess (EVar "c") "scModule") (EVar "c")))) (EVar "ctxs"))) (EVar "omEmpty"))) (DoExpr (EApp (EVar "reverseL") (EApp (EVar "fst") (EApp (EApp (EApp (EVar "fold") (EApp (EApp (EVar "judgeLiveGoal") (EVar "saved")) (EVar "byModule"))) (ETuple (EListLit) (EVar "omEmpty"))) (EVar "goals"))))))))))
(DTypeSig false "judgeLiveGoal" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "StampCtx")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "DrainFinding")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyCon "LiveGoal") (TyTuple (TyApp (TyCon "List") (TyCon "DrainFinding")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))))
(DFunDef false "judgeLiveGoal" ((PVar "saved") (PVar "byModule") (PTuple (PVar "found") (PVar "judged")) (PVar "lg")) (EBlock (DoLet false false (PVar "binding") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "$core.display") (EFieldAccess (EVar "lg") "lgModule"))) (ELit (LString "\t"))) (EApp (EVar "$core.display") (EApp (EVar "intToString") (EFieldAccess (EVar "lg") "lgBinding")))) (ELit (LString "")))) (DoExpr (EMatch (ETuple (EApp (EApp (EVar "omHasKey") (EVar "binding")) (EVar "judged")) (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "lg") "lgModule")) (EVar "byModule"))) (arm (PTuple (PCon "False") (PCon "Some" (PVar "ctx"))) () (EBlock (DoLet false false (PVar "stamp") (EApp (EApp (EVar "enterStampCtx") (EVar "saved")) (EVar "ctx"))) (DoLet false false (PVar "rigidIds") (EFieldAccess (EVar "lg") "lgRigidIds")) (DoLet false false (PVar "diags") (EApp (EApp (EVar "captureTypeErrors") (EVar "stamp")) (ELam (PWild) (EApp (EApp (EVar "each") (EApp (EApp (EApp (EApp (EVar "undeterminedVectorVerdict") (EVar "stamp")) (EVar "rigidIds")) (EVar "omEmpty")) (EFieldAccess (EVar "lg") "lgWindow"))) (EBinOp "::" (EFieldAccess (EVar "lg") "lgGoal") (EApp (EApp (EApp (EApp (EVar "nestedRequireGoals") (EVar "stamp")) (EVar "rigidIds")) (EVar "omEmpty")) (EListLit (EFieldAccess (EVar "lg") "lgGoal")))))))) (DoExpr (EMatch (EVar "diags") (arm (PList) () (ETuple (EVar "found") (EVar "judged"))) (arm PWild () (ETuple (EBinOp "++" (EApp (EVar "reverseL") (EApp (EApp (EVar "map") (EApp (EApp (EVar "verdictFinding") (EFieldAccess (EVar "lg") "lgModule")) (EVar "True"))) (EVar "diags"))) (EVar "found")) (EApp (EApp (EApp (EVar "omInsert") (EVar "binding")) (ELit LUnit)) (EVar "judged")))))))) (arm PWild () (ETuple (EVar "found") (EVar "judged")))))))
(DTypeSig false "unjudgedRanges" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "unjudgedRanges" ((PVar "lo") (PVar "hi") (PVar "skips")) (EApp (EApp (EApp (EVar "cutRanges") (EVar "lo")) (EVar "hi")) (EApp (EApp (EVar "sortOn") (EVar "fst")) (EApp (EApp (EVar "filterList") (ELam ((PTuple (PVar "a") (PVar "b"))) (EBinOp "&&" (EBinOp ">" (EVar "b") (EVar "lo")) (EBinOp "<" (EVar "a") (EVar "hi"))))) (EVar "skips")))))
(DTypeSig false "cutRanges" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "cutRanges" ((PVar "lo") (PVar "hi") (PList)) (EIf (EBinOp "<" (EVar "lo") (EVar "hi")) (EListLit (ETuple (EVar "lo") (EVar "hi"))) (EListLit)))
(DFunDef false "cutRanges" ((PVar "lo") (PVar "hi") (PCons (PTuple (PVar "a") (PVar "b")) (PVar "rest"))) (EBinOp "++" (EIf (EBinOp ">" (EVar "a") (EVar "lo")) (EListLit (ETuple (EVar "lo") (EVar "a"))) (EListLit)) (EApp (EApp (EApp (EVar "cutRanges") (EApp (EApp (EVar "max") (EVar "lo")) (EVar "b"))) (EVar "hi")) (EVar "rest"))))
(DTypeSig false "moduleStampOrder" (TyApp (TyCon "List") (TyCon "StampStep")))
(DFunDef false "moduleStampOrder" () (EListLit (EVar "SSNumlitFloats") (EVar "SSReturnSites") (EVar "SSBinopSites") (EVar "SSUnopSites") (EVar "SSArithSites") (EVar "SSArgStamps") (EVar "SSRLocalSites") (EVar "SSRecDictApps") (EVar "SSDictApps") (EVar "SSMethodDicts")))
(DTypeSig false "isLiveSpan" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Bool"))))
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
(DTypeSig false "spanKeys" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "spanKeys" ((PList)) (EListLit))
(DFunDef false "spanKeys" ((PCons (PCon "None") (PVar "rest"))) (EApp (EVar "spanKeys") (EVar "rest")))
(DFunDef false "spanKeys" ((PCons (PVar "loc") (PVar "rest"))) (EBinOp "::" (EApp (EVar "locKey") (EVar "loc")) (EApp (EVar "spanKeys") (EVar "rest"))))
(DTypeSig false "isInterfaceDecl" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isInterfaceDecl" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "isInterfaceDecl") (EVar "d")))
(DFunDef false "isInterfaceDecl" ((PRec "DInterface" () false)) (EVar "True"))
(DFunDef false "isInterfaceDecl" (PWild) (EVar "False"))
(DTypeSig true "enqueueStampCtx" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))))
(DFunDef false "enqueueStampCtx" ((PVar "mctx") (PVar "mid") (PVar "implDecls")) (EBlock (DoLet false false (PVar "mk") (EApp (EApp (EVar "currentModuleMarks") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (DoLet false false (PVar "ctx") (EApp (EApp (EApp (EApp (EApp (EVar "stampCtxOf") (EVar "mctx")) (EVar "mid")) (EVar "implDecls")) (EApp (EApp (EVar "goalsSince") (EFieldAccess (EVar "mctx") "mcGraph")) (EFieldAccess (EVar "mk") "mGoals"))) (EApp (EApp (EVar "numlitSince") (EFieldAccess (EVar "mctx") "mcGraph")) (EFieldAccess (EVar "mk") "mNumlit")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "stampCtxs")) (EBinOp "::" (EVar "ctx") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "stampCtxs") "value"))))))
(DTypeSig false "stampNoting" (TyFun (TyCon "ModuleCtx") (TyFun (TyFun (TyCon "SiteCtx") (TyFun (TyCon "Obligation") (TyCon "Unit"))) (TyFun (TyCon "Obligation") (TyCon "Unit")))))
(DFunDef false "stampNoting" ((PVar "stamp") (PVar "resolve") (PVar "o")) (EBlock (DoLet false false (PVar "acc") (EApp (EVar "Ref") (EVar "innerNone"))) (DoExpr (EApp (EApp (EVar "resolve") (ERecordUpdate (EApp (EVar "siteFor") (EVar "stamp")) ((fa "sxInner" (EApp (EVar "Some") (EVar "acc")))))) (EVar "o"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "o") "oInner")) (EApp (EApp (EVar "innerOr") (EFieldAccess (EFieldAccess (EVar "o") "oInner") "value")) (EFieldAccess (EVar "acc") "value"))))))
(DTypeSig false "runStampStep" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "StampCtx") (TyFun (TyCon "StampStep") (TyCon "Unit")))))
(DFunDef false "runStampStep" ((PVar "_mctx") (PVar "ctx") (PCon "SSNumlitFloats")) (EApp (EVar "setNumlitFloatsGo") (EFieldAccess (EVar "ctx") "scNumlits")))
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
(DTypeSig false "judgeEvidence" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "StampCtx")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))))))
(DFunDef false "judgeEvidence" ((PVar "gctx") (PVar "ctxs")) (EBlock (DoLet false false (PVar "g") (EFieldAccess (EVar "gctx") "graphRun")) (DoLet false false (PVar "lo") (EFieldAccess (EFieldAccess (EVar "g") "evJudged") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "evJudged")) (EFieldAccess (EFieldAccess (EVar "g") "evCounter") "value"))) (DoLet false false (PVar "base") (EFieldAccess (EVar "g") "evBase")) (DoLet false false (PVar "cellHoles") (EApp (EApp (EVar "flatMap") (ELam ((PTuple (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EApp (EVar "judgeCells") (EFieldAccess (EFieldAccess (EVar "g") "evCells") "value")) (EBinOp "-" (EVar "a") (EVar "base"))) (EBinOp "-" (EVar "b") (EVar "base"))) (EListLit)))) (EApp (EApp (EApp (EVar "unjudgedRanges") (EVar "lo")) (EFieldAccess (EFieldAccess (EVar "g") "evCounter") "value")) (EFieldAccess (EFieldAccess (EVar "g") "evScopedJudged") "value")))) (DoLet false false (PVar "goalHoles") (EApp (EApp (EVar "flatMap") (ELam ((PVar "c")) (EApp (EApp (EVar "flatMap") (EApp (EVar "judgeGoal") (EFieldAccess (EVar "c") "scModule"))) (EFieldAccess (EVar "c") "scGoals")))) (EVar "ctxs"))) (DoExpr (EApp (EApp (EVar "dedupBy") (EVar "holeKey")) (EBinOp "++" (EVar "cellHoles") (EVar "goalHoles"))))))
(DTypeSig false "holeKey" (TyFun (TyTuple (TyCon "String") (TyCon "TcDiag")) (TyCon "String")))
(DFunDef false "holeKey" ((PTuple (PVar "m") (PCon "TcDiag" PWild PWild (PVar "loc") (PVar "msg") PWild PWild))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "$core.display") (EApp (EVar "lenKey") (EVar "m")))) (ELit (LString ""))) (EApp (EVar "$core.display") (EApp (EVar "lenKey") (EApp (EVar "locGoalKey") (EVar "loc"))))) (ELit (LString ""))) (EApp (EVar "$core.display") (EVar "msg"))) (ELit (LString ""))))
(DTypeSig false "judgeCells" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvCell"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))))))))
(DFunDef false "judgeCells" ((PVar "arr") (PVar "i0") (PVar "hi") (PVar "acc0")) (ELetGroup ((lgb "go" (clause ((PVar "i") (PVar "acc")) (EIf (EBinOp "||" (EBinOp ">=" (EVar "i") (EVar "hi")) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr")))) (EVar "acc") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (arm (PCon "Some" (PVar "c")) () (EMatch (EFieldAccess (EFieldAccess (EVar "c") "ecArity") "value") (arm (PCon "Some" PWild) () (EBlock (DoLet false false (PVar "row") (EApp (EApp (EApp (EApp (EApp (EVar "OccurrenceRow") (EFieldAccess (EFieldAccess (EVar "c") "ecName") "value")) (EFieldAccess (EFieldAccess (EVar "c") "ecIface") "value")) (EFieldAccess (EFieldAccess (EVar "c") "ecTag") "value")) (EFieldAccess (EFieldAccess (EVar "c") "ecImpl") "value")) (EFieldAccess (EFieldAccess (EVar "c") "ecMeth") "value"))) (DoExpr (EApp (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "holeDiags") (EApp (EVar "evIdModule") (EFieldAccess (EVar "c") "ecId"))) (EFieldAccess (EFieldAccess (EVar "c") "ecLoc") "value")) (EFieldAccess (EFieldAccess (EVar "c") "ecInner") "value")) (EVar "row")) (EVar "acc")))))) (arm (PCon "None") () (EApp (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc"))))) (arm (PCon "None") () (EApp (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))) (EApp (EApp (EVar "go") (EVar "i0")) (EVar "acc0"))))
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
(DFunDef false "cellHeadKey" ((PVar "n") (PCon "OriginBuiltin")) (EBinOp "++" (EBinOp "++" (ELit (LString "builtin|")) (EApp (EVar "$core.display") (EVar "n"))) (ELit (LString ""))))
(DFunDef false "cellHeadKey" ((PVar "n") (PCon "OriginUnresolved")) (EBinOp "++" (EBinOp "++" (ELit (LString "unresolved|")) (EApp (EVar "$core.display") (EVar "n"))) (ELit (LString ""))))
(DFunDef false "cellHeadKey" ((PVar "n") (PCon "OriginModule" (PVar "m"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "module ")) (EApp (EVar "$core.display") (EVar "m"))) (ELit (LString "|"))) (EApp (EVar "$core.display") (EVar "n"))) (ELit (LString ""))))
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
# MARK
(DUse false (UseAlias ("core") "$core"))
(DUse false (UseGroup ("support" "diag_codes") ((mem "DiagCode" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "BinderId" true) (mem "ConPayload" true) (mem "Decl" true) (mem "EvEntry" true) (mem "EvVal" true) (mem "Expr" true) (mem "ExternDecl" true) (mem "FunClause" true) (mem "Ident" true) (mem "LetBind" true) (mem "Loc" true) (mem "Ns" true) (mem "Pat" true) (mem "PropParam" true) (mem "Route" true) (mem "Super" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "UseMember" true) (mem "UsePath" true) (mem "Variant" true) (mem "EvTable" false))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderRow" true) (mem "RuntimeType" true) (mem "addBinderRow" false) (mem "runtimeTypeOf" false))))
(DUse false (UseGroup ("types" "scopes") ((mem "ScopeOwner" true))))
(DUse false (UseGroup ("types" "tc_types") ((mem "BuiltinClasses" true) (mem "CeRow" true) (mem "CheckRunSeed" true) (mem "ClassEnv" true) (mem "ConstraintReg" true) (mem "DeclaringBinder" true) (mem "DeclEnvModule" true) (mem "DrainFinding" true) (mem "EnvBinding" true) (mem "EvCell" true) (mem "EvDest" true) (mem "EvidenceObservationEntry" true) (mem "EvidenceOutcomeKind" true) (mem "GoalKind" true) (mem "GoalPayload" true) (mem "GraphCtx" true) (mem "GraphMarks" true) (mem "GroupCtx" true) (mem "ImplEnv" true) (mem "LiveGoal" true) (mem "MethodPredicateSlot" true) (mem "MethodSchemeRow" true) (mem "ModuleBindings" true) (mem "ModuleCtx" true) (mem "ModuleMarking" true) (mem "ModuleSeed" true) (mem "NumBoundary" true) (mem "NumBoundaryDisposition" true) (mem "NumGuard" true) (mem "Obligation" true) (mem "ObligationSite" true) (mem "PendingBinder" true) (mem "PendingEntry" true) (mem "RecDictApp" true) (mem "RecordInfo" true) (mem "ScopedMember" true) (mem "ScopedScheme" true) (mem "SiteCtx" true) (mem "SiteKind" true) (mem "StampCtx" true) (mem "StampStep" true) (mem "StandaloneOrigin" true) (mem "TcEnv" true) (mem "siteFor" false))))
(DUse false (UseGroup ("types" "evidence_complete") ((mem "EvidenceRow" true) (mem "Inner" true) (mem "innerNone" false) (mem "innerOr" false) (mem "rowHoleWith" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Mono" true) (mem "Scheme" true) (mem "VecObl" true) (mem "normalize" false) (mem "ppMono" false))))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omFromNames" false) (mem "omFromPairs" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("types" "evidence") ((mem "ScopeId" true))))
(DUse false (UseGroup ("types" "publish") ((mem "TcDiag" true) (mem "tcLoc" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "monoUnboundIds" false) (mem "resultAfterArrows" false))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "dedupBy" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "joinWith" false) (mem "lenKey" false) (mem "listLen" false) (mem "reverseL" false))))
(DUse false (UseGroup ("types" "tc_occurrence") ((mem "evIdModule" false))))
(DUse false (UseGroup ("types" "tc_solve") ((mem "arithEntry" false) (mem "currentModuleMarks" false) (mem "dictAppEntry" false) (mem "goalKindName" false) (mem "goalKindTag" false) (mem "goalMonos" false) (mem "goalsOfKindIn" false) (mem "goalsSince" false) (mem "methodDictEntry" false) (mem "recDictAppEntry" false) (mem "refileDeterminedRows" false) (mem "returnPosMethodNames" false) (mem "routesOfMonosTopV" false) (mem "siteEntry" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "blankModuleCtx" false) (mem "enterStampCtx" false) (mem "moduleCtxFrom" false) (mem "moduleWindow" false) (mem "wMark" false) (mem "wWindow" false))))
(DUse false (UseGroup ("types" "tc_solve_check") ((mem "defaultLiveNumRoots" false) (mem "undeterminedVectorVerdict" false))))
(DUse false (UseGroup ("types" "tc_shadow") ((mem "checkAdmittedOccObls" false) (mem "resolveRLocalSite" false))))
(DUse false (UseGroup ("types" "tc_groups") ((mem "nestedRequireGoals" false))))
(DUse false (UseGroup ("types" "tc_diag_text") ((mem "locGoalKey" false) (mem "locKey" false))))
(DUse false (UseGroup ("list") ((mem "sortOn" false))))
(DUse false (UseGroup ("types" "tc_elab") ((mem "realizeRecDictApps" false) (mem "resolveAdmittedSite" false) (mem "resolveArgStamps" false) (mem "resolveArithSite" false) (mem "resolveDictApps" false) (mem "resolveExactReturnSite" false) (mem "resolveMethodDicts" false) (mem "resolveNumLitSite" false) (mem "resolveOpSite" false) (mem "resolvePredicateOpSite" false) (mem "resolveSite" false))))
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
(DFunDef false "renderRouteIdentity" ((PCon "RProj" (PVar "r") (PVar "path"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "RProj (")) (EApp (EVar "$core.display") (EApp (EVar "renderRouteIdentity") (EVar "r")))) (ELit (LString ") "))) (EApp (EVar "$core.display") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EApp (EApp (EMethodRef "map") (EVar "intToString")) (EVar "path"))))) (ELit (LString ""))))
(DTypeSig false "noteEvidenceObservation" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Obligation") (TyCon "Unit"))))
(DFunDef false "noteEvidenceObservation" ((PVar "gctx") (PVar "o")) (EMatch (EFieldAccess (EVar "gctx") "trace") (arm (PCon "Some" (PVar "sink")) () (EIf (EFieldAccess (EVar "sink") "tsEvidenceObservationEnabled") (EBlock (DoLet false false (PVar "routes") (EApp (EVar "obligationRoutes") (EVar "o"))) (DoLet false false (PVar "predicates") (EApp (EVar "obligationPredicateMonos") (EVar "o"))) (DoLet false false (PVar "arity") (EApp (EVar "listLen") (EVar "routes"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "sink") "tsEvidenceObservationEntries")) (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EVar "evidenceObservationEntriesGo") (EVar "o")) (EVar "routes")) (EVar "predicates")) (EVar "arity")) (ELit (LInt 0))) (EFieldAccess (EFieldAccess (EVar "sink") "tsEvidenceObservationEntries") "value"))))) (ELit LUnit))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig false "evidenceObservationEntriesGo" (TyFun (TyCon "Obligation") (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Mono"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "EvidenceObservationEntry"))))))))
(DFunDef false "evidenceObservationEntriesGo" (PWild (PList) PWild PWild PWild) (EListLit))
(DFunDef false "evidenceObservationEntriesGo" ((PVar "o") (PCons (PVar "r") (PVar "rs")) (PVar "preds") (PVar "arity") (PVar "slot")) (EBlock (DoLet false false (PTuple (PVar "predHere") (PVar "predsRest")) (EMatch (EVar "preds") (arm (PCons (PVar "p") (PVar "ptail")) () (ETuple (EVar "p") (EVar "ptail"))) (arm (PList) () (ETuple (EVar "None") (EListLit))))) (DoExpr (EBinOp "::" (ERecordCreate "EvidenceObservationEntry" ((fa "eoeEv" (EFieldAccess (EVar "o") "oEv")) (fa "eoeGoalKind" (EApp (EVar "goalKindName") (EFieldAccess (EVar "o") "oKind"))) (fa "eoeSlot" (EVar "slot")) (fa "eoeArity" (EVar "arity")) (fa "eoePredicate" (EApp (EApp (EMethodRef "map") (EVar "ppMono")) (EVar "predHere"))) (fa "eoeOutcome" (EApp (EVar "routeOutcomeKind") (EVar "r"))) (fa "eoeGivenBinder" (EApp (EVar "routeGivenBinder") (EVar "r"))) (fa "eoeInstanceKey" (EApp (EVar "routeInstanceKey") (EVar "r"))) (fa "eoePrerequisites" (EApp (EApp (EMethodRef "map") (EVar "renderRouteIdentity")) (EApp (EVar "routePrerequisiteRoutes") (EVar "r")))) (fa "eoeScope" (EFieldAccess (EVar "o") "oScope")))) (EApp (EApp (EApp (EApp (EApp (EVar "evidenceObservationEntriesGo") (EVar "o")) (EVar "rs")) (EVar "predsRest")) (EVar "arity")) (EBinOp "+" (EVar "slot") (ELit (LInt 1))))))))
(DTypeSig false "resolveSites" (TyFun (TyCon "SiteCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "PendingEntry")) (TyCon "Unit")))))
(DFunDef false "resolveSites" ((PVar "_sx") PWild (PList)) (ELit LUnit))
(DFunDef false "resolveSites" ((PVar "sx") (PVar "rpNames") (PCons (PCon "PendingEntry" (PVar "name") (PVar "tagRef") (PVar "resultMono") (PVar "encl") (PVar "kind") (PVar "loc") (PVar "scope") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "sx") (ERecordUpdate (EVar "sx") ((fa "sxSite" (EVar "loc"))))) (DoExpr (EMatch (EVar "kind") (arm (PCon "SKReturn" (PVar "implRef") (PVar "fullMono")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveSite") (EVar "sx")) (EVar "rpNames")) (EVar "name")) (EVar "tagRef")) (EVar "implRef")) (EVar "resultMono")) (EVar "fullMono")) (EVar "encl")) (EVar "loc")) (EVar "scope"))) (arm (PCon "SKAdmittedReturn" (PVar "ifaceRef") (PVar "implRef") (PVar "fullMono")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveAdmittedSite") (EVar "sx")) (EVar "name")) (EVar "ifaceRef")) (EVar "tagRef")) (EVar "implRef")) (EVar "fullMono")) (EVar "encl")) (EVar "scope"))) (arm (PCon "SKExactReturn" (PVar "implRef") (PVar "request")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveExactReturnSite") (EVar "sx")) (EVar "rpNames")) (EVar "name")) (EVar "tagRef")) (EVar "implRef")) (EVar "resultMono")) (EVar "request")) (EVar "encl")) (EVar "loc")) (EVar "scope"))) (arm (PCon "SKNumReturn" (PVar "predicate") (PVar "fullMono")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveNumLitSite") (EVar "sx")) (EVar "rpNames")) (EVar "name")) (EVar "tagRef")) (EVar "resultMono")) (EVar "fullMono")) (EVar "predicate")) (EVar "encl")) (EVar "loc")) (EVar "scope"))) (arm PWild () (ELit LUnit)))) (DoExpr (EApp (EApp (EApp (EVar "resolveSites") (EVar "sx")) (EVar "rpNames")) (EVar "rest")))))
(DTypeSig false "resolveRLocalSites" (TyFun (TyCon "SiteCtx") (TyFun (TyApp (TyCon "List") (TyCon "PendingEntry")) (TyCon "Unit"))))
(DFunDef false "resolveRLocalSites" ((PVar "_sx") (PList)) (ELit LUnit))
(DFunDef false "resolveRLocalSites" ((PVar "sx") (PCons (PCon "PendingEntry" (PVar "name") (PVar "tagRef") (PVar "am") (PVar "encl") (PVar "kind") (PVar "loc") (PVar "scope") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "sx") (ERecordUpdate (EVar "sx") ((fa "sxSite" (EVar "loc"))))) (DoExpr (EMatch (EVar "kind") (arm (PCon "SKRLocal" (PVar "sym") (PVar "forceLocal") (PVar "monos") (PVar "ifaces") (PVar "argVecs")) () (EIf (EVar "forceLocal") (EApp (EApp (EVar "setRef") (EVar "tagRef")) (EApp (EApp (EVar "RLocal") (EVar "sym")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routesOfMonosTopV") (EVar "sx")) (EVar "encl")) (EVar "scope")) (EVar "monos")) (EVar "ifaces")) (EVar "argVecs")))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveRLocalSite") (EVar "sx")) (EVar "name")) (EVar "tagRef")) (EVar "am")) (EVar "encl")) (EVar "scope")) (EVar "sym")) (EVar "monos")) (EVar "ifaces")) (EVar "argVecs")))) (arm PWild () (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "resolveRLocalSites") (EVar "sx")) (EVar "rest")))))
(DTypeSig false "resolveArithSites" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Ref") (TyCon "Route")) (TyCon "Mono"))) (TyCon "Unit")))
(DFunDef false "resolveArithSites" ((PList)) (ELit LUnit))
(DFunDef false "resolveArithSites" ((PCons (PTuple (PVar "dref") (PVar "m")) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EVar "resolveArithSite") (EVar "dref")) (EVar "m"))) (DoExpr (EApp (EVar "resolveArithSites") (EVar "rest")))))
(DTypeSig false "resolveOpSites" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "PendingEntry")) (TyCon "Unit")))))
(DFunDef false "resolveOpSites" ((PVar "_sx") PWild (PList)) (ELit LUnit))
(DFunDef false "resolveOpSites" ((PVar "sx") (PVar "isBinop") (PCons (PCon "PendingEntry" (PVar "method") (PVar "tagRef") (PVar "operandMono") (PVar "encl") (PVar "kind") (PVar "loc") (PVar "scope") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "sx") (ERecordUpdate (EVar "sx") ((fa "sxSite" (EVar "loc"))))) (DoExpr (EMatch (EVar "kind") (arm (PCon "SKOp" (PVar "inImpl")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveOpSite") (EVar "sx")) (EVar "isBinop")) (EVar "method")) (EVar "tagRef")) (EVar "operandMono")) (EVar "inImpl")) (EVar "encl")) (EVar "scope"))) (arm (PCon "SKPredicateOp" (PVar "inImpl") (PVar "predicate")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolvePredicateOpSite") (EVar "sx")) (EVar "isBinop")) (EVar "method")) (EVar "tagRef")) (EVar "operandMono")) (EVar "inImpl")) (EVar "predicate")) (EVar "encl")) (EVar "scope"))) (arm PWild () (ELit LUnit)))) (DoExpr (EApp (EApp (EApp (EVar "resolveOpSites") (EVar "sx")) (EVar "isBinop")) (EVar "rest")))))
(DTypeSig false "setNumlitFloatsGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Float"))) (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Route")))) (TyCon "Unit")))
(DFunDef false "setNumlitFloatsGo" ((PList)) (ELit LUnit))
(DFunDef false "setNumlitFloatsGo" ((PCons (PTuple (PVar "var") (PVar "fref") (PVar "n") (PVar "dref")) (PVar "rest"))) (EBlock (DoExpr (EMatch (EApp (EVar "normalize") (EVar "var")) (arm (PCon "TCon" (PLit (LString "Float")) PWild) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "fref")) (EApp (EVar "Some") (EApp (EVar "intToFloat") (EVar "n"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "dref")) (EVar "RNone"))))) (arm (PCon "TCon" (PLit (LString "Int")) PWild) () (EApp (EApp (EVar "setRef") (EVar "dref")) (EVar "RNone"))) (arm PWild () (ELit LUnit)))) (DoExpr (EApp (EVar "setNumlitFloatsGo") (EVar "rest")))))
(DTypeSig false "judgeLiveGoals" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "StampCtx")) (TyApp (TyCon "List") (TyCon "DrainFinding")))))
(DFunDef false "judgeLiveGoals" ((PVar "saved") (PVar "ctxs")) (EBlock (DoLet false false (PVar "g") (EFieldAccess (EFieldAccess (EVar "saved") "mcGraph") "graphRun")) (DoLet false false (PVar "goals") (EApp (EVar "reverseL") (EFieldAccess (EFieldAccess (EVar "g") "liveGoals") "value"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "liveGoals")) (EListLit))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "goals")) (EListLit) (EBlock (DoLet false false (PVar "byModule") (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EMethodRef "map") (ELam ((PVar "c")) (ETuple (EFieldAccess (EVar "c") "scModule") (EVar "c")))) (EVar "ctxs"))) (EVar "omEmpty"))) (DoExpr (EApp (EVar "reverseL") (EApp (EVar "fst") (EApp (EApp (EApp (EMethodRef "fold") (EApp (EApp (EVar "judgeLiveGoal") (EVar "saved")) (EVar "byModule"))) (ETuple (EListLit) (EVar "omEmpty"))) (EVar "goals"))))))))))
(DTypeSig false "judgeLiveGoal" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "StampCtx")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "DrainFinding")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyCon "LiveGoal") (TyTuple (TyApp (TyCon "List") (TyCon "DrainFinding")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))))
(DFunDef false "judgeLiveGoal" ((PVar "saved") (PVar "byModule") (PTuple (PVar "found") (PVar "judged")) (PVar "lg")) (EBlock (DoLet false false (PVar "binding") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "$core.display") (EFieldAccess (EVar "lg") "lgModule"))) (ELit (LString "\t"))) (EApp (EVar "$core.display") (EApp (EVar "intToString") (EFieldAccess (EVar "lg") "lgBinding")))) (ELit (LString "")))) (DoExpr (EMatch (ETuple (EApp (EApp (EVar "omHasKey") (EVar "binding")) (EVar "judged")) (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "lg") "lgModule")) (EVar "byModule"))) (arm (PTuple (PCon "False") (PCon "Some" (PVar "ctx"))) () (EBlock (DoLet false false (PVar "stamp") (EApp (EApp (EVar "enterStampCtx") (EVar "saved")) (EVar "ctx"))) (DoLet false false (PVar "rigidIds") (EFieldAccess (EVar "lg") "lgRigidIds")) (DoLet false false (PVar "diags") (EApp (EApp (EVar "captureTypeErrors") (EVar "stamp")) (ELam (PWild) (EApp (EApp (EVar "each") (EApp (EApp (EApp (EApp (EVar "undeterminedVectorVerdict") (EVar "stamp")) (EVar "rigidIds")) (EVar "omEmpty")) (EFieldAccess (EVar "lg") "lgWindow"))) (EBinOp "::" (EFieldAccess (EVar "lg") "lgGoal") (EApp (EApp (EApp (EApp (EVar "nestedRequireGoals") (EVar "stamp")) (EVar "rigidIds")) (EVar "omEmpty")) (EListLit (EFieldAccess (EVar "lg") "lgGoal")))))))) (DoExpr (EMatch (EVar "diags") (arm (PList) () (ETuple (EVar "found") (EVar "judged"))) (arm PWild () (ETuple (EBinOp "++" (EApp (EVar "reverseL") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "verdictFinding") (EFieldAccess (EVar "lg") "lgModule")) (EVar "True"))) (EVar "diags"))) (EVar "found")) (EApp (EApp (EApp (EVar "omInsert") (EVar "binding")) (ELit LUnit)) (EVar "judged")))))))) (arm PWild () (ETuple (EVar "found") (EVar "judged")))))))
(DTypeSig false "unjudgedRanges" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "unjudgedRanges" ((PVar "lo") (PVar "hi") (PVar "skips")) (EApp (EApp (EApp (EVar "cutRanges") (EVar "lo")) (EVar "hi")) (EApp (EApp (EVar "sortOn") (EVar "fst")) (EApp (EApp (EVar "filterList") (ELam ((PTuple (PVar "a") (PVar "b"))) (EBinOp "&&" (EBinOp ">" (EVar "b") (EVar "lo")) (EBinOp "<" (EVar "a") (EVar "hi"))))) (EVar "skips")))))
(DTypeSig false "cutRanges" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "cutRanges" ((PVar "lo") (PVar "hi") (PList)) (EIf (EBinOp "<" (EVar "lo") (EVar "hi")) (EListLit (ETuple (EVar "lo") (EVar "hi"))) (EListLit)))
(DFunDef false "cutRanges" ((PVar "lo") (PVar "hi") (PCons (PTuple (PVar "a") (PVar "b")) (PVar "rest"))) (EBinOp "++" (EIf (EBinOp ">" (EVar "a") (EVar "lo")) (EListLit (ETuple (EVar "lo") (EVar "a"))) (EListLit)) (EApp (EApp (EApp (EVar "cutRanges") (EApp (EApp (EMethodRef "max") (EVar "lo")) (EVar "b"))) (EVar "hi")) (EVar "rest"))))
(DTypeSig false "moduleStampOrder" (TyApp (TyCon "List") (TyCon "StampStep")))
(DFunDef false "moduleStampOrder" () (EListLit (EVar "SSNumlitFloats") (EVar "SSReturnSites") (EVar "SSBinopSites") (EVar "SSUnopSites") (EVar "SSArithSites") (EVar "SSArgStamps") (EVar "SSRLocalSites") (EVar "SSRecDictApps") (EVar "SSDictApps") (EVar "SSMethodDicts")))
(DTypeSig false "isLiveSpan" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Bool"))))
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
(DTypeSig false "spanKeys" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "spanKeys" ((PList)) (EListLit))
(DFunDef false "spanKeys" ((PCons (PCon "None") (PVar "rest"))) (EApp (EVar "spanKeys") (EVar "rest")))
(DFunDef false "spanKeys" ((PCons (PVar "loc") (PVar "rest"))) (EBinOp "::" (EApp (EVar "locKey") (EVar "loc")) (EApp (EVar "spanKeys") (EVar "rest"))))
(DTypeSig false "isInterfaceDecl" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isInterfaceDecl" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "isInterfaceDecl") (EVar "d")))
(DFunDef false "isInterfaceDecl" ((PRec "DInterface" () false)) (EVar "True"))
(DFunDef false "isInterfaceDecl" (PWild) (EVar "False"))
(DTypeSig true "enqueueStampCtx" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))))
(DFunDef false "enqueueStampCtx" ((PVar "mctx") (PVar "mid") (PVar "implDecls")) (EBlock (DoLet false false (PVar "mk") (EApp (EApp (EVar "currentModuleMarks") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (DoLet false false (PVar "ctx") (EApp (EApp (EApp (EApp (EApp (EVar "stampCtxOf") (EVar "mctx")) (EVar "mid")) (EVar "implDecls")) (EApp (EApp (EVar "goalsSince") (EFieldAccess (EVar "mctx") "mcGraph")) (EFieldAccess (EVar "mk") "mGoals"))) (EApp (EApp (EVar "numlitSince") (EFieldAccess (EVar "mctx") "mcGraph")) (EFieldAccess (EVar "mk") "mNumlit")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "stampCtxs")) (EBinOp "::" (EVar "ctx") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "stampCtxs") "value"))))))
(DTypeSig false "stampNoting" (TyFun (TyCon "ModuleCtx") (TyFun (TyFun (TyCon "SiteCtx") (TyFun (TyCon "Obligation") (TyCon "Unit"))) (TyFun (TyCon "Obligation") (TyCon "Unit")))))
(DFunDef false "stampNoting" ((PVar "stamp") (PVar "resolve") (PVar "o")) (EBlock (DoLet false false (PVar "acc") (EApp (EVar "Ref") (EVar "innerNone"))) (DoExpr (EApp (EApp (EVar "resolve") (ERecordUpdate (EApp (EVar "siteFor") (EVar "stamp")) ((fa "sxInner" (EApp (EVar "Some") (EVar "acc")))))) (EVar "o"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "o") "oInner")) (EApp (EApp (EVar "innerOr") (EFieldAccess (EFieldAccess (EVar "o") "oInner") "value")) (EFieldAccess (EVar "acc") "value"))))))
(DTypeSig false "runStampStep" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "StampCtx") (TyFun (TyCon "StampStep") (TyCon "Unit")))))
(DFunDef false "runStampStep" ((PVar "_mctx") (PVar "ctx") (PCon "SSNumlitFloats")) (EApp (EVar "setNumlitFloatsGo") (EFieldAccess (EVar "ctx") "scNumlits")))
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
(DTypeSig false "judgeEvidence" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "StampCtx")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))))))
(DFunDef false "judgeEvidence" ((PVar "gctx") (PVar "ctxs")) (EBlock (DoLet false false (PVar "g") (EFieldAccess (EVar "gctx") "graphRun")) (DoLet false false (PVar "lo") (EFieldAccess (EFieldAccess (EVar "g") "evJudged") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "evJudged")) (EFieldAccess (EFieldAccess (EVar "g") "evCounter") "value"))) (DoLet false false (PVar "base") (EFieldAccess (EVar "g") "evBase")) (DoLet false false (PVar "cellHoles") (EApp (EApp (EDictApp "flatMap") (ELam ((PTuple (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EApp (EVar "judgeCells") (EFieldAccess (EFieldAccess (EVar "g") "evCells") "value")) (EBinOp "-" (EVar "a") (EVar "base"))) (EBinOp "-" (EVar "b") (EVar "base"))) (EListLit)))) (EApp (EApp (EApp (EVar "unjudgedRanges") (EVar "lo")) (EFieldAccess (EFieldAccess (EVar "g") "evCounter") "value")) (EFieldAccess (EFieldAccess (EVar "g") "evScopedJudged") "value")))) (DoLet false false (PVar "goalHoles") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "c")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "judgeGoal") (EFieldAccess (EVar "c") "scModule"))) (EFieldAccess (EVar "c") "scGoals")))) (EVar "ctxs"))) (DoExpr (EApp (EApp (EVar "dedupBy") (EVar "holeKey")) (EBinOp "++" (EVar "cellHoles") (EVar "goalHoles"))))))
(DTypeSig false "holeKey" (TyFun (TyTuple (TyCon "String") (TyCon "TcDiag")) (TyCon "String")))
(DFunDef false "holeKey" ((PTuple (PVar "m") (PCon "TcDiag" PWild PWild (PVar "loc") (PVar "msg") PWild PWild))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "$core.display") (EApp (EVar "lenKey") (EVar "m")))) (ELit (LString ""))) (EApp (EVar "$core.display") (EApp (EVar "lenKey") (EApp (EVar "locGoalKey") (EVar "loc"))))) (ELit (LString ""))) (EApp (EVar "$core.display") (EVar "msg"))) (ELit (LString ""))))
(DTypeSig false "judgeCells" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvCell"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))))))))
(DFunDef false "judgeCells" ((PVar "arr") (PVar "i0") (PVar "hi") (PVar "acc0")) (ELetGroup ((lgb "go" (clause ((PVar "i") (PVar "acc")) (EIf (EBinOp "||" (EBinOp ">=" (EVar "i") (EVar "hi")) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr")))) (EVar "acc") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (arm (PCon "Some" (PVar "c")) () (EMatch (EFieldAccess (EFieldAccess (EVar "c") "ecArity") "value") (arm (PCon "Some" PWild) () (EBlock (DoLet false false (PVar "row") (EApp (EApp (EApp (EApp (EApp (EVar "OccurrenceRow") (EFieldAccess (EFieldAccess (EVar "c") "ecName") "value")) (EFieldAccess (EFieldAccess (EVar "c") "ecIface") "value")) (EFieldAccess (EFieldAccess (EVar "c") "ecTag") "value")) (EFieldAccess (EFieldAccess (EVar "c") "ecImpl") "value")) (EFieldAccess (EFieldAccess (EVar "c") "ecMeth") "value"))) (DoExpr (EApp (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "holeDiags") (EApp (EVar "evIdModule") (EFieldAccess (EVar "c") "ecId"))) (EFieldAccess (EFieldAccess (EVar "c") "ecLoc") "value")) (EFieldAccess (EFieldAccess (EVar "c") "ecInner") "value")) (EVar "row")) (EVar "acc")))))) (arm (PCon "None") () (EApp (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc"))))) (arm (PCon "None") () (EApp (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))) (EApp (EApp (EVar "go") (EVar "i0")) (EVar "acc0"))))
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
(DFunDef false "cellHeadKey" ((PVar "n") (PCon "OriginBuiltin")) (EBinOp "++" (EBinOp "++" (ELit (LString "builtin|")) (EApp (EVar "$core.display") (EVar "n"))) (ELit (LString ""))))
(DFunDef false "cellHeadKey" ((PVar "n") (PCon "OriginUnresolved")) (EBinOp "++" (EBinOp "++" (ELit (LString "unresolved|")) (EApp (EVar "$core.display") (EVar "n"))) (ELit (LString ""))))
(DFunDef false "cellHeadKey" ((PVar "n") (PCon "OriginModule" (PVar "m"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "module ")) (EApp (EVar "$core.display") (EVar "m"))) (ELit (LString "|"))) (EApp (EVar "$core.display") (EVar "n"))) (ELit (LString ""))))
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
