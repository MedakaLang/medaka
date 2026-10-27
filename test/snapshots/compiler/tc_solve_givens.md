# META
source_lines=1040
stages=DESUGAR,MARK
# SOURCE
-- tc_solve_givens: the given and assumption store of the solver: registering, scoping and answering
-- from givens and assumptions, including the active-dictionary assumption writers
-- (`registerEachActive`, `registerActiveDictVars`).
--
-- Spec: DICT section 3 (assumptions); TYPECHECK-CONTRACTS section 3 (givens).
--
-- Placement: declarations are placed by R1-R6 of the Phase 4 module table,
-- compiler/ARCHITECTURE-PLAYBOOK.md section 6.
-- Closure rule: this module may not import `types.typecheck`, nor any of `tc_solve_entail`,
-- `tc_solve`, `tc_solve_check`, `tc_shadow`, `tc_effects`, `tc_occurrence`, `tc_groups`, `tc_pat`,
-- `tc_infer_records`, `tc_infer`, `tc_elab`, `tc_global`, `tc_module`.

import types.tc_types.{
  AssumAnswer(..),
  AssumptionTraceEntry(..),
  AssumptionTraceKind(..),
  GivenEntry(..),
  GivenMatch(..),
  GivenProvenance(..),
  GivenScope(..),
  PredicateRequest(..),
  PredicateSlot(..),
  PredicateSlotArgs(..),
  GraphCtx,
  MethodBodyInstance,
  ModuleCtx,
}
import types.tc_mono.{
  containsI,
  dedupI,
  isBareTyvarMono,
  monoTyvarIds,
  monoVecSameGiven,
  peelQual,
  tyvarId,
  oblArgKey,
}
import types.tc_state.{currentScopeStore, renderEvidenceBinder}
import types.tc_env.{
  methodLevelConstraintVarNames, oblIfaceKey, sameIfaceDecl, superLookup
}
import types.tc_decls_types.{fromAstType}
import types.tc_decls.{constraintIface, constraintIsMethodLevel}
import frontend.ast.{
  TyConOrigin(..),
  Constraint(..),
  Route(..),
  Super(..),
  Ty(..),
}
import types.evidence.{EvidenceBinderId(..), ScopeId(..), SolverEvidence(..)}
import types.repr.{IfaceRef(..), Mono(..), lookupAssocI, normalize}
import support.ordmap.{omInsert, omLookup, OrdMap}
import types.superclass.{SuperNode(..), lookupPos, mapAll, superClosure}
import support.util.{allList, isSome, listLen, lookupAssoc, orElseOpt}
import list.{drop, elemIndex}
import string.{join}
import types.registry.{regKeyOfTab, regKeyRender}
import types.scopes as Scopes

-- B-4 producer migration: pure legacy projections at reader seams.  Mutable state
-- stores only `PredicateSlot`; ids, ifaces and the known argument-vector prefix are
-- derived on demand so they cannot drift into separate authorities again.
export
predicateSlotIds : List PredicateSlot -> List Int
predicateSlotIds [] = []
predicateSlotIds (s :: rest) = match s.psBoundIds
  [] => predicateSlotIds rest
  id :: _ => id :: predicateSlotIds rest

-- `idx` is the first-wins index `funPredicateSlotsIdxRef` mirrors from `funPredicateSlotsRef`.
export
lookupPredicateSlots : String ->
  OrdMap (List PredicateSlot) ->
  Option (List PredicateSlot)
lookupPredicateSlots k idx = omLookup k idx

export
predicateSlotIdsAt : String -> OrdMap (List PredicateSlot) -> List Int
predicateSlotIdsAt name idx = predicateSlotIds (optionOr [] (omLookup name idx))

assumAnswerBinder : AssumAnswer -> EvidenceBinderId
assumAnswerBinder (SemanticGiven evidence) = givenEvidenceBinder evidence
assumAnswerBinder (LegacyScalar binder) = binder
assumAnswerBinder (LegacyPredicate binder) = binder
assumAnswerBinder (LegacyProjected binder _) = binder

-- The evidence an assumption answer denotes.  A legacy answer has no semantic evidence
-- beyond the binder it routes through.
export
assumAnswerEvidence : AssumAnswer -> SolverEvidence
assumAnswerEvidence (SemanticGiven evidence) = evidence
assumAnswerEvidence (LegacyScalar binder) = GivenEvidence binder
assumAnswerEvidence (LegacyPredicate binder) = GivenEvidence binder
assumAnswerEvidence (LegacyProjected binder path) =
  SuperclassEvidence binder path

assumAnswerKind : AssumAnswer -> AssumptionTraceKind
assumAnswerKind (SemanticGiven (SuperclassEvidence _ _)) =
  ATSuperclassProjection
assumAnswerKind (SemanticGiven _) = ATDirectPredicate
assumAnswerKind (LegacyScalar _) = ATLegacyScalar
assumAnswerKind (LegacyPredicate _) = ATLegacyPredicate
assumAnswerKind (LegacyProjected _ _) = ATLegacyPredicate

-- The dict parameter that carries given-rooted evidence.  A superclass projection of a
-- given reads its parent's parameter: the super is a field of that dictionary
-- (`givenEvidenceRoute`), never selected again.
givenEvidenceBinder : SolverEvidence -> EvidenceBinderId
givenEvidenceBinder (GivenEvidence binder) = binder
givenEvidenceBinder (SuperclassEvidence parent _) = parent
givenEvidenceBinder _ = panic "non-given assumption evidence"

-- The route an assumption answer lowers to, reading its binder's parameter as
-- [paramRoute] renders it: a projection answer projects the parameter's dictionary
-- onto the super.  A scalar answer (a tyvar-keyed rung, which cannot say which
-- predicate it answered) whose binder's own predicate is a SUB-interface of the
-- goal's [goalIface] is projected the same way, along the first superclass path from
-- the binder's interface to the goal's.
export
assumAnswerRoute : GraphCtx ->
  AssumAnswer ->
  Option IfaceRef ->
  ScopeId ->
  (String -> Route) ->
  Route
assumAnswerRoute gctx (SemanticGiven (SuperclassEvidence parent path)) _ _ paramRoute =
  RProj (paramRoute (renderEvidenceBinder gctx parent)) path
assumAnswerRoute gctx (LegacyProjected parent path) _ _ paramRoute =
  RProj (paramRoute (renderEvidenceBinder gctx parent)) path
assumAnswerRoute gctx (LegacyScalar binder) (Some goalIface) useScope paramRoute =
  let base = paramRoute (renderEvidenceBinder gctx binder)
  match scalarGivenProjection gctx binder goalIface useScope
    Some path => RProj base path
    None => base
assumAnswerRoute gctx answer _ _ paramRoute =
  paramRoute (renderEvidenceBinder gctx (assumAnswerBinder answer))

-- The direct-super path from the predicate [binder] declares to [goalIface], when the
-- two differ.  Matched by spelling: a goal from a bare-named producer carries no
-- origin, and within one interface's superclass closure a spelling names one node.
scalarGivenProjection : GraphCtx ->
  EvidenceBinderId ->
  IfaceRef ->
  ScopeId ->
  Option (List Int)
scalarGivenProjection gctx binder goalIface useScope =
  match directGivenIfaceOf binder (givensForScope gctx useScope)
    None => None
    Some declared =>
      if declared.irName == goalIface.irName then
        None
      else
        map
          (n => drop 1 n.superPath)
          (find
            (n => n.superIface.irName == goalIface.irName)
            (superClosure
              (superLookup gctx)
              (_ _ _ => Some ())
              (ir _ => regKeyRender (regKeyOfTab (oblIfaceKey ir)))
              [(declared, ())]))

-- Whether the tyvar-keyed binder [binder] can answer a goal of [goalIface]: its own
-- predicate is the goal's interface or has it as a superclass.  A binder with no
-- recorded direct given, or a goal with no interface, is not constrained here.  The
-- interfaces compare by declaration identity; a goal still carrying no origin (the
-- #1318 residual, #3534) can only be compared by spelling.
export
scalarGivenAnswers : GraphCtx -> EvidenceBinderId -> IfaceRef -> ScopeId -> Bool
scalarGivenAnswers gctx binder goalIface useScope =
  goalIface.irName == ""
    || (match directGivenIfaceOf binder (givensForScope gctx useScope)
      None => True
      Some declared =>
        sameIfaceOrUnresolved declared goalIface
          || isSome (scalarGivenProjection gctx binder goalIface useScope))

sameIfaceOrUnresolved : IfaceRef -> IfaceRef -> Bool
sameIfaceOrUnresolved a b = match (a.irOrigin, b.irOrigin)
  (OriginUnresolved, _) => a.irName == b.irName
  (_, OriginUnresolved) => a.irName == b.irName
  _ => sameIfaceDecl a b

directGivenIfaceOf : EvidenceBinderId -> List GivenEntry -> Option IfaceRef
directGivenIfaceOf _ [] = None
directGivenIfaceOf binder (g :: rest)
  | g.geBinder == binder && g.geProvenance == DirectGiven =
    Some g.geSlot.psIface
  | otherwise = directGivenIfaceOf binder rest

export
projectedGivenOf : GraphCtx -> EvidenceBinderId -> List Int -> Option GivenEntry
projectedGivenOf gctx parent path =
  find
    (g => g.geProvenance == ProjectedGiven parent path)
    (givensForScope gctx (Scopes.binderScope parent))

export
noteAssumption : GraphCtx -> ScopeId -> AssumAnswer -> Unit
noteAssumption gctx scope answer = match gctx.trace
  Some sink =>
    if sink.tsAssumptionEnabled then
      sink.tsAssumptionEntries :=
        AssumptionTraceEntry {
            atGoalScope = scope,
            atBinder = assumAnswerBinder answer,
            atKind = assumAnswerKind answer,
          }
          :: sink.tsAssumptionEntries.value
  None => ()

-- #2547 unit 3: the givens of [sid]'s module.  The module id is the scope frame's,
-- minted with the frame, so a replayed or restored scope keeps its key with it.
export
givensForScope : GraphCtx -> ScopeId -> List GivenEntry
givensForScope gctx sid =
  optionOr
    []
    (omLookup
      (Scopes.scopeFrame (currentScopeStore gctx ()) sid).sfModuleId
      gctx.graphRun.gGiven.value)

-- The ONE given write.  Newest first, as both retired tables were, so every reader's
-- first-match order is the write order it had before.
export
pushGiven : GraphCtx ->
  GivenMatch ->
  GivenProvenance ->
  PredicateSlot ->
  EvidenceBinderId ->
  Unit
pushGiven gctx gm provenance slot binder =
  let mid =
    (Scopes.scopeFrame
      (currentScopeStore gctx ())
      (Scopes.binderScope binder)).sfModuleId
  let entry = GivenEntry {
    geSlot = slot,
    geBinder = binder,
    geMatch = gm,
    geProvenance = provenance,
  }
  gctx.graphRun.gGiven :=
    omInsert
      mid
      (entry :: optionOr [] (omLookup mid gctx.graphRun.gGiven.value))
      gctx.graphRun.gGiven.value

export
givenInScope : GivenScope -> GivenEntry -> Bool
givenInScope GSPredicateOnly g = match g.geMatch
  GMPredicate => True
  GMIdWitnessed => False
givenInScope GSImplRequires g = match g.geMatch
  GMIdWitnessed => True
  GMPredicate => False

export
givenRoute : GraphCtx -> Bool -> EvidenceBinderId -> Route
givenRoute gctx isReturnPosition binder =
  if isReturnPosition then
    RDictFwd (renderEvidenceBinder gctx binder)
  else
    RDict (renderEvidenceBinder gctx binder)

-- if [m] normalizes to a registered constraint variable, the dict parameter name
-- a method at that type reads.  A return-position method at a HIGHER-KINDED
-- constraint var (`pure : a -> m a`, so the result mono is `m Unit` = TApp (TVar
-- m) Unit) carries the dict var in the application HEAD, not at top level — recurse
-- through TApp to find it.  (A concrete head, e.g. `Option Unit` after unification,
-- is a TCon and falls through to None → RKey, unchanged.)
--
-- The lookup is lexical.  `registerImplRequires` registers every method of an impl
-- under the same impl tyvar id (`impl Ord (List a)` registers `a` once per
-- compare/lt/gt/min/max/…).  Each entry carries the exact body scope that owns its
-- slot.  The occurrence's captured scope may read that owner or an ancestor and
-- rejects every sibling; generated dictionary spellings play no part in selection,
-- and neither does the enclosing declaration's name: a site in a test or prop body,
-- which has none, still sees the givens of a local binding it sits in.
export
activeDictVarOf : GraphCtx -> Mono -> ScopeId -> Option EvidenceBinderId
activeDictVarOf gctx m useScope = match peelQual m
  TVar cell =>
    firstDictForEncl
      gctx
      (tyvarId cell)
      useScope
      gctx.graphRun.activeDictVars.value
  TApp a _ => activeDictVarOf gctx a useScope
  _ => None

-- The lexical active-dict lookup restricted to binders [answers] accepts: the
-- registry keeps every binder registered for the variable, most recent first.
export
activeDictVarAnswering : GraphCtx ->
  Mono ->
  ScopeId ->
  (EvidenceBinderId -> Bool) ->
  Option EvidenceBinderId
activeDictVarAnswering gctx m useScope answers = match peelQual m
  TVar cell =>
    find
      (b => answers b)
      (visibleDictsFor
        gctx
        (tyvarId cell)
        useScope
        gctx.graphRun.activeDictVars.value)
  TApp a _ => activeDictVarAnswering gctx a useScope answers
  _ => None

visibleDictsFor : GraphCtx ->
  Int ->
  ScopeId ->
  List (Int, EvidenceBinderId) ->
  List EvidenceBinderId
visibleDictsFor gctx _ _ [] = []
visibleDictsFor gctx id useScope ((eid, binder) :: rest)
  | eid == id
    && Scopes.givenVisibleFrom
      (currentScopeStore gctx ())
      useScope
      (Scopes.binderScope binder) =
    binder :: visibleDictsFor gctx id useScope rest
  | otherwise = visibleDictsFor gctx id useScope rest

firstDictForEncl : GraphCtx ->
  Int ->
  ScopeId ->
  List (Int, EvidenceBinderId) ->
  Option EvidenceBinderId
firstDictForEncl gctx _ _ [] = None
firstDictForEncl gctx id useScope ((eid, binder) :: rest)
  | eid == id
    && Scopes.givenVisibleFrom
      (currentScopeStore gctx ())
      useScope
      (Scopes.binderScope binder) = Some binder
  | otherwise = firstDictForEncl gctx id useScope rest

-- activeDictVarOf, but for a constraint var that is the ENCLOSING fn's OWN constraint
-- var, return [encl]'s in-scope dict param (the slot it sits at) rather than the
-- GLOBAL activeDictVars entry.  In a mutually-recursive group the constraint vars of
-- the siblings unify to one id; activeDictVars (global, uncleared) maps that id to
-- whichever sibling registered it LAST — so an arg-stamp inside `evenCat` would
-- forward `$dict_oddCat_0` (out of scope in evenCat's body).  Preferring encl's own
-- slot keeps the forwarded dict the one actually bound in the body.  A miss is None;
-- evidence owned by a different impl is not in scope here.
-- #1177: [goal] is the PREDICATE the use site has to discharge (its interface, and
-- the instantiated argument vector when the occurrence let one be recovered), NOT
-- just the constraint var — see `enclDictVarOf`.  `None` selects the legacy scalar
-- lookup, still bounded by the same lexical owner.
export
activeDictVarOfEncl : ModuleCtx ->
  Option PredicateRequest ->
  Mono ->
  String ->
  ScopeId ->
  Option AssumAnswer
activeDictVarOfEncl mctx None m encl useScope =
  map LegacyScalar (activeDictVarOf mctx.mcGraph m useScope)
activeDictVarOfEncl mctx (Some request) m encl useScope =
  -- A complete predicate request is terminal: a miss must not be overwritten by
  -- the scalar tyvar-id registry, whose key cannot distinguish declarations or
  -- complete argument vectors.  The None arm above is the legacy scalar control.
  orElseOpt
    (map LegacyScalar (enclDictVarOf mctx (Some request) m encl useScope))
    (implReqDictVarOf mctx.mcGraph (Some request) m useScope)

-- #1154 residual: an impl-`requires` site is resolved by its predicate, not by its
-- CONSTRAINT VAR'S ID — the same rule #1177 established for the SIGNATURE `=>` channel,
-- on the channel #1177 did not reach.  `registerReqSlots` opens one dict slot per
-- `requires` ENTRY but keys `activeDictVars` on the tyvar ids INSIDE the entry, so
-- `impl Sh (Box a) requires Ix a Char, Dbg2 a` registers `a`'s id TWICE — once per slot.
-- `firstDictForEncl` then scans a cons-list whose head is the LAST registration, so
-- EVERY method use in the body read the LAST slot: `ix x 'z'` read the `Dbg2` dict, its
-- route degraded, and first-declared-`impl Ix` won.  MEASURED on the typed Core IR dump
-- at this slice's base — `sh`'s body lowered to `CMethod "ix" (RDict "$dict_sh_1")` and
-- `CMethod "dbg2" (RDict "$dict_sh_1")`, with `$dict_sh_0` bound and never read — which
-- is why moving the `Ix` entry to the END of the `requires` list (a meaning-preserving
-- edit) moved the answer from 116 to the correct 227.
--
-- This is not the `argReqRoute`/`EKNestedTop` GOAL-vector seam, and that seam is not
-- BROKEN.  The routes handed to the call site are already correct at every position
-- (`(RKey "Ix|Int Char|") (RKey "Int")`, in `requires` order); the loss is entirely on
-- the CONSUMPTION side, in which slot the impl BODY reads.  A fix aimed at the routing
-- ladder would have moved nothing.
--
-- A complete request uses one exact pass.  A miss is terminal at
-- `activeDictVarOfEncl`; only an explicit no-predicate route may consult scalar state.
--
-- #2547 unit 3: the scan is `firstPredForEnclAt` — the id-gated given lookup — not a
-- private `implReqPick`.  The two were term-for-term the same test over the same pair in
-- opposite tuple orders; one given environment leaves one of them.
export
implReqDictVarOf : GraphCtx ->
  Option PredicateRequest ->
  Mono ->
  ScopeId ->
  Option AssumAnswer
implReqDictVarOf gctx None _ _ = None
implReqDictVarOf gctx (Some request) m useScope = match peelQual m
  TVar cell =>
    firstPredForEnclAt
      gctx
      GSImplRequires
      (tyvarId cell)
      request
      useScope
      (givensForScope gctx useScope)
  TApp a _ => implReqDictVarOf gctx (Some request) a useScope
  _ => None

-- #1177: A use site is resolved by its predicate, not by its constraint var'S ID.
-- A function's slots are one per predicate, each carrying its variables' ids, so a
-- context naming two interfaces over ONE type variable — `useIx : (Dbg a, Ix a Char) => a -> Int` —
-- registers TWO slots carrying the SAME id.  A lookup by `elemIndex (tyvarId cell) ids`
-- would take its FIRST match, slot 0 whichever predicate the site belongs to, so EVERY
-- method use in the body would read slot 0: `ix` would read the `Dbg` dict, its route
-- would degrade to the bare head tag, and first-declared-`impl` would win.  Swapping the
-- two predicates — a meaning-preserving edit — would then move the answer from 116 to the
-- correct 227, on both engines, at exit 0, with `check --json` clean.
--
-- `funPredicateSlotsRef` carries the authoritative slots in order, so this lookup
-- never has to reconstruct a predicate from parallel scalar tables.
export
enclDictVarOf : ModuleCtx ->
  Option PredicateRequest ->
  Mono ->
  String ->
  ScopeId ->
  Option EvidenceBinderId
enclDictVarOf mctx goal m encl useScope
  | encl == "" = None
  | otherwise = match peelQual m
    TVar cell =>
      map
        (Scopes.binderAt
          (Scopes.declarationScope
            (currentScopeStore mctx.mcGraph ())
            useScope))
        (enclSlotIndex mctx goal (tyvarId cell) encl)
    TApp a _ => enclDictVarOf mctx goal a encl useScope
    _ => None

-- the slot index [target]'s dict param sits at in [encl]'s own constraint slots:
-- by PREDICATE when the goal supplies one and a slot answers it, else the historical
-- first-tyvar-id match.
enclSlotIndex : ModuleCtx ->
  Option PredicateRequest ->
  Int ->
  String ->
  Option Int
enclSlotIndex mctx None target encl = elemIndex target (enclSlotIds mctx encl)
enclSlotIndex mctx (Some request) target encl =
  indexOfPred target request (enclPreds mctx encl)

enclSlotIds : ModuleCtx -> String -> List Int
enclSlotIds mctx encl =
  predicateSlotIdsAt encl mctx.mcCells.funPredicateSlotsIdxRef.value

-- [encl]'s own constraint slots as PREDICATES, in slot order: each slot's interface
-- and the argument vector its signature recorded, paired with every bound tyvar id.
enclPreds : ModuleCtx -> String -> List PredicateSlot
enclPreds mctx encl =
  optionOr
    []
    (lookupPredicateSlots encl mctx.mcCells.funPredicateSlotsIdxRef.value)

-- Stable one-pass predicate lookup.  Known/Known vector disagreement cannot downgrade
-- to interface-only or scalar matching.
indexOfPred : Int -> PredicateRequest -> List PredicateSlot -> Option Int
indexOfPred target request preds = indexOfPredGo 0 target request preds

indexOfPredGo : Int ->
  Int ->
  PredicateRequest ->
  List PredicateSlot ->
  Option Int
indexOfPredGo _ _ _ [] = None
indexOfPredGo i target request (sp :: rest)
  | containsI target sp.psBoundIds && predicateRequestMatchesSlot request sp =
    Some i
  | otherwise = indexOfPredGo (i + 1) target request rest

-- The single request/slot routing relation.  Declaration identity is complete and
-- fail-closed.  Known vectors compare recursively at every position; interface-only
-- compatibility is available only when at least one side explicitly says Unknown.
export
predicateRequestMatchesSlot : PredicateRequest -> PredicateSlot -> Bool
predicateRequestMatchesSlot request slot =
  request.prIface.irName /= ""
    && slot.psIface.irName /= ""
    && sameIfaceDecl request.prIface slot.psIface
    && predicateRequestArgsMatch request.prArgs slot.psArgs

predicateRequestArgsMatch : PredicateSlotArgs -> PredicateSlotArgs -> Bool
predicateRequestArgsMatch (PSArgsKnown requestArgs) (PSArgsKnown slotArgs) =
  monoVecSameGiven requestArgs slotArgs
predicateRequestArgsMatch _ _ = True

-- the dict-param slot at which [m]'s tyvar sits among the enclosing fn's
-- constraint ids (its position in `funPredicateSlotsRef`'s slots for [encl] = the kept slot)
export
enclSlot : ModuleCtx -> String -> Mono -> Option Int
enclSlot mctx encl m = match normalize m
  TVar cell =>
    elemIndex
      (tyvarId cell)
      (predicateSlotIdsAt encl mctx.mcCells.funPredicateSlotsIdxRef.value)
  _ => None

methodLevelPredicateSlots : ModuleCtx ->
  List String ->
  Ty ->
  List (String, Mono) ->
  List PredicateSlot
methodLevelPredicateSlots mctx typarams (TyConstrained cs t) tvMap =
  flatMap (methodLevelPredicateSlot mctx typarams tvMap) cs
    ++ methodLevelPredicateSlots mctx typarams t tvMap
methodLevelPredicateSlots mctx typarams (TyEffect _ _ t) tvMap =
  methodLevelPredicateSlots mctx typarams t tvMap
methodLevelPredicateSlots mctx _ _ _ = []

methodLevelPredicateSlot : ModuleCtx ->
  List String ->
  List (String, Mono) ->
  Constraint ->
  List PredicateSlot
methodLevelPredicateSlot mctx typarams tvMap c
  | not (constraintIsMethodLevel typarams c) = []
  | otherwise =
    let args = map (fromAstType mctx tvMap) c.constraintArgs
    [
      PredicateSlot {
        psIface = IfaceRef {
          irName = constraintIface c,
          irOrigin = c.constraintOrigin,
        },
        psArgs = PSArgsKnown args,
        psBoundIds = dedupI (flatMap monoTyvarIds args),
      },
    ]

export
goalGivenAt : GraphCtx -> IfaceRef -> List Mono -> ScopeId -> Bool
goalGivenAt gctx iface args scope =
  isSome
      (activeFunDictPredOf
        gctx
        PredicateRequest { prIface = iface, prArgs = PSArgsKnown args }
        scope)
    || goalMatchesGiven gctx scope iface args

-- register, per slot, the default body's constraint var id → `$dict_<method>_<slot>`
-- in activeDictVars, so an in-body method ref unified to that var routes RDict.
-- Run AFTER body inference so the id is the SURVIVING (normalized) union-find root —
-- the same id the in-body site normalizes to (mirrors registerImplRequires).
export
registerMethodDictSlots : GraphCtx ->
  ScopeId ->
  Int ->
  List Int ->
  List (Int, Mono) ->
  Unit
registerMethodDictSlots gctx _ _ [] _ = ()
registerMethodDictSlots gctx scope slot (id :: rest) subst =
  registerOneMethodDict gctx scope slot id subst
  registerMethodDictSlots gctx scope (slot + 1) rest subst

registerOneMethodDict : GraphCtx ->
  ScopeId ->
  Int ->
  Int ->
  List (Int, Mono) ->
  Unit
registerOneMethodDict gctx scope slot id subst = match lookupAssocI id subst
  None => ()
  Some m => match normalize m
    TVar cell =>
      gctx.graphRun.activeDictVars :=
        (tyvarId cell, Scopes.binderAt scope slot)
          :: gctx.graphRun.activeDictVars.value
    _ => ()

-- The method's own `=>` context, given in the body's scope with its supers.
export
publishMethodPredGivens : ModuleCtx ->
  List String ->
  Ty ->
  MethodBodyInstance ->
  ScopeId ->
  Unit
publishMethodPredGivens mctx params mty inst scope =
  registerSlotPredGivens
    mctx.mcGraph
    scope
    0
    (methodLevelPredicateSlots mctx params mty inst.mbiNamedVars)

export
givenAnswers : IfaceRef -> List Mono -> PredicateSlot -> Bool
givenAnswers iface args slot =
  sameIfaceDecl slot.psIface iface
    && (match slot.psArgs
      PSArgsKnown gargs => monoVecSameGiven gargs args
      PSArgsUnknown => False)

-- Register an impl method's OWN method-level constraints (`Thenable m => …`) into
-- activeDictVars, one slot per constraint, so a return-position method in the impl
-- body whose result type is the constraint var routes RDictFwd $dict_<mname>_<slot>.
-- [tvMap] maps the method type's tyvar names → the monos expected/the body unified
-- against; normalize each to its surviving root before registering.  Slot numbering
-- matches methodConstraintSlotIds (same flatMap order), so it lines up with
-- implDictPassMethods' prepended params and the call-site methodRoutes
-- resolveMethodDicts fills.
export
registerImplMethodDicts : GraphCtx ->
  ScopeId ->
  List String ->
  Ty ->
  List (String, Mono) ->
  Unit
registerImplMethodDicts gctx scope ifaceParams mty tvMap =
  registerImplMethodDictsGo
    gctx
    scope
    0
    (methodLevelConstraintVarNames ifaceParams mty)
    tvMap

registerImplMethodDictsGo : GraphCtx ->
  ScopeId ->
  Int ->
  List String ->
  List (String, Mono) ->
  Unit
registerImplMethodDictsGo gctx _ _ [] _ = ()
registerImplMethodDictsGo gctx scope slot (vname :: rest) tvMap =
  registerImplMethodDictOne gctx scope slot vname tvMap
  registerImplMethodDictsGo gctx scope (slot + 1) rest tvMap

registerImplMethodDictOne : GraphCtx ->
  ScopeId ->
  Int ->
  String ->
  List (String, Mono) ->
  Unit
registerImplMethodDictOne gctx scope slot vname tvMap =
  match lookupAssoc vname tvMap
    None => ()
    Some m => match normalize m
      TVar cell =>
        gctx.graphRun.activeDictVars :=
          (tyvarId cell, Scopes.binderAt scope slot)
            :: gctx.graphRun.activeDictVars.value
      -- A slot over a structured head (`Show2 (Pair b)` in `impl Desc (Pair b)`) has
      -- no single var to key by id; publishMethodPredGivens's predicate-keyed given
      -- for the same slot answers the body's goal instead.
      _ => ()

-- #412: the PREDICATE-keyed half of the given registry.  `activeDictVars` above is keyed
-- by TYVAR ID, which cannot express a STRUCTURED given: `requires S (List a)` registers
-- only `a`'s id (monoTyvarIds descends to the leaves), and the goal `S (List a)` looks up
-- through `activeDictVarOf`, which recurses to the SPINE HEAD (`TCon "List"`) and finds no
-- tyvar — so `assum` was unreachable by construction and `entail` fell through to
-- `entailInst`, statically committing the body to the GENERAL instance and discarding the
-- most-specific dict the construction site had correctly built and passed.  DICT-SEMANTICS
-- §3 (assum before inst) + :155-166 (sub-evidence is never pre-baked at the declaration).
-- Keyed by (iface, WHOLE argument vector) so it is neither iface-blind nor
-- structure-blind, and matched by `monoVecSameGiven` — pointwise `monoSameGiven`,
-- structural, on rigid-tyvar IDENTITY, never unification.
--
-- #1956 / #1937: the key is the vector, not the lead argument.  Matching only
-- `[subject]` and returning `()` for any longer vector would leave a MULTI-PARAMETER
-- declared context (`f : Conv (Wrap a) b => …`) with no consumption-side answer at all:
-- `entailAssum` could never see it, `entail` would fall through to `entailInst`, and the
-- body would be statically committed to whichever impl was most specific at ABSTRACTION
-- time while the caller's correctly-built dict went unread — so `f (Wrap 5) True` and
-- `f (Wrap 'c') 7` would both take the SAME impl, and swapping the two `impl` blocks
-- would change which one, at exit 0 (DICT-SEMANTICS §3 forbids selection by declaration
-- order outright).
-- The answer to "when are two predicate argument vectors the same predicate?" IS
-- Pointwise structural identity over the vector: equal length, and `monoSameGiven` at
-- every position, in order.  `goalMatchesGiven`/`goalSlotStillOpen` follow this shape
-- exactly, and must keep following it — see their own headers.
--
-- §6.1.3's rigid commit is preserved TWICE OVER, and the guard below is the load-bearing
-- one: `requires S a` is a bare-tyvar given, so this writer registers nothing for it, and
-- the body's goal `S (List a)` finds no assumption ⇒ `inst` fires on the rigid goal ⇒ the
-- general instance ⇒ 2, unchanged.  Even had it been registered, `monoSameGiven` compares
-- structurally and would not match subject `a` against goal `List a` — only unification
-- would, and this is deliberately not unification.  Pinned by
-- test/build_diff_fixtures/impl_requires_structured_rigid_control.mdk.
--
-- #2547 unit 3: the guard is a `GivenMatch` decision now, not an absence.  The
-- all-bare vector this arm refuses IS in `gGiven` — `registerReqSlots` pushes it as
-- `GMIdWitnessed` — and what preserves the paragraph above is that every reader keyed on
-- predicate identity alone scans `GSPredicateOnly` and so cannot see it.  Both halves must
-- move together: pushing an all-bare vector as `GMPredicate`, or widening a
-- `GSPredicateOnly` rung, re-opens exactly what this guard closes.  Function carriers have
-- a distinct Known-slot writer (`registerSlotPredGivens`) because their complete
-- multi-parameter identity is required by EKNestedTop.
--
-- #1956 widens that sharp edge to more positions, and does not introduce a new one.
-- A vector like `[Wrap a, b]` is admitted because SOME position is structured, but its
-- SECOND position is a bare tyvar matched by raw id — the same `TVar`/`TVar` arm of
-- `monoSameGiven`, one position over.  The structured position still gates the whole
-- match (all positions must agree, so a stale-id coincidence at a bare position can only
-- matter for a goal that already agrees structurally elsewhere at the same interface),
-- which is why this is a widening of an existing hazard rather than a new one.  Removing
-- it is the same scoped-projection question `activeDictVarOf`'s `inImpl` gate answers,
-- and belongs with the key-side work (#1904), not here.
export
registerPredGiven : GraphCtx ->
  IfaceRef ->
  List Mono ->
  EvidenceBinderId ->
  Unit
registerPredGiven gctx _ [] _ = ()
registerPredGiven gctx iface args dname
  | allList isBareTyvarMono args = ()
  | otherwise =
    let slot = PredicateSlot {
      psIface = iface,
      psArgs = PSArgsKnown args,
      psBoundIds = dedupI (flatMap monoTyvarIds args),
    }
    pushGiven gctx GMPredicate DirectGiven slot dname

-- Assumption lookup over predicate-keyed givens.  The occurrence's captured
-- scope selects only its own or an ancestor's binder; generated dictionary names
-- and registration order across sibling bodies are irrelevant, and so is the
-- enclosing declaration's name.
export
activeDictPredOf : GraphCtx ->
  PredicateRequest ->
  Mono ->
  ScopeId ->
  Option AssumAnswer
activeDictPredOf gctx request targetMono useScope =
  let preds = givensForScope gctx useScope
  match request.prArgs
    PSArgsKnown _ => firstPredForEncl gctx request useScope preds
    PSArgsUnknown => match predicateTargetId targetMono
      Some target =>
        firstPredForEnclAt gctx GSPredicateOnly target request useScope preds
      None => None

predicateTargetId : Mono -> Option Int
predicateTargetId m = match peelQual m
  TVar cell => Some (tyvarId cell)
  TApp a _ => predicateTargetId a
  _ => None

-- Function-carrier predicate evidence is lexical: the occurrence's captured scope
-- reads only its own or an ancestor's givens, so a module's givens accumulating across
-- its functions cannot route evidence from a different body.
export
activeFunDictPredOf : GraphCtx ->
  PredicateRequest ->
  ScopeId ->
  Option AssumAnswer
activeFunDictPredOf gctx request useScope =
  firstPredForEncl gctx request useScope (givensForScope gctx useScope)

export
firstPredForEncl : GraphCtx ->
  PredicateRequest ->
  ScopeId ->
  List GivenEntry ->
  Option AssumAnswer
firstPredForEncl gctx request useScope givens =
  firstPredOnChain
    request
    (Scopes.visibleChain (currentScopeStore gctx ()) useScope)
    givens

firstPredOnChain : PredicateRequest ->
  List Int ->
  List GivenEntry ->
  Option AssumAnswer
firstPredOnChain _ _ [] = None
firstPredOnChain request chain (g :: rest)
  | givenInScope GSPredicateOnly g
    && Scopes.visibleOnChain chain (Scopes.binderScope g.geBinder)
    && predicateRequestMatchesSlot request g.geSlot =
    Some (givenAnswerForRequest request g)
  | otherwise = firstPredOnChain request chain rest

-- Semantic given evidence requires predicate-only eligibility, complete matched
-- vectors, and resolved declaration identities.  Id-witnessed, unknown-vector,
-- and unresolved-declaration paths keep their routing but remain legacy.
givenAnswerExact : GivenEntry -> AssumAnswer
givenAnswerExact g = match g.geProvenance
  DirectGiven => SemanticGiven (GivenEvidence g.geBinder)
  ProjectedGiven parent path => SemanticGiven (SuperclassEvidence parent path)

givenAnswerForRequest : PredicateRequest -> GivenEntry -> AssumAnswer
givenAnswerForRequest request g = match (
  request.prArgs,
  g.geSlot.psArgs,
  g.geMatch,
)
  (PSArgsKnown _, PSArgsKnown _, GMPredicate) => match (
    request.prIface.irOrigin,
    g.geSlot.psIface.irOrigin,
  )
    (OriginUnresolved, _) => givenAnswerResidual g
    (_, OriginUnresolved) => givenAnswerResidual g
    _ => givenAnswerExact g
  _ => givenAnswerResidual g

givenAnswerResidual : GivenEntry -> AssumAnswer
givenAnswerResidual g = match g.geProvenance
  DirectGiven => LegacyPredicate g.geBinder
  ProjectedGiven parent path => LegacyProjected parent path

-- The id-witnessed scan.  [scope] is the rung's own declaration of what it may read —
-- both rungs that reach here supply a tyvar-id witness, but only one of them is keyed on
-- the givens that REQUIRE it.  See `GivenScope`.
export
firstPredForEnclAt : GraphCtx ->
  GivenScope ->
  Int ->
  PredicateRequest ->
  ScopeId ->
  List GivenEntry ->
  Option AssumAnswer
firstPredForEnclAt gctx scope target request useScope givens =
  firstPredAtOnChain
    scope
    target
    request
    (Scopes.visibleChain (currentScopeStore gctx ()) useScope)
    givens

firstPredAtOnChain : GivenScope ->
  Int ->
  PredicateRequest ->
  List Int ->
  List GivenEntry ->
  Option AssumAnswer
firstPredAtOnChain _ _ _ _ [] = None
firstPredAtOnChain scope target request chain (g :: rest)
  | givenInScope scope g
    && containsI target g.geSlot.psBoundIds
    && Scopes.visibleOnChain chain (Scopes.binderScope g.geBinder)
    && predicateRequestMatchesSlot request g.geSlot =
    Some (givenAnswerForRequest request g)
  | otherwise = firstPredAtOnChain scope target request chain rest

-- Explicit #1318 EKNestedTop residual: this is the one spelling-keyed lookup retained
-- for a producer that can still supply OriginUnresolved.  Complete method requests do
-- not reach it.
export
activeFunDictPredOfResidual : GraphCtx ->
  String ->
  List Mono ->
  ScopeId ->
  Option AssumAnswer
activeFunDictPredOfResidual gctx iface args useScope =
  firstPredForEnclResidual
    gctx
    iface
    args
    useScope
    (givensForScope gctx useScope)

export
firstPredForEnclResidual : GraphCtx ->
  String ->
  List Mono ->
  ScopeId ->
  List GivenEntry ->
  Option AssumAnswer
firstPredForEnclResidual gctx _ _ _ [] = None
firstPredForEnclResidual gctx iface args useScope (g :: rest)
  | givenInScope GSPredicateOnly g
    && g.geSlot.psIface.irName == iface
    && Scopes.givenVisibleFrom
      (currentScopeStore gctx ())
      useScope
      (Scopes.binderScope g.geBinder)
    && predicateRequestArgsMatch (PSArgsKnown args) g.geSlot.psArgs =
    Some (givenAnswerResidual g)
  | otherwise = firstPredForEnclResidual gctx iface args useScope rest

export
registerEachActive : GraphCtx -> List Int -> EvidenceBinderId -> Unit
registerEachActive gctx [] _ = ()
registerEachActive gctx (id :: rest) dname =
  gctx.graphRun.activeDictVars :=
    (id, dname) :: gctx.graphRun.activeDictVars.value
  registerEachActive gctx rest dname

-- #1909: the SIGNATURE channel's `registerPredGiven` call — the one `registerReqSlots`
-- has made since #412 and this side never did.  `registerEachActive` above registers a
-- fn's declared `=>` given by TYVAR ID only, which cannot express a STRUCTURED given:
-- `Tag (Wrap a) => …` registers only `a`'s id, and the body's goal `Tag (Wrap a)` looks
-- up through `activeDictVarOf`, which recurses to the spine head (`TCon "Wrap"`) and
-- finds no tyvar — so `entailAssum` was unreachable by construction, `entail` fell to
-- `entailInst`, and the body was statically committed to whichever impl `entailInst`
-- picked against the ABSTRACTION-time goal, discarding the per-instantiation dict the
-- call site (`routesOfMonosTopV` → `pickMostSpecificEntry`) had already built correctly.
-- `registerPredGiven`'s header carries the same paragraph for the `requires` channel.
--
-- No selector is called here, and none may be: `typecheck.mdk`'s assum-rung rule is
-- that no selector call may be reachable from `entailAssum`.  This restores an EARLIER
-- rung's ability to answer; it does not re-select.
--
-- [slot] counts dict params the way `registerMemberSlots`' `kept` does, so the nth kept
-- slot gets `dictParamName m n`.  The vector list is legitimately a PREFIX of the slots
-- (`declaredPredicateSlots` stops when its vectors run out — see `setFunConstraintEntry`), so
-- the second clause stops early rather than inventing a subject for a vectorless slot.
export
registerSlotPredGivens : GraphCtx ->
  ScopeId ->
  Int ->
  List PredicateSlot ->
  Unit
registerSlotPredGivens gctx _ _ [] = ()
registerSlotPredGivens gctx scope slot (s :: srest) =
  registerFunPredGiven gctx s (Scopes.binderAt scope slot)
  registerSlotPredGivens gctx scope (slot + 1) srest

export
registerFunPredGiven : GraphCtx -> PredicateSlot -> EvidenceBinderId -> Unit
registerFunPredGiven gctx slot binder
  | slot.psIface.irName == "" = ()
  | otherwise =
    pushGiven gctx GMPredicate DirectGiven slot binder
    registerFunPredGivenSlots gctx (predicateSlotKnownSupers gctx slot) binder

-- A signature slot's supers share its dict parameter: the dictionary it receives
-- carries them, and a super is answered by projecting it (`givenEvidenceBinder`).
export
registerFunPredGivenSlots : GraphCtx ->
  List (PredicateSlot, List Int) ->
  EvidenceBinderId ->
  Unit
registerFunPredGivenSlots gctx [] _ = ()
registerFunPredGivenSlots gctx ((slot, path) :: rest) binder =
  pushGiven gctx GMPredicate (ProjectedGiven binder path) slot binder
  registerFunPredGivenSlots gctx rest binder

-- A dictionary supplied for one predicate also supplies every transitive
-- superinterface.  The original predicate is registered separately as direct evidence;
-- all aliases retain the SAME dict parameter, so this does not alter dict arity.
-- Prelude chains (`Thenable` -> `Applicative` -> `Mappable`) are evidence exactly as
-- user ones are.  Unknown vectors stay direct-only:
-- projecting a superclass argument without the sub-predicate's positional vector would
-- invent identity.
export
predicateSlotKnownSupers : GraphCtx ->
  PredicateSlot ->
  List (PredicateSlot, List Int)
predicateSlotKnownSupers gctx slot = match slot.psArgs
  PSArgsUnknown => []
  PSArgsKnown args =>
    map
      (n => (predicateSlotOfNode n, drop 1 n.superPath))
      (filter
        (n => listLen n.superPath > 1)
        (superClosure (superLookup gctx) predicateSuperStep predicateNodeKey [
          (slot.psIface, args),
        ]))

-- One predicate by interface identity and structural argument vector.
predicateNodeKey : IfaceRef -> List Mono -> String
predicateNodeKey iface monos =
  "\{regKeyRender (regKeyOfTab (oblIfaceKey iface))}|\{join "," (map oblArgKey monos)}"

predicateSuperStep : List String -> List Mono -> Super -> Option (List Mono)
predicateSuperStep typarams args (Super { superParams = params, ... })
  | listLen args /= listLen typarams = None
  | otherwise = mapAll (p => lookupPos p typarams args) params

predicateSlotOfNode : SuperNode (List Mono) -> PredicateSlot
predicateSlotOfNode n = PredicateSlot {
  psIface = n.superIface,
  psArgs = PSArgsKnown n.superPayload,
  psBoundIds = dedupI (flatMap monoTyvarIds n.superPayload),
}

-- is there an in-scope PREDICATE-keyed given that answers this goal exactly?
-- Deliberately `registerPredGiven`'s own shape — the WHOLE argument vector, structural,
-- matched by `monoVecSameGiven` (pointwise `monoSameGiven` on rigid/cell IDENTITY) rather
-- than by unification — because the question this gate asks is not "is the goal
-- plausible" but "will `entailAssum` be handed a dict for it".
-- This shape and `registerPredGiven`'s must move together, and #1956 is why both moved
-- In one step.  Widening the registry alone would let this gate keep answering False for
-- a multi-parameter goal the registry can now answer (a needless reject); widening this
-- gate alone would re-open exactly the S0-1 hole FIX-1 closed — a goal admitted to defer
-- with no consumption-side answer, i.e. a dropped predicate and a type-confused dict at
-- exit 0.  The invariant is that this gate admits EXACTLY what that registry can answer.
-- #2547 unit 3: `GSPredicateOnly` is what still says so now that both registries share one
-- environment — it selects exactly the `GMPredicate` entries, which are exactly the ones
-- `registerPredGiven` / `registerFunPredGiven` write.
export
goalMatchesGiven : GraphCtx -> ScopeId -> IfaceRef -> List Mono -> Bool
goalMatchesGiven gctx _ _ [] = False
goalMatchesGiven gctx scope iface args =
  anyGivenMatches
    gctx
    PredicateRequest { prIface = iface, prArgs = PSArgsKnown args }
    scope
    (givensForScope gctx scope)

export
anyGivenMatches : GraphCtx ->
  PredicateRequest ->
  ScopeId ->
  List GivenEntry ->
  Bool
anyGivenMatches gctx request scope givens =
  anyGivenOnChain
    request
    (Scopes.visibleChain (currentScopeStore gctx ()) scope)
    givens

anyGivenOnChain : PredicateRequest -> List Int -> List GivenEntry -> Bool
anyGivenOnChain _ _ [] = False
anyGivenOnChain request chain (g :: rest) =
  givenInScope GSPredicateOnly g
      && Scopes.visibleOnChain chain (Scopes.binderScope g.geBinder)
      && predicateRequestMatchesSlot request g.geSlot
    || anyGivenOnChain request chain rest

export
registerActiveDictVars : GraphCtx ->
  ScopeId ->
  Int ->
  List PredicateSlot ->
  Unit
registerActiveDictVars gctx _ _ [] = ()
registerActiveDictVars gctx scope slot (s :: rest) =
  registerEachActive gctx s.psBoundIds (Scopes.binderAt scope slot)
  registerActiveDictVars gctx scope (slot + 1) rest
# DESUGAR
(DUse false (UseGroup ("types" "tc_types") ((mem "AssumAnswer" true) (mem "AssumptionTraceEntry" true) (mem "AssumptionTraceKind" true) (mem "GivenEntry" true) (mem "GivenMatch" true) (mem "GivenProvenance" true) (mem "GivenScope" true) (mem "PredicateRequest" true) (mem "PredicateSlot" true) (mem "PredicateSlotArgs" true) (mem "GraphCtx" false) (mem "MethodBodyInstance" false) (mem "ModuleCtx" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "containsI" false) (mem "dedupI" false) (mem "isBareTyvarMono" false) (mem "monoTyvarIds" false) (mem "monoVecSameGiven" false) (mem "peelQual" false) (mem "tyvarId" false) (mem "oblArgKey" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "currentScopeStore" false) (mem "renderEvidenceBinder" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "methodLevelConstraintVarNames" false) (mem "oblIfaceKey" false) (mem "sameIfaceDecl" false) (mem "superLookup" false))))
(DUse false (UseGroup ("types" "tc_decls_types") ((mem "fromAstType" false))))
(DUse false (UseGroup ("types" "tc_decls") ((mem "constraintIface" false) (mem "constraintIsMethodLevel" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "TyConOrigin" true) (mem "Constraint" true) (mem "Route" true) (mem "Super" true) (mem "Ty" true))))
(DUse false (UseGroup ("types" "evidence") ((mem "EvidenceBinderId" true) (mem "ScopeId" true) (mem "SolverEvidence" true))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Mono" true) (mem "lookupAssocI" false) (mem "normalize" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omInsert" false) (mem "omLookup" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("types" "superclass") ((mem "SuperNode" true) (mem "lookupPos" false) (mem "mapAll" false) (mem "superClosure" false))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "isSome" false) (mem "listLen" false) (mem "lookupAssoc" false) (mem "orElseOpt" false))))
(DUse false (UseGroup ("list") ((mem "drop" false) (mem "elemIndex" false))))
(DUse false (UseGroup ("string") ((mem "join" false))))
(DUse false (UseGroup ("types" "registry") ((mem "regKeyOfTab" false) (mem "regKeyRender" false))))
(DUse false (UseAlias ("types" "scopes") "Scopes"))
(DTypeSig true "predicateSlotIds" (TyFun (TyApp (TyCon "List") (TyCon "PredicateSlot")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "predicateSlotIds" ((PList)) (EListLit))
(DFunDef false "predicateSlotIds" ((PCons (PVar "s") (PVar "rest"))) (EMatch (EFieldAccess (EVar "s") "psBoundIds") (arm (PList) () (EApp (EVar "predicateSlotIds") (EVar "rest"))) (arm (PCons (PVar "id") PWild) () (EBinOp "::" (EVar "id") (EApp (EVar "predicateSlotIds") (EVar "rest"))))))
(DTypeSig true "lookupPredicateSlots" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "PredicateSlot"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "PredicateSlot"))))))
(DFunDef false "lookupPredicateSlots" ((PVar "k") (PVar "idx")) (EApp (EApp (EVar "omLookup") (EVar "k")) (EVar "idx")))
(DTypeSig true "predicateSlotIdsAt" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "PredicateSlot"))) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "predicateSlotIdsAt" ((PVar "name") (PVar "idx")) (EApp (EVar "predicateSlotIds") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "idx")))))
(DTypeSig false "assumAnswerBinder" (TyFun (TyCon "AssumAnswer") (TyCon "EvidenceBinderId")))
(DFunDef false "assumAnswerBinder" ((PCon "SemanticGiven" (PVar "evidence"))) (EApp (EVar "givenEvidenceBinder") (EVar "evidence")))
(DFunDef false "assumAnswerBinder" ((PCon "LegacyScalar" (PVar "binder"))) (EVar "binder"))
(DFunDef false "assumAnswerBinder" ((PCon "LegacyPredicate" (PVar "binder"))) (EVar "binder"))
(DFunDef false "assumAnswerBinder" ((PCon "LegacyProjected" (PVar "binder") PWild)) (EVar "binder"))
(DTypeSig true "assumAnswerEvidence" (TyFun (TyCon "AssumAnswer") (TyCon "SolverEvidence")))
(DFunDef false "assumAnswerEvidence" ((PCon "SemanticGiven" (PVar "evidence"))) (EVar "evidence"))
(DFunDef false "assumAnswerEvidence" ((PCon "LegacyScalar" (PVar "binder"))) (EApp (EVar "GivenEvidence") (EVar "binder")))
(DFunDef false "assumAnswerEvidence" ((PCon "LegacyPredicate" (PVar "binder"))) (EApp (EVar "GivenEvidence") (EVar "binder")))
(DFunDef false "assumAnswerEvidence" ((PCon "LegacyProjected" (PVar "binder") (PVar "path"))) (EApp (EApp (EVar "SuperclassEvidence") (EVar "binder")) (EVar "path")))
(DTypeSig false "assumAnswerKind" (TyFun (TyCon "AssumAnswer") (TyCon "AssumptionTraceKind")))
(DFunDef false "assumAnswerKind" ((PCon "SemanticGiven" (PCon "SuperclassEvidence" PWild PWild))) (EVar "ATSuperclassProjection"))
(DFunDef false "assumAnswerKind" ((PCon "SemanticGiven" PWild)) (EVar "ATDirectPredicate"))
(DFunDef false "assumAnswerKind" ((PCon "LegacyScalar" PWild)) (EVar "ATLegacyScalar"))
(DFunDef false "assumAnswerKind" ((PCon "LegacyPredicate" PWild)) (EVar "ATLegacyPredicate"))
(DFunDef false "assumAnswerKind" ((PCon "LegacyProjected" PWild PWild)) (EVar "ATLegacyPredicate"))
(DTypeSig false "givenEvidenceBinder" (TyFun (TyCon "SolverEvidence") (TyCon "EvidenceBinderId")))
(DFunDef false "givenEvidenceBinder" ((PCon "GivenEvidence" (PVar "binder"))) (EVar "binder"))
(DFunDef false "givenEvidenceBinder" ((PCon "SuperclassEvidence" (PVar "parent") PWild)) (EVar "parent"))
(DFunDef false "givenEvidenceBinder" (PWild) (EApp (EVar "panic") (ELit (LString "non-given assumption evidence"))))
(DTypeSig true "assumAnswerRoute" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "AssumAnswer") (TyFun (TyApp (TyCon "Option") (TyCon "IfaceRef")) (TyFun (TyCon "ScopeId") (TyFun (TyFun (TyCon "String") (TyCon "Route")) (TyCon "Route")))))))
(DFunDef false "assumAnswerRoute" ((PVar "gctx") (PCon "SemanticGiven" (PCon "SuperclassEvidence" (PVar "parent") (PVar "path"))) PWild PWild (PVar "paramRoute")) (EApp (EApp (EVar "RProj") (EApp (EVar "paramRoute") (EApp (EApp (EVar "renderEvidenceBinder") (EVar "gctx")) (EVar "parent")))) (EVar "path")))
(DFunDef false "assumAnswerRoute" ((PVar "gctx") (PCon "LegacyProjected" (PVar "parent") (PVar "path")) PWild PWild (PVar "paramRoute")) (EApp (EApp (EVar "RProj") (EApp (EVar "paramRoute") (EApp (EApp (EVar "renderEvidenceBinder") (EVar "gctx")) (EVar "parent")))) (EVar "path")))
(DFunDef false "assumAnswerRoute" ((PVar "gctx") (PCon "LegacyScalar" (PVar "binder")) (PCon "Some" (PVar "goalIface")) (PVar "useScope") (PVar "paramRoute")) (EBlock (DoLet false false (PVar "base") (EApp (EVar "paramRoute") (EApp (EApp (EVar "renderEvidenceBinder") (EVar "gctx")) (EVar "binder")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "scalarGivenProjection") (EVar "gctx")) (EVar "binder")) (EVar "goalIface")) (EVar "useScope")) (arm (PCon "Some" (PVar "path")) () (EApp (EApp (EVar "RProj") (EVar "base")) (EVar "path"))) (arm (PCon "None") () (EVar "base"))))))
(DFunDef false "assumAnswerRoute" ((PVar "gctx") (PVar "answer") PWild PWild (PVar "paramRoute")) (EApp (EVar "paramRoute") (EApp (EApp (EVar "renderEvidenceBinder") (EVar "gctx")) (EApp (EVar "assumAnswerBinder") (EVar "answer")))))
(DTypeSig false "scalarGivenProjection" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvidenceBinderId") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "ScopeId") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "scalarGivenProjection" ((PVar "gctx") (PVar "binder") (PVar "goalIface") (PVar "useScope")) (EMatch (EApp (EApp (EVar "directGivenIfaceOf") (EVar "binder")) (EApp (EApp (EVar "givensForScope") (EVar "gctx")) (EVar "useScope"))) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "declared")) () (EIf (EBinOp "==" (EFieldAccess (EVar "declared") "irName") (EFieldAccess (EVar "goalIface") "irName")) (EVar "None") (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EApp (EApp (EVar "drop") (ELit (LInt 1))) (EFieldAccess (EVar "n") "superPath")))) (EApp (EApp (EVar "find") (ELam ((PVar "n")) (EBinOp "==" (EFieldAccess (EFieldAccess (EVar "n") "superIface") "irName") (EFieldAccess (EVar "goalIface") "irName")))) (EApp (EApp (EApp (EApp (EVar "superClosure") (EApp (EVar "superLookup") (EVar "gctx"))) (ELam (PWild PWild PWild) (EApp (EVar "Some") (ELit LUnit)))) (ELam ((PVar "ir") PWild) (EApp (EVar "regKeyRender") (EApp (EVar "regKeyOfTab") (EApp (EVar "oblIfaceKey") (EVar "ir")))))) (EListLit (ETuple (EVar "declared") (ELit LUnit))))))))))
(DTypeSig true "scalarGivenAnswers" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvidenceBinderId") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "ScopeId") (TyCon "Bool"))))))
(DFunDef false "scalarGivenAnswers" ((PVar "gctx") (PVar "binder") (PVar "goalIface") (PVar "useScope")) (EBinOp "||" (EBinOp "==" (EFieldAccess (EVar "goalIface") "irName") (ELit (LString ""))) (EMatch (EApp (EApp (EVar "directGivenIfaceOf") (EVar "binder")) (EApp (EApp (EVar "givensForScope") (EVar "gctx")) (EVar "useScope"))) (arm (PCon "None") () (EVar "True")) (arm (PCon "Some" (PVar "declared")) () (EBinOp "||" (EApp (EApp (EVar "sameIfaceOrUnresolved") (EVar "declared")) (EVar "goalIface")) (EApp (EVar "isSome") (EApp (EApp (EApp (EApp (EVar "scalarGivenProjection") (EVar "gctx")) (EVar "binder")) (EVar "goalIface")) (EVar "useScope"))))))))
(DTypeSig false "sameIfaceOrUnresolved" (TyFun (TyCon "IfaceRef") (TyFun (TyCon "IfaceRef") (TyCon "Bool"))))
(DFunDef false "sameIfaceOrUnresolved" ((PVar "a") (PVar "b")) (EMatch (ETuple (EFieldAccess (EVar "a") "irOrigin") (EFieldAccess (EVar "b") "irOrigin")) (arm (PTuple (PCon "OriginUnresolved") PWild) () (EBinOp "==" (EFieldAccess (EVar "a") "irName") (EFieldAccess (EVar "b") "irName"))) (arm (PTuple PWild (PCon "OriginUnresolved")) () (EBinOp "==" (EFieldAccess (EVar "a") "irName") (EFieldAccess (EVar "b") "irName"))) (arm PWild () (EApp (EApp (EVar "sameIfaceDecl") (EVar "a")) (EVar "b")))))
(DTypeSig false "directGivenIfaceOf" (TyFun (TyCon "EvidenceBinderId") (TyFun (TyApp (TyCon "List") (TyCon "GivenEntry")) (TyApp (TyCon "Option") (TyCon "IfaceRef")))))
(DFunDef false "directGivenIfaceOf" (PWild (PList)) (EVar "None"))
(DFunDef false "directGivenIfaceOf" ((PVar "binder") (PCons (PVar "g") (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "g") "geBinder") (EVar "binder")) (EBinOp "==" (EFieldAccess (EVar "g") "geProvenance") (EVar "DirectGiven"))) (EApp (EVar "Some") (EFieldAccess (EFieldAccess (EVar "g") "geSlot") "psIface")) (EIf (EVar "otherwise") (EApp (EApp (EVar "directGivenIfaceOf") (EVar "binder")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "projectedGivenOf" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvidenceBinderId") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "GivenEntry"))))))
(DFunDef false "projectedGivenOf" ((PVar "gctx") (PVar "parent") (PVar "path")) (EApp (EApp (EVar "find") (ELam ((PVar "g")) (EBinOp "==" (EFieldAccess (EVar "g") "geProvenance") (EApp (EApp (EVar "ProjectedGiven") (EVar "parent")) (EVar "path"))))) (EApp (EApp (EVar "givensForScope") (EVar "gctx")) (EApp (EVar "Scopes.binderScope") (EVar "parent")))))
(DTypeSig true "noteAssumption" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ScopeId") (TyFun (TyCon "AssumAnswer") (TyCon "Unit")))))
(DFunDef false "noteAssumption" ((PVar "gctx") (PVar "scope") (PVar "answer")) (EMatch (EFieldAccess (EVar "gctx") "trace") (arm (PCon "Some" (PVar "sink")) () (EIf (EFieldAccess (EVar "sink") "tsAssumptionEnabled") (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "sink") "tsAssumptionEntries")) (EBinOp "::" (ERecordCreate "AssumptionTraceEntry" ((fa "atGoalScope" (EVar "scope")) (fa "atBinder" (EApp (EVar "assumAnswerBinder") (EVar "answer"))) (fa "atKind" (EApp (EVar "assumAnswerKind") (EVar "answer"))))) (EFieldAccess (EFieldAccess (EVar "sink") "tsAssumptionEntries") "value"))) (ELit LUnit))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig true "givensForScope" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ScopeId") (TyApp (TyCon "List") (TyCon "GivenEntry")))))
(DFunDef false "givensForScope" ((PVar "gctx") (PVar "sid")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EFieldAccess (EApp (EApp (EVar "Scopes.scopeFrame") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))) (EVar "sid")) "sfModuleId")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "gGiven") "value"))))
(DTypeSig true "pushGiven" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "GivenMatch") (TyFun (TyCon "GivenProvenance") (TyFun (TyCon "PredicateSlot") (TyFun (TyCon "EvidenceBinderId") (TyCon "Unit")))))))
(DFunDef false "pushGiven" ((PVar "gctx") (PVar "gm") (PVar "provenance") (PVar "slot") (PVar "binder")) (EBlock (DoLet false false (PVar "mid") (EFieldAccess (EApp (EApp (EVar "Scopes.scopeFrame") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))) (EApp (EVar "Scopes.binderScope") (EVar "binder"))) "sfModuleId")) (DoLet false false (PVar "entry") (ERecordCreate "GivenEntry" ((fa "geSlot" (EVar "slot")) (fa "geBinder" (EVar "binder")) (fa "geMatch" (EVar "gm")) (fa "geProvenance" (EVar "provenance"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "gGiven")) (EApp (EApp (EApp (EVar "omInsert") (EVar "mid")) (EBinOp "::" (EVar "entry") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "gGiven") "value"))))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "gGiven") "value"))))))
(DTypeSig true "givenInScope" (TyFun (TyCon "GivenScope") (TyFun (TyCon "GivenEntry") (TyCon "Bool"))))
(DFunDef false "givenInScope" ((PCon "GSPredicateOnly") (PVar "g")) (EMatch (EFieldAccess (EVar "g") "geMatch") (arm (PCon "GMPredicate") () (EVar "True")) (arm (PCon "GMIdWitnessed") () (EVar "False"))))
(DFunDef false "givenInScope" ((PCon "GSImplRequires") (PVar "g")) (EMatch (EFieldAccess (EVar "g") "geMatch") (arm (PCon "GMIdWitnessed") () (EVar "True")) (arm (PCon "GMPredicate") () (EVar "False"))))
(DTypeSig true "givenRoute" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Bool") (TyFun (TyCon "EvidenceBinderId") (TyCon "Route")))))
(DFunDef false "givenRoute" ((PVar "gctx") (PVar "isReturnPosition") (PVar "binder")) (EIf (EVar "isReturnPosition") (EApp (EVar "RDictFwd") (EApp (EApp (EVar "renderEvidenceBinder") (EVar "gctx")) (EVar "binder"))) (EApp (EVar "RDict") (EApp (EApp (EVar "renderEvidenceBinder") (EVar "gctx")) (EVar "binder")))))
(DTypeSig true "activeDictVarOf" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "ScopeId") (TyApp (TyCon "Option") (TyCon "EvidenceBinderId"))))))
(DFunDef false "activeDictVarOf" ((PVar "gctx") (PVar "m") (PVar "useScope")) (EMatch (EApp (EVar "peelQual") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EApp (EApp (EApp (EApp (EVar "firstDictForEncl") (EVar "gctx")) (EApp (EVar "tyvarId") (EVar "cell"))) (EVar "useScope")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "activeDictVars") "value"))) (arm (PCon "TApp" (PVar "a") PWild) () (EApp (EApp (EApp (EVar "activeDictVarOf") (EVar "gctx")) (EVar "a")) (EVar "useScope"))) (arm PWild () (EVar "None"))))
(DTypeSig true "activeDictVarAnswering" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "ScopeId") (TyFun (TyFun (TyCon "EvidenceBinderId") (TyCon "Bool")) (TyApp (TyCon "Option") (TyCon "EvidenceBinderId")))))))
(DFunDef false "activeDictVarAnswering" ((PVar "gctx") (PVar "m") (PVar "useScope") (PVar "answers")) (EMatch (EApp (EVar "peelQual") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EApp (EApp (EVar "find") (ELam ((PVar "b")) (EApp (EVar "answers") (EVar "b")))) (EApp (EApp (EApp (EApp (EVar "visibleDictsFor") (EVar "gctx")) (EApp (EVar "tyvarId") (EVar "cell"))) (EVar "useScope")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "activeDictVars") "value")))) (arm (PCon "TApp" (PVar "a") PWild) () (EApp (EApp (EApp (EApp (EVar "activeDictVarAnswering") (EVar "gctx")) (EVar "a")) (EVar "useScope")) (EVar "answers"))) (arm PWild () (EVar "None"))))
(DTypeSig false "visibleDictsFor" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "EvidenceBinderId"))) (TyApp (TyCon "List") (TyCon "EvidenceBinderId")))))))
(DFunDef false "visibleDictsFor" ((PVar "gctx") PWild PWild (PList)) (EListLit))
(DFunDef false "visibleDictsFor" ((PVar "gctx") (PVar "id") (PVar "useScope") (PCons (PTuple (PVar "eid") (PVar "binder")) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "eid") (EVar "id")) (EApp (EApp (EApp (EVar "Scopes.givenVisibleFrom") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))) (EVar "useScope")) (EApp (EVar "Scopes.binderScope") (EVar "binder")))) (EBinOp "::" (EVar "binder") (EApp (EApp (EApp (EApp (EVar "visibleDictsFor") (EVar "gctx")) (EVar "id")) (EVar "useScope")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "visibleDictsFor") (EVar "gctx")) (EVar "id")) (EVar "useScope")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "firstDictForEncl" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "EvidenceBinderId"))) (TyApp (TyCon "Option") (TyCon "EvidenceBinderId")))))))
(DFunDef false "firstDictForEncl" ((PVar "gctx") PWild PWild (PList)) (EVar "None"))
(DFunDef false "firstDictForEncl" ((PVar "gctx") (PVar "id") (PVar "useScope") (PCons (PTuple (PVar "eid") (PVar "binder")) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "eid") (EVar "id")) (EApp (EApp (EApp (EVar "Scopes.givenVisibleFrom") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))) (EVar "useScope")) (EApp (EVar "Scopes.binderScope") (EVar "binder")))) (EApp (EVar "Some") (EVar "binder")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "firstDictForEncl") (EVar "gctx")) (EVar "id")) (EVar "useScope")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "activeDictVarOfEncl" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "PredicateRequest")) (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyApp (TyCon "Option") (TyCon "AssumAnswer"))))))))
(DFunDef false "activeDictVarOfEncl" ((PVar "mctx") (PCon "None") (PVar "m") (PVar "encl") (PVar "useScope")) (EApp (EApp (EVar "map") (EVar "LegacyScalar")) (EApp (EApp (EApp (EVar "activeDictVarOf") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "m")) (EVar "useScope"))))
(DFunDef false "activeDictVarOfEncl" ((PVar "mctx") (PCon "Some" (PVar "request")) (PVar "m") (PVar "encl") (PVar "useScope")) (EApp (EApp (EVar "orElseOpt") (EApp (EApp (EVar "map") (EVar "LegacyScalar")) (EApp (EApp (EApp (EApp (EApp (EVar "enclDictVarOf") (EVar "mctx")) (EApp (EVar "Some") (EVar "request"))) (EVar "m")) (EVar "encl")) (EVar "useScope")))) (EApp (EApp (EApp (EApp (EVar "implReqDictVarOf") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EVar "Some") (EVar "request"))) (EVar "m")) (EVar "useScope"))))
(DTypeSig true "implReqDictVarOf" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "Option") (TyCon "PredicateRequest")) (TyFun (TyCon "Mono") (TyFun (TyCon "ScopeId") (TyApp (TyCon "Option") (TyCon "AssumAnswer")))))))
(DFunDef false "implReqDictVarOf" ((PVar "gctx") (PCon "None") PWild PWild) (EVar "None"))
(DFunDef false "implReqDictVarOf" ((PVar "gctx") (PCon "Some" (PVar "request")) (PVar "m") (PVar "useScope")) (EMatch (EApp (EVar "peelQual") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "firstPredForEnclAt") (EVar "gctx")) (EVar "GSImplRequires")) (EApp (EVar "tyvarId") (EVar "cell"))) (EVar "request")) (EVar "useScope")) (EApp (EApp (EVar "givensForScope") (EVar "gctx")) (EVar "useScope")))) (arm (PCon "TApp" (PVar "a") PWild) () (EApp (EApp (EApp (EApp (EVar "implReqDictVarOf") (EVar "gctx")) (EApp (EVar "Some") (EVar "request"))) (EVar "a")) (EVar "useScope"))) (arm PWild () (EVar "None"))))
(DTypeSig true "enclDictVarOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "PredicateRequest")) (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyApp (TyCon "Option") (TyCon "EvidenceBinderId"))))))))
(DFunDef false "enclDictVarOf" ((PVar "mctx") (PVar "goal") (PVar "m") (PVar "encl") (PVar "useScope")) (EIf (EBinOp "==" (EVar "encl") (ELit (LString ""))) (EVar "None") (EIf (EVar "otherwise") (EMatch (EApp (EVar "peelQual") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EApp (EApp (EVar "map") (EApp (EVar "Scopes.binderAt") (EApp (EApp (EVar "Scopes.declarationScope") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EVar "useScope")))) (EApp (EApp (EApp (EApp (EVar "enclSlotIndex") (EVar "mctx")) (EVar "goal")) (EApp (EVar "tyvarId") (EVar "cell"))) (EVar "encl")))) (arm (PCon "TApp" (PVar "a") PWild) () (EApp (EApp (EApp (EApp (EApp (EVar "enclDictVarOf") (EVar "mctx")) (EVar "goal")) (EVar "a")) (EVar "encl")) (EVar "useScope"))) (arm PWild () (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "enclSlotIndex" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "PredicateRequest")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "enclSlotIndex" ((PVar "mctx") (PCon "None") (PVar "target") (PVar "encl")) (EApp (EApp (EVar "elemIndex") (EVar "target")) (EApp (EApp (EVar "enclSlotIds") (EVar "mctx")) (EVar "encl"))))
(DFunDef false "enclSlotIndex" ((PVar "mctx") (PCon "Some" (PVar "request")) (PVar "target") (PVar "encl")) (EApp (EApp (EApp (EVar "indexOfPred") (EVar "target")) (EVar "request")) (EApp (EApp (EVar "enclPreds") (EVar "mctx")) (EVar "encl"))))
(DTypeSig false "enclSlotIds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "enclSlotIds" ((PVar "mctx") (PVar "encl")) (EApp (EApp (EVar "predicateSlotIdsAt") (EVar "encl")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funPredicateSlotsIdxRef") "value")))
(DTypeSig false "enclPreds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "PredicateSlot")))))
(DFunDef false "enclPreds" ((PVar "mctx") (PVar "encl")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "lookupPredicateSlots") (EVar "encl")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funPredicateSlotsIdxRef") "value"))))
(DTypeSig false "indexOfPred" (TyFun (TyCon "Int") (TyFun (TyCon "PredicateRequest") (TyFun (TyApp (TyCon "List") (TyCon "PredicateSlot")) (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "indexOfPred" ((PVar "target") (PVar "request") (PVar "preds")) (EApp (EApp (EApp (EApp (EVar "indexOfPredGo") (ELit (LInt 0))) (EVar "target")) (EVar "request")) (EVar "preds")))
(DTypeSig false "indexOfPredGo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "PredicateRequest") (TyFun (TyApp (TyCon "List") (TyCon "PredicateSlot")) (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "indexOfPredGo" (PWild PWild PWild (PList)) (EVar "None"))
(DFunDef false "indexOfPredGo" ((PVar "i") (PVar "target") (PVar "request") (PCons (PVar "sp") (PVar "rest"))) (EIf (EBinOp "&&" (EApp (EApp (EVar "containsI") (EVar "target")) (EFieldAccess (EVar "sp") "psBoundIds")) (EApp (EApp (EVar "predicateRequestMatchesSlot") (EVar "request")) (EVar "sp"))) (EApp (EVar "Some") (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "indexOfPredGo") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "target")) (EVar "request")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "predicateRequestMatchesSlot" (TyFun (TyCon "PredicateRequest") (TyFun (TyCon "PredicateSlot") (TyCon "Bool"))))
(DFunDef false "predicateRequestMatchesSlot" ((PVar "request") (PVar "slot")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "/=" (EFieldAccess (EFieldAccess (EVar "request") "prIface") "irName") (ELit (LString ""))) (EBinOp "/=" (EFieldAccess (EFieldAccess (EVar "slot") "psIface") "irName") (ELit (LString "")))) (EApp (EApp (EVar "sameIfaceDecl") (EFieldAccess (EVar "request") "prIface")) (EFieldAccess (EVar "slot") "psIface"))) (EApp (EApp (EVar "predicateRequestArgsMatch") (EFieldAccess (EVar "request") "prArgs")) (EFieldAccess (EVar "slot") "psArgs"))))
(DTypeSig false "predicateRequestArgsMatch" (TyFun (TyCon "PredicateSlotArgs") (TyFun (TyCon "PredicateSlotArgs") (TyCon "Bool"))))
(DFunDef false "predicateRequestArgsMatch" ((PCon "PSArgsKnown" (PVar "requestArgs")) (PCon "PSArgsKnown" (PVar "slotArgs"))) (EApp (EApp (EVar "monoVecSameGiven") (EVar "requestArgs")) (EVar "slotArgs")))
(DFunDef false "predicateRequestArgsMatch" (PWild PWild) (EVar "True"))
(DTypeSig true "enclSlot" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "enclSlot" ((PVar "mctx") (PVar "encl") (PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EApp (EApp (EVar "elemIndex") (EApp (EVar "tyvarId") (EVar "cell"))) (EApp (EApp (EVar "predicateSlotIdsAt") (EVar "encl")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funPredicateSlotsIdxRef") "value")))) (arm PWild () (EVar "None"))))
(DTypeSig false "methodLevelPredicateSlots" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "PredicateSlot")))))))
(DFunDef false "methodLevelPredicateSlots" ((PVar "mctx") (PVar "typarams") (PCon "TyConstrained" (PVar "cs") (PVar "t")) (PVar "tvMap")) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "methodLevelPredicateSlot") (EVar "mctx")) (EVar "typarams")) (EVar "tvMap"))) (EVar "cs")) (EApp (EApp (EApp (EApp (EVar "methodLevelPredicateSlots") (EVar "mctx")) (EVar "typarams")) (EVar "t")) (EVar "tvMap"))))
(DFunDef false "methodLevelPredicateSlots" ((PVar "mctx") (PVar "typarams") (PCon "TyEffect" PWild PWild (PVar "t")) (PVar "tvMap")) (EApp (EApp (EApp (EApp (EVar "methodLevelPredicateSlots") (EVar "mctx")) (EVar "typarams")) (EVar "t")) (EVar "tvMap")))
(DFunDef false "methodLevelPredicateSlots" ((PVar "mctx") PWild PWild PWild) (EListLit))
(DTypeSig false "methodLevelPredicateSlot" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyCon "PredicateSlot")))))))
(DFunDef false "methodLevelPredicateSlot" ((PVar "mctx") (PVar "typarams") (PVar "tvMap") (PVar "c")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "constraintIsMethodLevel") (EVar "typarams")) (EVar "c"))) (EListLit) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "args") (EApp (EApp (EVar "map") (EApp (EApp (EVar "fromAstType") (EVar "mctx")) (EVar "tvMap"))) (EFieldAccess (EVar "c") "constraintArgs"))) (DoExpr (EListLit (ERecordCreate "PredicateSlot" ((fa "psIface" (ERecordCreate "IfaceRef" ((fa "irName" (EApp (EVar "constraintIface") (EVar "c"))) (fa "irOrigin" (EFieldAccess (EVar "c") "constraintOrigin"))))) (fa "psArgs" (EApp (EVar "PSArgsKnown") (EVar "args"))) (fa "psBoundIds" (EApp (EVar "dedupI") (EApp (EApp (EVar "flatMap") (EVar "monoTyvarIds")) (EVar "args"))))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "goalGivenAt" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ScopeId") (TyCon "Bool"))))))
(DFunDef false "goalGivenAt" ((PVar "gctx") (PVar "iface") (PVar "args") (PVar "scope")) (EBinOp "||" (EApp (EVar "isSome") (EApp (EApp (EApp (EVar "activeFunDictPredOf") (EVar "gctx")) (ERecordCreate "PredicateRequest" ((fa "prIface" (EVar "iface")) (fa "prArgs" (EApp (EVar "PSArgsKnown") (EVar "args")))))) (EVar "scope"))) (EApp (EApp (EApp (EApp (EVar "goalMatchesGiven") (EVar "gctx")) (EVar "scope")) (EVar "iface")) (EVar "args"))))
(DTypeSig true "registerMethodDictSlots" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ScopeId") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyCon "Unit")))))))
(DFunDef false "registerMethodDictSlots" ((PVar "gctx") PWild PWild (PList) PWild) (ELit LUnit))
(DFunDef false "registerMethodDictSlots" ((PVar "gctx") (PVar "scope") (PVar "slot") (PCons (PVar "id") (PVar "rest")) (PVar "subst")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "registerOneMethodDict") (EVar "gctx")) (EVar "scope")) (EVar "slot")) (EVar "id")) (EVar "subst"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "registerMethodDictSlots") (EVar "gctx")) (EVar "scope")) (EBinOp "+" (EVar "slot") (ELit (LInt 1)))) (EVar "rest")) (EVar "subst")))))
(DTypeSig false "registerOneMethodDict" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ScopeId") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyCon "Unit")))))))
(DFunDef false "registerOneMethodDict" ((PVar "gctx") (PVar "scope") (PVar "slot") (PVar "id") (PVar "subst")) (EMatch (EApp (EApp (EVar "lookupAssocI") (EVar "id")) (EVar "subst")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "m")) () (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "activeDictVars")) (EBinOp "::" (ETuple (EApp (EVar "tyvarId") (EVar "cell")) (EApp (EApp (EVar "Scopes.binderAt") (EVar "scope")) (EVar "slot"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "activeDictVars") "value")))) (arm PWild () (ELit LUnit))))))
(DTypeSig true "publishMethodPredGivens" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyFun (TyCon "MethodBodyInstance") (TyFun (TyCon "ScopeId") (TyCon "Unit")))))))
(DFunDef false "publishMethodPredGivens" ((PVar "mctx") (PVar "params") (PVar "mty") (PVar "inst") (PVar "scope")) (EApp (EApp (EApp (EApp (EVar "registerSlotPredGivens") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "scope")) (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EVar "methodLevelPredicateSlots") (EVar "mctx")) (EVar "params")) (EVar "mty")) (EFieldAccess (EVar "inst") "mbiNamedVars"))))
(DTypeSig true "givenAnswers" (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "PredicateSlot") (TyCon "Bool")))))
(DFunDef false "givenAnswers" ((PVar "iface") (PVar "args") (PVar "slot")) (EBinOp "&&" (EApp (EApp (EVar "sameIfaceDecl") (EFieldAccess (EVar "slot") "psIface")) (EVar "iface")) (EMatch (EFieldAccess (EVar "slot") "psArgs") (arm (PCon "PSArgsKnown" (PVar "gargs")) () (EApp (EApp (EVar "monoVecSameGiven") (EVar "gargs")) (EVar "args"))) (arm (PCon "PSArgsUnknown") () (EVar "False")))))
(DTypeSig true "registerImplMethodDicts" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyCon "Unit")))))))
(DFunDef false "registerImplMethodDicts" ((PVar "gctx") (PVar "scope") (PVar "ifaceParams") (PVar "mty") (PVar "tvMap")) (EApp (EApp (EApp (EApp (EApp (EVar "registerImplMethodDictsGo") (EVar "gctx")) (EVar "scope")) (ELit (LInt 0))) (EApp (EApp (EVar "methodLevelConstraintVarNames") (EVar "ifaceParams")) (EVar "mty"))) (EVar "tvMap")))
(DTypeSig false "registerImplMethodDictsGo" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ScopeId") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyCon "Unit")))))))
(DFunDef false "registerImplMethodDictsGo" ((PVar "gctx") PWild PWild (PList) PWild) (ELit LUnit))
(DFunDef false "registerImplMethodDictsGo" ((PVar "gctx") (PVar "scope") (PVar "slot") (PCons (PVar "vname") (PVar "rest")) (PVar "tvMap")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "registerImplMethodDictOne") (EVar "gctx")) (EVar "scope")) (EVar "slot")) (EVar "vname")) (EVar "tvMap"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "registerImplMethodDictsGo") (EVar "gctx")) (EVar "scope")) (EBinOp "+" (EVar "slot") (ELit (LInt 1)))) (EVar "rest")) (EVar "tvMap")))))
(DTypeSig false "registerImplMethodDictOne" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ScopeId") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyCon "Unit")))))))
(DFunDef false "registerImplMethodDictOne" ((PVar "gctx") (PVar "scope") (PVar "slot") (PVar "vname") (PVar "tvMap")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "vname")) (EVar "tvMap")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "m")) () (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "activeDictVars")) (EBinOp "::" (ETuple (EApp (EVar "tyvarId") (EVar "cell")) (EApp (EApp (EVar "Scopes.binderAt") (EVar "scope")) (EVar "slot"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "activeDictVars") "value")))) (arm PWild () (ELit LUnit))))))
(DTypeSig true "registerPredGiven" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "EvidenceBinderId") (TyCon "Unit"))))))
(DFunDef false "registerPredGiven" ((PVar "gctx") PWild (PList) PWild) (ELit LUnit))
(DFunDef false "registerPredGiven" ((PVar "gctx") (PVar "iface") (PVar "args") (PVar "dname")) (EIf (EApp (EApp (EVar "allList") (EVar "isBareTyvarMono")) (EVar "args")) (ELit LUnit) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "slot") (ERecordCreate "PredicateSlot" ((fa "psIface" (EVar "iface")) (fa "psArgs" (EApp (EVar "PSArgsKnown") (EVar "args"))) (fa "psBoundIds" (EApp (EVar "dedupI") (EApp (EApp (EVar "flatMap") (EVar "monoTyvarIds")) (EVar "args"))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "pushGiven") (EVar "gctx")) (EVar "GMPredicate")) (EVar "DirectGiven")) (EVar "slot")) (EVar "dname")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "activeDictPredOf" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PredicateRequest") (TyFun (TyCon "Mono") (TyFun (TyCon "ScopeId") (TyApp (TyCon "Option") (TyCon "AssumAnswer")))))))
(DFunDef false "activeDictPredOf" ((PVar "gctx") (PVar "request") (PVar "targetMono") (PVar "useScope")) (EBlock (DoLet false false (PVar "preds") (EApp (EApp (EVar "givensForScope") (EVar "gctx")) (EVar "useScope"))) (DoExpr (EMatch (EFieldAccess (EVar "request") "prArgs") (arm (PCon "PSArgsKnown" PWild) () (EApp (EApp (EApp (EApp (EVar "firstPredForEncl") (EVar "gctx")) (EVar "request")) (EVar "useScope")) (EVar "preds"))) (arm (PCon "PSArgsUnknown") () (EMatch (EApp (EVar "predicateTargetId") (EVar "targetMono")) (arm (PCon "Some" (PVar "target")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "firstPredForEnclAt") (EVar "gctx")) (EVar "GSPredicateOnly")) (EVar "target")) (EVar "request")) (EVar "useScope")) (EVar "preds"))) (arm (PCon "None") () (EVar "None"))))))))
(DTypeSig false "predicateTargetId" (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "predicateTargetId" ((PVar "m")) (EMatch (EApp (EVar "peelQual") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EApp (EVar "Some") (EApp (EVar "tyvarId") (EVar "cell")))) (arm (PCon "TApp" (PVar "a") PWild) () (EApp (EVar "predicateTargetId") (EVar "a"))) (arm PWild () (EVar "None"))))
(DTypeSig true "activeFunDictPredOf" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PredicateRequest") (TyFun (TyCon "ScopeId") (TyApp (TyCon "Option") (TyCon "AssumAnswer"))))))
(DFunDef false "activeFunDictPredOf" ((PVar "gctx") (PVar "request") (PVar "useScope")) (EApp (EApp (EApp (EApp (EVar "firstPredForEncl") (EVar "gctx")) (EVar "request")) (EVar "useScope")) (EApp (EApp (EVar "givensForScope") (EVar "gctx")) (EVar "useScope"))))
(DTypeSig true "firstPredForEncl" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PredicateRequest") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyCon "GivenEntry")) (TyApp (TyCon "Option") (TyCon "AssumAnswer")))))))
(DFunDef false "firstPredForEncl" ((PVar "gctx") (PVar "request") (PVar "useScope") (PVar "givens")) (EApp (EApp (EApp (EVar "firstPredOnChain") (EVar "request")) (EApp (EApp (EVar "Scopes.visibleChain") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))) (EVar "useScope"))) (EVar "givens")))
(DTypeSig false "firstPredOnChain" (TyFun (TyCon "PredicateRequest") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "GivenEntry")) (TyApp (TyCon "Option") (TyCon "AssumAnswer"))))))
(DFunDef false "firstPredOnChain" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "firstPredOnChain" ((PVar "request") (PVar "chain") (PCons (PVar "g") (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "givenInScope") (EVar "GSPredicateOnly")) (EVar "g")) (EApp (EApp (EVar "Scopes.visibleOnChain") (EVar "chain")) (EApp (EVar "Scopes.binderScope") (EFieldAccess (EVar "g") "geBinder")))) (EApp (EApp (EVar "predicateRequestMatchesSlot") (EVar "request")) (EFieldAccess (EVar "g") "geSlot"))) (EApp (EVar "Some") (EApp (EApp (EVar "givenAnswerForRequest") (EVar "request")) (EVar "g"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "firstPredOnChain") (EVar "request")) (EVar "chain")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "givenAnswerExact" (TyFun (TyCon "GivenEntry") (TyCon "AssumAnswer")))
(DFunDef false "givenAnswerExact" ((PVar "g")) (EMatch (EFieldAccess (EVar "g") "geProvenance") (arm (PCon "DirectGiven") () (EApp (EVar "SemanticGiven") (EApp (EVar "GivenEvidence") (EFieldAccess (EVar "g") "geBinder")))) (arm (PCon "ProjectedGiven" (PVar "parent") (PVar "path")) () (EApp (EVar "SemanticGiven") (EApp (EApp (EVar "SuperclassEvidence") (EVar "parent")) (EVar "path"))))))
(DTypeSig false "givenAnswerForRequest" (TyFun (TyCon "PredicateRequest") (TyFun (TyCon "GivenEntry") (TyCon "AssumAnswer"))))
(DFunDef false "givenAnswerForRequest" ((PVar "request") (PVar "g")) (EMatch (ETuple (EFieldAccess (EVar "request") "prArgs") (EFieldAccess (EFieldAccess (EVar "g") "geSlot") "psArgs") (EFieldAccess (EVar "g") "geMatch")) (arm (PTuple (PCon "PSArgsKnown" PWild) (PCon "PSArgsKnown" PWild) (PCon "GMPredicate")) () (EMatch (ETuple (EFieldAccess (EFieldAccess (EVar "request") "prIface") "irOrigin") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "g") "geSlot") "psIface") "irOrigin")) (arm (PTuple (PCon "OriginUnresolved") PWild) () (EApp (EVar "givenAnswerResidual") (EVar "g"))) (arm (PTuple PWild (PCon "OriginUnresolved")) () (EApp (EVar "givenAnswerResidual") (EVar "g"))) (arm PWild () (EApp (EVar "givenAnswerExact") (EVar "g"))))) (arm PWild () (EApp (EVar "givenAnswerResidual") (EVar "g")))))
(DTypeSig false "givenAnswerResidual" (TyFun (TyCon "GivenEntry") (TyCon "AssumAnswer")))
(DFunDef false "givenAnswerResidual" ((PVar "g")) (EMatch (EFieldAccess (EVar "g") "geProvenance") (arm (PCon "DirectGiven") () (EApp (EVar "LegacyPredicate") (EFieldAccess (EVar "g") "geBinder"))) (arm (PCon "ProjectedGiven" (PVar "parent") (PVar "path")) () (EApp (EApp (EVar "LegacyProjected") (EVar "parent")) (EVar "path")))))
(DTypeSig true "firstPredForEnclAt" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "GivenScope") (TyFun (TyCon "Int") (TyFun (TyCon "PredicateRequest") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyCon "GivenEntry")) (TyApp (TyCon "Option") (TyCon "AssumAnswer")))))))))
(DFunDef false "firstPredForEnclAt" ((PVar "gctx") (PVar "scope") (PVar "target") (PVar "request") (PVar "useScope") (PVar "givens")) (EApp (EApp (EApp (EApp (EApp (EVar "firstPredAtOnChain") (EVar "scope")) (EVar "target")) (EVar "request")) (EApp (EApp (EVar "Scopes.visibleChain") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))) (EVar "useScope"))) (EVar "givens")))
(DTypeSig false "firstPredAtOnChain" (TyFun (TyCon "GivenScope") (TyFun (TyCon "Int") (TyFun (TyCon "PredicateRequest") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "GivenEntry")) (TyApp (TyCon "Option") (TyCon "AssumAnswer"))))))))
(DFunDef false "firstPredAtOnChain" (PWild PWild PWild PWild (PList)) (EVar "None"))
(DFunDef false "firstPredAtOnChain" ((PVar "scope") (PVar "target") (PVar "request") (PVar "chain") (PCons (PVar "g") (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "givenInScope") (EVar "scope")) (EVar "g")) (EApp (EApp (EVar "containsI") (EVar "target")) (EFieldAccess (EFieldAccess (EVar "g") "geSlot") "psBoundIds"))) (EApp (EApp (EVar "Scopes.visibleOnChain") (EVar "chain")) (EApp (EVar "Scopes.binderScope") (EFieldAccess (EVar "g") "geBinder")))) (EApp (EApp (EVar "predicateRequestMatchesSlot") (EVar "request")) (EFieldAccess (EVar "g") "geSlot"))) (EApp (EVar "Some") (EApp (EApp (EVar "givenAnswerForRequest") (EVar "request")) (EVar "g"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "firstPredAtOnChain") (EVar "scope")) (EVar "target")) (EVar "request")) (EVar "chain")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "activeFunDictPredOfResidual" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ScopeId") (TyApp (TyCon "Option") (TyCon "AssumAnswer")))))))
(DFunDef false "activeFunDictPredOfResidual" ((PVar "gctx") (PVar "iface") (PVar "args") (PVar "useScope")) (EApp (EApp (EApp (EApp (EApp (EVar "firstPredForEnclResidual") (EVar "gctx")) (EVar "iface")) (EVar "args")) (EVar "useScope")) (EApp (EApp (EVar "givensForScope") (EVar "gctx")) (EVar "useScope"))))
(DTypeSig true "firstPredForEnclResidual" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyCon "GivenEntry")) (TyApp (TyCon "Option") (TyCon "AssumAnswer"))))))))
(DFunDef false "firstPredForEnclResidual" ((PVar "gctx") PWild PWild PWild (PList)) (EVar "None"))
(DFunDef false "firstPredForEnclResidual" ((PVar "gctx") (PVar "iface") (PVar "args") (PVar "useScope") (PCons (PVar "g") (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "givenInScope") (EVar "GSPredicateOnly")) (EVar "g")) (EBinOp "==" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "g") "geSlot") "psIface") "irName") (EVar "iface"))) (EApp (EApp (EApp (EVar "Scopes.givenVisibleFrom") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))) (EVar "useScope")) (EApp (EVar "Scopes.binderScope") (EFieldAccess (EVar "g") "geBinder")))) (EApp (EApp (EVar "predicateRequestArgsMatch") (EApp (EVar "PSArgsKnown") (EVar "args"))) (EFieldAccess (EFieldAccess (EVar "g") "geSlot") "psArgs"))) (EApp (EVar "Some") (EApp (EVar "givenAnswerResidual") (EVar "g"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "firstPredForEnclResidual") (EVar "gctx")) (EVar "iface")) (EVar "args")) (EVar "useScope")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "registerEachActive" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "EvidenceBinderId") (TyCon "Unit")))))
(DFunDef false "registerEachActive" ((PVar "gctx") (PList) PWild) (ELit LUnit))
(DFunDef false "registerEachActive" ((PVar "gctx") (PCons (PVar "id") (PVar "rest")) (PVar "dname")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "activeDictVars")) (EBinOp "::" (ETuple (EVar "id") (EVar "dname")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "activeDictVars") "value")))) (DoExpr (EApp (EApp (EApp (EVar "registerEachActive") (EVar "gctx")) (EVar "rest")) (EVar "dname")))))
(DTypeSig true "registerSlotPredGivens" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ScopeId") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PredicateSlot")) (TyCon "Unit"))))))
(DFunDef false "registerSlotPredGivens" ((PVar "gctx") PWild PWild (PList)) (ELit LUnit))
(DFunDef false "registerSlotPredGivens" ((PVar "gctx") (PVar "scope") (PVar "slot") (PCons (PVar "s") (PVar "srest"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "registerFunPredGiven") (EVar "gctx")) (EVar "s")) (EApp (EApp (EVar "Scopes.binderAt") (EVar "scope")) (EVar "slot")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "registerSlotPredGivens") (EVar "gctx")) (EVar "scope")) (EBinOp "+" (EVar "slot") (ELit (LInt 1)))) (EVar "srest")))))
(DTypeSig true "registerFunPredGiven" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PredicateSlot") (TyFun (TyCon "EvidenceBinderId") (TyCon "Unit")))))
(DFunDef false "registerFunPredGiven" ((PVar "gctx") (PVar "slot") (PVar "binder")) (EIf (EBinOp "==" (EFieldAccess (EFieldAccess (EVar "slot") "psIface") "irName") (ELit (LString ""))) (ELit LUnit) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "pushGiven") (EVar "gctx")) (EVar "GMPredicate")) (EVar "DirectGiven")) (EVar "slot")) (EVar "binder"))) (DoExpr (EApp (EApp (EApp (EVar "registerFunPredGivenSlots") (EVar "gctx")) (EApp (EApp (EVar "predicateSlotKnownSupers") (EVar "gctx")) (EVar "slot"))) (EVar "binder")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "registerFunPredGivenSlots" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "PredicateSlot") (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyCon "EvidenceBinderId") (TyCon "Unit")))))
(DFunDef false "registerFunPredGivenSlots" ((PVar "gctx") (PList) PWild) (ELit LUnit))
(DFunDef false "registerFunPredGivenSlots" ((PVar "gctx") (PCons (PTuple (PVar "slot") (PVar "path")) (PVar "rest")) (PVar "binder")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "pushGiven") (EVar "gctx")) (EVar "GMPredicate")) (EApp (EApp (EVar "ProjectedGiven") (EVar "binder")) (EVar "path"))) (EVar "slot")) (EVar "binder"))) (DoExpr (EApp (EApp (EApp (EVar "registerFunPredGivenSlots") (EVar "gctx")) (EVar "rest")) (EVar "binder")))))
(DTypeSig true "predicateSlotKnownSupers" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PredicateSlot") (TyApp (TyCon "List") (TyTuple (TyCon "PredicateSlot") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "predicateSlotKnownSupers" ((PVar "gctx") (PVar "slot")) (EMatch (EFieldAccess (EVar "slot") "psArgs") (arm (PCon "PSArgsUnknown") () (EListLit)) (arm (PCon "PSArgsKnown" (PVar "args")) () (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EApp (EVar "predicateSlotOfNode") (EVar "n")) (EApp (EApp (EVar "drop") (ELit (LInt 1))) (EFieldAccess (EVar "n") "superPath"))))) (EApp (EApp (EVar "filter") (ELam ((PVar "n")) (EBinOp ">" (EApp (EVar "listLen") (EFieldAccess (EVar "n") "superPath")) (ELit (LInt 1))))) (EApp (EApp (EApp (EApp (EVar "superClosure") (EApp (EVar "superLookup") (EVar "gctx"))) (EVar "predicateSuperStep")) (EVar "predicateNodeKey")) (EListLit (ETuple (EFieldAccess (EVar "slot") "psIface") (EVar "args")))))))))
(DTypeSig false "predicateNodeKey" (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "String"))))
(DFunDef false "predicateNodeKey" ((PVar "iface") (PVar "monos")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "regKeyRender") (EApp (EVar "regKeyOfTab") (EApp (EVar "oblIfaceKey") (EVar "iface")))))) (ELit (LString "|"))) (EApp (EVar "display") (EApp (EApp (EVar "join") (ELit (LString ","))) (EApp (EApp (EVar "map") (EVar "oblArgKey")) (EVar "monos"))))) (ELit (LString ""))))
(DTypeSig false "predicateSuperStep" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "Super") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Mono")))))))
(DFunDef false "predicateSuperStep" ((PVar "typarams") (PVar "args") (PRec "Super" ((rf "superParams" (PVar "params"))) true)) (EIf (EBinOp "/=" (EApp (EVar "listLen") (EVar "args")) (EApp (EVar "listLen") (EVar "typarams"))) (EVar "None") (EIf (EVar "otherwise") (EApp (EApp (EVar "mapAll") (ELam ((PVar "p")) (EApp (EApp (EApp (EVar "lookupPos") (EVar "p")) (EVar "typarams")) (EVar "args")))) (EVar "params")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "predicateSlotOfNode" (TyFun (TyApp (TyCon "SuperNode") (TyApp (TyCon "List") (TyCon "Mono"))) (TyCon "PredicateSlot")))
(DFunDef false "predicateSlotOfNode" ((PVar "n")) (ERecordCreate "PredicateSlot" ((fa "psIface" (EFieldAccess (EVar "n") "superIface")) (fa "psArgs" (EApp (EVar "PSArgsKnown") (EFieldAccess (EVar "n") "superPayload"))) (fa "psBoundIds" (EApp (EVar "dedupI") (EApp (EApp (EVar "flatMap") (EVar "monoTyvarIds")) (EFieldAccess (EVar "n") "superPayload")))))))
(DTypeSig true "goalMatchesGiven" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ScopeId") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))))
(DFunDef false "goalMatchesGiven" ((PVar "gctx") PWild PWild (PList)) (EVar "False"))
(DFunDef false "goalMatchesGiven" ((PVar "gctx") (PVar "scope") (PVar "iface") (PVar "args")) (EApp (EApp (EApp (EApp (EVar "anyGivenMatches") (EVar "gctx")) (ERecordCreate "PredicateRequest" ((fa "prIface" (EVar "iface")) (fa "prArgs" (EApp (EVar "PSArgsKnown") (EVar "args")))))) (EVar "scope")) (EApp (EApp (EVar "givensForScope") (EVar "gctx")) (EVar "scope"))))
(DTypeSig true "anyGivenMatches" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PredicateRequest") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyCon "GivenEntry")) (TyCon "Bool"))))))
(DFunDef false "anyGivenMatches" ((PVar "gctx") (PVar "request") (PVar "scope") (PVar "givens")) (EApp (EApp (EApp (EVar "anyGivenOnChain") (EVar "request")) (EApp (EApp (EVar "Scopes.visibleChain") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))) (EVar "scope"))) (EVar "givens")))
(DTypeSig false "anyGivenOnChain" (TyFun (TyCon "PredicateRequest") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "GivenEntry")) (TyCon "Bool")))))
(DFunDef false "anyGivenOnChain" (PWild PWild (PList)) (EVar "False"))
(DFunDef false "anyGivenOnChain" ((PVar "request") (PVar "chain") (PCons (PVar "g") (PVar "rest"))) (EBinOp "||" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "givenInScope") (EVar "GSPredicateOnly")) (EVar "g")) (EApp (EApp (EVar "Scopes.visibleOnChain") (EVar "chain")) (EApp (EVar "Scopes.binderScope") (EFieldAccess (EVar "g") "geBinder")))) (EApp (EApp (EVar "predicateRequestMatchesSlot") (EVar "request")) (EFieldAccess (EVar "g") "geSlot"))) (EApp (EApp (EApp (EVar "anyGivenOnChain") (EVar "request")) (EVar "chain")) (EVar "rest"))))
(DTypeSig true "registerActiveDictVars" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ScopeId") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PredicateSlot")) (TyCon "Unit"))))))
(DFunDef false "registerActiveDictVars" ((PVar "gctx") PWild PWild (PList)) (ELit LUnit))
(DFunDef false "registerActiveDictVars" ((PVar "gctx") (PVar "scope") (PVar "slot") (PCons (PVar "s") (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "registerEachActive") (EVar "gctx")) (EFieldAccess (EVar "s") "psBoundIds")) (EApp (EApp (EVar "Scopes.binderAt") (EVar "scope")) (EVar "slot")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "registerActiveDictVars") (EVar "gctx")) (EVar "scope")) (EBinOp "+" (EVar "slot") (ELit (LInt 1)))) (EVar "rest")))))
# MARK
(DUse false (UseGroup ("types" "tc_types") ((mem "AssumAnswer" true) (mem "AssumptionTraceEntry" true) (mem "AssumptionTraceKind" true) (mem "GivenEntry" true) (mem "GivenMatch" true) (mem "GivenProvenance" true) (mem "GivenScope" true) (mem "PredicateRequest" true) (mem "PredicateSlot" true) (mem "PredicateSlotArgs" true) (mem "GraphCtx" false) (mem "MethodBodyInstance" false) (mem "ModuleCtx" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "containsI" false) (mem "dedupI" false) (mem "isBareTyvarMono" false) (mem "monoTyvarIds" false) (mem "monoVecSameGiven" false) (mem "peelQual" false) (mem "tyvarId" false) (mem "oblArgKey" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "currentScopeStore" false) (mem "renderEvidenceBinder" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "methodLevelConstraintVarNames" false) (mem "oblIfaceKey" false) (mem "sameIfaceDecl" false) (mem "superLookup" false))))
(DUse false (UseGroup ("types" "tc_decls_types") ((mem "fromAstType" false))))
(DUse false (UseGroup ("types" "tc_decls") ((mem "constraintIface" false) (mem "constraintIsMethodLevel" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "TyConOrigin" true) (mem "Constraint" true) (mem "Route" true) (mem "Super" true) (mem "Ty" true))))
(DUse false (UseGroup ("types" "evidence") ((mem "EvidenceBinderId" true) (mem "ScopeId" true) (mem "SolverEvidence" true))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Mono" true) (mem "lookupAssocI" false) (mem "normalize" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omInsert" false) (mem "omLookup" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("types" "superclass") ((mem "SuperNode" true) (mem "lookupPos" false) (mem "mapAll" false) (mem "superClosure" false))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "isSome" false) (mem "listLen" false) (mem "lookupAssoc" false) (mem "orElseOpt" false))))
(DUse false (UseGroup ("list") ((mem "drop" false) (mem "elemIndex" false))))
(DUse false (UseGroup ("string") ((mem "join" false))))
(DUse false (UseGroup ("types" "registry") ((mem "regKeyOfTab" false) (mem "regKeyRender" false))))
(DUse false (UseAlias ("types" "scopes") "Scopes"))
(DTypeSig true "predicateSlotIds" (TyFun (TyApp (TyCon "List") (TyCon "PredicateSlot")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "predicateSlotIds" ((PList)) (EListLit))
(DFunDef false "predicateSlotIds" ((PCons (PVar "s") (PVar "rest"))) (EMatch (EFieldAccess (EVar "s") "psBoundIds") (arm (PList) () (EApp (EVar "predicateSlotIds") (EVar "rest"))) (arm (PCons (PVar "id") PWild) () (EBinOp "::" (EVar "id") (EApp (EVar "predicateSlotIds") (EVar "rest"))))))
(DTypeSig true "lookupPredicateSlots" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "PredicateSlot"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "PredicateSlot"))))))
(DFunDef false "lookupPredicateSlots" ((PVar "k") (PVar "idx")) (EApp (EApp (EVar "omLookup") (EVar "k")) (EVar "idx")))
(DTypeSig true "predicateSlotIdsAt" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "PredicateSlot"))) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "predicateSlotIdsAt" ((PVar "name") (PVar "idx")) (EApp (EVar "predicateSlotIds") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "idx")))))
(DTypeSig false "assumAnswerBinder" (TyFun (TyCon "AssumAnswer") (TyCon "EvidenceBinderId")))
(DFunDef false "assumAnswerBinder" ((PCon "SemanticGiven" (PVar "evidence"))) (EApp (EVar "givenEvidenceBinder") (EVar "evidence")))
(DFunDef false "assumAnswerBinder" ((PCon "LegacyScalar" (PVar "binder"))) (EVar "binder"))
(DFunDef false "assumAnswerBinder" ((PCon "LegacyPredicate" (PVar "binder"))) (EVar "binder"))
(DFunDef false "assumAnswerBinder" ((PCon "LegacyProjected" (PVar "binder") PWild)) (EVar "binder"))
(DTypeSig true "assumAnswerEvidence" (TyFun (TyCon "AssumAnswer") (TyCon "SolverEvidence")))
(DFunDef false "assumAnswerEvidence" ((PCon "SemanticGiven" (PVar "evidence"))) (EVar "evidence"))
(DFunDef false "assumAnswerEvidence" ((PCon "LegacyScalar" (PVar "binder"))) (EApp (EVar "GivenEvidence") (EVar "binder")))
(DFunDef false "assumAnswerEvidence" ((PCon "LegacyPredicate" (PVar "binder"))) (EApp (EVar "GivenEvidence") (EVar "binder")))
(DFunDef false "assumAnswerEvidence" ((PCon "LegacyProjected" (PVar "binder") (PVar "path"))) (EApp (EApp (EVar "SuperclassEvidence") (EVar "binder")) (EVar "path")))
(DTypeSig false "assumAnswerKind" (TyFun (TyCon "AssumAnswer") (TyCon "AssumptionTraceKind")))
(DFunDef false "assumAnswerKind" ((PCon "SemanticGiven" (PCon "SuperclassEvidence" PWild PWild))) (EVar "ATSuperclassProjection"))
(DFunDef false "assumAnswerKind" ((PCon "SemanticGiven" PWild)) (EVar "ATDirectPredicate"))
(DFunDef false "assumAnswerKind" ((PCon "LegacyScalar" PWild)) (EVar "ATLegacyScalar"))
(DFunDef false "assumAnswerKind" ((PCon "LegacyPredicate" PWild)) (EVar "ATLegacyPredicate"))
(DFunDef false "assumAnswerKind" ((PCon "LegacyProjected" PWild PWild)) (EVar "ATLegacyPredicate"))
(DTypeSig false "givenEvidenceBinder" (TyFun (TyCon "SolverEvidence") (TyCon "EvidenceBinderId")))
(DFunDef false "givenEvidenceBinder" ((PCon "GivenEvidence" (PVar "binder"))) (EVar "binder"))
(DFunDef false "givenEvidenceBinder" ((PCon "SuperclassEvidence" (PVar "parent") PWild)) (EVar "parent"))
(DFunDef false "givenEvidenceBinder" (PWild) (EApp (EVar "panic") (ELit (LString "non-given assumption evidence"))))
(DTypeSig true "assumAnswerRoute" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "AssumAnswer") (TyFun (TyApp (TyCon "Option") (TyCon "IfaceRef")) (TyFun (TyCon "ScopeId") (TyFun (TyFun (TyCon "String") (TyCon "Route")) (TyCon "Route")))))))
(DFunDef false "assumAnswerRoute" ((PVar "gctx") (PCon "SemanticGiven" (PCon "SuperclassEvidence" (PVar "parent") (PVar "path"))) PWild PWild (PVar "paramRoute")) (EApp (EApp (EVar "RProj") (EApp (EVar "paramRoute") (EApp (EApp (EVar "renderEvidenceBinder") (EVar "gctx")) (EVar "parent")))) (EVar "path")))
(DFunDef false "assumAnswerRoute" ((PVar "gctx") (PCon "LegacyProjected" (PVar "parent") (PVar "path")) PWild PWild (PVar "paramRoute")) (EApp (EApp (EVar "RProj") (EApp (EVar "paramRoute") (EApp (EApp (EVar "renderEvidenceBinder") (EVar "gctx")) (EVar "parent")))) (EVar "path")))
(DFunDef false "assumAnswerRoute" ((PVar "gctx") (PCon "LegacyScalar" (PVar "binder")) (PCon "Some" (PVar "goalIface")) (PVar "useScope") (PVar "paramRoute")) (EBlock (DoLet false false (PVar "base") (EApp (EVar "paramRoute") (EApp (EApp (EVar "renderEvidenceBinder") (EVar "gctx")) (EVar "binder")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "scalarGivenProjection") (EVar "gctx")) (EVar "binder")) (EVar "goalIface")) (EVar "useScope")) (arm (PCon "Some" (PVar "path")) () (EApp (EApp (EVar "RProj") (EVar "base")) (EVar "path"))) (arm (PCon "None") () (EVar "base"))))))
(DFunDef false "assumAnswerRoute" ((PVar "gctx") (PVar "answer") PWild PWild (PVar "paramRoute")) (EApp (EVar "paramRoute") (EApp (EApp (EVar "renderEvidenceBinder") (EVar "gctx")) (EApp (EVar "assumAnswerBinder") (EVar "answer")))))
(DTypeSig false "scalarGivenProjection" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvidenceBinderId") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "ScopeId") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "scalarGivenProjection" ((PVar "gctx") (PVar "binder") (PVar "goalIface") (PVar "useScope")) (EMatch (EApp (EApp (EVar "directGivenIfaceOf") (EVar "binder")) (EApp (EApp (EVar "givensForScope") (EVar "gctx")) (EVar "useScope"))) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "declared")) () (EIf (EBinOp "==" (EFieldAccess (EVar "declared") "irName") (EFieldAccess (EVar "goalIface") "irName")) (EVar "None") (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EApp (EApp (EVar "drop") (ELit (LInt 1))) (EFieldAccess (EVar "n") "superPath")))) (EApp (EApp (EDictApp "find") (ELam ((PVar "n")) (EBinOp "==" (EFieldAccess (EFieldAccess (EVar "n") "superIface") "irName") (EFieldAccess (EVar "goalIface") "irName")))) (EApp (EApp (EApp (EApp (EVar "superClosure") (EApp (EVar "superLookup") (EVar "gctx"))) (ELam (PWild PWild PWild) (EApp (EVar "Some") (ELit LUnit)))) (ELam ((PVar "ir") PWild) (EApp (EVar "regKeyRender") (EApp (EVar "regKeyOfTab") (EApp (EVar "oblIfaceKey") (EVar "ir")))))) (EListLit (ETuple (EVar "declared") (ELit LUnit))))))))))
(DTypeSig true "scalarGivenAnswers" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvidenceBinderId") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "ScopeId") (TyCon "Bool"))))))
(DFunDef false "scalarGivenAnswers" ((PVar "gctx") (PVar "binder") (PVar "goalIface") (PVar "useScope")) (EBinOp "||" (EBinOp "==" (EFieldAccess (EVar "goalIface") "irName") (ELit (LString ""))) (EMatch (EApp (EApp (EVar "directGivenIfaceOf") (EVar "binder")) (EApp (EApp (EVar "givensForScope") (EVar "gctx")) (EVar "useScope"))) (arm (PCon "None") () (EVar "True")) (arm (PCon "Some" (PVar "declared")) () (EBinOp "||" (EApp (EApp (EVar "sameIfaceOrUnresolved") (EVar "declared")) (EVar "goalIface")) (EApp (EVar "isSome") (EApp (EApp (EApp (EApp (EVar "scalarGivenProjection") (EVar "gctx")) (EVar "binder")) (EVar "goalIface")) (EVar "useScope"))))))))
(DTypeSig false "sameIfaceOrUnresolved" (TyFun (TyCon "IfaceRef") (TyFun (TyCon "IfaceRef") (TyCon "Bool"))))
(DFunDef false "sameIfaceOrUnresolved" ((PVar "a") (PVar "b")) (EMatch (ETuple (EFieldAccess (EVar "a") "irOrigin") (EFieldAccess (EVar "b") "irOrigin")) (arm (PTuple (PCon "OriginUnresolved") PWild) () (EBinOp "==" (EFieldAccess (EVar "a") "irName") (EFieldAccess (EVar "b") "irName"))) (arm (PTuple PWild (PCon "OriginUnresolved")) () (EBinOp "==" (EFieldAccess (EVar "a") "irName") (EFieldAccess (EVar "b") "irName"))) (arm PWild () (EApp (EApp (EVar "sameIfaceDecl") (EVar "a")) (EVar "b")))))
(DTypeSig false "directGivenIfaceOf" (TyFun (TyCon "EvidenceBinderId") (TyFun (TyApp (TyCon "List") (TyCon "GivenEntry")) (TyApp (TyCon "Option") (TyCon "IfaceRef")))))
(DFunDef false "directGivenIfaceOf" (PWild (PList)) (EVar "None"))
(DFunDef false "directGivenIfaceOf" ((PVar "binder") (PCons (PVar "g") (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "g") "geBinder") (EVar "binder")) (EBinOp "==" (EFieldAccess (EVar "g") "geProvenance") (EVar "DirectGiven"))) (EApp (EVar "Some") (EFieldAccess (EFieldAccess (EVar "g") "geSlot") "psIface")) (EIf (EVar "otherwise") (EApp (EApp (EVar "directGivenIfaceOf") (EVar "binder")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "projectedGivenOf" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvidenceBinderId") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "GivenEntry"))))))
(DFunDef false "projectedGivenOf" ((PVar "gctx") (PVar "parent") (PVar "path")) (EApp (EApp (EDictApp "find") (ELam ((PVar "g")) (EBinOp "==" (EFieldAccess (EVar "g") "geProvenance") (EApp (EApp (EVar "ProjectedGiven") (EVar "parent")) (EVar "path"))))) (EApp (EApp (EVar "givensForScope") (EVar "gctx")) (EApp (EVar "Scopes.binderScope") (EVar "parent")))))
(DTypeSig true "noteAssumption" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ScopeId") (TyFun (TyCon "AssumAnswer") (TyCon "Unit")))))
(DFunDef false "noteAssumption" ((PVar "gctx") (PVar "scope") (PVar "answer")) (EMatch (EFieldAccess (EVar "gctx") "trace") (arm (PCon "Some" (PVar "sink")) () (EIf (EFieldAccess (EVar "sink") "tsAssumptionEnabled") (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "sink") "tsAssumptionEntries")) (EBinOp "::" (ERecordCreate "AssumptionTraceEntry" ((fa "atGoalScope" (EVar "scope")) (fa "atBinder" (EApp (EVar "assumAnswerBinder") (EVar "answer"))) (fa "atKind" (EApp (EVar "assumAnswerKind") (EVar "answer"))))) (EFieldAccess (EFieldAccess (EVar "sink") "tsAssumptionEntries") "value"))) (ELit LUnit))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig true "givensForScope" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ScopeId") (TyApp (TyCon "List") (TyCon "GivenEntry")))))
(DFunDef false "givensForScope" ((PVar "gctx") (PVar "sid")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EFieldAccess (EApp (EApp (EVar "Scopes.scopeFrame") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))) (EVar "sid")) "sfModuleId")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "gGiven") "value"))))
(DTypeSig true "pushGiven" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "GivenMatch") (TyFun (TyCon "GivenProvenance") (TyFun (TyCon "PredicateSlot") (TyFun (TyCon "EvidenceBinderId") (TyCon "Unit")))))))
(DFunDef false "pushGiven" ((PVar "gctx") (PVar "gm") (PVar "provenance") (PVar "slot") (PVar "binder")) (EBlock (DoLet false false (PVar "mid") (EFieldAccess (EApp (EApp (EVar "Scopes.scopeFrame") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))) (EApp (EVar "Scopes.binderScope") (EVar "binder"))) "sfModuleId")) (DoLet false false (PVar "entry") (ERecordCreate "GivenEntry" ((fa "geSlot" (EVar "slot")) (fa "geBinder" (EVar "binder")) (fa "geMatch" (EVar "gm")) (fa "geProvenance" (EVar "provenance"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "gGiven")) (EApp (EApp (EApp (EVar "omInsert") (EVar "mid")) (EBinOp "::" (EVar "entry") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "gGiven") "value"))))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "gGiven") "value"))))))
(DTypeSig true "givenInScope" (TyFun (TyCon "GivenScope") (TyFun (TyCon "GivenEntry") (TyCon "Bool"))))
(DFunDef false "givenInScope" ((PCon "GSPredicateOnly") (PVar "g")) (EMatch (EFieldAccess (EVar "g") "geMatch") (arm (PCon "GMPredicate") () (EVar "True")) (arm (PCon "GMIdWitnessed") () (EVar "False"))))
(DFunDef false "givenInScope" ((PCon "GSImplRequires") (PVar "g")) (EMatch (EFieldAccess (EVar "g") "geMatch") (arm (PCon "GMIdWitnessed") () (EVar "True")) (arm (PCon "GMPredicate") () (EVar "False"))))
(DTypeSig true "givenRoute" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Bool") (TyFun (TyCon "EvidenceBinderId") (TyCon "Route")))))
(DFunDef false "givenRoute" ((PVar "gctx") (PVar "isReturnPosition") (PVar "binder")) (EIf (EVar "isReturnPosition") (EApp (EVar "RDictFwd") (EApp (EApp (EVar "renderEvidenceBinder") (EVar "gctx")) (EVar "binder"))) (EApp (EVar "RDict") (EApp (EApp (EVar "renderEvidenceBinder") (EVar "gctx")) (EVar "binder")))))
(DTypeSig true "activeDictVarOf" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "ScopeId") (TyApp (TyCon "Option") (TyCon "EvidenceBinderId"))))))
(DFunDef false "activeDictVarOf" ((PVar "gctx") (PVar "m") (PVar "useScope")) (EMatch (EApp (EVar "peelQual") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EApp (EApp (EApp (EApp (EVar "firstDictForEncl") (EVar "gctx")) (EApp (EVar "tyvarId") (EVar "cell"))) (EVar "useScope")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "activeDictVars") "value"))) (arm (PCon "TApp" (PVar "a") PWild) () (EApp (EApp (EApp (EVar "activeDictVarOf") (EVar "gctx")) (EVar "a")) (EVar "useScope"))) (arm PWild () (EVar "None"))))
(DTypeSig true "activeDictVarAnswering" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "ScopeId") (TyFun (TyFun (TyCon "EvidenceBinderId") (TyCon "Bool")) (TyApp (TyCon "Option") (TyCon "EvidenceBinderId")))))))
(DFunDef false "activeDictVarAnswering" ((PVar "gctx") (PVar "m") (PVar "useScope") (PVar "answers")) (EMatch (EApp (EVar "peelQual") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EApp (EApp (EDictApp "find") (ELam ((PVar "b")) (EApp (EVar "answers") (EVar "b")))) (EApp (EApp (EApp (EApp (EVar "visibleDictsFor") (EVar "gctx")) (EApp (EVar "tyvarId") (EVar "cell"))) (EVar "useScope")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "activeDictVars") "value")))) (arm (PCon "TApp" (PVar "a") PWild) () (EApp (EApp (EApp (EApp (EVar "activeDictVarAnswering") (EVar "gctx")) (EVar "a")) (EVar "useScope")) (EVar "answers"))) (arm PWild () (EVar "None"))))
(DTypeSig false "visibleDictsFor" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "EvidenceBinderId"))) (TyApp (TyCon "List") (TyCon "EvidenceBinderId")))))))
(DFunDef false "visibleDictsFor" ((PVar "gctx") PWild PWild (PList)) (EListLit))
(DFunDef false "visibleDictsFor" ((PVar "gctx") (PVar "id") (PVar "useScope") (PCons (PTuple (PVar "eid") (PVar "binder")) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "eid") (EVar "id")) (EApp (EApp (EApp (EVar "Scopes.givenVisibleFrom") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))) (EVar "useScope")) (EApp (EVar "Scopes.binderScope") (EVar "binder")))) (EBinOp "::" (EVar "binder") (EApp (EApp (EApp (EApp (EVar "visibleDictsFor") (EVar "gctx")) (EVar "id")) (EVar "useScope")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "visibleDictsFor") (EVar "gctx")) (EVar "id")) (EVar "useScope")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "firstDictForEncl" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "EvidenceBinderId"))) (TyApp (TyCon "Option") (TyCon "EvidenceBinderId")))))))
(DFunDef false "firstDictForEncl" ((PVar "gctx") PWild PWild (PList)) (EVar "None"))
(DFunDef false "firstDictForEncl" ((PVar "gctx") (PVar "id") (PVar "useScope") (PCons (PTuple (PVar "eid") (PVar "binder")) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "eid") (EVar "id")) (EApp (EApp (EApp (EVar "Scopes.givenVisibleFrom") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))) (EVar "useScope")) (EApp (EVar "Scopes.binderScope") (EVar "binder")))) (EApp (EVar "Some") (EVar "binder")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "firstDictForEncl") (EVar "gctx")) (EVar "id")) (EVar "useScope")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "activeDictVarOfEncl" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "PredicateRequest")) (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyApp (TyCon "Option") (TyCon "AssumAnswer"))))))))
(DFunDef false "activeDictVarOfEncl" ((PVar "mctx") (PCon "None") (PVar "m") (PVar "encl") (PVar "useScope")) (EApp (EApp (EMethodRef "map") (EVar "LegacyScalar")) (EApp (EApp (EApp (EVar "activeDictVarOf") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "m")) (EVar "useScope"))))
(DFunDef false "activeDictVarOfEncl" ((PVar "mctx") (PCon "Some" (PVar "request")) (PVar "m") (PVar "encl") (PVar "useScope")) (EApp (EApp (EVar "orElseOpt") (EApp (EApp (EMethodRef "map") (EVar "LegacyScalar")) (EApp (EApp (EApp (EApp (EApp (EVar "enclDictVarOf") (EVar "mctx")) (EApp (EVar "Some") (EVar "request"))) (EVar "m")) (EVar "encl")) (EVar "useScope")))) (EApp (EApp (EApp (EApp (EVar "implReqDictVarOf") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EVar "Some") (EVar "request"))) (EVar "m")) (EVar "useScope"))))
(DTypeSig true "implReqDictVarOf" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "Option") (TyCon "PredicateRequest")) (TyFun (TyCon "Mono") (TyFun (TyCon "ScopeId") (TyApp (TyCon "Option") (TyCon "AssumAnswer")))))))
(DFunDef false "implReqDictVarOf" ((PVar "gctx") (PCon "None") PWild PWild) (EVar "None"))
(DFunDef false "implReqDictVarOf" ((PVar "gctx") (PCon "Some" (PVar "request")) (PVar "m") (PVar "useScope")) (EMatch (EApp (EVar "peelQual") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "firstPredForEnclAt") (EVar "gctx")) (EVar "GSImplRequires")) (EApp (EVar "tyvarId") (EVar "cell"))) (EVar "request")) (EVar "useScope")) (EApp (EApp (EVar "givensForScope") (EVar "gctx")) (EVar "useScope")))) (arm (PCon "TApp" (PVar "a") PWild) () (EApp (EApp (EApp (EApp (EVar "implReqDictVarOf") (EVar "gctx")) (EApp (EVar "Some") (EVar "request"))) (EVar "a")) (EVar "useScope"))) (arm PWild () (EVar "None"))))
(DTypeSig true "enclDictVarOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "PredicateRequest")) (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyApp (TyCon "Option") (TyCon "EvidenceBinderId"))))))))
(DFunDef false "enclDictVarOf" ((PVar "mctx") (PVar "goal") (PVar "m") (PVar "encl") (PVar "useScope")) (EIf (EBinOp "==" (EVar "encl") (ELit (LString ""))) (EVar "None") (EIf (EVar "otherwise") (EMatch (EApp (EVar "peelQual") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EApp (EApp (EMethodRef "map") (EApp (EVar "Scopes.binderAt") (EApp (EApp (EVar "Scopes.declarationScope") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EVar "useScope")))) (EApp (EApp (EApp (EApp (EVar "enclSlotIndex") (EVar "mctx")) (EVar "goal")) (EApp (EVar "tyvarId") (EVar "cell"))) (EVar "encl")))) (arm (PCon "TApp" (PVar "a") PWild) () (EApp (EApp (EApp (EApp (EApp (EVar "enclDictVarOf") (EVar "mctx")) (EVar "goal")) (EVar "a")) (EVar "encl")) (EVar "useScope"))) (arm PWild () (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "enclSlotIndex" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "PredicateRequest")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "enclSlotIndex" ((PVar "mctx") (PCon "None") (PVar "target") (PVar "encl")) (EApp (EApp (EVar "elemIndex") (EVar "target")) (EApp (EApp (EVar "enclSlotIds") (EVar "mctx")) (EVar "encl"))))
(DFunDef false "enclSlotIndex" ((PVar "mctx") (PCon "Some" (PVar "request")) (PVar "target") (PVar "encl")) (EApp (EApp (EApp (EVar "indexOfPred") (EVar "target")) (EVar "request")) (EApp (EApp (EVar "enclPreds") (EVar "mctx")) (EVar "encl"))))
(DTypeSig false "enclSlotIds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "enclSlotIds" ((PVar "mctx") (PVar "encl")) (EApp (EApp (EVar "predicateSlotIdsAt") (EVar "encl")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funPredicateSlotsIdxRef") "value")))
(DTypeSig false "enclPreds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "PredicateSlot")))))
(DFunDef false "enclPreds" ((PVar "mctx") (PVar "encl")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "lookupPredicateSlots") (EVar "encl")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funPredicateSlotsIdxRef") "value"))))
(DTypeSig false "indexOfPred" (TyFun (TyCon "Int") (TyFun (TyCon "PredicateRequest") (TyFun (TyApp (TyCon "List") (TyCon "PredicateSlot")) (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "indexOfPred" ((PVar "target") (PVar "request") (PVar "preds")) (EApp (EApp (EApp (EApp (EVar "indexOfPredGo") (ELit (LInt 0))) (EVar "target")) (EVar "request")) (EVar "preds")))
(DTypeSig false "indexOfPredGo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "PredicateRequest") (TyFun (TyApp (TyCon "List") (TyCon "PredicateSlot")) (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "indexOfPredGo" (PWild PWild PWild (PList)) (EVar "None"))
(DFunDef false "indexOfPredGo" ((PVar "i") (PVar "target") (PVar "request") (PCons (PVar "sp") (PVar "rest"))) (EIf (EBinOp "&&" (EApp (EApp (EVar "containsI") (EVar "target")) (EFieldAccess (EVar "sp") "psBoundIds")) (EApp (EApp (EVar "predicateRequestMatchesSlot") (EVar "request")) (EVar "sp"))) (EApp (EVar "Some") (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "indexOfPredGo") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "target")) (EVar "request")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "predicateRequestMatchesSlot" (TyFun (TyCon "PredicateRequest") (TyFun (TyCon "PredicateSlot") (TyCon "Bool"))))
(DFunDef false "predicateRequestMatchesSlot" ((PVar "request") (PVar "slot")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "/=" (EFieldAccess (EFieldAccess (EVar "request") "prIface") "irName") (ELit (LString ""))) (EBinOp "/=" (EFieldAccess (EFieldAccess (EVar "slot") "psIface") "irName") (ELit (LString "")))) (EApp (EApp (EVar "sameIfaceDecl") (EFieldAccess (EVar "request") "prIface")) (EFieldAccess (EVar "slot") "psIface"))) (EApp (EApp (EVar "predicateRequestArgsMatch") (EFieldAccess (EVar "request") "prArgs")) (EFieldAccess (EVar "slot") "psArgs"))))
(DTypeSig false "predicateRequestArgsMatch" (TyFun (TyCon "PredicateSlotArgs") (TyFun (TyCon "PredicateSlotArgs") (TyCon "Bool"))))
(DFunDef false "predicateRequestArgsMatch" ((PCon "PSArgsKnown" (PVar "requestArgs")) (PCon "PSArgsKnown" (PVar "slotArgs"))) (EApp (EApp (EVar "monoVecSameGiven") (EVar "requestArgs")) (EVar "slotArgs")))
(DFunDef false "predicateRequestArgsMatch" (PWild PWild) (EVar "True"))
(DTypeSig true "enclSlot" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "enclSlot" ((PVar "mctx") (PVar "encl") (PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EApp (EApp (EVar "elemIndex") (EApp (EVar "tyvarId") (EVar "cell"))) (EApp (EApp (EVar "predicateSlotIdsAt") (EVar "encl")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funPredicateSlotsIdxRef") "value")))) (arm PWild () (EVar "None"))))
(DTypeSig false "methodLevelPredicateSlots" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "PredicateSlot")))))))
(DFunDef false "methodLevelPredicateSlots" ((PVar "mctx") (PVar "typarams") (PCon "TyConstrained" (PVar "cs") (PVar "t")) (PVar "tvMap")) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "methodLevelPredicateSlot") (EVar "mctx")) (EVar "typarams")) (EVar "tvMap"))) (EVar "cs")) (EApp (EApp (EApp (EApp (EVar "methodLevelPredicateSlots") (EVar "mctx")) (EVar "typarams")) (EVar "t")) (EVar "tvMap"))))
(DFunDef false "methodLevelPredicateSlots" ((PVar "mctx") (PVar "typarams") (PCon "TyEffect" PWild PWild (PVar "t")) (PVar "tvMap")) (EApp (EApp (EApp (EApp (EVar "methodLevelPredicateSlots") (EVar "mctx")) (EVar "typarams")) (EVar "t")) (EVar "tvMap")))
(DFunDef false "methodLevelPredicateSlots" ((PVar "mctx") PWild PWild PWild) (EListLit))
(DTypeSig false "methodLevelPredicateSlot" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyCon "PredicateSlot")))))))
(DFunDef false "methodLevelPredicateSlot" ((PVar "mctx") (PVar "typarams") (PVar "tvMap") (PVar "c")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "constraintIsMethodLevel") (EVar "typarams")) (EVar "c"))) (EListLit) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "args") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "fromAstType") (EVar "mctx")) (EVar "tvMap"))) (EFieldAccess (EVar "c") "constraintArgs"))) (DoExpr (EListLit (ERecordCreate "PredicateSlot" ((fa "psIface" (ERecordCreate "IfaceRef" ((fa "irName" (EApp (EVar "constraintIface") (EVar "c"))) (fa "irOrigin" (EFieldAccess (EVar "c") "constraintOrigin"))))) (fa "psArgs" (EApp (EVar "PSArgsKnown") (EVar "args"))) (fa "psBoundIds" (EApp (EVar "dedupI") (EApp (EApp (EDictApp "flatMap") (EVar "monoTyvarIds")) (EVar "args"))))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "goalGivenAt" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ScopeId") (TyCon "Bool"))))))
(DFunDef false "goalGivenAt" ((PVar "gctx") (PVar "iface") (PVar "args") (PVar "scope")) (EBinOp "||" (EApp (EVar "isSome") (EApp (EApp (EApp (EVar "activeFunDictPredOf") (EVar "gctx")) (ERecordCreate "PredicateRequest" ((fa "prIface" (EVar "iface")) (fa "prArgs" (EApp (EVar "PSArgsKnown") (EVar "args")))))) (EVar "scope"))) (EApp (EApp (EApp (EApp (EVar "goalMatchesGiven") (EVar "gctx")) (EVar "scope")) (EVar "iface")) (EVar "args"))))
(DTypeSig true "registerMethodDictSlots" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ScopeId") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyCon "Unit")))))))
(DFunDef false "registerMethodDictSlots" ((PVar "gctx") PWild PWild (PList) PWild) (ELit LUnit))
(DFunDef false "registerMethodDictSlots" ((PVar "gctx") (PVar "scope") (PVar "slot") (PCons (PVar "id") (PVar "rest")) (PVar "subst")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "registerOneMethodDict") (EVar "gctx")) (EVar "scope")) (EVar "slot")) (EVar "id")) (EVar "subst"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "registerMethodDictSlots") (EVar "gctx")) (EVar "scope")) (EBinOp "+" (EVar "slot") (ELit (LInt 1)))) (EVar "rest")) (EVar "subst")))))
(DTypeSig false "registerOneMethodDict" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ScopeId") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyCon "Unit")))))))
(DFunDef false "registerOneMethodDict" ((PVar "gctx") (PVar "scope") (PVar "slot") (PVar "id") (PVar "subst")) (EMatch (EApp (EApp (EVar "lookupAssocI") (EVar "id")) (EVar "subst")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "m")) () (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "activeDictVars")) (EBinOp "::" (ETuple (EApp (EVar "tyvarId") (EVar "cell")) (EApp (EApp (EVar "Scopes.binderAt") (EVar "scope")) (EVar "slot"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "activeDictVars") "value")))) (arm PWild () (ELit LUnit))))))
(DTypeSig true "publishMethodPredGivens" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyFun (TyCon "MethodBodyInstance") (TyFun (TyCon "ScopeId") (TyCon "Unit")))))))
(DFunDef false "publishMethodPredGivens" ((PVar "mctx") (PVar "params") (PVar "mty") (PVar "inst") (PVar "scope")) (EApp (EApp (EApp (EApp (EVar "registerSlotPredGivens") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "scope")) (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EVar "methodLevelPredicateSlots") (EVar "mctx")) (EVar "params")) (EVar "mty")) (EFieldAccess (EVar "inst") "mbiNamedVars"))))
(DTypeSig true "givenAnswers" (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "PredicateSlot") (TyCon "Bool")))))
(DFunDef false "givenAnswers" ((PVar "iface") (PVar "args") (PVar "slot")) (EBinOp "&&" (EApp (EApp (EVar "sameIfaceDecl") (EFieldAccess (EVar "slot") "psIface")) (EVar "iface")) (EMatch (EFieldAccess (EVar "slot") "psArgs") (arm (PCon "PSArgsKnown" (PVar "gargs")) () (EApp (EApp (EVar "monoVecSameGiven") (EVar "gargs")) (EVar "args"))) (arm (PCon "PSArgsUnknown") () (EVar "False")))))
(DTypeSig true "registerImplMethodDicts" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyCon "Unit")))))))
(DFunDef false "registerImplMethodDicts" ((PVar "gctx") (PVar "scope") (PVar "ifaceParams") (PVar "mty") (PVar "tvMap")) (EApp (EApp (EApp (EApp (EApp (EVar "registerImplMethodDictsGo") (EVar "gctx")) (EVar "scope")) (ELit (LInt 0))) (EApp (EApp (EVar "methodLevelConstraintVarNames") (EVar "ifaceParams")) (EVar "mty"))) (EVar "tvMap")))
(DTypeSig false "registerImplMethodDictsGo" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ScopeId") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyCon "Unit")))))))
(DFunDef false "registerImplMethodDictsGo" ((PVar "gctx") PWild PWild (PList) PWild) (ELit LUnit))
(DFunDef false "registerImplMethodDictsGo" ((PVar "gctx") (PVar "scope") (PVar "slot") (PCons (PVar "vname") (PVar "rest")) (PVar "tvMap")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "registerImplMethodDictOne") (EVar "gctx")) (EVar "scope")) (EVar "slot")) (EVar "vname")) (EVar "tvMap"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "registerImplMethodDictsGo") (EVar "gctx")) (EVar "scope")) (EBinOp "+" (EVar "slot") (ELit (LInt 1)))) (EVar "rest")) (EVar "tvMap")))))
(DTypeSig false "registerImplMethodDictOne" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ScopeId") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyCon "Unit")))))))
(DFunDef false "registerImplMethodDictOne" ((PVar "gctx") (PVar "scope") (PVar "slot") (PVar "vname") (PVar "tvMap")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "vname")) (EVar "tvMap")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "m")) () (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "activeDictVars")) (EBinOp "::" (ETuple (EApp (EVar "tyvarId") (EVar "cell")) (EApp (EApp (EVar "Scopes.binderAt") (EVar "scope")) (EVar "slot"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "activeDictVars") "value")))) (arm PWild () (ELit LUnit))))))
(DTypeSig true "registerPredGiven" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "EvidenceBinderId") (TyCon "Unit"))))))
(DFunDef false "registerPredGiven" ((PVar "gctx") PWild (PList) PWild) (ELit LUnit))
(DFunDef false "registerPredGiven" ((PVar "gctx") (PVar "iface") (PVar "args") (PVar "dname")) (EIf (EApp (EApp (EVar "allList") (EVar "isBareTyvarMono")) (EVar "args")) (ELit LUnit) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "slot") (ERecordCreate "PredicateSlot" ((fa "psIface" (EVar "iface")) (fa "psArgs" (EApp (EVar "PSArgsKnown") (EVar "args"))) (fa "psBoundIds" (EApp (EVar "dedupI") (EApp (EApp (EDictApp "flatMap") (EVar "monoTyvarIds")) (EVar "args"))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "pushGiven") (EVar "gctx")) (EVar "GMPredicate")) (EVar "DirectGiven")) (EVar "slot")) (EVar "dname")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "activeDictPredOf" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PredicateRequest") (TyFun (TyCon "Mono") (TyFun (TyCon "ScopeId") (TyApp (TyCon "Option") (TyCon "AssumAnswer")))))))
(DFunDef false "activeDictPredOf" ((PVar "gctx") (PVar "request") (PVar "targetMono") (PVar "useScope")) (EBlock (DoLet false false (PVar "preds") (EApp (EApp (EVar "givensForScope") (EVar "gctx")) (EVar "useScope"))) (DoExpr (EMatch (EFieldAccess (EVar "request") "prArgs") (arm (PCon "PSArgsKnown" PWild) () (EApp (EApp (EApp (EApp (EVar "firstPredForEncl") (EVar "gctx")) (EVar "request")) (EVar "useScope")) (EVar "preds"))) (arm (PCon "PSArgsUnknown") () (EMatch (EApp (EVar "predicateTargetId") (EVar "targetMono")) (arm (PCon "Some" (PVar "target")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "firstPredForEnclAt") (EVar "gctx")) (EVar "GSPredicateOnly")) (EVar "target")) (EVar "request")) (EVar "useScope")) (EVar "preds"))) (arm (PCon "None") () (EVar "None"))))))))
(DTypeSig false "predicateTargetId" (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "predicateTargetId" ((PVar "m")) (EMatch (EApp (EVar "peelQual") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EApp (EVar "Some") (EApp (EVar "tyvarId") (EVar "cell")))) (arm (PCon "TApp" (PVar "a") PWild) () (EApp (EVar "predicateTargetId") (EVar "a"))) (arm PWild () (EVar "None"))))
(DTypeSig true "activeFunDictPredOf" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PredicateRequest") (TyFun (TyCon "ScopeId") (TyApp (TyCon "Option") (TyCon "AssumAnswer"))))))
(DFunDef false "activeFunDictPredOf" ((PVar "gctx") (PVar "request") (PVar "useScope")) (EApp (EApp (EApp (EApp (EVar "firstPredForEncl") (EVar "gctx")) (EVar "request")) (EVar "useScope")) (EApp (EApp (EVar "givensForScope") (EVar "gctx")) (EVar "useScope"))))
(DTypeSig true "firstPredForEncl" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PredicateRequest") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyCon "GivenEntry")) (TyApp (TyCon "Option") (TyCon "AssumAnswer")))))))
(DFunDef false "firstPredForEncl" ((PVar "gctx") (PVar "request") (PVar "useScope") (PVar "givens")) (EApp (EApp (EApp (EVar "firstPredOnChain") (EVar "request")) (EApp (EApp (EVar "Scopes.visibleChain") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))) (EVar "useScope"))) (EVar "givens")))
(DTypeSig false "firstPredOnChain" (TyFun (TyCon "PredicateRequest") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "GivenEntry")) (TyApp (TyCon "Option") (TyCon "AssumAnswer"))))))
(DFunDef false "firstPredOnChain" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "firstPredOnChain" ((PVar "request") (PVar "chain") (PCons (PVar "g") (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "givenInScope") (EVar "GSPredicateOnly")) (EVar "g")) (EApp (EApp (EVar "Scopes.visibleOnChain") (EVar "chain")) (EApp (EVar "Scopes.binderScope") (EFieldAccess (EVar "g") "geBinder")))) (EApp (EApp (EVar "predicateRequestMatchesSlot") (EVar "request")) (EFieldAccess (EVar "g") "geSlot"))) (EApp (EVar "Some") (EApp (EApp (EVar "givenAnswerForRequest") (EVar "request")) (EVar "g"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "firstPredOnChain") (EVar "request")) (EVar "chain")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "givenAnswerExact" (TyFun (TyCon "GivenEntry") (TyCon "AssumAnswer")))
(DFunDef false "givenAnswerExact" ((PVar "g")) (EMatch (EFieldAccess (EVar "g") "geProvenance") (arm (PCon "DirectGiven") () (EApp (EVar "SemanticGiven") (EApp (EVar "GivenEvidence") (EFieldAccess (EVar "g") "geBinder")))) (arm (PCon "ProjectedGiven" (PVar "parent") (PVar "path")) () (EApp (EVar "SemanticGiven") (EApp (EApp (EVar "SuperclassEvidence") (EVar "parent")) (EVar "path"))))))
(DTypeSig false "givenAnswerForRequest" (TyFun (TyCon "PredicateRequest") (TyFun (TyCon "GivenEntry") (TyCon "AssumAnswer"))))
(DFunDef false "givenAnswerForRequest" ((PVar "request") (PVar "g")) (EMatch (ETuple (EFieldAccess (EVar "request") "prArgs") (EFieldAccess (EFieldAccess (EVar "g") "geSlot") "psArgs") (EFieldAccess (EVar "g") "geMatch")) (arm (PTuple (PCon "PSArgsKnown" PWild) (PCon "PSArgsKnown" PWild) (PCon "GMPredicate")) () (EMatch (ETuple (EFieldAccess (EFieldAccess (EVar "request") "prIface") "irOrigin") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "g") "geSlot") "psIface") "irOrigin")) (arm (PTuple (PCon "OriginUnresolved") PWild) () (EApp (EVar "givenAnswerResidual") (EVar "g"))) (arm (PTuple PWild (PCon "OriginUnresolved")) () (EApp (EVar "givenAnswerResidual") (EVar "g"))) (arm PWild () (EApp (EVar "givenAnswerExact") (EVar "g"))))) (arm PWild () (EApp (EVar "givenAnswerResidual") (EVar "g")))))
(DTypeSig false "givenAnswerResidual" (TyFun (TyCon "GivenEntry") (TyCon "AssumAnswer")))
(DFunDef false "givenAnswerResidual" ((PVar "g")) (EMatch (EFieldAccess (EVar "g") "geProvenance") (arm (PCon "DirectGiven") () (EApp (EVar "LegacyPredicate") (EFieldAccess (EVar "g") "geBinder"))) (arm (PCon "ProjectedGiven" (PVar "parent") (PVar "path")) () (EApp (EApp (EVar "LegacyProjected") (EVar "parent")) (EVar "path")))))
(DTypeSig true "firstPredForEnclAt" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "GivenScope") (TyFun (TyCon "Int") (TyFun (TyCon "PredicateRequest") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyCon "GivenEntry")) (TyApp (TyCon "Option") (TyCon "AssumAnswer")))))))))
(DFunDef false "firstPredForEnclAt" ((PVar "gctx") (PVar "scope") (PVar "target") (PVar "request") (PVar "useScope") (PVar "givens")) (EApp (EApp (EApp (EApp (EApp (EVar "firstPredAtOnChain") (EVar "scope")) (EVar "target")) (EVar "request")) (EApp (EApp (EVar "Scopes.visibleChain") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))) (EVar "useScope"))) (EVar "givens")))
(DTypeSig false "firstPredAtOnChain" (TyFun (TyCon "GivenScope") (TyFun (TyCon "Int") (TyFun (TyCon "PredicateRequest") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "GivenEntry")) (TyApp (TyCon "Option") (TyCon "AssumAnswer"))))))))
(DFunDef false "firstPredAtOnChain" (PWild PWild PWild PWild (PList)) (EVar "None"))
(DFunDef false "firstPredAtOnChain" ((PVar "scope") (PVar "target") (PVar "request") (PVar "chain") (PCons (PVar "g") (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "givenInScope") (EVar "scope")) (EVar "g")) (EApp (EApp (EVar "containsI") (EVar "target")) (EFieldAccess (EFieldAccess (EVar "g") "geSlot") "psBoundIds"))) (EApp (EApp (EVar "Scopes.visibleOnChain") (EVar "chain")) (EApp (EVar "Scopes.binderScope") (EFieldAccess (EVar "g") "geBinder")))) (EApp (EApp (EVar "predicateRequestMatchesSlot") (EVar "request")) (EFieldAccess (EVar "g") "geSlot"))) (EApp (EVar "Some") (EApp (EApp (EVar "givenAnswerForRequest") (EVar "request")) (EVar "g"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "firstPredAtOnChain") (EVar "scope")) (EVar "target")) (EVar "request")) (EVar "chain")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "activeFunDictPredOfResidual" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ScopeId") (TyApp (TyCon "Option") (TyCon "AssumAnswer")))))))
(DFunDef false "activeFunDictPredOfResidual" ((PVar "gctx") (PVar "iface") (PVar "args") (PVar "useScope")) (EApp (EApp (EApp (EApp (EApp (EVar "firstPredForEnclResidual") (EVar "gctx")) (EVar "iface")) (EVar "args")) (EVar "useScope")) (EApp (EApp (EVar "givensForScope") (EVar "gctx")) (EVar "useScope"))))
(DTypeSig true "firstPredForEnclResidual" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyCon "GivenEntry")) (TyApp (TyCon "Option") (TyCon "AssumAnswer"))))))))
(DFunDef false "firstPredForEnclResidual" ((PVar "gctx") PWild PWild PWild (PList)) (EVar "None"))
(DFunDef false "firstPredForEnclResidual" ((PVar "gctx") (PVar "iface") (PVar "args") (PVar "useScope") (PCons (PVar "g") (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "givenInScope") (EVar "GSPredicateOnly")) (EVar "g")) (EBinOp "==" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "g") "geSlot") "psIface") "irName") (EVar "iface"))) (EApp (EApp (EApp (EVar "Scopes.givenVisibleFrom") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))) (EVar "useScope")) (EApp (EVar "Scopes.binderScope") (EFieldAccess (EVar "g") "geBinder")))) (EApp (EApp (EVar "predicateRequestArgsMatch") (EApp (EVar "PSArgsKnown") (EVar "args"))) (EFieldAccess (EFieldAccess (EVar "g") "geSlot") "psArgs"))) (EApp (EVar "Some") (EApp (EVar "givenAnswerResidual") (EVar "g"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "firstPredForEnclResidual") (EVar "gctx")) (EVar "iface")) (EVar "args")) (EVar "useScope")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "registerEachActive" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "EvidenceBinderId") (TyCon "Unit")))))
(DFunDef false "registerEachActive" ((PVar "gctx") (PList) PWild) (ELit LUnit))
(DFunDef false "registerEachActive" ((PVar "gctx") (PCons (PVar "id") (PVar "rest")) (PVar "dname")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "activeDictVars")) (EBinOp "::" (ETuple (EVar "id") (EVar "dname")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "activeDictVars") "value")))) (DoExpr (EApp (EApp (EApp (EVar "registerEachActive") (EVar "gctx")) (EVar "rest")) (EVar "dname")))))
(DTypeSig true "registerSlotPredGivens" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ScopeId") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PredicateSlot")) (TyCon "Unit"))))))
(DFunDef false "registerSlotPredGivens" ((PVar "gctx") PWild PWild (PList)) (ELit LUnit))
(DFunDef false "registerSlotPredGivens" ((PVar "gctx") (PVar "scope") (PVar "slot") (PCons (PVar "s") (PVar "srest"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "registerFunPredGiven") (EVar "gctx")) (EVar "s")) (EApp (EApp (EVar "Scopes.binderAt") (EVar "scope")) (EVar "slot")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "registerSlotPredGivens") (EVar "gctx")) (EVar "scope")) (EBinOp "+" (EVar "slot") (ELit (LInt 1)))) (EVar "srest")))))
(DTypeSig true "registerFunPredGiven" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PredicateSlot") (TyFun (TyCon "EvidenceBinderId") (TyCon "Unit")))))
(DFunDef false "registerFunPredGiven" ((PVar "gctx") (PVar "slot") (PVar "binder")) (EIf (EBinOp "==" (EFieldAccess (EFieldAccess (EVar "slot") "psIface") "irName") (ELit (LString ""))) (ELit LUnit) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "pushGiven") (EVar "gctx")) (EVar "GMPredicate")) (EVar "DirectGiven")) (EVar "slot")) (EVar "binder"))) (DoExpr (EApp (EApp (EApp (EVar "registerFunPredGivenSlots") (EVar "gctx")) (EApp (EApp (EVar "predicateSlotKnownSupers") (EVar "gctx")) (EVar "slot"))) (EVar "binder")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "registerFunPredGivenSlots" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "PredicateSlot") (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyCon "EvidenceBinderId") (TyCon "Unit")))))
(DFunDef false "registerFunPredGivenSlots" ((PVar "gctx") (PList) PWild) (ELit LUnit))
(DFunDef false "registerFunPredGivenSlots" ((PVar "gctx") (PCons (PTuple (PVar "slot") (PVar "path")) (PVar "rest")) (PVar "binder")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "pushGiven") (EVar "gctx")) (EVar "GMPredicate")) (EApp (EApp (EVar "ProjectedGiven") (EVar "binder")) (EVar "path"))) (EVar "slot")) (EVar "binder"))) (DoExpr (EApp (EApp (EApp (EVar "registerFunPredGivenSlots") (EVar "gctx")) (EVar "rest")) (EVar "binder")))))
(DTypeSig true "predicateSlotKnownSupers" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PredicateSlot") (TyApp (TyCon "List") (TyTuple (TyCon "PredicateSlot") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "predicateSlotKnownSupers" ((PVar "gctx") (PVar "slot")) (EMatch (EFieldAccess (EVar "slot") "psArgs") (arm (PCon "PSArgsUnknown") () (EListLit)) (arm (PCon "PSArgsKnown" (PVar "args")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EApp (EVar "predicateSlotOfNode") (EVar "n")) (EApp (EApp (EVar "drop") (ELit (LInt 1))) (EFieldAccess (EVar "n") "superPath"))))) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "n")) (EBinOp ">" (EApp (EVar "listLen") (EFieldAccess (EVar "n") "superPath")) (ELit (LInt 1))))) (EApp (EApp (EApp (EApp (EVar "superClosure") (EApp (EVar "superLookup") (EVar "gctx"))) (EVar "predicateSuperStep")) (EVar "predicateNodeKey")) (EListLit (ETuple (EFieldAccess (EVar "slot") "psIface") (EVar "args")))))))))
(DTypeSig false "predicateNodeKey" (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "String"))))
(DFunDef false "predicateNodeKey" ((PVar "iface") (PVar "monos")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "regKeyRender") (EApp (EVar "regKeyOfTab") (EApp (EVar "oblIfaceKey") (EVar "iface")))))) (ELit (LString "|"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "join") (ELit (LString ","))) (EApp (EApp (EMethodRef "map") (EVar "oblArgKey")) (EVar "monos"))))) (ELit (LString ""))))
(DTypeSig false "predicateSuperStep" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "Super") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Mono")))))))
(DFunDef false "predicateSuperStep" ((PVar "typarams") (PVar "args") (PRec "Super" ((rf "superParams" (PVar "params"))) true)) (EIf (EBinOp "/=" (EApp (EVar "listLen") (EVar "args")) (EApp (EVar "listLen") (EVar "typarams"))) (EVar "None") (EIf (EVar "otherwise") (EApp (EApp (EVar "mapAll") (ELam ((PVar "p")) (EApp (EApp (EApp (EVar "lookupPos") (EVar "p")) (EVar "typarams")) (EVar "args")))) (EVar "params")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "predicateSlotOfNode" (TyFun (TyApp (TyCon "SuperNode") (TyApp (TyCon "List") (TyCon "Mono"))) (TyCon "PredicateSlot")))
(DFunDef false "predicateSlotOfNode" ((PVar "n")) (ERecordCreate "PredicateSlot" ((fa "psIface" (EFieldAccess (EVar "n") "superIface")) (fa "psArgs" (EApp (EVar "PSArgsKnown") (EFieldAccess (EVar "n") "superPayload"))) (fa "psBoundIds" (EApp (EVar "dedupI") (EApp (EApp (EDictApp "flatMap") (EVar "monoTyvarIds")) (EFieldAccess (EVar "n") "superPayload")))))))
(DTypeSig true "goalMatchesGiven" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ScopeId") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))))
(DFunDef false "goalMatchesGiven" ((PVar "gctx") PWild PWild (PList)) (EVar "False"))
(DFunDef false "goalMatchesGiven" ((PVar "gctx") (PVar "scope") (PVar "iface") (PVar "args")) (EApp (EApp (EApp (EApp (EVar "anyGivenMatches") (EVar "gctx")) (ERecordCreate "PredicateRequest" ((fa "prIface" (EVar "iface")) (fa "prArgs" (EApp (EVar "PSArgsKnown") (EVar "args")))))) (EVar "scope")) (EApp (EApp (EVar "givensForScope") (EVar "gctx")) (EVar "scope"))))
(DTypeSig true "anyGivenMatches" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PredicateRequest") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyCon "GivenEntry")) (TyCon "Bool"))))))
(DFunDef false "anyGivenMatches" ((PVar "gctx") (PVar "request") (PVar "scope") (PVar "givens")) (EApp (EApp (EApp (EVar "anyGivenOnChain") (EVar "request")) (EApp (EApp (EVar "Scopes.visibleChain") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))) (EVar "scope"))) (EVar "givens")))
(DTypeSig false "anyGivenOnChain" (TyFun (TyCon "PredicateRequest") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "GivenEntry")) (TyCon "Bool")))))
(DFunDef false "anyGivenOnChain" (PWild PWild (PList)) (EVar "False"))
(DFunDef false "anyGivenOnChain" ((PVar "request") (PVar "chain") (PCons (PVar "g") (PVar "rest"))) (EBinOp "||" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "givenInScope") (EVar "GSPredicateOnly")) (EVar "g")) (EApp (EApp (EVar "Scopes.visibleOnChain") (EVar "chain")) (EApp (EVar "Scopes.binderScope") (EFieldAccess (EVar "g") "geBinder")))) (EApp (EApp (EVar "predicateRequestMatchesSlot") (EVar "request")) (EFieldAccess (EVar "g") "geSlot"))) (EApp (EApp (EApp (EVar "anyGivenOnChain") (EVar "request")) (EVar "chain")) (EVar "rest"))))
(DTypeSig true "registerActiveDictVars" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ScopeId") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PredicateSlot")) (TyCon "Unit"))))))
(DFunDef false "registerActiveDictVars" ((PVar "gctx") PWild PWild (PList)) (ELit LUnit))
(DFunDef false "registerActiveDictVars" ((PVar "gctx") (PVar "scope") (PVar "slot") (PCons (PVar "s") (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "registerEachActive") (EVar "gctx")) (EFieldAccess (EVar "s") "psBoundIds")) (EApp (EApp (EVar "Scopes.binderAt") (EVar "scope")) (EVar "slot")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "registerActiveDictVars") (EVar "gctx")) (EVar "scope")) (EBinOp "+" (EVar "slot") (ELit (LInt 1)))) (EVar "rest")))))
