# META
source_lines=1974
stages=DESUGAR,MARK
# SOURCE
-- tc_effects: the effect checks inference runs at binding boundaries and impl bodies (escape,
-- summary failures, rigidity, index-only variables), grant and authority recording, and file-bound
-- values (authority bounds at binding boundaries: recording, flow and settle checks); wires the
-- `effect_*` leaves into inference.
--
-- Spec: EFFECTS section 5, section 6.2-6.9, section 8.
--
-- Placement: declarations are placed by R1-R6 of the Phase 4 module table,
-- compiler/ARCHITECTURE-PLAYBOOK.md section 6.
-- Closure rule: this module may not import `types.typecheck`, nor any of `tc_occurrence`,
-- `tc_groups`, `tc_pat`, `tc_infer_records`, `tc_infer`, `tc_elab`, `tc_global`, `tc_module`.

import types.tc_types.{
  grantTopKey,
  methodGrantKey,
  setGrantIds,
  AbsorptionEvent(..),
  GrantBinder(..),
  GrantCallee(..),
  GrantOcc(..),
  MethodGrant(..),
  DynCtx,
  GraphCtx,
  GroupCtx,
  Kind,
  MethodSchemeRow,
  ModuleCtx,
  ObligationSite,
  ScopedMember,
  SelectedValueOccurrence,
  TcEnv,
}
import types.tc_mono.{
  allArrowEffs,
  arrowArity,
  authCellsIn,
  authOrderIn,
  authOrderRow,
  authRoots,
  authRowCells,
  authRowRoots,
  containsI,
  effectCells,
  effectRoots,
  effectRowRoots,
  funArity,
  joinCellOf,
  monoIndexEffvarIds,
  newEffvarId,
  peelQual,
  rowTailId,
  schemeAuthIds,
  schemeIds,
  tyAppSpine,
  tyArrowCount,
  liveTailId,
  anyContainsI,
  effVarTailIds,
  hasDupI,
}
import types.tc_diag_text.{
  aliasesHeadRowMsg,
  argAtomsMsgFor,
  argOnlyEffVarMsg,
  collapsesEffvarsMsg,
  effectEscapeMsg,
  effectInclusionMsg,
  effectUndeterminedMsg,
  effVarLaunderMsg,
  indexEagerMsg,
}
import types.tc_state.{
  currentScopeStore, mctxAt, wPushAll, wRestore, wSnapshot, wWindow
}
import types.tc_env.{
  declGradedScope,
  effTailNames,
  funClausePair,
  lookupBinding,
  lookupVar,
  methodArgs,
  removeAllS,
  tyTabKey,
}
import types.tc_diag.{
  pushTypeError,
  pushTypeErrorAt,
  pushTypeErrorOnceAt,
  pushTypeErrorOncePerSite,
}
import types.tc_unify.{
  atomsEscape,
  authorityFailureMsg,
  captureScope,
  effectLeakCheck,
  effectSiteKey,
  freshEffvarAt,
  freshVar,
  producedSlotCovariants,
  reportIndexFailure,
  resolvePendingJoins,
  widenOpenedFor,
}
import types.tc_decls_types.{
  atomsOfWritten, expandAliasHeadTy, rowArgNames, rowArgNamesIn
}
import types.tc_decls.{krowArgVarAtoms, paramRowAtomsOf, rowArgAtomsIn}
import types.tc_solve.{isLocalAbsName}
import types.tc_solve_check.{registerLocalAbs}
import types.effect_authority.{
  Authority(..),
  Authvar(..),
  authHasVars,
  authIsTop,
  authSub,
  authvarId,
  authvarName,
  authVars,
}
import types.effect_rows.{
  Atom(..),
  EffLabel(..),
  EffRow(..),
  Effvar(..),
  atomAuth,
  atomKey,
  atomLabelOf,
  atomsDiff,
  effrowLabels,
  findAtom,
  rowFlat,
}
import types.repr.{
  AuthResidual(..),
  Mono(..),
  Scheme(..),
  lookupAssocI,
  normalize,
  ppEachShared,
  ppMonosShared,
}
import types.effect_bindings.{BindingSummary(..), newBindingSummary}
import frontend.ast.{
  Decl(..),
  EffAtomTy(..),
  EvId(..),
  Expr(..),
  IfaceMethod(..),
  LetBind(..),
  Loc(..),
  Pat(..),
  Ty(..),
  TyConOrigin(..),
  firstTyLoc,
  lookupTab,
  orElseLoc,
}
import map.{Map(..)}
import support.ordmap.{
  omDelete, omFromNames, omHasKey, omInsert, omLookup, OrdMap
}
import types.evidence.{ScopeId(..)}
import types.effect_solver.{ScopeRoles(..), noScopeRoles, SummaryFailure}
import support.util.{
  anyList,
  contains,
  dedup,
  filterList,
  isEmptyL,
  isNonEmptyL,
  isSome,
  joinWith,
  listLen,
  lookupAssoc,
  reverseL,
}
import list.{findMap}
import types.route_key.{ifaceWordOf}
import frontend.desugar.{mapChildren, mapExpr}
import types.effect_values.{producedInputTypes}
import types.scopes as Scopes
import types.runtime_grants as RuntimeGrants
import types.effect_solver as EffectSolver
import map as IdMap
import types.scopes.{ScopeOwner(..)}

-- The site a binding performed a label at that the report is about: the
-- first, in source order, whose authority does not lie within the bound
-- the label was admitted at, else the first site.  Two reads under
-- `<FileRead "config/*">`, the second of `/etc/passwd`, report the second.
effectSiteOf : ModuleCtx ->
  String ->
  Option String ->
  Option Authority ->
  Option Loc
effectSiteOf mctx _ None _ = None
effectSiteOf mctx fn (Some label) bound =
  match omLookup (effectSiteKey fn label) mctx.mcCells.effectSitesRef.value
    Some sites =>
      let ordered = reverseL sites
      let offending = match bound
        Some hi => filterList (site => not (authSub (fst site) hi)) ordered
        None => []
      match offending ++ ordered
        site :: _ => snd site
        [] => None
    None => None

export
beginEffectSummaryScope : ModuleCtx -> Unit -> Unit
beginEffectSummaryScope mctx _ =
  mctx.mcCells.fileValueScopes :=
    wSnapshot mctx.mcCells.fileValueFlows :: mctx.mcCells.fileValueScopes.value
  EffectSolver.openSummaryScope
    mctx.mcCells.effectSummaries
    (newEffvarId mctx.mcGraph ())
    mctx.mcCells.currentLevel.value

export
freshEffectSummary : ModuleCtx -> Unit -> EffRow
freshEffectSummary mctx _ =
  EffectSolver.newSummary
    mctx.mcCells.effectSummaries
    (newEffvarId mctx.mcGraph ())

export
recordEffectBody : ModuleCtx -> EffRow -> EffRow -> Unit
recordEffectBody mctx summary lower =
  EffectSolver.recordBodyLower mctx.mcCells.effectSummaries summary lower

summaryEscape : GraphCtx -> Bool -> List Atom -> List Atom -> List Atom
summaryEscape gctx True lower upper = atomsDiff lower upper
summaryEscape gctx False lower upper = atomsEscape gctx lower upper

finishEffectSummaryScope : ModuleCtx ->
  Map Int Unit ->
  Map Int (Ref Effvar) ->
  Unit
finishEffectSummaryScope mctx retained borrowed =
  let _ = finishEffectSummaryScopeKeeping mctx noScopeRoles retained borrowed
  ()

-- Close the scope, keeping as residuals the unproven obligations over the
-- authorities [roles] quantifies at a member (`rlQuantified`, see
-- `closeSummaryScope`); each comes back with its member index.
export
finishEffectSummaryScopeKeeping : ModuleCtx ->
  ScopeRoles ->
  Map Int Unit ->
  Map Int (Ref Effvar) ->
  List (Int, AuthResidual)
finishEffectSummaryScopeKeeping mctx roles retained borrowed =
  let outcome =
    EffectSolver.closeSummaryScope
      mctx.mcCells.effectSummaries
      mctx.mcCells.rigidEffvarsRef.value
      mctx.mcCells.rigidAuthvarsRef.value
      roles
      retained
      borrowed
      (summaryEscape mctx.mcGraph)
      (joinCellOf mctx.mcGraph)
      (freshEffvarAt mctx.mcGraph)
      (widenOpenedFor mctx)
  reportEffectSummaryFailures mctx outcome.esoFailures
  finishFileValueScope mctx ()
  map
    ((member, w) => (
      member,
      AuthResidual {
        arLower = w.awLower,
        arUpper = w.awUpper,
        arExact = w.awExact,
      },
    ))
    outcome.esoResiduals

export
reportEffectSummaryFailures : ModuleCtx ->
  List (SummaryFailure ObligationSite) ->
  Unit
reportEffectSummaryFailures mctx [] = ()
reportEffectSummaryFailures outer (failure :: rest) =
  let fn = failure.esfContext.osFn
  let mctx =
    mctxAt
      (orElseLoc
        (effectSiteOf outer fn failure.esfLabel (failureBound failure))
        failure.esfContext.osLoc)
      outer
  match failure.esfAuthority
    Some (lo, hi) =>
      if mentionsEscaped mctx lo || mentionsEscaped mctx hi then
        ()
      else if failure.esfExact then
        reportIndexFailure mctx failure.esfContext.osCovering mctx.mcLoc lo hi
      else
        pushTypeErrorAt
          mctx
          "T-AUTHORITY"
          mctx.mcLoc
          (authorityFailureMsg
            mctx
            fn
            failure.esfLabel
            failure.esfResidualOf
            lo
            hi
            failure.esfWrittenUpper)
    None =>
      mctx.mcCells.rowFailureReportedRef :=
        omInsert fn () mctx.mcCells.rowFailureReportedRef.value
      reportRowFailure mctx failure
  reportEffectSummaryFailures outer rest

-- The authority the failing label was admitted at: the obligation's upper
-- term, or the upper row's atom of that label.
failureBound : SummaryFailure ObligationSite -> Option Authority
failureBound failure = match failure.esfAuthority
  Some (_, hi) => Some hi
  None => match failure.esfLabel
    Some label => map atomAuth (findAtom label (fst (rowFlat failure.esfUpper)))
    None => None

reportRowFailure : ModuleCtx -> SummaryFailure ObligationSite -> Unit
reportRowFailure mctx failure =
  let (upper, upperCells) = rowFlat failure.esfUpper
  let escaping = atomsEscape mctx.mcGraph (fst (rowFlat failure.esfLower)) upper
  if failure.esfExact then
    let rows = ppEachShared (Ref []) (Ref 0) [
      TEff failure.esfLower,
      TEff failure.esfUpper,
    ]
    pushTypeError
      mctx
      "T-EFFECT-INDEX-MISMATCH"
      ("effect index mismatch: "
        ++ joinWith " vs " rows
        ++ "; an effect row in a type argument is invariant, so write the same row on both sides")
  else if isNonEmptyL escaping && isEmptyL upperCells then
    effectLeakCheck mctx escaping upper
  else
    pushTypeError
      mctx
      "T-EFFECT-LAUNDER"
      (effectInclusionMsg
        failure.esfContext.osFn
        escaping
        (ppEachShared (Ref []) (Ref 0) [
          TEff failure.esfLower,
          TEff failure.esfUpper,
        ]))
  ()

export
borrowedEffectCells : ModuleCtx ->
  Mono ->
  Map Int (Ref Effvar) ->
  Map Int (Ref Effvar)
borrowedEffectCells mctx mono cells =
  fold
    (acc input => effectCells input acc)
    cells
    (producedInputTypes (producedSlotCovariants mctx) mono)

-- A contract's effect variables are universal throughout its body judgment.
-- The same boundary is used for supplied methods and generic default bodies.
export
beginEffectContract : ModuleCtx ->
  EffRow ->
  Mono ->
  (Map Int Unit, Map Int Unit)
beginEffectContract mctx force value =
  let saved = mctx.mcCells.rigidEffvarsRef.value
  let savedAuths = mctx.mcCells.rigidAuthvarsRef.value
  beginEffectSummaryScope mctx ()
  mctx.mcCells.rigidEffvarsRef := effectRoots value (effectRowRoots force saved)
  mctx.mcCells.rigidAuthvarsRef :=
    authRoots value (authRowRoots force savedAuths)
  (saved, savedAuths)

export
finishEffectContract : DynCtx -> (Map Int Unit, Map Int Unit) -> Unit
finishEffectContract dyn (saved, savedAuths) =
  resolvePendingJoins dyn dyn.dcModule.mcCells.currentLevel.value
  finishEffectSummaryScope dyn.dcModule Tip Tip
  dyn.dcModule.mcCells.rigidEffvarsRef := saved
  dyn.dcModule.mcCells.rigidAuthvarsRef := savedAuths

-- #784 (Option A): reject an interface method whose signature has a free effect
-- tail var in RETURN position but in NO ROW-KINDED argument position — it is
-- under-determined, so a caller can instantiate it to `<>` and LAUNDER the
-- dispatched impl's real effect (a pure-typed wrapper silently performs it).
-- SCOPED to interface methods (the scope of this check); a top-level return-only
-- effect var is #797's separate territory.
--
-- This runs as a SEPARATE pass from checkEffectParams, deliberately AFTER
-- registerAllData has populated `dataParamKindsRef` (see the call site in
-- checkBodyImpl). The predicate's kind-awareness (rowArgNames) consults that
-- table to tell a row-kinded ctor arg (`Async e a`) from a type-kinded one
-- (`List e`); running it in the early checkEffectParams pre-pass — before data
-- registration — would leave the table empty and spuriously reject `Async e a`.
export
checkUndeterminedRetEffVars : ModuleCtx -> List Decl -> Unit
checkUndeterminedRetEffVars mctx [] = ()
checkUndeterminedRetEffVars mctx (d :: rest) =
  checkUndeterminedRetEffVarsDecl mctx d
  checkUndeterminedRetEffVars mctx rest

checkUndeterminedRetEffVarsDecl : ModuleCtx -> Decl -> Unit
checkUndeterminedRetEffVarsDecl mctx (DInterface { name, typarams, typaramKinds, methods, ... }) =
  checkIfaceMethodEffs
    mctx
    name
    (declGradedScope mctx.mcGraph typarams typaramKinds methods)
    methods
-- #1103: the ARGUMENT-COVERAGE half of the rule is NOT method-only.  Its own
-- comment (below) says post-unify inspection cannot catch these shapes because
-- `unifyRowN`'s same-tail arm (`<e>` ~ `<Stdout | e>`) succeeds without
-- recording the atom anywhere — and that arm is reached from an ORDINARY
-- top-level arrow just as readily as from a method.  `launderArrow : (Unit ->
-- <Stdout | e> Unit) -> (Unit -> <e> Unit)` was accepted, and applying it to an
-- effectful callback produced a `Unit -> Unit` scheme that prints.  So the
-- coverage check runs over plain `DTypeSig` signatures too, with an EMPTY graded
-- scope (a non-interface signature has no graded typaram table — `scope` is the
-- only channel by which an abstract head can be row-kinded, see `rowArgNamesIn`).
-- Deliberately NOT widened alongside it: `undeterminedRetEffVars` (#784's
-- RETURN-only rule) stays interface-scoped — a top-level return-only effect var
-- is #797's separate territory, and the comment above says so.
checkUndeterminedRetEffVarsDecl mctx (DTypeSig _ n t _) =
  checkArgEffVarCoverage mctx None [] n t
checkUndeterminedRetEffVarsDecl mctx (DAttrib _ d) =
  checkUndeterminedRetEffVarsDecl mctx d
checkUndeterminedRetEffVarsDecl mctx _ = ()

checkIfaceMethodEffs : ModuleCtx ->
  String ->
  List (String, List Kind) ->
  List IfaceMethod ->
  Unit
checkIfaceMethodEffs mctx _ _ [] = ()
checkIfaceMethodEffs mctx iface scope ((IfaceMethod mname mty _ _) :: rest) =
  match undeterminedRetEffVars mctx scope mty
    [] => ()
    bad =>
      pushTypeErrorOnceAt
        mctx
        "T-EFFECT-UNDETERMINED"
        (firstTyLoc mty)
        (effectUndeterminedMsg iface mname bad)
  checkArgEffVarCoverage mctx (Some iface) scope mname mty
  checkIfaceMethodEffs mctx iface scope rest

-- The DUAL of the #784 rule, closing the adversarial review's break 4 (and the
-- argument-only variant): an effect var's ARGUMENT-position occurrences are
-- rows an impl can PERFORM by using that argument, so the method's own rows
-- must account for them.  Two ill-formed shapes, both rejected at the
-- interface declaration:
--   * argument-only — `use : a -> (Unit -> <e> Unit) -> Int`: e rides an
--     argument but no non-argument row, so an impl applying the callback
--     performs e with no row charging it (verified launder: a pure-typed
--     wrapper prints);
--   * uncovered atoms — `act1 : a -> (Unit -> <Stdout | e> Unit) -> <e> Unit`:
--     the callback's concrete <Stdout> pours into a row declared bare <e>,
--     which a caller instantiates to <> (verified launder).  Sound iff every
--     non-argument occurrence of e covers the union of its argument-side
--     atoms, IO-expanded (`<Stdout | e>` callback with `<Stdout | e>` return
--     is accepted; so is an `<IO | e>` return).
-- Post-unify inspection CANNOT catch these: the same-tail row-unification arm
-- (`<e>` ~ `<Stdout | e>`) succeeds without recording the atom anywhere, so
-- the declaration is the only seam with the information intact.
-- [iface] is `Some` the enclosing interface for a method signature and `None`
-- for an ordinary top-level `DTypeSig` (#1103); it selects the diagnostic's
-- wording and nothing else — the RULE is identical either way.
checkArgEffVarCoverage : ModuleCtx ->
  Option String ->
  List (String, List Kind) ->
  String ->
  Ty ->
  Unit
checkArgEffVarCoverage mctx iface scope mname mty =
  checkArgEffVars
    mctx
    iface
    mname
    mty
    (methodEffArgOccs mctx scope mty)
    (methodEffRetOccs mctx scope mty)
    (dedup (map fst (methodEffArgOccs mctx scope mty)))

-- The two arms have different scopes, and [iface] is what selects between
-- them.  Both arms apply to an interface method (`Some iface`); only the
-- UNCOVERED-ATOMS arm applies to an ordinary top-level signature (`None`).
--
-- Why the ARGUMENT-ONLY arm is method-only.  Its hazard is "an impl uses the
-- argument and performs <e> with no row charging it", and at an INTERFACE
-- declaration the declaration really is the only seam — the impl arrives later,
-- and #1100's `gtake : f e a -> a` launders for exactly that reason.  A
-- DIRECT call to a top-level function does not get there: the CALL SITE rejects
-- it.  MEASURED, both shapes, on this build — the reason is the call site, NOT
-- the callee's body (a first pass at this comment claimed the body check caught
-- it and that was falsified: `use : (Unit -> <e> Unit) -> Int` with a body that
-- calls `f ()` checks CLEAN, reported as `use : (Unit -> Unit) -> Int`):
--   * callback arg — `use : (Unit -> <e> Unit) -> Int`, body `let _ = f ()`,
--     applied to an effectful `shout`: "Effectful value used where <> is
--     allowed, but it performs <Stdout>", at `use shout`;
--   * row-kinded ctor arg — `force : Box e a -> a` forcing its `Susp` thunk,
--     applied to `Susp loud`: the same diagnostic, at `force (Susp loud)`.
-- Applying the arm to top-level signatures anyway buys no soundness and rejects
-- every honest INSPECTOR of a row-kinded value — also measured: 34 declarations
-- in this compiler's own sources (`unInt : Value e -> Int`, `isPartial : Value e
-- -> Bool`, … which pattern-match a `Value e` and never invoke the closure
-- inside it) plus `stdlib/async.mdk`'s `isDone`/`forceVal`.  Nothing at a
-- declaration tells an inspector from a forcer; for a method that uncertainty IS
-- the hazard, for a directly-called function the call site settles it.
--
-- Why the UNCOVERED-ATOMS arm is NOT method-only (#1103).  Its hazard survives
-- the body check: `launderArrow : (Unit -> <Stdout | e> Unit) -> (Unit -> <e>
-- Unit)` with body `launderArrow f = f` type-checks, because `unifyRowN`'s
-- same-tail arm accepts `<Stdout | e>` against `<e>` without recording <Stdout>
-- anywhere (see this function's header comment).  Effect inference therefore
-- CANNOT catch it, and the declaration is the only seam here too.
checkArgEffVars : ModuleCtx ->
  Option String ->
  String ->
  Ty ->
  List (String, List Atom) ->
  List (String, List Atom) ->
  List String ->
  Unit
checkArgEffVars mctx _ _ _ _ _ [] = ()
checkArgEffVars mctx iface mname mty argOccs retOccs (v :: rest) =
  let vrets = filterList (o => fst o == v) retOccs
  let vatoms = flatMap snd (filterList (o => fst o == v) argOccs)
  if isEmptyL vrets then match iface
    Some i =>
      pushTypeErrorOnceAt
        mctx
        "T-EFFECT-ARG-UNCOVERED"
        (firstTyLoc mty)
        (argOnlyEffVarMsg i mname v)
    None => ()
  else match retOccsEscape mctx.mcGraph vatoms vrets
    [] => ()
    esc =>
      pushTypeErrorOnceAt
        mctx
        "T-EFFECT-ARG-UNCOVERED"
        (firstTyLoc mty)
        (argAtomsMsgFor iface mname v esc)
  checkArgEffVars mctx iface mname mty argOccs retOccs rest

-- first non-empty escape of the argument-side atoms against a non-argument
-- occurrence's declared atoms (IO-expanded via atomsEscape)
retOccsEscape : GraphCtx -> List Atom -> List (String, List Atom) -> List Atom
retOccsEscape gctx _ [] = []
retOccsEscape gctx vatoms ((_, declAtoms) :: rest) =
  if isNonEmptyL (atomsEscape gctx vatoms declAtoms) then
    atomsEscape gctx vatoms declAtoms
  else
    retOccsEscape gctx vatoms rest

-- effect-var occurrences (name, written atoms) inside ARGUMENT positions of a
-- method signature that an impl can PERFORM: rows of functions the impl can
-- CALL (odd contravariant depth) and row-kinded values it can RUN.  The
-- arrow's own row is NOT an argument position, and — round-2 adversarial
-- FP 7 — a row at EVEN depth (`((Unit -> <e> Unit) -> Int)` argument: the
-- impl receives a CONSUMER of e-callbacks and can only SUPPLY callbacks) is
-- excluded: the impl cannot perform e there, and a malicious effectful supply
-- pours its atoms into e's own cell where the post-unify atom check reads
-- them.
-- [scope] mirrors `methodEffRetOccs`' parameter of the same name exactly: the
-- graded typaram map of the interface whose method signature this type IS
-- (`declGradedScope`), and `[]` for every non-method signature.  Before #1100 the
-- ARGUMENT half took no scope at all, so an abstract head (`gtake : f e a -> a`)
-- resolved no row-kinded slot and raised no obligation, while the RETURN half —
-- which has had the scope channel since #822 — did.
methodEffArgOccs : ModuleCtx ->
  List (String, List Kind) ->
  Ty ->
  List (String, List Atom)
methodEffArgOccs mctx scope (TyConstrained _ t) = methodEffArgOccs mctx scope t
methodEffArgOccs mctx scope (TyEffect _ _ t) = methodEffArgOccs mctx scope t
methodEffArgOccs mctx scope (TyFun a b) =
  argPerformableOccs mctx scope True a ++ methodEffArgOccs mctx scope b
methodEffArgOccs mctx _ _ = []

-- One `(tail var, the row's written atoms)` occurrence per tail variable.  A
-- row is a JOIN when it names several (#821, `<Stdout | e | e2>`), and every
-- collector below reports them all: a caller reads the row at each var
-- independently, so a var left out would be a var nothing constrains.
occsOfTails : GraphCtx ->
  List String ->
  List EffAtomTy ->
  List (String, List Atom)
occsOfTails gctx tails labels =
  let atoms = atomsOfWritten gctx labels
  map (n => (n, atoms)) tails

-- rows in an argument subtree, collected only where [perf] (the impl can call
-- or run the value at this position); each arrow-LHS descent flips it.
argPerformableOccs : ModuleCtx ->
  List (String, List Kind) ->
  Bool ->
  Ty ->
  List (String, List Atom)
argPerformableOccs mctx scope perf (TyEffect labels tails t) =
  (if perf then occsOfTails mctx.mcGraph tails labels else [])
    ++ argPerformableOccs mctx scope perf t
-- A bare row atom (#997) carries its own tail var + labels directly (no
-- wrapped type to recurse into) — same treatment as the `TyEffect` arms
-- above.  Without this, a KRow ctor-arg written as `Box <Stdout | e> Int`
-- (as opposed to a bare `Box e Int`) was invisible to this collector, which
-- made the impl-body T-EFFECT-LAUNDER check over-fire on it (see
-- `effVarOccAtoms` below, which shares this gap).
argPerformableOccs mctx _ perf (TyRow labels tails _) =
  if perf then occsOfTails mctx.mcGraph tails labels else []
argPerformableOccs mctx scope perf (TyFun a b) =
  argPerformableOccs mctx scope (not perf) a
    ++ argPerformableOccs mctx scope perf b
argPerformableOccs mctx scope perf (TyTuple ts) =
  flatMap (argPerformableOccs mctx scope perf) ts
argPerformableOccs mctx scope perf (TyApp a b) = match tyAppSpine (TyApp a b)
  -- OCCURRENCE MINT (#1110/#1111 A-2.3): the head's acquired identity, read off
  -- the same record pattern as its name so the two cannot drift apart.
  (TyCon { tyConName = n, tyConOrigin = o }, args) =>
    krowSlotOccs mctx scope perf o n args
  -- #1100, the abstract-head half — symmetric with `rowArgNamesVarApp` on the
  -- RETURN side.  An interface typaram of graded kind, in scope, is row-kinded
  -- in exactly the same way a registered ctor's KRow slot is; without this arm
  -- `gtake : f e a -> a` collected NOTHING and the coverage rule never fired.
  (TyVar h, args) => krowSlotVarOccs mctx scope perf h args
  _ =>
    argPerformableOccs mctx scope perf a ++ argPerformableOccs mctx scope perf b
argPerformableOccs mctx scope perf (TyConstrained _ t) =
  argPerformableOccs mctx scope perf t
argPerformableOccs mctx _ _ _ = []

-- one ctor node: its bare row-kinded slots (if performable) + recurse the args
--
-- THE SLOT'S atoms come from the head'S DECLARATION, not from the use site.
-- This used to pad every performable KRow slot to `(e, [])` — "the impl can
-- perform `e` here and nothing else is guaranteed" — the ARGUMENT-side twin of
-- the blind pad #2110 removed from `methodEffRetOccs`.  On this side the pad is
-- not an over-rejection but a LAUNDER: for
--   `data Slot e = Slot (Unit -> <Stdout | e> Unit)`
-- a `Slot e` ARGUMENT lets the callee run a field the declaration guarantees
-- performs <Stdout> at EVERY instantiation, `Slot <>` included, so
--   `unslot : Slot e -> (Unit -> <e> Unit)`
-- under-claims: it hands back a function typed `<e>` that really performs
-- <Stdout>, and at `e := <>` the caller gets a pure-typed printer (measured —
-- `check` and `run` both exited 0 and the program printed).  Reading the
-- guarantee out of `dataParamRowAtomsRef` through `krowArgVarAtoms` — the same
-- table and the same walker the RETURN side already consults — makes those
-- <Stdout> atoms argument-side evidence, and the coverage rule ("every
-- non-argument occurrence of `e` covers the union of its argument-side atoms")
-- then rejects `unslot` while still accepting `widen : Slot e -> Slot e`, whose
-- return occurrence carries the same atoms.  Both halves are pinned:
-- `test/typecheck_error_fixtures/effect_arg_slot_launder.mdk` and its
-- `effect_arg_slot_unrelated_ok.mdk` accept-side twin.
-- A written-row slot (`Slot <Log | e>`) has its WRITTEN labels reported
-- twice — once here by `krowArgVarAtoms`, once by the `flatMap` below through
-- `argPerformableOccs`' `TyRow` arm.  Harmless, and NOT the return side's
-- double-count hazard: `checkArgEffVars` UNIONS the argument-side atoms
-- (`flatMap snd`), where the return side takes a first-non-empty escape and so
-- lets an atom-less copy veto a faithful one.
krowSlotOccs : ModuleCtx ->
  List (String, List Kind) ->
  Bool ->
  TyConOrigin ->
  String ->
  List Ty ->
  List (String, List Atom)
krowSlotOccs mctx scope perf o n args =
  match lookupTab (tyTabKey o n) mctx.mcCells.dataParamKindsRef.value
    Some kinds if listLen kinds == listLen args =>
      (if perf then
          krowArgVarAtoms
            mctx.mcGraph
            kinds
            (optionOr [] (paramRowAtomsOf mctx (tyTabKey o n)))
            args
        else
          [])
        ++ flatMap (argPerformableOccs mctx scope perf) args
    _ => flatMap (argPerformableOccs mctx scope perf) args

-- the ABSTRACT-HEAD sibling of `krowSlotOccs` (#1100): same shape, but the
-- kinds come from the graded typaram [scope] instead of `dataParamKindsRef`.
-- This is `rowArgNamesVarApp`'s counterpart on the argument side; a miss falls
-- through to the args exactly as `krowSlotOccs`' miss does.
-- An abstract head has no declaration to read, so its guarantee list is `[]`
-- and every slot still reports `(e, [])` — `krowArgVarAtoms kinds []` is the
-- old blind pad, occurrence for occurrence.  It is written this way rather than
-- left as the `map`, so the two arms stay ONE walker: the next atom fact an
-- abstract head can offer (a graded typaram's declared row, #820) lands in one
-- place instead of two.
krowSlotVarOccs : ModuleCtx ->
  List (String, List Kind) ->
  Bool ->
  String ->
  List Ty ->
  List (String, List Atom)
krowSlotVarOccs mctx scope perf h args = match lookupAssoc h scope
  Some kinds if listLen kinds == listLen args =>
    (if perf then krowArgVarAtoms mctx.mcGraph kinds [] args else [])
      ++ flatMap (argPerformableOccs mctx scope perf) args
  _ => flatMap (argPerformableOccs mctx scope perf) args

-- effect-var occurrences in NON-argument positions: each spine arrow's own row,
-- plus every occurrence inside the final return type (nested rows and bare
-- row-kinded ctor-arg slots).
--
-- The two terms of the last arm can describe the same occurrence, and only
-- one of them carries its atoms.  For a return `Box <Stdout | e> Unit`,
-- `effVarOccAtoms` descends into the KRow slot's written row and reports
-- `(e, [Stdout])`; `rowArgAtomsIn` reports the same occurrence again, carrying
-- only what the HEAD'S DECLARATION guarantees at that slot (`(e, [])` for a
-- `Box` declared bare).  `retOccsEscape` takes the FIRST NON-EMPTY escape
-- over this list and does not dedupe, so the atom-less copy vetoes the faithful
-- one and an HONESTLY CHARGED declaration is rejected:
--   `widen : Box <Stdout | e> Unit -> Box <Stdout | e> Unit`
-- covers <Stdout> on both sides and must be ACCEPTED — it is the named
-- over-correction control in `test/typecheck_error_fixtures/
-- effect_index_unrelated_ok.mdk` (its header, "rejecting those instead would be
-- the obvious over-correction").  So a name `effVarOccAtoms` has already
-- reported is DROPPED from the padded term rather than added beside it.
-- This does NOT weaken any real rejection: the dropped entry is a strictly
-- less informative record of an occurrence still in the list, never an
-- occurrence the list would otherwise lose.  The rule stays "every non-argument
-- occurrence of e covers the union of its argument-side atoms"; this only stops
-- one occurrence from being counted twice, once with its labels erased.
-- Latent since the padded term was introduced — it mis-rejected interface
-- methods of this shape too, and #1103's widening to ordinary signatures is
-- merely what made it reachable from `effect_index_unrelated_ok.mdk`.
methodEffRetOccs : ModuleCtx ->
  List (String, List Kind) ->
  Ty ->
  List (String, List Atom)
methodEffRetOccs mctx scope (TyConstrained _ t) = methodEffRetOccs mctx scope t
methodEffRetOccs mctx scope (TyEffect labels tails t) =
  occsOfTails mctx.mcGraph tails labels ++ methodEffRetOccs mctx scope t
methodEffRetOccs mctx scope (TyFun _ b) = methodEffRetOccs mctx scope b
methodEffRetOccs mctx scope t =
  let occs = effVarOccAtoms mctx.mcGraph t
  occs
    ++ filterList
      (o2 => not (anyList (o => fst o == fst o2) occs))
      (rowArgAtomsIn mctx scope t)

-- The predicate: return-position effect tail vars minus argument-carried ones.
-- An effect var is argument-carried — hence soundly pinned at every call site —
-- ONLY by a ROW-KINDED occurrence in an argument. The test is kind-aware, NOT
-- name-based: a Row-kinded effect var and a Type-kinded type var may share a
-- spelling yet be independent variables, so a Type-kinded `e` in `List e` /
-- `Box e` pins NOTHING about the return row `<e>` — counting it would relaunder
-- the effect (#784). The two sound argument-carriers:
--   * a callback's latent arrow effect (`(a -> <e> b)`) — a Row-kinded effect
--     row, captured by effTailNames over each arg;
--   * a row-kinded type-CONSTRUCTOR argument (`Async e a`, where Async's first
--     param has kind Row) — captured by rowArgNames, which consults the ctor's
--     recorded param kinds (dataParamKindsRef) and takes ONLY the tyvars sitting
--     in a KRow slot. `List e`/`Box e` (Type-kinded param) contribute nothing.
-- An effect tail var in the RETURN row and in no such Row-kinded argument slot
-- is the laundering hazard (map/fold/traverse/`Async e a` are pinned;
-- `speak : a -> <e> String` and `speak : a -> List e -> <e> String` are not).
-- An abstract row-ctor arg (`r e a`, `r` a type variable) is conservatively
-- rejected — no real interface method has that shape, and matching it soundly
-- would need per-argument kind inference we do not run here.
undeterminedRetEffVars : ModuleCtx ->
  List (String, List Kind) ->
  Ty ->
  List String
undeterminedRetEffVars mctx scope sig =
  let args = methodArgs sig
  let argCarried =
    dedup (flatMap effTailNames args ++ flatMap (rowArgNamesIn mctx scope) args)
  let retTail = dedup (effTailNames (methodRet sig))
  removeAllS argCarried retTail

-- return type of a method: strip leading constraint wrappers and arrows, but
-- KEEP a trailing effect row so its tail var is visible (unlike methodArgs,
-- which peels it).
methodRet : Ty -> Ty
methodRet (TyConstrained _ t) = methodRet t
methodRet (TyFun _ b) = methodRet b
methodRet t = t

-- The signature the declared-row walks below read: every alias on the return
-- spine expanded, so the declared row is the row `fromAstTypeE` elaborates.
-- `d : Tick` with `type Tick = Int -> <Stdout> Unit` declares `<Stdout>`, and
-- so do `v : S` and `f : Int -> S` with `type S = <Stdout> Int`
-- (`writtenBindingForce`, `returnRowE`).  An alias that expands to any other
-- type stays unexpanded, since it carries no row to read.
expandReturnSpine : ModuleCtx -> Ty -> Ty
expandReturnSpine mctx ty = match expandAliasHeadTy mctx ty
  TyFun a ret => TyFun a (expandReturnSpine mctx ret)
  TyConstrained cs t => TyConstrained cs (expandReturnSpine mctx t)
  row@(TyEffect _ _ _) => row
  _ => ty

-- the declared concrete effect set of a signature: labels on the first `<…>`
-- reached walking down the return side (Phase 79e escape check)
declaredEffects : GraphCtx -> Ty -> List Atom
declaredEffects gctx (TyFun _ ret) = declaredEffects gctx ret
declaredEffects gctx (TyEffect effs _ _) = atomsOfWritten gctx effs
declaredEffects gctx (TyConstrained _ t) = declaredEffects gctx t
declaredEffects gctx _ = []

-- #797: the TAIL of that same first `<…>` — the field `declaredEffects` drops.
-- No names is a genuinely CLOSED row (`<>`, `<Stdout>`); one or more is an OPEN
-- one (`<e>`, `<Stdout | e>`, `<Stdout | e | e2>`).  Arms mirror
-- `declaredEffects` exactly, stopping at the same node, so the two always
-- describe ONE row.
declaredEffectTail : Ty -> List String
declaredEffectTail (TyFun _ ret) = declaredEffectTail ret
declaredEffectTail (TyEffect _ tail _) = tail
declaredEffectTail (TyConstrained _ t) = declaredEffectTail t
declaredEffectTail _ = []

-- #797: effect-tail names occurring in ARGUMENT positions of the signature,
-- walking the same return spine `declaredEffects` walks and stopping at the same
-- node.  A name here is one the CALLER also constrains, so the declared return
-- row is not free even though it is syntactically open.
--
-- Deliberately BROADER than `methodEffArgOccs`: that collector answers "can
-- the BODY perform this row" and so excludes an even-contravariant-depth
-- occurrence (`((Unit -> <e> Unit) -> Int)`).  The question here is the
-- different one "does the caller pin this var", for which ANY argument-side
-- occurrence counts — an even-depth `e` is still unified with the caller's
-- chosen row.  `effTailNames`' documented name-based over-counting (`List <e>`)
-- is likewise conservative in the safe direction here: it can only make a row
-- read as argument-carried, i.e. keep the pre-#797 rejection, never widen.
declaredArgEffNames : ModuleCtx -> Ty -> List String
declaredArgEffNames mctx (TyFun a ret) =
  effTailNames a ++ rowArgNames mctx a ++ declaredArgEffNames mctx ret
declaredArgEffNames mctx (TyConstrained _ t) = declaredArgEffNames mctx t
declaredArgEffNames mctx _ = []

-- #797: is the declared return row genuinely OPEN — a free tail var that appears
-- NOWHERE on the argument side?  Such a var is chosen by nothing but the callee's
-- own body: `f : Int -> <e> String` means "f performs whatever it performs", so a
-- body performing <Stdout> is not an escape and must not be reported as one.
-- An argument-carried var (`g : (Int -> <e> Int) -> <e> Int`) is NOT open in this
-- sense — the caller instantiates it, so a body adding <Stdout> would launder,
-- and the pre-existing escape rejection stands unchanged.
-- A JOIN is open when SOME member is free of the argument side: that member
-- alone already admits whatever the body performs.
declaredEffectsOpen : ModuleCtx -> Ty -> Bool
declaredEffectsOpen mctx ty =
  let argNames = declaredArgEffNames mctx ty
  anyList (v => not (contains v argNames)) (declaredEffectTail ty)

export
evOrdinal : EvId -> Int
evOrdinal (EvId _ i) = i

mentionsEscaped : ModuleCtx -> Authority -> Bool
mentionsEscaped mctx q =
  anyList
    (cell =>
      IdMap.has (authvarId cell) mctx.mcCells.escapedExistentialsRef.value)
    (authVars q)

export
registerLocalAbsIf : ModuleCtx ->
  String ->
  Option ScopeId ->
  Scheme ->
  Int ->
  Int ->
  Unit
registerLocalAbsIf mctx name lscope sch oblN0 callN0 =
  recordLocalQuantified mctx.mcGraph sch
  match lscope
    Some scope =>
      registerLocalGrants mctx.mcGraph name sch
      registerLocalAbs mctx name scope sch oblN0 callN0
    None => ()

-- A generalized local's quantified variables stay in the enclosing binding's
-- obligation window, but they are the scheme's now: each use instantiates them
-- afresh, and the enclosing boundary's defaulting must reach those instances,
-- never the scheme's own variables.  Grounding one would fix the local at one
-- type behind every use and select one dictionary for two predicates (#3516).
recordLocalQuantified : GraphCtx -> Scheme -> Unit
recordLocalQuantified gctx sch = match schemeIds sch
  [] => ()
  ids =>
    let st = gctx.graphRun.localAbs
    st.lasQuantified := omFromNames (map intToString ids) st.lasQuantified.value

-- The catalog externs whose authority parameter names a file path
-- (`stdlib/runtime.mdk`), each with its value arity and the number of paths it
-- names.  No other extern takes a grant: a foreign function is not a
-- parameterized file extern.
export
fileGrantExterns : OrdMap (Int, Int)
fileGrantExterns = RuntimeGrants.fileGrantExterns

-- Grants are passed only on a graph whose driver ran the marking preamble: a
-- driver that never marks has no use that could carry one.
grantsEnabled : GraphCtx -> Unit -> Bool
grantsEnabled gctx _ = isSome gctx.markSetsRef.value

-- What a use of [name] in the module being marked denotes.  An extern the module
-- declares or imports is a foreign declaration, and one spelled like a catalog
-- file extern binds that same runtime operation (a redeclaration must agree with
-- the catalog row); any other value the module defines or imports is a source
-- binding; a name the module neither defines nor imports is the catalog extern
-- when the catalog declares it.
grantCalleeOf : ModuleCtx -> String -> GrantCallee
grantCalleeOf mctx name
  | isLocalAbsName name = SourceCallee
  | otherwise = match mctx.mcCells.markingRef.value
    Some mm =>
      if omHasKey name mm.mmExterns then
        externCallee name
      else if omHasKey name mm.mmUserNames then
        SourceCallee
      else
        catalogCallee mctx.mcGraph name
    None => catalogCallee mctx.mcGraph name

catalogCallee : GraphCtx -> String -> GrantCallee
catalogCallee gctx name =
  if omHasKey name gctx.builtinExternNamesRef.value then
    externCallee name
  else
    SourceCallee

externCallee : String -> GrantCallee
externCallee name =
  if omHasKey name fileGrantExterns then FileExternCallee else NoGrantCallee

-- Whether the marker gives a use of [n] a grant identity: the binding [n] denotes
-- in [env] is a value, not an interface method (whose uses are method
-- occurrences), that takes grants, and its own scheme quantifies an authority.
export
grantNameIn : TcEnv -> String -> Bool
grantNameIn env n
  | not (grantsEnabled env.teDyn.dcModule.mcGraph ()) = False
  | otherwise = match lookupBinding env n
    Some b => match b.ebMethodRow
      Some _ => False
      None =>
        calleeTakesGrants (grantCalleeOf env.teDyn.dcModule n)
          && isNonEmptyL (schemeAuthIds b.ebValue.vsScheme)
    None => False

calleeTakesGrants : GrantCallee -> Bool
calleeTakesGrants SourceCallee = True
calleeTakesGrants FileExternCallee = True
calleeTakesGrants NoGrantCallee = False

-- A scheme's quantified authorities in grant order: first occurrence in the
-- type read left to right (an arrow's domain, its row, its result), so a
-- scheme and every copy of it list them alike whatever ids they carry.
export
grantOrder : Scheme -> List Int
grantOrder (Forall _ _ [] _ _ _) = []
grantOrder (Forall _ _ avars _ force body) =
  let seen = reverseL (authOrderRow force (authOrderIn body []))
  let quantified = filterList (i => containsI i avars) seen
  quantified ++ filterList (i => not (containsI i quantified)) avars

export
grantOccOf : GraphCtx -> EvId -> Option GrantOcc
grantOccOf gctx ev = IdMap.get (evOrdinal ev) gctx.graphRun.grants.gsOccs.value

setGrantOcc : GraphCtx -> EvId -> GrantOcc -> Unit
setGrantOcc gctx ev occ =
  let st = gctx.graphRun.grants
  st.gsOccs := IdMap.set (evOrdinal ev) occ st.gsOccs.value

-- The binding id resolve's stamp would have given this use: its top-level
-- binder's, or 0 for an imported name.
export
grantOnlyBindingId : ModuleCtx -> String -> Int
grantOnlyBindingId mctx name = match mctx.mcCells.markingRef.value
  Some mm => optionOr 0 (omLookup name mm.mmTop)
  None => 0

export
recordGrantOcc : ModuleCtx ->
  String ->
  EvId ->
  Scheme ->
  List (Int, Authority) ->
  Unit
recordGrantOcc mctx name ev (scheme@(Forall _ _ _ _ _ body)) subst =
  match grantCalleeOf mctx name
    NoGrantCallee => ()
    SourceCallee => recordOccWith mctx name ev scheme subst None False
    FileExternCallee =>
      recordOccWith mctx name ev scheme subst (Some (arrowArity body)) False

-- A method candidate's use: its grants follow its value arguments.
export
recordMethodGrantOcc : ModuleCtx ->
  String ->
  EvId ->
  Scheme ->
  List (Int, Authority) ->
  Unit
recordMethodGrantOcc mctx name ev (scheme@(Forall _ _ _ _ _ body)) subst =
  recordOccWith mctx name ev scheme subst (Some (arrowArity body)) False

-- A method occurrence typed as the standalone binding its name shadows: that
-- binding's grants, leading its arguments.
export
recordStandaloneGrantOcc : ModuleCtx ->
  String ->
  EvId ->
  Scheme ->
  List (Int, Authority) ->
  Int ->
  Unit
recordStandaloneGrantOcc mctx name ev scheme subst arity =
  recordOccWith mctx name ev scheme subst (Some arity) True

recordOccWith : ModuleCtx ->
  String ->
  EvId ->
  Scheme ->
  List (Int, Authority) ->
  Option Int ->
  Bool ->
  Unit
recordOccWith mctx name ev scheme subst trailing standalone =
  match grantOrder scheme
    [] => ()
    ids => setGrantOcc mctx.mcGraph ev GrantOcc {
      goCallee = name,
      goCells = map (i => optionOr (AJoin []) (lookupAssocI i subst)) ids,
      goRecIds = [],
      goTrailing = trailing,
      goChain = grantChainAt mctx.mcGraph (captureScope mctx ()),
      goStandalone = standalone,
    }

-- The evidence id of the method occurrence heading an application spine.
export
spineHeadEv : Expr -> Option EvId
spineHeadEv (ELoc _ e) = spineHeadEv e
spineHeadEv (EApp f _) = spineHeadEv f
spineHeadEv (EMethodAt _ _ ev) = Some ev
-- any other head is not a method occurrence
spineHeadEv _ = None

-- A shadow application's head, typed as the standalone [occurrence] selected.
export
recordStandaloneAt : ModuleCtx ->
  String ->
  Expr ->
  SelectedValueOccurrence ->
  Unit
recordStandaloneAt mctx name hd occurrence = match spineHeadEv hd
  Some ev =>
    recordStandaloneGrantOcc
      mctx
      name
      ev
      occurrence.svoScheme
      occurrence.svoInstance.mtiSubstitution.misAuthSubst
      (funArity occurrence.svoInstance.mtiBody)
  None => ()

export
methodGrantOf : GraphCtx -> String -> String -> Option MethodGrant
methodGrantOf gctx ifaceWord method =
  omLookup
    (methodGrantKey ifaceWord method)
    gctx.graphRun.grants.gsMethods.value

-- The interface methods a module declares whose type quantifies authorities; any
-- other method it declares has no row, whatever an earlier check of the module id
-- left.  The grants follow the arrows the written type spells, since that declared
-- arity is what the backends read; a result an alias names a function stays the
-- result.
export
recordMethodGrants : GraphCtx -> List MethodSchemeRow -> Unit
recordMethodGrants gctx rows =
  let st = gctx.graphRun.grants
  st.gsMethods :=
    fold
      (acc row =>
        let key =
          methodGrantKey
            (ifaceWordOf row.msrIface.irOrigin row.msrIface.irName)
            row.msrName
        match methodGrantOfRow row
          Some mg => omInsert key mg acc
          None => omDelete key acc)
      st.gsMethods.value
      rows

methodGrantOfRow : MethodSchemeRow -> Option MethodGrant
methodGrantOfRow row = match row.msrScheme
  Forall _ _ _ _ force body => match grantOrder row.msrScheme
    [] => None
    ids =>
      let cells = authCellsIn body (authRowCells force Tip)
      Some MethodGrant {
        mgArity = tyArrowCount row.msrType,
        mgNames =
          map
            (i => match IdMap.get i cells
              Some cell => optionOr "" (authvarName cell)
              None => "")
            ids,
      }

-- Authority variables no caller supplies, whose grant is the whole domain: the
-- escape check has already held every declaration they reach to its label's top.
export
markSourceless : GraphCtx -> List Int -> Unit
markSourceless gctx ids =
  let st = gctx.graphRun.grants
  st.gsSourceless := fold (m i => IdMap.set i () m) st.gsSourceless.value ids

-- The binders around [sid] whose authority parameters a grant may forward,
-- innermost first.
grantChainAt : GraphCtx -> ScopeId -> List GrantBinder
grantChainAt gctx (sid@(ScopeId i)) =
  let frame = Scopes.scopeFrame (currentScopeStore gctx ()) sid
  let outer = match frame.sfParent
    Some parent => grantChainAt gctx parent
    None => []
  let own = match frame.sfOwner
    BindingOwner n => TopGrantBinder frame.sfModuleId n :: outer
    LocalBindingOwner n => LocalGrantBinder n :: outer
    _ => outer
  match IdMap.get i gctx.graphRun.grants.gsBodies.value
    Some body => body :: own
    None => own

-- A generalized top-level group: each member whose scheme quantifies
-- authorities takes them as parameters, and each use of such a member inside
-- the group that instantiated nothing (its type was the member's own) forwards
-- them.  A member that takes none has no row, whatever an earlier check of the
-- module id left.
export
recordTopGrants : GraphCtx ->
  String ->
  List (String, Scheme) ->
  OrdMap (List (List Pat, Expr)) ->
  Unit
recordTopGrants gctx mid schemes grouped =
  let st = gctx.graphRun.grants
  let enabled = grantsEnabled gctx ()
  let granted =
    map ((n, sch) => (n, if enabled then grantOrder sch else [])) schemes
  each (e => setGrantIds st.gsTopIds (grantTopKey mid (fst e), snd e)) granted
  let taking = filterList (e => isNonEmptyL (snd e)) granted
  match taking
    [] => ()
    _ =>
      st.gsTakers := omFromNames (map fst taking) st.gsTakers.value
      fold
        (_ (m, _) =>
          fold
            (_ clause => recordRecursiveGrants gctx mid m taking (snd clause))
            ()
            (clausesOf m grouped))
        ()
        schemes

recordRecursiveGrants : GraphCtx ->
  String ->
  String ->
  List (String, List Int) ->
  Expr ->
  Unit
recordRecursiveGrants gctx mid m taking body =
  let visit =
    e => match e
      EDictAt n ev => match (lookupAssoc n taking, grantOccOf gctx ev)
        (Some ids, None) =>
          setGrantOcc gctx ev GrantOcc {
            goCallee = n,
            goCells = [],
            goRecIds = ids,
            goTrailing = None,
            goChain = [TopGrantBinder mid m],
            goStandalone = False,
          }
          e
        _ => e
      _ => e
  let _ = mapExpr visit body
  ()

-- A generalized candidate local: its quantified authorities become its
-- parameters, and its uses inside its own right-hand side forward them.
registerLocalGrants : GraphCtx -> String -> Scheme -> Unit
registerLocalGrants gctx name sch = match grantOrder sch
  [] => ()
  ids =>
    let st = gctx.graphRun.grants
    st.gsLocalIds := omInsert name ids st.gsLocalIds.value
    let recOccs =
      optionOr [] (omLookup name gctx.graphRun.localAbs.lasRecOccs.value)
    fold
      (_ occ => setGrantOcc gctx (fst occ) GrantOcc {
        goCallee = name,
        goCells = [],
        goRecIds = ids,
        goTrailing = None,
        goChain = grantChainAt gctx (snd occ),
        goStandalone = False,
      })
      ()
      recOccs

-- Chunk C: number of arguments applied in this spine (`f a b c` ⇒ 3).
export
appSpineArgCount : Expr -> Int
appSpineArgCount (ELoc _ e) = appSpineArgCount e
appSpineArgCount (EDoOrigin _ e) = appSpineArgCount e
appSpineArgCount (EAnnot e _) = appSpineArgCount e
appSpineArgCount (EApp f _) = 1 + appSpineArgCount f
appSpineArgCount _ = 0

-- Inside a body that collects them (`dcPerformSites`), each variable tail of the
-- row a call runs, with the span of the call: [env] is located at the call.
export
notePerformSite : TcEnv -> EffRow -> Unit
notePerformSite env eff = match env.teDyn.dcPerformSites
  None => ()
  Some sites =>
    sites :=
      map (cell => (cell, env.teDyn.dcModule.mcLoc)) (snd (rowFlat eff))
        ++ sites.value

export
markBinders : Ref (Map Int Unit) -> List (Ref Authvar) -> Unit
markBinders table cells =
  table := fold (m c => IdMap.set (authvarId c) () m) table.value cells

export
collectProducedSummary : ModuleCtx -> List EffRow -> EffRow
collectProducedSummary mctx rows =
  let summary = freshEffectSummary mctx ()
  each (row => recordEffectBody mctx summary row) rows
  summary

export
registerLocalGroupAbs : TcEnv ->
  Int ->
  Int ->
  List (LetBind, Option ScopeId) ->
  Unit
registerLocalGroupAbs env _ _ [] = ()
registerLocalGroupAbs genv oblN0 callN0 ((bind@(LetBind name _ _ _), lscope) :: rest) =
  match lookupVar genv name
    Some sch =>
      registerLocalAbsIf genv.teDyn.dcModule name lscope sch oblN0 callN0
    None => ()
  registerLocalGroupAbs genv oblN0 callN0 rest

export
localBindingSummary : ModuleCtx -> LetBind -> (String, BindingSummary)
localBindingSummary mctx (LetBind name clauses _ _) =
  let arity = match map funClausePair clauses
    (pats, _) :: _ => listLen pats
    [] => 0
  (name, newBindingSummary arity (freshVar mctx) (freshEffectSummary mctx))

-- A declared file row bounds every operation performed while its body runs,
-- including operations in helpers and callbacks. The bound is checked in
-- addition to each extern's own grant; a statically named symlink can change
-- the physical order between the two authorities.
fileBoundKey : Loc -> String
fileBoundKey (Loc file line col endLine endCol) =
  "\{file}:\{intToString line}:\{intToString col}:\{intToString endLine}:\{intToString endCol}"

-- Some application and block roots carry locations only on their children.
-- Key the body by its first source node, and guard the whole body at its
-- binding/lambda seam, rather than guarding that child alone.
export
fileBodyLoc : Expr -> Option Loc
fileBodyLoc (ELoc l _) = Some l
fileBodyLoc e =
  let found = Ref None
  let _ =
    mapChildren
      (child =>
        match found.value
          None => found := fileBodyLoc child
          Some _ => ()
        child)
      e
  found.value

export
fileBoundSite : String -> Loc -> String
-- Parsed locations may have an empty file field; the module keeps equal
-- source spans in different modules from sharing a bound.
fileBoundSite mid loc =
  "\{intToString (stringLength mid)}:\{mid}:\{fileBoundKey loc}"

scopeFileBoundModule : ModuleCtx -> Unit -> String
scopeFileBoundModule mctx _ =
  (Scopes.scopeFrame
    (currentScopeStore mctx.mcGraph ())
    (captureScope mctx ())).sfModuleId

export
fileValueKey : String -> Expr -> Option String
fileValueKey mid e =
  map (loc => "\{fileBoundSite mid loc}:\{fileValueShape e}") (fileBodyLoc e)

fileValueShape : Expr -> String
fileValueShape (ELoc _ _) = "loc"
fileValueShape (EApp f _) = "app" ++ intToString (appSpineArgCount f + 1)
fileValueShape (ELam _ _) = "lambda"
fileValueShape _ = "value"

finishFileValueScope : ModuleCtx -> Unit -> Unit
finishFileValueScope mctx _ = match mctx.mcCells.fileValueScopes.value
  saved :: rest =>
    mctx.mcCells.fileValueScopes := rest
    let flows = wWindow mctx.mcCells.fileValueFlows (snd saved)
    wRestore mctx.mcCells.fileValueFlows saved
    each
      (flow =>
        if isEmptyL rest || not (unsettledFileValueFlow flow) then
          checkFileValueFlow mctx flow)
      flows
    -- A local result can be shaped by a later use in its enclosing scope.
    -- Keep its producer evidence until that receiving type is determined.
    match rest
      [] => ()
      _ =>
        wPushAll
          mctx.mcCells.fileValueFlows
          (reverseL (filterList unsettledFileValueFlow flows))
    ()
  [] => ()

unsettledFileValueFlow : (Option Loc, Mono, Mono) -> Bool
unsettledFileValueFlow (_, upper, lower) =
  unsettledPackedFileBound False upper lower

unsettledPackedFileBound : Bool -> Mono -> Mono -> Bool
unsettledPackedFileBound packed upper lower = match (
  normalize upper,
  normalize lower,
)
  (TVar _, _) => True
  (_, TVar _) => True
  (TQual u _, l) => unsettledPackedFileBound packed u l
  (u, TQual l _) => unsettledPackedFileBound packed u l
  (TApp uf ux, TApp lf lx) =>
    unsettledPackedFileBound True uf lf || unsettledPackedFileBound True ux lx
  (TFun ud ur ux, TFun ld lr lx) =>
    packed && unsettledFileRow ur lr
      || unsettledPackedFileBound packed ld ud
      || unsettledPackedFileBound packed ux lx
  _ => False

unsettledFileRow : EffRow -> EffRow -> Bool
unsettledFileRow upper lower =
  let (ua, ut) = rowFlat upper
  let (la, lt) = rowFlat lower
  isNonEmptyL ut
    || isNonEmptyL lt
    || anyList (a => narrowFileAtom a && authHasVars (atomAuth a)) (ua ++ la)

checkFileValueFlow : ModuleCtx -> (Option Loc, Mono, Mono) -> Unit
checkFileValueFlow mctx (loc, upper, lower) =
  if changesPackedFileBound False upper lower then
    pushTypeErrorOncePerSite
      mctx
      "T-FILE-BOUND-VALUE"
      loc
      ("a function's file bound cannot change inside a container: "
        ++ ppMonosShared [lower, upper]
        ++ "; annotate the function with the container's FileRead or FileWrite bound before packing it")

changesPackedFileBound : Bool -> Mono -> Mono -> Bool
changesPackedFileBound packed upper lower = match (
  normalize upper,
  normalize lower,
)
  (TQual u _, l) => changesPackedFileBound packed u l
  (u, TQual l _) => changesPackedFileBound packed u l
  (TApp uf ux, TApp lf lx) =>
    changesPackedFileBound True uf lf || changesPackedFileBound True ux lx
  (TFun ud ur ux, TFun ld lr lx) =>
    packed && changesFileRow ur lr
      || changesPackedFileBound packed ld ud
      || changesPackedFileBound packed ux lx
  _ => False

changesFileRow : EffRow -> EffRow -> Bool
changesFileRow upper lower =
  let (ua, ut) = rowFlat upper
  let (la, lt) = rowFlat lower
  isEmptyL ut
    && anyList
      (u =>
        narrowFileAtom u
          && (isNonEmptyL lt
            || anyList
              (l =>
                atomKey l == atomKey u
                  && not
                    (authSub (atomAuth l) (atomAuth u)
                      && authSub (atomAuth u) (atomAuth l)))
              la))
      ua

export
hasFileBoundValue : Mono -> Bool
hasFileBoundValue t = match normalize t
  TFun _ row result =>
    let (atoms, tails) = rowFlat row
    isEmptyL tails && anyList narrowFileAtom atoms || hasFileBoundValue result
  TQual inner _ => hasFileBoundValue inner
  _ => False

export
recordValueFileBound : ModuleCtx -> Expr -> Mono -> Unit
recordValueFileBound mctx e ty =
  if hasFileBoundValue
    ty then match fileValueKey (scopeFileBoundModule mctx ()) e
    Some key =>
      let st = mctx.mcGraph.graphRun.grants
      st.gsValueBounds :=
        omInsert
          key
          ((ty, grantChainAt mctx.mcGraph (captureScope mctx ()))
            :: optionOr [] (omLookup key st.gsValueBounds.value))
          st.gsValueBounds.value
    None => ()

export
recordFileBound : ModuleCtx -> Expr -> EffRow -> Unit
recordFileBound mctx body row =
  let (atoms, tails) = rowFlat row
  if isEmptyL tails && anyList narrowFileAtom atoms then match fileBodyLoc body
    None => ()
    Some loc =>
      let st = mctx.mcGraph.graphRun.grants
      let key = fileBoundSite (scopeFileBoundModule mctx ()) loc
      st.gsBounds :=
        omInsert
          key
          ((row, grantChainAt mctx.mcGraph (captureScope mctx ()))
            :: optionOr [] (omLookup key st.gsBounds.value))
          st.gsBounds.value

export
narrowFileAtom : Atom -> Bool
narrowFileAtom atom = match atomLabelOf atom
  EffLabel label OriginBuiltin =>
    (label == "FileRead" || label == "FileWrite")
      && not (authIsTop (atomAuth atom))
  _ => False

export
recordClauseFileBound : ModuleCtx -> Expr -> Int -> Mono -> Unit
recordClauseFileBound mctx body arity ty
  | arity <= 0 = ()
  | otherwise = match normalize ty
    TFun _ row result =>
      if arity == 1 then
        recordFileBound mctx body row
      else
        recordClauseFileBound mctx body (arity - 1) result
    TQual inner _ => recordClauseFileBound mctx body arity inner
    _ => ()

-- #803 (S0, silent wrongness): the impl-body effect-LAUNDER check.  Sound rule, per
-- arrow of the method's DECLARED type down to its final return:
--
--     ∀ arrow i ≤ methodArity.  atoms(body_arrow_effect_i) ⊆ atoms(declared_effect_i)
--
-- i.e. the impl's concrete latent atoms at each arrow must be bounded by the method's
-- declared concrete atoms at that same arrow (the general form of
-- `body_latent ⊆ decl(φ) ∪ argContributable`).  Argument-contributed effects are free
-- and exact: at impl-check every parameter is still a fresh variable, so an effect the
-- body performs by USING an argument (applying a callback, running a row-kinded `Async e`
-- arg) appears as that VARIABLE — never a concrete atom — at every arrow.  Hence the
-- body's *concrete atoms* on any arrow are exactly the INTRINSIC effects, and per-arrow
-- `atomsEscape` against the declared row (IO-expanded via the same expandIoInBound the
-- binding-boundary check uses) is precisely the laundered set — a variable is
-- caller-visible and cannot lie, so only a concrete atom can launder.
--
-- #839 2b: sourced from the absorption event trail (increment 2a), POST-unify, rather
-- than arrowLaunderEscape's pre-unify walk over [expected]/[actual] arrow rows.  The
-- pre-unify walk existed only because `unify` then merges an intrinsic atom into the
-- shared open tail (both-open arm, no effectLeakCheck), after which effrowLabels can no
-- longer see it; 2a records that merge, so a post-unify query recovers it.
--
-- [declArrows]/[actualArrows] = the declared method type's and the inferred body's arrow
-- effect rows, BOTH captured PRE-unify and zipped (same spine, bounded at the shorter —
-- the methodArity bound arrowLaunderEscape had).  [evts] = the events `unify expected
-- actual` recorded in this body's trail window.  The per-arrow residual is
-- `atomsEscape (actual atoms) (declared WRITTEN atoms)`, recovered by two DISJOINT routes
-- keyed on whether the ACTUAL arrow is OPEN or CLOSED:
--
--  * OPEN actual arrow (the common inferred case): an intrinsic atom is ABSORBED at unify
--    (both-open / same-tail arm merges it into a shared tail, no effectLeakCheck), so
--    effrowLabels can no longer see it — recover it from the TRAIL.  Resolve the declared
--    arrow's tail LIVE (post-unify the fresh cell has ELinked into a shared v3 — a record-
--    time id names the old cell, not its current representative), gather atoms absorbed into that same
--    live tail (the per-cell key — risk 3, recovering arrowLaunderEscape's which-arrow
--    precision), and `atomsEscape` them against the declared row.  For a CLOSED declared
--    arrow met by an OPEN actual, the guarded closed~open arm already fired effectLeakCheck
--    (T-EFFECT-LEAK) during the SAME unify, so the trail route yields nothing and the leak
--    line stands alone (the pre-unify walk only ever DOUBLE-reported there).
--    WHY the trail equals the walk here: the both-open arm records the SYMMETRIC diff
--    (actual\declared ++ declared\actual) against the shared v3 both tails link to;
--    `atomsEscape absorbed declared` drops the declared\actual side (⊆ declared) and any
--    IO-covered atom, leaving actual \ expandIo(declared) — arrowLaunderEscape's residual.
--
--  * CLOSED actual arrow (a body type ANNOTATION — `(f : Unit -> <Stdout> Unit)` — or
--    a point-free body): nothing to recover here.  The seam's `unifyInto` checks a
--    closed~closed pair directionally as it meets it (T-EFFECT-LEAK when the actual's
--    atoms escape the declared row, nothing when the impl is PURER than declared), so
--    the query yields nothing for it and the one report stands alone.  (An annotated
--    closed actual met by an OPEN declared arrow lands in the open~closed arm and
--    reports the same launder the #816 effect-var rigidity check would — one report, via
--    launderFlagged suppression — matching the pre-unify walk.)
export
launderEscapeFromLog : GraphCtx ->
  List EffRow ->
  List EffRow ->
  List AbsorptionEvent ->
  List Atom
launderEscapeFromLog gctx [] _ _ = []
launderEscapeFromLog gctx _ [] _ = []
launderEscapeFromLog gctx (der :: dRest) (aer :: aRest) evts =
  let here = match aer
    EffRow _ None => []
    EffRow _ (Some _) => launderOpenActualArrow gctx der evts
  here ++ launderEscapeFromLog gctx dRest aRest evts

-- OPEN actual arrow: recover the absorbed launder atom from the trail, keyed on an OPEN
-- declared arrow's live tail; a CLOSED declared arrow's leak was already reported by the
-- closed~open arm's effectLeakCheck during the unify, so yield nothing.
launderOpenActualArrow : GraphCtx -> EffRow -> List AbsorptionEvent -> List Atom
launderOpenActualArrow gctx (EffRow declAtoms (Some cell)) evts =
  let tid = liveTailId cell
  if tid == 0 - 1 then
    []
  else
    atomsEscape gctx (atomsAbsorbedInto tid evts) declAtoms
launderOpenActualArrow gctx (EffRow _ None) _ = []

-- the concrete atoms the window recorded as absorbed into the live tail [tid]
-- (resolving each event's stored cell live, per risk 2).
atomsAbsorbedInto : Int -> List AbsorptionEvent -> List Atom
atomsAbsorbedInto _ [] = []
atomsAbsorbedInto tid (ev :: rest) =
  if liveTailId ev.cell == tid then
    ev.atom :: atomsAbsorbedInto tid rest
  else
    atomsAbsorbedInto tid rest

-- The effect axis of W3 rigidity, one call shape for both kinds of method body:
-- every [effVars] effect var's row carries no concrete atom beyond what the
-- declared row at EVERY occurrence of that var in [mty] already covers
-- (IO-expanded, as the §5 escape check) — an atom unification poured into the var
-- from a position whose declared row lacks it is an intrinsic effect the caller
-- erases by instantiating the var to <> — and the vars' tails are pairwise
-- distinct; see checkImplEffVarRigidity.
-- #817 carve-out RETIRED (#823): a method effect variable may no longer alias an
-- INSTANCE-HEAD row parameter (`impl Mappable (Async e)`, whose `Suspend` arm
-- stored the callback and forced method `e'` ~ head `e`, charging the effect at
-- build time and performing it at force time).  With the `Deferred*` family the
-- head is the bare constructor and the callback row rides the index, so the
-- identification is never needed; the type-variable half never had the exception.
-- A default body has no instance head and passes [] for [headMonos].
export
checkMethodEffVarRigidity : ModuleCtx ->
  String ->
  List Mono ->
  List (String, List Kind) ->
  Ty ->
  List (String, Ref Effvar) ->
  Bool ->
  List String ->
  Option Loc ->
  Unit
checkMethodEffVarRigidity mctx subject headMonos gscope mty effVars launderFlagged eager loc =
  if anyContainsI
    (effVarTailIds effVars)
    (flatMap monoIndexEffvarIds headMonos) then
    pushTypeErrorOnceAt
      mctx
      "T-IMPL-TOO-SPECIFIC"
      loc
      (aliasesHeadRowMsg subject mty)
  checkImplEffVarRigidity
    mctx
    subject
    gscope
    mty
    effVars
    launderFlagged
    eager
    loc

-- the effect half of the rigidity check: atom containment per declared
-- occurrence, then tail distinctness among the METHOD's own effect vars.
-- A method effect var aliasing an INSTANCE-HEAD row parameter is REJECTED, not
-- admitted: `checkMethodRigidityCore` pushes `T-IMPL-TOO-SPECIFIC` when a
-- method effect var's tail is among `monoIndexEffvarIds` of the head monos,
-- before it calls this function.  No legal impl needs that identification: with
-- the `Deferred*` family the head is the bare constructor and the callback row
-- rides the index.  This function's own dup set is therefore the METHOD's
-- own effect vars only — impl-head row tails never enter it.  (The TYPE-var
-- half never had an exception either: a method type var may never alias an
-- impl-head type var.)
checkImplEffVarRigidity : ModuleCtx ->
  String ->
  List (String, List Kind) ->
  Ty ->
  List (String, Ref Effvar) ->
  Bool ->
  List String ->
  Option Loc ->
  Unit
checkImplEffVarRigidity mctx subject scope mty effMap launderFlagged eager loc =
  let occs =
    effVarOccAtoms mctx.mcGraph mty
      ++ map (n => (n, [])) (rowArgNamesIn mctx scope mty)
  if launderFlagged then () else checkEffVarAtoms mctx subject occs effMap loc
  checkIndexOnlyEffVarsOpen mctx subject effMap loc eager
  -- DEFERRED-PERFORMANCE residual (round-2 break 4; tracked, NOT enforced):
  -- a method effect var forced CLOSED post-unify is in truth a PIN — an impl
  -- that applies its <e>-callback inside a value whose declared row is pure
  -- (`act d k = (u => k ())` under `-> <e> (Unit -> Unit)`) closes e := <>,
  -- and a caller's effectful callback then runs inside a pure-typed thunk.
  -- Rejecting it here is CORRECT but outlaws the compiler's own Parser monad
  -- (`impl Mappable Parser` stores the callback under Parser's pure arrows —
  -- the identical shape, latent because the compiler only passes pure
  -- callbacks) and every pure-container deferred-application impl with it.
  -- Like #817, the honest result type needs grading (`Parser e a`, #820), so
  -- the channel is admitted for now and owned by #825 (pinned).
  if hasDupI (effVarTailIds effMap) then
    pushTypeErrorOnceAt
      mctx
      "T-IMPL-TOO-SPECIFIC"
      loc
      (collapsesEffvarsMsg subject mty)

-- ── D-3 (#1095): a result-INDEX occurrence is a PROMISE, not a CHARGE ──────
-- `checkArgEffVarCoverage` lets a row-kinded occurrence in the method's RESULT
-- (`f e b`) discharge the argument-only obligation the callback's `<e>` raises.
-- That is right for the DECLARATION — `f e b` says "performs <e> when forced"
-- — but it says nothing about the CALL, so an impl that APPLIES its callback
-- (`gmap g (Done a) = Done (g a)`) performs <e> at call time on an arrow the
-- signature declares pure, and nothing charges it: `check` is green and a
-- value typed `Int` prints (both engines).  The declaration cannot see it
-- (the caller sees only the index) and the #803 per-arrow bound cannot see it
-- (applying the callback contributes the VARIABLE `e`, never an atom).  The
-- seam with the information intact is the IMPL BODY: under a signature whose
-- only non-argument occurrences of `e` are indices, the body must leave `e`
-- OPEN.  Performing it — or forcing an `e`-indexed argument — meets the
-- declared-pure arrow and CLOSES `e := <>`, which is exactly the pin
-- `effVarTailIds` documents as "the safe direction" for a var the method's
-- own arrow charges, and is a launder for one it does not.  Storing the
-- callback (`Susp (u => g a)`) unifies `e` with the container's own thunk row
-- and leaves it open, so the deferred arm the spec requires stays legal.
--
-- Scoped to INDEX-ONLY variables on purpose: a var the method's own arrow
-- charges (`map : (a -> <e> b) -> f a -> <e> f b`) may still close — the
-- compiler's own `impl Mappable Parser` stores its callback under a pure
-- arrow and does, which is #825's channel, out of scope here and pinned.
-- Closed alone is not the signal.  An index-only variable can also close
-- through an INDEX unification with no effect performed: `deferAp mf ma =
-- deferThen mf (g => deferMap g ma)` maps a PURE `g` (from `f e (a -> b)`,
-- whose arrow is `<>`), so `deferMap g ma : f <> b` meets the result `f e b`
-- and pins `e := <>` — honest, and sound (the value built carries `mf`'s real
-- row).  What distinguishes the eager arm is that the body PERFORMS `e` on one
-- of the method's own arrows.  So [eager] is computed at the impl seam from the
-- body's arrow rows BEFORE they are unified with the declared (pure) arrows —
-- the same pre-unify snapshot the #803 launder query takes — and only a var in
-- that set is reported here.  (An interface DEFAULT body has no such snapshot
-- available at its rigidity read and passes `[]`: a residual, not a rule.)
checkIndexOnlyEffVarsOpen : ModuleCtx ->
  String ->
  List (String, Ref Effvar) ->
  Option Loc ->
  List String ->
  Unit
checkIndexOnlyEffVarsOpen mctx subject effMap loc eager =
  checkIndexOnlyGo mctx subject effMap loc eager

-- the index-only vars of [mty] that some body arrow row (pre-unify) carries as
-- its tail — i.e. the body performs them at call time.
-- THE BODY'S cells are not the signature'S CELLS.  At the impl seam the
-- clause parameters are inferred fresh (`g : a -> <ρ> b`), and `ρ` is only
-- identified with the declared `<e>` by the final `unify expected actual`.
-- So the pre-unify arrow rows carry `ρ` (or whatever it has been linked to
-- meanwhile), never `e` itself.  [expected]/[actual] are walked in parallel
-- to pair each declared row cell with the actual cell at the same position
-- (`pairRowCells`), and the scan asks whether any of a var's actual
-- counterparts is a tail of some body arrow row.
export
eagerIndexOnlyVars : List String ->
  List (String, Ref Effvar) ->
  List EffRow ->
  Mono ->
  Mono ->
  List String
eagerIndexOnlyVars [] _ _ _ _ = []
eagerIndexOnlyVars idx effMap actualArrows expected actual =
  let tails = flatMap rowTailId actualArrows
  let pairs = pairRowCells expected actual
  filterList (v => effVarCellPerformed v effMap pairs tails) idx

-- (declared cell id, actual cell id) for every row found at the same
-- structural position of the two types — arrow latent rows and index rows,
-- under applications and arrows.  Ids are read AFTER normalization, so a cell
-- already linked during body inference reports its live representative.
pairRowCells : Mono -> Mono -> List (Int, Int)
pairRowCells d a = match peelQual d
  TFun d1 dr d2 => match peelQual a
    TFun a1 ar a2 => pairRows dr ar ++ pairRowCells d1 a1 ++ pairRowCells d2 a2
    _ => []
  TApp d1 d2 => match peelQual a
    TApp a1 a2 => pairRowCells d1 a1 ++ pairRowCells d2 a2
    _ => []
  TEff dr => match peelQual a
    TEff ar => pairRows dr ar
    _ => []
  _ => []

pairRows : EffRow -> EffRow -> List (Int, Int)
pairRows dr ar = match rowTailId dr
  [did] => map (aid => (did, aid)) (rowTailId ar)
  _ => []

effVarCellPerformed : String ->
  List (String, Ref Effvar) ->
  List (Int, Int) ->
  List Int ->
  Bool
effVarCellPerformed v effMap pairs tails = match lookupAssoc v effMap
  Some cell =>
    -- Compare live representatives, not the stable identity of an earlier
    -- linked cell: pairs/tails were recorded through normalization.
    let dids = rowTailId (EffRow [] (Some cell))
    anyList
      (did =>
        containsI did tails
          || anyList (p => fst p == did && containsI (snd p) tails) pairs)
      dids
  None => False

checkIndexOnlyGo : ModuleCtx ->
  String ->
  List (String, Ref Effvar) ->
  Option Loc ->
  List String ->
  Unit
checkIndexOnlyGo mctx _ _ _ [] = ()
checkIndexOnlyGo mctx subject effMap loc (v :: rest) =
  -- [eager] already holds only the vars the body performed on a method arrow
  -- (`eagerIndexOnlyVars`); whether the cell then closed (the pre-#821 unify)
  -- or the ambient became a join (#821) is not the signal, the performing is.
  pushTypeErrorOnceAt mctx "T-EFFECT-INDEX-EAGER" loc (indexEagerMsg subject v)
  checkIndexOnlyGo mctx subject effMap loc rest

-- The earliest collected call that ran a variable now on one of [actual]'s arrows.
export
performSiteIn : Option (Ref (List (Ref Effvar, Option Loc))) ->
  Mono ->
  Option Loc
performSiteIn None _ = None
performSiteIn (Some sites) actual =
  let tails = flatMap rowTailId (allArrowEffs actual)
  findMap
    (site =>
      if anyList
        (id => containsI id tails)
        (rowTailId (EffRow [] (Some (fst site)))) then
        snd site
      else
        None)
    (reverseL sites.value)

-- the method effect vars that ride an ARGUMENT (a callback row or a row-kinded
-- argument) and occur on NO row the method's own type charges — every
-- non-argument occurrence is a result index.
export
indexOnlyEffVars : ModuleCtx -> List (String, List Kind) -> Ty -> List String
indexOnlyEffVars mctx scope mty =
  let argNames = dedup (map fst (methodEffArgOccs mctx scope mty))
  let charged = map fst (methodEffChargedOccs mctx.mcGraph mty)
  filterList (v => not (contains v charged)) argNames

-- effect-var occurrences on rows the method's type CHARGES: each spine arrow's
-- own latent row, and every arrow row written inside the final return type.
-- The `effVarOccAtoms` half of `methodEffRetOccs` minus the two INDEX forms —
-- the row-kinded-slot padding (`rowArgAtomsIn`) and a bare row written in a
-- slot (`TyRow`, `Box <Stdout | e> Unit`) — which promise rather than charge.
methodEffChargedOccs : GraphCtx -> Ty -> List (String, List Atom)
methodEffChargedOccs gctx (TyConstrained _ t) = methodEffChargedOccs gctx t
methodEffChargedOccs gctx (TyEffect labels tails t) =
  occsOfTails gctx tails labels ++ methodEffChargedOccs gctx t
methodEffChargedOccs gctx (TyFun _ b) = methodEffChargedOccs gctx b
methodEffChargedOccs gctx t = effVarChargedOccs gctx t

effVarChargedOccs : GraphCtx -> Ty -> List (String, List Atom)
effVarChargedOccs gctx (TyEffect labels tails t) =
  occsOfTails gctx tails labels ++ effVarChargedOccs gctx t
effVarChargedOccs gctx (TyApp a b) =
  effVarChargedOccs gctx a ++ effVarChargedOccs gctx b
effVarChargedOccs gctx (TyFun a b) =
  effVarChargedOccs gctx a ++ effVarChargedOccs gctx b
effVarChargedOccs gctx (TyTuple ts) = flatMap (effVarChargedOccs gctx) ts
effVarChargedOccs gctx (TyConstrained _ t) = effVarChargedOccs gctx t
effVarChargedOccs gctx _ = []

checkEffVarAtoms : ModuleCtx ->
  String ->
  List (String, List Atom) ->
  List (String, Ref Effvar) ->
  Option Loc ->
  Unit
checkEffVarAtoms mctx _ _ [] _ = ()
checkEffVarAtoms mctx subject occs ((n, cell) :: rest) loc =
  let esc =
    effVarOccEscape mctx.mcGraph n (effrowLabels (EffRow [] (Some cell))) occs
  if isNonEmptyL esc then
    pushTypeErrorOnceAt
      mctx
      "T-EFFECT-LAUNDER"
      loc
      (effVarLaunderMsg subject n esc)
  checkEffVarAtoms mctx subject occs rest loc

-- the first occurrence of var [n] whose declared atoms fail to cover
-- [instAtoms]: laundering demands EVERY occurrence cover the instantiation,
-- since the caller reads the var's row at each of them independently.
effVarOccEscape : GraphCtx ->
  String ->
  List Atom ->
  List (String, List Atom) ->
  List Atom
effVarOccEscape gctx _ [] _ = []
effVarOccEscape gctx _ _ [] = []
effVarOccEscape gctx n instAtoms ((m, declAtoms) :: rest) =
  if m == n && isNonEmptyL (atomsEscape gctx instAtoms declAtoms) then
    atomsEscape gctx instAtoms declAtoms
  else
    effVarOccEscape gctx n instAtoms rest

-- (name, written atoms) for each named-tail row occurrence in a method's AST
-- type — every TyEffect node, on the arrow spine or nested (tuples, callback
-- rows, data-arg rows).  Bare row-kinded ctor-arg slots (`Async e a`) carry no
-- written atoms and are contributed by rowArgNames at the call site.
effVarOccAtoms : GraphCtx -> Ty -> List (String, List Atom)
effVarOccAtoms gctx (TyEffect labels tails t) =
  occsOfTails gctx tails labels ++ effVarOccAtoms gctx t
-- A bare row atom (#997) is a named-tail row occurrence exactly like
-- `TyEffect` above, just with no wrapped type. Without this arm, a KRow
-- ctor-arg written as `Box <Stdout | e> Int` was invisible to
-- `checkImplEffVarRigidity`'s coverage set, so the impl-body T-EFFECT-LAUNDER
-- check over-fired ("not sourced from any argument") on an argument that
-- demonstrably DOES declare the atom.
effVarOccAtoms gctx (TyRow labels tails _) = occsOfTails gctx tails labels
effVarOccAtoms gctx (TyApp a b) = effVarOccAtoms gctx a ++ effVarOccAtoms gctx b
effVarOccAtoms gctx (TyFun a b) = effVarOccAtoms gctx a ++ effVarOccAtoms gctx b
effVarOccAtoms gctx (TyTuple ts) = flatMap (effVarOccAtoms gctx) ts
effVarOccAtoms gctx (TyConstrained _ t) = effVarOccAtoms gctx t
effVarOccAtoms gctx _ = []

export
clausesAt : String -> OrdMap (List (List Pat, Expr)) -> List (List Pat, Expr)
clausesAt n m = match omLookup n m
  Some xs => xs
  None => []

export
clausesOf : String -> OrdMap (List (List Pat, Expr)) -> List (List Pat, Expr)
clausesOf n m = revClauses (clausesAt n m) []

export
revClauses : List (List Pat, Expr) ->
  List (List Pat, Expr) ->
  List (List Pat, Expr)
revClauses [] acc = acc
revClauses (x :: xs) acc = revClauses xs (x :: acc)

export
memberEffectRoots : ScopedMember -> Map Int Unit -> Map Int Unit
memberEffectRoots member roots =
  let inputs =
    if member.smSigned.value then
      roots
    else
      effectRoots member.smOwned.bsValue roots
  IdMap.foldlWithKey
    (acc id _ => IdMap.set id () acc)
    inputs
    member.smDeclaredRoots.value

-- a signatured binding's body must not perform a concrete effect its signature
-- doesn't declare; effect *variables* (polymorphic `<e>`) carry no labels and so
-- never escape (Phase 79e)
export
checkEffectEscape : DynCtx -> List (String, Ty) -> String -> List Atom -> Unit
checkEffectEscape dyn sigs m effs = match dyn.dcGroup
  None => ()
  Some group => checkEffectEscapeIn dyn.dcModule group sigs m effs

checkEffectEscapeIn : ModuleCtx ->
  GroupCtx ->
  List (String, Ty) ->
  String ->
  List Atom ->
  Unit
checkEffectEscapeIn mctx group sigs m effs =
  match omLookup m mctx.mcCells.sigTyMapRef.value
    None => ()
    -- #797: a genuinely open declared row (free return-position tail var, no
    -- argument-side occurrence) has nothing to escape FROM — the row admits
    -- whatever the body performs, which is what a free tail var MEANS.  Skipping
    -- here rather than widening `declaredEffects` keeps the CLOSED-row rejection
    -- (and its wording) byte-identical.
    Some written =>
      let ty = expandReturnSpine mctx written
      if declaredEffectsOpen mctx ty then
        ()
      else match (atomsEscape
        mctx.mcGraph
        (filterList concreteAtom effs)
        (declaredEffects mctx.mcGraph ty))
        -- An atom whose authority is still symbolic is the scoped solver's to
        -- decide once the binding's arguments have bounded it; comparing it
        -- here would report a variable a later solution resolves.

        [] => ()
        extras =>
          group.gcPendingEscapes :=
            (
                m,
                mctx.mcLoc,
                effectEscapeMsg
                  m
                  (declaredEffects mctx.mcGraph ty)
                  (declaredEffectTail ty)
                  extras,
              )
              :: group.gcPendingEscapes.value

-- After a group's solver scope has closed: report the walk's finding for a
-- member the solver said nothing about, and drop it for one it reported.
export
flushPendingEscapes : ModuleCtx -> Option GroupCtx -> Unit
flushPendingEscapes mctx None = ()
flushPendingEscapes mctx (Some group) =
  let pending = reverseL group.gcPendingEscapes.value
  group.gcPendingEscapes := []
  fold
    (_ entry =>
      let (m, loc, msg) = entry
      if omHasKey m mctx.mcCells.rowFailureReportedRef.value then
        ()
      else
        pushTypeErrorAt mctx "T-EFFECT-LEAK" loc msg)
    ()
    pending

concreteAtom : Atom -> Bool
concreteAtom a = not (authHasVars (atomAuth a))
# DESUGAR
(DUse false (UseGroup ("types" "tc_types") ((mem "grantTopKey" false) (mem "methodGrantKey" false) (mem "setGrantIds" false) (mem "AbsorptionEvent" true) (mem "GrantBinder" true) (mem "GrantCallee" true) (mem "GrantOcc" true) (mem "MethodGrant" true) (mem "DynCtx" false) (mem "GraphCtx" false) (mem "GroupCtx" false) (mem "Kind" false) (mem "MethodSchemeRow" false) (mem "ModuleCtx" false) (mem "ObligationSite" false) (mem "ScopedMember" false) (mem "SelectedValueOccurrence" false) (mem "TcEnv" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "allArrowEffs" false) (mem "arrowArity" false) (mem "authCellsIn" false) (mem "authOrderIn" false) (mem "authOrderRow" false) (mem "authRoots" false) (mem "authRowCells" false) (mem "authRowRoots" false) (mem "containsI" false) (mem "effectCells" false) (mem "effectRoots" false) (mem "effectRowRoots" false) (mem "funArity" false) (mem "joinCellOf" false) (mem "monoIndexEffvarIds" false) (mem "newEffvarId" false) (mem "peelQual" false) (mem "rowTailId" false) (mem "schemeAuthIds" false) (mem "schemeIds" false) (mem "tyAppSpine" false) (mem "tyArrowCount" false) (mem "liveTailId" false) (mem "anyContainsI" false) (mem "effVarTailIds" false) (mem "hasDupI" false))))
(DUse false (UseGroup ("types" "tc_diag_text") ((mem "aliasesHeadRowMsg" false) (mem "argAtomsMsgFor" false) (mem "argOnlyEffVarMsg" false) (mem "collapsesEffvarsMsg" false) (mem "effectEscapeMsg" false) (mem "effectInclusionMsg" false) (mem "effectUndeterminedMsg" false) (mem "effVarLaunderMsg" false) (mem "indexEagerMsg" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "currentScopeStore" false) (mem "mctxAt" false) (mem "wPushAll" false) (mem "wRestore" false) (mem "wSnapshot" false) (mem "wWindow" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "declGradedScope" false) (mem "effTailNames" false) (mem "funClausePair" false) (mem "lookupBinding" false) (mem "lookupVar" false) (mem "methodArgs" false) (mem "removeAllS" false) (mem "tyTabKey" false))))
(DUse false (UseGroup ("types" "tc_diag") ((mem "pushTypeError" false) (mem "pushTypeErrorAt" false) (mem "pushTypeErrorOnceAt" false) (mem "pushTypeErrorOncePerSite" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "atomsEscape" false) (mem "authorityFailureMsg" false) (mem "captureScope" false) (mem "effectLeakCheck" false) (mem "effectSiteKey" false) (mem "freshEffvarAt" false) (mem "freshVar" false) (mem "producedSlotCovariants" false) (mem "reportIndexFailure" false) (mem "resolvePendingJoins" false) (mem "widenOpenedFor" false))))
(DUse false (UseGroup ("types" "tc_decls_types") ((mem "atomsOfWritten" false) (mem "expandAliasHeadTy" false) (mem "rowArgNames" false) (mem "rowArgNamesIn" false))))
(DUse false (UseGroup ("types" "tc_decls") ((mem "krowArgVarAtoms" false) (mem "paramRowAtomsOf" false) (mem "rowArgAtomsIn" false))))
(DUse false (UseGroup ("types" "tc_solve") ((mem "isLocalAbsName" false))))
(DUse false (UseGroup ("types" "tc_solve_check") ((mem "registerLocalAbs" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" true) (mem "authHasVars" false) (mem "authIsTop" false) (mem "authSub" false) (mem "authvarId" false) (mem "authvarName" false) (mem "authVars" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" true) (mem "EffLabel" true) (mem "EffRow" true) (mem "Effvar" true) (mem "atomAuth" false) (mem "atomKey" false) (mem "atomLabelOf" false) (mem "atomsDiff" false) (mem "effrowLabels" false) (mem "findAtom" false) (mem "rowFlat" false))))
(DUse false (UseGroup ("types" "repr") ((mem "AuthResidual" true) (mem "Mono" true) (mem "Scheme" true) (mem "lookupAssocI" false) (mem "normalize" false) (mem "ppEachShared" false) (mem "ppMonosShared" false))))
(DUse false (UseGroup ("types" "effect_bindings") ((mem "BindingSummary" true) (mem "newBindingSummary" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "EffAtomTy" true) (mem "EvId" true) (mem "Expr" true) (mem "IfaceMethod" true) (mem "LetBind" true) (mem "Loc" true) (mem "Pat" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "firstTyLoc" false) (mem "lookupTab" false) (mem "orElseLoc" false))))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omDelete" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("types" "evidence") ((mem "ScopeId" true))))
(DUse false (UseGroup ("types" "effect_solver") ((mem "ScopeRoles" true) (mem "noScopeRoles" false) (mem "SummaryFailure" false))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "contains" false) (mem "dedup" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "isSome" false) (mem "joinWith" false) (mem "listLen" false) (mem "lookupAssoc" false) (mem "reverseL" false))))
(DUse false (UseGroup ("list") ((mem "findMap" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "ifaceWordOf" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "mapChildren" false) (mem "mapExpr" false))))
(DUse false (UseGroup ("types" "effect_values") ((mem "producedInputTypes" false))))
(DUse false (UseAlias ("types" "scopes") "Scopes"))
(DUse false (UseAlias ("types" "runtime_grants") "RuntimeGrants"))
(DUse false (UseAlias ("types" "effect_solver") "EffectSolver"))
(DUse false (UseAlias ("map") "IdMap"))
(DUse false (UseGroup ("types" "scopes") ((mem "ScopeOwner" true))))
(DTypeSig false "effectSiteOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "Authority")) (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "effectSiteOf" ((PVar "mctx") PWild (PCon "None") PWild) (EVar "None"))
(DFunDef false "effectSiteOf" ((PVar "mctx") (PVar "fn") (PCon "Some" (PVar "label")) (PVar "bound")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EApp (EVar "effectSiteKey") (EVar "fn")) (EVar "label"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "effectSitesRef") "value")) (arm (PCon "Some" (PVar "sites")) () (EBlock (DoLet false false (PVar "ordered") (EApp (EVar "reverseL") (EVar "sites"))) (DoLet false false (PVar "offending") (EMatch (EVar "bound") (arm (PCon "Some" (PVar "hi")) () (EApp (EApp (EVar "filterList") (ELam ((PVar "site")) (EApp (EVar "not") (EApp (EApp (EVar "authSub") (EApp (EVar "fst") (EVar "site"))) (EVar "hi"))))) (EVar "ordered"))) (arm (PCon "None") () (EListLit)))) (DoExpr (EMatch (EBinOp "++" (EVar "offending") (EVar "ordered")) (arm (PCons (PVar "site") PWild) () (EApp (EVar "snd") (EVar "site"))) (arm (PList) () (EVar "None")))))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig true "beginEffectSummaryScope" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "Unit"))))
(DFunDef false "beginEffectSummaryScope" ((PVar "mctx") PWild) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fileValueScopes")) (EBinOp "::" (EApp (EVar "wSnapshot") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fileValueFlows")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fileValueScopes") "value")))) (DoExpr (EApp (EApp (EApp (EVar "EffectSolver.openSummaryScope") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "effectSummaries")) (EApp (EApp (EVar "newEffvarId") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")))))
(DTypeSig true "freshEffectSummary" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "EffRow"))))
(DFunDef false "freshEffectSummary" ((PVar "mctx") PWild) (EApp (EApp (EVar "EffectSolver.newSummary") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "effectSummaries")) (EApp (EApp (EVar "newEffvarId") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))))
(DTypeSig true "recordEffectBody" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Unit")))))
(DFunDef false "recordEffectBody" ((PVar "mctx") (PVar "summary") (PVar "lower")) (EApp (EApp (EApp (EVar "EffectSolver.recordBodyLower") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "effectSummaries")) (EVar "summary")) (EVar "lower")))
(DTypeSig false "summaryEscape" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))))
(DFunDef false "summaryEscape" ((PVar "gctx") (PCon "True") (PVar "lower") (PVar "upper")) (EApp (EApp (EVar "atomsDiff") (EVar "lower")) (EVar "upper")))
(DFunDef false "summaryEscape" ((PVar "gctx") (PCon "False") (PVar "lower") (PVar "upper")) (EApp (EApp (EApp (EVar "atomsEscape") (EVar "gctx")) (EVar "lower")) (EVar "upper")))
(DTypeSig false "finishEffectSummaryScope" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyCon "Unit")))))
(DFunDef false "finishEffectSummaryScope" ((PVar "mctx") (PVar "retained") (PVar "borrowed")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "finishEffectSummaryScopeKeeping") (EVar "mctx")) (EVar "noScopeRoles")) (EVar "retained")) (EVar "borrowed"))) (DoExpr (ELit LUnit))))
(DTypeSig true "finishEffectSummaryScopeKeeping" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ScopeRoles") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "AuthResidual"))))))))
(DFunDef false "finishEffectSummaryScopeKeeping" ((PVar "mctx") (PVar "roles") (PVar "retained") (PVar "borrowed")) (EBlock (DoLet false false (PVar "outcome") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "EffectSolver.closeSummaryScope") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "effectSummaries")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "rigidEffvarsRef") "value")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "rigidAuthvarsRef") "value")) (EVar "roles")) (EVar "retained")) (EVar "borrowed")) (EApp (EVar "summaryEscape") (EFieldAccess (EVar "mctx") "mcGraph"))) (EApp (EVar "joinCellOf") (EFieldAccess (EVar "mctx") "mcGraph"))) (EApp (EVar "freshEffvarAt") (EFieldAccess (EVar "mctx") "mcGraph"))) (EApp (EVar "widenOpenedFor") (EVar "mctx")))) (DoExpr (EApp (EApp (EVar "reportEffectSummaryFailures") (EVar "mctx")) (EFieldAccess (EVar "outcome") "esoFailures"))) (DoExpr (EApp (EApp (EVar "finishFileValueScope") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "member") (PVar "w"))) (ETuple (EVar "member") (ERecordCreate "AuthResidual" ((fa "arLower" (EFieldAccess (EVar "w") "awLower")) (fa "arUpper" (EFieldAccess (EVar "w") "awUpper")) (fa "arExact" (EFieldAccess (EVar "w") "awExact"))))))) (EFieldAccess (EVar "outcome") "esoResiduals")))))
(DTypeSig true "reportEffectSummaryFailures" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "SummaryFailure") (TyCon "ObligationSite"))) (TyCon "Unit"))))
(DFunDef false "reportEffectSummaryFailures" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "reportEffectSummaryFailures" ((PVar "outer") (PCons (PVar "failure") (PVar "rest"))) (EBlock (DoLet false false (PVar "fn") (EFieldAccess (EFieldAccess (EVar "failure") "esfContext") "osFn")) (DoLet false false (PVar "mctx") (EApp (EApp (EVar "mctxAt") (EApp (EApp (EVar "orElseLoc") (EApp (EApp (EApp (EApp (EVar "effectSiteOf") (EVar "outer")) (EVar "fn")) (EFieldAccess (EVar "failure") "esfLabel")) (EApp (EVar "failureBound") (EVar "failure")))) (EFieldAccess (EFieldAccess (EVar "failure") "esfContext") "osLoc"))) (EVar "outer"))) (DoExpr (EMatch (EFieldAccess (EVar "failure") "esfAuthority") (arm (PCon "Some" (PTuple (PVar "lo") (PVar "hi"))) () (EIf (EBinOp "||" (EApp (EApp (EVar "mentionsEscaped") (EVar "mctx")) (EVar "lo")) (EApp (EApp (EVar "mentionsEscaped") (EVar "mctx")) (EVar "hi"))) (ELit LUnit) (EIf (EFieldAccess (EVar "failure") "esfExact") (EApp (EApp (EApp (EApp (EApp (EVar "reportIndexFailure") (EVar "mctx")) (EFieldAccess (EFieldAccess (EVar "failure") "esfContext") "osCovering")) (EFieldAccess (EVar "mctx") "mcLoc")) (EVar "lo")) (EVar "hi")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (ELit (LString "T-AUTHORITY"))) (EFieldAccess (EVar "mctx") "mcLoc")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "authorityFailureMsg") (EVar "mctx")) (EVar "fn")) (EFieldAccess (EVar "failure") "esfLabel")) (EFieldAccess (EVar "failure") "esfResidualOf")) (EVar "lo")) (EVar "hi")) (EFieldAccess (EVar "failure") "esfWrittenUpper")))))) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "rowFailureReportedRef")) (EApp (EApp (EApp (EVar "omInsert") (EVar "fn")) (ELit LUnit)) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "rowFailureReportedRef") "value")))) (DoExpr (EApp (EApp (EVar "reportRowFailure") (EVar "mctx")) (EVar "failure"))))))) (DoExpr (EApp (EApp (EVar "reportEffectSummaryFailures") (EVar "outer")) (EVar "rest")))))
(DTypeSig false "failureBound" (TyFun (TyApp (TyCon "SummaryFailure") (TyCon "ObligationSite")) (TyApp (TyCon "Option") (TyCon "Authority"))))
(DFunDef false "failureBound" ((PVar "failure")) (EMatch (EFieldAccess (EVar "failure") "esfAuthority") (arm (PCon "Some" (PTuple PWild (PVar "hi"))) () (EApp (EVar "Some") (EVar "hi"))) (arm (PCon "None") () (EMatch (EFieldAccess (EVar "failure") "esfLabel") (arm (PCon "Some" (PVar "label")) () (EApp (EApp (EVar "map") (EVar "atomAuth")) (EApp (EApp (EVar "findAtom") (EVar "label")) (EApp (EVar "fst") (EApp (EVar "rowFlat") (EFieldAccess (EVar "failure") "esfUpper")))))) (arm (PCon "None") () (EVar "None"))))))
(DTypeSig false "reportRowFailure" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "SummaryFailure") (TyCon "ObligationSite")) (TyCon "Unit"))))
(DFunDef false "reportRowFailure" ((PVar "mctx") (PVar "failure")) (EBlock (DoLet false false (PTuple (PVar "upper") (PVar "upperCells")) (EApp (EVar "rowFlat") (EFieldAccess (EVar "failure") "esfUpper"))) (DoLet false false (PVar "escaping") (EApp (EApp (EApp (EVar "atomsEscape") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EVar "fst") (EApp (EVar "rowFlat") (EFieldAccess (EVar "failure") "esfLower")))) (EVar "upper"))) (DoExpr (EIf (EFieldAccess (EVar "failure") "esfExact") (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EApp (EVar "ppEachShared") (EApp (EVar "Ref") (EListLit))) (EApp (EVar "Ref") (ELit (LInt 0)))) (EListLit (EApp (EVar "TEff") (EFieldAccess (EVar "failure") "esfLower")) (EApp (EVar "TEff") (EFieldAccess (EVar "failure") "esfUpper"))))) (DoExpr (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-EFFECT-INDEX-MISMATCH"))) (EBinOp "++" (EBinOp "++" (ELit (LString "effect index mismatch: ")) (EApp (EApp (EVar "joinWith") (ELit (LString " vs "))) (EVar "rows"))) (ELit (LString "; an effect row in a type argument is invariant, so write the same row on both sides")))))) (EIf (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "escaping")) (EApp (EVar "isEmptyL") (EVar "upperCells"))) (EApp (EApp (EApp (EVar "effectLeakCheck") (EVar "mctx")) (EVar "escaping")) (EVar "upper")) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-EFFECT-LAUNDER"))) (EApp (EApp (EApp (EVar "effectInclusionMsg") (EFieldAccess (EFieldAccess (EVar "failure") "esfContext") "osFn")) (EVar "escaping")) (EApp (EApp (EApp (EVar "ppEachShared") (EApp (EVar "Ref") (EListLit))) (EApp (EVar "Ref") (ELit (LInt 0)))) (EListLit (EApp (EVar "TEff") (EFieldAccess (EVar "failure") "esfLower")) (EApp (EVar "TEff") (EFieldAccess (EVar "failure") "esfUpper"))))))))) (DoExpr (ELit LUnit))))
(DTypeSig true "borrowedEffectCells" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar")))))))
(DFunDef false "borrowedEffectCells" ((PVar "mctx") (PVar "mono") (PVar "cells")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "input")) (EApp (EApp (EVar "effectCells") (EVar "input")) (EVar "acc")))) (EVar "cells")) (EApp (EApp (EVar "producedInputTypes") (EApp (EVar "producedSlotCovariants") (EVar "mctx"))) (EVar "mono"))))
(DTypeSig true "beginEffectContract" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "EffRow") (TyFun (TyCon "Mono") (TyTuple (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))))
(DFunDef false "beginEffectContract" ((PVar "mctx") (PVar "force") (PVar "value")) (EBlock (DoLet false false (PVar "saved") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "rigidEffvarsRef") "value")) (DoLet false false (PVar "savedAuths") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "rigidAuthvarsRef") "value")) (DoExpr (EApp (EApp (EVar "beginEffectSummaryScope") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "rigidEffvarsRef")) (EApp (EApp (EVar "effectRoots") (EVar "value")) (EApp (EApp (EVar "effectRowRoots") (EVar "force")) (EVar "saved"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "rigidAuthvarsRef")) (EApp (EApp (EVar "authRoots") (EVar "value")) (EApp (EApp (EVar "authRowRoots") (EVar "force")) (EVar "savedAuths"))))) (DoExpr (ETuple (EVar "saved") (EVar "savedAuths")))))
(DTypeSig true "finishEffectContract" (TyFun (TyCon "DynCtx") (TyFun (TyTuple (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))) (TyCon "Unit"))))
(DFunDef false "finishEffectContract" ((PVar "dyn") (PTuple (PVar "saved") (PVar "savedAuths"))) (EBlock (DoExpr (EApp (EApp (EVar "resolvePendingJoins") (EVar "dyn")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "currentLevel") "value"))) (DoExpr (EApp (EApp (EApp (EVar "finishEffectSummaryScope") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "Tip")) (EVar "Tip"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "rigidEffvarsRef")) (EVar "saved"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "rigidAuthvarsRef")) (EVar "savedAuths")))))
(DTypeSig true "checkUndeterminedRetEffVars" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "checkUndeterminedRetEffVars" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "checkUndeterminedRetEffVars" ((PVar "mctx") (PCons (PVar "d") (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EVar "checkUndeterminedRetEffVarsDecl") (EVar "mctx")) (EVar "d"))) (DoExpr (EApp (EApp (EVar "checkUndeterminedRetEffVars") (EVar "mctx")) (EVar "rest")))))
(DTypeSig false "checkUndeterminedRetEffVarsDecl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Decl") (TyCon "Unit"))))
(DFunDef false "checkUndeterminedRetEffVarsDecl" ((PVar "mctx") (PRec "DInterface" ((rf "name" None) (rf "typarams" None) (rf "typaramKinds" None) (rf "methods" None)) true)) (EApp (EApp (EApp (EApp (EVar "checkIfaceMethodEffs") (EVar "mctx")) (EVar "name")) (EApp (EApp (EApp (EApp (EVar "declGradedScope") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "typarams")) (EVar "typaramKinds")) (EVar "methods"))) (EVar "methods")))
(DFunDef false "checkUndeterminedRetEffVarsDecl" ((PVar "mctx") (PCon "DTypeSig" PWild (PVar "n") (PVar "t") PWild)) (EApp (EApp (EApp (EApp (EApp (EVar "checkArgEffVarCoverage") (EVar "mctx")) (EVar "None")) (EListLit)) (EVar "n")) (EVar "t")))
(DFunDef false "checkUndeterminedRetEffVarsDecl" ((PVar "mctx") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "checkUndeterminedRetEffVarsDecl") (EVar "mctx")) (EVar "d")))
(DFunDef false "checkUndeterminedRetEffVarsDecl" ((PVar "mctx") PWild) (ELit LUnit))
(DTypeSig false "checkIfaceMethodEffs" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyCon "Unit"))))))
(DFunDef false "checkIfaceMethodEffs" ((PVar "mctx") PWild PWild (PList)) (ELit LUnit))
(DFunDef false "checkIfaceMethodEffs" ((PVar "mctx") (PVar "iface") (PVar "scope") (PCons (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild PWild) (PVar "rest"))) (EBlock (DoExpr (EMatch (EApp (EApp (EApp (EVar "undeterminedRetEffVars") (EVar "mctx")) (EVar "scope")) (EVar "mty")) (arm (PList) () (ELit LUnit)) (arm (PVar "bad") () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-EFFECT-UNDETERMINED"))) (EApp (EVar "firstTyLoc") (EVar "mty"))) (EApp (EApp (EApp (EVar "effectUndeterminedMsg") (EVar "iface")) (EVar "mname")) (EVar "bad")))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "checkArgEffVarCoverage") (EVar "mctx")) (EApp (EVar "Some") (EVar "iface"))) (EVar "scope")) (EVar "mname")) (EVar "mty"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkIfaceMethodEffs") (EVar "mctx")) (EVar "iface")) (EVar "scope")) (EVar "rest")))))
(DTypeSig false "checkArgEffVarCoverage" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyCon "Unit")))))))
(DFunDef false "checkArgEffVarCoverage" ((PVar "mctx") (PVar "iface") (PVar "scope") (PVar "mname") (PVar "mty")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkArgEffVars") (EVar "mctx")) (EVar "iface")) (EVar "mname")) (EVar "mty")) (EApp (EApp (EApp (EVar "methodEffArgOccs") (EVar "mctx")) (EVar "scope")) (EVar "mty"))) (EApp (EApp (EApp (EVar "methodEffRetOccs") (EVar "mctx")) (EVar "scope")) (EVar "mty"))) (EApp (EVar "dedup") (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EApp (EVar "methodEffArgOccs") (EVar "mctx")) (EVar "scope")) (EVar "mty"))))))
(DTypeSig false "checkArgEffVars" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit")))))))))
(DFunDef false "checkArgEffVars" ((PVar "mctx") PWild PWild PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "checkArgEffVars" ((PVar "mctx") (PVar "iface") (PVar "mname") (PVar "mty") (PVar "argOccs") (PVar "retOccs") (PCons (PVar "v") (PVar "rest"))) (EBlock (DoLet false false (PVar "vrets") (EApp (EApp (EVar "filterList") (ELam ((PVar "o")) (EBinOp "==" (EApp (EVar "fst") (EVar "o")) (EVar "v")))) (EVar "retOccs"))) (DoLet false false (PVar "vatoms") (EApp (EApp (EVar "flatMap") (EVar "snd")) (EApp (EApp (EVar "filterList") (ELam ((PVar "o")) (EBinOp "==" (EApp (EVar "fst") (EVar "o")) (EVar "v")))) (EVar "argOccs")))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "vrets")) (EMatch (EVar "iface") (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-EFFECT-ARG-UNCOVERED"))) (EApp (EVar "firstTyLoc") (EVar "mty"))) (EApp (EApp (EApp (EVar "argOnlyEffVarMsg") (EVar "i")) (EVar "mname")) (EVar "v")))) (arm (PCon "None") () (ELit LUnit))) (EMatch (EApp (EApp (EApp (EVar "retOccsEscape") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "vatoms")) (EVar "vrets")) (arm (PList) () (ELit LUnit)) (arm (PVar "esc") () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-EFFECT-ARG-UNCOVERED"))) (EApp (EVar "firstTyLoc") (EVar "mty"))) (EApp (EApp (EApp (EApp (EVar "argAtomsMsgFor") (EVar "iface")) (EVar "mname")) (EVar "v")) (EVar "esc"))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkArgEffVars") (EVar "mctx")) (EVar "iface")) (EVar "mname")) (EVar "mty")) (EVar "argOccs")) (EVar "retOccs")) (EVar "rest")))))
(DTypeSig false "retOccsEscape" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))) (TyApp (TyCon "List") (TyCon "Atom"))))))
(DFunDef false "retOccsEscape" ((PVar "gctx") PWild (PList)) (EListLit))
(DFunDef false "retOccsEscape" ((PVar "gctx") (PVar "vatoms") (PCons (PTuple PWild (PVar "declAtoms")) (PVar "rest"))) (EIf (EApp (EVar "isNonEmptyL") (EApp (EApp (EApp (EVar "atomsEscape") (EVar "gctx")) (EVar "vatoms")) (EVar "declAtoms"))) (EApp (EApp (EApp (EVar "atomsEscape") (EVar "gctx")) (EVar "vatoms")) (EVar "declAtoms")) (EApp (EApp (EApp (EVar "retOccsEscape") (EVar "gctx")) (EVar "vatoms")) (EVar "rest"))))
(DTypeSig false "methodEffArgOccs" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom"))))))))
(DFunDef false "methodEffArgOccs" ((PVar "mctx") (PVar "scope") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EApp (EVar "methodEffArgOccs") (EVar "mctx")) (EVar "scope")) (EVar "t")))
(DFunDef false "methodEffArgOccs" ((PVar "mctx") (PVar "scope") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EApp (EVar "methodEffArgOccs") (EVar "mctx")) (EVar "scope")) (EVar "t")))
(DFunDef false "methodEffArgOccs" ((PVar "mctx") (PVar "scope") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "argPerformableOccs") (EVar "mctx")) (EVar "scope")) (EVar "True")) (EVar "a")) (EApp (EApp (EApp (EVar "methodEffArgOccs") (EVar "mctx")) (EVar "scope")) (EVar "b"))))
(DFunDef false "methodEffArgOccs" ((PVar "mctx") PWild PWild) (EListLit))
(DTypeSig false "occsOfTails" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom"))))))))
(DFunDef false "occsOfTails" ((PVar "gctx") (PVar "tails") (PVar "labels")) (EBlock (DoLet false false (PVar "atoms") (EApp (EApp (EVar "atomsOfWritten") (EVar "gctx")) (EVar "labels"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EVar "atoms")))) (EVar "tails")))))
(DTypeSig false "argPerformableOccs" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "Bool") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))))))))
(DFunDef false "argPerformableOccs" ((PVar "mctx") (PVar "scope") (PVar "perf") (PCon "TyEffect" (PVar "labels") (PVar "tails") (PVar "t"))) (EBinOp "++" (EIf (EVar "perf") (EApp (EApp (EApp (EVar "occsOfTails") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "tails")) (EVar "labels")) (EListLit)) (EApp (EApp (EApp (EApp (EVar "argPerformableOccs") (EVar "mctx")) (EVar "scope")) (EVar "perf")) (EVar "t"))))
(DFunDef false "argPerformableOccs" ((PVar "mctx") PWild (PVar "perf") (PCon "TyRow" (PVar "labels") (PVar "tails") PWild)) (EIf (EVar "perf") (EApp (EApp (EApp (EVar "occsOfTails") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "tails")) (EVar "labels")) (EListLit)))
(DFunDef false "argPerformableOccs" ((PVar "mctx") (PVar "scope") (PVar "perf") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "argPerformableOccs") (EVar "mctx")) (EVar "scope")) (EApp (EVar "not") (EVar "perf"))) (EVar "a")) (EApp (EApp (EApp (EApp (EVar "argPerformableOccs") (EVar "mctx")) (EVar "scope")) (EVar "perf")) (EVar "b"))))
(DFunDef false "argPerformableOccs" ((PVar "mctx") (PVar "scope") (PVar "perf") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "argPerformableOccs") (EVar "mctx")) (EVar "scope")) (EVar "perf"))) (EVar "ts")))
(DFunDef false "argPerformableOccs" ((PVar "mctx") (PVar "scope") (PVar "perf") (PCon "TyApp" (PVar "a") (PVar "b"))) (EMatch (EApp (EVar "tyAppSpine") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b"))) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false) (PVar "args")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "krowSlotOccs") (EVar "mctx")) (EVar "scope")) (EVar "perf")) (EVar "o")) (EVar "n")) (EVar "args"))) (arm (PTuple (PCon "TyVar" (PVar "h")) (PVar "args")) () (EApp (EApp (EApp (EApp (EApp (EVar "krowSlotVarOccs") (EVar "mctx")) (EVar "scope")) (EVar "perf")) (EVar "h")) (EVar "args"))) (arm PWild () (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "argPerformableOccs") (EVar "mctx")) (EVar "scope")) (EVar "perf")) (EVar "a")) (EApp (EApp (EApp (EApp (EVar "argPerformableOccs") (EVar "mctx")) (EVar "scope")) (EVar "perf")) (EVar "b"))))))
(DFunDef false "argPerformableOccs" ((PVar "mctx") (PVar "scope") (PVar "perf") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EApp (EApp (EVar "argPerformableOccs") (EVar "mctx")) (EVar "scope")) (EVar "perf")) (EVar "t")))
(DFunDef false "argPerformableOccs" ((PVar "mctx") PWild PWild PWild) (EListLit))
(DTypeSig false "krowSlotOccs" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "Bool") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))))))))))
(DFunDef false "krowSlotOccs" ((PVar "mctx") (PVar "scope") (PVar "perf") (PVar "o") (PVar "n") (PVar "args")) (EMatch (EApp (EApp (EVar "lookupTab") (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamKindsRef") "value")) (arm (PCon "Some" (PVar "kinds")) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EVar "kinds")) (EApp (EVar "listLen") (EVar "args"))))) (EBinOp "++" (EIf (EVar "perf") (EApp (EApp (EApp (EApp (EVar "krowArgVarAtoms") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "kinds")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "paramRowAtomsOf") (EVar "mctx")) (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n"))))) (EVar "args")) (EListLit)) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "argPerformableOccs") (EVar "mctx")) (EVar "scope")) (EVar "perf"))) (EVar "args")))) (arm PWild () (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "argPerformableOccs") (EVar "mctx")) (EVar "scope")) (EVar "perf"))) (EVar "args")))))
(DTypeSig false "krowSlotVarOccs" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom"))))))))))
(DFunDef false "krowSlotVarOccs" ((PVar "mctx") (PVar "scope") (PVar "perf") (PVar "h") (PVar "args")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "h")) (EVar "scope")) (arm (PCon "Some" (PVar "kinds")) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EVar "kinds")) (EApp (EVar "listLen") (EVar "args"))))) (EBinOp "++" (EIf (EVar "perf") (EApp (EApp (EApp (EApp (EVar "krowArgVarAtoms") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "kinds")) (EListLit)) (EVar "args")) (EListLit)) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "argPerformableOccs") (EVar "mctx")) (EVar "scope")) (EVar "perf"))) (EVar "args")))) (arm PWild () (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "argPerformableOccs") (EVar "mctx")) (EVar "scope")) (EVar "perf"))) (EVar "args")))))
(DTypeSig false "methodEffRetOccs" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom"))))))))
(DFunDef false "methodEffRetOccs" ((PVar "mctx") (PVar "scope") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EApp (EVar "methodEffRetOccs") (EVar "mctx")) (EVar "scope")) (EVar "t")))
(DFunDef false "methodEffRetOccs" ((PVar "mctx") (PVar "scope") (PCon "TyEffect" (PVar "labels") (PVar "tails") (PVar "t"))) (EBinOp "++" (EApp (EApp (EApp (EVar "occsOfTails") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "tails")) (EVar "labels")) (EApp (EApp (EApp (EVar "methodEffRetOccs") (EVar "mctx")) (EVar "scope")) (EVar "t"))))
(DFunDef false "methodEffRetOccs" ((PVar "mctx") (PVar "scope") (PCon "TyFun" PWild (PVar "b"))) (EApp (EApp (EApp (EVar "methodEffRetOccs") (EVar "mctx")) (EVar "scope")) (EVar "b")))
(DFunDef false "methodEffRetOccs" ((PVar "mctx") (PVar "scope") (PVar "t")) (EBlock (DoLet false false (PVar "occs") (EApp (EApp (EVar "effVarOccAtoms") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "t"))) (DoExpr (EBinOp "++" (EVar "occs") (EApp (EApp (EVar "filterList") (ELam ((PVar "o2")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "o")) (EBinOp "==" (EApp (EVar "fst") (EVar "o")) (EApp (EVar "fst") (EVar "o2"))))) (EVar "occs"))))) (EApp (EApp (EApp (EVar "rowArgAtomsIn") (EVar "mctx")) (EVar "scope")) (EVar "t")))))))
(DTypeSig false "undeterminedRetEffVars" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "undeterminedRetEffVars" ((PVar "mctx") (PVar "scope") (PVar "sig")) (EBlock (DoLet false false (PVar "args") (EApp (EVar "methodArgs") (EVar "sig"))) (DoLet false false (PVar "argCarried") (EApp (EVar "dedup") (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "effTailNames")) (EVar "args")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "rowArgNamesIn") (EVar "mctx")) (EVar "scope"))) (EVar "args"))))) (DoLet false false (PVar "retTail") (EApp (EVar "dedup") (EApp (EVar "effTailNames") (EApp (EVar "methodRet") (EVar "sig"))))) (DoExpr (EApp (EApp (EVar "removeAllS") (EVar "argCarried")) (EVar "retTail")))))
(DTypeSig false "methodRet" (TyFun (TyCon "Ty") (TyCon "Ty")))
(DFunDef false "methodRet" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "methodRet") (EVar "t")))
(DFunDef false "methodRet" ((PCon "TyFun" PWild (PVar "b"))) (EApp (EVar "methodRet") (EVar "b")))
(DFunDef false "methodRet" ((PVar "t")) (EVar "t"))
(DTypeSig false "expandReturnSpine" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyCon "Ty"))))
(DFunDef false "expandReturnSpine" ((PVar "mctx") (PVar "ty")) (EMatch (EApp (EApp (EVar "expandAliasHeadTy") (EVar "mctx")) (EVar "ty")) (arm (PCon "TyFun" (PVar "a") (PVar "ret")) () (EApp (EApp (EVar "TyFun") (EVar "a")) (EApp (EApp (EVar "expandReturnSpine") (EVar "mctx")) (EVar "ret")))) (arm (PCon "TyConstrained" (PVar "cs") (PVar "t")) () (EApp (EApp (EVar "TyConstrained") (EVar "cs")) (EApp (EApp (EVar "expandReturnSpine") (EVar "mctx")) (EVar "t")))) (arm (PAs "row" (PCon "TyEffect" PWild PWild PWild)) () (EVar "row")) (arm PWild () (EVar "ty"))))
(DTypeSig false "declaredEffects" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "declaredEffects" ((PVar "gctx") (PCon "TyFun" PWild (PVar "ret"))) (EApp (EApp (EVar "declaredEffects") (EVar "gctx")) (EVar "ret")))
(DFunDef false "declaredEffects" ((PVar "gctx") (PCon "TyEffect" (PVar "effs") PWild PWild)) (EApp (EApp (EVar "atomsOfWritten") (EVar "gctx")) (EVar "effs")))
(DFunDef false "declaredEffects" ((PVar "gctx") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EVar "declaredEffects") (EVar "gctx")) (EVar "t")))
(DFunDef false "declaredEffects" ((PVar "gctx") PWild) (EListLit))
(DTypeSig false "declaredEffectTail" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declaredEffectTail" ((PCon "TyFun" PWild (PVar "ret"))) (EApp (EVar "declaredEffectTail") (EVar "ret")))
(DFunDef false "declaredEffectTail" ((PCon "TyEffect" PWild (PVar "tail") PWild)) (EVar "tail"))
(DFunDef false "declaredEffectTail" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "declaredEffectTail") (EVar "t")))
(DFunDef false "declaredEffectTail" (PWild) (EListLit))
(DTypeSig false "declaredArgEffNames" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "declaredArgEffNames" ((PVar "mctx") (PCon "TyFun" (PVar "a") (PVar "ret"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "effTailNames") (EVar "a")) (EApp (EApp (EVar "rowArgNames") (EVar "mctx")) (EVar "a"))) (EApp (EApp (EVar "declaredArgEffNames") (EVar "mctx")) (EVar "ret"))))
(DFunDef false "declaredArgEffNames" ((PVar "mctx") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EVar "declaredArgEffNames") (EVar "mctx")) (EVar "t")))
(DFunDef false "declaredArgEffNames" ((PVar "mctx") PWild) (EListLit))
(DTypeSig false "declaredEffectsOpen" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyCon "Bool"))))
(DFunDef false "declaredEffectsOpen" ((PVar "mctx") (PVar "ty")) (EBlock (DoLet false false (PVar "argNames") (EApp (EApp (EVar "declaredArgEffNames") (EVar "mctx")) (EVar "ty"))) (DoExpr (EApp (EApp (EVar "anyList") (ELam ((PVar "v")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "v")) (EVar "argNames"))))) (EApp (EVar "declaredEffectTail") (EVar "ty"))))))
(DTypeSig true "evOrdinal" (TyFun (TyCon "EvId") (TyCon "Int")))
(DFunDef false "evOrdinal" ((PCon "EvId" PWild (PVar "i"))) (EVar "i"))
(DTypeSig false "mentionsEscaped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Authority") (TyCon "Bool"))))
(DFunDef false "mentionsEscaped" ((PVar "mctx") (PVar "q")) (EApp (EApp (EVar "anyList") (ELam ((PVar "cell")) (EApp (EApp (EVar "IdMap.has") (EApp (EVar "authvarId") (EVar "cell"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "escapedExistentialsRef") "value")))) (EApp (EVar "authVars") (EVar "q"))))
(DTypeSig true "registerLocalAbsIf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "ScopeId")) (TyFun (TyCon "Scheme") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Unit"))))))))
(DFunDef false "registerLocalAbsIf" ((PVar "mctx") (PVar "name") (PVar "lscope") (PVar "sch") (PVar "oblN0") (PVar "callN0")) (EBlock (DoExpr (EApp (EApp (EVar "recordLocalQuantified") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "sch"))) (DoExpr (EMatch (EVar "lscope") (arm (PCon "Some" (PVar "scope")) () (EBlock (DoExpr (EApp (EApp (EApp (EVar "registerLocalGrants") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "name")) (EVar "sch"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerLocalAbs") (EVar "mctx")) (EVar "name")) (EVar "scope")) (EVar "sch")) (EVar "oblN0")) (EVar "callN0"))))) (arm (PCon "None") () (ELit LUnit))))))
(DTypeSig false "recordLocalQuantified" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Scheme") (TyCon "Unit"))))
(DFunDef false "recordLocalQuantified" ((PVar "gctx") (PVar "sch")) (EMatch (EApp (EVar "schemeIds") (EVar "sch")) (arm (PList) () (ELit LUnit)) (arm (PVar "ids") () (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "localAbs")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "lasQuantified")) (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (EVar "intToString")) (EVar "ids"))) (EFieldAccess (EFieldAccess (EVar "st") "lasQuantified") "value"))))))))
(DTypeSig true "fileGrantExterns" (TyApp (TyCon "OrdMap") (TyTuple (TyCon "Int") (TyCon "Int"))))
(DFunDef false "fileGrantExterns" () (EVar "RuntimeGrants.fileGrantExterns"))
(DTypeSig false "grantsEnabled" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyCon "Bool"))))
(DFunDef false "grantsEnabled" ((PVar "gctx") PWild) (EApp (EVar "isSome") (EFieldAccess (EFieldAccess (EVar "gctx") "markSetsRef") "value")))
(DTypeSig false "grantCalleeOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "GrantCallee"))))
(DFunDef false "grantCalleeOf" ((PVar "mctx") (PVar "name")) (EIf (EApp (EVar "isLocalAbsName") (EVar "name")) (EVar "SourceCallee") (EIf (EVar "otherwise") (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "markingRef") "value") (arm (PCon "Some" (PVar "mm")) () (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "mm") "mmExterns")) (EApp (EVar "externCallee") (EVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "mm") "mmUserNames")) (EVar "SourceCallee") (EApp (EApp (EVar "catalogCallee") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "name"))))) (arm (PCon "None") () (EApp (EApp (EVar "catalogCallee") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "name")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "catalogCallee" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyCon "GrantCallee"))))
(DFunDef false "catalogCallee" ((PVar "gctx") (PVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EFieldAccess (EVar "gctx") "builtinExternNamesRef") "value")) (EApp (EVar "externCallee") (EVar "name")) (EVar "SourceCallee")))
(DTypeSig false "externCallee" (TyFun (TyCon "String") (TyCon "GrantCallee")))
(DFunDef false "externCallee" ((PVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "fileGrantExterns")) (EVar "FileExternCallee") (EVar "NoGrantCallee")))
(DTypeSig true "grantNameIn" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "grantNameIn" ((PVar "env") (PVar "n")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "grantsEnabled") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (EVar "False") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "lookupBinding") (EVar "env")) (EVar "n")) (arm (PCon "Some" (PVar "b")) () (EMatch (EFieldAccess (EVar "b") "ebMethodRow") (arm (PCon "Some" PWild) () (EVar "False")) (arm (PCon "None") () (EBinOp "&&" (EApp (EVar "calleeTakesGrants") (EApp (EApp (EVar "grantCalleeOf") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "n"))) (EApp (EVar "isNonEmptyL") (EApp (EVar "schemeAuthIds") (EFieldAccess (EFieldAccess (EVar "b") "ebValue") "vsScheme"))))))) (arm (PCon "None") () (EVar "False"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "calleeTakesGrants" (TyFun (TyCon "GrantCallee") (TyCon "Bool")))
(DFunDef false "calleeTakesGrants" ((PCon "SourceCallee")) (EVar "True"))
(DFunDef false "calleeTakesGrants" ((PCon "FileExternCallee")) (EVar "True"))
(DFunDef false "calleeTakesGrants" ((PCon "NoGrantCallee")) (EVar "False"))
(DTypeSig true "grantOrder" (TyFun (TyCon "Scheme") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "grantOrder" ((PCon "Forall" PWild PWild (PList) PWild PWild PWild)) (EListLit))
(DFunDef false "grantOrder" ((PCon "Forall" PWild PWild (PVar "avars") PWild (PVar "force") (PVar "body"))) (EBlock (DoLet false false (PVar "seen") (EApp (EVar "reverseL") (EApp (EApp (EVar "authOrderRow") (EVar "force")) (EApp (EApp (EVar "authOrderIn") (EVar "body")) (EListLit))))) (DoLet false false (PVar "quantified") (EApp (EApp (EVar "filterList") (ELam ((PVar "i")) (EApp (EApp (EVar "containsI") (EVar "i")) (EVar "avars")))) (EVar "seen"))) (DoExpr (EBinOp "++" (EVar "quantified") (EApp (EApp (EVar "filterList") (ELam ((PVar "i")) (EApp (EVar "not") (EApp (EApp (EVar "containsI") (EVar "i")) (EVar "quantified"))))) (EVar "avars"))))))
(DTypeSig true "grantOccOf" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvId") (TyApp (TyCon "Option") (TyCon "GrantOcc")))))
(DFunDef false "grantOccOf" ((PVar "gctx") (PVar "ev")) (EApp (EApp (EVar "IdMap.get") (EApp (EVar "evOrdinal") (EVar "ev"))) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants") "gsOccs") "value")))
(DTypeSig false "setGrantOcc" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvId") (TyFun (TyCon "GrantOcc") (TyCon "Unit")))))
(DFunDef false "setGrantOcc" ((PVar "gctx") (PVar "ev") (PVar "occ")) (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsOccs")) (EApp (EApp (EApp (EVar "IdMap.set") (EApp (EVar "evOrdinal") (EVar "ev"))) (EVar "occ")) (EFieldAccess (EFieldAccess (EVar "st") "gsOccs") "value"))))))
(DTypeSig true "grantOnlyBindingId" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "grantOnlyBindingId" ((PVar "mctx") (PVar "name")) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "markingRef") "value") (arm (PCon "Some" (PVar "mm")) () (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "mm") "mmTop")))) (arm (PCon "None") () (ELit (LInt 0)))))
(DTypeSig true "recordGrantOcc" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyFun (TyCon "Scheme") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))) (TyCon "Unit")))))))
(DFunDef false "recordGrantOcc" ((PVar "mctx") (PVar "name") (PVar "ev") (PAs "scheme" (PCon "Forall" PWild PWild PWild PWild PWild (PVar "body"))) (PVar "subst")) (EMatch (EApp (EApp (EVar "grantCalleeOf") (EVar "mctx")) (EVar "name")) (arm (PCon "NoGrantCallee") () (ELit LUnit)) (arm (PCon "SourceCallee") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordOccWith") (EVar "mctx")) (EVar "name")) (EVar "ev")) (EVar "scheme")) (EVar "subst")) (EVar "None")) (EVar "False"))) (arm (PCon "FileExternCallee") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordOccWith") (EVar "mctx")) (EVar "name")) (EVar "ev")) (EVar "scheme")) (EVar "subst")) (EApp (EVar "Some") (EApp (EVar "arrowArity") (EVar "body")))) (EVar "False")))))
(DTypeSig true "recordMethodGrantOcc" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyFun (TyCon "Scheme") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))) (TyCon "Unit")))))))
(DFunDef false "recordMethodGrantOcc" ((PVar "mctx") (PVar "name") (PVar "ev") (PAs "scheme" (PCon "Forall" PWild PWild PWild PWild PWild (PVar "body"))) (PVar "subst")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordOccWith") (EVar "mctx")) (EVar "name")) (EVar "ev")) (EVar "scheme")) (EVar "subst")) (EApp (EVar "Some") (EApp (EVar "arrowArity") (EVar "body")))) (EVar "False")))
(DTypeSig true "recordStandaloneGrantOcc" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyFun (TyCon "Scheme") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))) (TyFun (TyCon "Int") (TyCon "Unit"))))))))
(DFunDef false "recordStandaloneGrantOcc" ((PVar "mctx") (PVar "name") (PVar "ev") (PVar "scheme") (PVar "subst") (PVar "arity")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordOccWith") (EVar "mctx")) (EVar "name")) (EVar "ev")) (EVar "scheme")) (EVar "subst")) (EApp (EVar "Some") (EVar "arity"))) (EVar "True")))
(DTypeSig false "recordOccWith" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyFun (TyCon "Scheme") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "Bool") (TyCon "Unit")))))))))
(DFunDef false "recordOccWith" ((PVar "mctx") (PVar "name") (PVar "ev") (PVar "scheme") (PVar "subst") (PVar "trailing") (PVar "standalone")) (EMatch (EApp (EVar "grantOrder") (EVar "scheme")) (arm (PList) () (ELit LUnit)) (arm (PVar "ids") () (EApp (EApp (EApp (EVar "setGrantOcc") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ev")) (ERecordCreate "GrantOcc" ((fa "goCallee" (EVar "name")) (fa "goCells" (EApp (EApp (EVar "map") (ELam ((PVar "i")) (EApp (EApp (EVar "optionOr") (EApp (EVar "AJoin") (EListLit))) (EApp (EApp (EVar "lookupAssocI") (EVar "i")) (EVar "subst"))))) (EVar "ids"))) (fa "goRecIds" (EListLit)) (fa "goTrailing" (EVar "trailing")) (fa "goChain" (EApp (EApp (EVar "grantChainAt") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit)))) (fa "goStandalone" (EVar "standalone"))))))))
(DTypeSig true "spineHeadEv" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "EvId"))))
(DFunDef false "spineHeadEv" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "spineHeadEv") (EVar "e")))
(DFunDef false "spineHeadEv" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "spineHeadEv") (EVar "f")))
(DFunDef false "spineHeadEv" ((PCon "EMethodAt" PWild PWild (PVar "ev"))) (EApp (EVar "Some") (EVar "ev")))
(DFunDef false "spineHeadEv" (PWild) (EVar "None"))
(DTypeSig true "recordStandaloneAt" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "SelectedValueOccurrence") (TyCon "Unit"))))))
(DFunDef false "recordStandaloneAt" ((PVar "mctx") (PVar "name") (PVar "hd") (PVar "occurrence")) (EMatch (EApp (EVar "spineHeadEv") (EVar "hd")) (arm (PCon "Some" (PVar "ev")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordStandaloneGrantOcc") (EVar "mctx")) (EVar "name")) (EVar "ev")) (EFieldAccess (EVar "occurrence") "svoScheme")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "occurrence") "svoInstance") "mtiSubstitution") "misAuthSubst")) (EApp (EVar "funArity") (EFieldAccess (EFieldAccess (EVar "occurrence") "svoInstance") "mtiBody")))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig true "methodGrantOf" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "MethodGrant"))))))
(DFunDef false "methodGrantOf" ((PVar "gctx") (PVar "ifaceWord") (PVar "method")) (EApp (EApp (EVar "omLookup") (EApp (EApp (EVar "methodGrantKey") (EVar "ifaceWord")) (EVar "method"))) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants") "gsMethods") "value")))
(DTypeSig true "recordMethodGrants" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "MethodSchemeRow")) (TyCon "Unit"))))
(DFunDef false "recordMethodGrants" ((PVar "gctx") (PVar "rows")) (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsMethods")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "row")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "methodGrantKey") (EApp (EApp (EVar "ifaceWordOf") (EFieldAccess (EFieldAccess (EVar "row") "msrIface") "irOrigin")) (EFieldAccess (EFieldAccess (EVar "row") "msrIface") "irName"))) (EFieldAccess (EVar "row") "msrName"))) (DoExpr (EMatch (EApp (EVar "methodGrantOfRow") (EVar "row")) (arm (PCon "Some" (PVar "mg")) () (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "mg")) (EVar "acc"))) (arm (PCon "None") () (EApp (EApp (EVar "omDelete") (EVar "key")) (EVar "acc")))))))) (EFieldAccess (EFieldAccess (EVar "st") "gsMethods") "value")) (EVar "rows"))))))
(DTypeSig false "methodGrantOfRow" (TyFun (TyCon "MethodSchemeRow") (TyApp (TyCon "Option") (TyCon "MethodGrant"))))
(DFunDef false "methodGrantOfRow" ((PVar "row")) (EMatch (EFieldAccess (EVar "row") "msrScheme") (arm (PCon "Forall" PWild PWild PWild PWild (PVar "force") (PVar "body")) () (EMatch (EApp (EVar "grantOrder") (EFieldAccess (EVar "row") "msrScheme")) (arm (PList) () (EVar "None")) (arm (PVar "ids") () (EBlock (DoLet false false (PVar "cells") (EApp (EApp (EVar "authCellsIn") (EVar "body")) (EApp (EApp (EVar "authRowCells") (EVar "force")) (EVar "Tip")))) (DoExpr (EApp (EVar "Some") (ERecordCreate "MethodGrant" ((fa "mgArity" (EApp (EVar "tyArrowCount") (EFieldAccess (EVar "row") "msrType"))) (fa "mgNames" (EApp (EApp (EVar "map") (ELam ((PVar "i")) (EMatch (EApp (EApp (EVar "IdMap.get") (EVar "i")) (EVar "cells")) (arm (PCon "Some" (PVar "cell")) () (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EVar "authvarName") (EVar "cell")))) (arm (PCon "None") () (ELit (LString "")))))) (EVar "ids")))))))))))))
(DTypeSig true "markSourceless" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Unit"))))
(DFunDef false "markSourceless" ((PVar "gctx") (PVar "ids")) (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsSourceless")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PVar "i")) (EApp (EApp (EApp (EVar "IdMap.set") (EVar "i")) (ELit LUnit)) (EVar "m")))) (EFieldAccess (EFieldAccess (EVar "st") "gsSourceless") "value")) (EVar "ids"))))))
(DTypeSig false "grantChainAt" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ScopeId") (TyApp (TyCon "List") (TyCon "GrantBinder")))))
(DFunDef false "grantChainAt" ((PVar "gctx") (PAs "sid" (PCon "ScopeId" (PVar "i")))) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EVar "Scopes.scopeFrame") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))) (EVar "sid"))) (DoLet false false (PVar "outer") (EMatch (EFieldAccess (EVar "frame") "sfParent") (arm (PCon "Some" (PVar "parent")) () (EApp (EApp (EVar "grantChainAt") (EVar "gctx")) (EVar "parent"))) (arm (PCon "None") () (EListLit)))) (DoLet false false (PVar "own") (EMatch (EFieldAccess (EVar "frame") "sfOwner") (arm (PCon "BindingOwner" (PVar "n")) () (EBinOp "::" (EApp (EApp (EVar "TopGrantBinder") (EFieldAccess (EVar "frame") "sfModuleId")) (EVar "n")) (EVar "outer"))) (arm (PCon "LocalBindingOwner" (PVar "n")) () (EBinOp "::" (EApp (EVar "LocalGrantBinder") (EVar "n")) (EVar "outer"))) (arm PWild () (EVar "outer")))) (DoExpr (EMatch (EApp (EApp (EVar "IdMap.get") (EVar "i")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants") "gsBodies") "value")) (arm (PCon "Some" (PVar "body")) () (EBinOp "::" (EVar "body") (EVar "own"))) (arm (PCon "None") () (EVar "own"))))))
(DTypeSig true "recordTopGrants" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyCon "Unit"))))))
(DFunDef false "recordTopGrants" ((PVar "gctx") (PVar "mid") (PVar "schemes") (PVar "grouped")) (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (DoLet false false (PVar "enabled") (EApp (EApp (EVar "grantsEnabled") (EVar "gctx")) (ELit LUnit))) (DoLet false false (PVar "granted") (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "n") (PVar "sch"))) (ETuple (EVar "n") (EIf (EVar "enabled") (EApp (EVar "grantOrder") (EVar "sch")) (EListLit))))) (EVar "schemes"))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PVar "e")) (EApp (EApp (EVar "setGrantIds") (EFieldAccess (EVar "st") "gsTopIds")) (ETuple (EApp (EApp (EVar "grantTopKey") (EVar "mid")) (EApp (EVar "fst") (EVar "e"))) (EApp (EVar "snd") (EVar "e")))))) (EVar "granted"))) (DoLet false false (PVar "taking") (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EVar "isNonEmptyL") (EApp (EVar "snd") (EVar "e"))))) (EVar "granted"))) (DoExpr (EMatch (EVar "taking") (arm (PList) () (ELit LUnit)) (arm PWild () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsTakers")) (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "taking"))) (EFieldAccess (EFieldAccess (EVar "st") "gsTakers") "value")))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PTuple (PVar "m") PWild)) (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "clause")) (EApp (EApp (EApp (EApp (EApp (EVar "recordRecursiveGrants") (EVar "gctx")) (EVar "mid")) (EVar "m")) (EVar "taking")) (EApp (EVar "snd") (EVar "clause"))))) (ELit LUnit)) (EApp (EApp (EVar "clausesOf") (EVar "m")) (EVar "grouped"))))) (ELit LUnit)) (EVar "schemes")))))))))
(DTypeSig false "recordRecursiveGrants" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyCon "Expr") (TyCon "Unit")))))))
(DFunDef false "recordRecursiveGrants" ((PVar "gctx") (PVar "mid") (PVar "m") (PVar "taking") (PVar "body")) (EBlock (DoLet false false (PVar "visit") (ELam ((PVar "e")) (EMatch (EVar "e") (arm (PCon "EDictAt" (PVar "n") (PVar "ev")) () (EMatch (ETuple (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "taking")) (EApp (EApp (EVar "grantOccOf") (EVar "gctx")) (EVar "ev"))) (arm (PTuple (PCon "Some" (PVar "ids")) (PCon "None")) () (EBlock (DoExpr (EApp (EApp (EApp (EVar "setGrantOcc") (EVar "gctx")) (EVar "ev")) (ERecordCreate "GrantOcc" ((fa "goCallee" (EVar "n")) (fa "goCells" (EListLit)) (fa "goRecIds" (EVar "ids")) (fa "goTrailing" (EVar "None")) (fa "goChain" (EListLit (EApp (EApp (EVar "TopGrantBinder") (EVar "mid")) (EVar "m")))) (fa "goStandalone" (EVar "False")))))) (DoExpr (EVar "e")))) (arm PWild () (EVar "e")))) (arm PWild () (EVar "e"))))) (DoLet false false PWild (EApp (EApp (EVar "mapExpr") (EVar "visit")) (EVar "body"))) (DoExpr (ELit LUnit))))
(DTypeSig false "registerLocalGrants" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "Scheme") (TyCon "Unit")))))
(DFunDef false "registerLocalGrants" ((PVar "gctx") (PVar "name") (PVar "sch")) (EMatch (EApp (EVar "grantOrder") (EVar "sch")) (arm (PList) () (ELit LUnit)) (arm (PVar "ids") () (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsLocalIds")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EVar "ids")) (EFieldAccess (EFieldAccess (EVar "st") "gsLocalIds") "value")))) (DoLet false false (PVar "recOccs") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "localAbs") "lasRecOccs") "value")))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "occ")) (EApp (EApp (EApp (EVar "setGrantOcc") (EVar "gctx")) (EApp (EVar "fst") (EVar "occ"))) (ERecordCreate "GrantOcc" ((fa "goCallee" (EVar "name")) (fa "goCells" (EListLit)) (fa "goRecIds" (EVar "ids")) (fa "goTrailing" (EVar "None")) (fa "goChain" (EApp (EApp (EVar "grantChainAt") (EVar "gctx")) (EApp (EVar "snd") (EVar "occ")))) (fa "goStandalone" (EVar "False"))))))) (ELit LUnit)) (EVar "recOccs")))))))
(DTypeSig true "appSpineArgCount" (TyFun (TyCon "Expr") (TyCon "Int")))
(DFunDef false "appSpineArgCount" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "appSpineArgCount") (EVar "e")))
(DFunDef false "appSpineArgCount" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "appSpineArgCount") (EVar "e")))
(DFunDef false "appSpineArgCount" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "appSpineArgCount") (EVar "e")))
(DFunDef false "appSpineArgCount" ((PCon "EApp" (PVar "f") PWild)) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "appSpineArgCount") (EVar "f"))))
(DFunDef false "appSpineArgCount" (PWild) (ELit (LInt 0)))
(DTypeSig true "notePerformSite" (TyFun (TyCon "TcEnv") (TyFun (TyCon "EffRow") (TyCon "Unit"))))
(DFunDef false "notePerformSite" ((PVar "env") (PVar "eff")) (EMatch (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcPerformSites") (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "sites")) () (EApp (EApp (EVar "setRef") (EVar "sites")) (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "cell")) (ETuple (EVar "cell") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")))) (EApp (EVar "snd") (EApp (EVar "rowFlat") (EVar "eff")))) (EFieldAccess (EVar "sites") "value"))))))
(DTypeSig true "markBinders" (TyFun (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyCon "Unit"))))
(DFunDef false "markBinders" ((PVar "table") (PVar "cells")) (EApp (EApp (EVar "setRef") (EVar "table")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PVar "c")) (EApp (EApp (EApp (EVar "IdMap.set") (EApp (EVar "authvarId") (EVar "c"))) (ELit LUnit)) (EVar "m")))) (EFieldAccess (EVar "table") "value")) (EVar "cells"))))
(DTypeSig true "collectProducedSummary" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "EffRow")) (TyCon "EffRow"))))
(DFunDef false "collectProducedSummary" ((PVar "mctx") (PVar "rows")) (EBlock (DoLet false false (PVar "summary") (EApp (EApp (EVar "freshEffectSummary") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PVar "row")) (EApp (EApp (EApp (EVar "recordEffectBody") (EVar "mctx")) (EVar "summary")) (EVar "row")))) (EVar "rows"))) (DoExpr (EVar "summary"))))
(DTypeSig true "registerLocalGroupAbs" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "LetBind") (TyApp (TyCon "Option") (TyCon "ScopeId")))) (TyCon "Unit"))))))
(DFunDef false "registerLocalGroupAbs" ((PVar "env") PWild PWild (PList)) (ELit LUnit))
(DFunDef false "registerLocalGroupAbs" ((PVar "genv") (PVar "oblN0") (PVar "callN0") (PCons (PTuple (PAs "bind" (PCon "LetBind" (PVar "name") PWild PWild PWild)) (PVar "lscope")) (PVar "rest"))) (EBlock (DoExpr (EMatch (EApp (EApp (EVar "lookupVar") (EVar "genv")) (EVar "name")) (arm (PCon "Some" (PVar "sch")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerLocalAbsIf") (EFieldAccess (EFieldAccess (EVar "genv") "teDyn") "dcModule")) (EVar "name")) (EVar "lscope")) (EVar "sch")) (EVar "oblN0")) (EVar "callN0"))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EApp (EApp (EApp (EApp (EVar "registerLocalGroupAbs") (EVar "genv")) (EVar "oblN0")) (EVar "callN0")) (EVar "rest")))))
(DTypeSig true "localBindingSummary" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "LetBind") (TyTuple (TyCon "String") (TyCon "BindingSummary")))))
(DFunDef false "localBindingSummary" ((PVar "mctx") (PCon "LetBind" (PVar "name") (PVar "clauses") PWild PWild)) (EBlock (DoLet false false (PVar "arity") (EMatch (EApp (EApp (EVar "map") (EVar "funClausePair")) (EVar "clauses")) (arm (PCons (PTuple (PVar "pats") PWild) PWild) () (EApp (EVar "listLen") (EVar "pats"))) (arm (PList) () (ELit (LInt 0))))) (DoExpr (ETuple (EVar "name") (EApp (EApp (EApp (EVar "newBindingSummary") (EVar "arity")) (EApp (EVar "freshVar") (EVar "mctx"))) (EApp (EVar "freshEffectSummary") (EVar "mctx")))))))
(DTypeSig false "fileBoundKey" (TyFun (TyCon "Loc") (TyCon "String")))
(DFunDef false "fileBoundKey" ((PCon "Loc" (PVar "file") (PVar "line") (PVar "col") (PVar "endLine") (PVar "endCol"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "col")))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "endLine")))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "endCol")))) (ELit (LString ""))))
(DTypeSig true "fileBodyLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "fileBodyLoc" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "fileBodyLoc" ((PVar "e")) (EBlock (DoLet false false (PVar "found") (EApp (EVar "Ref") (EVar "None"))) (DoLet false false PWild (EApp (EApp (EVar "mapChildren") (ELam ((PVar "child")) (EBlock (DoExpr (EMatch (EFieldAccess (EVar "found") "value") (arm (PCon "None") () (EApp (EApp (EVar "setRef") (EVar "found")) (EApp (EVar "fileBodyLoc") (EVar "child")))) (arm (PCon "Some" PWild) () (ELit LUnit)))) (DoExpr (EVar "child"))))) (EVar "e"))) (DoExpr (EFieldAccess (EVar "found") "value"))))
(DTypeSig true "fileBoundSite" (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyCon "String"))))
(DFunDef false "fileBoundSite" ((PVar "mid") (PVar "loc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "stringLength") (EVar "mid"))))) (ELit (LString ":"))) (EApp (EVar "display") (EVar "mid"))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "fileBoundKey") (EVar "loc")))) (ELit (LString ""))))
(DTypeSig false "scopeFileBoundModule" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "String"))))
(DFunDef false "scopeFileBoundModule" ((PVar "mctx") PWild) (EFieldAccess (EApp (EApp (EVar "Scopes.scopeFrame") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) "sfModuleId"))
(DTypeSig true "fileValueKey" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "fileValueKey" ((PVar "mid") (PVar "e")) (EApp (EApp (EVar "map") (ELam ((PVar "loc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "fileBoundSite") (EVar "mid")) (EVar "loc")))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "fileValueShape") (EVar "e")))) (ELit (LString ""))))) (EApp (EVar "fileBodyLoc") (EVar "e"))))
(DTypeSig false "fileValueShape" (TyFun (TyCon "Expr") (TyCon "String")))
(DFunDef false "fileValueShape" ((PCon "ELoc" PWild PWild)) (ELit (LString "loc")))
(DFunDef false "fileValueShape" ((PCon "EApp" (PVar "f") PWild)) (EBinOp "++" (ELit (LString "app")) (EApp (EVar "intToString") (EBinOp "+" (EApp (EVar "appSpineArgCount") (EVar "f")) (ELit (LInt 1))))))
(DFunDef false "fileValueShape" ((PCon "ELam" PWild PWild)) (ELit (LString "lambda")))
(DFunDef false "fileValueShape" (PWild) (ELit (LString "value")))
(DTypeSig false "finishFileValueScope" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "Unit"))))
(DFunDef false "finishFileValueScope" ((PVar "mctx") PWild) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fileValueScopes") "value") (arm (PCons (PVar "saved") (PVar "rest")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fileValueScopes")) (EVar "rest"))) (DoLet false false (PVar "flows") (EApp (EApp (EVar "wWindow") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fileValueFlows")) (EApp (EVar "snd") (EVar "saved")))) (DoExpr (EApp (EApp (EVar "wRestore") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fileValueFlows")) (EVar "saved"))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PVar "flow")) (EIf (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "rest")) (EApp (EVar "not") (EApp (EVar "unsettledFileValueFlow") (EVar "flow")))) (EApp (EApp (EVar "checkFileValueFlow") (EVar "mctx")) (EVar "flow")) (ELit LUnit)))) (EVar "flows"))) (DoExpr (EMatch (EVar "rest") (arm (PList) () (ELit LUnit)) (arm PWild () (EApp (EApp (EVar "wPushAll") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fileValueFlows")) (EApp (EVar "reverseL") (EApp (EApp (EVar "filterList") (EVar "unsettledFileValueFlow")) (EVar "flows"))))))) (DoExpr (ELit LUnit)))) (arm (PList) () (ELit LUnit))))
(DTypeSig false "unsettledFileValueFlow" (TyFun (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono") (TyCon "Mono")) (TyCon "Bool")))
(DFunDef false "unsettledFileValueFlow" ((PTuple PWild (PVar "upper") (PVar "lower"))) (EApp (EApp (EApp (EVar "unsettledPackedFileBound") (EVar "False")) (EVar "upper")) (EVar "lower")))
(DTypeSig false "unsettledPackedFileBound" (TyFun (TyCon "Bool") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Bool")))))
(DFunDef false "unsettledPackedFileBound" ((PVar "packed") (PVar "upper") (PVar "lower")) (EMatch (ETuple (EApp (EVar "normalize") (EVar "upper")) (EApp (EVar "normalize") (EVar "lower"))) (arm (PTuple (PCon "TVar" PWild) PWild) () (EVar "True")) (arm (PTuple PWild (PCon "TVar" PWild)) () (EVar "True")) (arm (PTuple (PCon "TQual" (PVar "u") PWild) (PVar "l")) () (EApp (EApp (EApp (EVar "unsettledPackedFileBound") (EVar "packed")) (EVar "u")) (EVar "l"))) (arm (PTuple (PVar "u") (PCon "TQual" (PVar "l") PWild)) () (EApp (EApp (EApp (EVar "unsettledPackedFileBound") (EVar "packed")) (EVar "u")) (EVar "l"))) (arm (PTuple (PCon "TApp" (PVar "uf") (PVar "ux")) (PCon "TApp" (PVar "lf") (PVar "lx"))) () (EBinOp "||" (EApp (EApp (EApp (EVar "unsettledPackedFileBound") (EVar "True")) (EVar "uf")) (EVar "lf")) (EApp (EApp (EApp (EVar "unsettledPackedFileBound") (EVar "True")) (EVar "ux")) (EVar "lx")))) (arm (PTuple (PCon "TFun" (PVar "ud") (PVar "ur") (PVar "ux")) (PCon "TFun" (PVar "ld") (PVar "lr") (PVar "lx"))) () (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EVar "packed") (EApp (EApp (EVar "unsettledFileRow") (EVar "ur")) (EVar "lr"))) (EApp (EApp (EApp (EVar "unsettledPackedFileBound") (EVar "packed")) (EVar "ld")) (EVar "ud"))) (EApp (EApp (EApp (EVar "unsettledPackedFileBound") (EVar "packed")) (EVar "ux")) (EVar "lx")))) (arm PWild () (EVar "False"))))
(DTypeSig false "unsettledFileRow" (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Bool"))))
(DFunDef false "unsettledFileRow" ((PVar "upper") (PVar "lower")) (EBlock (DoLet false false (PTuple (PVar "ua") (PVar "ut")) (EApp (EVar "rowFlat") (EVar "upper"))) (DoLet false false (PTuple (PVar "la") (PVar "lt")) (EApp (EVar "rowFlat") (EVar "lower"))) (DoExpr (EBinOp "||" (EBinOp "||" (EApp (EVar "isNonEmptyL") (EVar "ut")) (EApp (EVar "isNonEmptyL") (EVar "lt"))) (EApp (EApp (EVar "anyList") (ELam ((PVar "a")) (EBinOp "&&" (EApp (EVar "narrowFileAtom") (EVar "a")) (EApp (EVar "authHasVars") (EApp (EVar "atomAuth") (EVar "a")))))) (EBinOp "++" (EVar "ua") (EVar "la")))))))
(DTypeSig false "checkFileValueFlow" (TyFun (TyCon "ModuleCtx") (TyFun (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono") (TyCon "Mono")) (TyCon "Unit"))))
(DFunDef false "checkFileValueFlow" ((PVar "mctx") (PTuple (PVar "loc") (PVar "upper") (PVar "lower"))) (EIf (EApp (EApp (EApp (EVar "changesPackedFileBound") (EVar "False")) (EVar "upper")) (EVar "lower")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (ELit (LString "T-FILE-BOUND-VALUE"))) (EVar "loc")) (EBinOp "++" (EBinOp "++" (ELit (LString "a function's file bound cannot change inside a container: ")) (EApp (EVar "ppMonosShared") (EListLit (EVar "lower") (EVar "upper")))) (ELit (LString "; annotate the function with the container's FileRead or FileWrite bound before packing it")))) (ELit LUnit)))
(DTypeSig false "changesPackedFileBound" (TyFun (TyCon "Bool") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Bool")))))
(DFunDef false "changesPackedFileBound" ((PVar "packed") (PVar "upper") (PVar "lower")) (EMatch (ETuple (EApp (EVar "normalize") (EVar "upper")) (EApp (EVar "normalize") (EVar "lower"))) (arm (PTuple (PCon "TQual" (PVar "u") PWild) (PVar "l")) () (EApp (EApp (EApp (EVar "changesPackedFileBound") (EVar "packed")) (EVar "u")) (EVar "l"))) (arm (PTuple (PVar "u") (PCon "TQual" (PVar "l") PWild)) () (EApp (EApp (EApp (EVar "changesPackedFileBound") (EVar "packed")) (EVar "u")) (EVar "l"))) (arm (PTuple (PCon "TApp" (PVar "uf") (PVar "ux")) (PCon "TApp" (PVar "lf") (PVar "lx"))) () (EBinOp "||" (EApp (EApp (EApp (EVar "changesPackedFileBound") (EVar "True")) (EVar "uf")) (EVar "lf")) (EApp (EApp (EApp (EVar "changesPackedFileBound") (EVar "True")) (EVar "ux")) (EVar "lx")))) (arm (PTuple (PCon "TFun" (PVar "ud") (PVar "ur") (PVar "ux")) (PCon "TFun" (PVar "ld") (PVar "lr") (PVar "lx"))) () (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EVar "packed") (EApp (EApp (EVar "changesFileRow") (EVar "ur")) (EVar "lr"))) (EApp (EApp (EApp (EVar "changesPackedFileBound") (EVar "packed")) (EVar "ld")) (EVar "ud"))) (EApp (EApp (EApp (EVar "changesPackedFileBound") (EVar "packed")) (EVar "ux")) (EVar "lx")))) (arm PWild () (EVar "False"))))
(DTypeSig false "changesFileRow" (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Bool"))))
(DFunDef false "changesFileRow" ((PVar "upper") (PVar "lower")) (EBlock (DoLet false false (PTuple (PVar "ua") (PVar "ut")) (EApp (EVar "rowFlat") (EVar "upper"))) (DoLet false false (PTuple (PVar "la") (PVar "lt")) (EApp (EVar "rowFlat") (EVar "lower"))) (DoExpr (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "ut")) (EApp (EApp (EVar "anyList") (ELam ((PVar "u")) (EBinOp "&&" (EApp (EVar "narrowFileAtom") (EVar "u")) (EBinOp "||" (EApp (EVar "isNonEmptyL") (EVar "lt")) (EApp (EApp (EVar "anyList") (ELam ((PVar "l")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "atomKey") (EVar "l")) (EApp (EVar "atomKey") (EVar "u"))) (EApp (EVar "not") (EBinOp "&&" (EApp (EApp (EVar "authSub") (EApp (EVar "atomAuth") (EVar "l"))) (EApp (EVar "atomAuth") (EVar "u"))) (EApp (EApp (EVar "authSub") (EApp (EVar "atomAuth") (EVar "u"))) (EApp (EVar "atomAuth") (EVar "l")))))))) (EVar "la")))))) (EVar "ua"))))))
(DTypeSig true "hasFileBoundValue" (TyFun (TyCon "Mono") (TyCon "Bool")))
(DFunDef false "hasFileBoundValue" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TFun" PWild (PVar "row") (PVar "result")) () (EBlock (DoLet false false (PTuple (PVar "atoms") (PVar "tails")) (EApp (EVar "rowFlat") (EVar "row"))) (DoExpr (EBinOp "||" (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "tails")) (EApp (EApp (EVar "anyList") (EVar "narrowFileAtom")) (EVar "atoms"))) (EApp (EVar "hasFileBoundValue") (EVar "result")))))) (arm (PCon "TQual" (PVar "inner") PWild) () (EApp (EVar "hasFileBoundValue") (EVar "inner"))) (arm PWild () (EVar "False"))))
(DTypeSig true "recordValueFileBound" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "recordValueFileBound" ((PVar "mctx") (PVar "e") (PVar "ty")) (EIf (EApp (EVar "hasFileBoundValue") (EVar "ty")) (EMatch (EApp (EApp (EVar "fileValueKey") (EApp (EApp (EVar "scopeFileBoundModule") (EVar "mctx")) (ELit LUnit))) (EVar "e")) (arm (PCon "Some" (PVar "key")) () (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsValueBounds")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "::" (ETuple (EVar "ty") (EApp (EApp (EVar "grantChainAt") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit)))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EFieldAccess (EVar "st") "gsValueBounds") "value"))))) (EFieldAccess (EFieldAccess (EVar "st") "gsValueBounds") "value")))))) (arm (PCon "None") () (ELit LUnit))) (ELit LUnit)))
(DTypeSig true "recordFileBound" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Expr") (TyFun (TyCon "EffRow") (TyCon "Unit")))))
(DFunDef false "recordFileBound" ((PVar "mctx") (PVar "body") (PVar "row")) (EBlock (DoLet false false (PTuple (PVar "atoms") (PVar "tails")) (EApp (EVar "rowFlat") (EVar "row"))) (DoExpr (EIf (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "tails")) (EApp (EApp (EVar "anyList") (EVar "narrowFileAtom")) (EVar "atoms"))) (EMatch (EApp (EVar "fileBodyLoc") (EVar "body")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "loc")) () (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "grants")) (DoLet false false (PVar "key") (EApp (EApp (EVar "fileBoundSite") (EApp (EApp (EVar "scopeFileBoundModule") (EVar "mctx")) (ELit LUnit))) (EVar "loc"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsBounds")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "::" (ETuple (EVar "row") (EApp (EApp (EVar "grantChainAt") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit)))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EFieldAccess (EVar "st") "gsBounds") "value"))))) (EFieldAccess (EFieldAccess (EVar "st") "gsBounds") "value"))))))) (ELit LUnit)))))
(DTypeSig true "narrowFileAtom" (TyFun (TyCon "Atom") (TyCon "Bool")))
(DFunDef false "narrowFileAtom" ((PVar "atom")) (EMatch (EApp (EVar "atomLabelOf") (EVar "atom")) (arm (PCon "EffLabel" (PVar "label") (PCon "OriginBuiltin")) () (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EVar "label") (ELit (LString "FileRead"))) (EBinOp "==" (EVar "label") (ELit (LString "FileWrite")))) (EApp (EVar "not") (EApp (EVar "authIsTop") (EApp (EVar "atomAuth") (EVar "atom")))))) (arm PWild () (EVar "False"))))
(DTypeSig true "recordClauseFileBound" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyCon "Unit"))))))
(DFunDef false "recordClauseFileBound" ((PVar "mctx") (PVar "body") (PVar "arity") (PVar "ty")) (EIf (EBinOp "<=" (EVar "arity") (ELit (LInt 0))) (ELit LUnit) (EIf (EVar "otherwise") (EMatch (EApp (EVar "normalize") (EVar "ty")) (arm (PCon "TFun" PWild (PVar "row") (PVar "result")) () (EIf (EBinOp "==" (EVar "arity") (ELit (LInt 1))) (EApp (EApp (EApp (EVar "recordFileBound") (EVar "mctx")) (EVar "body")) (EVar "row")) (EApp (EApp (EApp (EApp (EVar "recordClauseFileBound") (EVar "mctx")) (EVar "body")) (EBinOp "-" (EVar "arity") (ELit (LInt 1)))) (EVar "result")))) (arm (PCon "TQual" (PVar "inner") PWild) () (EApp (EApp (EApp (EApp (EVar "recordClauseFileBound") (EVar "mctx")) (EVar "body")) (EVar "arity")) (EVar "inner"))) (arm PWild () (ELit LUnit))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "launderEscapeFromLog" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "EffRow")) (TyFun (TyApp (TyCon "List") (TyCon "EffRow")) (TyFun (TyApp (TyCon "List") (TyCon "AbsorptionEvent")) (TyApp (TyCon "List") (TyCon "Atom")))))))
(DFunDef false "launderEscapeFromLog" ((PVar "gctx") (PList) PWild PWild) (EListLit))
(DFunDef false "launderEscapeFromLog" ((PVar "gctx") PWild (PList) PWild) (EListLit))
(DFunDef false "launderEscapeFromLog" ((PVar "gctx") (PCons (PVar "der") (PVar "dRest")) (PCons (PVar "aer") (PVar "aRest")) (PVar "evts")) (EBlock (DoLet false false (PVar "here") (EMatch (EVar "aer") (arm (PCon "EffRow" PWild (PCon "None")) () (EListLit)) (arm (PCon "EffRow" PWild (PCon "Some" PWild)) () (EApp (EApp (EApp (EVar "launderOpenActualArrow") (EVar "gctx")) (EVar "der")) (EVar "evts"))))) (DoExpr (EBinOp "++" (EVar "here") (EApp (EApp (EApp (EApp (EVar "launderEscapeFromLog") (EVar "gctx")) (EVar "dRest")) (EVar "aRest")) (EVar "evts"))))))
(DTypeSig false "launderOpenActualArrow" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EffRow") (TyFun (TyApp (TyCon "List") (TyCon "AbsorptionEvent")) (TyApp (TyCon "List") (TyCon "Atom"))))))
(DFunDef false "launderOpenActualArrow" ((PVar "gctx") (PCon "EffRow" (PVar "declAtoms") (PCon "Some" (PVar "cell"))) (PVar "evts")) (EBlock (DoLet false false (PVar "tid") (EApp (EVar "liveTailId") (EVar "cell"))) (DoExpr (EIf (EBinOp "==" (EVar "tid") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EListLit) (EApp (EApp (EApp (EVar "atomsEscape") (EVar "gctx")) (EApp (EApp (EVar "atomsAbsorbedInto") (EVar "tid")) (EVar "evts"))) (EVar "declAtoms"))))))
(DFunDef false "launderOpenActualArrow" ((PVar "gctx") (PCon "EffRow" PWild (PCon "None")) PWild) (EListLit))
(DTypeSig false "atomsAbsorbedInto" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "AbsorptionEvent")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "atomsAbsorbedInto" (PWild (PList)) (EListLit))
(DFunDef false "atomsAbsorbedInto" ((PVar "tid") (PCons (PVar "ev") (PVar "rest"))) (EIf (EBinOp "==" (EApp (EVar "liveTailId") (EFieldAccess (EVar "ev") "cell")) (EVar "tid")) (EBinOp "::" (EFieldAccess (EVar "ev") "atom") (EApp (EApp (EVar "atomsAbsorbedInto") (EVar "tid")) (EVar "rest"))) (EApp (EApp (EVar "atomsAbsorbedInto") (EVar "tid")) (EVar "rest"))))
(DTypeSig true "checkMethodEffVarRigidity" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit")))))))))))
(DFunDef false "checkMethodEffVarRigidity" ((PVar "mctx") (PVar "subject") (PVar "headMonos") (PVar "gscope") (PVar "mty") (PVar "effVars") (PVar "launderFlagged") (PVar "eager") (PVar "loc")) (EBlock (DoExpr (EIf (EApp (EApp (EVar "anyContainsI") (EApp (EVar "effVarTailIds") (EVar "effVars"))) (EApp (EApp (EVar "flatMap") (EVar "monoIndexEffvarIds")) (EVar "headMonos"))) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-IMPL-TOO-SPECIFIC"))) (EVar "loc")) (EApp (EApp (EVar "aliasesHeadRowMsg") (EVar "subject")) (EVar "mty"))) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkImplEffVarRigidity") (EVar "mctx")) (EVar "subject")) (EVar "gscope")) (EVar "mty")) (EVar "effVars")) (EVar "launderFlagged")) (EVar "eager")) (EVar "loc")))))
(DTypeSig false "checkImplEffVarRigidity" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit"))))))))))
(DFunDef false "checkImplEffVarRigidity" ((PVar "mctx") (PVar "subject") (PVar "scope") (PVar "mty") (PVar "effMap") (PVar "launderFlagged") (PVar "eager") (PVar "loc")) (EBlock (DoLet false false (PVar "occs") (EBinOp "++" (EApp (EApp (EVar "effVarOccAtoms") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "mty")) (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EListLit)))) (EApp (EApp (EApp (EVar "rowArgNamesIn") (EVar "mctx")) (EVar "scope")) (EVar "mty"))))) (DoExpr (EIf (EVar "launderFlagged") (ELit LUnit) (EApp (EApp (EApp (EApp (EApp (EVar "checkEffVarAtoms") (EVar "mctx")) (EVar "subject")) (EVar "occs")) (EVar "effMap")) (EVar "loc")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "checkIndexOnlyEffVarsOpen") (EVar "mctx")) (EVar "subject")) (EVar "effMap")) (EVar "loc")) (EVar "eager"))) (DoExpr (EIf (EApp (EVar "hasDupI") (EApp (EVar "effVarTailIds") (EVar "effMap"))) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-IMPL-TOO-SPECIFIC"))) (EVar "loc")) (EApp (EApp (EVar "collapsesEffvarsMsg") (EVar "subject")) (EVar "mty"))) (ELit LUnit)))))
(DTypeSig false "checkIndexOnlyEffVarsOpen" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "checkIndexOnlyEffVarsOpen" ((PVar "mctx") (PVar "subject") (PVar "effMap") (PVar "loc") (PVar "eager")) (EApp (EApp (EApp (EApp (EApp (EVar "checkIndexOnlyGo") (EVar "mctx")) (EVar "subject")) (EVar "effMap")) (EVar "loc")) (EVar "eager")))
(DTypeSig true "eagerIndexOnlyVars" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyFun (TyApp (TyCon "List") (TyCon "EffRow")) (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "eagerIndexOnlyVars" ((PList) PWild PWild PWild PWild) (EListLit))
(DFunDef false "eagerIndexOnlyVars" ((PVar "idx") (PVar "effMap") (PVar "actualArrows") (PVar "expected") (PVar "actual")) (EBlock (DoLet false false (PVar "tails") (EApp (EApp (EVar "flatMap") (EVar "rowTailId")) (EVar "actualArrows"))) (DoLet false false (PVar "pairs") (EApp (EApp (EVar "pairRowCells") (EVar "expected")) (EVar "actual"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "v")) (EApp (EApp (EApp (EApp (EVar "effVarCellPerformed") (EVar "v")) (EVar "effMap")) (EVar "pairs")) (EVar "tails")))) (EVar "idx")))))
(DTypeSig false "pairRowCells" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "pairRowCells" ((PVar "d") (PVar "a")) (EMatch (EApp (EVar "peelQual") (EVar "d")) (arm (PCon "TFun" (PVar "d1") (PVar "dr") (PVar "d2")) () (EMatch (EApp (EVar "peelQual") (EVar "a")) (arm (PCon "TFun" (PVar "a1") (PVar "ar") (PVar "a2")) () (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "pairRows") (EVar "dr")) (EVar "ar")) (EApp (EApp (EVar "pairRowCells") (EVar "d1")) (EVar "a1"))) (EApp (EApp (EVar "pairRowCells") (EVar "d2")) (EVar "a2")))) (arm PWild () (EListLit)))) (arm (PCon "TApp" (PVar "d1") (PVar "d2")) () (EMatch (EApp (EVar "peelQual") (EVar "a")) (arm (PCon "TApp" (PVar "a1") (PVar "a2")) () (EBinOp "++" (EApp (EApp (EVar "pairRowCells") (EVar "d1")) (EVar "a1")) (EApp (EApp (EVar "pairRowCells") (EVar "d2")) (EVar "a2")))) (arm PWild () (EListLit)))) (arm (PCon "TEff" (PVar "dr")) () (EMatch (EApp (EVar "peelQual") (EVar "a")) (arm (PCon "TEff" (PVar "ar")) () (EApp (EApp (EVar "pairRows") (EVar "dr")) (EVar "ar"))) (arm PWild () (EListLit)))) (arm PWild () (EListLit))))
(DTypeSig false "pairRows" (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "pairRows" ((PVar "dr") (PVar "ar")) (EMatch (EApp (EVar "rowTailId") (EVar "dr")) (arm (PList (PVar "did")) () (EApp (EApp (EVar "map") (ELam ((PVar "aid")) (ETuple (EVar "did") (EVar "aid")))) (EApp (EVar "rowTailId") (EVar "ar")))) (arm PWild () (EListLit))))
(DTypeSig false "effVarCellPerformed" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool"))))))
(DFunDef false "effVarCellPerformed" ((PVar "v") (PVar "effMap") (PVar "pairs") (PVar "tails")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "v")) (EVar "effMap")) (arm (PCon "Some" (PVar "cell")) () (EBlock (DoLet false false (PVar "dids") (EApp (EVar "rowTailId") (EApp (EApp (EVar "EffRow") (EListLit)) (EApp (EVar "Some") (EVar "cell"))))) (DoExpr (EApp (EApp (EVar "anyList") (ELam ((PVar "did")) (EBinOp "||" (EApp (EApp (EVar "containsI") (EVar "did")) (EVar "tails")) (EApp (EApp (EVar "anyList") (ELam ((PVar "p")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "fst") (EVar "p")) (EVar "did")) (EApp (EApp (EVar "containsI") (EApp (EVar "snd") (EVar "p"))) (EVar "tails"))))) (EVar "pairs"))))) (EVar "dids"))))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "checkIndexOnlyGo" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "checkIndexOnlyGo" ((PVar "mctx") PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "checkIndexOnlyGo" ((PVar "mctx") (PVar "subject") (PVar "effMap") (PVar "loc") (PCons (PVar "v") (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-EFFECT-INDEX-EAGER"))) (EVar "loc")) (EApp (EApp (EVar "indexEagerMsg") (EVar "subject")) (EVar "v")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "checkIndexOnlyGo") (EVar "mctx")) (EVar "subject")) (EVar "effMap")) (EVar "loc")) (EVar "rest")))))
(DTypeSig true "performSiteIn" (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyApp (TyCon "Option") (TyCon "Loc")))))) (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "performSiteIn" ((PCon "None") PWild) (EVar "None"))
(DFunDef false "performSiteIn" ((PCon "Some" (PVar "sites")) (PVar "actual")) (EBlock (DoLet false false (PVar "tails") (EApp (EApp (EVar "flatMap") (EVar "rowTailId")) (EApp (EVar "allArrowEffs") (EVar "actual")))) (DoExpr (EApp (EApp (EVar "findMap") (ELam ((PVar "site")) (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "id")) (EApp (EApp (EVar "containsI") (EVar "id")) (EVar "tails")))) (EApp (EVar "rowTailId") (EApp (EApp (EVar "EffRow") (EListLit)) (EApp (EVar "Some") (EApp (EVar "fst") (EVar "site")))))) (EApp (EVar "snd") (EVar "site")) (EVar "None")))) (EApp (EVar "reverseL") (EFieldAccess (EVar "sites") "value"))))))
(DTypeSig true "indexOnlyEffVars" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "indexOnlyEffVars" ((PVar "mctx") (PVar "scope") (PVar "mty")) (EBlock (DoLet false false (PVar "argNames") (EApp (EVar "dedup") (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EApp (EVar "methodEffArgOccs") (EVar "mctx")) (EVar "scope")) (EVar "mty"))))) (DoLet false false (PVar "charged") (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EVar "methodEffChargedOccs") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "mty")))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "v")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "v")) (EVar "charged"))))) (EVar "argNames")))))
(DTypeSig false "methodEffChargedOccs" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))))))
(DFunDef false "methodEffChargedOccs" ((PVar "gctx") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EVar "methodEffChargedOccs") (EVar "gctx")) (EVar "t")))
(DFunDef false "methodEffChargedOccs" ((PVar "gctx") (PCon "TyEffect" (PVar "labels") (PVar "tails") (PVar "t"))) (EBinOp "++" (EApp (EApp (EApp (EVar "occsOfTails") (EVar "gctx")) (EVar "tails")) (EVar "labels")) (EApp (EApp (EVar "methodEffChargedOccs") (EVar "gctx")) (EVar "t"))))
(DFunDef false "methodEffChargedOccs" ((PVar "gctx") (PCon "TyFun" PWild (PVar "b"))) (EApp (EApp (EVar "methodEffChargedOccs") (EVar "gctx")) (EVar "b")))
(DFunDef false "methodEffChargedOccs" ((PVar "gctx") (PVar "t")) (EApp (EApp (EVar "effVarChargedOccs") (EVar "gctx")) (EVar "t")))
(DTypeSig false "effVarChargedOccs" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))))))
(DFunDef false "effVarChargedOccs" ((PVar "gctx") (PCon "TyEffect" (PVar "labels") (PVar "tails") (PVar "t"))) (EBinOp "++" (EApp (EApp (EApp (EVar "occsOfTails") (EVar "gctx")) (EVar "tails")) (EVar "labels")) (EApp (EApp (EVar "effVarChargedOccs") (EVar "gctx")) (EVar "t"))))
(DFunDef false "effVarChargedOccs" ((PVar "gctx") (PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EVar "effVarChargedOccs") (EVar "gctx")) (EVar "a")) (EApp (EApp (EVar "effVarChargedOccs") (EVar "gctx")) (EVar "b"))))
(DFunDef false "effVarChargedOccs" ((PVar "gctx") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EVar "effVarChargedOccs") (EVar "gctx")) (EVar "a")) (EApp (EApp (EVar "effVarChargedOccs") (EVar "gctx")) (EVar "b"))))
(DFunDef false "effVarChargedOccs" ((PVar "gctx") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "effVarChargedOccs") (EVar "gctx"))) (EVar "ts")))
(DFunDef false "effVarChargedOccs" ((PVar "gctx") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EVar "effVarChargedOccs") (EVar "gctx")) (EVar "t")))
(DFunDef false "effVarChargedOccs" ((PVar "gctx") PWild) (EListLit))
(DTypeSig false "checkEffVarAtoms" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit")))))))
(DFunDef false "checkEffVarAtoms" ((PVar "mctx") PWild PWild (PList) PWild) (ELit LUnit))
(DFunDef false "checkEffVarAtoms" ((PVar "mctx") (PVar "subject") (PVar "occs") (PCons (PTuple (PVar "n") (PVar "cell")) (PVar "rest")) (PVar "loc")) (EBlock (DoLet false false (PVar "esc") (EApp (EApp (EApp (EApp (EVar "effVarOccEscape") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "n")) (EApp (EVar "effrowLabels") (EApp (EApp (EVar "EffRow") (EListLit)) (EApp (EVar "Some") (EVar "cell"))))) (EVar "occs"))) (DoExpr (EIf (EApp (EVar "isNonEmptyL") (EVar "esc")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-EFFECT-LAUNDER"))) (EVar "loc")) (EApp (EApp (EApp (EVar "effVarLaunderMsg") (EVar "subject")) (EVar "n")) (EVar "esc"))) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "checkEffVarAtoms") (EVar "mctx")) (EVar "subject")) (EVar "occs")) (EVar "rest")) (EVar "loc")))))
(DTypeSig false "effVarOccEscape" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))) (TyApp (TyCon "List") (TyCon "Atom")))))))
(DFunDef false "effVarOccEscape" ((PVar "gctx") PWild (PList) PWild) (EListLit))
(DFunDef false "effVarOccEscape" ((PVar "gctx") PWild PWild (PList)) (EListLit))
(DFunDef false "effVarOccEscape" ((PVar "gctx") (PVar "n") (PVar "instAtoms") (PCons (PTuple (PVar "m") (PVar "declAtoms")) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "m") (EVar "n")) (EApp (EVar "isNonEmptyL") (EApp (EApp (EApp (EVar "atomsEscape") (EVar "gctx")) (EVar "instAtoms")) (EVar "declAtoms")))) (EApp (EApp (EApp (EVar "atomsEscape") (EVar "gctx")) (EVar "instAtoms")) (EVar "declAtoms")) (EApp (EApp (EApp (EApp (EVar "effVarOccEscape") (EVar "gctx")) (EVar "n")) (EVar "instAtoms")) (EVar "rest"))))
(DTypeSig false "effVarOccAtoms" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))))))
(DFunDef false "effVarOccAtoms" ((PVar "gctx") (PCon "TyEffect" (PVar "labels") (PVar "tails") (PVar "t"))) (EBinOp "++" (EApp (EApp (EApp (EVar "occsOfTails") (EVar "gctx")) (EVar "tails")) (EVar "labels")) (EApp (EApp (EVar "effVarOccAtoms") (EVar "gctx")) (EVar "t"))))
(DFunDef false "effVarOccAtoms" ((PVar "gctx") (PCon "TyRow" (PVar "labels") (PVar "tails") PWild)) (EApp (EApp (EApp (EVar "occsOfTails") (EVar "gctx")) (EVar "tails")) (EVar "labels")))
(DFunDef false "effVarOccAtoms" ((PVar "gctx") (PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EVar "effVarOccAtoms") (EVar "gctx")) (EVar "a")) (EApp (EApp (EVar "effVarOccAtoms") (EVar "gctx")) (EVar "b"))))
(DFunDef false "effVarOccAtoms" ((PVar "gctx") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EVar "effVarOccAtoms") (EVar "gctx")) (EVar "a")) (EApp (EApp (EVar "effVarOccAtoms") (EVar "gctx")) (EVar "b"))))
(DFunDef false "effVarOccAtoms" ((PVar "gctx") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "effVarOccAtoms") (EVar "gctx"))) (EVar "ts")))
(DFunDef false "effVarOccAtoms" ((PVar "gctx") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EVar "effVarOccAtoms") (EVar "gctx")) (EVar "t")))
(DFunDef false "effVarOccAtoms" ((PVar "gctx") PWild) (EListLit))
(DTypeSig true "clausesAt" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "clausesAt" ((PVar "n") (PVar "m")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "m")) (arm (PCon "Some" (PVar "xs")) () (EVar "xs")) (arm (PCon "None") () (EListLit))))
(DTypeSig true "clausesOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "clausesOf" ((PVar "n") (PVar "m")) (EApp (EApp (EVar "revClauses") (EApp (EApp (EVar "clausesAt") (EVar "n")) (EVar "m"))) (EListLit)))
(DTypeSig true "revClauses" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "revClauses" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "revClauses" ((PCons (PVar "x") (PVar "xs")) (PVar "acc")) (EApp (EApp (EVar "revClauses") (EVar "xs")) (EBinOp "::" (EVar "x") (EVar "acc"))))
(DTypeSig true "memberEffectRoots" (TyFun (TyCon "ScopedMember") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "memberEffectRoots" ((PVar "member") (PVar "roots")) (EBlock (DoLet false false (PVar "inputs") (EIf (EFieldAccess (EFieldAccess (EVar "member") "smSigned") "value") (EVar "roots") (EApp (EApp (EVar "effectRoots") (EFieldAccess (EFieldAccess (EVar "member") "smOwned") "bsValue")) (EVar "roots")))) (DoExpr (EApp (EApp (EApp (EVar "IdMap.foldlWithKey") (ELam ((PVar "acc") (PVar "id") PWild) (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (ELit LUnit)) (EVar "acc")))) (EVar "inputs")) (EFieldAccess (EFieldAccess (EVar "member") "smDeclaredRoots") "value")))))
(DTypeSig true "checkEffectEscape" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "Unit"))))))
(DFunDef false "checkEffectEscape" ((PVar "dyn") (PVar "sigs") (PVar "m") (PVar "effs")) (EMatch (EFieldAccess (EVar "dyn") "dcGroup") (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "group")) () (EApp (EApp (EApp (EApp (EApp (EVar "checkEffectEscapeIn") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "group")) (EVar "sigs")) (EVar "m")) (EVar "effs")))))
(DTypeSig false "checkEffectEscapeIn" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "GroupCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "Unit")))))))
(DFunDef false "checkEffectEscapeIn" ((PVar "mctx") (PVar "group") (PVar "sigs") (PVar "m") (PVar "effs")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "m")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "sigTyMapRef") "value")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "written")) () (EBlock (DoLet false false (PVar "ty") (EApp (EApp (EVar "expandReturnSpine") (EVar "mctx")) (EVar "written"))) (DoExpr (EIf (EApp (EApp (EVar "declaredEffectsOpen") (EVar "mctx")) (EVar "ty")) (ELit LUnit) (EMatch (EApp (EApp (EApp (EVar "atomsEscape") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "filterList") (EVar "concreteAtom")) (EVar "effs"))) (EApp (EApp (EVar "declaredEffects") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ty"))) (arm (PList) () (ELit LUnit)) (arm (PVar "extras") () (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "group") "gcPendingEscapes")) (EBinOp "::" (ETuple (EVar "m") (EFieldAccess (EVar "mctx") "mcLoc") (EApp (EApp (EApp (EApp (EVar "effectEscapeMsg") (EVar "m")) (EApp (EApp (EVar "declaredEffects") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ty"))) (EApp (EVar "declaredEffectTail") (EVar "ty"))) (EVar "extras"))) (EFieldAccess (EFieldAccess (EVar "group") "gcPendingEscapes") "value")))))))))))
(DTypeSig true "flushPendingEscapes" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "GroupCtx")) (TyCon "Unit"))))
(DFunDef false "flushPendingEscapes" ((PVar "mctx") (PCon "None")) (ELit LUnit))
(DFunDef false "flushPendingEscapes" ((PVar "mctx") (PCon "Some" (PVar "group"))) (EBlock (DoLet false false (PVar "pending") (EApp (EVar "reverseL") (EFieldAccess (EFieldAccess (EVar "group") "gcPendingEscapes") "value"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "group") "gcPendingEscapes")) (EListLit))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "entry")) (EBlock (DoLet false false (PTuple (PVar "m") (PVar "loc") (PVar "msg")) (EVar "entry")) (DoExpr (EIf (EApp (EApp (EVar "omHasKey") (EVar "m")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "rowFailureReportedRef") "value")) (ELit LUnit) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (ELit (LString "T-EFFECT-LEAK"))) (EVar "loc")) (EVar "msg"))))))) (ELit LUnit)) (EVar "pending")))))
(DTypeSig false "concreteAtom" (TyFun (TyCon "Atom") (TyCon "Bool")))
(DFunDef false "concreteAtom" ((PVar "a")) (EApp (EVar "not") (EApp (EVar "authHasVars") (EApp (EVar "atomAuth") (EVar "a")))))
# MARK
(DUse false (UseGroup ("types" "tc_types") ((mem "grantTopKey" false) (mem "methodGrantKey" false) (mem "setGrantIds" false) (mem "AbsorptionEvent" true) (mem "GrantBinder" true) (mem "GrantCallee" true) (mem "GrantOcc" true) (mem "MethodGrant" true) (mem "DynCtx" false) (mem "GraphCtx" false) (mem "GroupCtx" false) (mem "Kind" false) (mem "MethodSchemeRow" false) (mem "ModuleCtx" false) (mem "ObligationSite" false) (mem "ScopedMember" false) (mem "SelectedValueOccurrence" false) (mem "TcEnv" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "allArrowEffs" false) (mem "arrowArity" false) (mem "authCellsIn" false) (mem "authOrderIn" false) (mem "authOrderRow" false) (mem "authRoots" false) (mem "authRowCells" false) (mem "authRowRoots" false) (mem "containsI" false) (mem "effectCells" false) (mem "effectRoots" false) (mem "effectRowRoots" false) (mem "funArity" false) (mem "joinCellOf" false) (mem "monoIndexEffvarIds" false) (mem "newEffvarId" false) (mem "peelQual" false) (mem "rowTailId" false) (mem "schemeAuthIds" false) (mem "schemeIds" false) (mem "tyAppSpine" false) (mem "tyArrowCount" false) (mem "liveTailId" false) (mem "anyContainsI" false) (mem "effVarTailIds" false) (mem "hasDupI" false))))
(DUse false (UseGroup ("types" "tc_diag_text") ((mem "aliasesHeadRowMsg" false) (mem "argAtomsMsgFor" false) (mem "argOnlyEffVarMsg" false) (mem "collapsesEffvarsMsg" false) (mem "effectEscapeMsg" false) (mem "effectInclusionMsg" false) (mem "effectUndeterminedMsg" false) (mem "effVarLaunderMsg" false) (mem "indexEagerMsg" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "currentScopeStore" false) (mem "mctxAt" false) (mem "wPushAll" false) (mem "wRestore" false) (mem "wSnapshot" false) (mem "wWindow" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "declGradedScope" false) (mem "effTailNames" false) (mem "funClausePair" false) (mem "lookupBinding" false) (mem "lookupVar" false) (mem "methodArgs" false) (mem "removeAllS" false) (mem "tyTabKey" false))))
(DUse false (UseGroup ("types" "tc_diag") ((mem "pushTypeError" false) (mem "pushTypeErrorAt" false) (mem "pushTypeErrorOnceAt" false) (mem "pushTypeErrorOncePerSite" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "atomsEscape" false) (mem "authorityFailureMsg" false) (mem "captureScope" false) (mem "effectLeakCheck" false) (mem "effectSiteKey" false) (mem "freshEffvarAt" false) (mem "freshVar" false) (mem "producedSlotCovariants" false) (mem "reportIndexFailure" false) (mem "resolvePendingJoins" false) (mem "widenOpenedFor" false))))
(DUse false (UseGroup ("types" "tc_decls_types") ((mem "atomsOfWritten" false) (mem "expandAliasHeadTy" false) (mem "rowArgNames" false) (mem "rowArgNamesIn" false))))
(DUse false (UseGroup ("types" "tc_decls") ((mem "krowArgVarAtoms" false) (mem "paramRowAtomsOf" false) (mem "rowArgAtomsIn" false))))
(DUse false (UseGroup ("types" "tc_solve") ((mem "isLocalAbsName" false))))
(DUse false (UseGroup ("types" "tc_solve_check") ((mem "registerLocalAbs" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" true) (mem "authHasVars" false) (mem "authIsTop" false) (mem "authSub" false) (mem "authvarId" false) (mem "authvarName" false) (mem "authVars" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" true) (mem "EffLabel" true) (mem "EffRow" true) (mem "Effvar" true) (mem "atomAuth" false) (mem "atomKey" false) (mem "atomLabelOf" false) (mem "atomsDiff" false) (mem "effrowLabels" false) (mem "findAtom" false) (mem "rowFlat" false))))
(DUse false (UseGroup ("types" "repr") ((mem "AuthResidual" true) (mem "Mono" true) (mem "Scheme" true) (mem "lookupAssocI" false) (mem "normalize" false) (mem "ppEachShared" false) (mem "ppMonosShared" false))))
(DUse false (UseGroup ("types" "effect_bindings") ((mem "BindingSummary" true) (mem "newBindingSummary" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "EffAtomTy" true) (mem "EvId" true) (mem "Expr" true) (mem "IfaceMethod" true) (mem "LetBind" true) (mem "Loc" true) (mem "Pat" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "firstTyLoc" false) (mem "lookupTab" false) (mem "orElseLoc" false))))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omDelete" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("types" "evidence") ((mem "ScopeId" true))))
(DUse false (UseGroup ("types" "effect_solver") ((mem "ScopeRoles" true) (mem "noScopeRoles" false) (mem "SummaryFailure" false))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "contains" false) (mem "dedup" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "isSome" false) (mem "joinWith" false) (mem "listLen" false) (mem "lookupAssoc" false) (mem "reverseL" false))))
(DUse false (UseGroup ("list") ((mem "findMap" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "ifaceWordOf" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "mapChildren" false) (mem "mapExpr" false))))
(DUse false (UseGroup ("types" "effect_values") ((mem "producedInputTypes" false))))
(DUse false (UseAlias ("types" "scopes") "Scopes"))
(DUse false (UseAlias ("types" "runtime_grants") "RuntimeGrants"))
(DUse false (UseAlias ("types" "effect_solver") "EffectSolver"))
(DUse false (UseAlias ("map") "IdMap"))
(DUse false (UseGroup ("types" "scopes") ((mem "ScopeOwner" true))))
(DTypeSig false "effectSiteOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "Authority")) (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "effectSiteOf" ((PVar "mctx") PWild (PCon "None") PWild) (EVar "None"))
(DFunDef false "effectSiteOf" ((PVar "mctx") (PVar "fn") (PCon "Some" (PVar "label")) (PVar "bound")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EApp (EVar "effectSiteKey") (EVar "fn")) (EVar "label"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "effectSitesRef") "value")) (arm (PCon "Some" (PVar "sites")) () (EBlock (DoLet false false (PVar "ordered") (EApp (EVar "reverseL") (EVar "sites"))) (DoLet false false (PVar "offending") (EMatch (EVar "bound") (arm (PCon "Some" (PVar "hi")) () (EApp (EApp (EVar "filterList") (ELam ((PVar "site")) (EApp (EVar "not") (EApp (EApp (EVar "authSub") (EApp (EVar "fst") (EVar "site"))) (EVar "hi"))))) (EVar "ordered"))) (arm (PCon "None") () (EListLit)))) (DoExpr (EMatch (EBinOp "++" (EVar "offending") (EVar "ordered")) (arm (PCons (PVar "site") PWild) () (EApp (EVar "snd") (EVar "site"))) (arm (PList) () (EVar "None")))))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig true "beginEffectSummaryScope" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "Unit"))))
(DFunDef false "beginEffectSummaryScope" ((PVar "mctx") PWild) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fileValueScopes")) (EBinOp "::" (EApp (EVar "wSnapshot") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fileValueFlows")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fileValueScopes") "value")))) (DoExpr (EApp (EApp (EApp (EVar "EffectSolver.openSummaryScope") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "effectSummaries")) (EApp (EApp (EVar "newEffvarId") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")))))
(DTypeSig true "freshEffectSummary" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "EffRow"))))
(DFunDef false "freshEffectSummary" ((PVar "mctx") PWild) (EApp (EApp (EVar "EffectSolver.newSummary") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "effectSummaries")) (EApp (EApp (EVar "newEffvarId") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))))
(DTypeSig true "recordEffectBody" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Unit")))))
(DFunDef false "recordEffectBody" ((PVar "mctx") (PVar "summary") (PVar "lower")) (EApp (EApp (EApp (EVar "EffectSolver.recordBodyLower") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "effectSummaries")) (EVar "summary")) (EVar "lower")))
(DTypeSig false "summaryEscape" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))))
(DFunDef false "summaryEscape" ((PVar "gctx") (PCon "True") (PVar "lower") (PVar "upper")) (EApp (EApp (EVar "atomsDiff") (EVar "lower")) (EVar "upper")))
(DFunDef false "summaryEscape" ((PVar "gctx") (PCon "False") (PVar "lower") (PVar "upper")) (EApp (EApp (EApp (EVar "atomsEscape") (EVar "gctx")) (EVar "lower")) (EVar "upper")))
(DTypeSig false "finishEffectSummaryScope" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyCon "Unit")))))
(DFunDef false "finishEffectSummaryScope" ((PVar "mctx") (PVar "retained") (PVar "borrowed")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "finishEffectSummaryScopeKeeping") (EVar "mctx")) (EVar "noScopeRoles")) (EVar "retained")) (EVar "borrowed"))) (DoExpr (ELit LUnit))))
(DTypeSig true "finishEffectSummaryScopeKeeping" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ScopeRoles") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "AuthResidual"))))))))
(DFunDef false "finishEffectSummaryScopeKeeping" ((PVar "mctx") (PVar "roles") (PVar "retained") (PVar "borrowed")) (EBlock (DoLet false false (PVar "outcome") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "EffectSolver.closeSummaryScope") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "effectSummaries")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "rigidEffvarsRef") "value")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "rigidAuthvarsRef") "value")) (EVar "roles")) (EVar "retained")) (EVar "borrowed")) (EApp (EVar "summaryEscape") (EFieldAccess (EVar "mctx") "mcGraph"))) (EApp (EVar "joinCellOf") (EFieldAccess (EVar "mctx") "mcGraph"))) (EApp (EVar "freshEffvarAt") (EFieldAccess (EVar "mctx") "mcGraph"))) (EApp (EVar "widenOpenedFor") (EVar "mctx")))) (DoExpr (EApp (EApp (EVar "reportEffectSummaryFailures") (EVar "mctx")) (EFieldAccess (EVar "outcome") "esoFailures"))) (DoExpr (EApp (EApp (EVar "finishFileValueScope") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "member") (PVar "w"))) (ETuple (EVar "member") (ERecordCreate "AuthResidual" ((fa "arLower" (EFieldAccess (EVar "w") "awLower")) (fa "arUpper" (EFieldAccess (EVar "w") "awUpper")) (fa "arExact" (EFieldAccess (EVar "w") "awExact"))))))) (EFieldAccess (EVar "outcome") "esoResiduals")))))
(DTypeSig true "reportEffectSummaryFailures" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "SummaryFailure") (TyCon "ObligationSite"))) (TyCon "Unit"))))
(DFunDef false "reportEffectSummaryFailures" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "reportEffectSummaryFailures" ((PVar "outer") (PCons (PVar "failure") (PVar "rest"))) (EBlock (DoLet false false (PVar "fn") (EFieldAccess (EFieldAccess (EVar "failure") "esfContext") "osFn")) (DoLet false false (PVar "mctx") (EApp (EApp (EVar "mctxAt") (EApp (EApp (EVar "orElseLoc") (EApp (EApp (EApp (EApp (EVar "effectSiteOf") (EVar "outer")) (EVar "fn")) (EFieldAccess (EVar "failure") "esfLabel")) (EApp (EVar "failureBound") (EVar "failure")))) (EFieldAccess (EFieldAccess (EVar "failure") "esfContext") "osLoc"))) (EVar "outer"))) (DoExpr (EMatch (EFieldAccess (EVar "failure") "esfAuthority") (arm (PCon "Some" (PTuple (PVar "lo") (PVar "hi"))) () (EIf (EBinOp "||" (EApp (EApp (EVar "mentionsEscaped") (EVar "mctx")) (EVar "lo")) (EApp (EApp (EVar "mentionsEscaped") (EVar "mctx")) (EVar "hi"))) (ELit LUnit) (EIf (EFieldAccess (EVar "failure") "esfExact") (EApp (EApp (EApp (EApp (EApp (EVar "reportIndexFailure") (EVar "mctx")) (EFieldAccess (EFieldAccess (EVar "failure") "esfContext") "osCovering")) (EFieldAccess (EVar "mctx") "mcLoc")) (EVar "lo")) (EVar "hi")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (ELit (LString "T-AUTHORITY"))) (EFieldAccess (EVar "mctx") "mcLoc")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "authorityFailureMsg") (EVar "mctx")) (EVar "fn")) (EFieldAccess (EVar "failure") "esfLabel")) (EFieldAccess (EVar "failure") "esfResidualOf")) (EVar "lo")) (EVar "hi")) (EFieldAccess (EVar "failure") "esfWrittenUpper")))))) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "rowFailureReportedRef")) (EApp (EApp (EApp (EVar "omInsert") (EVar "fn")) (ELit LUnit)) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "rowFailureReportedRef") "value")))) (DoExpr (EApp (EApp (EVar "reportRowFailure") (EVar "mctx")) (EVar "failure"))))))) (DoExpr (EApp (EApp (EVar "reportEffectSummaryFailures") (EVar "outer")) (EVar "rest")))))
(DTypeSig false "failureBound" (TyFun (TyApp (TyCon "SummaryFailure") (TyCon "ObligationSite")) (TyApp (TyCon "Option") (TyCon "Authority"))))
(DFunDef false "failureBound" ((PVar "failure")) (EMatch (EFieldAccess (EVar "failure") "esfAuthority") (arm (PCon "Some" (PTuple PWild (PVar "hi"))) () (EApp (EVar "Some") (EVar "hi"))) (arm (PCon "None") () (EMatch (EFieldAccess (EVar "failure") "esfLabel") (arm (PCon "Some" (PVar "label")) () (EApp (EApp (EMethodRef "map") (EVar "atomAuth")) (EApp (EApp (EVar "findAtom") (EVar "label")) (EApp (EVar "fst") (EApp (EVar "rowFlat") (EFieldAccess (EVar "failure") "esfUpper")))))) (arm (PCon "None") () (EVar "None"))))))
(DTypeSig false "reportRowFailure" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "SummaryFailure") (TyCon "ObligationSite")) (TyCon "Unit"))))
(DFunDef false "reportRowFailure" ((PVar "mctx") (PVar "failure")) (EBlock (DoLet false false (PTuple (PVar "upper") (PVar "upperCells")) (EApp (EVar "rowFlat") (EFieldAccess (EVar "failure") "esfUpper"))) (DoLet false false (PVar "escaping") (EApp (EApp (EApp (EVar "atomsEscape") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EVar "fst") (EApp (EVar "rowFlat") (EFieldAccess (EVar "failure") "esfLower")))) (EVar "upper"))) (DoExpr (EIf (EFieldAccess (EVar "failure") "esfExact") (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EApp (EVar "ppEachShared") (EApp (EVar "Ref") (EListLit))) (EApp (EVar "Ref") (ELit (LInt 0)))) (EListLit (EApp (EVar "TEff") (EFieldAccess (EVar "failure") "esfLower")) (EApp (EVar "TEff") (EFieldAccess (EVar "failure") "esfUpper"))))) (DoExpr (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-EFFECT-INDEX-MISMATCH"))) (EBinOp "++" (EBinOp "++" (ELit (LString "effect index mismatch: ")) (EApp (EApp (EVar "joinWith") (ELit (LString " vs "))) (EVar "rows"))) (ELit (LString "; an effect row in a type argument is invariant, so write the same row on both sides")))))) (EIf (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "escaping")) (EApp (EVar "isEmptyL") (EVar "upperCells"))) (EApp (EApp (EApp (EVar "effectLeakCheck") (EVar "mctx")) (EVar "escaping")) (EVar "upper")) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-EFFECT-LAUNDER"))) (EApp (EApp (EApp (EVar "effectInclusionMsg") (EFieldAccess (EFieldAccess (EVar "failure") "esfContext") "osFn")) (EVar "escaping")) (EApp (EApp (EApp (EVar "ppEachShared") (EApp (EVar "Ref") (EListLit))) (EApp (EVar "Ref") (ELit (LInt 0)))) (EListLit (EApp (EVar "TEff") (EFieldAccess (EVar "failure") "esfLower")) (EApp (EVar "TEff") (EFieldAccess (EVar "failure") "esfUpper"))))))))) (DoExpr (ELit LUnit))))
(DTypeSig true "borrowedEffectCells" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar")))))))
(DFunDef false "borrowedEffectCells" ((PVar "mctx") (PVar "mono") (PVar "cells")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "input")) (EApp (EApp (EVar "effectCells") (EVar "input")) (EVar "acc")))) (EVar "cells")) (EApp (EApp (EVar "producedInputTypes") (EApp (EVar "producedSlotCovariants") (EVar "mctx"))) (EVar "mono"))))
(DTypeSig true "beginEffectContract" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "EffRow") (TyFun (TyCon "Mono") (TyTuple (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))))
(DFunDef false "beginEffectContract" ((PVar "mctx") (PVar "force") (PVar "value")) (EBlock (DoLet false false (PVar "saved") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "rigidEffvarsRef") "value")) (DoLet false false (PVar "savedAuths") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "rigidAuthvarsRef") "value")) (DoExpr (EApp (EApp (EVar "beginEffectSummaryScope") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "rigidEffvarsRef")) (EApp (EApp (EVar "effectRoots") (EVar "value")) (EApp (EApp (EVar "effectRowRoots") (EVar "force")) (EVar "saved"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "rigidAuthvarsRef")) (EApp (EApp (EVar "authRoots") (EVar "value")) (EApp (EApp (EVar "authRowRoots") (EVar "force")) (EVar "savedAuths"))))) (DoExpr (ETuple (EVar "saved") (EVar "savedAuths")))))
(DTypeSig true "finishEffectContract" (TyFun (TyCon "DynCtx") (TyFun (TyTuple (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))) (TyCon "Unit"))))
(DFunDef false "finishEffectContract" ((PVar "dyn") (PTuple (PVar "saved") (PVar "savedAuths"))) (EBlock (DoExpr (EApp (EApp (EVar "resolvePendingJoins") (EVar "dyn")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "currentLevel") "value"))) (DoExpr (EApp (EApp (EApp (EVar "finishEffectSummaryScope") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "Tip")) (EVar "Tip"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "rigidEffvarsRef")) (EVar "saved"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "rigidAuthvarsRef")) (EVar "savedAuths")))))
(DTypeSig true "checkUndeterminedRetEffVars" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "checkUndeterminedRetEffVars" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "checkUndeterminedRetEffVars" ((PVar "mctx") (PCons (PVar "d") (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EVar "checkUndeterminedRetEffVarsDecl") (EVar "mctx")) (EVar "d"))) (DoExpr (EApp (EApp (EVar "checkUndeterminedRetEffVars") (EVar "mctx")) (EVar "rest")))))
(DTypeSig false "checkUndeterminedRetEffVarsDecl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Decl") (TyCon "Unit"))))
(DFunDef false "checkUndeterminedRetEffVarsDecl" ((PVar "mctx") (PRec "DInterface" ((rf "name" None) (rf "typarams" None) (rf "typaramKinds" None) (rf "methods" None)) true)) (EApp (EApp (EApp (EApp (EVar "checkIfaceMethodEffs") (EVar "mctx")) (EVar "name")) (EApp (EApp (EApp (EApp (EVar "declGradedScope") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "typarams")) (EVar "typaramKinds")) (EVar "methods"))) (EVar "methods")))
(DFunDef false "checkUndeterminedRetEffVarsDecl" ((PVar "mctx") (PCon "DTypeSig" PWild (PVar "n") (PVar "t") PWild)) (EApp (EApp (EApp (EApp (EApp (EVar "checkArgEffVarCoverage") (EVar "mctx")) (EVar "None")) (EListLit)) (EVar "n")) (EVar "t")))
(DFunDef false "checkUndeterminedRetEffVarsDecl" ((PVar "mctx") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "checkUndeterminedRetEffVarsDecl") (EVar "mctx")) (EVar "d")))
(DFunDef false "checkUndeterminedRetEffVarsDecl" ((PVar "mctx") PWild) (ELit LUnit))
(DTypeSig false "checkIfaceMethodEffs" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyCon "Unit"))))))
(DFunDef false "checkIfaceMethodEffs" ((PVar "mctx") PWild PWild (PList)) (ELit LUnit))
(DFunDef false "checkIfaceMethodEffs" ((PVar "mctx") (PVar "iface") (PVar "scope") (PCons (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild PWild) (PVar "rest"))) (EBlock (DoExpr (EMatch (EApp (EApp (EApp (EVar "undeterminedRetEffVars") (EVar "mctx")) (EVar "scope")) (EVar "mty")) (arm (PList) () (ELit LUnit)) (arm (PVar "bad") () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-EFFECT-UNDETERMINED"))) (EApp (EVar "firstTyLoc") (EVar "mty"))) (EApp (EApp (EApp (EVar "effectUndeterminedMsg") (EVar "iface")) (EVar "mname")) (EVar "bad")))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "checkArgEffVarCoverage") (EVar "mctx")) (EApp (EVar "Some") (EVar "iface"))) (EVar "scope")) (EVar "mname")) (EVar "mty"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkIfaceMethodEffs") (EVar "mctx")) (EVar "iface")) (EVar "scope")) (EVar "rest")))))
(DTypeSig false "checkArgEffVarCoverage" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyCon "Unit")))))))
(DFunDef false "checkArgEffVarCoverage" ((PVar "mctx") (PVar "iface") (PVar "scope") (PVar "mname") (PVar "mty")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkArgEffVars") (EVar "mctx")) (EVar "iface")) (EVar "mname")) (EVar "mty")) (EApp (EApp (EApp (EVar "methodEffArgOccs") (EVar "mctx")) (EVar "scope")) (EVar "mty"))) (EApp (EApp (EApp (EVar "methodEffRetOccs") (EVar "mctx")) (EVar "scope")) (EVar "mty"))) (EApp (EVar "dedup") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EApp (EVar "methodEffArgOccs") (EVar "mctx")) (EVar "scope")) (EVar "mty"))))))
(DTypeSig false "checkArgEffVars" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit")))))))))
(DFunDef false "checkArgEffVars" ((PVar "mctx") PWild PWild PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "checkArgEffVars" ((PVar "mctx") (PVar "iface") (PVar "mname") (PVar "mty") (PVar "argOccs") (PVar "retOccs") (PCons (PVar "v") (PVar "rest"))) (EBlock (DoLet false false (PVar "vrets") (EApp (EApp (EVar "filterList") (ELam ((PVar "o")) (EBinOp "==" (EApp (EVar "fst") (EVar "o")) (EVar "v")))) (EVar "retOccs"))) (DoLet false false (PVar "vatoms") (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EApp (EApp (EVar "filterList") (ELam ((PVar "o")) (EBinOp "==" (EApp (EVar "fst") (EVar "o")) (EVar "v")))) (EVar "argOccs")))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "vrets")) (EMatch (EVar "iface") (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-EFFECT-ARG-UNCOVERED"))) (EApp (EVar "firstTyLoc") (EVar "mty"))) (EApp (EApp (EApp (EVar "argOnlyEffVarMsg") (EVar "i")) (EVar "mname")) (EVar "v")))) (arm (PCon "None") () (ELit LUnit))) (EMatch (EApp (EApp (EApp (EVar "retOccsEscape") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "vatoms")) (EVar "vrets")) (arm (PList) () (ELit LUnit)) (arm (PVar "esc") () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-EFFECT-ARG-UNCOVERED"))) (EApp (EVar "firstTyLoc") (EVar "mty"))) (EApp (EApp (EApp (EApp (EVar "argAtomsMsgFor") (EVar "iface")) (EVar "mname")) (EVar "v")) (EVar "esc"))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkArgEffVars") (EVar "mctx")) (EVar "iface")) (EVar "mname")) (EVar "mty")) (EVar "argOccs")) (EVar "retOccs")) (EVar "rest")))))
(DTypeSig false "retOccsEscape" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))) (TyApp (TyCon "List") (TyCon "Atom"))))))
(DFunDef false "retOccsEscape" ((PVar "gctx") PWild (PList)) (EListLit))
(DFunDef false "retOccsEscape" ((PVar "gctx") (PVar "vatoms") (PCons (PTuple PWild (PVar "declAtoms")) (PVar "rest"))) (EIf (EApp (EVar "isNonEmptyL") (EApp (EApp (EApp (EVar "atomsEscape") (EVar "gctx")) (EVar "vatoms")) (EVar "declAtoms"))) (EApp (EApp (EApp (EVar "atomsEscape") (EVar "gctx")) (EVar "vatoms")) (EVar "declAtoms")) (EApp (EApp (EApp (EVar "retOccsEscape") (EVar "gctx")) (EVar "vatoms")) (EVar "rest"))))
(DTypeSig false "methodEffArgOccs" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom"))))))))
(DFunDef false "methodEffArgOccs" ((PVar "mctx") (PVar "scope") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EApp (EVar "methodEffArgOccs") (EVar "mctx")) (EVar "scope")) (EVar "t")))
(DFunDef false "methodEffArgOccs" ((PVar "mctx") (PVar "scope") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EApp (EVar "methodEffArgOccs") (EVar "mctx")) (EVar "scope")) (EVar "t")))
(DFunDef false "methodEffArgOccs" ((PVar "mctx") (PVar "scope") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "argPerformableOccs") (EVar "mctx")) (EVar "scope")) (EVar "True")) (EVar "a")) (EApp (EApp (EApp (EVar "methodEffArgOccs") (EVar "mctx")) (EVar "scope")) (EVar "b"))))
(DFunDef false "methodEffArgOccs" ((PVar "mctx") PWild PWild) (EListLit))
(DTypeSig false "occsOfTails" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom"))))))))
(DFunDef false "occsOfTails" ((PVar "gctx") (PVar "tails") (PVar "labels")) (EBlock (DoLet false false (PVar "atoms") (EApp (EApp (EVar "atomsOfWritten") (EVar "gctx")) (EVar "labels"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EVar "atoms")))) (EVar "tails")))))
(DTypeSig false "argPerformableOccs" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "Bool") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))))))))
(DFunDef false "argPerformableOccs" ((PVar "mctx") (PVar "scope") (PVar "perf") (PCon "TyEffect" (PVar "labels") (PVar "tails") (PVar "t"))) (EBinOp "++" (EIf (EVar "perf") (EApp (EApp (EApp (EVar "occsOfTails") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "tails")) (EVar "labels")) (EListLit)) (EApp (EApp (EApp (EApp (EVar "argPerformableOccs") (EVar "mctx")) (EVar "scope")) (EVar "perf")) (EVar "t"))))
(DFunDef false "argPerformableOccs" ((PVar "mctx") PWild (PVar "perf") (PCon "TyRow" (PVar "labels") (PVar "tails") PWild)) (EIf (EVar "perf") (EApp (EApp (EApp (EVar "occsOfTails") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "tails")) (EVar "labels")) (EListLit)))
(DFunDef false "argPerformableOccs" ((PVar "mctx") (PVar "scope") (PVar "perf") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "argPerformableOccs") (EVar "mctx")) (EVar "scope")) (EApp (EVar "not") (EVar "perf"))) (EVar "a")) (EApp (EApp (EApp (EApp (EVar "argPerformableOccs") (EVar "mctx")) (EVar "scope")) (EVar "perf")) (EVar "b"))))
(DFunDef false "argPerformableOccs" ((PVar "mctx") (PVar "scope") (PVar "perf") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "argPerformableOccs") (EVar "mctx")) (EVar "scope")) (EVar "perf"))) (EVar "ts")))
(DFunDef false "argPerformableOccs" ((PVar "mctx") (PVar "scope") (PVar "perf") (PCon "TyApp" (PVar "a") (PVar "b"))) (EMatch (EApp (EVar "tyAppSpine") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b"))) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false) (PVar "args")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "krowSlotOccs") (EVar "mctx")) (EVar "scope")) (EVar "perf")) (EVar "o")) (EVar "n")) (EVar "args"))) (arm (PTuple (PCon "TyVar" (PVar "h")) (PVar "args")) () (EApp (EApp (EApp (EApp (EApp (EVar "krowSlotVarOccs") (EVar "mctx")) (EVar "scope")) (EVar "perf")) (EVar "h")) (EVar "args"))) (arm PWild () (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "argPerformableOccs") (EVar "mctx")) (EVar "scope")) (EVar "perf")) (EVar "a")) (EApp (EApp (EApp (EApp (EVar "argPerformableOccs") (EVar "mctx")) (EVar "scope")) (EVar "perf")) (EVar "b"))))))
(DFunDef false "argPerformableOccs" ((PVar "mctx") (PVar "scope") (PVar "perf") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EApp (EApp (EVar "argPerformableOccs") (EVar "mctx")) (EVar "scope")) (EVar "perf")) (EVar "t")))
(DFunDef false "argPerformableOccs" ((PVar "mctx") PWild PWild PWild) (EListLit))
(DTypeSig false "krowSlotOccs" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "Bool") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))))))))))
(DFunDef false "krowSlotOccs" ((PVar "mctx") (PVar "scope") (PVar "perf") (PVar "o") (PVar "n") (PVar "args")) (EMatch (EApp (EApp (EVar "lookupTab") (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamKindsRef") "value")) (arm (PCon "Some" (PVar "kinds")) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EVar "kinds")) (EApp (EVar "listLen") (EVar "args"))))) (EBinOp "++" (EIf (EVar "perf") (EApp (EApp (EApp (EApp (EVar "krowArgVarAtoms") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "kinds")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "paramRowAtomsOf") (EVar "mctx")) (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n"))))) (EVar "args")) (EListLit)) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "argPerformableOccs") (EVar "mctx")) (EVar "scope")) (EVar "perf"))) (EVar "args")))) (arm PWild () (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "argPerformableOccs") (EVar "mctx")) (EVar "scope")) (EVar "perf"))) (EVar "args")))))
(DTypeSig false "krowSlotVarOccs" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom"))))))))))
(DFunDef false "krowSlotVarOccs" ((PVar "mctx") (PVar "scope") (PVar "perf") (PVar "h") (PVar "args")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "h")) (EVar "scope")) (arm (PCon "Some" (PVar "kinds")) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EVar "kinds")) (EApp (EVar "listLen") (EVar "args"))))) (EBinOp "++" (EIf (EVar "perf") (EApp (EApp (EApp (EApp (EVar "krowArgVarAtoms") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "kinds")) (EListLit)) (EVar "args")) (EListLit)) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "argPerformableOccs") (EVar "mctx")) (EVar "scope")) (EVar "perf"))) (EVar "args")))) (arm PWild () (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "argPerformableOccs") (EVar "mctx")) (EVar "scope")) (EVar "perf"))) (EVar "args")))))
(DTypeSig false "methodEffRetOccs" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom"))))))))
(DFunDef false "methodEffRetOccs" ((PVar "mctx") (PVar "scope") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EApp (EVar "methodEffRetOccs") (EVar "mctx")) (EVar "scope")) (EVar "t")))
(DFunDef false "methodEffRetOccs" ((PVar "mctx") (PVar "scope") (PCon "TyEffect" (PVar "labels") (PVar "tails") (PVar "t"))) (EBinOp "++" (EApp (EApp (EApp (EVar "occsOfTails") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "tails")) (EVar "labels")) (EApp (EApp (EApp (EVar "methodEffRetOccs") (EVar "mctx")) (EVar "scope")) (EVar "t"))))
(DFunDef false "methodEffRetOccs" ((PVar "mctx") (PVar "scope") (PCon "TyFun" PWild (PVar "b"))) (EApp (EApp (EApp (EVar "methodEffRetOccs") (EVar "mctx")) (EVar "scope")) (EVar "b")))
(DFunDef false "methodEffRetOccs" ((PVar "mctx") (PVar "scope") (PVar "t")) (EBlock (DoLet false false (PVar "occs") (EApp (EApp (EVar "effVarOccAtoms") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "t"))) (DoExpr (EBinOp "++" (EVar "occs") (EApp (EApp (EVar "filterList") (ELam ((PVar "o2")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "o")) (EBinOp "==" (EApp (EVar "fst") (EVar "o")) (EApp (EVar "fst") (EVar "o2"))))) (EVar "occs"))))) (EApp (EApp (EApp (EVar "rowArgAtomsIn") (EVar "mctx")) (EVar "scope")) (EVar "t")))))))
(DTypeSig false "undeterminedRetEffVars" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "undeterminedRetEffVars" ((PVar "mctx") (PVar "scope") (PVar "sig")) (EBlock (DoLet false false (PVar "args") (EApp (EVar "methodArgs") (EVar "sig"))) (DoLet false false (PVar "argCarried") (EApp (EVar "dedup") (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "effTailNames")) (EVar "args")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "rowArgNamesIn") (EVar "mctx")) (EVar "scope"))) (EVar "args"))))) (DoLet false false (PVar "retTail") (EApp (EVar "dedup") (EApp (EVar "effTailNames") (EApp (EVar "methodRet") (EVar "sig"))))) (DoExpr (EApp (EApp (EVar "removeAllS") (EVar "argCarried")) (EVar "retTail")))))
(DTypeSig false "methodRet" (TyFun (TyCon "Ty") (TyCon "Ty")))
(DFunDef false "methodRet" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "methodRet") (EVar "t")))
(DFunDef false "methodRet" ((PCon "TyFun" PWild (PVar "b"))) (EApp (EVar "methodRet") (EVar "b")))
(DFunDef false "methodRet" ((PVar "t")) (EVar "t"))
(DTypeSig false "expandReturnSpine" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyCon "Ty"))))
(DFunDef false "expandReturnSpine" ((PVar "mctx") (PVar "ty")) (EMatch (EApp (EApp (EVar "expandAliasHeadTy") (EVar "mctx")) (EVar "ty")) (arm (PCon "TyFun" (PVar "a") (PVar "ret")) () (EApp (EApp (EVar "TyFun") (EVar "a")) (EApp (EApp (EVar "expandReturnSpine") (EVar "mctx")) (EVar "ret")))) (arm (PCon "TyConstrained" (PVar "cs") (PVar "t")) () (EApp (EApp (EVar "TyConstrained") (EVar "cs")) (EApp (EApp (EVar "expandReturnSpine") (EVar "mctx")) (EVar "t")))) (arm (PAs "row" (PCon "TyEffect" PWild PWild PWild)) () (EVar "row")) (arm PWild () (EVar "ty"))))
(DTypeSig false "declaredEffects" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "declaredEffects" ((PVar "gctx") (PCon "TyFun" PWild (PVar "ret"))) (EApp (EApp (EVar "declaredEffects") (EVar "gctx")) (EVar "ret")))
(DFunDef false "declaredEffects" ((PVar "gctx") (PCon "TyEffect" (PVar "effs") PWild PWild)) (EApp (EApp (EVar "atomsOfWritten") (EVar "gctx")) (EVar "effs")))
(DFunDef false "declaredEffects" ((PVar "gctx") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EVar "declaredEffects") (EVar "gctx")) (EVar "t")))
(DFunDef false "declaredEffects" ((PVar "gctx") PWild) (EListLit))
(DTypeSig false "declaredEffectTail" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declaredEffectTail" ((PCon "TyFun" PWild (PVar "ret"))) (EApp (EVar "declaredEffectTail") (EVar "ret")))
(DFunDef false "declaredEffectTail" ((PCon "TyEffect" PWild (PVar "tail") PWild)) (EVar "tail"))
(DFunDef false "declaredEffectTail" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "declaredEffectTail") (EVar "t")))
(DFunDef false "declaredEffectTail" (PWild) (EListLit))
(DTypeSig false "declaredArgEffNames" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "declaredArgEffNames" ((PVar "mctx") (PCon "TyFun" (PVar "a") (PVar "ret"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "effTailNames") (EVar "a")) (EApp (EApp (EVar "rowArgNames") (EVar "mctx")) (EVar "a"))) (EApp (EApp (EVar "declaredArgEffNames") (EVar "mctx")) (EVar "ret"))))
(DFunDef false "declaredArgEffNames" ((PVar "mctx") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EVar "declaredArgEffNames") (EVar "mctx")) (EVar "t")))
(DFunDef false "declaredArgEffNames" ((PVar "mctx") PWild) (EListLit))
(DTypeSig false "declaredEffectsOpen" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyCon "Bool"))))
(DFunDef false "declaredEffectsOpen" ((PVar "mctx") (PVar "ty")) (EBlock (DoLet false false (PVar "argNames") (EApp (EApp (EVar "declaredArgEffNames") (EVar "mctx")) (EVar "ty"))) (DoExpr (EApp (EApp (EVar "anyList") (ELam ((PVar "v")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "v")) (EVar "argNames"))))) (EApp (EVar "declaredEffectTail") (EVar "ty"))))))
(DTypeSig true "evOrdinal" (TyFun (TyCon "EvId") (TyCon "Int")))
(DFunDef false "evOrdinal" ((PCon "EvId" PWild (PVar "i"))) (EVar "i"))
(DTypeSig false "mentionsEscaped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Authority") (TyCon "Bool"))))
(DFunDef false "mentionsEscaped" ((PVar "mctx") (PVar "q")) (EApp (EApp (EVar "anyList") (ELam ((PVar "cell")) (EApp (EApp (EVar "IdMap.has") (EApp (EVar "authvarId") (EVar "cell"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "escapedExistentialsRef") "value")))) (EApp (EVar "authVars") (EVar "q"))))
(DTypeSig true "registerLocalAbsIf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "ScopeId")) (TyFun (TyCon "Scheme") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Unit"))))))))
(DFunDef false "registerLocalAbsIf" ((PVar "mctx") (PVar "name") (PVar "lscope") (PVar "sch") (PVar "oblN0") (PVar "callN0")) (EBlock (DoExpr (EApp (EApp (EVar "recordLocalQuantified") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "sch"))) (DoExpr (EMatch (EVar "lscope") (arm (PCon "Some" (PVar "scope")) () (EBlock (DoExpr (EApp (EApp (EApp (EVar "registerLocalGrants") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "name")) (EVar "sch"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerLocalAbs") (EVar "mctx")) (EVar "name")) (EVar "scope")) (EVar "sch")) (EVar "oblN0")) (EVar "callN0"))))) (arm (PCon "None") () (ELit LUnit))))))
(DTypeSig false "recordLocalQuantified" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Scheme") (TyCon "Unit"))))
(DFunDef false "recordLocalQuantified" ((PVar "gctx") (PVar "sch")) (EMatch (EApp (EVar "schemeIds") (EVar "sch")) (arm (PList) () (ELit LUnit)) (arm (PVar "ids") () (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "localAbs")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "lasQuantified")) (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (EVar "intToString")) (EVar "ids"))) (EFieldAccess (EFieldAccess (EVar "st") "lasQuantified") "value"))))))))
(DTypeSig true "fileGrantExterns" (TyApp (TyCon "OrdMap") (TyTuple (TyCon "Int") (TyCon "Int"))))
(DFunDef false "fileGrantExterns" () (EVar "RuntimeGrants.fileGrantExterns"))
(DTypeSig false "grantsEnabled" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyCon "Bool"))))
(DFunDef false "grantsEnabled" ((PVar "gctx") PWild) (EApp (EVar "isSome") (EFieldAccess (EFieldAccess (EVar "gctx") "markSetsRef") "value")))
(DTypeSig false "grantCalleeOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "GrantCallee"))))
(DFunDef false "grantCalleeOf" ((PVar "mctx") (PVar "name")) (EIf (EApp (EVar "isLocalAbsName") (EVar "name")) (EVar "SourceCallee") (EIf (EVar "otherwise") (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "markingRef") "value") (arm (PCon "Some" (PVar "mm")) () (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "mm") "mmExterns")) (EApp (EVar "externCallee") (EVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "mm") "mmUserNames")) (EVar "SourceCallee") (EApp (EApp (EVar "catalogCallee") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "name"))))) (arm (PCon "None") () (EApp (EApp (EVar "catalogCallee") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "name")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "catalogCallee" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyCon "GrantCallee"))))
(DFunDef false "catalogCallee" ((PVar "gctx") (PVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EFieldAccess (EVar "gctx") "builtinExternNamesRef") "value")) (EApp (EVar "externCallee") (EVar "name")) (EVar "SourceCallee")))
(DTypeSig false "externCallee" (TyFun (TyCon "String") (TyCon "GrantCallee")))
(DFunDef false "externCallee" ((PVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "fileGrantExterns")) (EVar "FileExternCallee") (EVar "NoGrantCallee")))
(DTypeSig true "grantNameIn" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "grantNameIn" ((PVar "env") (PVar "n")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "grantsEnabled") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (EVar "False") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "lookupBinding") (EVar "env")) (EVar "n")) (arm (PCon "Some" (PVar "b")) () (EMatch (EFieldAccess (EVar "b") "ebMethodRow") (arm (PCon "Some" PWild) () (EVar "False")) (arm (PCon "None") () (EBinOp "&&" (EApp (EVar "calleeTakesGrants") (EApp (EApp (EVar "grantCalleeOf") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "n"))) (EApp (EVar "isNonEmptyL") (EApp (EVar "schemeAuthIds") (EFieldAccess (EFieldAccess (EVar "b") "ebValue") "vsScheme"))))))) (arm (PCon "None") () (EVar "False"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "calleeTakesGrants" (TyFun (TyCon "GrantCallee") (TyCon "Bool")))
(DFunDef false "calleeTakesGrants" ((PCon "SourceCallee")) (EVar "True"))
(DFunDef false "calleeTakesGrants" ((PCon "FileExternCallee")) (EVar "True"))
(DFunDef false "calleeTakesGrants" ((PCon "NoGrantCallee")) (EVar "False"))
(DTypeSig true "grantOrder" (TyFun (TyCon "Scheme") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "grantOrder" ((PCon "Forall" PWild PWild (PList) PWild PWild PWild)) (EListLit))
(DFunDef false "grantOrder" ((PCon "Forall" PWild PWild (PVar "avars") PWild (PVar "force") (PVar "body"))) (EBlock (DoLet false false (PVar "seen") (EApp (EVar "reverseL") (EApp (EApp (EVar "authOrderRow") (EVar "force")) (EApp (EApp (EVar "authOrderIn") (EVar "body")) (EListLit))))) (DoLet false false (PVar "quantified") (EApp (EApp (EVar "filterList") (ELam ((PVar "i")) (EApp (EApp (EVar "containsI") (EVar "i")) (EVar "avars")))) (EVar "seen"))) (DoExpr (EBinOp "++" (EVar "quantified") (EApp (EApp (EVar "filterList") (ELam ((PVar "i")) (EApp (EVar "not") (EApp (EApp (EVar "containsI") (EVar "i")) (EVar "quantified"))))) (EVar "avars"))))))
(DTypeSig true "grantOccOf" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvId") (TyApp (TyCon "Option") (TyCon "GrantOcc")))))
(DFunDef false "grantOccOf" ((PVar "gctx") (PVar "ev")) (EApp (EApp (EVar "IdMap.get") (EApp (EVar "evOrdinal") (EVar "ev"))) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants") "gsOccs") "value")))
(DTypeSig false "setGrantOcc" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvId") (TyFun (TyCon "GrantOcc") (TyCon "Unit")))))
(DFunDef false "setGrantOcc" ((PVar "gctx") (PVar "ev") (PVar "occ")) (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsOccs")) (EApp (EApp (EApp (EVar "IdMap.set") (EApp (EVar "evOrdinal") (EVar "ev"))) (EVar "occ")) (EFieldAccess (EFieldAccess (EVar "st") "gsOccs") "value"))))))
(DTypeSig true "grantOnlyBindingId" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "grantOnlyBindingId" ((PVar "mctx") (PVar "name")) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "markingRef") "value") (arm (PCon "Some" (PVar "mm")) () (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "mm") "mmTop")))) (arm (PCon "None") () (ELit (LInt 0)))))
(DTypeSig true "recordGrantOcc" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyFun (TyCon "Scheme") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))) (TyCon "Unit")))))))
(DFunDef false "recordGrantOcc" ((PVar "mctx") (PVar "name") (PVar "ev") (PAs "scheme" (PCon "Forall" PWild PWild PWild PWild PWild (PVar "body"))) (PVar "subst")) (EMatch (EApp (EApp (EVar "grantCalleeOf") (EVar "mctx")) (EVar "name")) (arm (PCon "NoGrantCallee") () (ELit LUnit)) (arm (PCon "SourceCallee") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordOccWith") (EVar "mctx")) (EVar "name")) (EVar "ev")) (EVar "scheme")) (EVar "subst")) (EVar "None")) (EVar "False"))) (arm (PCon "FileExternCallee") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordOccWith") (EVar "mctx")) (EVar "name")) (EVar "ev")) (EVar "scheme")) (EVar "subst")) (EApp (EVar "Some") (EApp (EVar "arrowArity") (EVar "body")))) (EVar "False")))))
(DTypeSig true "recordMethodGrantOcc" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyFun (TyCon "Scheme") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))) (TyCon "Unit")))))))
(DFunDef false "recordMethodGrantOcc" ((PVar "mctx") (PVar "name") (PVar "ev") (PAs "scheme" (PCon "Forall" PWild PWild PWild PWild PWild (PVar "body"))) (PVar "subst")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordOccWith") (EVar "mctx")) (EVar "name")) (EVar "ev")) (EVar "scheme")) (EVar "subst")) (EApp (EVar "Some") (EApp (EVar "arrowArity") (EVar "body")))) (EVar "False")))
(DTypeSig true "recordStandaloneGrantOcc" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyFun (TyCon "Scheme") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))) (TyFun (TyCon "Int") (TyCon "Unit"))))))))
(DFunDef false "recordStandaloneGrantOcc" ((PVar "mctx") (PVar "name") (PVar "ev") (PVar "scheme") (PVar "subst") (PVar "arity")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordOccWith") (EVar "mctx")) (EVar "name")) (EVar "ev")) (EVar "scheme")) (EVar "subst")) (EApp (EVar "Some") (EVar "arity"))) (EVar "True")))
(DTypeSig false "recordOccWith" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyFun (TyCon "Scheme") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "Bool") (TyCon "Unit")))))))))
(DFunDef false "recordOccWith" ((PVar "mctx") (PVar "name") (PVar "ev") (PVar "scheme") (PVar "subst") (PVar "trailing") (PVar "standalone")) (EMatch (EApp (EVar "grantOrder") (EVar "scheme")) (arm (PList) () (ELit LUnit)) (arm (PVar "ids") () (EApp (EApp (EApp (EVar "setGrantOcc") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ev")) (ERecordCreate "GrantOcc" ((fa "goCallee" (EVar "name")) (fa "goCells" (EApp (EApp (EMethodRef "map") (ELam ((PVar "i")) (EApp (EApp (EVar "optionOr") (EApp (EVar "AJoin") (EListLit))) (EApp (EApp (EVar "lookupAssocI") (EVar "i")) (EVar "subst"))))) (EVar "ids"))) (fa "goRecIds" (EListLit)) (fa "goTrailing" (EVar "trailing")) (fa "goChain" (EApp (EApp (EVar "grantChainAt") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit)))) (fa "goStandalone" (EVar "standalone"))))))))
(DTypeSig true "spineHeadEv" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "EvId"))))
(DFunDef false "spineHeadEv" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "spineHeadEv") (EVar "e")))
(DFunDef false "spineHeadEv" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "spineHeadEv") (EVar "f")))
(DFunDef false "spineHeadEv" ((PCon "EMethodAt" PWild PWild (PVar "ev"))) (EApp (EVar "Some") (EVar "ev")))
(DFunDef false "spineHeadEv" (PWild) (EVar "None"))
(DTypeSig true "recordStandaloneAt" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "SelectedValueOccurrence") (TyCon "Unit"))))))
(DFunDef false "recordStandaloneAt" ((PVar "mctx") (PVar "name") (PVar "hd") (PVar "occurrence")) (EMatch (EApp (EVar "spineHeadEv") (EVar "hd")) (arm (PCon "Some" (PVar "ev")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordStandaloneGrantOcc") (EVar "mctx")) (EVar "name")) (EVar "ev")) (EFieldAccess (EVar "occurrence") "svoScheme")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "occurrence") "svoInstance") "mtiSubstitution") "misAuthSubst")) (EApp (EVar "funArity") (EFieldAccess (EFieldAccess (EVar "occurrence") "svoInstance") "mtiBody")))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig true "methodGrantOf" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "MethodGrant"))))))
(DFunDef false "methodGrantOf" ((PVar "gctx") (PVar "ifaceWord") (PVar "method")) (EApp (EApp (EVar "omLookup") (EApp (EApp (EVar "methodGrantKey") (EVar "ifaceWord")) (EVar "method"))) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants") "gsMethods") "value")))
(DTypeSig true "recordMethodGrants" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "MethodSchemeRow")) (TyCon "Unit"))))
(DFunDef false "recordMethodGrants" ((PVar "gctx") (PVar "rows")) (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsMethods")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "row")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "methodGrantKey") (EApp (EApp (EVar "ifaceWordOf") (EFieldAccess (EFieldAccess (EVar "row") "msrIface") "irOrigin")) (EFieldAccess (EFieldAccess (EVar "row") "msrIface") "irName"))) (EFieldAccess (EVar "row") "msrName"))) (DoExpr (EMatch (EApp (EVar "methodGrantOfRow") (EVar "row")) (arm (PCon "Some" (PVar "mg")) () (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "mg")) (EVar "acc"))) (arm (PCon "None") () (EApp (EApp (EVar "omDelete") (EVar "key")) (EVar "acc")))))))) (EFieldAccess (EFieldAccess (EVar "st") "gsMethods") "value")) (EVar "rows"))))))
(DTypeSig false "methodGrantOfRow" (TyFun (TyCon "MethodSchemeRow") (TyApp (TyCon "Option") (TyCon "MethodGrant"))))
(DFunDef false "methodGrantOfRow" ((PVar "row")) (EMatch (EFieldAccess (EVar "row") "msrScheme") (arm (PCon "Forall" PWild PWild PWild PWild (PVar "force") (PVar "body")) () (EMatch (EApp (EVar "grantOrder") (EFieldAccess (EVar "row") "msrScheme")) (arm (PList) () (EVar "None")) (arm (PVar "ids") () (EBlock (DoLet false false (PVar "cells") (EApp (EApp (EVar "authCellsIn") (EVar "body")) (EApp (EApp (EVar "authRowCells") (EVar "force")) (EVar "Tip")))) (DoExpr (EApp (EVar "Some") (ERecordCreate "MethodGrant" ((fa "mgArity" (EApp (EVar "tyArrowCount") (EFieldAccess (EVar "row") "msrType"))) (fa "mgNames" (EApp (EApp (EMethodRef "map") (ELam ((PVar "i")) (EMatch (EApp (EApp (EVar "IdMap.get") (EVar "i")) (EVar "cells")) (arm (PCon "Some" (PVar "cell")) () (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EVar "authvarName") (EVar "cell")))) (arm (PCon "None") () (ELit (LString "")))))) (EVar "ids")))))))))))))
(DTypeSig true "markSourceless" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Unit"))))
(DFunDef false "markSourceless" ((PVar "gctx") (PVar "ids")) (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsSourceless")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PVar "i")) (EApp (EApp (EApp (EVar "IdMap.set") (EVar "i")) (ELit LUnit)) (EVar "m")))) (EFieldAccess (EFieldAccess (EVar "st") "gsSourceless") "value")) (EVar "ids"))))))
(DTypeSig false "grantChainAt" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ScopeId") (TyApp (TyCon "List") (TyCon "GrantBinder")))))
(DFunDef false "grantChainAt" ((PVar "gctx") (PAs "sid" (PCon "ScopeId" (PVar "i")))) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EVar "Scopes.scopeFrame") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))) (EVar "sid"))) (DoLet false false (PVar "outer") (EMatch (EFieldAccess (EVar "frame") "sfParent") (arm (PCon "Some" (PVar "parent")) () (EApp (EApp (EVar "grantChainAt") (EVar "gctx")) (EVar "parent"))) (arm (PCon "None") () (EListLit)))) (DoLet false false (PVar "own") (EMatch (EFieldAccess (EVar "frame") "sfOwner") (arm (PCon "BindingOwner" (PVar "n")) () (EBinOp "::" (EApp (EApp (EVar "TopGrantBinder") (EFieldAccess (EVar "frame") "sfModuleId")) (EVar "n")) (EVar "outer"))) (arm (PCon "LocalBindingOwner" (PVar "n")) () (EBinOp "::" (EApp (EVar "LocalGrantBinder") (EVar "n")) (EVar "outer"))) (arm PWild () (EVar "outer")))) (DoExpr (EMatch (EApp (EApp (EVar "IdMap.get") (EVar "i")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants") "gsBodies") "value")) (arm (PCon "Some" (PVar "body")) () (EBinOp "::" (EVar "body") (EVar "own"))) (arm (PCon "None") () (EVar "own"))))))
(DTypeSig true "recordTopGrants" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyCon "Unit"))))))
(DFunDef false "recordTopGrants" ((PVar "gctx") (PVar "mid") (PVar "schemes") (PVar "grouped")) (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (DoLet false false (PVar "enabled") (EApp (EApp (EVar "grantsEnabled") (EVar "gctx")) (ELit LUnit))) (DoLet false false (PVar "granted") (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "n") (PVar "sch"))) (ETuple (EVar "n") (EIf (EVar "enabled") (EApp (EVar "grantOrder") (EVar "sch")) (EListLit))))) (EVar "schemes"))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PVar "e")) (EApp (EApp (EVar "setGrantIds") (EFieldAccess (EVar "st") "gsTopIds")) (ETuple (EApp (EApp (EVar "grantTopKey") (EVar "mid")) (EApp (EVar "fst") (EVar "e"))) (EApp (EVar "snd") (EVar "e")))))) (EVar "granted"))) (DoLet false false (PVar "taking") (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EVar "isNonEmptyL") (EApp (EVar "snd") (EVar "e"))))) (EVar "granted"))) (DoExpr (EMatch (EVar "taking") (arm (PList) () (ELit LUnit)) (arm PWild () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsTakers")) (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "taking"))) (EFieldAccess (EFieldAccess (EVar "st") "gsTakers") "value")))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PTuple (PVar "m") PWild)) (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "clause")) (EApp (EApp (EApp (EApp (EApp (EVar "recordRecursiveGrants") (EVar "gctx")) (EVar "mid")) (EVar "m")) (EVar "taking")) (EApp (EVar "snd") (EVar "clause"))))) (ELit LUnit)) (EApp (EApp (EVar "clausesOf") (EVar "m")) (EVar "grouped"))))) (ELit LUnit)) (EVar "schemes")))))))))
(DTypeSig false "recordRecursiveGrants" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyCon "Expr") (TyCon "Unit")))))))
(DFunDef false "recordRecursiveGrants" ((PVar "gctx") (PVar "mid") (PVar "m") (PVar "taking") (PVar "body")) (EBlock (DoLet false false (PVar "visit") (ELam ((PVar "e")) (EMatch (EVar "e") (arm (PCon "EDictAt" (PVar "n") (PVar "ev")) () (EMatch (ETuple (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "taking")) (EApp (EApp (EVar "grantOccOf") (EVar "gctx")) (EVar "ev"))) (arm (PTuple (PCon "Some" (PVar "ids")) (PCon "None")) () (EBlock (DoExpr (EApp (EApp (EApp (EVar "setGrantOcc") (EVar "gctx")) (EVar "ev")) (ERecordCreate "GrantOcc" ((fa "goCallee" (EVar "n")) (fa "goCells" (EListLit)) (fa "goRecIds" (EVar "ids")) (fa "goTrailing" (EVar "None")) (fa "goChain" (EListLit (EApp (EApp (EVar "TopGrantBinder") (EVar "mid")) (EVar "m")))) (fa "goStandalone" (EVar "False")))))) (DoExpr (EVar "e")))) (arm PWild () (EVar "e")))) (arm PWild () (EVar "e"))))) (DoLet false false PWild (EApp (EApp (EVar "mapExpr") (EVar "visit")) (EVar "body"))) (DoExpr (ELit LUnit))))
(DTypeSig false "registerLocalGrants" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "Scheme") (TyCon "Unit")))))
(DFunDef false "registerLocalGrants" ((PVar "gctx") (PVar "name") (PVar "sch")) (EMatch (EApp (EVar "grantOrder") (EVar "sch")) (arm (PList) () (ELit LUnit)) (arm (PVar "ids") () (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsLocalIds")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EVar "ids")) (EFieldAccess (EFieldAccess (EVar "st") "gsLocalIds") "value")))) (DoLet false false (PVar "recOccs") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "localAbs") "lasRecOccs") "value")))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "occ")) (EApp (EApp (EApp (EVar "setGrantOcc") (EVar "gctx")) (EApp (EVar "fst") (EVar "occ"))) (ERecordCreate "GrantOcc" ((fa "goCallee" (EVar "name")) (fa "goCells" (EListLit)) (fa "goRecIds" (EVar "ids")) (fa "goTrailing" (EVar "None")) (fa "goChain" (EApp (EApp (EVar "grantChainAt") (EVar "gctx")) (EApp (EVar "snd") (EVar "occ")))) (fa "goStandalone" (EVar "False"))))))) (ELit LUnit)) (EVar "recOccs")))))))
(DTypeSig true "appSpineArgCount" (TyFun (TyCon "Expr") (TyCon "Int")))
(DFunDef false "appSpineArgCount" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "appSpineArgCount") (EVar "e")))
(DFunDef false "appSpineArgCount" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "appSpineArgCount") (EVar "e")))
(DFunDef false "appSpineArgCount" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "appSpineArgCount") (EVar "e")))
(DFunDef false "appSpineArgCount" ((PCon "EApp" (PVar "f") PWild)) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "appSpineArgCount") (EVar "f"))))
(DFunDef false "appSpineArgCount" (PWild) (ELit (LInt 0)))
(DTypeSig true "notePerformSite" (TyFun (TyCon "TcEnv") (TyFun (TyCon "EffRow") (TyCon "Unit"))))
(DFunDef false "notePerformSite" ((PVar "env") (PVar "eff")) (EMatch (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcPerformSites") (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "sites")) () (EApp (EApp (EVar "setRef") (EVar "sites")) (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "cell")) (ETuple (EVar "cell") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")))) (EApp (EVar "snd") (EApp (EVar "rowFlat") (EVar "eff")))) (EFieldAccess (EVar "sites") "value"))))))
(DTypeSig true "markBinders" (TyFun (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyCon "Unit"))))
(DFunDef false "markBinders" ((PVar "table") (PVar "cells")) (EApp (EApp (EVar "setRef") (EVar "table")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PVar "c")) (EApp (EApp (EApp (EVar "IdMap.set") (EApp (EVar "authvarId") (EVar "c"))) (ELit LUnit)) (EVar "m")))) (EFieldAccess (EVar "table") "value")) (EVar "cells"))))
(DTypeSig true "collectProducedSummary" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "EffRow")) (TyCon "EffRow"))))
(DFunDef false "collectProducedSummary" ((PVar "mctx") (PVar "rows")) (EBlock (DoLet false false (PVar "summary") (EApp (EApp (EVar "freshEffectSummary") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PVar "row")) (EApp (EApp (EApp (EVar "recordEffectBody") (EVar "mctx")) (EVar "summary")) (EVar "row")))) (EVar "rows"))) (DoExpr (EVar "summary"))))
(DTypeSig true "registerLocalGroupAbs" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "LetBind") (TyApp (TyCon "Option") (TyCon "ScopeId")))) (TyCon "Unit"))))))
(DFunDef false "registerLocalGroupAbs" ((PVar "env") PWild PWild (PList)) (ELit LUnit))
(DFunDef false "registerLocalGroupAbs" ((PVar "genv") (PVar "oblN0") (PVar "callN0") (PCons (PTuple (PAs "bind" (PCon "LetBind" (PVar "name") PWild PWild PWild)) (PVar "lscope")) (PVar "rest"))) (EBlock (DoExpr (EMatch (EApp (EApp (EVar "lookupVar") (EVar "genv")) (EVar "name")) (arm (PCon "Some" (PVar "sch")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerLocalAbsIf") (EFieldAccess (EFieldAccess (EVar "genv") "teDyn") "dcModule")) (EVar "name")) (EVar "lscope")) (EVar "sch")) (EVar "oblN0")) (EVar "callN0"))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EApp (EApp (EApp (EApp (EVar "registerLocalGroupAbs") (EVar "genv")) (EVar "oblN0")) (EVar "callN0")) (EVar "rest")))))
(DTypeSig true "localBindingSummary" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "LetBind") (TyTuple (TyCon "String") (TyCon "BindingSummary")))))
(DFunDef false "localBindingSummary" ((PVar "mctx") (PCon "LetBind" (PVar "name") (PVar "clauses") PWild PWild)) (EBlock (DoLet false false (PVar "arity") (EMatch (EApp (EApp (EMethodRef "map") (EVar "funClausePair")) (EVar "clauses")) (arm (PCons (PTuple (PVar "pats") PWild) PWild) () (EApp (EVar "listLen") (EVar "pats"))) (arm (PList) () (ELit (LInt 0))))) (DoExpr (ETuple (EVar "name") (EApp (EApp (EApp (EVar "newBindingSummary") (EVar "arity")) (EApp (EVar "freshVar") (EVar "mctx"))) (EApp (EVar "freshEffectSummary") (EVar "mctx")))))))
(DTypeSig false "fileBoundKey" (TyFun (TyCon "Loc") (TyCon "String")))
(DFunDef false "fileBoundKey" ((PCon "Loc" (PVar "file") (PVar "line") (PVar "col") (PVar "endLine") (PVar "endCol"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "col")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "endLine")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "endCol")))) (ELit (LString ""))))
(DTypeSig true "fileBodyLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "fileBodyLoc" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "fileBodyLoc" ((PVar "e")) (EBlock (DoLet false false (PVar "found") (EApp (EVar "Ref") (EVar "None"))) (DoLet false false PWild (EApp (EApp (EVar "mapChildren") (ELam ((PVar "child")) (EBlock (DoExpr (EMatch (EFieldAccess (EVar "found") "value") (arm (PCon "None") () (EApp (EApp (EVar "setRef") (EVar "found")) (EApp (EVar "fileBodyLoc") (EVar "child")))) (arm (PCon "Some" PWild) () (ELit LUnit)))) (DoExpr (EVar "child"))))) (EVar "e"))) (DoExpr (EFieldAccess (EVar "found") "value"))))
(DTypeSig true "fileBoundSite" (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyCon "String"))))
(DFunDef false "fileBoundSite" ((PVar "mid") (PVar "loc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "stringLength") (EVar "mid"))))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EVar "mid"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "fileBoundKey") (EVar "loc")))) (ELit (LString ""))))
(DTypeSig false "scopeFileBoundModule" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "String"))))
(DFunDef false "scopeFileBoundModule" ((PVar "mctx") PWild) (EFieldAccess (EApp (EApp (EVar "Scopes.scopeFrame") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) "sfModuleId"))
(DTypeSig true "fileValueKey" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "fileValueKey" ((PVar "mid") (PVar "e")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "loc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "fileBoundSite") (EVar "mid")) (EVar "loc")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "fileValueShape") (EVar "e")))) (ELit (LString ""))))) (EApp (EVar "fileBodyLoc") (EVar "e"))))
(DTypeSig false "fileValueShape" (TyFun (TyCon "Expr") (TyCon "String")))
(DFunDef false "fileValueShape" ((PCon "ELoc" PWild PWild)) (ELit (LString "loc")))
(DFunDef false "fileValueShape" ((PCon "EApp" (PVar "f") PWild)) (EBinOp "++" (ELit (LString "app")) (EApp (EVar "intToString") (EBinOp "+" (EApp (EVar "appSpineArgCount") (EVar "f")) (ELit (LInt 1))))))
(DFunDef false "fileValueShape" ((PCon "ELam" PWild PWild)) (ELit (LString "lambda")))
(DFunDef false "fileValueShape" (PWild) (ELit (LString "value")))
(DTypeSig false "finishFileValueScope" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "Unit"))))
(DFunDef false "finishFileValueScope" ((PVar "mctx") PWild) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fileValueScopes") "value") (arm (PCons (PVar "saved") (PVar "rest")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fileValueScopes")) (EVar "rest"))) (DoLet false false (PVar "flows") (EApp (EApp (EVar "wWindow") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fileValueFlows")) (EApp (EVar "snd") (EVar "saved")))) (DoExpr (EApp (EApp (EVar "wRestore") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fileValueFlows")) (EVar "saved"))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PVar "flow")) (EIf (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "rest")) (EApp (EVar "not") (EApp (EVar "unsettledFileValueFlow") (EVar "flow")))) (EApp (EApp (EVar "checkFileValueFlow") (EVar "mctx")) (EVar "flow")) (ELit LUnit)))) (EVar "flows"))) (DoExpr (EMatch (EVar "rest") (arm (PList) () (ELit LUnit)) (arm PWild () (EApp (EApp (EVar "wPushAll") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fileValueFlows")) (EApp (EVar "reverseL") (EApp (EApp (EVar "filterList") (EVar "unsettledFileValueFlow")) (EVar "flows"))))))) (DoExpr (ELit LUnit)))) (arm (PList) () (ELit LUnit))))
(DTypeSig false "unsettledFileValueFlow" (TyFun (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono") (TyCon "Mono")) (TyCon "Bool")))
(DFunDef false "unsettledFileValueFlow" ((PTuple PWild (PVar "upper") (PVar "lower"))) (EApp (EApp (EApp (EVar "unsettledPackedFileBound") (EVar "False")) (EVar "upper")) (EVar "lower")))
(DTypeSig false "unsettledPackedFileBound" (TyFun (TyCon "Bool") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Bool")))))
(DFunDef false "unsettledPackedFileBound" ((PVar "packed") (PVar "upper") (PVar "lower")) (EMatch (ETuple (EApp (EVar "normalize") (EVar "upper")) (EApp (EVar "normalize") (EVar "lower"))) (arm (PTuple (PCon "TVar" PWild) PWild) () (EVar "True")) (arm (PTuple PWild (PCon "TVar" PWild)) () (EVar "True")) (arm (PTuple (PCon "TQual" (PVar "u") PWild) (PVar "l")) () (EApp (EApp (EApp (EVar "unsettledPackedFileBound") (EVar "packed")) (EVar "u")) (EVar "l"))) (arm (PTuple (PVar "u") (PCon "TQual" (PVar "l") PWild)) () (EApp (EApp (EApp (EVar "unsettledPackedFileBound") (EVar "packed")) (EVar "u")) (EVar "l"))) (arm (PTuple (PCon "TApp" (PVar "uf") (PVar "ux")) (PCon "TApp" (PVar "lf") (PVar "lx"))) () (EBinOp "||" (EApp (EApp (EApp (EVar "unsettledPackedFileBound") (EVar "True")) (EVar "uf")) (EVar "lf")) (EApp (EApp (EApp (EVar "unsettledPackedFileBound") (EVar "True")) (EVar "ux")) (EVar "lx")))) (arm (PTuple (PCon "TFun" (PVar "ud") (PVar "ur") (PVar "ux")) (PCon "TFun" (PVar "ld") (PVar "lr") (PVar "lx"))) () (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EVar "packed") (EApp (EApp (EVar "unsettledFileRow") (EVar "ur")) (EVar "lr"))) (EApp (EApp (EApp (EVar "unsettledPackedFileBound") (EVar "packed")) (EVar "ld")) (EVar "ud"))) (EApp (EApp (EApp (EVar "unsettledPackedFileBound") (EVar "packed")) (EVar "ux")) (EVar "lx")))) (arm PWild () (EVar "False"))))
(DTypeSig false "unsettledFileRow" (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Bool"))))
(DFunDef false "unsettledFileRow" ((PVar "upper") (PVar "lower")) (EBlock (DoLet false false (PTuple (PVar "ua") (PVar "ut")) (EApp (EVar "rowFlat") (EVar "upper"))) (DoLet false false (PTuple (PVar "la") (PVar "lt")) (EApp (EVar "rowFlat") (EVar "lower"))) (DoExpr (EBinOp "||" (EBinOp "||" (EApp (EVar "isNonEmptyL") (EVar "ut")) (EApp (EVar "isNonEmptyL") (EMethodRef "lt"))) (EApp (EApp (EVar "anyList") (ELam ((PVar "a")) (EBinOp "&&" (EApp (EVar "narrowFileAtom") (EVar "a")) (EApp (EVar "authHasVars") (EApp (EVar "atomAuth") (EVar "a")))))) (EBinOp "++" (EVar "ua") (EVar "la")))))))
(DTypeSig false "checkFileValueFlow" (TyFun (TyCon "ModuleCtx") (TyFun (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono") (TyCon "Mono")) (TyCon "Unit"))))
(DFunDef false "checkFileValueFlow" ((PVar "mctx") (PTuple (PVar "loc") (PVar "upper") (PVar "lower"))) (EIf (EApp (EApp (EApp (EVar "changesPackedFileBound") (EVar "False")) (EVar "upper")) (EVar "lower")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (ELit (LString "T-FILE-BOUND-VALUE"))) (EVar "loc")) (EBinOp "++" (EBinOp "++" (ELit (LString "a function's file bound cannot change inside a container: ")) (EApp (EVar "ppMonosShared") (EListLit (EVar "lower") (EVar "upper")))) (ELit (LString "; annotate the function with the container's FileRead or FileWrite bound before packing it")))) (ELit LUnit)))
(DTypeSig false "changesPackedFileBound" (TyFun (TyCon "Bool") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Bool")))))
(DFunDef false "changesPackedFileBound" ((PVar "packed") (PVar "upper") (PVar "lower")) (EMatch (ETuple (EApp (EVar "normalize") (EVar "upper")) (EApp (EVar "normalize") (EVar "lower"))) (arm (PTuple (PCon "TQual" (PVar "u") PWild) (PVar "l")) () (EApp (EApp (EApp (EVar "changesPackedFileBound") (EVar "packed")) (EVar "u")) (EVar "l"))) (arm (PTuple (PVar "u") (PCon "TQual" (PVar "l") PWild)) () (EApp (EApp (EApp (EVar "changesPackedFileBound") (EVar "packed")) (EVar "u")) (EVar "l"))) (arm (PTuple (PCon "TApp" (PVar "uf") (PVar "ux")) (PCon "TApp" (PVar "lf") (PVar "lx"))) () (EBinOp "||" (EApp (EApp (EApp (EVar "changesPackedFileBound") (EVar "True")) (EVar "uf")) (EVar "lf")) (EApp (EApp (EApp (EVar "changesPackedFileBound") (EVar "True")) (EVar "ux")) (EVar "lx")))) (arm (PTuple (PCon "TFun" (PVar "ud") (PVar "ur") (PVar "ux")) (PCon "TFun" (PVar "ld") (PVar "lr") (PVar "lx"))) () (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EVar "packed") (EApp (EApp (EVar "changesFileRow") (EVar "ur")) (EVar "lr"))) (EApp (EApp (EApp (EVar "changesPackedFileBound") (EVar "packed")) (EVar "ld")) (EVar "ud"))) (EApp (EApp (EApp (EVar "changesPackedFileBound") (EVar "packed")) (EVar "ux")) (EVar "lx")))) (arm PWild () (EVar "False"))))
(DTypeSig false "changesFileRow" (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Bool"))))
(DFunDef false "changesFileRow" ((PVar "upper") (PVar "lower")) (EBlock (DoLet false false (PTuple (PVar "ua") (PVar "ut")) (EApp (EVar "rowFlat") (EVar "upper"))) (DoLet false false (PTuple (PVar "la") (PVar "lt")) (EApp (EVar "rowFlat") (EVar "lower"))) (DoExpr (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "ut")) (EApp (EApp (EVar "anyList") (ELam ((PVar "u")) (EBinOp "&&" (EApp (EVar "narrowFileAtom") (EVar "u")) (EBinOp "||" (EApp (EVar "isNonEmptyL") (EMethodRef "lt")) (EApp (EApp (EVar "anyList") (ELam ((PVar "l")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "atomKey") (EVar "l")) (EApp (EVar "atomKey") (EVar "u"))) (EApp (EVar "not") (EBinOp "&&" (EApp (EApp (EVar "authSub") (EApp (EVar "atomAuth") (EVar "l"))) (EApp (EVar "atomAuth") (EVar "u"))) (EApp (EApp (EVar "authSub") (EApp (EVar "atomAuth") (EVar "u"))) (EApp (EVar "atomAuth") (EVar "l")))))))) (EVar "la")))))) (EVar "ua"))))))
(DTypeSig true "hasFileBoundValue" (TyFun (TyCon "Mono") (TyCon "Bool")))
(DFunDef false "hasFileBoundValue" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TFun" PWild (PVar "row") (PVar "result")) () (EBlock (DoLet false false (PTuple (PVar "atoms") (PVar "tails")) (EApp (EVar "rowFlat") (EVar "row"))) (DoExpr (EBinOp "||" (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "tails")) (EApp (EApp (EVar "anyList") (EVar "narrowFileAtom")) (EVar "atoms"))) (EApp (EVar "hasFileBoundValue") (EVar "result")))))) (arm (PCon "TQual" (PVar "inner") PWild) () (EApp (EVar "hasFileBoundValue") (EVar "inner"))) (arm PWild () (EVar "False"))))
(DTypeSig true "recordValueFileBound" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "recordValueFileBound" ((PVar "mctx") (PVar "e") (PVar "ty")) (EIf (EApp (EVar "hasFileBoundValue") (EVar "ty")) (EMatch (EApp (EApp (EVar "fileValueKey") (EApp (EApp (EVar "scopeFileBoundModule") (EVar "mctx")) (ELit LUnit))) (EVar "e")) (arm (PCon "Some" (PVar "key")) () (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsValueBounds")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "::" (ETuple (EVar "ty") (EApp (EApp (EVar "grantChainAt") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit)))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EFieldAccess (EVar "st") "gsValueBounds") "value"))))) (EFieldAccess (EFieldAccess (EVar "st") "gsValueBounds") "value")))))) (arm (PCon "None") () (ELit LUnit))) (ELit LUnit)))
(DTypeSig true "recordFileBound" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Expr") (TyFun (TyCon "EffRow") (TyCon "Unit")))))
(DFunDef false "recordFileBound" ((PVar "mctx") (PVar "body") (PVar "row")) (EBlock (DoLet false false (PTuple (PVar "atoms") (PVar "tails")) (EApp (EVar "rowFlat") (EVar "row"))) (DoExpr (EIf (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "tails")) (EApp (EApp (EVar "anyList") (EVar "narrowFileAtom")) (EVar "atoms"))) (EMatch (EApp (EVar "fileBodyLoc") (EVar "body")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "loc")) () (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "grants")) (DoLet false false (PVar "key") (EApp (EApp (EVar "fileBoundSite") (EApp (EApp (EVar "scopeFileBoundModule") (EVar "mctx")) (ELit LUnit))) (EVar "loc"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsBounds")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "::" (ETuple (EVar "row") (EApp (EApp (EVar "grantChainAt") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit)))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EFieldAccess (EVar "st") "gsBounds") "value"))))) (EFieldAccess (EFieldAccess (EVar "st") "gsBounds") "value"))))))) (ELit LUnit)))))
(DTypeSig true "narrowFileAtom" (TyFun (TyCon "Atom") (TyCon "Bool")))
(DFunDef false "narrowFileAtom" ((PVar "atom")) (EMatch (EApp (EVar "atomLabelOf") (EVar "atom")) (arm (PCon "EffLabel" (PVar "label") (PCon "OriginBuiltin")) () (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EVar "label") (ELit (LString "FileRead"))) (EBinOp "==" (EVar "label") (ELit (LString "FileWrite")))) (EApp (EVar "not") (EApp (EVar "authIsTop") (EApp (EVar "atomAuth") (EVar "atom")))))) (arm PWild () (EVar "False"))))
(DTypeSig true "recordClauseFileBound" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyCon "Unit"))))))
(DFunDef false "recordClauseFileBound" ((PVar "mctx") (PVar "body") (PVar "arity") (PVar "ty")) (EIf (EBinOp "<=" (EVar "arity") (ELit (LInt 0))) (ELit LUnit) (EIf (EVar "otherwise") (EMatch (EApp (EVar "normalize") (EVar "ty")) (arm (PCon "TFun" PWild (PVar "row") (PVar "result")) () (EIf (EBinOp "==" (EVar "arity") (ELit (LInt 1))) (EApp (EApp (EApp (EVar "recordFileBound") (EVar "mctx")) (EVar "body")) (EVar "row")) (EApp (EApp (EApp (EApp (EVar "recordClauseFileBound") (EVar "mctx")) (EVar "body")) (EBinOp "-" (EVar "arity") (ELit (LInt 1)))) (EVar "result")))) (arm (PCon "TQual" (PVar "inner") PWild) () (EApp (EApp (EApp (EApp (EVar "recordClauseFileBound") (EVar "mctx")) (EVar "body")) (EVar "arity")) (EVar "inner"))) (arm PWild () (ELit LUnit))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "launderEscapeFromLog" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "EffRow")) (TyFun (TyApp (TyCon "List") (TyCon "EffRow")) (TyFun (TyApp (TyCon "List") (TyCon "AbsorptionEvent")) (TyApp (TyCon "List") (TyCon "Atom")))))))
(DFunDef false "launderEscapeFromLog" ((PVar "gctx") (PList) PWild PWild) (EListLit))
(DFunDef false "launderEscapeFromLog" ((PVar "gctx") PWild (PList) PWild) (EListLit))
(DFunDef false "launderEscapeFromLog" ((PVar "gctx") (PCons (PVar "der") (PVar "dRest")) (PCons (PVar "aer") (PVar "aRest")) (PVar "evts")) (EBlock (DoLet false false (PVar "here") (EMatch (EVar "aer") (arm (PCon "EffRow" PWild (PCon "None")) () (EListLit)) (arm (PCon "EffRow" PWild (PCon "Some" PWild)) () (EApp (EApp (EApp (EVar "launderOpenActualArrow") (EVar "gctx")) (EVar "der")) (EVar "evts"))))) (DoExpr (EBinOp "++" (EVar "here") (EApp (EApp (EApp (EApp (EVar "launderEscapeFromLog") (EVar "gctx")) (EVar "dRest")) (EVar "aRest")) (EVar "evts"))))))
(DTypeSig false "launderOpenActualArrow" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EffRow") (TyFun (TyApp (TyCon "List") (TyCon "AbsorptionEvent")) (TyApp (TyCon "List") (TyCon "Atom"))))))
(DFunDef false "launderOpenActualArrow" ((PVar "gctx") (PCon "EffRow" (PVar "declAtoms") (PCon "Some" (PVar "cell"))) (PVar "evts")) (EBlock (DoLet false false (PVar "tid") (EApp (EVar "liveTailId") (EVar "cell"))) (DoExpr (EIf (EBinOp "==" (EVar "tid") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EListLit) (EApp (EApp (EApp (EVar "atomsEscape") (EVar "gctx")) (EApp (EApp (EVar "atomsAbsorbedInto") (EVar "tid")) (EVar "evts"))) (EVar "declAtoms"))))))
(DFunDef false "launderOpenActualArrow" ((PVar "gctx") (PCon "EffRow" PWild (PCon "None")) PWild) (EListLit))
(DTypeSig false "atomsAbsorbedInto" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "AbsorptionEvent")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "atomsAbsorbedInto" (PWild (PList)) (EListLit))
(DFunDef false "atomsAbsorbedInto" ((PVar "tid") (PCons (PVar "ev") (PVar "rest"))) (EIf (EBinOp "==" (EApp (EVar "liveTailId") (EFieldAccess (EVar "ev") "cell")) (EVar "tid")) (EBinOp "::" (EFieldAccess (EVar "ev") "atom") (EApp (EApp (EVar "atomsAbsorbedInto") (EVar "tid")) (EVar "rest"))) (EApp (EApp (EVar "atomsAbsorbedInto") (EVar "tid")) (EVar "rest"))))
(DTypeSig true "checkMethodEffVarRigidity" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit")))))))))))
(DFunDef false "checkMethodEffVarRigidity" ((PVar "mctx") (PVar "subject") (PVar "headMonos") (PVar "gscope") (PVar "mty") (PVar "effVars") (PVar "launderFlagged") (PVar "eager") (PVar "loc")) (EBlock (DoExpr (EIf (EApp (EApp (EVar "anyContainsI") (EApp (EVar "effVarTailIds") (EVar "effVars"))) (EApp (EApp (EDictApp "flatMap") (EVar "monoIndexEffvarIds")) (EVar "headMonos"))) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-IMPL-TOO-SPECIFIC"))) (EVar "loc")) (EApp (EApp (EVar "aliasesHeadRowMsg") (EVar "subject")) (EVar "mty"))) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkImplEffVarRigidity") (EVar "mctx")) (EVar "subject")) (EVar "gscope")) (EVar "mty")) (EVar "effVars")) (EVar "launderFlagged")) (EVar "eager")) (EVar "loc")))))
(DTypeSig false "checkImplEffVarRigidity" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit"))))))))))
(DFunDef false "checkImplEffVarRigidity" ((PVar "mctx") (PVar "subject") (PVar "scope") (PVar "mty") (PVar "effMap") (PVar "launderFlagged") (PVar "eager") (PVar "loc")) (EBlock (DoLet false false (PVar "occs") (EBinOp "++" (EApp (EApp (EVar "effVarOccAtoms") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "mty")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EListLit)))) (EApp (EApp (EApp (EVar "rowArgNamesIn") (EVar "mctx")) (EVar "scope")) (EVar "mty"))))) (DoExpr (EIf (EVar "launderFlagged") (ELit LUnit) (EApp (EApp (EApp (EApp (EApp (EVar "checkEffVarAtoms") (EVar "mctx")) (EVar "subject")) (EVar "occs")) (EVar "effMap")) (EVar "loc")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "checkIndexOnlyEffVarsOpen") (EVar "mctx")) (EVar "subject")) (EVar "effMap")) (EVar "loc")) (EVar "eager"))) (DoExpr (EIf (EApp (EVar "hasDupI") (EApp (EVar "effVarTailIds") (EVar "effMap"))) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-IMPL-TOO-SPECIFIC"))) (EVar "loc")) (EApp (EApp (EVar "collapsesEffvarsMsg") (EVar "subject")) (EVar "mty"))) (ELit LUnit)))))
(DTypeSig false "checkIndexOnlyEffVarsOpen" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "checkIndexOnlyEffVarsOpen" ((PVar "mctx") (PVar "subject") (PVar "effMap") (PVar "loc") (PVar "eager")) (EApp (EApp (EApp (EApp (EApp (EVar "checkIndexOnlyGo") (EVar "mctx")) (EVar "subject")) (EVar "effMap")) (EVar "loc")) (EVar "eager")))
(DTypeSig true "eagerIndexOnlyVars" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyFun (TyApp (TyCon "List") (TyCon "EffRow")) (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "eagerIndexOnlyVars" ((PList) PWild PWild PWild PWild) (EListLit))
(DFunDef false "eagerIndexOnlyVars" ((PVar "idx") (PVar "effMap") (PVar "actualArrows") (PVar "expected") (PVar "actual")) (EBlock (DoLet false false (PVar "tails") (EApp (EApp (EDictApp "flatMap") (EVar "rowTailId")) (EVar "actualArrows"))) (DoLet false false (PVar "pairs") (EApp (EApp (EVar "pairRowCells") (EVar "expected")) (EVar "actual"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "v")) (EApp (EApp (EApp (EApp (EVar "effVarCellPerformed") (EVar "v")) (EVar "effMap")) (EVar "pairs")) (EVar "tails")))) (EVar "idx")))))
(DTypeSig false "pairRowCells" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "pairRowCells" ((PVar "d") (PVar "a")) (EMatch (EApp (EVar "peelQual") (EVar "d")) (arm (PCon "TFun" (PVar "d1") (PVar "dr") (PVar "d2")) () (EMatch (EApp (EVar "peelQual") (EVar "a")) (arm (PCon "TFun" (PVar "a1") (PVar "ar") (PVar "a2")) () (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "pairRows") (EVar "dr")) (EVar "ar")) (EApp (EApp (EVar "pairRowCells") (EVar "d1")) (EVar "a1"))) (EApp (EApp (EVar "pairRowCells") (EVar "d2")) (EVar "a2")))) (arm PWild () (EListLit)))) (arm (PCon "TApp" (PVar "d1") (PVar "d2")) () (EMatch (EApp (EVar "peelQual") (EVar "a")) (arm (PCon "TApp" (PVar "a1") (PVar "a2")) () (EBinOp "++" (EApp (EApp (EVar "pairRowCells") (EVar "d1")) (EVar "a1")) (EApp (EApp (EVar "pairRowCells") (EVar "d2")) (EVar "a2")))) (arm PWild () (EListLit)))) (arm (PCon "TEff" (PVar "dr")) () (EMatch (EApp (EVar "peelQual") (EVar "a")) (arm (PCon "TEff" (PVar "ar")) () (EApp (EApp (EVar "pairRows") (EVar "dr")) (EVar "ar"))) (arm PWild () (EListLit)))) (arm PWild () (EListLit))))
(DTypeSig false "pairRows" (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "pairRows" ((PVar "dr") (PVar "ar")) (EMatch (EApp (EVar "rowTailId") (EVar "dr")) (arm (PList (PVar "did")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "aid")) (ETuple (EVar "did") (EVar "aid")))) (EApp (EVar "rowTailId") (EVar "ar")))) (arm PWild () (EListLit))))
(DTypeSig false "effVarCellPerformed" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool"))))))
(DFunDef false "effVarCellPerformed" ((PVar "v") (PVar "effMap") (PVar "pairs") (PVar "tails")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "v")) (EVar "effMap")) (arm (PCon "Some" (PVar "cell")) () (EBlock (DoLet false false (PVar "dids") (EApp (EVar "rowTailId") (EApp (EApp (EVar "EffRow") (EListLit)) (EApp (EVar "Some") (EVar "cell"))))) (DoExpr (EApp (EApp (EVar "anyList") (ELam ((PVar "did")) (EBinOp "||" (EApp (EApp (EVar "containsI") (EVar "did")) (EVar "tails")) (EApp (EApp (EVar "anyList") (ELam ((PVar "p")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "fst") (EVar "p")) (EVar "did")) (EApp (EApp (EVar "containsI") (EApp (EVar "snd") (EVar "p"))) (EVar "tails"))))) (EVar "pairs"))))) (EVar "dids"))))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "checkIndexOnlyGo" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "checkIndexOnlyGo" ((PVar "mctx") PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "checkIndexOnlyGo" ((PVar "mctx") (PVar "subject") (PVar "effMap") (PVar "loc") (PCons (PVar "v") (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-EFFECT-INDEX-EAGER"))) (EVar "loc")) (EApp (EApp (EVar "indexEagerMsg") (EVar "subject")) (EVar "v")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "checkIndexOnlyGo") (EVar "mctx")) (EVar "subject")) (EVar "effMap")) (EVar "loc")) (EVar "rest")))))
(DTypeSig true "performSiteIn" (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyApp (TyCon "Option") (TyCon "Loc")))))) (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "performSiteIn" ((PCon "None") PWild) (EVar "None"))
(DFunDef false "performSiteIn" ((PCon "Some" (PVar "sites")) (PVar "actual")) (EBlock (DoLet false false (PVar "tails") (EApp (EApp (EDictApp "flatMap") (EVar "rowTailId")) (EApp (EVar "allArrowEffs") (EVar "actual")))) (DoExpr (EApp (EApp (EVar "findMap") (ELam ((PVar "site")) (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "id")) (EApp (EApp (EVar "containsI") (EVar "id")) (EVar "tails")))) (EApp (EVar "rowTailId") (EApp (EApp (EVar "EffRow") (EListLit)) (EApp (EVar "Some") (EApp (EVar "fst") (EVar "site")))))) (EApp (EVar "snd") (EVar "site")) (EVar "None")))) (EApp (EVar "reverseL") (EFieldAccess (EVar "sites") "value"))))))
(DTypeSig true "indexOnlyEffVars" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "indexOnlyEffVars" ((PVar "mctx") (PVar "scope") (PVar "mty")) (EBlock (DoLet false false (PVar "argNames") (EApp (EVar "dedup") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EApp (EVar "methodEffArgOccs") (EVar "mctx")) (EVar "scope")) (EVar "mty"))))) (DoLet false false (PVar "charged") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EVar "methodEffChargedOccs") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "mty")))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "v")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "v")) (EVar "charged"))))) (EVar "argNames")))))
(DTypeSig false "methodEffChargedOccs" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))))))
(DFunDef false "methodEffChargedOccs" ((PVar "gctx") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EVar "methodEffChargedOccs") (EVar "gctx")) (EVar "t")))
(DFunDef false "methodEffChargedOccs" ((PVar "gctx") (PCon "TyEffect" (PVar "labels") (PVar "tails") (PVar "t"))) (EBinOp "++" (EApp (EApp (EApp (EVar "occsOfTails") (EVar "gctx")) (EVar "tails")) (EVar "labels")) (EApp (EApp (EVar "methodEffChargedOccs") (EVar "gctx")) (EVar "t"))))
(DFunDef false "methodEffChargedOccs" ((PVar "gctx") (PCon "TyFun" PWild (PVar "b"))) (EApp (EApp (EVar "methodEffChargedOccs") (EVar "gctx")) (EVar "b")))
(DFunDef false "methodEffChargedOccs" ((PVar "gctx") (PVar "t")) (EApp (EApp (EVar "effVarChargedOccs") (EVar "gctx")) (EVar "t")))
(DTypeSig false "effVarChargedOccs" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))))))
(DFunDef false "effVarChargedOccs" ((PVar "gctx") (PCon "TyEffect" (PVar "labels") (PVar "tails") (PVar "t"))) (EBinOp "++" (EApp (EApp (EApp (EVar "occsOfTails") (EVar "gctx")) (EVar "tails")) (EVar "labels")) (EApp (EApp (EVar "effVarChargedOccs") (EVar "gctx")) (EVar "t"))))
(DFunDef false "effVarChargedOccs" ((PVar "gctx") (PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EVar "effVarChargedOccs") (EVar "gctx")) (EVar "a")) (EApp (EApp (EVar "effVarChargedOccs") (EVar "gctx")) (EVar "b"))))
(DFunDef false "effVarChargedOccs" ((PVar "gctx") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EVar "effVarChargedOccs") (EVar "gctx")) (EVar "a")) (EApp (EApp (EVar "effVarChargedOccs") (EVar "gctx")) (EVar "b"))))
(DFunDef false "effVarChargedOccs" ((PVar "gctx") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "effVarChargedOccs") (EVar "gctx"))) (EVar "ts")))
(DFunDef false "effVarChargedOccs" ((PVar "gctx") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EVar "effVarChargedOccs") (EVar "gctx")) (EVar "t")))
(DFunDef false "effVarChargedOccs" ((PVar "gctx") PWild) (EListLit))
(DTypeSig false "checkEffVarAtoms" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit")))))))
(DFunDef false "checkEffVarAtoms" ((PVar "mctx") PWild PWild (PList) PWild) (ELit LUnit))
(DFunDef false "checkEffVarAtoms" ((PVar "mctx") (PVar "subject") (PVar "occs") (PCons (PTuple (PVar "n") (PVar "cell")) (PVar "rest")) (PVar "loc")) (EBlock (DoLet false false (PVar "esc") (EApp (EApp (EApp (EApp (EVar "effVarOccEscape") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "n")) (EApp (EVar "effrowLabels") (EApp (EApp (EVar "EffRow") (EListLit)) (EApp (EVar "Some") (EVar "cell"))))) (EVar "occs"))) (DoExpr (EIf (EApp (EVar "isNonEmptyL") (EVar "esc")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-EFFECT-LAUNDER"))) (EVar "loc")) (EApp (EApp (EApp (EVar "effVarLaunderMsg") (EVar "subject")) (EVar "n")) (EVar "esc"))) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "checkEffVarAtoms") (EVar "mctx")) (EVar "subject")) (EVar "occs")) (EVar "rest")) (EVar "loc")))))
(DTypeSig false "effVarOccEscape" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))) (TyApp (TyCon "List") (TyCon "Atom")))))))
(DFunDef false "effVarOccEscape" ((PVar "gctx") PWild (PList) PWild) (EListLit))
(DFunDef false "effVarOccEscape" ((PVar "gctx") PWild PWild (PList)) (EListLit))
(DFunDef false "effVarOccEscape" ((PVar "gctx") (PVar "n") (PVar "instAtoms") (PCons (PTuple (PVar "m") (PVar "declAtoms")) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "m") (EVar "n")) (EApp (EVar "isNonEmptyL") (EApp (EApp (EApp (EVar "atomsEscape") (EVar "gctx")) (EVar "instAtoms")) (EVar "declAtoms")))) (EApp (EApp (EApp (EVar "atomsEscape") (EVar "gctx")) (EVar "instAtoms")) (EVar "declAtoms")) (EApp (EApp (EApp (EApp (EVar "effVarOccEscape") (EVar "gctx")) (EVar "n")) (EVar "instAtoms")) (EVar "rest"))))
(DTypeSig false "effVarOccAtoms" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))))))
(DFunDef false "effVarOccAtoms" ((PVar "gctx") (PCon "TyEffect" (PVar "labels") (PVar "tails") (PVar "t"))) (EBinOp "++" (EApp (EApp (EApp (EVar "occsOfTails") (EVar "gctx")) (EVar "tails")) (EVar "labels")) (EApp (EApp (EVar "effVarOccAtoms") (EVar "gctx")) (EVar "t"))))
(DFunDef false "effVarOccAtoms" ((PVar "gctx") (PCon "TyRow" (PVar "labels") (PVar "tails") PWild)) (EApp (EApp (EApp (EVar "occsOfTails") (EVar "gctx")) (EVar "tails")) (EVar "labels")))
(DFunDef false "effVarOccAtoms" ((PVar "gctx") (PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EVar "effVarOccAtoms") (EVar "gctx")) (EVar "a")) (EApp (EApp (EVar "effVarOccAtoms") (EVar "gctx")) (EVar "b"))))
(DFunDef false "effVarOccAtoms" ((PVar "gctx") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EVar "effVarOccAtoms") (EVar "gctx")) (EVar "a")) (EApp (EApp (EVar "effVarOccAtoms") (EVar "gctx")) (EVar "b"))))
(DFunDef false "effVarOccAtoms" ((PVar "gctx") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "effVarOccAtoms") (EVar "gctx"))) (EVar "ts")))
(DFunDef false "effVarOccAtoms" ((PVar "gctx") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EVar "effVarOccAtoms") (EVar "gctx")) (EVar "t")))
(DFunDef false "effVarOccAtoms" ((PVar "gctx") PWild) (EListLit))
(DTypeSig true "clausesAt" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "clausesAt" ((PVar "n") (PVar "m")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "m")) (arm (PCon "Some" (PVar "xs")) () (EVar "xs")) (arm (PCon "None") () (EListLit))))
(DTypeSig true "clausesOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "clausesOf" ((PVar "n") (PVar "m")) (EApp (EApp (EVar "revClauses") (EApp (EApp (EVar "clausesAt") (EVar "n")) (EVar "m"))) (EListLit)))
(DTypeSig true "revClauses" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "revClauses" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "revClauses" ((PCons (PVar "x") (PVar "xs")) (PVar "acc")) (EApp (EApp (EVar "revClauses") (EVar "xs")) (EBinOp "::" (EVar "x") (EVar "acc"))))
(DTypeSig true "memberEffectRoots" (TyFun (TyCon "ScopedMember") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "memberEffectRoots" ((PVar "member") (PVar "roots")) (EBlock (DoLet false false (PVar "inputs") (EIf (EFieldAccess (EFieldAccess (EVar "member") "smSigned") "value") (EVar "roots") (EApp (EApp (EVar "effectRoots") (EFieldAccess (EFieldAccess (EVar "member") "smOwned") "bsValue")) (EVar "roots")))) (DoExpr (EApp (EApp (EApp (EVar "IdMap.foldlWithKey") (ELam ((PVar "acc") (PVar "id") PWild) (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (ELit LUnit)) (EVar "acc")))) (EVar "inputs")) (EFieldAccess (EFieldAccess (EVar "member") "smDeclaredRoots") "value")))))
(DTypeSig true "checkEffectEscape" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "Unit"))))))
(DFunDef false "checkEffectEscape" ((PVar "dyn") (PVar "sigs") (PVar "m") (PVar "effs")) (EMatch (EFieldAccess (EVar "dyn") "dcGroup") (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "group")) () (EApp (EApp (EApp (EApp (EApp (EVar "checkEffectEscapeIn") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "group")) (EVar "sigs")) (EVar "m")) (EVar "effs")))))
(DTypeSig false "checkEffectEscapeIn" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "GroupCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "Unit")))))))
(DFunDef false "checkEffectEscapeIn" ((PVar "mctx") (PVar "group") (PVar "sigs") (PVar "m") (PVar "effs")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "m")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "sigTyMapRef") "value")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "written")) () (EBlock (DoLet false false (PVar "ty") (EApp (EApp (EVar "expandReturnSpine") (EVar "mctx")) (EVar "written"))) (DoExpr (EIf (EApp (EApp (EVar "declaredEffectsOpen") (EVar "mctx")) (EVar "ty")) (ELit LUnit) (EMatch (EApp (EApp (EApp (EVar "atomsEscape") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "filterList") (EVar "concreteAtom")) (EVar "effs"))) (EApp (EApp (EVar "declaredEffects") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ty"))) (arm (PList) () (ELit LUnit)) (arm (PVar "extras") () (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "group") "gcPendingEscapes")) (EBinOp "::" (ETuple (EVar "m") (EFieldAccess (EVar "mctx") "mcLoc") (EApp (EApp (EApp (EApp (EVar "effectEscapeMsg") (EVar "m")) (EApp (EApp (EVar "declaredEffects") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ty"))) (EApp (EVar "declaredEffectTail") (EVar "ty"))) (EVar "extras"))) (EFieldAccess (EFieldAccess (EVar "group") "gcPendingEscapes") "value")))))))))))
(DTypeSig true "flushPendingEscapes" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "GroupCtx")) (TyCon "Unit"))))
(DFunDef false "flushPendingEscapes" ((PVar "mctx") (PCon "None")) (ELit LUnit))
(DFunDef false "flushPendingEscapes" ((PVar "mctx") (PCon "Some" (PVar "group"))) (EBlock (DoLet false false (PVar "pending") (EApp (EVar "reverseL") (EFieldAccess (EFieldAccess (EVar "group") "gcPendingEscapes") "value"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "group") "gcPendingEscapes")) (EListLit))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "entry")) (EBlock (DoLet false false (PTuple (PVar "m") (PVar "loc") (PVar "msg")) (EVar "entry")) (DoExpr (EIf (EApp (EApp (EVar "omHasKey") (EVar "m")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "rowFailureReportedRef") "value")) (ELit LUnit) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (ELit (LString "T-EFFECT-LEAK"))) (EVar "loc")) (EVar "msg"))))))) (ELit LUnit)) (EVar "pending")))))
(DTypeSig false "concreteAtom" (TyFun (TyCon "Atom") (TyCon "Bool")))
(DFunDef false "concreteAtom" ((PVar "a")) (EApp (EVar "not") (EApp (EVar "authHasVars") (EApp (EVar "atomAuth") (EVar "a")))))
