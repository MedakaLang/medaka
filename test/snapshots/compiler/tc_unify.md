# META
source_lines=2964
stages=DESUGAR,MARK
# SOURCE
-- tc_unify: fresh variables and levels (including level lowering, `lowerToCurrent`,
-- `lowerOwnedRoot`), unification over types, rows, joins, index rows and authority, the occurs
-- check, the mismatch action (`typeMismatch`, `poisonMismatchVars`, the do-block report
-- `recordDoMonadError`), generalization (with the defaulting it performs: sourceless authorities,
-- deferred pattern literals) and instantiation, with the call obligations, effects and value flows
-- that instantiation and directional unification record (`recordObl`, `recordOblAt`,
-- `recordSchemeCallObligations`, `performEffect`, `recordEffectSites`, `recordFileValueFlow`,
-- `captureScope`, `obligationSiteHere`); and the messages of these failures that need checker
-- context (`authorityFailureMsg`, `effectLeakMsg`, `constrainedApplicationHelp`; D3). Context-free
-- message text is `tc_diag_text`'s.
--
-- Spec: HM-CORE section 3, section 4 (owed, #2555); EFFECTS section 2.4, section 5, section
-- 6.6-6.8.
--
-- Placement: declarations are placed by R1-R6 of the Phase 4 module table,
-- compiler/ARCHITECTURE-PLAYBOOK.md section 6.
-- Closure rule: this module may not import `types.typecheck`, nor any of `tc_decls_variance`,
-- `tc_decls_types`, `tc_decls`, `tc_foreign`, `tc_solve_givens`, `tc_solve_entail`, `tc_solve`,
-- `tc_solve_check`, `tc_shadow`, `tc_effects`, `tc_occurrence`, `tc_groups`, `tc_pat`,
-- `tc_infer_records`, `tc_infer`, `tc_elab`, `tc_global`, `tc_module`.

import types.tc_types.{
  AbsorptionEvent(..),
  CDeclared(..),
  CDeclaredPrefix(..),
  CSlot(..),
  DynCtx(..),
  JoinContext(..),
  Kind(..),
  MethodInstantiationSubst(..),
  MethodTrackedInstantiation(..),
  ObligationSite(..),
  OblProjection(..),
  PendingJoin(..),
  Polarity(..),
  Predicate(..),
  PredicateSlotArgs(..),
  Provenance(..),
  UObligation(..),
  Windowed(..),
  DoCtx,
  dynFor,
  GraphCtx,
  ModuleCtx,
  PredicateSlot,
}
import types.tc_mono.{
  authCellsIn,
  authRowCells,
  cellIdSet,
  containsI,
  dedupI,
  effvarLevel,
  headTyconMono,
  headTyconNameMono,
  isUnshaped,
  joinCellOf,
  minLevelOf,
  monoHasArrowInSlot,
  monoIsApp,
  monoSpineDepth,
  monoUnboundIds,
  newEffvarId,
  qualifierAuthIds,
  rowOfMembers,
  sameRootId,
  spineHead,
  substAuth,
  substMono,
  substMonos,
  substOblArgs,
  substRow,
  tconBuiltin,
  tupleUnifyClash,
  tyAppSpine,
  tyvarId,
  xmodOblArgId,
}
import types.tc_state.{dynAtIfSome, wAll, wPush, wRestore, wSnapshot}
import types.tc_env.{domainHasPatterns, tyTabKey}
import types.tc_diag.{
  firstTupleCallHint, pushTypeError, pushTypeErrorAt, pushTypeErrorHelpFixAt,
  recordTypeError
}
import types.tc_diag_text.{
  authorityCoverMsg, authorityIndexMsg, authorityTermTextIn,
  closedRowMismatchMsg, constrainedApplicationText, contraRowMsg,
  deferRequiresMonadMsg, doRequiresMonadMsg, elselessIfHelp,
  indexRowMismatchMsg, joinMismatchMsg, paramVarianceMismatchMsg,
  patternIndexMsg, renderFlatRow, residualFailureMsg, sameSpellingHint,
  starSpelling
}
import types.effect_authority.{
  Authority(..),
  Authvar(..),
  authDomainTop,
  authHasVars,
  authIsPattern,
  authIsTop,
  authJoinAll,
  authNorm,
  authSplit,
  authSub,
  authTop,
  authvarDomain,
  authvarId,
  authvarIsPattern,
  authvarLevel,
  authvarName,
  authVars,
  linkAuthvar,
  markAuthvarPattern,
}
import types.effect_rows.{
  Atom(..),
  EffLabel(..),
  EffRow(..),
  Effvar(..),
  atomAuth,
  atomKey,
  atomsDiff,
  atomsNorm,
  atomsUnion,
  builtinLabel,
  collectRows,
  effLabelName,
  effrowNorm,
  effvarId,
  findAtom,
  isJoinCell,
  labelKey,
  linkRow,
  pureRow,
  renderAtoms,
  rowFlat,
  rowHasSummary,
}
import types.repr.{
  AuthResidual(..),
  Mono(..),
  Scheme(..),
  Tyvar(..),
  VecObl(..),
  normalize,
  ppAuthority,
  ppMono,
  tupleTagArity,
}
import frontend.ast.{
  Decl(..),
  EffAtomTy(..),
  EffParamTy(..),
  Loc(..),
  TabKey(..),
  Ty(..),
  TyConOrigin(..),
  lookupTab,
  sameTyConHead,
  tabKeyEq,
}
import types.registry.{HeadKey(..)}
import map.{Map(..)}
import types.effect_domain.{Param(..)}
import types.evidence.{ScopeId(..)}
import types.publish.{TcDiag(..)}
import types.effect_values.{
  ValueJoinOps(..),
  joinProduced,
  joinProducedEnvelope,
  resolveDeferredJoin,
}
import support.util.{
  allList,
  anyList,
  dedup,
  filterList,
  isEmptyL,
  isNonEmptyL,
  isSome,
  listLen,
  lookupAssoc,
  minI,
  orElseOpt,
  reverseL,
  splitOnChar,
}
import types.effect_param_decode.{atomOfLabel}
import types.solver_contract.{Instantiation(..), Wanted(..)}
import types.target_profile.{hostLabels}
import types.disposition.{MethodDisposition(..)}
import list.{drop, last, replicate}
import support.ordmap.{omInsert, omLookup}
import types.invocation_basis.{paramPolaritiesIn}
import types.effect_infer.{recordEffect, typeAuthority}
import types.effect_solver as EffectSolver
import types.scopes as Scopes
import map as IdMap

ioLabel : EffLabel
ioLabel = builtinLabel "IO"

-- `IO` is the join of the labels the drive's profile grants (`ioJoin`), so it
-- widens on either side of an escape check.  On the bound side a NARROW inferred
-- row is subsumed by an `<IO>` bound (narrow ⊑ IO); `IO` stays in the expansion
-- (atomsNorm keeps it) so an inferred IO matches a bound IO.
expandIoInBound : GraphCtx -> List Atom -> List Atom
expandIoInBound gctx b = match findAtom (labelKey ioLabel) b
  None => b
  Some _ => atomsNorm (b ++ gctx.config.value.tcIoJoin)

-- A performed `IO` left over against a bound without `IO` stands for the labels
-- it joins: a bound naming all of them admits it, a bound naming some refuses it
-- naming the labels it lacks, and a bound naming none leaves it as `IO`.  Only a
-- label of the join can cover a performed `IO`, so when the profile grants no
-- host label the join is empty, the bound names none of it, and `IO` stands.
narrowPerformedIo : GraphCtx -> List Atom -> List Atom -> List Atom
narrowPerformedIo gctx diff bound = match findAtom (labelKey ioLabel) diff
  None => diff
  Some _ =>
    let rest = filterList (x => atomKey x /= labelKey ioLabel) diff
    let join = gctx.config.value.tcIoJoin
    let missing = atomsDiff join bound
    if listLen missing == listLen join then
      diff
    else if isEmptyL missing then
      rest
    else
      atomsNorm (rest ++ missing)

-- escape-direction difference: inferred [a] not permitted by bound [b], with
-- `IO` widened to its security-label alias on both sides.
export
atomsEscape : GraphCtx -> List Atom -> List Atom -> List Atom
atomsEscape gctx a b =
  let bound = expandIoInBound gctx b
  narrowPerformedIo gctx (atomsDiff a bound) bound

newTyvarId : GraphCtx -> Unit -> Int
newTyvarId gctx _ =
  let n = gctx.graphRun.tyvarCounter.value
  gctx.graphRun.tyvarCounter := n + 1
  n

export
freshVar : ModuleCtx -> Unit -> Mono
freshVar mctx _ =
  TVar
    (Ref (Unbound (newTyvarId mctx.mcGraph ()) mctx.mcCells.currentLevel.value))

export
freshEffvar : ModuleCtx -> Unit -> Ref Effvar
freshEffvar mctx _ =
  Ref (EUnbound (newEffvarId mctx.mcGraph ()) mctx.mcCells.currentLevel.value)

export
freshEffvarAt : GraphCtx -> Int -> Ref Effvar
freshEffvarAt gctx lvl = Ref (EUnbound (newEffvarId gctx ()) lvl)

-- An inference-created row is a local existential choice. Publication retains
-- it if it is still reachable from the inferred value; otherwise scope solving
-- may close it. Declaration variables use freshEffvar directly, not this path.
freshInferenceEffvar : ModuleCtx -> Unit -> Ref Effvar
freshInferenceEffvar mctx _ =
  let cell = freshEffvar mctx ()
  EffectSolver.registerExistential mctx.mcCells.effectSummaries cell
  cell

export
openRow : ModuleCtx -> Unit -> EffRow
openRow mctx _ = EffRow [] (Some (freshInferenceEffvar mctx ()))

export
enterLevel : ModuleCtx -> Unit -> Unit
enterLevel mctx _ =
  mctx.mcCells.currentLevel := mctx.mcCells.currentLevel.value + 1

export
exitLevel : ModuleCtx -> Unit -> Unit
exitLevel mctx _ =
  mctx.mcCells.currentLevel := mctx.mcCells.currentLevel.value - 1

-- #821: a rigid method effect variable (its cell id is in the current impl
-- body's rigid set) must never be identified with another tail; two such tails
-- meeting in an ambient row JOIN instead.
isRigidCell : ModuleCtx -> Ref Effvar -> Bool
isRigidCell mctx cell =
  IdMap.has (effvarId cell) mctx.mcCells.rigidEffvarsRef.value

-- Accumulation records what ran. It never solves the performed row's variables:
-- two independently effectful computations contribute their join, not equality.
export
performEffect : ModuleCtx -> Ref (List EffRow) -> EffRow -> Unit
performEffect mctx cur eff =
  recordEffectSites mctx eff
  recordEffect cur eff

-- Most performed rows carry no atom of their own (a pure call, a row that
-- is one tail variable), and those cost nothing here: the key is built only
-- for an atom that is present.
recordEffectSites : ModuleCtx -> EffRow -> Unit
recordEffectSites mctx (EffRow [] _) = ()
recordEffectSites mctx eff =
  fold
    (_ atom =>
      let key = effectSiteKey mctx.mcCells.currentFn.value (atomKey atom)
      let sites = optionOr [] (omLookup key mctx.mcCells.effectSitesRef.value)
      mctx.mcCells.effectSitesRef :=
        omInsert
          key
          ((atomAuth atom, mctx.mcLoc) :: sites)
          mctx.mcCells.effectSitesRef.value)
    ()
    (fst (rowFlat eff))

export
effectSiteKey : String -> String -> String
effectSiteKey fn label = "\{fn}\t\{label}"

obligationSiteHere : ModuleCtx -> Bool -> ObligationSite
obligationSiteHere mctx covering = ObligationSite {
  osLoc = mctx.mcLoc,
  osFn = mctx.mcCells.currentFn.value,
  osCovering = covering,
}

deferEffectRelation : ModuleCtx -> Bool -> EffRow -> EffRow -> Unit
deferEffectRelation mctx exact lower upper =
  EffectSolver.recordRelation
    mctx.mcCells.effectSummaries
    exact
    (obligationSiteHere mctx False)
    lower
    upper

-- An index slot is invariant.  A flexible variable on either side takes the
-- other side as its solution outright — a substitution, as an alias
-- parameter's or an impl head's variable is — so a match or an improvement
-- loop that unifies indices sees progress rather than a pair of pending
-- obligations; two determined terms (constants, rigids, joins) record the
-- equality as the pair of obligations the scope checks.
unifyIndex : ModuleCtx -> Authority -> Authority -> Unit
unifyIndex mctx qa qb = match (authNorm qa, authNorm qb)
  (AVar a, b) if flexibleIndex mctx a b => substituteIndex mctx a b
  (a, AVar b) if flexibleIndex mctx b a => substituteIndex mctx b a
  (a, b) =>
    wantAuthorityWith mctx True a b
    wantAuthorityWith mctx True b a

-- A pattern-ranging cell takes only a pattern-ranging term (EFFECTS-SEMANTICS
-- §4.1): the term's flexible variables are narrowed to patterns with it,
-- since the equation makes them one authority, but an exact element or a
-- variable a caller chooses over the whole domain cannot be, and the
-- equation is refused.
substituteIndex : ModuleCtx -> Ref Authvar -> Authority -> Unit
substituteIndex mctx cell term =
  if authvarIsPattern cell && not (authIsPattern term) then
    let fixed = indexOutsidePatterns mctx term
    if isEmptyL fixed then
      fold
        (_ v => if authvarIsPattern v then () else markAuthvarPattern v)
        ()
        (authVars term)
    else
      pushTypeError mctx "T-AUTHORITY-PATTERN" (patternIndexMsg term)
  substituteIndexLinked mctx cell term

-- The operands of [term] no narrowing brings into the pattern range: a
-- constant that is not a pattern, and a rigid variable that is not
-- pattern-ranging.
indexOutsidePatterns : ModuleCtx -> Authority -> List Authority
indexOutsidePatterns mctx term =
  let members = match authNorm term
    AJoin ms => ms
    other => [other]
  filterList
    (m => match m
      AVar c =>
        not (authvarIsPattern c)
          && IdMap.has (authvarId c) mctx.mcCells.rigidAuthvarsRef.value
      other => not (authIsPattern other))
    members

substituteIndexLinked : ModuleCtx -> Ref Authvar -> Authority -> Unit
substituteIndexLinked mctx cell term =
  lowerAuthLevels (authvarLevel cell) term
  if authHasVars term then
    ()
  else
    mctx.mcCells.indexSubstitutedRef :=
      IdMap.set (authvarId cell) () mctx.mcCells.indexSubstitutedRef.value
  linkAuthvar cell term

flexibleIndex : ModuleCtx -> Ref Authvar -> Authority -> Bool
flexibleIndex mctx cell other =
  not (IdMap.has (authvarId cell) mctx.mcCells.rigidAuthvarsRef.value)
    && not (anyList (c => authvarId c == authvarId cell) (authVars other))

-- Ordinary row equality can solve flexible cells, never declaration universals.
-- Binding-owned summaries instead record both directions for scoped solving.
unifyRow : DynCtx -> EffRow -> EffRow -> Unit
unifyRow dyn r1 r2 = unifyRowN dyn (effrowNorm r1) (effrowNorm r2)

-- Joins and universal leaves use the role-aware unifier. Plain flexible rows
-- retain the cheaper single-tail unification path.
unifyRowN : DynCtx -> EffRow -> EffRow -> Unit
unifyRowN dyn r1 r2 =
  if rowHasSummary r1 || rowHasSummary r2 then
    deferEffectRelation dyn.dcModule False r1 r2
    deferEffectRelation dyn.dcModule False r2 r1
  else if rowTailIsJoin r1
    || rowTailIsJoin r2
    || rowHasRigid dyn.dcModule r1
    || rowHasRigid dyn.dcModule r2 then
    unifyJoinRows dyn.dcModule False r1 r2
  else
    unifyRowPlain dyn r1 r2

-- Equality may solve a flexible variable toward a declared universal, but
-- never the reverse. The join unifier already partitions cells by this role.
rowHasRigid : ModuleCtx -> EffRow -> Bool
rowHasRigid mctx row = match mctx.mcCells.rigidEffvarsRef.value
  Tip => False
  _ => anyList (isRigidCell mctx) (snd (rowFlat row))

rowTailIsJoin : EffRow -> Bool
rowTailIsJoin (EffRow _ (Some c)) = isJoinCell c
rowTailIsJoin (EffRow _ None) = False

-- ── #821: unifying rows whose tails are JOINS ─────────────────────────────
-- Both rows are taken apart into (atoms, unbound member cells).  Members
-- common to both sides cancel; what remains on each side is split into RIGID
-- members (a method effect variable of the impl body being checked — never
-- bound) and FLEXIBLE ones (ordinary metavariables).  The spec's discipline
-- (EFFECTS-SEMANTICS §6, "unification never decomposes a join") is honoured by
-- never binding a rigid member: a join is solved only by binding the flexible
-- members on each side to whatever the OTHER side has left over, which is the
-- ordinary open-absorbs rule generalized from one tail to a set.  A rigid
-- member with nothing on the other side to match it is a genuine mismatch.
--   * flexible on both sides — every flexible member is bound to a fresh
--     shared tail joined with the other side's rigid residue (the plain
--     BOTH-OPEN arm, over sets);
--   * flexible on one side only — those members are bound to the other side's
--     residue; a closed residue also runs the §5 leak check on the open side's
--     atoms (the plain OPEN~CLOSED arm), and in INDEX mode the atoms must be
--     equal (the plain index arm);
--   * no flexible member anywhere — the rigid residues must both be empty and
--     (index mode) the atoms equal; an arrow row with equal member sets and
--     differing prefixes keeps the plain SAME-TAIL arm's leniency.
unifyJoinRows : ModuleCtx -> Bool -> EffRow -> EffRow -> Unit
unifyJoinRows mctx isIndex r1 r2 =
  let fa = rowFlat r1
  let fb = rowFlat r2
  let ma = snd fa
  let mb = snd fb
  let idsA = cellIdSet ma
  let idsB = cellIdSet mb
  let common = filterList (c => IdMap.has (effvarId c) idsB) ma
  -- a SHARED flexible member can absorb either side's leftovers too:
  -- `x ⊔ R` against `x` is solved by `x := x' ⊔ R` (both sides gain R).
  let cflex = filterList (c => not (isRigidCell mctx c)) common
  let onlyA = filterList (c => not (IdMap.has (effvarId c) idsB)) ma
  let onlyB = filterList (c => not (IdMap.has (effvarId c) idsA)) mb
  let rigidA = filterList (isRigidCell mctx) onlyA
  let flexA = filterList (c => not (isRigidCell mctx c)) onlyA
  let rigidB = filterList (isRigidCell mctx) onlyB
  let flexB = filterList (c => not (isRigidCell mctx c)) onlyB
  -- An index with no flexible member on either side has no room for an
  -- atom the other side lacks, so its shared labels are equal as indices.
  if isIndex && isEmptyL flexA && isEmptyL flexB && isEmptyL cflex then
    unifyIndexAtomAuthorities mctx (fst fa) (fst fb)
  let dA = atomsDiff (fst fa) (fst fb)
  let dB = atomsDiff (fst fb) (fst fa)
  -- A's leftovers (rigidA, dA) must be absorbed on B's side: by B's own
  -- flexible leftovers if any, else by a shared flexible member.
  let bindC =
    isNonEmptyL cflex
      && (isNonEmptyL rigidA && isEmptyL flexB
        || isNonEmptyL rigidB && isEmptyL flexA
        || isNonEmptyL dA && isEmptyL flexB
        || isNonEmptyL dB && isEmptyL flexA)
  let useV3 = isNonEmptyL flexA && isNonEmptyL flexB || bindC
  let v3s =
    if useV3 then
      [freshEffvarAt mctx.mcGraph (minLevelOf (flexA ++ flexB ++ cflex))]
    else
      []
  if isNonEmptyL rigidA && isEmptyL flexB && not bindC then
    joinMismatch mctx isIndex fa fb
  if isNonEmptyL rigidB && isEmptyL flexA && not bindC then
    joinMismatch mctx isIndex fa fb
  if isNonEmptyL dA && isEmptyL flexB && not bindC then
    joinSideCheck mctx isIndex dA dB (fst fa) (fst fb)
  if isNonEmptyL dB && isEmptyL flexA && not bindC then
    joinSideCheck mctx isIndex dB dA (fst fb) (fst fa)
  bindEach flexA (rowOfMembers mctx.mcGraph dB (v3s ++ rigidB))
  bindEach flexB (rowOfMembers mctx.mcGraph dA (v3s ++ rigidA))
  if bindC then
    bindEach
      cflex
      (rowOfMembers mctx.mcGraph (atomsUnion dA dB) (v3s ++ rigidA ++ rigidB))
  match v3s
    v3 :: _ => recordAbsorptions mctx (dA ++ dB) v3
    [] => ()

bindEach : List (Ref Effvar) -> EffRow -> Unit
bindEach [] _ = ()
bindEach (c :: cs) row =
  linkRow c row
  bindEach cs row

-- the open side's atoms [dOpen] escaping the closed side's bound: the plain
-- OPEN~CLOSED arm's leak check for arrows, coverage for an index.
joinSideCheck : ModuleCtx ->
  Bool ->
  List Atom ->
  List Atom ->
  List Atom ->
  List Atom ->
  Unit
joinSideCheck mctx True dOpen _ lOpen lClosed =
  indexRowEqCheck mctx (indexAtomsCovered mctx dOpen lClosed) [] lOpen lClosed
joinSideCheck mctx False _ _ lOpen lClosed =
  effectLeakCheck mctx (atomsEscape mctx.mcGraph lOpen lClosed) lClosed

joinMismatch : ModuleCtx ->
  Bool ->
  (List Atom, List (Ref Effvar)) ->
  (List Atom, List (Ref Effvar)) ->
  Unit
joinMismatch mctx isIndex fa fb =
  pushTypeError
    mctx
    (if isIndex then "T-EFFECT-INDEX-MISMATCH" else "T-EFFECT-LEAK")
    (joinMismatchMsg (renderFlatRow fa) (renderFlatRow fb))

-- #839 STRICTNESS AUDIT.  The four arms below are classified against
-- EFFECTS-SEMANTICS §5 (docs/spec/EFFECTS-SEMANTICS.md:335-371) and §6
-- (:406-451).  Each open-tailed arm can ABSORB or DISCARD a concrete effect
-- atom; whether that loss is load-bearing subtyping-via-reopen or accidental
-- leniency decides whether a downstream soundness check must RACE this unifier
-- (run pre-unify) or may inspect its result.  This records that relevance AT
-- the arm rather than only ~12k lines away in checkImplEffectLaunder's comment.
-- Per-arm verdicts inline.  The eventual fix (#839 increments 2a-2c) is an
-- absorption event trail so a post-unify QUERY can substitute for the pre-unify
-- races; a post-unify cell inspection alone CANNOT recover an absorbed atom
-- (see the both-open note), which is the whole reason the trail is needed.
-- (Intra-file refs below name SYMBOLS, not line numbers — the latter rot; the
-- §N (:lines) spec cites point into EFFECTS-SEMANTICS.md, verified current.)
unifyRowPlain : DynCtx -> EffRow -> EffRow -> Unit
unifyRowPlain dyn (EffRow l1 (Some v1)) (EffRow l2 (Some v2))
  -- L1 ∪ r = L2 ∪ r requires every unmatched atom to belong to r. Preserve
  -- that lower bound by extending the shared tail, just as the join unifier
  -- does for a shared flexible member. Merely recording an absorption loses
  -- the effect when r is a recursive binding's forcing row. Equal prefixes
  -- need no mutation. A caller-chosen tail cannot acquire such a lower bound.
  | effvarId v1 == effvarId v2 =
    let missing = atomsUnion (atomsDiff l1 l2) (atomsDiff l2 l1)
    match missing
      [] => ()
      _ =>
        if isRigidCell dyn.dcModule v1 then
          pushTypeError
            dyn.dcModule
            "T-EFFECT-LAUNDER"
            "a caller-chosen effect row cannot be required to contain <\{renderAtoms missing}>; declare those effects as labels beside the row variable"
        else
          let next = freshEffvarAt dyn.dcModule.mcGraph (effvarLevel v1)
          linkRow v1 (EffRow missing (Some next))
          recordAbsorptions dyn.dcModule missing next
  -- BOTH-OPEN arm (v1 /= v2): two distinct open tails.  Merges each side's
  -- missing atoms (atomsDiff l2 l1, atomsDiff l1 l2) into a shared fresh tail v3
  -- and links both old tails to it — after this, effrowLabels on either cell
  -- resolves THROUGH v3 and no longer distinguishes intrinsic vs argument-borne
  -- atoms; the atoms are ABSORBED into the shared tail.  LOAD-BEARING: this is
  -- the standard subtyping-via-row-polymorphism encoding §5 (:361) relies on and
  -- the effect-parametricity of map/andThen/fold/traverse §6 (:388-396) — an
  -- open row "can absorb further atoms".  KEEP.  Note it deliberately runs NO
  -- effectLeakCheck (contrast the two closed-side arms just below, which DO): an
  -- open tail has not committed to a bound, so nothing can escape PAST it yet.
  -- That asymmetry is why #803's intrinsic-atom bound runs POST-unify (#839 2b,
  -- launderEscapeFromLog) rather than PRE-unify: a naive post-unify effrowLabels
  -- inspection CANNOT recover the absorbed atom, so the atoms are recorded HERE
  -- (recordAbsorptions) and the trail carries what effrowLabels no longer can.
  | otherwise =
    let v3 =
      freshEffvarAt
        dyn.dcModule.mcGraph
        (minI (effvarLevel v1) (effvarLevel v2))
    let d21 = atomsDiff l2 l1
    let d12 = atomsDiff l1 l2
    -- #821: rigidity follows the REPRESENTATIVE.  A method effect variable of
    -- the impl body being checked (`rigidEffvarsRef`) linked into the shared
    -- fresh tail makes that tail rigid too, so `performEffect`/`unifyJoinRows`
    -- still see the variable after `inferApp` has unified the callee's row
    -- with a fresh one.  Two rigid tails meeting here still identify (the dup
    -- check downstream reports it), exactly as before.
    if isRigidCell dyn.dcModule v1 || isRigidCell dyn.dcModule v2 then
      dyn.dcModule.mcCells.rigidEffvarsRef :=
        IdMap.set (effvarId v3) () dyn.dcModule.mcCells.rigidEffvarsRef.value
    linkRow v1 (EffRow d21 (Some v3))
    linkRow v2 (EffRow d12 (Some v3))
    -- #839 2a: both diffs vanish into the shared fresh tail v3; record them
    -- against v3 (the surviving tail).  The setRef links above are UNCHANGED —
    -- d21/d12 are the same values inlined before, so unification is byte-identical.
    recordAbsorptions dyn.dcModule (d21 ++ d12) v3
-- OPEN~CLOSED / CLOSED~OPEN arms: GUARDED — each runs effectLeakCheck (atomsEscape …),
-- §5's binding-boundary escape check (:339-351), checking the OPEN side's labels against
-- the CLOSED side's bound at the open-meets-closed seam.  (Absorbing into a CLOSED tail is
-- the guarded direction.)
unifyRowPlain dyn (EffRow l1 (Some v1)) (EffRow l2 None) =
  effectLeakCheck dyn.dcModule (atomsEscape dyn.dcModule.mcGraph l1 l2) l2
  linkRow v1 (EffRow (atomsDiff l2 l1) None)
unifyRowPlain dyn (EffRow l1 None) (EffRow l2 (Some v2)) =
  effectLeakCheck dyn.dcModule (atomsEscape dyn.dcModule.mcGraph l2 l1) l1
  linkRow v2 (EffRow (atomsDiff l1 l2) None)
-- CLOSED~CLOSED arm: EQUALITY, via `closedRowEqCheck` (#2557).  Two written rows
-- have no tail to bind and this unifier has no expected/actual role, so the only
-- sound symmetric verdict is that the atom sets match.  A silent no-op here is wrong:
-- a plain generic reaches this arm with no downstream consumer of the direction
-- (`launderEscapeFromLog` is consulted only by the impl/default-method seam), so
-- `coerce : a -> a -> a` applied to two callbacks whose PARAMETER rows differ (`<IO>`
-- vs `<>`) would equate them, `reopenRowN` reopens only covariant rows, and the result
-- would carry one closure's declared type with the other's body.  The
-- purer-than-declared case (an impl `<>` against a declared `<Stdout>`) is real, but it
-- is a DIRECTED flow (a value into a declared slot), and every such seam takes
-- `unifyInto`, which checks a closed~closed pair directionally and never brings one
-- here.  Index rows route to `unifyIndexRow` below, NOT here — an index is invariant by
-- kind (#1094); do not re-point `unifyN`'s `TEff`/`TEff` arm at `unifyRow`.
unifyRowPlain dyn (EffRow l1 None) (EffRow l2 None) = closedRowEqCheck dyn l1 l2

-- ── the INDEX row unifier (#1094) ──────────────────────────────────────────
-- `Mono` carries two different kinds of row and they obey different rules:
--   * `TFun _ EffRow _` — an arrow's LATENT row.  Sub-effecting via row-polymorphic
--     re-open (§5) is load-bearing; `unifyRow` above is written for it.
--   * `TEff EffRow`     — a row in an `Effect`-kinded type-argument (INDEX) slot.
--     EFFECTS-SEMANTICS §9 "Index fidelity": `F φ₁ τ̄` and `F φ₂ τ̄` are interchangeable
--     only when `φ₁ = φ₂`.  INVARIANT — no direction of `≤` is licensed here.  A
--     parameter's polarity is not knowable without a variance analysis, which this
--     compiler does not have, and a CONTRAVARIANT index is writable today
--     (`data Sink e = MkSink ((Unit -> <e> Unit) -> Int)`), so widening in EITHER
--     direction launders an effect.  Only equality is sound.
-- `substMonoP` already encodes this distinction (it wraps an arrow row in `reopenRow`
-- and passes a `TEff` row through UNCHANGED); routing both through one unifier threw
-- that decision away.  This restores the agreement.
--
-- Invariance is not "both sides closed and equal" checked at the top.  Solving an
-- index METAVARIABLE against a written row is instantiation, not interchange, and must
-- keep working — `test/typecheck_error_fixtures/graded_closed_row_grade_ok.mdk:17`
-- (`mkPure : a -> Async <> a`, body `Done x`) unifies a FRESH OPEN effvar against the
-- written closed `<>`.  So the OPEN-tailed cases are not blanket-rejected.
--
-- BUT "every open-tailed arm of `unifyRowN` is already invariance-correct" is FALSE,
-- and an earlier revision of this comment said it.  Exactly TWO of the three open-tailed
-- shapes are:
--   * open~closed / closed~open — binds the tail to the exact difference and
--     `effectLeakCheck`s the residue.  Correct: there is a metavariable to solve.
--   * BOTH-OPEN with DISTINCT tails — ordinary Rémy/Wand unification into a shared fresh
--     tail.  Correct: two metavariable-tailed rows CAN be made equal, and the join is the
--     most general row equal to both.
--   * SAME-TAIL with DIFFERING PREFIXES (`<Stdout | e>` ~ `<e>`, the same physical
--     effvar) — NOT correct.  `unifyRowN`'s own arm DISCARDS the symmetric difference
--     ("the atom evaporates … ACCIDENTAL leniency, NOT load-bearing", ~60 lines above).
--     There is nothing left to solve — the tails are already the same cell — so the
--     differing prefixes are two genuinely different rows, and dropping the difference is
--     precisely the widening invariance forbids.  `launderBox : Box <Stdout | e> a ->
--     Box e a` was accepted, and a value typed `Int` printed.  Hence the same-tail arm
--     below, BEFORE the delegation.
--     The benign self-unify `e ~ e` (equal prefixes, including two empty ones) has an
--     EMPTY diff in both directions, so `relay : Box e a -> Box e a` stays green.
--     Nothing is lost by intercepting here: the arm this pre-empts would have called
--     `recordAbsorptions` on exactly this symmetric difference, and a non-empty
--     difference is now an error instead of a silently-absorbed atom, while an empty one
--     recorded nothing to begin with.
--     Do not copy this arm onto `unifyRowN`'s ARROW same-tail arm.  The same discard
--     launders there too (`launderArrow : (Unit -> <Stdout | e> Unit) -> (Unit -> <e>
--     Unit)` is accepted), but that arm's leniency is NOT the same call: the covering
--     rule for it was deliberately pushed to DECLARATION time (T-EFFECT-ARG-UNCOVERED /
--     `checkArgEffVars`, whose own comment cites that arm), and the recordAbsorptions →
--     `launderEscapeFromLog` trail depends on it.  Tightening the arrow side is a design
--     decision with its own blast radius, tracked separately — not a copy-paste of this.
unifyIndexRow : DynCtx -> EffRow -> EffRow -> Unit
unifyIndexRow dyn r1 r2 = unifyIndexRowN dyn (effrowNorm r1) (effrowNorm r2)

-- An index row is a set of atoms, and two index rows are equal when each
-- covers the other (EFFECTS-SEMANTICS §6.4, §2.2).  Two atoms of one label at
-- different authorities are two members of that set, not one authority to be
-- equated: `<Net h | e1>` and `<Net "127.0.0.1" | e2>` are made equal by
-- giving each open tail the other side's atom, and `<Net h | e1>` equals
-- `<Net | e>` because the bare label covers `Net h`.  So an atom one side
-- does not cover flows into the other side's flexible tail when there is one;
-- only a side with no room must cover it, as an index obligation
-- (`indexAtomsCovered`).  Where NEITHER side has a flexible tail, a shared
-- label's two authorities are equal as indices (`unifyIndex`): a flexible
-- one is substituted, two fixed ones are compared for equality, and what is
-- left for the row comparison is which labels each side carries.
unifyIndexAtomAuthorities : ModuleCtx -> List Atom -> List Atom -> Unit
unifyIndexAtomAuthorities mctx a1 a2 =
  fold
    (_ x => match findAtom (atomKey x) a2
      Some y => unifyIndex mctx (atomAuth x) (atomAuth y)
      None => ())
    ()
    a1

-- #821: an index row whose tail is a join is solved by the join unifier in
-- INDEX mode (equality, never subsumption).  A row with a summary cell goes
-- to the scoped solver as two exact relations, whose coverage is already
-- atom by atom.
unifyIndexRowN : DynCtx -> EffRow -> EffRow -> Unit
unifyIndexRowN dyn r1 r2 =
  if rowHasSummary r1 || rowHasSummary r2 then
    deferEffectRelation dyn.dcModule True r1 r2
    deferEffectRelation dyn.dcModule True r2 r1
  else if rowTailIsJoin r1
    || rowTailIsJoin r2
    || rowHasRigid dyn.dcModule r1
    || rowHasRigid dyn.dcModule r2 then
    unifyJoinRows dyn.dcModule True r1 r2
  else
    unifyIndexRowPlain dyn r1 r2

-- Both closed, or the same tail: nothing can absorb an atom, so the rows are
-- equal label by label.  Open against closed: the closed side's extra atoms
-- are the open tail's solution, and the open side's atoms must be covered by
-- the closed side (the §5 leak check, with a shared label's authority an
-- index obligation).  Two distinct open tails: each takes what the other
-- side has that it does not cover, into one fresh shared tail.
unifyIndexRowPlain : DynCtx -> EffRow -> EffRow -> Unit
unifyIndexRowPlain dyn (EffRow l1 None) (EffRow l2 None) =
  indexRowEquate dyn.dcModule l1 l2
unifyIndexRowPlain dyn (EffRow l1 (Some v1)) (EffRow l2 (Some v2))
  | effvarId v1 == effvarId v2 = indexRowEquate dyn.dcModule l1 l2
unifyIndexRowPlain dyn (EffRow l1 (Some v1)) (EffRow l2 None) =
  indexOpenClosed dyn.dcModule l1 v1 l2
unifyIndexRowPlain dyn (EffRow l1 None) (EffRow l2 (Some v2)) =
  indexOpenClosed dyn.dcModule l2 v2 l1
unifyIndexRowPlain dyn r1 r2 = unifyRowPlain dyn r1 r2

indexRowEquate : ModuleCtx -> List Atom -> List Atom -> Unit
indexRowEquate mctx l1 l2 =
  unifyIndexAtomAuthorities mctx l1 l2
  indexRowEqCheck mctx (labelsMissing l1 l2) (labelsMissing l2 l1) l1 l2

indexOpenClosed : ModuleCtx -> List Atom -> Ref Effvar -> List Atom -> Unit
indexOpenClosed mctx lOpen v lClosed =
  effectLeakCheck
    mctx
    (indexAtomsCovered mctx (atomsEscape mctx.mcGraph lOpen lClosed) lClosed)
    lClosed
  linkRow v (EffRow (atomsDiff lClosed lOpen) None)

-- The atoms of [escaping] whose label [bound] does not carry.  An escaping
-- atom whose label the bound does carry is not missing from it: its
-- authority must lie within the bound's, which is recorded as an index
-- obligation, so a variable is solved and a mismatch reads as an atom the
-- bound does not cover (`wantIndexCovered`).
indexAtomsCovered : ModuleCtx -> List Atom -> List Atom -> List Atom
indexAtomsCovered mctx [] _ = []
indexAtomsCovered mctx (x :: rest) bound = match findAtom (atomKey x) bound
  Some y =>
    wantIndexCovered mctx (atomAuth x) (atomAuth y)
    indexAtomsCovered mctx rest bound
  None => x :: indexAtomsCovered mctx rest bound

-- The atoms of [l1] whose label [l2] does not carry.  A shared label's two
-- authorities were already equated by `unifyIndexAtomAuthorities`, which
-- reports their mismatch as an authority index, so it is not a second report
-- here.
labelsMissing : List Atom -> List Atom -> List Atom
labelsMissing l1 l2 =
  filterList
    (x => match findAtom (atomKey x) l2
      Some _ => False
      None => True)
    l1

-- Two index rows with nothing left to solve — both closed, or both already ending in the
-- SAME effvar cell — are the same type iff neither side carries an atom the other lacks.
-- `atomsDiff` (not `atomsEscape`) on purpose: `expandIoInBound` widens a bound's
-- `IO` into the security-label alias, which is a SUBSUMPTION step — exactly the ≤ that
-- invariance forbids here, so `<IO>` and `<Stdout>` are different index rows.
indexRowEqCheck : ModuleCtx ->
  List Atom ->
  List Atom ->
  List Atom ->
  List Atom ->
  Unit
indexRowEqCheck mctx [] [] _ _ = ()
indexRowEqCheck mctx _ _ l1 l2 =
  pushTypeError mctx "T-EFFECT-INDEX-MISMATCH" (indexRowMismatchMsg l1 l2)

-- SOUNDNESS (Phase 146): an open row (an inference-synthesized arrow, i.e. a
-- concrete value's latent effect) meeting a closed bound — its own labels must
-- not exceed the bound, else they escape.  [escaping] = open labels \ bound.
export
effectLeakCheck : ModuleCtx -> List Atom -> List Atom -> Unit
effectLeakCheck mctx [] bound = ()
effectLeakCheck mctx escaping bound =
  pushTypeError mctx "T-EFFECT-LEAK" (effectLeakMsg mctx.mcGraph bound escaping)

-- Two CLOSED rows meeting at `unify` must carry the same atoms (#2557).  Neither
-- has a tail to bind, and `unify` has no expected/actual role to read a direction
-- from, so equality is the only sound symmetric rule — the rule `unifyIndexRow`
-- already applies to an index and the non-covariant slot rule applies to a type
-- argument.  A seam that DOES know which side is the declaration (a signed body,
-- a call argument, a supplied field, an annotated expression, an impl method)
-- goes through `unifyInto`, which checks a closed~closed pair directionally and
-- never brings one here.  Equality is modulo the `IO` alias — each side's atoms
-- must be covered by the other's (`atomsEscape` both ways), so `<IO>` and
-- `<IO, Stderr>`, one denotation in two spellings, are equal, while `<IO>` and
-- `<Stderr>` are not.  Inside a non-covariant type argument the mismatch takes
-- the variance wording, which names that slot and its eta-expansion recovery.
closedRowEqCheck : DynCtx -> List Atom -> List Atom -> Unit
closedRowEqCheck dyn l1 l2 = match (
  atomsEscape dyn.dcModule.mcGraph l1 l2,
  atomsEscape dyn.dcModule.mcGraph l2 l1,
)
  ([], []) => ()
  _ =>
    if dyn.dcNonCovariant then
      pushTypeError
        dyn.dcModule
        "T-EFFECT-PARAM-VARIANCE"
        (paramVarianceMismatchMsg l1 l2)
    else
      pushTypeError dyn.dcModule "T-EFFECT-LEAK" (closedRowMismatchMsg l1 l2)

effectLeakMsg : GraphCtx -> List Atom -> List Atom -> String
effectLeakMsg gctx bound extras =
  "performs <\{renderAtoms extras}> where only <\{renderAtoms bound}> is allowed\{ioJoinClause gctx (bound ++ extras)}"

-- What `IO` means on the selected profile, for a message naming `IO` there:
-- the reader cannot otherwise tell why `IO` does not cover a host label.
-- Empty when `IO` joins every host label at its top.
ioJoinClause : GraphCtx -> List Atom -> String
ioJoinClause gctx atoms =
  let join = gctx.config.value.tcIoJoin
  let full = map (atomOfLabel gctx.effectDomains.value) hostLabels
  if isSome (findAtom (labelKey ioLabel) atoms)
    && isNonEmptyL (atomsDiff full join) then
    "; `IO` on `\{gctx.config.value.tcIoJoinProfile}` is <\{renderAtoms join}>"
  else
    ""

-- lower a row's tail effvar level to <= [level] alongside the tyvar being bound
-- A row's level is its tail's and every authority its atoms name: a row that
-- reaches an older binding carries its atoms' authorities with it, so they
-- are lowered with the tail (an authority left at an arm's level would read
-- as local to the arm after it escaped through the row).
export
lowerRowLevels : Int -> EffRow -> Unit
lowerRowLevels level r =
  let (atoms, members) = rowFlat r
  lowerMembers level members
  fold (_ a => lowerAuthLevels level (atomAuth a)) () atoms

lowerMembers : Int -> List (Ref Effvar) -> Unit
lowerMembers _ [] = ()
lowerMembers level (m :: ms) =
  match !m
    EUnbound id lvl => if lvl > level then m := EUnbound id level
    _ => ()
  lowerMembers level ms

-- free generalizable effect variables: a row tail effvar deeper than the current
-- scope (deduped by the caller, mirroring freeGenVars)
freeEffvars : ModuleCtx -> Mono -> List Int
freeEffvars mctx t = match normalize t
  TVar cell => match !cell
    Link t2 => freeEffvars mctx t2
    Unbound _ _ => []
  TCon _ _ => []
  TRigid _ => []
  TApp a b => freeEffvars mctx a ++ freeEffvars mctx b
  TFun a r b =>
    freeEffvars mctx a ++ rowFreeEffvars mctx r ++ freeEffvars mctx b
  TEff r => rowFreeEffvars mctx r
  TQual a _ => freeEffvars mctx a
  TAuth _ => []

rowFreeEffvars : ModuleCtx -> EffRow -> List Int
rowFreeEffvars mctx r = flatMap (generalizableEffvar mctx) (snd (rowFlat r))

generalizableEffvar : ModuleCtx -> Ref Effvar -> List Int
generalizableEffvar mctx v = match !v
  EUnbound id lvl => if lvl > mctx.mcCells.currentLevel.value then [id] else []
  ELink _ _ => []
  EJoin _ _ _ => []
  ESummary _ _ _ => []

-- The inverse function-slot projections.  A malformed carrier (non-singleton bound ids,
-- or a known vector after an unknown one) deliberately loses that field so the live
-- round-trip comparator below panics instead of silently normalising it.
export
predicateSlotCSlots : List PredicateSlot -> List CSlot
predicateSlotCSlots [] = []
predicateSlotCSlots (s :: rest) = match s.psBoundIds
  id :: _ =>
    CSlot { csIface = s.psIface, csId = id } :: predicateSlotCSlots rest
  _ => predicateSlotCSlots rest

export
predicateSlotArgs : List PredicateSlot -> List (List Mono)
predicateSlotArgs [] = []
predicateSlotArgs (slot :: rest) = match slot.psArgs
  PSArgsUnknown => []
  PSArgsKnown args => args :: predicateSlotArgs rest

-- The single recorder for the (now-ported) call channel: every producer becomes a
-- thin caller stamping its own provenance.
export
recordObl : ModuleCtx -> Predicate -> Int -> Provenance -> Option Loc -> Unit
recordObl mctx p originId prov loc =
  recordOblAt mctx p originId prov loc (captureScope mctx ())

export
recordOblAt : ModuleCtx ->
  Predicate ->
  Int ->
  Provenance ->
  Option Loc ->
  ScopeId ->
  Unit
recordOblAt mctx p originId prov loc scope = wPush
  mctx.mcCells.obls
  UObligation {
    pred = p,
    originId = originId,
    prov = prov,
    loc = loc,
    uoScope = scope,
    oblProj = OpProjected,
  }

-- #839 increment 2a: append one AbsorptionEvent per absorbed/discarded atom onto
-- the (write-only in 2a) trail, keyed on the surviving/absorbing tail [cell].
-- Recursive + []-short-circuits so the hot self-unify path (empty prefixes ⇒
-- empty diff) pushes NOTHING and allocates nothing.  Records the cell Ref, not
-- effvarId (see AbsorptionEvent), and snapshots the enclosing construct's span.
recordAbsorptions : ModuleCtx -> List Atom -> Ref Effvar -> Unit
recordAbsorptions mctx [] _ = ()
recordAbsorptions mctx (a :: rest) cell =
  wPush mctx.mcCells.absorptions AbsorptionEvent {
    atom = a,
    cell = cell,
    loc = mctx.mcLoc,
  }
  recordAbsorptions mctx rest cell

export
captureScope : ModuleCtx -> Unit -> ScopeId
captureScope mctx _ = Scopes.captureScopeCursor mctx.mcCells.currentScope.value

tyvarLevel : Ref Tyvar -> Int
tyvarLevel cell = match !cell
  Unbound _ lvl => lvl
  Link _ => 0

-- occurs-check + lower the levels of vars in [t] to <= [level] (Phase: Rémy levels)
occursAdjust : ModuleCtx -> Int -> Int -> Mono -> Unit
occursAdjust mctx id level t = match normalize t
  TVar cell => occursAdjustVar mctx id level cell
  TCon _ _ => ()
  TRigid _ => ()
  TApp a b =>
    occursAdjust mctx id level a
    occursAdjust mctx id level b
  TFun a r b =>
    occursAdjust mctx id level a
    lowerRowLevels level r
    occursAdjust mctx id level b
  TEff r => lowerRowLevels level r
  TQual a q =>
    lowerAuthLevels level q
    occursAdjust mctx id level a
  TAuth q => lowerAuthLevels level q

occursAdjustVar : ModuleCtx -> Int -> Int -> Ref Tyvar -> Unit
occursAdjustVar mctx id level cell = match !cell
  Unbound id2 lvl2 => occursAdjustUnbound mctx id level cell id2 lvl2
  Link t => occursAdjust mctx id level t

occursAdjustUnbound : ModuleCtx -> Int -> Int -> Ref Tyvar -> Int -> Int -> Unit
occursAdjustUnbound mctx id level cell id2 lvl2
  | id2 == id =
    mctx.mcCells.occursCheckFailed := True
    pushTypeError
      mctx
      "T-INFINITE-TYPE"
      ("cannot construct an infinite type involving `"
        ++ ppMono (TVar cell)
        ++ "`")
  | lvl2 > level = cell := Unbound id2 level
  | otherwise = ()

-- Two VALUE types equated.  A top-level qualifier erases: undirected
-- unification cannot tell which side is the value, so it may neither let a
-- variable's value claim the other side's authority nor demand a proof of the
-- plain side.  A qualifier reaches a variable only through a directed flow —
-- an argument (`argumentInto`), a declared parameter, a match scrutinee or a
-- call's result (`bindFrom`), a cell read (`refStored`).  Below the top the
-- types are structure, not values, and `unifyN` keeps qualifiers equal.
--
-- `unify` is the call from outside every construct that sets a dynamic context;
-- the unification core takes the caller's `DynCtx` (`unifyIn`).
export
unify : ModuleCtx -> Mono -> Mono -> Unit
unify mctx a b = unifyIn (dynFor mctx) a b

export
unifyIn : DynCtx -> Mono -> Mono -> Unit
unifyIn dyn a b = unifyValue dyn (normalize a) (normalize b)

unifyValue : DynCtx -> Mono -> Mono -> Unit
unifyValue dyn (TVar c) (TQual a _) = unifyN dyn (TVar c) (normalize a)
unifyValue dyn (TQual a _) (TVar c) = unifyN dyn (normalize a) (TVar c)
unifyValue dyn (TQual a _) (TQual b _) = unifyN dyn (normalize a) (normalize b)
unifyValue dyn (TQual a _) b = unifyN dyn (normalize a) b
unifyValue dyn a (TQual b _) = unifyN dyn a (normalize b)
unifyValue dyn a b = unifyN dyn a b

-- Structural equality: inside a constructor argument, an arrow or an index, a
-- qualifier is part of the type.  A variable takes a qualified type verbatim,
-- two qualifiers must cover each other, and a qualified type against a plain
-- one is equal only where the qualifier admits the domain's top — a `Ref`
-- holding `String @p` cannot be the same cell as one holding any `String`.
unifyStruct : DynCtx -> Mono -> Mono -> Unit
unifyStruct dyn a b = unifyN dyn (normalize a) (normalize b)

unifyN : DynCtx -> Mono -> Mono -> Unit
unifyN dyn (TVar c1) (TVar c2) = unifyVars dyn c1 c2
unifyN dyn (TVar c) t = bindVar dyn c t
unifyN dyn t (TVar c) = bindVar dyn c t
-- The head comparison reads the tycon's identity: two modules' unrelated `T`s do not
-- unify (#1208, #1209), and the origin surviving a link does not depend on link
-- direction, so a key computed from the field is a function of the type.
-- `sameTyConHead` (`frontend/ast.mdk`) owns the absent-origin rule; read its
-- derivation before changing either side of this.
unifyN dyn (ta@(TCon a oa)) (tb@(TCon b ob)) =
  if sameTyConHead a oa b ob then () else typeMismatch dyn ta tb
-- Rigid~rigid.  MANDATORY: without it a rigid variable fails to unify with ITSELF (it
-- would fall to the catch-all `typeMismatch`), because `TRigid` is not a `TCon`.
unifyN dyn (TRigid a) (TRigid b) =
  if a == b then () else typeMismatch dyn (TRigid a) (TRigid b)
-- CROSS-POPULATION (#1110), and it is NOT dead code.  A rigid and a real head can
-- share a name — both spell `__tupleN__` (see `Mono.TRigid`) — so a `TCon a == TCon b`
-- style test can be TRUE across the populations, and dropping these two arms changes an
-- answer: `data Bad = Bad __tuple2__; g : Bad -> (,)` would become `Type mismatch: (,)
-- vs (,)` — an error whose two sides render IDENTICALLY.  For every other name the test
-- is False and the message is byte-identical to the catch-all's, since `ppMono` renders
-- `TRigid` exactly as `TCon`.  Placed ABOVE the `tupleUnifyClash` guard, as the
-- `TCon`/`TCon` arm is.
--
-- The preserved answer is a FORGERY (DICT-SEMANTICS §8 I6.2(b), OWED-#1110):
-- a rigid variable is not the builtin tuple head.  Carrier now, semantics later.
unifyN dyn (ta@(TCon a _)) (tb@(TRigid b)) =
  if a == b then () else typeMismatch dyn ta tb
unifyN dyn (ta@(TRigid a)) (tb@(TCon b _)) =
  if a == b then () else typeMismatch dyn ta tb
-- A tuple TYPE is a `__tupleN__`-headed `TApp` spine; when it clashes with a
-- differing-arity tuple or with a concrete non-tuple head, report the FULL types
-- (which render `(a, b)` via ppGo) instead of letting the generic `TApp~TApp`
-- recursion bottom out on a partial sub-spine.  Guard is False when the other side is a
-- TVar-headed spine (so `p a b` unifying with a tuple still flows through the generic arm).
unifyN dyn t1 t2
  | tupleUnifyClash t1 t2 = typeMismatch dyn t1 t2
-- #1119 D-2 (#1098, #1121): the VARIANCE gate.  `a1` is the partial spine, so
-- the number of `TApp` nodes already in `a1` is `b1`'s positional index.  When
-- the head's recorded polarity at that index is not `PCo`, an effect row inside
-- the argument must be EQUAL rather than merely compatible — see
-- `paramVarianceGuard`, which unifies the argument.
unifyN dyn (TApp a1 b1) (TApp a2 b2) =
  unifyStruct dyn a1 a2
  paramVarianceGuard dyn a1 b1 b2
unifyN dyn (TFun a1 r1 b1) (TFun a2 r2 b2) =
  unifyStruct dyn a1 a2
  unifyRow dyn r1 r2
  unifyStruct dyn b1 b2
-- #1094: an `Effect`-kinded type-ARGUMENT row is INVARIANT and gets its own unifier.
-- `unifyRow` is the ARROW-row unifier; its closed~closed leniency is justified for a
-- latent row and is a silent laundering hole for an index.  See `unifyIndexRow`.
unifyN dyn (TEff r1) (TEff r2) = unifyIndexRow dyn r1 r2
-- An `Authority`-kinded type-argument index is INVARIANT (§6.4): the two
-- authorities must cover each other, in both directions, whatever the flow.
unifyN dyn (TAuth qa) (TAuth qb) = unifyIndex dyn.dcModule qa qb
unifyN dyn (TQual a qa) (TQual b qb) =
  wantAuthority dyn.dcModule qa qb
  wantAuthority dyn.dcModule qb qa
  unifyStruct dyn a b
unifyN dyn (TQual a qa) b =
  wantAuthority dyn.dcModule (authTop (authDomainTop qa)) qa
  unifyStruct dyn a b
unifyN dyn a (TQual b qb) =
  wantAuthority dyn.dcModule (authTop (authDomainTop qb)) qb
  unifyStruct dyn a b
unifyN dyn a b = typeMismatch dyn a b

-- A fresh variable standing for a value takes its source's type verbatim,
-- qualifier included: a declared parameter, a match scrutinee, a call's
-- result.  Anything already shaped unifies as usual.
export
bindFrom : DynCtx -> Mono -> Mono -> Unit
bindFrom dyn target source = match normalize target
  TVar cell => match !cell
    Unbound _ _ => bindVar dyn cell source
    Link _ => unifyIn dyn target source
  _ => unifyIn dyn target source

-- `lower ⊑ upper`, as an obligation of the open inference scope, or decided
-- on the spot outside one (an annotation checked at top level).
-- The terms are recorded normalised: a cell already linked when the
-- obligation is recorded (an alias parameter standing for a written index)
-- is the written term it stands for, and only a cell the scope solves
-- afterwards reads as a solved bound in a report (`esfWrittenUpper`).
export
wantAuthority : ModuleCtx -> Authority -> Authority -> Unit
wantAuthority mctx lower upper = wantAuthorityWith mctx False lower upper

-- [exact]: this obligation is one half of an index equality, so its failure
-- is reported as an index mismatch, once for both halves.
export
wantAuthorityWith : ModuleCtx -> Bool -> Authority -> Authority -> Unit
wantAuthorityWith mctx exact lower upper =
  wantAuthorityFrom mctx None exact lower upper

-- [origin]: the binding whose scheme carried this obligation as a residual,
-- when it is one re-emitted at a use of that binding.
-- Against a Product tuple that holds variables the obligation is one per axis
-- (`authSplit`), so a variable on an axis is solved from its own axis.
wantAuthorityFrom : ModuleCtx ->
  Option String ->
  Bool ->
  Authority ->
  Authority ->
  Unit
wantAuthorityFrom mctx origin exact lower upper =
  fold
    (_ pair => wantAuthorityOne mctx origin exact False (fst pair) (snd pair))
    ()
    (authSplit lower upper)

-- An index row's atom that its other side must cover, having no tail to take
-- it: an index obligation in one direction only, so a failure reads as the
-- atom not covered rather than as two indices that differ.
wantIndexCovered : ModuleCtx -> Authority -> Authority -> Unit
wantIndexCovered mctx lower upper =
  fold
    (_ pair => wantAuthorityOne mctx None True True (fst pair) (snd pair))
    ()
    (authSplit lower upper)

wantAuthorityOne : ModuleCtx ->
  Option String ->
  Bool ->
  Bool ->
  Authority ->
  Authority ->
  Unit
wantAuthorityOne mctx origin exact covering lower upper
  | EffectSolver.hasSummaryScope mctx.mcCells.effectSummaries =
    EffectSolver.recordAuthorityFrom
      mctx.mcCells.effectSummaries
      origin
      exact
      (obligationSiteHere mctx covering)
      (authNorm lower)
      (authNorm upper)
  | authSub lower upper = ()
  | otherwise = match solveFlexibleUpper mctx lower upper
    True => ()
    False =>
      if exact then
        reportIndexFailure mctx covering mctx.mcLoc lower upper
      else
        reportAuthorityFailure mctx mctx.mcLoc origin lower upper

-- Outside a scope, a flexible upper variable takes the lower bound as its
-- solution, widened as the scoped solver widens a solution
-- (`widenOpenedFor`).  Once solved it is no longer a variable, so a later
-- obligation is checked against that solution; a variable is never linked to
-- a join containing itself, which normalisation would follow forever.  A
-- rigid or concrete upper that does not cover fails.
solveFlexibleUpper : ModuleCtx -> Authority -> Authority -> Bool
solveFlexibleUpper mctx lower upper = match authNorm upper
  AVar cell =>
    if IdMap.has (authvarId cell) mctx.mcCells.rigidAuthvarsRef.value then
      False
    else match withoutVar cell lower
      [] => True
      rest =>
        linkAuthvar
          cell
          (widenOpenedFor mctx (authvarLevel cell) (authJoinAll rest))
        True
  _ => False

-- A term's join members other than [cell] (`κ ⊔ x ⊑ κ` asks only `x ⊑ κ`).
withoutVar : Ref Authvar -> Authority -> List Authority
withoutVar cell q =
  let members = match authNorm q
    AJoin ms => ms
    other => [other]
  filterList
    (m => match m
      AVar c => authvarId c /= authvarId cell
      _ => True)
    members

-- An existential a pattern opened is scoped to its arm or clause, which runs
-- one level deeper than anything older (`openExistentialScope`).  The arm's
-- own close checks what the arm's inference bound to it, but an authority
-- obligation is solved later, at the binding's close, and its solution can
-- name the opened authority for a variable older than the arm (a clause
-- parameter's index, a binding's row).  Such a solution is widened: the
-- opened authority becomes its domain's top, the §4 over-approximation a
-- sourceless opened authority publishes as.  A variable as young as the arm
-- keeps it, since it cannot leave the arm.
export
widenOpenedFor : ModuleCtx -> Int -> Authority -> Authority
widenOpenedFor mctx level q =
  let asub =
    flatMap
      (c =>
        if IdMap.has (authvarId c) mctx.mcCells.openedAuthvarsRef.value
          && authvarLevel c > level then
          [(authvarId c, authTop (authvarDomain c))]
        else
          [])
      (authVars q)
  substAuth asub q

reportAuthorityFailure : ModuleCtx ->
  Option Loc ->
  Option String ->
  Authority ->
  Authority ->
  Unit
reportAuthorityFailure mctx loc origin lower upper =
  pushTypeErrorAt
    mctx
    "T-AUTHORITY"
    loc
    (authorityFailureMsg
      mctx
      mctx.mcCells.currentFn.value
      None
      origin
      lower
      upper
      (Some upper))

-- Both halves of one index equality render the same message (the two terms
-- in one order), so the second is the same (code, span, message) and is
-- recorded once.  [covering]: the obligation is an index row's coverage of
-- an atom, which has one direction.
export
reportIndexFailure : ModuleCtx ->
  Bool ->
  Option Loc ->
  Authority ->
  Authority ->
  Unit
reportIndexFailure mctx covering loc a b = pushTypeErrorAt
  mctx
  "T-AUTHORITY-INDEX-MISMATCH"
  loc
  (if covering then authorityCoverMsg a b else authorityIndexMsg a b)

-- Against a named authority the remedy is to derive the value from the
-- argument; against a written bound it is to stay within, or widen, the
-- bound; against a bound the scope SOLVED — an upper term recorded as a
-- flexible variable that this binding's other uses determined — the remedy
-- is to make every use lie within one bound, since nothing was written.
-- [label]: the key of the label the obligation came from, when it came from
-- a row's atom.
export
authorityFailureMsg : ModuleCtx ->
  String ->
  Option String ->
  Option String ->
  Authority ->
  Authority ->
  Option Authority ->
  String
authorityFailureMsg mctx name label origin lower upper written =
  let ctx = Ref []
  let cnt = Ref 0
  let lo = authorityTermTextIn ctx cnt lower
  let hi = ppAuthority ctx cnt upper
  match origin
    Some callee => residualFailureMsg callee lo hi
    None => boundFailureMsg mctx name label lower lo hi upper written

-- A bound over binders the caller chooses says what a body may do with
-- them.  A `*` is offered only where it would help: the body extends a
-- binder on the right, reaching the whole domain, and the binder's domain has
-- patterns.  An interpolation through a `display` other than the prelude's
-- is named as the cause, since the value is built as the advice says.
boundFailureMsg : ModuleCtx ->
  String ->
  Option String ->
  Authority ->
  String ->
  String ->
  Authority ->
  Option Authority ->
  String
boundFailureMsg mctx name label lower lo hi upper written =
  if mentionsOpened mctx upper then
    "`\{name}` reaches \{lo} where only \{hi} is admitted, the authority of the value this arm or clause opened; derive the operation from the opened value, or widen the declared row to the label bare"
  else if authHasVars upper
    && binderIn mctx.mcCells.displayHiddenBindersRef upper then
    "`\{name}` reaches \{lo} where only \{hi} is admitted: the interpolation uses this module's own `display`, not the prelude's, so the string is not known to derive from \{hi}; build it with `++` from the named argument"
  else if authHasVars upper && allList authvarIsPattern (authVars upper) then
    "`\{name}` reaches \{lo} where only \{hi} is admitted, a pattern-ranging authority the caller chooses; build the value by appending to the named argument, `root ++ suffix`, or widen the declared row to the label bare"
  else if authHasVars upper then
    ordinaryBoundFailureMsg mctx name label lower lo hi upper
  else if solvedUpper mctx written then
    "`\{name}` reaches \{lo} where only \{hi} is admitted, the bound this binding's other uses of the same authority determined; make every use lie within one bound, or write the bound"
  else
    "`\{name}` reaches \{lo} where its declared bound admits only \{hi}; stay within the bound, or widen it"

-- An ordinary binder: an extension of it is the whole domain.  The `*` is
-- offered, spelled with the program's own label, only when the body
-- extended one whose domain has patterns.
ordinaryBoundFailureMsg : ModuleCtx ->
  String ->
  Option String ->
  Authority ->
  String ->
  String ->
  Authority ->
  String
ordinaryBoundFailureMsg mctx name label lower lo hi upper =
  let head =
    "`\{name}` reaches \{lo} where only \{hi} is admitted, an authority the caller chooses"
  let extended =
    filterList
      (c => IdMap.has (authvarId c) mctx.mcCells.extendedBindersRef.value)
      (authVars upper)
  if authIsTop lower && isNonEmptyL extended then
    let tail = "; an extension of it is the whole domain, so "
    match filterList (c => domainHasPatterns (authvarDomain c)) extended
      c :: _ =>
        let n = optionOr hi (authvarName c)
        let star = starSpelling n (binderLabel mctx name n label)
        "\{head}\{tail}declare \{star}"
      [] =>
        "\{head}\{tail}perform the operation on the named argument and extend the value at the call site"
  else
    "\{head}; perform the operation on the named argument, or widen the declared row to the label bare"

-- The label binder [n] of binding [fn] is written under: the binding's
-- signature says, else the label of the atom the failed obligation came from
-- ([key]).
binderLabel : ModuleCtx -> String -> String -> Option String -> Option String
binderLabel mctx fn n key =
  let written = match omLookup fn mctx.mcCells.sigTyMapRef.value
    Some ty => binderLabelIn mctx n ty
    None => None
  orElseOpt written (map labelKeyName key)

-- The label a signature writes binder [n] under: its written domain
-- (`(n : String @L)`), else the first atom naming it (`<L n>`), else the
-- first `Authority L` index slot it fills.
binderLabelIn : ModuleCtx -> String -> Ty -> Option String
binderLabelIn mctx n ty = match lookupAssoc n (namedArgDomains ty)
  Some (Some d) => Some d.eatLabel
  _ =>
    match (atomBindersIn (a => atomNaming n a) ty
      ++ authSlotNamesIn mctx (slotLabelsNaming n) ty)
      l :: _ => Some l
      [] => None

slotLabelsNaming : String -> List Kind -> List Ty -> List String
slotLabelsNaming n ((KAuth l _) :: ks) ((TyVar m) :: as2) =
  if m == n then
    effLabelName l :: slotLabelsNaming n ks as2
  else
    slotLabelsNaming n ks as2
slotLabelsNaming n (_ :: ks) (_ :: as2) = slotLabelsNaming n ks as2
slotLabelsNaming _ _ _ = []

atomNaming : String -> EffAtomTy -> List String
atomNaming n a = match a.eatParam
  EPName m => if m == n then [a.eatLabel] else []
  _ => []

-- A label's name from its key (`labelKey`), without the defining module.
labelKeyName : String -> String
labelKeyName key = match reverseL (splitOnChar ':' key)
  last :: _ => last
  [] => key

binderIn : Ref (Map Int Unit) -> Authority -> Bool
binderIn table q =
  anyList (c => IdMap.has (authvarId c) table.value) (authVars q)

mentionsOpened : ModuleCtx -> Authority -> Bool
mentionsOpened mctx q =
  anyList
    (cell => IdMap.has (authvarId cell) mctx.mcCells.openedAuthvarsRef.value)
    (authVars q)

-- The upper term was recorded as a variable and has since been solved by
-- the scope — not substituted by an index equality with a written term,
-- which reads as the written bound it is.
solvedUpper : ModuleCtx -> Option Authority -> Bool
solvedUpper mctx (Some (AVar cell)) = match !cell
  ALink _ _ _ =>
    not (IdMap.has (authvarId cell) mctx.mcCells.indexSubstitutedRef.value)
  AUnbound _ _ _ _ _ => False
solvedUpper mctx _ = False

-- ── #1119 D-2: the per-parameter VARIANCE gate (#1098, #1121) ─────────────
-- The arrow-row unifier's closed~closed arm demands equality, and a seam that
-- knows its direction relaxes that to sub-effecting through `unifyInto`.  A
-- type ARGUMENT at a non-covariant slot is where the relaxation must NOT
-- happen, in either direction:
--   * `#1098` — `box : Ref (Unit -> <> Unit)` assigned to `alias : Ref (Unit ->
--     <Stdout> Unit)`, then `alias := shout` writes a `<Stdout>` closure into
--     the cell `box` still reads as pure.  `callBox : Unit -> Unit` performs
--     Stdout and carries no row.
--   * `#1121` — `pureTaker : Taker (Unit -> Unit)` assigned to `wide : Taker
--     (Unit -> <IO> Unit)`, where `data Taker a = MkTaker (a -> Int)` puts `a`
--     in a DOMAIN.  No mutation anywhere; the laundering is pure contravariance.
-- Both are ANNOTATED-BINDING widenings met by `preunifySigsEx`' `unify`;
-- `unifyN`'s `TApp` arm IS the seam.  The guard unifies the argument with
-- `dcNonCovariant` set, so `closedRowEqCheck` reports a mismatch anywhere inside
-- it with the variance wording (`paramVarianceMismatchMsg`) rather than the
-- generic one, and `unifyInto` treats such a slot as equality rather than
-- descending directionally.  An open tail still has a metavariable to solve,
-- and solving one against a written row is instantiation rather than
-- interchange — the same caveat `unifyIndexRowN` documents
-- (`graded_closed_row_grade_ok`) — so nothing changes for it.
--
-- This does narrow acceptance in the sound direction too.  A contravariant
-- NARROWING (`Taker (Unit -> <IO> Unit)` assigned where `Taker (Unit -> <>
-- Unit)` is declared) is genuinely safe and is rejected as well: a type
-- argument's polarity is a property of the constructor, not of the flow, and
-- equality is the only symmetric sound rule.
-- A covariant slot nested inside a non-covariant one is unified in the copy the
-- outer slot set, so it stays non-covariant.
paramVarianceGuard : DynCtx -> Mono -> Mono -> Mono -> Unit
paramVarianceGuard dyn hd b1 b2
  | monoSlotNonCovariant dyn.dcModule hd =
    unifyStruct { dyn | dcNonCovariant = True } b1 b2
  | otherwise = unifyStruct dyn b1 b2

-- The ONE read of the polarity table, and the place the WRITE-CHANNEL SEED
-- lives.  `Ref` and `Array` are the two mutable primitives (`stdlib/runtime.mdk`
-- — `Ref`/`setRef`, `arraySetUnsafe`/`arrayFill`); neither has a Medaka-visible
-- `data` declaration, so neither ever reaches `registerVariants` and
-- `inferParamPolarities` has no constructor field to derive their invariance
-- from.  They are therefore seeded, and seeded HERE rather than into the ref
-- itself: the Module path REPLACES that whole list per module
-- (`declEnvSeedDataUniverse`), so a value planted in `freshModuleCtx` would survive
-- on one entry path and be silently wiped on another — the exact
-- single-file-vs-cross-module split a seed must not have.
--
-- Exactly two seeds, not four.  `Vector`/`HashMap` are ordinary Medaka
-- types declared OVER these, so they inherit invariance transitively through
-- `paramOccPolarities`' `TyApp` composition and must NOT be listed: a hardcoded
-- entry would be a second, unkeyed source of the same fact.
paramPolaritiesOf : ModuleCtx -> TabKey -> Option (List Polarity)
paramPolaritiesOf mctx key =
  paramPolaritiesIn mctx.mcCells.dataParamPolarityRef.value key

unifyVars : DynCtx -> Ref Tyvar -> Ref Tyvar -> Unit
unifyVars dyn c1 c2 =
  if tyvarId c1 == tyvarId c2 then () else bindVar dyn c1 (TVar c2)

bindVar : DynCtx -> Ref Tyvar -> Mono -> Unit
bindVar dyn cell t =
  dyn.dcModule.mcCells.occursCheckFailed := False
  occursAdjust dyn.dcModule (tyvarId cell) (tyvarLevel cell) t
  if dyn.dcModule.mcCells.occursCheckFailed.value then
    ()
  else
    propagatePoison dyn.dcModule cell t
    let shaped = takeJoinsShapedBy dyn.dcModule cell t
    cell := Link t
    settleShapedJoins dyn shaped

-- A recorded join whose result a unification is shaping is decided by that
-- use, as it was before joins were delayed: once the result has its shape,
-- every alternative takes it by equality (EFFECTS-SEMANTICS §6.8).  Deciding
-- it later would let the use first relate a row the alternatives then share
-- to a closed row, which a caller-supplied row can meet only by equality.
-- Linking the result to another variable shapes nothing.  The common case has
-- nothing recorded and costs one emptiness test.  The join is settled in the
-- context of the unification that shaped it, under the construct it was
-- recorded for (`PendingJoin`).
takeJoinsShapedBy : ModuleCtx -> Ref Tyvar -> Mono -> List PendingJoin
takeJoinsShapedBy mctx cell t = match mctx.mcCells.pendingJoinsRef.value
  [] => []
  pending => match normalize t
    TVar _ => []
    _ =>
      let id = tyvarId cell
      let hits = filter (pj => joinResultIs id pj) pending
      match hits
        [] => []
        _ =>
          mctx.mcCells.pendingJoinsRef :=
            filter (pj => not (joinResultIs id pj)) pending
          hits

joinResultIs : Int -> PendingJoin -> Bool
joinResultIs id pj = match normalize pj.pjResult
  TVar c => tyvarId c == id
  _ => False

settleShapedJoins : DynCtx -> List PendingJoin -> Unit
settleShapedJoins dyn [] = ()
settleShapedJoins dyn shaped =
  fold
    (_ pj =>
      fold
        (_ (loc, value) =>
          joinValueEqual dyn pj.pjContext loc pj.pjResult value)
        ()
        pj.pjValues)
    ()
    shaped

-- A poisoned variable is one an earlier diagnostic already explained; whatever
-- it is bound to inherits that, so an obligation on a variable reached only
-- through the poisoned one (the result of applying it, a field of its shape)
-- is not reported as a second, unexplained error. The common case has nothing
-- poisoned and costs one emptiness test.
propagatePoison : ModuleCtx -> Ref Tyvar -> Mono -> Unit
propagatePoison mctx cell t = match mctx.mcCells.poisonedVars.value
  [] => ()
  poisoned =>
    if containsI (tyvarId cell) poisoned then
      mctx.mcCells.poisonedVars := monoUnboundIds t ++ poisoned

-- Chunk A: record the union-find roots of every free var on either side of a
-- unification failure so a later obligation check can suppress a secondary
-- `ambiguous instance` cascade on the same (already-errored) var.
export
poisonMismatchVars : ModuleCtx -> Mono -> Mono -> Unit
poisonMismatchVars mctx a b =
  let poisoned =
    monoUnboundIds a ++ monoUnboundIds b ++ mctx.mcCells.poisonedVars.value
  mctx.mcCells.poisonedVars := poisoned

typeMismatch : DynCtx -> Mono -> Mono -> Unit
typeMismatch dyn a b =
  poisonMismatchVars dyn.dcModule a b
  typeMismatchReport dyn a b

-- The do-chain a mismatch is blamed on: none once a report has been made for it.
activeDo : DynCtx -> Option DoCtx
activeDo dyn = match dyn.dcDo
  Some doCtx => if doCtx.doReported.value then None else Some doCtx
  None => None

typeMismatchReport : DynCtx -> Mono -> Mono -> Unit
typeMismatchReport dyn a b = match dyn.dcMethodMismatch
  Some mname =>
    pushTypeError
      dyn.dcModule
      "T-METHOD-MISMATCH"
      "method `\{mname}` has type \{ppMono b} but its interface declares \{ppMono a}"
  None => typeMismatchReportJoin dyn a b

-- A mismatch inside the join of an `if` with no `else` branch is that `if`'s
-- missing branch: the branch is `()`, so the `then` branch must be Unit too.
-- Outside a do-lowered chain, a variable applied to arguments against a type
-- with no application to fill it names the interface that variable stands for.
typeMismatchReportJoin : DynCtx -> Mono -> Mono -> Unit
typeMismatchReportJoin dyn a b = match dyn.dcJoin
  Some JoinElselessIf =>
    pushTypeErrorHelpFixAt
      dyn.dcModule
      "T-TYPE-MISMATCH"
      dyn.dcModule.mcLoc
      "type mismatch: \{ppMono a} vs \{ppMono b}; \{elselessIfHelp}"
      elselessIfHelp
      None
  _ => match (activeDo dyn, constrainedApplicationHelp dyn.dcModule a b)
    (None, Some help) =>
      pushTypeErrorHelpFixAt
        dyn.dcModule
        "T-TYPE-MISMATCH"
        dyn.dcModule.mcLoc
        "type mismatch: \{ppMono a} vs \{ppMono b}; \{help}"
        help
        None
    _ => typeMismatchReportRest dyn a b

-- One side is an unsolved variable applied to arguments (`m Unit`), the other a
-- type with no application for that variable to take (`Unit`, an arrow).  Such
-- a pair can only fail.  When the variable carries interface obligations, the
-- applied side is a value of a type implementing them and the other side is
-- not.  `unify` has no expected/actual role, and the same pair arises with the
-- applied side on either, so the text names neither side as the position.
constrainedApplicationHelp : ModuleCtx -> Mono -> Mono -> Option String
constrainedApplicationHelp mctx a b =
  map
    ((app, plain, ifaces) => constrainedApplicationText app plain ifaces)
    (orElseOpt (appliedVarIfaces mctx a b) (appliedVarIfaces mctx b a))

appliedVarIfaces : ModuleCtx -> Mono -> Mono -> Option (Mono, Mono, List String)
appliedVarIfaces mctx app plain = match (normalize app, normalize plain)
  (TApp _ _, TApp _ _) => None
  (TApp _ _, _) => match normalize (spineHead app)
    TVar cell => match ifacesConstrainingVar mctx (tyvarId cell)
      [] => None
      ifaces => Some (app, plain, ifaces)
    _ => None
  _ => None

-- The interfaces a pending call or impl obligation places on the variable
-- whose union-find root is [id], in first-recorded order, without repeats.
ifacesConstrainingVar : ModuleCtx -> Int -> List String
ifacesConstrainingVar mctx id =
  let pending = wAll mctx.mcCells.obls ++ wAll mctx.mcCells.implObls
  let onVar = filter (o => anyList (sameRootId id) o.pred.args) pending
  dedup (map (o => o.pred.iface.irName) onVar)

typeMismatchReportRest : DynCtx -> Mono -> Mono -> Unit
typeMismatchReportRest dyn a b = match activeDo dyn
  Some doCtx => typeMismatchInDo dyn.dcModule a b doCtx
  None => match firstTupleCallHint dyn.dcModule [a, b]
    -- P0-16: one side is a tuple-call residual (e.g. `z : Int; z = add(1, 2)`
    -- → `Type mismatch: Int vs (a, b) -> (a, b)`) — append the call-syntax hint.
    Some (help, fix) =>
      pushTypeErrorHelpFixAt
        dyn.dcModule
        "T-TYPE-MISMATCH"
        dyn.dcModule.mcLoc
        "type mismatch: \{ppMono a} vs \{ppMono b}; \{help}"
        help
        fix
    None => match sameSpellingHint a b
      -- Two modules' unrelated `T`s now mismatch, and the message renders two
      -- identical sides (`Type mismatch: T vs T`) — true, and useless without
      -- this hint.
      Some help =>
        pushTypeErrorHelpFixAt
          dyn.dcModule
          "T-TYPE-MISMATCH"
          dyn.dcModule.mcLoc
          "type mismatch: \{ppMono a} vs \{ppMono b}; \{help}"
          help
          None
      None =>
        pushTypeError
          dyn.dcModule
          "T-TYPE-MISMATCH"
          "type mismatch: \{ppMono a} vs \{ppMono b}"

-- a mismatch inside a do-lowered chain: if it is the monad-shape (`m b`) vs
-- non-monad obligation, retarget to the tailored "do requires a monad" error;
-- otherwise fall back to the plain mismatch (the loc stays the do-block's).
typeMismatchInDo : ModuleCtx -> Mono -> Mono -> DoCtx -> Unit
typeMismatchInDo mctx a b doCtx
  | monoIsApp (normalize a) /= monoIsApp (normalize b) =
    recordDoMonadError mctx doCtx
  | otherwise =
    pushTypeError
      mctx
      "T-TYPE-MISMATCH"
      "type mismatch: \{ppMono a} vs \{ppMono b}"

-- This push site routes through `recordTypeError` like every other push, so this
-- path's detection reaches the counter too.  (The counter is not equal to the
-- list-length delta: see `recordTypeError`.)
recordDoMonadError : ModuleCtx -> DoCtx -> Unit
recordDoMonadError mctx doCtx =
  doCtx.doReported := True
  recordTypeError
    mctx
    (TcDiag
      "T-DO-NOT-MONAD"
      1
      (Some doCtx.doLoc)
      (if doCtx.doDeferred then deferRequiresMonadMsg else doRequiresMonadMsg)
      None
      None)

-- ── generalization & instantiation ────────────────────────────────────────
-- Quantify a mono for DISPLAY (the LSP hover fallback, `mapLocalSchemes`):
-- no defaulting, since the cells are shared with schemes already published
-- and a default written here would rewrite them after the fact.
export
generalize : ModuleCtx -> Mono -> Scheme
generalize mctx t = quantifyFree mctx [] pureRow t

-- [declared] are the authority cells a written signature binds: rigid through
-- the body and published as written, never defaulted.  [residual] are the
-- obligations the binding's scope kept over its own quantified authorities.
export
generalizeBindingDeclared : DynCtx ->
  Map Int Unit ->
  List AuthResidual ->
  EffRow ->
  Mono ->
  Scheme
generalizeBindingDeclared dyn declared residual force t =
  defaultDeferredPatLitsIn dyn dyn.dcModule.mcCells.currentLevel.value t
  defaultSourcelessAuthorities dyn.dcModule declared force t
  quantifyFree dyn.dcModule residual force t

quantifyFree : ModuleCtx -> List AuthResidual -> EffRow -> Mono -> Scheme
quantifyFree mctx residual force t =
  Forall
    (dedupI (freeGenVars mctx.mcCells.currentLevel.value t))
    (dedupI (freeEffvars mctx t ++ rowFreeEffvars mctx force))
    (dedupI (freeAuthvars mctx t ++ rowFreeAuthvars mctx force))
    residual
    force
    t

-- Lower every unbound var in [t] deeper than the current level down to the
-- current level, so a value-restricted (non-generalized) binding's vars can't be
-- picked up by an enclosing let's generalize.  Mirrors the lowering `unify`
-- performs via occursAdjust in the non-PVar pattern path.
export
lowerToCurrent : ModuleCtx -> Mono -> Unit
lowerToCurrent mctx t = match normalize t
  TVar cell => match !cell
    Unbound id lvl =>
      if lvl > mctx.mcCells.currentLevel.value then
        cell := Unbound id mctx.mcCells.currentLevel.value
    Link t2 => lowerToCurrent mctx t2
  TCon _ _ => ()
  TRigid _ => ()
  TApp a b =>
    lowerToCurrent mctx a
    lowerToCurrent mctx b
  TFun a r b =>
    lowerToCurrent mctx a
    lowerRowLevels mctx.mcCells.currentLevel.value r
    lowerToCurrent mctx b
  TAuth q => lowerAuthLevels mctx.mcCells.currentLevel.value q
  TEff r =>
    lowerRowLevels mctx.mcCells.currentLevel.value r
    ()
  TQual a q =>
    lowerAuthLevels mctx.mcCells.currentLevel.value q
    lowerToCurrent mctx a

freeGenVars : Int -> Mono -> List Int
freeGenVars lvl t = match normalize t
  TVar cell => if tyvarLevel cell > lvl then [tyvarId cell] else []
  TCon _ _ => []
  TRigid _ => []
  TApp a b => freeGenVars lvl a ++ freeGenVars lvl b
  TFun a _ b => freeGenVars lvl a ++ freeGenVars lvl b
  TEff _ => []
  TAuth _ => []
  TQual a _ => freeGenVars lvl a

export
instantiate : ModuleCtx -> Scheme -> Mono
instantiate mctx (Forall ids evars avars _ _ t) =
  substMono
    mctx.mcGraph
    (freshSubst mctx ids)
    (freshEffSubst mctx evars)
    (freshAuthSubstFor mctx avars t pureRow)
    t

-- Like `freshAuthSubstFor`, returning the cells minted for the ids recorded
-- as existential; those are made rigid here.
export
freshAuthSubstOpening : ModuleCtx ->
  List Int ->
  Mono ->
  (List (Int, Authority), List (Ref Authvar))
freshAuthSubstOpening mctx [] _ = ([], [])
freshAuthSubstOpening mctx ids body =
  freshAuthSubstOpeningIn mctx ids (authCellsIn body Tip)

-- The same, given the scheme's cells already collected (a record's binder
-- cells sit in its fields, not in its result).
export
freshAuthSubstOpeningIn : ModuleCtx ->
  List Int ->
  Map Int (Ref Authvar) ->
  (List (Int, Authority), List (Ref Authvar))
freshAuthSubstOpeningIn mctx [] _ = ([], [])
freshAuthSubstOpeningIn mctx ids cells =
  let pairs =
    map
      (id =>
        let cell = freshInferenceAuthvar mctx id (IdMap.get id cells)
        (
          id,
          cell,
          IdMap.has id mctx.mcGraph.graphRun.ctorExistentialsRef.value,
        ))
      ids
  let opened =
    flatMap ((_, cell, isOpen) => if isOpen then [cell] else []) pairs
  mctx.mcCells.rigidAuthvarsRef :=
    fold
      (m cell => IdMap.set (authvarId cell) () m)
      mctx.mcCells.rigidAuthvarsRef.value
      opened
  mctx.mcCells.openedAuthvarsRef :=
    fold
      (m cell => IdMap.set (authvarId cell) () m)
      mctx.mcCells.openedAuthvarsRef.value
      opened
  (map ((id, cell, _) => (id, AVar cell)) pairs, opened)

export
freshSubst : ModuleCtx -> List Int -> List (Int, Mono)
freshSubst mctx [] = []
freshSubst mctx (id :: rest) =
  let v = freshVar mctx ()
  if id == ambiguousImportTyvarId then poisonMismatchVars mctx v v
  (id, v) :: freshSubst mctx rest

-- The one quantified id no allocation ever mints (`newTyvarId` counts up from
-- zero). A scheme quantifying it is an error-recovery scheme for an ambiguous
-- import: each occurrence instantiates to a fresh variable that is poisoned on
-- arrival, so no secondary obligation diagnostic is raised on it.
export
ambiguousImportTyvarId : Int
ambiguousImportTyvarId = 0 - 1

export
freshEffSubst : ModuleCtx -> List Int -> List (Int, Ref Effvar)
freshEffSubst mctx [] = []
freshEffSubst mctx (id :: rest) =
  let cell = freshInferenceEffvar mctx ()
  (id, cell) :: freshEffSubst mctx rest

-- A use freshens each quantified authority to a flexible variable of the
-- current scope.  The fresh cell copies the binder's domain and name from the
-- scheme's own cell, found by id in the scheme body and forcing row.
freshAuthSubstFor : ModuleCtx ->
  List Int ->
  Mono ->
  EffRow ->
  List (Int, Authority)
freshAuthSubstFor mctx [] _ _ = []
freshAuthSubstFor mctx ids body force =
  let cells = authCellsIn body (authRowCells force Tip)
  map
    (id => (id, AVar (freshInferenceAuthvar mctx id (IdMap.get id cells))))
    ids

-- An instantiation's authority choice belongs to the current scope, at the
-- current level, like an instantiated row tail.  The fresh cell keeps the
-- binder's range: a pattern-ranging binder instantiates to a pattern-ranging
-- variable, or an exact element could reach it.  A quantified id with no
-- cell in the scheme is dead (nothing it would substitute remains), except
-- one minted pattern-ranging (`patternAuthIdsRef`): losing its source would
-- lose its range, so that is an internal error rather than a default.  A
-- constructor's existential binder is the one pattern-ranging id that may
-- have no cell: its cells are the fields', so one no field mentions is
-- phantom, and as dead as an ordinary phantom binder.
export
freshInferenceAuthvar : ModuleCtx -> Int -> Option (Ref Authvar) -> Ref Authvar
freshInferenceAuthvar mctx _ (Some source) =
  freshAuthvarRanged
    mctx
    (authvarDomain source)
    (authvarIsPattern source)
    (authvarName source)
freshInferenceAuthvar mctx id None =
  if IdMap.has id mctx.mcGraph.graphRun.patternAuthIdsRef.value
    && not (IdMap.has id mctx.mcGraph.graphRun.ctorExistentialsRef.value) then
    panic
      "internal error: the pattern-ranging authority variable #\{intToString id} has no cell in the scheme that quantifies it, so its range would be lost at instantiation"
  else
    freshAuthvar mctx PUnit None

-- free generalizable authority variables: deeper than the current scope
freeAuthvars : ModuleCtx -> Mono -> List Int
freeAuthvars mctx t =
  generalizableAuthvars mctx (IdMap.values (authCellsIn t Tip))

rowFreeAuthvars : ModuleCtx -> EffRow -> List Int
rowFreeAuthvars mctx row =
  generalizableAuthvars mctx (IdMap.values (authRowCells row Tip))

generalizableAuthvars : ModuleCtx -> List (Ref Authvar) -> List Int
generalizableAuthvars mctx cells =
  flatMap
    (cell =>
      if authvarLevel cell > mctx.mcCells.currentLevel.value then
        [authvarId cell]
      else
        [])
    cells

-- An authority variable is quantified only where the published type gives a
-- caller a way to supply it: a qualified argument slot.  A variable that
-- occurs only in rows has no source, so publication takes the domain's top
-- for it rather than claiming an authority nothing determines.
defaultSourcelessAuthorities : ModuleCtx ->
  Map Int Unit ->
  EffRow ->
  Mono ->
  Unit
defaultSourcelessAuthorities mctx declared force t =
  let sources = qualifierAuthIds t declared
  let candidates = IdMap.values (authCellsIn t (authRowCells force Tip))
  fold
    (_ cell =>
      if authvarLevel cell > mctx.mcCells.currentLevel.value
        && not (IdMap.has (authvarId cell) sources) then
        linkAuthvar cell (authTop (authvarDomain cell)))
    ()
    candidates

export
lowerAuthLevels : Int -> Authority -> Unit
lowerAuthLevels _ (AConst _) = ()
lowerAuthLevels level q =
  fold
    (_ cell => match !cell
      AUnbound id lvl top pat name =>
        if lvl > level then cell := AUnbound id level top pat name
      ALink _ _ _ => ())
    ()
    (authVars q)

export
freshTvMap : ModuleCtx -> List String -> List (String, Mono)
freshTvMap mctx [] = []
freshTvMap mctx (n :: rest) = (n, freshVar mctx ()) :: freshTvMap mctx rest

export
freshEffMap : ModuleCtx -> List String -> List (String, Ref Effvar)
freshEffMap mctx [] = []
freshEffMap mctx (n :: rest) = (n, freshEffvar mctx ()) :: freshEffMap mctx rest

export
freshAuthBinderRanged : ModuleCtx ->
  Bool ->
  (String, Param) ->
  (String, Ref Authvar)
freshAuthBinderRanged mctx pat (n, top) =
  (n, freshAuthvarRanged mctx top pat (Some n))

-- Every named argument with its written domain, if any.
export
namedArgDomains : Ty -> List (String, Option EffAtomTy)
namedArgDomains (TyFun (TyNamed n _ d) b) = (n, d) :: namedArgDomains b
namedArgDomains (TyFun _ b) = namedArgDomains b
namedArgDomains (TyConstrained _ t) = namedArgDomains t
namedArgDomains _ = []

export
freshAuthvar : ModuleCtx -> Param -> Option String -> Ref Authvar
freshAuthvar mctx top name = freshAuthvarRanged mctx top False name

-- [pat]: the variable ranges over the domain's patterns only (a binder
-- written `@L*` or `Authority L*`); its id is recorded so an instantiation
-- that cannot find its cell fails loudly (`freshInferenceAuthvar`).
export
freshAuthvarRanged : ModuleCtx -> Param -> Bool -> Option String -> Ref Authvar
freshAuthvarRanged mctx top pat name =
  let id = newEffvarId mctx.mcGraph ()
  if pat then
    mctx.mcGraph.graphRun.patternAuthIdsRef :=
      IdMap.set id () mctx.mcGraph.graphRun.patternAuthIdsRef.value
  Ref (AUnbound id mctx.mcCells.currentLevel.value top pat name)

-- What [readSlots] reads off every registered head's argument list, given
-- the head's declared kinds.
export
authSlotNamesIn : ModuleCtx -> (List Kind -> List Ty -> List a) -> Ty -> List a
authSlotNamesIn mctx readSlots (TyApp a b) = match tyAppSpine (TyApp a b)
  (TyCon { tyConName = n, tyConOrigin = o }, args) =>
    match lookupTab (tyTabKey o n) mctx.mcCells.dataParamKindsRef.value
      Some kinds if listLen kinds == listLen args =>
        readSlots kinds args ++ flatMap (authSlotNamesIn mctx readSlots) args
      _ => authSlotNamesIn mctx readSlots a ++ authSlotNamesIn mctx readSlots b
  _ => authSlotNamesIn mctx readSlots a ++ authSlotNamesIn mctx readSlots b
authSlotNamesIn mctx readSlots (TyFun a b) =
  authSlotNamesIn mctx readSlots a ++ authSlotNamesIn mctx readSlots b
authSlotNamesIn mctx readSlots (TyTuple ts) =
  flatMap (authSlotNamesIn mctx readSlots) ts
authSlotNamesIn mctx readSlots (TyEffect _ _ t) =
  authSlotNamesIn mctx readSlots t
authSlotNamesIn mctx readSlots (TyConstrained _ t) =
  authSlotNamesIn mctx readSlots t
authSlotNamesIn mctx readSlots (TyNamed _ t _) =
  authSlotNamesIn mctx readSlots t
authSlotNamesIn mctx readSlots (TyQual t _ _) = authSlotNamesIn mctx readSlots t
authSlotNamesIn mctx _ _ = []

-- What [readAtom] reads off every effect atom a written type holds.
export
atomBindersIn : (EffAtomTy -> List a) -> Ty -> List a
atomBindersIn _ (TyVar _) = []
atomBindersIn _ (TyCon { tyConName = _ }) = []
atomBindersIn readAtom (TyApp a b) =
  atomBindersIn readAtom a ++ atomBindersIn readAtom b
atomBindersIn readAtom (TyFun a b) =
  atomBindersIn readAtom a ++ atomBindersIn readAtom b
atomBindersIn readAtom (TyTuple ts) = flatMap (atomBindersIn readAtom) ts
atomBindersIn readAtom (TyEffect atoms _ t) =
  flatMap readAtom atoms ++ atomBindersIn readAtom t
atomBindersIn readAtom (TyRow atoms _ _) = flatMap readAtom atoms
atomBindersIn _ (TyAuth _ _) = []
atomBindersIn readAtom (TyConstrained _ t) = atomBindersIn readAtom t
atomBindersIn readAtom (TyNamed _ t _) = atomBindersIn readAtom t
atomBindersIn readAtom (TyQual t _ _) = atomBindersIn readAtom t

-- Called by `generalize` before it quantifies [t]: a deferred literal-pattern var
-- that is about to become a scheme variable is `Int` instead, so a literal pattern
-- never makes a binding polymorphic.
defaultDeferredPatLitsIn : DynCtx -> Int -> Mono -> Unit
defaultDeferredPatLitsIn dyn lvl t =
  match dyn.dcModule.mcCells.patLitDeferred.value
    [] => ()
    deferred => defaultPatLitVarsIn dyn (freeGenVars lvl t) deferred

defaultPatLitVarsIn : DynCtx -> List Int -> List (Mono, Int, Option Loc) -> Unit
defaultPatLitVarsIn dyn _ [] = ()
defaultPatLitVarsIn dyn quantified ((a, _, _) :: rest) =
  match normalize a
    TVar cell =>
      if containsI (tyvarId cell) quantified then
        unifyIn dyn (tconBuiltin "Int") a
    _ => ()
  defaultPatLitVarsIn dyn quantified rest

export
unifyAll : DynCtx -> Mono -> List Mono -> Unit
unifyAll dyn _ [] = ()
unifyAll dyn t (x :: xs) =
  unifyIn dyn t x
  unifyAll dyn t xs

-- THE qual-entry resolution: a cross-module constrained callee's whole recorded
-- constraint fact — slots, declared prefix, and argument vectors — from ONE
-- `(definer module, exported name)` decision.  `None` ⇒ not an explicitly-imported name,
-- or that name owns no qual ids entry.
export
qualConstraintDecl : ModuleCtx -> String -> Option CDeclared
qualConstraintDecl mctx name = match qualConstraintKey mctx name
  None => None
  Some (src, origin) =>
    map
      (slots => qualDeclOf mctx.mcGraph src origin slots)
      (lookupQualPayload
        src
        origin
        mctx.mcGraph.crossRun.crossModuleFunPredicateSlotsQualRef.value)

qualDeclOf : GraphCtx -> String -> String -> List PredicateSlot -> CDeclared
qualDeclOf gctx src origin stored =
  let slots = predicateSlotCSlots stored
  CDeclared {
    cdSlots = slots,
    cdPrefix =
      clampPrefix
        slots
        (lookupQualPayload
          src
          origin
          gctx.crossRun.crossModuleFunConstraintDeclaredQualRef.value),
    -- S-xmod-vector-supply (#1868/#1867): the vectors of the SAME entry.  An ABSENT row
    -- is `[]`, which `zipSlotVecs` reads as "no vector recoverable" for every slot —
    -- byte-identically the pre-slice cross-module behaviour, so a callee registered with
    -- ids but no args is unaffected.  S-inferred-vector-supply (#1869): an INFERRED callee
    -- is no longer automatically in that class — `registerInferredFor` writes a real row
    -- when it recovers one, and writes none (this arm) when it recovers nothing.
    cdArgs = predicateSlotArgs stored,
  }

-- the (import-source module, ORIGINAL exported name) key a cross-module callee's qual
-- entries live under; `None` ⇒ local fn / wildcard import / re-export / check path.
--
-- #739 fix follow-up: an aliased import's surface name is resolved to its ORIGINAL
-- exported name before keying the qual tables (they are attributed under the defining
-- name).  A plain import / non-alias defaults to the name itself.  Without this,
-- `{set as hmSet}` of a constrained `hash_map.set` misses (qual has `(hash_map, set)`,
-- not `(hash_map, hmSet)`), the slot lookup comes back empty and `inferDictAtFound`
-- DROPS the Hash dict → `no matching impl for dispatch` at run/build.
--
-- Factored out by U1b (#1482) so `qualConstraintFor` (slots) and
-- `qualConstraintIds` (ids only) cannot drift on WHICH entry they resolve to.  Two
-- readers of one table that re-derive the key independently is the shape this seam
-- already pays for elsewhere; there is one derivation.
export
qualConstraintKey : ModuleCtx -> String -> Option (String, String)
qualConstraintKey mctx name =
  map
    (src => (
      src,
      optionOr name (omLookup name mctx.mcCells.currentImportOriginsRef.value),
    ))
    (omLookup name mctx.mcCells.currentImportDefinersRef.value)

-- first-match lookup in a `(definer module, exported name)`-keyed qual table.
--
-- B-2.2-f (#1113): ONE polymorphic function where there were two byte-identical
-- monomorphic copies (`lookupQualArity` / `lookupQualIfaces`).  The declared-prefix
-- sidecar's payload is a SCALAR, so a third copy could not have shared their `List X`
-- shape anyway — and three identical bodies is where `rule-duplicate-body` starts
-- collecting disables.
export
lookupQualPayload : String -> String -> List ((String, String), a) -> Option a
lookupQualPayload _ _ [] = None
lookupQualPayload src name (((m, n), v) :: rest)
  | m == src && n == name = Some v
  | otherwise = lookupQualPayload src name rest

-- B-2.2-f (#1113): a recorded prefix, clamped to the slots it indexes into; an ABSENT
-- one stays `CDPUnknown`, which every reader must treat as WITHHOLD (prefix 0).  Do not
-- "simplify" the absent arm to `CDPLen 0` — `CDPLen 0` is a recorded state a real entry
-- can hold, and collapsing the two erases the only signal that a write site is missing.
export
clampPrefix : List CSlot -> Option CDeclaredPrefix -> CDeclaredPrefix
clampPrefix _ None = CDPUnknown
clampPrefix _ (Some CDPUnknown) = CDPUnknown
clampPrefix slots (Some (CDPLen k)) = CDPLen (minI k (listLen slots))

-- instantiate a scheme, returning both the mono and the (quantified id → fresh
-- var) substitution, so a caller can recover specific quantified variables
export
instantiateTracked : ModuleCtx -> Scheme -> (Mono, List (Int, Mono))
instantiateTracked mctx scheme =
  let inst = instantiateMethodTracked mctx scheme
  (inst.mtiBody, inst.mtiSubstitution.misTypeSubst)

export
instantiateMethodTracked : ModuleCtx -> Scheme -> MethodTrackedInstantiation
instantiateMethodTracked mctx (Forall ids evars avars residual force body) =
  let typeSubst = freshSubst mctx ids
  let effectSubst = freshEffSubst mctx evars
  let authSubst = freshAuthSubstFor mctx avars body force
  MethodTrackedInstantiation {
    mtiBody = substMono mctx.mcGraph typeSubst effectSubst authSubst body,
    mtiForce = substRow mctx.mcGraph effectSubst authSubst force,
    mtiResidual =
      map
        (r => AuthResidual {
          arLower = substAuth authSubst r.arLower,
          arUpper = substAuth authSubst r.arUpper,
          arExact = r.arExact,
        })
        residual,
    mtiSubstitution = MethodInstantiationSubst {
      misTypeSubst = typeSubst,
      misEffectSubst = effectSubst,
      misAuthSubst = authSubst,
    },
  }

-- Only term occurrences incur the forcing row and the scheme's residual
-- obligations, which become obligations of the using scope. Type probes,
-- constructor patterns and dictionary elaboration use effect-neutral
-- instantiation.
export
forceInstantiation : ModuleCtx -> String -> MethodTrackedInstantiation -> Mono
forceInstantiation mctx name inst =
  performEffect mctx mctx.mcCells.curEffect inst.mtiForce
  fold
    (_ r => wantAuthorityFrom mctx (Some name) r.arExact r.arLower r.arUpper)
    ()
    inst.mtiResidual
  inst.mtiBody

export
instantiateValueTracked : ModuleCtx ->
  String ->
  Scheme ->
  MethodTrackedInstantiation
instantiateValueTracked mctx name scheme =
  let inst = instantiateMethodTracked mctx scheme
  let _ = forceInstantiation mctx name inst
  mctx.mcGraph.graphRun.grants.gsLastInst :=
    Some (scheme, inst.mtiSubstitution.misAuthSubst)
  inst

-- pair each declared slot with the argument vector its signature recorded.  The vector
-- list is a PREFIX (`keptConstraintArgs`; and `registerInferredFor` records `[]` for a
-- slot whose predicate it could not recover — S-inferred-vector-supply, #1869), so a slot
-- past its end, or with an empty vector at its position, gets `[]`, which every consumer
-- reads as "no vector recoverable".
export
zipSlotVecs : List CSlot -> List (List Mono) -> List (CSlot, List Mono)
zipSlotVecs [] _ = []
zipSlotVecs (s :: rest) [] = (s, []) :: zipSlotVecs rest []
zipSlotVecs (s :: rest) (v :: vs) = (s, v) :: zipSlotVecs rest vs

-- Chunk D: if one of [a]/[b] is a still-unbound literal var and the other is
-- concrete-headed, tag that literal's loc with [kind] so the reframe can use
-- site-specific wording.  Pure state capture — never alters unification.
export
noteNumlitCtx : ModuleCtx -> Mono -> Mono -> JoinContext -> Unit
noteNumlitCtx mctx a b kind =
  tagNumlitCtxIf mctx a b kind
  tagNumlitCtxIf mctx b a kind

-- Tag EVERY literal whose var shares [v]'s root (not just the first) when [other]
-- has a concrete head — so a heterogeneous list forcing several literals to one
-- type tags them all with the same [kind], letting their reframed messages dedup to
-- a single "list elements have different types" line.
tagNumlitCtxIf : ModuleCtx -> Mono -> Mono -> JoinContext -> Unit
tagNumlitCtxIf mctx v other kind
  | isSome (headTyconMono other) = tagAllLitLocs mctx v kind
  | otherwise = ()

tagAllLitLocs : ModuleCtx -> Mono -> JoinContext -> Unit
tagAllLitLocs mctx v kind = match normalize v
  TVar cell =>
    tagLitLocsWithRoot mctx (tyvarId cell) kind mctx.mcCells.numlitVarLocs.value
  _ => ()

tagLitLocsWithRoot : ModuleCtx -> Int -> JoinContext -> List (Mono, Loc) -> Unit
tagLitLocsWithRoot mctx _ _ [] = ()
tagLitLocsWithRoot mctx id kind ((mv, l) :: rest) =
  if sameRootId id mv then
    mctx.mcCells.numlitCtxTags := (l, kind) :: mctx.mcCells.numlitCtxTags.value
  tagLitLocsWithRoot mctx id kind rest

-- The arrow a callee presents, introduced when its shape is still unknown.
export
calleeArrow : DynCtx -> Mono -> (Mono, EffRow, Mono)
calleeArrow dyn ft = match normalize ft
  TFun dom row res => (dom, row, res)
  _ =>
    let dom = freshVar dyn.dcModule ()
    let row = openRow dyn.dcModule ()
    let res = freshVar dyn.dcModule ()
    unifyIn dyn ft (TFun dom row res)
    (dom, row, res)

-- The type a `Ref` cell stores, read verbatim: the read is a directed flow out
-- of the cell, so a stored qualifier survives it.  A cell whose shape is still
-- unknown takes the `Ref` shape here.
export
refStored : DynCtx -> Mono -> Mono
refStored dyn t = match normalize t
  TApp (TCon "Ref" _) inner => inner
  _ =>
    let inner = freshVar dyn.dcModule ()
    unifyIn dyn t (TApp (tconBuiltin "Ref") inner)
    inner

export
instantiateLegacyVarTracked : ModuleCtx ->
  String ->
  Int ->
  Scheme ->
  MethodTrackedInstantiation
instantiateLegacyVarTracked mctx x id s =
  match lookupSchemeObls x id mctx.mcCells.schemeObligationsRef.value
    Some obs =>
      let inst = instantiateValueTracked mctx x s
      recordSchemeCallObligations mctx id obs inst.mtiSubstitution.misTypeSubst
      inst
    -- #673: schemeObligationsRef is a PER-MODULE ref (reset per module), so a CROSS-MODULE
    -- constrained binding used as a plain EVar has NO entry here.  For a PRELUDE binding
    -- (`println : Display a => …`, the #673 repro) the plain-`instantiate` fallback silently
    -- DROPPED its call obligation, so `check` false-greened on `println (Foo 1)` / a 6-tuple
    -- with no Display while `run`/`build` (dict elaboration is a separate net) rejected.
    None => match declaredCrossModuleObls mctx x
      Some obs =>
        let inst = instantiateValueTracked mctx x s
        recordSchemeCallObligations
          mctx
          id
          obs
          inst.mtiSubstitution.misTypeSubst
        inst
      None => instantiateValueTracked mctx x s

-- #673: the declared call obligations of a CROSS-MODULE constrained binding [x] used as a
-- plain EVar, in schemeObligations shape (`(iface, quantified-var-id VECTOR)` list) so the
-- caller records them exactly like the same-module `Some obs` branch.  TWO source-EXACT
-- lookups, NEVER a name-only whole-table scan (both correctness- and perf-unsound, #673 rework):
--
--   (1) qualConstraintFor x — a USER import resolves through currentImportDefinersRef to the
--       ACTUAL owning module's (src, name) qual entry, so a same-named import from a DIFFERENT
--       module (foo's constrained `bar` vs baz's unconstrained `bar`, where `x` resolves to
--       baz) can never be misattributed.  It also gates on the cheap currentImportDefinersRef
--       membership, so only a genuine import pays a scan — not every unconstrained/local var.
--   (2) coreSchemeObligationsRef — core's OWN captured schemeObligationsRef (snapshotted right
--       after the core pass, before the first module's `freshModuleCtx`).  Prelude names are
--       deliberately excluded from currentImportDefinersRef (importDefinersOf skips `core`),
--       so qualConstraintFor cannot see them; this is the source-EXACT store for exactly that
--       set (`println`/`print`), an O(log n) OrdMap lookup with ZERO wrong-module surface.
--   (3) #1114/#845 — crossModuleSchemeOblsQualRef, the (module, name)-attributed
--       snapshot of every USER module's own schemeObligationsRef.  Lookups (1) and (2)
--       between them cover only DECLARED contexts (funConstraintsRef, whose inferred
--       half is `dictEligibleSetRef`-gated and empty on the check path) and CORE.  An
--       UNSIGNATURED constrained export of a user module — `export f x = go x where go
--       n = n + 1`, whose `Num a =>` is inferred, not written — is in NEITHER, so its
--       obligation was dropped at every importing call site and `check` false-greened
--       on `f "abc"` (`run` panicked `unknown op '+'`; `build` exited 0 and the binary
--       SEGFAULTED).  Per DICT-SEMANTICS §4.2 D6(a) a declared and an inferred context
--       defer identically — §4 `(gen)`/`(gen-sig)` put both on the SCHEME — so the
--       cross-module use site must read the store that holds the scheme context, which
--       is exactly what the same-module use site reads one branch up.
--
-- ORDER: (1) then (3) then (2).  (1) stays first, so every SIGNED callee resolves exactly
-- as it did.  (3) precedes (2) because (3) is IMPORT-SCOPED and (2) is a program-global
-- bare-NAME table.  The disjointness does not come from `currentImportDefinersRef`
-- (that is (1)'s gate; (3) reads `importedSchemeOblsRef`): (3)'s table is rebuilt per module from
-- THIS module's own `DUse` decls, and `importDefinersOf` skipping `core` is irrelevant to it —
-- what keeps prelude names out of (3) is that no module writes a `DUse` for the implicit prelude
-- at all, so no arm of `importedSchemeOblEntries` ever emits one.  The populations are therefore
-- disjoint by construction, and the one case where both could answer — a user module exporting a
-- name core also defines — is exactly the case where the import-scoped answer is the right one.
export
declaredCrossModuleObls : ModuleCtx -> String -> Option (List VecObl)
declaredCrossModuleObls mctx x = match qualConstraintDecl mctx x
  -- S-xmod-vector-supply (#1868/#1867): lookup (1) reads the WHOLE qual entry, not just
  -- its slots.  Reading the slots alone is what made this lookup the truncation point:
  -- `vecOblsOfSlots` lifted each slot to a ONE-argument obligation, so an imported
  -- `Ix a Bool =>` was re-checked as the unary goal `Ix Int` — which matched `impl Ix
  -- Int Char` and ACCEPTED an unsatisfiable program (#1868), and matched two impls and
  -- REJECTED a legal one (#1867).  The same-module branch one level up
  -- (`schemeObligationsRef`) has carried the full vector since #1161; this is the
  -- cross-module twin of that fact, and `substVecOblArgs` already knows how to
  -- instantiate it.
  Some d => Some (vecOblsOfSlotVecs (zipSlotVecs d.cdSlots d.cdArgs))
  None => match qualSchemeOblsFor mctx x
    Some obs => Some obs
    None => omLookup x mctx.mcGraph.crossRun.coreSchemeObligationsRef.value

-- #1114 (#845): lookup (3) of declaredCrossModuleObls — the SCHEME context of a
-- cross-module callee, keyed by the LOCAL spelling this module writes.  The table is
-- `importedSchemeOblsRef`, rebuilt per module from THIS module's own `DUse` decls (see
-- `importedSchemeOblEntries`), so a hit is already source-exact: an entry exists only
-- because one of this module's imports names the module that defines it.
--
-- SPELLING-complete on purpose, and that is the whole reason this is a per-module
-- table rather than another `currentImportDefinersRef` gate.  `importDefinersOf` is
-- populated only from `UseGroup` (`importedBindings` answers `None` for `UseWild` and
-- `Some []` for `UseAlias`), so anything gated on it is a rule about ONE of the three
-- import spellings.  Measured on the pre-fix binary, all three cross-module spellings
-- dropped the obligation for an unsignatured constrained callee, and `import m.*` /
-- `import m as A` dropped it for a SIGNATURED one too — so gating this lookup the same
-- way would have drained exactly one cell of a 2x3 matrix and left the rule
-- spelling-matched, which is the shape #674/#1070 warn about.  Keying by the local
-- spelling covers all three arms with one rule and no per-spelling branch at the
-- READ site.
qualSchemeOblsFor : ModuleCtx -> String -> Option (List VecObl)
qualSchemeOblsFor mctx name =
  omLookup name mctx.mcCells.importedSchemeOblsRef.value

-- lift each already-paired dict slot, WITH its recorded predicate argument vector, to a
-- vector obligation, skipping slots with no interface.
--
-- The pairing of interfaces with ids happens once, in `pairSlots`, so this function
-- cannot be handed a mispaired input.
--
-- The vector is the point (#1868/#1867): emitting `voArgs = []` unconditionally — the
-- "shattered per-tyvar dict slots" reading of `funConstraintsRef` — would make
-- `substVecOblArgs` instantiate through `substMonos o.voIds`, i.e. ONE argument per
-- slot.  For a binary predicate that is not a weaker obligation, it is a DIFFERENT one:
-- `Ix a Bool` re-checked as `Ix Int`.  An empty vector still means exactly what it meant
-- (`voArgs = []` ⇒ the historical ids-only path), so a slot past the args prefix — an
-- inferred callee whose vector `registerInferredFor` could not recover, a module with no
-- args row — is byte-identically unchanged.
vecOblsOfSlotVecs : List (CSlot, List Mono) -> List VecObl
vecOblsOfSlotVecs [] = []
vecOblsOfSlotVecs ((s, v) :: rest)
  | s.csIface.irName == "" = vecOblsOfSlotVecs rest
  | otherwise = xmodVecObl s v :: vecOblsOfSlotVecs rest

-- ONE cross-module slot's obligation.  The admission rule is `declaredOblMixed`'S,
-- Deliberately and argument-FOR-ARGUMENT — this is the same fact for an IMPORTED callee
-- that that function records for a same-module one, and a channel that admitted a wider
-- argument class on one side of a module boundary than the other would be a new
-- divergence, not a fix.  Exactly two classes carry:
--   * a BARE tyvar — `substOblArgs` maps it through the call's instantiation subst, and
--     an id that subst does not carry skips the whole predicate (fails CLOSED, as the
--     ids-only path always did);
--   * a GROUND argument — no tyvars anywhere, so the signature's mono IS the call's mono.
-- #1937 adds a THIRD class, in lockstep with the same widening on the two same-module
-- channels (`declaredOblMixed`, `residualMixedPred`) — the header's own argument is why
-- it could not land on one side alone:
--   * a STRUCTURED argument mentioning a tyvar (`Ix a (List b)`) — `substOblArgs` now
--     recurses through `TApp`/`TFun` and substitutes at every tyvar LEAF, so the
--     importer's goal is the instantiated `Ix Int (List Bool)` rather than the defining
--     signature's cell carried across the boundary.  A leaf id the subst does not carry
--     still skips the whole predicate, exactly as the bare class does.
-- A slot past the args prefix still falls back to `voArgs = []`, today's per-tyvar goal.
-- [voIds] holds the deferred-on ids IN ORDER, per `VecObl`'s invariant — NOT `[s.csId]`,
-- which is only the LEAD one and would understate a `Ix a b =>` vector.
xmodVecObl : CSlot -> List Mono -> VecObl
xmodVecObl s v
  | isEmptyL v || isEmptyL (flatMap xmodOblArgId v) =
    VecObl { voIface = s.csIface, voIds = [s.csId], voArgs = [] }
  | otherwise =
    VecObl { voIface = s.csIface, voIds = flatMap xmodOblArgId v, voArgs = v }

-- map each (iface, scheme-var-id VECTOR) through the instantiation subst to this
-- call's monos, pushing ONE joint obligation per predicate onto the call channel
-- (`Windowed UObligation`, #838 I1).  [originId] is the occurrence's own #837 binding
-- id (threaded from instantiateVarTrackedId's [id] — the binding this re-instantiation
-- was deferred by; 0 = anchorless), stored on the record so a later increment (I2) can
-- read it without a second migration.  If ANY id is absent from the subst (shouldn't
-- happen for a quantified var) the whole predicate is skipped — a partial vector would
-- be a different predicate (#607).
export
recordSchemeCallObligations : ModuleCtx ->
  Int ->
  List VecObl ->
  List (Int, Mono) ->
  Unit
recordSchemeCallObligations mctx _ [] _ = ()
recordSchemeCallObligations mctx originId (o :: rest) subst =
  match substVecOblArgs o subst
    Some monos =>
      -- `schemeObligationsRef` and its cross-module mirrors
      -- store `VecObl`, whose interface half is an identity-carrying `IfaceRef`, so this
      -- site never records `OriginUnresolved`.
      recordObl
        mctx
        Predicate {
          iface = o.voIface,
          args = monos,
        }
        originId
        PSchemeReinst
        mctx.mcLoc
      recordSchemeCallObligations mctx originId rest subst
    None => recordSchemeCallObligations mctx originId rest subst

-- #1161: this predicate's goal at THIS call's instantiation.  An ids-only entry
-- (`voArgs == []`) takes the historical `substMonos` path unchanged; a vector-carrying
-- entry maps its tyvar LEAVES through [subst] and keeps everything else as written.
-- `None` (an unmapped quantified id) still skips the whole predicate: a partial vector
-- is a different predicate (#607).
substVecOblArgs : VecObl -> List (Int, Mono) -> Option (List Mono)
substVecOblArgs o subst
  | isEmptyL o.voArgs = substMonos o.voIds subst
  | otherwise = substOblArgs o.voIds o.voArgs subst

-- #837: (name, id)-keyed lookup over schemeObligationsRef.  id /= 0 keys the
-- occurrence's binding EXACTLY; id == 0 falls to the bare-name scan (today's path).
export
lookupSchemeObls : String ->
  Int ->
  List ((String, Int), List VecObl) ->
  Option (List VecObl)
lookupSchemeObls x 0 table = lookupSchemeOblsByName x table
lookupSchemeObls _ _ [] = None
lookupSchemeObls x id (((n2, i2), v) :: rest)
  | n2 == x && i2 == id = Some v
  | otherwise = lookupSchemeObls x id rest

-- name-only scan (first match) — the bare-name fallback and the display readers
-- (lookupSchemeIface) keep exactly this pre-#837 behaviour.
lookupSchemeOblsByName : String ->
  List ((String, Int), List VecObl) ->
  Option (List VecObl)
lookupSchemeOblsByName _ [] = None
lookupSchemeOblsByName x (((n2, _), v) :: rest)
  | n2 == x = Some v
  | otherwise = lookupSchemeOblsByName x rest

-- as `unifySpineResult`, but a PROBE: it performs no effect and discards the result.
-- The dict-slot and obligation recoveries below unify only to populate a substitution.
export
unifySpineProbe : DynCtx -> Mono -> List Mono -> Unit
unifySpineProbe dyn ft args =
  let saved = wSnapshot dyn.dcModule.mcCells.fileValueFlows
  unifySpineProbeGo dyn ft args
  wRestore dyn.dcModule.mcCells.fileValueFlows saved

unifySpineProbeGo : DynCtx -> Mono -> List Mono -> Unit
unifySpineProbeGo dyn _ [] = ()
unifySpineProbeGo dyn ft (a :: rest) =
  let r = freshVar dyn.dcModule ()
  let _ = applicationRowTyped dyn ft a r
  unifySpineProbeGo dyn r rest

-- [actual] flows INTO a slot of type [expected] — a call argument into the
-- callee's domain, a signed body into its signature, a supplied field, an
-- annotated expression, an impl body into its method type — so the direction is
-- known: at a covariant position the actual's row must be within the expected's,
-- at a contravariant one the reverse, and a non-covariant type-constructor slot
-- demands equality (`paramVarianceGuard`). A closed lower row already covered
-- by the upper row's known labels imposes no constraint on its tail. Closed
-- pairs are checked directionally. Inside an inference scope, open rows become
-- solver constraints. A flexible upper type acquires a positive envelope rather
-- than copying the first value's closed rows. Other shape equations use ordinary
-- `unify`, including the order a plain type mismatch names the two sides in:
-- `unifyInto` names the slot first,
-- as a call argument's `unify` did; `unifyIntoOrd True` names the value first,
-- as an annotation and a supplied field do (through `argumentIntoOrd`).
export
unifyInto : DynCtx -> Bool -> Mono -> Mono -> Unit
unifyInto dyn pos e a = unifyIntoOrd dyn False pos e a

-- [valueFirst] is only the operand order of the fallback `unify`.
export
unifyIntoOrd : DynCtx -> Bool -> Bool -> Mono -> Mono -> Unit
unifyIntoOrd dyn valueFirst pos e a =
  if monoHasArrowInSlot e || monoHasArrowInSlot a then
    if pos then
      recordFileValueFlow dyn.dcModule dyn.dcModule.mcLoc e a
    else
      recordFileValueFlow dyn.dcModule dyn.dcModule.mcLoc a e
  unifyIntoStep dyn valueFirst pos e a

-- Capture a directed judgment once; recursive descent does not rescan every
-- remaining type subtree for packed arrows.
unifyIntoStep : DynCtx -> Bool -> Bool -> Mono -> Mono -> Unit
unifyIntoStep dyn valueFirst pos e a =
  unifyIntoN dyn valueFirst pos (normalize e) (normalize a)

unifyIntoN : DynCtx -> Bool -> Bool -> Mono -> Mono -> Unit
unifyIntoN dyn _ True (TVar cell) (lower@(TFun _ _ _)) =
  bindValueUpper dyn cell lower
unifyIntoN dyn _ True (TVar cell) (lower@(TApp _ _)) =
  bindValueUpper dyn cell lower
unifyIntoN dyn _ False (lower@(TFun _ _ _)) (TVar cell) =
  bindValueUpper dyn cell lower
unifyIntoN dyn _ False (lower@(TApp _ _)) (TVar cell) =
  bindValueUpper dyn cell lower
-- A qualified value reaching a flexible slot gives it a qualified shape with
-- an allowance above the value's authority, so several values can converge.
unifyIntoN dyn _ True (TVar cell) (lower@(TQual _ _)) =
  bindValueUpper dyn cell lower
unifyIntoN dyn _ False (lower@(TQual _ _)) (TVar cell) =
  bindValueUpper dyn cell lower
-- A flexible slot the qualified value flows OUT OF keeps the qualifier as it
-- is, so a composed or partially applied function still names its authority.
unifyIntoN dyn _ _ (TVar cell) (t@(TQual _ _)) = bindVar dyn cell t
unifyIntoN dyn _ _ (t@(TQual _ _)) (TVar cell) = bindVar dyn cell t
-- Qualified into qualified: the flowing side's authority must be within the
-- receiving side's.  Qualified into plain forgets; plain into qualified can
-- only be admitted when the qualifier admits the domain's top, since nothing
-- bounds the plain value (the application site refines this with α).
unifyIntoN dyn vf pos (TQual e qe) (TQual a qa) =
  if pos then
    wantAuthority dyn.dcModule qa qe
  else
    wantAuthority dyn.dcModule qe qa
  unifyIntoStep dyn vf pos e a
unifyIntoN dyn vf pos (TQual e qe) a =
  if pos then wantAuthority dyn.dcModule (authTop (authDomainTop qe)) qe
  unifyIntoStep dyn vf pos e a
unifyIntoN dyn vf pos e (TQual a qa) =
  if pos then () else wantAuthority dyn.dcModule (authTop (authDomainTop qa)) qa
  unifyIntoStep dyn vf pos e a
unifyIntoN dyn _ _ (TAuth qe) (TAuth qa) = unifyIndex dyn.dcModule qa qe
unifyIntoN dyn vf pos (TFun e1 er e2) (TFun a1 ar a2) =
  unifyIntoStep dyn vf (not pos) e1 a1
  rowInto dyn pos (effrowNorm er) (effrowNorm ar)
  unifyIntoStep dyn vf pos e2 a2
unifyIntoN dyn vf pos (e@(TApp e1 e2)) (a@(TApp a1 a2))
  | tupleUnifyClash e a || monoSlotNonCovariant dyn.dcModule e1 =
    unifyOrdered dyn vf e a
  | otherwise =
    unifyIntoStep dyn vf pos e1 a1
    unifyIntoStep dyn vf pos e2 a2
unifyIntoN dyn vf _ e a = unifyOrdered dyn vf e a

-- A flexible receiving slot acquires the value's shape, not its first closed
-- row. Positive arrows get inference allowances with directed lower bounds;
-- domains and invariant constructor arguments keep ordinary HM equality.
-- This is the same structural envelope as a produced-value join, so a generic
-- choice cannot depend on which callback happens to be supplied first.
bindValueUpper : DynCtx -> Ref Tyvar -> Mono -> Unit
bindValueUpper dyn cell lower =
  dyn.dcModule.mcCells.occursCheckFailed := False
  occursAdjust dyn.dcModule (tyvarId cell) (tyvarLevel cell) lower
  if not dyn.dcModule.mcCells.occursCheckFailed.value then
    let upper =
      optionOrFresh
        dyn.dcModule
        (joinProducedEnvelope (valueJoinOps
          dyn
          JoinArgument
          collectValueAllowance) [
          (dyn.dcModule.mcLoc, lower),
        ])
    recordFileValueFlow dyn.dcModule dyn.dcModule.mcLoc upper lower
    bindVar dyn cell upper

collectValueAllowance : DynCtx -> List EffRow -> EffRow
collectValueAllowance dyn rows =
  let cell = freshInferenceEffvar dyn.dcModule ()
  EffectSolver.registerValueAllowance dyn.dcModule.mcCells.effectSummaries cell
  let upper = EffRow [] (Some cell)
  fold (_ lower => rowInto dyn True upper lower) () rows
  upper

unifyOrdered : DynCtx -> Bool -> Mono -> Mono -> Unit
unifyOrdered dyn True e a = unifyIn dyn a e
unifyOrdered dyn False e a = unifyIn dyn e a

-- Check the known inclusion without equating the allowance with the performed
-- row. In particular, a pure alternative must not close an allowance's tail.
export
rowInto : DynCtx -> Bool -> EffRow -> EffRow -> Unit
rowInto dyn pos er ar
  | EffectSolver.hasSummaryScope dyn.dcModule.mcCells.effectSummaries =
    if pos then
      deferEffectRelation dyn.dcModule False ar er
    else
      deferEffectRelation dyn.dcModule False er ar
rowInto dyn True (EffRow le None) (EffRow la None) =
  effectLeakCheck dyn.dcModule (atomsEscape dyn.dcModule.mcGraph la le) le
rowInto dyn False (EffRow le None) (EffRow la None) =
  contraRowCheck dyn.dcModule (atomsEscape dyn.dcModule.mcGraph le la) le la
rowInto dyn True (er@(EffRow le _)) (ar@(EffRow la None)) =
  if isEmptyL (atomsEscape dyn.dcModule.mcGraph la le) then
    ()
  else
    unifyRowN dyn er ar
rowInto dyn False (er@(EffRow le None)) (ar@(EffRow la _)) =
  if isEmptyL (atomsEscape dyn.dcModule.mcGraph le la) then
    ()
  else
    unifyRowN dyn er ar
rowInto dyn _ er ar = unifyRowN dyn er ar

-- the contravariant half of `rowInto`: the expected PARAMETER row [le] admits
-- atoms the actual's parameter row [la] does not, so a caller could hand the
-- actual an argument it would run under too small a row.
contraRowCheck : ModuleCtx -> List Atom -> List Atom -> List Atom -> Unit
contraRowCheck mctx [] _ _ = ()
contraRowCheck mctx extras le la =
  pushTypeError mctx "T-EFFECT-LEAK" (contraRowMsg le la extras)

export
monoHasNonCovariantSlot : ModuleCtx -> Mono -> Bool
monoHasNonCovariantSlot mctx t = match normalize t
  TApp a b =>
    monoSlotNonCovariant mctx a
      || monoHasNonCovariantSlot mctx a
      || monoHasNonCovariantSlot mctx b
  TFun a _ b => monoHasNonCovariantSlot mctx a || monoHasNonCovariantSlot mctx b
  _ => False

-- is the slot applied at the node above [hd] (positional index = the depth of
-- [hd]'s own spine) recorded as non-covariant for [hd]'s head?  The same read
-- `paramVarianceGuard` makes, so the two agree on which slots count.
monoSlotNonCovariant : ModuleCtx -> Mono -> Bool
monoSlotNonCovariant mctx hd = match headTyconMono hd
  Some (HkDecl key) => match paramPolaritiesOf mctx key
    Some pols => match polarityAt pols (monoSpineDepth hd)
      PCo => False
      _ => True
    None => False
  _ => False

-- unify each param type with its expected type, for the prefix both lists cover.
export
unifyParamsExpected : DynCtx -> List Mono -> List Mono -> Unit
unifyParamsExpected dyn (p :: ps) (e :: es) =
  bindFrom dyn p e
  unifyParamsExpected dyn ps es
unifyParamsExpected dyn _ _ = ()

-- The same judgment where only the argument's type is at hand (a pipe, a
-- composition, a dispatch spine): the type's own qualifier or the top.
export
applicationRowTyped : DynCtx -> Mono -> Mono -> Mono -> EffRow
applicationRowTyped dyn ft xt result = match normalize ft
  TFun dom row res =>
    argumentIntoTyped dyn dom xt
    bindFrom dyn result res
    row
  _ =>
    let unknown = openRow dyn.dcModule ()
    unifyIn dyn ft (TFun xt unknown result)
    unknown

argumentIntoTyped : DynCtx -> Mono -> Mono -> Unit
argumentIntoTyped dyn dom xt = match normalize dom
  TQual d q =>
    unifyInto dyn True d xt
    wantAuthority dyn.dcModule (typeAuthority (authDomainTop q) xt) q
  _ => unifyInto dyn True dom xt

-- Inference owns source locations and variance metadata; effect_values owns
-- the structural join. Unknown constructor slots remain exact.
export
joinValueTypes : DynCtx -> JoinContext -> List (Option Loc, Mono) -> Mono
joinValueTypes dyn context values =
  let upper =
    optionOrFresh
      dyn.dcModule
      (joinProduced
        (valueJoinOps dyn context (_ =>
          collectRows (joinCellOf dyn.dcModule.mcGraph)))
        values)
  let _ =
    map
      ((loc, lower) => recordFileValueFlow dyn.dcModule loc upper lower)
      values
  upper

export
valueJoinOps : DynCtx ->
  JoinContext ->
  (DynCtx -> List EffRow -> EffRow) ->
  ValueJoinOps (Option Loc)
valueJoinOps dyn context collector =
  let ops = decidingJoinOps dyn context collector
  { ops | vjoDefer = values => deferJoin dyn.dcModule context collector values }

-- The join services that decide on the spot: resolving a recorded join
-- must not record it again.
decidingJoinOps : DynCtx ->
  JoinContext ->
  (DynCtx -> List EffRow -> EffRow) ->
  ValueJoinOps (Option Loc)
decidingJoinOps dyn context collector = ValueJoinOps {
  vjoEqual = joinValueEqual dyn context,
  vjoCovariants = producedSlotCovariants dyn.dcModule,
  vjoFreshType = freshVar dyn.dcModule,
  vjoFreshRow = openRow dyn.dcModule,
  vjoCollectRows = collector dyn,
  vjoFreshAuth = top => AVar (freshAuthvar dyn.dcModule top None),
  vjoCollectAuth = collectAuthAllowance dyn.dcModule,
  vjoDefer = _ => None,
}

-- Alternatives with no shape yet (`if c then f else g` over two parameters)
-- are not equated: equality would give both the same latent row before a
-- later use shapes one of them.  Inside a binding scope the join is recorded
-- and decided when the scope closes (§6.8); outside one it is decided now.
deferJoin : ModuleCtx ->
  JoinContext ->
  (DynCtx -> List EffRow -> EffRow) ->
  List (Option Loc, Mono) ->
  Option Mono
deferJoin mctx context collector values =
  if EffectSolver.hasSummaryScope mctx.mcCells.effectSummaries
    && distinctVariables values then
    let result = freshVar mctx ()
    mctx.mcCells.pendingJoinsRef :=
      PendingJoin {
          pjResult = result,
          pjValues = values,
          pjLevel = mctx.mcCells.currentLevel.value,
          pjContext = context,
          pjCollector = collector,
        }
        :: mctx.mcCells.pendingJoinsRef.value
    Some result
  else
    None

-- At least two different unshaped alternatives: a single alternative, or one
-- variable met on every branch, has nothing to join.
distinctVariables : List (Option Loc, Mono) -> Bool
distinctVariables values =
  let roots =
    fold
      (acc (_, value) => match normalize value
        TVar cell => IdMap.set (tyvarId cell) () acc
        _ => acc)
      Tip
      values
  listLen (IdMap.keys roots) >= 2

-- Decide every join recorded at this level or deeper: the ones the closing
-- scope owns, which sit at the front of the list.  A top-level group decides
-- all of its joins, since the routes of the methods it uses are fixed when it
-- closes.  Newest first, so an outer join shapes its alternatives before an
-- inner join whose result is one of them is decided from that shape.
export
resolvePendingJoins : DynCtx -> Int -> Unit
resolvePendingJoins dyn level = match dyn.dcModule.mcCells.pendingJoinsRef.value
  pj :: rest =>
    if pj.pjLevel >= level then
      dyn.dcModule.mcCells.pendingJoinsRef := rest
      resolvePendingJoin dyn pj
      resolvePendingJoins dyn level
  [] => ()

-- Settle the joins a local binding scope recorded before the binding
-- generalizes.  A join whose alternatives are all still unshaped variables of
-- an enclosing level (the enclosing function's parameters) is handed to the
-- enclosing scope, its result lowered to that level so the binding cannot
-- generalize over it, exactly as equating it with those variables would; a
-- later use there may still shape an alternative.  Any other join is decided
-- now, including one whose result is already outer but which has a local
-- alternative: handing it out would let the binding generalize that
-- alternative while the join still constrains it.
export
settlePendingJoins : DynCtx -> Int -> Unit
settlePendingJoins dyn level =
  let postponed = settlePending dyn level []
  dyn.dcModule.mcCells.pendingJoinsRef :=
    reverseL postponed ++ dyn.dcModule.mcCells.pendingJoinsRef.value

settlePending : DynCtx -> Int -> List PendingJoin -> List PendingJoin
settlePending dyn level postponed =
  match dyn.dcModule.mcCells.pendingJoinsRef.value
    pj :: rest =>
      if pj.pjLevel >= level then
        dyn.dcModule.mcCells.pendingJoinsRef := rest
        if joinOfOuterVariables level pj then
          lowerTyvarLevel (level - 1) pj.pjResult
          settlePending dyn level ({ pj | pjLevel = level - 1 } :: postponed)
        else
          resolvePendingJoin dyn pj
          settlePending dyn level postponed
      else
        postponed
    [] => postponed

joinOfOuterVariables : Int -> PendingJoin -> Bool
joinOfOuterVariables level pj =
  isUnshaped pj.pjResult
    && allList (value => isOuterVariable level (snd value)) pj.pjValues

isOuterVariable : Int -> Mono -> Bool
isOuterVariable level t = match normalize t
  TVar cell => tyvarLevel cell < level
  _ => False

lowerTyvarLevel : Int -> Mono -> Unit
lowerTyvarLevel level t = match normalize t
  TVar cell => match !cell
    Unbound id old => if old > level then cell := Unbound id level
    Link _ => ()
  _ => ()

-- A scope whose bindings do not generalize hands its recorded joins to the
-- enclosing scope.
export
postponePendingJoins : ModuleCtx -> Int -> Unit
postponePendingJoins mctx level =
  mctx.mcCells.pendingJoinsRef :=
    lowerPending level mctx.mcCells.pendingJoinsRef.value

lowerPending : Int -> List PendingJoin -> List PendingJoin
lowerPending level (pj :: rest)
  | pj.pjLevel >= level =
    { pj | pjLevel = level - 1 } :: lowerPending level rest
lowerPending _ pending = pending

-- Decide a join at the close of its scope.  A result a unification shaped
-- was decided then (`takeJoinsShapedBy`); one still shaped here is decided
-- the same way.
resolvePendingJoin : DynCtx -> PendingJoin -> Unit
resolvePendingJoin dyn pj = match normalize pj.pjResult
  TVar _ =>
    unifyIn
      dyn
      pj.pjResult
      (resolveDeferredJoin
        (decidingJoinOps dyn pj.pjContext pj.pjCollector)
        pj.pjValues)
  _ => settleShapedJoins dyn [pj]

-- A receiving qualified slot's allowance: one flexible variable of the
-- current scope, bounded below by every value that reaches the slot.
collectAuthAllowance : ModuleCtx -> List Authority -> Authority
collectAuthAllowance mctx lowers =
  let top = match lowers
    q :: _ => authDomainTop q
    [] => PUnit
  let cell = freshAuthvar mctx top None
  fold (_ q => wantAuthority mctx q (AVar cell)) () lowers
  AVar cell

export
optionOrFresh : ModuleCtx -> Option Mono -> Mono
optionOrFresh mctx None = freshVar mctx ()
optionOrFresh mctx (Some value) = value

joinValueEqual : DynCtx -> JoinContext -> Option Loc -> Mono -> Mono -> Unit
joinValueEqual outer context loc left right =
  let dyn = dynAtIfSome loc outer
  noteNumlitCtx dyn.dcModule left right context
  unifyIn { dyn | dcJoin = Some context } left right

export
producedSlotCovariants : ModuleCtx -> Mono -> List Bool
producedSlotCovariants mctx head = match headTyconMono head
  Some (HkDecl key) =>
    let slot = monoSpineDepth head
    match paramPolaritiesOf mctx key
      Some polarities => map isCovariantPolarity (drop slot polarities)
      None =>
        if tabKeyEq key (tyTabKey OriginBuiltin "List") then
          if slot == 0 then [True] else []
        else match headTyconNameMono head
          Some name => match tupleTagArity name
            Some arity =>
              if tabKeyEq key (tyTabKey OriginBuiltin name) then
                replicate (arity - slot) True
              else
                []
            None => []
          None => []
  _ => []

isCovariantPolarity : Polarity -> Bool
isCovariantPolarity PCo = True
isCovariantPolarity _ = False

export
raiseAuthvarLevel : Int -> Ref Authvar -> Unit
raiseAuthvarLevel level cell = match !cell
  AUnbound id _ top pat name => cell := AUnbound id level top pat name
  ALink _ _ _ => ()

export
polarityAt : List Polarity -> Int -> Polarity
polarityAt [] _ = PCo
polarityAt (q :: rest) i = if i <= 0 then q else polarityAt rest (i - 1)

export
freshVars : ModuleCtx -> Int -> List Mono
freshVars mctx n
  | n <= 0 = []
  | otherwise = freshVar mctx () :: freshVars mctx (n - 1)

export
lowerOwnedRoot : ModuleCtx -> Int -> Mono -> Unit
lowerOwnedRoot mctx owner m = match normalize m
  TVar cell => if tyvarLevel cell == owner then lowerToCurrent mctx m
  _ => ()

-- the (id, level) of every UNBOUND tyvar in [t] (sibling of monoUnboundIds, but
-- carrying the level so registerOneAmbiguous can tell a this-group constraint var
-- from a deeper inner-generalized one that merely leaked into the obligation list).
export
monoUnboundVarLevels : Mono -> List (Int, Int)
monoUnboundVarLevels t = match normalize t
  TVar cell => [(tyvarId cell, tyvarLevel cell)]
  TCon _ _ => []
  TRigid _ => []
  TApp a b => monoUnboundVarLevels a ++ monoUnboundVarLevels b
  TFun a _ b => monoUnboundVarLevels a ++ monoUnboundVarLevels b
  TEff _ => []
  TAuth _ => []
  TQual a _ => monoUnboundVarLevels a

-- Container covariance cannot install a confinement wrapper on a function
-- already packed inside the value. Retain the directed flows until the row
-- solver closes, including the lower rows of produced-value joins.
export
recordFileValueFlow : ModuleCtx -> Option Loc -> Mono -> Mono -> Unit
recordFileValueFlow mctx loc upper lower =
  wPush mctx.mcCells.fileValueFlows (loc, upper, lower)

export
unifySourceDomains : DynCtx -> Int -> Mono -> Mono -> Unit
unifySourceDomains dyn arity owned actual =
  if arity <= 0 then
    ()
  else match (normalize owned, normalize actual)
    (TFun domain _ result, TFun param _ body) =>
      unifyIn dyn domain param
      unifySourceDomains dyn (arity - 1) result body
    _ => unifyIn dyn owned actual

export
zipBindFrom : DynCtx -> List Mono -> List Mono -> Unit
zipBindFrom dyn (p :: ps) (q :: qs) =
  bindFrom dyn p q
  zipBindFrom dyn ps qs
zipBindFrom dyn _ _ = ()
# DESUGAR
(DUse false (UseGroup ("types" "tc_types") ((mem "AbsorptionEvent" true) (mem "CDeclared" true) (mem "CDeclaredPrefix" true) (mem "CSlot" true) (mem "DynCtx" true) (mem "JoinContext" true) (mem "Kind" true) (mem "MethodInstantiationSubst" true) (mem "MethodTrackedInstantiation" true) (mem "ObligationSite" true) (mem "OblProjection" true) (mem "PendingJoin" true) (mem "Polarity" true) (mem "Predicate" true) (mem "PredicateSlotArgs" true) (mem "Provenance" true) (mem "UObligation" true) (mem "Windowed" true) (mem "DoCtx" false) (mem "dynFor" false) (mem "GraphCtx" false) (mem "ModuleCtx" false) (mem "PredicateSlot" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "authCellsIn" false) (mem "authRowCells" false) (mem "cellIdSet" false) (mem "containsI" false) (mem "dedupI" false) (mem "effvarLevel" false) (mem "headTyconMono" false) (mem "headTyconNameMono" false) (mem "isUnshaped" false) (mem "joinCellOf" false) (mem "minLevelOf" false) (mem "monoHasArrowInSlot" false) (mem "monoIsApp" false) (mem "monoSpineDepth" false) (mem "monoUnboundIds" false) (mem "newEffvarId" false) (mem "qualifierAuthIds" false) (mem "rowOfMembers" false) (mem "sameRootId" false) (mem "spineHead" false) (mem "substAuth" false) (mem "substMono" false) (mem "substMonos" false) (mem "substOblArgs" false) (mem "substRow" false) (mem "tconBuiltin" false) (mem "tupleUnifyClash" false) (mem "tyAppSpine" false) (mem "tyvarId" false) (mem "xmodOblArgId" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "dynAtIfSome" false) (mem "wAll" false) (mem "wPush" false) (mem "wRestore" false) (mem "wSnapshot" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "domainHasPatterns" false) (mem "tyTabKey" false))))
(DUse false (UseGroup ("types" "tc_diag") ((mem "firstTupleCallHint" false) (mem "pushTypeError" false) (mem "pushTypeErrorAt" false) (mem "pushTypeErrorHelpFixAt" false) (mem "recordTypeError" false))))
(DUse false (UseGroup ("types" "tc_diag_text") ((mem "authorityCoverMsg" false) (mem "authorityIndexMsg" false) (mem "authorityTermTextIn" false) (mem "closedRowMismatchMsg" false) (mem "constrainedApplicationText" false) (mem "contraRowMsg" false) (mem "deferRequiresMonadMsg" false) (mem "doRequiresMonadMsg" false) (mem "elselessIfHelp" false) (mem "indexRowMismatchMsg" false) (mem "joinMismatchMsg" false) (mem "paramVarianceMismatchMsg" false) (mem "patternIndexMsg" false) (mem "renderFlatRow" false) (mem "residualFailureMsg" false) (mem "sameSpellingHint" false) (mem "starSpelling" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" true) (mem "authDomainTop" false) (mem "authHasVars" false) (mem "authIsPattern" false) (mem "authIsTop" false) (mem "authJoinAll" false) (mem "authNorm" false) (mem "authSplit" false) (mem "authSub" false) (mem "authTop" false) (mem "authvarDomain" false) (mem "authvarId" false) (mem "authvarIsPattern" false) (mem "authvarLevel" false) (mem "authvarName" false) (mem "authVars" false) (mem "linkAuthvar" false) (mem "markAuthvarPattern" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" true) (mem "EffLabel" true) (mem "EffRow" true) (mem "Effvar" true) (mem "atomAuth" false) (mem "atomKey" false) (mem "atomsDiff" false) (mem "atomsNorm" false) (mem "atomsUnion" false) (mem "builtinLabel" false) (mem "collectRows" false) (mem "effLabelName" false) (mem "effrowNorm" false) (mem "effvarId" false) (mem "findAtom" false) (mem "isJoinCell" false) (mem "labelKey" false) (mem "linkRow" false) (mem "pureRow" false) (mem "renderAtoms" false) (mem "rowFlat" false) (mem "rowHasSummary" false))))
(DUse false (UseGroup ("types" "repr") ((mem "AuthResidual" true) (mem "Mono" true) (mem "Scheme" true) (mem "Tyvar" true) (mem "VecObl" true) (mem "normalize" false) (mem "ppAuthority" false) (mem "ppMono" false) (mem "tupleTagArity" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "EffAtomTy" true) (mem "EffParamTy" true) (mem "Loc" true) (mem "TabKey" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "lookupTab" false) (mem "sameTyConHead" false) (mem "tabKeyEq" false))))
(DUse false (UseGroup ("types" "registry") ((mem "HeadKey" true))))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true))))
(DUse false (UseGroup ("types" "evidence") ((mem "ScopeId" true))))
(DUse false (UseGroup ("types" "publish") ((mem "TcDiag" true))))
(DUse false (UseGroup ("types" "effect_values") ((mem "ValueJoinOps" true) (mem "joinProduced" false) (mem "joinProducedEnvelope" false) (mem "resolveDeferredJoin" false))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "anyList" false) (mem "dedup" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "isSome" false) (mem "listLen" false) (mem "lookupAssoc" false) (mem "minI" false) (mem "orElseOpt" false) (mem "reverseL" false) (mem "splitOnChar" false))))
(DUse false (UseGroup ("types" "effect_param_decode") ((mem "atomOfLabel" false))))
(DUse false (UseGroup ("types" "solver_contract") ((mem "Instantiation" true) (mem "Wanted" true))))
(DUse false (UseGroup ("types" "target_profile") ((mem "hostLabels" false))))
(DUse false (UseGroup ("types" "disposition") ((mem "MethodDisposition" true))))
(DUse false (UseGroup ("list") ((mem "drop" false) (mem "last" false) (mem "replicate" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omInsert" false) (mem "omLookup" false))))
(DUse false (UseGroup ("types" "invocation_basis") ((mem "paramPolaritiesIn" false))))
(DUse false (UseGroup ("types" "effect_infer") ((mem "recordEffect" false) (mem "typeAuthority" false))))
(DUse false (UseAlias ("types" "effect_solver") "EffectSolver"))
(DUse false (UseAlias ("types" "scopes") "Scopes"))
(DUse false (UseAlias ("map") "IdMap"))
(DTypeSig false "ioLabel" (TyCon "EffLabel"))
(DFunDef false "ioLabel" () (EApp (EVar "builtinLabel") (ELit (LString "IO"))))
(DTypeSig false "expandIoInBound" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "expandIoInBound" ((PVar "gctx") (PVar "b")) (EMatch (EApp (EApp (EVar "findAtom") (EApp (EVar "labelKey") (EVar "ioLabel"))) (EVar "b")) (arm (PCon "None") () (EVar "b")) (arm (PCon "Some" PWild) () (EApp (EVar "atomsNorm") (EBinOp "++" (EVar "b") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "config") "value") "tcIoJoin"))))))
(DTypeSig false "narrowPerformedIo" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))))
(DFunDef false "narrowPerformedIo" ((PVar "gctx") (PVar "diff") (PVar "bound")) (EMatch (EApp (EApp (EVar "findAtom") (EApp (EVar "labelKey") (EVar "ioLabel"))) (EVar "diff")) (arm (PCon "None") () (EVar "diff")) (arm (PCon "Some" PWild) () (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EVar "filterList") (ELam ((PVar "x")) (EBinOp "/=" (EApp (EVar "atomKey") (EVar "x")) (EApp (EVar "labelKey") (EVar "ioLabel"))))) (EVar "diff"))) (DoLet false false (PVar "join") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "config") "value") "tcIoJoin")) (DoLet false false (PVar "missing") (EApp (EApp (EVar "atomsDiff") (EVar "join")) (EVar "bound"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "missing")) (EApp (EVar "listLen") (EVar "join"))) (EVar "diff") (EIf (EApp (EVar "isEmptyL") (EVar "missing")) (EVar "rest") (EApp (EVar "atomsNorm") (EBinOp "++" (EVar "rest") (EVar "missing"))))))))))
(DTypeSig true "atomsEscape" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))))
(DFunDef false "atomsEscape" ((PVar "gctx") (PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "bound") (EApp (EApp (EVar "expandIoInBound") (EVar "gctx")) (EVar "b"))) (DoExpr (EApp (EApp (EApp (EVar "narrowPerformedIo") (EVar "gctx")) (EApp (EApp (EVar "atomsDiff") (EVar "a")) (EVar "bound"))) (EVar "bound")))))
(DTypeSig false "newTyvarId" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyCon "Int"))))
(DFunDef false "newTyvarId" ((PVar "gctx") PWild) (EBlock (DoLet false false (PVar "n") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "tyvarCounter") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "tyvarCounter")) (EBinOp "+" (EVar "n") (ELit (LInt 1))))) (DoExpr (EVar "n"))))
(DTypeSig true "freshVar" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "Mono"))))
(DFunDef false "freshVar" ((PVar "mctx") PWild) (EApp (EVar "TVar") (EApp (EVar "Ref") (EApp (EApp (EVar "Unbound") (EApp (EApp (EVar "newTyvarId") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")))))
(DTypeSig true "freshEffvar" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyApp (TyCon "Ref") (TyCon "Effvar")))))
(DFunDef false "freshEffvar" ((PVar "mctx") PWild) (EApp (EVar "Ref") (EApp (EApp (EVar "EUnbound") (EApp (EApp (EVar "newEffvarId") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value"))))
(DTypeSig true "freshEffvarAt" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Effvar")))))
(DFunDef false "freshEffvarAt" ((PVar "gctx") (PVar "lvl")) (EApp (EVar "Ref") (EApp (EApp (EVar "EUnbound") (EApp (EApp (EVar "newEffvarId") (EVar "gctx")) (ELit LUnit))) (EVar "lvl"))))
(DTypeSig false "freshInferenceEffvar" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyApp (TyCon "Ref") (TyCon "Effvar")))))
(DFunDef false "freshInferenceEffvar" ((PVar "mctx") PWild) (EBlock (DoLet false false (PVar "cell") (EApp (EApp (EVar "freshEffvar") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "EffectSolver.registerExistential") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "effectSummaries")) (EVar "cell"))) (DoExpr (EVar "cell"))))
(DTypeSig true "openRow" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "EffRow"))))
(DFunDef false "openRow" ((PVar "mctx") PWild) (EApp (EApp (EVar "EffRow") (EListLit)) (EApp (EVar "Some") (EApp (EApp (EVar "freshInferenceEffvar") (EVar "mctx")) (ELit LUnit)))))
(DTypeSig true "enterLevel" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "Unit"))))
(DFunDef false "enterLevel" ((PVar "mctx") PWild) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel")) (EBinOp "+" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value") (ELit (LInt 1)))))
(DTypeSig true "exitLevel" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "Unit"))))
(DFunDef false "exitLevel" ((PVar "mctx") PWild) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel")) (EBinOp "-" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value") (ELit (LInt 1)))))
(DTypeSig false "isRigidCell" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyCon "Bool"))))
(DFunDef false "isRigidCell" ((PVar "mctx") (PVar "cell")) (EApp (EApp (EVar "IdMap.has") (EApp (EVar "effvarId") (EVar "cell"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "rigidEffvarsRef") "value")))
(DTypeSig true "performEffect" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "EffRow"))) (TyFun (TyCon "EffRow") (TyCon "Unit")))))
(DFunDef false "performEffect" ((PVar "mctx") (PVar "cur") (PVar "eff")) (EBlock (DoExpr (EApp (EApp (EVar "recordEffectSites") (EVar "mctx")) (EVar "eff"))) (DoExpr (EApp (EApp (EVar "recordEffect") (EVar "cur")) (EVar "eff")))))
(DTypeSig false "recordEffectSites" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "EffRow") (TyCon "Unit"))))
(DFunDef false "recordEffectSites" ((PVar "mctx") (PCon "EffRow" (PList) PWild)) (ELit LUnit))
(DFunDef false "recordEffectSites" ((PVar "mctx") (PVar "eff")) (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "atom")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "effectSiteKey") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (EApp (EVar "atomKey") (EVar "atom")))) (DoLet false false (PVar "sites") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "effectSitesRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "effectSitesRef")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "::" (ETuple (EApp (EVar "atomAuth") (EVar "atom")) (EFieldAccess (EVar "mctx") "mcLoc")) (EVar "sites"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "effectSitesRef") "value"))))))) (ELit LUnit)) (EApp (EVar "fst") (EApp (EVar "rowFlat") (EVar "eff")))))
(DTypeSig true "effectSiteKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "effectSiteKey" ((PVar "fn") (PVar "label")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "fn"))) (ELit (LString "\t"))) (EApp (EVar "display") (EVar "label"))) (ELit (LString ""))))
(DTypeSig false "obligationSiteHere" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyCon "ObligationSite"))))
(DFunDef false "obligationSiteHere" ((PVar "mctx") (PVar "covering")) (ERecordCreate "ObligationSite" ((fa "osLoc" (EFieldAccess (EVar "mctx") "mcLoc")) (fa "osFn" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (fa "osCovering" (EVar "covering")))))
(DTypeSig false "deferEffectRelation" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Unit"))))))
(DFunDef false "deferEffectRelation" ((PVar "mctx") (PVar "exact") (PVar "lower") (PVar "upper")) (EApp (EApp (EApp (EApp (EApp (EVar "EffectSolver.recordRelation") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "effectSummaries")) (EVar "exact")) (EApp (EApp (EVar "obligationSiteHere") (EVar "mctx")) (EVar "False"))) (EVar "lower")) (EVar "upper")))
(DTypeSig false "unifyIndex" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Unit")))))
(DFunDef false "unifyIndex" ((PVar "mctx") (PVar "qa") (PVar "qb")) (EMatch (ETuple (EApp (EVar "authNorm") (EVar "qa")) (EApp (EVar "authNorm") (EVar "qb"))) (arm (PTuple (PCon "AVar" (PVar "a")) (PVar "b")) ((GBool (EApp (EApp (EApp (EVar "flexibleIndex") (EVar "mctx")) (EVar "a")) (EVar "b")))) (EApp (EApp (EApp (EVar "substituteIndex") (EVar "mctx")) (EVar "a")) (EVar "b"))) (arm (PTuple (PVar "a") (PCon "AVar" (PVar "b"))) ((GBool (EApp (EApp (EApp (EVar "flexibleIndex") (EVar "mctx")) (EVar "b")) (EVar "a")))) (EApp (EApp (EApp (EVar "substituteIndex") (EVar "mctx")) (EVar "b")) (EVar "a"))) (arm (PTuple (PVar "a") (PVar "b")) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "wantAuthorityWith") (EVar "mctx")) (EVar "True")) (EVar "a")) (EVar "b"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "wantAuthorityWith") (EVar "mctx")) (EVar "True")) (EVar "b")) (EVar "a")))))))
(DTypeSig false "substituteIndex" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyFun (TyCon "Authority") (TyCon "Unit")))))
(DFunDef false "substituteIndex" ((PVar "mctx") (PVar "cell") (PVar "term")) (EBlock (DoExpr (EIf (EBinOp "&&" (EApp (EVar "authvarIsPattern") (EVar "cell")) (EApp (EVar "not") (EApp (EVar "authIsPattern") (EVar "term")))) (EBlock (DoLet false false (PVar "fixed") (EApp (EApp (EVar "indexOutsidePatterns") (EVar "mctx")) (EVar "term"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "fixed")) (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "v")) (EIf (EApp (EVar "authvarIsPattern") (EVar "v")) (ELit LUnit) (EApp (EVar "markAuthvarPattern") (EVar "v"))))) (ELit LUnit)) (EApp (EVar "authVars") (EVar "term"))) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-AUTHORITY-PATTERN"))) (EApp (EVar "patternIndexMsg") (EVar "term")))))) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "substituteIndexLinked") (EVar "mctx")) (EVar "cell")) (EVar "term")))))
(DTypeSig false "indexOutsidePatterns" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Authority") (TyApp (TyCon "List") (TyCon "Authority")))))
(DFunDef false "indexOutsidePatterns" ((PVar "mctx") (PVar "term")) (EBlock (DoLet false false (PVar "members") (EMatch (EApp (EVar "authNorm") (EVar "term")) (arm (PCon "AJoin" (PVar "ms")) () (EVar "ms")) (arm (PVar "other") () (EListLit (EVar "other"))))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "m")) (EMatch (EVar "m") (arm (PCon "AVar" (PVar "c")) () (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "authvarIsPattern") (EVar "c"))) (EApp (EApp (EVar "IdMap.has") (EApp (EVar "authvarId") (EVar "c"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "rigidAuthvarsRef") "value")))) (arm (PVar "other") () (EApp (EVar "not") (EApp (EVar "authIsPattern") (EVar "other"))))))) (EVar "members")))))
(DTypeSig false "substituteIndexLinked" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyFun (TyCon "Authority") (TyCon "Unit")))))
(DFunDef false "substituteIndexLinked" ((PVar "mctx") (PVar "cell") (PVar "term")) (EBlock (DoExpr (EApp (EApp (EVar "lowerAuthLevels") (EApp (EVar "authvarLevel") (EVar "cell"))) (EVar "term"))) (DoExpr (EIf (EApp (EVar "authHasVars") (EVar "term")) (ELit LUnit) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "indexSubstitutedRef")) (EApp (EApp (EApp (EVar "IdMap.set") (EApp (EVar "authvarId") (EVar "cell"))) (ELit LUnit)) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "indexSubstitutedRef") "value"))))) (DoExpr (EApp (EApp (EVar "linkAuthvar") (EVar "cell")) (EVar "term")))))
(DTypeSig false "flexibleIndex" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyFun (TyCon "Authority") (TyCon "Bool")))))
(DFunDef false "flexibleIndex" ((PVar "mctx") (PVar "cell") (PVar "other")) (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "IdMap.has") (EApp (EVar "authvarId") (EVar "cell"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "rigidAuthvarsRef") "value"))) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "c")) (EBinOp "==" (EApp (EVar "authvarId") (EVar "c")) (EApp (EVar "authvarId") (EVar "cell"))))) (EApp (EVar "authVars") (EVar "other"))))))
(DTypeSig false "unifyRow" (TyFun (TyCon "DynCtx") (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Unit")))))
(DFunDef false "unifyRow" ((PVar "dyn") (PVar "r1") (PVar "r2")) (EApp (EApp (EApp (EVar "unifyRowN") (EVar "dyn")) (EApp (EVar "effrowNorm") (EVar "r1"))) (EApp (EVar "effrowNorm") (EVar "r2"))))
(DTypeSig false "unifyRowN" (TyFun (TyCon "DynCtx") (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Unit")))))
(DFunDef false "unifyRowN" ((PVar "dyn") (PVar "r1") (PVar "r2")) (EIf (EBinOp "||" (EApp (EVar "rowHasSummary") (EVar "r1")) (EApp (EVar "rowHasSummary") (EVar "r2"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "deferEffectRelation") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "False")) (EVar "r1")) (EVar "r2"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "deferEffectRelation") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "False")) (EVar "r2")) (EVar "r1")))) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "rowTailIsJoin") (EVar "r1")) (EApp (EVar "rowTailIsJoin") (EVar "r2"))) (EApp (EApp (EVar "rowHasRigid") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "r1"))) (EApp (EApp (EVar "rowHasRigid") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "r2"))) (EApp (EApp (EApp (EApp (EVar "unifyJoinRows") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "False")) (EVar "r1")) (EVar "r2")) (EApp (EApp (EApp (EVar "unifyRowPlain") (EVar "dyn")) (EVar "r1")) (EVar "r2")))))
(DTypeSig false "rowHasRigid" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "EffRow") (TyCon "Bool"))))
(DFunDef false "rowHasRigid" ((PVar "mctx") (PVar "row")) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "rigidEffvarsRef") "value") (arm (PCon "Tip") () (EVar "False")) (arm PWild () (EApp (EApp (EVar "anyList") (EApp (EVar "isRigidCell") (EVar "mctx"))) (EApp (EVar "snd") (EApp (EVar "rowFlat") (EVar "row")))))))
(DTypeSig false "rowTailIsJoin" (TyFun (TyCon "EffRow") (TyCon "Bool")))
(DFunDef false "rowTailIsJoin" ((PCon "EffRow" PWild (PCon "Some" (PVar "c")))) (EApp (EVar "isJoinCell") (EVar "c")))
(DFunDef false "rowTailIsJoin" ((PCon "EffRow" PWild (PCon "None"))) (EVar "False"))
(DTypeSig false "unifyJoinRows" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Unit"))))))
(DFunDef false "unifyJoinRows" ((PVar "mctx") (PVar "isIndex") (PVar "r1") (PVar "r2")) (EBlock (DoLet false false (PVar "fa") (EApp (EVar "rowFlat") (EVar "r1"))) (DoLet false false (PVar "fb") (EApp (EVar "rowFlat") (EVar "r2"))) (DoLet false false (PVar "ma") (EApp (EVar "snd") (EVar "fa"))) (DoLet false false (PVar "mb") (EApp (EVar "snd") (EVar "fb"))) (DoLet false false (PVar "idsA") (EApp (EVar "cellIdSet") (EVar "ma"))) (DoLet false false (PVar "idsB") (EApp (EVar "cellIdSet") (EVar "mb"))) (DoLet false false (PVar "common") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EApp (EVar "IdMap.has") (EApp (EVar "effvarId") (EVar "c"))) (EVar "idsB")))) (EVar "ma"))) (DoLet false false (PVar "cflex") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "not") (EApp (EApp (EVar "isRigidCell") (EVar "mctx")) (EVar "c"))))) (EVar "common"))) (DoLet false false (PVar "onlyA") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "not") (EApp (EApp (EVar "IdMap.has") (EApp (EVar "effvarId") (EVar "c"))) (EVar "idsB"))))) (EVar "ma"))) (DoLet false false (PVar "onlyB") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "not") (EApp (EApp (EVar "IdMap.has") (EApp (EVar "effvarId") (EVar "c"))) (EVar "idsA"))))) (EVar "mb"))) (DoLet false false (PVar "rigidA") (EApp (EApp (EVar "filterList") (EApp (EVar "isRigidCell") (EVar "mctx"))) (EVar "onlyA"))) (DoLet false false (PVar "flexA") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "not") (EApp (EApp (EVar "isRigidCell") (EVar "mctx")) (EVar "c"))))) (EVar "onlyA"))) (DoLet false false (PVar "rigidB") (EApp (EApp (EVar "filterList") (EApp (EVar "isRigidCell") (EVar "mctx"))) (EVar "onlyB"))) (DoLet false false (PVar "flexB") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "not") (EApp (EApp (EVar "isRigidCell") (EVar "mctx")) (EVar "c"))))) (EVar "onlyB"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EVar "isIndex") (EApp (EVar "isEmptyL") (EVar "flexA"))) (EApp (EVar "isEmptyL") (EVar "flexB"))) (EApp (EVar "isEmptyL") (EVar "cflex"))) (EApp (EApp (EApp (EVar "unifyIndexAtomAuthorities") (EVar "mctx")) (EApp (EVar "fst") (EVar "fa"))) (EApp (EVar "fst") (EVar "fb"))) (ELit LUnit))) (DoLet false false (PVar "dA") (EApp (EApp (EVar "atomsDiff") (EApp (EVar "fst") (EVar "fa"))) (EApp (EVar "fst") (EVar "fb")))) (DoLet false false (PVar "dB") (EApp (EApp (EVar "atomsDiff") (EApp (EVar "fst") (EVar "fb"))) (EApp (EVar "fst") (EVar "fa")))) (DoLet false false (PVar "bindC") (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "cflex")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "rigidA")) (EApp (EVar "isEmptyL") (EVar "flexB"))) (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "rigidB")) (EApp (EVar "isEmptyL") (EVar "flexA")))) (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "dA")) (EApp (EVar "isEmptyL") (EVar "flexB")))) (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "dB")) (EApp (EVar "isEmptyL") (EVar "flexA")))))) (DoLet false false (PVar "useV3") (EBinOp "||" (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "flexA")) (EApp (EVar "isNonEmptyL") (EVar "flexB"))) (EVar "bindC"))) (DoLet false false (PVar "v3s") (EIf (EVar "useV3") (EListLit (EApp (EApp (EVar "freshEffvarAt") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EVar "minLevelOf") (EBinOp "++" (EBinOp "++" (EVar "flexA") (EVar "flexB")) (EVar "cflex"))))) (EListLit))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "rigidA")) (EApp (EVar "isEmptyL") (EVar "flexB"))) (EApp (EVar "not") (EVar "bindC"))) (EApp (EApp (EApp (EApp (EVar "joinMismatch") (EVar "mctx")) (EVar "isIndex")) (EVar "fa")) (EVar "fb")) (ELit LUnit))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "rigidB")) (EApp (EVar "isEmptyL") (EVar "flexA"))) (EApp (EVar "not") (EVar "bindC"))) (EApp (EApp (EApp (EApp (EVar "joinMismatch") (EVar "mctx")) (EVar "isIndex")) (EVar "fa")) (EVar "fb")) (ELit LUnit))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "dA")) (EApp (EVar "isEmptyL") (EVar "flexB"))) (EApp (EVar "not") (EVar "bindC"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "joinSideCheck") (EVar "mctx")) (EVar "isIndex")) (EVar "dA")) (EVar "dB")) (EApp (EVar "fst") (EVar "fa"))) (EApp (EVar "fst") (EVar "fb"))) (ELit LUnit))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "dB")) (EApp (EVar "isEmptyL") (EVar "flexA"))) (EApp (EVar "not") (EVar "bindC"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "joinSideCheck") (EVar "mctx")) (EVar "isIndex")) (EVar "dB")) (EVar "dA")) (EApp (EVar "fst") (EVar "fb"))) (EApp (EVar "fst") (EVar "fa"))) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "bindEach") (EVar "flexA")) (EApp (EApp (EApp (EVar "rowOfMembers") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "dB")) (EBinOp "++" (EVar "v3s") (EVar "rigidB"))))) (DoExpr (EApp (EApp (EVar "bindEach") (EVar "flexB")) (EApp (EApp (EApp (EVar "rowOfMembers") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "dA")) (EBinOp "++" (EVar "v3s") (EVar "rigidA"))))) (DoExpr (EIf (EVar "bindC") (EApp (EApp (EVar "bindEach") (EVar "cflex")) (EApp (EApp (EApp (EVar "rowOfMembers") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "atomsUnion") (EVar "dA")) (EVar "dB"))) (EBinOp "++" (EBinOp "++" (EVar "v3s") (EVar "rigidA")) (EVar "rigidB")))) (ELit LUnit))) (DoExpr (EMatch (EVar "v3s") (arm (PCons (PVar "v3") PWild) () (EApp (EApp (EApp (EVar "recordAbsorptions") (EVar "mctx")) (EBinOp "++" (EVar "dA") (EVar "dB"))) (EVar "v3"))) (arm (PList) () (ELit LUnit))))))
(DTypeSig false "bindEach" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyCon "EffRow") (TyCon "Unit"))))
(DFunDef false "bindEach" ((PList) PWild) (ELit LUnit))
(DFunDef false "bindEach" ((PCons (PVar "c") (PVar "cs")) (PVar "row")) (EBlock (DoExpr (EApp (EApp (EVar "linkRow") (EVar "c")) (EVar "row"))) (DoExpr (EApp (EApp (EVar "bindEach") (EVar "cs")) (EVar "row")))))
(DTypeSig false "joinSideCheck" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "Unit"))))))))
(DFunDef false "joinSideCheck" ((PVar "mctx") (PCon "True") (PVar "dOpen") PWild (PVar "lOpen") (PVar "lClosed")) (EApp (EApp (EApp (EApp (EApp (EVar "indexRowEqCheck") (EVar "mctx")) (EApp (EApp (EApp (EVar "indexAtomsCovered") (EVar "mctx")) (EVar "dOpen")) (EVar "lClosed"))) (EListLit)) (EVar "lOpen")) (EVar "lClosed")))
(DFunDef false "joinSideCheck" ((PVar "mctx") (PCon "False") PWild PWild (PVar "lOpen") (PVar "lClosed")) (EApp (EApp (EApp (EVar "effectLeakCheck") (EVar "mctx")) (EApp (EApp (EApp (EVar "atomsEscape") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "lOpen")) (EVar "lClosed"))) (EVar "lClosed")))
(DTypeSig false "joinMismatch" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyCon "Unit"))))))
(DFunDef false "joinMismatch" ((PVar "mctx") (PVar "isIndex") (PVar "fa") (PVar "fb")) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (EIf (EVar "isIndex") (ELit (LString "T-EFFECT-INDEX-MISMATCH")) (ELit (LString "T-EFFECT-LEAK")))) (EApp (EApp (EVar "joinMismatchMsg") (EApp (EVar "renderFlatRow") (EVar "fa"))) (EApp (EVar "renderFlatRow") (EVar "fb")))))
(DTypeSig false "unifyRowPlain" (TyFun (TyCon "DynCtx") (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Unit")))))
(DFunDef false "unifyRowPlain" ((PVar "dyn") (PCon "EffRow" (PVar "l1") (PCon "Some" (PVar "v1"))) (PCon "EffRow" (PVar "l2") (PCon "Some" (PVar "v2")))) (EIf (EBinOp "==" (EApp (EVar "effvarId") (EVar "v1")) (EApp (EVar "effvarId") (EVar "v2"))) (EBlock (DoLet false false (PVar "missing") (EApp (EApp (EVar "atomsUnion") (EApp (EApp (EVar "atomsDiff") (EVar "l1")) (EVar "l2"))) (EApp (EApp (EVar "atomsDiff") (EVar "l2")) (EVar "l1")))) (DoExpr (EMatch (EVar "missing") (arm (PList) () (ELit LUnit)) (arm PWild () (EIf (EApp (EApp (EVar "isRigidCell") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "v1")) (EApp (EApp (EApp (EVar "pushTypeError") (EFieldAccess (EVar "dyn") "dcModule")) (ELit (LString "T-EFFECT-LAUNDER"))) (EBinOp "++" (EBinOp "++" (ELit (LString "a caller-chosen effect row cannot be required to contain <")) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "missing")))) (ELit (LString ">; declare those effects as labels beside the row variable")))) (EBlock (DoLet false false (PVar "next") (EApp (EApp (EVar "freshEffvarAt") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph")) (EApp (EVar "effvarLevel") (EVar "v1")))) (DoExpr (EApp (EApp (EVar "linkRow") (EVar "v1")) (EApp (EApp (EVar "EffRow") (EVar "missing")) (EApp (EVar "Some") (EVar "next"))))) (DoExpr (EApp (EApp (EApp (EVar "recordAbsorptions") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "missing")) (EVar "next"))))))))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "v3") (EApp (EApp (EVar "freshEffvarAt") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph")) (EApp (EApp (EVar "minI") (EApp (EVar "effvarLevel") (EVar "v1"))) (EApp (EVar "effvarLevel") (EVar "v2"))))) (DoLet false false (PVar "d21") (EApp (EApp (EVar "atomsDiff") (EVar "l2")) (EVar "l1"))) (DoLet false false (PVar "d12") (EApp (EApp (EVar "atomsDiff") (EVar "l1")) (EVar "l2"))) (DoExpr (EIf (EBinOp "||" (EApp (EApp (EVar "isRigidCell") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "v1")) (EApp (EApp (EVar "isRigidCell") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "v2"))) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "rigidEffvarsRef")) (EApp (EApp (EApp (EVar "IdMap.set") (EApp (EVar "effvarId") (EVar "v3"))) (ELit LUnit)) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "rigidEffvarsRef") "value"))) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "linkRow") (EVar "v1")) (EApp (EApp (EVar "EffRow") (EVar "d21")) (EApp (EVar "Some") (EVar "v3"))))) (DoExpr (EApp (EApp (EVar "linkRow") (EVar "v2")) (EApp (EApp (EVar "EffRow") (EVar "d12")) (EApp (EVar "Some") (EVar "v3"))))) (DoExpr (EApp (EApp (EApp (EVar "recordAbsorptions") (EFieldAccess (EVar "dyn") "dcModule")) (EBinOp "++" (EVar "d21") (EVar "d12"))) (EVar "v3")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "unifyRowPlain" ((PVar "dyn") (PCon "EffRow" (PVar "l1") (PCon "Some" (PVar "v1"))) (PCon "EffRow" (PVar "l2") (PCon "None"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "effectLeakCheck") (EFieldAccess (EVar "dyn") "dcModule")) (EApp (EApp (EApp (EVar "atomsEscape") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph")) (EVar "l1")) (EVar "l2"))) (EVar "l2"))) (DoExpr (EApp (EApp (EVar "linkRow") (EVar "v1")) (EApp (EApp (EVar "EffRow") (EApp (EApp (EVar "atomsDiff") (EVar "l2")) (EVar "l1"))) (EVar "None"))))))
(DFunDef false "unifyRowPlain" ((PVar "dyn") (PCon "EffRow" (PVar "l1") (PCon "None")) (PCon "EffRow" (PVar "l2") (PCon "Some" (PVar "v2")))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "effectLeakCheck") (EFieldAccess (EVar "dyn") "dcModule")) (EApp (EApp (EApp (EVar "atomsEscape") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph")) (EVar "l2")) (EVar "l1"))) (EVar "l1"))) (DoExpr (EApp (EApp (EVar "linkRow") (EVar "v2")) (EApp (EApp (EVar "EffRow") (EApp (EApp (EVar "atomsDiff") (EVar "l1")) (EVar "l2"))) (EVar "None"))))))
(DFunDef false "unifyRowPlain" ((PVar "dyn") (PCon "EffRow" (PVar "l1") (PCon "None")) (PCon "EffRow" (PVar "l2") (PCon "None"))) (EApp (EApp (EApp (EVar "closedRowEqCheck") (EVar "dyn")) (EVar "l1")) (EVar "l2")))
(DTypeSig false "unifyIndexRow" (TyFun (TyCon "DynCtx") (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Unit")))))
(DFunDef false "unifyIndexRow" ((PVar "dyn") (PVar "r1") (PVar "r2")) (EApp (EApp (EApp (EVar "unifyIndexRowN") (EVar "dyn")) (EApp (EVar "effrowNorm") (EVar "r1"))) (EApp (EVar "effrowNorm") (EVar "r2"))))
(DTypeSig false "unifyIndexAtomAuthorities" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "Unit")))))
(DFunDef false "unifyIndexAtomAuthorities" ((PVar "mctx") (PVar "a1") (PVar "a2")) (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "x")) (EMatch (EApp (EApp (EVar "findAtom") (EApp (EVar "atomKey") (EVar "x"))) (EVar "a2")) (arm (PCon "Some" (PVar "y")) () (EApp (EApp (EApp (EVar "unifyIndex") (EVar "mctx")) (EApp (EVar "atomAuth") (EVar "x"))) (EApp (EVar "atomAuth") (EVar "y")))) (arm (PCon "None") () (ELit LUnit))))) (ELit LUnit)) (EVar "a1")))
(DTypeSig false "unifyIndexRowN" (TyFun (TyCon "DynCtx") (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Unit")))))
(DFunDef false "unifyIndexRowN" ((PVar "dyn") (PVar "r1") (PVar "r2")) (EIf (EBinOp "||" (EApp (EVar "rowHasSummary") (EVar "r1")) (EApp (EVar "rowHasSummary") (EVar "r2"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "deferEffectRelation") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "True")) (EVar "r1")) (EVar "r2"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "deferEffectRelation") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "True")) (EVar "r2")) (EVar "r1")))) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "rowTailIsJoin") (EVar "r1")) (EApp (EVar "rowTailIsJoin") (EVar "r2"))) (EApp (EApp (EVar "rowHasRigid") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "r1"))) (EApp (EApp (EVar "rowHasRigid") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "r2"))) (EApp (EApp (EApp (EApp (EVar "unifyJoinRows") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "True")) (EVar "r1")) (EVar "r2")) (EApp (EApp (EApp (EVar "unifyIndexRowPlain") (EVar "dyn")) (EVar "r1")) (EVar "r2")))))
(DTypeSig false "unifyIndexRowPlain" (TyFun (TyCon "DynCtx") (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Unit")))))
(DFunDef false "unifyIndexRowPlain" ((PVar "dyn") (PCon "EffRow" (PVar "l1") (PCon "None")) (PCon "EffRow" (PVar "l2") (PCon "None"))) (EApp (EApp (EApp (EVar "indexRowEquate") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "l1")) (EVar "l2")))
(DFunDef false "unifyIndexRowPlain" ((PVar "dyn") (PCon "EffRow" (PVar "l1") (PCon "Some" (PVar "v1"))) (PCon "EffRow" (PVar "l2") (PCon "Some" (PVar "v2")))) (EIf (EBinOp "==" (EApp (EVar "effvarId") (EVar "v1")) (EApp (EVar "effvarId") (EVar "v2"))) (EApp (EApp (EApp (EVar "indexRowEquate") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "l1")) (EVar "l2")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "unifyIndexRowPlain" ((PVar "dyn") (PCon "EffRow" (PVar "l1") (PCon "Some" (PVar "v1"))) (PCon "EffRow" (PVar "l2") (PCon "None"))) (EApp (EApp (EApp (EApp (EVar "indexOpenClosed") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "l1")) (EVar "v1")) (EVar "l2")))
(DFunDef false "unifyIndexRowPlain" ((PVar "dyn") (PCon "EffRow" (PVar "l1") (PCon "None")) (PCon "EffRow" (PVar "l2") (PCon "Some" (PVar "v2")))) (EApp (EApp (EApp (EApp (EVar "indexOpenClosed") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "l2")) (EVar "v2")) (EVar "l1")))
(DFunDef false "unifyIndexRowPlain" ((PVar "dyn") (PVar "r1") (PVar "r2")) (EApp (EApp (EApp (EVar "unifyRowPlain") (EVar "dyn")) (EVar "r1")) (EVar "r2")))
(DTypeSig false "indexRowEquate" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "Unit")))))
(DFunDef false "indexRowEquate" ((PVar "mctx") (PVar "l1") (PVar "l2")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "unifyIndexAtomAuthorities") (EVar "mctx")) (EVar "l1")) (EVar "l2"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "indexRowEqCheck") (EVar "mctx")) (EApp (EApp (EVar "labelsMissing") (EVar "l1")) (EVar "l2"))) (EApp (EApp (EVar "labelsMissing") (EVar "l2")) (EVar "l1"))) (EVar "l1")) (EVar "l2")))))
(DTypeSig false "indexOpenClosed" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "Unit"))))))
(DFunDef false "indexOpenClosed" ((PVar "mctx") (PVar "lOpen") (PVar "v") (PVar "lClosed")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "effectLeakCheck") (EVar "mctx")) (EApp (EApp (EApp (EVar "indexAtomsCovered") (EVar "mctx")) (EApp (EApp (EApp (EVar "atomsEscape") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "lOpen")) (EVar "lClosed"))) (EVar "lClosed"))) (EVar "lClosed"))) (DoExpr (EApp (EApp (EVar "linkRow") (EVar "v")) (EApp (EApp (EVar "EffRow") (EApp (EApp (EVar "atomsDiff") (EVar "lClosed")) (EVar "lOpen"))) (EVar "None"))))))
(DTypeSig false "indexAtomsCovered" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))))
(DFunDef false "indexAtomsCovered" ((PVar "mctx") (PList) PWild) (EListLit))
(DFunDef false "indexAtomsCovered" ((PVar "mctx") (PCons (PVar "x") (PVar "rest")) (PVar "bound")) (EMatch (EApp (EApp (EVar "findAtom") (EApp (EVar "atomKey") (EVar "x"))) (EVar "bound")) (arm (PCon "Some" (PVar "y")) () (EBlock (DoExpr (EApp (EApp (EApp (EVar "wantIndexCovered") (EVar "mctx")) (EApp (EVar "atomAuth") (EVar "x"))) (EApp (EVar "atomAuth") (EVar "y")))) (DoExpr (EApp (EApp (EApp (EVar "indexAtomsCovered") (EVar "mctx")) (EVar "rest")) (EVar "bound"))))) (arm (PCon "None") () (EBinOp "::" (EVar "x") (EApp (EApp (EApp (EVar "indexAtomsCovered") (EVar "mctx")) (EVar "rest")) (EVar "bound"))))))
(DTypeSig false "labelsMissing" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "labelsMissing" ((PVar "l1") (PVar "l2")) (EApp (EApp (EVar "filterList") (ELam ((PVar "x")) (EMatch (EApp (EApp (EVar "findAtom") (EApp (EVar "atomKey") (EVar "x"))) (EVar "l2")) (arm (PCon "Some" PWild) () (EVar "False")) (arm (PCon "None") () (EVar "True"))))) (EVar "l1")))
(DTypeSig false "indexRowEqCheck" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "Unit")))))))
(DFunDef false "indexRowEqCheck" ((PVar "mctx") (PList) (PList) PWild PWild) (ELit LUnit))
(DFunDef false "indexRowEqCheck" ((PVar "mctx") PWild PWild (PVar "l1") (PVar "l2")) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-EFFECT-INDEX-MISMATCH"))) (EApp (EApp (EVar "indexRowMismatchMsg") (EVar "l1")) (EVar "l2"))))
(DTypeSig true "effectLeakCheck" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "Unit")))))
(DFunDef false "effectLeakCheck" ((PVar "mctx") (PList) (PVar "bound")) (ELit LUnit))
(DFunDef false "effectLeakCheck" ((PVar "mctx") (PVar "escaping") (PVar "bound")) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-EFFECT-LEAK"))) (EApp (EApp (EApp (EVar "effectLeakMsg") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "bound")) (EVar "escaping"))))
(DTypeSig false "closedRowEqCheck" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "Unit")))))
(DFunDef false "closedRowEqCheck" ((PVar "dyn") (PVar "l1") (PVar "l2")) (EMatch (ETuple (EApp (EApp (EApp (EVar "atomsEscape") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph")) (EVar "l1")) (EVar "l2")) (EApp (EApp (EApp (EVar "atomsEscape") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph")) (EVar "l2")) (EVar "l1"))) (arm (PTuple (PList) (PList)) () (ELit LUnit)) (arm PWild () (EIf (EFieldAccess (EVar "dyn") "dcNonCovariant") (EApp (EApp (EApp (EVar "pushTypeError") (EFieldAccess (EVar "dyn") "dcModule")) (ELit (LString "T-EFFECT-PARAM-VARIANCE"))) (EApp (EApp (EVar "paramVarianceMismatchMsg") (EVar "l1")) (EVar "l2"))) (EApp (EApp (EApp (EVar "pushTypeError") (EFieldAccess (EVar "dyn") "dcModule")) (ELit (LString "T-EFFECT-LEAK"))) (EApp (EApp (EVar "closedRowMismatchMsg") (EVar "l1")) (EVar "l2")))))))
(DTypeSig false "effectLeakMsg" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))))
(DFunDef false "effectLeakMsg" ((PVar "gctx") (PVar "bound") (PVar "extras")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "performs <")) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "extras")))) (ELit (LString "> where only <"))) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "bound")))) (ELit (LString "> is allowed"))) (EApp (EVar "display") (EApp (EApp (EVar "ioJoinClause") (EVar "gctx")) (EBinOp "++" (EVar "bound") (EVar "extras"))))) (ELit (LString ""))))
(DTypeSig false "ioJoinClause" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String"))))
(DFunDef false "ioJoinClause" ((PVar "gctx") (PVar "atoms")) (EBlock (DoLet false false (PVar "join") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "config") "value") "tcIoJoin")) (DoLet false false (PVar "full") (EApp (EApp (EVar "map") (EApp (EVar "atomOfLabel") (EFieldAccess (EFieldAccess (EVar "gctx") "effectDomains") "value"))) (EVar "hostLabels"))) (DoExpr (EIf (EBinOp "&&" (EApp (EVar "isSome") (EApp (EApp (EVar "findAtom") (EApp (EVar "labelKey") (EVar "ioLabel"))) (EVar "atoms"))) (EApp (EVar "isNonEmptyL") (EApp (EApp (EVar "atomsDiff") (EVar "full")) (EVar "join")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "; `IO` on `")) (EApp (EVar "display") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "config") "value") "tcIoJoinProfile"))) (ELit (LString "` is <"))) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "join")))) (ELit (LString ">"))) (ELit (LString ""))))))
(DTypeSig true "lowerRowLevels" (TyFun (TyCon "Int") (TyFun (TyCon "EffRow") (TyCon "Unit"))))
(DFunDef false "lowerRowLevels" ((PVar "level") (PVar "r")) (EBlock (DoLet false false (PTuple (PVar "atoms") (PVar "members")) (EApp (EVar "rowFlat") (EVar "r"))) (DoExpr (EApp (EApp (EVar "lowerMembers") (EVar "level")) (EVar "members"))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "a")) (EApp (EApp (EVar "lowerAuthLevels") (EVar "level")) (EApp (EVar "atomAuth") (EVar "a"))))) (ELit LUnit)) (EVar "atoms")))))
(DTypeSig false "lowerMembers" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyCon "Unit"))))
(DFunDef false "lowerMembers" (PWild (PList)) (ELit LUnit))
(DFunDef false "lowerMembers" ((PVar "level") (PCons (PVar "m") (PVar "ms"))) (EBlock (DoExpr (EMatch (EUnOp "!" (EVar "m")) (arm (PCon "EUnbound" (PVar "id") (PVar "lvl")) () (EIf (EBinOp ">" (EVar "lvl") (EVar "level")) (EApp (EApp (EVar "setRef") (EVar "m")) (EApp (EApp (EVar "EUnbound") (EVar "id")) (EVar "level"))) (ELit LUnit))) (arm PWild () (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "lowerMembers") (EVar "level")) (EVar "ms")))))
(DTypeSig false "freeEffvars" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "freeEffvars" ((PVar "mctx") (PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TVar" (PVar "cell")) () (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Link" (PVar "t2")) () (EApp (EApp (EVar "freeEffvars") (EVar "mctx")) (EVar "t2"))) (arm (PCon "Unbound" PWild PWild) () (EListLit)))) (arm (PCon "TCon" PWild PWild) () (EListLit)) (arm (PCon "TRigid" PWild) () (EListLit)) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EBinOp "++" (EApp (EApp (EVar "freeEffvars") (EVar "mctx")) (EVar "a")) (EApp (EApp (EVar "freeEffvars") (EVar "mctx")) (EVar "b")))) (arm (PCon "TFun" (PVar "a") (PVar "r") (PVar "b")) () (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "freeEffvars") (EVar "mctx")) (EVar "a")) (EApp (EApp (EVar "rowFreeEffvars") (EVar "mctx")) (EVar "r"))) (EApp (EApp (EVar "freeEffvars") (EVar "mctx")) (EVar "b")))) (arm (PCon "TEff" (PVar "r")) () (EApp (EApp (EVar "rowFreeEffvars") (EVar "mctx")) (EVar "r"))) (arm (PCon "TQual" (PVar "a") PWild) () (EApp (EApp (EVar "freeEffvars") (EVar "mctx")) (EVar "a"))) (arm (PCon "TAuth" PWild) () (EListLit))))
(DTypeSig false "rowFreeEffvars" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "EffRow") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "rowFreeEffvars" ((PVar "mctx") (PVar "r")) (EApp (EApp (EVar "flatMap") (EApp (EVar "generalizableEffvar") (EVar "mctx"))) (EApp (EVar "snd") (EApp (EVar "rowFlat") (EVar "r")))))
(DTypeSig false "generalizableEffvar" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "generalizableEffvar" ((PVar "mctx") (PVar "v")) (EMatch (EUnOp "!" (EVar "v")) (arm (PCon "EUnbound" (PVar "id") (PVar "lvl")) () (EIf (EBinOp ">" (EVar "lvl") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (EListLit (EVar "id")) (EListLit))) (arm (PCon "ELink" PWild PWild) () (EListLit)) (arm (PCon "EJoin" PWild PWild PWild) () (EListLit)) (arm (PCon "ESummary" PWild PWild PWild) () (EListLit))))
(DTypeSig true "predicateSlotCSlots" (TyFun (TyApp (TyCon "List") (TyCon "PredicateSlot")) (TyApp (TyCon "List") (TyCon "CSlot"))))
(DFunDef false "predicateSlotCSlots" ((PList)) (EListLit))
(DFunDef false "predicateSlotCSlots" ((PCons (PVar "s") (PVar "rest"))) (EMatch (EFieldAccess (EVar "s") "psBoundIds") (arm (PCons (PVar "id") PWild) () (EBinOp "::" (ERecordCreate "CSlot" ((fa "csIface" (EFieldAccess (EVar "s") "psIface")) (fa "csId" (EVar "id")))) (EApp (EVar "predicateSlotCSlots") (EVar "rest")))) (arm PWild () (EApp (EVar "predicateSlotCSlots") (EVar "rest")))))
(DTypeSig true "predicateSlotArgs" (TyFun (TyApp (TyCon "List") (TyCon "PredicateSlot")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "predicateSlotArgs" ((PList)) (EListLit))
(DFunDef false "predicateSlotArgs" ((PCons (PVar "slot") (PVar "rest"))) (EMatch (EFieldAccess (EVar "slot") "psArgs") (arm (PCon "PSArgsUnknown") () (EListLit)) (arm (PCon "PSArgsKnown" (PVar "args")) () (EBinOp "::" (EVar "args") (EApp (EVar "predicateSlotArgs") (EVar "rest"))))))
(DTypeSig true "recordObl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Predicate") (TyFun (TyCon "Int") (TyFun (TyCon "Provenance") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit")))))))
(DFunDef false "recordObl" ((PVar "mctx") (PVar "p") (PVar "originId") (PVar "prov") (PVar "loc")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordOblAt") (EVar "mctx")) (EVar "p")) (EVar "originId")) (EVar "prov")) (EVar "loc")) (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))))
(DTypeSig true "recordOblAt" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Predicate") (TyFun (TyCon "Int") (TyFun (TyCon "Provenance") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ScopeId") (TyCon "Unit"))))))))
(DFunDef false "recordOblAt" ((PVar "mctx") (PVar "p") (PVar "originId") (PVar "prov") (PVar "loc") (PVar "scope")) (EApp (EApp (EVar "wPush") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "obls")) (ERecordCreate "UObligation" ((fa "pred" (EVar "p")) (fa "originId" (EVar "originId")) (fa "prov" (EVar "prov")) (fa "loc" (EVar "loc")) (fa "uoScope" (EVar "scope")) (fa "oblProj" (EVar "OpProjected"))))))
(DTypeSig false "recordAbsorptions" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyCon "Unit")))))
(DFunDef false "recordAbsorptions" ((PVar "mctx") (PList) PWild) (ELit LUnit))
(DFunDef false "recordAbsorptions" ((PVar "mctx") (PCons (PVar "a") (PVar "rest")) (PVar "cell")) (EBlock (DoExpr (EApp (EApp (EVar "wPush") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "absorptions")) (ERecordCreate "AbsorptionEvent" ((fa "atom" (EVar "a")) (fa "cell" (EVar "cell")) (fa "loc" (EFieldAccess (EVar "mctx") "mcLoc")))))) (DoExpr (EApp (EApp (EApp (EVar "recordAbsorptions") (EVar "mctx")) (EVar "rest")) (EVar "cell")))))
(DTypeSig true "captureScope" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "ScopeId"))))
(DFunDef false "captureScope" ((PVar "mctx") PWild) (EApp (EVar "Scopes.captureScopeCursor") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentScope") "value")))
(DTypeSig false "tyvarLevel" (TyFun (TyApp (TyCon "Ref") (TyCon "Tyvar")) (TyCon "Int")))
(DFunDef false "tyvarLevel" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Unbound" PWild (PVar "lvl")) () (EVar "lvl")) (arm (PCon "Link" PWild) () (ELit (LInt 0)))))
(DTypeSig false "occursAdjust" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyCon "Unit"))))))
(DFunDef false "occursAdjust" ((PVar "mctx") (PVar "id") (PVar "level") (PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TVar" (PVar "cell")) () (EApp (EApp (EApp (EApp (EVar "occursAdjustVar") (EVar "mctx")) (EVar "id")) (EVar "level")) (EVar "cell"))) (arm (PCon "TCon" PWild PWild) () (ELit LUnit)) (arm (PCon "TRigid" PWild) () (ELit LUnit)) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "occursAdjust") (EVar "mctx")) (EVar "id")) (EVar "level")) (EVar "a"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "occursAdjust") (EVar "mctx")) (EVar "id")) (EVar "level")) (EVar "b"))))) (arm (PCon "TFun" (PVar "a") (PVar "r") (PVar "b")) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "occursAdjust") (EVar "mctx")) (EVar "id")) (EVar "level")) (EVar "a"))) (DoExpr (EApp (EApp (EVar "lowerRowLevels") (EVar "level")) (EVar "r"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "occursAdjust") (EVar "mctx")) (EVar "id")) (EVar "level")) (EVar "b"))))) (arm (PCon "TEff" (PVar "r")) () (EApp (EApp (EVar "lowerRowLevels") (EVar "level")) (EVar "r"))) (arm (PCon "TQual" (PVar "a") (PVar "q")) () (EBlock (DoExpr (EApp (EApp (EVar "lowerAuthLevels") (EVar "level")) (EVar "q"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "occursAdjust") (EVar "mctx")) (EVar "id")) (EVar "level")) (EVar "a"))))) (arm (PCon "TAuth" (PVar "q")) () (EApp (EApp (EVar "lowerAuthLevels") (EVar "level")) (EVar "q")))))
(DTypeSig false "occursAdjustVar" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyCon "Tyvar")) (TyCon "Unit"))))))
(DFunDef false "occursAdjustVar" ((PVar "mctx") (PVar "id") (PVar "level") (PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Unbound" (PVar "id2") (PVar "lvl2")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "occursAdjustUnbound") (EVar "mctx")) (EVar "id")) (EVar "level")) (EVar "cell")) (EVar "id2")) (EVar "lvl2"))) (arm (PCon "Link" (PVar "t")) () (EApp (EApp (EApp (EApp (EVar "occursAdjust") (EVar "mctx")) (EVar "id")) (EVar "level")) (EVar "t")))))
(DTypeSig false "occursAdjustUnbound" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyCon "Tyvar")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Unit"))))))))
(DFunDef false "occursAdjustUnbound" ((PVar "mctx") (PVar "id") (PVar "level") (PVar "cell") (PVar "id2") (PVar "lvl2")) (EIf (EBinOp "==" (EVar "id2") (EVar "id")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "occursCheckFailed")) (EVar "True"))) (DoExpr (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-INFINITE-TYPE"))) (EBinOp "++" (EBinOp "++" (ELit (LString "cannot construct an infinite type involving `")) (EApp (EVar "ppMono") (EApp (EVar "TVar") (EVar "cell")))) (ELit (LString "`")))))) (EIf (EBinOp ">" (EVar "lvl2") (EVar "level")) (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EApp (EVar "Unbound") (EVar "id2")) (EVar "level"))) (EIf (EVar "otherwise") (ELit LUnit) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "unify" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "unify" ((PVar "mctx") (PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "unifyIn") (EApp (EVar "dynFor") (EVar "mctx"))) (EVar "a")) (EVar "b")))
(DTypeSig true "unifyIn" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "unifyIn" ((PVar "dyn") (PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "unifyValue") (EVar "dyn")) (EApp (EVar "normalize") (EVar "a"))) (EApp (EVar "normalize") (EVar "b"))))
(DTypeSig false "unifyValue" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "unifyValue" ((PVar "dyn") (PCon "TVar" (PVar "c")) (PCon "TQual" (PVar "a") PWild)) (EApp (EApp (EApp (EVar "unifyN") (EVar "dyn")) (EApp (EVar "TVar") (EVar "c"))) (EApp (EVar "normalize") (EVar "a"))))
(DFunDef false "unifyValue" ((PVar "dyn") (PCon "TQual" (PVar "a") PWild) (PCon "TVar" (PVar "c"))) (EApp (EApp (EApp (EVar "unifyN") (EVar "dyn")) (EApp (EVar "normalize") (EVar "a"))) (EApp (EVar "TVar") (EVar "c"))))
(DFunDef false "unifyValue" ((PVar "dyn") (PCon "TQual" (PVar "a") PWild) (PCon "TQual" (PVar "b") PWild)) (EApp (EApp (EApp (EVar "unifyN") (EVar "dyn")) (EApp (EVar "normalize") (EVar "a"))) (EApp (EVar "normalize") (EVar "b"))))
(DFunDef false "unifyValue" ((PVar "dyn") (PCon "TQual" (PVar "a") PWild) (PVar "b")) (EApp (EApp (EApp (EVar "unifyN") (EVar "dyn")) (EApp (EVar "normalize") (EVar "a"))) (EVar "b")))
(DFunDef false "unifyValue" ((PVar "dyn") (PVar "a") (PCon "TQual" (PVar "b") PWild)) (EApp (EApp (EApp (EVar "unifyN") (EVar "dyn")) (EVar "a")) (EApp (EVar "normalize") (EVar "b"))))
(DFunDef false "unifyValue" ((PVar "dyn") (PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "unifyN") (EVar "dyn")) (EVar "a")) (EVar "b")))
(DTypeSig false "unifyStruct" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "unifyStruct" ((PVar "dyn") (PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "unifyN") (EVar "dyn")) (EApp (EVar "normalize") (EVar "a"))) (EApp (EVar "normalize") (EVar "b"))))
(DTypeSig false "unifyN" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "unifyN" ((PVar "dyn") (PCon "TVar" (PVar "c1")) (PCon "TVar" (PVar "c2"))) (EApp (EApp (EApp (EVar "unifyVars") (EVar "dyn")) (EVar "c1")) (EVar "c2")))
(DFunDef false "unifyN" ((PVar "dyn") (PCon "TVar" (PVar "c")) (PVar "t")) (EApp (EApp (EApp (EVar "bindVar") (EVar "dyn")) (EVar "c")) (EVar "t")))
(DFunDef false "unifyN" ((PVar "dyn") (PVar "t") (PCon "TVar" (PVar "c"))) (EApp (EApp (EApp (EVar "bindVar") (EVar "dyn")) (EVar "c")) (EVar "t")))
(DFunDef false "unifyN" ((PVar "dyn") (PAs "ta" (PCon "TCon" (PVar "a") (PVar "oa"))) (PAs "tb" (PCon "TCon" (PVar "b") (PVar "ob")))) (EIf (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EVar "a")) (EVar "oa")) (EVar "b")) (EVar "ob")) (ELit LUnit) (EApp (EApp (EApp (EVar "typeMismatch") (EVar "dyn")) (EVar "ta")) (EVar "tb"))))
(DFunDef false "unifyN" ((PVar "dyn") (PCon "TRigid" (PVar "a")) (PCon "TRigid" (PVar "b"))) (EIf (EBinOp "==" (EVar "a") (EVar "b")) (ELit LUnit) (EApp (EApp (EApp (EVar "typeMismatch") (EVar "dyn")) (EApp (EVar "TRigid") (EVar "a"))) (EApp (EVar "TRigid") (EVar "b")))))
(DFunDef false "unifyN" ((PVar "dyn") (PAs "ta" (PCon "TCon" (PVar "a") PWild)) (PAs "tb" (PCon "TRigid" (PVar "b")))) (EIf (EBinOp "==" (EVar "a") (EVar "b")) (ELit LUnit) (EApp (EApp (EApp (EVar "typeMismatch") (EVar "dyn")) (EVar "ta")) (EVar "tb"))))
(DFunDef false "unifyN" ((PVar "dyn") (PAs "ta" (PCon "TRigid" (PVar "a"))) (PAs "tb" (PCon "TCon" (PVar "b") PWild))) (EIf (EBinOp "==" (EVar "a") (EVar "b")) (ELit LUnit) (EApp (EApp (EApp (EVar "typeMismatch") (EVar "dyn")) (EVar "ta")) (EVar "tb"))))
(DFunDef false "unifyN" ((PVar "dyn") (PVar "t1") (PVar "t2")) (EIf (EApp (EApp (EVar "tupleUnifyClash") (EVar "t1")) (EVar "t2")) (EApp (EApp (EApp (EVar "typeMismatch") (EVar "dyn")) (EVar "t1")) (EVar "t2")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "unifyN" ((PVar "dyn") (PCon "TApp" (PVar "a1") (PVar "b1")) (PCon "TApp" (PVar "a2") (PVar "b2"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "unifyStruct") (EVar "dyn")) (EVar "a1")) (EVar "a2"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "paramVarianceGuard") (EVar "dyn")) (EVar "a1")) (EVar "b1")) (EVar "b2")))))
(DFunDef false "unifyN" ((PVar "dyn") (PCon "TFun" (PVar "a1") (PVar "r1") (PVar "b1")) (PCon "TFun" (PVar "a2") (PVar "r2") (PVar "b2"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "unifyStruct") (EVar "dyn")) (EVar "a1")) (EVar "a2"))) (DoExpr (EApp (EApp (EApp (EVar "unifyRow") (EVar "dyn")) (EVar "r1")) (EVar "r2"))) (DoExpr (EApp (EApp (EApp (EVar "unifyStruct") (EVar "dyn")) (EVar "b1")) (EVar "b2")))))
(DFunDef false "unifyN" ((PVar "dyn") (PCon "TEff" (PVar "r1")) (PCon "TEff" (PVar "r2"))) (EApp (EApp (EApp (EVar "unifyIndexRow") (EVar "dyn")) (EVar "r1")) (EVar "r2")))
(DFunDef false "unifyN" ((PVar "dyn") (PCon "TAuth" (PVar "qa")) (PCon "TAuth" (PVar "qb"))) (EApp (EApp (EApp (EVar "unifyIndex") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "qa")) (EVar "qb")))
(DFunDef false "unifyN" ((PVar "dyn") (PCon "TQual" (PVar "a") (PVar "qa")) (PCon "TQual" (PVar "b") (PVar "qb"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "wantAuthority") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "qa")) (EVar "qb"))) (DoExpr (EApp (EApp (EApp (EVar "wantAuthority") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "qb")) (EVar "qa"))) (DoExpr (EApp (EApp (EApp (EVar "unifyStruct") (EVar "dyn")) (EVar "a")) (EVar "b")))))
(DFunDef false "unifyN" ((PVar "dyn") (PCon "TQual" (PVar "a") (PVar "qa")) (PVar "b")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "wantAuthority") (EFieldAccess (EVar "dyn") "dcModule")) (EApp (EVar "authTop") (EApp (EVar "authDomainTop") (EVar "qa")))) (EVar "qa"))) (DoExpr (EApp (EApp (EApp (EVar "unifyStruct") (EVar "dyn")) (EVar "a")) (EVar "b")))))
(DFunDef false "unifyN" ((PVar "dyn") (PVar "a") (PCon "TQual" (PVar "b") (PVar "qb"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "wantAuthority") (EFieldAccess (EVar "dyn") "dcModule")) (EApp (EVar "authTop") (EApp (EVar "authDomainTop") (EVar "qb")))) (EVar "qb"))) (DoExpr (EApp (EApp (EApp (EVar "unifyStruct") (EVar "dyn")) (EVar "a")) (EVar "b")))))
(DFunDef false "unifyN" ((PVar "dyn") (PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "typeMismatch") (EVar "dyn")) (EVar "a")) (EVar "b")))
(DTypeSig true "bindFrom" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "bindFrom" ((PVar "dyn") (PVar "target") (PVar "source")) (EMatch (EApp (EVar "normalize") (EVar "target")) (arm (PCon "TVar" (PVar "cell")) () (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Unbound" PWild PWild) () (EApp (EApp (EApp (EVar "bindVar") (EVar "dyn")) (EVar "cell")) (EVar "source"))) (arm (PCon "Link" PWild) () (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "target")) (EVar "source"))))) (arm PWild () (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "target")) (EVar "source")))))
(DTypeSig true "wantAuthority" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Unit")))))
(DFunDef false "wantAuthority" ((PVar "mctx") (PVar "lower") (PVar "upper")) (EApp (EApp (EApp (EApp (EVar "wantAuthorityWith") (EVar "mctx")) (EVar "False")) (EVar "lower")) (EVar "upper")))
(DTypeSig true "wantAuthorityWith" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Unit"))))))
(DFunDef false "wantAuthorityWith" ((PVar "mctx") (PVar "exact") (PVar "lower") (PVar "upper")) (EApp (EApp (EApp (EApp (EApp (EVar "wantAuthorityFrom") (EVar "mctx")) (EVar "None")) (EVar "exact")) (EVar "lower")) (EVar "upper")))
(DTypeSig false "wantAuthorityFrom" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Unit")))))))
(DFunDef false "wantAuthorityFrom" ((PVar "mctx") (PVar "origin") (PVar "exact") (PVar "lower") (PVar "upper")) (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "pair")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "wantAuthorityOne") (EVar "mctx")) (EVar "origin")) (EVar "exact")) (EVar "False")) (EApp (EVar "fst") (EVar "pair"))) (EApp (EVar "snd") (EVar "pair"))))) (ELit LUnit)) (EApp (EApp (EVar "authSplit") (EVar "lower")) (EVar "upper"))))
(DTypeSig false "wantIndexCovered" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Unit")))))
(DFunDef false "wantIndexCovered" ((PVar "mctx") (PVar "lower") (PVar "upper")) (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "pair")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "wantAuthorityOne") (EVar "mctx")) (EVar "None")) (EVar "True")) (EVar "True")) (EApp (EVar "fst") (EVar "pair"))) (EApp (EVar "snd") (EVar "pair"))))) (ELit LUnit)) (EApp (EApp (EVar "authSplit") (EVar "lower")) (EVar "upper"))))
(DTypeSig false "wantAuthorityOne" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Unit"))))))))
(DFunDef false "wantAuthorityOne" ((PVar "mctx") (PVar "origin") (PVar "exact") (PVar "covering") (PVar "lower") (PVar "upper")) (EIf (EApp (EVar "EffectSolver.hasSummaryScope") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "effectSummaries")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "EffectSolver.recordAuthorityFrom") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "effectSummaries")) (EVar "origin")) (EVar "exact")) (EApp (EApp (EVar "obligationSiteHere") (EVar "mctx")) (EVar "covering"))) (EApp (EVar "authNorm") (EVar "lower"))) (EApp (EVar "authNorm") (EVar "upper"))) (EIf (EApp (EApp (EVar "authSub") (EVar "lower")) (EVar "upper")) (ELit LUnit) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "solveFlexibleUpper") (EVar "mctx")) (EVar "lower")) (EVar "upper")) (arm (PCon "True") () (ELit LUnit)) (arm (PCon "False") () (EIf (EVar "exact") (EApp (EApp (EApp (EApp (EApp (EVar "reportIndexFailure") (EVar "mctx")) (EVar "covering")) (EFieldAccess (EVar "mctx") "mcLoc")) (EVar "lower")) (EVar "upper")) (EApp (EApp (EApp (EApp (EApp (EVar "reportAuthorityFailure") (EVar "mctx")) (EFieldAccess (EVar "mctx") "mcLoc")) (EVar "origin")) (EVar "lower")) (EVar "upper"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "solveFlexibleUpper" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Bool")))))
(DFunDef false "solveFlexibleUpper" ((PVar "mctx") (PVar "lower") (PVar "upper")) (EMatch (EApp (EVar "authNorm") (EVar "upper")) (arm (PCon "AVar" (PVar "cell")) () (EIf (EApp (EApp (EVar "IdMap.has") (EApp (EVar "authvarId") (EVar "cell"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "rigidAuthvarsRef") "value")) (EVar "False") (EMatch (EApp (EApp (EVar "withoutVar") (EVar "cell")) (EVar "lower")) (arm (PList) () (EVar "True")) (arm (PVar "rest") () (EBlock (DoExpr (EApp (EApp (EVar "linkAuthvar") (EVar "cell")) (EApp (EApp (EApp (EVar "widenOpenedFor") (EVar "mctx")) (EApp (EVar "authvarLevel") (EVar "cell"))) (EApp (EVar "authJoinAll") (EVar "rest"))))) (DoExpr (EVar "True"))))))) (arm PWild () (EVar "False"))))
(DTypeSig false "withoutVar" (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyFun (TyCon "Authority") (TyApp (TyCon "List") (TyCon "Authority")))))
(DFunDef false "withoutVar" ((PVar "cell") (PVar "q")) (EBlock (DoLet false false (PVar "members") (EMatch (EApp (EVar "authNorm") (EVar "q")) (arm (PCon "AJoin" (PVar "ms")) () (EVar "ms")) (arm (PVar "other") () (EListLit (EVar "other"))))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "m")) (EMatch (EVar "m") (arm (PCon "AVar" (PVar "c")) () (EBinOp "/=" (EApp (EVar "authvarId") (EVar "c")) (EApp (EVar "authvarId") (EVar "cell")))) (arm PWild () (EVar "True"))))) (EVar "members")))))
(DTypeSig true "widenOpenedFor" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyFun (TyCon "Authority") (TyCon "Authority")))))
(DFunDef false "widenOpenedFor" ((PVar "mctx") (PVar "level") (PVar "q")) (EBlock (DoLet false false (PVar "asub") (EApp (EApp (EVar "flatMap") (ELam ((PVar "c")) (EIf (EBinOp "&&" (EApp (EApp (EVar "IdMap.has") (EApp (EVar "authvarId") (EVar "c"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedAuthvarsRef") "value")) (EBinOp ">" (EApp (EVar "authvarLevel") (EVar "c")) (EVar "level"))) (EListLit (ETuple (EApp (EVar "authvarId") (EVar "c")) (EApp (EVar "authTop") (EApp (EVar "authvarDomain") (EVar "c"))))) (EListLit)))) (EApp (EVar "authVars") (EVar "q")))) (DoExpr (EApp (EApp (EVar "substAuth") (EVar "asub")) (EVar "q")))))
(DTypeSig false "reportAuthorityFailure" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Unit")))))))
(DFunDef false "reportAuthorityFailure" ((PVar "mctx") (PVar "loc") (PVar "origin") (PVar "lower") (PVar "upper")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (ELit (LString "T-AUTHORITY"))) (EVar "loc")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "authorityFailureMsg") (EVar "mctx")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (EVar "None")) (EVar "origin")) (EVar "lower")) (EVar "upper")) (EApp (EVar "Some") (EVar "upper")))))
(DTypeSig true "reportIndexFailure" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Unit")))))))
(DFunDef false "reportIndexFailure" ((PVar "mctx") (PVar "covering") (PVar "loc") (PVar "a") (PVar "b")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (ELit (LString "T-AUTHORITY-INDEX-MISMATCH"))) (EVar "loc")) (EIf (EVar "covering") (EApp (EApp (EVar "authorityCoverMsg") (EVar "a")) (EVar "b")) (EApp (EApp (EVar "authorityIndexMsg") (EVar "a")) (EVar "b")))))
(DTypeSig true "authorityFailureMsg" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyFun (TyApp (TyCon "Option") (TyCon "Authority")) (TyCon "String")))))))))
(DFunDef false "authorityFailureMsg" ((PVar "mctx") (PVar "name") (PVar "label") (PVar "origin") (PVar "lower") (PVar "upper") (PVar "written")) (EBlock (DoLet false false (PVar "ctx") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "cnt") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "lo") (EApp (EApp (EApp (EVar "authorityTermTextIn") (EVar "ctx")) (EVar "cnt")) (EVar "lower"))) (DoLet false false (PVar "hi") (EApp (EApp (EApp (EVar "ppAuthority") (EVar "ctx")) (EVar "cnt")) (EVar "upper"))) (DoExpr (EMatch (EVar "origin") (arm (PCon "Some" (PVar "callee")) () (EApp (EApp (EApp (EVar "residualFailureMsg") (EVar "callee")) (EVar "lo")) (EVar "hi"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "boundFailureMsg") (EVar "mctx")) (EVar "name")) (EVar "label")) (EVar "lower")) (EVar "lo")) (EVar "hi")) (EVar "upper")) (EVar "written")))))))
(DTypeSig false "boundFailureMsg" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Authority") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Authority") (TyFun (TyApp (TyCon "Option") (TyCon "Authority")) (TyCon "String"))))))))))
(DFunDef false "boundFailureMsg" ((PVar "mctx") (PVar "name") (PVar "label") (PVar "lower") (PVar "lo") (PVar "hi") (PVar "upper") (PVar "written")) (EIf (EApp (EApp (EVar "mentionsOpened") (EVar "mctx")) (EVar "upper")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` reaches "))) (EApp (EVar "display") (EVar "lo"))) (ELit (LString " where only "))) (EApp (EVar "display") (EVar "hi"))) (ELit (LString " is admitted, the authority of the value this arm or clause opened; derive the operation from the opened value, or widen the declared row to the label bare"))) (EIf (EBinOp "&&" (EApp (EVar "authHasVars") (EVar "upper")) (EApp (EApp (EVar "binderIn") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "displayHiddenBindersRef")) (EVar "upper"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` reaches "))) (EApp (EVar "display") (EVar "lo"))) (ELit (LString " where only "))) (EApp (EVar "display") (EVar "hi"))) (ELit (LString " is admitted: the interpolation uses this module's own `display`, not the prelude's, so the string is not known to derive from "))) (EApp (EVar "display") (EVar "hi"))) (ELit (LString "; build it with `++` from the named argument"))) (EIf (EBinOp "&&" (EApp (EVar "authHasVars") (EVar "upper")) (EApp (EApp (EVar "allList") (EVar "authvarIsPattern")) (EApp (EVar "authVars") (EVar "upper")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` reaches "))) (EApp (EVar "display") (EVar "lo"))) (ELit (LString " where only "))) (EApp (EVar "display") (EVar "hi"))) (ELit (LString " is admitted, a pattern-ranging authority the caller chooses; build the value by appending to the named argument, `root ++ suffix`, or widen the declared row to the label bare"))) (EIf (EApp (EVar "authHasVars") (EVar "upper")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ordinaryBoundFailureMsg") (EVar "mctx")) (EVar "name")) (EVar "label")) (EVar "lower")) (EVar "lo")) (EVar "hi")) (EVar "upper")) (EIf (EApp (EApp (EVar "solvedUpper") (EVar "mctx")) (EVar "written")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` reaches "))) (EApp (EVar "display") (EVar "lo"))) (ELit (LString " where only "))) (EApp (EVar "display") (EVar "hi"))) (ELit (LString " is admitted, the bound this binding's other uses of the same authority determined; make every use lie within one bound, or write the bound"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` reaches "))) (EApp (EVar "display") (EVar "lo"))) (ELit (LString " where its declared bound admits only "))) (EApp (EVar "display") (EVar "hi"))) (ELit (LString "; stay within the bound, or widen it")))))))))
(DTypeSig false "ordinaryBoundFailureMsg" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Authority") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Authority") (TyCon "String")))))))))
(DFunDef false "ordinaryBoundFailureMsg" ((PVar "mctx") (PVar "name") (PVar "label") (PVar "lower") (PVar "lo") (PVar "hi") (PVar "upper")) (EBlock (DoLet false false (PVar "head") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` reaches "))) (EApp (EVar "display") (EVar "lo"))) (ELit (LString " where only "))) (EApp (EVar "display") (EVar "hi"))) (ELit (LString " is admitted, an authority the caller chooses")))) (DoLet false false (PVar "extended") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EApp (EVar "IdMap.has") (EApp (EVar "authvarId") (EVar "c"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "extendedBindersRef") "value")))) (EApp (EVar "authVars") (EVar "upper")))) (DoExpr (EIf (EBinOp "&&" (EApp (EVar "authIsTop") (EVar "lower")) (EApp (EVar "isNonEmptyL") (EVar "extended"))) (EBlock (DoLet false false (PVar "tail") (ELit (LString "; an extension of it is the whole domain, so "))) (DoExpr (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "domainHasPatterns") (EApp (EVar "authvarDomain") (EVar "c"))))) (EVar "extended")) (arm (PCons (PVar "c") PWild) () (EBlock (DoLet false false (PVar "n") (EApp (EApp (EVar "optionOr") (EVar "hi")) (EApp (EVar "authvarName") (EVar "c")))) (DoLet false false (PVar "star") (EApp (EApp (EVar "starSpelling") (EVar "n")) (EApp (EApp (EApp (EApp (EVar "binderLabel") (EVar "mctx")) (EVar "name")) (EVar "n")) (EVar "label")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "head"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "tail"))) (ELit (LString "declare "))) (EApp (EVar "display") (EVar "star"))) (ELit (LString "")))))) (arm (PList) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "head"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "tail"))) (ELit (LString "perform the operation on the named argument and extend the value at the call site"))))))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "head"))) (ELit (LString "; perform the operation on the named argument, or widen the declared row to the label bare")))))))
(DTypeSig false "binderLabel" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "binderLabel" ((PVar "mctx") (PVar "fn") (PVar "n") (PVar "key")) (EBlock (DoLet false false (PVar "written") (EMatch (EApp (EApp (EVar "omLookup") (EVar "fn")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "sigTyMapRef") "value")) (arm (PCon "Some" (PVar "ty")) () (EApp (EApp (EApp (EVar "binderLabelIn") (EVar "mctx")) (EVar "n")) (EVar "ty"))) (arm (PCon "None") () (EVar "None")))) (DoExpr (EApp (EApp (EVar "orElseOpt") (EVar "written")) (EApp (EApp (EVar "map") (EVar "labelKeyName")) (EVar "key"))))))
(DTypeSig false "binderLabelIn" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "binderLabelIn" ((PVar "mctx") (PVar "n") (PVar "ty")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EApp (EVar "namedArgDomains") (EVar "ty"))) (arm (PCon "Some" (PCon "Some" (PVar "d"))) () (EApp (EVar "Some") (EFieldAccess (EVar "d") "eatLabel"))) (arm PWild () (EMatch (EBinOp "++" (EApp (EApp (EVar "atomBindersIn") (ELam ((PVar "a")) (EApp (EApp (EVar "atomNaming") (EVar "n")) (EVar "a")))) (EVar "ty")) (EApp (EApp (EApp (EVar "authSlotNamesIn") (EVar "mctx")) (EApp (EVar "slotLabelsNaming") (EVar "n"))) (EVar "ty"))) (arm (PCons (PVar "l") PWild) () (EApp (EVar "Some") (EVar "l"))) (arm (PList) () (EVar "None"))))))
(DTypeSig false "slotLabelsNaming" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "slotLabelsNaming" ((PVar "n") (PCons (PCon "KAuth" (PVar "l") PWild) (PVar "ks")) (PCons (PCon "TyVar" (PVar "m")) (PVar "as2"))) (EIf (EBinOp "==" (EVar "m") (EVar "n")) (EBinOp "::" (EApp (EVar "effLabelName") (EVar "l")) (EApp (EApp (EApp (EVar "slotLabelsNaming") (EVar "n")) (EVar "ks")) (EVar "as2"))) (EApp (EApp (EApp (EVar "slotLabelsNaming") (EVar "n")) (EVar "ks")) (EVar "as2"))))
(DFunDef false "slotLabelsNaming" ((PVar "n") (PCons PWild (PVar "ks")) (PCons PWild (PVar "as2"))) (EApp (EApp (EApp (EVar "slotLabelsNaming") (EVar "n")) (EVar "ks")) (EVar "as2")))
(DFunDef false "slotLabelsNaming" (PWild PWild PWild) (EListLit))
(DTypeSig false "atomNaming" (TyFun (TyCon "String") (TyFun (TyCon "EffAtomTy") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "atomNaming" ((PVar "n") (PVar "a")) (EMatch (EFieldAccess (EVar "a") "eatParam") (arm (PCon "EPName" (PVar "m")) () (EIf (EBinOp "==" (EVar "m") (EVar "n")) (EListLit (EFieldAccess (EVar "a") "eatLabel")) (EListLit))) (arm PWild () (EListLit))))
(DTypeSig false "labelKeyName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "labelKeyName" ((PVar "key")) (EMatch (EApp (EVar "reverseL") (EApp (EApp (EVar "splitOnChar") (ELit (LChar ":"))) (EVar "key"))) (arm (PCons (PVar "last") PWild) () (EVar "last")) (arm (PList) () (EVar "key"))))
(DTypeSig false "binderIn" (TyFun (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))) (TyFun (TyCon "Authority") (TyCon "Bool"))))
(DFunDef false "binderIn" ((PVar "table") (PVar "q")) (EApp (EApp (EVar "anyList") (ELam ((PVar "c")) (EApp (EApp (EVar "IdMap.has") (EApp (EVar "authvarId") (EVar "c"))) (EFieldAccess (EVar "table") "value")))) (EApp (EVar "authVars") (EVar "q"))))
(DTypeSig false "mentionsOpened" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Authority") (TyCon "Bool"))))
(DFunDef false "mentionsOpened" ((PVar "mctx") (PVar "q")) (EApp (EApp (EVar "anyList") (ELam ((PVar "cell")) (EApp (EApp (EVar "IdMap.has") (EApp (EVar "authvarId") (EVar "cell"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedAuthvarsRef") "value")))) (EApp (EVar "authVars") (EVar "q"))))
(DTypeSig false "solvedUpper" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "Authority")) (TyCon "Bool"))))
(DFunDef false "solvedUpper" ((PVar "mctx") (PCon "Some" (PCon "AVar" (PVar "cell")))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "ALink" PWild PWild PWild) () (EApp (EVar "not") (EApp (EApp (EVar "IdMap.has") (EApp (EVar "authvarId") (EVar "cell"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "indexSubstitutedRef") "value")))) (arm (PCon "AUnbound" PWild PWild PWild PWild PWild) () (EVar "False"))))
(DFunDef false "solvedUpper" ((PVar "mctx") PWild) (EVar "False"))
(DTypeSig false "paramVarianceGuard" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit"))))))
(DFunDef false "paramVarianceGuard" ((PVar "dyn") (PVar "hd") (PVar "b1") (PVar "b2")) (EIf (EApp (EApp (EVar "monoSlotNonCovariant") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "hd")) (EApp (EApp (EApp (EVar "unifyStruct") (ERecordUpdate (EVar "dyn") ((fa "dcNonCovariant" (EVar "True"))))) (EVar "b1")) (EVar "b2")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "unifyStruct") (EVar "dyn")) (EVar "b1")) (EVar "b2")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "paramPolaritiesOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "TabKey") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Polarity"))))))
(DFunDef false "paramPolaritiesOf" ((PVar "mctx") (PVar "key")) (EApp (EApp (EVar "paramPolaritiesIn") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamPolarityRef") "value")) (EVar "key")))
(DTypeSig false "unifyVars" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "Ref") (TyCon "Tyvar")) (TyFun (TyApp (TyCon "Ref") (TyCon "Tyvar")) (TyCon "Unit")))))
(DFunDef false "unifyVars" ((PVar "dyn") (PVar "c1") (PVar "c2")) (EIf (EBinOp "==" (EApp (EVar "tyvarId") (EVar "c1")) (EApp (EVar "tyvarId") (EVar "c2"))) (ELit LUnit) (EApp (EApp (EApp (EVar "bindVar") (EVar "dyn")) (EVar "c1")) (EApp (EVar "TVar") (EVar "c2")))))
(DTypeSig false "bindVar" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "Ref") (TyCon "Tyvar")) (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "bindVar" ((PVar "dyn") (PVar "cell") (PVar "t")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "occursCheckFailed")) (EVar "False"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "occursAdjust") (EFieldAccess (EVar "dyn") "dcModule")) (EApp (EVar "tyvarId") (EVar "cell"))) (EApp (EVar "tyvarLevel") (EVar "cell"))) (EVar "t"))) (DoExpr (EIf (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "occursCheckFailed") "value") (ELit LUnit) (EBlock (DoExpr (EApp (EApp (EApp (EVar "propagatePoison") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "cell")) (EVar "t"))) (DoLet false false (PVar "shaped") (EApp (EApp (EApp (EVar "takeJoinsShapedBy") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "cell")) (EVar "t"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EVar "Link") (EVar "t")))) (DoExpr (EApp (EApp (EVar "settleShapedJoins") (EVar "dyn")) (EVar "shaped"))))))))
(DTypeSig false "takeJoinsShapedBy" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Ref") (TyCon "Tyvar")) (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "PendingJoin"))))))
(DFunDef false "takeJoinsShapedBy" ((PVar "mctx") (PVar "cell") (PVar "t")) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "pendingJoinsRef") "value") (arm (PList) () (EListLit)) (arm (PVar "pending") () (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TVar" PWild) () (EListLit)) (arm PWild () (EBlock (DoLet false false (PVar "id") (EApp (EVar "tyvarId") (EVar "cell"))) (DoLet false false (PVar "hits") (EApp (EApp (EVar "filter") (ELam ((PVar "pj")) (EApp (EApp (EVar "joinResultIs") (EVar "id")) (EVar "pj")))) (EVar "pending"))) (DoExpr (EMatch (EVar "hits") (arm (PList) () (EListLit)) (arm PWild () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "pendingJoinsRef")) (EApp (EApp (EVar "filter") (ELam ((PVar "pj")) (EApp (EVar "not") (EApp (EApp (EVar "joinResultIs") (EVar "id")) (EVar "pj"))))) (EVar "pending")))) (DoExpr (EVar "hits"))))))))))))
(DTypeSig false "joinResultIs" (TyFun (TyCon "Int") (TyFun (TyCon "PendingJoin") (TyCon "Bool"))))
(DFunDef false "joinResultIs" ((PVar "id") (PVar "pj")) (EMatch (EApp (EVar "normalize") (EFieldAccess (EVar "pj") "pjResult")) (arm (PCon "TVar" (PVar "c")) () (EBinOp "==" (EApp (EVar "tyvarId") (EVar "c")) (EVar "id"))) (arm PWild () (EVar "False"))))
(DTypeSig false "settleShapedJoins" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "List") (TyCon "PendingJoin")) (TyCon "Unit"))))
(DFunDef false "settleShapedJoins" ((PVar "dyn") (PList)) (ELit LUnit))
(DFunDef false "settleShapedJoins" ((PVar "dyn") (PVar "shaped")) (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "pj")) (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PTuple (PVar "loc") (PVar "value"))) (EApp (EApp (EApp (EApp (EApp (EVar "joinValueEqual") (EVar "dyn")) (EFieldAccess (EVar "pj") "pjContext")) (EVar "loc")) (EFieldAccess (EVar "pj") "pjResult")) (EVar "value")))) (ELit LUnit)) (EFieldAccess (EVar "pj") "pjValues")))) (ELit LUnit)) (EVar "shaped")))
(DTypeSig false "propagatePoison" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Ref") (TyCon "Tyvar")) (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "propagatePoison" ((PVar "mctx") (PVar "cell") (PVar "t")) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "poisonedVars") "value") (arm (PList) () (ELit LUnit)) (arm (PVar "poisoned") () (EIf (EApp (EApp (EVar "containsI") (EApp (EVar "tyvarId") (EVar "cell"))) (EVar "poisoned")) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "poisonedVars")) (EBinOp "++" (EApp (EVar "monoUnboundIds") (EVar "t")) (EVar "poisoned"))) (ELit LUnit)))))
(DTypeSig true "poisonMismatchVars" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "poisonMismatchVars" ((PVar "mctx") (PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "poisoned") (EBinOp "++" (EBinOp "++" (EApp (EVar "monoUnboundIds") (EVar "a")) (EApp (EVar "monoUnboundIds") (EVar "b"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "poisonedVars") "value"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "poisonedVars")) (EVar "poisoned")))))
(DTypeSig false "typeMismatch" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "typeMismatch" ((PVar "dyn") (PVar "a") (PVar "b")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "poisonMismatchVars") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "a")) (EVar "b"))) (DoExpr (EApp (EApp (EApp (EVar "typeMismatchReport") (EVar "dyn")) (EVar "a")) (EVar "b")))))
(DTypeSig false "activeDo" (TyFun (TyCon "DynCtx") (TyApp (TyCon "Option") (TyCon "DoCtx"))))
(DFunDef false "activeDo" ((PVar "dyn")) (EMatch (EFieldAccess (EVar "dyn") "dcDo") (arm (PCon "Some" (PVar "doCtx")) () (EIf (EFieldAccess (EFieldAccess (EVar "doCtx") "doReported") "value") (EVar "None") (EApp (EVar "Some") (EVar "doCtx")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "typeMismatchReport" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "typeMismatchReport" ((PVar "dyn") (PVar "a") (PVar "b")) (EMatch (EFieldAccess (EVar "dyn") "dcMethodMismatch") (arm (PCon "Some" (PVar "mname")) () (EApp (EApp (EApp (EVar "pushTypeError") (EFieldAccess (EVar "dyn") "dcModule")) (ELit (LString "T-METHOD-MISMATCH"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "method `")) (EApp (EVar "display") (EVar "mname"))) (ELit (LString "` has type "))) (EApp (EVar "display") (EApp (EVar "ppMono") (EVar "b")))) (ELit (LString " but its interface declares "))) (EApp (EVar "display") (EApp (EVar "ppMono") (EVar "a")))) (ELit (LString ""))))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "typeMismatchReportJoin") (EVar "dyn")) (EVar "a")) (EVar "b")))))
(DTypeSig false "typeMismatchReportJoin" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "typeMismatchReportJoin" ((PVar "dyn") (PVar "a") (PVar "b")) (EMatch (EFieldAccess (EVar "dyn") "dcJoin") (arm (PCon "Some" (PCon "JoinElselessIf")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushTypeErrorHelpFixAt") (EFieldAccess (EVar "dyn") "dcModule")) (ELit (LString "T-TYPE-MISMATCH"))) (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcLoc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type mismatch: ")) (EApp (EVar "display") (EApp (EVar "ppMono") (EVar "a")))) (ELit (LString " vs "))) (EApp (EVar "display") (EApp (EVar "ppMono") (EVar "b")))) (ELit (LString "; "))) (EApp (EVar "display") (EVar "elselessIfHelp"))) (ELit (LString "")))) (EVar "elselessIfHelp")) (EVar "None"))) (arm PWild () (EMatch (ETuple (EApp (EVar "activeDo") (EVar "dyn")) (EApp (EApp (EApp (EVar "constrainedApplicationHelp") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "a")) (EVar "b"))) (arm (PTuple (PCon "None") (PCon "Some" (PVar "help"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushTypeErrorHelpFixAt") (EFieldAccess (EVar "dyn") "dcModule")) (ELit (LString "T-TYPE-MISMATCH"))) (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcLoc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type mismatch: ")) (EApp (EVar "display") (EApp (EVar "ppMono") (EVar "a")))) (ELit (LString " vs "))) (EApp (EVar "display") (EApp (EVar "ppMono") (EVar "b")))) (ELit (LString "; "))) (EApp (EVar "display") (EVar "help"))) (ELit (LString "")))) (EVar "help")) (EVar "None"))) (arm PWild () (EApp (EApp (EApp (EVar "typeMismatchReportRest") (EVar "dyn")) (EVar "a")) (EVar "b")))))))
(DTypeSig false "constrainedApplicationHelp" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "constrainedApplicationHelp" ((PVar "mctx") (PVar "a") (PVar "b")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "app") (PVar "plain") (PVar "ifaces"))) (EApp (EApp (EApp (EVar "constrainedApplicationText") (EVar "app")) (EVar "plain")) (EVar "ifaces")))) (EApp (EApp (EVar "orElseOpt") (EApp (EApp (EApp (EVar "appliedVarIfaces") (EVar "mctx")) (EVar "a")) (EVar "b"))) (EApp (EApp (EApp (EVar "appliedVarIfaces") (EVar "mctx")) (EVar "b")) (EVar "a")))))
(DTypeSig false "appliedVarIfaces" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyTuple (TyCon "Mono") (TyCon "Mono") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "appliedVarIfaces" ((PVar "mctx") (PVar "app") (PVar "plain")) (EMatch (ETuple (EApp (EVar "normalize") (EVar "app")) (EApp (EVar "normalize") (EVar "plain"))) (arm (PTuple (PCon "TApp" PWild PWild) (PCon "TApp" PWild PWild)) () (EVar "None")) (arm (PTuple (PCon "TApp" PWild PWild) PWild) () (EMatch (EApp (EVar "normalize") (EApp (EVar "spineHead") (EVar "app"))) (arm (PCon "TVar" (PVar "cell")) () (EMatch (EApp (EApp (EVar "ifacesConstrainingVar") (EVar "mctx")) (EApp (EVar "tyvarId") (EVar "cell"))) (arm (PList) () (EVar "None")) (arm (PVar "ifaces") () (EApp (EVar "Some") (ETuple (EVar "app") (EVar "plain") (EVar "ifaces")))))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig false "ifacesConstrainingVar" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ifacesConstrainingVar" ((PVar "mctx") (PVar "id")) (EBlock (DoLet false false (PVar "pending") (EBinOp "++" (EApp (EVar "wAll") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "obls")) (EApp (EVar "wAll") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "implObls")))) (DoLet false false (PVar "onVar") (EApp (EApp (EVar "filter") (ELam ((PVar "o")) (EApp (EApp (EVar "anyList") (EApp (EVar "sameRootId") (EVar "id"))) (EFieldAccess (EFieldAccess (EVar "o") "pred") "args")))) (EVar "pending"))) (DoExpr (EApp (EVar "dedup") (EApp (EApp (EVar "map") (ELam ((PVar "o")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "o") "pred") "iface") "irName"))) (EVar "onVar"))))))
(DTypeSig false "typeMismatchReportRest" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "typeMismatchReportRest" ((PVar "dyn") (PVar "a") (PVar "b")) (EMatch (EApp (EVar "activeDo") (EVar "dyn")) (arm (PCon "Some" (PVar "doCtx")) () (EApp (EApp (EApp (EApp (EVar "typeMismatchInDo") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "a")) (EVar "b")) (EVar "doCtx"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "firstTupleCallHint") (EFieldAccess (EVar "dyn") "dcModule")) (EListLit (EVar "a") (EVar "b"))) (arm (PCon "Some" (PTuple (PVar "help") (PVar "fix"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushTypeErrorHelpFixAt") (EFieldAccess (EVar "dyn") "dcModule")) (ELit (LString "T-TYPE-MISMATCH"))) (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcLoc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type mismatch: ")) (EApp (EVar "display") (EApp (EVar "ppMono") (EVar "a")))) (ELit (LString " vs "))) (EApp (EVar "display") (EApp (EVar "ppMono") (EVar "b")))) (ELit (LString "; "))) (EApp (EVar "display") (EVar "help"))) (ELit (LString "")))) (EVar "help")) (EVar "fix"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "sameSpellingHint") (EVar "a")) (EVar "b")) (arm (PCon "Some" (PVar "help")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushTypeErrorHelpFixAt") (EFieldAccess (EVar "dyn") "dcModule")) (ELit (LString "T-TYPE-MISMATCH"))) (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcLoc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type mismatch: ")) (EApp (EVar "display") (EApp (EVar "ppMono") (EVar "a")))) (ELit (LString " vs "))) (EApp (EVar "display") (EApp (EVar "ppMono") (EVar "b")))) (ELit (LString "; "))) (EApp (EVar "display") (EVar "help"))) (ELit (LString "")))) (EVar "help")) (EVar "None"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "pushTypeError") (EFieldAccess (EVar "dyn") "dcModule")) (ELit (LString "T-TYPE-MISMATCH"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type mismatch: ")) (EApp (EVar "display") (EApp (EVar "ppMono") (EVar "a")))) (ELit (LString " vs "))) (EApp (EVar "display") (EApp (EVar "ppMono") (EVar "b")))) (ELit (LString "")))))))))))
(DTypeSig false "typeMismatchInDo" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyFun (TyCon "DoCtx") (TyCon "Unit"))))))
(DFunDef false "typeMismatchInDo" ((PVar "mctx") (PVar "a") (PVar "b") (PVar "doCtx")) (EIf (EBinOp "/=" (EApp (EVar "monoIsApp") (EApp (EVar "normalize") (EVar "a"))) (EApp (EVar "monoIsApp") (EApp (EVar "normalize") (EVar "b")))) (EApp (EApp (EVar "recordDoMonadError") (EVar "mctx")) (EVar "doCtx")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-TYPE-MISMATCH"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type mismatch: ")) (EApp (EVar "display") (EApp (EVar "ppMono") (EVar "a")))) (ELit (LString " vs "))) (EApp (EVar "display") (EApp (EVar "ppMono") (EVar "b")))) (ELit (LString "")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "recordDoMonadError" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "DoCtx") (TyCon "Unit"))))
(DFunDef false "recordDoMonadError" ((PVar "mctx") (PVar "doCtx")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "doCtx") "doReported")) (EVar "True"))) (DoExpr (EApp (EApp (EVar "recordTypeError") (EVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "T-DO-NOT-MONAD"))) (ELit (LInt 1))) (EApp (EVar "Some") (EFieldAccess (EVar "doCtx") "doLoc"))) (EIf (EFieldAccess (EVar "doCtx") "doDeferred") (EVar "deferRequiresMonadMsg") (EVar "doRequiresMonadMsg"))) (EVar "None")) (EVar "None"))))))
(DTypeSig true "generalize" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyCon "Scheme"))))
(DFunDef false "generalize" ((PVar "mctx") (PVar "t")) (EApp (EApp (EApp (EApp (EVar "quantifyFree") (EVar "mctx")) (EListLit)) (EVar "pureRow")) (EVar "t")))
(DTypeSig true "generalizeBindingDeclared" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "AuthResidual")) (TyFun (TyCon "EffRow") (TyFun (TyCon "Mono") (TyCon "Scheme")))))))
(DFunDef false "generalizeBindingDeclared" ((PVar "dyn") (PVar "declared") (PVar "residual") (PVar "force") (PVar "t")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "defaultDeferredPatLitsIn") (EVar "dyn")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "currentLevel") "value")) (EVar "t"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "defaultSourcelessAuthorities") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "declared")) (EVar "force")) (EVar "t"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "quantifyFree") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "residual")) (EVar "force")) (EVar "t")))))
(DTypeSig false "quantifyFree" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "AuthResidual")) (TyFun (TyCon "EffRow") (TyFun (TyCon "Mono") (TyCon "Scheme"))))))
(DFunDef false "quantifyFree" ((PVar "mctx") (PVar "residual") (PVar "force") (PVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Forall") (EApp (EVar "dedupI") (EApp (EApp (EVar "freeGenVars") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (EVar "t")))) (EApp (EVar "dedupI") (EBinOp "++" (EApp (EApp (EVar "freeEffvars") (EVar "mctx")) (EVar "t")) (EApp (EApp (EVar "rowFreeEffvars") (EVar "mctx")) (EVar "force"))))) (EApp (EVar "dedupI") (EBinOp "++" (EApp (EApp (EVar "freeAuthvars") (EVar "mctx")) (EVar "t")) (EApp (EApp (EVar "rowFreeAuthvars") (EVar "mctx")) (EVar "force"))))) (EVar "residual")) (EVar "force")) (EVar "t")))
(DTypeSig true "lowerToCurrent" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyCon "Unit"))))
(DFunDef false "lowerToCurrent" ((PVar "mctx") (PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TVar" (PVar "cell")) () (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Unbound" (PVar "id") (PVar "lvl")) () (EIf (EBinOp ">" (EVar "lvl") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EApp (EVar "Unbound") (EVar "id")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value"))) (ELit LUnit))) (arm (PCon "Link" (PVar "t2")) () (EApp (EApp (EVar "lowerToCurrent") (EVar "mctx")) (EVar "t2"))))) (arm (PCon "TCon" PWild PWild) () (ELit LUnit)) (arm (PCon "TRigid" PWild) () (ELit LUnit)) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EBlock (DoExpr (EApp (EApp (EVar "lowerToCurrent") (EVar "mctx")) (EVar "a"))) (DoExpr (EApp (EApp (EVar "lowerToCurrent") (EVar "mctx")) (EVar "b"))))) (arm (PCon "TFun" (PVar "a") (PVar "r") (PVar "b")) () (EBlock (DoExpr (EApp (EApp (EVar "lowerToCurrent") (EVar "mctx")) (EVar "a"))) (DoExpr (EApp (EApp (EVar "lowerRowLevels") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (EVar "r"))) (DoExpr (EApp (EApp (EVar "lowerToCurrent") (EVar "mctx")) (EVar "b"))))) (arm (PCon "TAuth" (PVar "q")) () (EApp (EApp (EVar "lowerAuthLevels") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (EVar "q"))) (arm (PCon "TEff" (PVar "r")) () (EBlock (DoExpr (EApp (EApp (EVar "lowerRowLevels") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (EVar "r"))) (DoExpr (ELit LUnit)))) (arm (PCon "TQual" (PVar "a") (PVar "q")) () (EBlock (DoExpr (EApp (EApp (EVar "lowerAuthLevels") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (EVar "q"))) (DoExpr (EApp (EApp (EVar "lowerToCurrent") (EVar "mctx")) (EVar "a")))))))
(DTypeSig false "freeGenVars" (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "freeGenVars" ((PVar "lvl") (PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TVar" (PVar "cell")) () (EIf (EBinOp ">" (EApp (EVar "tyvarLevel") (EVar "cell")) (EVar "lvl")) (EListLit (EApp (EVar "tyvarId") (EVar "cell"))) (EListLit))) (arm (PCon "TCon" PWild PWild) () (EListLit)) (arm (PCon "TRigid" PWild) () (EListLit)) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EBinOp "++" (EApp (EApp (EVar "freeGenVars") (EVar "lvl")) (EVar "a")) (EApp (EApp (EVar "freeGenVars") (EVar "lvl")) (EVar "b")))) (arm (PCon "TFun" (PVar "a") PWild (PVar "b")) () (EBinOp "++" (EApp (EApp (EVar "freeGenVars") (EVar "lvl")) (EVar "a")) (EApp (EApp (EVar "freeGenVars") (EVar "lvl")) (EVar "b")))) (arm (PCon "TEff" PWild) () (EListLit)) (arm (PCon "TAuth" PWild) () (EListLit)) (arm (PCon "TQual" (PVar "a") PWild) () (EApp (EApp (EVar "freeGenVars") (EVar "lvl")) (EVar "a")))))
(DTypeSig true "instantiate" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Scheme") (TyCon "Mono"))))
(DFunDef false "instantiate" ((PVar "mctx") (PCon "Forall" (PVar "ids") (PVar "evars") (PVar "avars") PWild PWild (PVar "t"))) (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "freshSubst") (EVar "mctx")) (EVar "ids"))) (EApp (EApp (EVar "freshEffSubst") (EVar "mctx")) (EVar "evars"))) (EApp (EApp (EApp (EApp (EVar "freshAuthSubstFor") (EVar "mctx")) (EVar "avars")) (EVar "t")) (EVar "pureRow"))) (EVar "t")))
(DTypeSig true "freshAuthSubstOpening" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Mono") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))) (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Authvar"))))))))
(DFunDef false "freshAuthSubstOpening" ((PVar "mctx") (PList) PWild) (ETuple (EListLit) (EListLit)))
(DFunDef false "freshAuthSubstOpening" ((PVar "mctx") (PVar "ids") (PVar "body")) (EApp (EApp (EApp (EVar "freshAuthSubstOpeningIn") (EVar "mctx")) (EVar "ids")) (EApp (EApp (EVar "authCellsIn") (EVar "body")) (EVar "Tip"))))
(DTypeSig true "freshAuthSubstOpeningIn" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))) (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Authvar"))))))))
(DFunDef false "freshAuthSubstOpeningIn" ((PVar "mctx") (PList) PWild) (ETuple (EListLit) (EListLit)))
(DFunDef false "freshAuthSubstOpeningIn" ((PVar "mctx") (PVar "ids") (PVar "cells")) (EBlock (DoLet false false (PVar "pairs") (EApp (EApp (EVar "map") (ELam ((PVar "id")) (EBlock (DoLet false false (PVar "cell") (EApp (EApp (EApp (EVar "freshInferenceAuthvar") (EVar "mctx")) (EVar "id")) (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EVar "cells")))) (DoExpr (ETuple (EVar "id") (EVar "cell") (EApp (EApp (EVar "IdMap.has") (EVar "id")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "ctorExistentialsRef") "value"))))))) (EVar "ids"))) (DoLet false false (PVar "opened") (EApp (EApp (EVar "flatMap") (ELam ((PTuple PWild (PVar "cell") (PVar "isOpen"))) (EIf (EVar "isOpen") (EListLit (EVar "cell")) (EListLit)))) (EVar "pairs"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "rigidAuthvarsRef")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PVar "cell")) (EApp (EApp (EApp (EVar "IdMap.set") (EApp (EVar "authvarId") (EVar "cell"))) (ELit LUnit)) (EVar "m")))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "rigidAuthvarsRef") "value")) (EVar "opened")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedAuthvarsRef")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PVar "cell")) (EApp (EApp (EApp (EVar "IdMap.set") (EApp (EVar "authvarId") (EVar "cell"))) (ELit LUnit)) (EVar "m")))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedAuthvarsRef") "value")) (EVar "opened")))) (DoExpr (ETuple (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "id") (PVar "cell") PWild)) (ETuple (EVar "id") (EApp (EVar "AVar") (EVar "cell"))))) (EVar "pairs")) (EVar "opened")))))
(DTypeSig true "freshSubst" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))))))
(DFunDef false "freshSubst" ((PVar "mctx") (PList)) (EListLit))
(DFunDef false "freshSubst" ((PVar "mctx") (PCons (PVar "id") (PVar "rest"))) (EBlock (DoLet false false (PVar "v") (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit))) (DoExpr (EIf (EBinOp "==" (EVar "id") (EVar "ambiguousImportTyvarId")) (EApp (EApp (EApp (EVar "poisonMismatchVars") (EVar "mctx")) (EVar "v")) (EVar "v")) (ELit LUnit))) (DoExpr (EBinOp "::" (ETuple (EVar "id") (EVar "v")) (EApp (EApp (EVar "freshSubst") (EVar "mctx")) (EVar "rest"))))))
(DTypeSig true "ambiguousImportTyvarId" (TyCon "Int"))
(DFunDef false "ambiguousImportTyvarId" () (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))))
(DTypeSig true "freshEffSubst" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Effvar")))))))
(DFunDef false "freshEffSubst" ((PVar "mctx") (PList)) (EListLit))
(DFunDef false "freshEffSubst" ((PVar "mctx") (PCons (PVar "id") (PVar "rest"))) (EBlock (DoLet false false (PVar "cell") (EApp (EApp (EVar "freshInferenceEffvar") (EVar "mctx")) (ELit LUnit))) (DoExpr (EBinOp "::" (ETuple (EVar "id") (EVar "cell")) (EApp (EApp (EVar "freshEffSubst") (EVar "mctx")) (EVar "rest"))))))
(DTypeSig false "freshAuthSubstFor" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Mono") (TyFun (TyCon "EffRow") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))))))))
(DFunDef false "freshAuthSubstFor" ((PVar "mctx") (PList) PWild PWild) (EListLit))
(DFunDef false "freshAuthSubstFor" ((PVar "mctx") (PVar "ids") (PVar "body") (PVar "force")) (EBlock (DoLet false false (PVar "cells") (EApp (EApp (EVar "authCellsIn") (EVar "body")) (EApp (EApp (EVar "authRowCells") (EVar "force")) (EVar "Tip")))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "id")) (ETuple (EVar "id") (EApp (EVar "AVar") (EApp (EApp (EApp (EVar "freshInferenceAuthvar") (EVar "mctx")) (EVar "id")) (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EVar "cells"))))))) (EVar "ids")))))
(DTypeSig true "freshInferenceAuthvar" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyApp (TyCon "Ref") (TyCon "Authvar"))))))
(DFunDef false "freshInferenceAuthvar" ((PVar "mctx") PWild (PCon "Some" (PVar "source"))) (EApp (EApp (EApp (EApp (EVar "freshAuthvarRanged") (EVar "mctx")) (EApp (EVar "authvarDomain") (EVar "source"))) (EApp (EVar "authvarIsPattern") (EVar "source"))) (EApp (EVar "authvarName") (EVar "source"))))
(DFunDef false "freshInferenceAuthvar" ((PVar "mctx") (PVar "id") (PCon "None")) (EIf (EBinOp "&&" (EApp (EApp (EVar "IdMap.has") (EVar "id")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "patternAuthIdsRef") "value")) (EApp (EVar "not") (EApp (EApp (EVar "IdMap.has") (EVar "id")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "ctorExistentialsRef") "value")))) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "internal error: the pattern-ranging authority variable #")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "id")))) (ELit (LString " has no cell in the scheme that quantifies it, so its range would be lost at instantiation")))) (EApp (EApp (EApp (EVar "freshAuthvar") (EVar "mctx")) (EVar "PUnit")) (EVar "None"))))
(DTypeSig false "freeAuthvars" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "freeAuthvars" ((PVar "mctx") (PVar "t")) (EApp (EApp (EVar "generalizableAuthvars") (EVar "mctx")) (EApp (EVar "IdMap.values") (EApp (EApp (EVar "authCellsIn") (EVar "t")) (EVar "Tip")))))
(DTypeSig false "rowFreeAuthvars" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "EffRow") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "rowFreeAuthvars" ((PVar "mctx") (PVar "row")) (EApp (EApp (EVar "generalizableAuthvars") (EVar "mctx")) (EApp (EVar "IdMap.values") (EApp (EApp (EVar "authRowCells") (EVar "row")) (EVar "Tip")))))
(DTypeSig false "generalizableAuthvars" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "generalizableAuthvars" ((PVar "mctx") (PVar "cells")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "cell")) (EIf (EBinOp ">" (EApp (EVar "authvarLevel") (EVar "cell")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (EListLit (EApp (EVar "authvarId") (EVar "cell"))) (EListLit)))) (EVar "cells")))
(DTypeSig false "defaultSourcelessAuthorities" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyCon "EffRow") (TyFun (TyCon "Mono") (TyCon "Unit"))))))
(DFunDef false "defaultSourcelessAuthorities" ((PVar "mctx") (PVar "declared") (PVar "force") (PVar "t")) (EBlock (DoLet false false (PVar "sources") (EApp (EApp (EVar "qualifierAuthIds") (EVar "t")) (EVar "declared"))) (DoLet false false (PVar "candidates") (EApp (EVar "IdMap.values") (EApp (EApp (EVar "authCellsIn") (EVar "t")) (EApp (EApp (EVar "authRowCells") (EVar "force")) (EVar "Tip"))))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "cell")) (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "authvarLevel") (EVar "cell")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (EApp (EVar "not") (EApp (EApp (EVar "IdMap.has") (EApp (EVar "authvarId") (EVar "cell"))) (EVar "sources")))) (EApp (EApp (EVar "linkAuthvar") (EVar "cell")) (EApp (EVar "authTop") (EApp (EVar "authvarDomain") (EVar "cell")))) (ELit LUnit)))) (ELit LUnit)) (EVar "candidates")))))
(DTypeSig true "lowerAuthLevels" (TyFun (TyCon "Int") (TyFun (TyCon "Authority") (TyCon "Unit"))))
(DFunDef false "lowerAuthLevels" (PWild (PCon "AConst" PWild)) (ELit LUnit))
(DFunDef false "lowerAuthLevels" ((PVar "level") (PVar "q")) (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "AUnbound" (PVar "id") (PVar "lvl") (PVar "top") (PVar "pat") (PVar "name")) () (EIf (EBinOp ">" (EVar "lvl") (EVar "level")) (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EApp (EApp (EApp (EApp (EVar "AUnbound") (EVar "id")) (EVar "level")) (EVar "top")) (EVar "pat")) (EVar "name"))) (ELit LUnit))) (arm (PCon "ALink" PWild PWild PWild) () (ELit LUnit))))) (ELit LUnit)) (EApp (EVar "authVars") (EVar "q"))))
(DTypeSig true "freshTvMap" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))))
(DFunDef false "freshTvMap" ((PVar "mctx") (PList)) (EListLit))
(DFunDef false "freshTvMap" ((PVar "mctx") (PCons (PVar "n") (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit))) (EApp (EApp (EVar "freshTvMap") (EVar "mctx")) (EVar "rest"))))
(DTypeSig true "freshEffMap" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Effvar")))))))
(DFunDef false "freshEffMap" ((PVar "mctx") (PList)) (EListLit))
(DFunDef false "freshEffMap" ((PVar "mctx") (PCons (PVar "n") (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EVar "freshEffvar") (EVar "mctx")) (ELit LUnit))) (EApp (EApp (EVar "freshEffMap") (EVar "mctx")) (EVar "rest"))))
(DTypeSig true "freshAuthBinderRanged" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Authvar")))))))
(DFunDef false "freshAuthBinderRanged" ((PVar "mctx") (PVar "pat") (PTuple (PVar "n") (PVar "top"))) (ETuple (EVar "n") (EApp (EApp (EApp (EApp (EVar "freshAuthvarRanged") (EVar "mctx")) (EVar "top")) (EVar "pat")) (EApp (EVar "Some") (EVar "n")))))
(DTypeSig true "namedArgDomains" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "EffAtomTy"))))))
(DFunDef false "namedArgDomains" ((PCon "TyFun" (PCon "TyNamed" (PVar "n") PWild (PVar "d")) (PVar "b"))) (EBinOp "::" (ETuple (EVar "n") (EVar "d")) (EApp (EVar "namedArgDomains") (EVar "b"))))
(DFunDef false "namedArgDomains" ((PCon "TyFun" PWild (PVar "b"))) (EApp (EVar "namedArgDomains") (EVar "b")))
(DFunDef false "namedArgDomains" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "namedArgDomains") (EVar "t")))
(DFunDef false "namedArgDomains" (PWild) (EListLit))
(DTypeSig true "freshAuthvar" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Param") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Ref") (TyCon "Authvar"))))))
(DFunDef false "freshAuthvar" ((PVar "mctx") (PVar "top") (PVar "name")) (EApp (EApp (EApp (EApp (EVar "freshAuthvarRanged") (EVar "mctx")) (EVar "top")) (EVar "False")) (EVar "name")))
(DTypeSig true "freshAuthvarRanged" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Param") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Ref") (TyCon "Authvar")))))))
(DFunDef false "freshAuthvarRanged" ((PVar "mctx") (PVar "top") (PVar "pat") (PVar "name")) (EBlock (DoLet false false (PVar "id") (EApp (EApp (EVar "newEffvarId") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (DoExpr (EIf (EVar "pat") (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "patternAuthIdsRef")) (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (ELit LUnit)) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "patternAuthIdsRef") "value"))) (ELit LUnit))) (DoExpr (EApp (EVar "Ref") (EApp (EApp (EApp (EApp (EApp (EVar "AUnbound") (EVar "id")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (EVar "top")) (EVar "pat")) (EVar "name"))))))
(DTypeSig true "authSlotNamesIn" (TyFun (TyCon "ModuleCtx") (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyVar "a")))) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "authSlotNamesIn" ((PVar "mctx") (PVar "readSlots") (PCon "TyApp" (PVar "a") (PVar "b"))) (EMatch (EApp (EVar "tyAppSpine") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b"))) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false) (PVar "args")) () (EMatch (EApp (EApp (EVar "lookupTab") (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamKindsRef") "value")) (arm (PCon "Some" (PVar "kinds")) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EVar "kinds")) (EApp (EVar "listLen") (EVar "args"))))) (EBinOp "++" (EApp (EApp (EVar "readSlots") (EVar "kinds")) (EVar "args")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "authSlotNamesIn") (EVar "mctx")) (EVar "readSlots"))) (EVar "args")))) (arm PWild () (EBinOp "++" (EApp (EApp (EApp (EVar "authSlotNamesIn") (EVar "mctx")) (EVar "readSlots")) (EVar "a")) (EApp (EApp (EApp (EVar "authSlotNamesIn") (EVar "mctx")) (EVar "readSlots")) (EVar "b")))))) (arm PWild () (EBinOp "++" (EApp (EApp (EApp (EVar "authSlotNamesIn") (EVar "mctx")) (EVar "readSlots")) (EVar "a")) (EApp (EApp (EApp (EVar "authSlotNamesIn") (EVar "mctx")) (EVar "readSlots")) (EVar "b"))))))
(DFunDef false "authSlotNamesIn" ((PVar "mctx") (PVar "readSlots") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EApp (EVar "authSlotNamesIn") (EVar "mctx")) (EVar "readSlots")) (EVar "a")) (EApp (EApp (EApp (EVar "authSlotNamesIn") (EVar "mctx")) (EVar "readSlots")) (EVar "b"))))
(DFunDef false "authSlotNamesIn" ((PVar "mctx") (PVar "readSlots") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "authSlotNamesIn") (EVar "mctx")) (EVar "readSlots"))) (EVar "ts")))
(DFunDef false "authSlotNamesIn" ((PVar "mctx") (PVar "readSlots") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EApp (EVar "authSlotNamesIn") (EVar "mctx")) (EVar "readSlots")) (EVar "t")))
(DFunDef false "authSlotNamesIn" ((PVar "mctx") (PVar "readSlots") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EApp (EVar "authSlotNamesIn") (EVar "mctx")) (EVar "readSlots")) (EVar "t")))
(DFunDef false "authSlotNamesIn" ((PVar "mctx") (PVar "readSlots") (PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EApp (EApp (EVar "authSlotNamesIn") (EVar "mctx")) (EVar "readSlots")) (EVar "t")))
(DFunDef false "authSlotNamesIn" ((PVar "mctx") (PVar "readSlots") (PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EApp (EApp (EVar "authSlotNamesIn") (EVar "mctx")) (EVar "readSlots")) (EVar "t")))
(DFunDef false "authSlotNamesIn" ((PVar "mctx") PWild PWild) (EListLit))
(DTypeSig true "atomBindersIn" (TyFun (TyFun (TyCon "EffAtomTy") (TyApp (TyCon "List") (TyVar "a"))) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "atomBindersIn" (PWild (PCon "TyVar" PWild)) (EListLit))
(DFunDef false "atomBindersIn" (PWild (PRec "TyCon" ((rf "tyConName" PWild)) false)) (EListLit))
(DFunDef false "atomBindersIn" ((PVar "readAtom") (PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EVar "atomBindersIn") (EVar "readAtom")) (EVar "a")) (EApp (EApp (EVar "atomBindersIn") (EVar "readAtom")) (EVar "b"))))
(DFunDef false "atomBindersIn" ((PVar "readAtom") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EVar "atomBindersIn") (EVar "readAtom")) (EVar "a")) (EApp (EApp (EVar "atomBindersIn") (EVar "readAtom")) (EVar "b"))))
(DFunDef false "atomBindersIn" ((PVar "readAtom") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "atomBindersIn") (EVar "readAtom"))) (EVar "ts")))
(DFunDef false "atomBindersIn" ((PVar "readAtom") (PCon "TyEffect" (PVar "atoms") PWild (PVar "t"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "readAtom")) (EVar "atoms")) (EApp (EApp (EVar "atomBindersIn") (EVar "readAtom")) (EVar "t"))))
(DFunDef false "atomBindersIn" ((PVar "readAtom") (PCon "TyRow" (PVar "atoms") PWild PWild)) (EApp (EApp (EVar "flatMap") (EVar "readAtom")) (EVar "atoms")))
(DFunDef false "atomBindersIn" (PWild (PCon "TyAuth" PWild PWild)) (EListLit))
(DFunDef false "atomBindersIn" ((PVar "readAtom") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EVar "atomBindersIn") (EVar "readAtom")) (EVar "t")))
(DFunDef false "atomBindersIn" ((PVar "readAtom") (PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EApp (EVar "atomBindersIn") (EVar "readAtom")) (EVar "t")))
(DFunDef false "atomBindersIn" ((PVar "readAtom") (PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EApp (EVar "atomBindersIn") (EVar "readAtom")) (EVar "t")))
(DTypeSig false "defaultDeferredPatLitsIn" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "defaultDeferredPatLitsIn" ((PVar "dyn") (PVar "lvl") (PVar "t")) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "patLitDeferred") "value") (arm (PList) () (ELit LUnit)) (arm (PVar "deferred") () (EApp (EApp (EApp (EVar "defaultPatLitVarsIn") (EVar "dyn")) (EApp (EApp (EVar "freeGenVars") (EVar "lvl")) (EVar "t"))) (EVar "deferred")))))
(DTypeSig false "defaultPatLitVarsIn" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyCon "Unit")))))
(DFunDef false "defaultPatLitVarsIn" ((PVar "dyn") PWild (PList)) (ELit LUnit))
(DFunDef false "defaultPatLitVarsIn" ((PVar "dyn") (PVar "quantified") (PCons (PTuple (PVar "a") PWild PWild) (PVar "rest"))) (EBlock (DoExpr (EMatch (EApp (EVar "normalize") (EVar "a")) (arm (PCon "TVar" (PVar "cell")) () (EIf (EApp (EApp (EVar "containsI") (EApp (EVar "tyvarId") (EVar "cell"))) (EVar "quantified")) (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EApp (EVar "tconBuiltin") (ELit (LString "Int")))) (EVar "a")) (ELit LUnit))) (arm PWild () (ELit LUnit)))) (DoExpr (EApp (EApp (EApp (EVar "defaultPatLitVarsIn") (EVar "dyn")) (EVar "quantified")) (EVar "rest")))))
(DTypeSig true "unifyAll" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Unit")))))
(DFunDef false "unifyAll" ((PVar "dyn") PWild (PList)) (ELit LUnit))
(DFunDef false "unifyAll" ((PVar "dyn") (PVar "t") (PCons (PVar "x") (PVar "xs"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "t")) (EVar "x"))) (DoExpr (EApp (EApp (EApp (EVar "unifyAll") (EVar "dyn")) (EVar "t")) (EVar "xs")))))
(DTypeSig true "qualConstraintDecl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "CDeclared")))))
(DFunDef false "qualConstraintDecl" ((PVar "mctx") (PVar "name")) (EMatch (EApp (EApp (EVar "qualConstraintKey") (EVar "mctx")) (EVar "name")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple (PVar "src") (PVar "origin"))) () (EApp (EApp (EVar "map") (ELam ((PVar "slots")) (EApp (EApp (EApp (EApp (EVar "qualDeclOf") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "src")) (EVar "origin")) (EVar "slots")))) (EApp (EApp (EApp (EVar "lookupQualPayload") (EVar "src")) (EVar "origin")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "crossRun") "crossModuleFunPredicateSlotsQualRef") "value"))))))
(DTypeSig false "qualDeclOf" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PredicateSlot")) (TyCon "CDeclared"))))))
(DFunDef false "qualDeclOf" ((PVar "gctx") (PVar "src") (PVar "origin") (PVar "stored")) (EBlock (DoLet false false (PVar "slots") (EApp (EVar "predicateSlotCSlots") (EVar "stored"))) (DoExpr (ERecordCreate "CDeclared" ((fa "cdSlots" (EVar "slots")) (fa "cdPrefix" (EApp (EApp (EVar "clampPrefix") (EVar "slots")) (EApp (EApp (EApp (EVar "lookupQualPayload") (EVar "src")) (EVar "origin")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleFunConstraintDeclaredQualRef") "value")))) (fa "cdArgs" (EApp (EVar "predicateSlotArgs") (EVar "stored"))))))))
(DTypeSig true "qualConstraintKey" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "qualConstraintKey" ((PVar "mctx") (PVar "name")) (EApp (EApp (EVar "map") (ELam ((PVar "src")) (ETuple (EVar "src") (EApp (EApp (EVar "optionOr") (EVar "name")) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentImportOriginsRef") "value")))))) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentImportDefinersRef") "value"))))
(DTypeSig true "lookupQualPayload" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyVar "a"))) (TyApp (TyCon "Option") (TyVar "a"))))))
(DFunDef false "lookupQualPayload" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "lookupQualPayload" ((PVar "src") (PVar "name") (PCons (PTuple (PTuple (PVar "m") (PVar "n")) (PVar "v")) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "m") (EVar "src")) (EBinOp "==" (EVar "n") (EVar "name"))) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "lookupQualPayload") (EVar "src")) (EVar "name")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "clampPrefix" (TyFun (TyApp (TyCon "List") (TyCon "CSlot")) (TyFun (TyApp (TyCon "Option") (TyCon "CDeclaredPrefix")) (TyCon "CDeclaredPrefix"))))
(DFunDef false "clampPrefix" (PWild (PCon "None")) (EVar "CDPUnknown"))
(DFunDef false "clampPrefix" (PWild (PCon "Some" (PCon "CDPUnknown"))) (EVar "CDPUnknown"))
(DFunDef false "clampPrefix" ((PVar "slots") (PCon "Some" (PCon "CDPLen" (PVar "k")))) (EApp (EVar "CDPLen") (EApp (EApp (EVar "minI") (EVar "k")) (EApp (EVar "listLen") (EVar "slots")))))
(DTypeSig true "instantiateTracked" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Scheme") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))))))
(DFunDef false "instantiateTracked" ((PVar "mctx") (PVar "scheme")) (EBlock (DoLet false false (PVar "inst") (EApp (EApp (EVar "instantiateMethodTracked") (EVar "mctx")) (EVar "scheme"))) (DoExpr (ETuple (EFieldAccess (EVar "inst") "mtiBody") (EFieldAccess (EFieldAccess (EVar "inst") "mtiSubstitution") "misTypeSubst")))))
(DTypeSig true "instantiateMethodTracked" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Scheme") (TyCon "MethodTrackedInstantiation"))))
(DFunDef false "instantiateMethodTracked" ((PVar "mctx") (PCon "Forall" (PVar "ids") (PVar "evars") (PVar "avars") (PVar "residual") (PVar "force") (PVar "body"))) (EBlock (DoLet false false (PVar "typeSubst") (EApp (EApp (EVar "freshSubst") (EVar "mctx")) (EVar "ids"))) (DoLet false false (PVar "effectSubst") (EApp (EApp (EVar "freshEffSubst") (EVar "mctx")) (EVar "evars"))) (DoLet false false (PVar "authSubst") (EApp (EApp (EApp (EApp (EVar "freshAuthSubstFor") (EVar "mctx")) (EVar "avars")) (EVar "body")) (EVar "force"))) (DoExpr (ERecordCreate "MethodTrackedInstantiation" ((fa "mtiBody" (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "typeSubst")) (EVar "effectSubst")) (EVar "authSubst")) (EVar "body"))) (fa "mtiForce" (EApp (EApp (EApp (EApp (EVar "substRow") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "effectSubst")) (EVar "authSubst")) (EVar "force"))) (fa "mtiResidual" (EApp (EApp (EVar "map") (ELam ((PVar "r")) (ERecordCreate "AuthResidual" ((fa "arLower" (EApp (EApp (EVar "substAuth") (EVar "authSubst")) (EFieldAccess (EVar "r") "arLower"))) (fa "arUpper" (EApp (EApp (EVar "substAuth") (EVar "authSubst")) (EFieldAccess (EVar "r") "arUpper"))) (fa "arExact" (EFieldAccess (EVar "r") "arExact")))))) (EVar "residual"))) (fa "mtiSubstitution" (ERecordCreate "MethodInstantiationSubst" ((fa "misTypeSubst" (EVar "typeSubst")) (fa "misEffectSubst" (EVar "effectSubst")) (fa "misAuthSubst" (EVar "authSubst"))))))))))
(DTypeSig true "forceInstantiation" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "MethodTrackedInstantiation") (TyCon "Mono")))))
(DFunDef false "forceInstantiation" ((PVar "mctx") (PVar "name") (PVar "inst")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "performEffect") (EVar "mctx")) (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "curEffect")) (EFieldAccess (EVar "inst") "mtiForce"))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "r")) (EApp (EApp (EApp (EApp (EApp (EVar "wantAuthorityFrom") (EVar "mctx")) (EApp (EVar "Some") (EVar "name"))) (EFieldAccess (EVar "r") "arExact")) (EFieldAccess (EVar "r") "arLower")) (EFieldAccess (EVar "r") "arUpper")))) (ELit LUnit)) (EFieldAccess (EVar "inst") "mtiResidual"))) (DoExpr (EFieldAccess (EVar "inst") "mtiBody"))))
(DTypeSig true "instantiateValueTracked" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Scheme") (TyCon "MethodTrackedInstantiation")))))
(DFunDef false "instantiateValueTracked" ((PVar "mctx") (PVar "name") (PVar "scheme")) (EBlock (DoLet false false (PVar "inst") (EApp (EApp (EVar "instantiateMethodTracked") (EVar "mctx")) (EVar "scheme"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "forceInstantiation") (EVar "mctx")) (EVar "name")) (EVar "inst"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "grants") "gsLastInst")) (EApp (EVar "Some") (ETuple (EVar "scheme") (EFieldAccess (EFieldAccess (EVar "inst") "mtiSubstitution") "misAuthSubst"))))) (DoExpr (EVar "inst"))))
(DTypeSig true "zipSlotVecs" (TyFun (TyApp (TyCon "List") (TyCon "CSlot")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "CSlot") (TyApp (TyCon "List") (TyCon "Mono")))))))
(DFunDef false "zipSlotVecs" ((PList) PWild) (EListLit))
(DFunDef false "zipSlotVecs" ((PCons (PVar "s") (PVar "rest")) (PList)) (EBinOp "::" (ETuple (EVar "s") (EListLit)) (EApp (EApp (EVar "zipSlotVecs") (EVar "rest")) (EListLit))))
(DFunDef false "zipSlotVecs" ((PCons (PVar "s") (PVar "rest")) (PCons (PVar "v") (PVar "vs"))) (EBinOp "::" (ETuple (EVar "s") (EVar "v")) (EApp (EApp (EVar "zipSlotVecs") (EVar "rest")) (EVar "vs"))))
(DTypeSig true "noteNumlitCtx" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyFun (TyCon "JoinContext") (TyCon "Unit"))))))
(DFunDef false "noteNumlitCtx" ((PVar "mctx") (PVar "a") (PVar "b") (PVar "kind")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "tagNumlitCtxIf") (EVar "mctx")) (EVar "a")) (EVar "b")) (EVar "kind"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "tagNumlitCtxIf") (EVar "mctx")) (EVar "b")) (EVar "a")) (EVar "kind")))))
(DTypeSig false "tagNumlitCtxIf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyFun (TyCon "JoinContext") (TyCon "Unit"))))))
(DFunDef false "tagNumlitCtxIf" ((PVar "mctx") (PVar "v") (PVar "other") (PVar "kind")) (EIf (EApp (EVar "isSome") (EApp (EVar "headTyconMono") (EVar "other"))) (EApp (EApp (EApp (EVar "tagAllLitLocs") (EVar "mctx")) (EVar "v")) (EVar "kind")) (EIf (EVar "otherwise") (ELit LUnit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "tagAllLitLocs" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "JoinContext") (TyCon "Unit")))))
(DFunDef false "tagAllLitLocs" ((PVar "mctx") (PVar "v") (PVar "kind")) (EMatch (EApp (EVar "normalize") (EVar "v")) (arm (PCon "TVar" (PVar "cell")) () (EApp (EApp (EApp (EApp (EVar "tagLitLocsWithRoot") (EVar "mctx")) (EApp (EVar "tyvarId") (EVar "cell"))) (EVar "kind")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitVarLocs") "value"))) (arm PWild () (ELit LUnit))))
(DTypeSig false "tagLitLocsWithRoot" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyFun (TyCon "JoinContext") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Loc"))) (TyCon "Unit"))))))
(DFunDef false "tagLitLocsWithRoot" ((PVar "mctx") PWild PWild (PList)) (ELit LUnit))
(DFunDef false "tagLitLocsWithRoot" ((PVar "mctx") (PVar "id") (PVar "kind") (PCons (PTuple (PVar "mv") (PVar "l")) (PVar "rest"))) (EBlock (DoExpr (EIf (EApp (EApp (EVar "sameRootId") (EVar "id")) (EVar "mv")) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitCtxTags")) (EBinOp "::" (ETuple (EVar "l") (EVar "kind")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitCtxTags") "value"))) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EVar "tagLitLocsWithRoot") (EVar "mctx")) (EVar "id")) (EVar "kind")) (EVar "rest")))))
(DTypeSig true "calleeArrow" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyTuple (TyCon "Mono") (TyCon "EffRow") (TyCon "Mono")))))
(DFunDef false "calleeArrow" ((PVar "dyn") (PVar "ft")) (EMatch (EApp (EVar "normalize") (EVar "ft")) (arm (PCon "TFun" (PVar "dom") (PVar "row") (PVar "res")) () (ETuple (EVar "dom") (EVar "row") (EVar "res"))) (arm PWild () (EBlock (DoLet false false (PVar "dom") (EApp (EApp (EVar "freshVar") (EFieldAccess (EVar "dyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "row") (EApp (EApp (EVar "openRow") (EFieldAccess (EVar "dyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "res") (EApp (EApp (EVar "freshVar") (EFieldAccess (EVar "dyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "ft")) (EApp (EApp (EApp (EVar "TFun") (EVar "dom")) (EVar "row")) (EVar "res")))) (DoExpr (ETuple (EVar "dom") (EVar "row") (EVar "res")))))))
(DTypeSig true "refStored" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyCon "Mono"))))
(DFunDef false "refStored" ((PVar "dyn") (PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TApp" (PCon "TCon" (PLit (LString "Ref")) PWild) (PVar "inner")) () (EVar "inner")) (arm PWild () (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "freshVar") (EFieldAccess (EVar "dyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "t")) (EApp (EApp (EVar "TApp") (EApp (EVar "tconBuiltin") (ELit (LString "Ref")))) (EVar "inner")))) (DoExpr (EVar "inner"))))))
(DTypeSig true "instantiateLegacyVarTracked" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Scheme") (TyCon "MethodTrackedInstantiation"))))))
(DFunDef false "instantiateLegacyVarTracked" ((PVar "mctx") (PVar "x") (PVar "id") (PVar "s")) (EMatch (EApp (EApp (EApp (EVar "lookupSchemeObls") (EVar "x")) (EVar "id")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "schemeObligationsRef") "value")) (arm (PCon "Some" (PVar "obs")) () (EBlock (DoLet false false (PVar "inst") (EApp (EApp (EApp (EVar "instantiateValueTracked") (EVar "mctx")) (EVar "x")) (EVar "s"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordSchemeCallObligations") (EVar "mctx")) (EVar "id")) (EVar "obs")) (EFieldAccess (EFieldAccess (EVar "inst") "mtiSubstitution") "misTypeSubst"))) (DoExpr (EVar "inst")))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "declaredCrossModuleObls") (EVar "mctx")) (EVar "x")) (arm (PCon "Some" (PVar "obs")) () (EBlock (DoLet false false (PVar "inst") (EApp (EApp (EApp (EVar "instantiateValueTracked") (EVar "mctx")) (EVar "x")) (EVar "s"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordSchemeCallObligations") (EVar "mctx")) (EVar "id")) (EVar "obs")) (EFieldAccess (EFieldAccess (EVar "inst") "mtiSubstitution") "misTypeSubst"))) (DoExpr (EVar "inst")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "instantiateValueTracked") (EVar "mctx")) (EVar "x")) (EVar "s")))))))
(DTypeSig true "declaredCrossModuleObls" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "VecObl"))))))
(DFunDef false "declaredCrossModuleObls" ((PVar "mctx") (PVar "x")) (EMatch (EApp (EApp (EVar "qualConstraintDecl") (EVar "mctx")) (EVar "x")) (arm (PCon "Some" (PVar "d")) () (EApp (EVar "Some") (EApp (EVar "vecOblsOfSlotVecs") (EApp (EApp (EVar "zipSlotVecs") (EFieldAccess (EVar "d") "cdSlots")) (EFieldAccess (EVar "d") "cdArgs"))))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "qualSchemeOblsFor") (EVar "mctx")) (EVar "x")) (arm (PCon "Some" (PVar "obs")) () (EApp (EVar "Some") (EVar "obs"))) (arm (PCon "None") () (EApp (EApp (EVar "omLookup") (EVar "x")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "crossRun") "coreSchemeObligationsRef") "value")))))))
(DTypeSig false "qualSchemeOblsFor" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "VecObl"))))))
(DFunDef false "qualSchemeOblsFor" ((PVar "mctx") (PVar "name")) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "importedSchemeOblsRef") "value")))
(DTypeSig false "vecOblsOfSlotVecs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "CSlot") (TyApp (TyCon "List") (TyCon "Mono")))) (TyApp (TyCon "List") (TyCon "VecObl"))))
(DFunDef false "vecOblsOfSlotVecs" ((PList)) (EListLit))
(DFunDef false "vecOblsOfSlotVecs" ((PCons (PTuple (PVar "s") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EFieldAccess (EFieldAccess (EVar "s") "csIface") "irName") (ELit (LString ""))) (EApp (EVar "vecOblsOfSlotVecs") (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "xmodVecObl") (EVar "s")) (EVar "v")) (EApp (EVar "vecOblsOfSlotVecs") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "xmodVecObl" (TyFun (TyCon "CSlot") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "VecObl"))))
(DFunDef false "xmodVecObl" ((PVar "s") (PVar "v")) (EIf (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "v")) (EApp (EVar "isEmptyL") (EApp (EApp (EVar "flatMap") (EVar "xmodOblArgId")) (EVar "v")))) (ERecordCreate "VecObl" ((fa "voIface" (EFieldAccess (EVar "s") "csIface")) (fa "voIds" (EListLit (EFieldAccess (EVar "s") "csId"))) (fa "voArgs" (EListLit)))) (EIf (EVar "otherwise") (ERecordCreate "VecObl" ((fa "voIface" (EFieldAccess (EVar "s") "csIface")) (fa "voIds" (EApp (EApp (EVar "flatMap") (EVar "xmodOblArgId")) (EVar "v"))) (fa "voArgs" (EVar "v")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "recordSchemeCallObligations" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "VecObl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyCon "Unit"))))))
(DFunDef false "recordSchemeCallObligations" ((PVar "mctx") PWild (PList) PWild) (ELit LUnit))
(DFunDef false "recordSchemeCallObligations" ((PVar "mctx") (PVar "originId") (PCons (PVar "o") (PVar "rest")) (PVar "subst")) (EMatch (EApp (EApp (EVar "substVecOblArgs") (EVar "o")) (EVar "subst")) (arm (PCon "Some" (PVar "monos")) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordObl") (EVar "mctx")) (ERecordCreate "Predicate" ((fa "iface" (EFieldAccess (EVar "o") "voIface")) (fa "args" (EVar "monos"))))) (EVar "originId")) (EVar "PSchemeReinst")) (EFieldAccess (EVar "mctx") "mcLoc"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordSchemeCallObligations") (EVar "mctx")) (EVar "originId")) (EVar "rest")) (EVar "subst"))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "recordSchemeCallObligations") (EVar "mctx")) (EVar "originId")) (EVar "rest")) (EVar "subst")))))
(DTypeSig false "substVecOblArgs" (TyFun (TyCon "VecObl") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Mono"))))))
(DFunDef false "substVecOblArgs" ((PVar "o") (PVar "subst")) (EIf (EApp (EVar "isEmptyL") (EFieldAccess (EVar "o") "voArgs")) (EApp (EApp (EVar "substMonos") (EFieldAccess (EVar "o") "voIds")) (EVar "subst")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "substOblArgs") (EFieldAccess (EVar "o") "voIds")) (EFieldAccess (EVar "o") "voArgs")) (EVar "subst")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "lookupSchemeObls" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "VecObl")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "VecObl")))))))
(DFunDef false "lookupSchemeObls" ((PVar "x") (PLit (LInt 0)) (PVar "table")) (EApp (EApp (EVar "lookupSchemeOblsByName") (EVar "x")) (EVar "table")))
(DFunDef false "lookupSchemeObls" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "lookupSchemeObls" ((PVar "x") (PVar "id") (PCons (PTuple (PTuple (PVar "n2") (PVar "i2")) (PVar "v")) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "n2") (EVar "x")) (EBinOp "==" (EVar "i2") (EVar "id"))) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "lookupSchemeObls") (EVar "x")) (EVar "id")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "lookupSchemeOblsByName" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "VecObl")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "VecObl"))))))
(DFunDef false "lookupSchemeOblsByName" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupSchemeOblsByName" ((PVar "x") (PCons (PTuple (PTuple (PVar "n2") PWild) (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n2") (EVar "x")) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupSchemeOblsByName") (EVar "x")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "unifySpineProbe" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Unit")))))
(DFunDef false "unifySpineProbe" ((PVar "dyn") (PVar "ft") (PVar "args")) (EBlock (DoLet false false (PVar "saved") (EApp (EVar "wSnapshot") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "fileValueFlows"))) (DoExpr (EApp (EApp (EApp (EVar "unifySpineProbeGo") (EVar "dyn")) (EVar "ft")) (EVar "args"))) (DoExpr (EApp (EApp (EVar "wRestore") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "fileValueFlows")) (EVar "saved")))))
(DTypeSig false "unifySpineProbeGo" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Unit")))))
(DFunDef false "unifySpineProbeGo" ((PVar "dyn") PWild (PList)) (ELit LUnit))
(DFunDef false "unifySpineProbeGo" ((PVar "dyn") (PVar "ft") (PCons (PVar "a") (PVar "rest"))) (EBlock (DoLet false false (PVar "r") (EApp (EApp (EVar "freshVar") (EFieldAccess (EVar "dyn") "dcModule")) (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "applicationRowTyped") (EVar "dyn")) (EVar "ft")) (EVar "a")) (EVar "r"))) (DoExpr (EApp (EApp (EApp (EVar "unifySpineProbeGo") (EVar "dyn")) (EVar "r")) (EVar "rest")))))
(DTypeSig true "unifyInto" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Bool") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit"))))))
(DFunDef false "unifyInto" ((PVar "dyn") (PVar "pos") (PVar "e") (PVar "a")) (EApp (EApp (EApp (EApp (EApp (EVar "unifyIntoOrd") (EVar "dyn")) (EVar "False")) (EVar "pos")) (EVar "e")) (EVar "a")))
(DTypeSig true "unifyIntoOrd" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))))
(DFunDef false "unifyIntoOrd" ((PVar "dyn") (PVar "valueFirst") (PVar "pos") (PVar "e") (PVar "a")) (EBlock (DoExpr (EIf (EBinOp "||" (EApp (EVar "monoHasArrowInSlot") (EVar "e")) (EApp (EVar "monoHasArrowInSlot") (EVar "a"))) (EIf (EVar "pos") (EApp (EApp (EApp (EApp (EVar "recordFileValueFlow") (EFieldAccess (EVar "dyn") "dcModule")) (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcLoc")) (EVar "e")) (EVar "a")) (EApp (EApp (EApp (EApp (EVar "recordFileValueFlow") (EFieldAccess (EVar "dyn") "dcModule")) (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcLoc")) (EVar "a")) (EVar "e"))) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "unifyIntoStep") (EVar "dyn")) (EVar "valueFirst")) (EVar "pos")) (EVar "e")) (EVar "a")))))
(DTypeSig false "unifyIntoStep" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))))
(DFunDef false "unifyIntoStep" ((PVar "dyn") (PVar "valueFirst") (PVar "pos") (PVar "e") (PVar "a")) (EApp (EApp (EApp (EApp (EApp (EVar "unifyIntoN") (EVar "dyn")) (EVar "valueFirst")) (EVar "pos")) (EApp (EVar "normalize") (EVar "e"))) (EApp (EVar "normalize") (EVar "a"))))
(DTypeSig false "unifyIntoN" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))))
(DFunDef false "unifyIntoN" ((PVar "dyn") PWild (PCon "True") (PCon "TVar" (PVar "cell")) (PAs "lower" (PCon "TFun" PWild PWild PWild))) (EApp (EApp (EApp (EVar "bindValueUpper") (EVar "dyn")) (EVar "cell")) (EVar "lower")))
(DFunDef false "unifyIntoN" ((PVar "dyn") PWild (PCon "True") (PCon "TVar" (PVar "cell")) (PAs "lower" (PCon "TApp" PWild PWild))) (EApp (EApp (EApp (EVar "bindValueUpper") (EVar "dyn")) (EVar "cell")) (EVar "lower")))
(DFunDef false "unifyIntoN" ((PVar "dyn") PWild (PCon "False") (PAs "lower" (PCon "TFun" PWild PWild PWild)) (PCon "TVar" (PVar "cell"))) (EApp (EApp (EApp (EVar "bindValueUpper") (EVar "dyn")) (EVar "cell")) (EVar "lower")))
(DFunDef false "unifyIntoN" ((PVar "dyn") PWild (PCon "False") (PAs "lower" (PCon "TApp" PWild PWild)) (PCon "TVar" (PVar "cell"))) (EApp (EApp (EApp (EVar "bindValueUpper") (EVar "dyn")) (EVar "cell")) (EVar "lower")))
(DFunDef false "unifyIntoN" ((PVar "dyn") PWild (PCon "True") (PCon "TVar" (PVar "cell")) (PAs "lower" (PCon "TQual" PWild PWild))) (EApp (EApp (EApp (EVar "bindValueUpper") (EVar "dyn")) (EVar "cell")) (EVar "lower")))
(DFunDef false "unifyIntoN" ((PVar "dyn") PWild (PCon "False") (PAs "lower" (PCon "TQual" PWild PWild)) (PCon "TVar" (PVar "cell"))) (EApp (EApp (EApp (EVar "bindValueUpper") (EVar "dyn")) (EVar "cell")) (EVar "lower")))
(DFunDef false "unifyIntoN" ((PVar "dyn") PWild PWild (PCon "TVar" (PVar "cell")) (PAs "t" (PCon "TQual" PWild PWild))) (EApp (EApp (EApp (EVar "bindVar") (EVar "dyn")) (EVar "cell")) (EVar "t")))
(DFunDef false "unifyIntoN" ((PVar "dyn") PWild PWild (PAs "t" (PCon "TQual" PWild PWild)) (PCon "TVar" (PVar "cell"))) (EApp (EApp (EApp (EVar "bindVar") (EVar "dyn")) (EVar "cell")) (EVar "t")))
(DFunDef false "unifyIntoN" ((PVar "dyn") (PVar "vf") (PVar "pos") (PCon "TQual" (PVar "e") (PVar "qe")) (PCon "TQual" (PVar "a") (PVar "qa"))) (EBlock (DoExpr (EIf (EVar "pos") (EApp (EApp (EApp (EVar "wantAuthority") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "qa")) (EVar "qe")) (EApp (EApp (EApp (EVar "wantAuthority") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "qe")) (EVar "qa")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "unifyIntoStep") (EVar "dyn")) (EVar "vf")) (EVar "pos")) (EVar "e")) (EVar "a")))))
(DFunDef false "unifyIntoN" ((PVar "dyn") (PVar "vf") (PVar "pos") (PCon "TQual" (PVar "e") (PVar "qe")) (PVar "a")) (EBlock (DoExpr (EIf (EVar "pos") (EApp (EApp (EApp (EVar "wantAuthority") (EFieldAccess (EVar "dyn") "dcModule")) (EApp (EVar "authTop") (EApp (EVar "authDomainTop") (EVar "qe")))) (EVar "qe")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "unifyIntoStep") (EVar "dyn")) (EVar "vf")) (EVar "pos")) (EVar "e")) (EVar "a")))))
(DFunDef false "unifyIntoN" ((PVar "dyn") (PVar "vf") (PVar "pos") (PVar "e") (PCon "TQual" (PVar "a") (PVar "qa"))) (EBlock (DoExpr (EIf (EVar "pos") (ELit LUnit) (EApp (EApp (EApp (EVar "wantAuthority") (EFieldAccess (EVar "dyn") "dcModule")) (EApp (EVar "authTop") (EApp (EVar "authDomainTop") (EVar "qa")))) (EVar "qa")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "unifyIntoStep") (EVar "dyn")) (EVar "vf")) (EVar "pos")) (EVar "e")) (EVar "a")))))
(DFunDef false "unifyIntoN" ((PVar "dyn") PWild PWild (PCon "TAuth" (PVar "qe")) (PCon "TAuth" (PVar "qa"))) (EApp (EApp (EApp (EVar "unifyIndex") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "qa")) (EVar "qe")))
(DFunDef false "unifyIntoN" ((PVar "dyn") (PVar "vf") (PVar "pos") (PCon "TFun" (PVar "e1") (PVar "er") (PVar "e2")) (PCon "TFun" (PVar "a1") (PVar "ar") (PVar "a2"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "unifyIntoStep") (EVar "dyn")) (EVar "vf")) (EApp (EVar "not") (EVar "pos"))) (EVar "e1")) (EVar "a1"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "rowInto") (EVar "dyn")) (EVar "pos")) (EApp (EVar "effrowNorm") (EVar "er"))) (EApp (EVar "effrowNorm") (EVar "ar")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "unifyIntoStep") (EVar "dyn")) (EVar "vf")) (EVar "pos")) (EVar "e2")) (EVar "a2")))))
(DFunDef false "unifyIntoN" ((PVar "dyn") (PVar "vf") (PVar "pos") (PAs "e" (PCon "TApp" (PVar "e1") (PVar "e2"))) (PAs "a" (PCon "TApp" (PVar "a1") (PVar "a2")))) (EIf (EBinOp "||" (EApp (EApp (EVar "tupleUnifyClash") (EVar "e")) (EVar "a")) (EApp (EApp (EVar "monoSlotNonCovariant") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "e1"))) (EApp (EApp (EApp (EApp (EVar "unifyOrdered") (EVar "dyn")) (EVar "vf")) (EVar "e")) (EVar "a")) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "unifyIntoStep") (EVar "dyn")) (EVar "vf")) (EVar "pos")) (EVar "e1")) (EVar "a1"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "unifyIntoStep") (EVar "dyn")) (EVar "vf")) (EVar "pos")) (EVar "e2")) (EVar "a2")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "unifyIntoN" ((PVar "dyn") (PVar "vf") PWild (PVar "e") (PVar "a")) (EApp (EApp (EApp (EApp (EVar "unifyOrdered") (EVar "dyn")) (EVar "vf")) (EVar "e")) (EVar "a")))
(DTypeSig false "bindValueUpper" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "Ref") (TyCon "Tyvar")) (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "bindValueUpper" ((PVar "dyn") (PVar "cell") (PVar "lower")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "occursCheckFailed")) (EVar "False"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "occursAdjust") (EFieldAccess (EVar "dyn") "dcModule")) (EApp (EVar "tyvarId") (EVar "cell"))) (EApp (EVar "tyvarLevel") (EVar "cell"))) (EVar "lower"))) (DoExpr (EIf (EApp (EVar "not") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "occursCheckFailed") "value")) (EBlock (DoLet false false (PVar "upper") (EApp (EApp (EVar "optionOrFresh") (EFieldAccess (EVar "dyn") "dcModule")) (EApp (EApp (EVar "joinProducedEnvelope") (EApp (EApp (EApp (EVar "valueJoinOps") (EVar "dyn")) (EVar "JoinArgument")) (EVar "collectValueAllowance"))) (EListLit (ETuple (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcLoc") (EVar "lower")))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordFileValueFlow") (EFieldAccess (EVar "dyn") "dcModule")) (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcLoc")) (EVar "upper")) (EVar "lower"))) (DoExpr (EApp (EApp (EApp (EVar "bindVar") (EVar "dyn")) (EVar "cell")) (EVar "upper")))) (ELit LUnit)))))
(DTypeSig false "collectValueAllowance" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "List") (TyCon "EffRow")) (TyCon "EffRow"))))
(DFunDef false "collectValueAllowance" ((PVar "dyn") (PVar "rows")) (EBlock (DoLet false false (PVar "cell") (EApp (EApp (EVar "freshInferenceEffvar") (EFieldAccess (EVar "dyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "EffectSolver.registerValueAllowance") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "effectSummaries")) (EVar "cell"))) (DoLet false false (PVar "upper") (EApp (EApp (EVar "EffRow") (EListLit)) (EApp (EVar "Some") (EVar "cell")))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "lower")) (EApp (EApp (EApp (EApp (EVar "rowInto") (EVar "dyn")) (EVar "True")) (EVar "upper")) (EVar "lower")))) (ELit LUnit)) (EVar "rows"))) (DoExpr (EVar "upper"))))
(DTypeSig false "unifyOrdered" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Bool") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit"))))))
(DFunDef false "unifyOrdered" ((PVar "dyn") (PCon "True") (PVar "e") (PVar "a")) (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "a")) (EVar "e")))
(DFunDef false "unifyOrdered" ((PVar "dyn") (PCon "False") (PVar "e") (PVar "a")) (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "e")) (EVar "a")))
(DTypeSig true "rowInto" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Bool") (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Unit"))))))
(DFunDef false "rowInto" ((PVar "dyn") (PVar "pos") (PVar "er") (PVar "ar")) (EIf (EApp (EVar "EffectSolver.hasSummaryScope") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "effectSummaries")) (EIf (EVar "pos") (EApp (EApp (EApp (EApp (EVar "deferEffectRelation") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "False")) (EVar "ar")) (EVar "er")) (EApp (EApp (EApp (EApp (EVar "deferEffectRelation") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "False")) (EVar "er")) (EVar "ar"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "rowInto" ((PVar "dyn") (PCon "True") (PCon "EffRow" (PVar "le") (PCon "None")) (PCon "EffRow" (PVar "la") (PCon "None"))) (EApp (EApp (EApp (EVar "effectLeakCheck") (EFieldAccess (EVar "dyn") "dcModule")) (EApp (EApp (EApp (EVar "atomsEscape") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph")) (EVar "la")) (EVar "le"))) (EVar "le")))
(DFunDef false "rowInto" ((PVar "dyn") (PCon "False") (PCon "EffRow" (PVar "le") (PCon "None")) (PCon "EffRow" (PVar "la") (PCon "None"))) (EApp (EApp (EApp (EApp (EVar "contraRowCheck") (EFieldAccess (EVar "dyn") "dcModule")) (EApp (EApp (EApp (EVar "atomsEscape") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph")) (EVar "le")) (EVar "la"))) (EVar "le")) (EVar "la")))
(DFunDef false "rowInto" ((PVar "dyn") (PCon "True") (PAs "er" (PCon "EffRow" (PVar "le") PWild)) (PAs "ar" (PCon "EffRow" (PVar "la") (PCon "None")))) (EIf (EApp (EVar "isEmptyL") (EApp (EApp (EApp (EVar "atomsEscape") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph")) (EVar "la")) (EVar "le"))) (ELit LUnit) (EApp (EApp (EApp (EVar "unifyRowN") (EVar "dyn")) (EVar "er")) (EVar "ar"))))
(DFunDef false "rowInto" ((PVar "dyn") (PCon "False") (PAs "er" (PCon "EffRow" (PVar "le") (PCon "None"))) (PAs "ar" (PCon "EffRow" (PVar "la") PWild))) (EIf (EApp (EVar "isEmptyL") (EApp (EApp (EApp (EVar "atomsEscape") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph")) (EVar "le")) (EVar "la"))) (ELit LUnit) (EApp (EApp (EApp (EVar "unifyRowN") (EVar "dyn")) (EVar "er")) (EVar "ar"))))
(DFunDef false "rowInto" ((PVar "dyn") PWild (PVar "er") (PVar "ar")) (EApp (EApp (EApp (EVar "unifyRowN") (EVar "dyn")) (EVar "er")) (EVar "ar")))
(DTypeSig false "contraRowCheck" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "Unit"))))))
(DFunDef false "contraRowCheck" ((PVar "mctx") (PList) PWild PWild) (ELit LUnit))
(DFunDef false "contraRowCheck" ((PVar "mctx") (PVar "extras") (PVar "le") (PVar "la")) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-EFFECT-LEAK"))) (EApp (EApp (EApp (EVar "contraRowMsg") (EVar "le")) (EVar "la")) (EVar "extras"))))
(DTypeSig true "monoHasNonCovariantSlot" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyCon "Bool"))))
(DFunDef false "monoHasNonCovariantSlot" ((PVar "mctx") (PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "monoSlotNonCovariant") (EVar "mctx")) (EVar "a")) (EApp (EApp (EVar "monoHasNonCovariantSlot") (EVar "mctx")) (EVar "a"))) (EApp (EApp (EVar "monoHasNonCovariantSlot") (EVar "mctx")) (EVar "b")))) (arm (PCon "TFun" (PVar "a") PWild (PVar "b")) () (EBinOp "||" (EApp (EApp (EVar "monoHasNonCovariantSlot") (EVar "mctx")) (EVar "a")) (EApp (EApp (EVar "monoHasNonCovariantSlot") (EVar "mctx")) (EVar "b")))) (arm PWild () (EVar "False"))))
(DTypeSig false "monoSlotNonCovariant" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyCon "Bool"))))
(DFunDef false "monoSlotNonCovariant" ((PVar "mctx") (PVar "hd")) (EMatch (EApp (EVar "headTyconMono") (EVar "hd")) (arm (PCon "Some" (PCon "HkDecl" (PVar "key"))) () (EMatch (EApp (EApp (EVar "paramPolaritiesOf") (EVar "mctx")) (EVar "key")) (arm (PCon "Some" (PVar "pols")) () (EMatch (EApp (EApp (EVar "polarityAt") (EVar "pols")) (EApp (EVar "monoSpineDepth") (EVar "hd"))) (arm (PCon "PCo") () (EVar "False")) (arm PWild () (EVar "True")))) (arm (PCon "None") () (EVar "False")))) (arm PWild () (EVar "False"))))
(DTypeSig true "unifyParamsExpected" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Unit")))))
(DFunDef false "unifyParamsExpected" ((PVar "dyn") (PCons (PVar "p") (PVar "ps")) (PCons (PVar "e") (PVar "es"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "bindFrom") (EVar "dyn")) (EVar "p")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EVar "unifyParamsExpected") (EVar "dyn")) (EVar "ps")) (EVar "es")))))
(DFunDef false "unifyParamsExpected" ((PVar "dyn") PWild PWild) (ELit LUnit))
(DTypeSig true "applicationRowTyped" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "EffRow"))))))
(DFunDef false "applicationRowTyped" ((PVar "dyn") (PVar "ft") (PVar "xt") (PVar "result")) (EMatch (EApp (EVar "normalize") (EVar "ft")) (arm (PCon "TFun" (PVar "dom") (PVar "row") (PVar "res")) () (EBlock (DoExpr (EApp (EApp (EApp (EVar "argumentIntoTyped") (EVar "dyn")) (EVar "dom")) (EVar "xt"))) (DoExpr (EApp (EApp (EApp (EVar "bindFrom") (EVar "dyn")) (EVar "result")) (EVar "res"))) (DoExpr (EVar "row")))) (arm PWild () (EBlock (DoLet false false (PVar "unknown") (EApp (EApp (EVar "openRow") (EFieldAccess (EVar "dyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "ft")) (EApp (EApp (EApp (EVar "TFun") (EVar "xt")) (EVar "unknown")) (EVar "result")))) (DoExpr (EVar "unknown"))))))
(DTypeSig false "argumentIntoTyped" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "argumentIntoTyped" ((PVar "dyn") (PVar "dom") (PVar "xt")) (EMatch (EApp (EVar "normalize") (EVar "dom")) (arm (PCon "TQual" (PVar "d") (PVar "q")) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "unifyInto") (EVar "dyn")) (EVar "True")) (EVar "d")) (EVar "xt"))) (DoExpr (EApp (EApp (EApp (EVar "wantAuthority") (EFieldAccess (EVar "dyn") "dcModule")) (EApp (EApp (EVar "typeAuthority") (EApp (EVar "authDomainTop") (EVar "q"))) (EVar "xt"))) (EVar "q"))))) (arm PWild () (EApp (EApp (EApp (EApp (EVar "unifyInto") (EVar "dyn")) (EVar "True")) (EVar "dom")) (EVar "xt")))))
(DTypeSig true "joinValueTypes" (TyFun (TyCon "DynCtx") (TyFun (TyCon "JoinContext") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono"))) (TyCon "Mono")))))
(DFunDef false "joinValueTypes" ((PVar "dyn") (PVar "context") (PVar "values")) (EBlock (DoLet false false (PVar "upper") (EApp (EApp (EVar "optionOrFresh") (EFieldAccess (EVar "dyn") "dcModule")) (EApp (EApp (EVar "joinProduced") (EApp (EApp (EApp (EVar "valueJoinOps") (EVar "dyn")) (EVar "context")) (ELam (PWild) (EApp (EVar "collectRows") (EApp (EVar "joinCellOf") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph")))))) (EVar "values")))) (DoLet false false PWild (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "loc") (PVar "lower"))) (EApp (EApp (EApp (EApp (EVar "recordFileValueFlow") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "loc")) (EVar "upper")) (EVar "lower")))) (EVar "values"))) (DoExpr (EVar "upper"))))
(DTypeSig true "valueJoinOps" (TyFun (TyCon "DynCtx") (TyFun (TyCon "JoinContext") (TyFun (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "List") (TyCon "EffRow")) (TyCon "EffRow"))) (TyApp (TyCon "ValueJoinOps") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "valueJoinOps" ((PVar "dyn") (PVar "context") (PVar "collector")) (EBlock (DoLet false false (PVar "ops") (EApp (EApp (EApp (EVar "decidingJoinOps") (EVar "dyn")) (EVar "context")) (EVar "collector"))) (DoExpr (ERecordUpdate (EVar "ops") ((fa "vjoDefer" (ELam ((PVar "values")) (EApp (EApp (EApp (EApp (EVar "deferJoin") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "context")) (EVar "collector")) (EVar "values")))))))))
(DTypeSig false "decidingJoinOps" (TyFun (TyCon "DynCtx") (TyFun (TyCon "JoinContext") (TyFun (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "List") (TyCon "EffRow")) (TyCon "EffRow"))) (TyApp (TyCon "ValueJoinOps") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "decidingJoinOps" ((PVar "dyn") (PVar "context") (PVar "collector")) (ERecordCreate "ValueJoinOps" ((fa "vjoEqual" (EApp (EApp (EVar "joinValueEqual") (EVar "dyn")) (EVar "context"))) (fa "vjoCovariants" (EApp (EVar "producedSlotCovariants") (EFieldAccess (EVar "dyn") "dcModule"))) (fa "vjoFreshType" (EApp (EVar "freshVar") (EFieldAccess (EVar "dyn") "dcModule"))) (fa "vjoFreshRow" (EApp (EVar "openRow") (EFieldAccess (EVar "dyn") "dcModule"))) (fa "vjoCollectRows" (EApp (EVar "collector") (EVar "dyn"))) (fa "vjoFreshAuth" (ELam ((PVar "top")) (EApp (EVar "AVar") (EApp (EApp (EApp (EVar "freshAuthvar") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "top")) (EVar "None"))))) (fa "vjoCollectAuth" (EApp (EVar "collectAuthAllowance") (EFieldAccess (EVar "dyn") "dcModule"))) (fa "vjoDefer" (ELam (PWild) (EVar "None"))))))
(DTypeSig false "deferJoin" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "JoinContext") (TyFun (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "List") (TyCon "EffRow")) (TyCon "EffRow"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono"))) (TyApp (TyCon "Option") (TyCon "Mono")))))))
(DFunDef false "deferJoin" ((PVar "mctx") (PVar "context") (PVar "collector") (PVar "values")) (EIf (EBinOp "&&" (EApp (EVar "EffectSolver.hasSummaryScope") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "effectSummaries")) (EApp (EVar "distinctVariables") (EVar "values"))) (EBlock (DoLet false false (PVar "result") (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "pendingJoinsRef")) (EBinOp "::" (ERecordCreate "PendingJoin" ((fa "pjResult" (EVar "result")) (fa "pjValues" (EVar "values")) (fa "pjLevel" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (fa "pjContext" (EVar "context")) (fa "pjCollector" (EVar "collector")))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "pendingJoinsRef") "value")))) (DoExpr (EApp (EVar "Some") (EVar "result")))) (EVar "None")))
(DTypeSig false "distinctVariables" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono"))) (TyCon "Bool")))
(DFunDef false "distinctVariables" ((PVar "values")) (EBlock (DoLet false false (PVar "roots") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PTuple PWild (PVar "value"))) (EMatch (EApp (EVar "normalize") (EVar "value")) (arm (PCon "TVar" (PVar "cell")) () (EApp (EApp (EApp (EVar "IdMap.set") (EApp (EVar "tyvarId") (EVar "cell"))) (ELit LUnit)) (EVar "acc"))) (arm PWild () (EVar "acc"))))) (EVar "Tip")) (EVar "values"))) (DoExpr (EBinOp ">=" (EApp (EVar "listLen") (EApp (EVar "IdMap.keys") (EVar "roots"))) (ELit (LInt 2))))))
(DTypeSig true "resolvePendingJoins" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Int") (TyCon "Unit"))))
(DFunDef false "resolvePendingJoins" ((PVar "dyn") (PVar "level")) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "pendingJoinsRef") "value") (arm (PCons (PVar "pj") (PVar "rest")) () (EIf (EBinOp ">=" (EFieldAccess (EVar "pj") "pjLevel") (EVar "level")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "pendingJoinsRef")) (EVar "rest"))) (DoExpr (EApp (EApp (EVar "resolvePendingJoin") (EVar "dyn")) (EVar "pj"))) (DoExpr (EApp (EApp (EVar "resolvePendingJoins") (EVar "dyn")) (EVar "level")))) (ELit LUnit))) (arm (PList) () (ELit LUnit))))
(DTypeSig true "settlePendingJoins" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Int") (TyCon "Unit"))))
(DFunDef false "settlePendingJoins" ((PVar "dyn") (PVar "level")) (EBlock (DoLet false false (PVar "postponed") (EApp (EApp (EApp (EVar "settlePending") (EVar "dyn")) (EVar "level")) (EListLit))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "pendingJoinsRef")) (EBinOp "++" (EApp (EVar "reverseL") (EVar "postponed")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "pendingJoinsRef") "value"))))))
(DTypeSig false "settlePending" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PendingJoin")) (TyApp (TyCon "List") (TyCon "PendingJoin"))))))
(DFunDef false "settlePending" ((PVar "dyn") (PVar "level") (PVar "postponed")) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "pendingJoinsRef") "value") (arm (PCons (PVar "pj") (PVar "rest")) () (EIf (EBinOp ">=" (EFieldAccess (EVar "pj") "pjLevel") (EVar "level")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "pendingJoinsRef")) (EVar "rest"))) (DoExpr (EIf (EApp (EApp (EVar "joinOfOuterVariables") (EVar "level")) (EVar "pj")) (EBlock (DoExpr (EApp (EApp (EVar "lowerTyvarLevel") (EBinOp "-" (EVar "level") (ELit (LInt 1)))) (EFieldAccess (EVar "pj") "pjResult"))) (DoExpr (EApp (EApp (EApp (EVar "settlePending") (EVar "dyn")) (EVar "level")) (EBinOp "::" (ERecordUpdate (EVar "pj") ((fa "pjLevel" (EBinOp "-" (EVar "level") (ELit (LInt 1)))))) (EVar "postponed"))))) (EBlock (DoExpr (EApp (EApp (EVar "resolvePendingJoin") (EVar "dyn")) (EVar "pj"))) (DoExpr (EApp (EApp (EApp (EVar "settlePending") (EVar "dyn")) (EVar "level")) (EVar "postponed"))))))) (EVar "postponed"))) (arm (PList) () (EVar "postponed"))))
(DTypeSig false "joinOfOuterVariables" (TyFun (TyCon "Int") (TyFun (TyCon "PendingJoin") (TyCon "Bool"))))
(DFunDef false "joinOfOuterVariables" ((PVar "level") (PVar "pj")) (EBinOp "&&" (EApp (EVar "isUnshaped") (EFieldAccess (EVar "pj") "pjResult")) (EApp (EApp (EVar "allList") (ELam ((PVar "value")) (EApp (EApp (EVar "isOuterVariable") (EVar "level")) (EApp (EVar "snd") (EVar "value"))))) (EFieldAccess (EVar "pj") "pjValues"))))
(DTypeSig false "isOuterVariable" (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyCon "Bool"))))
(DFunDef false "isOuterVariable" ((PVar "level") (PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TVar" (PVar "cell")) () (EBinOp "<" (EApp (EVar "tyvarLevel") (EVar "cell")) (EVar "level"))) (arm PWild () (EVar "False"))))
(DTypeSig false "lowerTyvarLevel" (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyCon "Unit"))))
(DFunDef false "lowerTyvarLevel" ((PVar "level") (PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TVar" (PVar "cell")) () (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Unbound" (PVar "id") (PVar "old")) () (EIf (EBinOp ">" (EVar "old") (EVar "level")) (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EApp (EVar "Unbound") (EVar "id")) (EVar "level"))) (ELit LUnit))) (arm (PCon "Link" PWild) () (ELit LUnit)))) (arm PWild () (ELit LUnit))))
(DTypeSig true "postponePendingJoins" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyCon "Unit"))))
(DFunDef false "postponePendingJoins" ((PVar "mctx") (PVar "level")) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "pendingJoinsRef")) (EApp (EApp (EVar "lowerPending") (EVar "level")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "pendingJoinsRef") "value"))))
(DTypeSig false "lowerPending" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PendingJoin")) (TyApp (TyCon "List") (TyCon "PendingJoin")))))
(DFunDef false "lowerPending" ((PVar "level") (PCons (PVar "pj") (PVar "rest"))) (EIf (EBinOp ">=" (EFieldAccess (EVar "pj") "pjLevel") (EVar "level")) (EBinOp "::" (ERecordUpdate (EVar "pj") ((fa "pjLevel" (EBinOp "-" (EVar "level") (ELit (LInt 1)))))) (EApp (EApp (EVar "lowerPending") (EVar "level")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "lowerPending" (PWild (PVar "pending")) (EVar "pending"))
(DTypeSig false "resolvePendingJoin" (TyFun (TyCon "DynCtx") (TyFun (TyCon "PendingJoin") (TyCon "Unit"))))
(DFunDef false "resolvePendingJoin" ((PVar "dyn") (PVar "pj")) (EMatch (EApp (EVar "normalize") (EFieldAccess (EVar "pj") "pjResult")) (arm (PCon "TVar" PWild) () (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EFieldAccess (EVar "pj") "pjResult")) (EApp (EApp (EVar "resolveDeferredJoin") (EApp (EApp (EApp (EVar "decidingJoinOps") (EVar "dyn")) (EFieldAccess (EVar "pj") "pjContext")) (EFieldAccess (EVar "pj") "pjCollector"))) (EFieldAccess (EVar "pj") "pjValues")))) (arm PWild () (EApp (EApp (EVar "settleShapedJoins") (EVar "dyn")) (EListLit (EVar "pj"))))))
(DTypeSig false "collectAuthAllowance" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Authority")) (TyCon "Authority"))))
(DFunDef false "collectAuthAllowance" ((PVar "mctx") (PVar "lowers")) (EBlock (DoLet false false (PVar "top") (EMatch (EVar "lowers") (arm (PCons (PVar "q") PWild) () (EApp (EVar "authDomainTop") (EVar "q"))) (arm (PList) () (EVar "PUnit")))) (DoLet false false (PVar "cell") (EApp (EApp (EApp (EVar "freshAuthvar") (EVar "mctx")) (EVar "top")) (EVar "None"))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "q")) (EApp (EApp (EApp (EVar "wantAuthority") (EVar "mctx")) (EVar "q")) (EApp (EVar "AVar") (EVar "cell"))))) (ELit LUnit)) (EVar "lowers"))) (DoExpr (EApp (EVar "AVar") (EVar "cell")))))
(DTypeSig true "optionOrFresh" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "Mono")) (TyCon "Mono"))))
(DFunDef false "optionOrFresh" ((PVar "mctx") (PCon "None")) (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit)))
(DFunDef false "optionOrFresh" ((PVar "mctx") (PCon "Some" (PVar "value"))) (EVar "value"))
(DTypeSig false "joinValueEqual" (TyFun (TyCon "DynCtx") (TyFun (TyCon "JoinContext") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))))
(DFunDef false "joinValueEqual" ((PVar "outer") (PVar "context") (PVar "loc") (PVar "left") (PVar "right")) (EBlock (DoLet false false (PVar "dyn") (EApp (EApp (EVar "dynAtIfSome") (EVar "loc")) (EVar "outer"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "noteNumlitCtx") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "left")) (EVar "right")) (EVar "context"))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (ERecordUpdate (EVar "dyn") ((fa "dcJoin" (EApp (EVar "Some") (EVar "context")))))) (EVar "left")) (EVar "right")))))
(DTypeSig true "producedSlotCovariants" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Bool")))))
(DFunDef false "producedSlotCovariants" ((PVar "mctx") (PVar "head")) (EMatch (EApp (EVar "headTyconMono") (EVar "head")) (arm (PCon "Some" (PCon "HkDecl" (PVar "key"))) () (EBlock (DoLet false false (PVar "slot") (EApp (EVar "monoSpineDepth") (EVar "head"))) (DoExpr (EMatch (EApp (EApp (EVar "paramPolaritiesOf") (EVar "mctx")) (EVar "key")) (arm (PCon "Some" (PVar "polarities")) () (EApp (EApp (EVar "map") (EVar "isCovariantPolarity")) (EApp (EApp (EVar "drop") (EVar "slot")) (EVar "polarities")))) (arm (PCon "None") () (EIf (EApp (EApp (EVar "tabKeyEq") (EVar "key")) (EApp (EApp (EVar "tyTabKey") (EVar "OriginBuiltin")) (ELit (LString "List")))) (EIf (EBinOp "==" (EVar "slot") (ELit (LInt 0))) (EListLit (EVar "True")) (EListLit)) (EMatch (EApp (EVar "headTyconNameMono") (EVar "head")) (arm (PCon "Some" (PVar "name")) () (EMatch (EApp (EVar "tupleTagArity") (EVar "name")) (arm (PCon "Some" (PVar "arity")) () (EIf (EApp (EApp (EVar "tabKeyEq") (EVar "key")) (EApp (EApp (EVar "tyTabKey") (EVar "OriginBuiltin")) (EVar "name"))) (EApp (EApp (EVar "replicate") (EBinOp "-" (EVar "arity") (EVar "slot"))) (EVar "True")) (EListLit))) (arm (PCon "None") () (EListLit)))) (arm (PCon "None") () (EListLit))))))))) (arm PWild () (EListLit))))
(DTypeSig false "isCovariantPolarity" (TyFun (TyCon "Polarity") (TyCon "Bool")))
(DFunDef false "isCovariantPolarity" ((PCon "PCo")) (EVar "True"))
(DFunDef false "isCovariantPolarity" (PWild) (EVar "False"))
(DTypeSig true "raiseAuthvarLevel" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "Unit"))))
(DFunDef false "raiseAuthvarLevel" ((PVar "level") (PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "AUnbound" (PVar "id") PWild (PVar "top") (PVar "pat") (PVar "name")) () (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EApp (EApp (EApp (EApp (EVar "AUnbound") (EVar "id")) (EVar "level")) (EVar "top")) (EVar "pat")) (EVar "name")))) (arm (PCon "ALink" PWild PWild PWild) () (ELit LUnit))))
(DTypeSig true "polarityAt" (TyFun (TyApp (TyCon "List") (TyCon "Polarity")) (TyFun (TyCon "Int") (TyCon "Polarity"))))
(DFunDef false "polarityAt" ((PList) PWild) (EVar "PCo"))
(DFunDef false "polarityAt" ((PCons (PVar "q") (PVar "rest")) (PVar "i")) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (EVar "q") (EApp (EApp (EVar "polarityAt") (EVar "rest")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))
(DTypeSig true "freshVars" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "freshVars" ((PVar "mctx") (PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit)) (EApp (EApp (EVar "freshVars") (EVar "mctx")) (EBinOp "-" (EVar "n") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "lowerOwnedRoot" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "lowerOwnedRoot" ((PVar "mctx") (PVar "owner") (PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EIf (EBinOp "==" (EApp (EVar "tyvarLevel") (EVar "cell")) (EVar "owner")) (EApp (EApp (EVar "lowerToCurrent") (EVar "mctx")) (EVar "m")) (ELit LUnit))) (arm PWild () (ELit LUnit))))
(DTypeSig true "monoUnboundVarLevels" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "monoUnboundVarLevels" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TVar" (PVar "cell")) () (EListLit (ETuple (EApp (EVar "tyvarId") (EVar "cell")) (EApp (EVar "tyvarLevel") (EVar "cell"))))) (arm (PCon "TCon" PWild PWild) () (EListLit)) (arm (PCon "TRigid" PWild) () (EListLit)) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EBinOp "++" (EApp (EVar "monoUnboundVarLevels") (EVar "a")) (EApp (EVar "monoUnboundVarLevels") (EVar "b")))) (arm (PCon "TFun" (PVar "a") PWild (PVar "b")) () (EBinOp "++" (EApp (EVar "monoUnboundVarLevels") (EVar "a")) (EApp (EVar "monoUnboundVarLevels") (EVar "b")))) (arm (PCon "TEff" PWild) () (EListLit)) (arm (PCon "TAuth" PWild) () (EListLit)) (arm (PCon "TQual" (PVar "a") PWild) () (EApp (EVar "monoUnboundVarLevels") (EVar "a")))))
(DTypeSig true "recordFileValueFlow" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit"))))))
(DFunDef false "recordFileValueFlow" ((PVar "mctx") (PVar "loc") (PVar "upper") (PVar "lower")) (EApp (EApp (EVar "wPush") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fileValueFlows")) (ETuple (EVar "loc") (EVar "upper") (EVar "lower"))))
(DTypeSig true "unifySourceDomains" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit"))))))
(DFunDef false "unifySourceDomains" ((PVar "dyn") (PVar "arity") (PVar "owned") (PVar "actual")) (EIf (EBinOp "<=" (EVar "arity") (ELit (LInt 0))) (ELit LUnit) (EMatch (ETuple (EApp (EVar "normalize") (EVar "owned")) (EApp (EVar "normalize") (EVar "actual"))) (arm (PTuple (PCon "TFun" (PVar "domain") PWild (PVar "result")) (PCon "TFun" (PVar "param") PWild (PVar "body"))) () (EBlock (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "domain")) (EVar "param"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "unifySourceDomains") (EVar "dyn")) (EBinOp "-" (EVar "arity") (ELit (LInt 1)))) (EVar "result")) (EVar "body"))))) (arm PWild () (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "owned")) (EVar "actual"))))))
(DTypeSig true "zipBindFrom" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Unit")))))
(DFunDef false "zipBindFrom" ((PVar "dyn") (PCons (PVar "p") (PVar "ps")) (PCons (PVar "q") (PVar "qs"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "bindFrom") (EVar "dyn")) (EVar "p")) (EVar "q"))) (DoExpr (EApp (EApp (EApp (EVar "zipBindFrom") (EVar "dyn")) (EVar "ps")) (EVar "qs")))))
(DFunDef false "zipBindFrom" ((PVar "dyn") PWild PWild) (ELit LUnit))
# MARK
(DUse false (UseGroup ("types" "tc_types") ((mem "AbsorptionEvent" true) (mem "CDeclared" true) (mem "CDeclaredPrefix" true) (mem "CSlot" true) (mem "DynCtx" true) (mem "JoinContext" true) (mem "Kind" true) (mem "MethodInstantiationSubst" true) (mem "MethodTrackedInstantiation" true) (mem "ObligationSite" true) (mem "OblProjection" true) (mem "PendingJoin" true) (mem "Polarity" true) (mem "Predicate" true) (mem "PredicateSlotArgs" true) (mem "Provenance" true) (mem "UObligation" true) (mem "Windowed" true) (mem "DoCtx" false) (mem "dynFor" false) (mem "GraphCtx" false) (mem "ModuleCtx" false) (mem "PredicateSlot" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "authCellsIn" false) (mem "authRowCells" false) (mem "cellIdSet" false) (mem "containsI" false) (mem "dedupI" false) (mem "effvarLevel" false) (mem "headTyconMono" false) (mem "headTyconNameMono" false) (mem "isUnshaped" false) (mem "joinCellOf" false) (mem "minLevelOf" false) (mem "monoHasArrowInSlot" false) (mem "monoIsApp" false) (mem "monoSpineDepth" false) (mem "monoUnboundIds" false) (mem "newEffvarId" false) (mem "qualifierAuthIds" false) (mem "rowOfMembers" false) (mem "sameRootId" false) (mem "spineHead" false) (mem "substAuth" false) (mem "substMono" false) (mem "substMonos" false) (mem "substOblArgs" false) (mem "substRow" false) (mem "tconBuiltin" false) (mem "tupleUnifyClash" false) (mem "tyAppSpine" false) (mem "tyvarId" false) (mem "xmodOblArgId" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "dynAtIfSome" false) (mem "wAll" false) (mem "wPush" false) (mem "wRestore" false) (mem "wSnapshot" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "domainHasPatterns" false) (mem "tyTabKey" false))))
(DUse false (UseGroup ("types" "tc_diag") ((mem "firstTupleCallHint" false) (mem "pushTypeError" false) (mem "pushTypeErrorAt" false) (mem "pushTypeErrorHelpFixAt" false) (mem "recordTypeError" false))))
(DUse false (UseGroup ("types" "tc_diag_text") ((mem "authorityCoverMsg" false) (mem "authorityIndexMsg" false) (mem "authorityTermTextIn" false) (mem "closedRowMismatchMsg" false) (mem "constrainedApplicationText" false) (mem "contraRowMsg" false) (mem "deferRequiresMonadMsg" false) (mem "doRequiresMonadMsg" false) (mem "elselessIfHelp" false) (mem "indexRowMismatchMsg" false) (mem "joinMismatchMsg" false) (mem "paramVarianceMismatchMsg" false) (mem "patternIndexMsg" false) (mem "renderFlatRow" false) (mem "residualFailureMsg" false) (mem "sameSpellingHint" false) (mem "starSpelling" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" true) (mem "authDomainTop" false) (mem "authHasVars" false) (mem "authIsPattern" false) (mem "authIsTop" false) (mem "authJoinAll" false) (mem "authNorm" false) (mem "authSplit" false) (mem "authSub" false) (mem "authTop" false) (mem "authvarDomain" false) (mem "authvarId" false) (mem "authvarIsPattern" false) (mem "authvarLevel" false) (mem "authvarName" false) (mem "authVars" false) (mem "linkAuthvar" false) (mem "markAuthvarPattern" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" true) (mem "EffLabel" true) (mem "EffRow" true) (mem "Effvar" true) (mem "atomAuth" false) (mem "atomKey" false) (mem "atomsDiff" false) (mem "atomsNorm" false) (mem "atomsUnion" false) (mem "builtinLabel" false) (mem "collectRows" false) (mem "effLabelName" false) (mem "effrowNorm" false) (mem "effvarId" false) (mem "findAtom" false) (mem "isJoinCell" false) (mem "labelKey" false) (mem "linkRow" false) (mem "pureRow" false) (mem "renderAtoms" false) (mem "rowFlat" false) (mem "rowHasSummary" false))))
(DUse false (UseGroup ("types" "repr") ((mem "AuthResidual" true) (mem "Mono" true) (mem "Scheme" true) (mem "Tyvar" true) (mem "VecObl" true) (mem "normalize" false) (mem "ppAuthority" false) (mem "ppMono" false) (mem "tupleTagArity" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "EffAtomTy" true) (mem "EffParamTy" true) (mem "Loc" true) (mem "TabKey" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "lookupTab" false) (mem "sameTyConHead" false) (mem "tabKeyEq" false))))
(DUse false (UseGroup ("types" "registry") ((mem "HeadKey" true))))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true))))
(DUse false (UseGroup ("types" "evidence") ((mem "ScopeId" true))))
(DUse false (UseGroup ("types" "publish") ((mem "TcDiag" true))))
(DUse false (UseGroup ("types" "effect_values") ((mem "ValueJoinOps" true) (mem "joinProduced" false) (mem "joinProducedEnvelope" false) (mem "resolveDeferredJoin" false))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "anyList" false) (mem "dedup" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "isSome" false) (mem "listLen" false) (mem "lookupAssoc" false) (mem "minI" false) (mem "orElseOpt" false) (mem "reverseL" false) (mem "splitOnChar" false))))
(DUse false (UseGroup ("types" "effect_param_decode") ((mem "atomOfLabel" false))))
(DUse false (UseGroup ("types" "solver_contract") ((mem "Instantiation" true) (mem "Wanted" true))))
(DUse false (UseGroup ("types" "target_profile") ((mem "hostLabels" false))))
(DUse false (UseGroup ("types" "disposition") ((mem "MethodDisposition" true))))
(DUse false (UseGroup ("list") ((mem "drop" false) (mem "last" false) (mem "replicate" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omInsert" false) (mem "omLookup" false))))
(DUse false (UseGroup ("types" "invocation_basis") ((mem "paramPolaritiesIn" false))))
(DUse false (UseGroup ("types" "effect_infer") ((mem "recordEffect" false) (mem "typeAuthority" false))))
(DUse false (UseAlias ("types" "effect_solver") "EffectSolver"))
(DUse false (UseAlias ("types" "scopes") "Scopes"))
(DUse false (UseAlias ("map") "IdMap"))
(DTypeSig false "ioLabel" (TyCon "EffLabel"))
(DFunDef false "ioLabel" () (EApp (EVar "builtinLabel") (ELit (LString "IO"))))
(DTypeSig false "expandIoInBound" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "expandIoInBound" ((PVar "gctx") (PVar "b")) (EMatch (EApp (EApp (EVar "findAtom") (EApp (EVar "labelKey") (EVar "ioLabel"))) (EVar "b")) (arm (PCon "None") () (EVar "b")) (arm (PCon "Some" PWild) () (EApp (EVar "atomsNorm") (EBinOp "++" (EVar "b") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "config") "value") "tcIoJoin"))))))
(DTypeSig false "narrowPerformedIo" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))))
(DFunDef false "narrowPerformedIo" ((PVar "gctx") (PVar "diff") (PVar "bound")) (EMatch (EApp (EApp (EVar "findAtom") (EApp (EVar "labelKey") (EVar "ioLabel"))) (EVar "diff")) (arm (PCon "None") () (EVar "diff")) (arm (PCon "Some" PWild) () (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EVar "filterList") (ELam ((PVar "x")) (EBinOp "/=" (EApp (EVar "atomKey") (EVar "x")) (EApp (EVar "labelKey") (EVar "ioLabel"))))) (EVar "diff"))) (DoLet false false (PVar "join") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "config") "value") "tcIoJoin")) (DoLet false false (PVar "missing") (EApp (EApp (EVar "atomsDiff") (EVar "join")) (EVar "bound"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "missing")) (EApp (EVar "listLen") (EVar "join"))) (EVar "diff") (EIf (EApp (EVar "isEmptyL") (EVar "missing")) (EVar "rest") (EApp (EVar "atomsNorm") (EBinOp "++" (EVar "rest") (EVar "missing"))))))))))
(DTypeSig true "atomsEscape" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))))
(DFunDef false "atomsEscape" ((PVar "gctx") (PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "bound") (EApp (EApp (EVar "expandIoInBound") (EVar "gctx")) (EVar "b"))) (DoExpr (EApp (EApp (EApp (EVar "narrowPerformedIo") (EVar "gctx")) (EApp (EApp (EVar "atomsDiff") (EVar "a")) (EVar "bound"))) (EVar "bound")))))
(DTypeSig false "newTyvarId" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyCon "Int"))))
(DFunDef false "newTyvarId" ((PVar "gctx") PWild) (EBlock (DoLet false false (PVar "n") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "tyvarCounter") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "tyvarCounter")) (EBinOp "+" (EVar "n") (ELit (LInt 1))))) (DoExpr (EVar "n"))))
(DTypeSig true "freshVar" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "Mono"))))
(DFunDef false "freshVar" ((PVar "mctx") PWild) (EApp (EVar "TVar") (EApp (EVar "Ref") (EApp (EApp (EVar "Unbound") (EApp (EApp (EVar "newTyvarId") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")))))
(DTypeSig true "freshEffvar" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyApp (TyCon "Ref") (TyCon "Effvar")))))
(DFunDef false "freshEffvar" ((PVar "mctx") PWild) (EApp (EVar "Ref") (EApp (EApp (EVar "EUnbound") (EApp (EApp (EVar "newEffvarId") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value"))))
(DTypeSig true "freshEffvarAt" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Effvar")))))
(DFunDef false "freshEffvarAt" ((PVar "gctx") (PVar "lvl")) (EApp (EVar "Ref") (EApp (EApp (EVar "EUnbound") (EApp (EApp (EVar "newEffvarId") (EVar "gctx")) (ELit LUnit))) (EVar "lvl"))))
(DTypeSig false "freshInferenceEffvar" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyApp (TyCon "Ref") (TyCon "Effvar")))))
(DFunDef false "freshInferenceEffvar" ((PVar "mctx") PWild) (EBlock (DoLet false false (PVar "cell") (EApp (EApp (EVar "freshEffvar") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "EffectSolver.registerExistential") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "effectSummaries")) (EVar "cell"))) (DoExpr (EVar "cell"))))
(DTypeSig true "openRow" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "EffRow"))))
(DFunDef false "openRow" ((PVar "mctx") PWild) (EApp (EApp (EVar "EffRow") (EListLit)) (EApp (EVar "Some") (EApp (EApp (EVar "freshInferenceEffvar") (EVar "mctx")) (ELit LUnit)))))
(DTypeSig true "enterLevel" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "Unit"))))
(DFunDef false "enterLevel" ((PVar "mctx") PWild) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel")) (EBinOp "+" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value") (ELit (LInt 1)))))
(DTypeSig true "exitLevel" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "Unit"))))
(DFunDef false "exitLevel" ((PVar "mctx") PWild) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel")) (EBinOp "-" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value") (ELit (LInt 1)))))
(DTypeSig false "isRigidCell" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyCon "Bool"))))
(DFunDef false "isRigidCell" ((PVar "mctx") (PVar "cell")) (EApp (EApp (EVar "IdMap.has") (EApp (EVar "effvarId") (EVar "cell"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "rigidEffvarsRef") "value")))
(DTypeSig true "performEffect" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "EffRow"))) (TyFun (TyCon "EffRow") (TyCon "Unit")))))
(DFunDef false "performEffect" ((PVar "mctx") (PVar "cur") (PVar "eff")) (EBlock (DoExpr (EApp (EApp (EVar "recordEffectSites") (EVar "mctx")) (EVar "eff"))) (DoExpr (EApp (EApp (EVar "recordEffect") (EVar "cur")) (EVar "eff")))))
(DTypeSig false "recordEffectSites" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "EffRow") (TyCon "Unit"))))
(DFunDef false "recordEffectSites" ((PVar "mctx") (PCon "EffRow" (PList) PWild)) (ELit LUnit))
(DFunDef false "recordEffectSites" ((PVar "mctx") (PVar "eff")) (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "atom")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "effectSiteKey") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (EApp (EVar "atomKey") (EVar "atom")))) (DoLet false false (PVar "sites") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "effectSitesRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "effectSitesRef")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "::" (ETuple (EApp (EVar "atomAuth") (EVar "atom")) (EFieldAccess (EVar "mctx") "mcLoc")) (EVar "sites"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "effectSitesRef") "value"))))))) (ELit LUnit)) (EApp (EVar "fst") (EApp (EVar "rowFlat") (EVar "eff")))))
(DTypeSig true "effectSiteKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "effectSiteKey" ((PVar "fn") (PVar "label")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "fn"))) (ELit (LString "\t"))) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString ""))))
(DTypeSig false "obligationSiteHere" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyCon "ObligationSite"))))
(DFunDef false "obligationSiteHere" ((PVar "mctx") (PVar "covering")) (ERecordCreate "ObligationSite" ((fa "osLoc" (EFieldAccess (EVar "mctx") "mcLoc")) (fa "osFn" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (fa "osCovering" (EVar "covering")))))
(DTypeSig false "deferEffectRelation" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Unit"))))))
(DFunDef false "deferEffectRelation" ((PVar "mctx") (PVar "exact") (PVar "lower") (PVar "upper")) (EApp (EApp (EApp (EApp (EApp (EVar "EffectSolver.recordRelation") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "effectSummaries")) (EVar "exact")) (EApp (EApp (EVar "obligationSiteHere") (EVar "mctx")) (EVar "False"))) (EVar "lower")) (EVar "upper")))
(DTypeSig false "unifyIndex" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Unit")))))
(DFunDef false "unifyIndex" ((PVar "mctx") (PVar "qa") (PVar "qb")) (EMatch (ETuple (EApp (EVar "authNorm") (EVar "qa")) (EApp (EVar "authNorm") (EVar "qb"))) (arm (PTuple (PCon "AVar" (PVar "a")) (PVar "b")) ((GBool (EApp (EApp (EApp (EVar "flexibleIndex") (EVar "mctx")) (EVar "a")) (EVar "b")))) (EApp (EApp (EApp (EVar "substituteIndex") (EVar "mctx")) (EVar "a")) (EVar "b"))) (arm (PTuple (PVar "a") (PCon "AVar" (PVar "b"))) ((GBool (EApp (EApp (EApp (EVar "flexibleIndex") (EVar "mctx")) (EVar "b")) (EVar "a")))) (EApp (EApp (EApp (EVar "substituteIndex") (EVar "mctx")) (EVar "b")) (EVar "a"))) (arm (PTuple (PVar "a") (PVar "b")) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "wantAuthorityWith") (EVar "mctx")) (EVar "True")) (EVar "a")) (EVar "b"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "wantAuthorityWith") (EVar "mctx")) (EVar "True")) (EVar "b")) (EVar "a")))))))
(DTypeSig false "substituteIndex" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyFun (TyCon "Authority") (TyCon "Unit")))))
(DFunDef false "substituteIndex" ((PVar "mctx") (PVar "cell") (PVar "term")) (EBlock (DoExpr (EIf (EBinOp "&&" (EApp (EVar "authvarIsPattern") (EVar "cell")) (EApp (EVar "not") (EApp (EVar "authIsPattern") (EVar "term")))) (EBlock (DoLet false false (PVar "fixed") (EApp (EApp (EVar "indexOutsidePatterns") (EVar "mctx")) (EVar "term"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "fixed")) (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "v")) (EIf (EApp (EVar "authvarIsPattern") (EVar "v")) (ELit LUnit) (EApp (EVar "markAuthvarPattern") (EVar "v"))))) (ELit LUnit)) (EApp (EVar "authVars") (EVar "term"))) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-AUTHORITY-PATTERN"))) (EApp (EVar "patternIndexMsg") (EVar "term")))))) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "substituteIndexLinked") (EVar "mctx")) (EVar "cell")) (EVar "term")))))
(DTypeSig false "indexOutsidePatterns" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Authority") (TyApp (TyCon "List") (TyCon "Authority")))))
(DFunDef false "indexOutsidePatterns" ((PVar "mctx") (PVar "term")) (EBlock (DoLet false false (PVar "members") (EMatch (EApp (EVar "authNorm") (EVar "term")) (arm (PCon "AJoin" (PVar "ms")) () (EVar "ms")) (arm (PVar "other") () (EListLit (EVar "other"))))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "m")) (EMatch (EVar "m") (arm (PCon "AVar" (PVar "c")) () (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "authvarIsPattern") (EVar "c"))) (EApp (EApp (EVar "IdMap.has") (EApp (EVar "authvarId") (EVar "c"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "rigidAuthvarsRef") "value")))) (arm (PVar "other") () (EApp (EVar "not") (EApp (EVar "authIsPattern") (EVar "other"))))))) (EVar "members")))))
(DTypeSig false "substituteIndexLinked" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyFun (TyCon "Authority") (TyCon "Unit")))))
(DFunDef false "substituteIndexLinked" ((PVar "mctx") (PVar "cell") (PVar "term")) (EBlock (DoExpr (EApp (EApp (EVar "lowerAuthLevels") (EApp (EVar "authvarLevel") (EVar "cell"))) (EVar "term"))) (DoExpr (EIf (EApp (EVar "authHasVars") (EVar "term")) (ELit LUnit) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "indexSubstitutedRef")) (EApp (EApp (EApp (EVar "IdMap.set") (EApp (EVar "authvarId") (EVar "cell"))) (ELit LUnit)) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "indexSubstitutedRef") "value"))))) (DoExpr (EApp (EApp (EVar "linkAuthvar") (EVar "cell")) (EVar "term")))))
(DTypeSig false "flexibleIndex" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyFun (TyCon "Authority") (TyCon "Bool")))))
(DFunDef false "flexibleIndex" ((PVar "mctx") (PVar "cell") (PVar "other")) (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "IdMap.has") (EApp (EVar "authvarId") (EVar "cell"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "rigidAuthvarsRef") "value"))) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "c")) (EBinOp "==" (EApp (EVar "authvarId") (EVar "c")) (EApp (EVar "authvarId") (EVar "cell"))))) (EApp (EVar "authVars") (EVar "other"))))))
(DTypeSig false "unifyRow" (TyFun (TyCon "DynCtx") (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Unit")))))
(DFunDef false "unifyRow" ((PVar "dyn") (PVar "r1") (PVar "r2")) (EApp (EApp (EApp (EVar "unifyRowN") (EVar "dyn")) (EApp (EVar "effrowNorm") (EVar "r1"))) (EApp (EVar "effrowNorm") (EVar "r2"))))
(DTypeSig false "unifyRowN" (TyFun (TyCon "DynCtx") (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Unit")))))
(DFunDef false "unifyRowN" ((PVar "dyn") (PVar "r1") (PVar "r2")) (EIf (EBinOp "||" (EApp (EVar "rowHasSummary") (EVar "r1")) (EApp (EVar "rowHasSummary") (EVar "r2"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "deferEffectRelation") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "False")) (EVar "r1")) (EVar "r2"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "deferEffectRelation") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "False")) (EVar "r2")) (EVar "r1")))) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "rowTailIsJoin") (EVar "r1")) (EApp (EVar "rowTailIsJoin") (EVar "r2"))) (EApp (EApp (EVar "rowHasRigid") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "r1"))) (EApp (EApp (EVar "rowHasRigid") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "r2"))) (EApp (EApp (EApp (EApp (EVar "unifyJoinRows") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "False")) (EVar "r1")) (EVar "r2")) (EApp (EApp (EApp (EVar "unifyRowPlain") (EVar "dyn")) (EVar "r1")) (EVar "r2")))))
(DTypeSig false "rowHasRigid" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "EffRow") (TyCon "Bool"))))
(DFunDef false "rowHasRigid" ((PVar "mctx") (PVar "row")) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "rigidEffvarsRef") "value") (arm (PCon "Tip") () (EVar "False")) (arm PWild () (EApp (EApp (EVar "anyList") (EApp (EVar "isRigidCell") (EVar "mctx"))) (EApp (EVar "snd") (EApp (EVar "rowFlat") (EVar "row")))))))
(DTypeSig false "rowTailIsJoin" (TyFun (TyCon "EffRow") (TyCon "Bool")))
(DFunDef false "rowTailIsJoin" ((PCon "EffRow" PWild (PCon "Some" (PVar "c")))) (EApp (EVar "isJoinCell") (EVar "c")))
(DFunDef false "rowTailIsJoin" ((PCon "EffRow" PWild (PCon "None"))) (EVar "False"))
(DTypeSig false "unifyJoinRows" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Unit"))))))
(DFunDef false "unifyJoinRows" ((PVar "mctx") (PVar "isIndex") (PVar "r1") (PVar "r2")) (EBlock (DoLet false false (PVar "fa") (EApp (EVar "rowFlat") (EVar "r1"))) (DoLet false false (PVar "fb") (EApp (EVar "rowFlat") (EVar "r2"))) (DoLet false false (PVar "ma") (EApp (EVar "snd") (EVar "fa"))) (DoLet false false (PVar "mb") (EApp (EVar "snd") (EVar "fb"))) (DoLet false false (PVar "idsA") (EApp (EVar "cellIdSet") (EVar "ma"))) (DoLet false false (PVar "idsB") (EApp (EVar "cellIdSet") (EVar "mb"))) (DoLet false false (PVar "common") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EApp (EVar "IdMap.has") (EApp (EVar "effvarId") (EVar "c"))) (EVar "idsB")))) (EVar "ma"))) (DoLet false false (PVar "cflex") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "not") (EApp (EApp (EVar "isRigidCell") (EVar "mctx")) (EVar "c"))))) (EVar "common"))) (DoLet false false (PVar "onlyA") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "not") (EApp (EApp (EVar "IdMap.has") (EApp (EVar "effvarId") (EVar "c"))) (EVar "idsB"))))) (EVar "ma"))) (DoLet false false (PVar "onlyB") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "not") (EApp (EApp (EVar "IdMap.has") (EApp (EVar "effvarId") (EVar "c"))) (EVar "idsA"))))) (EVar "mb"))) (DoLet false false (PVar "rigidA") (EApp (EApp (EVar "filterList") (EApp (EVar "isRigidCell") (EVar "mctx"))) (EVar "onlyA"))) (DoLet false false (PVar "flexA") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "not") (EApp (EApp (EVar "isRigidCell") (EVar "mctx")) (EVar "c"))))) (EVar "onlyA"))) (DoLet false false (PVar "rigidB") (EApp (EApp (EVar "filterList") (EApp (EVar "isRigidCell") (EVar "mctx"))) (EVar "onlyB"))) (DoLet false false (PVar "flexB") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "not") (EApp (EApp (EVar "isRigidCell") (EVar "mctx")) (EVar "c"))))) (EVar "onlyB"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EVar "isIndex") (EApp (EVar "isEmptyL") (EVar "flexA"))) (EApp (EVar "isEmptyL") (EVar "flexB"))) (EApp (EVar "isEmptyL") (EVar "cflex"))) (EApp (EApp (EApp (EVar "unifyIndexAtomAuthorities") (EVar "mctx")) (EApp (EVar "fst") (EVar "fa"))) (EApp (EVar "fst") (EVar "fb"))) (ELit LUnit))) (DoLet false false (PVar "dA") (EApp (EApp (EVar "atomsDiff") (EApp (EVar "fst") (EVar "fa"))) (EApp (EVar "fst") (EVar "fb")))) (DoLet false false (PVar "dB") (EApp (EApp (EVar "atomsDiff") (EApp (EVar "fst") (EVar "fb"))) (EApp (EVar "fst") (EVar "fa")))) (DoLet false false (PVar "bindC") (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "cflex")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "rigidA")) (EApp (EVar "isEmptyL") (EVar "flexB"))) (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "rigidB")) (EApp (EVar "isEmptyL") (EVar "flexA")))) (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "dA")) (EApp (EVar "isEmptyL") (EVar "flexB")))) (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "dB")) (EApp (EVar "isEmptyL") (EVar "flexA")))))) (DoLet false false (PVar "useV3") (EBinOp "||" (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "flexA")) (EApp (EVar "isNonEmptyL") (EVar "flexB"))) (EVar "bindC"))) (DoLet false false (PVar "v3s") (EIf (EVar "useV3") (EListLit (EApp (EApp (EVar "freshEffvarAt") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EVar "minLevelOf") (EBinOp "++" (EBinOp "++" (EVar "flexA") (EVar "flexB")) (EVar "cflex"))))) (EListLit))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "rigidA")) (EApp (EVar "isEmptyL") (EVar "flexB"))) (EApp (EVar "not") (EVar "bindC"))) (EApp (EApp (EApp (EApp (EVar "joinMismatch") (EVar "mctx")) (EVar "isIndex")) (EVar "fa")) (EVar "fb")) (ELit LUnit))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "rigidB")) (EApp (EVar "isEmptyL") (EVar "flexA"))) (EApp (EVar "not") (EVar "bindC"))) (EApp (EApp (EApp (EApp (EVar "joinMismatch") (EVar "mctx")) (EVar "isIndex")) (EVar "fa")) (EVar "fb")) (ELit LUnit))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "dA")) (EApp (EVar "isEmptyL") (EVar "flexB"))) (EApp (EVar "not") (EVar "bindC"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "joinSideCheck") (EVar "mctx")) (EVar "isIndex")) (EVar "dA")) (EVar "dB")) (EApp (EVar "fst") (EVar "fa"))) (EApp (EVar "fst") (EVar "fb"))) (ELit LUnit))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "dB")) (EApp (EVar "isEmptyL") (EVar "flexA"))) (EApp (EVar "not") (EVar "bindC"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "joinSideCheck") (EVar "mctx")) (EVar "isIndex")) (EVar "dB")) (EVar "dA")) (EApp (EVar "fst") (EVar "fb"))) (EApp (EVar "fst") (EVar "fa"))) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "bindEach") (EVar "flexA")) (EApp (EApp (EApp (EVar "rowOfMembers") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "dB")) (EBinOp "++" (EVar "v3s") (EVar "rigidB"))))) (DoExpr (EApp (EApp (EVar "bindEach") (EVar "flexB")) (EApp (EApp (EApp (EVar "rowOfMembers") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "dA")) (EBinOp "++" (EVar "v3s") (EVar "rigidA"))))) (DoExpr (EIf (EVar "bindC") (EApp (EApp (EVar "bindEach") (EVar "cflex")) (EApp (EApp (EApp (EVar "rowOfMembers") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "atomsUnion") (EVar "dA")) (EVar "dB"))) (EBinOp "++" (EBinOp "++" (EVar "v3s") (EVar "rigidA")) (EVar "rigidB")))) (ELit LUnit))) (DoExpr (EMatch (EVar "v3s") (arm (PCons (PVar "v3") PWild) () (EApp (EApp (EApp (EVar "recordAbsorptions") (EVar "mctx")) (EBinOp "++" (EVar "dA") (EVar "dB"))) (EVar "v3"))) (arm (PList) () (ELit LUnit))))))
(DTypeSig false "bindEach" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyCon "EffRow") (TyCon "Unit"))))
(DFunDef false "bindEach" ((PList) PWild) (ELit LUnit))
(DFunDef false "bindEach" ((PCons (PVar "c") (PVar "cs")) (PVar "row")) (EBlock (DoExpr (EApp (EApp (EVar "linkRow") (EVar "c")) (EVar "row"))) (DoExpr (EApp (EApp (EVar "bindEach") (EVar "cs")) (EVar "row")))))
(DTypeSig false "joinSideCheck" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "Unit"))))))))
(DFunDef false "joinSideCheck" ((PVar "mctx") (PCon "True") (PVar "dOpen") PWild (PVar "lOpen") (PVar "lClosed")) (EApp (EApp (EApp (EApp (EApp (EVar "indexRowEqCheck") (EVar "mctx")) (EApp (EApp (EApp (EVar "indexAtomsCovered") (EVar "mctx")) (EVar "dOpen")) (EVar "lClosed"))) (EListLit)) (EVar "lOpen")) (EVar "lClosed")))
(DFunDef false "joinSideCheck" ((PVar "mctx") (PCon "False") PWild PWild (PVar "lOpen") (PVar "lClosed")) (EApp (EApp (EApp (EVar "effectLeakCheck") (EVar "mctx")) (EApp (EApp (EApp (EVar "atomsEscape") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "lOpen")) (EVar "lClosed"))) (EVar "lClosed")))
(DTypeSig false "joinMismatch" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyCon "Unit"))))))
(DFunDef false "joinMismatch" ((PVar "mctx") (PVar "isIndex") (PVar "fa") (PVar "fb")) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (EIf (EVar "isIndex") (ELit (LString "T-EFFECT-INDEX-MISMATCH")) (ELit (LString "T-EFFECT-LEAK")))) (EApp (EApp (EVar "joinMismatchMsg") (EApp (EVar "renderFlatRow") (EVar "fa"))) (EApp (EVar "renderFlatRow") (EVar "fb")))))
(DTypeSig false "unifyRowPlain" (TyFun (TyCon "DynCtx") (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Unit")))))
(DFunDef false "unifyRowPlain" ((PVar "dyn") (PCon "EffRow" (PVar "l1") (PCon "Some" (PVar "v1"))) (PCon "EffRow" (PVar "l2") (PCon "Some" (PVar "v2")))) (EIf (EBinOp "==" (EApp (EVar "effvarId") (EVar "v1")) (EApp (EVar "effvarId") (EVar "v2"))) (EBlock (DoLet false false (PVar "missing") (EApp (EApp (EVar "atomsUnion") (EApp (EApp (EVar "atomsDiff") (EVar "l1")) (EVar "l2"))) (EApp (EApp (EVar "atomsDiff") (EVar "l2")) (EVar "l1")))) (DoExpr (EMatch (EVar "missing") (arm (PList) () (ELit LUnit)) (arm PWild () (EIf (EApp (EApp (EVar "isRigidCell") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "v1")) (EApp (EApp (EApp (EVar "pushTypeError") (EFieldAccess (EVar "dyn") "dcModule")) (ELit (LString "T-EFFECT-LAUNDER"))) (EBinOp "++" (EBinOp "++" (ELit (LString "a caller-chosen effect row cannot be required to contain <")) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "missing")))) (ELit (LString ">; declare those effects as labels beside the row variable")))) (EBlock (DoLet false false (PVar "next") (EApp (EApp (EVar "freshEffvarAt") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph")) (EApp (EVar "effvarLevel") (EVar "v1")))) (DoExpr (EApp (EApp (EVar "linkRow") (EVar "v1")) (EApp (EApp (EVar "EffRow") (EVar "missing")) (EApp (EVar "Some") (EVar "next"))))) (DoExpr (EApp (EApp (EApp (EVar "recordAbsorptions") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "missing")) (EVar "next"))))))))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "v3") (EApp (EApp (EVar "freshEffvarAt") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph")) (EApp (EApp (EVar "minI") (EApp (EVar "effvarLevel") (EVar "v1"))) (EApp (EVar "effvarLevel") (EVar "v2"))))) (DoLet false false (PVar "d21") (EApp (EApp (EVar "atomsDiff") (EVar "l2")) (EVar "l1"))) (DoLet false false (PVar "d12") (EApp (EApp (EVar "atomsDiff") (EVar "l1")) (EVar "l2"))) (DoExpr (EIf (EBinOp "||" (EApp (EApp (EVar "isRigidCell") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "v1")) (EApp (EApp (EVar "isRigidCell") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "v2"))) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "rigidEffvarsRef")) (EApp (EApp (EApp (EVar "IdMap.set") (EApp (EVar "effvarId") (EVar "v3"))) (ELit LUnit)) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "rigidEffvarsRef") "value"))) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "linkRow") (EVar "v1")) (EApp (EApp (EVar "EffRow") (EVar "d21")) (EApp (EVar "Some") (EVar "v3"))))) (DoExpr (EApp (EApp (EVar "linkRow") (EVar "v2")) (EApp (EApp (EVar "EffRow") (EVar "d12")) (EApp (EVar "Some") (EVar "v3"))))) (DoExpr (EApp (EApp (EApp (EVar "recordAbsorptions") (EFieldAccess (EVar "dyn") "dcModule")) (EBinOp "++" (EVar "d21") (EVar "d12"))) (EVar "v3")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "unifyRowPlain" ((PVar "dyn") (PCon "EffRow" (PVar "l1") (PCon "Some" (PVar "v1"))) (PCon "EffRow" (PVar "l2") (PCon "None"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "effectLeakCheck") (EFieldAccess (EVar "dyn") "dcModule")) (EApp (EApp (EApp (EVar "atomsEscape") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph")) (EVar "l1")) (EVar "l2"))) (EVar "l2"))) (DoExpr (EApp (EApp (EVar "linkRow") (EVar "v1")) (EApp (EApp (EVar "EffRow") (EApp (EApp (EVar "atomsDiff") (EVar "l2")) (EVar "l1"))) (EVar "None"))))))
(DFunDef false "unifyRowPlain" ((PVar "dyn") (PCon "EffRow" (PVar "l1") (PCon "None")) (PCon "EffRow" (PVar "l2") (PCon "Some" (PVar "v2")))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "effectLeakCheck") (EFieldAccess (EVar "dyn") "dcModule")) (EApp (EApp (EApp (EVar "atomsEscape") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph")) (EVar "l2")) (EVar "l1"))) (EVar "l1"))) (DoExpr (EApp (EApp (EVar "linkRow") (EVar "v2")) (EApp (EApp (EVar "EffRow") (EApp (EApp (EVar "atomsDiff") (EVar "l1")) (EVar "l2"))) (EVar "None"))))))
(DFunDef false "unifyRowPlain" ((PVar "dyn") (PCon "EffRow" (PVar "l1") (PCon "None")) (PCon "EffRow" (PVar "l2") (PCon "None"))) (EApp (EApp (EApp (EVar "closedRowEqCheck") (EVar "dyn")) (EVar "l1")) (EVar "l2")))
(DTypeSig false "unifyIndexRow" (TyFun (TyCon "DynCtx") (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Unit")))))
(DFunDef false "unifyIndexRow" ((PVar "dyn") (PVar "r1") (PVar "r2")) (EApp (EApp (EApp (EVar "unifyIndexRowN") (EVar "dyn")) (EApp (EVar "effrowNorm") (EVar "r1"))) (EApp (EVar "effrowNorm") (EVar "r2"))))
(DTypeSig false "unifyIndexAtomAuthorities" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "Unit")))))
(DFunDef false "unifyIndexAtomAuthorities" ((PVar "mctx") (PVar "a1") (PVar "a2")) (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "x")) (EMatch (EApp (EApp (EVar "findAtom") (EApp (EVar "atomKey") (EVar "x"))) (EVar "a2")) (arm (PCon "Some" (PVar "y")) () (EApp (EApp (EApp (EVar "unifyIndex") (EVar "mctx")) (EApp (EVar "atomAuth") (EVar "x"))) (EApp (EVar "atomAuth") (EVar "y")))) (arm (PCon "None") () (ELit LUnit))))) (ELit LUnit)) (EVar "a1")))
(DTypeSig false "unifyIndexRowN" (TyFun (TyCon "DynCtx") (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Unit")))))
(DFunDef false "unifyIndexRowN" ((PVar "dyn") (PVar "r1") (PVar "r2")) (EIf (EBinOp "||" (EApp (EVar "rowHasSummary") (EVar "r1")) (EApp (EVar "rowHasSummary") (EVar "r2"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "deferEffectRelation") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "True")) (EVar "r1")) (EVar "r2"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "deferEffectRelation") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "True")) (EVar "r2")) (EVar "r1")))) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "rowTailIsJoin") (EVar "r1")) (EApp (EVar "rowTailIsJoin") (EVar "r2"))) (EApp (EApp (EVar "rowHasRigid") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "r1"))) (EApp (EApp (EVar "rowHasRigid") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "r2"))) (EApp (EApp (EApp (EApp (EVar "unifyJoinRows") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "True")) (EVar "r1")) (EVar "r2")) (EApp (EApp (EApp (EVar "unifyIndexRowPlain") (EVar "dyn")) (EVar "r1")) (EVar "r2")))))
(DTypeSig false "unifyIndexRowPlain" (TyFun (TyCon "DynCtx") (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Unit")))))
(DFunDef false "unifyIndexRowPlain" ((PVar "dyn") (PCon "EffRow" (PVar "l1") (PCon "None")) (PCon "EffRow" (PVar "l2") (PCon "None"))) (EApp (EApp (EApp (EVar "indexRowEquate") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "l1")) (EVar "l2")))
(DFunDef false "unifyIndexRowPlain" ((PVar "dyn") (PCon "EffRow" (PVar "l1") (PCon "Some" (PVar "v1"))) (PCon "EffRow" (PVar "l2") (PCon "Some" (PVar "v2")))) (EIf (EBinOp "==" (EApp (EVar "effvarId") (EVar "v1")) (EApp (EVar "effvarId") (EVar "v2"))) (EApp (EApp (EApp (EVar "indexRowEquate") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "l1")) (EVar "l2")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "unifyIndexRowPlain" ((PVar "dyn") (PCon "EffRow" (PVar "l1") (PCon "Some" (PVar "v1"))) (PCon "EffRow" (PVar "l2") (PCon "None"))) (EApp (EApp (EApp (EApp (EVar "indexOpenClosed") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "l1")) (EVar "v1")) (EVar "l2")))
(DFunDef false "unifyIndexRowPlain" ((PVar "dyn") (PCon "EffRow" (PVar "l1") (PCon "None")) (PCon "EffRow" (PVar "l2") (PCon "Some" (PVar "v2")))) (EApp (EApp (EApp (EApp (EVar "indexOpenClosed") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "l2")) (EVar "v2")) (EVar "l1")))
(DFunDef false "unifyIndexRowPlain" ((PVar "dyn") (PVar "r1") (PVar "r2")) (EApp (EApp (EApp (EVar "unifyRowPlain") (EVar "dyn")) (EVar "r1")) (EVar "r2")))
(DTypeSig false "indexRowEquate" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "Unit")))))
(DFunDef false "indexRowEquate" ((PVar "mctx") (PVar "l1") (PVar "l2")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "unifyIndexAtomAuthorities") (EVar "mctx")) (EVar "l1")) (EVar "l2"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "indexRowEqCheck") (EVar "mctx")) (EApp (EApp (EVar "labelsMissing") (EVar "l1")) (EVar "l2"))) (EApp (EApp (EVar "labelsMissing") (EVar "l2")) (EVar "l1"))) (EVar "l1")) (EVar "l2")))))
(DTypeSig false "indexOpenClosed" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "Unit"))))))
(DFunDef false "indexOpenClosed" ((PVar "mctx") (PVar "lOpen") (PVar "v") (PVar "lClosed")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "effectLeakCheck") (EVar "mctx")) (EApp (EApp (EApp (EVar "indexAtomsCovered") (EVar "mctx")) (EApp (EApp (EApp (EVar "atomsEscape") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "lOpen")) (EVar "lClosed"))) (EVar "lClosed"))) (EVar "lClosed"))) (DoExpr (EApp (EApp (EVar "linkRow") (EVar "v")) (EApp (EApp (EVar "EffRow") (EApp (EApp (EVar "atomsDiff") (EVar "lClosed")) (EVar "lOpen"))) (EVar "None"))))))
(DTypeSig false "indexAtomsCovered" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom"))))))
(DFunDef false "indexAtomsCovered" ((PVar "mctx") (PList) PWild) (EListLit))
(DFunDef false "indexAtomsCovered" ((PVar "mctx") (PCons (PVar "x") (PVar "rest")) (PVar "bound")) (EMatch (EApp (EApp (EVar "findAtom") (EApp (EVar "atomKey") (EVar "x"))) (EVar "bound")) (arm (PCon "Some" (PVar "y")) () (EBlock (DoExpr (EApp (EApp (EApp (EVar "wantIndexCovered") (EVar "mctx")) (EApp (EVar "atomAuth") (EVar "x"))) (EApp (EVar "atomAuth") (EVar "y")))) (DoExpr (EApp (EApp (EApp (EVar "indexAtomsCovered") (EVar "mctx")) (EVar "rest")) (EVar "bound"))))) (arm (PCon "None") () (EBinOp "::" (EVar "x") (EApp (EApp (EApp (EVar "indexAtomsCovered") (EVar "mctx")) (EVar "rest")) (EVar "bound"))))))
(DTypeSig false "labelsMissing" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "labelsMissing" ((PVar "l1") (PVar "l2")) (EApp (EApp (EVar "filterList") (ELam ((PVar "x")) (EMatch (EApp (EApp (EVar "findAtom") (EApp (EVar "atomKey") (EVar "x"))) (EVar "l2")) (arm (PCon "Some" PWild) () (EVar "False")) (arm (PCon "None") () (EVar "True"))))) (EVar "l1")))
(DTypeSig false "indexRowEqCheck" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "Unit")))))))
(DFunDef false "indexRowEqCheck" ((PVar "mctx") (PList) (PList) PWild PWild) (ELit LUnit))
(DFunDef false "indexRowEqCheck" ((PVar "mctx") PWild PWild (PVar "l1") (PVar "l2")) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-EFFECT-INDEX-MISMATCH"))) (EApp (EApp (EVar "indexRowMismatchMsg") (EVar "l1")) (EVar "l2"))))
(DTypeSig true "effectLeakCheck" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "Unit")))))
(DFunDef false "effectLeakCheck" ((PVar "mctx") (PList) (PVar "bound")) (ELit LUnit))
(DFunDef false "effectLeakCheck" ((PVar "mctx") (PVar "escaping") (PVar "bound")) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-EFFECT-LEAK"))) (EApp (EApp (EApp (EVar "effectLeakMsg") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "bound")) (EVar "escaping"))))
(DTypeSig false "closedRowEqCheck" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "Unit")))))
(DFunDef false "closedRowEqCheck" ((PVar "dyn") (PVar "l1") (PVar "l2")) (EMatch (ETuple (EApp (EApp (EApp (EVar "atomsEscape") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph")) (EVar "l1")) (EVar "l2")) (EApp (EApp (EApp (EVar "atomsEscape") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph")) (EVar "l2")) (EVar "l1"))) (arm (PTuple (PList) (PList)) () (ELit LUnit)) (arm PWild () (EIf (EFieldAccess (EVar "dyn") "dcNonCovariant") (EApp (EApp (EApp (EVar "pushTypeError") (EFieldAccess (EVar "dyn") "dcModule")) (ELit (LString "T-EFFECT-PARAM-VARIANCE"))) (EApp (EApp (EVar "paramVarianceMismatchMsg") (EVar "l1")) (EVar "l2"))) (EApp (EApp (EApp (EVar "pushTypeError") (EFieldAccess (EVar "dyn") "dcModule")) (ELit (LString "T-EFFECT-LEAK"))) (EApp (EApp (EVar "closedRowMismatchMsg") (EVar "l1")) (EVar "l2")))))))
(DTypeSig false "effectLeakMsg" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))))
(DFunDef false "effectLeakMsg" ((PVar "gctx") (PVar "bound") (PVar "extras")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "performs <")) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "extras")))) (ELit (LString "> where only <"))) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "bound")))) (ELit (LString "> is allowed"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "ioJoinClause") (EVar "gctx")) (EBinOp "++" (EVar "bound") (EVar "extras"))))) (ELit (LString ""))))
(DTypeSig false "ioJoinClause" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String"))))
(DFunDef false "ioJoinClause" ((PVar "gctx") (PVar "atoms")) (EBlock (DoLet false false (PVar "join") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "config") "value") "tcIoJoin")) (DoLet false false (PVar "full") (EApp (EApp (EMethodRef "map") (EApp (EVar "atomOfLabel") (EFieldAccess (EFieldAccess (EVar "gctx") "effectDomains") "value"))) (EVar "hostLabels"))) (DoExpr (EIf (EBinOp "&&" (EApp (EVar "isSome") (EApp (EApp (EVar "findAtom") (EApp (EVar "labelKey") (EVar "ioLabel"))) (EVar "atoms"))) (EApp (EVar "isNonEmptyL") (EApp (EApp (EVar "atomsDiff") (EVar "full")) (EVar "join")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "; `IO` on `")) (EApp (EMethodRef "display") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "config") "value") "tcIoJoinProfile"))) (ELit (LString "` is <"))) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "join")))) (ELit (LString ">"))) (ELit (LString ""))))))
(DTypeSig true "lowerRowLevels" (TyFun (TyCon "Int") (TyFun (TyCon "EffRow") (TyCon "Unit"))))
(DFunDef false "lowerRowLevels" ((PVar "level") (PVar "r")) (EBlock (DoLet false false (PTuple (PVar "atoms") (PVar "members")) (EApp (EVar "rowFlat") (EVar "r"))) (DoExpr (EApp (EApp (EVar "lowerMembers") (EVar "level")) (EVar "members"))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "a")) (EApp (EApp (EVar "lowerAuthLevels") (EVar "level")) (EApp (EVar "atomAuth") (EVar "a"))))) (ELit LUnit)) (EVar "atoms")))))
(DTypeSig false "lowerMembers" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyCon "Unit"))))
(DFunDef false "lowerMembers" (PWild (PList)) (ELit LUnit))
(DFunDef false "lowerMembers" ((PVar "level") (PCons (PVar "m") (PVar "ms"))) (EBlock (DoExpr (EMatch (EUnOp "!" (EVar "m")) (arm (PCon "EUnbound" (PVar "id") (PVar "lvl")) () (EIf (EBinOp ">" (EVar "lvl") (EVar "level")) (EApp (EApp (EVar "setRef") (EVar "m")) (EApp (EApp (EVar "EUnbound") (EVar "id")) (EVar "level"))) (ELit LUnit))) (arm PWild () (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "lowerMembers") (EVar "level")) (EVar "ms")))))
(DTypeSig false "freeEffvars" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "freeEffvars" ((PVar "mctx") (PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TVar" (PVar "cell")) () (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Link" (PVar "t2")) () (EApp (EApp (EVar "freeEffvars") (EVar "mctx")) (EVar "t2"))) (arm (PCon "Unbound" PWild PWild) () (EListLit)))) (arm (PCon "TCon" PWild PWild) () (EListLit)) (arm (PCon "TRigid" PWild) () (EListLit)) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EBinOp "++" (EApp (EApp (EVar "freeEffvars") (EVar "mctx")) (EVar "a")) (EApp (EApp (EVar "freeEffvars") (EVar "mctx")) (EVar "b")))) (arm (PCon "TFun" (PVar "a") (PVar "r") (PVar "b")) () (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "freeEffvars") (EVar "mctx")) (EVar "a")) (EApp (EApp (EVar "rowFreeEffvars") (EVar "mctx")) (EVar "r"))) (EApp (EApp (EVar "freeEffvars") (EVar "mctx")) (EVar "b")))) (arm (PCon "TEff" (PVar "r")) () (EApp (EApp (EVar "rowFreeEffvars") (EVar "mctx")) (EVar "r"))) (arm (PCon "TQual" (PVar "a") PWild) () (EApp (EApp (EVar "freeEffvars") (EVar "mctx")) (EVar "a"))) (arm (PCon "TAuth" PWild) () (EListLit))))
(DTypeSig false "rowFreeEffvars" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "EffRow") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "rowFreeEffvars" ((PVar "mctx") (PVar "r")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "generalizableEffvar") (EVar "mctx"))) (EApp (EVar "snd") (EApp (EVar "rowFlat") (EVar "r")))))
(DTypeSig false "generalizableEffvar" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "generalizableEffvar" ((PVar "mctx") (PVar "v")) (EMatch (EUnOp "!" (EVar "v")) (arm (PCon "EUnbound" (PVar "id") (PVar "lvl")) () (EIf (EBinOp ">" (EVar "lvl") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (EListLit (EVar "id")) (EListLit))) (arm (PCon "ELink" PWild PWild) () (EListLit)) (arm (PCon "EJoin" PWild PWild PWild) () (EListLit)) (arm (PCon "ESummary" PWild PWild PWild) () (EListLit))))
(DTypeSig true "predicateSlotCSlots" (TyFun (TyApp (TyCon "List") (TyCon "PredicateSlot")) (TyApp (TyCon "List") (TyCon "CSlot"))))
(DFunDef false "predicateSlotCSlots" ((PList)) (EListLit))
(DFunDef false "predicateSlotCSlots" ((PCons (PVar "s") (PVar "rest"))) (EMatch (EFieldAccess (EVar "s") "psBoundIds") (arm (PCons (PVar "id") PWild) () (EBinOp "::" (ERecordCreate "CSlot" ((fa "csIface" (EFieldAccess (EVar "s") "psIface")) (fa "csId" (EVar "id")))) (EApp (EVar "predicateSlotCSlots") (EVar "rest")))) (arm PWild () (EApp (EVar "predicateSlotCSlots") (EVar "rest")))))
(DTypeSig true "predicateSlotArgs" (TyFun (TyApp (TyCon "List") (TyCon "PredicateSlot")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "predicateSlotArgs" ((PList)) (EListLit))
(DFunDef false "predicateSlotArgs" ((PCons (PVar "slot") (PVar "rest"))) (EMatch (EFieldAccess (EVar "slot") "psArgs") (arm (PCon "PSArgsUnknown") () (EListLit)) (arm (PCon "PSArgsKnown" (PVar "args")) () (EBinOp "::" (EVar "args") (EApp (EVar "predicateSlotArgs") (EVar "rest"))))))
(DTypeSig true "recordObl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Predicate") (TyFun (TyCon "Int") (TyFun (TyCon "Provenance") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit")))))))
(DFunDef false "recordObl" ((PVar "mctx") (PVar "p") (PVar "originId") (PVar "prov") (PVar "loc")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordOblAt") (EVar "mctx")) (EVar "p")) (EVar "originId")) (EVar "prov")) (EVar "loc")) (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))))
(DTypeSig true "recordOblAt" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Predicate") (TyFun (TyCon "Int") (TyFun (TyCon "Provenance") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ScopeId") (TyCon "Unit"))))))))
(DFunDef false "recordOblAt" ((PVar "mctx") (PVar "p") (PVar "originId") (PVar "prov") (PVar "loc") (PVar "scope")) (EApp (EApp (EVar "wPush") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "obls")) (ERecordCreate "UObligation" ((fa "pred" (EVar "p")) (fa "originId" (EVar "originId")) (fa "prov" (EVar "prov")) (fa "loc" (EVar "loc")) (fa "uoScope" (EVar "scope")) (fa "oblProj" (EVar "OpProjected"))))))
(DTypeSig false "recordAbsorptions" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyCon "Unit")))))
(DFunDef false "recordAbsorptions" ((PVar "mctx") (PList) PWild) (ELit LUnit))
(DFunDef false "recordAbsorptions" ((PVar "mctx") (PCons (PVar "a") (PVar "rest")) (PVar "cell")) (EBlock (DoExpr (EApp (EApp (EVar "wPush") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "absorptions")) (ERecordCreate "AbsorptionEvent" ((fa "atom" (EVar "a")) (fa "cell" (EVar "cell")) (fa "loc" (EFieldAccess (EVar "mctx") "mcLoc")))))) (DoExpr (EApp (EApp (EApp (EVar "recordAbsorptions") (EVar "mctx")) (EVar "rest")) (EVar "cell")))))
(DTypeSig true "captureScope" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "ScopeId"))))
(DFunDef false "captureScope" ((PVar "mctx") PWild) (EApp (EVar "Scopes.captureScopeCursor") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentScope") "value")))
(DTypeSig false "tyvarLevel" (TyFun (TyApp (TyCon "Ref") (TyCon "Tyvar")) (TyCon "Int")))
(DFunDef false "tyvarLevel" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Unbound" PWild (PVar "lvl")) () (EVar "lvl")) (arm (PCon "Link" PWild) () (ELit (LInt 0)))))
(DTypeSig false "occursAdjust" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyCon "Unit"))))))
(DFunDef false "occursAdjust" ((PVar "mctx") (PVar "id") (PVar "level") (PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TVar" (PVar "cell")) () (EApp (EApp (EApp (EApp (EVar "occursAdjustVar") (EVar "mctx")) (EVar "id")) (EVar "level")) (EVar "cell"))) (arm (PCon "TCon" PWild PWild) () (ELit LUnit)) (arm (PCon "TRigid" PWild) () (ELit LUnit)) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "occursAdjust") (EVar "mctx")) (EVar "id")) (EVar "level")) (EVar "a"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "occursAdjust") (EVar "mctx")) (EVar "id")) (EVar "level")) (EVar "b"))))) (arm (PCon "TFun" (PVar "a") (PVar "r") (PVar "b")) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "occursAdjust") (EVar "mctx")) (EVar "id")) (EVar "level")) (EVar "a"))) (DoExpr (EApp (EApp (EVar "lowerRowLevels") (EVar "level")) (EVar "r"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "occursAdjust") (EVar "mctx")) (EVar "id")) (EVar "level")) (EVar "b"))))) (arm (PCon "TEff" (PVar "r")) () (EApp (EApp (EVar "lowerRowLevels") (EVar "level")) (EVar "r"))) (arm (PCon "TQual" (PVar "a") (PVar "q")) () (EBlock (DoExpr (EApp (EApp (EVar "lowerAuthLevels") (EVar "level")) (EVar "q"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "occursAdjust") (EVar "mctx")) (EVar "id")) (EVar "level")) (EVar "a"))))) (arm (PCon "TAuth" (PVar "q")) () (EApp (EApp (EVar "lowerAuthLevels") (EVar "level")) (EVar "q")))))
(DTypeSig false "occursAdjustVar" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyCon "Tyvar")) (TyCon "Unit"))))))
(DFunDef false "occursAdjustVar" ((PVar "mctx") (PVar "id") (PVar "level") (PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Unbound" (PVar "id2") (PVar "lvl2")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "occursAdjustUnbound") (EVar "mctx")) (EVar "id")) (EVar "level")) (EVar "cell")) (EVar "id2")) (EVar "lvl2"))) (arm (PCon "Link" (PVar "t")) () (EApp (EApp (EApp (EApp (EVar "occursAdjust") (EVar "mctx")) (EVar "id")) (EVar "level")) (EVar "t")))))
(DTypeSig false "occursAdjustUnbound" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyCon "Tyvar")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Unit"))))))))
(DFunDef false "occursAdjustUnbound" ((PVar "mctx") (PVar "id") (PVar "level") (PVar "cell") (PVar "id2") (PVar "lvl2")) (EIf (EBinOp "==" (EVar "id2") (EVar "id")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "occursCheckFailed")) (EVar "True"))) (DoExpr (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-INFINITE-TYPE"))) (EBinOp "++" (EBinOp "++" (ELit (LString "cannot construct an infinite type involving `")) (EApp (EVar "ppMono") (EApp (EVar "TVar") (EVar "cell")))) (ELit (LString "`")))))) (EIf (EBinOp ">" (EVar "lvl2") (EVar "level")) (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EApp (EVar "Unbound") (EVar "id2")) (EVar "level"))) (EIf (EVar "otherwise") (ELit LUnit) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "unify" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "unify" ((PVar "mctx") (PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "unifyIn") (EApp (EVar "dynFor") (EVar "mctx"))) (EVar "a")) (EVar "b")))
(DTypeSig true "unifyIn" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "unifyIn" ((PVar "dyn") (PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "unifyValue") (EVar "dyn")) (EApp (EVar "normalize") (EVar "a"))) (EApp (EVar "normalize") (EVar "b"))))
(DTypeSig false "unifyValue" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "unifyValue" ((PVar "dyn") (PCon "TVar" (PVar "c")) (PCon "TQual" (PVar "a") PWild)) (EApp (EApp (EApp (EVar "unifyN") (EVar "dyn")) (EApp (EVar "TVar") (EVar "c"))) (EApp (EVar "normalize") (EVar "a"))))
(DFunDef false "unifyValue" ((PVar "dyn") (PCon "TQual" (PVar "a") PWild) (PCon "TVar" (PVar "c"))) (EApp (EApp (EApp (EVar "unifyN") (EVar "dyn")) (EApp (EVar "normalize") (EVar "a"))) (EApp (EVar "TVar") (EVar "c"))))
(DFunDef false "unifyValue" ((PVar "dyn") (PCon "TQual" (PVar "a") PWild) (PCon "TQual" (PVar "b") PWild)) (EApp (EApp (EApp (EVar "unifyN") (EVar "dyn")) (EApp (EVar "normalize") (EVar "a"))) (EApp (EVar "normalize") (EVar "b"))))
(DFunDef false "unifyValue" ((PVar "dyn") (PCon "TQual" (PVar "a") PWild) (PVar "b")) (EApp (EApp (EApp (EVar "unifyN") (EVar "dyn")) (EApp (EVar "normalize") (EVar "a"))) (EVar "b")))
(DFunDef false "unifyValue" ((PVar "dyn") (PVar "a") (PCon "TQual" (PVar "b") PWild)) (EApp (EApp (EApp (EVar "unifyN") (EVar "dyn")) (EVar "a")) (EApp (EVar "normalize") (EVar "b"))))
(DFunDef false "unifyValue" ((PVar "dyn") (PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "unifyN") (EVar "dyn")) (EVar "a")) (EVar "b")))
(DTypeSig false "unifyStruct" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "unifyStruct" ((PVar "dyn") (PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "unifyN") (EVar "dyn")) (EApp (EVar "normalize") (EVar "a"))) (EApp (EVar "normalize") (EVar "b"))))
(DTypeSig false "unifyN" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "unifyN" ((PVar "dyn") (PCon "TVar" (PVar "c1")) (PCon "TVar" (PVar "c2"))) (EApp (EApp (EApp (EVar "unifyVars") (EVar "dyn")) (EVar "c1")) (EVar "c2")))
(DFunDef false "unifyN" ((PVar "dyn") (PCon "TVar" (PVar "c")) (PVar "t")) (EApp (EApp (EApp (EVar "bindVar") (EVar "dyn")) (EVar "c")) (EVar "t")))
(DFunDef false "unifyN" ((PVar "dyn") (PVar "t") (PCon "TVar" (PVar "c"))) (EApp (EApp (EApp (EVar "bindVar") (EVar "dyn")) (EVar "c")) (EVar "t")))
(DFunDef false "unifyN" ((PVar "dyn") (PAs "ta" (PCon "TCon" (PVar "a") (PVar "oa"))) (PAs "tb" (PCon "TCon" (PVar "b") (PVar "ob")))) (EIf (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EVar "a")) (EVar "oa")) (EVar "b")) (EVar "ob")) (ELit LUnit) (EApp (EApp (EApp (EVar "typeMismatch") (EVar "dyn")) (EVar "ta")) (EVar "tb"))))
(DFunDef false "unifyN" ((PVar "dyn") (PCon "TRigid" (PVar "a")) (PCon "TRigid" (PVar "b"))) (EIf (EBinOp "==" (EVar "a") (EVar "b")) (ELit LUnit) (EApp (EApp (EApp (EVar "typeMismatch") (EVar "dyn")) (EApp (EVar "TRigid") (EVar "a"))) (EApp (EVar "TRigid") (EVar "b")))))
(DFunDef false "unifyN" ((PVar "dyn") (PAs "ta" (PCon "TCon" (PVar "a") PWild)) (PAs "tb" (PCon "TRigid" (PVar "b")))) (EIf (EBinOp "==" (EVar "a") (EVar "b")) (ELit LUnit) (EApp (EApp (EApp (EVar "typeMismatch") (EVar "dyn")) (EVar "ta")) (EVar "tb"))))
(DFunDef false "unifyN" ((PVar "dyn") (PAs "ta" (PCon "TRigid" (PVar "a"))) (PAs "tb" (PCon "TCon" (PVar "b") PWild))) (EIf (EBinOp "==" (EVar "a") (EVar "b")) (ELit LUnit) (EApp (EApp (EApp (EVar "typeMismatch") (EVar "dyn")) (EVar "ta")) (EVar "tb"))))
(DFunDef false "unifyN" ((PVar "dyn") (PVar "t1") (PVar "t2")) (EIf (EApp (EApp (EVar "tupleUnifyClash") (EVar "t1")) (EVar "t2")) (EApp (EApp (EApp (EVar "typeMismatch") (EVar "dyn")) (EVar "t1")) (EVar "t2")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "unifyN" ((PVar "dyn") (PCon "TApp" (PVar "a1") (PVar "b1")) (PCon "TApp" (PVar "a2") (PVar "b2"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "unifyStruct") (EVar "dyn")) (EVar "a1")) (EVar "a2"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "paramVarianceGuard") (EVar "dyn")) (EVar "a1")) (EVar "b1")) (EVar "b2")))))
(DFunDef false "unifyN" ((PVar "dyn") (PCon "TFun" (PVar "a1") (PVar "r1") (PVar "b1")) (PCon "TFun" (PVar "a2") (PVar "r2") (PVar "b2"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "unifyStruct") (EVar "dyn")) (EVar "a1")) (EVar "a2"))) (DoExpr (EApp (EApp (EApp (EVar "unifyRow") (EVar "dyn")) (EVar "r1")) (EVar "r2"))) (DoExpr (EApp (EApp (EApp (EVar "unifyStruct") (EVar "dyn")) (EVar "b1")) (EVar "b2")))))
(DFunDef false "unifyN" ((PVar "dyn") (PCon "TEff" (PVar "r1")) (PCon "TEff" (PVar "r2"))) (EApp (EApp (EApp (EVar "unifyIndexRow") (EVar "dyn")) (EVar "r1")) (EVar "r2")))
(DFunDef false "unifyN" ((PVar "dyn") (PCon "TAuth" (PVar "qa")) (PCon "TAuth" (PVar "qb"))) (EApp (EApp (EApp (EVar "unifyIndex") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "qa")) (EVar "qb")))
(DFunDef false "unifyN" ((PVar "dyn") (PCon "TQual" (PVar "a") (PVar "qa")) (PCon "TQual" (PVar "b") (PVar "qb"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "wantAuthority") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "qa")) (EVar "qb"))) (DoExpr (EApp (EApp (EApp (EVar "wantAuthority") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "qb")) (EVar "qa"))) (DoExpr (EApp (EApp (EApp (EVar "unifyStruct") (EVar "dyn")) (EVar "a")) (EVar "b")))))
(DFunDef false "unifyN" ((PVar "dyn") (PCon "TQual" (PVar "a") (PVar "qa")) (PVar "b")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "wantAuthority") (EFieldAccess (EVar "dyn") "dcModule")) (EApp (EVar "authTop") (EApp (EVar "authDomainTop") (EVar "qa")))) (EVar "qa"))) (DoExpr (EApp (EApp (EApp (EVar "unifyStruct") (EVar "dyn")) (EVar "a")) (EVar "b")))))
(DFunDef false "unifyN" ((PVar "dyn") (PVar "a") (PCon "TQual" (PVar "b") (PVar "qb"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "wantAuthority") (EFieldAccess (EVar "dyn") "dcModule")) (EApp (EVar "authTop") (EApp (EVar "authDomainTop") (EVar "qb")))) (EVar "qb"))) (DoExpr (EApp (EApp (EApp (EVar "unifyStruct") (EVar "dyn")) (EVar "a")) (EVar "b")))))
(DFunDef false "unifyN" ((PVar "dyn") (PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "typeMismatch") (EVar "dyn")) (EVar "a")) (EVar "b")))
(DTypeSig true "bindFrom" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "bindFrom" ((PVar "dyn") (PVar "target") (PVar "source")) (EMatch (EApp (EVar "normalize") (EVar "target")) (arm (PCon "TVar" (PVar "cell")) () (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Unbound" PWild PWild) () (EApp (EApp (EApp (EVar "bindVar") (EVar "dyn")) (EVar "cell")) (EVar "source"))) (arm (PCon "Link" PWild) () (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "target")) (EVar "source"))))) (arm PWild () (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "target")) (EVar "source")))))
(DTypeSig true "wantAuthority" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Unit")))))
(DFunDef false "wantAuthority" ((PVar "mctx") (PVar "lower") (PVar "upper")) (EApp (EApp (EApp (EApp (EVar "wantAuthorityWith") (EVar "mctx")) (EVar "False")) (EVar "lower")) (EVar "upper")))
(DTypeSig true "wantAuthorityWith" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Unit"))))))
(DFunDef false "wantAuthorityWith" ((PVar "mctx") (PVar "exact") (PVar "lower") (PVar "upper")) (EApp (EApp (EApp (EApp (EApp (EVar "wantAuthorityFrom") (EVar "mctx")) (EVar "None")) (EVar "exact")) (EVar "lower")) (EVar "upper")))
(DTypeSig false "wantAuthorityFrom" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Unit")))))))
(DFunDef false "wantAuthorityFrom" ((PVar "mctx") (PVar "origin") (PVar "exact") (PVar "lower") (PVar "upper")) (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "pair")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "wantAuthorityOne") (EVar "mctx")) (EVar "origin")) (EVar "exact")) (EVar "False")) (EApp (EVar "fst") (EVar "pair"))) (EApp (EVar "snd") (EVar "pair"))))) (ELit LUnit)) (EApp (EApp (EVar "authSplit") (EVar "lower")) (EVar "upper"))))
(DTypeSig false "wantIndexCovered" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Unit")))))
(DFunDef false "wantIndexCovered" ((PVar "mctx") (PVar "lower") (PVar "upper")) (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "pair")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "wantAuthorityOne") (EVar "mctx")) (EVar "None")) (EVar "True")) (EVar "True")) (EApp (EVar "fst") (EVar "pair"))) (EApp (EVar "snd") (EVar "pair"))))) (ELit LUnit)) (EApp (EApp (EVar "authSplit") (EVar "lower")) (EVar "upper"))))
(DTypeSig false "wantAuthorityOne" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Unit"))))))))
(DFunDef false "wantAuthorityOne" ((PVar "mctx") (PVar "origin") (PVar "exact") (PVar "covering") (PVar "lower") (PVar "upper")) (EIf (EApp (EVar "EffectSolver.hasSummaryScope") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "effectSummaries")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "EffectSolver.recordAuthorityFrom") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "effectSummaries")) (EVar "origin")) (EVar "exact")) (EApp (EApp (EVar "obligationSiteHere") (EVar "mctx")) (EVar "covering"))) (EApp (EVar "authNorm") (EVar "lower"))) (EApp (EVar "authNorm") (EVar "upper"))) (EIf (EApp (EApp (EVar "authSub") (EVar "lower")) (EVar "upper")) (ELit LUnit) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "solveFlexibleUpper") (EVar "mctx")) (EVar "lower")) (EVar "upper")) (arm (PCon "True") () (ELit LUnit)) (arm (PCon "False") () (EIf (EVar "exact") (EApp (EApp (EApp (EApp (EApp (EVar "reportIndexFailure") (EVar "mctx")) (EVar "covering")) (EFieldAccess (EVar "mctx") "mcLoc")) (EVar "lower")) (EVar "upper")) (EApp (EApp (EApp (EApp (EApp (EVar "reportAuthorityFailure") (EVar "mctx")) (EFieldAccess (EVar "mctx") "mcLoc")) (EVar "origin")) (EVar "lower")) (EVar "upper"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "solveFlexibleUpper" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Bool")))))
(DFunDef false "solveFlexibleUpper" ((PVar "mctx") (PVar "lower") (PVar "upper")) (EMatch (EApp (EVar "authNorm") (EVar "upper")) (arm (PCon "AVar" (PVar "cell")) () (EIf (EApp (EApp (EVar "IdMap.has") (EApp (EVar "authvarId") (EVar "cell"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "rigidAuthvarsRef") "value")) (EVar "False") (EMatch (EApp (EApp (EVar "withoutVar") (EVar "cell")) (EVar "lower")) (arm (PList) () (EVar "True")) (arm (PVar "rest") () (EBlock (DoExpr (EApp (EApp (EVar "linkAuthvar") (EVar "cell")) (EApp (EApp (EApp (EVar "widenOpenedFor") (EVar "mctx")) (EApp (EVar "authvarLevel") (EVar "cell"))) (EApp (EVar "authJoinAll") (EVar "rest"))))) (DoExpr (EVar "True"))))))) (arm PWild () (EVar "False"))))
(DTypeSig false "withoutVar" (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyFun (TyCon "Authority") (TyApp (TyCon "List") (TyCon "Authority")))))
(DFunDef false "withoutVar" ((PVar "cell") (PVar "q")) (EBlock (DoLet false false (PVar "members") (EMatch (EApp (EVar "authNorm") (EVar "q")) (arm (PCon "AJoin" (PVar "ms")) () (EVar "ms")) (arm (PVar "other") () (EListLit (EVar "other"))))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "m")) (EMatch (EVar "m") (arm (PCon "AVar" (PVar "c")) () (EBinOp "/=" (EApp (EVar "authvarId") (EVar "c")) (EApp (EVar "authvarId") (EVar "cell")))) (arm PWild () (EVar "True"))))) (EVar "members")))))
(DTypeSig true "widenOpenedFor" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyFun (TyCon "Authority") (TyCon "Authority")))))
(DFunDef false "widenOpenedFor" ((PVar "mctx") (PVar "level") (PVar "q")) (EBlock (DoLet false false (PVar "asub") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "c")) (EIf (EBinOp "&&" (EApp (EApp (EVar "IdMap.has") (EApp (EVar "authvarId") (EVar "c"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedAuthvarsRef") "value")) (EBinOp ">" (EApp (EVar "authvarLevel") (EVar "c")) (EVar "level"))) (EListLit (ETuple (EApp (EVar "authvarId") (EVar "c")) (EApp (EVar "authTop") (EApp (EVar "authvarDomain") (EVar "c"))))) (EListLit)))) (EApp (EVar "authVars") (EVar "q")))) (DoExpr (EApp (EApp (EVar "substAuth") (EVar "asub")) (EVar "q")))))
(DTypeSig false "reportAuthorityFailure" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Unit")))))))
(DFunDef false "reportAuthorityFailure" ((PVar "mctx") (PVar "loc") (PVar "origin") (PVar "lower") (PVar "upper")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (ELit (LString "T-AUTHORITY"))) (EVar "loc")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "authorityFailureMsg") (EVar "mctx")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value")) (EVar "None")) (EVar "origin")) (EVar "lower")) (EVar "upper")) (EApp (EVar "Some") (EVar "upper")))))
(DTypeSig true "reportIndexFailure" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "Unit")))))))
(DFunDef false "reportIndexFailure" ((PVar "mctx") (PVar "covering") (PVar "loc") (PVar "a") (PVar "b")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (ELit (LString "T-AUTHORITY-INDEX-MISMATCH"))) (EVar "loc")) (EIf (EVar "covering") (EApp (EApp (EVar "authorityCoverMsg") (EVar "a")) (EVar "b")) (EApp (EApp (EVar "authorityIndexMsg") (EVar "a")) (EVar "b")))))
(DTypeSig true "authorityFailureMsg" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyFun (TyApp (TyCon "Option") (TyCon "Authority")) (TyCon "String")))))))))
(DFunDef false "authorityFailureMsg" ((PVar "mctx") (PVar "name") (PVar "label") (PVar "origin") (PVar "lower") (PVar "upper") (PVar "written")) (EBlock (DoLet false false (PVar "ctx") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "cnt") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "lo") (EApp (EApp (EApp (EVar "authorityTermTextIn") (EVar "ctx")) (EVar "cnt")) (EVar "lower"))) (DoLet false false (PVar "hi") (EApp (EApp (EApp (EVar "ppAuthority") (EVar "ctx")) (EVar "cnt")) (EVar "upper"))) (DoExpr (EMatch (EVar "origin") (arm (PCon "Some" (PVar "callee")) () (EApp (EApp (EApp (EVar "residualFailureMsg") (EVar "callee")) (EVar "lo")) (EVar "hi"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "boundFailureMsg") (EVar "mctx")) (EVar "name")) (EVar "label")) (EVar "lower")) (EVar "lo")) (EVar "hi")) (EVar "upper")) (EVar "written")))))))
(DTypeSig false "boundFailureMsg" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Authority") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Authority") (TyFun (TyApp (TyCon "Option") (TyCon "Authority")) (TyCon "String"))))))))))
(DFunDef false "boundFailureMsg" ((PVar "mctx") (PVar "name") (PVar "label") (PVar "lower") (PVar "lo") (PVar "hi") (PVar "upper") (PVar "written")) (EIf (EApp (EApp (EVar "mentionsOpened") (EVar "mctx")) (EVar "upper")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` reaches "))) (EApp (EMethodRef "display") (EVar "lo"))) (ELit (LString " where only "))) (EApp (EMethodRef "display") (EVar "hi"))) (ELit (LString " is admitted, the authority of the value this arm or clause opened; derive the operation from the opened value, or widen the declared row to the label bare"))) (EIf (EBinOp "&&" (EApp (EVar "authHasVars") (EVar "upper")) (EApp (EApp (EVar "binderIn") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "displayHiddenBindersRef")) (EVar "upper"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` reaches "))) (EApp (EMethodRef "display") (EVar "lo"))) (ELit (LString " where only "))) (EApp (EMethodRef "display") (EVar "hi"))) (ELit (LString " is admitted: the interpolation uses this module's own `display`, not the prelude's, so the string is not known to derive from "))) (EApp (EMethodRef "display") (EVar "hi"))) (ELit (LString "; build it with `++` from the named argument"))) (EIf (EBinOp "&&" (EApp (EVar "authHasVars") (EVar "upper")) (EApp (EApp (EVar "allList") (EVar "authvarIsPattern")) (EApp (EVar "authVars") (EVar "upper")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` reaches "))) (EApp (EMethodRef "display") (EVar "lo"))) (ELit (LString " where only "))) (EApp (EMethodRef "display") (EVar "hi"))) (ELit (LString " is admitted, a pattern-ranging authority the caller chooses; build the value by appending to the named argument, `root ++ suffix`, or widen the declared row to the label bare"))) (EIf (EApp (EVar "authHasVars") (EVar "upper")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ordinaryBoundFailureMsg") (EVar "mctx")) (EVar "name")) (EVar "label")) (EVar "lower")) (EVar "lo")) (EVar "hi")) (EVar "upper")) (EIf (EApp (EApp (EVar "solvedUpper") (EVar "mctx")) (EVar "written")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` reaches "))) (EApp (EMethodRef "display") (EVar "lo"))) (ELit (LString " where only "))) (EApp (EMethodRef "display") (EVar "hi"))) (ELit (LString " is admitted, the bound this binding's other uses of the same authority determined; make every use lie within one bound, or write the bound"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` reaches "))) (EApp (EMethodRef "display") (EVar "lo"))) (ELit (LString " where its declared bound admits only "))) (EApp (EMethodRef "display") (EVar "hi"))) (ELit (LString "; stay within the bound, or widen it")))))))))
(DTypeSig false "ordinaryBoundFailureMsg" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Authority") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Authority") (TyCon "String")))))))))
(DFunDef false "ordinaryBoundFailureMsg" ((PVar "mctx") (PVar "name") (PVar "label") (PVar "lower") (PVar "lo") (PVar "hi") (PVar "upper")) (EBlock (DoLet false false (PVar "head") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` reaches "))) (EApp (EMethodRef "display") (EVar "lo"))) (ELit (LString " where only "))) (EApp (EMethodRef "display") (EVar "hi"))) (ELit (LString " is admitted, an authority the caller chooses")))) (DoLet false false (PVar "extended") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EApp (EVar "IdMap.has") (EApp (EVar "authvarId") (EVar "c"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "extendedBindersRef") "value")))) (EApp (EVar "authVars") (EVar "upper")))) (DoExpr (EIf (EBinOp "&&" (EApp (EVar "authIsTop") (EVar "lower")) (EApp (EVar "isNonEmptyL") (EVar "extended"))) (EBlock (DoLet false false (PVar "tail") (ELit (LString "; an extension of it is the whole domain, so "))) (DoExpr (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "domainHasPatterns") (EApp (EVar "authvarDomain") (EVar "c"))))) (EVar "extended")) (arm (PCons (PVar "c") PWild) () (EBlock (DoLet false false (PVar "n") (EApp (EApp (EVar "optionOr") (EVar "hi")) (EApp (EVar "authvarName") (EVar "c")))) (DoLet false false (PVar "star") (EApp (EApp (EVar "starSpelling") (EVar "n")) (EApp (EApp (EApp (EApp (EVar "binderLabel") (EVar "mctx")) (EVar "name")) (EVar "n")) (EVar "label")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "tail"))) (ELit (LString "declare "))) (EApp (EMethodRef "display") (EVar "star"))) (ELit (LString "")))))) (arm (PList) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "tail"))) (ELit (LString "perform the operation on the named argument and extend the value at the call site"))))))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString "; perform the operation on the named argument, or widen the declared row to the label bare")))))))
(DTypeSig false "binderLabel" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "binderLabel" ((PVar "mctx") (PVar "fn") (PVar "n") (PVar "key")) (EBlock (DoLet false false (PVar "written") (EMatch (EApp (EApp (EVar "omLookup") (EVar "fn")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "sigTyMapRef") "value")) (arm (PCon "Some" (PVar "ty")) () (EApp (EApp (EApp (EVar "binderLabelIn") (EVar "mctx")) (EVar "n")) (EVar "ty"))) (arm (PCon "None") () (EVar "None")))) (DoExpr (EApp (EApp (EVar "orElseOpt") (EVar "written")) (EApp (EApp (EMethodRef "map") (EVar "labelKeyName")) (EVar "key"))))))
(DTypeSig false "binderLabelIn" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "binderLabelIn" ((PVar "mctx") (PVar "n") (PVar "ty")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EApp (EVar "namedArgDomains") (EVar "ty"))) (arm (PCon "Some" (PCon "Some" (PVar "d"))) () (EApp (EVar "Some") (EFieldAccess (EVar "d") "eatLabel"))) (arm PWild () (EMatch (EBinOp "++" (EApp (EApp (EVar "atomBindersIn") (ELam ((PVar "a")) (EApp (EApp (EVar "atomNaming") (EVar "n")) (EVar "a")))) (EVar "ty")) (EApp (EApp (EApp (EVar "authSlotNamesIn") (EVar "mctx")) (EApp (EVar "slotLabelsNaming") (EVar "n"))) (EVar "ty"))) (arm (PCons (PVar "l") PWild) () (EApp (EVar "Some") (EVar "l"))) (arm (PList) () (EVar "None"))))))
(DTypeSig false "slotLabelsNaming" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "slotLabelsNaming" ((PVar "n") (PCons (PCon "KAuth" (PVar "l") PWild) (PVar "ks")) (PCons (PCon "TyVar" (PVar "m")) (PVar "as2"))) (EIf (EBinOp "==" (EVar "m") (EVar "n")) (EBinOp "::" (EApp (EVar "effLabelName") (EVar "l")) (EApp (EApp (EApp (EVar "slotLabelsNaming") (EVar "n")) (EVar "ks")) (EVar "as2"))) (EApp (EApp (EApp (EVar "slotLabelsNaming") (EVar "n")) (EVar "ks")) (EVar "as2"))))
(DFunDef false "slotLabelsNaming" ((PVar "n") (PCons PWild (PVar "ks")) (PCons PWild (PVar "as2"))) (EApp (EApp (EApp (EVar "slotLabelsNaming") (EVar "n")) (EVar "ks")) (EVar "as2")))
(DFunDef false "slotLabelsNaming" (PWild PWild PWild) (EListLit))
(DTypeSig false "atomNaming" (TyFun (TyCon "String") (TyFun (TyCon "EffAtomTy") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "atomNaming" ((PVar "n") (PVar "a")) (EMatch (EFieldAccess (EVar "a") "eatParam") (arm (PCon "EPName" (PVar "m")) () (EIf (EBinOp "==" (EVar "m") (EVar "n")) (EListLit (EFieldAccess (EVar "a") "eatLabel")) (EListLit))) (arm PWild () (EListLit))))
(DTypeSig false "labelKeyName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "labelKeyName" ((PVar "key")) (EMatch (EApp (EVar "reverseL") (EApp (EApp (EVar "splitOnChar") (ELit (LChar ":"))) (EVar "key"))) (arm (PCons (PVar "last") PWild) () (EVar "last")) (arm (PList) () (EVar "key"))))
(DTypeSig false "binderIn" (TyFun (TyApp (TyCon "Ref") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))) (TyFun (TyCon "Authority") (TyCon "Bool"))))
(DFunDef false "binderIn" ((PVar "table") (PVar "q")) (EApp (EApp (EVar "anyList") (ELam ((PVar "c")) (EApp (EApp (EVar "IdMap.has") (EApp (EVar "authvarId") (EVar "c"))) (EFieldAccess (EVar "table") "value")))) (EApp (EVar "authVars") (EVar "q"))))
(DTypeSig false "mentionsOpened" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Authority") (TyCon "Bool"))))
(DFunDef false "mentionsOpened" ((PVar "mctx") (PVar "q")) (EApp (EApp (EVar "anyList") (ELam ((PVar "cell")) (EApp (EApp (EVar "IdMap.has") (EApp (EVar "authvarId") (EVar "cell"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedAuthvarsRef") "value")))) (EApp (EVar "authVars") (EVar "q"))))
(DTypeSig false "solvedUpper" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "Authority")) (TyCon "Bool"))))
(DFunDef false "solvedUpper" ((PVar "mctx") (PCon "Some" (PCon "AVar" (PVar "cell")))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "ALink" PWild PWild PWild) () (EApp (EVar "not") (EApp (EApp (EVar "IdMap.has") (EApp (EVar "authvarId") (EVar "cell"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "indexSubstitutedRef") "value")))) (arm (PCon "AUnbound" PWild PWild PWild PWild PWild) () (EVar "False"))))
(DFunDef false "solvedUpper" ((PVar "mctx") PWild) (EVar "False"))
(DTypeSig false "paramVarianceGuard" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit"))))))
(DFunDef false "paramVarianceGuard" ((PVar "dyn") (PVar "hd") (PVar "b1") (PVar "b2")) (EIf (EApp (EApp (EVar "monoSlotNonCovariant") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "hd")) (EApp (EApp (EApp (EVar "unifyStruct") (ERecordUpdate (EVar "dyn") ((fa "dcNonCovariant" (EVar "True"))))) (EVar "b1")) (EVar "b2")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "unifyStruct") (EVar "dyn")) (EVar "b1")) (EVar "b2")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "paramPolaritiesOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "TabKey") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Polarity"))))))
(DFunDef false "paramPolaritiesOf" ((PVar "mctx") (PVar "key")) (EApp (EApp (EVar "paramPolaritiesIn") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamPolarityRef") "value")) (EVar "key")))
(DTypeSig false "unifyVars" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "Ref") (TyCon "Tyvar")) (TyFun (TyApp (TyCon "Ref") (TyCon "Tyvar")) (TyCon "Unit")))))
(DFunDef false "unifyVars" ((PVar "dyn") (PVar "c1") (PVar "c2")) (EIf (EBinOp "==" (EApp (EVar "tyvarId") (EVar "c1")) (EApp (EVar "tyvarId") (EVar "c2"))) (ELit LUnit) (EApp (EApp (EApp (EVar "bindVar") (EVar "dyn")) (EVar "c1")) (EApp (EVar "TVar") (EVar "c2")))))
(DTypeSig false "bindVar" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "Ref") (TyCon "Tyvar")) (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "bindVar" ((PVar "dyn") (PVar "cell") (PVar "t")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "occursCheckFailed")) (EVar "False"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "occursAdjust") (EFieldAccess (EVar "dyn") "dcModule")) (EApp (EVar "tyvarId") (EVar "cell"))) (EApp (EVar "tyvarLevel") (EVar "cell"))) (EVar "t"))) (DoExpr (EIf (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "occursCheckFailed") "value") (ELit LUnit) (EBlock (DoExpr (EApp (EApp (EApp (EVar "propagatePoison") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "cell")) (EVar "t"))) (DoLet false false (PVar "shaped") (EApp (EApp (EApp (EVar "takeJoinsShapedBy") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "cell")) (EVar "t"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EVar "Link") (EVar "t")))) (DoExpr (EApp (EApp (EVar "settleShapedJoins") (EVar "dyn")) (EVar "shaped"))))))))
(DTypeSig false "takeJoinsShapedBy" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Ref") (TyCon "Tyvar")) (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "PendingJoin"))))))
(DFunDef false "takeJoinsShapedBy" ((PVar "mctx") (PVar "cell") (PVar "t")) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "pendingJoinsRef") "value") (arm (PList) () (EListLit)) (arm (PVar "pending") () (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TVar" PWild) () (EListLit)) (arm PWild () (EBlock (DoLet false false (PVar "id") (EApp (EVar "tyvarId") (EVar "cell"))) (DoLet false false (PVar "hits") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "pj")) (EApp (EApp (EVar "joinResultIs") (EVar "id")) (EVar "pj")))) (EVar "pending"))) (DoExpr (EMatch (EVar "hits") (arm (PList) () (EListLit)) (arm PWild () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "pendingJoinsRef")) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "pj")) (EApp (EVar "not") (EApp (EApp (EVar "joinResultIs") (EVar "id")) (EVar "pj"))))) (EVar "pending")))) (DoExpr (EVar "hits"))))))))))))
(DTypeSig false "joinResultIs" (TyFun (TyCon "Int") (TyFun (TyCon "PendingJoin") (TyCon "Bool"))))
(DFunDef false "joinResultIs" ((PVar "id") (PVar "pj")) (EMatch (EApp (EVar "normalize") (EFieldAccess (EVar "pj") "pjResult")) (arm (PCon "TVar" (PVar "c")) () (EBinOp "==" (EApp (EVar "tyvarId") (EVar "c")) (EVar "id"))) (arm PWild () (EVar "False"))))
(DTypeSig false "settleShapedJoins" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "List") (TyCon "PendingJoin")) (TyCon "Unit"))))
(DFunDef false "settleShapedJoins" ((PVar "dyn") (PList)) (ELit LUnit))
(DFunDef false "settleShapedJoins" ((PVar "dyn") (PVar "shaped")) (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "pj")) (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PTuple (PVar "loc") (PVar "value"))) (EApp (EApp (EApp (EApp (EApp (EVar "joinValueEqual") (EVar "dyn")) (EFieldAccess (EVar "pj") "pjContext")) (EVar "loc")) (EFieldAccess (EVar "pj") "pjResult")) (EVar "value")))) (ELit LUnit)) (EFieldAccess (EVar "pj") "pjValues")))) (ELit LUnit)) (EVar "shaped")))
(DTypeSig false "propagatePoison" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Ref") (TyCon "Tyvar")) (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "propagatePoison" ((PVar "mctx") (PVar "cell") (PVar "t")) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "poisonedVars") "value") (arm (PList) () (ELit LUnit)) (arm (PVar "poisoned") () (EIf (EApp (EApp (EVar "containsI") (EApp (EVar "tyvarId") (EVar "cell"))) (EVar "poisoned")) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "poisonedVars")) (EBinOp "++" (EApp (EVar "monoUnboundIds") (EVar "t")) (EVar "poisoned"))) (ELit LUnit)))))
(DTypeSig true "poisonMismatchVars" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "poisonMismatchVars" ((PVar "mctx") (PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "poisoned") (EBinOp "++" (EBinOp "++" (EApp (EVar "monoUnboundIds") (EVar "a")) (EApp (EVar "monoUnboundIds") (EVar "b"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "poisonedVars") "value"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "poisonedVars")) (EVar "poisoned")))))
(DTypeSig false "typeMismatch" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "typeMismatch" ((PVar "dyn") (PVar "a") (PVar "b")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "poisonMismatchVars") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "a")) (EVar "b"))) (DoExpr (EApp (EApp (EApp (EVar "typeMismatchReport") (EVar "dyn")) (EVar "a")) (EVar "b")))))
(DTypeSig false "activeDo" (TyFun (TyCon "DynCtx") (TyApp (TyCon "Option") (TyCon "DoCtx"))))
(DFunDef false "activeDo" ((PVar "dyn")) (EMatch (EFieldAccess (EVar "dyn") "dcDo") (arm (PCon "Some" (PVar "doCtx")) () (EIf (EFieldAccess (EFieldAccess (EVar "doCtx") "doReported") "value") (EVar "None") (EApp (EVar "Some") (EVar "doCtx")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "typeMismatchReport" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "typeMismatchReport" ((PVar "dyn") (PVar "a") (PVar "b")) (EMatch (EFieldAccess (EVar "dyn") "dcMethodMismatch") (arm (PCon "Some" (PVar "mname")) () (EApp (EApp (EApp (EVar "pushTypeError") (EFieldAccess (EVar "dyn") "dcModule")) (ELit (LString "T-METHOD-MISMATCH"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "method `")) (EApp (EMethodRef "display") (EVar "mname"))) (ELit (LString "` has type "))) (EApp (EMethodRef "display") (EApp (EVar "ppMono") (EVar "b")))) (ELit (LString " but its interface declares "))) (EApp (EMethodRef "display") (EApp (EVar "ppMono") (EVar "a")))) (ELit (LString ""))))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "typeMismatchReportJoin") (EVar "dyn")) (EVar "a")) (EVar "b")))))
(DTypeSig false "typeMismatchReportJoin" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "typeMismatchReportJoin" ((PVar "dyn") (PVar "a") (PVar "b")) (EMatch (EFieldAccess (EVar "dyn") "dcJoin") (arm (PCon "Some" (PCon "JoinElselessIf")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushTypeErrorHelpFixAt") (EFieldAccess (EVar "dyn") "dcModule")) (ELit (LString "T-TYPE-MISMATCH"))) (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcLoc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type mismatch: ")) (EApp (EMethodRef "display") (EApp (EVar "ppMono") (EVar "a")))) (ELit (LString " vs "))) (EApp (EMethodRef "display") (EApp (EVar "ppMono") (EVar "b")))) (ELit (LString "; "))) (EApp (EMethodRef "display") (EVar "elselessIfHelp"))) (ELit (LString "")))) (EVar "elselessIfHelp")) (EVar "None"))) (arm PWild () (EMatch (ETuple (EApp (EVar "activeDo") (EVar "dyn")) (EApp (EApp (EApp (EVar "constrainedApplicationHelp") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "a")) (EVar "b"))) (arm (PTuple (PCon "None") (PCon "Some" (PVar "help"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushTypeErrorHelpFixAt") (EFieldAccess (EVar "dyn") "dcModule")) (ELit (LString "T-TYPE-MISMATCH"))) (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcLoc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type mismatch: ")) (EApp (EMethodRef "display") (EApp (EVar "ppMono") (EVar "a")))) (ELit (LString " vs "))) (EApp (EMethodRef "display") (EApp (EVar "ppMono") (EVar "b")))) (ELit (LString "; "))) (EApp (EMethodRef "display") (EVar "help"))) (ELit (LString "")))) (EVar "help")) (EVar "None"))) (arm PWild () (EApp (EApp (EApp (EVar "typeMismatchReportRest") (EVar "dyn")) (EVar "a")) (EVar "b")))))))
(DTypeSig false "constrainedApplicationHelp" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "constrainedApplicationHelp" ((PVar "mctx") (PVar "a") (PVar "b")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "app") (PVar "plain") (PVar "ifaces"))) (EApp (EApp (EApp (EVar "constrainedApplicationText") (EVar "app")) (EVar "plain")) (EVar "ifaces")))) (EApp (EApp (EVar "orElseOpt") (EApp (EApp (EApp (EVar "appliedVarIfaces") (EVar "mctx")) (EVar "a")) (EVar "b"))) (EApp (EApp (EApp (EVar "appliedVarIfaces") (EVar "mctx")) (EVar "b")) (EVar "a")))))
(DTypeSig false "appliedVarIfaces" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyTuple (TyCon "Mono") (TyCon "Mono") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "appliedVarIfaces" ((PVar "mctx") (PVar "app") (PVar "plain")) (EMatch (ETuple (EApp (EVar "normalize") (EVar "app")) (EApp (EVar "normalize") (EVar "plain"))) (arm (PTuple (PCon "TApp" PWild PWild) (PCon "TApp" PWild PWild)) () (EVar "None")) (arm (PTuple (PCon "TApp" PWild PWild) PWild) () (EMatch (EApp (EVar "normalize") (EApp (EVar "spineHead") (EVar "app"))) (arm (PCon "TVar" (PVar "cell")) () (EMatch (EApp (EApp (EVar "ifacesConstrainingVar") (EVar "mctx")) (EApp (EVar "tyvarId") (EVar "cell"))) (arm (PList) () (EVar "None")) (arm (PVar "ifaces") () (EApp (EVar "Some") (ETuple (EVar "app") (EVar "plain") (EVar "ifaces")))))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig false "ifacesConstrainingVar" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ifacesConstrainingVar" ((PVar "mctx") (PVar "id")) (EBlock (DoLet false false (PVar "pending") (EBinOp "++" (EApp (EVar "wAll") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "obls")) (EApp (EVar "wAll") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "implObls")))) (DoLet false false (PVar "onVar") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "o")) (EApp (EApp (EVar "anyList") (EApp (EVar "sameRootId") (EVar "id"))) (EFieldAccess (EFieldAccess (EVar "o") "pred") "args")))) (EVar "pending"))) (DoExpr (EApp (EVar "dedup") (EApp (EApp (EMethodRef "map") (ELam ((PVar "o")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "o") "pred") "iface") "irName"))) (EVar "onVar"))))))
(DTypeSig false "typeMismatchReportRest" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "typeMismatchReportRest" ((PVar "dyn") (PVar "a") (PVar "b")) (EMatch (EApp (EVar "activeDo") (EVar "dyn")) (arm (PCon "Some" (PVar "doCtx")) () (EApp (EApp (EApp (EApp (EVar "typeMismatchInDo") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "a")) (EVar "b")) (EVar "doCtx"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "firstTupleCallHint") (EFieldAccess (EVar "dyn") "dcModule")) (EListLit (EVar "a") (EVar "b"))) (arm (PCon "Some" (PTuple (PVar "help") (PVar "fix"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushTypeErrorHelpFixAt") (EFieldAccess (EVar "dyn") "dcModule")) (ELit (LString "T-TYPE-MISMATCH"))) (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcLoc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type mismatch: ")) (EApp (EMethodRef "display") (EApp (EVar "ppMono") (EVar "a")))) (ELit (LString " vs "))) (EApp (EMethodRef "display") (EApp (EVar "ppMono") (EVar "b")))) (ELit (LString "; "))) (EApp (EMethodRef "display") (EVar "help"))) (ELit (LString "")))) (EVar "help")) (EVar "fix"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "sameSpellingHint") (EVar "a")) (EVar "b")) (arm (PCon "Some" (PVar "help")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushTypeErrorHelpFixAt") (EFieldAccess (EVar "dyn") "dcModule")) (ELit (LString "T-TYPE-MISMATCH"))) (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcLoc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type mismatch: ")) (EApp (EMethodRef "display") (EApp (EVar "ppMono") (EVar "a")))) (ELit (LString " vs "))) (EApp (EMethodRef "display") (EApp (EVar "ppMono") (EVar "b")))) (ELit (LString "; "))) (EApp (EMethodRef "display") (EVar "help"))) (ELit (LString "")))) (EVar "help")) (EVar "None"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "pushTypeError") (EFieldAccess (EVar "dyn") "dcModule")) (ELit (LString "T-TYPE-MISMATCH"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type mismatch: ")) (EApp (EMethodRef "display") (EApp (EVar "ppMono") (EVar "a")))) (ELit (LString " vs "))) (EApp (EMethodRef "display") (EApp (EVar "ppMono") (EVar "b")))) (ELit (LString "")))))))))))
(DTypeSig false "typeMismatchInDo" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyFun (TyCon "DoCtx") (TyCon "Unit"))))))
(DFunDef false "typeMismatchInDo" ((PVar "mctx") (PVar "a") (PVar "b") (PVar "doCtx")) (EIf (EBinOp "/=" (EApp (EVar "monoIsApp") (EApp (EVar "normalize") (EVar "a"))) (EApp (EVar "monoIsApp") (EApp (EVar "normalize") (EVar "b")))) (EApp (EApp (EVar "recordDoMonadError") (EVar "mctx")) (EVar "doCtx")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-TYPE-MISMATCH"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type mismatch: ")) (EApp (EMethodRef "display") (EApp (EVar "ppMono") (EVar "a")))) (ELit (LString " vs "))) (EApp (EMethodRef "display") (EApp (EVar "ppMono") (EVar "b")))) (ELit (LString "")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "recordDoMonadError" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "DoCtx") (TyCon "Unit"))))
(DFunDef false "recordDoMonadError" ((PVar "mctx") (PVar "doCtx")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "doCtx") "doReported")) (EVar "True"))) (DoExpr (EApp (EApp (EVar "recordTypeError") (EVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "T-DO-NOT-MONAD"))) (ELit (LInt 1))) (EApp (EVar "Some") (EFieldAccess (EVar "doCtx") "doLoc"))) (EIf (EFieldAccess (EVar "doCtx") "doDeferred") (EVar "deferRequiresMonadMsg") (EVar "doRequiresMonadMsg"))) (EVar "None")) (EVar "None"))))))
(DTypeSig true "generalize" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyCon "Scheme"))))
(DFunDef false "generalize" ((PVar "mctx") (PVar "t")) (EApp (EApp (EApp (EApp (EVar "quantifyFree") (EVar "mctx")) (EListLit)) (EVar "pureRow")) (EVar "t")))
(DTypeSig true "generalizeBindingDeclared" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "AuthResidual")) (TyFun (TyCon "EffRow") (TyFun (TyCon "Mono") (TyCon "Scheme")))))))
(DFunDef false "generalizeBindingDeclared" ((PVar "dyn") (PVar "declared") (PVar "residual") (PVar "force") (PVar "t")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "defaultDeferredPatLitsIn") (EVar "dyn")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "currentLevel") "value")) (EVar "t"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "defaultSourcelessAuthorities") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "declared")) (EVar "force")) (EVar "t"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "quantifyFree") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "residual")) (EVar "force")) (EVar "t")))))
(DTypeSig false "quantifyFree" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "AuthResidual")) (TyFun (TyCon "EffRow") (TyFun (TyCon "Mono") (TyCon "Scheme"))))))
(DFunDef false "quantifyFree" ((PVar "mctx") (PVar "residual") (PVar "force") (PVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Forall") (EApp (EVar "dedupI") (EApp (EApp (EVar "freeGenVars") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (EVar "t")))) (EApp (EVar "dedupI") (EBinOp "++" (EApp (EApp (EVar "freeEffvars") (EVar "mctx")) (EVar "t")) (EApp (EApp (EVar "rowFreeEffvars") (EVar "mctx")) (EVar "force"))))) (EApp (EVar "dedupI") (EBinOp "++" (EApp (EApp (EVar "freeAuthvars") (EVar "mctx")) (EVar "t")) (EApp (EApp (EVar "rowFreeAuthvars") (EVar "mctx")) (EVar "force"))))) (EVar "residual")) (EVar "force")) (EVar "t")))
(DTypeSig true "lowerToCurrent" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyCon "Unit"))))
(DFunDef false "lowerToCurrent" ((PVar "mctx") (PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TVar" (PVar "cell")) () (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Unbound" (PVar "id") (PVar "lvl")) () (EIf (EBinOp ">" (EVar "lvl") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EApp (EVar "Unbound") (EVar "id")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value"))) (ELit LUnit))) (arm (PCon "Link" (PVar "t2")) () (EApp (EApp (EVar "lowerToCurrent") (EVar "mctx")) (EVar "t2"))))) (arm (PCon "TCon" PWild PWild) () (ELit LUnit)) (arm (PCon "TRigid" PWild) () (ELit LUnit)) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EBlock (DoExpr (EApp (EApp (EVar "lowerToCurrent") (EVar "mctx")) (EVar "a"))) (DoExpr (EApp (EApp (EVar "lowerToCurrent") (EVar "mctx")) (EVar "b"))))) (arm (PCon "TFun" (PVar "a") (PVar "r") (PVar "b")) () (EBlock (DoExpr (EApp (EApp (EVar "lowerToCurrent") (EVar "mctx")) (EVar "a"))) (DoExpr (EApp (EApp (EVar "lowerRowLevels") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (EVar "r"))) (DoExpr (EApp (EApp (EVar "lowerToCurrent") (EVar "mctx")) (EVar "b"))))) (arm (PCon "TAuth" (PVar "q")) () (EApp (EApp (EVar "lowerAuthLevels") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (EVar "q"))) (arm (PCon "TEff" (PVar "r")) () (EBlock (DoExpr (EApp (EApp (EVar "lowerRowLevels") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (EVar "r"))) (DoExpr (ELit LUnit)))) (arm (PCon "TQual" (PVar "a") (PVar "q")) () (EBlock (DoExpr (EApp (EApp (EVar "lowerAuthLevels") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (EVar "q"))) (DoExpr (EApp (EApp (EVar "lowerToCurrent") (EVar "mctx")) (EVar "a")))))))
(DTypeSig false "freeGenVars" (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "freeGenVars" ((PVar "lvl") (PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TVar" (PVar "cell")) () (EIf (EBinOp ">" (EApp (EVar "tyvarLevel") (EVar "cell")) (EVar "lvl")) (EListLit (EApp (EVar "tyvarId") (EVar "cell"))) (EListLit))) (arm (PCon "TCon" PWild PWild) () (EListLit)) (arm (PCon "TRigid" PWild) () (EListLit)) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EBinOp "++" (EApp (EApp (EVar "freeGenVars") (EVar "lvl")) (EVar "a")) (EApp (EApp (EVar "freeGenVars") (EVar "lvl")) (EVar "b")))) (arm (PCon "TFun" (PVar "a") PWild (PVar "b")) () (EBinOp "++" (EApp (EApp (EVar "freeGenVars") (EVar "lvl")) (EVar "a")) (EApp (EApp (EVar "freeGenVars") (EVar "lvl")) (EVar "b")))) (arm (PCon "TEff" PWild) () (EListLit)) (arm (PCon "TAuth" PWild) () (EListLit)) (arm (PCon "TQual" (PVar "a") PWild) () (EApp (EApp (EVar "freeGenVars") (EVar "lvl")) (EVar "a")))))
(DTypeSig true "instantiate" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Scheme") (TyCon "Mono"))))
(DFunDef false "instantiate" ((PVar "mctx") (PCon "Forall" (PVar "ids") (PVar "evars") (PVar "avars") PWild PWild (PVar "t"))) (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "freshSubst") (EVar "mctx")) (EVar "ids"))) (EApp (EApp (EVar "freshEffSubst") (EVar "mctx")) (EVar "evars"))) (EApp (EApp (EApp (EApp (EVar "freshAuthSubstFor") (EVar "mctx")) (EVar "avars")) (EVar "t")) (EVar "pureRow"))) (EVar "t")))
(DTypeSig true "freshAuthSubstOpening" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Mono") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))) (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Authvar"))))))))
(DFunDef false "freshAuthSubstOpening" ((PVar "mctx") (PList) PWild) (ETuple (EListLit) (EListLit)))
(DFunDef false "freshAuthSubstOpening" ((PVar "mctx") (PVar "ids") (PVar "body")) (EApp (EApp (EApp (EVar "freshAuthSubstOpeningIn") (EVar "mctx")) (EVar "ids")) (EApp (EApp (EVar "authCellsIn") (EVar "body")) (EVar "Tip"))))
(DTypeSig true "freshAuthSubstOpeningIn" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))) (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Authvar"))))))))
(DFunDef false "freshAuthSubstOpeningIn" ((PVar "mctx") (PList) PWild) (ETuple (EListLit) (EListLit)))
(DFunDef false "freshAuthSubstOpeningIn" ((PVar "mctx") (PVar "ids") (PVar "cells")) (EBlock (DoLet false false (PVar "pairs") (EApp (EApp (EMethodRef "map") (ELam ((PVar "id")) (EBlock (DoLet false false (PVar "cell") (EApp (EApp (EApp (EVar "freshInferenceAuthvar") (EVar "mctx")) (EVar "id")) (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EVar "cells")))) (DoExpr (ETuple (EVar "id") (EVar "cell") (EApp (EApp (EVar "IdMap.has") (EVar "id")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "ctorExistentialsRef") "value"))))))) (EVar "ids"))) (DoLet false false (PVar "opened") (EApp (EApp (EDictApp "flatMap") (ELam ((PTuple PWild (PVar "cell") (PVar "isOpen"))) (EIf (EVar "isOpen") (EListLit (EVar "cell")) (EListLit)))) (EVar "pairs"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "rigidAuthvarsRef")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PVar "cell")) (EApp (EApp (EApp (EVar "IdMap.set") (EApp (EVar "authvarId") (EVar "cell"))) (ELit LUnit)) (EVar "m")))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "rigidAuthvarsRef") "value")) (EVar "opened")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedAuthvarsRef")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PVar "cell")) (EApp (EApp (EApp (EVar "IdMap.set") (EApp (EVar "authvarId") (EVar "cell"))) (ELit LUnit)) (EVar "m")))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "openedAuthvarsRef") "value")) (EVar "opened")))) (DoExpr (ETuple (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "id") (PVar "cell") PWild)) (ETuple (EVar "id") (EApp (EVar "AVar") (EVar "cell"))))) (EVar "pairs")) (EVar "opened")))))
(DTypeSig true "freshSubst" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))))))
(DFunDef false "freshSubst" ((PVar "mctx") (PList)) (EListLit))
(DFunDef false "freshSubst" ((PVar "mctx") (PCons (PVar "id") (PVar "rest"))) (EBlock (DoLet false false (PVar "v") (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit))) (DoExpr (EIf (EBinOp "==" (EVar "id") (EVar "ambiguousImportTyvarId")) (EApp (EApp (EApp (EVar "poisonMismatchVars") (EVar "mctx")) (EVar "v")) (EVar "v")) (ELit LUnit))) (DoExpr (EBinOp "::" (ETuple (EVar "id") (EVar "v")) (EApp (EApp (EVar "freshSubst") (EVar "mctx")) (EVar "rest"))))))
(DTypeSig true "ambiguousImportTyvarId" (TyCon "Int"))
(DFunDef false "ambiguousImportTyvarId" () (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))))
(DTypeSig true "freshEffSubst" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Effvar")))))))
(DFunDef false "freshEffSubst" ((PVar "mctx") (PList)) (EListLit))
(DFunDef false "freshEffSubst" ((PVar "mctx") (PCons (PVar "id") (PVar "rest"))) (EBlock (DoLet false false (PVar "cell") (EApp (EApp (EVar "freshInferenceEffvar") (EVar "mctx")) (ELit LUnit))) (DoExpr (EBinOp "::" (ETuple (EVar "id") (EVar "cell")) (EApp (EApp (EVar "freshEffSubst") (EVar "mctx")) (EVar "rest"))))))
(DTypeSig false "freshAuthSubstFor" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Mono") (TyFun (TyCon "EffRow") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))))))))
(DFunDef false "freshAuthSubstFor" ((PVar "mctx") (PList) PWild PWild) (EListLit))
(DFunDef false "freshAuthSubstFor" ((PVar "mctx") (PVar "ids") (PVar "body") (PVar "force")) (EBlock (DoLet false false (PVar "cells") (EApp (EApp (EVar "authCellsIn") (EVar "body")) (EApp (EApp (EVar "authRowCells") (EVar "force")) (EVar "Tip")))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "id")) (ETuple (EVar "id") (EApp (EVar "AVar") (EApp (EApp (EApp (EVar "freshInferenceAuthvar") (EVar "mctx")) (EVar "id")) (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EVar "cells"))))))) (EVar "ids")))))
(DTypeSig true "freshInferenceAuthvar" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyApp (TyCon "Ref") (TyCon "Authvar"))))))
(DFunDef false "freshInferenceAuthvar" ((PVar "mctx") PWild (PCon "Some" (PVar "source"))) (EApp (EApp (EApp (EApp (EVar "freshAuthvarRanged") (EVar "mctx")) (EApp (EVar "authvarDomain") (EVar "source"))) (EApp (EVar "authvarIsPattern") (EVar "source"))) (EApp (EVar "authvarName") (EVar "source"))))
(DFunDef false "freshInferenceAuthvar" ((PVar "mctx") (PVar "id") (PCon "None")) (EIf (EBinOp "&&" (EApp (EApp (EVar "IdMap.has") (EVar "id")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "patternAuthIdsRef") "value")) (EApp (EVar "not") (EApp (EApp (EVar "IdMap.has") (EVar "id")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "ctorExistentialsRef") "value")))) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "internal error: the pattern-ranging authority variable #")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "id")))) (ELit (LString " has no cell in the scheme that quantifies it, so its range would be lost at instantiation")))) (EApp (EApp (EApp (EVar "freshAuthvar") (EVar "mctx")) (EVar "PUnit")) (EVar "None"))))
(DTypeSig false "freeAuthvars" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "freeAuthvars" ((PVar "mctx") (PVar "t")) (EApp (EApp (EVar "generalizableAuthvars") (EVar "mctx")) (EApp (EVar "IdMap.values") (EApp (EApp (EVar "authCellsIn") (EVar "t")) (EVar "Tip")))))
(DTypeSig false "rowFreeAuthvars" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "EffRow") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "rowFreeAuthvars" ((PVar "mctx") (PVar "row")) (EApp (EApp (EVar "generalizableAuthvars") (EVar "mctx")) (EApp (EVar "IdMap.values") (EApp (EApp (EVar "authRowCells") (EVar "row")) (EVar "Tip")))))
(DTypeSig false "generalizableAuthvars" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "generalizableAuthvars" ((PVar "mctx") (PVar "cells")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "cell")) (EIf (EBinOp ">" (EApp (EVar "authvarLevel") (EVar "cell")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (EListLit (EApp (EVar "authvarId") (EVar "cell"))) (EListLit)))) (EVar "cells")))
(DTypeSig false "defaultSourcelessAuthorities" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyCon "EffRow") (TyFun (TyCon "Mono") (TyCon "Unit"))))))
(DFunDef false "defaultSourcelessAuthorities" ((PVar "mctx") (PVar "declared") (PVar "force") (PVar "t")) (EBlock (DoLet false false (PVar "sources") (EApp (EApp (EVar "qualifierAuthIds") (EVar "t")) (EVar "declared"))) (DoLet false false (PVar "candidates") (EApp (EVar "IdMap.values") (EApp (EApp (EVar "authCellsIn") (EVar "t")) (EApp (EApp (EVar "authRowCells") (EVar "force")) (EVar "Tip"))))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "cell")) (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "authvarLevel") (EVar "cell")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (EApp (EVar "not") (EApp (EApp (EVar "IdMap.has") (EApp (EVar "authvarId") (EVar "cell"))) (EVar "sources")))) (EApp (EApp (EVar "linkAuthvar") (EVar "cell")) (EApp (EVar "authTop") (EApp (EVar "authvarDomain") (EVar "cell")))) (ELit LUnit)))) (ELit LUnit)) (EVar "candidates")))))
(DTypeSig true "lowerAuthLevels" (TyFun (TyCon "Int") (TyFun (TyCon "Authority") (TyCon "Unit"))))
(DFunDef false "lowerAuthLevels" (PWild (PCon "AConst" PWild)) (ELit LUnit))
(DFunDef false "lowerAuthLevels" ((PVar "level") (PVar "q")) (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "AUnbound" (PVar "id") (PVar "lvl") (PVar "top") (PVar "pat") (PVar "name")) () (EIf (EBinOp ">" (EVar "lvl") (EVar "level")) (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EApp (EApp (EApp (EApp (EVar "AUnbound") (EVar "id")) (EVar "level")) (EVar "top")) (EVar "pat")) (EVar "name"))) (ELit LUnit))) (arm (PCon "ALink" PWild PWild PWild) () (ELit LUnit))))) (ELit LUnit)) (EApp (EVar "authVars") (EVar "q"))))
(DTypeSig true "freshTvMap" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))))
(DFunDef false "freshTvMap" ((PVar "mctx") (PList)) (EListLit))
(DFunDef false "freshTvMap" ((PVar "mctx") (PCons (PVar "n") (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit))) (EApp (EApp (EVar "freshTvMap") (EVar "mctx")) (EVar "rest"))))
(DTypeSig true "freshEffMap" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Effvar")))))))
(DFunDef false "freshEffMap" ((PVar "mctx") (PList)) (EListLit))
(DFunDef false "freshEffMap" ((PVar "mctx") (PCons (PVar "n") (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EVar "freshEffvar") (EVar "mctx")) (ELit LUnit))) (EApp (EApp (EVar "freshEffMap") (EVar "mctx")) (EVar "rest"))))
(DTypeSig true "freshAuthBinderRanged" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Authvar")))))))
(DFunDef false "freshAuthBinderRanged" ((PVar "mctx") (PVar "pat") (PTuple (PVar "n") (PVar "top"))) (ETuple (EVar "n") (EApp (EApp (EApp (EApp (EVar "freshAuthvarRanged") (EVar "mctx")) (EVar "top")) (EVar "pat")) (EApp (EVar "Some") (EVar "n")))))
(DTypeSig true "namedArgDomains" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "EffAtomTy"))))))
(DFunDef false "namedArgDomains" ((PCon "TyFun" (PCon "TyNamed" (PVar "n") PWild (PVar "d")) (PVar "b"))) (EBinOp "::" (ETuple (EVar "n") (EVar "d")) (EApp (EVar "namedArgDomains") (EVar "b"))))
(DFunDef false "namedArgDomains" ((PCon "TyFun" PWild (PVar "b"))) (EApp (EVar "namedArgDomains") (EVar "b")))
(DFunDef false "namedArgDomains" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "namedArgDomains") (EVar "t")))
(DFunDef false "namedArgDomains" (PWild) (EListLit))
(DTypeSig true "freshAuthvar" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Param") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Ref") (TyCon "Authvar"))))))
(DFunDef false "freshAuthvar" ((PVar "mctx") (PVar "top") (PVar "name")) (EApp (EApp (EApp (EApp (EVar "freshAuthvarRanged") (EVar "mctx")) (EVar "top")) (EVar "False")) (EVar "name")))
(DTypeSig true "freshAuthvarRanged" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Param") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Ref") (TyCon "Authvar")))))))
(DFunDef false "freshAuthvarRanged" ((PVar "mctx") (PVar "top") (PVar "pat") (PVar "name")) (EBlock (DoLet false false (PVar "id") (EApp (EApp (EVar "newEffvarId") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (DoExpr (EIf (EVar "pat") (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "patternAuthIdsRef")) (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (ELit LUnit)) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "patternAuthIdsRef") "value"))) (ELit LUnit))) (DoExpr (EApp (EVar "Ref") (EApp (EApp (EApp (EApp (EApp (EVar "AUnbound") (EVar "id")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (EVar "top")) (EVar "pat")) (EVar "name"))))))
(DTypeSig true "authSlotNamesIn" (TyFun (TyCon "ModuleCtx") (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyVar "a")))) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "authSlotNamesIn" ((PVar "mctx") (PVar "readSlots") (PCon "TyApp" (PVar "a") (PVar "b"))) (EMatch (EApp (EVar "tyAppSpine") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b"))) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false) (PVar "args")) () (EMatch (EApp (EApp (EVar "lookupTab") (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamKindsRef") "value")) (arm (PCon "Some" (PVar "kinds")) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EVar "kinds")) (EApp (EVar "listLen") (EVar "args"))))) (EBinOp "++" (EApp (EApp (EVar "readSlots") (EVar "kinds")) (EVar "args")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "authSlotNamesIn") (EVar "mctx")) (EVar "readSlots"))) (EVar "args")))) (arm PWild () (EBinOp "++" (EApp (EApp (EApp (EVar "authSlotNamesIn") (EVar "mctx")) (EVar "readSlots")) (EVar "a")) (EApp (EApp (EApp (EVar "authSlotNamesIn") (EVar "mctx")) (EVar "readSlots")) (EVar "b")))))) (arm PWild () (EBinOp "++" (EApp (EApp (EApp (EVar "authSlotNamesIn") (EVar "mctx")) (EVar "readSlots")) (EVar "a")) (EApp (EApp (EApp (EVar "authSlotNamesIn") (EVar "mctx")) (EVar "readSlots")) (EVar "b"))))))
(DFunDef false "authSlotNamesIn" ((PVar "mctx") (PVar "readSlots") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EApp (EVar "authSlotNamesIn") (EVar "mctx")) (EVar "readSlots")) (EVar "a")) (EApp (EApp (EApp (EVar "authSlotNamesIn") (EVar "mctx")) (EVar "readSlots")) (EVar "b"))))
(DFunDef false "authSlotNamesIn" ((PVar "mctx") (PVar "readSlots") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "authSlotNamesIn") (EVar "mctx")) (EVar "readSlots"))) (EVar "ts")))
(DFunDef false "authSlotNamesIn" ((PVar "mctx") (PVar "readSlots") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EApp (EVar "authSlotNamesIn") (EVar "mctx")) (EVar "readSlots")) (EVar "t")))
(DFunDef false "authSlotNamesIn" ((PVar "mctx") (PVar "readSlots") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EApp (EVar "authSlotNamesIn") (EVar "mctx")) (EVar "readSlots")) (EVar "t")))
(DFunDef false "authSlotNamesIn" ((PVar "mctx") (PVar "readSlots") (PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EApp (EApp (EVar "authSlotNamesIn") (EVar "mctx")) (EVar "readSlots")) (EVar "t")))
(DFunDef false "authSlotNamesIn" ((PVar "mctx") (PVar "readSlots") (PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EApp (EApp (EVar "authSlotNamesIn") (EVar "mctx")) (EVar "readSlots")) (EVar "t")))
(DFunDef false "authSlotNamesIn" ((PVar "mctx") PWild PWild) (EListLit))
(DTypeSig true "atomBindersIn" (TyFun (TyFun (TyCon "EffAtomTy") (TyApp (TyCon "List") (TyVar "a"))) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "atomBindersIn" (PWild (PCon "TyVar" PWild)) (EListLit))
(DFunDef false "atomBindersIn" (PWild (PRec "TyCon" ((rf "tyConName" PWild)) false)) (EListLit))
(DFunDef false "atomBindersIn" ((PVar "readAtom") (PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EVar "atomBindersIn") (EVar "readAtom")) (EVar "a")) (EApp (EApp (EVar "atomBindersIn") (EVar "readAtom")) (EVar "b"))))
(DFunDef false "atomBindersIn" ((PVar "readAtom") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EVar "atomBindersIn") (EVar "readAtom")) (EVar "a")) (EApp (EApp (EVar "atomBindersIn") (EVar "readAtom")) (EVar "b"))))
(DFunDef false "atomBindersIn" ((PVar "readAtom") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "atomBindersIn") (EVar "readAtom"))) (EVar "ts")))
(DFunDef false "atomBindersIn" ((PVar "readAtom") (PCon "TyEffect" (PVar "atoms") PWild (PVar "t"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "readAtom")) (EVar "atoms")) (EApp (EApp (EVar "atomBindersIn") (EVar "readAtom")) (EVar "t"))))
(DFunDef false "atomBindersIn" ((PVar "readAtom") (PCon "TyRow" (PVar "atoms") PWild PWild)) (EApp (EApp (EDictApp "flatMap") (EVar "readAtom")) (EVar "atoms")))
(DFunDef false "atomBindersIn" (PWild (PCon "TyAuth" PWild PWild)) (EListLit))
(DFunDef false "atomBindersIn" ((PVar "readAtom") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EVar "atomBindersIn") (EVar "readAtom")) (EVar "t")))
(DFunDef false "atomBindersIn" ((PVar "readAtom") (PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EApp (EVar "atomBindersIn") (EVar "readAtom")) (EVar "t")))
(DFunDef false "atomBindersIn" ((PVar "readAtom") (PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EApp (EVar "atomBindersIn") (EVar "readAtom")) (EVar "t")))
(DTypeSig false "defaultDeferredPatLitsIn" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "defaultDeferredPatLitsIn" ((PVar "dyn") (PVar "lvl") (PVar "t")) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "patLitDeferred") "value") (arm (PList) () (ELit LUnit)) (arm (PVar "deferred") () (EApp (EApp (EApp (EVar "defaultPatLitVarsIn") (EVar "dyn")) (EApp (EApp (EVar "freeGenVars") (EVar "lvl")) (EVar "t"))) (EVar "deferred")))))
(DTypeSig false "defaultPatLitVarsIn" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyCon "Unit")))))
(DFunDef false "defaultPatLitVarsIn" ((PVar "dyn") PWild (PList)) (ELit LUnit))
(DFunDef false "defaultPatLitVarsIn" ((PVar "dyn") (PVar "quantified") (PCons (PTuple (PVar "a") PWild PWild) (PVar "rest"))) (EBlock (DoExpr (EMatch (EApp (EVar "normalize") (EVar "a")) (arm (PCon "TVar" (PVar "cell")) () (EIf (EApp (EApp (EVar "containsI") (EApp (EVar "tyvarId") (EVar "cell"))) (EVar "quantified")) (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EApp (EVar "tconBuiltin") (ELit (LString "Int")))) (EVar "a")) (ELit LUnit))) (arm PWild () (ELit LUnit)))) (DoExpr (EApp (EApp (EApp (EVar "defaultPatLitVarsIn") (EVar "dyn")) (EVar "quantified")) (EVar "rest")))))
(DTypeSig true "unifyAll" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Unit")))))
(DFunDef false "unifyAll" ((PVar "dyn") PWild (PList)) (ELit LUnit))
(DFunDef false "unifyAll" ((PVar "dyn") (PVar "t") (PCons (PVar "x") (PVar "xs"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "t")) (EVar "x"))) (DoExpr (EApp (EApp (EApp (EVar "unifyAll") (EVar "dyn")) (EVar "t")) (EVar "xs")))))
(DTypeSig true "qualConstraintDecl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "CDeclared")))))
(DFunDef false "qualConstraintDecl" ((PVar "mctx") (PVar "name")) (EMatch (EApp (EApp (EVar "qualConstraintKey") (EVar "mctx")) (EVar "name")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple (PVar "src") (PVar "origin"))) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "slots")) (EApp (EApp (EApp (EApp (EVar "qualDeclOf") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "src")) (EVar "origin")) (EVar "slots")))) (EApp (EApp (EApp (EVar "lookupQualPayload") (EVar "src")) (EVar "origin")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "crossRun") "crossModuleFunPredicateSlotsQualRef") "value"))))))
(DTypeSig false "qualDeclOf" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PredicateSlot")) (TyCon "CDeclared"))))))
(DFunDef false "qualDeclOf" ((PVar "gctx") (PVar "src") (PVar "origin") (PVar "stored")) (EBlock (DoLet false false (PVar "slots") (EApp (EVar "predicateSlotCSlots") (EVar "stored"))) (DoExpr (ERecordCreate "CDeclared" ((fa "cdSlots" (EVar "slots")) (fa "cdPrefix" (EApp (EApp (EVar "clampPrefix") (EVar "slots")) (EApp (EApp (EApp (EVar "lookupQualPayload") (EVar "src")) (EVar "origin")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "crossModuleFunConstraintDeclaredQualRef") "value")))) (fa "cdArgs" (EApp (EVar "predicateSlotArgs") (EVar "stored"))))))))
(DTypeSig true "qualConstraintKey" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "qualConstraintKey" ((PVar "mctx") (PVar "name")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "src")) (ETuple (EVar "src") (EApp (EApp (EVar "optionOr") (EVar "name")) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentImportOriginsRef") "value")))))) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentImportDefinersRef") "value"))))
(DTypeSig true "lookupQualPayload" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyVar "a"))) (TyApp (TyCon "Option") (TyVar "a"))))))
(DFunDef false "lookupQualPayload" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "lookupQualPayload" ((PVar "src") (PVar "name") (PCons (PTuple (PTuple (PVar "m") (PVar "n")) (PVar "v")) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "m") (EVar "src")) (EBinOp "==" (EVar "n") (EVar "name"))) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "lookupQualPayload") (EVar "src")) (EVar "name")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "clampPrefix" (TyFun (TyApp (TyCon "List") (TyCon "CSlot")) (TyFun (TyApp (TyCon "Option") (TyCon "CDeclaredPrefix")) (TyCon "CDeclaredPrefix"))))
(DFunDef false "clampPrefix" (PWild (PCon "None")) (EVar "CDPUnknown"))
(DFunDef false "clampPrefix" (PWild (PCon "Some" (PCon "CDPUnknown"))) (EVar "CDPUnknown"))
(DFunDef false "clampPrefix" ((PVar "slots") (PCon "Some" (PCon "CDPLen" (PVar "k")))) (EApp (EVar "CDPLen") (EApp (EApp (EVar "minI") (EVar "k")) (EApp (EVar "listLen") (EVar "slots")))))
(DTypeSig true "instantiateTracked" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Scheme") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))))))
(DFunDef false "instantiateTracked" ((PVar "mctx") (PVar "scheme")) (EBlock (DoLet false false (PVar "inst") (EApp (EApp (EVar "instantiateMethodTracked") (EVar "mctx")) (EVar "scheme"))) (DoExpr (ETuple (EFieldAccess (EVar "inst") "mtiBody") (EFieldAccess (EFieldAccess (EVar "inst") "mtiSubstitution") "misTypeSubst")))))
(DTypeSig true "instantiateMethodTracked" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Scheme") (TyCon "MethodTrackedInstantiation"))))
(DFunDef false "instantiateMethodTracked" ((PVar "mctx") (PCon "Forall" (PVar "ids") (PVar "evars") (PVar "avars") (PVar "residual") (PVar "force") (PVar "body"))) (EBlock (DoLet false false (PVar "typeSubst") (EApp (EApp (EVar "freshSubst") (EVar "mctx")) (EVar "ids"))) (DoLet false false (PVar "effectSubst") (EApp (EApp (EVar "freshEffSubst") (EVar "mctx")) (EVar "evars"))) (DoLet false false (PVar "authSubst") (EApp (EApp (EApp (EApp (EVar "freshAuthSubstFor") (EVar "mctx")) (EVar "avars")) (EVar "body")) (EVar "force"))) (DoExpr (ERecordCreate "MethodTrackedInstantiation" ((fa "mtiBody" (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "typeSubst")) (EVar "effectSubst")) (EVar "authSubst")) (EVar "body"))) (fa "mtiForce" (EApp (EApp (EApp (EApp (EVar "substRow") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "effectSubst")) (EVar "authSubst")) (EVar "force"))) (fa "mtiResidual" (EApp (EApp (EMethodRef "map") (ELam ((PVar "r")) (ERecordCreate "AuthResidual" ((fa "arLower" (EApp (EApp (EVar "substAuth") (EVar "authSubst")) (EFieldAccess (EVar "r") "arLower"))) (fa "arUpper" (EApp (EApp (EVar "substAuth") (EVar "authSubst")) (EFieldAccess (EVar "r") "arUpper"))) (fa "arExact" (EFieldAccess (EVar "r") "arExact")))))) (EVar "residual"))) (fa "mtiSubstitution" (ERecordCreate "MethodInstantiationSubst" ((fa "misTypeSubst" (EVar "typeSubst")) (fa "misEffectSubst" (EVar "effectSubst")) (fa "misAuthSubst" (EVar "authSubst"))))))))))
(DTypeSig true "forceInstantiation" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "MethodTrackedInstantiation") (TyCon "Mono")))))
(DFunDef false "forceInstantiation" ((PVar "mctx") (PVar "name") (PVar "inst")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "performEffect") (EVar "mctx")) (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "curEffect")) (EFieldAccess (EVar "inst") "mtiForce"))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "r")) (EApp (EApp (EApp (EApp (EApp (EVar "wantAuthorityFrom") (EVar "mctx")) (EApp (EVar "Some") (EVar "name"))) (EFieldAccess (EVar "r") "arExact")) (EFieldAccess (EVar "r") "arLower")) (EFieldAccess (EVar "r") "arUpper")))) (ELit LUnit)) (EFieldAccess (EVar "inst") "mtiResidual"))) (DoExpr (EFieldAccess (EVar "inst") "mtiBody"))))
(DTypeSig true "instantiateValueTracked" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Scheme") (TyCon "MethodTrackedInstantiation")))))
(DFunDef false "instantiateValueTracked" ((PVar "mctx") (PVar "name") (PVar "scheme")) (EBlock (DoLet false false (PVar "inst") (EApp (EApp (EVar "instantiateMethodTracked") (EVar "mctx")) (EVar "scheme"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "forceInstantiation") (EVar "mctx")) (EVar "name")) (EVar "inst"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "grants") "gsLastInst")) (EApp (EVar "Some") (ETuple (EVar "scheme") (EFieldAccess (EFieldAccess (EVar "inst") "mtiSubstitution") "misAuthSubst"))))) (DoExpr (EVar "inst"))))
(DTypeSig true "zipSlotVecs" (TyFun (TyApp (TyCon "List") (TyCon "CSlot")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "CSlot") (TyApp (TyCon "List") (TyCon "Mono")))))))
(DFunDef false "zipSlotVecs" ((PList) PWild) (EListLit))
(DFunDef false "zipSlotVecs" ((PCons (PVar "s") (PVar "rest")) (PList)) (EBinOp "::" (ETuple (EVar "s") (EListLit)) (EApp (EApp (EVar "zipSlotVecs") (EVar "rest")) (EListLit))))
(DFunDef false "zipSlotVecs" ((PCons (PVar "s") (PVar "rest")) (PCons (PVar "v") (PVar "vs"))) (EBinOp "::" (ETuple (EVar "s") (EVar "v")) (EApp (EApp (EVar "zipSlotVecs") (EVar "rest")) (EVar "vs"))))
(DTypeSig true "noteNumlitCtx" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyFun (TyCon "JoinContext") (TyCon "Unit"))))))
(DFunDef false "noteNumlitCtx" ((PVar "mctx") (PVar "a") (PVar "b") (PVar "kind")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "tagNumlitCtxIf") (EVar "mctx")) (EVar "a")) (EVar "b")) (EVar "kind"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "tagNumlitCtxIf") (EVar "mctx")) (EVar "b")) (EVar "a")) (EVar "kind")))))
(DTypeSig false "tagNumlitCtxIf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyFun (TyCon "JoinContext") (TyCon "Unit"))))))
(DFunDef false "tagNumlitCtxIf" ((PVar "mctx") (PVar "v") (PVar "other") (PVar "kind")) (EIf (EApp (EVar "isSome") (EApp (EVar "headTyconMono") (EVar "other"))) (EApp (EApp (EApp (EVar "tagAllLitLocs") (EVar "mctx")) (EVar "v")) (EVar "kind")) (EIf (EVar "otherwise") (ELit LUnit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "tagAllLitLocs" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "JoinContext") (TyCon "Unit")))))
(DFunDef false "tagAllLitLocs" ((PVar "mctx") (PVar "v") (PVar "kind")) (EMatch (EApp (EVar "normalize") (EVar "v")) (arm (PCon "TVar" (PVar "cell")) () (EApp (EApp (EApp (EApp (EVar "tagLitLocsWithRoot") (EVar "mctx")) (EApp (EVar "tyvarId") (EVar "cell"))) (EVar "kind")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitVarLocs") "value"))) (arm PWild () (ELit LUnit))))
(DTypeSig false "tagLitLocsWithRoot" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyFun (TyCon "JoinContext") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Loc"))) (TyCon "Unit"))))))
(DFunDef false "tagLitLocsWithRoot" ((PVar "mctx") PWild PWild (PList)) (ELit LUnit))
(DFunDef false "tagLitLocsWithRoot" ((PVar "mctx") (PVar "id") (PVar "kind") (PCons (PTuple (PVar "mv") (PVar "l")) (PVar "rest"))) (EBlock (DoExpr (EIf (EApp (EApp (EVar "sameRootId") (EVar "id")) (EVar "mv")) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitCtxTags")) (EBinOp "::" (ETuple (EVar "l") (EVar "kind")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numlitCtxTags") "value"))) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EVar "tagLitLocsWithRoot") (EVar "mctx")) (EVar "id")) (EVar "kind")) (EVar "rest")))))
(DTypeSig true "calleeArrow" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyTuple (TyCon "Mono") (TyCon "EffRow") (TyCon "Mono")))))
(DFunDef false "calleeArrow" ((PVar "dyn") (PVar "ft")) (EMatch (EApp (EVar "normalize") (EVar "ft")) (arm (PCon "TFun" (PVar "dom") (PVar "row") (PVar "res")) () (ETuple (EVar "dom") (EVar "row") (EVar "res"))) (arm PWild () (EBlock (DoLet false false (PVar "dom") (EApp (EApp (EVar "freshVar") (EFieldAccess (EVar "dyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "row") (EApp (EApp (EVar "openRow") (EFieldAccess (EVar "dyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "res") (EApp (EApp (EVar "freshVar") (EFieldAccess (EVar "dyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "ft")) (EApp (EApp (EApp (EVar "TFun") (EVar "dom")) (EVar "row")) (EVar "res")))) (DoExpr (ETuple (EVar "dom") (EVar "row") (EVar "res")))))))
(DTypeSig true "refStored" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyCon "Mono"))))
(DFunDef false "refStored" ((PVar "dyn") (PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TApp" (PCon "TCon" (PLit (LString "Ref")) PWild) (PVar "inner")) () (EVar "inner")) (arm PWild () (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "freshVar") (EFieldAccess (EVar "dyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "t")) (EApp (EApp (EVar "TApp") (EApp (EVar "tconBuiltin") (ELit (LString "Ref")))) (EVar "inner")))) (DoExpr (EVar "inner"))))))
(DTypeSig true "instantiateLegacyVarTracked" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Scheme") (TyCon "MethodTrackedInstantiation"))))))
(DFunDef false "instantiateLegacyVarTracked" ((PVar "mctx") (PVar "x") (PVar "id") (PVar "s")) (EMatch (EApp (EApp (EApp (EVar "lookupSchemeObls") (EVar "x")) (EVar "id")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "schemeObligationsRef") "value")) (arm (PCon "Some" (PVar "obs")) () (EBlock (DoLet false false (PVar "inst") (EApp (EApp (EApp (EVar "instantiateValueTracked") (EVar "mctx")) (EVar "x")) (EVar "s"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordSchemeCallObligations") (EVar "mctx")) (EVar "id")) (EVar "obs")) (EFieldAccess (EFieldAccess (EVar "inst") "mtiSubstitution") "misTypeSubst"))) (DoExpr (EVar "inst")))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "declaredCrossModuleObls") (EVar "mctx")) (EVar "x")) (arm (PCon "Some" (PVar "obs")) () (EBlock (DoLet false false (PVar "inst") (EApp (EApp (EApp (EVar "instantiateValueTracked") (EVar "mctx")) (EVar "x")) (EVar "s"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordSchemeCallObligations") (EVar "mctx")) (EVar "id")) (EVar "obs")) (EFieldAccess (EFieldAccess (EVar "inst") "mtiSubstitution") "misTypeSubst"))) (DoExpr (EVar "inst")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "instantiateValueTracked") (EVar "mctx")) (EVar "x")) (EVar "s")))))))
(DTypeSig true "declaredCrossModuleObls" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "VecObl"))))))
(DFunDef false "declaredCrossModuleObls" ((PVar "mctx") (PVar "x")) (EMatch (EApp (EApp (EVar "qualConstraintDecl") (EVar "mctx")) (EVar "x")) (arm (PCon "Some" (PVar "d")) () (EApp (EVar "Some") (EApp (EVar "vecOblsOfSlotVecs") (EApp (EApp (EVar "zipSlotVecs") (EFieldAccess (EVar "d") "cdSlots")) (EFieldAccess (EVar "d") "cdArgs"))))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "qualSchemeOblsFor") (EVar "mctx")) (EVar "x")) (arm (PCon "Some" (PVar "obs")) () (EApp (EVar "Some") (EVar "obs"))) (arm (PCon "None") () (EApp (EApp (EVar "omLookup") (EVar "x")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "crossRun") "coreSchemeObligationsRef") "value")))))))
(DTypeSig false "qualSchemeOblsFor" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "VecObl"))))))
(DFunDef false "qualSchemeOblsFor" ((PVar "mctx") (PVar "name")) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "importedSchemeOblsRef") "value")))
(DTypeSig false "vecOblsOfSlotVecs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "CSlot") (TyApp (TyCon "List") (TyCon "Mono")))) (TyApp (TyCon "List") (TyCon "VecObl"))))
(DFunDef false "vecOblsOfSlotVecs" ((PList)) (EListLit))
(DFunDef false "vecOblsOfSlotVecs" ((PCons (PTuple (PVar "s") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EFieldAccess (EFieldAccess (EVar "s") "csIface") "irName") (ELit (LString ""))) (EApp (EVar "vecOblsOfSlotVecs") (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "xmodVecObl") (EVar "s")) (EVar "v")) (EApp (EVar "vecOblsOfSlotVecs") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "xmodVecObl" (TyFun (TyCon "CSlot") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "VecObl"))))
(DFunDef false "xmodVecObl" ((PVar "s") (PVar "v")) (EIf (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "v")) (EApp (EVar "isEmptyL") (EApp (EApp (EDictApp "flatMap") (EVar "xmodOblArgId")) (EVar "v")))) (ERecordCreate "VecObl" ((fa "voIface" (EFieldAccess (EVar "s") "csIface")) (fa "voIds" (EListLit (EFieldAccess (EVar "s") "csId"))) (fa "voArgs" (EListLit)))) (EIf (EVar "otherwise") (ERecordCreate "VecObl" ((fa "voIface" (EFieldAccess (EVar "s") "csIface")) (fa "voIds" (EApp (EApp (EDictApp "flatMap") (EVar "xmodOblArgId")) (EVar "v"))) (fa "voArgs" (EVar "v")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "recordSchemeCallObligations" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "VecObl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyCon "Unit"))))))
(DFunDef false "recordSchemeCallObligations" ((PVar "mctx") PWild (PList) PWild) (ELit LUnit))
(DFunDef false "recordSchemeCallObligations" ((PVar "mctx") (PVar "originId") (PCons (PVar "o") (PVar "rest")) (PVar "subst")) (EMatch (EApp (EApp (EVar "substVecOblArgs") (EVar "o")) (EVar "subst")) (arm (PCon "Some" (PVar "monos")) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordObl") (EVar "mctx")) (ERecordCreate "Predicate" ((fa "iface" (EFieldAccess (EVar "o") "voIface")) (fa "args" (EVar "monos"))))) (EVar "originId")) (EVar "PSchemeReinst")) (EFieldAccess (EVar "mctx") "mcLoc"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordSchemeCallObligations") (EVar "mctx")) (EVar "originId")) (EVar "rest")) (EVar "subst"))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "recordSchemeCallObligations") (EVar "mctx")) (EVar "originId")) (EVar "rest")) (EVar "subst")))))
(DTypeSig false "substVecOblArgs" (TyFun (TyCon "VecObl") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Mono"))))))
(DFunDef false "substVecOblArgs" ((PVar "o") (PVar "subst")) (EIf (EApp (EVar "isEmptyL") (EFieldAccess (EVar "o") "voArgs")) (EApp (EApp (EVar "substMonos") (EFieldAccess (EVar "o") "voIds")) (EVar "subst")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "substOblArgs") (EFieldAccess (EVar "o") "voIds")) (EFieldAccess (EVar "o") "voArgs")) (EVar "subst")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "lookupSchemeObls" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "VecObl")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "VecObl")))))))
(DFunDef false "lookupSchemeObls" ((PVar "x") (PLit (LInt 0)) (PVar "table")) (EApp (EApp (EVar "lookupSchemeOblsByName") (EVar "x")) (EVar "table")))
(DFunDef false "lookupSchemeObls" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "lookupSchemeObls" ((PVar "x") (PVar "id") (PCons (PTuple (PTuple (PVar "n2") (PVar "i2")) (PVar "v")) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "n2") (EVar "x")) (EBinOp "==" (EVar "i2") (EVar "id"))) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "lookupSchemeObls") (EVar "x")) (EVar "id")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "lookupSchemeOblsByName" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "VecObl")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "VecObl"))))))
(DFunDef false "lookupSchemeOblsByName" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupSchemeOblsByName" ((PVar "x") (PCons (PTuple (PTuple (PVar "n2") PWild) (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n2") (EVar "x")) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupSchemeOblsByName") (EVar "x")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "unifySpineProbe" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Unit")))))
(DFunDef false "unifySpineProbe" ((PVar "dyn") (PVar "ft") (PVar "args")) (EBlock (DoLet false false (PVar "saved") (EApp (EVar "wSnapshot") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "fileValueFlows"))) (DoExpr (EApp (EApp (EApp (EVar "unifySpineProbeGo") (EVar "dyn")) (EVar "ft")) (EVar "args"))) (DoExpr (EApp (EApp (EVar "wRestore") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "fileValueFlows")) (EVar "saved")))))
(DTypeSig false "unifySpineProbeGo" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Unit")))))
(DFunDef false "unifySpineProbeGo" ((PVar "dyn") PWild (PList)) (ELit LUnit))
(DFunDef false "unifySpineProbeGo" ((PVar "dyn") (PVar "ft") (PCons (PVar "a") (PVar "rest"))) (EBlock (DoLet false false (PVar "r") (EApp (EApp (EVar "freshVar") (EFieldAccess (EVar "dyn") "dcModule")) (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "applicationRowTyped") (EVar "dyn")) (EVar "ft")) (EVar "a")) (EVar "r"))) (DoExpr (EApp (EApp (EApp (EVar "unifySpineProbeGo") (EVar "dyn")) (EVar "r")) (EVar "rest")))))
(DTypeSig true "unifyInto" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Bool") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit"))))))
(DFunDef false "unifyInto" ((PVar "dyn") (PVar "pos") (PVar "e") (PVar "a")) (EApp (EApp (EApp (EApp (EApp (EVar "unifyIntoOrd") (EVar "dyn")) (EVar "False")) (EVar "pos")) (EVar "e")) (EVar "a")))
(DTypeSig true "unifyIntoOrd" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))))
(DFunDef false "unifyIntoOrd" ((PVar "dyn") (PVar "valueFirst") (PVar "pos") (PVar "e") (PVar "a")) (EBlock (DoExpr (EIf (EBinOp "||" (EApp (EVar "monoHasArrowInSlot") (EVar "e")) (EApp (EVar "monoHasArrowInSlot") (EVar "a"))) (EIf (EVar "pos") (EApp (EApp (EApp (EApp (EVar "recordFileValueFlow") (EFieldAccess (EVar "dyn") "dcModule")) (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcLoc")) (EVar "e")) (EVar "a")) (EApp (EApp (EApp (EApp (EVar "recordFileValueFlow") (EFieldAccess (EVar "dyn") "dcModule")) (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcLoc")) (EVar "a")) (EVar "e"))) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "unifyIntoStep") (EVar "dyn")) (EVar "valueFirst")) (EVar "pos")) (EVar "e")) (EVar "a")))))
(DTypeSig false "unifyIntoStep" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))))
(DFunDef false "unifyIntoStep" ((PVar "dyn") (PVar "valueFirst") (PVar "pos") (PVar "e") (PVar "a")) (EApp (EApp (EApp (EApp (EApp (EVar "unifyIntoN") (EVar "dyn")) (EVar "valueFirst")) (EVar "pos")) (EApp (EVar "normalize") (EVar "e"))) (EApp (EVar "normalize") (EVar "a"))))
(DTypeSig false "unifyIntoN" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))))
(DFunDef false "unifyIntoN" ((PVar "dyn") PWild (PCon "True") (PCon "TVar" (PVar "cell")) (PAs "lower" (PCon "TFun" PWild PWild PWild))) (EApp (EApp (EApp (EVar "bindValueUpper") (EVar "dyn")) (EVar "cell")) (EVar "lower")))
(DFunDef false "unifyIntoN" ((PVar "dyn") PWild (PCon "True") (PCon "TVar" (PVar "cell")) (PAs "lower" (PCon "TApp" PWild PWild))) (EApp (EApp (EApp (EVar "bindValueUpper") (EVar "dyn")) (EVar "cell")) (EVar "lower")))
(DFunDef false "unifyIntoN" ((PVar "dyn") PWild (PCon "False") (PAs "lower" (PCon "TFun" PWild PWild PWild)) (PCon "TVar" (PVar "cell"))) (EApp (EApp (EApp (EVar "bindValueUpper") (EVar "dyn")) (EVar "cell")) (EVar "lower")))
(DFunDef false "unifyIntoN" ((PVar "dyn") PWild (PCon "False") (PAs "lower" (PCon "TApp" PWild PWild)) (PCon "TVar" (PVar "cell"))) (EApp (EApp (EApp (EVar "bindValueUpper") (EVar "dyn")) (EVar "cell")) (EVar "lower")))
(DFunDef false "unifyIntoN" ((PVar "dyn") PWild (PCon "True") (PCon "TVar" (PVar "cell")) (PAs "lower" (PCon "TQual" PWild PWild))) (EApp (EApp (EApp (EVar "bindValueUpper") (EVar "dyn")) (EVar "cell")) (EVar "lower")))
(DFunDef false "unifyIntoN" ((PVar "dyn") PWild (PCon "False") (PAs "lower" (PCon "TQual" PWild PWild)) (PCon "TVar" (PVar "cell"))) (EApp (EApp (EApp (EVar "bindValueUpper") (EVar "dyn")) (EVar "cell")) (EVar "lower")))
(DFunDef false "unifyIntoN" ((PVar "dyn") PWild PWild (PCon "TVar" (PVar "cell")) (PAs "t" (PCon "TQual" PWild PWild))) (EApp (EApp (EApp (EVar "bindVar") (EVar "dyn")) (EVar "cell")) (EVar "t")))
(DFunDef false "unifyIntoN" ((PVar "dyn") PWild PWild (PAs "t" (PCon "TQual" PWild PWild)) (PCon "TVar" (PVar "cell"))) (EApp (EApp (EApp (EVar "bindVar") (EVar "dyn")) (EVar "cell")) (EVar "t")))
(DFunDef false "unifyIntoN" ((PVar "dyn") (PVar "vf") (PVar "pos") (PCon "TQual" (PVar "e") (PVar "qe")) (PCon "TQual" (PVar "a") (PVar "qa"))) (EBlock (DoExpr (EIf (EVar "pos") (EApp (EApp (EApp (EVar "wantAuthority") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "qa")) (EVar "qe")) (EApp (EApp (EApp (EVar "wantAuthority") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "qe")) (EVar "qa")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "unifyIntoStep") (EVar "dyn")) (EVar "vf")) (EVar "pos")) (EVar "e")) (EVar "a")))))
(DFunDef false "unifyIntoN" ((PVar "dyn") (PVar "vf") (PVar "pos") (PCon "TQual" (PVar "e") (PVar "qe")) (PVar "a")) (EBlock (DoExpr (EIf (EVar "pos") (EApp (EApp (EApp (EVar "wantAuthority") (EFieldAccess (EVar "dyn") "dcModule")) (EApp (EVar "authTop") (EApp (EVar "authDomainTop") (EVar "qe")))) (EVar "qe")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "unifyIntoStep") (EVar "dyn")) (EVar "vf")) (EVar "pos")) (EVar "e")) (EVar "a")))))
(DFunDef false "unifyIntoN" ((PVar "dyn") (PVar "vf") (PVar "pos") (PVar "e") (PCon "TQual" (PVar "a") (PVar "qa"))) (EBlock (DoExpr (EIf (EVar "pos") (ELit LUnit) (EApp (EApp (EApp (EVar "wantAuthority") (EFieldAccess (EVar "dyn") "dcModule")) (EApp (EVar "authTop") (EApp (EVar "authDomainTop") (EVar "qa")))) (EVar "qa")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "unifyIntoStep") (EVar "dyn")) (EVar "vf")) (EVar "pos")) (EVar "e")) (EVar "a")))))
(DFunDef false "unifyIntoN" ((PVar "dyn") PWild PWild (PCon "TAuth" (PVar "qe")) (PCon "TAuth" (PVar "qa"))) (EApp (EApp (EApp (EVar "unifyIndex") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "qa")) (EVar "qe")))
(DFunDef false "unifyIntoN" ((PVar "dyn") (PVar "vf") (PVar "pos") (PCon "TFun" (PVar "e1") (PVar "er") (PVar "e2")) (PCon "TFun" (PVar "a1") (PVar "ar") (PVar "a2"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "unifyIntoStep") (EVar "dyn")) (EVar "vf")) (EApp (EVar "not") (EVar "pos"))) (EVar "e1")) (EVar "a1"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "rowInto") (EVar "dyn")) (EVar "pos")) (EApp (EVar "effrowNorm") (EVar "er"))) (EApp (EVar "effrowNorm") (EVar "ar")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "unifyIntoStep") (EVar "dyn")) (EVar "vf")) (EVar "pos")) (EVar "e2")) (EVar "a2")))))
(DFunDef false "unifyIntoN" ((PVar "dyn") (PVar "vf") (PVar "pos") (PAs "e" (PCon "TApp" (PVar "e1") (PVar "e2"))) (PAs "a" (PCon "TApp" (PVar "a1") (PVar "a2")))) (EIf (EBinOp "||" (EApp (EApp (EVar "tupleUnifyClash") (EVar "e")) (EVar "a")) (EApp (EApp (EVar "monoSlotNonCovariant") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "e1"))) (EApp (EApp (EApp (EApp (EVar "unifyOrdered") (EVar "dyn")) (EVar "vf")) (EVar "e")) (EVar "a")) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "unifyIntoStep") (EVar "dyn")) (EVar "vf")) (EVar "pos")) (EVar "e1")) (EVar "a1"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "unifyIntoStep") (EVar "dyn")) (EVar "vf")) (EVar "pos")) (EVar "e2")) (EVar "a2")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "unifyIntoN" ((PVar "dyn") (PVar "vf") PWild (PVar "e") (PVar "a")) (EApp (EApp (EApp (EApp (EVar "unifyOrdered") (EVar "dyn")) (EVar "vf")) (EVar "e")) (EVar "a")))
(DTypeSig false "bindValueUpper" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "Ref") (TyCon "Tyvar")) (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "bindValueUpper" ((PVar "dyn") (PVar "cell") (PVar "lower")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "occursCheckFailed")) (EVar "False"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "occursAdjust") (EFieldAccess (EVar "dyn") "dcModule")) (EApp (EVar "tyvarId") (EVar "cell"))) (EApp (EVar "tyvarLevel") (EVar "cell"))) (EVar "lower"))) (DoExpr (EIf (EApp (EVar "not") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "occursCheckFailed") "value")) (EBlock (DoLet false false (PVar "upper") (EApp (EApp (EVar "optionOrFresh") (EFieldAccess (EVar "dyn") "dcModule")) (EApp (EApp (EVar "joinProducedEnvelope") (EApp (EApp (EApp (EVar "valueJoinOps") (EVar "dyn")) (EVar "JoinArgument")) (EVar "collectValueAllowance"))) (EListLit (ETuple (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcLoc") (EVar "lower")))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordFileValueFlow") (EFieldAccess (EVar "dyn") "dcModule")) (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcLoc")) (EVar "upper")) (EVar "lower"))) (DoExpr (EApp (EApp (EApp (EVar "bindVar") (EVar "dyn")) (EVar "cell")) (EVar "upper")))) (ELit LUnit)))))
(DTypeSig false "collectValueAllowance" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "List") (TyCon "EffRow")) (TyCon "EffRow"))))
(DFunDef false "collectValueAllowance" ((PVar "dyn") (PVar "rows")) (EBlock (DoLet false false (PVar "cell") (EApp (EApp (EVar "freshInferenceEffvar") (EFieldAccess (EVar "dyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "EffectSolver.registerValueAllowance") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "effectSummaries")) (EVar "cell"))) (DoLet false false (PVar "upper") (EApp (EApp (EVar "EffRow") (EListLit)) (EApp (EVar "Some") (EVar "cell")))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "lower")) (EApp (EApp (EApp (EApp (EVar "rowInto") (EVar "dyn")) (EVar "True")) (EVar "upper")) (EVar "lower")))) (ELit LUnit)) (EVar "rows"))) (DoExpr (EVar "upper"))))
(DTypeSig false "unifyOrdered" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Bool") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit"))))))
(DFunDef false "unifyOrdered" ((PVar "dyn") (PCon "True") (PVar "e") (PVar "a")) (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "a")) (EVar "e")))
(DFunDef false "unifyOrdered" ((PVar "dyn") (PCon "False") (PVar "e") (PVar "a")) (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "e")) (EVar "a")))
(DTypeSig true "rowInto" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Bool") (TyFun (TyCon "EffRow") (TyFun (TyCon "EffRow") (TyCon "Unit"))))))
(DFunDef false "rowInto" ((PVar "dyn") (PVar "pos") (PVar "er") (PVar "ar")) (EIf (EApp (EVar "EffectSolver.hasSummaryScope") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "effectSummaries")) (EIf (EVar "pos") (EApp (EApp (EApp (EApp (EVar "deferEffectRelation") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "False")) (EVar "ar")) (EVar "er")) (EApp (EApp (EApp (EApp (EVar "deferEffectRelation") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "False")) (EVar "er")) (EVar "ar"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "rowInto" ((PVar "dyn") (PCon "True") (PCon "EffRow" (PVar "le") (PCon "None")) (PCon "EffRow" (PVar "la") (PCon "None"))) (EApp (EApp (EApp (EVar "effectLeakCheck") (EFieldAccess (EVar "dyn") "dcModule")) (EApp (EApp (EApp (EVar "atomsEscape") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph")) (EVar "la")) (EVar "le"))) (EVar "le")))
(DFunDef false "rowInto" ((PVar "dyn") (PCon "False") (PCon "EffRow" (PVar "le") (PCon "None")) (PCon "EffRow" (PVar "la") (PCon "None"))) (EApp (EApp (EApp (EApp (EVar "contraRowCheck") (EFieldAccess (EVar "dyn") "dcModule")) (EApp (EApp (EApp (EVar "atomsEscape") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph")) (EVar "le")) (EVar "la"))) (EVar "le")) (EVar "la")))
(DFunDef false "rowInto" ((PVar "dyn") (PCon "True") (PAs "er" (PCon "EffRow" (PVar "le") PWild)) (PAs "ar" (PCon "EffRow" (PVar "la") (PCon "None")))) (EIf (EApp (EVar "isEmptyL") (EApp (EApp (EApp (EVar "atomsEscape") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph")) (EVar "la")) (EVar "le"))) (ELit LUnit) (EApp (EApp (EApp (EVar "unifyRowN") (EVar "dyn")) (EVar "er")) (EVar "ar"))))
(DFunDef false "rowInto" ((PVar "dyn") (PCon "False") (PAs "er" (PCon "EffRow" (PVar "le") (PCon "None"))) (PAs "ar" (PCon "EffRow" (PVar "la") PWild))) (EIf (EApp (EVar "isEmptyL") (EApp (EApp (EApp (EVar "atomsEscape") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph")) (EVar "le")) (EVar "la"))) (ELit LUnit) (EApp (EApp (EApp (EVar "unifyRowN") (EVar "dyn")) (EVar "er")) (EVar "ar"))))
(DFunDef false "rowInto" ((PVar "dyn") PWild (PVar "er") (PVar "ar")) (EApp (EApp (EApp (EVar "unifyRowN") (EVar "dyn")) (EVar "er")) (EVar "ar")))
(DTypeSig false "contraRowCheck" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "Unit"))))))
(DFunDef false "contraRowCheck" ((PVar "mctx") (PList) PWild PWild) (ELit LUnit))
(DFunDef false "contraRowCheck" ((PVar "mctx") (PVar "extras") (PVar "le") (PVar "la")) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-EFFECT-LEAK"))) (EApp (EApp (EApp (EVar "contraRowMsg") (EVar "le")) (EVar "la")) (EVar "extras"))))
(DTypeSig true "monoHasNonCovariantSlot" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyCon "Bool"))))
(DFunDef false "monoHasNonCovariantSlot" ((PVar "mctx") (PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "monoSlotNonCovariant") (EVar "mctx")) (EVar "a")) (EApp (EApp (EVar "monoHasNonCovariantSlot") (EVar "mctx")) (EVar "a"))) (EApp (EApp (EVar "monoHasNonCovariantSlot") (EVar "mctx")) (EVar "b")))) (arm (PCon "TFun" (PVar "a") PWild (PVar "b")) () (EBinOp "||" (EApp (EApp (EVar "monoHasNonCovariantSlot") (EVar "mctx")) (EVar "a")) (EApp (EApp (EVar "monoHasNonCovariantSlot") (EVar "mctx")) (EVar "b")))) (arm PWild () (EVar "False"))))
(DTypeSig false "monoSlotNonCovariant" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyCon "Bool"))))
(DFunDef false "monoSlotNonCovariant" ((PVar "mctx") (PVar "hd")) (EMatch (EApp (EVar "headTyconMono") (EVar "hd")) (arm (PCon "Some" (PCon "HkDecl" (PVar "key"))) () (EMatch (EApp (EApp (EVar "paramPolaritiesOf") (EVar "mctx")) (EVar "key")) (arm (PCon "Some" (PVar "pols")) () (EMatch (EApp (EApp (EVar "polarityAt") (EVar "pols")) (EApp (EVar "monoSpineDepth") (EVar "hd"))) (arm (PCon "PCo") () (EVar "False")) (arm PWild () (EVar "True")))) (arm (PCon "None") () (EVar "False")))) (arm PWild () (EVar "False"))))
(DTypeSig true "unifyParamsExpected" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Unit")))))
(DFunDef false "unifyParamsExpected" ((PVar "dyn") (PCons (PVar "p") (PVar "ps")) (PCons (PVar "e") (PVar "es"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "bindFrom") (EVar "dyn")) (EVar "p")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EVar "unifyParamsExpected") (EVar "dyn")) (EVar "ps")) (EVar "es")))))
(DFunDef false "unifyParamsExpected" ((PVar "dyn") PWild PWild) (ELit LUnit))
(DTypeSig true "applicationRowTyped" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "EffRow"))))))
(DFunDef false "applicationRowTyped" ((PVar "dyn") (PVar "ft") (PVar "xt") (PVar "result")) (EMatch (EApp (EVar "normalize") (EVar "ft")) (arm (PCon "TFun" (PVar "dom") (PVar "row") (PVar "res")) () (EBlock (DoExpr (EApp (EApp (EApp (EVar "argumentIntoTyped") (EVar "dyn")) (EVar "dom")) (EVar "xt"))) (DoExpr (EApp (EApp (EApp (EVar "bindFrom") (EVar "dyn")) (EVar "result")) (EVar "res"))) (DoExpr (EVar "row")))) (arm PWild () (EBlock (DoLet false false (PVar "unknown") (EApp (EApp (EVar "openRow") (EFieldAccess (EVar "dyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "ft")) (EApp (EApp (EApp (EVar "TFun") (EVar "xt")) (EVar "unknown")) (EVar "result")))) (DoExpr (EVar "unknown"))))))
(DTypeSig false "argumentIntoTyped" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "argumentIntoTyped" ((PVar "dyn") (PVar "dom") (PVar "xt")) (EMatch (EApp (EVar "normalize") (EVar "dom")) (arm (PCon "TQual" (PVar "d") (PVar "q")) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "unifyInto") (EVar "dyn")) (EVar "True")) (EVar "d")) (EVar "xt"))) (DoExpr (EApp (EApp (EApp (EVar "wantAuthority") (EFieldAccess (EVar "dyn") "dcModule")) (EApp (EApp (EVar "typeAuthority") (EApp (EVar "authDomainTop") (EVar "q"))) (EVar "xt"))) (EVar "q"))))) (arm PWild () (EApp (EApp (EApp (EApp (EVar "unifyInto") (EVar "dyn")) (EVar "True")) (EVar "dom")) (EVar "xt")))))
(DTypeSig true "joinValueTypes" (TyFun (TyCon "DynCtx") (TyFun (TyCon "JoinContext") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono"))) (TyCon "Mono")))))
(DFunDef false "joinValueTypes" ((PVar "dyn") (PVar "context") (PVar "values")) (EBlock (DoLet false false (PVar "upper") (EApp (EApp (EVar "optionOrFresh") (EFieldAccess (EVar "dyn") "dcModule")) (EApp (EApp (EVar "joinProduced") (EApp (EApp (EApp (EVar "valueJoinOps") (EVar "dyn")) (EVar "context")) (ELam (PWild) (EApp (EVar "collectRows") (EApp (EVar "joinCellOf") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph")))))) (EVar "values")))) (DoLet false false PWild (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "loc") (PVar "lower"))) (EApp (EApp (EApp (EApp (EVar "recordFileValueFlow") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "loc")) (EVar "upper")) (EVar "lower")))) (EVar "values"))) (DoExpr (EVar "upper"))))
(DTypeSig true "valueJoinOps" (TyFun (TyCon "DynCtx") (TyFun (TyCon "JoinContext") (TyFun (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "List") (TyCon "EffRow")) (TyCon "EffRow"))) (TyApp (TyCon "ValueJoinOps") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "valueJoinOps" ((PVar "dyn") (PVar "context") (PVar "collector")) (EBlock (DoLet false false (PVar "ops") (EApp (EApp (EApp (EVar "decidingJoinOps") (EVar "dyn")) (EVar "context")) (EVar "collector"))) (DoExpr (ERecordUpdate (EVar "ops") ((fa "vjoDefer" (ELam ((PVar "values")) (EApp (EApp (EApp (EApp (EVar "deferJoin") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "context")) (EVar "collector")) (EVar "values")))))))))
(DTypeSig false "decidingJoinOps" (TyFun (TyCon "DynCtx") (TyFun (TyCon "JoinContext") (TyFun (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "List") (TyCon "EffRow")) (TyCon "EffRow"))) (TyApp (TyCon "ValueJoinOps") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "decidingJoinOps" ((PVar "dyn") (PVar "context") (PVar "collector")) (ERecordCreate "ValueJoinOps" ((fa "vjoEqual" (EApp (EApp (EVar "joinValueEqual") (EVar "dyn")) (EVar "context"))) (fa "vjoCovariants" (EApp (EVar "producedSlotCovariants") (EFieldAccess (EVar "dyn") "dcModule"))) (fa "vjoFreshType" (EApp (EVar "freshVar") (EFieldAccess (EVar "dyn") "dcModule"))) (fa "vjoFreshRow" (EApp (EVar "openRow") (EFieldAccess (EVar "dyn") "dcModule"))) (fa "vjoCollectRows" (EApp (EVar "collector") (EVar "dyn"))) (fa "vjoFreshAuth" (ELam ((PVar "top")) (EApp (EVar "AVar") (EApp (EApp (EApp (EVar "freshAuthvar") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "top")) (EVar "None"))))) (fa "vjoCollectAuth" (EApp (EVar "collectAuthAllowance") (EFieldAccess (EVar "dyn") "dcModule"))) (fa "vjoDefer" (ELam (PWild) (EVar "None"))))))
(DTypeSig false "deferJoin" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "JoinContext") (TyFun (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "List") (TyCon "EffRow")) (TyCon "EffRow"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono"))) (TyApp (TyCon "Option") (TyCon "Mono")))))))
(DFunDef false "deferJoin" ((PVar "mctx") (PVar "context") (PVar "collector") (PVar "values")) (EIf (EBinOp "&&" (EApp (EVar "EffectSolver.hasSummaryScope") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "effectSummaries")) (EApp (EVar "distinctVariables") (EVar "values"))) (EBlock (DoLet false false (PVar "result") (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "pendingJoinsRef")) (EBinOp "::" (ERecordCreate "PendingJoin" ((fa "pjResult" (EVar "result")) (fa "pjValues" (EVar "values")) (fa "pjLevel" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (fa "pjContext" (EVar "context")) (fa "pjCollector" (EVar "collector")))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "pendingJoinsRef") "value")))) (DoExpr (EApp (EVar "Some") (EVar "result")))) (EVar "None")))
(DTypeSig false "distinctVariables" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono"))) (TyCon "Bool")))
(DFunDef false "distinctVariables" ((PVar "values")) (EBlock (DoLet false false (PVar "roots") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PTuple PWild (PVar "value"))) (EMatch (EApp (EVar "normalize") (EVar "value")) (arm (PCon "TVar" (PVar "cell")) () (EApp (EApp (EApp (EVar "IdMap.set") (EApp (EVar "tyvarId") (EVar "cell"))) (ELit LUnit)) (EVar "acc"))) (arm PWild () (EVar "acc"))))) (EVar "Tip")) (EVar "values"))) (DoExpr (EBinOp ">=" (EApp (EVar "listLen") (EApp (EVar "IdMap.keys") (EVar "roots"))) (ELit (LInt 2))))))
(DTypeSig true "resolvePendingJoins" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Int") (TyCon "Unit"))))
(DFunDef false "resolvePendingJoins" ((PVar "dyn") (PVar "level")) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "pendingJoinsRef") "value") (arm (PCons (PVar "pj") (PVar "rest")) () (EIf (EBinOp ">=" (EFieldAccess (EVar "pj") "pjLevel") (EVar "level")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "pendingJoinsRef")) (EVar "rest"))) (DoExpr (EApp (EApp (EVar "resolvePendingJoin") (EVar "dyn")) (EVar "pj"))) (DoExpr (EApp (EApp (EVar "resolvePendingJoins") (EVar "dyn")) (EVar "level")))) (ELit LUnit))) (arm (PList) () (ELit LUnit))))
(DTypeSig true "settlePendingJoins" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Int") (TyCon "Unit"))))
(DFunDef false "settlePendingJoins" ((PVar "dyn") (PVar "level")) (EBlock (DoLet false false (PVar "postponed") (EApp (EApp (EApp (EVar "settlePending") (EVar "dyn")) (EVar "level")) (EListLit))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "pendingJoinsRef")) (EBinOp "++" (EApp (EVar "reverseL") (EVar "postponed")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "pendingJoinsRef") "value"))))))
(DTypeSig false "settlePending" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PendingJoin")) (TyApp (TyCon "List") (TyCon "PendingJoin"))))))
(DFunDef false "settlePending" ((PVar "dyn") (PVar "level") (PVar "postponed")) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "pendingJoinsRef") "value") (arm (PCons (PVar "pj") (PVar "rest")) () (EIf (EBinOp ">=" (EFieldAccess (EVar "pj") "pjLevel") (EVar "level")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "pendingJoinsRef")) (EVar "rest"))) (DoExpr (EIf (EApp (EApp (EVar "joinOfOuterVariables") (EVar "level")) (EVar "pj")) (EBlock (DoExpr (EApp (EApp (EVar "lowerTyvarLevel") (EBinOp "-" (EVar "level") (ELit (LInt 1)))) (EFieldAccess (EVar "pj") "pjResult"))) (DoExpr (EApp (EApp (EApp (EVar "settlePending") (EVar "dyn")) (EVar "level")) (EBinOp "::" (ERecordUpdate (EVar "pj") ((fa "pjLevel" (EBinOp "-" (EVar "level") (ELit (LInt 1)))))) (EVar "postponed"))))) (EBlock (DoExpr (EApp (EApp (EVar "resolvePendingJoin") (EVar "dyn")) (EVar "pj"))) (DoExpr (EApp (EApp (EApp (EVar "settlePending") (EVar "dyn")) (EVar "level")) (EVar "postponed"))))))) (EVar "postponed"))) (arm (PList) () (EVar "postponed"))))
(DTypeSig false "joinOfOuterVariables" (TyFun (TyCon "Int") (TyFun (TyCon "PendingJoin") (TyCon "Bool"))))
(DFunDef false "joinOfOuterVariables" ((PVar "level") (PVar "pj")) (EBinOp "&&" (EApp (EVar "isUnshaped") (EFieldAccess (EVar "pj") "pjResult")) (EApp (EApp (EVar "allList") (ELam ((PVar "value")) (EApp (EApp (EVar "isOuterVariable") (EVar "level")) (EApp (EVar "snd") (EVar "value"))))) (EFieldAccess (EVar "pj") "pjValues"))))
(DTypeSig false "isOuterVariable" (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyCon "Bool"))))
(DFunDef false "isOuterVariable" ((PVar "level") (PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TVar" (PVar "cell")) () (EBinOp "<" (EApp (EVar "tyvarLevel") (EVar "cell")) (EVar "level"))) (arm PWild () (EVar "False"))))
(DTypeSig false "lowerTyvarLevel" (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyCon "Unit"))))
(DFunDef false "lowerTyvarLevel" ((PVar "level") (PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TVar" (PVar "cell")) () (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Unbound" (PVar "id") (PVar "old")) () (EIf (EBinOp ">" (EVar "old") (EVar "level")) (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EApp (EVar "Unbound") (EVar "id")) (EVar "level"))) (ELit LUnit))) (arm (PCon "Link" PWild) () (ELit LUnit)))) (arm PWild () (ELit LUnit))))
(DTypeSig true "postponePendingJoins" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyCon "Unit"))))
(DFunDef false "postponePendingJoins" ((PVar "mctx") (PVar "level")) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "pendingJoinsRef")) (EApp (EApp (EVar "lowerPending") (EVar "level")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "pendingJoinsRef") "value"))))
(DTypeSig false "lowerPending" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PendingJoin")) (TyApp (TyCon "List") (TyCon "PendingJoin")))))
(DFunDef false "lowerPending" ((PVar "level") (PCons (PVar "pj") (PVar "rest"))) (EIf (EBinOp ">=" (EFieldAccess (EVar "pj") "pjLevel") (EVar "level")) (EBinOp "::" (ERecordUpdate (EVar "pj") ((fa "pjLevel" (EBinOp "-" (EVar "level") (ELit (LInt 1)))))) (EApp (EApp (EVar "lowerPending") (EVar "level")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "lowerPending" (PWild (PVar "pending")) (EVar "pending"))
(DTypeSig false "resolvePendingJoin" (TyFun (TyCon "DynCtx") (TyFun (TyCon "PendingJoin") (TyCon "Unit"))))
(DFunDef false "resolvePendingJoin" ((PVar "dyn") (PVar "pj")) (EMatch (EApp (EVar "normalize") (EFieldAccess (EVar "pj") "pjResult")) (arm (PCon "TVar" PWild) () (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EFieldAccess (EVar "pj") "pjResult")) (EApp (EApp (EVar "resolveDeferredJoin") (EApp (EApp (EApp (EVar "decidingJoinOps") (EVar "dyn")) (EFieldAccess (EVar "pj") "pjContext")) (EFieldAccess (EVar "pj") "pjCollector"))) (EFieldAccess (EVar "pj") "pjValues")))) (arm PWild () (EApp (EApp (EVar "settleShapedJoins") (EVar "dyn")) (EListLit (EVar "pj"))))))
(DTypeSig false "collectAuthAllowance" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Authority")) (TyCon "Authority"))))
(DFunDef false "collectAuthAllowance" ((PVar "mctx") (PVar "lowers")) (EBlock (DoLet false false (PVar "top") (EMatch (EVar "lowers") (arm (PCons (PVar "q") PWild) () (EApp (EVar "authDomainTop") (EVar "q"))) (arm (PList) () (EVar "PUnit")))) (DoLet false false (PVar "cell") (EApp (EApp (EApp (EVar "freshAuthvar") (EVar "mctx")) (EVar "top")) (EVar "None"))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "q")) (EApp (EApp (EApp (EVar "wantAuthority") (EVar "mctx")) (EVar "q")) (EApp (EVar "AVar") (EVar "cell"))))) (ELit LUnit)) (EVar "lowers"))) (DoExpr (EApp (EVar "AVar") (EVar "cell")))))
(DTypeSig true "optionOrFresh" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "Mono")) (TyCon "Mono"))))
(DFunDef false "optionOrFresh" ((PVar "mctx") (PCon "None")) (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit)))
(DFunDef false "optionOrFresh" ((PVar "mctx") (PCon "Some" (PVar "value"))) (EVar "value"))
(DTypeSig false "joinValueEqual" (TyFun (TyCon "DynCtx") (TyFun (TyCon "JoinContext") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))))
(DFunDef false "joinValueEqual" ((PVar "outer") (PVar "context") (PVar "loc") (PVar "left") (PVar "right")) (EBlock (DoLet false false (PVar "dyn") (EApp (EApp (EVar "dynAtIfSome") (EVar "loc")) (EVar "outer"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "noteNumlitCtx") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "left")) (EVar "right")) (EVar "context"))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (ERecordUpdate (EVar "dyn") ((fa "dcJoin" (EApp (EVar "Some") (EVar "context")))))) (EVar "left")) (EVar "right")))))
(DTypeSig true "producedSlotCovariants" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Bool")))))
(DFunDef false "producedSlotCovariants" ((PVar "mctx") (PVar "head")) (EMatch (EApp (EVar "headTyconMono") (EVar "head")) (arm (PCon "Some" (PCon "HkDecl" (PVar "key"))) () (EBlock (DoLet false false (PVar "slot") (EApp (EVar "monoSpineDepth") (EVar "head"))) (DoExpr (EMatch (EApp (EApp (EVar "paramPolaritiesOf") (EVar "mctx")) (EVar "key")) (arm (PCon "Some" (PVar "polarities")) () (EApp (EApp (EMethodRef "map") (EVar "isCovariantPolarity")) (EApp (EApp (EVar "drop") (EVar "slot")) (EVar "polarities")))) (arm (PCon "None") () (EIf (EApp (EApp (EVar "tabKeyEq") (EVar "key")) (EApp (EApp (EVar "tyTabKey") (EVar "OriginBuiltin")) (ELit (LString "List")))) (EIf (EBinOp "==" (EVar "slot") (ELit (LInt 0))) (EListLit (EVar "True")) (EListLit)) (EMatch (EApp (EVar "headTyconNameMono") (EVar "head")) (arm (PCon "Some" (PVar "name")) () (EMatch (EApp (EVar "tupleTagArity") (EVar "name")) (arm (PCon "Some" (PVar "arity")) () (EIf (EApp (EApp (EVar "tabKeyEq") (EVar "key")) (EApp (EApp (EVar "tyTabKey") (EVar "OriginBuiltin")) (EVar "name"))) (EApp (EApp (EVar "replicate") (EBinOp "-" (EVar "arity") (EVar "slot"))) (EVar "True")) (EListLit))) (arm (PCon "None") () (EListLit)))) (arm (PCon "None") () (EListLit))))))))) (arm PWild () (EListLit))))
(DTypeSig false "isCovariantPolarity" (TyFun (TyCon "Polarity") (TyCon "Bool")))
(DFunDef false "isCovariantPolarity" ((PCon "PCo")) (EVar "True"))
(DFunDef false "isCovariantPolarity" (PWild) (EVar "False"))
(DTypeSig true "raiseAuthvarLevel" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "Unit"))))
(DFunDef false "raiseAuthvarLevel" ((PVar "level") (PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "AUnbound" (PVar "id") PWild (PVar "top") (PVar "pat") (PVar "name")) () (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EApp (EApp (EApp (EApp (EVar "AUnbound") (EVar "id")) (EVar "level")) (EVar "top")) (EVar "pat")) (EVar "name")))) (arm (PCon "ALink" PWild PWild PWild) () (ELit LUnit))))
(DTypeSig true "polarityAt" (TyFun (TyApp (TyCon "List") (TyCon "Polarity")) (TyFun (TyCon "Int") (TyCon "Polarity"))))
(DFunDef false "polarityAt" ((PList) PWild) (EVar "PCo"))
(DFunDef false "polarityAt" ((PCons (PVar "q") (PVar "rest")) (PVar "i")) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (EVar "q") (EApp (EApp (EVar "polarityAt") (EVar "rest")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))
(DTypeSig true "freshVars" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "freshVars" ((PVar "mctx") (PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit)) (EApp (EApp (EVar "freshVars") (EVar "mctx")) (EBinOp "-" (EVar "n") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "lowerOwnedRoot" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "lowerOwnedRoot" ((PVar "mctx") (PVar "owner") (PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EIf (EBinOp "==" (EApp (EVar "tyvarLevel") (EVar "cell")) (EVar "owner")) (EApp (EApp (EVar "lowerToCurrent") (EVar "mctx")) (EVar "m")) (ELit LUnit))) (arm PWild () (ELit LUnit))))
(DTypeSig true "monoUnboundVarLevels" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "monoUnboundVarLevels" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TVar" (PVar "cell")) () (EListLit (ETuple (EApp (EVar "tyvarId") (EVar "cell")) (EApp (EVar "tyvarLevel") (EVar "cell"))))) (arm (PCon "TCon" PWild PWild) () (EListLit)) (arm (PCon "TRigid" PWild) () (EListLit)) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EBinOp "++" (EApp (EVar "monoUnboundVarLevels") (EVar "a")) (EApp (EVar "monoUnboundVarLevels") (EVar "b")))) (arm (PCon "TFun" (PVar "a") PWild (PVar "b")) () (EBinOp "++" (EApp (EVar "monoUnboundVarLevels") (EVar "a")) (EApp (EVar "monoUnboundVarLevels") (EVar "b")))) (arm (PCon "TEff" PWild) () (EListLit)) (arm (PCon "TAuth" PWild) () (EListLit)) (arm (PCon "TQual" (PVar "a") PWild) () (EApp (EVar "monoUnboundVarLevels") (EVar "a")))))
(DTypeSig true "recordFileValueFlow" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit"))))))
(DFunDef false "recordFileValueFlow" ((PVar "mctx") (PVar "loc") (PVar "upper") (PVar "lower")) (EApp (EApp (EVar "wPush") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fileValueFlows")) (ETuple (EVar "loc") (EVar "upper") (EVar "lower"))))
(DTypeSig true "unifySourceDomains" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit"))))))
(DFunDef false "unifySourceDomains" ((PVar "dyn") (PVar "arity") (PVar "owned") (PVar "actual")) (EIf (EBinOp "<=" (EVar "arity") (ELit (LInt 0))) (ELit LUnit) (EMatch (ETuple (EApp (EVar "normalize") (EVar "owned")) (EApp (EVar "normalize") (EVar "actual"))) (arm (PTuple (PCon "TFun" (PVar "domain") PWild (PVar "result")) (PCon "TFun" (PVar "param") PWild (PVar "body"))) () (EBlock (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "domain")) (EVar "param"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "unifySourceDomains") (EVar "dyn")) (EBinOp "-" (EVar "arity") (ELit (LInt 1)))) (EVar "result")) (EVar "body"))))) (arm PWild () (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "owned")) (EVar "actual"))))))
(DTypeSig true "zipBindFrom" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Unit")))))
(DFunDef false "zipBindFrom" ((PVar "dyn") (PCons (PVar "p") (PVar "ps")) (PCons (PVar "q") (PVar "qs"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "bindFrom") (EVar "dyn")) (EVar "p")) (EVar "q"))) (DoExpr (EApp (EApp (EApp (EVar "zipBindFrom") (EVar "dyn")) (EVar "ps")) (EVar "qs")))))
(DFunDef false "zipBindFrom" ((PVar "dyn") PWild PWild) (ELit LUnit))
