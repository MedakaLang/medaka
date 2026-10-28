# META
source_lines=3001
stages=DESUGAR,MARK
# SOURCE
-- tc_global: the whole-graph and declaration-level checks that need inference: the coherence scan,
-- impl head, super-context and completeness checks, impl and default method bodies, survivor call
-- obligations.
--
-- Spec: DICT section 6 C1-C4, section 5.1 M1-M3, section 3 (super context); #3995/#4010.
--
-- Placement: declarations are placed by R1-R6 of the Phase 4 module table,
-- compiler/ARCHITECTURE-PLAYBOOK.md section 6.
-- Closure rule: this module may not import `types.typecheck`, nor any of `tc_module`.

import types.tc_types.{
  BuiltinClass(..),
  CohSweep(..),
  DeclaringBinder(..),
  GrantBinder(..),
  HeadVarRoot(..),
  ImplBodySite(..),
  Kind(..),
  MethodBodyCheck(..),
  MethodBodyInstance(..),
  MethodBodyKind(..),
  MStep(..),
  NumBoundary(..),
  NumBoundaryDisposition(..),
  NumGuard(..),
  PredicateSlot(..),
  PredicateSlotArgs(..),
  Provenance(..),
  ReqStep(..),
  ScopedImplMethod(..),
  SiteCtx(..),
  TcEnv(..),
  UObligation(..),
  CeRow,
  ClassEnv,
  CohImpl,
  CohScan,
  GraphCtx,
  ImplEnv,
  ImplRow,
  ModuleCtx,
  PendingDictApp,
  ReqWalk,
  siteFor,
}
import types.tc_mono.{
  allArrowEffs,
  anyConcreteHead,
  anyContainsI,
  anyMember,
  authCellsIn,
  authOrderIn,
  authOrderRow,
  cohEqMono,
  cohOverlap,
  cohPpPair,
  containsI,
  dedupI,
  hasDupI,
  headVarRootOf,
  instantiateNamedMonos,
  isUnboundTvar,
  matchOneSided,
  monoRootIdSet,
  monoTyvarId,
  monoTyvarIds,
  monoUnboundIds,
  peelQual,
  sigTvarIds,
  stripTyWrap,
  tyAppSpine,
  tyStep,
  tyStructEq,
  tyvarId,
  tyVarNames,
}
import types.tc_diag_text.{
  backticked,
  cohCrossModuleMsg,
  cohIncomparableHelp,
  cohOverlapMsg,
  cohPreludeOverlapMsg,
  collapsesTyvarsMsg,
  derivableIface,
  implGoalFixesHeadMsg,
  implHeadIndexMsg,
  implKindMismatchMsg,
  implTupleHeadKindMsg,
  methodBodyLaunderMsg,
  methodBodySubject,
  missingImplMethodMsg,
  narrowsImplHeadMsg,
  pinsTyvarMsg,
  qualifiedIfaceLabel,
  superContextNoImplMsg,
  superContextUndeclaredMsg,
  undeclaredImplPredicateMsg,
  undeclaredImplPrerequisiteMsg,
}
import types.tc_state.{
  callUOblsWindow,
  currentScopeStore,
  defaultReceiverOrdinal,
  dynAtIfSome,
  emptySigVars,
  envAtIfSome,
  mctxAtIfSome,
  wMark,
  wRestore,
  wSnapshot,
  wWindow,
}
import types.tc_env.{
  anyKRow,
  builtinIfaceRef,
  ceLookupAt,
  ceMethodTyAt,
  ceRequiredAt,
  ceRowIfaceName,
  ceRowLoc,
  ceRowMethods,
  ceRowsOwnedBy,
  ceRowSupers,
  ceRowTyparams,
  ceSlotKindsAt,
  constraintSlotDispatchVar,
  declGradedScope,
  effTailNames,
  extendVars,
  ieRowInst,
  ieRowLoc,
  ieRowOrd,
  ieRowsAll,
  ieRowsOwnedBy,
  ieRowsVisibleAt,
  ieRowTriple,
  ifaceTabKey,
  instRefMid,
  methodLevelConstraintVarNames,
  removeAllS,
  tyTabKey,
}
import types.tc_diag.{
  erredDuring,
  pushTypeError,
  pushTypeErrorAt,
  pushTypeErrorOnceAt,
  pushTypeErrorOncePerSite,
}
import types.tc_unify.{
  captureScope,
  closeScope,
  enterLevel,
  exitLevel,
  freshAuthBinderRanged,
  freshTvMap,
  instantiateMethodTracked,
  rowInto,
  unifyInto,
}
import types.tc_decls_types.{
  authArgBindersIn,
  bindingForceFromAst,
  fromAstType,
  fromAstTypeE,
  kindsEq,
  patternSlotNamesIn,
  rowArgNamesIn,
  sigConstraintsOf,
  sigVarsWithAuths,
}
import types.tc_decls.{
  dedupBinders,
  methodSchemesPure,
  sigToSchemeTvsIn,
  sigVarsFor,
  tyConNamesInTy,
}
import types.tc_solve_givens.{
  givenAnswers,
  predicateSlotKnownSupers,
  publishMethodPredGivens,
  registerFunPredGiven,
  registerImplMethodDicts,
  registerMethodDictSlots,
}
import types.tc_solve_entail.{
  goalCandidates,
  goalRows,
  reqWalkEnter,
  reqWalkMemo,
  reqWalkSeed,
  reqWalkStart,
  superParamsOf,
}
import types.tc_solve.{
  answeredOnlyByBindingHead,
  determineByUniqueInstance,
  dictAppsSince,
  goalsMark,
  improveByUniqueImpl,
  noteWalkGoalFollowed,
  openScope,
  rigidHeadInstanceContext,
  solvedCleanly,
  solvedOnWalk,
  uOblArgs,
  walkGoalFollowed,
}
import types.tc_solve_check.{
  callOblsWindow,
  callPredOf,
  checkSigVarGoals,
  checkSurvivorDispatchMonos,
  checkSurvivorObligations,
  finalizeNumBoundary,
  ifaceSelfAndSupers,
  implGoalResiduals,
  numConstrainedIds,
  numObligIds,
  oblPredOf,
  prerequisiteOnWalk,
  registerImplRequires,
  rejectUndeterminedVectors,
  rejectWithheldAmbiguity,
  reportUndeterminedNoImpl,
  reqWalkReported,
  survivorNameOfId,
}
import types.tc_effects.{
  beginEffectContract,
  checkMethodEffVarRigidity,
  eagerIndexOnlyVars,
  finishEffectContract,
  indexOnlyEffVars,
  launderEscapeFromLog,
  markSourceless,
  methodGrantOf,
  performSiteIn,
  recordClauseFileBound,
}
import types.tc_occurrence.{mkMethodOccObl}
import types.tc_groups.{exprLoc, requireGoalsBelow, sccProtectedSignatureIds}
import types.tc_infer.{appArgLoc, inferBindingChecked, valueSpanLoc}
import types.scopes.{DefaultBodyIdentity(..), ScopeOwner(..)}
import frontend.ast.{
  Constraint(..),
  Decl(..),
  Expr(..),
  IfaceMethod(..),
  ImplMethod(..),
  Loc(..),
  MethodDefault(..),
  Pat(..),
  Require(..),
  Super(..),
  TabKey(..),
  Ty(..),
  TyConOrigin(..),
  firstTyLoc,
  firstTyLocList,
  implMethodName,
  lookupTab,
  orElseLoc,
  sameTyConHead,
}
import types.repr.{
  IfaceRef(..), Mono(..), lookupAssocI, normalize, ppEach, ppTy, ppTyAtom
}
import map.{Map(..)}
import support.ordmap.{omEmpty, omFromNames, omHasKey, OrdMap}
import types.evidence.{ScopeId(..)}
import types.publish.{TcDiag(..)}
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
}
import list.{drop, get, range, reverse, zip}
import string.{join}
import types.effect_rows.{effrowNorm}
import frontend.desugar.{exprSpanLoc}
import frontend.resolve.{firstExprLoc}
import types.route_key.{ifaceWordOf}
import types.superclass.{lookupPos, mapAll, superIfaceRef}
import types.registry.{regKeyOfTab}
import types.scopes as Scopes
import map as IdMap

-- #822 (graded interfaces): an instance head must have the KIND the interface's
-- corresponding type parameter has.  A graded interface binds the whole row-indexed
-- FAMILY — `impl GThenable Async`, never a fixed row like `impl GThenable (Async e)`
-- (EFFECTS-SEMANTICS §6, DICT-SEMANTICS §3) — so the head's REMAINING parameter
-- kinds (its declared kinds minus the ones the head already applied) must equal the
-- interface slot's kinds.
--
-- This is a soundness guard, not polish.  A kind-mismatched head elaborates the
-- method type's KRow slot to a `TEff` row while the constructor's own scheme has a
-- plain tyvar in that position, and `unify` binds a tyvar to a TEff without
-- complaint: the impl would be ACCEPTED and its grade would mean nothing — every
-- index a caller reads off the result would be a fabrication.
--
-- Only interfaces that actually HAVE a graded slot are JUDGED — the `anyKRow want`
-- guard below is what does that, not the table: every slot of every interface is
-- recorded (it always was, and `ceRowParamKinds` keeps doing so), and an all-`KType`
-- row falls into the same `_ => ()` arm an outright miss does.  This paragraph
-- read *"only interfaces that actually HAVE a graded slot are inspected
-- (ifaceParamKindsRef records nothing else)"* until #1557 A-3.5c, and the
-- parenthetical was false of the retired table too.  Runs on BOTH whole-program
-- paths: its one call site is in checkBodyImpl, shared by Flat and Module,
-- immediately after `dataEnv` has populated the head-constructor kind table.
--
-- #1557 A-3.5c: it still iterates `prog`, and that is the unit's defining
-- CONDITION, not an implementation detail.  The owner ruling that split A-3.5c
-- out of the A-3b lane (issue #1557, 2026-08-12) is CONDITIONAL: this check
-- qualifies as CE-only *"only if the graded impl-head kind check keeps
-- iterating `prog` rather than `IE.ieRows`"*.  The impl HEADS come from the
-- decl list; only the interface's declared slot kinds come from stage K's `CE`.
-- Whoever re-points this walk at `IE.ieRows` has re-classified the unit as A-3b
-- by construction — that is a routing decision, not a refactor.
export
checkGradedImplHeads : ModuleCtx -> ClassEnv -> Int -> List Decl -> Unit
checkGradedImplHeads mctx _ _ [] = ()
checkGradedImplHeads mctx ce cur (d :: rest) =
  checkGradedImplHeadDecl mctx ce cur d
  checkGradedImplHeads mctx ce cur rest

-- OCCURRENCE MINT (#1110/#1111 A-2.4): `implOrigin` is the identity the
-- interface NAME in `impl <iface> …` acquired at resolve — read off the same record
-- pattern as the name itself so the two cannot drift apart, exactly as A-2.3 reads
-- `tyConOrigin` beside `tyConName`.
checkGradedImplHeadDecl : ModuleCtx -> ClassEnv -> Int -> Decl -> Unit
checkGradedImplHeadDecl mctx ce cur (DAttrib _ d) =
  checkGradedImplHeadDecl mctx ce cur d
checkGradedImplHeadDecl mctx ce cur (DImpl { iface, tys, implOrigin = o, ... }) =
  checkGradedImplTys mctx ce cur o iface 0 tys
checkGradedImplHeadDecl mctx _ _ _ = ()

-- The `CE` lookup via `ceSlotKindsAt` uses ordinal filtering — the key is a RegKey
-- (`ifaceTabKey o iface` + slot position), identity-based not bare-name, preserving
-- the identity mint from A-2.4. Ordinals are assigned in dependency-first order,
-- matching the order the accumulator is grown in, so ordinal filtering and the
-- previous marshalled population agree. See
-- compiler/TYPECHECK-TARGET-ARCHITECTURE.md § "5. Decisions reopened, and decisions
-- deliberately kept" (A-3.5c) for the prior bare-name table this replaced and the
-- #1257 defect class it drains.
checkGradedImplTys : ModuleCtx ->
  ClassEnv ->
  Int ->
  TyConOrigin ->
  String ->
  Int ->
  List Ty ->
  Unit
checkGradedImplTys mctx _ _ _ _ _ [] = ()
checkGradedImplTys mctx ce cur o iface i (t :: rest) =
  match ceSlotKindsAt (regKeyOfTab (ifaceTabKey o iface)) cur i ce
    Some want if anyKRow want => checkGradedImplHead mctx iface t want
    _ => ()
  checkGradedImplTys mctx ce cur o iface (i + 1) rest

-- [want] is the interface slot's kind list.
--
-- Only a head whose kind is actually KNOWN is judged, and the two ways it can be
-- unknown are BOTH deliberate abstentions, not oversights:
--   * a type ALIAS head lives in aliasTableRef, never in dataParamKindsRef, and its
--     saturation is already policed by T-ALIAS-ARITY — a kind complaint here would be
--     a second, worse-worded report of the same defect;
--   * a head absent from dataParamKindsRef entirely — a builtin like `Int`, whose kinds
--     this compiler records nowhere.  Abstaining costs nothing real: a genuinely wrong
--     head still fails on its method bodies, where the mismatch is concrete and located.
--     An ABSTRACTLY-exported data type (`export data Asy e a`) USED to land here too,
--     cross-module, and the abstention was load-bearing for it: judging it reported a
--     correct program rejected and told the author to add a `Row` parameter the type
--     ALREADY HAD.  #804/#1028 fixed that at the source — an opaque type's kinds are
--     published cross-module (`kindPublicDataDecl`'s `VisAbstract` arm; it was
--     `registerOpaqueParamKinds` until A-3.2b retired the kind universe) — so an
--     abstract head is now judged on its REAL kinds like any other, and this arm no
--     longer covers for it.
-- A head that is not a TyCon spine at all is judged where it can be: a saturated
-- TUPLE is kind `Type`, which is never a graded slot's kind, so it is reported; a bare
-- tyvar head carries no kind and is left to the checks that already reject it.
checkGradedImplHead : ModuleCtx -> String -> Ty -> List Kind -> Unit
checkGradedImplHead mctx iface t want = match tyAppSpine t
  (TyCon { tyConName = n, tyConLoc = loc, tyConOrigin = o }, applied) =>
    checkGradedImplHeadCon mctx iface o n loc (listLen applied) want
  -- A saturated tuple is kind `Type`, which is never a graded slot's kind.  It gets its
  -- OWN remedy: the generic "give it a Row parameter" advice is nonsense for a tuple —
  -- you cannot add one.  The span is best-effort: `TyTuple` carries no loc of its own
  -- and `TyVar` carries none either, so `impl I (a, b)` genuinely has no span to point at
  -- and reports unlocated.  Fabricating a nearby one would be worse than saying nothing.
  (TyTuple ts, _) =>
    pushTypeErrorOncePerSite
      mctx
      "T-IMPL-KIND-MISMATCH"
      (firstTyLocList ts)
      (implTupleHeadKindMsg iface (listLen ts) want)
  _ => ()

checkGradedImplHeadCon : ModuleCtx ->
  String ->
  TyConOrigin ->
  String ->
  Option Loc ->
  Int ->
  List Kind ->
  Unit
checkGradedImplHeadCon mctx iface o n loc nApplied want =
  match headRemainingKinds mctx o n nApplied
    None => ()
    Some got => checkGradedImplHeadKinds mctx iface n loc nApplied want got

-- The head constructor's declared parameter kinds MINUS the ones the head already
-- applies (`impl I (Async e)` supplies one).  `None` = "this head's kind is not
-- knowable here" (an alias or a builtin), which the caller treats as an abstention.
-- An abstractly-exported type was in that bucket until #804/#1028 and is NOT any
-- more — `kindPublicDataDecl`'s `VisAbstract` arm gives it a real `dataParamKindsRef`
-- entry (via `declEnvSeedChain`), so it returns `Some` and is judged exactly like
-- a `public export` one.
-- `key` is minted ONCE and shared by both guard arms via the `where` (#1111
-- A-2.3 follow-up): the first guard ALWAYS evaluates it (Medaka is strict, and
-- a `where` scoping over guard arms lowers to `ELetGroup (..key..) (EGuards
-- arms)`, so the binding runs once before either arm is tested), so hoisting
-- adds nothing on the alias arm and removes the previously-redundant second
-- mint on the common `otherwise` arm.  A redundant-allocation removal, not a
-- measured perf win (`test/bench.sh` doesn't run on this box, #1187; the
-- perf-scaling gate grades a growth ratio, blind to a constant factor).
headRemainingKinds : ModuleCtx ->
  TyConOrigin ->
  String ->
  Int ->
  Option (List Kind)
headRemainingKinds mctx o n nApplied
  | isSome (lookupTab key mctx.mcCells.aliasTableRef.value) = None
  | otherwise =
    map (drop nApplied) (lookupTab key mctx.mcCells.dataParamKindsRef.value)
  where
    key = tyTabKey o n

checkGradedImplHeadKinds : ModuleCtx ->
  String ->
  String ->
  Option Loc ->
  Int ->
  List Kind ->
  List Kind ->
  Unit
checkGradedImplHeadKinds mctx iface n loc nApplied want got
  | kindsEq got want = ()
  | otherwise =
    pushTypeErrorOncePerSite
      mctx
      "T-IMPL-KIND-MISMATCH"
      loc
      (implKindMismatchMsg iface n nApplied want got)

-- A method body's own authority binders, bound by the body's grant parameters.
-- The instance head's cells are no caller's to supply.  Every other authority
-- variable of the instantiated type is the method's own, and they occur in the
-- order `grantOrder` reads the method's scheme in, since both are the one written
-- type read left to right: the k-th of them is the k-th grant, whatever it is
-- called.
registerMethodBodyGrants : GraphCtx ->
  IfaceRef ->
  String ->
  List Mono ->
  MethodBodyInstance ->
  ScopeId ->
  Unit
registerMethodBodyGrants gctx iface mname heads inst (ScopeId sid) =
  let headIds = IdMap.keys (fold (acc h => authCellsIn h acc) Tip heads)
  markSourceless gctx headIds
  match methodGrantOf gctx (ifaceWordOf iface.irOrigin iface.irName) mname
    None => ()
    Some mg =>
      let own =
        filterList
          (i => not (containsI i headIds))
          (reverse
            (authOrderRow
              inst.mbiContractForce
              (authOrderIn inst.mbiExpected [])))
      let ids =
        map (k => optionOr (0 - 1) (get k own)) (range 0 (listLen mg.mgNames))
      let st = gctx.graphRun.grants
      st.gsBodies := IdMap.set sid (BodyGrantBinder mname ids) st.gsBodies.value

-- The D3 channel rule is an identity intersection, not whole-type reachability:
-- only roots constrained by this boundary's own Num obligations can survive, and
-- only when the supplied head/dictionary channels carry that exact live root.
numChannelRootSet : List UObligation -> List Mono -> OrdMap Unit
numChannelRootSet obls channels =
  let channelIds = monoRootIdSet channels
  omFromNames
    (filterList
      (name => omHasKey name channelIds)
      (map intToString (dedupI (numConstrainedIds obls))))
    omEmpty

-- 🪦 RETIRED 2026-08-12 (#1559 A-3.7 bite 3.7-9): `cohImplsOf` / `cohImplsOfMid` —
-- the decl-walking adapters that built `CohImpl`s straight off `DImpl` nodes, and
-- `cohCollectImpls` / `cohCollectModuleImpls`, their two list drivers.  Coherence's
-- input is now a projection of `IE`'s rows (`cohImplOfRow`), so both sweeps read the
-- registry the rest of stage K reads instead of re-walking decls.  Zero tree-wide
-- callers at deletion time (`grep -rn 'cohCollectImpls\|cohCollectModuleImpls\|
-- cohImplsOf' --include=*.mdk .` → definitions and comments only).  The `#414` span
-- derivation they carried is preserved below, because `cohImplOfRow` still calls
-- `firstTyLocList` on the row's head and inherits every word of it.
--
-- #414: the span to blame for an impl comes from its head types, via
-- `firstTyLocList` (`frontend/ast.mdk`), which folds `firstTyLoc` — that inner
-- walk is the one shared with resolve (`dupSigOf`); resolve does not call
-- `firstTyLocList` itself (issue 480).
-- A `DImpl` has no `Loc` of its own (`DUse` is the only `Decl` variant
-- carrying one inline) — but the parser stamps every `TyCon` leaf with its span
-- (`parser.mdk`'s parseTyAtom: `tyConUnresolved c (Some (locOfSpan s q))`), so the head's
-- own tycon IS the impl's location.  Pre-order, so `impl C (Pair a Int)` blames
-- `Pair` — the head — not the argument.  An alias head's expansion is located at
-- the alias occurrence (`locateTyAt`), so `impl C LB` still blames `LB`.
--
-- RESIDUAL (#414): only `TyCon` leaves carry spans, so a head with NO tycon —
-- the fully-parametric `impl Foo a` — still yields `None` and falls back to the
-- file-start caret.  That is the degenerate overlap case (`test/
-- typecheck_error_fixtures/overlapping_impls.mdk`).  Closing it needs a span on
-- `TyVar` (an ast.mdk change rippling through every `Ty` consumer) or the parser's
-- `DeclPos` side-table threaded into typecheck; both are out of proportion to an
-- S3 diagnostic-quality fix.  Every head naming a CONCRETE type is covered.
--
-- #1559 A-3.7 OCCURRENCE MINT, and the retirement above is the reason it worked:
-- the deleted adapter destructured `implOrigin` in the SAME record pattern as `iface`
-- and built the `IfaceRef` from that pair on the spot, using the identical expression
-- `implDeclFact` uses to build `ImplRow`'s interface half.  Because the two
-- constructions could not drift, replacing the adapter with a projection of `IE`'s
-- rows yields the same interface half by construction rather than by assertion.
--
-- the impl's head args → monos under ONE shared fresh-var map (so a var reused
-- across args, e.g. `Conv a a`, is the SAME fresh tyvar — the oracle shares one
-- tbl across the whole impl head; distinct impls get distinct ids).
cohFreshTys : ModuleCtx -> List Ty -> List Mono
cohFreshTys mctx tys = snd (implHeadMonos mctx tys)

-- An impl head's variables under their declared kinds: a name in an
-- `Authority`-kinded slot (`impl Eq (Handle p)`) is an authority binder, as
-- in a signature; every other bare name is a type variable.  One map is
-- shared across the head's arguments, so a name reused across them is one
-- variable.
implHeadMonos : ModuleCtx -> List Ty -> (List (String, Mono), List Mono)
implHeadMonos mctx tys =
  each (checkImplHeadIndices mctx) tys
  let auths = dedupBinders (flatMap (authArgBindersIn mctx) tys) []
  let pats = flatMap (patternSlotNamesIn mctx) tys
  let tvMap =
    freshTvMap
      mctx
      (removeAllS (map fst auths) (dedup (flatMap tyVarNames tys)))
  let etbl =
    sigVarsWithAuths
      (map (b => freshAuthBinderRanged mctx (contains (fst b) pats) b) auths)
      emptySigVars
  (tvMap, map (fromAstTypeE mctx etbl tvMap) tys)

-- An instance is chosen by its head's type constructor and the index is
-- erased, so an impl covers every index of the head: an `Authority` slot of
-- an impl head takes a name, never a written term.
checkImplHeadIndices : ModuleCtx -> Ty -> Unit
checkImplHeadIndices mctx (TyApp a b) = match tyAppSpine (TyApp a b)
  (TyCon { tyConName = n, tyConOrigin = o }, args) =>
    match lookupTab (tyTabKey o n) mctx.mcCells.dataParamKindsRef.value
      Some kinds if listLen kinds == listLen args =>
        fold
          (_ ka => match ka
            (KAuth _ _, TyAuth ps loc) =>
              pushTypeErrorOncePerSite
                mctx
                "T-AUTHORITY-KIND"
                loc
                (implHeadIndexMsg n (ppTy (TyAuth ps loc)))
            _ => ())
          ()
          (zip kinds args)
      _ => ()
  _ => ()
checkImplHeadIndices mctx _ = ()

-- #1559 A-3.7: THE `IE`→`CohImpl` ADAPTER — coherence's input, relocated off the decl
-- walk.  Every one of the four things coherence judges on comes out of the row:
--   * the interface half is `ieRowTriple`'s `IfaceRef` — the SAME value
--     `cohImplsOfMid` built by hand from `iface`+`implOrigin`, because `implDeclFact`
--     builds it with the identical expression.  That is why this relocation is not an
--     acceptance change: `cohSameIface` (3.7-4) sees the same pair of `IfaceRef`s.
--   * the head is `cohFreshTys` of the row's `List Ty`, the same call the decl
--     adapter made.  Effectful (fresh tyvars), exactly as the decl adapter was.
--     The head is already in alias normal form (`stampGraphDecls`), so
--     coherence compares the head selection reads, and `fromAstTypeE` finds no
--     alias left on it to expand with the checked module's alias table (the
--     wrong table for another module's head).
--   * the owner module id is `instRefMid` of the row's `InstRef` — this is where
--     `InstRef` acquires its FIRST judgment reader in this tree.
--   * the blame span is `firstTyLocList` of that same head.
-- `ieLoc` is not owed for this.  `ImplRow`'s "no location field" note argues from
-- `Decl` carrying no `Loc`, which is true and beside the point: the row carries the
-- head's `List Ty`, and the parser stamps every `TyCon` leaf with its span, so the span
-- coherence uses today is recoverable with no new field and no `DImpl` change.
cohImplOfRow : ModuleCtx -> ImplRow -> CohImpl
cohImplOfRow mctx r = match ieRowTriple r
  (ir, tys, _) =>
    CohImpl
      ir
      (cohFreshTys mctx tys)
      (instRefMid (ieRowInst r))
      (orElseLoc (firstTyLocList tys) (ieRowLoc r))

-- The prelude is ordinal 0 on the Module arm, structurally: `buildDeclEnvs` builds
-- `declEnvModulesFrom 0 (("core", coreDecls)::modules)`, so nothing else can be.
-- Coherence compares a program's impls with the prelude's (DICT-SEMANTICS §6.1), but
-- never the prelude's with itself: the prelude is trusted and cannot be edited.
cohPreludeOrd : Int
cohPreludeOrd = 0

-- the prelude's own rows: the second population of the per-module sweep.
cohPreludeRows : ImplEnv -> List ImplRow
cohPreludeRows env = ieRowsOwnedBy cohPreludeOrd env

-- every USER module's rows, for the whole-graph sweep.  The prelude is absent here
-- because a program-vs-prelude pair is owned by the per-module sweep (which sees the
-- prelude and reports with the impl's own span); the whole-graph sweep would report
-- the same pair a second time, span-less.
cohRowsOf : ImplEnv -> List ImplRow
cohRowsOf env = filterList (r => ieRowOrd r /= cohPreludeOrd) (ieRowsAll env)

-- the per-module sweep's own population.  The prelude module itself checks nothing:
-- its rows are the second population, never the first.
cohRowsOwnedBy : Int -> ImplEnv -> List ImplRow
cohRowsOwnedBy cur env
  | cur == cohPreludeOrd = []
  | otherwise = ieRowsOwnedBy cur env

-- subsumes ~general ~specific: is [specific] an instance of [general]?  Only the
-- general side's vars bind (consistently: a var bound twice must see structurally
-- equal types); the specific side's vars are rigid (match only the same id).
cohSubsumes : List Mono -> List Mono -> Bool
cohSubsumes general specific
  | listLen general == listLen specific =
    isSome (matchOneSided cohStep (==) cohEqMono (zip general specific) [])
  | otherwise = False

-- Mono-space step: normalize BOTH sides (chasing links), then classify the general
-- node.  Effect rows are row-blind (TEff/TEff ⇒ MOk; TFun's row slot ignored).
cohStep : Mono -> Mono -> MStep Int Mono Mono
cohStep g0 s0 =
  let g = peelQual (normalize g0)
  let s = peelQual (normalize s0)
  match g
    TVar c => MVar (tyvarId c)
    -- #1111 A-2.10 on the `TCon`/`TCon` pairing only (`sameTyConHead`); the
    -- cross-population arms stay name-only for the reason `cohGoR` gives.
    -- The cross-population ones are not separately probed — armed
    -- because the pre-split arm answered them, and because a rigid and a real
    -- head CAN both spell `__tupleN__` (see `Mono.TRigid`).  Measured instances
    -- of that forgery: `unifyN`, `matchStep` (§8 I6.2(b), OWED-#1243).
    TCon a oa => match s
      TCon b ob => if sameTyConHead a oa b ob then MOk else MFail
      TRigid b => if a == b then MOk else MFail
      _ => MFail
    TRigid a => match s
      TRigid b => if a == b then MOk else MFail
      TCon b _ => if a == b then MOk else MFail
      _ => MFail
    TApp f1 a1 => match s
      TApp f2 a2 => MKids [(f1, f2), (a1, a2)]
      _ => MFail
    TFun a1 _ b1 => match s
      TFun a2 _ b2 => MKids [(a1, a2), (b1, b2)]
      _ => MFail
    TEff _ => match s
      TEff _ => MOk
      _ => MFail
    TAuth _ => match s
      TAuth _ => MOk
      _ => MFail

-- [a] strictly more specific than [b]: b subsumes a but not a subsumes b
cohStrictlyMoreSpecific : List Mono -> List Mono -> Bool
cohStrictlyMoreSpecific a b = cohSubsumes b a && not (cohSubsumes a b)

-- [impls] are paired with each other; each is also paired with every one of [fixed]
-- (the prelude's impls), which are never paired with one another.
cohScan : CohSweep -> List CohImpl -> List CohImpl -> CohScan
cohScan sweep impls fixed = cohScanOuter sweep impls fixed (CohScan None None)

cohScanOuter : CohSweep -> List CohImpl -> List CohImpl -> CohScan -> CohScan
cohScanOuter _ [] _ acc = acc
cohScanOuter sweep (e :: rest) fixed acc
  | cohScanDone acc = acc
  | otherwise =
    cohScanOuter
      sweep
      rest
      fixed
      (cohScanInner sweep e fixed (cohScanInner sweep e rest acc))

-- both classes already witnessed ⇒ nothing later can change what is reported.
cohScanDone : CohScan -> Bool
cohScanDone (CohScan (Some _) (Some _)) = True
cohScanDone _ = False

-- #1559 A-3.7: do two impl occurrences name the same interface?
--
-- `sameTyConHead`, never `ifaceIdMatches`, and the two are exact inverses.  This
-- is the whole substance of the bite, so the derivation is here rather than in a
-- ledger:
--   * `sameTyConHead n1 o1 n2 o2 = n1 == n2 && not (tyConIdsConflict o1 o2)`
--     (`frontend/ast.mdk`) — name equality, and an ABSENT origin makes NO CLAIM, so
--     it matches anything.
--   * `ifaceIdMatches a b = a /= "" && a == b` (`frontend/ast.mdk`) — absence NEVER
--     matches, not even itself.
-- `recordCandIsType`'s header states which to use when, and the rule is about the
-- QUESTION being asked, not about the table: `sameTyConHead` belongs where a false
-- REJECT would refuse a valid program (an ACCEPTANCE question); `ifaceIdMatches`
-- belongs where a false HIT is silent wrongness (a LOOKUP).
--
-- Coherence is an ACCEPTANCE question — it decides whether to reject a program — so
-- `sameTyConHead` is correct, and it is also the FAIL-LOUD direction here: an impl
-- whose `implOrigin` is still `OriginUnresolved` compares by name exactly as it did
-- before this unit, so no live rejection can silently vanish.  `ifaceIdMatches` in
-- this position would turn every unstamped-origin conflict into a SILENT ACCEPT,
-- which is a severity INCREASE and one no fixture in the tree would catch.
--
-- NOT a re-keying of the HEAD half.  Coherence's head comparison already routes
-- through `sameTyConHead` (`cohGoR`'s `TCon` arm, A-2.10) and is untouched, so the
-- #1317 T1 rule and closed S0 #1277 are not in scope for this unit.
cohSameIface : IfaceRef -> IfaceRef -> Bool
cohSameIface a b = sameTyConHead a.irName a.irOrigin b.irName b.irOrigin

cohScanInner : CohSweep -> CohImpl -> List CohImpl -> CohScan -> CohScan
cohScanInner _ _ [] acc = acc
cohScanInner sweep (e1@(CohImpl if1 xs mid1 _)) ((CohImpl if2 ys mid2 _) :: rest) acc
  | cohScanDone acc = acc
  | cohSameIface if1 if2 && cohOverlap xs ys =
    cohScanInner sweep e1 rest (cohClassify sweep e1 xs ys mid1 mid2 acc)
  | otherwise = cohScanInner sweep e1 rest acc

-- classify ONE overlapping pair.  A strict specialization either way is coherent
-- (most-specific-wins ranks it) and contributes nothing.  The remaining two cases
-- are exhaustive and disjoint: `cohStrictlyMoreSpecific a b = cohSubsumes b a && not
-- (cohSubsumes a b)`, so if neither direction is strict then `cohSubsumes` holds
-- BOTH ways (mutual ⇒ HARD) or NEITHER way (incomparable ⇒ SOFT).
-- Keep-first per class mirrors the old "first conflict wins" reporting.
--
-- Why the hard arm cannot simply move to the goal site, stated because "then fix
-- it there" is the obvious review question and the answer is not "we didn't try".
-- The root is one level up from `entryCovers`: `entryCoversAllOthers` /
-- `findMostSpecificEntry` test for a ⊑-MINIMUM, where §6 C1 requires **at most one
-- ⊑-MINIMAL element**.  In a preorder that is not antisymmetric those two coincide
-- everywhere EXCEPT at α-equal heads — precisely this arm's class.  (`entryCovers`
-- itself is fine: with `S = tySubsumesV`, `tyHeadEqV a b || S b a` is exactly ⊑;
-- it does not conflate ⊒ with =.)  Tightening `entryCoversAllOthers` to demand
-- STRICT specificity was built and measured: it finds 6 true positives and then
-- breaks `stdlib/core.mdk`, which stops typechecking with "the goal `Num Int`
-- matches `impl Num Int` and `impl Num Int`" — checking core as a user program
-- registers the same instance twice, and deduping needs INSTANCE IDENTITY this tree
-- does not have (`bucketKeyEntriesFrom` restarts its numbering at 0 per module, so
-- two distinct impls in different modules share an index).  That is L2 / A-3 / B-2
-- work.  Until it exists, the declaration site is the only place this class is
-- caught at all.
--
-- A program impl α-equal to a PRELUDE impl is this arm's class too: the per-module
-- sweep pairs each program impl with the prelude's impls (DICT-SEMANTICS §6.1), so a
-- user `impl Display String` is rejected at the program's impl.  A strictly more
-- specific program impl is coherent and wins on every engine.
cohClassify : CohSweep ->
  CohImpl ->
  List Mono ->
  List Mono ->
  String ->
  String ->
  CohScan ->
  CohScan
cohClassify sweep e1 xs ys mid1 mid2 (CohScan hard soft)
  | cohStrictlyMoreSpecific xs ys = CohScan hard soft
  | cohStrictlyMoreSpecific ys xs = CohScan hard soft
  | cohMutuallySubsumes xs ys && cohHardInScope sweep mid1 mid2 =
    CohScan
      (cohKeepFirst hard (Some (cohHardMsg e1 xs ys mid1 mid2, cohImplLoc e1)))
      soft
  -- A mutually-subsuming pair the sweep does NOT own contributes nothing at all --
  -- it must not fall through to the soft arm below, because HARD and SOFT are
  -- disjoint classes (mutual subsumption is the exact complement of
  -- ⊑-incomparability here), and reporting it as `W-INCOMPARABLE-IMPLS`
  -- would be a wrong classification, not a quieter one.
  | cohMutuallySubsumes xs ys = CohScan hard soft
  | not (cohSoftInScope sweep mid1 mid2) = CohScan hard soft
  | otherwise =
    CohScan
      hard
      (cohKeepFirst
        soft
        (Some (
          cohIncomparableMsg (cohImplIfaceName e1) xs ys mid1 mid2,
          cohImplLoc e1,
        )))

-- Which sweep OWNS a soft (⊑-incomparable) pair.  Two sweeps run over overlapping
-- inputs: `checkCoherence` over ONE module's own impls and `globalCoherenceConflict`
-- over every user module's impls (real mids).  A pair
-- whose two impls live in the SAME module is seen by BOTH — the per-module one with a
-- real span, the global one span-less (#414) — so recording it in both makes
-- `run`/`build` print it TWICE where `check` prints it once.  The global sweep's
-- unique contribution is the pair that SPANS two modules, which no per-module sweep
-- can see; that is the only soft pair it should claim.
--
-- Scoped to the SOFT class deliberately.  The HARD class double-reports the same
-- way, and that is PRE-EXISTING — it did so as a `T-CONFLICTING-IMPL` error before
-- F-3d, on these same two paths — so narrowing it here would be an unrelated
-- behaviour change riding this one, and one that moves error goldens.
-- The answer depends on the sweep, not on the shape of the module ids: the
-- per-module sweep's rows carry real module ids, so an intra-module pair arrives
-- as `(m, m)` with `m /= ""`, and a blank-id test would drop every intra-module
-- `W-INCOMPARABLE-IMPLS` (a diagnostic-only loss no value golden can see).
--
-- The sweep tag says outright what the mid shapes were being read to infer:
--   * `CohSweepOwn` — the per-module sweep.  Its input is ONE module's own rows, so
--     every pair it sees is intra-module BY CONSTRUCTION and it owns all of them.
--     It answers `True` unconditionally.
--   * `CohSweepGlobal` — the whole-graph sweep.  It owns only the pair that SPANS two
--     modules; the intra-module ones already belong to the sweep above.  The `"" ""`
--     arm answers `True` for a degenerate global input in which both ids are blank.
cohSoftInScope : CohSweep -> String -> String -> Bool
cohSoftInScope CohSweepOwn _ _ = True
cohSoftInScope CohSweepGlobal "" "" = True
cohSoftInScope CohSweepGlobal mid1 mid2 = cohIsCrossModule mid1 mid2

-- Which sweep OWNS a HARD (mutually-subsuming) pair.  #1449 / F8: the SAME rule as
-- `cohSoftInScope`, and it is a delegation rather than a copy so the two classes can
-- never drift apart silently.
--
-- This is the narrowing `cohSoftInScope`'s header declined to make, now made
-- deliberately.  That header said, of the hard class: "The HARD class double-reports
-- the same way, and that is PRE-EXISTING … so narrowing it here would be an unrelated
-- behaviour change riding this one, and one that moves error goldens."  It is no
-- longer unrelated: the double report IS #1449's shape, and it is user-visible on the
-- most ordinary program there is.  Measured before this change, on a single file with
-- two `impl Foo Int`, `medaka check --json` emitted the identical
-- `T-CONFLICTING-IMPL` message TWICE — once with the declaration's real span (from the
-- per-module sweep, `checkCoherence` / `CohSweepOwn`) and once span-less (from this
-- whole-graph sweep, prepended by `attachCoherenceConflict`, which `driveGraphK` and
-- the keyed arm of `checkModulesDiagsChain` both call.  An IMPORT-BEARING two-module
-- program whose overlap is entry-module-local double-reports identically, so the
-- double report is not specific to one module.  Per-module sweep and whole-graph
-- sweep each report the pair: one with the declaration span, one without it.
--
-- NOT loud→silent, and here is why that is a claim and not a hope.  The pair this
-- now declines is INTRA-module, and the per-module sweep's population
-- (`cohRowsOwnedBy cur`) contains every one of that module's own rows by
-- construction, with `foldModules` running the worker for EVERY module in the graph.
-- So the union of the per-module sweeps already covers every intra-module pair the
-- whole-graph sweep could see, WITH a span, which is strictly the better diagnostic.
-- The whole-graph sweep's unique contribution -- the pair that SPANS two modules, which
-- no per-module sweep can see -- is exactly what this predicate keeps.  Control
-- measured across the change: two modules each declaring `impl Foo Int` for a third
-- module's interface still reports `Conflicting `impl Foo`. Defined in amod and main`,
-- once.
--
-- The one residual hole is `runFinalChecks`' documented `-1` ordinal sentinel, at which
-- `checkCoherence` sweeps no rows: an intra-module hard pair would then be reported by
-- NEITHER sweep.  That path is unreachable today and `ordinalSentinelGuard` already
-- pushes a loud `T-INTERNAL-ORDINAL` error when it is taken, so the failure announces
-- itself rather than accepting silently.
cohHardInScope : CohSweep -> String -> String -> Bool
cohHardInScope sweep mid1 mid2 = cohSoftInScope sweep mid1 mid2

-- each head matches the other, i.e. they are α-equal up to renaming (`cohSubsumes`
-- is one-sided matching, so mutual matching means each is an instance of the other).
cohMutuallySubsumes : List Mono -> List Mono -> Bool
cohMutuallySubsumes xs ys = cohSubsumes xs ys && cohSubsumes ys xs

cohKeepFirst : Option a -> Option a -> Option a
cohKeepFirst (Some x) _ = Some x
cohKeepFirst None y = y

-- HARD wording.  When the two impls come from DIFFERENT modules (mid1 /= mid2, both
-- non-empty), the message names BOTH owning modules (the cross-module global-
-- coherence case, D3/WS-2 — which is exactly the duplicate-instance class).
cohHardMsg : CohImpl -> List Mono -> List Mono -> String -> String -> String
cohHardMsg e1 xs ys mid1 mid2
  | cohPairsPrelude mid1 mid2 = cohPreludeOverlapMsg (cohImplIfaceName e1) xs ys
  | cohIsCrossModule mid1 mid2 =
    cohCrossModuleMsg (cohImplIfaceName e1) mid1 mid2
  | otherwise = cohOverlapMsg (cohImplIfaceName e1) xs ys

-- the prelude's module id in `buildDeclEnvs`' module list.
cohPreludeMid : String
cohPreludeMid = "core"

-- Whether one impl of the pair is the prelude's.  The per-module sweep pairs a
-- module's own rows (first) with the prelude's (second), so the prelude's is [mid2].
cohPairsPrelude : String -> String -> Bool
cohPairsPrelude mid1 mid2 = mid1 == cohPreludeMid || mid2 == cohPreludeMid

cohIsCrossModule : String -> String -> Bool
cohIsCrossModule mid1 mid2 = mid1 /= "" && mid2 /= "" && mid1 /= mid2

-- SOFT wording (`W-INCOMPARABLE-IMPLS`).  Carries the "Warning: " prefix the
-- `matchWarnings` channel's text renderers expect and `stripWarnPrefix` removes for
-- the structured `--json` form.  ERROR-QUALITY: it states the rule that was violated
-- in the user's own vocabulary (these two heads, this interface), says the acceptance
-- consequence rather than asserting the program is wrong — because under (c) it may
-- not be — and puts the SPEC's remedy first.  It does not advise making the heads
-- disjoint or wrapping one type in a newtype: that is the wrong fix here (#614), and
-- adding the ranking impl changes nothing.
-- A pair with the prelude names the prelude's impl as such rather than by module id,
-- as `cohPreludeOverlapMsg` does: the program's own module id differs between verbs.
cohIncomparableMsg : String ->
  List Mono ->
  List Mono ->
  String ->
  String ->
  String
cohIncomparableMsg iface xs ys mid1 mid2 = match cohPpPair xs ys
  (s1, s2) =>
    if cohPairsPrelude mid1 mid2 then
      "Warning: overlapping impls of \{iface}: neither \{s1} nor the prelude's \{s2} is more specific than the other, so a goal matching both has no impl to pick"
    else
      "Warning: overlapping impls of \{iface}\{cohWhereSuffix mid1 mid2}: neither \{s1} nor \{s2} is more specific than the other, so a goal matching both has no impl to pick"

cohWhereSuffix : String -> String -> String
cohWhereSuffix mid1 mid2
  | cohIsCrossModule mid1 mid2 = " (defined in `\{mid2}` and `\{mid1}`)"
  | otherwise = ""

cohImplIface : CohImpl -> IfaceRef
cohImplIface (CohImpl i _ _ _) = i

-- #1559 A-3.7: the SPELLING, for the message renderers alone.  Every `coh*Msg`
-- below keeps its `String` parameter deliberately — the rendered wording is pinned
-- byte-for-byte by error goldens, and this unit moves no diagnostic text.  Reading
-- `.irName` through a named projection rather than at each call site keeps the
-- "identity decides, spelling only prints" split visible.
cohImplIfaceName : CohImpl -> String
cohImplIfaceName e = (cohImplIface e).irName

cohImplLoc : CohImpl -> Option Loc
cohImplLoc (CohImpl _ _ _ l) = l

-- push the SOFT (condition-(a)-only) coherence finding onto the typecheck WARNING
-- channel.  `matchWarnings`, NOT `recordTypeError` with severity 2 — see
-- `matchWarnings`' own note: `recordTypeError` arms `typeErrorsSticky` (aborts
-- build/run) and bumps `errorsDetected` (steers `erredDuring`-gated inference)
-- unconditionally, without reading severity, so a severity-2 push there keeps BOTH of
-- an error's side effects and still renders as severity 1.  A demotion has to change
-- channel, not just the number.
pushCoherenceWarning : ModuleCtx -> Option Loc -> String -> Unit
pushCoherenceWarning mctx loc msg =
  let warning =
    TcDiag
      "W-INCOMPARABLE-IMPLS"
      2
      (orElseLoc loc mctx.mcLoc)
      msg
      (Some cohIncomparableHelp)
      None
  mctx.mcCells.matchWarnings := warning :: mctx.mcCells.matchWarnings.value

-- run coherence over USER decls; push at most one HARD conflict into typeErrors and
-- at most one SOFT one onto the warning channel.  The impls are scanned in REVERSE
-- declaration order to mirror the oracle, whose env.impls is built by prepending each
-- entry (`entry :: !(env.impls)`) — so the conflict message names the later-declared
-- impl as the first head, byte-identical.
-- #1559 A-3.7: the input is `IE`'s rows for THIS module, not a decl list.
-- [cur] is the reading module's ordinal.  Its own rows are paired with each other and
-- with the prelude's rows (`cohPreludeRows`), never prelude with prelude.
--
-- The rows are exactly the module's own desugared decls' impls: `ieRowsOwnedBy
-- ordHere` returns the rows `implRowsOf` built from `demDecls` at that ordinal,
-- in decl order, with no transform between the driver's stamp and this scan.
export
checkCoherence : ModuleCtx -> ImplEnv -> Int -> Unit
checkCoherence mctx env cur =
  match (cohScan
    CohSweepOwn
    (reverse (map (cohImplOfRow mctx) (cohRowsOwnedBy cur env)))
    (map (cohImplOfRow mctx) (cohPreludeRows env)))
    CohScan hard soft =>
      cohPushHard mctx hard
      cohPushSoft mctx soft

cohPushHard : ModuleCtx -> Option (String, Option Loc) -> Unit
cohPushHard mctx None = ()
cohPushHard mctx (Some (msg, loc)) =
  pushTypeErrorAt mctx "T-CONFLICTING-IMPL" loc msg

cohPushSoft : ModuleCtx -> Option (String, Option Loc) -> Unit
cohPushSoft mctx None = ()
cohPushSoft mctx (Some (msg, loc)) = pushCoherenceWarning mctx loc msg

-- ── the superinterface rule for impl declarations (DICT-SEMANTICS §3 W-super) ──
-- Checks each impl in [userDecls] against every direct super of its interface; see
-- `checkImplSuperContexts`.  The supers come from `CE` at the reading ordinal [cur],
-- keyed by the impl's `implOrigin`.  Existence of a super impl is asked of every
-- `IE` row in the graph (`ieRowsVisibleAt` reads `ieCandidacyVisibleAt`, the
-- predicate instance candidacy reads), so a super impl declared in a later module
-- counts, as it does for dispatch; a row counts only when its own interface identity
-- is the super's `superOrigin`, never a same-spelled interface.
--
-- The row list is bound here, once: it is O(rows), and the existence test runs per
-- (impl x super).
export
checkSuperImpls : ModuleCtx -> List Decl -> ClassEnv -> ImplEnv -> Int -> Unit
checkSuperImpls mctx userDecls ce ie cur =
  let rows = ieRowsVisibleAt cur ie
  each (checkImplSuperContexts mctx userDecls ce cur rows) userDecls

-- DICT-SEMANTICS §3, the declaration rule for supers: a dictionary for `C ts` carries
-- one for each direct super `D` of `C` at the same arguments, built by the instance
-- `D ts` selects, so that instance's `requires` is part of what `C ts` owes.  The impl
-- must entail it from its own `requires` (with their supers), at its head with the
-- head variables rigid, or every binder that reduces `C ts` drops it.  A goal of the
-- selected instance's context is reduced through the instances as W3-inst's are; a
-- leaf that is no given is reported at the impl.  A super goal no given answers and
-- no impl row covers (`superRowExists`) is a missing super impl, reported at the impl
-- whether its head is concrete or parametric.  Direct supers suffice because every
-- impl is checked, the super's own impl included.
--
-- A parsed `impl` always records its interface token's span; a derived one records
-- none, so it is reported at the `data`/`newtype` declaration that produced it, and
-- its remedies are a `deriving` clause or a hand-written impl, since a `deriving`
-- clause takes no `requires`.
checkImplSuperContexts : ModuleCtx ->
  List Decl ->
  ClassEnv ->
  Int ->
  List ImplRow ->
  Decl ->
  Unit
checkImplSuperContexts mctx decls ce cur rows (DAttrib _ d) =
  checkImplSuperContexts mctx decls ce cur rows d
checkImplSuperContexts mctx decls ce cur rows (DImpl { iface, tys, reqs, implOrigin = o, implIfaceLoc = ifaceLoc, ... }) =
  let derived = isNone ifaceLoc
  let loc = if derived then derivedImplDeclLoc decls tys else ifaceLoc
  match ceLookupAt (regKeyOfTab (ifaceTabKey o iface)) cur ce
    Some r if listLen (ceRowTyparams r) == listLen tys =>
      let (implTvMap, headMonos) = implHeadMonos mctx tys
      let roots = implHeadTypeVarRoots implTvMap
      let headIds = omFromNames (map (p => intToString (snd p)) roots) omEmpty
      let declared = map (requirePredicateSlot mctx implTvMap) reqs
      let givens =
        declared
          ++ flatMap
            (s => map fst (predicateSlotKnownSupers mctx.mcGraph s))
            declared
      let subject = "impl \{iface} \{join " " (map ppTyAtom tys)}"
      let subst = zip (ceRowTyparams r) tys
      let argsOf =
        sup =>
          mapAll
            (p => lookupPos p (ceRowTyparams r) headMonos)
            (superParamsOf sup)
      fold
        (_ sup => match argsOf sup
          Some supArgs => checkSuperInstanceContext
            mctx
            subject
            roots
            headIds
            givens
            loc
            derived
            (superIfaceRef sup)
            supArgs
            (_ => superRowExists rows subst sup)
          None => ())
        ()
        (ceRowSupers r)
    _ => ()
checkImplSuperContexts mctx _ _ _ _ _ = ()

-- The span of the `data`/`newtype` declaration a derived impl's head names.
derivedImplDeclLoc : List Decl -> List Ty -> Option Loc
derivedImplDeclLoc decls tys = match flatMap tyConNamesInTy tys
  [n] => match flatMap (declNameLocs n) decls
    l :: _ => Some l
    [] => None
  _ => None

declNameLocs : String -> Decl -> List Loc
declNameLocs n (DAttrib _ d) = declNameLocs n d
declNameLocs n (DData { dataName, dataNameLoc = (Some l), ... })
  | dataName == n = [l]
declNameLocs n (DNewtype { newtypeName, newtypeNameLoc = (Some l), ... })
  | newtypeName == n = [l]
declNameLocs _ _ = []

checkSuperInstanceContext : ModuleCtx ->
  String ->
  List (String, Int) ->
  OrdMap Unit ->
  List PredicateSlot ->
  Option Loc ->
  Bool ->
  IfaceRef ->
  List Mono ->
  (Unit -> Bool) ->
  Unit
checkSuperInstanceContext mctx subject roots headIds givens loc derived sup supArgs covered
  | anyList (givenAnswers sup supArgs) givens = ()
  | otherwise =
    match rigidHeadInstanceContext (siteFor mctx) headIds sup supArgs
      None =>
        if not (covered ()) then
          reportMissingSuperImpl mctx subject roots loc derived sup supArgs
      Some ctx =>
        let walk = reqWalkStart ()
        let leaves =
          flatMap
            (g =>
              superContextLeaves mctx walk headIds givens loc (fst g) (snd g))
            ctx
        fold
          (_ leaf =>
            reportSuperContextLeaf
              mctx
              subject
              roots
              loc
              derived
              sup
              supArgs
              leaf)
          ()
          leaves

-- Whether some impl row of the super covers the super goal at the impl's head
-- (`superHeadCovers`).  Rows are graph-wide, so a super impl declared downstream
-- counts.
superRowExists : List ImplRow -> List (String, Ty) -> Super -> Bool
superRowExists rows subst (Super { superHead = n, superParams = ps, superOrigin = so }) =
  let tys = substParams ps subst
  listLen tys /= listLen ps || superImplExists rows (ifaceTabKey so n) n tys

-- The super is named by its spelling, as the checked impl's own interface is, so
-- the text is the same on every verb and at every head.  A derived impl's remedy is
-- the `deriving` clause when the super is derivable, else the hand-written impl.
reportMissingSuperImpl : ModuleCtx ->
  String ->
  List (String, Int) ->
  Option Loc ->
  Bool ->
  IfaceRef ->
  List Mono ->
  Unit
reportMissingSuperImpl mctx subject roots loc derived sup supArgs =
  let named = Ref (map (p => (snd p, fst p)) roots)
  let goal = "\{sup.irName} \{join " " (ppEach named (Ref 0) 3 supArgs)}"
  let missing = "requires the superinterface `\{goal}`, which no impl covers"
  pushTypeErrorOnceAt mctx "T-MISSING-SUPER-IMPL" loc (if not derived then
    "`\{subject}` \{missing}; add an `impl \{goal}` covering it, or add `requires \{goal}` to the impl"
  else if derivableIface sup.irName then
    "`\{subject}` (derived) \{missing}; add `\{sup.irName}` to the type's `deriving` clause, or add an `impl \{goal}`"
  else
    "`\{subject}` (derived) \{missing}; add an `impl \{goal}`")

-- The goals below [iface] [args] that no given answers: a goal over variables alone,
-- or one no instance selects with the head variables rigid.  Bounded by the shared
-- `requires` measure, a cycle or a runaway chain reported at [loc].  Each goal is
-- solved once per walk (`solvedOnWalk`); [headIds], [givens] and [loc] are fixed for
-- the walk `checkSuperInstanceContext` starts.
superContextLeaves : ModuleCtx ->
  ReqWalk ->
  OrdMap Unit ->
  List PredicateSlot ->
  Option Loc ->
  IfaceRef ->
  List Mono ->
  List (IfaceRef, List Mono)
superContextLeaves mctx walk headIds givens loc iface args
  | anyList (givenAnswers iface args) givens = []
  | not (anyConcreteHead args) = [(iface, args)]
  | otherwise = match reqWalkReported mctx loc (reqWalkEnter walk iface args)
    None => []
    Some next => solvedOnWalk
      mctx
      next
      iface
      args
      (_ => match rigidHeadInstanceContext (siteFor mctx) headIds iface args
        None => [(iface, args)]
        Some ctx =>
          flatMap
            (g =>
              superContextLeaves mctx next headIds givens loc (fst g) (snd g))
            ctx)

-- A leaf over head variables names the `requires` to add; a ground one names the
-- missing instance.  A leaf mentioning a variable the head does not bind has no
-- `requires` to name and is left to the goal's use.
reportSuperContextLeaf : ModuleCtx ->
  String ->
  List (String, Int) ->
  Option Loc ->
  Bool ->
  IfaceRef ->
  List Mono ->
  (IfaceRef, List Mono) ->
  Unit
reportSuperContextLeaf mctx subject roots loc derived sup supArgs (iface, args) =
  let ids = flatMap monoUnboundIds args
  let named = Ref (map (p => (snd p, fst p)) roots)
  let argsText = join " " (ppEach named (Ref 0) 3 args)
  let superGoal =
    "\{qualifiedIfaceLabel sup} \{join " " (ppEach named (Ref 0) 3 supArgs)}"
  let pred = "\{qualifiedIfaceLabel iface} \{argsText}"
  let predBare = "\{iface.irName} \{argsText}"
  if isEmptyL ids then
    pushTypeErrorOnceAt
      mctx
      "T-NO-IMPL"
      loc
      (superContextNoImplMsg subject derived superGoal pred predBare)
  else if allList (i => containsI i (map snd roots)) ids then
    pushTypeErrorOnceAt
      mctx
      "T-IMPL-MISSING-REQUIRES"
      loc
      (superContextUndeclaredMsg subject derived superGoal pred predBare)

-- ── P0-17: impl-completeness check ─────────────────────────────────────────
-- An `impl Iface Ty…` that defines only SOME of the interface's methods would
-- `check` clean, then PANIC at runtime
-- (`E-PANIC: unbound identifier: <method>`) when a missing method is dispatched —
-- a run≠check hole.  For each impl, verify every REQUIRED interface method (one
-- declared WITHOUT a default body) is defined by the impl body; each missing one
-- is a located `T-INCOMPLETE-IMPL` error, so check/run/build all reject instead of
-- deferring to a runtime panic.
--
-- Runs POST-desugar (from the typecheck cores), which is the ONLY stage where both
-- sets are cleanly visible with defaults distinguishable:
--   • desugar's mergeIfaceDefaults has coalesced each interface method's split
--     signature-entry (`lt : …`, default None) and body-entry (`lt x y = …`,
--     default Some) into ONE `IfaceMethod` carrying the merged Option MethodDefault.
--     PRE-merge the sig-only `None` entry would make every defaulted method (Ord's
--     lt/gt/…) look REQUIRED → hundreds of false positives across core/stdlib.
--   • an impl's defined set is exactly what it writes: a method it leaves to its
--     interface's default is a disposition row, not a clause, so the defined set
--     cannot mask a genuinely-missing required method.
-- The interface decl is resolved out of stage K's `CE` at the reading module's
-- ordinal (`ceRequiredAt`), so an IMPORTED interface resolves exactly as a local one
-- does; [iterDecls] (this module's own decls) are the impls to check.  Unknown
-- interface (not in scope) → skip (a distinct error is reported elsewhere), as
-- `checkImplSuperContexts` skips one.
--
-- One checker serves both driver modes.  It looks the interface up by the impl's own
-- `implOrigin`, never by a bare first-match scan over the decl list, so where a USER
-- interface shadows a prelude one by spelling, a user impl is checked against the
-- user interface's required set.
pushIncompleteImpl : ModuleCtx -> (Option Loc, String) -> Unit
pushIncompleteImpl mctx (loc, msg) =
  pushTypeErrorOnceAt mctx "T-INCOMPLETE-IMPL" loc msg

-- The span a missing-method error is attributed to: the first impl method's
-- body, read from its parsed AST whether or not the body was ever inferred.
-- `exprLoc` sees only an outermost `ELoc`/`EDoOrigin` wrapper, and a body shaped
-- `f x` (an application) has none, so `appArgLoc` gives its argument's span, a
-- location inside the impl block.  `None` for an impl with no method body or a
-- body neither form locates; the caller then reports at the impl's interface
-- name (`implIfaceLoc`).
firstImplMethodLoc : List ImplMethod -> Option Loc
firstImplMethodLoc [] = None
firstImplMethodLoc ((ImplMethod _ _ body) :: _) =
  orElseLoc (exprLoc body) (appArgLoc body)

-- The `Map` suffix is cited from compiler/frontend/resolve.mdk,
-- compiler/TYPECHECK-TARGET-ARCHITECTURE.md (§ "9.6 The subsumption enumeration —
-- derived by SHAPE, not by prefix", the `implCompletenessMsgsOf` row) and other
-- comments in this file; this is the one impl-completeness checker.
--
-- Required-ness is prePass-INVARIANT: `requiredMethodNames` reads only the presence
-- of `IfaceMethod`'s third position, and the prePass rewrite touches only a
-- `Some (…, e)` arm's body, so building `CE` from raw `demDecls` cannot change the
-- required-ness.
export
checkImplCompletenessMap : ModuleCtx -> ClassEnv -> Int -> List Decl -> Unit
checkImplCompletenessMap mctx ce cur iterDecls =
  each
    (pushIncompleteImpl mctx)
    (flatMap (implCompletenessMsgsOfMap ce cur) iterDecls)

-- OCCURRENCE MINT (#1110/#1111 A-2.4): `implOrigin` beside `iface` in the same
-- record pattern, so the identity and the name it qualifies cannot drift apart.
implCompletenessMsgsOfMap : ClassEnv -> Int -> Decl -> List (Option Loc, String)
implCompletenessMsgsOfMap ce cur (DAttrib _ d) =
  implCompletenessMsgsOfMap ce cur d
implCompletenessMsgsOfMap ce cur (DImpl { iface, tys, methods, implOrigin = o, implIfaceLoc = ifaceLoc, ... }) =
  match ceRequiredAt (regKeyOfTab (ifaceTabKey o iface)) cur ce
    None => []  -- unknown interface (reported elsewhere) → skip
    Some required =>
      let defined = map implMethodName methods
      -- An impl with no method body of its own is located at its interface name.
      let loc = orElseLoc (firstImplMethodLoc methods) ifaceLoc
      map
        (m => (loc, missingImplMethodMsg iface tys m))
        (filter (m => not (contains m defined)) required)
implCompletenessMsgsOfMap _ _ _ = []

-- #1557 A-3.5c: relocated onto stage K's `CE`.  The row set is
-- `ceRowsOwnedBy` — the READING module's OWN interfaces, which is exactly the
-- decl list this check was handed before (`prog` on the Module arm, the
-- driver-staged USER decls on Flat), NOT the visible prefix: an imported
-- interface's phantom method is reported once, at the module that declares it,
-- not once per importer.  See `ceRowsVisibleAt`/`ceRowsOwnedBy` for why the two
-- populations are kept apart.
--
-- `classEnvDeclFact` peels `DAttrib`, so an attributed interface reaches `CE` as a
-- row like any other.
export
checkPhantomMethods : ModuleCtx -> ClassEnv -> Int -> Unit
checkPhantomMethods mctx ce cur =
  each
    ((loc, msg) => pushTypeError (mctxAtIfSome loc mctx) "T-PHANTOM-METHOD" msg)
    (flatMap phantomMethodMsgs (ceRowsOwnedBy cur ce))

-- Each message with the span of the method's declared type it is about, or of
-- the interface's name when that type carries none (a default with no signature).
phantomMethodMsgs : CeRow -> List (Option Loc, String)
phantomMethodMsgs r =
  map
    (m => (orElseLoc (fst m) (ceRowLoc r), snd m))
    (flatMap
      (phantomMethodMsg (ceRowIfaceName r) (ceRowTyparams r))
      (ceRowMethods r))

phantomMethodMsg : String ->
  List String ->
  (String, Ty, List (String, List Kind)) ->
  List (Option Loc, String)
phantomMethodMsg ifaceName typarams (mname, mty, _) =
  if isEmptyL typarams then
    []
  else if anyMember (tyVarNames mty) typarams then
    []
  else
    let noun = if listLen typarams == 1 then "parameter" else "parameters"
    [
      (
        firstTyLoc mty,
        "method `\{mname}` of interface `\{ifaceName}` does not mention the interface \{noun} \{join ", " (map (t => "'" ++ backticked t ++ "'") typarams)}, so it cannot be dispatched",
      ),
    ]

-- map each super-param NAME through [subst] to its Ty, dropping any unmapped (so a
-- short result vs [params] signals an incomplete substitution → caller skips).
substParams : List String -> List (String, Ty) -> List Ty
substParams [] _ = []
substParams (p :: rest) subst = match lookupAssoc p subst
  Some t => t :: substParams rest subst
  None => substParams rest subst

-- does an `impl superName <head>` covering [goal] exist among [rows]?  [rows] are
-- `IE`'s rows, bound once by `checkSuperImpls`; [superKey] is the super's identity and
-- [superName] its bare spelling.
--
-- It compares the identity leg, never the buckets.  `ieInsertRow` indexes every row
-- under `oblIfaceKeys`, which mints two keys: the identity key and a bare-spelling
-- compatibility leg that #1438 still rides on.  Looking [superKey] up in
-- `ieConcrete`/`ieHeadless` would therefore answer with both same-spelled interfaces'
-- rows.  Reading `ieRows` and testing each row's own `IfaceRef` cannot reach the bare
-- bucket.
superImplExists : List ImplRow -> TabKey -> String -> List Ty -> Bool
superImplExists rows superKey superName goal =
  anyList (implRowMatchesSuper superKey superName goal) rows

-- Name first, then identity: `ifaceTabKey` allocates (it goes through `mkIdent`), and
-- this runs once per row per (impl x super) in a GC-bound stage.  Bare-name equality
-- is a necessary condition for key equality (`tabKeyOf` puts the same name into both
-- the `TkIdent` and the `TkBare` arm), so gating on it is sound; the identity compare
-- decides.
implRowMatchesSuper : TabKey -> String -> List Ty -> ImplRow -> Bool
implRowMatchesSuper superKey superName goal (ImplRow _ _ ir tys _ _ _) =
  ir.irName == superName
    && listLen tys == listLen goal
    && ifaceTabKey ir.irOrigin ir.irName == superKey
    && superHeadCovers tys goal

-- Whether the impl head [pats] covers the super goal [goal], which is the checked
-- impl's own head with its variables rigid: one substitution for the whole vector
-- (`matchOneSided`, as the min⊑ selector's `tySubsumesV` and the use site's
-- `implHeadSubst` match), so a variable [pats] repeats must bind equal types, and a
-- variable of [goal] matches only a variable of [pats].  `impl D (Pair a a)` does not
-- cover `D (Pair a b)` or `D (Pair Int Bool)`.  Effect rows are transparent on both
-- sides.  Type constructors compare by identity (`tyStep`), as at the use site.
superHeadCovers : List Ty -> List Ty -> Bool
superHeadCovers pats goal =
  isSome (matchOneSided superHeadStep (==) tyStructEq (zip pats goal) [])

superHeadStep : Ty -> Ty -> MStep String Ty Ty
superHeadStep pat t = tyStep pat (stripTyWrap t)

-- ── D3 / WS-2 part-2: GLOBAL (cross-module) coherence ──────────────────────
-- Per-module coherence accepts two DIFFERENT modules that
-- each define `impl C T` for the SAME instance — each module is locally coherent,
-- but jointly they are incoherent (silent dispatch ambiguity).  This pass scans
-- the joint impl set over ALL USER modules (the prelude is paired by the per-module
-- sweep, which reports with the impl's own span).
-- Each CohImpl carries the id of the module that PHYSICALLY declares it; imports do
-- NOT copy impl decls, so the joint set has exactly one entry per definition and a
-- structural (iface, head-tys) overlap already distinguishes distinct definitions —
-- no occurrence-dedup needed.  A conflict between two distinct modules is reported
-- naming BOTH (cohCrossModuleMsg via cohHardMsg's cross-module branch, or the
-- `(defined in …)` suffix `cohWhereSuffix` adds to the F-3d soft warning).
-- The joint impl set is `cohRowsOf` over the whole-graph `IE`, which leaves out the
-- prelude's rows, and the one-entry-per-definition property is `ieRows`' by
-- construction (imports copy no rows either).
--
-- the first cross-module coherence conflict of EACH CLASS (if any) as bare messages
-- — `(hard, soft)`, the same split `checkCoherence` reports, so the cross-module path
-- demotes the ⊑-incomparable class exactly as the per-module one does (F-3d).
-- Callers that thread errs as a VALUE (`checkModulesEntryFromDiags`) prepend these
-- themselves,
-- rather than relying on the typeErrors ref (cleared per-module by `freshModuleCtx`).
--
-- #414: this deliberately DROPS the blame-span `cohScan` returns.
-- Both consumers attach the diagnostic to the ENTRY module, but the span belongs to
-- whichever module declares the offending impl — and the `--json`/human renderers
-- key a diagnostic's file by the GROUP it is filed under, NOT by the filename
-- inside its own `Loc`.  Attaching a foreign span therefore renders a caret at that
-- line/col in the WRONG file.  Measured, with the impl 40 lines into a dependency:
--     ./main.mdk:42:7: Conflicting `impl C`. Defined in amod and bmod
-- — main.mdk is 5 lines long, so the caret block cannot even render.  That is worse
-- than the file-start default: a confidently wrong location beats an obviously
-- fabricated one only at misleading the reader.  The cross-module wording already
-- names BOTH owning modules, which is the locating information that actually helps
-- here.  Attaching a real span needs the renderers to honour `Loc`'s own filename
-- (a driver/diagnostics.mdk change, well beyond an S3 caret fix).
-- #1559 A-3.7: the input is the whole-graph `IE`, prelude carved out, not the driver's
-- per-module decl pairs.
--
-- Order is the thing this bite could move, because `cohScanInner` keeps the FIRST pair
-- per class over a `reverse`-ed list and the wording names `e1` first.  The two orders
-- agree, term by term: the old list was `flatMap (cohImplsOfMid mid) prog` over the
-- driver's `modules` in dependency-first order; `ieRows` is built by `buildImplEnvGo`
-- over the same modules in ORDINAL order (which is that same order, offset by the
-- prelude at 0) and within a module by `implDeclFacts = flatMap implDeclFact prog`, in
-- decl order.  The one difference is the prelude, which `cohRowsOf` removes
-- BEFORE the `reverse` below — so the filtered list's head is the first user module,
-- which is exactly what the old list's head was.
export
globalCoherenceConflict : ModuleCtx -> ImplEnv -> (Option String, Option String)
globalCoherenceConflict mctx env =
  match (cohScan
    CohSweepGlobal
    (reverse (map (cohImplOfRow mctx) (cohRowsOf env)))
    [])
    CohScan hard soft => (map fst hard, map fst soft)

-- True for a DImpl whose head types carry NO type variable (a monomorphic receiver like
-- `Eq Outer` / `Debug (List Int)`); False for a parametric head (`Eq (List a)`) and every
-- non-impl decl (which contributes no impl body regardless).
export
implHeadGround : Decl -> Bool
implHeadGround (DAttrib _ d) = implHeadGround d
implHeadGround (DImpl { tys, ... }) = isEmptyL (flatMap tyVarNames tys)
implHeadGround _ = False

-- True for a DImpl whose head types carry at least one type variable (a parametric
-- receiver like `Eq (List a)`); False for a ground head and every non-impl decl.  The
-- exact complement of implHeadGround over DImpl decls, so the two filters partition the
-- impls without double-inferring any (and both skip non-impl decls).
export
implHeadParametric : Decl -> Bool
implHeadParametric (DAttrib _ d) = implHeadParametric d
implHeadParametric (DImpl { tys, ... }) = isNonEmptyL (flatMap tyVarNames tys)
implHeadParametric _ = False

-- C8b: default-body type-checking runs UNCONDITIONALLY (checks
-- ALL default bodies regardless of whether they carry method-level constraints),
-- on every driver — a driver that skipped the unconstrained defaults
-- (Ord.lt/gt/min/max, Foldable.length/isEmpty, Filterable.filter, …) would
-- silently accept a bad default body.  The constrained branch still registers dict slots (needed
-- for the emit/dict path); the unconstrained branch only type-checks — safe on
-- the plain-check path (activeDictVars mutation is harmless; reset by `freshModuleCtx`).
export
inferDefaultBodies : TcEnv -> List Decl -> Unit
inferDefaultBodies env [] = ()
inferDefaultBodies env (d :: rest) =
  inferOneIfaceDefaults env d
  inferDefaultBodies env rest

inferOneIfaceDefaults : TcEnv -> Decl -> Unit
inferOneIfaceDefaults env (DAttrib _ d) = inferOneIfaceDefaults env d
-- Type each default body against the
-- interface's OWN method scheme (built from [typarams]+[methods]), NOT
-- `lookupVar env mname`.  On the flat single-file check path a user top-level
-- funDef can SHADOW a method name (e.g. map.mdk's `isEmpty : Map k v -> Bool`
-- shadowing Foldable's `isEmpty`); looking the name up in env would instantiate
-- that Map-typed shadow and infer the default `isEmpty t = match toList t`
-- against it, grounding the default body's container var to `Map` — so a default
-- every `Foldable` shares would be typed for ONE container.  The interface scheme is
-- shadow-free.  (Until #2769 gave `Map` a real `impl Foldable`, that grounding also
-- raised a spurious `No impl of Foldable for Map`; the mis-typing is the part that
-- does not depend on which impls happen to exist.)
-- Also extend env with these schemes so PEER-method refs in a default body
-- resolve to the interface methods (oracle's env_with_methods), not user shadows.
inferOneIfaceDefaults env (DInterface { name, typarams, typaramKinds, methods, ifaceOrigin, ... }) =
  -- #822: derived from THIS declaration, not from a name key (declGradedScope), and
  -- threaded down so the default bodies see the same Row slots the schemes were built
  -- with.  Computed ONCE per interface rather than per method.
  let dscope =
    declGradedScope env.teDyn.dcModule.mcGraph typarams typaramKinds methods
  let ifaceSchemes = methodSchemesPure env.teDyn.dcModule dscope methods
  let iface = IfaceRef { irName = name, irOrigin = ifaceOrigin }
  inferDefaultMethods
    (extendVars env ifaceSchemes)
    iface
    dscope
    typarams
    methods
inferOneIfaceDefaults env _ = ()

inferDefaultMethods : TcEnv ->
  IfaceRef ->
  List (String, List Kind) ->
  List String ->
  List IfaceMethod ->
  Unit
inferDefaultMethods env _ _ _ [] = ()
inferDefaultMethods env iface dscope typarams (m :: rest) =
  inferDefaultMethod env iface dscope typarams m
  inferDefaultMethods env iface dscope typarams rest

-- C8b: every interface default body is type-checked, constrained or not, by the
-- one method-body driver, against the interface's own signature for the method.
inferDefaultMethod : TcEnv ->
  IfaceRef ->
  List (String, List Kind) ->
  List String ->
  IfaceMethod ->
  Unit
inferDefaultMethod env iface dscope typarams (IfaceMethod mname mty (Some (MethodDefault pats body)) _) =
  inferMethodBody env iface DefaultBody (typarams, mty, dscope) mname pats body
inferDefaultMethod env _ _ _ _ = ()

-- The prerequisites of the instances [obls]' goals select, as goals of the same
-- boundary at their parents' sites (DICT-SEMANTICS §3).  An instance answers a goal
-- only once its `requires` is answered too, so a prerequisite left open is judged
-- like a goal the boundary posed itself.  It is not determined: an open sibling
-- refutes no candidate, so a commit through a prerequisite could choose a
-- structural instance whose open sibling no instance meets (`Num (MyList ?m)`).
-- A goal a given
-- answers whole selects no instance; a goal every variable of which is held rigid
-- leaves its prerequisites to the enclosing scope; a closed goal's are closed, and
-- the obligation gate's.  A goal whose verdict waits for quiescence, on a variable
-- of [liveIds], is walked there with it (`judgeQuiescentGoals`), after a later
-- group could ground that variable.  Each prerequisite continues its parent's walk
-- under the shared `requires` measure (`reqWalkEnter`), which bounds a chain that does
-- not shrink; a repeated or out-of-fuel prerequisite is reported at its site.
-- The goals come level by level, in the order the walk reaches them.  A goal one
-- seed's walk reaches again, at the same fuel, after following it cleanly is the same
-- goal with the same prerequisites, so it is kept and followed once (`wmFollowed`).
-- That pass reports nothing; when a step of it repeats a goal or runs out of fuel,
-- the goals come from a second pass that follows every path and reports each such
-- step, because the walk's path then decides what is reported.
export
nestedRequireGoals : ModuleCtx ->
  OrdMap Unit ->
  OrdMap Unit ->
  List UObligation ->
  List UObligation
nestedRequireGoals mctx rigidIds liveIds obls =
  let seeds = requireGoalSeeds mctx.mcGraph obls
  let goals =
    nestedRequireGoalsOnce
      mctx
      rigidIds
      liveIds
      (flatMap (followRequireGoal mctx rigidIds liveIds) seeds)
  if anyList (s => (reqWalkMemo (snd s)).wmStopped.value) seeds then
    nestedRequireGoalsGo
      mctx
      rigidIds
      liveIds
      (requireGoalSeeds mctx.mcGraph obls)
  else
    goals

-- Each goal of [obls] as the seed of its own walk.
requireGoalSeeds : GraphCtx -> List UObligation -> List (UObligation, ReqWalk)
requireGoalSeeds gctx obls =
  map
    (o => (o, reqWalkSeed o.pred.iface (map normalize (uOblArgs gctx o))))
    obls

nestedRequireGoalsGo : ModuleCtx ->
  OrdMap Unit ->
  OrdMap Unit ->
  List (UObligation, ReqWalk) ->
  List UObligation
nestedRequireGoalsGo mctx rigidIds liveIds walks =
  match flatMap (selectedRequireGoals mctx rigidIds liveIds) walks
    [] => []
    derived =>
      map fst derived ++ nestedRequireGoalsGo mctx rigidIds liveIds derived

-- The goals from level [walks] down, each goal its walk has already followed left out.
nestedRequireGoalsOnce : ModuleCtx ->
  OrdMap Unit ->
  OrdMap Unit ->
  List (UObligation, ReqWalk) ->
  List UObligation
nestedRequireGoalsOnce mctx _ _ [] = []
nestedRequireGoalsOnce mctx rigidIds liveIds walks =
  let (kept, derived) = followRequireLevel mctx rigidIds liveIds walks [] []
  kept ++ nestedRequireGoalsOnce mctx rigidIds liveIds derived

-- One level, in order: a goal its walk has already followed is left out,
-- each other is kept and followed, and the goals it selects form the next level.
followRequireLevel : ModuleCtx ->
  OrdMap Unit ->
  OrdMap Unit ->
  List (UObligation, ReqWalk) ->
  List UObligation ->
  List (List (UObligation, ReqWalk)) ->
  (List UObligation, List (UObligation, ReqWalk))
followRequireLevel mctx _ _ [] kept derived =
  (reverse kept, flatMap identity (reverse derived))
followRequireLevel mctx rigidIds liveIds ((o, walk) :: rest) kept derived =
  if walkGoalFollowed walk o.pred.iface (uOblGoalArgs mctx.mcGraph o) then
    followRequireLevel mctx rigidIds liveIds rest kept derived
  else
    let below = followRequireGoal mctx rigidIds liveIds (o, walk)
    followRequireLevel mctx rigidIds liveIds rest (o :: kept) (below :: derived)

-- [o]'s prerequisites on the pass that reports nothing; [o] is recorded as followed
-- when selecting them detected no error and minted none of their variables
-- (`solvedCleanly`).
followRequireGoal : ModuleCtx ->
  OrdMap Unit ->
  OrdMap Unit ->
  (UObligation, ReqWalk) ->
  List (UObligation, ReqWalk)
followRequireGoal mctx rigidIds liveIds (o, walk) =
  let (clean, below) =
    solvedCleanly
      mctx
      (goals => flatMap (g => uOblArgs mctx.mcGraph (fst g)) goals)
      (_ => requireGoalsBelow mctx prerequisiteUnreported rigidIds liveIds (
        o,
        walk,
      ))
  if clean then
    noteWalkGoalFollowed walk o.pred.iface (uOblGoalArgs mctx.mcGraph o)
  below

uOblGoalArgs : GraphCtx -> UObligation -> List Mono
uOblGoalArgs gctx o = map normalize (uOblArgs gctx o)

-- [o]'s prerequisites under the one instance its goal selects as it stands, each
-- with the walk that reaches it from [o]'s.
selectedRequireGoals : ModuleCtx ->
  OrdMap Unit ->
  OrdMap Unit ->
  (UObligation, ReqWalk) ->
  List (UObligation, ReqWalk)
selectedRequireGoals mctx rigidIds liveIds walk =
  requireGoalsBelow mctx (prerequisiteOnWalk mctx) rigidIds liveIds walk

-- A prerequisite entered on its parent's walk without a report: a repeated or
-- out-of-fuel one stops the walk (`wmStopped`), which `nestedRequireGoals` then runs
-- again with `prerequisiteOnWalk`.
prerequisiteUnreported : ReqWalk -> UObligation -> List (UObligation, ReqWalk)
prerequisiteUnreported walk g =
  match reqWalkEnter walk g.pred.iface (map normalize g.pred.args)
    ReqOn next => [(g, next)]
    _ =>
      let memo = reqWalkMemo walk
      memo.wmStopped := True
      []

-- infer each impl-with-`requires`' return-position method bodies; the interface
-- method declarations come from the identity-keyed ClassEnv row at [cur].
-- Each impl is inferred at the span `locatedImpls` paired it with.
export
inferImplBodies : TcEnv ->
  List String ->
  ClassEnv ->
  Int ->
  List (Option Loc, Decl) ->
  Unit
inferImplBodies env _ _ _ [] = ()
inferImplBodies env rpNames ce cur ((loc, d) :: rest) =
  inferOneImpl (envAtIfSome loc env) rpNames ce cur d
  inferImplBodies env rpNames ce cur rest

-- `Some` for an impl, holding its interface name's span.
export
implDeclLoc : Decl -> Option (Option Loc)
implDeclLoc (DAttrib _ d) = implDeclLoc d
implDeclLoc (DImpl { implIfaceLoc, ... }) = Some implIfaceLoc
implDeclLoc _ = None

inferOneImpl : TcEnv -> List String -> ClassEnv -> Int -> Decl -> Unit
inferOneImpl env rpNames ce cur (DAttrib _ d) =
  inferOneImpl env rpNames ce cur d
-- [implOrigin] is bound here, not dropped by the `...`: the impl-body signature
-- lookup takes the interface's IDENTITY, not its bare spelling, so two modules each
-- declaring an interface spelled `Speak` cannot attribute one module's impl body
-- to the other's declared method type.  DICT-SEMANTICS §8 I4: an interface is a
-- (module, name) pair.  Same construction as `implDeclFact`, from the same two fields.
inferOneImpl env rpNames ce cur (DImpl { iface, tys, reqs, methods, implOrigin, ... }) =
  let iref = IfaceRef { irName = iface, irOrigin = implOrigin }
  match reqs
    [] => inferPlainImpl env ce cur iref tys methods
    _ => inferRequiresImpl env rpNames ce cur iref tys reqs methods
inferOneImpl env _ _ _ _ = ()

-- D3a: a NON-`requires` impl body, inferred on every path (single elaboration mode)
-- so its ARG-position method occurrences (e.g. `display` of a String field inside a
-- `Display`/`Debug` impl — the 19 `display@String` sites) reach inferMethodAt and
-- get stamped.  Mirrors inferRequiresImpl's head-mono substitution but with no
-- requires to register (an unconstrained impl threads no element dict).
inferPlainImpl : TcEnv ->
  ClassEnv ->
  Int ->
  IfaceRef ->
  List Ty ->
  List ImplMethod ->
  Unit
inferPlainImpl env ce cur iface tys methods =
  let (implTvMap, headMonos) = implHeadMonos env.teDyn.dcModule tys
  inferImplMethods
    env
    ce
    cur
    iface
    implTvMap
    headMonos
    []
    (scopeImplMethods
      env.teDyn.dcModule
      (captureScope env.teDyn.dcModule ())
      methods)

-- one impl `impl Iface (List a) requires Iface a where …`: build ONE tyvar map
-- shared between the head (`List a`) and the requires (`Iface a`) so the body's
-- inner method ref unifies its discriminating var to the head's `a`; infer each
-- method body against the method type instantiated at the head; THEN register the
-- requires' post-unification ids in activeDictVars keyed to `$dict_<method>_<slot>`.
inferRequiresImpl : TcEnv ->
  List String ->
  ClassEnv ->
  Int ->
  IfaceRef ->
  List Ty ->
  List Require ->
  List ImplMethod ->
  Unit
inferRequiresImpl env rpNames ce cur iface tys reqs methods =
  let (implTvMap, headMonos) = implHeadMonos env.teDyn.dcModule tys
  let scopedMethods =
    scopeImplMethods
      env.teDyn.dcModule
      (captureScope env.teDyn.dcModule ())
      methods
  inferImplMethods env ce cur iface implTvMap headMonos reqs scopedMethods
  registerImplRequires
    env.teDyn.dcModule
    ce
    cur
    iface
    implTvMap
    rpNames
    reqs
    scopedMethods

scopeImplMethods : ModuleCtx ->
  ScopeId ->
  List ImplMethod ->
  List ScopedImplMethod
scopeImplMethods mctx _ [] = []
scopeImplMethods mctx parent (method :: rest) =
  let name = implMethodName method
  let scope =
    Scopes.freshScope
      (currentScopeStore mctx.mcGraph ())
      (Some parent)
      mctx.mcCells.currentLevel.value
      (Scopes.scopeFrame (currentScopeStore mctx.mcGraph ()) parent).sfModuleId
      (BindingOwner name)
  ScopedImplMethod { simMethod = method, simScope = scope }
    :: scopeImplMethods mctx parent rest

inferImplMethods : TcEnv ->
  ClassEnv ->
  Int ->
  IfaceRef ->
  List (String, Mono) ->
  List Mono ->
  List Require ->
  List ScopedImplMethod ->
  Unit
inferImplMethods env _ _ _ _ _ _ [] = ()
inferImplMethods env ce cur iface implTvMap headMonos reqs (m :: rest) =
  inferImplMethod env ce cur iface implTvMap headMonos reqs m
  inferImplMethods env ce cur iface implTvMap headMonos reqs rest

inferImplMethod : TcEnv ->
  ClassEnv ->
  Int ->
  IfaceRef ->
  List (String, Mono) ->
  List Mono ->
  List Require ->
  ScopedImplMethod ->
  Unit
inferImplMethod env ce cur iface implTvMap headMonos reqs scoped =
  match scoped.simMethod
    ImplMethod mname pats body => match ceMethodTyAt iface mname cur ce
      None => ()
      Some sig =>
        inferMethodBody
          env
          iface
          (ImplBody ImplBodySite {
            ibImplTvMap = implTvMap,
            ibHeadMonos = headMonos,
            ibRequires = reqs,
            ibScope = scoped.simScope,
          })
          sig
          mname
          pats
          body

-- The one method-body judgment: an impl method body, or an interface default
-- body, checked against the method's declared signature [sig] (the interface
-- params, the method type, and the graded scope the method's own scheme was built
-- under).  Both kinds instantiate the signature, infer the body against it under
-- one effect contract, query the launder trail, check W3 rigidity, run the
-- body-local numeric boundary and publish the method-level givens.  Each step at
-- which the kinds differ reads [kind] explicitly, and no flag governs two
-- unrelated steps.  In order:
--   * scope and currentFn: `openMethodBodyScope`; an impl body also sets
--     currentImplBody and resets currentFn to "" afterwards, where a default body
--     restores the caller's.
--   * instantiation: `instantiateMethodBody`.  A default body's rigidity reads the
--     same instantiation as its body and forcing row; a second signature would
--     disconnect force-only variables from the body being checked (guard fixture:
--     test/run_check_agreement_fixtures/reject_offspine_closed_row_launder_crossmodule.mdk).
--   * cascade suppression: `gatesBodyCascade`, default bodies only.
--   * where the forcing row is checked and the effect contract closes, and the
--     launder message: `checkMethodBodyAgainst`.
--   * effect-variable rigidity: one call, `checkMethodEffVarRigidity`.  An impl body
--     runs it after the type-variable half, with the launder query's verdict and its
--     index-only variables; a default body runs it before, with False and [], and
--     skips it when the body erred.  The two halves' diagnostics print in the order
--     they are pushed.
--   * the numeric channel: an impl body intersects the head and declared-dictionary
--     roots and checks its head's numeric prerequisites; a default body's surviving
--     roots are its declared type's.
--   * givens: `registerMethodBodyGivens`.
inferMethodBody : TcEnv ->
  IfaceRef ->
  MethodBodyKind ->
  (List String, Ty, List (String, List Kind)) ->
  String ->
  List Pat ->
  Expr ->
  Unit
inferMethodBody outer iface kind (params, mty, gscope) mname pats body =
  -- The body's own checks (its rigidity, its effect contract) are located at
  -- the body; its type meets the signature at the value it returns.
  let env = envAtIfSome (exprSpanLoc body) outer
  enterLevel env.teDyn.dcModule ()
  let bodyLevel = env.teDyn.dcModule.mcCells.currentLevel.value
  let bodyScope = openMethodBodyScope env.teDyn.dcModule iface mname kind
  let savedCurrentFn = env.teDyn.dcModule.mcCells.currentFn.value
  -- currentFn = the method name (NOT "") so arg-/return-position sites in THIS
  -- body record `encl = mname`.  registerImplRequires keys every method of an impl
  -- under the SAME impl tyvar id (`impl Ord (List a)` registers `a` once per
  -- compare/lt/min/max/…), so the global first-match route resolution returns the
  -- LAST-registered method's `$dict_<m>_<slot>` for ALL bodies — corrupting e.g.
  -- compare's element dispatch to `$dict_max_0` (unbound in compare's scope).  With
  -- encl = mname, activeDictVarOfEncl/argImplDictRoutesForEncl prefer THIS method's
  -- own `$dict_<mname>_<slot>`.  Pre-specialization each Ord impl defined only
  -- compare so there was no collision; universal default specialization exposes it.
  env.teDyn.dcModule.mcCells.currentFn := mname
  match kind
    ImplBody _ => env.teDyn.dcModule.mcCells.currentImplBody := True
    DefaultBody => ()
  -- #518: window this body's newly-added obligations, exactly as processLetGroup /
  -- `checkBodyImpl` does for a let-group, so the Num defaulting below is scoped to
  -- THIS method and can never touch an already-generalized outer var.
  let oblN0 = wMark env.teDyn.dcModule.mcCells.implObls
  let callN0 = wMark env.teDyn.dcModule.mcCells.obls
  let dictN0 = goalsMark env.teDyn.dcModule.mcGraph ()
  let inst = instantiateMethodBody env.teDyn.dcModule kind params mty gscope
  let headBefore = match kind
    ImplBody site => implHeadVarRoots site.ibImplTvMap
    DefaultBody => []
  registerMethodBodyGrants
    env.teDyn.dcModule.mcGraph
    iface
    mname
    (methodBodyHeadMonos kind)
    inst
    bodyScope
  recordClauseFileBound env.teDyn.dcModule body (listLen pats) inst.mbiExpected
  let loc = orElseLoc (implBodyLoc body) (firstTyLoc mty)
  let subject = methodBodySubject kind iface.irName mname
  -- #821: the method's effect variables are RIGID for the body — two of them
  -- meeting in an ambient row join rather than being identified.
  let contract =
    beginEffectContract
      env.teDyn.dcModule
      inst.mbiContractForce
      inst.mbiExpected
  -- issue 1146: "did the body DETECT an error" is a CONTROL judgment, so it is read
  -- off the occurrence counter, not off `listLen typeErrors`.  The region is the
  -- whole body check, which also pushes T-EFFECT-LAUNDER and contains its own gated
  -- unify, so no unify-level failure signal could answer it.
  let (bodyErred, check) = erredDuring env.teDyn.dcModule (_ =>
    checkMethodBodyAgainst
      env
      iface
      kind
      mname
      mty
      gscope
      inst
      contract
      loc
      pats
      body)
  let headMonos = methodBodyHeadMonos kind
  -- The launder query's verdict silences the atom half of an impl body's
  -- effect-variable check (same defect, one report).  A default body passes False,
  -- so a default body that launders can be reported by both.
  let launderFlagged = match kind
    ImplBody _ => check.mbcLaunderFlagged
    DefaultBody => False
  let effVarRigidity =
    _ =>
      checkMethodEffVarRigidity
        env.teDyn.dcModule
        subject
        headMonos
        gscope
        mty
        inst.mbiEffVars
        launderFlagged
        check.mbcEagerIndexed
        (orElseLoc loc check.mbcPerformedAt)
  -- Cascade gate S1 (ERROR-QUALITY.md §6): a default body that detected an error
  -- skips its effect-variable check.
  match kind
    DefaultBody => if bodyErred then () else effVarRigidity ()
    ImplBody _ => ()
  -- #814 (S0): W3 method-scheme fidelity (DICT-SEMANTICS §3).  The method's
  -- non-head quantified variables — type AND effect — belong to the CALLER
  -- (every use site re-instantiates them freshly), so the body must be checked
  -- at full generality.  [mbiSurvivors]/[mbiEffVars] were fresh flexible vars for
  -- the unify; verifying they SURVIVED unification as distinct unbound
  -- variables (types) / atom-free rows with distinct tails (effects) is
  -- equivalent to having checked the body against skolems, at the cost of one
  -- post-unify inspection (the same discipline as checkAnnotTooGeneral's C3).
  -- Without it a body can pin `b` in `mk : a -> b` — to Int (caller
  -- instantiates b := String, evaluation crashes) or to an effect-bearing
  -- arrow, alone or nested in a tuple/data arg (caller pins b to the pure
  -- arrow: a certified-pure value performs IO — the #814 laundering vein the
  -- per-arrow #803 walk is structurally blind to).  Runs BEFORE body-local
  -- defaulting so a Num default can never mask a pin.
  -- [addedObls] (this body's obligation window, also fed to the numeric boundary
  -- below) carries the CONSTRAINT axis: a body whose pin is a *constrained
  -- var* rather than a constructed type (`mk d = 42` pins b to a Num-obligated
  -- var, still a TVar) escapes the distinctness check, but its obligation on a
  -- caller-owned var is the same lie — gen-sig's `Q_sig ⊩ P'` on the impl side.
  let addedObls = wWindow env.teDyn.dcModule.mcCells.implObls oblN0
  -- ALSO the CALL-obligation window: a predicate reaching a scheme var through
  -- a constrained HELPER call (`hh : Num x => x -> x`; body `meth d x = hh x`)
  -- is recorded by recordCallObligations, never by recordImplObligation — the
  -- adversarial review's break 2: without this window the Num rides a channel
  -- the survivor check never read, and `check` stayed green on a program whose
  -- built binary printed garbage.
  let addedCallObls = callOblsWindow env.teDyn.dcModule callN0
  -- The settle sequence at the method-body boundary (DICT-SEMANTICS §3).  The body
  -- owns neither the instance head's variables nor its declared signature's: a
  -- construction site instantiates both, so both are held rigid, and every other
  -- variable of a goal is the body's.  An impl body's head monos and method type
  -- carry them; a default body has no head, and its method type carries the
  -- receiver's variables too.  It runs before the rigidity and head-prerequisite
  -- checks so that a predicate determination moves onto a head variable is read
  -- by them, and before the surviving roots are snapshotted.
  let bodyRigidIds =
    monoRootIdSet (headMonos ++ [inst.mbiExpected] ++ map snd inst.mbiNamedVars)
  let bodyObls = addedObls ++ callUOblsWindow env.teDyn.dcModule callN0
  improveByUniqueImpl env.teDyn bodyRigidIds bodyObls
  determineByUniqueInstance env.teDyn.dcModule bodyRigidIds bodyObls
  checkMethodRigidityCore
    env.teDyn.dcModule
    subject
    iface.irName
    mty
    headMonos
    inst.mbiSurvivors
    (methodBodyOwnTyparams kind params)
    addedObls
    addedCallObls
    loc
  match kind
    ImplBody site =>
      checkImplHeadRigidity
        env.teDyn.dcModule
        subject
        iface.irName
        site
        headBefore
        (orElseLoc (firstExprLoc body) loc)
    DefaultBody => ()
  match kind
    ImplBody _ => effVarRigidity ()
    DefaultBody => ()
  -- The rigidity read above can normalize/alias union-find roots. Snapshot
  -- channels only afterward so this set and every obligation use the same
  -- final root identities.
  let survivingNumIds = match kind
    ImplBody site =>
      numChannelRootSet
        addedObls
        (site.ibHeadMonos
          ++ methodLevelConstraintMonos params mty inst.mbiNamedVars)
    DefaultBody => monoRootIdSet [inst.mbiExpected]
  match kind
    ImplBody site =>
      checkImplHeadNumObligations
        env.teDyn.dcModule
        subject
        site.ibImplTvMap
        site.ibRequires
        survivingNumIds
        addedObls
    DefaultBody => ()
  match kind
    ImplBody site =>
      checkImplHeadPrerequisites
        env.teDyn.dcModule
        subject
        iface
        site
        inst.mbiNamedVars
        mty
        addedObls
        addedCallObls
    DefaultBody => ()
  exitLevel env.teDyn.dcModule ()
  -- #518 (S0, silent wrongness): PLAN.md #11 Num defaulting NEVER RAN over a method
  -- body — this path is not a let-group, so nothing grounded its ambiguous
  -- Num vars.  A literal consumed entirely inside the body (`t _ = s [1, 2]`) left
  -- its element var UNBOUND, so the receiver the route resolver saw was `List _a`,
  -- not `List Int` — and `List _a` matches only the GENERAL `impl S (List a)`, never
  -- the specific `impl S (List Int)`.  The min⊑ selector was never at fault: with one
  -- match there is nothing to select between.  It resolved to the general impl and
  -- routed its `requires S a` to RNone (a null dict) — hence `build` silently printing
  -- the general instance's answer and `run` panicking E-NOT-A-FUNCTION.
  -- The same expression at TOP LEVEL was always correct precisely because
  -- group defaulting grounded the var to Int first.  #873: a default body is inferred
  -- once and every inheriting instance reuses its routes, so it grounds here too, or
  -- module placement would decide which impl a body-local literal dispatches to.
  --
  -- MUST run AFTER the body's unify, when root identities are final. The
  -- surviving set is the intersection of this body's Num roots with head roots and
  -- declared method-dictionary roots. A return-position method variable (`lift :
  -- Num b => a -> Box b`) survives through the latter; `b` in `impl Mk (Acc b)`
  -- survives through the former and the rigidity owner above requires its impl-level
  -- prerequisite. An unrelated body-local root remains outside both and grounds.
  -- Group defaulting is still the wrong policy here: its arg-position-only filter
  -- measurably traded #518's S0 for a new one.
  --
  -- The just-exited method-body level owns both body-local defaulting and the
  -- ambiguity registration that follows it. Roots carried by the impl head or
  -- declared method dictionaries survive through [survivingNumIds]/[mbiExpected];
  -- deeper generalized locals remain outside this boundary by level.  A variable a
  -- multi-parameter goal ties to the head (`e` of `Index (Array a) k e`) is not in
  -- that set: D3 clause 3 withholds it when grounding it would leave the goal no
  -- instance, and the second determination below settles it.
  let withheld = finalizeNumBoundary
    env.teDyn
    NumBoundary {
      nbDisposition = NumBoundaryOwnedMethodBody bodyLevel,
      nbMembers = [inst.mbiExpected],
      nbSurvivingIds = survivingNumIds,
      nbDefaultObls =
        addedObls ++ calleeNumObls env.teDyn.dcModule callN0 dictN0,
      nbAmbiguityObls = addedObls,
      nbGuard = NumGuard {
        ngGoals = bodyObls,
        ngRigidIds = bodyRigidIds,
        ngOuterBelow = None,
      },
    }
  -- Defaulting is a substitution like any other, so the goals it changed are
  -- improved and determined once more.
  improveByUniqueImpl env.teDyn bodyRigidIds bodyObls
  determineByUniqueInstance env.teDyn.dcModule bodyRigidIds bodyObls
  -- The method signature's own variables are held at the body's close as a
  -- top-level signature's are at its group's.  A goal that fixes a head variable is
  -- W3-inst's (`checkImplHeadPrerequisites`), so only these are held.  The method's
  -- own `=>` context is given in the body's scope, with its supers, before they are
  -- (`publishMethodPredGivens`), so the check reads it through `goalGivenAt`.  They
  -- do not join `declaredSigVarIds`: the module-end verdict on a default body's
  -- open goal reads the instances its receiver variables reach
  -- (`test/dict_fixtures/undetermined-method-goal-default-body.mdk`).
  let methodSig = [(mname, mty, inst.mbiSurvivors)]
  let methodVarIds = sccProtectedSignatureIds methodSig
  publishMethodPredGivens env.teDyn.dcModule params mty inst bodyScope
  checkSigVarGoals
    env.teDyn.dcModule
    DeclaredBySignature
    methodVarIds
    methodSig
    bodyObls
  rejectUndeterminedVectors
    env.teDyn.dcModule
    bodyRigidIds
    omEmpty
    addedObls
    (callUOblsWindow env.teDyn.dcModule callN0
      ++ nestedRequireGoals env.teDyn.dcModule bodyRigidIds omEmpty bodyObls)
  rejectWithheldAmbiguity env.teDyn.dcModule bodyRigidIds withheld bodyObls
  registerMethodBodyGivens
    env.teDyn.dcModule.mcGraph
    iface
    kind
    params
    mty
    inst
    bodyScope
  match kind
    ImplBody _ => env.teDyn.dcModule.mcCells.currentImplBody := False
    DefaultBody => ()
  let restoredFn = match kind
    ImplBody _ => ""
    DefaultBody => savedCurrentFn
  env.teDyn.dcModule.mcCells.currentFn := restoredFn
  closeScope env.teDyn.dcModule ()

-- An impl body's scope was minted beside its siblings' before any body ran; a
-- default body mints its own, owned by its (interface, method) identity, at the
-- level just entered.
openMethodBodyScope : ModuleCtx ->
  IfaceRef ->
  String ->
  MethodBodyKind ->
  ScopeId
openMethodBodyScope mctx _ _ (ImplBody site) =
  openScope mctx site.ibScope
  site.ibScope
openMethodBodyScope mctx iface mname DefaultBody =
  let parentScope = captureScope mctx ()
  let owner = DefaultBodyIdentity { dbiIface = iface, dbiMethod = mname }
  let bodyScope =
    Scopes.freshScope
      (currentScopeStore mctx.mcGraph ())
      (Some parentScope)
      mctx.mcCells.currentLevel.value
      (Scopes.scopeFrame
        (currentScopeStore mctx.mcGraph ())
        parentScope).sfModuleId
      (DefaultBodyOwner owner)
  openScope mctx bodyScope
  bodyScope

-- Instantiate the declared method type for one body.
instantiateMethodBody : ModuleCtx ->
  MethodBodyKind ->
  List String ->
  Ty ->
  List (String, List Kind) ->
  MethodBodyInstance
-- An impl body: the interface params are the head monos, every other signature
-- variable is fresh.  The tv map is built explicitly (instead of
-- expectedMethodType, which hides it) so the method's OWN method-level constraint
-- vars (`Thenable m => …`) can be registered after the body.
instantiateMethodBody mctx (ImplBody site) ifaceParams mty gscope =
  let baseMap = zip ifaceParams site.ibHeadMonos
  -- #822: subtract rowArgNames too — the same split sigToSchemeTvs and
  -- astTypeFreshTbl already make.  A name sitting in a KRow type-app slot (`f e a`
  -- under a graded interface) is an EFFECT variable: it belongs to [effMap] below,
  -- and minting a TYPE var for it as well puts an entry in [extraMap] that
  -- [expected] never mentions.  Without the subtraction the graded fixtures still
  -- check, run and build identically, because the stray entry survives unification
  -- as an unbound, distinct var and so passes checkMethodRigidityCore's
  -- pinned/dup/head-disjointness tests vacuously; a survivor set containing a
  -- variable the method type does not mention would still be a false positive for
  -- the first rule that quantifies over all survivors.
  let extraMap =
    freshTvMap
      mctx
      (removeAllS
        ifaceParams
        (removeAllS (rowArgNamesIn mctx gscope mty) (dedup (tyVarNames mty))))
  -- #782/#784: build the method type's effect table the way sigToSchemeTvs does,
  -- so a free return-position effect var (`speak : a -> <e> String`) becomes a
  -- FRESH OPEN effvar that the impl body's actual effect instantiates (effect
  -- polymorphism: `Speak Dog`'s <Stdout> body sets e := <Stdout>), rather than
  -- collapsing to a CLOSED empty `<>` (fromAstType's empty etbl) and firing a
  -- spurious T-EFFECT-LEAK against a bound the method never declared.  A CONCRETE
  -- (`<Stdout>`) or PURE (`<>`) declared row still yields a closed row, so a genuine
  -- impl-body effect leak past a non-var bound is still enforced (#782).
  let effMap =
    sigVarsFor
      mctx
      mty
      (dedup (effTailNames mty ++ rowArgNamesIn mctx gscope mty))
  let mtvs = baseMap ++ extraMap
  let expected = fromAstTypeE mctx effMap mtvs mty
  let contractForce = bindingForceFromAst mctx effMap mtvs mty
  MethodBodyInstance {
    mbiExpected = expected,
    mbiContractForce = contractForce,
    mbiCheckedForce = _ => bindingForceFromAst mctx effMap mtvs mty,
    mbiEffVars = effMap.svRows,
    mbiSurvivors = extraMap,
    mbiNamedVars = mtvs,
    mbiDictSlots = [],
    mbiTypeSubst = [],
  }
-- A default body: the interface's own scheme for the method, instantiated once.
-- #822: [dscope] is the declaration-derived graded scope the method's scheme was
-- built under (inferOneIfaceDefaults → methodSchemesPure), so a default body of a
-- graded method sees its Row slots as rows, not as tyvars.
-- The constraint slot ids AND the instantiation MUST come from the SAME
-- sigToSchemeTvs build of this method's type.  Reading the ids from
-- methodPredicateSlotsRef (filled by a separate method-row build with its own
-- fresh tyvar ids) and instantiating an unrelated methodSchemesPure scheme gave ids
-- that did not appear in the instantiation subst → registerOneMethodDict's
-- `lookupAssocI id subst` returned None → activeDictVars got no entry → the in-body
-- `empty`/`++` routed RNone → eval's `++` saw a non-monoid acc and panicked
-- ('++' requires Semigroup).
-- The effect variables are read off the same substitution: sigToSchemeTvsIn
-- allocates its quantified rows in this name order, and the instantiation
-- preserves that order.
instantiateMethodBody mctx DefaultBody typarams mty dscope =
  let st = sigToSchemeTvsIn mctx dscope mty
  let descriptor = instantiateMethodTracked mctx (fst st)
  let subst = descriptor.mtiSubstitution.misTypeSubst
  MethodBodyInstance {
    mbiExpected = descriptor.mtiBody,
    mbiContractForce = descriptor.mtiForce,
    mbiCheckedForce = _ => effrowNorm descriptor.mtiForce,
    mbiEffVars =
      zip
        (dedup (effTailNames mty ++ rowArgNamesIn mctx dscope mty))
        (map snd descriptor.mtiSubstitution.misEffectSubst),
    mbiSurvivors = defaultSurvivorMap (snd st) subst,
    mbiNamedVars = instantiateNamedMonos mctx.mcGraph (snd st) subst,
    mbiDictSlots = methodConstraintSlotIds typarams mty (snd st),
    mbiTypeSubst = subst,
  }

-- A default body has no instance head: the head-disjointness and head-row alias
-- tests then have nothing to compare against.
methodBodyHeadMonos : MethodBodyKind -> List Mono
methodBodyHeadMonos (ImplBody site) = site.ibHeadMonos
methodBodyHeadMonos DefaultBody = []

-- An obligation on a receiver typaram is entailed by the interface itself on a
-- default body; an impl body's receiver is its head, so it has none.
methodBodyOwnTyparams : MethodBodyKind -> List String -> List String
methodBodyOwnTyparams (ImplBody _) _ = []
methodBodyOwnTyparams DefaultBody typarams = typarams

-- The cascade gates of ERROR-QUALITY.md §6 (dim R: one root cause, no cascade; dim
-- X: one diagnostic per root cause), which a default body is checked under: S1
-- skips its effect-variable check when the body erred, S2 skips the method-boundary
-- unify and the launder query when inferring the body erred, and S3 drops the
-- body's own obligations when that unify fails.
gatesBodyCascade : MethodBodyKind -> Bool
gatesBodyCascade (ImplBody _) = False
gatesBodyCascade DefaultBody = True

-- Infer a method body against its declared type and query the launder trail.
--
-- The clause parameters are CHECKED against the declared domains (#821/#825,
-- Phase 73's peel) rather than inferred fresh, so a callback's row IS the
-- method's rigid `e` inside the body.  Performing it under a pure stored arrow
-- then meets `<>` as a rigid leftover — the #825 launder becomes a mismatch — and
-- two rigid rows performed together JOIN.
--
-- #803 (S0): the body's latent effect on EVERY arrow down to the method's declared
-- return is bounded by the effect the method declares at that same arrow.  An
-- effect a body legitimately performs by USING an argument (applying a callback
-- `a -> <e> b`, running a row-kinded `Async e` arg) enters the body row as that
-- argument's effect VARIABLE.  An INTRINSIC effect — `putStr`, or a call to a
-- concrete-effect helper, sourced from NO argument — instead lands as a CONCRETE
-- ATOM on whichever arrow evaluates it.  So per arrow, the body's concrete atoms
-- must be a subset of the method's declared concrete atoms; anything more
-- launders to pure at the call site.  Covering ALL declared arrows (not just the
-- `pats` count) is load-bearing: a curried / eta-reduced body (`speak d k = u =>
-- putStr …`) writes FEWER patterns and performs its intrinsic effect on a
-- RETURNED-lambda arrow BEYOND its pattern count — the arrow the declared return
-- still covers.
--
-- #839 2b: this is a POST-unify QUERY over the absorption event trail.  `unify`
-- merges an intrinsic atom into the shared open tail (both-open arm, runs no
-- effectLeakCheck), after which effrowLabels can no longer see it; the trail
-- records that merge.  So: snapshot the declared AND body arrow rows + MARK the
-- trail BEFORE the unify, run the unify (which RECORDS each absorbed atom against
-- the surviving tail), then query the window per arrow.  An OPEN body arrow's
-- absorbed atom is recovered from the trail; a CLOSED body arrow (a type
-- ANNOTATION or a point-free body) is checked directionally by `unifyInto` at the
-- seam itself — see launderEscapeFromLog.
--
-- Where the two kinds differ:
--   * an impl body checks its forcing row before the launder window opens and
--     closes the effect contract before the launder query; a default body checks
--     its forcing row inside the unify's error region and closes the contract
--     last.  Either order moves absorption events and diagnostics relative to the
--     other kind's, so each keeps its own.
--   * D-3 (#1095): an impl body reads its index-only effect variables BEFORE the
--     unify closes the declared-pure arrows.
--   * cascade gates S2/S3 (`gatesBodyCascade`), on a default body: when inferring
--     the body detected an error, the unify and the launder query are skipped, so
--     one root cause is not reported again as the shape mismatch it induces at the
--     method boundary.  The unify runs with `dcMethodMismatch = Some mname`, so
--     a leaf TypeMismatch reports the specialized line `Method '<mname>': expected
--     type <e> but got <a>` (dims C and J).  When that unify detects a mismatch,
--     the body's own added impl obligations are TRUNCATED back to the pre-body
--     snapshot: the method's type is already known wrong, so its body's induced
--     obligations (e.g. `(5 : Bool)` ⇒ `Num Bool`) are cascade victims.  All three
--     read `ModuleCells.mcCells.errorsDetected` via `erredDuring`, never the diagnostic list
--     (issue 1146).  The leaf mismatch the unify region expects is pushed
--     NON-deduped: `dcMethodMismatch` is `Some mname` across the whole region,
--     which selects typeMismatchReport's first arm.
checkMethodBodyAgainst : TcEnv ->
  IfaceRef ->
  MethodBodyKind ->
  String ->
  Ty ->
  List (String, List Kind) ->
  MethodBodyInstance ->
  (Map Int Unit, Map Int Unit) ->
  Option Loc ->
  List Pat ->
  Expr ->
  MethodBodyCheck
checkMethodBodyAgainst env iface kind mname mty gscope inst contract loc pats body =
  let oblSnapshot = wSnapshot env.teDyn.dcModule.mcCells.implObls
  let indexOnly = match kind
    ImplBody _ => indexOnlyEffVars env.teDyn.dcModule gscope mty
    DefaultBody => []
  -- A graded impl body collects the calls that run an effect variable, so the
  -- effect checks below can name the call rather than the whole body.
  let sites = if isEmptyL indexOnly then None else Some (Ref [])
  let envSites = { env | teDyn = { env.teDyn | dcPerformSites = sites } }
  let (inferErred, inferred) = erredDuring env.teDyn.dcModule (_ =>
    inferBindingChecked
      False
      envSites
      (Some (normalize inst.mbiExpected))
      pats
      body)
  let actual = fst inferred
  let check =
    if inferErred && gatesBodyCascade kind then
      MethodBodyCheck {
        mbcLaunderFlagged = False,
        mbcEagerIndexed = [],
        mbcPerformedAt = None,
      }
    else
      match kind
        ImplBody _ =>
          rowInto
            env.teDyn
            True
            (inst.mbiCheckedForce ())
            (effrowNorm (snd inferred))
        DefaultBody => ()
      let launderMark = wMark env.teDyn.dcModule.mcCells.absorptions
      let declArrows = allArrowEffs inst.mbiExpected
      let actualArrows = allArrowEffs actual
      let eager =
        eagerIndexOnlyVars
          indexOnly
          inst.mbiEffVars
          actualArrows
          inst.mbiExpected
          actual
      -- A body that runs, at call time, a variable its signature charges only in
      -- a result index is judged against its signature at the call that ran it.
      let performedAt =
        if isEmptyL eager then None else performSiteIn sites actual
      let bodyDyn = match kind
        DefaultBody => { env.teDyn | dcMethodMismatch = Some mname }
        ImplBody _ => env.teDyn
      -- The body's type meets the signature at the value the body returns.
      let valueDyn = dynAtIfSome (valueSpanLoc body) bodyDyn
      let unifyDyn = match kind
        DefaultBody => valueDyn
        ImplBody _ => dynAtIfSome performedAt valueDyn
      let unifyErred =
        fst
          (erredDuring env.teDyn.dcModule (_ =>
            match kind
              DefaultBody =>
                rowInto
                  bodyDyn
                  True
                  (inst.mbiCheckedForce ())
                  (effrowNorm (snd inferred))
              ImplBody _ => ()
            unifyInto unifyDyn True inst.mbiExpected actual))
      match kind
        DefaultBody => ()
        ImplBody _ => finishEffectContract env.teDyn contract
      let escaping =
        launderEscapeFromLog
          env.teDyn.dcModule.mcGraph
          declArrows
          actualArrows
          (wWindow env.teDyn.dcModule.mcCells.absorptions launderMark)
      -- `.irName`: a DIAGNOSTIC wants the spelling, not the identity (#1446 P1's
      -- rule — `irName` is kept alongside `irOrigin` for exactly this).
      match escaping
        [] => ()
        _ =>
          pushTypeErrorOnceAt
            env.teDyn.dcModule
            "T-EFFECT-LAUNDER"
            loc
            (methodBodyLaunderMsg kind iface.irName mname escaping)
      if unifyErred && gatesBodyCascade kind then
        wRestore env.teDyn.dcModule.mcCells.implObls oblSnapshot
      MethodBodyCheck {
        mbcLaunderFlagged = isNonEmptyL escaping,
        mbcEagerIndexed = eager,
        mbcPerformedAt = performedAt,
      }
  match kind
    DefaultBody => finishEffectContract env.teDyn contract
    ImplBody _ => ()
  check

-- Publish the method-level dictionary givens after body inference, so each
-- constraint var's id is its SURVIVING (normalized) union-find root — the same id
-- an in-body return-position site (`pure []`, `empty`, `++`) normalizes to
-- (activeDictVarOf reads that root).  Registering BEFORE inference recorded the
-- pre-unification id, the in-body site could become the surviving root instead,
-- and the route fell to RNone.  Mirrors registerImplRequires's ordering.
--   * the scalar slots: an impl body registers them by name over its tv map
--     (registerImplMethodDicts), a default body by slot id over its instantiation
--     (registerMethodDictSlots);
--   * the predicate-keyed twin, from this very instantiation, into the lexical
--     given registry before route resolution — a complete request miss is
--     terminal, so this carrier is not optional.  `inferMethodBody` publishes it
--     earlier, once the body's goals are settled (`publishMethodPredGivens`);
--   * a default body's receiver: the body answers for whichever instance inherits
--     it, so a sibling or superclass call inside it is discharged by the
--     receiver's evidence (directly, or projected onto a super) instead of being
--     left for an engine to select.  The binder is no parameter of the body — see
--     `defaultReceiverDict`.
registerMethodBodyGivens : GraphCtx ->
  IfaceRef ->
  MethodBodyKind ->
  List String ->
  Ty ->
  MethodBodyInstance ->
  ScopeId ->
  Unit
registerMethodBodyGivens gctx iface kind params mty inst scope =
  match kind
    ImplBody _ =>
      registerImplMethodDicts gctx scope params mty inst.mbiNamedVars
    DefaultBody =>
      registerMethodDictSlots gctx scope 0 inst.mbiDictSlots inst.mbiTypeSubst
  match kind
    DefaultBody =>
      let receiverArgs =
        map
          (tp => optionOr (TRigid tp) (lookupAssoc tp inst.mbiNamedVars))
          params
      registerFunPredGiven
        gctx
        PredicateSlot {
          psIface = iface,
          psArgs = PSArgsKnown receiverArgs,
          psBoundIds = dedupI (flatMap monoTyvarIds receiverArgs),
        }
        (Scopes.binderAt scope defaultReceiverOrdinal)
    ImplBody _ => ()

-- the first source span inside an impl-method body, for locating T-EFFECT-LAUNDER
-- at the offending body rather than the shared interface signature.  Peels the
-- let-chain a `let _ = putStr …; body` body desugars to (a partial mirror of
-- resolve.mdk's firstExprLoc, which is not exported); falls back at the call site
-- to the method-signature loc when the body carries no span.
implBodyLoc : Expr -> Option Loc
implBodyLoc (ELoc l _) = Some l
implBodyLoc (ELam _ b) = implBodyLoc b
implBodyLoc (ELet _ _ _ e1 e2) = orElseLoc (implBodyLoc e1) (implBodyLoc e2)
implBodyLoc (ELetGroup _ b) = implBodyLoc b
implBodyLoc _ = None

-- #814 (S0): W3 method-scheme fidelity — the post-unify rigidity check, type-variable
-- and constraint axes (the effect axis is `checkMethodEffVarRigidity`).  The method
-- scheme's non-head quantifiers are re-instantiated freshly by every caller, so the
-- body may not constrain them.  Having unified the body against fresh flexible vars,
-- rigidity holds iff each survived untouched: every [extraMap] type var still
-- normalizes to a TVar (not pinned to a constructed type), and all their ids are
-- pairwise distinct and disjoint from the impl-head vars' ids (not identified with
-- each other or with a head variable).
-- Union-find bindings are monotone, so a var unbound-and-distinct AFTER unify
-- was never constrained DURING it: this is observationally the skolem check.
-- All lists here are the handful of quantified vars of one method signature.
-- One core for both kinds of method body; the per-kind values are parameters:
--   * [subject]      implSubject vs defaultSubject.
--   * [headMonos]    the instance-head monos of an impl body; a default body has no
--                    instance head and passes [], so the head-disjointness disjunct
--                    is vacuous (anyContainsI _ [] = False).
--   * [extraMap]     the survivor set: an impl body's non-head vars, every
--                    signature var of a default body (`defaultSurvivorMap`).
--   * [ownTyparams]  [] on an impl body, the interface typarams on a default body:
--                    a receiver-typaram obligation is self-entailed there.
checkMethodRigidityCore : ModuleCtx ->
  String ->
  String ->
  Ty ->
  List Mono ->
  List (String, Mono) ->
  List String ->
  List UObligation ->
  List (IfaceRef, List Mono, Option Loc) ->
  Option Loc ->
  Unit
checkMethodRigidityCore mctx subject iface mty headMonos extraMap ownTyparams addedObls addedCallObls loc =
  let pinned = map fst (filterList (p => not (isUnboundTvar (snd p))) extraMap)
  if isNonEmptyL pinned then
    pushTypeErrorOnceAt
      mctx
      "T-IMPL-TOO-SPECIFIC"
      loc
      (pinsTyvarMsg subject mty pinned)
  else
    let survivors = sigTvarIds (map snd extraMap)
    if hasDupI survivors
      || anyContainsI survivors (flatMap monoTyvarIds headMonos) then
      pushTypeErrorOnceAt
        mctx
        "T-IMPL-TOO-SPECIFIC"
        loc
        (collapsesTyvarsMsg subject mty)
  checkSurvivorObligations
    mctx
    subject
    iface
    ownTyparams
    mty
    extraMap
    addedObls
    loc
  checkSurvivorCallObligations
    mctx
    subject
    iface
    ownTyparams
    mty
    extraMap
    addedCallObls
    loc

-- A default body's survivor set: [tvs] is sigToSchemeTvs' name→scheme-var map and
-- [subst] instantiateTracked's scheme-var-id→fresh-mono subst; crossing them
-- recovers each declared name's post-unify mono, the shape an impl body's
-- non-head tv map already has.
defaultSurvivorMap : List (String, Mono) ->
  List (Int, Mono) ->
  List (String, Mono)
defaultSurvivorMap [] _ = []
defaultSurvivorMap ((name, m) :: rest) subst =
  match lookupAssocI (monoTyvarId m) subst
    Some fm => (name, fm) :: defaultSurvivorMap rest subst
    None => defaultSurvivorMap rest subst

-- #563's narrow instance-head prerequisite check. This reads the SAME protected
-- root set that body-local Num defaulting consumes, then asks only whether a root
-- carried by [implTvMap] has declared evidence in this impl's `requires`. Pinning is
-- `checkImplHeadRigidity`'s, and every other predicate on a head variable is
-- `checkImplHeadPrerequisites`'s, which renders a Num residual with this same
-- message, so the two report it once.
checkImplHeadNumObligations : ModuleCtx ->
  String ->
  List (String, Mono) ->
  List Require ->
  OrdMap Unit ->
  List UObligation ->
  Unit
checkImplHeadNumObligations mctx _ _ _ _ [] = ()
checkImplHeadNumObligations mctx subject implTvMap reqs survivingIds (o :: rest) =
  checkImplHeadNumIds
    mctx
    subject
    implTvMap
    reqs
    survivingIds
    o.loc
    (dedupI (numObligIds o))
  checkImplHeadNumObligations mctx subject implTvMap reqs survivingIds rest

checkImplHeadNumIds : ModuleCtx ->
  String ->
  List (String, Mono) ->
  List Require ->
  OrdMap Unit ->
  Option Loc ->
  List Int ->
  Unit
checkImplHeadNumIds mctx _ _ _ _ _ [] = ()
checkImplHeadNumIds mctx subject implTvMap reqs survivingIds loc (id :: rest) =
  match survivorNameOfId id implTvMap
    Some vname =>
      if omHasKey (intToString id) survivingIds
        && not (implRequiresRoot mctx "Num" id implTvMap reqs) then
        pushTypeErrorOnceAt
          mctx
          "T-IMPL-MISSING-REQUIRES"
          loc
          (undeclaredImplPrerequisiteMsg subject "Num" vname)
    None => ()
  checkImplHeadNumIds mctx subject implTvMap reqs survivingIds loc rest

implRequiresRoot : ModuleCtx ->
  String ->
  Int ->
  List (String, Mono) ->
  List Require ->
  Bool
implRequiresRoot mctx _ _ _ [] = False
implRequiresRoot mctx wanted id implTvMap ((Require { requireHead = iface, requireArgs = args, ... }) :: rest) =
  contains wanted (ifaceSelfAndSupers mctx iface)
      && requireArgsAreRoot id implTvMap args
    || implRequiresRoot mctx wanted id implTvMap rest

requireArgsAreRoot : Int -> List (String, Mono) -> List Ty -> Bool
requireArgsAreRoot id implTvMap [TyVar name] = match lookupAssoc name implTvMap
  Some m => match normalize m
    TVar cell => tyvarId cell == id
    _ => False
  None => False
requireArgsAreRoot _ _ _ = False

implHeadVarRoots : List (String, Mono) -> List (String, HeadVarRoot)
implHeadVarRoots implTvMap =
  flatMap
    (p => match headVarRootOf (snd p)
      Some root => [(fst p, root)]
      None => [])
    implTvMap

-- The head variables that are still type variables, by tyvar root.
implHeadTypeVarRoots : List (String, Mono) -> List (String, Int)
implHeadTypeVarRoots implTvMap =
  flatMap
    (p => match snd p
      TypeVarRoot id => [(fst p, id)]
      RowVarRoot _ => [])
    (implHeadVarRoots implTvMap)

-- The head variables this body narrowed: each one that was a variable before the
-- body and is now fixed to a constructed type or a row with atoms or a closed
-- tail, or now shares its root with another
-- head variable that was distinct before.  A variable an earlier sibling body
-- narrowed is not in [before], so it is reported once, by that body.
headVarsNarrowedBy : List (String, HeadVarRoot) ->
  List (String, Mono) ->
  List String
headVarsNarrowedBy before implTvMap =
  let after = implHeadVarRoots implTvMap
  map fst (filterList (headVarNarrowed before after) before)

headVarNarrowed : List (String, HeadVarRoot) ->
  List (String, HeadVarRoot) ->
  (String, HeadVarRoot) ->
  Bool
headVarNarrowed before after (name, root0) = match lookupAssoc name after
  None => True
  Some root =>
    anyList
      (other =>
        snd other /= root0 && lookupAssoc (fst other) after == Some root)
      before

-- A body that fixes a head variable holds only for the narrower head it implies,
-- yet the instance is registered for the written one, so a receiver the written
-- head admits and the body does not reaches the body with a value of another type.
checkImplHeadRigidity : ModuleCtx ->
  String ->
  String ->
  ImplBodySite ->
  List (String, HeadVarRoot) ->
  Option Loc ->
  Unit
checkImplHeadRigidity mctx subject iface site before loc =
  match headVarsNarrowedBy before site.ibImplTvMap
    [] => ()
    narrowed =>
      pushTypeErrorOnceAt
        mctx
        "T-IMPL-TOO-SPECIFIC"
        loc
        (narrowsImplHeadMsg subject narrowed (narrowedImplHead iface site))

-- The head the body actually supports, each still-free head variable under its
-- written name.
narrowedImplHead : String -> ImplBodySite -> String
narrowedImplHead iface site =
  let named = map (p => (snd p, fst p)) (implHeadTypeVarRoots site.ibImplTvMap)
  join " " ("impl" :: iface :: ppEach (Ref named) (Ref 0) 3 site.ibHeadMonos)

-- The constraint axis of W3-inst: every predicate this body leaves on head variables
-- must be given by the impl.  Each goal mentioning a head variable is reduced through
-- the instances (§3 `inst`), a goal the impl gives ending the reduction (§3 `assum`
-- before `inst`), and a residual over head variables alone that no given answers is
-- reported at the goal's site.  The givens are the impl's own head, its `requires`
-- with their superinterfaces, and the method signature's own `=>` context.
-- A residual that an instance answers only by binding a head variable is reported
-- too, whatever other variables it mentions.  A goal no instance can answer even
-- with the head variables free is left to the obligation gate's no-impl verdict only
-- when the gate decides it (`allConcreteHeads`, as `uOblIsDecidableNow` asks).  A
-- vector the gate defers is a residual here: the head variable it waits on is rigid
-- for the body and never binds, so no later reader judges it.
checkImplHeadPrerequisites : ModuleCtx ->
  String ->
  IfaceRef ->
  ImplBodySite ->
  List (String, Mono) ->
  Ty ->
  List UObligation ->
  List (IfaceRef, List Mono, Option Loc) ->
  Unit
checkImplHeadPrerequisites mctx subject iface site methodTvs mty addedObls addedCallObls =
  match implHeadTypeVarRoots site.ibImplTvMap
    [] => ()
    roots =>
      let givens = implBodyGivens mctx iface site methodTvs mty
      let goals =
        flatMap (oblPredOf mctx.mcGraph) addedObls
          ++ flatMap callPredOf addedCallObls
      fold
        (_ g => checkImplHeadGoal (siteFor mctx) subject roots givens g)
        ()
        goals

checkImplHeadGoal : SiteCtx ->
  String ->
  List (String, Int) ->
  List PredicateSlot ->
  (IfaceRef, List Mono, Option Loc) ->
  Unit
checkImplHeadGoal sx subject roots givens (iface, ds, loc) =
  let args = map normalize ds
  let rootIds = map snd roots
  if any (i => elem i rootIds) (flatMap monoUnboundIds args) then
    let headIds = omFromNames (map (r => intToString (snd r)) roots) omEmpty
    let leaves =
      implGoalResiduals
        { sx | sxSite = loc }
        (reqWalkStart ())
        headIds
        givens
        iface
        args
    fold
      (_ leaf => reportImplHeadResidual sx.sxModule subject roots loc leaf)
      ()
      leaves

-- The impl's own head is given as written: its superinterfaces are separate
-- instances whose own contexts must hold, so they are not given with it.
implBodyGivens : ModuleCtx ->
  IfaceRef ->
  ImplBodySite ->
  List (String, Mono) ->
  Ty ->
  List PredicateSlot
implBodyGivens mctx iface site methodTvs mty =
  let declared =
    map (requirePredicateSlot mctx site.ibImplTvMap) site.ibRequires
      ++ map (constraintPredicateSlot mctx methodTvs) (sigConstraintsOf mty)
  knownPredicateSlot iface site.ibHeadMonos
    :: declared
      ++ flatMap
        (s => map fst (predicateSlotKnownSupers mctx.mcGraph s))
        declared

requirePredicateSlot : ModuleCtx ->
  List (String, Mono) ->
  Require ->
  PredicateSlot
requirePredicateSlot mctx implTvMap (Require { requireHead = h, requireArgs = rargs, requireOrigin = o }) =
  knownPredicateSlot
    IfaceRef { irName = h, irOrigin = o }
    (map (fromAstType mctx implTvMap) rargs)

constraintPredicateSlot : ModuleCtx ->
  List (String, Mono) ->
  Constraint ->
  PredicateSlot
constraintPredicateSlot mctx tvs (Constraint { constraintHead = h, constraintArgs = cargs, constraintOrigin = o }) =
  knownPredicateSlot
    IfaceRef { irName = h, irOrigin = o }
    (map (fromAstType mctx tvs) cargs)

knownPredicateSlot : IfaceRef -> List Mono -> PredicateSlot
knownPredicateSlot iface args = PredicateSlot {
  psIface = iface,
  psArgs = PSArgsKnown args,
  psBoundIds = dedupI (flatMap monoTyvarIds args),
}

-- A residual over head variables alone names the `requires` to add.  One that also
-- mentions a variable of the body's own has no `requires` to name, so it is
-- reported when an instance answers it only by fixing a head variable, and as
-- `T-NO-IMPL` when no instance unifies with it at all: the head variable is rigid,
-- so no later binding can give it an instance.
reportImplHeadResidual : ModuleCtx ->
  String ->
  List (String, Int) ->
  Option Loc ->
  (IfaceRef, List Mono) ->
  Unit
reportImplHeadResidual mctx subject roots loc (iface, args) =
  let ids = flatMap monoUnboundIds args
  let headIds = map snd roots
  let named = map (p => (snd p, fst p)) roots
  let rendered = ppEach (Ref named) (Ref 0) 3 args
  let pred = "\{iface.irName} \{join " " rendered}"
  if isEmptyL ids || not (anyList (i => containsI i headIds) ids) then
    ()
  else if allList (i => containsI i headIds) ids then
    let msg = match (map normalize args, rendered)
      ([TVar _], [vname]) =>
        undeclaredImplPrerequisiteMsg subject iface.irName vname
      _ => undeclaredImplPredicateMsg subject pred
    pushTypeErrorOnceAt mctx "T-IMPL-MISSING-REQUIRES" loc msg
  else if answeredOnlyByBindingHead
    mctx
    (omFromNames (map (r => intToString (snd r)) roots) omEmpty)
    iface
    args then
    let fixed =
      dedup (flatMap (r => if containsI (snd r) ids then [fst r] else []) roots)
    pushTypeErrorOnceAt
      mctx
      "T-IMPL-MISSING-REQUIRES"
      loc
      (implGoalFixesHeadMsg subject pred fixed)
  else if isEmptyL
    (goalCandidates mctx omEmpty args (goalRows mctx iface args)) then
    reportUndeterminedNoImpl mctx iface args loc

-- the CALL-obligation half of the constraint axis: recordCallObligations pushes
-- (iface, [constraint-var mono], loc) for each dict slot a constrained CALLEE
-- discharges at a call site, so the monos here are the dispatch monos directly
-- (no declared-type walk needed).  Same rule as checkSurvivorObligations: a
-- predicate landing on a method-scheme var must be entailed by a declared
-- method-level constraint under requires-closure.
checkSurvivorCallObligations : ModuleCtx ->
  String ->
  String ->
  List String ->
  Ty ->
  List (String, Mono) ->
  List (IfaceRef, List Mono, Option Loc) ->
  Option Loc ->
  Unit
checkSurvivorCallObligations mctx _ _ _ _ _ [] _ = ()
checkSurvivorCallObligations mctx subject ownIface ownTyparams mty extraMap ((oiface, monos, _) :: rest) loc =
  checkSurvivorDispatchMonos
    mctx
    subject
    ownIface
    ownTyparams
    mty
    extraMap
    oiface.irName
    monos
    loc
  checkSurvivorCallObligations
    mctx
    subject
    ownIface
    ownTyparams
    mty
    extraMap
    rest
    loc

methodLevelConstraintMonos : List String ->
  Ty ->
  List (String, Mono) ->
  List Mono
methodLevelConstraintMonos ifaceParams mty tvMap =
  flatMap
    (name => match lookupAssoc name tvMap
      Some m => [m]
      None => [])
    (methodLevelConstraintVarNames ifaceParams mty)

methodConstraintSlotIds : List String -> Ty -> List (String, Mono) -> List Int
methodConstraintSlotIds typarams (TyConstrained cs t) tvs =
  flatMap (constraintSlotId typarams tvs) cs
    ++ methodConstraintSlotIds typarams t tvs
methodConstraintSlotIds typarams (TyEffect _ _ t) tvs =
  methodConstraintSlotIds typarams t tvs
methodConstraintSlotIds _ _ _ = []

-- one slot per method-level constraint: the id of its dispatch var
-- (constraintSlotDispatchVar), which the supplied dict narrows by.
constraintSlotId : List String -> List (String, Mono) -> Constraint -> List Int
constraintSlotId typarams tvs c = match constraintSlotDispatchVar typarams c
  [] => []
  n :: _ => match lookupAssoc n tvs
    Some m => [monoTyvarId m]
    None => []

-- The Num obligations of variables that reach a boundary only through a
-- constrained callee's instantiation (a where helper generalized as
-- `Num r => a -> r`, used as `debug (two ())`).  They are on the call and
-- dictionary-application windows, not the boundary's own (#23); a top-level
-- group and a method body default them like any other candidate.
export
calleeNumObls : ModuleCtx -> Int -> Int -> List UObligation
calleeNumObls mctx callN0 dictN0 =
  numCallObls mctx.mcGraph (callUOblsWindow mctx callN0)
    ++ numDictObls mctx.mcGraph (dictAppsSince mctx.mcGraph dictN0)

-- #23 support: synthesize impl-obligation-shaped Num entries from a group's
-- pendingCallObligations / pendingDictApps deltas.  The Num constraint of an
-- ambiguous var reaching a group ONLY through a constrained-callee instantiation
-- (`main = println (app2 (==))`) is recorded on those refs, never on
-- pendingImplObligations, so group-level Num defaulting (defaultGroupNumWith /
-- groundNumVarsWith, which both reads candidate ids AND finds the live var to ground
-- from impl-shaped entries) never saw it — leaving an ungrounded var whose Num dict
-- route resolves RNone → a NULL dict word → build-time SIGTRAP (run is correct).
-- Only field 0 (iface) and field 3 (the live operand mono) are read downstream;
-- the rest mirror inferNumLitBare's placeholder shape.
-- Num is 1-param, so its obligation vector is a singleton; a wider predicate can
-- never be "Num" and is filtered out anyway.
export
numCallObls : GraphCtx -> List UObligation -> List UObligation
numCallObls gctx [] = []
numCallObls gctx (o :: rest) = match (o.pred.iface.irName, uOblArgs gctx o)
  ("Num", [mono]) =>
    mkMethodOccObl
        (builtinIfaceRef gctx BNum)
        ["a"]
        (TyVar "a")
        mono
        []
        PNumLit
        o.loc
        o.uoScope
      :: numCallObls gctx rest
  _ => numCallObls gctx rest

numDictObls : GraphCtx -> List PendingDictApp -> List UObligation
-- #1155: the loc comes from the ENTRY's own snapshot.  This runs at a generalized
-- group close, well after inference left the call site, where the record's `mcLoc`
-- names no construct of the entry.
-- Behaviour-neutral by inspection rather than by hope: these synthetic entries feed
-- ONLY the Num-defaulting search (`NumBoundaryOwnedScc` →
-- `numConstrainedIds`/`groundNumVarsWith` → `numObligIds`/`liveNumVarGo`), and every one
-- of those readers destructures the 5th element as `_`.  Nothing renders it today;
-- the point is that the tuple stops carrying a span it knows to be wrong.
numDictObls gctx [] = []
-- B-4b-iii: SPELLING consumer of the widened route carrier — the `"Num"` test is a
-- name test against the prelude spelling, unchanged, so `.irName` is projected here.
numDictObls gctx (app :: rest) =
  flatMap
      (p =>
        if fst p == "Num" then
          [
            mkMethodOccObl
              (builtinIfaceRef gctx BNum)
              ["a"]
              (TyVar "a")
              (snd p)
              []
              PNumLit
              app.pdaLoc
              app.pdaScope,
          ]
        else
          [])
      (zip (map (i => i.irName) app.pdaIfaces) app.pdaMonos)
    ++ numDictObls gctx rest
# DESUGAR
(DUse false (UseGroup ("types" "tc_types") ((mem "BuiltinClass" true) (mem "CohSweep" true) (mem "DeclaringBinder" true) (mem "GrantBinder" true) (mem "HeadVarRoot" true) (mem "ImplBodySite" true) (mem "Kind" true) (mem "MethodBodyCheck" true) (mem "MethodBodyInstance" true) (mem "MethodBodyKind" true) (mem "MStep" true) (mem "NumBoundary" true) (mem "NumBoundaryDisposition" true) (mem "NumGuard" true) (mem "PredicateSlot" true) (mem "PredicateSlotArgs" true) (mem "Provenance" true) (mem "ReqStep" true) (mem "ScopedImplMethod" true) (mem "SiteCtx" true) (mem "TcEnv" true) (mem "UObligation" true) (mem "CeRow" false) (mem "ClassEnv" false) (mem "CohImpl" false) (mem "CohScan" false) (mem "GraphCtx" false) (mem "ImplEnv" false) (mem "ImplRow" false) (mem "ModuleCtx" false) (mem "PendingDictApp" false) (mem "ReqWalk" false) (mem "siteFor" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "allArrowEffs" false) (mem "anyConcreteHead" false) (mem "anyContainsI" false) (mem "anyMember" false) (mem "authCellsIn" false) (mem "authOrderIn" false) (mem "authOrderRow" false) (mem "cohEqMono" false) (mem "cohOverlap" false) (mem "cohPpPair" false) (mem "containsI" false) (mem "dedupI" false) (mem "hasDupI" false) (mem "headVarRootOf" false) (mem "instantiateNamedMonos" false) (mem "isUnboundTvar" false) (mem "matchOneSided" false) (mem "monoRootIdSet" false) (mem "monoTyvarId" false) (mem "monoTyvarIds" false) (mem "monoUnboundIds" false) (mem "peelQual" false) (mem "sigTvarIds" false) (mem "stripTyWrap" false) (mem "tyAppSpine" false) (mem "tyStep" false) (mem "tyStructEq" false) (mem "tyvarId" false) (mem "tyVarNames" false))))
(DUse false (UseGroup ("types" "tc_diag_text") ((mem "backticked" false) (mem "cohCrossModuleMsg" false) (mem "cohIncomparableHelp" false) (mem "cohOverlapMsg" false) (mem "cohPreludeOverlapMsg" false) (mem "collapsesTyvarsMsg" false) (mem "derivableIface" false) (mem "implGoalFixesHeadMsg" false) (mem "implHeadIndexMsg" false) (mem "implKindMismatchMsg" false) (mem "implTupleHeadKindMsg" false) (mem "methodBodyLaunderMsg" false) (mem "methodBodySubject" false) (mem "missingImplMethodMsg" false) (mem "narrowsImplHeadMsg" false) (mem "pinsTyvarMsg" false) (mem "qualifiedIfaceLabel" false) (mem "superContextNoImplMsg" false) (mem "superContextUndeclaredMsg" false) (mem "undeclaredImplPredicateMsg" false) (mem "undeclaredImplPrerequisiteMsg" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "callUOblsWindow" false) (mem "currentScopeStore" false) (mem "defaultReceiverOrdinal" false) (mem "dynAtIfSome" false) (mem "emptySigVars" false) (mem "envAtIfSome" false) (mem "mctxAtIfSome" false) (mem "wMark" false) (mem "wRestore" false) (mem "wSnapshot" false) (mem "wWindow" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "anyKRow" false) (mem "builtinIfaceRef" false) (mem "ceLookupAt" false) (mem "ceMethodTyAt" false) (mem "ceRequiredAt" false) (mem "ceRowIfaceName" false) (mem "ceRowLoc" false) (mem "ceRowMethods" false) (mem "ceRowsOwnedBy" false) (mem "ceRowSupers" false) (mem "ceRowTyparams" false) (mem "ceSlotKindsAt" false) (mem "constraintSlotDispatchVar" false) (mem "declGradedScope" false) (mem "effTailNames" false) (mem "extendVars" false) (mem "ieRowInst" false) (mem "ieRowLoc" false) (mem "ieRowOrd" false) (mem "ieRowsAll" false) (mem "ieRowsOwnedBy" false) (mem "ieRowsVisibleAt" false) (mem "ieRowTriple" false) (mem "ifaceTabKey" false) (mem "instRefMid" false) (mem "methodLevelConstraintVarNames" false) (mem "removeAllS" false) (mem "tyTabKey" false))))
(DUse false (UseGroup ("types" "tc_diag") ((mem "erredDuring" false) (mem "pushTypeError" false) (mem "pushTypeErrorAt" false) (mem "pushTypeErrorOnceAt" false) (mem "pushTypeErrorOncePerSite" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "captureScope" false) (mem "closeScope" false) (mem "enterLevel" false) (mem "exitLevel" false) (mem "freshAuthBinderRanged" false) (mem "freshTvMap" false) (mem "instantiateMethodTracked" false) (mem "rowInto" false) (mem "unifyInto" false))))
(DUse false (UseGroup ("types" "tc_decls_types") ((mem "authArgBindersIn" false) (mem "bindingForceFromAst" false) (mem "fromAstType" false) (mem "fromAstTypeE" false) (mem "kindsEq" false) (mem "patternSlotNamesIn" false) (mem "rowArgNamesIn" false) (mem "sigConstraintsOf" false) (mem "sigVarsWithAuths" false))))
(DUse false (UseGroup ("types" "tc_decls") ((mem "dedupBinders" false) (mem "methodSchemesPure" false) (mem "sigToSchemeTvsIn" false) (mem "sigVarsFor" false) (mem "tyConNamesInTy" false))))
(DUse false (UseGroup ("types" "tc_solve_givens") ((mem "givenAnswers" false) (mem "predicateSlotKnownSupers" false) (mem "publishMethodPredGivens" false) (mem "registerFunPredGiven" false) (mem "registerImplMethodDicts" false) (mem "registerMethodDictSlots" false))))
(DUse false (UseGroup ("types" "tc_solve_entail") ((mem "goalCandidates" false) (mem "goalRows" false) (mem "reqWalkEnter" false) (mem "reqWalkMemo" false) (mem "reqWalkSeed" false) (mem "reqWalkStart" false) (mem "superParamsOf" false))))
(DUse false (UseGroup ("types" "tc_solve") ((mem "answeredOnlyByBindingHead" false) (mem "determineByUniqueInstance" false) (mem "dictAppsSince" false) (mem "goalsMark" false) (mem "improveByUniqueImpl" false) (mem "noteWalkGoalFollowed" false) (mem "openScope" false) (mem "rigidHeadInstanceContext" false) (mem "solvedCleanly" false) (mem "solvedOnWalk" false) (mem "uOblArgs" false) (mem "walkGoalFollowed" false))))
(DUse false (UseGroup ("types" "tc_solve_check") ((mem "callOblsWindow" false) (mem "callPredOf" false) (mem "checkSigVarGoals" false) (mem "checkSurvivorDispatchMonos" false) (mem "checkSurvivorObligations" false) (mem "finalizeNumBoundary" false) (mem "ifaceSelfAndSupers" false) (mem "implGoalResiduals" false) (mem "numConstrainedIds" false) (mem "numObligIds" false) (mem "oblPredOf" false) (mem "prerequisiteOnWalk" false) (mem "registerImplRequires" false) (mem "rejectUndeterminedVectors" false) (mem "rejectWithheldAmbiguity" false) (mem "reportUndeterminedNoImpl" false) (mem "reqWalkReported" false) (mem "survivorNameOfId" false))))
(DUse false (UseGroup ("types" "tc_effects") ((mem "beginEffectContract" false) (mem "checkMethodEffVarRigidity" false) (mem "eagerIndexOnlyVars" false) (mem "finishEffectContract" false) (mem "indexOnlyEffVars" false) (mem "launderEscapeFromLog" false) (mem "markSourceless" false) (mem "methodGrantOf" false) (mem "performSiteIn" false) (mem "recordClauseFileBound" false))))
(DUse false (UseGroup ("types" "tc_occurrence") ((mem "mkMethodOccObl" false))))
(DUse false (UseGroup ("types" "tc_groups") ((mem "exprLoc" false) (mem "requireGoalsBelow" false) (mem "sccProtectedSignatureIds" false))))
(DUse false (UseGroup ("types" "tc_infer") ((mem "appArgLoc" false) (mem "inferBindingChecked" false) (mem "valueSpanLoc" false))))
(DUse false (UseGroup ("types" "scopes") ((mem "DefaultBodyIdentity" true) (mem "ScopeOwner" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Constraint" true) (mem "Decl" true) (mem "Expr" true) (mem "IfaceMethod" true) (mem "ImplMethod" true) (mem "Loc" true) (mem "MethodDefault" true) (mem "Pat" true) (mem "Require" true) (mem "Super" true) (mem "TabKey" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "firstTyLoc" false) (mem "firstTyLocList" false) (mem "implMethodName" false) (mem "lookupTab" false) (mem "orElseLoc" false) (mem "sameTyConHead" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Mono" true) (mem "lookupAssocI" false) (mem "normalize" false) (mem "ppEach" false) (mem "ppTy" false) (mem "ppTyAtom" false))))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("types" "evidence") ((mem "ScopeId" true))))
(DUse false (UseGroup ("types" "publish") ((mem "TcDiag" true))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "anyList" false) (mem "contains" false) (mem "dedup" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "isSome" false) (mem "listLen" false) (mem "lookupAssoc" false))))
(DUse false (UseGroup ("list") ((mem "drop" false) (mem "get" false) (mem "range" false) (mem "reverse" false) (mem "zip" false))))
(DUse false (UseGroup ("string") ((mem "join" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "effrowNorm" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "exprSpanLoc" false))))
(DUse false (UseGroup ("frontend" "resolve") ((mem "firstExprLoc" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "ifaceWordOf" false))))
(DUse false (UseGroup ("types" "superclass") ((mem "lookupPos" false) (mem "mapAll" false) (mem "superIfaceRef" false))))
(DUse false (UseGroup ("types" "registry") ((mem "regKeyOfTab" false))))
(DUse false (UseAlias ("types" "scopes") "Scopes"))
(DUse false (UseAlias ("map") "IdMap"))
(DTypeSig true "checkGradedImplHeads" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))))
(DFunDef false "checkGradedImplHeads" ((PVar "mctx") PWild PWild (PList)) (ELit LUnit))
(DFunDef false "checkGradedImplHeads" ((PVar "mctx") (PVar "ce") (PVar "cur") (PCons (PVar "d") (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "checkGradedImplHeadDecl") (EVar "mctx")) (EVar "ce")) (EVar "cur")) (EVar "d"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkGradedImplHeads") (EVar "mctx")) (EVar "ce")) (EVar "cur")) (EVar "rest")))))
(DTypeSig false "checkGradedImplHeadDecl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyFun (TyCon "Decl") (TyCon "Unit"))))))
(DFunDef false "checkGradedImplHeadDecl" ((PVar "mctx") (PVar "ce") (PVar "cur") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EVar "checkGradedImplHeadDecl") (EVar "mctx")) (EVar "ce")) (EVar "cur")) (EVar "d")))
(DFunDef false "checkGradedImplHeadDecl" ((PVar "mctx") (PVar "ce") (PVar "cur") (PRec "DImpl" ((rf "iface" None) (rf "tys" None) (rf "implOrigin" (PVar "o"))) true)) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkGradedImplTys") (EVar "mctx")) (EVar "ce")) (EVar "cur")) (EVar "o")) (EVar "iface")) (ELit (LInt 0))) (EVar "tys")))
(DFunDef false "checkGradedImplHeadDecl" ((PVar "mctx") PWild PWild PWild) (ELit LUnit))
(DTypeSig false "checkGradedImplTys" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Unit")))))))))
(DFunDef false "checkGradedImplTys" ((PVar "mctx") PWild PWild PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "checkGradedImplTys" ((PVar "mctx") (PVar "ce") (PVar "cur") (PVar "o") (PVar "iface") (PVar "i") (PCons (PVar "t") (PVar "rest"))) (EBlock (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "ceSlotKindsAt") (EApp (EVar "regKeyOfTab") (EApp (EApp (EVar "ifaceTabKey") (EVar "o")) (EVar "iface")))) (EVar "cur")) (EVar "i")) (EVar "ce")) (arm (PCon "Some" (PVar "want")) ((GBool (EApp (EVar "anyKRow") (EVar "want")))) (EApp (EApp (EApp (EApp (EVar "checkGradedImplHead") (EVar "mctx")) (EVar "iface")) (EVar "t")) (EVar "want"))) (arm PWild () (ELit LUnit)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkGradedImplTys") (EVar "mctx")) (EVar "ce")) (EVar "cur")) (EVar "o")) (EVar "iface")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")))))
(DTypeSig false "checkGradedImplHead" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyCon "Unit"))))))
(DFunDef false "checkGradedImplHead" ((PVar "mctx") (PVar "iface") (PVar "t") (PVar "want")) (EMatch (EApp (EVar "tyAppSpine") (EVar "t")) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConLoc" (PVar "loc")) (rf "tyConOrigin" (PVar "o"))) false) (PVar "applied")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkGradedImplHeadCon") (EVar "mctx")) (EVar "iface")) (EVar "o")) (EVar "n")) (EVar "loc")) (EApp (EVar "listLen") (EVar "applied"))) (EVar "want"))) (arm (PTuple (PCon "TyTuple" (PVar "ts")) PWild) () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (ELit (LString "T-IMPL-KIND-MISMATCH"))) (EApp (EVar "firstTyLocList") (EVar "ts"))) (EApp (EApp (EApp (EVar "implTupleHeadKindMsg") (EVar "iface")) (EApp (EVar "listLen") (EVar "ts"))) (EVar "want")))) (arm PWild () (ELit LUnit))))
(DTypeSig false "checkGradedImplHeadCon" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyCon "Unit")))))))))
(DFunDef false "checkGradedImplHeadCon" ((PVar "mctx") (PVar "iface") (PVar "o") (PVar "n") (PVar "loc") (PVar "nApplied") (PVar "want")) (EMatch (EApp (EApp (EApp (EApp (EVar "headRemainingKinds") (EVar "mctx")) (EVar "o")) (EVar "n")) (EVar "nApplied")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "got")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkGradedImplHeadKinds") (EVar "mctx")) (EVar "iface")) (EVar "n")) (EVar "loc")) (EVar "nApplied")) (EVar "want")) (EVar "got")))))
(DTypeSig false "headRemainingKinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Kind"))))))))
(DFunDef false "headRemainingKinds" ((PVar "mctx") (PVar "o") (PVar "n") (PVar "nApplied")) (ELetGroup ((lgb "key" (clause () (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n"))))) (EIf (EApp (EVar "isSome") (EApp (EApp (EVar "lookupTab") (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "aliasTableRef") "value"))) (EVar "None") (EIf (EVar "otherwise") (EApp (EApp (EVar "map") (EApp (EVar "drop") (EVar "nApplied"))) (EApp (EApp (EVar "lookupTab") (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamKindsRef") "value"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "checkGradedImplHeadKinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyCon "Unit")))))))))
(DFunDef false "checkGradedImplHeadKinds" ((PVar "mctx") (PVar "iface") (PVar "n") (PVar "loc") (PVar "nApplied") (PVar "want") (PVar "got")) (EIf (EApp (EApp (EVar "kindsEq") (EVar "got")) (EVar "want")) (ELit LUnit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (ELit (LString "T-IMPL-KIND-MISMATCH"))) (EVar "loc")) (EApp (EApp (EApp (EApp (EApp (EVar "implKindMismatchMsg") (EVar "iface")) (EVar "n")) (EVar "nApplied")) (EVar "want")) (EVar "got"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "registerMethodBodyGrants" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "MethodBodyInstance") (TyFun (TyCon "ScopeId") (TyCon "Unit"))))))))
(DFunDef false "registerMethodBodyGrants" ((PVar "gctx") (PVar "iface") (PVar "mname") (PVar "heads") (PVar "inst") (PCon "ScopeId" (PVar "sid"))) (EBlock (DoLet false false (PVar "headIds") (EApp (EVar "IdMap.keys") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "h")) (EApp (EApp (EVar "authCellsIn") (EVar "h")) (EVar "acc")))) (EVar "Tip")) (EVar "heads")))) (DoExpr (EApp (EApp (EVar "markSourceless") (EVar "gctx")) (EVar "headIds"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "methodGrantOf") (EVar "gctx")) (EApp (EApp (EVar "ifaceWordOf") (EFieldAccess (EVar "iface") "irOrigin")) (EFieldAccess (EVar "iface") "irName"))) (EVar "mname")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "mg")) () (EBlock (DoLet false false (PVar "own") (EApp (EApp (EVar "filterList") (ELam ((PVar "i")) (EApp (EVar "not") (EApp (EApp (EVar "containsI") (EVar "i")) (EVar "headIds"))))) (EApp (EVar "reverse") (EApp (EApp (EVar "authOrderRow") (EFieldAccess (EVar "inst") "mbiContractForce")) (EApp (EApp (EVar "authOrderIn") (EFieldAccess (EVar "inst") "mbiExpected")) (EListLit)))))) (DoLet false false (PVar "ids") (EApp (EApp (EVar "map") (ELam ((PVar "k")) (EApp (EApp (EVar "optionOr") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EApp (EApp (EVar "get") (EVar "k")) (EVar "own"))))) (EApp (EApp (EVar "range") (ELit (LInt 0))) (EApp (EVar "listLen") (EFieldAccess (EVar "mg") "mgNames"))))) (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsBodies")) (EApp (EApp (EApp (EVar "IdMap.set") (EVar "sid")) (EApp (EApp (EVar "BodyGrantBinder") (EVar "mname")) (EVar "ids"))) (EFieldAccess (EFieldAccess (EVar "st") "gsBodies") "value"))))))))))
(DTypeSig false "numChannelRootSet" (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "numChannelRootSet" ((PVar "obls") (PVar "channels")) (EBlock (DoLet false false (PVar "channelIds") (EApp (EVar "monoRootIdSet") (EVar "channels"))) (DoExpr (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "filterList") (ELam ((PVar "name")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "channelIds")))) (EApp (EApp (EVar "map") (EVar "intToString")) (EApp (EVar "dedupI") (EApp (EVar "numConstrainedIds") (EVar "obls")))))) (EVar "omEmpty")))))
(DTypeSig false "cohFreshTys" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "cohFreshTys" ((PVar "mctx") (PVar "tys")) (EApp (EVar "snd") (EApp (EApp (EVar "implHeadMonos") (EVar "mctx")) (EVar "tys"))))
(DTypeSig false "implHeadMonos" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "Mono"))))))
(DFunDef false "implHeadMonos" ((PVar "mctx") (PVar "tys")) (EBlock (DoExpr (EApp (EApp (EVar "each") (EApp (EVar "checkImplHeadIndices") (EVar "mctx"))) (EVar "tys"))) (DoLet false false (PVar "auths") (EApp (EApp (EVar "dedupBinders") (EApp (EApp (EVar "flatMap") (EApp (EVar "authArgBindersIn") (EVar "mctx"))) (EVar "tys"))) (EListLit))) (DoLet false false (PVar "pats") (EApp (EApp (EVar "flatMap") (EApp (EVar "patternSlotNamesIn") (EVar "mctx"))) (EVar "tys"))) (DoLet false false (PVar "tvMap") (EApp (EApp (EVar "freshTvMap") (EVar "mctx")) (EApp (EApp (EVar "removeAllS") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "auths"))) (EApp (EVar "dedup") (EApp (EApp (EVar "flatMap") (EVar "tyVarNames")) (EVar "tys")))))) (DoLet false false (PVar "etbl") (EApp (EApp (EVar "sigVarsWithAuths") (EApp (EApp (EVar "map") (ELam ((PVar "b")) (EApp (EApp (EApp (EVar "freshAuthBinderRanged") (EVar "mctx")) (EApp (EApp (EVar "contains") (EApp (EVar "fst") (EVar "b"))) (EVar "pats"))) (EVar "b")))) (EVar "auths"))) (EVar "emptySigVars"))) (DoExpr (ETuple (EVar "tvMap") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvMap"))) (EVar "tys"))))))
(DTypeSig false "checkImplHeadIndices" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyCon "Unit"))))
(DFunDef false "checkImplHeadIndices" ((PVar "mctx") (PCon "TyApp" (PVar "a") (PVar "b"))) (EMatch (EApp (EVar "tyAppSpine") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b"))) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false) (PVar "args")) () (EMatch (EApp (EApp (EVar "lookupTab") (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamKindsRef") "value")) (arm (PCon "Some" (PVar "kinds")) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EVar "kinds")) (EApp (EVar "listLen") (EVar "args"))))) (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "ka")) (EMatch (EVar "ka") (arm (PTuple (PCon "KAuth" PWild PWild) (PCon "TyAuth" (PVar "ps") (PVar "loc"))) () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (ELit (LString "T-AUTHORITY-KIND"))) (EVar "loc")) (EApp (EApp (EVar "implHeadIndexMsg") (EVar "n")) (EApp (EVar "ppTy") (EApp (EApp (EVar "TyAuth") (EVar "ps")) (EVar "loc")))))) (arm PWild () (ELit LUnit))))) (ELit LUnit)) (EApp (EApp (EVar "zip") (EVar "kinds")) (EVar "args")))) (arm PWild () (ELit LUnit)))) (arm PWild () (ELit LUnit))))
(DFunDef false "checkImplHeadIndices" ((PVar "mctx") PWild) (ELit LUnit))
(DTypeSig false "cohImplOfRow" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ImplRow") (TyCon "CohImpl"))))
(DFunDef false "cohImplOfRow" ((PVar "mctx") (PVar "r")) (EMatch (EApp (EVar "ieRowTriple") (EVar "r")) (arm (PTuple (PVar "ir") (PVar "tys") PWild) () (EApp (EApp (EApp (EApp (EVar "CohImpl") (EVar "ir")) (EApp (EApp (EVar "cohFreshTys") (EVar "mctx")) (EVar "tys"))) (EApp (EVar "instRefMid") (EApp (EVar "ieRowInst") (EVar "r")))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstTyLocList") (EVar "tys"))) (EApp (EVar "ieRowLoc") (EVar "r")))))))
(DTypeSig false "cohPreludeOrd" (TyCon "Int"))
(DFunDef false "cohPreludeOrd" () (ELit (LInt 0)))
(DTypeSig false "cohPreludeRows" (TyFun (TyCon "ImplEnv") (TyApp (TyCon "List") (TyCon "ImplRow"))))
(DFunDef false "cohPreludeRows" ((PVar "env")) (EApp (EApp (EVar "ieRowsOwnedBy") (EVar "cohPreludeOrd")) (EVar "env")))
(DTypeSig false "cohRowsOf" (TyFun (TyCon "ImplEnv") (TyApp (TyCon "List") (TyCon "ImplRow"))))
(DFunDef false "cohRowsOf" ((PVar "env")) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EBinOp "/=" (EApp (EVar "ieRowOrd") (EVar "r")) (EVar "cohPreludeOrd")))) (EApp (EVar "ieRowsAll") (EVar "env"))))
(DTypeSig false "cohRowsOwnedBy" (TyFun (TyCon "Int") (TyFun (TyCon "ImplEnv") (TyApp (TyCon "List") (TyCon "ImplRow")))))
(DFunDef false "cohRowsOwnedBy" ((PVar "cur") (PVar "env")) (EIf (EBinOp "==" (EVar "cur") (EVar "cohPreludeOrd")) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EVar "ieRowsOwnedBy") (EVar "cur")) (EVar "env")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "cohSubsumes" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))
(DFunDef false "cohSubsumes" ((PVar "general") (PVar "specific")) (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "general")) (EApp (EVar "listLen") (EVar "specific"))) (EApp (EVar "isSome") (EApp (EApp (EApp (EApp (EApp (EVar "matchOneSided") (EVar "cohStep")) (ELam ((PVar "_a") (PVar "_b")) (EBinOp "==" (EVar "_a") (EVar "_b")))) (EVar "cohEqMono")) (EApp (EApp (EVar "zip") (EVar "general")) (EVar "specific"))) (EListLit))) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "cohStep" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyApp (TyApp (TyApp (TyCon "MStep") (TyCon "Int")) (TyCon "Mono")) (TyCon "Mono")))))
(DFunDef false "cohStep" ((PVar "g0") (PVar "s0")) (EBlock (DoLet false false (PVar "g") (EApp (EVar "peelQual") (EApp (EVar "normalize") (EVar "g0")))) (DoLet false false (PVar "s") (EApp (EVar "peelQual") (EApp (EVar "normalize") (EVar "s0")))) (DoExpr (EMatch (EVar "g") (arm (PCon "TVar" (PVar "c")) () (EApp (EVar "MVar") (EApp (EVar "tyvarId") (EVar "c")))) (arm (PCon "TCon" (PVar "a") (PVar "oa")) () (EMatch (EVar "s") (arm (PCon "TCon" (PVar "b") (PVar "ob")) () (EIf (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EVar "a")) (EVar "oa")) (EVar "b")) (EVar "ob")) (EVar "MOk") (EVar "MFail"))) (arm (PCon "TRigid" (PVar "b")) () (EIf (EBinOp "==" (EVar "a") (EVar "b")) (EVar "MOk") (EVar "MFail"))) (arm PWild () (EVar "MFail")))) (arm (PCon "TRigid" (PVar "a")) () (EMatch (EVar "s") (arm (PCon "TRigid" (PVar "b")) () (EIf (EBinOp "==" (EVar "a") (EVar "b")) (EVar "MOk") (EVar "MFail"))) (arm (PCon "TCon" (PVar "b") PWild) () (EIf (EBinOp "==" (EVar "a") (EVar "b")) (EVar "MOk") (EVar "MFail"))) (arm PWild () (EVar "MFail")))) (arm (PCon "TApp" (PVar "f1") (PVar "a1")) () (EMatch (EVar "s") (arm (PCon "TApp" (PVar "f2") (PVar "a2")) () (EApp (EVar "MKids") (EListLit (ETuple (EVar "f1") (EVar "f2")) (ETuple (EVar "a1") (EVar "a2"))))) (arm PWild () (EVar "MFail")))) (arm (PCon "TFun" (PVar "a1") PWild (PVar "b1")) () (EMatch (EVar "s") (arm (PCon "TFun" (PVar "a2") PWild (PVar "b2")) () (EApp (EVar "MKids") (EListLit (ETuple (EVar "a1") (EVar "a2")) (ETuple (EVar "b1") (EVar "b2"))))) (arm PWild () (EVar "MFail")))) (arm (PCon "TEff" PWild) () (EMatch (EVar "s") (arm (PCon "TEff" PWild) () (EVar "MOk")) (arm PWild () (EVar "MFail")))) (arm (PCon "TAuth" PWild) () (EMatch (EVar "s") (arm (PCon "TAuth" PWild) () (EVar "MOk")) (arm PWild () (EVar "MFail"))))))))
(DTypeSig false "cohStrictlyMoreSpecific" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))
(DFunDef false "cohStrictlyMoreSpecific" ((PVar "a") (PVar "b")) (EBinOp "&&" (EApp (EApp (EVar "cohSubsumes") (EVar "b")) (EVar "a")) (EApp (EVar "not") (EApp (EApp (EVar "cohSubsumes") (EVar "a")) (EVar "b")))))
(DTypeSig false "cohScan" (TyFun (TyCon "CohSweep") (TyFun (TyApp (TyCon "List") (TyCon "CohImpl")) (TyFun (TyApp (TyCon "List") (TyCon "CohImpl")) (TyCon "CohScan")))))
(DFunDef false "cohScan" ((PVar "sweep") (PVar "impls") (PVar "fixed")) (EApp (EApp (EApp (EApp (EVar "cohScanOuter") (EVar "sweep")) (EVar "impls")) (EVar "fixed")) (EApp (EApp (EVar "CohScan") (EVar "None")) (EVar "None"))))
(DTypeSig false "cohScanOuter" (TyFun (TyCon "CohSweep") (TyFun (TyApp (TyCon "List") (TyCon "CohImpl")) (TyFun (TyApp (TyCon "List") (TyCon "CohImpl")) (TyFun (TyCon "CohScan") (TyCon "CohScan"))))))
(DFunDef false "cohScanOuter" (PWild (PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "cohScanOuter" ((PVar "sweep") (PCons (PVar "e") (PVar "rest")) (PVar "fixed") (PVar "acc")) (EIf (EApp (EVar "cohScanDone") (EVar "acc")) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "cohScanOuter") (EVar "sweep")) (EVar "rest")) (EVar "fixed")) (EApp (EApp (EApp (EApp (EVar "cohScanInner") (EVar "sweep")) (EVar "e")) (EVar "fixed")) (EApp (EApp (EApp (EApp (EVar "cohScanInner") (EVar "sweep")) (EVar "e")) (EVar "rest")) (EVar "acc")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "cohScanDone" (TyFun (TyCon "CohScan") (TyCon "Bool")))
(DFunDef false "cohScanDone" ((PCon "CohScan" (PCon "Some" PWild) (PCon "Some" PWild))) (EVar "True"))
(DFunDef false "cohScanDone" (PWild) (EVar "False"))
(DTypeSig false "cohSameIface" (TyFun (TyCon "IfaceRef") (TyFun (TyCon "IfaceRef") (TyCon "Bool"))))
(DFunDef false "cohSameIface" ((PVar "a") (PVar "b")) (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EFieldAccess (EVar "a") "irName")) (EFieldAccess (EVar "a") "irOrigin")) (EFieldAccess (EVar "b") "irName")) (EFieldAccess (EVar "b") "irOrigin")))
(DTypeSig false "cohScanInner" (TyFun (TyCon "CohSweep") (TyFun (TyCon "CohImpl") (TyFun (TyApp (TyCon "List") (TyCon "CohImpl")) (TyFun (TyCon "CohScan") (TyCon "CohScan"))))))
(DFunDef false "cohScanInner" (PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "cohScanInner" ((PVar "sweep") (PAs "e1" (PCon "CohImpl" (PVar "if1") (PVar "xs") (PVar "mid1") PWild)) (PCons (PCon "CohImpl" (PVar "if2") (PVar "ys") (PVar "mid2") PWild) (PVar "rest")) (PVar "acc")) (EIf (EApp (EVar "cohScanDone") (EVar "acc")) (EVar "acc") (EIf (EBinOp "&&" (EApp (EApp (EVar "cohSameIface") (EVar "if1")) (EVar "if2")) (EApp (EApp (EVar "cohOverlap") (EVar "xs")) (EVar "ys"))) (EApp (EApp (EApp (EApp (EVar "cohScanInner") (EVar "sweep")) (EVar "e1")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "cohClassify") (EVar "sweep")) (EVar "e1")) (EVar "xs")) (EVar "ys")) (EVar "mid1")) (EVar "mid2")) (EVar "acc"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "cohScanInner") (EVar "sweep")) (EVar "e1")) (EVar "rest")) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "cohClassify" (TyFun (TyCon "CohSweep") (TyFun (TyCon "CohImpl") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "CohScan") (TyCon "CohScan")))))))))
(DFunDef false "cohClassify" ((PVar "sweep") (PVar "e1") (PVar "xs") (PVar "ys") (PVar "mid1") (PVar "mid2") (PCon "CohScan" (PVar "hard") (PVar "soft"))) (EIf (EApp (EApp (EVar "cohStrictlyMoreSpecific") (EVar "xs")) (EVar "ys")) (EApp (EApp (EVar "CohScan") (EVar "hard")) (EVar "soft")) (EIf (EApp (EApp (EVar "cohStrictlyMoreSpecific") (EVar "ys")) (EVar "xs")) (EApp (EApp (EVar "CohScan") (EVar "hard")) (EVar "soft")) (EIf (EBinOp "&&" (EApp (EApp (EVar "cohMutuallySubsumes") (EVar "xs")) (EVar "ys")) (EApp (EApp (EApp (EVar "cohHardInScope") (EVar "sweep")) (EVar "mid1")) (EVar "mid2"))) (EApp (EApp (EVar "CohScan") (EApp (EApp (EVar "cohKeepFirst") (EVar "hard")) (EApp (EVar "Some") (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "cohHardMsg") (EVar "e1")) (EVar "xs")) (EVar "ys")) (EVar "mid1")) (EVar "mid2")) (EApp (EVar "cohImplLoc") (EVar "e1")))))) (EVar "soft")) (EIf (EApp (EApp (EVar "cohMutuallySubsumes") (EVar "xs")) (EVar "ys")) (EApp (EApp (EVar "CohScan") (EVar "hard")) (EVar "soft")) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EVar "cohSoftInScope") (EVar "sweep")) (EVar "mid1")) (EVar "mid2"))) (EApp (EApp (EVar "CohScan") (EVar "hard")) (EVar "soft")) (EIf (EVar "otherwise") (EApp (EApp (EVar "CohScan") (EVar "hard")) (EApp (EApp (EVar "cohKeepFirst") (EVar "soft")) (EApp (EVar "Some") (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "cohIncomparableMsg") (EApp (EVar "cohImplIfaceName") (EVar "e1"))) (EVar "xs")) (EVar "ys")) (EVar "mid1")) (EVar "mid2")) (EApp (EVar "cohImplLoc") (EVar "e1")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "cohSoftInScope" (TyFun (TyCon "CohSweep") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "cohSoftInScope" ((PCon "CohSweepOwn") PWild PWild) (EVar "True"))
(DFunDef false "cohSoftInScope" ((PCon "CohSweepGlobal") (PLit (LString "")) (PLit (LString ""))) (EVar "True"))
(DFunDef false "cohSoftInScope" ((PCon "CohSweepGlobal") (PVar "mid1") (PVar "mid2")) (EApp (EApp (EVar "cohIsCrossModule") (EVar "mid1")) (EVar "mid2")))
(DTypeSig false "cohHardInScope" (TyFun (TyCon "CohSweep") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "cohHardInScope" ((PVar "sweep") (PVar "mid1") (PVar "mid2")) (EApp (EApp (EApp (EVar "cohSoftInScope") (EVar "sweep")) (EVar "mid1")) (EVar "mid2")))
(DTypeSig false "cohMutuallySubsumes" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))
(DFunDef false "cohMutuallySubsumes" ((PVar "xs") (PVar "ys")) (EBinOp "&&" (EApp (EApp (EVar "cohSubsumes") (EVar "xs")) (EVar "ys")) (EApp (EApp (EVar "cohSubsumes") (EVar "ys")) (EVar "xs"))))
(DTypeSig false "cohKeepFirst" (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "cohKeepFirst" ((PCon "Some" (PVar "x")) PWild) (EApp (EVar "Some") (EVar "x")))
(DFunDef false "cohKeepFirst" ((PCon "None") (PVar "y")) (EVar "y"))
(DTypeSig false "cohHardMsg" (TyFun (TyCon "CohImpl") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))))
(DFunDef false "cohHardMsg" ((PVar "e1") (PVar "xs") (PVar "ys") (PVar "mid1") (PVar "mid2")) (EIf (EApp (EApp (EVar "cohPairsPrelude") (EVar "mid1")) (EVar "mid2")) (EApp (EApp (EApp (EVar "cohPreludeOverlapMsg") (EApp (EVar "cohImplIfaceName") (EVar "e1"))) (EVar "xs")) (EVar "ys")) (EIf (EApp (EApp (EVar "cohIsCrossModule") (EVar "mid1")) (EVar "mid2")) (EApp (EApp (EApp (EVar "cohCrossModuleMsg") (EApp (EVar "cohImplIfaceName") (EVar "e1"))) (EVar "mid1")) (EVar "mid2")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "cohOverlapMsg") (EApp (EVar "cohImplIfaceName") (EVar "e1"))) (EVar "xs")) (EVar "ys")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "cohPreludeMid" (TyCon "String"))
(DFunDef false "cohPreludeMid" () (ELit (LString "core")))
(DTypeSig false "cohPairsPrelude" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "cohPairsPrelude" ((PVar "mid1") (PVar "mid2")) (EBinOp "||" (EBinOp "==" (EVar "mid1") (EVar "cohPreludeMid")) (EBinOp "==" (EVar "mid2") (EVar "cohPreludeMid"))))
(DTypeSig false "cohIsCrossModule" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "cohIsCrossModule" ((PVar "mid1") (PVar "mid2")) (EBinOp "&&" (EBinOp "&&" (EBinOp "/=" (EVar "mid1") (ELit (LString ""))) (EBinOp "/=" (EVar "mid2") (ELit (LString "")))) (EBinOp "/=" (EVar "mid1") (EVar "mid2"))))
(DTypeSig false "cohIncomparableMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))))
(DFunDef false "cohIncomparableMsg" ((PVar "iface") (PVar "xs") (PVar "ys") (PVar "mid1") (PVar "mid2")) (EMatch (EApp (EApp (EVar "cohPpPair") (EVar "xs")) (EVar "ys")) (arm (PTuple (PVar "s1") (PVar "s2")) () (EIf (EApp (EApp (EVar "cohPairsPrelude") (EVar "mid1")) (EVar "mid2")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Warning: overlapping impls of ")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString ": neither "))) (EApp (EVar "display") (EVar "s1"))) (ELit (LString " nor the prelude's "))) (EApp (EVar "display") (EVar "s2"))) (ELit (LString " is more specific than the other, so a goal matching both has no impl to pick"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Warning: overlapping impls of ")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EApp (EVar "cohWhereSuffix") (EVar "mid1")) (EVar "mid2")))) (ELit (LString ": neither "))) (EApp (EVar "display") (EVar "s1"))) (ELit (LString " nor "))) (EApp (EVar "display") (EVar "s2"))) (ELit (LString " is more specific than the other, so a goal matching both has no impl to pick")))))))
(DTypeSig false "cohWhereSuffix" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "cohWhereSuffix" ((PVar "mid1") (PVar "mid2")) (EIf (EApp (EApp (EVar "cohIsCrossModule") (EVar "mid1")) (EVar "mid2")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " (defined in `")) (EApp (EVar "display") (EVar "mid2"))) (ELit (LString "` and `"))) (EApp (EVar "display") (EVar "mid1"))) (ELit (LString "`)"))) (EIf (EVar "otherwise") (ELit (LString "")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "cohImplIface" (TyFun (TyCon "CohImpl") (TyCon "IfaceRef")))
(DFunDef false "cohImplIface" ((PCon "CohImpl" (PVar "i") PWild PWild PWild)) (EVar "i"))
(DTypeSig false "cohImplIfaceName" (TyFun (TyCon "CohImpl") (TyCon "String")))
(DFunDef false "cohImplIfaceName" ((PVar "e")) (EFieldAccess (EApp (EVar "cohImplIface") (EVar "e")) "irName"))
(DTypeSig false "cohImplLoc" (TyFun (TyCon "CohImpl") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "cohImplLoc" ((PCon "CohImpl" PWild PWild PWild (PVar "l"))) (EVar "l"))
(DTypeSig false "pushCoherenceWarning" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyCon "Unit")))))
(DFunDef false "pushCoherenceWarning" ((PVar "mctx") (PVar "loc") (PVar "msg")) (EBlock (DoLet false false (PVar "warning") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "W-INCOMPARABLE-IMPLS"))) (ELit (LInt 2))) (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EFieldAccess (EVar "mctx") "mcLoc"))) (EVar "msg")) (EApp (EVar "Some") (EVar "cohIncomparableHelp"))) (EVar "None"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchWarnings")) (EBinOp "::" (EVar "warning") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchWarnings") "value"))))))
(DTypeSig true "checkCoherence" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ImplEnv") (TyFun (TyCon "Int") (TyCon "Unit")))))
(DFunDef false "checkCoherence" ((PVar "mctx") (PVar "env") (PVar "cur")) (EMatch (EApp (EApp (EApp (EVar "cohScan") (EVar "CohSweepOwn")) (EApp (EVar "reverse") (EApp (EApp (EVar "map") (EApp (EVar "cohImplOfRow") (EVar "mctx"))) (EApp (EApp (EVar "cohRowsOwnedBy") (EVar "cur")) (EVar "env"))))) (EApp (EApp (EVar "map") (EApp (EVar "cohImplOfRow") (EVar "mctx"))) (EApp (EVar "cohPreludeRows") (EVar "env")))) (arm (PCon "CohScan" (PVar "hard") (PVar "soft")) () (EBlock (DoExpr (EApp (EApp (EVar "cohPushHard") (EVar "mctx")) (EVar "hard"))) (DoExpr (EApp (EApp (EVar "cohPushSoft") (EVar "mctx")) (EVar "soft")))))))
(DTypeSig false "cohPushHard" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyCon "Unit"))))
(DFunDef false "cohPushHard" ((PVar "mctx") (PCon "None")) (ELit LUnit))
(DFunDef false "cohPushHard" ((PVar "mctx") (PCon "Some" (PTuple (PVar "msg") (PVar "loc")))) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (ELit (LString "T-CONFLICTING-IMPL"))) (EVar "loc")) (EVar "msg")))
(DTypeSig false "cohPushSoft" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyCon "Unit"))))
(DFunDef false "cohPushSoft" ((PVar "mctx") (PCon "None")) (ELit LUnit))
(DFunDef false "cohPushSoft" ((PVar "mctx") (PCon "Some" (PTuple (PVar "msg") (PVar "loc")))) (EApp (EApp (EApp (EVar "pushCoherenceWarning") (EVar "mctx")) (EVar "loc")) (EVar "msg")))
(DTypeSig true "checkSuperImpls" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "ClassEnv") (TyFun (TyCon "ImplEnv") (TyFun (TyCon "Int") (TyCon "Unit")))))))
(DFunDef false "checkSuperImpls" ((PVar "mctx") (PVar "userDecls") (PVar "ce") (PVar "ie") (PVar "cur")) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EVar "ieRowsVisibleAt") (EVar "cur")) (EVar "ie"))) (DoExpr (EApp (EApp (EVar "each") (EApp (EApp (EApp (EApp (EApp (EVar "checkImplSuperContexts") (EVar "mctx")) (EVar "userDecls")) (EVar "ce")) (EVar "cur")) (EVar "rows"))) (EVar "userDecls")))))
(DTypeSig false "checkImplSuperContexts" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyCon "Decl") (TyCon "Unit"))))))))
(DFunDef false "checkImplSuperContexts" ((PVar "mctx") (PVar "decls") (PVar "ce") (PVar "cur") (PVar "rows") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkImplSuperContexts") (EVar "mctx")) (EVar "decls")) (EVar "ce")) (EVar "cur")) (EVar "rows")) (EVar "d")))
(DFunDef false "checkImplSuperContexts" ((PVar "mctx") (PVar "decls") (PVar "ce") (PVar "cur") (PVar "rows") (PRec "DImpl" ((rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "implOrigin" (PVar "o")) (rf "implIfaceLoc" (PVar "ifaceLoc"))) true)) (EBlock (DoLet false false (PVar "derived") (EApp (EVar "isNone") (EVar "ifaceLoc"))) (DoLet false false (PVar "loc") (EIf (EVar "derived") (EApp (EApp (EVar "derivedImplDeclLoc") (EVar "decls")) (EVar "tys")) (EVar "ifaceLoc"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "ceLookupAt") (EApp (EVar "regKeyOfTab") (EApp (EApp (EVar "ifaceTabKey") (EVar "o")) (EVar "iface")))) (EVar "cur")) (EVar "ce")) (arm (PCon "Some" (PVar "r")) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EApp (EVar "ceRowTyparams") (EVar "r"))) (EApp (EVar "listLen") (EVar "tys"))))) (EBlock (DoLet false false (PTuple (PVar "implTvMap") (PVar "headMonos")) (EApp (EApp (EVar "implHeadMonos") (EVar "mctx")) (EVar "tys"))) (DoLet false false (PVar "roots") (EApp (EVar "implHeadTypeVarRoots") (EVar "implTvMap"))) (DoLet false false (PVar "headIds") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EVar "intToString") (EApp (EVar "snd") (EVar "p"))))) (EVar "roots"))) (EVar "omEmpty"))) (DoLet false false (PVar "declared") (EApp (EApp (EVar "map") (EApp (EApp (EVar "requirePredicateSlot") (EVar "mctx")) (EVar "implTvMap"))) (EVar "reqs"))) (DoLet false false (PVar "givens") (EBinOp "++" (EVar "declared") (EApp (EApp (EVar "flatMap") (ELam ((PVar "s")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EVar "predicateSlotKnownSupers") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "s"))))) (EVar "declared")))) (DoLet false false (PVar "subject") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "impl ")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "join") (ELit (LString " "))) (EApp (EApp (EVar "map") (EVar "ppTyAtom")) (EVar "tys"))))) (ELit (LString "")))) (DoLet false false (PVar "subst") (EApp (EApp (EVar "zip") (EApp (EVar "ceRowTyparams") (EVar "r"))) (EVar "tys"))) (DoLet false false (PVar "argsOf") (ELam ((PVar "sup")) (EApp (EApp (EVar "mapAll") (ELam ((PVar "p")) (EApp (EApp (EApp (EVar "lookupPos") (EVar "p")) (EApp (EVar "ceRowTyparams") (EVar "r"))) (EVar "headMonos")))) (EApp (EVar "superParamsOf") (EVar "sup"))))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "sup")) (EMatch (EApp (EVar "argsOf") (EVar "sup")) (arm (PCon "Some" (PVar "supArgs")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkSuperInstanceContext") (EVar "mctx")) (EVar "subject")) (EVar "roots")) (EVar "headIds")) (EVar "givens")) (EVar "loc")) (EVar "derived")) (EApp (EVar "superIfaceRef") (EVar "sup"))) (EVar "supArgs")) (ELam (PWild) (EApp (EApp (EApp (EVar "superRowExists") (EVar "rows")) (EVar "subst")) (EVar "sup"))))) (arm (PCon "None") () (ELit LUnit))))) (ELit LUnit)) (EApp (EVar "ceRowSupers") (EVar "r")))))) (arm PWild () (ELit LUnit))))))
(DFunDef false "checkImplSuperContexts" ((PVar "mctx") PWild PWild PWild PWild PWild) (ELit LUnit))
(DTypeSig false "derivedImplDeclLoc" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "derivedImplDeclLoc" ((PVar "decls") (PVar "tys")) (EMatch (EApp (EApp (EVar "flatMap") (EVar "tyConNamesInTy")) (EVar "tys")) (arm (PList (PVar "n")) () (EMatch (EApp (EApp (EVar "flatMap") (EApp (EVar "declNameLocs") (EVar "n"))) (EVar "decls")) (arm (PCons (PVar "l") PWild) () (EApp (EVar "Some") (EVar "l"))) (arm (PList) () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig false "declNameLocs" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Loc")))))
(DFunDef false "declNameLocs" ((PVar "n") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "declNameLocs") (EVar "n")) (EVar "d")))
(DFunDef false "declNameLocs" ((PVar "n") (PRec "DData" ((rf "dataName" None) (rf "dataNameLoc" (PCon "Some" (PVar "l")))) true)) (EIf (EBinOp "==" (EVar "dataName") (EVar "n")) (EListLit (EVar "l")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "declNameLocs" ((PVar "n") (PRec "DNewtype" ((rf "newtypeName" None) (rf "newtypeNameLoc" (PCon "Some" (PVar "l")))) true)) (EIf (EBinOp "==" (EVar "newtypeName") (EVar "n")) (EListLit (EVar "l")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "declNameLocs" (PWild PWild) (EListLit))
(DTypeSig false "checkSuperInstanceContext" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "PredicateSlot")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Bool") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyFun (TyCon "Unit") (TyCon "Bool")) (TyCon "Unit"))))))))))))
(DFunDef false "checkSuperInstanceContext" ((PVar "mctx") (PVar "subject") (PVar "roots") (PVar "headIds") (PVar "givens") (PVar "loc") (PVar "derived") (PVar "sup") (PVar "supArgs") (PVar "covered")) (EIf (EApp (EApp (EVar "anyList") (EApp (EApp (EVar "givenAnswers") (EVar "sup")) (EVar "supArgs"))) (EVar "givens")) (ELit LUnit) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EApp (EVar "rigidHeadInstanceContext") (EApp (EVar "siteFor") (EVar "mctx"))) (EVar "headIds")) (EVar "sup")) (EVar "supArgs")) (arm (PCon "None") () (EIf (EApp (EVar "not") (EApp (EVar "covered") (ELit LUnit))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reportMissingSuperImpl") (EVar "mctx")) (EVar "subject")) (EVar "roots")) (EVar "loc")) (EVar "derived")) (EVar "sup")) (EVar "supArgs")) (ELit LUnit))) (arm (PCon "Some" (PVar "ctx")) () (EBlock (DoLet false false (PVar "walk") (EApp (EVar "reqWalkStart") (ELit LUnit))) (DoLet false false (PVar "leaves") (EApp (EApp (EVar "flatMap") (ELam ((PVar "g")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "superContextLeaves") (EVar "mctx")) (EVar "walk")) (EVar "headIds")) (EVar "givens")) (EVar "loc")) (EApp (EVar "fst") (EVar "g"))) (EApp (EVar "snd") (EVar "g"))))) (EVar "ctx"))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "leaf")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reportSuperContextLeaf") (EVar "mctx")) (EVar "subject")) (EVar "roots")) (EVar "loc")) (EVar "derived")) (EVar "sup")) (EVar "supArgs")) (EVar "leaf")))) (ELit LUnit)) (EVar "leaves")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "superRowExists" (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Super") (TyCon "Bool")))))
(DFunDef false "superRowExists" ((PVar "rows") (PVar "subst") (PRec "Super" ((rf "superHead" (PVar "n")) (rf "superParams" (PVar "ps")) (rf "superOrigin" (PVar "so"))) false)) (EBlock (DoLet false false (PVar "tys") (EApp (EApp (EVar "substParams") (EVar "ps")) (EVar "subst"))) (DoExpr (EBinOp "||" (EBinOp "/=" (EApp (EVar "listLen") (EVar "tys")) (EApp (EVar "listLen") (EVar "ps"))) (EApp (EApp (EApp (EApp (EVar "superImplExists") (EVar "rows")) (EApp (EApp (EVar "ifaceTabKey") (EVar "so")) (EVar "n"))) (EVar "n")) (EVar "tys"))))))
(DTypeSig false "reportMissingSuperImpl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Bool") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Unit")))))))))
(DFunDef false "reportMissingSuperImpl" ((PVar "mctx") (PVar "subject") (PVar "roots") (PVar "loc") (PVar "derived") (PVar "sup") (PVar "supArgs")) (EBlock (DoLet false false (PVar "named") (EApp (EVar "Ref") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (ETuple (EApp (EVar "snd") (EVar "p")) (EApp (EVar "fst") (EVar "p"))))) (EVar "roots")))) (DoLet false false (PVar "goal") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "sup") "irName"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "join") (ELit (LString " "))) (EApp (EApp (EApp (EApp (EVar "ppEach") (EVar "named")) (EApp (EVar "Ref") (ELit (LInt 0)))) (ELit (LInt 3))) (EVar "supArgs"))))) (ELit (LString "")))) (DoLet false false (PVar "missing") (EBinOp "++" (EBinOp "++" (ELit (LString "requires the superinterface `")) (EApp (EVar "display") (EVar "goal"))) (ELit (LString "`, which no impl covers")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-MISSING-SUPER-IMPL"))) (EVar "loc")) (EIf (EApp (EVar "not") (EVar "derived")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "subject"))) (ELit (LString "` "))) (EApp (EVar "display") (EVar "missing"))) (ELit (LString "; add an `impl "))) (EApp (EVar "display") (EVar "goal"))) (ELit (LString "` covering it, or add `requires "))) (EApp (EVar "display") (EVar "goal"))) (ELit (LString "` to the impl"))) (EIf (EApp (EVar "derivableIface") (EFieldAccess (EVar "sup") "irName")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "subject"))) (ELit (LString "` (derived) "))) (EApp (EVar "display") (EVar "missing"))) (ELit (LString "; add `"))) (EApp (EVar "display") (EFieldAccess (EVar "sup") "irName"))) (ELit (LString "` to the type's `deriving` clause, or add an `impl "))) (EApp (EVar "display") (EVar "goal"))) (ELit (LString "`"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "subject"))) (ELit (LString "` (derived) "))) (EApp (EVar "display") (EVar "missing"))) (ELit (LString "; add an `impl "))) (EApp (EVar "display") (EVar "goal"))) (ELit (LString "`")))))))))
(DTypeSig false "superContextLeaves" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ReqWalk") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "PredicateSlot")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))))))))))))
(DFunDef false "superContextLeaves" ((PVar "mctx") (PVar "walk") (PVar "headIds") (PVar "givens") (PVar "loc") (PVar "iface") (PVar "args")) (EIf (EApp (EApp (EVar "anyList") (EApp (EApp (EVar "givenAnswers") (EVar "iface")) (EVar "args"))) (EVar "givens")) (EListLit) (EIf (EApp (EVar "not") (EApp (EVar "anyConcreteHead") (EVar "args"))) (EListLit (ETuple (EVar "iface") (EVar "args"))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "reqWalkReported") (EVar "mctx")) (EVar "loc")) (EApp (EApp (EApp (EVar "reqWalkEnter") (EVar "walk")) (EVar "iface")) (EVar "args"))) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "next")) () (EApp (EApp (EApp (EApp (EApp (EVar "solvedOnWalk") (EVar "mctx")) (EVar "next")) (EVar "iface")) (EVar "args")) (ELam (PWild) (EMatch (EApp (EApp (EApp (EApp (EVar "rigidHeadInstanceContext") (EApp (EVar "siteFor") (EVar "mctx"))) (EVar "headIds")) (EVar "iface")) (EVar "args")) (arm (PCon "None") () (EListLit (ETuple (EVar "iface") (EVar "args")))) (arm (PCon "Some" (PVar "ctx")) () (EApp (EApp (EVar "flatMap") (ELam ((PVar "g")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "superContextLeaves") (EVar "mctx")) (EVar "next")) (EVar "headIds")) (EVar "givens")) (EVar "loc")) (EApp (EVar "fst") (EVar "g"))) (EApp (EVar "snd") (EVar "g"))))) (EVar "ctx")))))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "reportSuperContextLeaf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Bool") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))) (TyCon "Unit"))))))))))
(DFunDef false "reportSuperContextLeaf" ((PVar "mctx") (PVar "subject") (PVar "roots") (PVar "loc") (PVar "derived") (PVar "sup") (PVar "supArgs") (PTuple (PVar "iface") (PVar "args"))) (EBlock (DoLet false false (PVar "ids") (EApp (EApp (EVar "flatMap") (EVar "monoUnboundIds")) (EVar "args"))) (DoLet false false (PVar "named") (EApp (EVar "Ref") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (ETuple (EApp (EVar "snd") (EVar "p")) (EApp (EVar "fst") (EVar "p"))))) (EVar "roots")))) (DoLet false false (PVar "argsText") (EApp (EApp (EVar "join") (ELit (LString " "))) (EApp (EApp (EApp (EApp (EVar "ppEach") (EVar "named")) (EApp (EVar "Ref") (ELit (LInt 0)))) (ELit (LInt 3))) (EVar "args")))) (DoLet false false (PVar "superGoal") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "qualifiedIfaceLabel") (EVar "sup")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "join") (ELit (LString " "))) (EApp (EApp (EApp (EApp (EVar "ppEach") (EVar "named")) (EApp (EVar "Ref") (ELit (LInt 0)))) (ELit (LInt 3))) (EVar "supArgs"))))) (ELit (LString "")))) (DoLet false false (PVar "pred") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "qualifiedIfaceLabel") (EVar "iface")))) (ELit (LString " "))) (EApp (EVar "display") (EVar "argsText"))) (ELit (LString "")))) (DoLet false false (PVar "predBare") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "iface") "irName"))) (ELit (LString " "))) (EApp (EVar "display") (EVar "argsText"))) (ELit (LString "")))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "ids")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-NO-IMPL"))) (EVar "loc")) (EApp (EApp (EApp (EApp (EApp (EVar "superContextNoImplMsg") (EVar "subject")) (EVar "derived")) (EVar "superGoal")) (EVar "pred")) (EVar "predBare"))) (EIf (EApp (EApp (EVar "allList") (ELam ((PVar "i")) (EApp (EApp (EVar "containsI") (EVar "i")) (EApp (EApp (EVar "map") (EVar "snd")) (EVar "roots"))))) (EVar "ids")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-IMPL-MISSING-REQUIRES"))) (EVar "loc")) (EApp (EApp (EApp (EApp (EApp (EVar "superContextUndeclaredMsg") (EVar "subject")) (EVar "derived")) (EVar "superGoal")) (EVar "pred")) (EVar "predBare"))) (ELit LUnit))))))
(DTypeSig false "pushIncompleteImpl" (TyFun (TyCon "ModuleCtx") (TyFun (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "pushIncompleteImpl" ((PVar "mctx") (PTuple (PVar "loc") (PVar "msg"))) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-INCOMPLETE-IMPL"))) (EVar "loc")) (EVar "msg")))
(DTypeSig false "firstImplMethodLoc" (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "firstImplMethodLoc" ((PList)) (EVar "None"))
(DFunDef false "firstImplMethodLoc" ((PCons (PCon "ImplMethod" PWild PWild (PVar "body")) PWild)) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "exprLoc") (EVar "body"))) (EApp (EVar "appArgLoc") (EVar "body"))))
(DTypeSig true "checkImplCompletenessMap" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))))
(DFunDef false "checkImplCompletenessMap" ((PVar "mctx") (PVar "ce") (PVar "cur") (PVar "iterDecls")) (EApp (EApp (EVar "each") (EApp (EVar "pushIncompleteImpl") (EVar "mctx"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "implCompletenessMsgsOfMap") (EVar "ce")) (EVar "cur"))) (EVar "iterDecls"))))
(DTypeSig false "implCompletenessMsgsOfMap" (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))))))
(DFunDef false "implCompletenessMsgsOfMap" ((PVar "ce") (PVar "cur") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EVar "implCompletenessMsgsOfMap") (EVar "ce")) (EVar "cur")) (EVar "d")))
(DFunDef false "implCompletenessMsgsOfMap" ((PVar "ce") (PVar "cur") (PRec "DImpl" ((rf "iface" None) (rf "tys" None) (rf "methods" None) (rf "implOrigin" (PVar "o")) (rf "implIfaceLoc" (PVar "ifaceLoc"))) true)) (EMatch (EApp (EApp (EApp (EVar "ceRequiredAt") (EApp (EVar "regKeyOfTab") (EApp (EApp (EVar "ifaceTabKey") (EVar "o")) (EVar "iface")))) (EVar "cur")) (EVar "ce")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "required")) () (EBlock (DoLet false false (PVar "defined") (EApp (EApp (EVar "map") (EVar "implMethodName")) (EVar "methods"))) (DoLet false false (PVar "loc") (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstImplMethodLoc") (EVar "methods"))) (EVar "ifaceLoc"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "m")) (ETuple (EVar "loc") (EApp (EApp (EApp (EVar "missingImplMethodMsg") (EVar "iface")) (EVar "tys")) (EVar "m"))))) (EApp (EApp (EVar "filter") (ELam ((PVar "m")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "m")) (EVar "defined"))))) (EVar "required"))))))))
(DFunDef false "implCompletenessMsgsOfMap" (PWild PWild PWild) (EListLit))
(DTypeSig true "checkPhantomMethods" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyCon "Unit")))))
(DFunDef false "checkPhantomMethods" ((PVar "mctx") (PVar "ce") (PVar "cur")) (EApp (EApp (EVar "each") (ELam ((PTuple (PVar "loc") (PVar "msg"))) (EApp (EApp (EApp (EVar "pushTypeError") (EApp (EApp (EVar "mctxAtIfSome") (EVar "loc")) (EVar "mctx"))) (ELit (LString "T-PHANTOM-METHOD"))) (EVar "msg")))) (EApp (EApp (EVar "flatMap") (EVar "phantomMethodMsgs")) (EApp (EApp (EVar "ceRowsOwnedBy") (EVar "cur")) (EVar "ce")))))
(DTypeSig false "phantomMethodMsgs" (TyFun (TyCon "CeRow") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))))
(DFunDef false "phantomMethodMsgs" ((PVar "r")) (EApp (EApp (EVar "map") (ELam ((PVar "m")) (ETuple (EApp (EApp (EVar "orElseLoc") (EApp (EVar "fst") (EVar "m"))) (EApp (EVar "ceRowLoc") (EVar "r"))) (EApp (EVar "snd") (EVar "m"))))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "phantomMethodMsg") (EApp (EVar "ceRowIfaceName") (EVar "r"))) (EApp (EVar "ceRowTyparams") (EVar "r")))) (EApp (EVar "ceRowMethods") (EVar "r")))))
(DTypeSig false "phantomMethodMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind"))))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))))))
(DFunDef false "phantomMethodMsg" ((PVar "ifaceName") (PVar "typarams") (PTuple (PVar "mname") (PVar "mty") PWild)) (EIf (EApp (EVar "isEmptyL") (EVar "typarams")) (EListLit) (EIf (EApp (EApp (EVar "anyMember") (EApp (EVar "tyVarNames") (EVar "mty"))) (EVar "typarams")) (EListLit) (EBlock (DoLet false false (PVar "noun") (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "typarams")) (ELit (LInt 1))) (ELit (LString "parameter")) (ELit (LString "parameters")))) (DoExpr (EListLit (ETuple (EApp (EVar "firstTyLoc") (EVar "mty")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "method `")) (EApp (EVar "display") (EVar "mname"))) (ELit (LString "` of interface `"))) (EApp (EVar "display") (EVar "ifaceName"))) (ELit (LString "` does not mention the interface "))) (EApp (EVar "display") (EVar "noun"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "join") (ELit (LString ", "))) (EApp (EApp (EVar "map") (ELam ((PVar "t")) (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EVar "backticked") (EVar "t"))) (ELit (LString "'"))))) (EVar "typarams"))))) (ELit (LString ", so it cannot be dispatched"))))))))))
(DTypeSig false "substParams" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyApp (TyCon "List") (TyCon "Ty")))))
(DFunDef false "substParams" ((PList) PWild) (EListLit))
(DFunDef false "substParams" ((PCons (PVar "p") (PVar "rest")) (PVar "subst")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "p")) (EVar "subst")) (arm (PCon "Some" (PVar "t")) () (EBinOp "::" (EVar "t") (EApp (EApp (EVar "substParams") (EVar "rest")) (EVar "subst")))) (arm (PCon "None") () (EApp (EApp (EVar "substParams") (EVar "rest")) (EVar "subst")))))
(DTypeSig false "superImplExists" (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyCon "TabKey") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Bool"))))))
(DFunDef false "superImplExists" ((PVar "rows") (PVar "superKey") (PVar "superName") (PVar "goal")) (EApp (EApp (EVar "anyList") (EApp (EApp (EApp (EVar "implRowMatchesSuper") (EVar "superKey")) (EVar "superName")) (EVar "goal"))) (EVar "rows")))
(DTypeSig false "implRowMatchesSuper" (TyFun (TyCon "TabKey") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyCon "ImplRow") (TyCon "Bool"))))))
(DFunDef false "implRowMatchesSuper" ((PVar "superKey") (PVar "superName") (PVar "goal") (PCon "ImplRow" PWild PWild (PVar "ir") (PVar "tys") PWild PWild PWild)) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "ir") "irName") (EVar "superName")) (EBinOp "==" (EApp (EVar "listLen") (EVar "tys")) (EApp (EVar "listLen") (EVar "goal")))) (EBinOp "==" (EApp (EApp (EVar "ifaceTabKey") (EFieldAccess (EVar "ir") "irOrigin")) (EFieldAccess (EVar "ir") "irName")) (EVar "superKey"))) (EApp (EApp (EVar "superHeadCovers") (EVar "tys")) (EVar "goal"))))
(DTypeSig false "superHeadCovers" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Bool"))))
(DFunDef false "superHeadCovers" ((PVar "pats") (PVar "goal")) (EApp (EVar "isSome") (EApp (EApp (EApp (EApp (EApp (EVar "matchOneSided") (EVar "superHeadStep")) (ELam ((PVar "_a") (PVar "_b")) (EBinOp "==" (EVar "_a") (EVar "_b")))) (EVar "tyStructEq")) (EApp (EApp (EVar "zip") (EVar "pats")) (EVar "goal"))) (EListLit))))
(DTypeSig false "superHeadStep" (TyFun (TyCon "Ty") (TyFun (TyCon "Ty") (TyApp (TyApp (TyApp (TyCon "MStep") (TyCon "String")) (TyCon "Ty")) (TyCon "Ty")))))
(DFunDef false "superHeadStep" ((PVar "pat") (PVar "t")) (EApp (EApp (EVar "tyStep") (EVar "pat")) (EApp (EVar "stripTyWrap") (EVar "t"))))
(DTypeSig true "globalCoherenceConflict" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ImplEnv") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "globalCoherenceConflict" ((PVar "mctx") (PVar "env")) (EMatch (EApp (EApp (EApp (EVar "cohScan") (EVar "CohSweepGlobal")) (EApp (EVar "reverse") (EApp (EApp (EVar "map") (EApp (EVar "cohImplOfRow") (EVar "mctx"))) (EApp (EVar "cohRowsOf") (EVar "env"))))) (EListLit)) (arm (PCon "CohScan" (PVar "hard") (PVar "soft")) () (ETuple (EApp (EApp (EVar "map") (EVar "fst")) (EVar "hard")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "soft"))))))
(DTypeSig true "implHeadGround" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "implHeadGround" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "implHeadGround") (EVar "d")))
(DFunDef false "implHeadGround" ((PRec "DImpl" ((rf "tys" None)) true)) (EApp (EVar "isEmptyL") (EApp (EApp (EVar "flatMap") (EVar "tyVarNames")) (EVar "tys"))))
(DFunDef false "implHeadGround" (PWild) (EVar "False"))
(DTypeSig true "implHeadParametric" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "implHeadParametric" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "implHeadParametric") (EVar "d")))
(DFunDef false "implHeadParametric" ((PRec "DImpl" ((rf "tys" None)) true)) (EApp (EVar "isNonEmptyL") (EApp (EApp (EVar "flatMap") (EVar "tyVarNames")) (EVar "tys"))))
(DFunDef false "implHeadParametric" (PWild) (EVar "False"))
(DTypeSig true "inferDefaultBodies" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "inferDefaultBodies" ((PVar "env") (PList)) (ELit LUnit))
(DFunDef false "inferDefaultBodies" ((PVar "env") (PCons (PVar "d") (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EVar "inferOneIfaceDefaults") (EVar "env")) (EVar "d"))) (DoExpr (EApp (EApp (EVar "inferDefaultBodies") (EVar "env")) (EVar "rest")))))
(DTypeSig false "inferOneIfaceDefaults" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Decl") (TyCon "Unit"))))
(DFunDef false "inferOneIfaceDefaults" ((PVar "env") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "inferOneIfaceDefaults") (EVar "env")) (EVar "d")))
(DFunDef false "inferOneIfaceDefaults" ((PVar "env") (PRec "DInterface" ((rf "name" None) (rf "typarams" None) (rf "typaramKinds" None) (rf "methods" None) (rf "ifaceOrigin" None)) true)) (EBlock (DoLet false false (PVar "dscope") (EApp (EApp (EApp (EApp (EVar "declGradedScope") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "typarams")) (EVar "typaramKinds")) (EVar "methods"))) (DoLet false false (PVar "ifaceSchemes") (EApp (EApp (EApp (EVar "methodSchemesPure") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "dscope")) (EVar "methods"))) (DoLet false false (PVar "iface") (ERecordCreate "IfaceRef" ((fa "irName" (EVar "name")) (fa "irOrigin" (EVar "ifaceOrigin"))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "inferDefaultMethods") (EApp (EApp (EVar "extendVars") (EVar "env")) (EVar "ifaceSchemes"))) (EVar "iface")) (EVar "dscope")) (EVar "typarams")) (EVar "methods")))))
(DFunDef false "inferOneIfaceDefaults" ((PVar "env") PWild) (ELit LUnit))
(DTypeSig false "inferDefaultMethods" (TyFun (TyCon "TcEnv") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyCon "Unit")))))))
(DFunDef false "inferDefaultMethods" ((PVar "env") PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "inferDefaultMethods" ((PVar "env") (PVar "iface") (PVar "dscope") (PVar "typarams") (PCons (PVar "m") (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "inferDefaultMethod") (EVar "env")) (EVar "iface")) (EVar "dscope")) (EVar "typarams")) (EVar "m"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "inferDefaultMethods") (EVar "env")) (EVar "iface")) (EVar "dscope")) (EVar "typarams")) (EVar "rest")))))
(DTypeSig false "inferDefaultMethod" (TyFun (TyCon "TcEnv") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyCon "Unit")))))))
(DFunDef false "inferDefaultMethod" ((PVar "env") (PVar "iface") (PVar "dscope") (PVar "typarams") (PCon "IfaceMethod" (PVar "mname") (PVar "mty") (PCon "Some" (PCon "MethodDefault" (PVar "pats") (PVar "body"))) PWild)) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferMethodBody") (EVar "env")) (EVar "iface")) (EVar "DefaultBody")) (ETuple (EVar "typarams") (EVar "mty") (EVar "dscope"))) (EVar "mname")) (EVar "pats")) (EVar "body")))
(DFunDef false "inferDefaultMethod" ((PVar "env") PWild PWild PWild PWild) (ELit LUnit))
(DTypeSig true "nestedRequireGoals" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyApp (TyCon "List") (TyCon "UObligation")))))))
(DFunDef false "nestedRequireGoals" ((PVar "mctx") (PVar "rigidIds") (PVar "liveIds") (PVar "obls")) (EBlock (DoLet false false (PVar "seeds") (EApp (EApp (EVar "requireGoalSeeds") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "obls"))) (DoLet false false (PVar "goals") (EApp (EApp (EApp (EApp (EVar "nestedRequireGoalsOnce") (EVar "mctx")) (EVar "rigidIds")) (EVar "liveIds")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "followRequireGoal") (EVar "mctx")) (EVar "rigidIds")) (EVar "liveIds"))) (EVar "seeds")))) (DoExpr (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "s")) (EFieldAccess (EFieldAccess (EApp (EVar "reqWalkMemo") (EApp (EVar "snd") (EVar "s"))) "wmStopped") "value"))) (EVar "seeds")) (EApp (EApp (EApp (EApp (EVar "nestedRequireGoalsGo") (EVar "mctx")) (EVar "rigidIds")) (EVar "liveIds")) (EApp (EApp (EVar "requireGoalSeeds") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "obls"))) (EVar "goals")))))
(DTypeSig false "requireGoalSeeds" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyApp (TyCon "List") (TyTuple (TyCon "UObligation") (TyCon "ReqWalk"))))))
(DFunDef false "requireGoalSeeds" ((PVar "gctx") (PVar "obls")) (EApp (EApp (EVar "map") (ELam ((PVar "o")) (ETuple (EVar "o") (EApp (EApp (EVar "reqWalkSeed") (EFieldAccess (EFieldAccess (EVar "o") "pred") "iface")) (EApp (EApp (EVar "map") (EVar "normalize")) (EApp (EApp (EVar "uOblArgs") (EVar "gctx")) (EVar "o"))))))) (EVar "obls")))
(DTypeSig false "nestedRequireGoalsGo" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "UObligation") (TyCon "ReqWalk"))) (TyApp (TyCon "List") (TyCon "UObligation")))))))
(DFunDef false "nestedRequireGoalsGo" ((PVar "mctx") (PVar "rigidIds") (PVar "liveIds") (PVar "walks")) (EMatch (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "selectedRequireGoals") (EVar "mctx")) (EVar "rigidIds")) (EVar "liveIds"))) (EVar "walks")) (arm (PList) () (EListLit)) (arm (PVar "derived") () (EBinOp "++" (EApp (EApp (EVar "map") (EVar "fst")) (EVar "derived")) (EApp (EApp (EApp (EApp (EVar "nestedRequireGoalsGo") (EVar "mctx")) (EVar "rigidIds")) (EVar "liveIds")) (EVar "derived"))))))
(DTypeSig false "nestedRequireGoalsOnce" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "UObligation") (TyCon "ReqWalk"))) (TyApp (TyCon "List") (TyCon "UObligation")))))))
(DFunDef false "nestedRequireGoalsOnce" ((PVar "mctx") PWild PWild (PList)) (EListLit))
(DFunDef false "nestedRequireGoalsOnce" ((PVar "mctx") (PVar "rigidIds") (PVar "liveIds") (PVar "walks")) (EBlock (DoLet false false (PTuple (PVar "kept") (PVar "derived")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "followRequireLevel") (EVar "mctx")) (EVar "rigidIds")) (EVar "liveIds")) (EVar "walks")) (EListLit)) (EListLit))) (DoExpr (EBinOp "++" (EVar "kept") (EApp (EApp (EApp (EApp (EVar "nestedRequireGoalsOnce") (EVar "mctx")) (EVar "rigidIds")) (EVar "liveIds")) (EVar "derived"))))))
(DTypeSig false "followRequireLevel" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "UObligation") (TyCon "ReqWalk"))) (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "UObligation") (TyCon "ReqWalk")))) (TyTuple (TyApp (TyCon "List") (TyCon "UObligation")) (TyApp (TyCon "List") (TyTuple (TyCon "UObligation") (TyCon "ReqWalk")))))))))))
(DFunDef false "followRequireLevel" ((PVar "mctx") PWild PWild (PList) (PVar "kept") (PVar "derived")) (ETuple (EApp (EVar "reverse") (EVar "kept")) (EApp (EApp (EVar "flatMap") (EVar "identity")) (EApp (EVar "reverse") (EVar "derived")))))
(DFunDef false "followRequireLevel" ((PVar "mctx") (PVar "rigidIds") (PVar "liveIds") (PCons (PTuple (PVar "o") (PVar "walk")) (PVar "rest")) (PVar "kept") (PVar "derived")) (EIf (EApp (EApp (EApp (EVar "walkGoalFollowed") (EVar "walk")) (EFieldAccess (EFieldAccess (EVar "o") "pred") "iface")) (EApp (EApp (EVar "uOblGoalArgs") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "o"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "followRequireLevel") (EVar "mctx")) (EVar "rigidIds")) (EVar "liveIds")) (EVar "rest")) (EVar "kept")) (EVar "derived")) (EBlock (DoLet false false (PVar "below") (EApp (EApp (EApp (EApp (EVar "followRequireGoal") (EVar "mctx")) (EVar "rigidIds")) (EVar "liveIds")) (ETuple (EVar "o") (EVar "walk")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "followRequireLevel") (EVar "mctx")) (EVar "rigidIds")) (EVar "liveIds")) (EVar "rest")) (EBinOp "::" (EVar "o") (EVar "kept"))) (EBinOp "::" (EVar "below") (EVar "derived")))))))
(DTypeSig false "followRequireGoal" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyTuple (TyCon "UObligation") (TyCon "ReqWalk")) (TyApp (TyCon "List") (TyTuple (TyCon "UObligation") (TyCon "ReqWalk"))))))))
(DFunDef false "followRequireGoal" ((PVar "mctx") (PVar "rigidIds") (PVar "liveIds") (PTuple (PVar "o") (PVar "walk"))) (EBlock (DoLet false false (PTuple (PVar "clean") (PVar "below")) (EApp (EApp (EApp (EVar "solvedCleanly") (EVar "mctx")) (ELam ((PVar "goals")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "g")) (EApp (EApp (EVar "uOblArgs") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EVar "fst") (EVar "g"))))) (EVar "goals")))) (ELam (PWild) (EApp (EApp (EApp (EApp (EApp (EVar "requireGoalsBelow") (EVar "mctx")) (EVar "prerequisiteUnreported")) (EVar "rigidIds")) (EVar "liveIds")) (ETuple (EVar "o") (EVar "walk")))))) (DoExpr (EIf (EVar "clean") (EApp (EApp (EApp (EVar "noteWalkGoalFollowed") (EVar "walk")) (EFieldAccess (EFieldAccess (EVar "o") "pred") "iface")) (EApp (EApp (EVar "uOblGoalArgs") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "o"))) (ELit LUnit))) (DoExpr (EVar "below"))))
(DTypeSig false "uOblGoalArgs" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "UObligation") (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "uOblGoalArgs" ((PVar "gctx") (PVar "o")) (EApp (EApp (EVar "map") (EVar "normalize")) (EApp (EApp (EVar "uOblArgs") (EVar "gctx")) (EVar "o"))))
(DTypeSig false "selectedRequireGoals" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyTuple (TyCon "UObligation") (TyCon "ReqWalk")) (TyApp (TyCon "List") (TyTuple (TyCon "UObligation") (TyCon "ReqWalk"))))))))
(DFunDef false "selectedRequireGoals" ((PVar "mctx") (PVar "rigidIds") (PVar "liveIds") (PVar "walk")) (EApp (EApp (EApp (EApp (EApp (EVar "requireGoalsBelow") (EVar "mctx")) (EApp (EVar "prerequisiteOnWalk") (EVar "mctx"))) (EVar "rigidIds")) (EVar "liveIds")) (EVar "walk")))
(DTypeSig false "prerequisiteUnreported" (TyFun (TyCon "ReqWalk") (TyFun (TyCon "UObligation") (TyApp (TyCon "List") (TyTuple (TyCon "UObligation") (TyCon "ReqWalk"))))))
(DFunDef false "prerequisiteUnreported" ((PVar "walk") (PVar "g")) (EMatch (EApp (EApp (EApp (EVar "reqWalkEnter") (EVar "walk")) (EFieldAccess (EFieldAccess (EVar "g") "pred") "iface")) (EApp (EApp (EVar "map") (EVar "normalize")) (EFieldAccess (EFieldAccess (EVar "g") "pred") "args"))) (arm (PCon "ReqOn" (PVar "next")) () (EListLit (ETuple (EVar "g") (EVar "next")))) (arm PWild () (EBlock (DoLet false false (PVar "memo") (EApp (EVar "reqWalkMemo") (EVar "walk"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "memo") "wmStopped")) (EVar "True"))) (DoExpr (EListLit))))))
(DTypeSig true "inferImplBodies" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Decl"))) (TyCon "Unit")))))))
(DFunDef false "inferImplBodies" ((PVar "env") PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "inferImplBodies" ((PVar "env") (PVar "rpNames") (PVar "ce") (PVar "cur") (PCons (PTuple (PVar "loc") (PVar "d")) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "inferOneImpl") (EApp (EApp (EVar "envAtIfSome") (EVar "loc")) (EVar "env"))) (EVar "rpNames")) (EVar "ce")) (EVar "cur")) (EVar "d"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "inferImplBodies") (EVar "env")) (EVar "rpNames")) (EVar "ce")) (EVar "cur")) (EVar "rest")))))
(DTypeSig true "implDeclLoc" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "implDeclLoc" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "implDeclLoc") (EVar "d")))
(DFunDef false "implDeclLoc" ((PRec "DImpl" ((rf "implIfaceLoc" None)) true)) (EApp (EVar "Some") (EVar "implIfaceLoc")))
(DFunDef false "implDeclLoc" (PWild) (EVar "None"))
(DTypeSig false "inferOneImpl" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyFun (TyCon "Decl") (TyCon "Unit")))))))
(DFunDef false "inferOneImpl" ((PVar "env") (PVar "rpNames") (PVar "ce") (PVar "cur") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EApp (EVar "inferOneImpl") (EVar "env")) (EVar "rpNames")) (EVar "ce")) (EVar "cur")) (EVar "d")))
(DFunDef false "inferOneImpl" ((PVar "env") (PVar "rpNames") (PVar "ce") (PVar "cur") (PRec "DImpl" ((rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "methods" None) (rf "implOrigin" None)) true)) (EBlock (DoLet false false (PVar "iref") (ERecordCreate "IfaceRef" ((fa "irName" (EVar "iface")) (fa "irOrigin" (EVar "implOrigin"))))) (DoExpr (EMatch (EVar "reqs") (arm (PList) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferPlainImpl") (EVar "env")) (EVar "ce")) (EVar "cur")) (EVar "iref")) (EVar "tys")) (EVar "methods"))) (arm PWild () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferRequiresImpl") (EVar "env")) (EVar "rpNames")) (EVar "ce")) (EVar "cur")) (EVar "iref")) (EVar "tys")) (EVar "reqs")) (EVar "methods")))))))
(DFunDef false "inferOneImpl" ((PVar "env") PWild PWild PWild PWild) (ELit LUnit))
(DTypeSig false "inferPlainImpl" (TyFun (TyCon "TcEnv") (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyCon "Unit"))))))))
(DFunDef false "inferPlainImpl" ((PVar "env") (PVar "ce") (PVar "cur") (PVar "iface") (PVar "tys") (PVar "methods")) (EBlock (DoLet false false (PTuple (PVar "implTvMap") (PVar "headMonos")) (EApp (EApp (EVar "implHeadMonos") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "tys"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferImplMethods") (EVar "env")) (EVar "ce")) (EVar "cur")) (EVar "iface")) (EVar "implTvMap")) (EVar "headMonos")) (EListLit)) (EApp (EApp (EApp (EVar "scopeImplMethods") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EApp (EVar "captureScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (EVar "methods"))))))
(DTypeSig false "inferRequiresImpl" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyCon "Unit"))))))))))
(DFunDef false "inferRequiresImpl" ((PVar "env") (PVar "rpNames") (PVar "ce") (PVar "cur") (PVar "iface") (PVar "tys") (PVar "reqs") (PVar "methods")) (EBlock (DoLet false false (PTuple (PVar "implTvMap") (PVar "headMonos")) (EApp (EApp (EVar "implHeadMonos") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "tys"))) (DoLet false false (PVar "scopedMethods") (EApp (EApp (EApp (EVar "scopeImplMethods") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EApp (EVar "captureScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (EVar "methods"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferImplMethods") (EVar "env")) (EVar "ce")) (EVar "cur")) (EVar "iface")) (EVar "implTvMap")) (EVar "headMonos")) (EVar "reqs")) (EVar "scopedMethods"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerImplRequires") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "ce")) (EVar "cur")) (EVar "iface")) (EVar "implTvMap")) (EVar "rpNames")) (EVar "reqs")) (EVar "scopedMethods")))))
(DTypeSig false "scopeImplMethods" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyApp (TyCon "List") (TyCon "ScopedImplMethod"))))))
(DFunDef false "scopeImplMethods" ((PVar "mctx") PWild (PList)) (EListLit))
(DFunDef false "scopeImplMethods" ((PVar "mctx") (PVar "parent") (PCons (PVar "method") (PVar "rest"))) (EBlock (DoLet false false (PVar "name") (EApp (EVar "implMethodName") (EVar "method"))) (DoLet false false (PVar "scope") (EApp (EApp (EApp (EApp (EApp (EVar "Scopes.freshScope") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EApp (EVar "Some") (EVar "parent"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (EFieldAccess (EApp (EApp (EVar "Scopes.scopeFrame") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EVar "parent")) "sfModuleId")) (EApp (EVar "BindingOwner") (EVar "name")))) (DoExpr (EBinOp "::" (ERecordCreate "ScopedImplMethod" ((fa "simMethod" (EVar "method")) (fa "simScope" (EVar "scope")))) (EApp (EApp (EApp (EVar "scopeImplMethods") (EVar "mctx")) (EVar "parent")) (EVar "rest"))))))
(DTypeSig false "inferImplMethods" (TyFun (TyCon "TcEnv") (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyFun (TyApp (TyCon "List") (TyCon "ScopedImplMethod")) (TyCon "Unit"))))))))))
(DFunDef false "inferImplMethods" ((PVar "env") PWild PWild PWild PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "inferImplMethods" ((PVar "env") (PVar "ce") (PVar "cur") (PVar "iface") (PVar "implTvMap") (PVar "headMonos") (PVar "reqs") (PCons (PVar "m") (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferImplMethod") (EVar "env")) (EVar "ce")) (EVar "cur")) (EVar "iface")) (EVar "implTvMap")) (EVar "headMonos")) (EVar "reqs")) (EVar "m"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferImplMethods") (EVar "env")) (EVar "ce")) (EVar "cur")) (EVar "iface")) (EVar "implTvMap")) (EVar "headMonos")) (EVar "reqs")) (EVar "rest")))))
(DTypeSig false "inferImplMethod" (TyFun (TyCon "TcEnv") (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyFun (TyCon "ScopedImplMethod") (TyCon "Unit"))))))))))
(DFunDef false "inferImplMethod" ((PVar "env") (PVar "ce") (PVar "cur") (PVar "iface") (PVar "implTvMap") (PVar "headMonos") (PVar "reqs") (PVar "scoped")) (EMatch (EFieldAccess (EVar "scoped") "simMethod") (arm (PCon "ImplMethod" (PVar "mname") (PVar "pats") (PVar "body")) () (EMatch (EApp (EApp (EApp (EApp (EVar "ceMethodTyAt") (EVar "iface")) (EVar "mname")) (EVar "cur")) (EVar "ce")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "sig")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferMethodBody") (EVar "env")) (EVar "iface")) (EApp (EVar "ImplBody") (ERecordCreate "ImplBodySite" ((fa "ibImplTvMap" (EVar "implTvMap")) (fa "ibHeadMonos" (EVar "headMonos")) (fa "ibRequires" (EVar "reqs")) (fa "ibScope" (EFieldAccess (EVar "scoped") "simScope")))))) (EVar "sig")) (EVar "mname")) (EVar "pats")) (EVar "body")))))))
(DTypeSig false "inferMethodBody" (TyFun (TyCon "TcEnv") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "MethodBodyKind") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind"))))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyCon "Unit")))))))))
(DFunDef false "inferMethodBody" ((PVar "outer") (PVar "iface") (PVar "kind") (PTuple (PVar "params") (PVar "mty") (PVar "gscope")) (PVar "mname") (PVar "pats") (PVar "body")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EVar "envAtIfSome") (EApp (EVar "exprSpanLoc") (EVar "body"))) (EVar "outer"))) (DoExpr (EApp (EApp (EVar "enterLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "bodyLevel") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentLevel") "value")) (DoLet false false (PVar "bodyScope") (EApp (EApp (EApp (EApp (EVar "openMethodBodyScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "iface")) (EVar "mname")) (EVar "kind"))) (DoLet false false (PVar "savedCurrentFn") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentFn") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentFn")) (EVar "mname"))) (DoExpr (EMatch (EVar "kind") (arm (PCon "ImplBody" PWild) () (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentImplBody")) (EVar "True"))) (arm (PCon "DefaultBody") () (ELit LUnit)))) (DoLet false false (PVar "oblN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls"))) (DoLet false false (PVar "callN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "obls"))) (DoLet false false (PVar "dictN0") (EApp (EApp (EVar "goalsMark") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (DoLet false false (PVar "inst") (EApp (EApp (EApp (EApp (EApp (EVar "instantiateMethodBody") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "kind")) (EVar "params")) (EVar "mty")) (EVar "gscope"))) (DoLet false false (PVar "headBefore") (EMatch (EVar "kind") (arm (PCon "ImplBody" (PVar "site")) () (EApp (EVar "implHeadVarRoots") (EFieldAccess (EVar "site") "ibImplTvMap"))) (arm (PCon "DefaultBody") () (EListLit)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerMethodBodyGrants") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "iface")) (EVar "mname")) (EApp (EVar "methodBodyHeadMonos") (EVar "kind"))) (EVar "inst")) (EVar "bodyScope"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordClauseFileBound") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "body")) (EApp (EVar "listLen") (EVar "pats"))) (EFieldAccess (EVar "inst") "mbiExpected"))) (DoLet false false (PVar "loc") (EApp (EApp (EVar "orElseLoc") (EApp (EVar "implBodyLoc") (EVar "body"))) (EApp (EVar "firstTyLoc") (EVar "mty")))) (DoLet false false (PVar "subject") (EApp (EApp (EApp (EVar "methodBodySubject") (EVar "kind")) (EFieldAccess (EVar "iface") "irName")) (EVar "mname"))) (DoLet false false (PVar "contract") (EApp (EApp (EApp (EVar "beginEffectContract") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EVar "inst") "mbiContractForce")) (EFieldAccess (EVar "inst") "mbiExpected"))) (DoLet false false (PTuple (PVar "bodyErred") (PVar "check")) (EApp (EApp (EVar "erredDuring") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELam (PWild) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkMethodBodyAgainst") (EVar "env")) (EVar "iface")) (EVar "kind")) (EVar "mname")) (EVar "mty")) (EVar "gscope")) (EVar "inst")) (EVar "contract")) (EVar "loc")) (EVar "pats")) (EVar "body"))))) (DoLet false false (PVar "headMonos") (EApp (EVar "methodBodyHeadMonos") (EVar "kind"))) (DoLet false false (PVar "launderFlagged") (EMatch (EVar "kind") (arm (PCon "ImplBody" PWild) () (EFieldAccess (EVar "check") "mbcLaunderFlagged")) (arm (PCon "DefaultBody") () (EVar "False")))) (DoLet false false (PVar "effVarRigidity") (ELam (PWild) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkMethodEffVarRigidity") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "subject")) (EVar "headMonos")) (EVar "gscope")) (EVar "mty")) (EFieldAccess (EVar "inst") "mbiEffVars")) (EVar "launderFlagged")) (EFieldAccess (EVar "check") "mbcEagerIndexed")) (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EFieldAccess (EVar "check") "mbcPerformedAt"))))) (DoExpr (EMatch (EVar "kind") (arm (PCon "DefaultBody") () (EIf (EVar "bodyErred") (ELit LUnit) (EApp (EVar "effVarRigidity") (ELit LUnit)))) (arm (PCon "ImplBody" PWild) () (ELit LUnit)))) (DoLet false false (PVar "addedObls") (EApp (EApp (EVar "wWindow") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls")) (EVar "oblN0"))) (DoLet false false (PVar "addedCallObls") (EApp (EApp (EVar "callOblsWindow") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "callN0"))) (DoLet false false (PVar "bodyRigidIds") (EApp (EVar "monoRootIdSet") (EBinOp "++" (EBinOp "++" (EVar "headMonos") (EListLit (EFieldAccess (EVar "inst") "mbiExpected"))) (EApp (EApp (EVar "map") (EVar "snd")) (EFieldAccess (EVar "inst") "mbiNamedVars"))))) (DoLet false false (PVar "bodyObls") (EBinOp "++" (EVar "addedObls") (EApp (EApp (EVar "callUOblsWindow") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "callN0")))) (DoExpr (EApp (EApp (EApp (EVar "improveByUniqueImpl") (EFieldAccess (EVar "env") "teDyn")) (EVar "bodyRigidIds")) (EVar "bodyObls"))) (DoExpr (EApp (EApp (EApp (EVar "determineByUniqueInstance") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "bodyRigidIds")) (EVar "bodyObls"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkMethodRigidityCore") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "subject")) (EFieldAccess (EVar "iface") "irName")) (EVar "mty")) (EVar "headMonos")) (EFieldAccess (EVar "inst") "mbiSurvivors")) (EApp (EApp (EVar "methodBodyOwnTyparams") (EVar "kind")) (EVar "params"))) (EVar "addedObls")) (EVar "addedCallObls")) (EVar "loc"))) (DoExpr (EMatch (EVar "kind") (arm (PCon "ImplBody" (PVar "site")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkImplHeadRigidity") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "subject")) (EFieldAccess (EVar "iface") "irName")) (EVar "site")) (EVar "headBefore")) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstExprLoc") (EVar "body"))) (EVar "loc")))) (arm (PCon "DefaultBody") () (ELit LUnit)))) (DoExpr (EMatch (EVar "kind") (arm (PCon "ImplBody" PWild) () (EApp (EVar "effVarRigidity") (ELit LUnit))) (arm (PCon "DefaultBody") () (ELit LUnit)))) (DoLet false false (PVar "survivingNumIds") (EMatch (EVar "kind") (arm (PCon "ImplBody" (PVar "site")) () (EApp (EApp (EVar "numChannelRootSet") (EVar "addedObls")) (EBinOp "++" (EFieldAccess (EVar "site") "ibHeadMonos") (EApp (EApp (EApp (EVar "methodLevelConstraintMonos") (EVar "params")) (EVar "mty")) (EFieldAccess (EVar "inst") "mbiNamedVars"))))) (arm (PCon "DefaultBody") () (EApp (EVar "monoRootIdSet") (EListLit (EFieldAccess (EVar "inst") "mbiExpected")))))) (DoExpr (EMatch (EVar "kind") (arm (PCon "ImplBody" (PVar "site")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkImplHeadNumObligations") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "subject")) (EFieldAccess (EVar "site") "ibImplTvMap")) (EFieldAccess (EVar "site") "ibRequires")) (EVar "survivingNumIds")) (EVar "addedObls"))) (arm (PCon "DefaultBody") () (ELit LUnit)))) (DoExpr (EMatch (EVar "kind") (arm (PCon "ImplBody" (PVar "site")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkImplHeadPrerequisites") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "subject")) (EVar "iface")) (EVar "site")) (EFieldAccess (EVar "inst") "mbiNamedVars")) (EVar "mty")) (EVar "addedObls")) (EVar "addedCallObls"))) (arm (PCon "DefaultBody") () (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "exitLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "withheld") (EApp (EApp (EVar "finalizeNumBoundary") (EFieldAccess (EVar "env") "teDyn")) (ERecordCreate "NumBoundary" ((fa "nbDisposition" (EApp (EVar "NumBoundaryOwnedMethodBody") (EVar "bodyLevel"))) (fa "nbMembers" (EListLit (EFieldAccess (EVar "inst") "mbiExpected"))) (fa "nbSurvivingIds" (EVar "survivingNumIds")) (fa "nbDefaultObls" (EBinOp "++" (EVar "addedObls") (EApp (EApp (EApp (EVar "calleeNumObls") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "callN0")) (EVar "dictN0")))) (fa "nbAmbiguityObls" (EVar "addedObls")) (fa "nbGuard" (ERecordCreate "NumGuard" ((fa "ngGoals" (EVar "bodyObls")) (fa "ngRigidIds" (EVar "bodyRigidIds")) (fa "ngOuterBelow" (EVar "None"))))))))) (DoExpr (EApp (EApp (EApp (EVar "improveByUniqueImpl") (EFieldAccess (EVar "env") "teDyn")) (EVar "bodyRigidIds")) (EVar "bodyObls"))) (DoExpr (EApp (EApp (EApp (EVar "determineByUniqueInstance") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "bodyRigidIds")) (EVar "bodyObls"))) (DoLet false false (PVar "methodSig") (EListLit (ETuple (EVar "mname") (EVar "mty") (EFieldAccess (EVar "inst") "mbiSurvivors")))) (DoLet false false (PVar "methodVarIds") (EApp (EVar "sccProtectedSignatureIds") (EVar "methodSig"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "publishMethodPredGivens") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "params")) (EVar "mty")) (EVar "inst")) (EVar "bodyScope"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "checkSigVarGoals") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "DeclaredBySignature")) (EVar "methodVarIds")) (EVar "methodSig")) (EVar "bodyObls"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "rejectUndeterminedVectors") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "bodyRigidIds")) (EVar "omEmpty")) (EVar "addedObls")) (EBinOp "++" (EApp (EApp (EVar "callUOblsWindow") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "callN0")) (EApp (EApp (EApp (EApp (EVar "nestedRequireGoals") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "bodyRigidIds")) (EVar "omEmpty")) (EVar "bodyObls"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "rejectWithheldAmbiguity") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "bodyRigidIds")) (EVar "withheld")) (EVar "bodyObls"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerMethodBodyGivens") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "iface")) (EVar "kind")) (EVar "params")) (EVar "mty")) (EVar "inst")) (EVar "bodyScope"))) (DoExpr (EMatch (EVar "kind") (arm (PCon "ImplBody" PWild) () (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentImplBody")) (EVar "False"))) (arm (PCon "DefaultBody") () (ELit LUnit)))) (DoLet false false (PVar "restoredFn") (EMatch (EVar "kind") (arm (PCon "ImplBody" PWild) () (ELit (LString ""))) (arm (PCon "DefaultBody") () (EVar "savedCurrentFn")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentFn")) (EVar "restoredFn"))) (DoExpr (EApp (EApp (EVar "closeScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit)))))
(DTypeSig false "openMethodBodyScope" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "String") (TyFun (TyCon "MethodBodyKind") (TyCon "ScopeId"))))))
(DFunDef false "openMethodBodyScope" ((PVar "mctx") PWild PWild (PCon "ImplBody" (PVar "site"))) (EBlock (DoExpr (EApp (EApp (EVar "openScope") (EVar "mctx")) (EFieldAccess (EVar "site") "ibScope"))) (DoExpr (EFieldAccess (EVar "site") "ibScope"))))
(DFunDef false "openMethodBodyScope" ((PVar "mctx") (PVar "iface") (PVar "mname") (PCon "DefaultBody")) (EBlock (DoLet false false (PVar "parentScope") (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) (DoLet false false (PVar "owner") (ERecordCreate "DefaultBodyIdentity" ((fa "dbiIface" (EVar "iface")) (fa "dbiMethod" (EVar "mname"))))) (DoLet false false (PVar "bodyScope") (EApp (EApp (EApp (EApp (EApp (EVar "Scopes.freshScope") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EApp (EVar "Some") (EVar "parentScope"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (EFieldAccess (EApp (EApp (EVar "Scopes.scopeFrame") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EVar "parentScope")) "sfModuleId")) (EApp (EVar "DefaultBodyOwner") (EVar "owner")))) (DoExpr (EApp (EApp (EVar "openScope") (EVar "mctx")) (EVar "bodyScope"))) (DoExpr (EVar "bodyScope"))))
(DTypeSig false "instantiateMethodBody" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodBodyKind") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyCon "MethodBodyInstance")))))))
(DFunDef false "instantiateMethodBody" ((PVar "mctx") (PCon "ImplBody" (PVar "site")) (PVar "ifaceParams") (PVar "mty") (PVar "gscope")) (EBlock (DoLet false false (PVar "baseMap") (EApp (EApp (EVar "zip") (EVar "ifaceParams")) (EFieldAccess (EVar "site") "ibHeadMonos"))) (DoLet false false (PVar "extraMap") (EApp (EApp (EVar "freshTvMap") (EVar "mctx")) (EApp (EApp (EVar "removeAllS") (EVar "ifaceParams")) (EApp (EApp (EVar "removeAllS") (EApp (EApp (EApp (EVar "rowArgNamesIn") (EVar "mctx")) (EVar "gscope")) (EVar "mty"))) (EApp (EVar "dedup") (EApp (EVar "tyVarNames") (EVar "mty"))))))) (DoLet false false (PVar "effMap") (EApp (EApp (EApp (EVar "sigVarsFor") (EVar "mctx")) (EVar "mty")) (EApp (EVar "dedup") (EBinOp "++" (EApp (EVar "effTailNames") (EVar "mty")) (EApp (EApp (EApp (EVar "rowArgNamesIn") (EVar "mctx")) (EVar "gscope")) (EVar "mty")))))) (DoLet false false (PVar "mtvs") (EBinOp "++" (EVar "baseMap") (EVar "extraMap"))) (DoLet false false (PVar "expected") (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "effMap")) (EVar "mtvs")) (EVar "mty"))) (DoLet false false (PVar "contractForce") (EApp (EApp (EApp (EApp (EVar "bindingForceFromAst") (EVar "mctx")) (EVar "effMap")) (EVar "mtvs")) (EVar "mty"))) (DoExpr (ERecordCreate "MethodBodyInstance" ((fa "mbiExpected" (EVar "expected")) (fa "mbiContractForce" (EVar "contractForce")) (fa "mbiCheckedForce" (ELam (PWild) (EApp (EApp (EApp (EApp (EVar "bindingForceFromAst") (EVar "mctx")) (EVar "effMap")) (EVar "mtvs")) (EVar "mty")))) (fa "mbiEffVars" (EFieldAccess (EVar "effMap") "svRows")) (fa "mbiSurvivors" (EVar "extraMap")) (fa "mbiNamedVars" (EVar "mtvs")) (fa "mbiDictSlots" (EListLit)) (fa "mbiTypeSubst" (EListLit)))))))
(DFunDef false "instantiateMethodBody" ((PVar "mctx") (PCon "DefaultBody") (PVar "typarams") (PVar "mty") (PVar "dscope")) (EBlock (DoLet false false (PVar "st") (EApp (EApp (EApp (EVar "sigToSchemeTvsIn") (EVar "mctx")) (EVar "dscope")) (EVar "mty"))) (DoLet false false (PVar "descriptor") (EApp (EApp (EVar "instantiateMethodTracked") (EVar "mctx")) (EApp (EVar "fst") (EVar "st")))) (DoLet false false (PVar "subst") (EFieldAccess (EFieldAccess (EVar "descriptor") "mtiSubstitution") "misTypeSubst")) (DoExpr (ERecordCreate "MethodBodyInstance" ((fa "mbiExpected" (EFieldAccess (EVar "descriptor") "mtiBody")) (fa "mbiContractForce" (EFieldAccess (EVar "descriptor") "mtiForce")) (fa "mbiCheckedForce" (ELam (PWild) (EApp (EVar "effrowNorm") (EFieldAccess (EVar "descriptor") "mtiForce")))) (fa "mbiEffVars" (EApp (EApp (EVar "zip") (EApp (EVar "dedup") (EBinOp "++" (EApp (EVar "effTailNames") (EVar "mty")) (EApp (EApp (EApp (EVar "rowArgNamesIn") (EVar "mctx")) (EVar "dscope")) (EVar "mty"))))) (EApp (EApp (EVar "map") (EVar "snd")) (EFieldAccess (EFieldAccess (EVar "descriptor") "mtiSubstitution") "misEffectSubst")))) (fa "mbiSurvivors" (EApp (EApp (EVar "defaultSurvivorMap") (EApp (EVar "snd") (EVar "st"))) (EVar "subst"))) (fa "mbiNamedVars" (EApp (EApp (EApp (EVar "instantiateNamedMonos") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EVar "snd") (EVar "st"))) (EVar "subst"))) (fa "mbiDictSlots" (EApp (EApp (EApp (EVar "methodConstraintSlotIds") (EVar "typarams")) (EVar "mty")) (EApp (EVar "snd") (EVar "st")))) (fa "mbiTypeSubst" (EVar "subst")))))))
(DTypeSig false "methodBodyHeadMonos" (TyFun (TyCon "MethodBodyKind") (TyApp (TyCon "List") (TyCon "Mono"))))
(DFunDef false "methodBodyHeadMonos" ((PCon "ImplBody" (PVar "site"))) (EFieldAccess (EVar "site") "ibHeadMonos"))
(DFunDef false "methodBodyHeadMonos" ((PCon "DefaultBody")) (EListLit))
(DTypeSig false "methodBodyOwnTyparams" (TyFun (TyCon "MethodBodyKind") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "methodBodyOwnTyparams" ((PCon "ImplBody" PWild) PWild) (EListLit))
(DFunDef false "methodBodyOwnTyparams" ((PCon "DefaultBody") (PVar "typarams")) (EVar "typarams"))
(DTypeSig false "gatesBodyCascade" (TyFun (TyCon "MethodBodyKind") (TyCon "Bool")))
(DFunDef false "gatesBodyCascade" ((PCon "ImplBody" PWild)) (EVar "False"))
(DFunDef false "gatesBodyCascade" ((PCon "DefaultBody")) (EVar "True"))
(DTypeSig false "checkMethodBodyAgainst" (TyFun (TyCon "TcEnv") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "MethodBodyKind") (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "MethodBodyInstance") (TyFun (TyTuple (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyCon "MethodBodyCheck")))))))))))))
(DFunDef false "checkMethodBodyAgainst" ((PVar "env") (PVar "iface") (PVar "kind") (PVar "mname") (PVar "mty") (PVar "gscope") (PVar "inst") (PVar "contract") (PVar "loc") (PVar "pats") (PVar "body")) (EBlock (DoLet false false (PVar "oblSnapshot") (EApp (EVar "wSnapshot") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls"))) (DoLet false false (PVar "indexOnly") (EMatch (EVar "kind") (arm (PCon "ImplBody" PWild) () (EApp (EApp (EApp (EVar "indexOnlyEffVars") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "gscope")) (EVar "mty"))) (arm (PCon "DefaultBody") () (EListLit)))) (DoLet false false (PVar "sites") (EIf (EApp (EVar "isEmptyL") (EVar "indexOnly")) (EVar "None") (EApp (EVar "Some") (EApp (EVar "Ref") (EListLit))))) (DoLet false false (PVar "envSites") (ERecordUpdate (EVar "env") ((fa "teDyn" (ERecordUpdate (EFieldAccess (EVar "env") "teDyn") ((fa "dcPerformSites" (EVar "sites")))))))) (DoLet false false (PTuple (PVar "inferErred") (PVar "inferred")) (EApp (EApp (EVar "erredDuring") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELam (PWild) (EApp (EApp (EApp (EApp (EApp (EVar "inferBindingChecked") (EVar "False")) (EVar "envSites")) (EApp (EVar "Some") (EApp (EVar "normalize") (EFieldAccess (EVar "inst") "mbiExpected")))) (EVar "pats")) (EVar "body"))))) (DoLet false false (PVar "actual") (EApp (EVar "fst") (EVar "inferred"))) (DoLet false false (PVar "check") (EIf (EBinOp "&&" (EVar "inferErred") (EApp (EVar "gatesBodyCascade") (EVar "kind"))) (ERecordCreate "MethodBodyCheck" ((fa "mbcLaunderFlagged" (EVar "False")) (fa "mbcEagerIndexed" (EListLit)) (fa "mbcPerformedAt" (EVar "None")))) (EBlock (DoExpr (EMatch (EVar "kind") (arm (PCon "ImplBody" PWild) () (EApp (EApp (EApp (EApp (EVar "rowInto") (EFieldAccess (EVar "env") "teDyn")) (EVar "True")) (EApp (EFieldAccess (EVar "inst") "mbiCheckedForce") (ELit LUnit))) (EApp (EVar "effrowNorm") (EApp (EVar "snd") (EVar "inferred"))))) (arm (PCon "DefaultBody") () (ELit LUnit)))) (DoLet false false (PVar "launderMark") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "absorptions"))) (DoLet false false (PVar "declArrows") (EApp (EVar "allArrowEffs") (EFieldAccess (EVar "inst") "mbiExpected"))) (DoLet false false (PVar "actualArrows") (EApp (EVar "allArrowEffs") (EVar "actual"))) (DoLet false false (PVar "eager") (EApp (EApp (EApp (EApp (EApp (EVar "eagerIndexOnlyVars") (EVar "indexOnly")) (EFieldAccess (EVar "inst") "mbiEffVars")) (EVar "actualArrows")) (EFieldAccess (EVar "inst") "mbiExpected")) (EVar "actual"))) (DoLet false false (PVar "performedAt") (EIf (EApp (EVar "isEmptyL") (EVar "eager")) (EVar "None") (EApp (EApp (EVar "performSiteIn") (EVar "sites")) (EVar "actual")))) (DoLet false false (PVar "bodyDyn") (EMatch (EVar "kind") (arm (PCon "DefaultBody") () (ERecordUpdate (EFieldAccess (EVar "env") "teDyn") ((fa "dcMethodMismatch" (EApp (EVar "Some") (EVar "mname")))))) (arm (PCon "ImplBody" PWild) () (EFieldAccess (EVar "env") "teDyn")))) (DoLet false false (PVar "valueDyn") (EApp (EApp (EVar "dynAtIfSome") (EApp (EVar "valueSpanLoc") (EVar "body"))) (EVar "bodyDyn"))) (DoLet false false (PVar "unifyDyn") (EMatch (EVar "kind") (arm (PCon "DefaultBody") () (EVar "valueDyn")) (arm (PCon "ImplBody" PWild) () (EApp (EApp (EVar "dynAtIfSome") (EVar "performedAt")) (EVar "valueDyn"))))) (DoLet false false (PVar "unifyErred") (EApp (EVar "fst") (EApp (EApp (EVar "erredDuring") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELam (PWild) (EBlock (DoExpr (EMatch (EVar "kind") (arm (PCon "DefaultBody") () (EApp (EApp (EApp (EApp (EVar "rowInto") (EVar "bodyDyn")) (EVar "True")) (EApp (EFieldAccess (EVar "inst") "mbiCheckedForce") (ELit LUnit))) (EApp (EVar "effrowNorm") (EApp (EVar "snd") (EVar "inferred"))))) (arm (PCon "ImplBody" PWild) () (ELit LUnit)))) (DoExpr (EApp (EApp (EApp (EApp (EVar "unifyInto") (EVar "unifyDyn")) (EVar "True")) (EFieldAccess (EVar "inst") "mbiExpected")) (EVar "actual")))))))) (DoExpr (EMatch (EVar "kind") (arm (PCon "DefaultBody") () (ELit LUnit)) (arm (PCon "ImplBody" PWild) () (EApp (EApp (EVar "finishEffectContract") (EFieldAccess (EVar "env") "teDyn")) (EVar "contract"))))) (DoLet false false (PVar "escaping") (EApp (EApp (EApp (EApp (EVar "launderEscapeFromLog") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "declArrows")) (EVar "actualArrows")) (EApp (EApp (EVar "wWindow") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "absorptions")) (EVar "launderMark")))) (DoExpr (EMatch (EVar "escaping") (arm (PList) () (ELit LUnit)) (arm PWild () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit (LString "T-EFFECT-LAUNDER"))) (EVar "loc")) (EApp (EApp (EApp (EApp (EVar "methodBodyLaunderMsg") (EVar "kind")) (EFieldAccess (EVar "iface") "irName")) (EVar "mname")) (EVar "escaping")))))) (DoExpr (EIf (EBinOp "&&" (EVar "unifyErred") (EApp (EVar "gatesBodyCascade") (EVar "kind"))) (EApp (EApp (EVar "wRestore") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls")) (EVar "oblSnapshot")) (ELit LUnit))) (DoExpr (ERecordCreate "MethodBodyCheck" ((fa "mbcLaunderFlagged" (EApp (EVar "isNonEmptyL") (EVar "escaping"))) (fa "mbcEagerIndexed" (EVar "eager")) (fa "mbcPerformedAt" (EVar "performedAt")))))))) (DoExpr (EMatch (EVar "kind") (arm (PCon "DefaultBody") () (EApp (EApp (EVar "finishEffectContract") (EFieldAccess (EVar "env") "teDyn")) (EVar "contract"))) (arm (PCon "ImplBody" PWild) () (ELit LUnit)))) (DoExpr (EVar "check"))))
(DTypeSig false "registerMethodBodyGivens" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "MethodBodyKind") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyFun (TyCon "MethodBodyInstance") (TyFun (TyCon "ScopeId") (TyCon "Unit")))))))))
(DFunDef false "registerMethodBodyGivens" ((PVar "gctx") (PVar "iface") (PVar "kind") (PVar "params") (PVar "mty") (PVar "inst") (PVar "scope")) (EBlock (DoExpr (EMatch (EVar "kind") (arm (PCon "ImplBody" PWild) () (EApp (EApp (EApp (EApp (EApp (EVar "registerImplMethodDicts") (EVar "gctx")) (EVar "scope")) (EVar "params")) (EVar "mty")) (EFieldAccess (EVar "inst") "mbiNamedVars"))) (arm (PCon "DefaultBody") () (EApp (EApp (EApp (EApp (EApp (EVar "registerMethodDictSlots") (EVar "gctx")) (EVar "scope")) (ELit (LInt 0))) (EFieldAccess (EVar "inst") "mbiDictSlots")) (EFieldAccess (EVar "inst") "mbiTypeSubst"))))) (DoExpr (EMatch (EVar "kind") (arm (PCon "DefaultBody") () (EBlock (DoLet false false (PVar "receiverArgs") (EApp (EApp (EVar "map") (ELam ((PVar "tp")) (EApp (EApp (EVar "optionOr") (EApp (EVar "TRigid") (EVar "tp"))) (EApp (EApp (EVar "lookupAssoc") (EVar "tp")) (EFieldAccess (EVar "inst") "mbiNamedVars"))))) (EVar "params"))) (DoExpr (EApp (EApp (EApp (EVar "registerFunPredGiven") (EVar "gctx")) (ERecordCreate "PredicateSlot" ((fa "psIface" (EVar "iface")) (fa "psArgs" (EApp (EVar "PSArgsKnown") (EVar "receiverArgs"))) (fa "psBoundIds" (EApp (EVar "dedupI") (EApp (EApp (EVar "flatMap") (EVar "monoTyvarIds")) (EVar "receiverArgs"))))))) (EApp (EApp (EVar "Scopes.binderAt") (EVar "scope")) (EVar "defaultReceiverOrdinal")))))) (arm (PCon "ImplBody" PWild) () (ELit LUnit))))))
(DTypeSig false "implBodyLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "implBodyLoc" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "implBodyLoc" ((PCon "ELam" PWild (PVar "b"))) (EApp (EVar "implBodyLoc") (EVar "b")))
(DFunDef false "implBodyLoc" ((PCon "ELet" PWild PWild PWild (PVar "e1") (PVar "e2"))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "implBodyLoc") (EVar "e1"))) (EApp (EVar "implBodyLoc") (EVar "e2"))))
(DFunDef false "implBodyLoc" ((PCon "ELetGroup" PWild (PVar "b"))) (EApp (EVar "implBodyLoc") (EVar "b")))
(DFunDef false "implBodyLoc" (PWild) (EVar "None"))
(DTypeSig false "checkMethodRigidityCore" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "Loc")))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit"))))))))))))
(DFunDef false "checkMethodRigidityCore" ((PVar "mctx") (PVar "subject") (PVar "iface") (PVar "mty") (PVar "headMonos") (PVar "extraMap") (PVar "ownTyparams") (PVar "addedObls") (PVar "addedCallObls") (PVar "loc")) (EBlock (DoLet false false (PVar "pinned") (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EVar "filterList") (ELam ((PVar "p")) (EApp (EVar "not") (EApp (EVar "isUnboundTvar") (EApp (EVar "snd") (EVar "p")))))) (EVar "extraMap")))) (DoExpr (EIf (EApp (EVar "isNonEmptyL") (EVar "pinned")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-IMPL-TOO-SPECIFIC"))) (EVar "loc")) (EApp (EApp (EApp (EVar "pinsTyvarMsg") (EVar "subject")) (EVar "mty")) (EVar "pinned"))) (EBlock (DoLet false false (PVar "survivors") (EApp (EVar "sigTvarIds") (EApp (EApp (EVar "map") (EVar "snd")) (EVar "extraMap")))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "hasDupI") (EVar "survivors")) (EApp (EApp (EVar "anyContainsI") (EVar "survivors")) (EApp (EApp (EVar "flatMap") (EVar "monoTyvarIds")) (EVar "headMonos")))) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-IMPL-TOO-SPECIFIC"))) (EVar "loc")) (EApp (EApp (EVar "collapsesTyvarsMsg") (EVar "subject")) (EVar "mty"))) (ELit LUnit)))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkSurvivorObligations") (EVar "mctx")) (EVar "subject")) (EVar "iface")) (EVar "ownTyparams")) (EVar "mty")) (EVar "extraMap")) (EVar "addedObls")) (EVar "loc"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkSurvivorCallObligations") (EVar "mctx")) (EVar "subject")) (EVar "iface")) (EVar "ownTyparams")) (EVar "mty")) (EVar "extraMap")) (EVar "addedCallObls")) (EVar "loc")))))
(DTypeSig false "defaultSurvivorMap" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))))
(DFunDef false "defaultSurvivorMap" ((PList) PWild) (EListLit))
(DFunDef false "defaultSurvivorMap" ((PCons (PTuple (PVar "name") (PVar "m")) (PVar "rest")) (PVar "subst")) (EMatch (EApp (EApp (EVar "lookupAssocI") (EApp (EVar "monoTyvarId") (EVar "m"))) (EVar "subst")) (arm (PCon "Some" (PVar "fm")) () (EBinOp "::" (ETuple (EVar "name") (EVar "fm")) (EApp (EApp (EVar "defaultSurvivorMap") (EVar "rest")) (EVar "subst")))) (arm (PCon "None") () (EApp (EApp (EVar "defaultSurvivorMap") (EVar "rest")) (EVar "subst")))))
(DTypeSig false "checkImplHeadNumObligations" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyCon "Unit"))))))))
(DFunDef false "checkImplHeadNumObligations" ((PVar "mctx") PWild PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "checkImplHeadNumObligations" ((PVar "mctx") (PVar "subject") (PVar "implTvMap") (PVar "reqs") (PVar "survivingIds") (PCons (PVar "o") (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkImplHeadNumIds") (EVar "mctx")) (EVar "subject")) (EVar "implTvMap")) (EVar "reqs")) (EVar "survivingIds")) (EFieldAccess (EVar "o") "loc")) (EApp (EVar "dedupI") (EApp (EVar "numObligIds") (EVar "o"))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkImplHeadNumObligations") (EVar "mctx")) (EVar "subject")) (EVar "implTvMap")) (EVar "reqs")) (EVar "survivingIds")) (EVar "rest")))))
(DTypeSig false "checkImplHeadNumIds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Unit")))))))))
(DFunDef false "checkImplHeadNumIds" ((PVar "mctx") PWild PWild PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "checkImplHeadNumIds" ((PVar "mctx") (PVar "subject") (PVar "implTvMap") (PVar "reqs") (PVar "survivingIds") (PVar "loc") (PCons (PVar "id") (PVar "rest"))) (EBlock (DoExpr (EMatch (EApp (EApp (EVar "survivorNameOfId") (EVar "id")) (EVar "implTvMap")) (arm (PCon "Some" (PVar "vname")) () (EIf (EBinOp "&&" (EApp (EApp (EVar "omHasKey") (EApp (EVar "intToString") (EVar "id"))) (EVar "survivingIds")) (EApp (EVar "not") (EApp (EApp (EApp (EApp (EApp (EVar "implRequiresRoot") (EVar "mctx")) (ELit (LString "Num"))) (EVar "id")) (EVar "implTvMap")) (EVar "reqs")))) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-IMPL-MISSING-REQUIRES"))) (EVar "loc")) (EApp (EApp (EApp (EVar "undeclaredImplPrerequisiteMsg") (EVar "subject")) (ELit (LString "Num"))) (EVar "vname"))) (ELit LUnit))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkImplHeadNumIds") (EVar "mctx")) (EVar "subject")) (EVar "implTvMap")) (EVar "reqs")) (EVar "survivingIds")) (EVar "loc")) (EVar "rest")))))
(DTypeSig false "implRequiresRoot" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyCon "Bool")))))))
(DFunDef false "implRequiresRoot" ((PVar "mctx") PWild PWild PWild (PList)) (EVar "False"))
(DFunDef false "implRequiresRoot" ((PVar "mctx") (PVar "wanted") (PVar "id") (PVar "implTvMap") (PCons (PRec "Require" ((rf "requireHead" (PVar "iface")) (rf "requireArgs" (PVar "args"))) true) (PVar "rest"))) (EBinOp "||" (EBinOp "&&" (EApp (EApp (EVar "contains") (EVar "wanted")) (EApp (EApp (EVar "ifaceSelfAndSupers") (EVar "mctx")) (EVar "iface"))) (EApp (EApp (EApp (EVar "requireArgsAreRoot") (EVar "id")) (EVar "implTvMap")) (EVar "args"))) (EApp (EApp (EApp (EApp (EApp (EVar "implRequiresRoot") (EVar "mctx")) (EVar "wanted")) (EVar "id")) (EVar "implTvMap")) (EVar "rest"))))
(DTypeSig false "requireArgsAreRoot" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Bool")))))
(DFunDef false "requireArgsAreRoot" ((PVar "id") (PVar "implTvMap") (PList (PCon "TyVar" (PVar "name")))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EVar "implTvMap")) (arm (PCon "Some" (PVar "m")) () (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EBinOp "==" (EApp (EVar "tyvarId") (EVar "cell")) (EVar "id"))) (arm PWild () (EVar "False")))) (arm (PCon "None") () (EVar "False"))))
(DFunDef false "requireArgsAreRoot" (PWild PWild PWild) (EVar "False"))
(DTypeSig false "implHeadVarRoots" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "HeadVarRoot")))))
(DFunDef false "implHeadVarRoots" ((PVar "implTvMap")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "p")) (EMatch (EApp (EVar "headVarRootOf") (EApp (EVar "snd") (EVar "p"))) (arm (PCon "Some" (PVar "root")) () (EListLit (ETuple (EApp (EVar "fst") (EVar "p")) (EVar "root")))) (arm (PCon "None") () (EListLit))))) (EVar "implTvMap")))
(DTypeSig false "implHeadTypeVarRoots" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "implHeadTypeVarRoots" ((PVar "implTvMap")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "p")) (EMatch (EApp (EVar "snd") (EVar "p")) (arm (PCon "TypeVarRoot" (PVar "id")) () (EListLit (ETuple (EApp (EVar "fst") (EVar "p")) (EVar "id")))) (arm (PCon "RowVarRoot" PWild) () (EListLit))))) (EApp (EVar "implHeadVarRoots") (EVar "implTvMap"))))
(DTypeSig false "headVarsNarrowedBy" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "HeadVarRoot"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "headVarsNarrowedBy" ((PVar "before") (PVar "implTvMap")) (EBlock (DoLet false false (PVar "after") (EApp (EVar "implHeadVarRoots") (EVar "implTvMap"))) (DoExpr (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "headVarNarrowed") (EVar "before")) (EVar "after"))) (EVar "before"))))))
(DTypeSig false "headVarNarrowed" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "HeadVarRoot"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "HeadVarRoot"))) (TyFun (TyTuple (TyCon "String") (TyCon "HeadVarRoot")) (TyCon "Bool")))))
(DFunDef false "headVarNarrowed" ((PVar "before") (PVar "after") (PTuple (PVar "name") (PVar "root0"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EVar "after")) (arm (PCon "None") () (EVar "True")) (arm (PCon "Some" (PVar "root")) () (EApp (EApp (EVar "anyList") (ELam ((PVar "other")) (EBinOp "&&" (EBinOp "/=" (EApp (EVar "snd") (EVar "other")) (EVar "root0")) (EBinOp "==" (EApp (EApp (EVar "lookupAssoc") (EApp (EVar "fst") (EVar "other"))) (EVar "after")) (EApp (EVar "Some") (EVar "root")))))) (EVar "before")))))
(DTypeSig false "checkImplHeadRigidity" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "ImplBodySite") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "HeadVarRoot"))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit"))))))))
(DFunDef false "checkImplHeadRigidity" ((PVar "mctx") (PVar "subject") (PVar "iface") (PVar "site") (PVar "before") (PVar "loc")) (EMatch (EApp (EApp (EVar "headVarsNarrowedBy") (EVar "before")) (EFieldAccess (EVar "site") "ibImplTvMap")) (arm (PList) () (ELit LUnit)) (arm (PVar "narrowed") () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-IMPL-TOO-SPECIFIC"))) (EVar "loc")) (EApp (EApp (EApp (EVar "narrowsImplHeadMsg") (EVar "subject")) (EVar "narrowed")) (EApp (EApp (EVar "narrowedImplHead") (EVar "iface")) (EVar "site")))))))
(DTypeSig false "narrowedImplHead" (TyFun (TyCon "String") (TyFun (TyCon "ImplBodySite") (TyCon "String"))))
(DFunDef false "narrowedImplHead" ((PVar "iface") (PVar "site")) (EBlock (DoLet false false (PVar "named") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (ETuple (EApp (EVar "snd") (EVar "p")) (EApp (EVar "fst") (EVar "p"))))) (EApp (EVar "implHeadTypeVarRoots") (EFieldAccess (EVar "site") "ibImplTvMap")))) (DoExpr (EApp (EApp (EVar "join") (ELit (LString " "))) (EBinOp "::" (ELit (LString "impl")) (EBinOp "::" (EVar "iface") (EApp (EApp (EApp (EApp (EVar "ppEach") (EApp (EVar "Ref") (EVar "named"))) (EApp (EVar "Ref") (ELit (LInt 0)))) (ELit (LInt 3))) (EFieldAccess (EVar "site") "ibHeadMonos"))))))))
(DTypeSig false "checkImplHeadPrerequisites" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "ImplBodySite") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "Loc")))) (TyCon "Unit"))))))))))
(DFunDef false "checkImplHeadPrerequisites" ((PVar "mctx") (PVar "subject") (PVar "iface") (PVar "site") (PVar "methodTvs") (PVar "mty") (PVar "addedObls") (PVar "addedCallObls")) (EMatch (EApp (EVar "implHeadTypeVarRoots") (EFieldAccess (EVar "site") "ibImplTvMap")) (arm (PList) () (ELit LUnit)) (arm (PVar "roots") () (EBlock (DoLet false false (PVar "givens") (EApp (EApp (EApp (EApp (EApp (EVar "implBodyGivens") (EVar "mctx")) (EVar "iface")) (EVar "site")) (EVar "methodTvs")) (EVar "mty"))) (DoLet false false (PVar "goals") (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EVar "oblPredOf") (EFieldAccess (EVar "mctx") "mcGraph"))) (EVar "addedObls")) (EApp (EApp (EVar "flatMap") (EVar "callPredOf")) (EVar "addedCallObls")))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "g")) (EApp (EApp (EApp (EApp (EApp (EVar "checkImplHeadGoal") (EApp (EVar "siteFor") (EVar "mctx"))) (EVar "subject")) (EVar "roots")) (EVar "givens")) (EVar "g")))) (ELit LUnit)) (EVar "goals")))))))
(DTypeSig false "checkImplHeadGoal" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "PredicateSlot")) (TyFun (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Unit")))))))
(DFunDef false "checkImplHeadGoal" ((PVar "sx") (PVar "subject") (PVar "roots") (PVar "givens") (PTuple (PVar "iface") (PVar "ds") (PVar "loc"))) (EBlock (DoLet false false (PVar "args") (EApp (EApp (EVar "map") (EVar "normalize")) (EVar "ds"))) (DoLet false false (PVar "rootIds") (EApp (EApp (EVar "map") (EVar "snd")) (EVar "roots"))) (DoExpr (EIf (EApp (EApp (EVar "any") (ELam ((PVar "i")) (EApp (EApp (EVar "elem") (EVar "i")) (EVar "rootIds")))) (EApp (EApp (EVar "flatMap") (EVar "monoUnboundIds")) (EVar "args"))) (EBlock (DoLet false false (PVar "headIds") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (ELam ((PVar "r")) (EApp (EVar "intToString") (EApp (EVar "snd") (EVar "r"))))) (EVar "roots"))) (EVar "omEmpty"))) (DoLet false false (PVar "leaves") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "implGoalResiduals") (ERecordUpdate (EVar "sx") ((fa "sxSite" (EVar "loc"))))) (EApp (EVar "reqWalkStart") (ELit LUnit))) (EVar "headIds")) (EVar "givens")) (EVar "iface")) (EVar "args"))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "leaf")) (EApp (EApp (EApp (EApp (EApp (EVar "reportImplHeadResidual") (EFieldAccess (EVar "sx") "sxModule")) (EVar "subject")) (EVar "roots")) (EVar "loc")) (EVar "leaf")))) (ELit LUnit)) (EVar "leaves")))) (ELit LUnit)))))
(DTypeSig false "implBodyGivens" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "ImplBodySite") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "PredicateSlot"))))))))
(DFunDef false "implBodyGivens" ((PVar "mctx") (PVar "iface") (PVar "site") (PVar "methodTvs") (PVar "mty")) (EBlock (DoLet false false (PVar "declared") (EBinOp "++" (EApp (EApp (EVar "map") (EApp (EApp (EVar "requirePredicateSlot") (EVar "mctx")) (EFieldAccess (EVar "site") "ibImplTvMap"))) (EFieldAccess (EVar "site") "ibRequires")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "constraintPredicateSlot") (EVar "mctx")) (EVar "methodTvs"))) (EApp (EVar "sigConstraintsOf") (EVar "mty"))))) (DoExpr (EBinOp "::" (EApp (EApp (EVar "knownPredicateSlot") (EVar "iface")) (EFieldAccess (EVar "site") "ibHeadMonos")) (EBinOp "++" (EVar "declared") (EApp (EApp (EVar "flatMap") (ELam ((PVar "s")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EVar "predicateSlotKnownSupers") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "s"))))) (EVar "declared")))))))
(DTypeSig false "requirePredicateSlot" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Require") (TyCon "PredicateSlot")))))
(DFunDef false "requirePredicateSlot" ((PVar "mctx") (PVar "implTvMap") (PRec "Require" ((rf "requireHead" (PVar "h")) (rf "requireArgs" (PVar "rargs")) (rf "requireOrigin" (PVar "o"))) false)) (EApp (EApp (EVar "knownPredicateSlot") (ERecordCreate "IfaceRef" ((fa "irName" (EVar "h")) (fa "irOrigin" (EVar "o"))))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "fromAstType") (EVar "mctx")) (EVar "implTvMap"))) (EVar "rargs"))))
(DTypeSig false "constraintPredicateSlot" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Constraint") (TyCon "PredicateSlot")))))
(DFunDef false "constraintPredicateSlot" ((PVar "mctx") (PVar "tvs") (PRec "Constraint" ((rf "constraintHead" (PVar "h")) (rf "constraintArgs" (PVar "cargs")) (rf "constraintOrigin" (PVar "o"))) false)) (EApp (EApp (EVar "knownPredicateSlot") (ERecordCreate "IfaceRef" ((fa "irName" (EVar "h")) (fa "irOrigin" (EVar "o"))))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "fromAstType") (EVar "mctx")) (EVar "tvs"))) (EVar "cargs"))))
(DTypeSig false "knownPredicateSlot" (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "PredicateSlot"))))
(DFunDef false "knownPredicateSlot" ((PVar "iface") (PVar "args")) (ERecordCreate "PredicateSlot" ((fa "psIface" (EVar "iface")) (fa "psArgs" (EApp (EVar "PSArgsKnown") (EVar "args"))) (fa "psBoundIds" (EApp (EVar "dedupI") (EApp (EApp (EVar "flatMap") (EVar "monoTyvarIds")) (EVar "args")))))))
(DTypeSig false "reportImplHeadResidual" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))) (TyCon "Unit")))))))
(DFunDef false "reportImplHeadResidual" ((PVar "mctx") (PVar "subject") (PVar "roots") (PVar "loc") (PTuple (PVar "iface") (PVar "args"))) (EBlock (DoLet false false (PVar "ids") (EApp (EApp (EVar "flatMap") (EVar "monoUnboundIds")) (EVar "args"))) (DoLet false false (PVar "headIds") (EApp (EApp (EVar "map") (EVar "snd")) (EVar "roots"))) (DoLet false false (PVar "named") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (ETuple (EApp (EVar "snd") (EVar "p")) (EApp (EVar "fst") (EVar "p"))))) (EVar "roots"))) (DoLet false false (PVar "rendered") (EApp (EApp (EApp (EApp (EVar "ppEach") (EApp (EVar "Ref") (EVar "named"))) (EApp (EVar "Ref") (ELit (LInt 0)))) (ELit (LInt 3))) (EVar "args"))) (DoLet false false (PVar "pred") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "iface") "irName"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "join") (ELit (LString " "))) (EVar "rendered")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "ids")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "i")) (EApp (EApp (EVar "containsI") (EVar "i")) (EVar "headIds")))) (EVar "ids")))) (ELit LUnit) (EIf (EApp (EApp (EVar "allList") (ELam ((PVar "i")) (EApp (EApp (EVar "containsI") (EVar "i")) (EVar "headIds")))) (EVar "ids")) (EBlock (DoLet false false (PVar "msg") (EMatch (ETuple (EApp (EApp (EVar "map") (EVar "normalize")) (EVar "args")) (EVar "rendered")) (arm (PTuple (PList (PCon "TVar" PWild)) (PList (PVar "vname"))) () (EApp (EApp (EApp (EVar "undeclaredImplPrerequisiteMsg") (EVar "subject")) (EFieldAccess (EVar "iface") "irName")) (EVar "vname"))) (arm PWild () (EApp (EApp (EVar "undeclaredImplPredicateMsg") (EVar "subject")) (EVar "pred"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-IMPL-MISSING-REQUIRES"))) (EVar "loc")) (EVar "msg")))) (EIf (EApp (EApp (EApp (EApp (EVar "answeredOnlyByBindingHead") (EVar "mctx")) (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (ELam ((PVar "r")) (EApp (EVar "intToString") (EApp (EVar "snd") (EVar "r"))))) (EVar "roots"))) (EVar "omEmpty"))) (EVar "iface")) (EVar "args")) (EBlock (DoLet false false (PVar "fixed") (EApp (EVar "dedup") (EApp (EApp (EVar "flatMap") (ELam ((PVar "r")) (EIf (EApp (EApp (EVar "containsI") (EApp (EVar "snd") (EVar "r"))) (EVar "ids")) (EListLit (EApp (EVar "fst") (EVar "r"))) (EListLit)))) (EVar "roots")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-IMPL-MISSING-REQUIRES"))) (EVar "loc")) (EApp (EApp (EApp (EVar "implGoalFixesHeadMsg") (EVar "subject")) (EVar "pred")) (EVar "fixed"))))) (EIf (EApp (EVar "isEmptyL") (EApp (EApp (EApp (EApp (EVar "goalCandidates") (EVar "mctx")) (EVar "omEmpty")) (EVar "args")) (EApp (EApp (EApp (EVar "goalRows") (EVar "mctx")) (EVar "iface")) (EVar "args")))) (EApp (EApp (EApp (EApp (EVar "reportUndeterminedNoImpl") (EVar "mctx")) (EVar "iface")) (EVar "args")) (EVar "loc")) (ELit LUnit))))))))
(DTypeSig false "checkSurvivorCallObligations" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "Loc")))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit"))))))))))
(DFunDef false "checkSurvivorCallObligations" ((PVar "mctx") PWild PWild PWild PWild PWild (PList) PWild) (ELit LUnit))
(DFunDef false "checkSurvivorCallObligations" ((PVar "mctx") (PVar "subject") (PVar "ownIface") (PVar "ownTyparams") (PVar "mty") (PVar "extraMap") (PCons (PTuple (PVar "oiface") (PVar "monos") PWild) (PVar "rest")) (PVar "loc")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkSurvivorDispatchMonos") (EVar "mctx")) (EVar "subject")) (EVar "ownIface")) (EVar "ownTyparams")) (EVar "mty")) (EVar "extraMap")) (EFieldAccess (EVar "oiface") "irName")) (EVar "monos")) (EVar "loc"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkSurvivorCallObligations") (EVar "mctx")) (EVar "subject")) (EVar "ownIface")) (EVar "ownTyparams")) (EVar "mty")) (EVar "extraMap")) (EVar "rest")) (EVar "loc")))))
(DTypeSig false "methodLevelConstraintMonos" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "Mono"))))))
(DFunDef false "methodLevelConstraintMonos" ((PVar "ifaceParams") (PVar "mty") (PVar "tvMap")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "name")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EVar "tvMap")) (arm (PCon "Some" (PVar "m")) () (EListLit (EVar "m"))) (arm (PCon "None") () (EListLit))))) (EApp (EApp (EVar "methodLevelConstraintVarNames") (EVar "ifaceParams")) (EVar "mty"))))
(DTypeSig false "methodConstraintSlotIds" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "methodConstraintSlotIds" ((PVar "typarams") (PCon "TyConstrained" (PVar "cs") (PVar "t")) (PVar "tvs")) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "constraintSlotId") (EVar "typarams")) (EVar "tvs"))) (EVar "cs")) (EApp (EApp (EApp (EVar "methodConstraintSlotIds") (EVar "typarams")) (EVar "t")) (EVar "tvs"))))
(DFunDef false "methodConstraintSlotIds" ((PVar "typarams") (PCon "TyEffect" PWild PWild (PVar "t")) (PVar "tvs")) (EApp (EApp (EApp (EVar "methodConstraintSlotIds") (EVar "typarams")) (EVar "t")) (EVar "tvs")))
(DFunDef false "methodConstraintSlotIds" (PWild PWild PWild) (EListLit))
(DTypeSig false "constraintSlotId" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "constraintSlotId" ((PVar "typarams") (PVar "tvs") (PVar "c")) (EMatch (EApp (EApp (EVar "constraintSlotDispatchVar") (EVar "typarams")) (EVar "c")) (arm (PList) () (EListLit)) (arm (PCons (PVar "n") PWild) () (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "tvs")) (arm (PCon "Some" (PVar "m")) () (EListLit (EApp (EVar "monoTyvarId") (EVar "m")))) (arm (PCon "None") () (EListLit))))))
(DTypeSig true "calleeNumObls" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "UObligation"))))))
(DFunDef false "calleeNumObls" ((PVar "mctx") (PVar "callN0") (PVar "dictN0")) (EBinOp "++" (EApp (EApp (EVar "numCallObls") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "callUOblsWindow") (EVar "mctx")) (EVar "callN0"))) (EApp (EApp (EVar "numDictObls") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "dictAppsSince") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "dictN0")))))
(DTypeSig true "numCallObls" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyApp (TyCon "List") (TyCon "UObligation")))))
(DFunDef false "numCallObls" ((PVar "gctx") (PList)) (EListLit))
(DFunDef false "numCallObls" ((PVar "gctx") (PCons (PVar "o") (PVar "rest"))) (EMatch (ETuple (EFieldAccess (EFieldAccess (EFieldAccess (EVar "o") "pred") "iface") "irName") (EApp (EApp (EVar "uOblArgs") (EVar "gctx")) (EVar "o"))) (arm (PTuple (PLit (LString "Num")) (PList (PVar "mono"))) () (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkMethodOccObl") (EApp (EApp (EVar "builtinIfaceRef") (EVar "gctx")) (EVar "BNum"))) (EListLit (ELit (LString "a")))) (EApp (EVar "TyVar") (ELit (LString "a")))) (EVar "mono")) (EListLit)) (EVar "PNumLit")) (EFieldAccess (EVar "o") "loc")) (EFieldAccess (EVar "o") "uoScope")) (EApp (EApp (EVar "numCallObls") (EVar "gctx")) (EVar "rest")))) (arm PWild () (EApp (EApp (EVar "numCallObls") (EVar "gctx")) (EVar "rest")))))
(DTypeSig false "numDictObls" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "PendingDictApp")) (TyApp (TyCon "List") (TyCon "UObligation")))))
(DFunDef false "numDictObls" ((PVar "gctx") (PList)) (EListLit))
(DFunDef false "numDictObls" ((PVar "gctx") (PCons (PVar "app") (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (ELam ((PVar "p")) (EIf (EBinOp "==" (EApp (EVar "fst") (EVar "p")) (ELit (LString "Num"))) (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkMethodOccObl") (EApp (EApp (EVar "builtinIfaceRef") (EVar "gctx")) (EVar "BNum"))) (EListLit (ELit (LString "a")))) (EApp (EVar "TyVar") (ELit (LString "a")))) (EApp (EVar "snd") (EVar "p"))) (EListLit)) (EVar "PNumLit")) (EFieldAccess (EVar "app") "pdaLoc")) (EFieldAccess (EVar "app") "pdaScope"))) (EListLit)))) (EApp (EApp (EVar "zip") (EApp (EApp (EVar "map") (ELam ((PVar "i")) (EFieldAccess (EVar "i") "irName"))) (EFieldAccess (EVar "app") "pdaIfaces"))) (EFieldAccess (EVar "app") "pdaMonos"))) (EApp (EApp (EVar "numDictObls") (EVar "gctx")) (EVar "rest"))))
# MARK
(DUse false (UseGroup ("types" "tc_types") ((mem "BuiltinClass" true) (mem "CohSweep" true) (mem "DeclaringBinder" true) (mem "GrantBinder" true) (mem "HeadVarRoot" true) (mem "ImplBodySite" true) (mem "Kind" true) (mem "MethodBodyCheck" true) (mem "MethodBodyInstance" true) (mem "MethodBodyKind" true) (mem "MStep" true) (mem "NumBoundary" true) (mem "NumBoundaryDisposition" true) (mem "NumGuard" true) (mem "PredicateSlot" true) (mem "PredicateSlotArgs" true) (mem "Provenance" true) (mem "ReqStep" true) (mem "ScopedImplMethod" true) (mem "SiteCtx" true) (mem "TcEnv" true) (mem "UObligation" true) (mem "CeRow" false) (mem "ClassEnv" false) (mem "CohImpl" false) (mem "CohScan" false) (mem "GraphCtx" false) (mem "ImplEnv" false) (mem "ImplRow" false) (mem "ModuleCtx" false) (mem "PendingDictApp" false) (mem "ReqWalk" false) (mem "siteFor" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "allArrowEffs" false) (mem "anyConcreteHead" false) (mem "anyContainsI" false) (mem "anyMember" false) (mem "authCellsIn" false) (mem "authOrderIn" false) (mem "authOrderRow" false) (mem "cohEqMono" false) (mem "cohOverlap" false) (mem "cohPpPair" false) (mem "containsI" false) (mem "dedupI" false) (mem "hasDupI" false) (mem "headVarRootOf" false) (mem "instantiateNamedMonos" false) (mem "isUnboundTvar" false) (mem "matchOneSided" false) (mem "monoRootIdSet" false) (mem "monoTyvarId" false) (mem "monoTyvarIds" false) (mem "monoUnboundIds" false) (mem "peelQual" false) (mem "sigTvarIds" false) (mem "stripTyWrap" false) (mem "tyAppSpine" false) (mem "tyStep" false) (mem "tyStructEq" false) (mem "tyvarId" false) (mem "tyVarNames" false))))
(DUse false (UseGroup ("types" "tc_diag_text") ((mem "backticked" false) (mem "cohCrossModuleMsg" false) (mem "cohIncomparableHelp" false) (mem "cohOverlapMsg" false) (mem "cohPreludeOverlapMsg" false) (mem "collapsesTyvarsMsg" false) (mem "derivableIface" false) (mem "implGoalFixesHeadMsg" false) (mem "implHeadIndexMsg" false) (mem "implKindMismatchMsg" false) (mem "implTupleHeadKindMsg" false) (mem "methodBodyLaunderMsg" false) (mem "methodBodySubject" false) (mem "missingImplMethodMsg" false) (mem "narrowsImplHeadMsg" false) (mem "pinsTyvarMsg" false) (mem "qualifiedIfaceLabel" false) (mem "superContextNoImplMsg" false) (mem "superContextUndeclaredMsg" false) (mem "undeclaredImplPredicateMsg" false) (mem "undeclaredImplPrerequisiteMsg" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "callUOblsWindow" false) (mem "currentScopeStore" false) (mem "defaultReceiverOrdinal" false) (mem "dynAtIfSome" false) (mem "emptySigVars" false) (mem "envAtIfSome" false) (mem "mctxAtIfSome" false) (mem "wMark" false) (mem "wRestore" false) (mem "wSnapshot" false) (mem "wWindow" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "anyKRow" false) (mem "builtinIfaceRef" false) (mem "ceLookupAt" false) (mem "ceMethodTyAt" false) (mem "ceRequiredAt" false) (mem "ceRowIfaceName" false) (mem "ceRowLoc" false) (mem "ceRowMethods" false) (mem "ceRowsOwnedBy" false) (mem "ceRowSupers" false) (mem "ceRowTyparams" false) (mem "ceSlotKindsAt" false) (mem "constraintSlotDispatchVar" false) (mem "declGradedScope" false) (mem "effTailNames" false) (mem "extendVars" false) (mem "ieRowInst" false) (mem "ieRowLoc" false) (mem "ieRowOrd" false) (mem "ieRowsAll" false) (mem "ieRowsOwnedBy" false) (mem "ieRowsVisibleAt" false) (mem "ieRowTriple" false) (mem "ifaceTabKey" false) (mem "instRefMid" false) (mem "methodLevelConstraintVarNames" false) (mem "removeAllS" false) (mem "tyTabKey" false))))
(DUse false (UseGroup ("types" "tc_diag") ((mem "erredDuring" false) (mem "pushTypeError" false) (mem "pushTypeErrorAt" false) (mem "pushTypeErrorOnceAt" false) (mem "pushTypeErrorOncePerSite" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "captureScope" false) (mem "closeScope" false) (mem "enterLevel" false) (mem "exitLevel" false) (mem "freshAuthBinderRanged" false) (mem "freshTvMap" false) (mem "instantiateMethodTracked" false) (mem "rowInto" false) (mem "unifyInto" false))))
(DUse false (UseGroup ("types" "tc_decls_types") ((mem "authArgBindersIn" false) (mem "bindingForceFromAst" false) (mem "fromAstType" false) (mem "fromAstTypeE" false) (mem "kindsEq" false) (mem "patternSlotNamesIn" false) (mem "rowArgNamesIn" false) (mem "sigConstraintsOf" false) (mem "sigVarsWithAuths" false))))
(DUse false (UseGroup ("types" "tc_decls") ((mem "dedupBinders" false) (mem "methodSchemesPure" false) (mem "sigToSchemeTvsIn" false) (mem "sigVarsFor" false) (mem "tyConNamesInTy" false))))
(DUse false (UseGroup ("types" "tc_solve_givens") ((mem "givenAnswers" false) (mem "predicateSlotKnownSupers" false) (mem "publishMethodPredGivens" false) (mem "registerFunPredGiven" false) (mem "registerImplMethodDicts" false) (mem "registerMethodDictSlots" false))))
(DUse false (UseGroup ("types" "tc_solve_entail") ((mem "goalCandidates" false) (mem "goalRows" false) (mem "reqWalkEnter" false) (mem "reqWalkMemo" false) (mem "reqWalkSeed" false) (mem "reqWalkStart" false) (mem "superParamsOf" false))))
(DUse false (UseGroup ("types" "tc_solve") ((mem "answeredOnlyByBindingHead" false) (mem "determineByUniqueInstance" false) (mem "dictAppsSince" false) (mem "goalsMark" false) (mem "improveByUniqueImpl" false) (mem "noteWalkGoalFollowed" false) (mem "openScope" false) (mem "rigidHeadInstanceContext" false) (mem "solvedCleanly" false) (mem "solvedOnWalk" false) (mem "uOblArgs" false) (mem "walkGoalFollowed" false))))
(DUse false (UseGroup ("types" "tc_solve_check") ((mem "callOblsWindow" false) (mem "callPredOf" false) (mem "checkSigVarGoals" false) (mem "checkSurvivorDispatchMonos" false) (mem "checkSurvivorObligations" false) (mem "finalizeNumBoundary" false) (mem "ifaceSelfAndSupers" false) (mem "implGoalResiduals" false) (mem "numConstrainedIds" false) (mem "numObligIds" false) (mem "oblPredOf" false) (mem "prerequisiteOnWalk" false) (mem "registerImplRequires" false) (mem "rejectUndeterminedVectors" false) (mem "rejectWithheldAmbiguity" false) (mem "reportUndeterminedNoImpl" false) (mem "reqWalkReported" false) (mem "survivorNameOfId" false))))
(DUse false (UseGroup ("types" "tc_effects") ((mem "beginEffectContract" false) (mem "checkMethodEffVarRigidity" false) (mem "eagerIndexOnlyVars" false) (mem "finishEffectContract" false) (mem "indexOnlyEffVars" false) (mem "launderEscapeFromLog" false) (mem "markSourceless" false) (mem "methodGrantOf" false) (mem "performSiteIn" false) (mem "recordClauseFileBound" false))))
(DUse false (UseGroup ("types" "tc_occurrence") ((mem "mkMethodOccObl" false))))
(DUse false (UseGroup ("types" "tc_groups") ((mem "exprLoc" false) (mem "requireGoalsBelow" false) (mem "sccProtectedSignatureIds" false))))
(DUse false (UseGroup ("types" "tc_infer") ((mem "appArgLoc" false) (mem "inferBindingChecked" false) (mem "valueSpanLoc" false))))
(DUse false (UseGroup ("types" "scopes") ((mem "DefaultBodyIdentity" true) (mem "ScopeOwner" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Constraint" true) (mem "Decl" true) (mem "Expr" true) (mem "IfaceMethod" true) (mem "ImplMethod" true) (mem "Loc" true) (mem "MethodDefault" true) (mem "Pat" true) (mem "Require" true) (mem "Super" true) (mem "TabKey" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "firstTyLoc" false) (mem "firstTyLocList" false) (mem "implMethodName" false) (mem "lookupTab" false) (mem "orElseLoc" false) (mem "sameTyConHead" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Mono" true) (mem "lookupAssocI" false) (mem "normalize" false) (mem "ppEach" false) (mem "ppTy" false) (mem "ppTyAtom" false))))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("types" "evidence") ((mem "ScopeId" true))))
(DUse false (UseGroup ("types" "publish") ((mem "TcDiag" true))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "anyList" false) (mem "contains" false) (mem "dedup" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "isSome" false) (mem "listLen" false) (mem "lookupAssoc" false))))
(DUse false (UseGroup ("list") ((mem "drop" false) (mem "get" false) (mem "range" false) (mem "reverse" false) (mem "zip" false))))
(DUse false (UseGroup ("string") ((mem "join" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "effrowNorm" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "exprSpanLoc" false))))
(DUse false (UseGroup ("frontend" "resolve") ((mem "firstExprLoc" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "ifaceWordOf" false))))
(DUse false (UseGroup ("types" "superclass") ((mem "lookupPos" false) (mem "mapAll" false) (mem "superIfaceRef" false))))
(DUse false (UseGroup ("types" "registry") ((mem "regKeyOfTab" false))))
(DUse false (UseAlias ("types" "scopes") "Scopes"))
(DUse false (UseAlias ("map") "IdMap"))
(DTypeSig true "checkGradedImplHeads" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))))
(DFunDef false "checkGradedImplHeads" ((PVar "mctx") PWild PWild (PList)) (ELit LUnit))
(DFunDef false "checkGradedImplHeads" ((PVar "mctx") (PVar "ce") (PVar "cur") (PCons (PVar "d") (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "checkGradedImplHeadDecl") (EVar "mctx")) (EVar "ce")) (EVar "cur")) (EVar "d"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkGradedImplHeads") (EVar "mctx")) (EVar "ce")) (EVar "cur")) (EVar "rest")))))
(DTypeSig false "checkGradedImplHeadDecl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyFun (TyCon "Decl") (TyCon "Unit"))))))
(DFunDef false "checkGradedImplHeadDecl" ((PVar "mctx") (PVar "ce") (PVar "cur") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EVar "checkGradedImplHeadDecl") (EVar "mctx")) (EVar "ce")) (EVar "cur")) (EVar "d")))
(DFunDef false "checkGradedImplHeadDecl" ((PVar "mctx") (PVar "ce") (PVar "cur") (PRec "DImpl" ((rf "iface" None) (rf "tys" None) (rf "implOrigin" (PVar "o"))) true)) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkGradedImplTys") (EVar "mctx")) (EVar "ce")) (EVar "cur")) (EVar "o")) (EVar "iface")) (ELit (LInt 0))) (EVar "tys")))
(DFunDef false "checkGradedImplHeadDecl" ((PVar "mctx") PWild PWild PWild) (ELit LUnit))
(DTypeSig false "checkGradedImplTys" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Unit")))))))))
(DFunDef false "checkGradedImplTys" ((PVar "mctx") PWild PWild PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "checkGradedImplTys" ((PVar "mctx") (PVar "ce") (PVar "cur") (PVar "o") (PVar "iface") (PVar "i") (PCons (PVar "t") (PVar "rest"))) (EBlock (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "ceSlotKindsAt") (EApp (EVar "regKeyOfTab") (EApp (EApp (EVar "ifaceTabKey") (EVar "o")) (EVar "iface")))) (EVar "cur")) (EVar "i")) (EVar "ce")) (arm (PCon "Some" (PVar "want")) ((GBool (EApp (EVar "anyKRow") (EVar "want")))) (EApp (EApp (EApp (EApp (EVar "checkGradedImplHead") (EVar "mctx")) (EVar "iface")) (EVar "t")) (EVar "want"))) (arm PWild () (ELit LUnit)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkGradedImplTys") (EVar "mctx")) (EVar "ce")) (EVar "cur")) (EVar "o")) (EVar "iface")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")))))
(DTypeSig false "checkGradedImplHead" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyCon "Unit"))))))
(DFunDef false "checkGradedImplHead" ((PVar "mctx") (PVar "iface") (PVar "t") (PVar "want")) (EMatch (EApp (EVar "tyAppSpine") (EVar "t")) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConLoc" (PVar "loc")) (rf "tyConOrigin" (PVar "o"))) false) (PVar "applied")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkGradedImplHeadCon") (EVar "mctx")) (EVar "iface")) (EVar "o")) (EVar "n")) (EVar "loc")) (EApp (EVar "listLen") (EVar "applied"))) (EVar "want"))) (arm (PTuple (PCon "TyTuple" (PVar "ts")) PWild) () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (ELit (LString "T-IMPL-KIND-MISMATCH"))) (EApp (EVar "firstTyLocList") (EVar "ts"))) (EApp (EApp (EApp (EVar "implTupleHeadKindMsg") (EVar "iface")) (EApp (EVar "listLen") (EVar "ts"))) (EVar "want")))) (arm PWild () (ELit LUnit))))
(DTypeSig false "checkGradedImplHeadCon" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyCon "Unit")))))))))
(DFunDef false "checkGradedImplHeadCon" ((PVar "mctx") (PVar "iface") (PVar "o") (PVar "n") (PVar "loc") (PVar "nApplied") (PVar "want")) (EMatch (EApp (EApp (EApp (EApp (EVar "headRemainingKinds") (EVar "mctx")) (EVar "o")) (EVar "n")) (EVar "nApplied")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "got")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkGradedImplHeadKinds") (EVar "mctx")) (EVar "iface")) (EVar "n")) (EVar "loc")) (EVar "nApplied")) (EVar "want")) (EVar "got")))))
(DTypeSig false "headRemainingKinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Kind"))))))))
(DFunDef false "headRemainingKinds" ((PVar "mctx") (PVar "o") (PVar "n") (PVar "nApplied")) (ELetGroup ((lgb "key" (clause () (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n"))))) (EIf (EApp (EVar "isSome") (EApp (EApp (EVar "lookupTab") (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "aliasTableRef") "value"))) (EVar "None") (EIf (EVar "otherwise") (EApp (EApp (EMethodRef "map") (EApp (EVar "drop") (EVar "nApplied"))) (EApp (EApp (EVar "lookupTab") (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamKindsRef") "value"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "checkGradedImplHeadKinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyCon "Unit")))))))))
(DFunDef false "checkGradedImplHeadKinds" ((PVar "mctx") (PVar "iface") (PVar "n") (PVar "loc") (PVar "nApplied") (PVar "want") (PVar "got")) (EIf (EApp (EApp (EVar "kindsEq") (EVar "got")) (EVar "want")) (ELit LUnit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (ELit (LString "T-IMPL-KIND-MISMATCH"))) (EVar "loc")) (EApp (EApp (EApp (EApp (EApp (EVar "implKindMismatchMsg") (EVar "iface")) (EVar "n")) (EVar "nApplied")) (EVar "want")) (EVar "got"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "registerMethodBodyGrants" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "MethodBodyInstance") (TyFun (TyCon "ScopeId") (TyCon "Unit"))))))))
(DFunDef false "registerMethodBodyGrants" ((PVar "gctx") (PVar "iface") (PVar "mname") (PVar "heads") (PVar "inst") (PCon "ScopeId" (PVar "sid"))) (EBlock (DoLet false false (PVar "headIds") (EApp (EVar "IdMap.keys") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "h")) (EApp (EApp (EVar "authCellsIn") (EVar "h")) (EVar "acc")))) (EVar "Tip")) (EVar "heads")))) (DoExpr (EApp (EApp (EVar "markSourceless") (EVar "gctx")) (EVar "headIds"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "methodGrantOf") (EVar "gctx")) (EApp (EApp (EVar "ifaceWordOf") (EFieldAccess (EVar "iface") "irOrigin")) (EFieldAccess (EVar "iface") "irName"))) (EVar "mname")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "mg")) () (EBlock (DoLet false false (PVar "own") (EApp (EApp (EVar "filterList") (ELam ((PVar "i")) (EApp (EVar "not") (EApp (EApp (EVar "containsI") (EVar "i")) (EVar "headIds"))))) (EApp (EVar "reverse") (EApp (EApp (EVar "authOrderRow") (EFieldAccess (EVar "inst") "mbiContractForce")) (EApp (EApp (EVar "authOrderIn") (EFieldAccess (EVar "inst") "mbiExpected")) (EListLit)))))) (DoLet false false (PVar "ids") (EApp (EApp (EMethodRef "map") (ELam ((PVar "k")) (EApp (EApp (EVar "optionOr") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EApp (EApp (EVar "get") (EVar "k")) (EVar "own"))))) (EApp (EApp (EVar "range") (ELit (LInt 0))) (EApp (EVar "listLen") (EFieldAccess (EVar "mg") "mgNames"))))) (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsBodies")) (EApp (EApp (EApp (EVar "IdMap.set") (EVar "sid")) (EApp (EApp (EVar "BodyGrantBinder") (EVar "mname")) (EVar "ids"))) (EFieldAccess (EFieldAccess (EVar "st") "gsBodies") "value"))))))))))
(DTypeSig false "numChannelRootSet" (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "numChannelRootSet" ((PVar "obls") (PVar "channels")) (EBlock (DoLet false false (PVar "channelIds") (EApp (EVar "monoRootIdSet") (EVar "channels"))) (DoExpr (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "filterList") (ELam ((PVar "name")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "channelIds")))) (EApp (EApp (EMethodRef "map") (EVar "intToString")) (EApp (EVar "dedupI") (EApp (EVar "numConstrainedIds") (EVar "obls")))))) (EVar "omEmpty")))))
(DTypeSig false "cohFreshTys" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "cohFreshTys" ((PVar "mctx") (PVar "tys")) (EApp (EVar "snd") (EApp (EApp (EVar "implHeadMonos") (EVar "mctx")) (EVar "tys"))))
(DTypeSig false "implHeadMonos" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "Mono"))))))
(DFunDef false "implHeadMonos" ((PVar "mctx") (PVar "tys")) (EBlock (DoExpr (EApp (EApp (EVar "each") (EApp (EVar "checkImplHeadIndices") (EVar "mctx"))) (EVar "tys"))) (DoLet false false (PVar "auths") (EApp (EApp (EVar "dedupBinders") (EApp (EApp (EDictApp "flatMap") (EApp (EVar "authArgBindersIn") (EVar "mctx"))) (EVar "tys"))) (EListLit))) (DoLet false false (PVar "pats") (EApp (EApp (EDictApp "flatMap") (EApp (EVar "patternSlotNamesIn") (EVar "mctx"))) (EVar "tys"))) (DoLet false false (PVar "tvMap") (EApp (EApp (EVar "freshTvMap") (EVar "mctx")) (EApp (EApp (EVar "removeAllS") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "auths"))) (EApp (EVar "dedup") (EApp (EApp (EDictApp "flatMap") (EVar "tyVarNames")) (EVar "tys")))))) (DoLet false false (PVar "etbl") (EApp (EApp (EVar "sigVarsWithAuths") (EApp (EApp (EMethodRef "map") (ELam ((PVar "b")) (EApp (EApp (EApp (EVar "freshAuthBinderRanged") (EVar "mctx")) (EApp (EApp (EVar "contains") (EApp (EVar "fst") (EVar "b"))) (EVar "pats"))) (EVar "b")))) (EVar "auths"))) (EVar "emptySigVars"))) (DoExpr (ETuple (EVar "tvMap") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvMap"))) (EVar "tys"))))))
(DTypeSig false "checkImplHeadIndices" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyCon "Unit"))))
(DFunDef false "checkImplHeadIndices" ((PVar "mctx") (PCon "TyApp" (PVar "a") (PVar "b"))) (EMatch (EApp (EVar "tyAppSpine") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b"))) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false) (PVar "args")) () (EMatch (EApp (EApp (EVar "lookupTab") (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamKindsRef") "value")) (arm (PCon "Some" (PVar "kinds")) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EVar "kinds")) (EApp (EVar "listLen") (EVar "args"))))) (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "ka")) (EMatch (EVar "ka") (arm (PTuple (PCon "KAuth" PWild PWild) (PCon "TyAuth" (PVar "ps") (PVar "loc"))) () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOncePerSite") (EVar "mctx")) (ELit (LString "T-AUTHORITY-KIND"))) (EVar "loc")) (EApp (EApp (EVar "implHeadIndexMsg") (EVar "n")) (EApp (EVar "ppTy") (EApp (EApp (EVar "TyAuth") (EVar "ps")) (EVar "loc")))))) (arm PWild () (ELit LUnit))))) (ELit LUnit)) (EApp (EApp (EVar "zip") (EVar "kinds")) (EVar "args")))) (arm PWild () (ELit LUnit)))) (arm PWild () (ELit LUnit))))
(DFunDef false "checkImplHeadIndices" ((PVar "mctx") PWild) (ELit LUnit))
(DTypeSig false "cohImplOfRow" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ImplRow") (TyCon "CohImpl"))))
(DFunDef false "cohImplOfRow" ((PVar "mctx") (PVar "r")) (EMatch (EApp (EVar "ieRowTriple") (EVar "r")) (arm (PTuple (PVar "ir") (PVar "tys") PWild) () (EApp (EApp (EApp (EApp (EVar "CohImpl") (EVar "ir")) (EApp (EApp (EVar "cohFreshTys") (EVar "mctx")) (EVar "tys"))) (EApp (EVar "instRefMid") (EApp (EVar "ieRowInst") (EVar "r")))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstTyLocList") (EVar "tys"))) (EApp (EVar "ieRowLoc") (EVar "r")))))))
(DTypeSig false "cohPreludeOrd" (TyCon "Int"))
(DFunDef false "cohPreludeOrd" () (ELit (LInt 0)))
(DTypeSig false "cohPreludeRows" (TyFun (TyCon "ImplEnv") (TyApp (TyCon "List") (TyCon "ImplRow"))))
(DFunDef false "cohPreludeRows" ((PVar "env")) (EApp (EApp (EVar "ieRowsOwnedBy") (EVar "cohPreludeOrd")) (EVar "env")))
(DTypeSig false "cohRowsOf" (TyFun (TyCon "ImplEnv") (TyApp (TyCon "List") (TyCon "ImplRow"))))
(DFunDef false "cohRowsOf" ((PVar "env")) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EBinOp "/=" (EApp (EVar "ieRowOrd") (EVar "r")) (EVar "cohPreludeOrd")))) (EApp (EVar "ieRowsAll") (EVar "env"))))
(DTypeSig false "cohRowsOwnedBy" (TyFun (TyCon "Int") (TyFun (TyCon "ImplEnv") (TyApp (TyCon "List") (TyCon "ImplRow")))))
(DFunDef false "cohRowsOwnedBy" ((PVar "cur") (PVar "env")) (EIf (EBinOp "==" (EVar "cur") (EVar "cohPreludeOrd")) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EVar "ieRowsOwnedBy") (EVar "cur")) (EVar "env")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "cohSubsumes" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))
(DFunDef false "cohSubsumes" ((PVar "general") (PVar "specific")) (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "general")) (EApp (EVar "listLen") (EVar "specific"))) (EApp (EVar "isSome") (EApp (EApp (EApp (EApp (EApp (EVar "matchOneSided") (EVar "cohStep")) (ELam ((PVar "_a") (PVar "_b")) (EBinOp "==" (EVar "_a") (EVar "_b")))) (EVar "cohEqMono")) (EApp (EApp (EVar "zip") (EVar "general")) (EVar "specific"))) (EListLit))) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "cohStep" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyApp (TyApp (TyApp (TyCon "MStep") (TyCon "Int")) (TyCon "Mono")) (TyCon "Mono")))))
(DFunDef false "cohStep" ((PVar "g0") (PVar "s0")) (EBlock (DoLet false false (PVar "g") (EApp (EVar "peelQual") (EApp (EVar "normalize") (EVar "g0")))) (DoLet false false (PVar "s") (EApp (EVar "peelQual") (EApp (EVar "normalize") (EVar "s0")))) (DoExpr (EMatch (EVar "g") (arm (PCon "TVar" (PVar "c")) () (EApp (EVar "MVar") (EApp (EVar "tyvarId") (EVar "c")))) (arm (PCon "TCon" (PVar "a") (PVar "oa")) () (EMatch (EVar "s") (arm (PCon "TCon" (PVar "b") (PVar "ob")) () (EIf (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EVar "a")) (EVar "oa")) (EVar "b")) (EVar "ob")) (EVar "MOk") (EVar "MFail"))) (arm (PCon "TRigid" (PVar "b")) () (EIf (EBinOp "==" (EVar "a") (EVar "b")) (EVar "MOk") (EVar "MFail"))) (arm PWild () (EVar "MFail")))) (arm (PCon "TRigid" (PVar "a")) () (EMatch (EVar "s") (arm (PCon "TRigid" (PVar "b")) () (EIf (EBinOp "==" (EVar "a") (EVar "b")) (EVar "MOk") (EVar "MFail"))) (arm (PCon "TCon" (PVar "b") PWild) () (EIf (EBinOp "==" (EVar "a") (EVar "b")) (EVar "MOk") (EVar "MFail"))) (arm PWild () (EVar "MFail")))) (arm (PCon "TApp" (PVar "f1") (PVar "a1")) () (EMatch (EVar "s") (arm (PCon "TApp" (PVar "f2") (PVar "a2")) () (EApp (EVar "MKids") (EListLit (ETuple (EVar "f1") (EVar "f2")) (ETuple (EVar "a1") (EVar "a2"))))) (arm PWild () (EVar "MFail")))) (arm (PCon "TFun" (PVar "a1") PWild (PVar "b1")) () (EMatch (EVar "s") (arm (PCon "TFun" (PVar "a2") PWild (PVar "b2")) () (EApp (EVar "MKids") (EListLit (ETuple (EVar "a1") (EVar "a2")) (ETuple (EVar "b1") (EVar "b2"))))) (arm PWild () (EVar "MFail")))) (arm (PCon "TEff" PWild) () (EMatch (EVar "s") (arm (PCon "TEff" PWild) () (EVar "MOk")) (arm PWild () (EVar "MFail")))) (arm (PCon "TAuth" PWild) () (EMatch (EVar "s") (arm (PCon "TAuth" PWild) () (EVar "MOk")) (arm PWild () (EVar "MFail"))))))))
(DTypeSig false "cohStrictlyMoreSpecific" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))
(DFunDef false "cohStrictlyMoreSpecific" ((PVar "a") (PVar "b")) (EBinOp "&&" (EApp (EApp (EVar "cohSubsumes") (EVar "b")) (EVar "a")) (EApp (EVar "not") (EApp (EApp (EVar "cohSubsumes") (EVar "a")) (EVar "b")))))
(DTypeSig false "cohScan" (TyFun (TyCon "CohSweep") (TyFun (TyApp (TyCon "List") (TyCon "CohImpl")) (TyFun (TyApp (TyCon "List") (TyCon "CohImpl")) (TyCon "CohScan")))))
(DFunDef false "cohScan" ((PVar "sweep") (PVar "impls") (PVar "fixed")) (EApp (EApp (EApp (EApp (EVar "cohScanOuter") (EVar "sweep")) (EVar "impls")) (EVar "fixed")) (EApp (EApp (EVar "CohScan") (EVar "None")) (EVar "None"))))
(DTypeSig false "cohScanOuter" (TyFun (TyCon "CohSweep") (TyFun (TyApp (TyCon "List") (TyCon "CohImpl")) (TyFun (TyApp (TyCon "List") (TyCon "CohImpl")) (TyFun (TyCon "CohScan") (TyCon "CohScan"))))))
(DFunDef false "cohScanOuter" (PWild (PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "cohScanOuter" ((PVar "sweep") (PCons (PVar "e") (PVar "rest")) (PVar "fixed") (PVar "acc")) (EIf (EApp (EVar "cohScanDone") (EVar "acc")) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "cohScanOuter") (EVar "sweep")) (EVar "rest")) (EVar "fixed")) (EApp (EApp (EApp (EApp (EVar "cohScanInner") (EVar "sweep")) (EVar "e")) (EVar "fixed")) (EApp (EApp (EApp (EApp (EVar "cohScanInner") (EVar "sweep")) (EVar "e")) (EVar "rest")) (EVar "acc")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "cohScanDone" (TyFun (TyCon "CohScan") (TyCon "Bool")))
(DFunDef false "cohScanDone" ((PCon "CohScan" (PCon "Some" PWild) (PCon "Some" PWild))) (EVar "True"))
(DFunDef false "cohScanDone" (PWild) (EVar "False"))
(DTypeSig false "cohSameIface" (TyFun (TyCon "IfaceRef") (TyFun (TyCon "IfaceRef") (TyCon "Bool"))))
(DFunDef false "cohSameIface" ((PVar "a") (PVar "b")) (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EFieldAccess (EVar "a") "irName")) (EFieldAccess (EVar "a") "irOrigin")) (EFieldAccess (EVar "b") "irName")) (EFieldAccess (EVar "b") "irOrigin")))
(DTypeSig false "cohScanInner" (TyFun (TyCon "CohSweep") (TyFun (TyCon "CohImpl") (TyFun (TyApp (TyCon "List") (TyCon "CohImpl")) (TyFun (TyCon "CohScan") (TyCon "CohScan"))))))
(DFunDef false "cohScanInner" (PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "cohScanInner" ((PVar "sweep") (PAs "e1" (PCon "CohImpl" (PVar "if1") (PVar "xs") (PVar "mid1") PWild)) (PCons (PCon "CohImpl" (PVar "if2") (PVar "ys") (PVar "mid2") PWild) (PVar "rest")) (PVar "acc")) (EIf (EApp (EVar "cohScanDone") (EVar "acc")) (EVar "acc") (EIf (EBinOp "&&" (EApp (EApp (EVar "cohSameIface") (EVar "if1")) (EVar "if2")) (EApp (EApp (EVar "cohOverlap") (EVar "xs")) (EVar "ys"))) (EApp (EApp (EApp (EApp (EVar "cohScanInner") (EVar "sweep")) (EVar "e1")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "cohClassify") (EVar "sweep")) (EVar "e1")) (EVar "xs")) (EVar "ys")) (EVar "mid1")) (EVar "mid2")) (EVar "acc"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "cohScanInner") (EVar "sweep")) (EVar "e1")) (EVar "rest")) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "cohClassify" (TyFun (TyCon "CohSweep") (TyFun (TyCon "CohImpl") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "CohScan") (TyCon "CohScan")))))))))
(DFunDef false "cohClassify" ((PVar "sweep") (PVar "e1") (PVar "xs") (PVar "ys") (PVar "mid1") (PVar "mid2") (PCon "CohScan" (PVar "hard") (PVar "soft"))) (EIf (EApp (EApp (EVar "cohStrictlyMoreSpecific") (EVar "xs")) (EVar "ys")) (EApp (EApp (EVar "CohScan") (EVar "hard")) (EVar "soft")) (EIf (EApp (EApp (EVar "cohStrictlyMoreSpecific") (EVar "ys")) (EVar "xs")) (EApp (EApp (EVar "CohScan") (EVar "hard")) (EVar "soft")) (EIf (EBinOp "&&" (EApp (EApp (EVar "cohMutuallySubsumes") (EVar "xs")) (EVar "ys")) (EApp (EApp (EApp (EVar "cohHardInScope") (EVar "sweep")) (EVar "mid1")) (EVar "mid2"))) (EApp (EApp (EVar "CohScan") (EApp (EApp (EVar "cohKeepFirst") (EVar "hard")) (EApp (EVar "Some") (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "cohHardMsg") (EVar "e1")) (EVar "xs")) (EVar "ys")) (EVar "mid1")) (EVar "mid2")) (EApp (EVar "cohImplLoc") (EVar "e1")))))) (EVar "soft")) (EIf (EApp (EApp (EVar "cohMutuallySubsumes") (EVar "xs")) (EVar "ys")) (EApp (EApp (EVar "CohScan") (EVar "hard")) (EVar "soft")) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EVar "cohSoftInScope") (EVar "sweep")) (EVar "mid1")) (EVar "mid2"))) (EApp (EApp (EVar "CohScan") (EVar "hard")) (EVar "soft")) (EIf (EVar "otherwise") (EApp (EApp (EVar "CohScan") (EVar "hard")) (EApp (EApp (EVar "cohKeepFirst") (EVar "soft")) (EApp (EVar "Some") (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "cohIncomparableMsg") (EApp (EVar "cohImplIfaceName") (EVar "e1"))) (EVar "xs")) (EVar "ys")) (EVar "mid1")) (EVar "mid2")) (EApp (EVar "cohImplLoc") (EVar "e1")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "cohSoftInScope" (TyFun (TyCon "CohSweep") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "cohSoftInScope" ((PCon "CohSweepOwn") PWild PWild) (EVar "True"))
(DFunDef false "cohSoftInScope" ((PCon "CohSweepGlobal") (PLit (LString "")) (PLit (LString ""))) (EVar "True"))
(DFunDef false "cohSoftInScope" ((PCon "CohSweepGlobal") (PVar "mid1") (PVar "mid2")) (EApp (EApp (EVar "cohIsCrossModule") (EVar "mid1")) (EVar "mid2")))
(DTypeSig false "cohHardInScope" (TyFun (TyCon "CohSweep") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "cohHardInScope" ((PVar "sweep") (PVar "mid1") (PVar "mid2")) (EApp (EApp (EApp (EVar "cohSoftInScope") (EVar "sweep")) (EVar "mid1")) (EVar "mid2")))
(DTypeSig false "cohMutuallySubsumes" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))
(DFunDef false "cohMutuallySubsumes" ((PVar "xs") (PVar "ys")) (EBinOp "&&" (EApp (EApp (EVar "cohSubsumes") (EVar "xs")) (EVar "ys")) (EApp (EApp (EVar "cohSubsumes") (EVar "ys")) (EVar "xs"))))
(DTypeSig false "cohKeepFirst" (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "cohKeepFirst" ((PCon "Some" (PVar "x")) PWild) (EApp (EVar "Some") (EVar "x")))
(DFunDef false "cohKeepFirst" ((PCon "None") (PVar "y")) (EVar "y"))
(DTypeSig false "cohHardMsg" (TyFun (TyCon "CohImpl") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))))
(DFunDef false "cohHardMsg" ((PVar "e1") (PVar "xs") (PVar "ys") (PVar "mid1") (PVar "mid2")) (EIf (EApp (EApp (EVar "cohPairsPrelude") (EVar "mid1")) (EVar "mid2")) (EApp (EApp (EApp (EVar "cohPreludeOverlapMsg") (EApp (EVar "cohImplIfaceName") (EVar "e1"))) (EVar "xs")) (EVar "ys")) (EIf (EApp (EApp (EVar "cohIsCrossModule") (EVar "mid1")) (EVar "mid2")) (EApp (EApp (EApp (EVar "cohCrossModuleMsg") (EApp (EVar "cohImplIfaceName") (EVar "e1"))) (EVar "mid1")) (EVar "mid2")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "cohOverlapMsg") (EApp (EVar "cohImplIfaceName") (EVar "e1"))) (EVar "xs")) (EVar "ys")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "cohPreludeMid" (TyCon "String"))
(DFunDef false "cohPreludeMid" () (ELit (LString "core")))
(DTypeSig false "cohPairsPrelude" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "cohPairsPrelude" ((PVar "mid1") (PVar "mid2")) (EBinOp "||" (EBinOp "==" (EVar "mid1") (EVar "cohPreludeMid")) (EBinOp "==" (EVar "mid2") (EVar "cohPreludeMid"))))
(DTypeSig false "cohIsCrossModule" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "cohIsCrossModule" ((PVar "mid1") (PVar "mid2")) (EBinOp "&&" (EBinOp "&&" (EBinOp "/=" (EVar "mid1") (ELit (LString ""))) (EBinOp "/=" (EVar "mid2") (ELit (LString "")))) (EBinOp "/=" (EVar "mid1") (EVar "mid2"))))
(DTypeSig false "cohIncomparableMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))))
(DFunDef false "cohIncomparableMsg" ((PVar "iface") (PVar "xs") (PVar "ys") (PVar "mid1") (PVar "mid2")) (EMatch (EApp (EApp (EVar "cohPpPair") (EVar "xs")) (EVar "ys")) (arm (PTuple (PVar "s1") (PVar "s2")) () (EIf (EApp (EApp (EVar "cohPairsPrelude") (EVar "mid1")) (EVar "mid2")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Warning: overlapping impls of ")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString ": neither "))) (EApp (EMethodRef "display") (EVar "s1"))) (ELit (LString " nor the prelude's "))) (EApp (EMethodRef "display") (EVar "s2"))) (ELit (LString " is more specific than the other, so a goal matching both has no impl to pick"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Warning: overlapping impls of ")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EApp (EVar "cohWhereSuffix") (EVar "mid1")) (EVar "mid2")))) (ELit (LString ": neither "))) (EApp (EMethodRef "display") (EVar "s1"))) (ELit (LString " nor "))) (EApp (EMethodRef "display") (EVar "s2"))) (ELit (LString " is more specific than the other, so a goal matching both has no impl to pick")))))))
(DTypeSig false "cohWhereSuffix" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "cohWhereSuffix" ((PVar "mid1") (PVar "mid2")) (EIf (EApp (EApp (EVar "cohIsCrossModule") (EVar "mid1")) (EVar "mid2")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " (defined in `")) (EApp (EMethodRef "display") (EVar "mid2"))) (ELit (LString "` and `"))) (EApp (EMethodRef "display") (EVar "mid1"))) (ELit (LString "`)"))) (EIf (EVar "otherwise") (ELit (LString "")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "cohImplIface" (TyFun (TyCon "CohImpl") (TyCon "IfaceRef")))
(DFunDef false "cohImplIface" ((PCon "CohImpl" (PVar "i") PWild PWild PWild)) (EVar "i"))
(DTypeSig false "cohImplIfaceName" (TyFun (TyCon "CohImpl") (TyCon "String")))
(DFunDef false "cohImplIfaceName" ((PVar "e")) (EFieldAccess (EApp (EVar "cohImplIface") (EVar "e")) "irName"))
(DTypeSig false "cohImplLoc" (TyFun (TyCon "CohImpl") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "cohImplLoc" ((PCon "CohImpl" PWild PWild PWild (PVar "l"))) (EVar "l"))
(DTypeSig false "pushCoherenceWarning" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyCon "Unit")))))
(DFunDef false "pushCoherenceWarning" ((PVar "mctx") (PVar "loc") (PVar "msg")) (EBlock (DoLet false false (PVar "warning") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "W-INCOMPARABLE-IMPLS"))) (ELit (LInt 2))) (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EFieldAccess (EVar "mctx") "mcLoc"))) (EVar "msg")) (EApp (EVar "Some") (EVar "cohIncomparableHelp"))) (EVar "None"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchWarnings")) (EBinOp "::" (EVar "warning") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchWarnings") "value"))))))
(DTypeSig true "checkCoherence" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ImplEnv") (TyFun (TyCon "Int") (TyCon "Unit")))))
(DFunDef false "checkCoherence" ((PVar "mctx") (PVar "env") (PVar "cur")) (EMatch (EApp (EApp (EApp (EVar "cohScan") (EVar "CohSweepOwn")) (EApp (EVar "reverse") (EApp (EApp (EMethodRef "map") (EApp (EVar "cohImplOfRow") (EVar "mctx"))) (EApp (EApp (EVar "cohRowsOwnedBy") (EVar "cur")) (EVar "env"))))) (EApp (EApp (EMethodRef "map") (EApp (EVar "cohImplOfRow") (EVar "mctx"))) (EApp (EVar "cohPreludeRows") (EVar "env")))) (arm (PCon "CohScan" (PVar "hard") (PVar "soft")) () (EBlock (DoExpr (EApp (EApp (EVar "cohPushHard") (EVar "mctx")) (EVar "hard"))) (DoExpr (EApp (EApp (EVar "cohPushSoft") (EVar "mctx")) (EVar "soft")))))))
(DTypeSig false "cohPushHard" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyCon "Unit"))))
(DFunDef false "cohPushHard" ((PVar "mctx") (PCon "None")) (ELit LUnit))
(DFunDef false "cohPushHard" ((PVar "mctx") (PCon "Some" (PTuple (PVar "msg") (PVar "loc")))) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (ELit (LString "T-CONFLICTING-IMPL"))) (EVar "loc")) (EVar "msg")))
(DTypeSig false "cohPushSoft" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyCon "Unit"))))
(DFunDef false "cohPushSoft" ((PVar "mctx") (PCon "None")) (ELit LUnit))
(DFunDef false "cohPushSoft" ((PVar "mctx") (PCon "Some" (PTuple (PVar "msg") (PVar "loc")))) (EApp (EApp (EApp (EVar "pushCoherenceWarning") (EVar "mctx")) (EVar "loc")) (EVar "msg")))
(DTypeSig true "checkSuperImpls" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "ClassEnv") (TyFun (TyCon "ImplEnv") (TyFun (TyCon "Int") (TyCon "Unit")))))))
(DFunDef false "checkSuperImpls" ((PVar "mctx") (PVar "userDecls") (PVar "ce") (PVar "ie") (PVar "cur")) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EVar "ieRowsVisibleAt") (EVar "cur")) (EVar "ie"))) (DoExpr (EApp (EApp (EVar "each") (EApp (EApp (EApp (EApp (EApp (EVar "checkImplSuperContexts") (EVar "mctx")) (EVar "userDecls")) (EVar "ce")) (EVar "cur")) (EVar "rows"))) (EVar "userDecls")))))
(DTypeSig false "checkImplSuperContexts" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyCon "Decl") (TyCon "Unit"))))))))
(DFunDef false "checkImplSuperContexts" ((PVar "mctx") (PVar "decls") (PVar "ce") (PVar "cur") (PVar "rows") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkImplSuperContexts") (EVar "mctx")) (EVar "decls")) (EVar "ce")) (EVar "cur")) (EVar "rows")) (EVar "d")))
(DFunDef false "checkImplSuperContexts" ((PVar "mctx") (PVar "decls") (PVar "ce") (PVar "cur") (PVar "rows") (PRec "DImpl" ((rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "implOrigin" (PVar "o")) (rf "implIfaceLoc" (PVar "ifaceLoc"))) true)) (EBlock (DoLet false false (PVar "derived") (EApp (EVar "isNone") (EVar "ifaceLoc"))) (DoLet false false (PVar "loc") (EIf (EVar "derived") (EApp (EApp (EVar "derivedImplDeclLoc") (EVar "decls")) (EVar "tys")) (EVar "ifaceLoc"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "ceLookupAt") (EApp (EVar "regKeyOfTab") (EApp (EApp (EVar "ifaceTabKey") (EVar "o")) (EVar "iface")))) (EVar "cur")) (EVar "ce")) (arm (PCon "Some" (PVar "r")) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EApp (EVar "ceRowTyparams") (EVar "r"))) (EApp (EVar "listLen") (EVar "tys"))))) (EBlock (DoLet false false (PTuple (PVar "implTvMap") (PVar "headMonos")) (EApp (EApp (EVar "implHeadMonos") (EVar "mctx")) (EVar "tys"))) (DoLet false false (PVar "roots") (EApp (EVar "implHeadTypeVarRoots") (EVar "implTvMap"))) (DoLet false false (PVar "headIds") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EVar "intToString") (EApp (EVar "snd") (EVar "p"))))) (EVar "roots"))) (EVar "omEmpty"))) (DoLet false false (PVar "declared") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "requirePredicateSlot") (EVar "mctx")) (EVar "implTvMap"))) (EVar "reqs"))) (DoLet false false (PVar "givens") (EBinOp "++" (EVar "declared") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "s")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EVar "predicateSlotKnownSupers") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "s"))))) (EVar "declared")))) (DoLet false false (PVar "subject") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "impl ")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "join") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EVar "ppTyAtom")) (EVar "tys"))))) (ELit (LString "")))) (DoLet false false (PVar "subst") (EApp (EApp (EVar "zip") (EApp (EVar "ceRowTyparams") (EVar "r"))) (EVar "tys"))) (DoLet false false (PVar "argsOf") (ELam ((PVar "sup")) (EApp (EApp (EVar "mapAll") (ELam ((PVar "p")) (EApp (EApp (EApp (EVar "lookupPos") (EVar "p")) (EApp (EVar "ceRowTyparams") (EVar "r"))) (EVar "headMonos")))) (EApp (EVar "superParamsOf") (EVar "sup"))))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "sup")) (EMatch (EApp (EVar "argsOf") (EVar "sup")) (arm (PCon "Some" (PVar "supArgs")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkSuperInstanceContext") (EVar "mctx")) (EVar "subject")) (EVar "roots")) (EVar "headIds")) (EVar "givens")) (EVar "loc")) (EVar "derived")) (EApp (EVar "superIfaceRef") (EVar "sup"))) (EVar "supArgs")) (ELam (PWild) (EApp (EApp (EApp (EVar "superRowExists") (EVar "rows")) (EVar "subst")) (EVar "sup"))))) (arm (PCon "None") () (ELit LUnit))))) (ELit LUnit)) (EApp (EVar "ceRowSupers") (EVar "r")))))) (arm PWild () (ELit LUnit))))))
(DFunDef false "checkImplSuperContexts" ((PVar "mctx") PWild PWild PWild PWild PWild) (ELit LUnit))
(DTypeSig false "derivedImplDeclLoc" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "derivedImplDeclLoc" ((PVar "decls") (PVar "tys")) (EMatch (EApp (EApp (EDictApp "flatMap") (EVar "tyConNamesInTy")) (EVar "tys")) (arm (PList (PVar "n")) () (EMatch (EApp (EApp (EDictApp "flatMap") (EApp (EVar "declNameLocs") (EVar "n"))) (EVar "decls")) (arm (PCons (PVar "l") PWild) () (EApp (EVar "Some") (EVar "l"))) (arm (PList) () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig false "declNameLocs" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Loc")))))
(DFunDef false "declNameLocs" ((PVar "n") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "declNameLocs") (EVar "n")) (EVar "d")))
(DFunDef false "declNameLocs" ((PVar "n") (PRec "DData" ((rf "dataName" None) (rf "dataNameLoc" (PCon "Some" (PVar "l")))) true)) (EIf (EBinOp "==" (EVar "dataName") (EVar "n")) (EListLit (EVar "l")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "declNameLocs" ((PVar "n") (PRec "DNewtype" ((rf "newtypeName" None) (rf "newtypeNameLoc" (PCon "Some" (PVar "l")))) true)) (EIf (EBinOp "==" (EVar "newtypeName") (EVar "n")) (EListLit (EVar "l")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "declNameLocs" (PWild PWild) (EListLit))
(DTypeSig false "checkSuperInstanceContext" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "PredicateSlot")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Bool") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyFun (TyCon "Unit") (TyCon "Bool")) (TyCon "Unit"))))))))))))
(DFunDef false "checkSuperInstanceContext" ((PVar "mctx") (PVar "subject") (PVar "roots") (PVar "headIds") (PVar "givens") (PVar "loc") (PVar "derived") (PVar "sup") (PVar "supArgs") (PVar "covered")) (EIf (EApp (EApp (EVar "anyList") (EApp (EApp (EVar "givenAnswers") (EVar "sup")) (EVar "supArgs"))) (EVar "givens")) (ELit LUnit) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EApp (EVar "rigidHeadInstanceContext") (EApp (EVar "siteFor") (EVar "mctx"))) (EVar "headIds")) (EVar "sup")) (EVar "supArgs")) (arm (PCon "None") () (EIf (EApp (EVar "not") (EApp (EVar "covered") (ELit LUnit))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reportMissingSuperImpl") (EVar "mctx")) (EVar "subject")) (EVar "roots")) (EVar "loc")) (EVar "derived")) (EVar "sup")) (EVar "supArgs")) (ELit LUnit))) (arm (PCon "Some" (PVar "ctx")) () (EBlock (DoLet false false (PVar "walk") (EApp (EVar "reqWalkStart") (ELit LUnit))) (DoLet false false (PVar "leaves") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "g")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "superContextLeaves") (EVar "mctx")) (EVar "walk")) (EVar "headIds")) (EVar "givens")) (EVar "loc")) (EApp (EVar "fst") (EVar "g"))) (EApp (EVar "snd") (EVar "g"))))) (EVar "ctx"))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "leaf")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reportSuperContextLeaf") (EVar "mctx")) (EVar "subject")) (EVar "roots")) (EVar "loc")) (EVar "derived")) (EVar "sup")) (EVar "supArgs")) (EVar "leaf")))) (ELit LUnit)) (EVar "leaves")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "superRowExists" (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Super") (TyCon "Bool")))))
(DFunDef false "superRowExists" ((PVar "rows") (PVar "subst") (PRec "Super" ((rf "superHead" (PVar "n")) (rf "superParams" (PVar "ps")) (rf "superOrigin" (PVar "so"))) false)) (EBlock (DoLet false false (PVar "tys") (EApp (EApp (EVar "substParams") (EVar "ps")) (EVar "subst"))) (DoExpr (EBinOp "||" (EBinOp "/=" (EApp (EVar "listLen") (EVar "tys")) (EApp (EVar "listLen") (EVar "ps"))) (EApp (EApp (EApp (EApp (EVar "superImplExists") (EVar "rows")) (EApp (EApp (EVar "ifaceTabKey") (EVar "so")) (EVar "n"))) (EVar "n")) (EVar "tys"))))))
(DTypeSig false "reportMissingSuperImpl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Bool") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Unit")))))))))
(DFunDef false "reportMissingSuperImpl" ((PVar "mctx") (PVar "subject") (PVar "roots") (PVar "loc") (PVar "derived") (PVar "sup") (PVar "supArgs")) (EBlock (DoLet false false (PVar "named") (EApp (EVar "Ref") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (ETuple (EApp (EVar "snd") (EVar "p")) (EApp (EVar "fst") (EVar "p"))))) (EVar "roots")))) (DoLet false false (PVar "goal") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "sup") "irName"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "join") (ELit (LString " "))) (EApp (EApp (EApp (EApp (EVar "ppEach") (EVar "named")) (EApp (EVar "Ref") (ELit (LInt 0)))) (ELit (LInt 3))) (EVar "supArgs"))))) (ELit (LString "")))) (DoLet false false (PVar "missing") (EBinOp "++" (EBinOp "++" (ELit (LString "requires the superinterface `")) (EApp (EMethodRef "display") (EVar "goal"))) (ELit (LString "`, which no impl covers")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-MISSING-SUPER-IMPL"))) (EVar "loc")) (EIf (EApp (EVar "not") (EVar "derived")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "subject"))) (ELit (LString "` "))) (EApp (EMethodRef "display") (EVar "missing"))) (ELit (LString "; add an `impl "))) (EApp (EMethodRef "display") (EVar "goal"))) (ELit (LString "` covering it, or add `requires "))) (EApp (EMethodRef "display") (EVar "goal"))) (ELit (LString "` to the impl"))) (EIf (EApp (EVar "derivableIface") (EFieldAccess (EVar "sup") "irName")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "subject"))) (ELit (LString "` (derived) "))) (EApp (EMethodRef "display") (EVar "missing"))) (ELit (LString "; add `"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "sup") "irName"))) (ELit (LString "` to the type's `deriving` clause, or add an `impl "))) (EApp (EMethodRef "display") (EVar "goal"))) (ELit (LString "`"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "subject"))) (ELit (LString "` (derived) "))) (EApp (EMethodRef "display") (EVar "missing"))) (ELit (LString "; add an `impl "))) (EApp (EMethodRef "display") (EVar "goal"))) (ELit (LString "`")))))))))
(DTypeSig false "superContextLeaves" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ReqWalk") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "PredicateSlot")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))))))))))))
(DFunDef false "superContextLeaves" ((PVar "mctx") (PVar "walk") (PVar "headIds") (PVar "givens") (PVar "loc") (PVar "iface") (PVar "args")) (EIf (EApp (EApp (EVar "anyList") (EApp (EApp (EVar "givenAnswers") (EVar "iface")) (EVar "args"))) (EVar "givens")) (EListLit) (EIf (EApp (EVar "not") (EApp (EVar "anyConcreteHead") (EVar "args"))) (EListLit (ETuple (EVar "iface") (EVar "args"))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "reqWalkReported") (EVar "mctx")) (EVar "loc")) (EApp (EApp (EApp (EVar "reqWalkEnter") (EVar "walk")) (EVar "iface")) (EVar "args"))) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "next")) () (EApp (EApp (EApp (EApp (EApp (EVar "solvedOnWalk") (EVar "mctx")) (EVar "next")) (EVar "iface")) (EVar "args")) (ELam (PWild) (EMatch (EApp (EApp (EApp (EApp (EVar "rigidHeadInstanceContext") (EApp (EVar "siteFor") (EVar "mctx"))) (EVar "headIds")) (EVar "iface")) (EVar "args")) (arm (PCon "None") () (EListLit (ETuple (EVar "iface") (EVar "args")))) (arm (PCon "Some" (PVar "ctx")) () (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "g")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "superContextLeaves") (EVar "mctx")) (EVar "next")) (EVar "headIds")) (EVar "givens")) (EVar "loc")) (EApp (EVar "fst") (EVar "g"))) (EApp (EVar "snd") (EVar "g"))))) (EVar "ctx")))))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "reportSuperContextLeaf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Bool") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))) (TyCon "Unit"))))))))))
(DFunDef false "reportSuperContextLeaf" ((PVar "mctx") (PVar "subject") (PVar "roots") (PVar "loc") (PVar "derived") (PVar "sup") (PVar "supArgs") (PTuple (PVar "iface") (PVar "args"))) (EBlock (DoLet false false (PVar "ids") (EApp (EApp (EDictApp "flatMap") (EVar "monoUnboundIds")) (EVar "args"))) (DoLet false false (PVar "named") (EApp (EVar "Ref") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (ETuple (EApp (EVar "snd") (EVar "p")) (EApp (EVar "fst") (EVar "p"))))) (EVar "roots")))) (DoLet false false (PVar "argsText") (EApp (EApp (EVar "join") (ELit (LString " "))) (EApp (EApp (EApp (EApp (EVar "ppEach") (EVar "named")) (EApp (EVar "Ref") (ELit (LInt 0)))) (ELit (LInt 3))) (EVar "args")))) (DoLet false false (PVar "superGoal") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "qualifiedIfaceLabel") (EVar "sup")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "join") (ELit (LString " "))) (EApp (EApp (EApp (EApp (EVar "ppEach") (EVar "named")) (EApp (EVar "Ref") (ELit (LInt 0)))) (ELit (LInt 3))) (EVar "supArgs"))))) (ELit (LString "")))) (DoLet false false (PVar "pred") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "qualifiedIfaceLabel") (EVar "iface")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "argsText"))) (ELit (LString "")))) (DoLet false false (PVar "predBare") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "iface") "irName"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "argsText"))) (ELit (LString "")))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "ids")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-NO-IMPL"))) (EVar "loc")) (EApp (EApp (EApp (EApp (EApp (EVar "superContextNoImplMsg") (EVar "subject")) (EVar "derived")) (EVar "superGoal")) (EVar "pred")) (EVar "predBare"))) (EIf (EApp (EApp (EVar "allList") (ELam ((PVar "i")) (EApp (EApp (EVar "containsI") (EVar "i")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "roots"))))) (EVar "ids")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-IMPL-MISSING-REQUIRES"))) (EVar "loc")) (EApp (EApp (EApp (EApp (EApp (EVar "superContextUndeclaredMsg") (EVar "subject")) (EVar "derived")) (EVar "superGoal")) (EVar "pred")) (EVar "predBare"))) (ELit LUnit))))))
(DTypeSig false "pushIncompleteImpl" (TyFun (TyCon "ModuleCtx") (TyFun (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "pushIncompleteImpl" ((PVar "mctx") (PTuple (PVar "loc") (PVar "msg"))) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-INCOMPLETE-IMPL"))) (EVar "loc")) (EVar "msg")))
(DTypeSig false "firstImplMethodLoc" (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "firstImplMethodLoc" ((PList)) (EVar "None"))
(DFunDef false "firstImplMethodLoc" ((PCons (PCon "ImplMethod" PWild PWild (PVar "body")) PWild)) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "exprLoc") (EVar "body"))) (EApp (EVar "appArgLoc") (EVar "body"))))
(DTypeSig true "checkImplCompletenessMap" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))))
(DFunDef false "checkImplCompletenessMap" ((PVar "mctx") (PVar "ce") (PVar "cur") (PVar "iterDecls")) (EApp (EApp (EVar "each") (EApp (EVar "pushIncompleteImpl") (EVar "mctx"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "implCompletenessMsgsOfMap") (EVar "ce")) (EVar "cur"))) (EVar "iterDecls"))))
(DTypeSig false "implCompletenessMsgsOfMap" (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))))))
(DFunDef false "implCompletenessMsgsOfMap" ((PVar "ce") (PVar "cur") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EVar "implCompletenessMsgsOfMap") (EVar "ce")) (EVar "cur")) (EVar "d")))
(DFunDef false "implCompletenessMsgsOfMap" ((PVar "ce") (PVar "cur") (PRec "DImpl" ((rf "iface" None) (rf "tys" None) (rf "methods" None) (rf "implOrigin" (PVar "o")) (rf "implIfaceLoc" (PVar "ifaceLoc"))) true)) (EMatch (EApp (EApp (EApp (EVar "ceRequiredAt") (EApp (EVar "regKeyOfTab") (EApp (EApp (EVar "ifaceTabKey") (EVar "o")) (EVar "iface")))) (EVar "cur")) (EVar "ce")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "required")) () (EBlock (DoLet false false (PVar "defined") (EApp (EApp (EMethodRef "map") (EVar "implMethodName")) (EVar "methods"))) (DoLet false false (PVar "loc") (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstImplMethodLoc") (EVar "methods"))) (EVar "ifaceLoc"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (ETuple (EVar "loc") (EApp (EApp (EApp (EVar "missingImplMethodMsg") (EVar "iface")) (EVar "tys")) (EVar "m"))))) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "m")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "m")) (EVar "defined"))))) (EVar "required"))))))))
(DFunDef false "implCompletenessMsgsOfMap" (PWild PWild PWild) (EListLit))
(DTypeSig true "checkPhantomMethods" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyCon "Unit")))))
(DFunDef false "checkPhantomMethods" ((PVar "mctx") (PVar "ce") (PVar "cur")) (EApp (EApp (EVar "each") (ELam ((PTuple (PVar "loc") (PVar "msg"))) (EApp (EApp (EApp (EVar "pushTypeError") (EApp (EApp (EVar "mctxAtIfSome") (EVar "loc")) (EVar "mctx"))) (ELit (LString "T-PHANTOM-METHOD"))) (EVar "msg")))) (EApp (EApp (EDictApp "flatMap") (EVar "phantomMethodMsgs")) (EApp (EApp (EVar "ceRowsOwnedBy") (EVar "cur")) (EVar "ce")))))
(DTypeSig false "phantomMethodMsgs" (TyFun (TyCon "CeRow") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))))
(DFunDef false "phantomMethodMsgs" ((PVar "r")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (ETuple (EApp (EApp (EVar "orElseLoc") (EApp (EVar "fst") (EVar "m"))) (EApp (EVar "ceRowLoc") (EVar "r"))) (EApp (EVar "snd") (EVar "m"))))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "phantomMethodMsg") (EApp (EVar "ceRowIfaceName") (EVar "r"))) (EApp (EVar "ceRowTyparams") (EVar "r")))) (EApp (EVar "ceRowMethods") (EVar "r")))))
(DTypeSig false "phantomMethodMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind"))))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))))))
(DFunDef false "phantomMethodMsg" ((PVar "ifaceName") (PVar "typarams") (PTuple (PVar "mname") (PVar "mty") PWild)) (EIf (EApp (EVar "isEmptyL") (EVar "typarams")) (EListLit) (EIf (EApp (EApp (EVar "anyMember") (EApp (EVar "tyVarNames") (EVar "mty"))) (EVar "typarams")) (EListLit) (EBlock (DoLet false false (PVar "noun") (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "typarams")) (ELit (LInt 1))) (ELit (LString "parameter")) (ELit (LString "parameters")))) (DoExpr (EListLit (ETuple (EApp (EVar "firstTyLoc") (EVar "mty")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "method `")) (EApp (EMethodRef "display") (EVar "mname"))) (ELit (LString "` of interface `"))) (EApp (EMethodRef "display") (EVar "ifaceName"))) (ELit (LString "` does not mention the interface "))) (EApp (EMethodRef "display") (EVar "noun"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "join") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "t")) (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EVar "backticked") (EVar "t"))) (ELit (LString "'"))))) (EVar "typarams"))))) (ELit (LString ", so it cannot be dispatched"))))))))))
(DTypeSig false "substParams" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyApp (TyCon "List") (TyCon "Ty")))))
(DFunDef false "substParams" ((PList) PWild) (EListLit))
(DFunDef false "substParams" ((PCons (PVar "p") (PVar "rest")) (PVar "subst")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "p")) (EVar "subst")) (arm (PCon "Some" (PVar "t")) () (EBinOp "::" (EVar "t") (EApp (EApp (EVar "substParams") (EVar "rest")) (EVar "subst")))) (arm (PCon "None") () (EApp (EApp (EVar "substParams") (EVar "rest")) (EVar "subst")))))
(DTypeSig false "superImplExists" (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyCon "TabKey") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Bool"))))))
(DFunDef false "superImplExists" ((PVar "rows") (PVar "superKey") (PVar "superName") (PVar "goal")) (EApp (EApp (EVar "anyList") (EApp (EApp (EApp (EVar "implRowMatchesSuper") (EVar "superKey")) (EVar "superName")) (EVar "goal"))) (EVar "rows")))
(DTypeSig false "implRowMatchesSuper" (TyFun (TyCon "TabKey") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyCon "ImplRow") (TyCon "Bool"))))))
(DFunDef false "implRowMatchesSuper" ((PVar "superKey") (PVar "superName") (PVar "goal") (PCon "ImplRow" PWild PWild (PVar "ir") (PVar "tys") PWild PWild PWild)) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "ir") "irName") (EVar "superName")) (EBinOp "==" (EApp (EVar "listLen") (EVar "tys")) (EApp (EVar "listLen") (EVar "goal")))) (EBinOp "==" (EApp (EApp (EVar "ifaceTabKey") (EFieldAccess (EVar "ir") "irOrigin")) (EFieldAccess (EVar "ir") "irName")) (EVar "superKey"))) (EApp (EApp (EVar "superHeadCovers") (EVar "tys")) (EVar "goal"))))
(DTypeSig false "superHeadCovers" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Bool"))))
(DFunDef false "superHeadCovers" ((PVar "pats") (PVar "goal")) (EApp (EVar "isSome") (EApp (EApp (EApp (EApp (EApp (EVar "matchOneSided") (EVar "superHeadStep")) (ELam ((PVar "_a") (PVar "_b")) (EBinOp "==" (EVar "_a") (EVar "_b")))) (EVar "tyStructEq")) (EApp (EApp (EVar "zip") (EVar "pats")) (EVar "goal"))) (EListLit))))
(DTypeSig false "superHeadStep" (TyFun (TyCon "Ty") (TyFun (TyCon "Ty") (TyApp (TyApp (TyApp (TyCon "MStep") (TyCon "String")) (TyCon "Ty")) (TyCon "Ty")))))
(DFunDef false "superHeadStep" ((PVar "pat") (PVar "t")) (EApp (EApp (EVar "tyStep") (EVar "pat")) (EApp (EVar "stripTyWrap") (EVar "t"))))
(DTypeSig true "globalCoherenceConflict" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ImplEnv") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "globalCoherenceConflict" ((PVar "mctx") (PVar "env")) (EMatch (EApp (EApp (EApp (EVar "cohScan") (EVar "CohSweepGlobal")) (EApp (EVar "reverse") (EApp (EApp (EMethodRef "map") (EApp (EVar "cohImplOfRow") (EVar "mctx"))) (EApp (EVar "cohRowsOf") (EVar "env"))))) (EListLit)) (arm (PCon "CohScan" (PVar "hard") (PVar "soft")) () (ETuple (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "hard")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "soft"))))))
(DTypeSig true "implHeadGround" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "implHeadGround" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "implHeadGround") (EVar "d")))
(DFunDef false "implHeadGround" ((PRec "DImpl" ((rf "tys" None)) true)) (EApp (EVar "isEmptyL") (EApp (EApp (EDictApp "flatMap") (EVar "tyVarNames")) (EVar "tys"))))
(DFunDef false "implHeadGround" (PWild) (EVar "False"))
(DTypeSig true "implHeadParametric" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "implHeadParametric" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "implHeadParametric") (EVar "d")))
(DFunDef false "implHeadParametric" ((PRec "DImpl" ((rf "tys" None)) true)) (EApp (EVar "isNonEmptyL") (EApp (EApp (EDictApp "flatMap") (EVar "tyVarNames")) (EVar "tys"))))
(DFunDef false "implHeadParametric" (PWild) (EVar "False"))
(DTypeSig true "inferDefaultBodies" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "inferDefaultBodies" ((PVar "env") (PList)) (ELit LUnit))
(DFunDef false "inferDefaultBodies" ((PVar "env") (PCons (PVar "d") (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EVar "inferOneIfaceDefaults") (EVar "env")) (EVar "d"))) (DoExpr (EApp (EApp (EVar "inferDefaultBodies") (EVar "env")) (EVar "rest")))))
(DTypeSig false "inferOneIfaceDefaults" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Decl") (TyCon "Unit"))))
(DFunDef false "inferOneIfaceDefaults" ((PVar "env") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "inferOneIfaceDefaults") (EVar "env")) (EVar "d")))
(DFunDef false "inferOneIfaceDefaults" ((PVar "env") (PRec "DInterface" ((rf "name" None) (rf "typarams" None) (rf "typaramKinds" None) (rf "methods" None) (rf "ifaceOrigin" None)) true)) (EBlock (DoLet false false (PVar "dscope") (EApp (EApp (EApp (EApp (EVar "declGradedScope") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "typarams")) (EVar "typaramKinds")) (EVar "methods"))) (DoLet false false (PVar "ifaceSchemes") (EApp (EApp (EApp (EVar "methodSchemesPure") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "dscope")) (EVar "methods"))) (DoLet false false (PVar "iface") (ERecordCreate "IfaceRef" ((fa "irName" (EVar "name")) (fa "irOrigin" (EVar "ifaceOrigin"))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "inferDefaultMethods") (EApp (EApp (EVar "extendVars") (EVar "env")) (EVar "ifaceSchemes"))) (EVar "iface")) (EVar "dscope")) (EVar "typarams")) (EVar "methods")))))
(DFunDef false "inferOneIfaceDefaults" ((PVar "env") PWild) (ELit LUnit))
(DTypeSig false "inferDefaultMethods" (TyFun (TyCon "TcEnv") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyCon "Unit")))))))
(DFunDef false "inferDefaultMethods" ((PVar "env") PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "inferDefaultMethods" ((PVar "env") (PVar "iface") (PVar "dscope") (PVar "typarams") (PCons (PVar "m") (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "inferDefaultMethod") (EVar "env")) (EVar "iface")) (EVar "dscope")) (EVar "typarams")) (EVar "m"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "inferDefaultMethods") (EVar "env")) (EVar "iface")) (EVar "dscope")) (EVar "typarams")) (EVar "rest")))))
(DTypeSig false "inferDefaultMethod" (TyFun (TyCon "TcEnv") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyCon "Unit")))))))
(DFunDef false "inferDefaultMethod" ((PVar "env") (PVar "iface") (PVar "dscope") (PVar "typarams") (PCon "IfaceMethod" (PVar "mname") (PVar "mty") (PCon "Some" (PCon "MethodDefault" (PVar "pats") (PVar "body"))) PWild)) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferMethodBody") (EVar "env")) (EVar "iface")) (EVar "DefaultBody")) (ETuple (EVar "typarams") (EVar "mty") (EVar "dscope"))) (EVar "mname")) (EVar "pats")) (EVar "body")))
(DFunDef false "inferDefaultMethod" ((PVar "env") PWild PWild PWild PWild) (ELit LUnit))
(DTypeSig true "nestedRequireGoals" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyApp (TyCon "List") (TyCon "UObligation")))))))
(DFunDef false "nestedRequireGoals" ((PVar "mctx") (PVar "rigidIds") (PVar "liveIds") (PVar "obls")) (EBlock (DoLet false false (PVar "seeds") (EApp (EApp (EVar "requireGoalSeeds") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "obls"))) (DoLet false false (PVar "goals") (EApp (EApp (EApp (EApp (EVar "nestedRequireGoalsOnce") (EVar "mctx")) (EVar "rigidIds")) (EVar "liveIds")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "followRequireGoal") (EVar "mctx")) (EVar "rigidIds")) (EVar "liveIds"))) (EVar "seeds")))) (DoExpr (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "s")) (EFieldAccess (EFieldAccess (EApp (EVar "reqWalkMemo") (EApp (EVar "snd") (EVar "s"))) "wmStopped") "value"))) (EVar "seeds")) (EApp (EApp (EApp (EApp (EVar "nestedRequireGoalsGo") (EVar "mctx")) (EVar "rigidIds")) (EVar "liveIds")) (EApp (EApp (EVar "requireGoalSeeds") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "obls"))) (EVar "goals")))))
(DTypeSig false "requireGoalSeeds" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyApp (TyCon "List") (TyTuple (TyCon "UObligation") (TyCon "ReqWalk"))))))
(DFunDef false "requireGoalSeeds" ((PVar "gctx") (PVar "obls")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "o")) (ETuple (EVar "o") (EApp (EApp (EVar "reqWalkSeed") (EFieldAccess (EFieldAccess (EVar "o") "pred") "iface")) (EApp (EApp (EMethodRef "map") (EVar "normalize")) (EApp (EApp (EVar "uOblArgs") (EVar "gctx")) (EVar "o"))))))) (EVar "obls")))
(DTypeSig false "nestedRequireGoalsGo" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "UObligation") (TyCon "ReqWalk"))) (TyApp (TyCon "List") (TyCon "UObligation")))))))
(DFunDef false "nestedRequireGoalsGo" ((PVar "mctx") (PVar "rigidIds") (PVar "liveIds") (PVar "walks")) (EMatch (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "selectedRequireGoals") (EVar "mctx")) (EVar "rigidIds")) (EVar "liveIds"))) (EVar "walks")) (arm (PList) () (EListLit)) (arm (PVar "derived") () (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "derived")) (EApp (EApp (EApp (EApp (EVar "nestedRequireGoalsGo") (EVar "mctx")) (EVar "rigidIds")) (EVar "liveIds")) (EVar "derived"))))))
(DTypeSig false "nestedRequireGoalsOnce" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "UObligation") (TyCon "ReqWalk"))) (TyApp (TyCon "List") (TyCon "UObligation")))))))
(DFunDef false "nestedRequireGoalsOnce" ((PVar "mctx") PWild PWild (PList)) (EListLit))
(DFunDef false "nestedRequireGoalsOnce" ((PVar "mctx") (PVar "rigidIds") (PVar "liveIds") (PVar "walks")) (EBlock (DoLet false false (PTuple (PVar "kept") (PVar "derived")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "followRequireLevel") (EVar "mctx")) (EVar "rigidIds")) (EVar "liveIds")) (EVar "walks")) (EListLit)) (EListLit))) (DoExpr (EBinOp "++" (EVar "kept") (EApp (EApp (EApp (EApp (EVar "nestedRequireGoalsOnce") (EVar "mctx")) (EVar "rigidIds")) (EVar "liveIds")) (EVar "derived"))))))
(DTypeSig false "followRequireLevel" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "UObligation") (TyCon "ReqWalk"))) (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "UObligation") (TyCon "ReqWalk")))) (TyTuple (TyApp (TyCon "List") (TyCon "UObligation")) (TyApp (TyCon "List") (TyTuple (TyCon "UObligation") (TyCon "ReqWalk")))))))))))
(DFunDef false "followRequireLevel" ((PVar "mctx") PWild PWild (PList) (PVar "kept") (PVar "derived")) (ETuple (EApp (EVar "reverse") (EVar "kept")) (EApp (EApp (EDictApp "flatMap") (EVar "identity")) (EApp (EVar "reverse") (EVar "derived")))))
(DFunDef false "followRequireLevel" ((PVar "mctx") (PVar "rigidIds") (PVar "liveIds") (PCons (PTuple (PVar "o") (PVar "walk")) (PVar "rest")) (PVar "kept") (PVar "derived")) (EIf (EApp (EApp (EApp (EVar "walkGoalFollowed") (EVar "walk")) (EFieldAccess (EFieldAccess (EVar "o") "pred") "iface")) (EApp (EApp (EVar "uOblGoalArgs") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "o"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "followRequireLevel") (EVar "mctx")) (EVar "rigidIds")) (EVar "liveIds")) (EVar "rest")) (EVar "kept")) (EVar "derived")) (EBlock (DoLet false false (PVar "below") (EApp (EApp (EApp (EApp (EVar "followRequireGoal") (EVar "mctx")) (EVar "rigidIds")) (EVar "liveIds")) (ETuple (EVar "o") (EVar "walk")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "followRequireLevel") (EVar "mctx")) (EVar "rigidIds")) (EVar "liveIds")) (EVar "rest")) (EBinOp "::" (EVar "o") (EVar "kept"))) (EBinOp "::" (EVar "below") (EVar "derived")))))))
(DTypeSig false "followRequireGoal" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyTuple (TyCon "UObligation") (TyCon "ReqWalk")) (TyApp (TyCon "List") (TyTuple (TyCon "UObligation") (TyCon "ReqWalk"))))))))
(DFunDef false "followRequireGoal" ((PVar "mctx") (PVar "rigidIds") (PVar "liveIds") (PTuple (PVar "o") (PVar "walk"))) (EBlock (DoLet false false (PTuple (PVar "clean") (PVar "below")) (EApp (EApp (EApp (EVar "solvedCleanly") (EVar "mctx")) (ELam ((PVar "goals")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "g")) (EApp (EApp (EVar "uOblArgs") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EVar "fst") (EVar "g"))))) (EVar "goals")))) (ELam (PWild) (EApp (EApp (EApp (EApp (EApp (EVar "requireGoalsBelow") (EVar "mctx")) (EVar "prerequisiteUnreported")) (EVar "rigidIds")) (EVar "liveIds")) (ETuple (EVar "o") (EVar "walk")))))) (DoExpr (EIf (EVar "clean") (EApp (EApp (EApp (EVar "noteWalkGoalFollowed") (EVar "walk")) (EFieldAccess (EFieldAccess (EVar "o") "pred") "iface")) (EApp (EApp (EVar "uOblGoalArgs") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "o"))) (ELit LUnit))) (DoExpr (EVar "below"))))
(DTypeSig false "uOblGoalArgs" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "UObligation") (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "uOblGoalArgs" ((PVar "gctx") (PVar "o")) (EApp (EApp (EMethodRef "map") (EVar "normalize")) (EApp (EApp (EVar "uOblArgs") (EVar "gctx")) (EVar "o"))))
(DTypeSig false "selectedRequireGoals" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyTuple (TyCon "UObligation") (TyCon "ReqWalk")) (TyApp (TyCon "List") (TyTuple (TyCon "UObligation") (TyCon "ReqWalk"))))))))
(DFunDef false "selectedRequireGoals" ((PVar "mctx") (PVar "rigidIds") (PVar "liveIds") (PVar "walk")) (EApp (EApp (EApp (EApp (EApp (EVar "requireGoalsBelow") (EVar "mctx")) (EApp (EVar "prerequisiteOnWalk") (EVar "mctx"))) (EVar "rigidIds")) (EVar "liveIds")) (EVar "walk")))
(DTypeSig false "prerequisiteUnreported" (TyFun (TyCon "ReqWalk") (TyFun (TyCon "UObligation") (TyApp (TyCon "List") (TyTuple (TyCon "UObligation") (TyCon "ReqWalk"))))))
(DFunDef false "prerequisiteUnreported" ((PVar "walk") (PVar "g")) (EMatch (EApp (EApp (EApp (EVar "reqWalkEnter") (EVar "walk")) (EFieldAccess (EFieldAccess (EVar "g") "pred") "iface")) (EApp (EApp (EMethodRef "map") (EVar "normalize")) (EFieldAccess (EFieldAccess (EVar "g") "pred") "args"))) (arm (PCon "ReqOn" (PVar "next")) () (EListLit (ETuple (EVar "g") (EVar "next")))) (arm PWild () (EBlock (DoLet false false (PVar "memo") (EApp (EVar "reqWalkMemo") (EVar "walk"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "memo") "wmStopped")) (EVar "True"))) (DoExpr (EListLit))))))
(DTypeSig true "inferImplBodies" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Decl"))) (TyCon "Unit")))))))
(DFunDef false "inferImplBodies" ((PVar "env") PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "inferImplBodies" ((PVar "env") (PVar "rpNames") (PVar "ce") (PVar "cur") (PCons (PTuple (PVar "loc") (PVar "d")) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "inferOneImpl") (EApp (EApp (EVar "envAtIfSome") (EVar "loc")) (EVar "env"))) (EVar "rpNames")) (EVar "ce")) (EVar "cur")) (EVar "d"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "inferImplBodies") (EVar "env")) (EVar "rpNames")) (EVar "ce")) (EVar "cur")) (EVar "rest")))))
(DTypeSig true "implDeclLoc" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "implDeclLoc" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "implDeclLoc") (EVar "d")))
(DFunDef false "implDeclLoc" ((PRec "DImpl" ((rf "implIfaceLoc" None)) true)) (EApp (EVar "Some") (EVar "implIfaceLoc")))
(DFunDef false "implDeclLoc" (PWild) (EVar "None"))
(DTypeSig false "inferOneImpl" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyFun (TyCon "Decl") (TyCon "Unit")))))))
(DFunDef false "inferOneImpl" ((PVar "env") (PVar "rpNames") (PVar "ce") (PVar "cur") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EApp (EVar "inferOneImpl") (EVar "env")) (EVar "rpNames")) (EVar "ce")) (EVar "cur")) (EVar "d")))
(DFunDef false "inferOneImpl" ((PVar "env") (PVar "rpNames") (PVar "ce") (PVar "cur") (PRec "DImpl" ((rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "methods" None) (rf "implOrigin" None)) true)) (EBlock (DoLet false false (PVar "iref") (ERecordCreate "IfaceRef" ((fa "irName" (EVar "iface")) (fa "irOrigin" (EVar "implOrigin"))))) (DoExpr (EMatch (EVar "reqs") (arm (PList) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferPlainImpl") (EVar "env")) (EVar "ce")) (EVar "cur")) (EVar "iref")) (EVar "tys")) (EVar "methods"))) (arm PWild () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferRequiresImpl") (EVar "env")) (EVar "rpNames")) (EVar "ce")) (EVar "cur")) (EVar "iref")) (EVar "tys")) (EVar "reqs")) (EVar "methods")))))))
(DFunDef false "inferOneImpl" ((PVar "env") PWild PWild PWild PWild) (ELit LUnit))
(DTypeSig false "inferPlainImpl" (TyFun (TyCon "TcEnv") (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyCon "Unit"))))))))
(DFunDef false "inferPlainImpl" ((PVar "env") (PVar "ce") (PVar "cur") (PVar "iface") (PVar "tys") (PVar "methods")) (EBlock (DoLet false false (PTuple (PVar "implTvMap") (PVar "headMonos")) (EApp (EApp (EVar "implHeadMonos") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "tys"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferImplMethods") (EVar "env")) (EVar "ce")) (EVar "cur")) (EVar "iface")) (EVar "implTvMap")) (EVar "headMonos")) (EListLit)) (EApp (EApp (EApp (EVar "scopeImplMethods") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EApp (EVar "captureScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (EVar "methods"))))))
(DTypeSig false "inferRequiresImpl" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyCon "Unit"))))))))))
(DFunDef false "inferRequiresImpl" ((PVar "env") (PVar "rpNames") (PVar "ce") (PVar "cur") (PVar "iface") (PVar "tys") (PVar "reqs") (PVar "methods")) (EBlock (DoLet false false (PTuple (PVar "implTvMap") (PVar "headMonos")) (EApp (EApp (EVar "implHeadMonos") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "tys"))) (DoLet false false (PVar "scopedMethods") (EApp (EApp (EApp (EVar "scopeImplMethods") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EApp (EVar "captureScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (EVar "methods"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferImplMethods") (EVar "env")) (EVar "ce")) (EVar "cur")) (EVar "iface")) (EVar "implTvMap")) (EVar "headMonos")) (EVar "reqs")) (EVar "scopedMethods"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerImplRequires") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "ce")) (EVar "cur")) (EVar "iface")) (EVar "implTvMap")) (EVar "rpNames")) (EVar "reqs")) (EVar "scopedMethods")))))
(DTypeSig false "scopeImplMethods" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyApp (TyCon "List") (TyCon "ScopedImplMethod"))))))
(DFunDef false "scopeImplMethods" ((PVar "mctx") PWild (PList)) (EListLit))
(DFunDef false "scopeImplMethods" ((PVar "mctx") (PVar "parent") (PCons (PVar "method") (PVar "rest"))) (EBlock (DoLet false false (PVar "name") (EApp (EVar "implMethodName") (EVar "method"))) (DoLet false false (PVar "scope") (EApp (EApp (EApp (EApp (EApp (EVar "Scopes.freshScope") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EApp (EVar "Some") (EVar "parent"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (EFieldAccess (EApp (EApp (EVar "Scopes.scopeFrame") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EVar "parent")) "sfModuleId")) (EApp (EVar "BindingOwner") (EVar "name")))) (DoExpr (EBinOp "::" (ERecordCreate "ScopedImplMethod" ((fa "simMethod" (EVar "method")) (fa "simScope" (EVar "scope")))) (EApp (EApp (EApp (EVar "scopeImplMethods") (EVar "mctx")) (EVar "parent")) (EVar "rest"))))))
(DTypeSig false "inferImplMethods" (TyFun (TyCon "TcEnv") (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyFun (TyApp (TyCon "List") (TyCon "ScopedImplMethod")) (TyCon "Unit"))))))))))
(DFunDef false "inferImplMethods" ((PVar "env") PWild PWild PWild PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "inferImplMethods" ((PVar "env") (PVar "ce") (PVar "cur") (PVar "iface") (PVar "implTvMap") (PVar "headMonos") (PVar "reqs") (PCons (PVar "m") (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferImplMethod") (EVar "env")) (EVar "ce")) (EVar "cur")) (EVar "iface")) (EVar "implTvMap")) (EVar "headMonos")) (EVar "reqs")) (EVar "m"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferImplMethods") (EVar "env")) (EVar "ce")) (EVar "cur")) (EVar "iface")) (EVar "implTvMap")) (EVar "headMonos")) (EVar "reqs")) (EVar "rest")))))
(DTypeSig false "inferImplMethod" (TyFun (TyCon "TcEnv") (TyFun (TyCon "ClassEnv") (TyFun (TyCon "Int") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyFun (TyCon "ScopedImplMethod") (TyCon "Unit"))))))))))
(DFunDef false "inferImplMethod" ((PVar "env") (PVar "ce") (PVar "cur") (PVar "iface") (PVar "implTvMap") (PVar "headMonos") (PVar "reqs") (PVar "scoped")) (EMatch (EFieldAccess (EVar "scoped") "simMethod") (arm (PCon "ImplMethod" (PVar "mname") (PVar "pats") (PVar "body")) () (EMatch (EApp (EApp (EApp (EApp (EVar "ceMethodTyAt") (EVar "iface")) (EVar "mname")) (EVar "cur")) (EVar "ce")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "sig")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferMethodBody") (EVar "env")) (EVar "iface")) (EApp (EVar "ImplBody") (ERecordCreate "ImplBodySite" ((fa "ibImplTvMap" (EVar "implTvMap")) (fa "ibHeadMonos" (EVar "headMonos")) (fa "ibRequires" (EVar "reqs")) (fa "ibScope" (EFieldAccess (EVar "scoped") "simScope")))))) (EVar "sig")) (EVar "mname")) (EVar "pats")) (EVar "body")))))))
(DTypeSig false "inferMethodBody" (TyFun (TyCon "TcEnv") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "MethodBodyKind") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind"))))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyCon "Unit")))))))))
(DFunDef false "inferMethodBody" ((PVar "outer") (PVar "iface") (PVar "kind") (PTuple (PVar "params") (PVar "mty") (PVar "gscope")) (PVar "mname") (PVar "pats") (PVar "body")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EVar "envAtIfSome") (EApp (EVar "exprSpanLoc") (EVar "body"))) (EVar "outer"))) (DoExpr (EApp (EApp (EVar "enterLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "bodyLevel") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentLevel") "value")) (DoLet false false (PVar "bodyScope") (EApp (EApp (EApp (EApp (EVar "openMethodBodyScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "iface")) (EVar "mname")) (EVar "kind"))) (DoLet false false (PVar "savedCurrentFn") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentFn") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentFn")) (EVar "mname"))) (DoExpr (EMatch (EVar "kind") (arm (PCon "ImplBody" PWild) () (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentImplBody")) (EVar "True"))) (arm (PCon "DefaultBody") () (ELit LUnit)))) (DoLet false false (PVar "oblN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls"))) (DoLet false false (PVar "callN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "obls"))) (DoLet false false (PVar "dictN0") (EApp (EApp (EVar "goalsMark") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (DoLet false false (PVar "inst") (EApp (EApp (EApp (EApp (EApp (EVar "instantiateMethodBody") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "kind")) (EVar "params")) (EVar "mty")) (EVar "gscope"))) (DoLet false false (PVar "headBefore") (EMatch (EVar "kind") (arm (PCon "ImplBody" (PVar "site")) () (EApp (EVar "implHeadVarRoots") (EFieldAccess (EVar "site") "ibImplTvMap"))) (arm (PCon "DefaultBody") () (EListLit)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerMethodBodyGrants") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "iface")) (EVar "mname")) (EApp (EVar "methodBodyHeadMonos") (EVar "kind"))) (EVar "inst")) (EVar "bodyScope"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordClauseFileBound") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "body")) (EApp (EVar "listLen") (EVar "pats"))) (EFieldAccess (EVar "inst") "mbiExpected"))) (DoLet false false (PVar "loc") (EApp (EApp (EVar "orElseLoc") (EApp (EVar "implBodyLoc") (EVar "body"))) (EApp (EVar "firstTyLoc") (EVar "mty")))) (DoLet false false (PVar "subject") (EApp (EApp (EApp (EVar "methodBodySubject") (EVar "kind")) (EFieldAccess (EVar "iface") "irName")) (EVar "mname"))) (DoLet false false (PVar "contract") (EApp (EApp (EApp (EVar "beginEffectContract") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EVar "inst") "mbiContractForce")) (EFieldAccess (EVar "inst") "mbiExpected"))) (DoLet false false (PTuple (PVar "bodyErred") (PVar "check")) (EApp (EApp (EVar "erredDuring") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELam (PWild) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkMethodBodyAgainst") (EVar "env")) (EVar "iface")) (EVar "kind")) (EVar "mname")) (EVar "mty")) (EVar "gscope")) (EVar "inst")) (EVar "contract")) (EVar "loc")) (EVar "pats")) (EVar "body"))))) (DoLet false false (PVar "headMonos") (EApp (EVar "methodBodyHeadMonos") (EVar "kind"))) (DoLet false false (PVar "launderFlagged") (EMatch (EVar "kind") (arm (PCon "ImplBody" PWild) () (EFieldAccess (EVar "check") "mbcLaunderFlagged")) (arm (PCon "DefaultBody") () (EVar "False")))) (DoLet false false (PVar "effVarRigidity") (ELam (PWild) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkMethodEffVarRigidity") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "subject")) (EVar "headMonos")) (EVar "gscope")) (EVar "mty")) (EFieldAccess (EVar "inst") "mbiEffVars")) (EVar "launderFlagged")) (EFieldAccess (EVar "check") "mbcEagerIndexed")) (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EFieldAccess (EVar "check") "mbcPerformedAt"))))) (DoExpr (EMatch (EVar "kind") (arm (PCon "DefaultBody") () (EIf (EVar "bodyErred") (ELit LUnit) (EApp (EVar "effVarRigidity") (ELit LUnit)))) (arm (PCon "ImplBody" PWild) () (ELit LUnit)))) (DoLet false false (PVar "addedObls") (EApp (EApp (EVar "wWindow") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls")) (EVar "oblN0"))) (DoLet false false (PVar "addedCallObls") (EApp (EApp (EVar "callOblsWindow") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "callN0"))) (DoLet false false (PVar "bodyRigidIds") (EApp (EVar "monoRootIdSet") (EBinOp "++" (EBinOp "++" (EVar "headMonos") (EListLit (EFieldAccess (EVar "inst") "mbiExpected"))) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EFieldAccess (EVar "inst") "mbiNamedVars"))))) (DoLet false false (PVar "bodyObls") (EBinOp "++" (EVar "addedObls") (EApp (EApp (EVar "callUOblsWindow") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "callN0")))) (DoExpr (EApp (EApp (EApp (EVar "improveByUniqueImpl") (EFieldAccess (EVar "env") "teDyn")) (EVar "bodyRigidIds")) (EVar "bodyObls"))) (DoExpr (EApp (EApp (EApp (EVar "determineByUniqueInstance") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "bodyRigidIds")) (EVar "bodyObls"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkMethodRigidityCore") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "subject")) (EFieldAccess (EVar "iface") "irName")) (EVar "mty")) (EVar "headMonos")) (EFieldAccess (EVar "inst") "mbiSurvivors")) (EApp (EApp (EVar "methodBodyOwnTyparams") (EVar "kind")) (EVar "params"))) (EVar "addedObls")) (EVar "addedCallObls")) (EVar "loc"))) (DoExpr (EMatch (EVar "kind") (arm (PCon "ImplBody" (PVar "site")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkImplHeadRigidity") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "subject")) (EFieldAccess (EVar "iface") "irName")) (EVar "site")) (EVar "headBefore")) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstExprLoc") (EVar "body"))) (EVar "loc")))) (arm (PCon "DefaultBody") () (ELit LUnit)))) (DoExpr (EMatch (EVar "kind") (arm (PCon "ImplBody" PWild) () (EApp (EVar "effVarRigidity") (ELit LUnit))) (arm (PCon "DefaultBody") () (ELit LUnit)))) (DoLet false false (PVar "survivingNumIds") (EMatch (EVar "kind") (arm (PCon "ImplBody" (PVar "site")) () (EApp (EApp (EVar "numChannelRootSet") (EVar "addedObls")) (EBinOp "++" (EFieldAccess (EVar "site") "ibHeadMonos") (EApp (EApp (EApp (EVar "methodLevelConstraintMonos") (EVar "params")) (EVar "mty")) (EFieldAccess (EVar "inst") "mbiNamedVars"))))) (arm (PCon "DefaultBody") () (EApp (EVar "monoRootIdSet") (EListLit (EFieldAccess (EVar "inst") "mbiExpected")))))) (DoExpr (EMatch (EVar "kind") (arm (PCon "ImplBody" (PVar "site")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkImplHeadNumObligations") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "subject")) (EFieldAccess (EVar "site") "ibImplTvMap")) (EFieldAccess (EVar "site") "ibRequires")) (EVar "survivingNumIds")) (EVar "addedObls"))) (arm (PCon "DefaultBody") () (ELit LUnit)))) (DoExpr (EMatch (EVar "kind") (arm (PCon "ImplBody" (PVar "site")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkImplHeadPrerequisites") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "subject")) (EVar "iface")) (EVar "site")) (EFieldAccess (EVar "inst") "mbiNamedVars")) (EVar "mty")) (EVar "addedObls")) (EVar "addedCallObls"))) (arm (PCon "DefaultBody") () (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "exitLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "withheld") (EApp (EApp (EVar "finalizeNumBoundary") (EFieldAccess (EVar "env") "teDyn")) (ERecordCreate "NumBoundary" ((fa "nbDisposition" (EApp (EVar "NumBoundaryOwnedMethodBody") (EVar "bodyLevel"))) (fa "nbMembers" (EListLit (EFieldAccess (EVar "inst") "mbiExpected"))) (fa "nbSurvivingIds" (EVar "survivingNumIds")) (fa "nbDefaultObls" (EBinOp "++" (EVar "addedObls") (EApp (EApp (EApp (EVar "calleeNumObls") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "callN0")) (EVar "dictN0")))) (fa "nbAmbiguityObls" (EVar "addedObls")) (fa "nbGuard" (ERecordCreate "NumGuard" ((fa "ngGoals" (EVar "bodyObls")) (fa "ngRigidIds" (EVar "bodyRigidIds")) (fa "ngOuterBelow" (EVar "None"))))))))) (DoExpr (EApp (EApp (EApp (EVar "improveByUniqueImpl") (EFieldAccess (EVar "env") "teDyn")) (EVar "bodyRigidIds")) (EVar "bodyObls"))) (DoExpr (EApp (EApp (EApp (EVar "determineByUniqueInstance") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "bodyRigidIds")) (EVar "bodyObls"))) (DoLet false false (PVar "methodSig") (EListLit (ETuple (EVar "mname") (EVar "mty") (EFieldAccess (EVar "inst") "mbiSurvivors")))) (DoLet false false (PVar "methodVarIds") (EApp (EVar "sccProtectedSignatureIds") (EVar "methodSig"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "publishMethodPredGivens") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "params")) (EVar "mty")) (EVar "inst")) (EVar "bodyScope"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "checkSigVarGoals") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "DeclaredBySignature")) (EVar "methodVarIds")) (EVar "methodSig")) (EVar "bodyObls"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "rejectUndeterminedVectors") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "bodyRigidIds")) (EVar "omEmpty")) (EVar "addedObls")) (EBinOp "++" (EApp (EApp (EVar "callUOblsWindow") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "callN0")) (EApp (EApp (EApp (EApp (EVar "nestedRequireGoals") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "bodyRigidIds")) (EVar "omEmpty")) (EVar "bodyObls"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "rejectWithheldAmbiguity") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "bodyRigidIds")) (EVar "withheld")) (EVar "bodyObls"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerMethodBodyGivens") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "iface")) (EVar "kind")) (EVar "params")) (EVar "mty")) (EVar "inst")) (EVar "bodyScope"))) (DoExpr (EMatch (EVar "kind") (arm (PCon "ImplBody" PWild) () (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentImplBody")) (EVar "False"))) (arm (PCon "DefaultBody") () (ELit LUnit)))) (DoLet false false (PVar "restoredFn") (EMatch (EVar "kind") (arm (PCon "ImplBody" PWild) () (ELit (LString ""))) (arm (PCon "DefaultBody") () (EVar "savedCurrentFn")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentFn")) (EVar "restoredFn"))) (DoExpr (EApp (EApp (EVar "closeScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit)))))
(DTypeSig false "openMethodBodyScope" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "String") (TyFun (TyCon "MethodBodyKind") (TyCon "ScopeId"))))))
(DFunDef false "openMethodBodyScope" ((PVar "mctx") PWild PWild (PCon "ImplBody" (PVar "site"))) (EBlock (DoExpr (EApp (EApp (EVar "openScope") (EVar "mctx")) (EFieldAccess (EVar "site") "ibScope"))) (DoExpr (EFieldAccess (EVar "site") "ibScope"))))
(DFunDef false "openMethodBodyScope" ((PVar "mctx") (PVar "iface") (PVar "mname") (PCon "DefaultBody")) (EBlock (DoLet false false (PVar "parentScope") (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) (DoLet false false (PVar "owner") (ERecordCreate "DefaultBodyIdentity" ((fa "dbiIface" (EVar "iface")) (fa "dbiMethod" (EVar "mname"))))) (DoLet false false (PVar "bodyScope") (EApp (EApp (EApp (EApp (EApp (EVar "Scopes.freshScope") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EApp (EVar "Some") (EVar "parentScope"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (EFieldAccess (EApp (EApp (EVar "Scopes.scopeFrame") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EVar "parentScope")) "sfModuleId")) (EApp (EVar "DefaultBodyOwner") (EVar "owner")))) (DoExpr (EApp (EApp (EVar "openScope") (EVar "mctx")) (EVar "bodyScope"))) (DoExpr (EVar "bodyScope"))))
(DTypeSig false "instantiateMethodBody" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "MethodBodyKind") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyCon "MethodBodyInstance")))))))
(DFunDef false "instantiateMethodBody" ((PVar "mctx") (PCon "ImplBody" (PVar "site")) (PVar "ifaceParams") (PVar "mty") (PVar "gscope")) (EBlock (DoLet false false (PVar "baseMap") (EApp (EApp (EVar "zip") (EVar "ifaceParams")) (EFieldAccess (EVar "site") "ibHeadMonos"))) (DoLet false false (PVar "extraMap") (EApp (EApp (EVar "freshTvMap") (EVar "mctx")) (EApp (EApp (EVar "removeAllS") (EVar "ifaceParams")) (EApp (EApp (EVar "removeAllS") (EApp (EApp (EApp (EVar "rowArgNamesIn") (EVar "mctx")) (EVar "gscope")) (EVar "mty"))) (EApp (EVar "dedup") (EApp (EVar "tyVarNames") (EVar "mty"))))))) (DoLet false false (PVar "effMap") (EApp (EApp (EApp (EVar "sigVarsFor") (EVar "mctx")) (EVar "mty")) (EApp (EVar "dedup") (EBinOp "++" (EApp (EVar "effTailNames") (EVar "mty")) (EApp (EApp (EApp (EVar "rowArgNamesIn") (EVar "mctx")) (EVar "gscope")) (EVar "mty")))))) (DoLet false false (PVar "mtvs") (EBinOp "++" (EVar "baseMap") (EVar "extraMap"))) (DoLet false false (PVar "expected") (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "effMap")) (EVar "mtvs")) (EVar "mty"))) (DoLet false false (PVar "contractForce") (EApp (EApp (EApp (EApp (EVar "bindingForceFromAst") (EVar "mctx")) (EVar "effMap")) (EVar "mtvs")) (EVar "mty"))) (DoExpr (ERecordCreate "MethodBodyInstance" ((fa "mbiExpected" (EVar "expected")) (fa "mbiContractForce" (EVar "contractForce")) (fa "mbiCheckedForce" (ELam (PWild) (EApp (EApp (EApp (EApp (EVar "bindingForceFromAst") (EVar "mctx")) (EVar "effMap")) (EVar "mtvs")) (EVar "mty")))) (fa "mbiEffVars" (EFieldAccess (EVar "effMap") "svRows")) (fa "mbiSurvivors" (EVar "extraMap")) (fa "mbiNamedVars" (EVar "mtvs")) (fa "mbiDictSlots" (EListLit)) (fa "mbiTypeSubst" (EListLit)))))))
(DFunDef false "instantiateMethodBody" ((PVar "mctx") (PCon "DefaultBody") (PVar "typarams") (PVar "mty") (PVar "dscope")) (EBlock (DoLet false false (PVar "st") (EApp (EApp (EApp (EVar "sigToSchemeTvsIn") (EVar "mctx")) (EVar "dscope")) (EVar "mty"))) (DoLet false false (PVar "descriptor") (EApp (EApp (EVar "instantiateMethodTracked") (EVar "mctx")) (EApp (EVar "fst") (EVar "st")))) (DoLet false false (PVar "subst") (EFieldAccess (EFieldAccess (EVar "descriptor") "mtiSubstitution") "misTypeSubst")) (DoExpr (ERecordCreate "MethodBodyInstance" ((fa "mbiExpected" (EFieldAccess (EVar "descriptor") "mtiBody")) (fa "mbiContractForce" (EFieldAccess (EVar "descriptor") "mtiForce")) (fa "mbiCheckedForce" (ELam (PWild) (EApp (EVar "effrowNorm") (EFieldAccess (EVar "descriptor") "mtiForce")))) (fa "mbiEffVars" (EApp (EApp (EVar "zip") (EApp (EVar "dedup") (EBinOp "++" (EApp (EVar "effTailNames") (EVar "mty")) (EApp (EApp (EApp (EVar "rowArgNamesIn") (EVar "mctx")) (EVar "dscope")) (EVar "mty"))))) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EFieldAccess (EFieldAccess (EVar "descriptor") "mtiSubstitution") "misEffectSubst")))) (fa "mbiSurvivors" (EApp (EApp (EVar "defaultSurvivorMap") (EApp (EVar "snd") (EVar "st"))) (EVar "subst"))) (fa "mbiNamedVars" (EApp (EApp (EApp (EVar "instantiateNamedMonos") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EVar "snd") (EVar "st"))) (EVar "subst"))) (fa "mbiDictSlots" (EApp (EApp (EApp (EVar "methodConstraintSlotIds") (EVar "typarams")) (EVar "mty")) (EApp (EVar "snd") (EVar "st")))) (fa "mbiTypeSubst" (EVar "subst")))))))
(DTypeSig false "methodBodyHeadMonos" (TyFun (TyCon "MethodBodyKind") (TyApp (TyCon "List") (TyCon "Mono"))))
(DFunDef false "methodBodyHeadMonos" ((PCon "ImplBody" (PVar "site"))) (EFieldAccess (EVar "site") "ibHeadMonos"))
(DFunDef false "methodBodyHeadMonos" ((PCon "DefaultBody")) (EListLit))
(DTypeSig false "methodBodyOwnTyparams" (TyFun (TyCon "MethodBodyKind") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "methodBodyOwnTyparams" ((PCon "ImplBody" PWild) PWild) (EListLit))
(DFunDef false "methodBodyOwnTyparams" ((PCon "DefaultBody") (PVar "typarams")) (EVar "typarams"))
(DTypeSig false "gatesBodyCascade" (TyFun (TyCon "MethodBodyKind") (TyCon "Bool")))
(DFunDef false "gatesBodyCascade" ((PCon "ImplBody" PWild)) (EVar "False"))
(DFunDef false "gatesBodyCascade" ((PCon "DefaultBody")) (EVar "True"))
(DTypeSig false "checkMethodBodyAgainst" (TyFun (TyCon "TcEnv") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "MethodBodyKind") (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "MethodBodyInstance") (TyFun (TyTuple (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyCon "MethodBodyCheck")))))))))))))
(DFunDef false "checkMethodBodyAgainst" ((PVar "env") (PVar "iface") (PVar "kind") (PVar "mname") (PVar "mty") (PVar "gscope") (PVar "inst") (PVar "contract") (PVar "loc") (PVar "pats") (PVar "body")) (EBlock (DoLet false false (PVar "oblSnapshot") (EApp (EVar "wSnapshot") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls"))) (DoLet false false (PVar "indexOnly") (EMatch (EVar "kind") (arm (PCon "ImplBody" PWild) () (EApp (EApp (EApp (EVar "indexOnlyEffVars") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "gscope")) (EVar "mty"))) (arm (PCon "DefaultBody") () (EListLit)))) (DoLet false false (PVar "sites") (EIf (EApp (EVar "isEmptyL") (EVar "indexOnly")) (EVar "None") (EApp (EVar "Some") (EApp (EVar "Ref") (EListLit))))) (DoLet false false (PVar "envSites") (ERecordUpdate (EVar "env") ((fa "teDyn" (ERecordUpdate (EFieldAccess (EVar "env") "teDyn") ((fa "dcPerformSites" (EVar "sites")))))))) (DoLet false false (PTuple (PVar "inferErred") (PVar "inferred")) (EApp (EApp (EVar "erredDuring") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELam (PWild) (EApp (EApp (EApp (EApp (EApp (EVar "inferBindingChecked") (EVar "False")) (EVar "envSites")) (EApp (EVar "Some") (EApp (EVar "normalize") (EFieldAccess (EVar "inst") "mbiExpected")))) (EVar "pats")) (EVar "body"))))) (DoLet false false (PVar "actual") (EApp (EVar "fst") (EVar "inferred"))) (DoLet false false (PVar "check") (EIf (EBinOp "&&" (EVar "inferErred") (EApp (EVar "gatesBodyCascade") (EVar "kind"))) (ERecordCreate "MethodBodyCheck" ((fa "mbcLaunderFlagged" (EVar "False")) (fa "mbcEagerIndexed" (EListLit)) (fa "mbcPerformedAt" (EVar "None")))) (EBlock (DoExpr (EMatch (EVar "kind") (arm (PCon "ImplBody" PWild) () (EApp (EApp (EApp (EApp (EVar "rowInto") (EFieldAccess (EVar "env") "teDyn")) (EVar "True")) (EApp (EFieldAccess (EVar "inst") "mbiCheckedForce") (ELit LUnit))) (EApp (EVar "effrowNorm") (EApp (EVar "snd") (EVar "inferred"))))) (arm (PCon "DefaultBody") () (ELit LUnit)))) (DoLet false false (PVar "launderMark") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "absorptions"))) (DoLet false false (PVar "declArrows") (EApp (EVar "allArrowEffs") (EFieldAccess (EVar "inst") "mbiExpected"))) (DoLet false false (PVar "actualArrows") (EApp (EVar "allArrowEffs") (EVar "actual"))) (DoLet false false (PVar "eager") (EApp (EApp (EApp (EApp (EApp (EVar "eagerIndexOnlyVars") (EVar "indexOnly")) (EFieldAccess (EVar "inst") "mbiEffVars")) (EVar "actualArrows")) (EFieldAccess (EVar "inst") "mbiExpected")) (EVar "actual"))) (DoLet false false (PVar "performedAt") (EIf (EApp (EVar "isEmptyL") (EVar "eager")) (EVar "None") (EApp (EApp (EVar "performSiteIn") (EVar "sites")) (EVar "actual")))) (DoLet false false (PVar "bodyDyn") (EMatch (EVar "kind") (arm (PCon "DefaultBody") () (ERecordUpdate (EFieldAccess (EVar "env") "teDyn") ((fa "dcMethodMismatch" (EApp (EVar "Some") (EVar "mname")))))) (arm (PCon "ImplBody" PWild) () (EFieldAccess (EVar "env") "teDyn")))) (DoLet false false (PVar "valueDyn") (EApp (EApp (EVar "dynAtIfSome") (EApp (EVar "valueSpanLoc") (EVar "body"))) (EVar "bodyDyn"))) (DoLet false false (PVar "unifyDyn") (EMatch (EVar "kind") (arm (PCon "DefaultBody") () (EVar "valueDyn")) (arm (PCon "ImplBody" PWild) () (EApp (EApp (EVar "dynAtIfSome") (EVar "performedAt")) (EVar "valueDyn"))))) (DoLet false false (PVar "unifyErred") (EApp (EVar "fst") (EApp (EApp (EVar "erredDuring") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELam (PWild) (EBlock (DoExpr (EMatch (EVar "kind") (arm (PCon "DefaultBody") () (EApp (EApp (EApp (EApp (EVar "rowInto") (EVar "bodyDyn")) (EVar "True")) (EApp (EFieldAccess (EVar "inst") "mbiCheckedForce") (ELit LUnit))) (EApp (EVar "effrowNorm") (EApp (EVar "snd") (EVar "inferred"))))) (arm (PCon "ImplBody" PWild) () (ELit LUnit)))) (DoExpr (EApp (EApp (EApp (EApp (EVar "unifyInto") (EVar "unifyDyn")) (EVar "True")) (EFieldAccess (EVar "inst") "mbiExpected")) (EVar "actual")))))))) (DoExpr (EMatch (EVar "kind") (arm (PCon "DefaultBody") () (ELit LUnit)) (arm (PCon "ImplBody" PWild) () (EApp (EApp (EVar "finishEffectContract") (EFieldAccess (EVar "env") "teDyn")) (EVar "contract"))))) (DoLet false false (PVar "escaping") (EApp (EApp (EApp (EApp (EVar "launderEscapeFromLog") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "declArrows")) (EVar "actualArrows")) (EApp (EApp (EVar "wWindow") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "absorptions")) (EVar "launderMark")))) (DoExpr (EMatch (EVar "escaping") (arm (PList) () (ELit LUnit)) (arm PWild () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit (LString "T-EFFECT-LAUNDER"))) (EVar "loc")) (EApp (EApp (EApp (EApp (EVar "methodBodyLaunderMsg") (EVar "kind")) (EFieldAccess (EVar "iface") "irName")) (EVar "mname")) (EVar "escaping")))))) (DoExpr (EIf (EBinOp "&&" (EVar "unifyErred") (EApp (EVar "gatesBodyCascade") (EVar "kind"))) (EApp (EApp (EVar "wRestore") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls")) (EVar "oblSnapshot")) (ELit LUnit))) (DoExpr (ERecordCreate "MethodBodyCheck" ((fa "mbcLaunderFlagged" (EApp (EVar "isNonEmptyL") (EVar "escaping"))) (fa "mbcEagerIndexed" (EVar "eager")) (fa "mbcPerformedAt" (EVar "performedAt")))))))) (DoExpr (EMatch (EVar "kind") (arm (PCon "DefaultBody") () (EApp (EApp (EVar "finishEffectContract") (EFieldAccess (EVar "env") "teDyn")) (EVar "contract"))) (arm (PCon "ImplBody" PWild) () (ELit LUnit)))) (DoExpr (EVar "check"))))
(DTypeSig false "registerMethodBodyGivens" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "MethodBodyKind") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyFun (TyCon "MethodBodyInstance") (TyFun (TyCon "ScopeId") (TyCon "Unit")))))))))
(DFunDef false "registerMethodBodyGivens" ((PVar "gctx") (PVar "iface") (PVar "kind") (PVar "params") (PVar "mty") (PVar "inst") (PVar "scope")) (EBlock (DoExpr (EMatch (EVar "kind") (arm (PCon "ImplBody" PWild) () (EApp (EApp (EApp (EApp (EApp (EVar "registerImplMethodDicts") (EVar "gctx")) (EVar "scope")) (EVar "params")) (EVar "mty")) (EFieldAccess (EVar "inst") "mbiNamedVars"))) (arm (PCon "DefaultBody") () (EApp (EApp (EApp (EApp (EApp (EVar "registerMethodDictSlots") (EVar "gctx")) (EVar "scope")) (ELit (LInt 0))) (EFieldAccess (EVar "inst") "mbiDictSlots")) (EFieldAccess (EVar "inst") "mbiTypeSubst"))))) (DoExpr (EMatch (EVar "kind") (arm (PCon "DefaultBody") () (EBlock (DoLet false false (PVar "receiverArgs") (EApp (EApp (EMethodRef "map") (ELam ((PVar "tp")) (EApp (EApp (EVar "optionOr") (EApp (EVar "TRigid") (EVar "tp"))) (EApp (EApp (EVar "lookupAssoc") (EVar "tp")) (EFieldAccess (EVar "inst") "mbiNamedVars"))))) (EVar "params"))) (DoExpr (EApp (EApp (EApp (EVar "registerFunPredGiven") (EVar "gctx")) (ERecordCreate "PredicateSlot" ((fa "psIface" (EVar "iface")) (fa "psArgs" (EApp (EVar "PSArgsKnown") (EVar "receiverArgs"))) (fa "psBoundIds" (EApp (EVar "dedupI") (EApp (EApp (EDictApp "flatMap") (EVar "monoTyvarIds")) (EVar "receiverArgs"))))))) (EApp (EApp (EVar "Scopes.binderAt") (EVar "scope")) (EVar "defaultReceiverOrdinal")))))) (arm (PCon "ImplBody" PWild) () (ELit LUnit))))))
(DTypeSig false "implBodyLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "implBodyLoc" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "implBodyLoc" ((PCon "ELam" PWild (PVar "b"))) (EApp (EVar "implBodyLoc") (EVar "b")))
(DFunDef false "implBodyLoc" ((PCon "ELet" PWild PWild PWild (PVar "e1") (PVar "e2"))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "implBodyLoc") (EVar "e1"))) (EApp (EVar "implBodyLoc") (EVar "e2"))))
(DFunDef false "implBodyLoc" ((PCon "ELetGroup" PWild (PVar "b"))) (EApp (EVar "implBodyLoc") (EVar "b")))
(DFunDef false "implBodyLoc" (PWild) (EVar "None"))
(DTypeSig false "checkMethodRigidityCore" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "Loc")))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit"))))))))))))
(DFunDef false "checkMethodRigidityCore" ((PVar "mctx") (PVar "subject") (PVar "iface") (PVar "mty") (PVar "headMonos") (PVar "extraMap") (PVar "ownTyparams") (PVar "addedObls") (PVar "addedCallObls") (PVar "loc")) (EBlock (DoLet false false (PVar "pinned") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EVar "filterList") (ELam ((PVar "p")) (EApp (EVar "not") (EApp (EVar "isUnboundTvar") (EApp (EVar "snd") (EVar "p")))))) (EVar "extraMap")))) (DoExpr (EIf (EApp (EVar "isNonEmptyL") (EVar "pinned")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-IMPL-TOO-SPECIFIC"))) (EVar "loc")) (EApp (EApp (EApp (EVar "pinsTyvarMsg") (EVar "subject")) (EVar "mty")) (EVar "pinned"))) (EBlock (DoLet false false (PVar "survivors") (EApp (EVar "sigTvarIds") (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "extraMap")))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "hasDupI") (EVar "survivors")) (EApp (EApp (EVar "anyContainsI") (EVar "survivors")) (EApp (EApp (EDictApp "flatMap") (EVar "monoTyvarIds")) (EVar "headMonos")))) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-IMPL-TOO-SPECIFIC"))) (EVar "loc")) (EApp (EApp (EVar "collapsesTyvarsMsg") (EVar "subject")) (EVar "mty"))) (ELit LUnit)))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkSurvivorObligations") (EVar "mctx")) (EVar "subject")) (EVar "iface")) (EVar "ownTyparams")) (EVar "mty")) (EVar "extraMap")) (EVar "addedObls")) (EVar "loc"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkSurvivorCallObligations") (EVar "mctx")) (EVar "subject")) (EVar "iface")) (EVar "ownTyparams")) (EVar "mty")) (EVar "extraMap")) (EVar "addedCallObls")) (EVar "loc")))))
(DTypeSig false "defaultSurvivorMap" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))))
(DFunDef false "defaultSurvivorMap" ((PList) PWild) (EListLit))
(DFunDef false "defaultSurvivorMap" ((PCons (PTuple (PVar "name") (PVar "m")) (PVar "rest")) (PVar "subst")) (EMatch (EApp (EApp (EVar "lookupAssocI") (EApp (EVar "monoTyvarId") (EVar "m"))) (EVar "subst")) (arm (PCon "Some" (PVar "fm")) () (EBinOp "::" (ETuple (EVar "name") (EVar "fm")) (EApp (EApp (EVar "defaultSurvivorMap") (EVar "rest")) (EVar "subst")))) (arm (PCon "None") () (EApp (EApp (EVar "defaultSurvivorMap") (EVar "rest")) (EVar "subst")))))
(DTypeSig false "checkImplHeadNumObligations" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyCon "Unit"))))))))
(DFunDef false "checkImplHeadNumObligations" ((PVar "mctx") PWild PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "checkImplHeadNumObligations" ((PVar "mctx") (PVar "subject") (PVar "implTvMap") (PVar "reqs") (PVar "survivingIds") (PCons (PVar "o") (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkImplHeadNumIds") (EVar "mctx")) (EVar "subject")) (EVar "implTvMap")) (EVar "reqs")) (EVar "survivingIds")) (EFieldAccess (EVar "o") "loc")) (EApp (EVar "dedupI") (EApp (EVar "numObligIds") (EVar "o"))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkImplHeadNumObligations") (EVar "mctx")) (EVar "subject")) (EVar "implTvMap")) (EVar "reqs")) (EVar "survivingIds")) (EVar "rest")))))
(DTypeSig false "checkImplHeadNumIds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Unit")))))))))
(DFunDef false "checkImplHeadNumIds" ((PVar "mctx") PWild PWild PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "checkImplHeadNumIds" ((PVar "mctx") (PVar "subject") (PVar "implTvMap") (PVar "reqs") (PVar "survivingIds") (PVar "loc") (PCons (PVar "id") (PVar "rest"))) (EBlock (DoExpr (EMatch (EApp (EApp (EVar "survivorNameOfId") (EVar "id")) (EVar "implTvMap")) (arm (PCon "Some" (PVar "vname")) () (EIf (EBinOp "&&" (EApp (EApp (EVar "omHasKey") (EApp (EVar "intToString") (EVar "id"))) (EVar "survivingIds")) (EApp (EVar "not") (EApp (EApp (EApp (EApp (EApp (EVar "implRequiresRoot") (EVar "mctx")) (ELit (LString "Num"))) (EVar "id")) (EVar "implTvMap")) (EVar "reqs")))) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-IMPL-MISSING-REQUIRES"))) (EVar "loc")) (EApp (EApp (EApp (EVar "undeclaredImplPrerequisiteMsg") (EVar "subject")) (ELit (LString "Num"))) (EVar "vname"))) (ELit LUnit))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkImplHeadNumIds") (EVar "mctx")) (EVar "subject")) (EVar "implTvMap")) (EVar "reqs")) (EVar "survivingIds")) (EVar "loc")) (EVar "rest")))))
(DTypeSig false "implRequiresRoot" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyCon "Bool")))))))
(DFunDef false "implRequiresRoot" ((PVar "mctx") PWild PWild PWild (PList)) (EVar "False"))
(DFunDef false "implRequiresRoot" ((PVar "mctx") (PVar "wanted") (PVar "id") (PVar "implTvMap") (PCons (PRec "Require" ((rf "requireHead" (PVar "iface")) (rf "requireArgs" (PVar "args"))) true) (PVar "rest"))) (EBinOp "||" (EBinOp "&&" (EApp (EApp (EVar "contains") (EVar "wanted")) (EApp (EApp (EVar "ifaceSelfAndSupers") (EVar "mctx")) (EVar "iface"))) (EApp (EApp (EApp (EVar "requireArgsAreRoot") (EVar "id")) (EVar "implTvMap")) (EVar "args"))) (EApp (EApp (EApp (EApp (EApp (EVar "implRequiresRoot") (EVar "mctx")) (EVar "wanted")) (EVar "id")) (EVar "implTvMap")) (EVar "rest"))))
(DTypeSig false "requireArgsAreRoot" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Bool")))))
(DFunDef false "requireArgsAreRoot" ((PVar "id") (PVar "implTvMap") (PList (PCon "TyVar" (PVar "name")))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EVar "implTvMap")) (arm (PCon "Some" (PVar "m")) () (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TVar" (PVar "cell")) () (EBinOp "==" (EApp (EVar "tyvarId") (EVar "cell")) (EVar "id"))) (arm PWild () (EVar "False")))) (arm (PCon "None") () (EVar "False"))))
(DFunDef false "requireArgsAreRoot" (PWild PWild PWild) (EVar "False"))
(DTypeSig false "implHeadVarRoots" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "HeadVarRoot")))))
(DFunDef false "implHeadVarRoots" ((PVar "implTvMap")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "p")) (EMatch (EApp (EVar "headVarRootOf") (EApp (EVar "snd") (EVar "p"))) (arm (PCon "Some" (PVar "root")) () (EListLit (ETuple (EApp (EVar "fst") (EVar "p")) (EVar "root")))) (arm (PCon "None") () (EListLit))))) (EVar "implTvMap")))
(DTypeSig false "implHeadTypeVarRoots" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "implHeadTypeVarRoots" ((PVar "implTvMap")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "p")) (EMatch (EApp (EVar "snd") (EVar "p")) (arm (PCon "TypeVarRoot" (PVar "id")) () (EListLit (ETuple (EApp (EVar "fst") (EVar "p")) (EVar "id")))) (arm (PCon "RowVarRoot" PWild) () (EListLit))))) (EApp (EVar "implHeadVarRoots") (EVar "implTvMap"))))
(DTypeSig false "headVarsNarrowedBy" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "HeadVarRoot"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "headVarsNarrowedBy" ((PVar "before") (PVar "implTvMap")) (EBlock (DoLet false false (PVar "after") (EApp (EVar "implHeadVarRoots") (EVar "implTvMap"))) (DoExpr (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "headVarNarrowed") (EVar "before")) (EVar "after"))) (EVar "before"))))))
(DTypeSig false "headVarNarrowed" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "HeadVarRoot"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "HeadVarRoot"))) (TyFun (TyTuple (TyCon "String") (TyCon "HeadVarRoot")) (TyCon "Bool")))))
(DFunDef false "headVarNarrowed" ((PVar "before") (PVar "after") (PTuple (PVar "name") (PVar "root0"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EVar "after")) (arm (PCon "None") () (EVar "True")) (arm (PCon "Some" (PVar "root")) () (EApp (EApp (EVar "anyList") (ELam ((PVar "other")) (EBinOp "&&" (EBinOp "/=" (EApp (EVar "snd") (EVar "other")) (EVar "root0")) (EBinOp "==" (EApp (EApp (EVar "lookupAssoc") (EApp (EVar "fst") (EVar "other"))) (EVar "after")) (EApp (EVar "Some") (EVar "root")))))) (EVar "before")))))
(DTypeSig false "checkImplHeadRigidity" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "ImplBodySite") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "HeadVarRoot"))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit"))))))))
(DFunDef false "checkImplHeadRigidity" ((PVar "mctx") (PVar "subject") (PVar "iface") (PVar "site") (PVar "before") (PVar "loc")) (EMatch (EApp (EApp (EVar "headVarsNarrowedBy") (EVar "before")) (EFieldAccess (EVar "site") "ibImplTvMap")) (arm (PList) () (ELit LUnit)) (arm (PVar "narrowed") () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-IMPL-TOO-SPECIFIC"))) (EVar "loc")) (EApp (EApp (EApp (EVar "narrowsImplHeadMsg") (EVar "subject")) (EVar "narrowed")) (EApp (EApp (EVar "narrowedImplHead") (EVar "iface")) (EVar "site")))))))
(DTypeSig false "narrowedImplHead" (TyFun (TyCon "String") (TyFun (TyCon "ImplBodySite") (TyCon "String"))))
(DFunDef false "narrowedImplHead" ((PVar "iface") (PVar "site")) (EBlock (DoLet false false (PVar "named") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (ETuple (EApp (EVar "snd") (EVar "p")) (EApp (EVar "fst") (EVar "p"))))) (EApp (EVar "implHeadTypeVarRoots") (EFieldAccess (EVar "site") "ibImplTvMap")))) (DoExpr (EApp (EApp (EVar "join") (ELit (LString " "))) (EBinOp "::" (ELit (LString "impl")) (EBinOp "::" (EVar "iface") (EApp (EApp (EApp (EApp (EVar "ppEach") (EApp (EVar "Ref") (EVar "named"))) (EApp (EVar "Ref") (ELit (LInt 0)))) (ELit (LInt 3))) (EFieldAccess (EVar "site") "ibHeadMonos"))))))))
(DTypeSig false "checkImplHeadPrerequisites" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "ImplBodySite") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "Loc")))) (TyCon "Unit"))))))))))
(DFunDef false "checkImplHeadPrerequisites" ((PVar "mctx") (PVar "subject") (PVar "iface") (PVar "site") (PVar "methodTvs") (PVar "mty") (PVar "addedObls") (PVar "addedCallObls")) (EMatch (EApp (EVar "implHeadTypeVarRoots") (EFieldAccess (EVar "site") "ibImplTvMap")) (arm (PList) () (ELit LUnit)) (arm (PVar "roots") () (EBlock (DoLet false false (PVar "givens") (EApp (EApp (EApp (EApp (EApp (EVar "implBodyGivens") (EVar "mctx")) (EVar "iface")) (EVar "site")) (EVar "methodTvs")) (EVar "mty"))) (DoLet false false (PVar "goals") (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EVar "oblPredOf") (EFieldAccess (EVar "mctx") "mcGraph"))) (EVar "addedObls")) (EApp (EApp (EDictApp "flatMap") (EVar "callPredOf")) (EVar "addedCallObls")))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "g")) (EApp (EApp (EApp (EApp (EApp (EVar "checkImplHeadGoal") (EApp (EVar "siteFor") (EVar "mctx"))) (EVar "subject")) (EVar "roots")) (EVar "givens")) (EVar "g")))) (ELit LUnit)) (EVar "goals")))))))
(DTypeSig false "checkImplHeadGoal" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "PredicateSlot")) (TyFun (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Unit")))))))
(DFunDef false "checkImplHeadGoal" ((PVar "sx") (PVar "subject") (PVar "roots") (PVar "givens") (PTuple (PVar "iface") (PVar "ds") (PVar "loc"))) (EBlock (DoLet false false (PVar "args") (EApp (EApp (EMethodRef "map") (EVar "normalize")) (EVar "ds"))) (DoLet false false (PVar "rootIds") (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "roots"))) (DoExpr (EIf (EApp (EApp (EDictApp "any") (ELam ((PVar "i")) (EApp (EApp (EDictApp "elem") (EVar "i")) (EVar "rootIds")))) (EApp (EApp (EDictApp "flatMap") (EVar "monoUnboundIds")) (EVar "args"))) (EBlock (DoLet false false (PVar "headIds") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (ELam ((PVar "r")) (EApp (EVar "intToString") (EApp (EVar "snd") (EVar "r"))))) (EVar "roots"))) (EVar "omEmpty"))) (DoLet false false (PVar "leaves") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "implGoalResiduals") (ERecordUpdate (EVar "sx") ((fa "sxSite" (EVar "loc"))))) (EApp (EVar "reqWalkStart") (ELit LUnit))) (EVar "headIds")) (EVar "givens")) (EVar "iface")) (EVar "args"))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "leaf")) (EApp (EApp (EApp (EApp (EApp (EVar "reportImplHeadResidual") (EFieldAccess (EVar "sx") "sxModule")) (EVar "subject")) (EVar "roots")) (EVar "loc")) (EVar "leaf")))) (ELit LUnit)) (EVar "leaves")))) (ELit LUnit)))))
(DTypeSig false "implBodyGivens" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "ImplBodySite") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "PredicateSlot"))))))))
(DFunDef false "implBodyGivens" ((PVar "mctx") (PVar "iface") (PVar "site") (PVar "methodTvs") (PVar "mty")) (EBlock (DoLet false false (PVar "declared") (EBinOp "++" (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "requirePredicateSlot") (EVar "mctx")) (EFieldAccess (EVar "site") "ibImplTvMap"))) (EFieldAccess (EVar "site") "ibRequires")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "constraintPredicateSlot") (EVar "mctx")) (EVar "methodTvs"))) (EApp (EVar "sigConstraintsOf") (EVar "mty"))))) (DoExpr (EBinOp "::" (EApp (EApp (EVar "knownPredicateSlot") (EVar "iface")) (EFieldAccess (EVar "site") "ibHeadMonos")) (EBinOp "++" (EVar "declared") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "s")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EVar "predicateSlotKnownSupers") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "s"))))) (EVar "declared")))))))
(DTypeSig false "requirePredicateSlot" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Require") (TyCon "PredicateSlot")))))
(DFunDef false "requirePredicateSlot" ((PVar "mctx") (PVar "implTvMap") (PRec "Require" ((rf "requireHead" (PVar "h")) (rf "requireArgs" (PVar "rargs")) (rf "requireOrigin" (PVar "o"))) false)) (EApp (EApp (EVar "knownPredicateSlot") (ERecordCreate "IfaceRef" ((fa "irName" (EVar "h")) (fa "irOrigin" (EVar "o"))))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "fromAstType") (EVar "mctx")) (EVar "implTvMap"))) (EVar "rargs"))))
(DTypeSig false "constraintPredicateSlot" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Constraint") (TyCon "PredicateSlot")))))
(DFunDef false "constraintPredicateSlot" ((PVar "mctx") (PVar "tvs") (PRec "Constraint" ((rf "constraintHead" (PVar "h")) (rf "constraintArgs" (PVar "cargs")) (rf "constraintOrigin" (PVar "o"))) false)) (EApp (EApp (EVar "knownPredicateSlot") (ERecordCreate "IfaceRef" ((fa "irName" (EVar "h")) (fa "irOrigin" (EVar "o"))))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "fromAstType") (EVar "mctx")) (EVar "tvs"))) (EVar "cargs"))))
(DTypeSig false "knownPredicateSlot" (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "PredicateSlot"))))
(DFunDef false "knownPredicateSlot" ((PVar "iface") (PVar "args")) (ERecordCreate "PredicateSlot" ((fa "psIface" (EVar "iface")) (fa "psArgs" (EApp (EVar "PSArgsKnown") (EVar "args"))) (fa "psBoundIds" (EApp (EVar "dedupI") (EApp (EApp (EDictApp "flatMap") (EVar "monoTyvarIds")) (EVar "args")))))))
(DTypeSig false "reportImplHeadResidual" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))) (TyCon "Unit")))))))
(DFunDef false "reportImplHeadResidual" ((PVar "mctx") (PVar "subject") (PVar "roots") (PVar "loc") (PTuple (PVar "iface") (PVar "args"))) (EBlock (DoLet false false (PVar "ids") (EApp (EApp (EDictApp "flatMap") (EVar "monoUnboundIds")) (EVar "args"))) (DoLet false false (PVar "headIds") (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "roots"))) (DoLet false false (PVar "named") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (ETuple (EApp (EVar "snd") (EVar "p")) (EApp (EVar "fst") (EVar "p"))))) (EVar "roots"))) (DoLet false false (PVar "rendered") (EApp (EApp (EApp (EApp (EVar "ppEach") (EApp (EVar "Ref") (EVar "named"))) (EApp (EVar "Ref") (ELit (LInt 0)))) (ELit (LInt 3))) (EVar "args"))) (DoLet false false (PVar "pred") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "iface") "irName"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "join") (ELit (LString " "))) (EVar "rendered")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "ids")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "i")) (EApp (EApp (EVar "containsI") (EVar "i")) (EVar "headIds")))) (EVar "ids")))) (ELit LUnit) (EIf (EApp (EApp (EVar "allList") (ELam ((PVar "i")) (EApp (EApp (EVar "containsI") (EVar "i")) (EVar "headIds")))) (EVar "ids")) (EBlock (DoLet false false (PVar "msg") (EMatch (ETuple (EApp (EApp (EMethodRef "map") (EVar "normalize")) (EVar "args")) (EVar "rendered")) (arm (PTuple (PList (PCon "TVar" PWild)) (PList (PVar "vname"))) () (EApp (EApp (EApp (EVar "undeclaredImplPrerequisiteMsg") (EVar "subject")) (EFieldAccess (EVar "iface") "irName")) (EVar "vname"))) (arm PWild () (EApp (EApp (EVar "undeclaredImplPredicateMsg") (EVar "subject")) (EVar "pred"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-IMPL-MISSING-REQUIRES"))) (EVar "loc")) (EVar "msg")))) (EIf (EApp (EApp (EApp (EApp (EVar "answeredOnlyByBindingHead") (EVar "mctx")) (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (ELam ((PVar "r")) (EApp (EVar "intToString") (EApp (EVar "snd") (EVar "r"))))) (EVar "roots"))) (EVar "omEmpty"))) (EVar "iface")) (EVar "args")) (EBlock (DoLet false false (PVar "fixed") (EApp (EVar "dedup") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "r")) (EIf (EApp (EApp (EVar "containsI") (EApp (EVar "snd") (EVar "r"))) (EVar "ids")) (EListLit (EApp (EVar "fst") (EVar "r"))) (EListLit)))) (EVar "roots")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-IMPL-MISSING-REQUIRES"))) (EVar "loc")) (EApp (EApp (EApp (EVar "implGoalFixesHeadMsg") (EVar "subject")) (EVar "pred")) (EVar "fixed"))))) (EIf (EApp (EVar "isEmptyL") (EApp (EApp (EApp (EApp (EVar "goalCandidates") (EVar "mctx")) (EVar "omEmpty")) (EVar "args")) (EApp (EApp (EApp (EVar "goalRows") (EVar "mctx")) (EVar "iface")) (EVar "args")))) (EApp (EApp (EApp (EApp (EVar "reportUndeterminedNoImpl") (EVar "mctx")) (EVar "iface")) (EVar "args")) (EVar "loc")) (ELit LUnit))))))))
(DTypeSig false "checkSurvivorCallObligations" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "Loc")))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit"))))))))))
(DFunDef false "checkSurvivorCallObligations" ((PVar "mctx") PWild PWild PWild PWild PWild (PList) PWild) (ELit LUnit))
(DFunDef false "checkSurvivorCallObligations" ((PVar "mctx") (PVar "subject") (PVar "ownIface") (PVar "ownTyparams") (PVar "mty") (PVar "extraMap") (PCons (PTuple (PVar "oiface") (PVar "monos") PWild) (PVar "rest")) (PVar "loc")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkSurvivorDispatchMonos") (EVar "mctx")) (EVar "subject")) (EVar "ownIface")) (EVar "ownTyparams")) (EVar "mty")) (EVar "extraMap")) (EFieldAccess (EVar "oiface") "irName")) (EVar "monos")) (EVar "loc"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkSurvivorCallObligations") (EVar "mctx")) (EVar "subject")) (EVar "ownIface")) (EVar "ownTyparams")) (EVar "mty")) (EVar "extraMap")) (EVar "rest")) (EVar "loc")))))
(DTypeSig false "methodLevelConstraintMonos" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "Mono"))))))
(DFunDef false "methodLevelConstraintMonos" ((PVar "ifaceParams") (PVar "mty") (PVar "tvMap")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "name")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EVar "tvMap")) (arm (PCon "Some" (PVar "m")) () (EListLit (EVar "m"))) (arm (PCon "None") () (EListLit))))) (EApp (EApp (EVar "methodLevelConstraintVarNames") (EVar "ifaceParams")) (EVar "mty"))))
(DTypeSig false "methodConstraintSlotIds" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "methodConstraintSlotIds" ((PVar "typarams") (PCon "TyConstrained" (PVar "cs") (PVar "t")) (PVar "tvs")) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "constraintSlotId") (EVar "typarams")) (EVar "tvs"))) (EVar "cs")) (EApp (EApp (EApp (EVar "methodConstraintSlotIds") (EVar "typarams")) (EVar "t")) (EVar "tvs"))))
(DFunDef false "methodConstraintSlotIds" ((PVar "typarams") (PCon "TyEffect" PWild PWild (PVar "t")) (PVar "tvs")) (EApp (EApp (EApp (EVar "methodConstraintSlotIds") (EVar "typarams")) (EVar "t")) (EVar "tvs")))
(DFunDef false "methodConstraintSlotIds" (PWild PWild PWild) (EListLit))
(DTypeSig false "constraintSlotId" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "constraintSlotId" ((PVar "typarams") (PVar "tvs") (PVar "c")) (EMatch (EApp (EApp (EVar "constraintSlotDispatchVar") (EVar "typarams")) (EVar "c")) (arm (PList) () (EListLit)) (arm (PCons (PVar "n") PWild) () (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "tvs")) (arm (PCon "Some" (PVar "m")) () (EListLit (EApp (EVar "monoTyvarId") (EVar "m")))) (arm (PCon "None") () (EListLit))))))
(DTypeSig true "calleeNumObls" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "UObligation"))))))
(DFunDef false "calleeNumObls" ((PVar "mctx") (PVar "callN0") (PVar "dictN0")) (EBinOp "++" (EApp (EApp (EVar "numCallObls") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "callUOblsWindow") (EVar "mctx")) (EVar "callN0"))) (EApp (EApp (EVar "numDictObls") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "dictAppsSince") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "dictN0")))))
(DTypeSig true "numCallObls" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyApp (TyCon "List") (TyCon "UObligation")))))
(DFunDef false "numCallObls" ((PVar "gctx") (PList)) (EListLit))
(DFunDef false "numCallObls" ((PVar "gctx") (PCons (PVar "o") (PVar "rest"))) (EMatch (ETuple (EFieldAccess (EFieldAccess (EFieldAccess (EVar "o") "pred") "iface") "irName") (EApp (EApp (EVar "uOblArgs") (EVar "gctx")) (EVar "o"))) (arm (PTuple (PLit (LString "Num")) (PList (PVar "mono"))) () (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkMethodOccObl") (EApp (EApp (EVar "builtinIfaceRef") (EVar "gctx")) (EVar "BNum"))) (EListLit (ELit (LString "a")))) (EApp (EVar "TyVar") (ELit (LString "a")))) (EVar "mono")) (EListLit)) (EVar "PNumLit")) (EFieldAccess (EVar "o") "loc")) (EFieldAccess (EVar "o") "uoScope")) (EApp (EApp (EVar "numCallObls") (EVar "gctx")) (EVar "rest")))) (arm PWild () (EApp (EApp (EVar "numCallObls") (EVar "gctx")) (EVar "rest")))))
(DTypeSig false "numDictObls" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "PendingDictApp")) (TyApp (TyCon "List") (TyCon "UObligation")))))
(DFunDef false "numDictObls" ((PVar "gctx") (PList)) (EListLit))
(DFunDef false "numDictObls" ((PVar "gctx") (PCons (PVar "app") (PVar "rest"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "p")) (EIf (EBinOp "==" (EApp (EVar "fst") (EVar "p")) (ELit (LString "Num"))) (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkMethodOccObl") (EApp (EApp (EVar "builtinIfaceRef") (EVar "gctx")) (EVar "BNum"))) (EListLit (ELit (LString "a")))) (EApp (EVar "TyVar") (ELit (LString "a")))) (EApp (EVar "snd") (EVar "p"))) (EListLit)) (EVar "PNumLit")) (EFieldAccess (EVar "app") "pdaLoc")) (EFieldAccess (EVar "app") "pdaScope"))) (EListLit)))) (EApp (EApp (EVar "zip") (EApp (EApp (EMethodRef "map") (ELam ((PVar "i")) (EFieldAccess (EVar "i") "irName"))) (EFieldAccess (EVar "app") "pdaIfaces"))) (EFieldAccess (EVar "app") "pdaMonos"))) (EApp (EApp (EVar "numDictObls") (EVar "gctx")) (EVar "rest"))))
