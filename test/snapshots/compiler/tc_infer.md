# META
source_lines=3544
stages=DESUGAR,MARK
# SOURCE
-- tc_infer: the expression inference recursion (variables, application, lambda, let and rec-let,
-- match and arms, blocks, the shadow-application arms, the record arms, and the operator arms with
-- their typing rules (`inferBinop`, `inferUnop`)), signature pre-unification, exhaustiveness and
-- wide-literal checks at their sites, with their module-end steps beside them
-- (`checkDeferredMatches`, `checkFixedWidthLiterals`); the record arms' helpers are
-- `tc_infer_records`.
--
-- Spec: DICT section 4 (the elaboration judgment); HM-CORE section 3-section 5 (owed, #2555);
-- SHADOW section 1 (S2, S4-S7), section 1.1; S2-DECL (d); EFFECTS section 3.
--
-- Placement: declarations are placed by R1-R6 of the Phase 4 module table,
-- compiler/ARCHITECTURE-PLAYBOOK.md section 6.
-- Closure rule: this module may not import `types.typecheck`, nor any of `tc_elab`, `tc_global`,
-- `tc_module`.

import types.tc_types.{
  AdmittedVerdict(..),
  BindingRole(..),
  BuiltinClass(..),
  CDeclared(..),
  CDeclaredPrefix(..),
  ConstraintReg(..),
  DeclaringBinder(..),
  DoCtx(..),
  DynCtx(..),
  EnvBinding(..),
  GoalKind(..),
  JoinContext(..),
  NumBoundary(..),
  NumBoundaryDisposition(..),
  SiteKind(..),
  TcEnv(..),
  UObligation(..),
  ValueScheme(..),
  dynFor,
  GraphCtx,
  ModuleCtx,
  PendingEntry,
  RecordInfo,
  RecordSubst,
  ScopedMember,
}
import types.tc_mono.{
  authRoots,
  authRowRoots,
  containerParamScalarArg,
  containsI,
  domainIsTupleOfArity,
  effectRoots,
  effectRowRoots,
  expectedParamTypes,
  funArity,
  headTyconMono,
  headTyconNameMono,
  joinCellOf,
  litType,
  matchCol0Type,
  monoHasArrowInSlot,
  monoIsBool,
  monoScheme,
  peelArrows,
  peelQual,
  resultAfterArrows,
  schemeIds,
  schemeMono,
  tconBuiltin,
  tupleMono,
}
import types.tc_diag_text.{
  appSpineName,
  bangOnBoolHelp,
  bangOnBoolMsg,
  binderNonExhaustiveMsg,
  bindOutsideDoMsg,
  containerArgHint,
  containerArgMsg,
  discardedValueFix,
  discardedValueMsg,
  doBindArgHint,
  doBindArgMsg,
  i64RangeText,
  locKey,
  nonExhaustiveMatchWarning,
  notAFunctionHint,
  notAFunctionMsg,
  notAFunctionMsgFor,
  overAppliedMsg,
  renderCallArgs,
  tyOfMsg,
  u64RangeText,
  unboundVarMsg,
  unknownFieldMsg,
  unreachableArmWarning,
  wideAnnotateHelp,
  writtenDiag,
}
import types.tc_state.{
  callUOblsWindow,
  currentScopeStore,
  dynAtIfSome,
  emptyShadowDicts,
  envAt,
  envAtIfSome,
  mctxAt,
  wMark,
  wWindow,
}
import types.tc_env.{
  extendLocalVar,
  extendLocalVars,
  funClausePair,
  lookupMethodRow,
  lookupRecordByName,
  lookupStandaloneValue,
  lookupVar,
  seedAlphaLets,
}
import types.tc_diag.{pushTypeError, pushTypeErrorHelpFixAt, recordTypeError}
import types.tc_scope.{
  admittedIfaceWord, argDispatchOf, ieImplExistsForHead, methodEntryHere
}
import types.tc_unify.{
  applicationRowTyped,
  bindFrom,
  calleeArrow,
  captureScope,
  enterLevel,
  exitLevel,
  forceInstantiation,
  freshVar,
  instantiateMethodTracked,
  instantiateValueTracked,
  joinValueTypes,
  monoHasNonCovariantSlot,
  noteNumlitCtx,
  openRow,
  optionOrFresh,
  performEffect,
  poisonMismatchVars,
  postponePendingJoins,
  predicateSlotArgs,
  predicateSlotCSlots,
  recordFileValueFlow,
  refStored,
  settlePendingJoins,
  unify,
  unifyIn,
  unifyIntoOrd,
  unifyParamsExpected,
  unifySourceDomains,
  valueJoinOps,
  wantAuthority,
  zipBindFrom,
  closeScope,
}
import types.tc_decls.{
  astTypeFreshTbl,
  instantiateSigTracked,
  sigToSchemeTvs,
  sigToSchemeTvsIn,
  headAnnotTy,
}
import types.tc_solve.{
  goalsMark,
  improveLocalGoals,
  isLocalAbsName,
  openScope,
  pushLocalDictApp,
  routeLocalSym,
}
import types.tc_solve_check.{
  callOblsWindow,
  checkSigVarGoals,
  declaredPredicateSlots,
  dedupSlotVecs,
  finalizeNumBoundary,
  localNumGuard,
  memberTiedSurvivors,
  numConstrainedIds,
  predicateSlotView,
}
import types.tc_shadow.{
  definerReceiverDispatches,
  definerReceiverIsDictVar,
  definerShadowArgHead,
  definerShadowSpineArgAt,
  definerShadowSpineVarAt,
  definerShadowVarHead,
  enforceStandaloneDomainAt,
  groundAdmittedReceivers,
  groundShadowReceiver,
  importerAdmittedVerdict,
  importerShadowDomain,
  importerShadowDomainAt,
  methodCellOf,
  plainAppHeadVar,
  pushAmbiguousShadowDecl,
  recoveredShadowSym,
  shadowDomainForAt,
  shadowHeadEnv,
  shadowStandaloneHead,
  shadowStandaloneSpineHeadAt,
  stampMethodArities,
  stampRoutes,
  standaloneShadowDomainAt,
}
import types.tc_effects.{
  appSpineArgCount,
  beginEffectSummaryScope,
  borrowedEffectCells,
  collectProducedSummary,
  finishEffectSummaryScopeKeeping,
  flushPendingEscapes,
  freshEffectSummary,
  grantOnlyBindingId,
  localBindingSummary,
  notePerformSite,
  recordClauseFileBound,
  recordEffectBody,
  recordGrantOcc,
  recordStandaloneAt,
  recordValueFileBound,
  registerLocalAbsIf,
  registerLocalGroupAbs,
  spineHeadEv,
  argumentAuthority,
}
import types.tc_occurrence.{
  bindingDeclaredAt,
  freshEvId,
  inferDeclaredDictAt,
  inferDictAtFound,
  inferMethodAtCell,
  inferNumLit,
  inferWideLit,
  instantiateStandaloneOccurrence,
  instantiateVarTrackedId,
  instantiateVarTrackedWithSubst,
  isGrantOnlyEv,
  markNumlitOpTaint,
  maybeStandaloneValueMono,
  methodOmittedVars,
  pushSiteGoal,
  recordBinopGoals,
  recordIfaceObligation,
  recordMethodObligationGuarded,
  recordMethodObligationOwned,
  recordNegatedLitRange,
  recordSelectedStandaloneRoutes,
  recordUnopSite,
  siteHeadCell,
  siteRouteCell,
  standaloneOccurrence,
  standaloneSchemeFor,
}
import types.tc_groups.{
  checkAnnotTooGeneral,
  checkLetGroupBindsLocated,
  checkRecBindNonFunction,
  checkRecursiveValue,
  constraintVarArgMonos,
  constraintVarIfaceMonos,
  exprLoc,
  genBindingRestricted,
  generalizeGroup,
  isNonexpansive,
  letBindGeneralizes,
  letGroupComponents,
  registerSchemeObligations,
  residualsOf,
  sccProtectedSignatureIds,
  scopeRolesOf,
  sigConstraintArgTys,
  sigConstraints,
}
import types.tc_pat.{
  closeExistentialScope,
  inferPat,
  inferPats,
  openExistentialScope,
  patOpensExistentials,
  recordLetBindType,
  recordLocalBind,
  settlePatLits,
  takeOpenedExistentials,
  takePatLits,
}
import types.tc_infer_records.{
  assignedFieldNames,
  checkMissingFields,
  fieldAssignNamePair,
  fieldSelectionWellTyped,
  firstFieldName,
  inferFieldOfRecord,
  instantiateRecordShared,
  instantiateRecordUpdate,
  recordFieldMap,
  recordFieldNames,
  recordUpdateWellTyped,
  resolveFieldRecord,
  stampedRecordHead,
  substRecordField,
  unknownRecordFresh,
}
import frontend.ast.{
  Arm(..),
  BinderId(..),
  DoStmt(..),
  EvId(..),
  Expr(..),
  FieldAssign(..),
  Guard(..),
  LetBind(..),
  Lit(..),
  Loc(..),
  Pat(..),
  Route(..),
  TabKey(..),
  Ty(..),
  intMinLiteralHelp,
  intMinLiteralMsg,
  isI64Head,
  isU64Head,
  letBindName,
  orElseLoc,
  taggedFixedRange,
}
import types.effect_rows.{
  Atom(..), EffRow(..), collectRows, effrowLabels, joinRows, pureRow
}
import types.repr.{
  AuthResidual(..),
  Mono(..),
  Scheme(..),
  Tyvar(..),
  normalize,
  ppMono,
}
import types.effect_authority.{
  authDomainTop,
}
import types.effect_bindings.{
  BindingSummary(..), bodyArrows, bodyRowAt, newBindingSummary
}
import types.evidence_complete.{Inner(..)}
import types.scopes.{ScopeOwner(..)}
import support.ordmap.{
  omEmpty,
  omFromNames,
  omFromPairs,
  omHasKey,
  omInsert,
  omLookup,
  omSize,
  OrdMap,
}
import types.evidence.{ScopeId(..)}
import types.publish.{TcDiag(..)}
import map.{Map(..)}
import support.util.{
  allList,
  anyList,
  contains,
  isEmptyL,
  joinWith,
  listLen,
  zipL,
}
import types.effect_infer.{captureEffects}
import frontend.exhaust.{
  desugarPat,
  patHasRange,
  patUnreachable,
  renderWitness,
  useful,
  usefulWitness,
}
import frontend.desugar.{exprSpanLoc}
import types.module_interface.{forgetLocalRows}
import list.{head, last}
import types.effect_values.{joinProducedEnvelope}
import types.scopes as Scopes
import map as IdMap

-- Close a local binding scope over [members]: whether each generalizes, and
-- its type.  Joins recorded in the scope are decided first when a member
-- generalizes, since its type must not generalize over an undecided join;
-- otherwise they belong to the enclosing scope, where later uses of the
-- alternatives can still shape them.  Everything the close reads (roots,
-- quantifiable authorities) is taken after that.
finishValueEffectsKeeping : DynCtx ->
  List (Bool, Mono) ->
  List (Int, AuthResidual)
finishValueEffectsKeeping dyn generalizing =
  let members =
    map ((generalizes, mono) => (localRole generalizes, mono)) generalizing
  let level = dyn.dcModule.mcCells.currentLevel.value
  if anyList fst generalizing then
    settlePendingJoins dyn level
  else
    postponePendingJoins dyn.dcModule level
  let monos = map snd members
  finishEffectSummaryScopeKeeping
    dyn.dcModule
    (scopeRolesOf members)
    (fold (acc mono => effectRoots mono acc) Tip monos)
    (fold (acc mono => borrowedEffectCells dyn.dcModule mono acc) Tip monos)

-- ── expression inference ──────────────────────────────────────────────────
export
infer : TcEnv -> Expr -> Mono
infer env (ELit l) = litType l
-- PLAN.md #11: a source integer literal is `Num a` for a fresh `a`.  With the
-- prelude loaded (Num registered + `fromInt` in scope), model the literal exactly
-- as `fromInt n`.  inferMethodAt
-- "fromInt" records the Num impl obligation AND a pendingSite keyed on [dref] (the
-- node's route cell), so resolveSites later stamps [dref]: RKey when the literal's
-- type grounds to a concrete Num head, RDictFwd onto the enclosing `Num a` dict when
-- it stays polymorphic (the soundness case, `1` in `inc x = x + 1` — exactly the
-- route `fromInt 0` in `sum` gets).  Apply the `Int -> a` method type to an Int arg
-- (mirror OCaml's `unify from_int_ty (TFun t_int … a)`) to recover the result var
-- [a], and stash (a, fref, n, dref) in numlitRefs so the post-HM setNumlitFloats can
-- decide concrete-Float / concrete-Int / still-poly.  Recording the obligation here
-- AND (when under `+`) in numArithOp is harmless: both unify the same var, both
-- demand `Num`.  Without the prelude (bare-HM oracle, `builtinClassPresent BNum` False)
-- `fromInt` is unbound: fall back to a plain fresh var, dref stays RNone (⇒ Int).
infer env (ENumLit n ev _) = inferNumLit env n ev
infer env (EWideLit hi lo ev lx) = inferWideLit env hi lo ev lx
infer env (EVar x) = inferVar env x
-- #837: EVarId carries the resolve-minted binding id; thread it to
-- instantiateVarTrackedId so obligation lookup keys by (name, id).
infer env (EVarId x id) = inferVarId env x id
infer env (EApp f x) = inferAppExpr env f x
infer env (ELam pats body) = inferLam env pats body
infer env (ELet _ isFun pat e1 e2) = inferLet env isFun pat e1 e2
infer env (ELetGroup binds body) = inferLetGroup env binds body
infer env (EIf c t e) = inferIf env c t e
infer env (EMatch scrut arms) = inferMatch env (infer env scrut) arms
infer env (ETuple es) = tupleMono (inferEach env es)
infer env (EListLit es) = inferListLit env es
infer env (EAnnot e ty) = inferAnnot env e ty
infer env (EBinOp op l r ev) =
  inferBinopE env op l r (siteRouteCell env.teDyn.dcModule.mcGraph ev)
-- An operator or a field access the parser leaves unwrapped names its own span
-- (its operand's: the operator and the field name carry none).
infer env (EUnOp op e ev) =
  inferUnopE
    (envAtIfSome (exprSpanLoc e) env)
    op
    e
    (siteRouteCell env.teDyn.dcModule.mcGraph ev)
infer env (EInfix op l r) = inferInfix env op l r
infer env (ERecordCreate name fields) = inferRecordCreate env name fields
infer env (EFieldAccess e fname ev) =
  inferFieldAccess (envAtIfSome (exprSpanLoc e) env) e fname ev
infer env (ERecordUpdate base fields ev) = inferRecordUpdate env base fields ev
infer env (EVariantUpdate cname base fields) =
  inferVariantUpdate env cname base fields
infer env (EBlock stmts) = inferBlock env stmts
infer env (EMethodAt name _ ev) =
  inferMethodAtCell env name (methodCellOf env.teDyn.dcModule.mcGraph ev)
infer env (EDictAt name ev) = inferGrantedAt env name ev
infer env (EArrayLit es) = inferArrayLit env es
infer env (ERangeList lo hi _) = inferIntRange env lo hi (tconBuiltin "List")
infer env (ERangeArray lo hi _) = inferIntRange env lo hi (tconBuiltin "Array")
-- EIndex is desugared to an `index` method call before typecheck;
-- the built-in index-inference path is retired, so no `EIndex` arm here.  ESlice
-- is likewise desugared to a `slice` method call before typecheck (#670), so
-- no `ESlice` arm here -- a surviving one is a desugar-ordering bug and hits the
-- loud "unsupported expression" catch-all, and a non-container receiver becomes a
-- "no impl of Slice" constraint error via normal method dispatch.
infer env (EHeadAnnot e ty) = inferHeadAnnot env e ty
-- ELoc is transparent: the wrapped expression and every check inside it are
-- located at this span, until a nested construct names its own.
infer env (ELoc l e) = infer (envAt (Some l) env) e
-- A do-lowered chain.  Record the do-block loc so a monad-shape
-- mismatch during inference is retargeted to the tailored "do requires a monad"
-- error (see typeMismatch).  The chain's walk gets its own context; an inline
-- nested `do` block (`a <- (do ...)`) mints another, so its first report never
-- un-blames a LATER statement of the outer chain (#894 review finding 2).
infer env (EDoOrigin l e) =
  -- #824: the lowered chain's synthesized callee names the herald
  -- (`deferThen` for a `defer` block), so the "requires a monad" reframe can
  -- name the right interface.
  let doCtx = DoCtx {
    doLoc = l,
    doDeferred = doChainIsDeferred e,
    doReported = Ref False,
  }
  infer { env | teDyn = { env.teDyn | dcDo = Some doCtx } } e

infer env _ = panic "typecheck: unsupported expression"

-- is this lowered do-chain a `defer` block?  Its head callee is the tagged
-- `deferThen` (see `callAndThen` in desugar.mdk).
doChainIsDeferred : Expr -> Bool
doChainIsDeferred (EApp f _) = doChainIsDeferred f
doChainIsDeferred (ELoc _ e) = doChainIsDeferred e
doChainIsDeferred (EDoOrigin _ (EVar "deferThen")) = True
doChainIsDeferred (EDoOrigin _ (EVarId "deferThen" _)) = True
doChainIsDeferred _ = False

inferArrayLit : TcEnv -> List Expr -> Mono
inferArrayLit env es =
  let elem = joinValueTypes env.teDyn JoinArray (inferProduced env es)
  TApp (tconBuiltin "Array") elem

-- [lo..hi] : List Int, [|lo..hi|] : Array Int
inferIntRange : TcEnv -> Expr -> Expr -> Mono -> Mono
inferIntRange env lo hi container =
  unifyIn env.teDyn (infer env lo) (tconBuiltin "Int")
  unifyIn env.teDyn (infer env hi) (tconBuiltin "Int")
  TApp container (tconBuiltin "Int")

-- Forget what a previous inference of the same binder left, before any member of
-- its group is inferred (a group member's body records its siblings' uses): an
-- earlier inference in this drive, or a check of the module id in an earlier one.
forgetLocalAbs : GraphCtx -> String -> Unit
forgetLocalAbs gctx name =
  forgetLocalRows gctx.graphRun.localAbs gctx.graphRun.grants name

-- Enter a candidate local binder's own scope before its right-hand side is
-- inferred.
openLocalScope : ModuleCtx -> String -> ScopeId
openLocalScope mctx name =
  let parent = captureScope mctx ()
  let sid =
    Scopes.freshScope
      (currentScopeStore mctx.mcGraph ())
      (Some parent)
      mctx.mcCells.currentLevel.value
      (Scopes.scopeFrame (currentScopeStore mctx.mcGraph ()) parent).sfModuleId
      (LocalBindingOwner name)
  openScope mctx sid
  sid

-- The candidate local's scope, opened when the binder is a candidate.
openLocalScopeIf : ModuleCtx -> String -> Option ScopeId
openLocalScopeIf mctx name
  | isLocalAbsName name =
    forgetLocalAbs mctx.mcGraph name
    Some (openLocalScope mctx name)
  | otherwise = None

closeLocalScope : ModuleCtx -> Option ScopeId -> Unit
closeLocalScope mctx (Some _) = closeScope mctx ()
closeLocalScope mctx None = ()

-- An occurrence of a candidate local.  Once its binder has generalized with
-- predicates the occurrence instantiates them; before that (a recursive use) it is
-- recorded for `registerLocalAbs`.
inferLocalDictAt : TcEnv -> String -> EvId -> Mono
inferLocalDictAt env name ev =
  match (omLookup
    name
    env.teDyn.dcModule.mcGraph.graphRun.localAbs.lasBinders.value)
    Some (Some la) => match lookupVar env name
      Some s =>
        let inst = instantiateVarTrackedWithSubst env name 0 s
        pushLocalDictApp
          env.teDyn.dcModule
          name
          ev
          la
          inst.mtiSubstitution.misTypeSubst
          (captureScope env.teDyn.dcModule ())
        inst.mtiBody
      None => unboundVarFresh env.teDyn.dcModule name
    Some None => inferVarId env name 0
    None =>
      recordLocalRecOcc env.teDyn.dcModule name ev
      inferVarId env name 0

recordLocalRecOcc : ModuleCtx -> String -> EvId -> Unit
recordLocalRecOcc mctx name ev =
  let st = mctx.mcGraph.graphRun.localAbs
  let occs =
    (ev, captureScope mctx ())
      :: optionOr [] (omLookup name st.lasRecOccs.value)
  st.lasRecOccs := omInsert name occs st.lasRecOccs.value

inferDictAt : TcEnv -> String -> EvId -> Mono
inferDictAt env name ev
  | isLocalAbsName name = inferLocalDictAt env name ev
  | otherwise = inferGlobalDictAt env name ev

inferGlobalDictAt : TcEnv -> String -> EvId -> Mono
inferGlobalDictAt env name ev = match lookupVar env name
  None => panic ("unbound constrained fn: " ++ name)
  Some scheme =>
    let inst = instantiateValueTracked env.teDyn.dcModule name scheme
    let occurrence = (inst.mtiBody, inst.mtiSubstitution.misTypeSubst)
    match bindingDeclaredAt env name inst
      Some dc => inferDeclaredDictAt env.teDyn.dcModule name ev dc occurrence
      None => inferDictAtFound env.teDyn.dcModule name ev occurrence

-- An `EDictAt` use: a dictionary application, a grant-only use, or both.  The
-- instantiation inference makes for it is recorded for its grants; a grant-only
-- use is inferred exactly as the stamped variable it stands for.
inferGrantedAt : TcEnv -> String -> EvId -> Mono
inferGrantedAt env name ev =
  let st = env.teDyn.dcModule.mcGraph.graphRun.grants
  st.gsLastInst := None
  let t =
    if isGrantOnlyEv env.teDyn.dcModule.mcGraph ev then
      inferVarId env name (grantOnlyBindingId env.teDyn.dcModule name)
    else
      inferDictAt env name ev
  match st.gsLastInst.value
    Some (scheme, subst) =>
      recordGrantOcc env.teDyn.dcModule name ev scheme subst
    None => ()
  t

-- bare sequential block: value of the last statement; earlier statements typed
-- for effect; let/assign extend the env
inferBlock : TcEnv -> List DoStmt -> Mono
inferBlock env [] = tconBuiltin "Unit"
inferBlock env [s] = inferLastStmt env s
inferBlock env (s :: rest) = inferBlock (inferStmt env s) rest

inferLastStmt : TcEnv -> DoStmt -> Mono
inferLastStmt env (DoExpr e) = infer env e
inferLastStmt env s =
  let _ = inferStmt env s
  tconBuiltin "Unit"

-- A statement's own checks are located at its expression; the statements after
-- it are the enclosing construct's again.
inferStmt : TcEnv -> DoStmt -> TcEnv
inferStmt outer s =
  envAt
    outer.teDyn.dcModule.mcLoc
    (inferStmtAt (envAtIfSome (stmtSpanLoc s) outer) s)

stmtSpanLoc : DoStmt -> Option Loc
stmtSpanLoc (DoExpr e) = exprSpanLoc e
stmtSpanLoc (DoLet _ _ _ e _) = exprSpanLoc e
stmtSpanLoc (DoAssign _ e) = exprSpanLoc e
stmtSpanLoc (DoBind _ e) = exprSpanLoc e
stmtSpanLoc _ = None

inferStmtAt : TcEnv -> DoStmt -> TcEnv
inferStmtAt env (DoExpr e) =
  let oblN0 = wMark env.teDyn.dcModule.mcCells.implObls
  let t = infer env e
  checkStmtNotDiscarded
    env.teDyn
    (wWindow env.teDyn.dcModule.mcCells.implObls oblN0)
    t
    e
  env
-- #866: the binder's own Loc is threaded to blockRecLet for the pin note.  A
-- FUNCTION-FORM block let (`let h a p q = …`) parses with rec=True and lands HERE, not
-- in blockLet — so a pin note built from `exprLoc` of the curried lambda (which carries
-- no ELoc wrapper) had no location and the diagnostic silently never fired for the most
-- ordinary spelling of a local helper.  The binder pattern always has a real Loc.
inferStmtAt env (DoLet _ True (PVar x xloc bid) e _) =
  blockRecLet env x (Some xloc) bid e
inferStmtAt env (DoLet _ _ pat e _) = blockLet env pat e
inferStmtAt env (DoAssign x e) = extendLocalVar env x (monoScheme (infer env e))
-- A `<-` bind (DoBind) reaching a bare block is a user error: `<-` is
-- monadic-`do`-only, and a monadic `do` lowers to EDo (desugared before
-- typecheck), so only a bare-block `<-` arrives here.  Emit a clean LOCATED
-- error (symmetric with doRequiresMonadMsg) instead of panicking; infer the RHS
-- for effect (surfacing its own errors + snapshotting its ELoc span for the
-- caret) and bind the pattern's vars into env so downstream statements don't
-- cascade spurious `Unbound variable` errors (mirrors inferRecPatField).
inferStmtAt env (DoBind pat e) =
  let t = infer env e
  pushTypeError env.teDyn.dcModule "T-BIND-OUTSIDE-DO" bindOutsideDoMsg
  let lits = takePatLits env.teDyn.dcModule ()
  let pr = inferPat env pat
  bindFrom env.teDyn (fst pr) t
  settlePatLits env.teDyn lits
  extendLocalVars env (snd pr)
inferStmtAt env _ = panic "typecheck: unsupported block statement"

-- A bare (non-final, non-`let`) block statement discards its value.  A free
-- result var (nothing downstream constrained it) is pinned to `Unit` via plain
-- `unify` — always succeeds, and is exactly what "this value goes unused"
-- means for an otherwise-unconstrained type.  A CONCRETE non-`Unit` type is a
-- real mismatch, but routing it through bare `unify` would render the generic
-- `Type mismatch: Int vs Unit` (ERROR-QUALITY.md dim 3/5: doesn't name the rule
-- or offer the fix), so it is reported here instead with its own code and a
-- one-token `fix` (`let _ = `) for the intentional-discard case.
checkStmtNotDiscarded : DynCtx -> List UObligation -> Mono -> Expr -> Unit
checkStmtNotDiscarded dyn stmtObls t e
  | isExemptInPlaceSetIndex t e = ()
  | otherwise = match normalize t
    TCon "Unit" _ => ()
    TVar cell => match !cell
      Unbound id _ =>
        -- A variable a pending `Num` obligation constrains is a number of a
        -- kind a later statement may still fix (`Float`), so the report says
        -- "a number"; pinning it to `Unit` instead fails as `No impl of Num for Unit`.
        if containsI id (numConstrainedIds stmtObls) then
          pushDiscardedValueDesc dyn.dcModule "a number" e
        else
          unifyIn dyn t (tconBuiltin "Unit")
      Link _ => panic "checkStmtNotDiscarded: normalize left a Link"
    nt => pushDiscardedValueError dyn.dcModule nt e

-- `a[i] := v` desugars to `setIndex a i v` (`rewriteAssignIndex`, desugar.mdk), and
-- `IndexMut.setIndex : c -> k -> v -> c` (core.mdk) returns the container BY
-- INTERFACE CONTRACT so a caller can chain — but every current impl (`Array`,
-- `Vector` in vector.mdk) mutates in place and returns the SAME value, so the
-- bare-statement idiom `arr[i] := v` (real code: sqlite/lib/dbwriter.mdk,
-- gzip/lib/{huffman,inflate}.mdk) never actually loses anything by discarding it.
--
-- NOT exempted by callee name alone: `setIndex` is not a reserved word and
-- method names are not globally unique (#1111 A-2.5) — a user's OWN unrelated
-- binding named `setIndex` (e.g. `setIndex : HashMap -> String -> Int -> Bool`,
-- an existed-already probe) would silently dodge the discard check too, which
-- is exactly the bug this check exists to catch. `isExemptInPlaceSetIndex`
-- therefore also requires the DISCARDED VALUE's own head type constructor to be
-- one of the two real in-place `IndexMut` impls (`Array`/`Vector`) — since
-- `setIndex : c -> k -> v -> c`, that head IS the receiver's head, so this reads
-- the receiver's type off the statement's own already-inferred `t` for free,
-- no separate route/interface lookup needed. A future persistent-container
-- `IndexMut` impl (`setIndex` returning a NEW value) would need EXCLUDING from
-- `exemptInPlaceIndexMutHeads`, not just narrowing further.
-- `setIndex` is an `IndexMut` interface method, so which node shape this walk
-- is handed depends on the driver: this file has two output selections of the one
-- graph driver, `driveGraphK` (`checkModulesDiagsChain`'s `None` arm, for `check`, vs
-- `elaborateModules` for `build`/`run`; see harden-typechecker skill).  Both run the dict pre-pass
-- `prePassDictArg` now (#2705), which rewrites the call to
-- `EMethodAt "setIndex" …` BEFORE this check runs; before that only the
-- elaborate driver marked, and a bare-`EVar` node reached here under `check` —
-- reproduced: `medaka check` on
-- sqlite/lib/dbwriter.mdk was clean while `medaka build` rejected the same
-- file, because `stmtCalleeName` didn't yet cover `EMethodAt`/`EDictAt`. So it
-- must cover the stamped forms alongside the bare ones, where `appSpineName`
-- (this file's other spine-name walk, used elsewhere) covers neither.
stmtCalleeName : Expr -> Option String
stmtCalleeName (ELoc _ e) = stmtCalleeName e
stmtCalleeName (EDoOrigin _ e) = stmtCalleeName e
stmtCalleeName (EAnnot e _) = stmtCalleeName e
stmtCalleeName (EApp f _) = stmtCalleeName f
stmtCalleeName (EVar n) = Some n
stmtCalleeName (EVarId n _) = Some n
stmtCalleeName (EVarAt n _) = Some n
stmtCalleeName (EMethodRef n) = Some n
stmtCalleeName (EMethodAt n _ _) = Some n
stmtCalleeName (EDictAt n _) = Some n
stmtCalleeName _ = None

exemptInPlaceIndexMutHeads : List String
exemptInPlaceIndexMutHeads = ["Array", "Vector"]

isExemptInPlaceSetIndex : Mono -> Expr -> Bool
isExemptInPlaceSetIndex t e = match headTyconNameMono t
  Some hd =>
    stmtCalleeName e == Some "setIndex"
      && contains hd exemptInPlaceIndexMutHeads
  None => False

pushDiscardedValueError : ModuleCtx -> Mono -> Expr -> Unit
pushDiscardedValueError mctx nt e =
  pushDiscardedValueDesc mctx "`\{ppMono nt}`" e

pushDiscardedValueDesc : ModuleCtx -> String -> Expr -> Unit
pushDiscardedValueDesc mctx desc e =
  pushTypeErrorHelpFixAt
    mctx
    "T-DISCARDED-VALUE"
    (exprSpanLoc e)
    (discardedValueMsg desc)
    "bind it with `let _ = ...` if dropping the value is intentional"
    (discardedValueFix (exprLoc e))

blockRecLet : TcEnv -> String -> Option Loc -> BinderId -> Expr -> TcEnv
blockRecLet env x xloc bid e =
  checkRecBindNonFunction env.teDyn.dcModule x e  -- #799
  enterLevel env.teDyn.dcModule ()
  let oblN0 = wMark env.teDyn.dcModule.mcCells.implObls
  let callN0 = wMark env.teDyn.dcModule.mcCells.obls
  let dictN0 = goalsMark env.teDyn.dcModule.mcGraph ()
  let lscope = openLocalScopeIf env.teDyn.dcModule x
  let (t1, residuals) = inferRecursiveValue env x e
  closeLocalScope env.teDyn.dcModule lscope
  exitLevel env.teDyn.dcModule ()
  let addedObls = wWindow env.teDyn.dcModule.mcCells.implObls oblN0
  improveLocalGoals env.teDyn addedObls callN0
  let _ = finalizeNumBoundary env.teDyn NumBoundary {
    nbDisposition =
      NumBoundaryOwnedMember
        (env.teDyn.dcModule.mcCells.currentLevel.value + 1),
    nbMembers = [t1],
    nbSurvivingIds = memberTiedSurvivors env.teDyn.dcModule t1 addedObls callN0,
    nbDefaultObls = addedObls,
    nbAmbiguityObls = addedObls,
    nbGuard = localNumGuard env.teDyn.dcModule addedObls callN0,
  }  -- PLAN.md #11 / RETPOS soundness
  recordLocalBind env.teDyn.dcModule x xloc bid t1  -- LSP hover (block rec-let bypasses inferPat)
  let sch =
    genBindingRestricted env.teDyn Tip (residualsOf 0 residuals) True pureRow t1  -- #866
  registerLocalScheme env.teDyn.dcModule x sch oblN0 callN0 dictN0
  registerLocalAbsIf env.teDyn.dcModule x lscope sch oblN0 callN0
  seedAlphaLets (extendLocalVar env x sch) x e  -- WS-2: α scope-seed

blockLet : TcEnv -> Pat -> Expr -> TcEnv
blockLet env (PVar x xloc bid) e =
  enterLevel env.teDyn.dcModule ()
  beginEffectSummaryScope env.teDyn.dcModule ()
  let oblN0 = wMark env.teDyn.dcModule.mcCells.implObls
  let callN0 = wMark env.teDyn.dcModule.mcCells.obls
  let dictN0 = goalsMark env.teDyn.dcModule.mcGraph ()
  let lscope = openLocalScopeIf env.teDyn.dcModule x
  let t = infer env e
  closeLocalScope env.teDyn.dcModule lscope
  let residuals =
    finishValueEffectsKeeping env.teDyn [(isNonexpansive env e, t)]
  exitLevel env.teDyn.dcModule ()
  let addedObls = wWindow env.teDyn.dcModule.mcCells.implObls oblN0
  improveLocalGoals env.teDyn addedObls callN0
  let _ = finalizeNumBoundary env.teDyn NumBoundary {
    nbDisposition =
      NumBoundaryOwnedMember
        (env.teDyn.dcModule.mcCells.currentLevel.value + 1),
    nbMembers = [t],
    nbSurvivingIds = memberTiedSurvivors env.teDyn.dcModule t addedObls callN0,
    nbDefaultObls = addedObls,
    nbAmbiguityObls = addedObls,
    nbGuard = localNumGuard env.teDyn.dcModule addedObls callN0,
  }  -- PLAN.md #11 / RETPOS soundness
  recordLocalBind env.teDyn.dcModule x (Some xloc) bid t  -- LSP hover (block let bypasses inferPat)
  let sch =
    genBindingRestricted
      env.teDyn
      Tip
      (residualsOf 0 residuals)
      (isNonexpansive env e)
      pureRow
      t  -- #866
  registerLocalScheme env.teDyn.dcModule x sch oblN0 callN0 dictN0
  registerLocalAbsIf env.teDyn.dcModule x lscope sch oblN0 callN0
  -- WS-2: α scope-seed — bindings are immutable, so the prefix is stable.
  seedAlphaLets (extendLocalVar env x sch) x e
blockLet env pat e =
  let t = infer env e
  let lits = takePatLits env.teDyn.dcModule ()
  let pr = inferPat env pat
  bindFrom env.teDyn (fst pr) t
  settlePatLits env.teDyn lits
  checkBinderPat env (fst pr) pat
  extendLocalVars env (snd pr)

inferRecordCreate : TcEnv -> String -> List FieldAssign -> Mono
inferRecordCreate env name fields =
  match lookupRecordByName env.teDyn.dcModule name
    None => unknownRecordFresh env.teDyn.dcModule name
    Some ri => inferRecordCreateWith env name ri fields

-- Record CREATE.  A construction supplies EVERY field, so a single `R { … }` with
-- N fields is itself O(N x N): each supplied field did a `lookupAssoc fn` over the N
-- declared field types.  Same fix as the access/update paths (issue #980): instantiate
-- the result + each supplied field via the O(log N) index, and check missing fields
-- against the declared NAME list.  `checkMissingFields` walks declared order (identical
-- to the old `snd ir` order, which is `map fst fields`), so the missing-field errors are
-- pushed in the same order; the per-supplied-field unify is byte-identical (same subst).
inferRecordCreateWith : TcEnv ->
  String ->
  RecordInfo ->
  List FieldAssign ->
  Mono
inferRecordCreateWith env rname ri fields =
  let sr = instantiateRecordShared env.teDyn.dcModule ri
  checkMissingFields
    env.teDyn.dcModule
    rname
    (recordFieldNames ri)
    (omFromPairs (map fieldAssignNamePair fields) omEmpty)
  unifyFieldAssignsIdx env rname ri (fst sr) fields
  snd sr

-- Index-based field-assignment unify for the record CREATE and UPDATE paths: instead of
-- instantiating all N declared fields and linearly `lookupAssoc`-ing each supplied
-- field, look the supplied field up in the record's O(log N) index and instantiate
-- ONLY it with the shared param substitution (issue #980).  Byte-identical: same field
-- Mono (same `subst`, same `substMono`), same error + order (per supplied field, in
-- supplied order), `infer env val` is still the only fresh-var allocator in each step.
unifyFieldAssignsIdx : TcEnv ->
  String ->
  RecordInfo ->
  RecordSubst ->
  List FieldAssign ->
  Unit
unifyFieldAssignsIdx env _ _ _ [] = ()
unifyFieldAssignsIdx env rname ri subst ((FieldAssign fn val) :: rest) =
  unifyFieldAssignIdx env rname ri subst fn val
  unifyFieldAssignsIdx env rname ri subst rest

unifyFieldAssignIdx : TcEnv ->
  String ->
  RecordInfo ->
  RecordSubst ->
  String ->
  Expr ->
  Unit
unifyFieldAssignIdx env rname ri subst fn val =
  match omLookup fn (recordFieldMap ri)
    None =>
      pushTypeError
        env.teDyn.dcModule
        "T-UNKNOWN-FIELD"
        (unknownFieldMsg fn rname)
    Some fm =>
      -- A supplied field flows into its slot at the value's span.
      let at = envAtIfSome (exprSpanLoc val) env
      let vt = infer at val
      argumentIntoOrd
        True
        at
        (Some val)
        (substRecordField env.teDyn.dcModule.mcGraph subst fm)
        vt

-- Receiver-directed field resolution.  Infer the
-- receiver FIRST, then pick the owning record by its head tycon when known; if
-- the receiver is still an unbound var and the field is owned by several
-- records, the access is ambiguous.  `value` keeps the Ref-projection special case (no
-- record in compiler/stdlib declares a `value` field, so this matches the
-- oracle's structural `(Ref a).value → a`).
inferFieldAccess : TcEnv -> Expr -> String -> EvId -> Mono
inferFieldAccess env e fname ev
  | fname == "value" = inferValueField env e
  | otherwise =
    let te = normalize (infer env e)
    match resolveFieldRecord env.teDyn.dcModule te fname
      None => freshVar env.teDyn.dcModule ()
      Some (rname, ri) =>
        siteHeadCell env.teDyn.dcModule.mcGraph ev := stampedRecordHead rname ri
        let ft = inferFieldOfRecord env.teDyn te rname ri fname
        -- #1468: the WELL-TYPEDNESS half, and it runs AFTER `inferFieldOfRecord`
        -- on purpose — that call is what unifies `te` with the record's result
        -- type, so only here does the receiver's head name the type whose
        -- constructor set has to be asked about.
        fieldSelectionWellTyped env.teDyn.dcModule te rname ri fname ft

-- `cell.value` projects a Ref's contents.  Unify the receiver with `Ref a`
-- (forcing it, like the reference's `(Ref a).value → a` special case) and return
-- `a` — done by unification, not a structural match, so it also works when the
-- receiver's type is still an unsolved tyvar at this point (the self-hosted
-- typecheck infers function params as fresh vars, not yet pinned to their sig).
inferValueField : TcEnv -> Expr -> Mono
inferValueField env e = refStored env.teDyn (infer env e)

unboundVarFresh : ModuleCtx -> String -> Mono
unboundVarFresh mctx name =
  pushTypeError mctx "T-UNBOUND" (unboundVarMsg name)
  freshVar mctx ()

inferRecordUpdate : TcEnv -> Expr -> List FieldAssign -> EvId -> Mono
inferRecordUpdate env base fields ev = match firstFieldName fields
  None => panic "empty record update"
  Some fn => inferRecordUpdateField env base fields fn ev

-- `Con { base | f = v, … }` — a named-field-variant update (e.g. desugar's
-- `DInterface { d | methods = … }`).  Resolve the variant's field layout by the
-- CONSTRUCTOR name (registered via registerNamedFieldVariants); both `base` and
-- the result have the variant's DATA type, only the provided fields are typed.
inferVariantUpdate : TcEnv -> String -> Expr -> List FieldAssign -> Mono
inferVariantUpdate env cname base fields =
  match lookupRecordByName env.teDyn.dcModule cname
    None => unknownRecordFresh env.teDyn.dcModule cname
    Some ri => inferRecordUpdateWith env cname base fields ri

-- receiver-directed, like inferFieldAccess: infer base first, then
-- pick the owning record by the base's head tycon, falling back to the first
-- update field's owners.
inferRecordUpdateField : TcEnv ->
  Expr ->
  List FieldAssign ->
  String ->
  EvId ->
  Mono
inferRecordUpdateField env base fields fn ev =
  let bt = normalize (infer env base)
  match resolveFieldRecord env.teDyn.dcModule bt fn
    None => freshVar env.teDyn.dcModule ()
    Some (rname, ri) =>
      -- stamp the RESOLVED receiver record onto the node (bug #38): both emitters
      -- read it to pick the record by name, instead of guessing from the first
      -- update label (which picks the wrong record — and so the wrong slot — when
      -- two records share a field name at different indices).
      siteHeadCell env.teDyn.dcModule.mcGraph ev := stampedRecordHead rname ri
      inferRecordUpdatePicked rname bt env fields ri

inferRecordUpdatePicked : String ->
  Mono ->
  TcEnv ->
  List FieldAssign ->
  RecordInfo ->
  Mono
inferRecordUpdatePicked rname bt env fields ri =
  let sr =
    instantiateRecordUpdate
      env.teDyn.dcModule
      rname
      ri
      (assignedFieldNames fields)
  unifyIn env.teDyn bt (snd sr)
  -- Before the field values are inferred, so the error sits on the receiver.
  match firstFieldName fields
    Some fn => recordUpdateWellTyped env.teDyn.dcModule bt rname ri fn
    None => ()
  unifyFieldAssignsIdx env rname ri (fst sr) fields
  snd sr

inferRecordUpdateWith : TcEnv ->
  String ->
  Expr ->
  List FieldAssign ->
  RecordInfo ->
  Mono
inferRecordUpdateWith env rname base fields ri =
  let sr =
    instantiateRecordUpdate
      env.teDyn.dcModule
      rname
      ri
      (assignedFieldNames fields)
  unifyIn env.teDyn (infer env base) (snd sr)
  unifyFieldAssignsIdx env rname ri (fst sr) fields
  snd sr

-- Operator predicates use language-fixed prelude interfaces, independent of
-- term-level method lookup. Their residuals can appear in inferred schemes.
inferBinopE : TcEnv -> String -> Expr -> Expr -> Ref Route -> Mono
inferBinopE env op l r dref =
  let lt = infer env l
  let rt = infer env r
  -- The binop node carries no `ELoc` (the parser wraps its operands), so its
  -- own checks name the whole `l <op> r` span (l's start .. r's end): the
  -- Num-obligation errors and the comparison/Eq/Ord `typeMismatch` binop
  -- errors squiggle the operator expression rather than a lone operand.
  let at = envAtIfSome (binopSpanLoc l r) env
  recordBinopGoals at.teDyn.dcModule op dref lt
  if op == "|>" then pipeOp at l r lt rt else inferBinop at.teDyn op lt rt

-- Synthesize the whole-binop span from its operand Exprs: file + start of the
-- left operand, end of the right operand.  Falls back to whichever single
-- operand loc is available (None only when neither operand is ELoc-wrapped).
binopSpanLoc : Expr -> Expr -> Option Loc
binopSpanLoc l r = match (exprLoc l, exprLoc r)
  (Some (Loc f sl sc _ _), Some (Loc _ _ _ el ec)) => Some (Loc f sl sc el ec)
  (Some ll, None) => Some ll
  (None, Some rr) => Some rr
  (None, None) => None

-- The EUnOp analogue of inferBinopE: infer the single operand, record its
-- pending unop site (for `-`), then dispatch to inferUnop for the actual
-- obligation/unification work (negateOp for `-`, Bool-unify for `!`).
inferUnopE : TcEnv -> String -> Expr -> Ref Route -> Mono
inferUnopE env op e dref =
  let t = infer env e
  recordUnopSite env.teDyn.dcModule op dref t
  if op == "-" then recordNegatedLitRange env.teDyn.dcModule t e
  inferUnop env.teDyn op t

inferBinop : DynCtx -> String -> Mono -> Mono -> Mono
inferBinop dyn "+" lt rt = numArithOp dyn lt rt
inferBinop dyn "-" lt rt = numArithOp dyn lt rt
inferBinop dyn "*" lt rt = numArithOp dyn lt rt
inferBinop dyn "/" lt rt = numArithOp dyn lt rt
inferBinop dyn "%" lt rt = numArithOp dyn lt rt
inferBinop dyn "++" lt rt = appendOp dyn lt rt
inferBinop dyn "==" lt rt = eqCompareOp dyn lt rt
inferBinop dyn "/=" lt rt = eqCompareOp dyn lt rt
inferBinop dyn "<" lt rt = ordCompareOp dyn lt rt
inferBinop dyn ">" lt rt = ordCompareOp dyn lt rt
inferBinop dyn "<=" lt rt = ordCompareOp dyn lt rt
inferBinop dyn ">=" lt rt = ordCompareOp dyn lt rt
inferBinop dyn "&&" lt rt = boolOp dyn lt rt
inferBinop dyn "||" lt rt = boolOp dyn lt rt
inferBinop dyn "::" lt rt = consOp dyn lt rt
inferBinop dyn ">>" lt rt = composeOp dyn lt rt False
inferBinop dyn "<<" lt rt = composeOp dyn lt rt True
inferBinop dyn op _ _ = panic ("typecheck: unsupported operator " ++ op)

-- `++` (append) carries a `Semigroup` obligation on its (unified)
-- operand type — a verbatim mirror of `eqCompareOp`/`recordIfaceObligation` for `==`,
-- and the reason `"x" ++ Box 1` is a located `No impl of Semigroup for Box`
-- reject at CHECK time rather than an eval-time `E-PANIC`.  Reuses the same
-- pendingImplObligations / checkImplObligations path: a synthetic Semigroup
-- obligation with a bare iface-param declared type (`TyVar "a"`, typaram ["a"]) so
-- dispatchMonosOf recovers exactly the operand mono.  `Monoid a requires Semigroup
-- a`, so a declared `Monoid a =>` constraint superclass-closes to satisfy it (this
-- is what keeps core.mdk's `foldMap f = fold (acc x => acc ++ f x) empty` typing).
-- A still-polymorphic operand defers to the caller, exactly like Num/Eq/Ord.
--
-- Gated on the PRELUDE's `Semigroup` being present, via `builtinClassPresent`: the
-- bare-HM no-prelude oracle (tc_probe / typecheck_main.mdk) has no `Semigroup` class, so
-- recording the obligation only when it exists keeps those drivers byte-identical while
-- `medaka check` rejects.
-- The result is a new value of the operands' value type; what it may reach
-- is the abstraction's business (`alphaOf`), never inherited from an operand.
appendOp : DynCtx -> Mono -> Mono -> Mono
appendOp dyn lt rt =
  let plain = peelQual lt
  unifyIn dyn plain rt
  recordIfaceObligation dyn.dcModule BSemigroup plain
  plain

-- G2: arithmetic `+ - * / %` carry a `Num` obligation on their (unified) operand
-- type — a `No impl of Num for <T>` reject.
-- `++` (append) is NOT Num — it carries a `Semigroup` obligation instead (appendOp
-- above).  We reuse the
-- existing pendingImplObligations / checkImplObligations path: a synthetic Num
-- obligation with a bare iface-param declared type (`TyVar "a"`, typaram ["a"]) so
-- dispatchMonosOf recovers exactly the operand mono.  When it grounds to a concrete
-- non-Num head (String/Bool) with no `impl Num`, the post-inference check rejects;
-- while still a polymorphic var (a `Num a =>` site) allConcreteHeads defers it to
-- the caller — exactly the oracle's behaviour.
--
-- Gated on the `Num` interface being REGISTERED (prelude loaded): the bare-HM,
-- no-prelude oracle (tc_probe / typecheck_main.mdk) imposes NO class constraint on
-- `+`, so `1 + 2 : Int` and `"a" - "b" : String` both type there.  Recording the
-- obligation only when Num exists keeps the no-prelude drivers byte-identical to
-- that oracle while the full check_main (prelude) path rejects, matching `medaka
-- check`.
numArithOp : DynCtx -> Mono -> Mono -> Mono
numArithOp dyn lt rt =
  -- Taint any literal operand BEFORE the unify grounds it — so a literal
  -- fed to an arithmetic op (`1 + "x"`, `x + 1`, `1 + x`) keeps `No impl of Num for
  -- T` (the `+` is the culprit) rather than being reframed as a bare mismatch.
  markNumlitOpTaint dyn.dcModule lt
  markNumlitOpTaint dyn.dcModule rt
  unifyIn dyn lt rt
  recordIfaceObligation dyn.dcModule BNum lt
  lt

-- A wide literal's magnitude (its halves) fits `I64`: below 2^63, or exactly 2^63
-- when it is negated.
wideFitsI64 : Int -> Int -> Bool -> Bool
wideFitsI64 hi lo negated =
  hi < 2147483648 || negated && hi == 2147483648 && lo == 0

-- A wide literal is a `U64` literal or an error: at any other ground type, and at a
-- type still polymorphic when the module ends (whose `fromInt` would receive a value
-- no `Int` can carry), it is `L-INT-OVERFLOW`, exactly as the lexer's cap refused it
-- before wide literals existed.  At `I64` it fits up to `2^63 - 1`, and negated
-- (`-9223372036854775808`, which the parser reads as `-` applied to the wide
-- literal) down to `-2^63`: the literal is `I64`'s bit pattern of the magnitude,
-- and the `-` is `I64`'s wrapping negation, so `-2^63` is `minBound`.  Negated,
-- it fits no other type.
export
checkWideLiterals : ModuleCtx ->
  List (Mono, String, Int, Int, Bool, Option Loc) ->
  Unit
checkWideLiterals mctx [] = ()
checkWideLiterals mctx ((m, lx, hi, lo, negated, loc) :: rest) =
  let at = orElseLoc loc mctx.mcLoc
  let shown = if negated then "-" ++ lx else lx
  let pow62 = hi == 1073741824 && lo == 0
  match normalize m
    -- A positive 2^62 is the one wide literal the lexer admits as an `Int` (for
    -- `-4611686018427387904`'s sake); at `Int` it gets the diagnostic that says so.
    TCon "Int" _ if pow62 && not negated =>
      recordTypeError
        mctx
        (TcDiag
          "L-INT-OVERFLOW"
          1
          at
          intMinLiteralMsg
          (Some intMinLiteralHelp)
          None)
    TCon tag _ if isU64Head tag =>
      if negated then
        recordTypeError
          mctx
          (TcDiag
            "L-INT-OVERFLOW"
            1
            at
            "integer literal \{shown} does not fit U64 (\{u64RangeText})"
            None
            None)
    TCon tag _ if isI64Head tag =>
      if not (wideFitsI64 hi lo negated) then
        recordTypeError
          mctx
          (TcDiag
            "L-INT-OVERFLOW"
            1
            at
            "integer literal \{shown} does not fit I64 (\{i64RangeText})"
            None
            None)
    TCon tag _ =>
      recordTypeError
        mctx
        (TcDiag
          "L-INT-OVERFLOW"
          1
          at
          "integer literal \{shown} does not fit \{tag}"
          (Some "only a `U64` or an `I64` holds a literal above 2^62")
          None)
    _ =>
      recordTypeError
        mctx
        (TcDiag
          "L-INT-OVERFLOW"
          1
          at
          "integer literal \{shown} fits only `U64` or `I64`, and its type here is undetermined"
          (Some (wideAnnotateHelp shown negated))
          None)
  checkWideLiterals mctx rest

-- INTEGER-TYPES-DESIGN §3.2 item 2: a literal whose type grounded to a fixed-width
-- head must lie in that head's range, or it is `L-INT-OVERFLOW` naming the type and
-- the range.  Runs once per module after inference, on every driver, so `check`,
-- `run` and `build` all refuse `(300 : U8)`.  `-2 : U8` is caught here too, as the
-- negative value `recordNegatedLitRange` records for it.  Each literal reports at its
-- own location (no message dedup: two `300`s are two errors).
export
checkFixedWidthLiterals : ModuleCtx -> List (Mono, Int, Option Loc) -> Unit
checkFixedWidthLiterals mctx [] = ()
checkFixedWidthLiterals mctx ((m, n, loc) :: rest) =
  match normalize m
    TCon tag _ => match taggedFixedRange tag
      Some (lo, hi) =>
        if n < lo || n > hi then
          recordTypeError
            mctx
            (TcDiag
              "L-INT-OVERFLOW"
              1
              (orElseLoc loc mctx.mcLoc)
              "integer literal \{n} does not fit \{tag} (\{lo}..\{hi})"
              None
              None)
      None =>
        if isU64Head tag && n < 0 then
          recordTypeError
            mctx
            (TcDiag
              "L-INT-OVERFLOW"
              1
              (orElseLoc loc mctx.mcLoc)
              "integer literal \{n} does not fit U64 (\{u64RangeText})"
              None
              None)
    _ => ()
  checkFixedWidthLiterals mctx rest

-- Stage-1 Eq dispatch (EQ-DISPATCH-DESIGN.md §2.1): `==`/`/=` carry an `Eq`
-- obligation on their (unified) operand type — a verbatim mirror of
-- `recordIfaceObligation` for `+`.  We reuse the existing pendingImplObligations /
-- checkImplObligations path: a synthetic Eq obligation with a bare iface-param
-- declared type (`TyVar "a"`, typaram ["a"]) so dispatchMonosOf recovers exactly
-- the operand mono.  When it grounds to a concrete non-Eq head (a function, an
-- un-derived ADT) with no `impl Eq`, the post-inference check rejects; while still
-- a polymorphic var (an `Eq a =>` site) allConcreteHeads defers it to the caller
-- — exactly the Num behaviour.  `<`/`>`/`<=`/`>=` carry the sibling `Ord`
-- obligation via `ordCompareOp` below.  `/=` shares this seam and lowers to
-- `not (eq …)` at the dict layer (binopMethodApp), so it does not double-report.
--
-- Gated on the PRELUDE's `Eq` being present (`builtinClassPresent BEq`, #1539): the
-- bare-HM no-prelude oracle (tc_probe / typecheck_main)
-- has no `Eq` class, so recording the obligation only when Eq exists keeps those
-- drivers byte-identical while full check_main (prelude) rejects.
eqCompareOp : DynCtx -> Mono -> Mono -> Mono
eqCompareOp dyn lt rt =
  unifyIn dyn lt rt
  recordIfaceObligation dyn.dcModule BEq lt
  tconBuiltin "Bool"

-- Stage-1 Ord dispatch (EQ-DISPATCH-DESIGN.md §"sibling Ord follow-up"): the four
-- ordering comparisons `<`/`>`/`<=`/`>=` carry an `Ord` obligation on their
-- (unified) operand type — a verbatim mirror of `eqCompareOp` for `==`.  Reuses the
-- same pendingImplObligations / checkImplObligations path.  `Ord` supersets `Eq`
-- (`interface Ord a requires Eq a`), so a declared `Ord a =>` constraint already
-- superclass-closes to satisfy BOTH the `<`→Ord and a sibling `==`→Eq obligation;
-- an `Eq a =>` declaration does NOT close upward, so a bare `<` under `Eq a =>` is
-- correctly rejected as needing `Ord a`.  When the operand grounds to a concrete
-- non-Ord head (a function, an un-derived ADT) with no `impl Ord`, the
-- post-inference check rejects; while still a polymorphic var it defers to the
-- caller — exactly the Eq/Num behaviour.  NO change to eval/emit: `<` still lowers
-- to `EMethodAt "lt"` at the dict layer, so runtime/emit dispatch is unchanged.
--
-- Gated on the PRELUDE's `Ord` being present (`builtinClassPresent BOrd`, #1539).
ordCompareOp : DynCtx -> Mono -> Mono -> Mono
ordCompareOp dyn lt rt =
  unifyIn dyn lt rt
  recordIfaceObligation dyn.dcModule BOrd lt
  tconBuiltin "Bool"

boolOp : DynCtx -> Mono -> Mono -> Mono
boolOp dyn lt rt =
  unifyIn dyn lt (tconBuiltin "Bool")
  unifyIn dyn rt (tconBuiltin "Bool")
  tconBuiltin "Bool"

consOp : DynCtx -> Mono -> Mono -> Mono
consOp dyn lt rt =
  let tailElem = freshVar dyn.dcModule ()
  noteNumlitCtx dyn.dcModule lt rt JoinCons  -- tag cons head-vs-list Num mismatch
  unifyIn dyn rt (TApp (tconBuiltin "List") tailElem)
  TApp
    (tconBuiltin "List")
    (joinValueTypes dyn JoinCons [
      (dyn.dcModule.mcLoc, lt),
      (dyn.dcModule.mcLoc, tailElem),
    ])

-- `x |> f` is `f x` spelled backwards, and the argument's syntax reaches the
-- abstraction the same way.
pipeOp : TcEnv -> Expr -> Expr -> Mono -> Mono -> Mono
pipeOp env l r lt rt =
  let res = freshVar env.teDyn.dcModule ()
  let eff = applicationRow env (EApp r l) rt lt res
  performEffect env.teDyn.dcModule env.teDyn.dcModule.mcCells.curEffect eff
  notePerformSite env eff
  res

-- g >> h : (a->b) -> (b->c) -> (a->c)  [flipped=False]
-- g << h : (a->b) -> (c->a) -> (c->b)  [flipped=True]
-- The composite takes g's own domain, qualifier included: nothing is applied
-- to g here, so there is no argument to abstract.  g's result then flows into
-- h as an ordinary argument.
composeOp : DynCtx -> Mono -> Mono -> Bool -> Mono
composeOp dyn gt ht False =
  let (a, first, b) = calleeArrow dyn gt
  let c = freshVar dyn.dcModule ()
  let second = applicationRowTyped dyn ht b c
  TFun a (joinRows (joinCellOf dyn.dcModule.mcGraph) first second) c
composeOp dyn gt ht True = composeOp dyn ht gt False

inferUnop : DynCtx -> String -> Mono -> Mono
inferUnop dyn "-" t = negateOp dyn.dcModule t
inferUnop dyn "!" t = derefOp dyn t
inferUnop dyn op _ = panic ("typecheck: unsupported unary op " ++ op)

-- #1739 half A: `!x` is Ref-DEREFERENCE, not boolean negation — `not` is the sole
-- boolean negation (it is already a prelude fn).  The unify is the same one
-- `inferValueField` does for `x.value`, and deliberately so: the two spellings must
-- infer identically, since desugar-free lowering sends both to `CFieldAccess _
-- "value"`.  Unification rather than a structural match, so it also works when the
-- receiver is still an unsolved tyvar (a param not yet pinned to its signature).
--
-- The `Bool` arm is the REQUIRED diagnostic (user, 2026-07-10).  `!aBool` is the OLD
-- boolean-not use, and left to unification it fails as a bare `Ref a vs Bool`
-- mismatch that says nothing about what changed — so the Bool shape is INTERCEPTED
-- here, before unify, and answered with a message naming `not`.
--
-- The "use `not x`" advice is in the message, not only in `help`.  ERROR-QUALITY
-- §4.5 puts actionable advice on a `help:` line, but `help` is a JSON-ONLY channel
-- here — the CLI renderer never prints it — so advice that lives only there is
-- invisible to the human this diagnostic exists for.  The did-you-mean precedent
-- does the same ("Unbound variable: greetng. Did you mean 'greeting'"), and this is
-- the wording the user specified for this bite (2026-07-10).  `help` still carries
-- the longer WHY for the structured consumers.
--
-- It returns `Bool` on that path rather than a fresh var: the operand was a Bool and
-- the author meant negation, so `Bool` is the type the surrounding expression was
-- written to expect (`if !flag then …`), and handing it back keeps ONE located error
-- instead of a cascade of downstream mismatches — the recovery shape the
-- literal-provenance arms use.
derefOp : DynCtx -> Mono -> Mono
derefOp dyn t =
  if monoIsBool (normalize t) then
    pushTypeErrorHelpFixAt
      dyn.dcModule
      "T-BANG-ON-BOOL"
      None
      bangOnBoolMsg
      bangOnBoolHelp
      None
    tconBuiltin "Bool"
  else
    refStored dyn t

-- Unary minus `-x` carries a `Num` obligation on its operand type —
-- a verbatim mirror of `numArithOp`/`recordIfaceObligation` for binary `+`/`-`/…,
-- and the reason `-"x"` is a located `No impl of Num for String` reject at
-- CHECK time rather than an eval-time `panic "unary minus on non-number"`.
-- markNumlitOpTaint keeps the same literal-provenance error framing as
-- the binary arithmetic operators (`-"x"` blames the operator, not a bare
-- literal-vs-String mismatch).
negateOp : ModuleCtx -> Mono -> Mono
negateOp mctx t =
  markNumlitOpTaint mctx t
  recordIfaceObligation mctx BNum t
  t

-- backtick infix `x `f` y` is just f applied to x then y
inferInfix : TcEnv -> String -> Expr -> Expr -> Mono
inferInfix env op l r =
  let ft = inferVar env op
  let lt = infer env l
  let rt = infer env r
  -- reconstruct the equivalent app spine so a hole-bearing extern fills from
  -- its FIRST arg (l) — mirror of the EApp path (v2 Stage 2b).
  let inner = EApp (EVar op) l
  inferApp env (EApp inner r) (inferApp env inner ft lt) rt

inferVar : TcEnv -> String -> Mono
inferVar env x = inferVarId env x 0

-- #837: the id-carrying entry point.  id 0 (every non-EVarId caller, e.g.
-- inferInfix) is the bare-name fallback — byte-identical to the pre-#837 path.
inferVarId : TcEnv -> String -> Int -> Mono
inferVarId env x id = match maybeStandaloneValueMono env x
  -- S4: bare value-position definer shadow → the standalone scheme.
  Some m => m
  None => inferVarPlainId env x id

inferVarPlainId : TcEnv -> String -> Int -> Mono
inferVarPlainId env x id = match lookupVar env x
  Some s => match lookupMethodRow env x
    Some _ =>
      let inst = instantiateVarTrackedWithSubst env x id s
      recordMethodObligationOwned env x s inst.mtiBody inst.mtiSubstitution None
    None =>
      let mono = instantiateVarTrackedId env x id s
      recordMethodObligationGuarded
        env
        x
        s
        mono
        (methodOmittedVars env.teDyn.dcModule x)
  None => unboundVarFresh env.teDyn.dcModule x

-- The span of an application's outermost argument (Bite 3): peel any ELoc
-- wrapper on the `EApp` head, then read the argument Expr's span (an unwrapped
-- argument included).  Non-EApp shapes (never passed as `appExpr`) return None.
export
appArgLoc : Expr -> Option Loc
appArgLoc (ELoc _ e) = appArgLoc e
appArgLoc (EApp _ x) = exprSpanLoc x
appArgLoc _ = None

-- The span of a check about the application [app] itself: its own span, head
-- through last argument, or the [enclosing] construct's when that construct
-- begins with the application (at its first column, or one before it: an
-- opening bracket), so it does not start on unrelated code.
appSpanLoc : Option Loc -> Expr -> Option Loc
appSpanLoc enclosing app = match exprSpanLoc app
  None => enclosing
  Some own => if beginsWithSpan enclosing own then enclosing else Some own

-- Does [outer] start where [inner] starts, or one column before it, and reach
-- at least as far?
beginsWithSpan : Option Loc -> Loc -> Bool
beginsWithSpan (Some (Loc _ sl sc el ec)) (Loc _ isl isc iel iec) =
  sl == isl
    && isc - sc >= 0
    && isc - sc <= 1
    && (el > iel || el == iel && ec >= iec)
beginsWithSpan None _ = False

-- The type/route classifier strips locations from the head. Its occurrence
-- obligations still belong to that head, including at a later dispatch argument.
appSpineHeadLoc : Expr -> Option Loc
appSpineHeadLoc (ELoc loc e) = orElseLoc (appSpineHeadLoc e) (Some loc)
appSpineHeadLoc (EApp f _) = appSpineHeadLoc f
appSpineHeadLoc e = exprLoc e

-- the argument an application node supplies.  Total only over nodes `appSpineNodes`
-- returned; anything else has no argument and yields itself, which cannot happen.
appNodeArg : Expr -> Expr
appNodeArg (ELoc _ e) = appNodeArg e
appNodeArg (EApp _ x) = x
appNodeArg e = e

-- infer a spine's already-applied arguments, left to right (source order), pairing
-- each with the node that supplies it so `inferApp` can still localize its own error
-- span.
inferSpineArgs : TcEnv -> List Expr -> List (Expr, Mono)
inferSpineArgs env [] = []
inferSpineArgs env (n :: rest) =
  let t = infer env (appNodeArg n)
  (n, t) :: inferSpineArgs env rest

-- fold `inferApp` over a spine's (node, argument-type) pairs, left to right.  One
-- pair is exactly the single `inferApp` call the bare-head paths make.
inferAppNodes : TcEnv -> Mono -> List (Expr, Mono) -> Mono
inferAppNodes env ft [] = ft
inferAppNodes env ft ((node, at) :: rest) =
  inferAppNodes env (inferApp env node ft at) rest

-- Apply [ft] to the spine's argument nodes in order and return the residual
-- result.  `[]` is the identity.  Each argument flows in through
-- `applicationRow` with its own syntax, so a standalone selected in place of a
-- method is proved exactly like any other callee.
unifySpineResult : TcEnv -> Expr -> Mono -> List (Expr, Mono) -> Mono
unifySpineResult env _ ft [] = ft
unifySpineResult env f ft ((node, at) :: rest) =
  let r = freshVar env.teDyn.dcModule ()
  let eff = applicationRow env (EApp f node) ft at r
  performEffect env.teDyn.dcModule env.teDyn.dcModule.mcCells.curEffect eff
  notePerformSite env eff
  unifySpineResult env f r rest

-- ── #2109: RESULT-FIRST inference against a known expected type ───────────
-- `paramVarianceGuard` (the D-2 variance gate) fires only when BOTH rows at a
-- non-covariant slot are closed, and abstains while either is still a
-- metavariable.  That is the whole lever here.  Inferring an application
-- ARGUMENT-FIRST (`Ref noop`: `noop`'s closed `<>` row is pinned into `Ref ?a`
-- before the result ever meets the declaration) presents two closed rows and
-- the safe write-side narrowing is rejected; inferring it RESULT-FIRST
-- (`Ref ?a` meets `Ref (String -> <Stdout> Unit)` while `?a` is fresh) lets
-- the declaration pin the slot, and the argument is then checked against the
-- DECLARED field type by the ordinary arrow-row rule, which accepts a purer
-- function where a more effectful one is allowed.
--
-- Why this is sound for ANY callee, not only a constructor: the guard still
-- fires exactly when the callee's result at the slot is CLOSED independently
-- of the expectation — `idr : Ref a -> Ref a` applied to an already-typed cell
-- (`alias = idr box`, the #1098 launder) unifies its result first, which pins
-- `a := String -> <Stdout> Unit`, and the argument `box : Ref (String -> <>
-- Unit)` then meets that as closed~closed and is rejected.  A callee
-- whose result slot is a metavariable cannot have aliased the cell at any
-- particular row (parametricity), so nothing but a fresh value ever reaches
-- the accepting order.  The value this admits therefore has no other alias
-- yet, which is the one condition under which narrowing at a write is safe.
--
-- Scope, deliberately narrow: the expected type must contain a non-covariant
-- slot at all (`monoHasNonCovariantSlot`), the expression must be a plain
-- application spine (no lambda-argument or shadow-head special case, which
-- keep `inferAppExpr`'s arms), and only then does the order change.  Every
-- other program is inferred in the plain order, so no diagnostic moves.
inferExpected : TcEnv -> Expr -> Mono -> Mono
inferExpected env (ELoc l e) expected =
  inferExpected (envAt (Some l) env) e expected
-- A lambda meeting a known arrow takes the arrow's domains as its parameters
-- before its body is inferred, so a signed `f = p => …` sees `String @κ` the
-- way a clause `f p = …` does.
inferExpected env (ELam pats body) expected = match normalize expected
  TFun _ _ _ =>
    inferLamChecked
      (envAtIfSome (exprLoc body) env)
      (Some (normalize expected))
      pats
      body
  _ => infer env (ELam pats body)
inferExpected env e expected =
  -- The order only matters when an ARROW ROW sits inside a type-constructor
  -- slot (that is the only thing the variance gate compares), so a purely
  -- structural pre-check (`monoHasArrowInSlot`) runs first; the polarity
  -- table (a list, scanned per lookup) is consulted only for the rare
  -- expected types that have such a slot.  Measured: the unconditional table
  -- walk per signed clause cost ~1% Ir on hello-world `check`.
  if monoHasArrowInSlot expected
    && monoHasNonCovariantSlot
      env.teDyn.dcModule
      expected then match appSpineExpr e
    (hd, args) =>
      if isEmptyL args || not (plainAppHead env hd) then
        infer env e
      else
        inferAppResultFirst env hd args expected
  else
    infer env e

-- the application spine of [e]: its head and its arguments in order, looking
-- through the location wrappers that sit between one application node and
-- the next.  A non-application returns itself with no arguments.
appSpineExpr : Expr -> (Expr, List Expr)
appSpineExpr e = appSpineExprGo e []

-- Outermost node first, so each argument is prepended as it is met and the list
-- is already in application order.
appSpineExprGo : Expr -> List Expr -> (Expr, List Expr)
appSpineExprGo (EApp f x) args = appSpineExprGo f (x :: args)
appSpineExprGo (ELoc _ (EApp f x)) args = appSpineExprGo (EApp f x) args
appSpineExprGo e args = (e, args)

-- a head `inferAppExpr` would take through its plain arm: an ordinary variable
-- that is neither a standalone shadow nor a definer shadow.  Anything else
-- keeps its dedicated arm and the argument-first order.
plainAppHead : TcEnv -> Expr -> Bool
plainAppHead env (ELoc _ inner) = plainAppHead env inner
plainAppHead env (hd@(EVar _)) = plainAppHeadVar env hd
plainAppHead env (hd@(EVarId _ _)) = plainAppHeadVar env hd
plainAppHead env (EDictAt _ _) = True
plainAppHead env _ = False

-- the arrows of [ft] peeled [n] deep, then the result unified with [expected]
-- BEFORE any argument is looked at; each argument is then inferred against
-- the (now pinned) domain and applied through the ordinary `inferApp`, so the
-- effect bookkeeping and every diagnostic of the plain path are unchanged.
-- A callee with fewer than [n] arrows skips the pre-unification (the arity
-- error surfaces from `inferApp`).
inferAppResultFirst : TcEnv -> Expr -> List Expr -> Mono -> Mono
inferAppResultFirst env hd args expected =
  let ft = infer env hd
  match resultAfterArrows (listLen args) ft
    Some res => unifyIn env.teDyn res expected
    None => ()
  inferAppArgsAgainst env hd ft args

inferAppArgsAgainst : TcEnv -> Expr -> Mono -> List Expr -> Mono
inferAppArgsAgainst env _ ft [] = ft
inferAppArgsAgainst env appSoFar ft (x :: rest) =
  let xt = match lamUnderLoc x
    Some (loc, pats, body) =>
      inferLamChecked
        (envAtIfSome loc env)
        (Some (funDomain env.teDyn.dcModule (normalize ft)))
        pats
        body
    None => inferExpected env x (funDomain env.teDyn.dcModule (normalize ft))
  let res = inferApp env (EApp appSoFar x) ft xt
  inferAppArgsAgainst env (EApp appSoFar x) res rest

inferAppExpr : TcEnv -> Expr -> Expr -> Mono
inferAppExpr env f x = match lamUnderLoc x
  Some (loc, pats, body) =>
    let ft = infer env f
    -- ft is `(lamType) -> result`; its FIRST domain is the lambda's expected
    -- type.  Peel that, then peel the lambda type itself for its per-param types.
    let lamExpected = funDomain env.teDyn.dcModule (normalize ft)
    let xt = inferLamChecked (envAtIfSome loc env) (Some lamExpected) pats body
    inferApp env (EApp f x) ft xt
  None => match shadowStandaloneSpineHeadAt env f
    -- #2154: the IMPORTER-side spine arm, mirroring #1815's definer spine arms — it
    -- must run BEFORE the bare-head shadowStandaloneHead/inferShadowApp arm below for
    -- the same reason: an importer shadow whose interface dispatches at index k > 0
    -- has its receiver at the OUTER spine node, not the inner node the bare-head arm
    -- would otherwise ask about.  Declines (None) at k == 0, so the bare-head arm
    -- stays byte-identical.
    Some (mname, arityRefs, tagRefs, hd, nodes) =>
      inferShadowAppAt env mname arityRefs tagRefs hd nodes f x
    None => match shadowStandaloneHead env f
      Some (mname, arityRefs, tagRefs) =>
        inferShadowApp env mname arityRefs tagRefs f x
      -- #1815: the SPINE arms come FIRST, and they are the same two definer-shadow arms
      -- one node further out.  A definer shadow whose interface dispatches on argument
      -- k > 0 (`mth : Int -> b -> Int`) reaches its dispatch argument at the OUTER node
      -- of `EApp (EApp mth n) x` — the inner node supplies argument 0, which is not the
      -- receiver at all.  Without these arms the inner node fired the index-0 arms, asked
      -- the dispatch question about argument 0, and imposed the standalone's whole
      -- declared type on the enclosing annotated function.  They decline at k == 0 (a
      -- bare head has no applied nodes), so the index-0 path below is byte-unchanged.
      None => match definerShadowSpineArgAt env.teDyn.dcModule f
        Some (dname, darityRef, dtagRef, dimplRef, dinnerRef, dhd, dnodes) =>
          inferDefinerShadowAppAt
            env
            dname
            darityRef
            dtagRef
            dimplRef
            dinnerRef
            dhd
            dnodes
            f
            x
        None => match definerShadowSpineVarAt env.teDyn.dcModule f
          Some (dname, dhd, dnodes) =>
            inferDefinerShadowVarAppAt env dname dhd dnodes f x
          None => match definerShadowArgHead env.teDyn.dcModule f
            Some (dname, darityRef, dtagRef, dimplRef, dinnerRef) =>
              inferDefinerShadowApp
                env
                dname
                darityRef
                dtagRef
                dimplRef
                dinnerRef
                f
                x
            None => match definerShadowVarHead env.teDyn.dcModule f
              Some dname => inferDefinerShadowVarApp env dname f x
              None =>
                let ft = infer env f
                let xt = infer env x
                -- Detect `f(1, 2)` on the PRISTINE ft (before inferApp unifies
                -- its domain with the tuple), then record the residual result so a
                -- downstream no-impl / mismatch can surface the tailored hint.
                let pend = tupleCallShapeHint f x ft
                let res = inferApp env (EApp f x) ft xt
                match pend
                  Some (help, fix) =>
                    env.teDyn.dcModule.mcCells.tupleCallCandidates :=
                      (res, help, fix)
                        :: env.teDyn.dcModule.mcCells.tupleCallCandidates.value
                  None => ()
                res

-- Bug C: type `toList m` for a no-impl receiver against the imported STANDALONE
-- scheme (giving the concrete result element type, e.g. `List (String, Int)`) and
-- stamp the route RLocal (when marked); if the receiver DOES have an impl (or its head
-- is not yet concrete) fall through to ordinary dispatch (typed against the method
-- scheme the env rebound the name to).
--
-- An UNGROUNDED receiver (a bare `Num` literal is the everyday case: `Num a => a`, not
-- `Int`) has no head to test, so without grounding it would skip the standalone arm and
-- type against the METHOD scheme the env rebound the name to:
--
--   -- lib/prov.mdk:  export isEmpty : Int -> Bool
--   import lib.prov.{isEmpty}
--   main = println (debug (isEmpty 0))     -- would read `Type mismatch: Int literal vs Int Int`
--
-- The prelude's `Foldable.isEmpty : t a -> Bool` is higher-kinded, so unifying `t a` with
-- the literal's tyvar solves `t := Int, a := Int` and the imported `isEmpty` is never
-- consulted.  So the receiver is grounded to the IMPORTED standalone's declared domain
-- BEFORE the S2 impl question, so typecheck and the post-inference route resolver ask it
-- about the SAME head (a decision derived twice, at two times, over a receiver that
-- changed in between).
--
-- An IMPORTER shadow keeps the per-receiver rule (Fork 1): grounding only decides WHICH
-- head the rule is applied to; a grounded head with a live impl still dispatches
-- (`isEmpty [1, 2]` -> `Foldable.isEmpty`, fixture i4).
inferShadowApp : TcEnv ->
  String ->
  List (Ref (Option Int)) ->
  List (Ref Route, Ref Inner) ->
  Expr ->
  Expr ->
  Mono
inferShadowApp env mname arityRefs tagRefs f x =
  -- the application's loc, so a domain mismatch localizes to the call site, not
  -- the argument.
  let dloc = appSpanLoc env.teDyn.dcModule.mcLoc (EApp f x)
  let tx = infer env x
  -- The dict-var carve-out (S5/Fork 2) applies to importer shadows too: a receiver that is
  -- the enclosing fn's `=>`-bound constraint var DISPATCHES through that dict, so it must
  -- NOT be ground to the standalone's domain (that would monomorphise the written signature).
  -- groundShadowReceiver is also inert on an already-grounded receiver, so i1/i3/i4 (all
  -- concrete receivers) are byte-identical.
  groundShadowReceiver
    env.teDyn
    (importerShadowDomain env mname)
    tx
    (definerReceiverIsDictVar env.teDyn mname tx)
    dloc
  -- #2188 / S2-DECL (d): the cardinality decision, asked BEFORE the single-winner impl
  -- question below.  Inert (`AdDefer`, and `groundAdmittedReceivers` a no-op) for every
  -- name with fewer than two admitted declarations — see `importerAdmittedVerdict`.
  groundAdmittedReceivers env mname [tx] dloc
  match (importerAdmittedVerdict
    env.teDyn.dcModule
    env.teDyn.dcModule.mcCells.bodyImplEnvRef.value
    mname
    [tx])
    AdReject ifs =>
      pushAmbiguousShadowDecl
        env.teDyn.dcModule
        mname
        ifs
        (orElseLoc (appSpineHeadLoc f) dloc)
      -- T-ERRORS-ACCUM: the diagnostic is the verdict; inference still has to produce a
      -- type for the occurrence, and the standalone is the only denotation this call has
      -- that no admitted declaration disputes the SHAPE of.
      inferShadowStandaloneArm env mname arityRefs tagRefs f x tx
    AdStandalone => inferShadowStandaloneArm env mname arityRefs tagRefs f x tx
    AdDefer => match headTyconMono tx
      -- The S2 impl question, off the GRAPH-GLOBAL substrate — see
      -- `ieImplExistsForHead`.  The answer must not depend on where in the module order
      -- the receiver's impl sits, so it never reads the cumulative topological prefix
      -- (`shadowKeyTableRef`).
      Some head =>
        if ieImplExistsForHead
          env.teDyn.dcModule
          env.teDyn.dcModule.mcCells.bodyImplEnvRef.value
          mname
          head then
          inferApp env (EApp f x) (inferShadowAppHead env f) tx
        else
          inferShadowStandaloneArm env mname arityRefs tagRefs f x tx
      None => inferApp env (EApp f x) (inferShadowAppHead env f) tx

-- The STANDALONE arm of `inferShadowApp`, factored out verbatim so S2-DECL (d)'s
-- `AdStandalone` and `AdReject` verdicts reach exactly the arm the impl-query miss
-- already reached — one arm, three callers, no second copy to drift.
inferShadowStandaloneArm : TcEnv ->
  String ->
  List (Ref (Option Int)) ->
  List (Ref Route, Ref Inner) ->
  Expr ->
  Expr ->
  Mono ->
  Mono
inferShadowStandaloneArm env mname arityRefs tagRefs f x tx =
  match lookupStandaloneValue env mname
    Some value =>
      let occurrence =
        instantiateStandaloneOccurrence
          env
          mname
          ""
          (orElseLoc (appSpineHeadLoc f) env.teDyn.dcModule.mcLoc)
          value
      recordStandaloneAt env.teDyn.dcModule mname f occurrence
      let smono = occurrence.svoInstance.mtiBody
      stampMethodArities arityRefs (funArity smono)
      let r = freshVar env.teDyn.dcModule ()
      -- At the call site, as `inferShadowApp`'s domain check.
      let eff =
        applicationRow
          (envAtIfSome (appSpanLoc env.teDyn.dcModule.mcLoc (EApp f x)) env)
          (EApp f x)
          smono
          tx
          r
      performEffect env.teDyn.dcModule env.teDyn.dcModule.mcCells.curEffect eff
      stampRoutes (map fst tagRefs)
      -- S-1 (Fork D — the importer half): an IMPORTED constrained standalone shadowing
      -- a method breaks identically to a local one (its def is dict-passed in its own
      -- module; this call must supply the dicts).  Compute them off the head type we
      -- just unified, and defer the ROUTE stamp to resolveRLocalSites — stampRoutes
      -- above ran mid-inference, when the receiver is not yet solved, so it could only
      -- write `RLocal sym []`.  forceLocal=True: this arm has already committed the
      -- site's TYPE to the standalone, so its route is not open to re-derivation.
      recordSelectedStandaloneRoutes
        env.teDyn.dcModule
        mname
        occurrence.svoDicts
        tagRefs
        tx
      r
    None => inferApp env (EApp f x) (inferShadowAppHead env f) tx

-- #411: infer an IMPORTER-shadow application's head with `dcShadowHeadCtx` set, so
-- maybeStandaloneValueMono's importer arm does not pin an APPLIED occurrence to the
-- standalone scheme (which would kill per-receiver dispatch — Fork 1 / i4).  The definer
-- path types its head this way (inferDefinerShadowApp); this is its peer for the importer
-- path.
inferShadowAppHead : TcEnv -> Expr -> Mono
inferShadowAppHead env f = infer (shadowHeadEnv env) f

-- #2154: the spine-generalized twin of inferShadowApp — the peer of
-- inferDefinerShadowAppAt for the IMPORTER path.  [hd] is the spine's ultimate head
-- ([f] itself at index 0, unreachable here since shadowStandaloneSpineHeadAt declines
-- at k == 0) and [nodes] the application nodes already applied to it; [pre] is those
-- nodes' inferred (node, mono) pairs in source order, exactly as inferDefinerShadowAppAt
-- computes them.  Performs the SAME S2 impl-exists-vs-standalone-scheme branch
-- inferShadowApp does, at the outer node, folding inferApp/unification over the whole
-- applied prefix via inferSpineArgs/inferAppNodes/unifySpineResult.
inferShadowAppAt : TcEnv ->
  String ->
  List (Ref (Option Int)) ->
  List (Ref Route, Ref Inner) ->
  Expr ->
  List Expr ->
  Expr ->
  Expr ->
  Mono
inferShadowAppAt env mname arityRefs tagRefs hd nodes f x =
  -- the application's loc, as in `inferShadowApp`.
  let dloc = appSpanLoc env.teDyn.dcModule.mcLoc (EApp f x)
  let pre = inferSpineArgs env nodes
  let k = listLen pre
  let tx = infer env x
  groundShadowReceiver
    env.teDyn
    (importerShadowDomainAt env mname k)
    tx
    (definerReceiverIsDictVar env.teDyn mname tx)
    dloc
  -- #2188 / S2-DECL (d): [ats] is every argument up to and including THIS node's, so at
  -- the OUTERMOST admitted dispatch index (`importerDispatchIdxOuter`, the index this arm
  -- is gated on) every admitted declaration's own receiver argument is in it — which is
  -- what makes (b)'s per-declaration pairs jointly evaluable here and nowhere else.
  let ats = map snd pre ++ [tx]
  groundAdmittedReceivers env mname ats dloc
  match (importerAdmittedVerdict
    env.teDyn.dcModule
    env.teDyn.dcModule.mcCells.bodyImplEnvRef.value
    mname
    ats)
    AdReject ifs =>
      pushAmbiguousShadowDecl
        env.teDyn.dcModule
        mname
        ifs
        (orElseLoc (appSpineHeadLoc f) dloc)
      inferShadowStandaloneArmAt env mname arityRefs tagRefs hd pre f x tx
    AdStandalone =>
      inferShadowStandaloneArmAt env mname arityRefs tagRefs hd pre f x tx
    AdDefer => match headTyconMono tx
      Some head =>
        if ieImplExistsForHead
          env.teDyn.dcModule
          env.teDyn.dcModule.mcCells.bodyImplEnvRef.value
          mname
          head then
          inferAppNodes
            env
            (inferShadowAppHead env hd)
            (pre ++ [(EApp f x, tx)])
        else
          inferShadowStandaloneArmAt env mname arityRefs tagRefs hd pre f x tx
      None =>
        inferAppNodes env (inferShadowAppHead env hd) (pre ++ [(EApp f x, tx)])

-- The STANDALONE arm of `inferShadowAppAt`, factored out verbatim — the peer of
-- `inferShadowStandaloneArm` at dispatch index k > 0, and reached from the same three
-- verdicts.
inferShadowStandaloneArmAt : TcEnv ->
  String ->
  List (Ref (Option Int)) ->
  List (Ref Route, Ref Inner) ->
  Expr ->
  List (Expr, Mono) ->
  Expr ->
  Expr ->
  Mono ->
  Mono
inferShadowStandaloneArmAt env mname arityRefs tagRefs hd pre f x tx =
  match lookupStandaloneValue env mname
    Some value =>
      let occurrence =
        instantiateStandaloneOccurrence
          env
          mname
          ""
          (orElseLoc (appSpineHeadLoc f) env.teDyn.dcModule.mcLoc)
          value
      recordStandaloneAt env.teDyn.dcModule mname hd occurrence
      let smono = occurrence.svoInstance.mtiBody
      stampMethodArities arityRefs (funArity smono)
      -- At the call site, as `inferShadowApp`'s domain check.
      let r =
        unifySpineResult
          (envAtIfSome (appSpanLoc env.teDyn.dcModule.mcLoc (EApp f x)) env)
          f
          smono
          (pre ++ [(x, tx)])
      stampRoutes (map fst tagRefs)
      recordSelectedStandaloneRoutes
        env.teDyn.dcModule
        mname
        occurrence.svoDicts
        tagRefs
        tx
      r
    None =>
      inferAppNodes env (inferShadowAppHead env hd) (pre ++ [(EApp f x, tx)])

-- Type `size (Box 3)` exactly as the ordinary path (against the standalone
-- scheme the env rebound `size` to, preserving program types), but record the
-- ACTUAL argument mono (`Box`) as this site's receiver so resolveRLocalSite routes
-- per-receiver: a receiver head WITH an impl of the shadowed interface dispatches to
-- the method (route left untouched → eval arg-tag / emit RKey), one WITHOUT an impl
-- stays the standalone (RLocal).  dcSuppressRLocalRecord stops recordRLocalSite from
-- ALSO pushing the standalone's declared domain (which would mis-route `Box`→`Int`).
inferDefinerShadowApp : TcEnv ->
  String ->
  Ref (Option Int) ->
  Ref Route ->
  Ref (List Route) ->
  Ref Inner ->
  Expr ->
  Expr ->
  Mono
inferDefinerShadowApp env name arityRef tagRef implRef innerRef f x =
  inferDefinerShadowAppAt env name arityRef tagRef implRef innerRef f [] f x

-- #1815: the marked twin at an arbitrary dispatch index — the peer of
-- inferDefinerShadowVarAppAt, and the two must still agree cell-for-cell (S7).  [hd] is
-- the spine's ultimate head ([f] itself at index 0) and [nodes] the application nodes
-- already applied to it.  BOTH decision layers move together here: the TYPE arm reads
-- the receiver at index k, and the ROUTE stamps (pendingRLocalSites / pendingArgStamps)
-- are pushed at THIS node with THAT receiver — "the route must follow the arm".
inferDefinerShadowAppAt : TcEnv ->
  String ->
  Ref (Option Int) ->
  Ref Route ->
  Ref (List Route) ->
  Ref Inner ->
  Expr ->
  List Expr ->
  Expr ->
  Expr ->
  Mono
inferDefinerShadowAppAt env name arityRef tagRef implRef innerRef hd nodes f x =
  -- #2809: the RECOVERED symbol, not the raw route seed — every use of [sym] below is
  -- a typing decision that presumes "the bare name no longer denotes the standalone"
  -- (see `recoveredShadowSym`).  The two `SKRLocal (routeLocalSym !tagRef)` stamps
  -- keep the raw seed: that is the route the emitter follows.
  let sym = recoveredShadowSym name tagRef
  -- The application's location, so a standalone-domain mismatch reports at
  -- the call site.
  let dloc = appSpanLoc env.teDyn.dcModule.mcLoc (EApp f x)
  -- #1815: the arguments the spine already applied, inferred in source order.
  let pre = inferSpineArgs env nodes
  let k = listLen pre
  -- S2/S6: infer the argument FIRST so the head scheme is chosen PER
  -- RECEIVER.  A receiver with a VISIBLE impl of the shadowed interface DISPATCHES: type
  -- the head against the METHOD scheme; else it is the STANDALONE.  The impl universe is
  -- graph-global (`bodyImplEnvRef` via `ieImplExistsForHead`); `SHADOW-SEMANTICS.md`
  -- retires "local U imported U prelude" as a synonym for it, and `shadowKeyTableRef`
  -- (the topological prefix) is narrower still.  The mangled emit path (sym /= "") must
  -- not always type against the standalone scheme (`Int -> Int`): a definer shadow whose
  -- impl is IMPORTED (`size (Box 3)`, d8) has to dispatch to that impl, not reject
  -- `Int vs Box`.
  let xt = infer env x
  -- Constrained-receiver arm: an ungrounded receiver that is a dict-bound
  -- constraint var dispatches through that dict — it must neither be typed against the
  -- standalone scheme nor stamped RLocal (which would send eval/emit to the standalone
  -- and, e.g., apply `sz n = n + 1` to a Bool).
  let isDictVar = definerReceiverIsDictVar env.teDyn name xt
  -- Ground an ungrounded receiver to the standalone's declared domain BEFORE the
  -- dispatch decision, so typecheck asks the impl question about the SAME head the
  -- post-inference route resolver will.  See groundShadowReceiver.
  groundShadowReceiver
    env.teDyn
    (shadowDomainForAt env name sym k)
    xt
    isDictVar
    dloc
  let dispatches = definerReceiverDispatches env.teDyn name xt
  -- A dispatching occurrence names the interface whose method it selects, as an
  -- ordinary method occurrence does (`inferMethodCandidateAt`); the standalone arm
  -- names none.
  if dispatches || isDictVar then match spineHeadEv hd
    Some ev =>
      let cell = methodCellOf env.teDyn.dcModule.mcGraph ev
      cell.ecIface := admittedIfaceWord env.teDyn.dcModule name
    None => ()
  -- The head is typed in `headEnv`: the two default pushes are suppressed, and, as an
  -- application head (marked EMethodAt on run/build), it keeps the method
  -- scheme for per-receiver dispatch rather than the value-position standalone pin.
  let headEnv = { env |
    teDyn = { env.teDyn |
      dcSuppressRLocalRecord = True,
      dcSuppressArgStamp = True,
      dcShadowHeadCtx = True,
    },
  }
  -- For the STANDALONE arm, type the head against the STANDALONE scheme.  On the
  -- un-mangled run/check path `infer env f` already resolves the bare name to the
  -- standalone (which shadows the method in scope).  On the EMIT path the bare name
  -- resolves to the interface METHOD scheme instead (the standalone was renamed to
  -- `<mid>__name`), whose result loses the concrete element type — e.g. Map's `toList`
  -- would type `List a` not `List (k, v)`, so a downstream `debug (toList m)` resolves
  -- the WRONG element dict and SIGSEGVs.  When we carry the mangled symbol, instantiate
  -- its (standalone) scheme directly so the impl-body types exactly as the run path
  -- does. For the DISPATCH arm, type against the METHOD scheme so a live-impl
  -- receiver unifies and the result comes from the method.
  -- DISPATCH arm: the interface METHOD scheme, fetched EXPLICITLY from
  -- methodEntryHere (which spans imported interfaces) — NOT `infer env f`, because
  -- on the multi-module path the env rebinds the bare method name to the LOCAL
  -- standalone (`Int -> Int`), so inferMethodAt's lookupVar would hand back `Int -> Int`
  -- and reject a live-impl receiver (`Box`).  STANDALONE arm: the standalone scheme
  -- (mangled sym on the emit path preserves the concrete result type).
  let selected =
    if dispatches then
      None
    else
      standaloneOccurrence headEnv name sym (orElseLoc (appSpineHeadLoc f) dloc)
  let ft =
    if dispatches then
      shadowVarHeadMethodScheme headEnv name hd
    else match selected
      Some occurrence =>
        recordStandaloneAt env.teDyn.dcModule name hd occurrence
        occurrence.svoInstance.mtiBody
      None => infer headEnv hd
  arityRef := Some (funArity ft)
  -- S-1: on the STANDALONE arm ONLY, compute that standalone's own `=>`-constraint
  -- dicts (and record its call obligations).  The DISPATCH arm typed `ft` against the
  -- interface METHOD scheme, whose dicts are the method's, not the standalone's — asking
  -- there would be meaningless.  A dict-var receiver dispatches through its dict and is
  -- likewise not the standalone.  ([], []) for an unconstrained standalone.
  let dicts =
    if dispatches || isDictVar then
      emptyShadowDicts
    else
      optionOr
        emptyShadowDicts
        (map (occurrence => occurrence.svoDicts) selected)
  -- Route by the ACTUAL argument type on BOTH the eval path (pendingRLocalSites,
  -- read by resolveRLocalSites) and the emit path (pendingArgStamps, read by
  -- resolveArgStamps — only recorded when this method arg-dispatches, i.e. on the
  -- build path).  xt grounds to the real receiver post-inference; the two default
  -- pushes (recordRLocalSite / recordArgStamp) that would carry the standalone's
  -- declared domain are suppressed above.
  -- ...EXCEPT for a dict-bound constraint-var receiver: resolveRLocalSite's ungrounded
  -- arm stamps RLocal unconditionally, which would route a genuine dict dispatch to the
  -- shadowing standalone.  Not recording the site leaves the route for ordinary dispatch
  -- (RNone → eval arg-tag / emit RKey via resolveArgStamps).
  -- The route follows the arm (`not dispatches` ⇒ forceLocal).  `ft` above has
  -- already committed this site's TYPE, so re-deriving its route from a receiver mono
  -- that may ground LATER (Num defaulting on an unsignatured standalone) is exactly how
  -- `check` and the binary came to disagree.  A dispatching receiver still re-derives
  -- (its head is already ground; RKey comes from resolveArgStamps on the emit path).
  if isDictVar then
    ()
  else
    pushSiteGoal
      env.teDyn.dcModule.mcGraph
      GKRLocalSite
      innerRef
      (PendingEntry
        name
        tagRef
        xt
        env.teDyn.dcModule.mcCells.currentFn.value
        (SKRLocal
          (routeLocalSym !tagRef)
          (not dispatches)
          dicts.sdMonos
          dicts.sdIfaces
          dicts.sdArgVecs)
        env.teDyn.dcModule.mcLoc
        (captureScope env.teDyn.dcModule ())
        (freshEvId env.teDyn.dcModule ()))
  match argDispatchOf env.teDyn.dcModule name
    -- #609: the SKArg full mono is the DISPATCH arm's method scheme (`ft`) — the
    -- only arm whose route this stamp decides.  On the STANDALONE arm `ft` is the
    -- standalone's own scheme, which is not an interface-method occurrence at all;
    -- pass the receiver mono `xt` so ifaceParamMonos fails its shape match and the
    -- selector falls back to the singleton goal.
    Some _ =>
      pushSiteGoal
        env.teDyn.dcModule.mcGraph
        GKArgStamp
        innerRef
        (PendingEntry
          name
          tagRef
          xt
          env.teDyn.dcModule.mcCells.currentFn.value
          (SKArg implRef (if dispatches then ft else xt) [])
          env.teDyn.dcModule.mcLoc
          (captureScope env.teDyn.dcModule ())
          (freshEvId env.teDyn.dcModule ()))
    None => ()
  -- On the UN-MANGLED path (sym == "") `ft` is the permissive METHOD scheme
  -- (`a -> Int`), so `inferApp ft xt` would accept ANY receiver.  When this
  -- occurrence resolves to the STANDALONE — a grounded receiver head with no visible
  -- impl of the shadowed interface, or an ungrounded receiver (S5) — impose the
  -- standalone's DECLARED domain on the argument, so a domain mismatch (`size "hi"`,
  -- or a wrapper generalized over the shadow receiver then called at a live-impl type)
  -- becomes a located reject instead of build-time garbage.  A grounded receiver WITH
  -- an impl still dispatches (no enforcement) — that arm is untouched.  On the mangled
  -- emit path (sym /= "") `ft` is already the selected standalone instance,
  -- which enforces the domain itself, so this stays inert there.
  -- The STANDALONE arm with a written signature mirrors its unmarked twin
  -- (`inferDefinerStandaloneVarAppAt`'s `Some smono` branch): ONE unification of the
  -- standalone's type against the applied spine, at the call site.  Running the
  -- domain enforcement AND `inferApp` here raises the same mismatch twice (once at
  -- the call site, once at the receiver), and every driver reports from this arm
  -- now. `ft` IS the standalone's retained occurrence on this arm, so nothing is
  -- lost by not re-deriving it from the signature.
  match (if dispatches || isDictVar then
    None
  else
    standaloneSchemeFor env name sym)
    Some _ => unifySpineResult (envAtIfSome dloc env) f ft (pre ++ [(x, xt)])
    None =>
      if sym == "" then enforceStandaloneDomainAt env name xt dloc k
      inferAppNodes env ft (pre ++ [(EApp f x, xt)])

-- S2 (THE INVERSION): type an un-marked (check-path) definer-shadow application against
-- the module's OWN standalone, unconditionally.  Peer of inferDefinerShadowApp (the marked
-- run/build path); the two must agree cell-for-cell or `check` and the binary diverge (S7),
-- which is the bug class this whole arc keeps producing.
--
-- The receiver's impl universe is not consulted (see definerReceiverDispatches).  The
-- sole dispatch arm is the Fork-2 carve-out: a dict-bound `=>` constraint var, which is
-- an explicit written request to resolve through the interface.  Everything else — grounded
-- live-impl head included — types against the LOCAL standalone scheme, so a domain mismatch
-- (`size (Box 3)` against `size : Int -> Int`) is a located reject at the call, not a silent
-- dispatch that erases the user's function.
inferDefinerShadowVarApp : TcEnv -> String -> Expr -> Expr -> Mono
inferDefinerShadowVarApp env name f x =
  inferDefinerShadowVarAppAt env name f [] f x

-- #1815: the same arm at an arbitrary dispatch index.  [hd] is the spine's ultimate head
-- (which is [f] itself at index 0) and [nodes] the application nodes already applied to
-- it, so `nodes ++ [this node]` is every argument up to and including the receiver.  The
-- head is typed ONCE, here, against the chosen scheme and `inferApp` is folded over the
-- whole prefix — deliberately NOT `infer env f`, which would walk back into the inner
-- node and re-ask the dispatch question about argument 0.
inferDefinerShadowVarAppAt : TcEnv ->
  String ->
  Expr ->
  List Expr ->
  Expr ->
  Expr ->
  Mono
inferDefinerShadowVarAppAt env name hd nodes f x =
  -- the application's location, as in `inferDefinerShadowAppAt`.
  let dloc = appSpanLoc env.teDyn.dcModule.mcLoc (EApp f x)
  let pre = inferSpineArgs env nodes
  let xt = infer env x
  let isDictVar = definerReceiverIsDictVar env.teDyn name xt
  -- Ground an ungrounded receiver to the standalone's declared domain BEFORE the
  -- dispatch decision (see groundShadowReceiver).  Still load-bearing under the inversion:
  -- it is what gives a bare `Num` literal receiver (`eq 1 2`) the standalone's domain
  -- rather than leaving it open for Num-defaulting to ground LATER, behind typecheck's back.
  -- #1815: the declared domain the receiver grounds to is the k-th one, not the first.
  groundShadowReceiver
    env.teDyn
    (standaloneShadowDomainAt env.teDyn.dcModule name (listLen pre))
    xt
    isDictVar
    dloc
  if isDictVar then
    inferAppNodes
      env
      (shadowVarHeadMethodScheme env name hd)
      (pre ++ [(EApp f x, xt)])
  else
    inferDefinerStandaloneVarAppAt env name hd pre f x xt dloc

-- Dispatch arm (d8): the interface METHOD scheme for [name], from
-- methodEntryHere (which spans imported interfaces) so per-receiver dispatch works
-- even when the multi-module env has rebound the bare name to the local standalone.
-- Falls back to `infer env f` (flagged as an app head so maybeStandaloneValueMono does
-- not pin it) when the method type is unavailable.
shadowVarHeadMethodScheme : TcEnv -> String -> Expr -> Mono
shadowVarHeadMethodScheme env name f =
  match methodEntryHere env.teDyn.dcModule name
    -- #822: this elaborates an interface METHOD type, so it must use the stored graded
    -- scope.  Unscoped (`sigToScheme ty`) a graded method's index came out as a plain
    -- tyvar here while its real scheme has a row there, and `unify` binds the two without
    -- complaint — a silent divergence between two elaborations of the SAME signature.
    -- Co-locating the scope with `ty` is what makes this a one-token fix instead of a
    -- second lookup that could disagree.
    Some (_, _, ty, scope) =>
      forceInstantiation
        env.teDyn.dcModule
        name
        (instantiateMethodTracked
          env.teDyn.dcModule
          (fst (sigToSchemeTvsIn env.teDyn.dcModule scope ty)))
    None => infer (shadowHeadEnv env) f

-- Standalone arm: type the application against the LOCAL standalone scheme so
-- the result is the standalone's (S2/S5); a domain mismatch (`size "hi"`) or a wrapper
-- generalized over the shadow receiver then called at a foreign type localizes to the
-- call [dloc].  No declared signature ⇒ fall back to the permissive method-scheme head
-- + enforceStandaloneDomain.
-- #1815: [pre] is the spine's already-applied (node, type) prefix — `[]` at dispatch
-- index 0, where every line below reduces to the single-argument form it had before.
inferDefinerStandaloneVarAppAt : TcEnv ->
  String ->
  Expr ->
  List (Expr, Mono) ->
  Expr ->
  Expr ->
  Mono ->
  Option Loc ->
  Mono
inferDefinerStandaloneVarAppAt env name hd pre f x xt dloc =
  match standaloneOccurrence env name "" (orElseLoc (appSpineHeadLoc f) dloc)
    Some occurrence =>
      recordStandaloneAt env.teDyn.dcModule name hd occurrence
      -- #1815: consume the WHOLE applied prefix, not just the receiver.  Unifying the
      -- standalone's declared type against `TFun xt … r` when the receiver is argument 1
      -- is what equated `Int -> Int -> Int` (the standalone) with `b -> r` (the annotated
      -- `wrap`'s second parameter) and monomorphised the user's written signature.
      unifySpineResult
        (envAtIfSome dloc env)
        f
        occurrence.svoInstance.mtiBody
        (pre ++ [(x, xt)])
    None =>
      let ft = infer (shadowHeadEnv env) hd
      enforceStandaloneDomainAt env name xt dloc (listLen pre)
      inferAppNodes env ft (pre ++ [(EApp f x, xt)])

-- peek through an ELoc wrapper to a lambda; returns its loc, params and body.
-- Non-lambda arguments (the common case) take the ordinary inference path.
lamUnderLoc : Expr -> Option (Option Loc, List Pat, Expr)
lamUnderLoc (ELam pats body) = Some (None, pats, body)
lamUnderLoc (ELoc l (ELam pats body)) = Some (Some l, pats, body)
lamUnderLoc _ = None

-- the function's first parameter type (the lambda's expected type), or a fresh
-- var when `ft` is not yet a concrete arrow (then nothing is pushed; the trailing
-- `unify ft (TFun xt …)` reconciles).
funDomain : ModuleCtx -> Mono -> Mono
funDomain mctx (TFun a _ _) = a
funDomain mctx _ = freshVar mctx ()

-- like inferLam, but checked against the arrow [expected] it flows into, when
-- one is known: each lambda param is unified with the corresponding expected
-- param type right after inferPat — so the body and the hover side-channel see
-- the expected type, not a bare fresh var — and the body flows into the
-- expected result (`checkedInto`).
inferLamChecked : TcEnv -> Option Mono -> List Pat -> Expr -> Mono
inferLamChecked env expected pats body =
  fst (inferBindingChecked True env expected pats body)

-- [judge] says the patterns are a lambda's own; a method clause's patterns are
-- one row of its method's clauses, which are judged together.
export
inferBindingChecked : Bool ->
  TcEnv ->
  Option Mono ->
  List Pat ->
  Expr ->
  (Mono, EffRow)
inferBindingChecked judge env expected pats body =
  let lits = takePatLits env.teDyn.dcModule ()
  let pr = inferPats env pats
  let arity = listLen pats
  match expected
    Some want =>
      unifyParamsExpected env.teDyn (fst pr) (expectedParamTypes want arity)
    None => ()
  let scope =
    openExistentialScope
      env.teDyn.dcModule
      (takeOpenedExistentials env.teDyn.dcModule ())
  settlePatLits env.teDyn lits
  if judge then checkBinderPats env (fst pr) pats
  match expected
    Some want => recordClauseFileBound env.teDyn.dcModule body arity want
    None => ()
  let (bodyTy, bodyEff) = captureEffects
    env.teDyn.dcModule.mcCells.curEffect
    (joinCellOf env.teDyn.dcModule.mcGraph)
    (_ =>
      let bodyEnv = extendLocalVars env (snd pr)
      let actual = infer bodyEnv body
      match expected
        Some want => match resultAfterArrows arity want
          Some result => checkedInto bodyEnv body result actual
          None => actual
        None => actual)
  closeExistentialScope env.teDyn.dcModule scope bodyTy (exprLoc body)
  let force = if isEmptyL pats then bodyEff else pureRow
  -- closure construction is pure; only the source body's final application runs it
  (bodyArrows (fst pr) bodyEff bodyTy, force)

-- #894: is `appExpr`'s own callee EXACTLY the synthesized `andThen` `lowerDo` builds
-- for a `do`-bind (`callAndThen`, `compiler/frontend/desugar.mdk`)?  A STRUCTURAL
-- check off the one node `inferApp` was called for, with no ambient/dynamic flag: a
-- callee-name + do-origin-context test would also light up on a user's own explicit
-- `andThen` call nested inside a do-bind's scrutinee (`x <- andThen b f`), which is
-- neither `lowerDo`'s callee nor wants the `let`-instead-of-`<-` advice.
-- `callAndThen` tags ONLY the callee it itself constructs, so no user-authored
-- `andThen` occurrence can carry this wrapper.
isDoLoweredAndThenCallee : Expr -> Bool
isDoLoweredAndThenCallee (EApp callee _) = isDoLoweredAndThenCalleeExpr callee
isDoLoweredAndThenCallee _ = False

isDoLoweredAndThenCalleeExpr : Expr -> Bool
isDoLoweredAndThenCalleeExpr (ELoc _ e) = isDoLoweredAndThenCalleeExpr e
isDoLoweredAndThenCalleeExpr (EDoOrigin _ (EVar "andThen")) = True
-- `defer` blocks (#824) lower through the same `callAndThen` with `deferThen`
-- as the bind method, so they get the same tailored reframing.
isDoLoweredAndThenCalleeExpr (EDoOrigin _ (EVar "deferThen")) = True
-- `resolve` rewrites every surviving `EVar` to `EVarId name id` (a stable
-- per-binding identity) — by the time `inferApp` runs, the callee `lowerDo`
-- tagged is `EVarId "andThen" _`, not the raw `EVar` it started as. Debugged
-- with `medaka check` + a one-off shape dump: the untagged-`EVar` arm above
-- never actually fires post-resolve; keep it anyway as the honest pre-resolve
-- shape (harmless — `EDoOrigin _ (EVar "andThen")` just never matches here).
isDoLoweredAndThenCalleeExpr (EDoOrigin _ (EVarId "andThen" _)) = True
isDoLoweredAndThenCalleeExpr (EDoOrigin _ (EVarId "deferThen" _)) = True
-- #2705: the mark pass runs on every driver before inference, and `andThen` /
-- `deferThen` are interface methods, so `lowerDo`'s callee reaches `inferApp` as
-- the marked occurrence shape; the wrapper is the same.
isDoLoweredAndThenCalleeExpr (EDoOrigin _ (EMethodAt "andThen" _ _)) = True
isDoLoweredAndThenCalleeExpr (EDoOrigin _ (EMethodAt "deferThen" _ _)) = True
isDoLoweredAndThenCalleeExpr (EDoOrigin _ (EDictAt "andThen" _)) = True
isDoLoweredAndThenCalleeExpr (EDoOrigin _ (EDictAt "deferThen" _)) = True
isDoLoweredAndThenCalleeExpr _ = False

-- the elements of a tuple-literal argument (through the transparent ELoc wrapper).
tupleArgElems : Expr -> Option (List Expr)
tupleArgElems (ELoc _ e) = tupleArgElems e
tupleArgElems (ETuple es) = Some es
tupleArgElems _ = None

-- source span covering the whole `name(args)` call: callee start → tuple end.
tupleCallSpanLoc : Expr -> Expr -> Option Loc
tupleCallSpanLoc f x = match (exprLoc f, exprLoc x)
  (Some (Loc file sl sc _ _), Some (Loc _ _ _ el ec)) =>
    Some (Loc file sl sc el ec)
  _ => None

-- build the (help, optional fix) for a detected tuple-call.  The help names the
-- rule (Medaka calls with spaces, `(…)` is a tuple) and gives the exact rewrite;
-- when every element renders, a machine-applicable `fix` rewrites `add(1, 2)` →
-- `add 1 2` verbatim.  ERROR-QUALITY: located (caller sets loc), names the issue,
-- actionable fix, carries a code (T-NO-IMPL / T-TYPE-MISMATCH at the surface site).
buildTupleCallHint : String ->
  List Expr ->
  Expr ->
  Expr ->
  (String, Option (Loc, String))
buildTupleCallHint name es f x = match renderCallArgs es
  Some parts =>
    let argsCsv = joinWith ", " parts
    let argsSpaced = joinWith " " parts
    let spread = "\{name} \{argsSpaced}"
    let help =
      "Medaka calls functions with spaces, not parentheses: `\{name}(\{argsCsv})` passes the single tuple `(\{argsCsv})`; did you mean `\{spread}`?"
    let fix = map (span => (span, spread)) (tupleCallSpanLoc f x)
    (help, fix)
  None =>
    let n = listLen es
    let help =
      "Medaka calls functions with spaces, not parentheses: `\{name}(...)` passes one \{intToString n}-tuple, not \{intToString n} arguments; separate them with spaces, as in `\{name} x y`"
    (help, None)

-- detect the tuple-call shape on the PRISTINE ft (before inferApp) and return the
-- (help, fix) to record against the residual result type, else None.  Fires only
-- when the argument is a tuple literal of arity N ≥ 2, the callee has curried arity
-- EXACTLY N (spreading the tuple would saturate it), and its first param is not
-- itself an N-tuple (the genuine tuple-arg case), and the callee is a named spine.
tupleCallShapeHint : Expr ->
  Expr ->
  Mono ->
  Option (String, Option (Loc, String))
tupleCallShapeHint f x ft = match tupleArgElems x
  None => None
  Some es =>
    let n = listLen es
    if n < 2 then
      None
    else if funArity ft /= n then
      None
    else if domainIsTupleOfArity ft n then
      None
    else
      map (name => buildTupleCallHint name es f x) (appSpineName f)

inferApp : TcEnv -> Expr -> Mono -> Mono -> Mono
inferApp env appExpr ft xt =
  let r = freshVar env.teDyn.dcModule ()
  -- If the callee normalizes to a concrete NON-arrow head (a known type
  -- constructor like `Int`/`List Int`, never a tyvar or an arrow), applying it
  -- is genuinely impossible.  Emit a context-aware `T-NOT-A-FUNCTION` instead of
  -- letting `unify ft (TFun …)` render a leaked `Int vs a -> b` mismatch, and
  -- poison the fresh result var so no secondary obligation cascade fires (reuses
  -- the poisoned-var set).  Fires ONLY on a ground non-arrow head: a real
  -- function (`TFun`) or an as-yet-unresolved var (`TVar`) is unaffected.
  match headTyconNameMono ft
    Some _ => inferAppNotFunction env.teDyn.dcModule appExpr ft r
    None => match containerParamScalarArg ft xt
      Some scalarTy =>
        -- Batch B #6: container-consuming HOF handed a scalar.  Reframe here
        -- (callee name + arg loc in scope) instead of letting the generic sink
        -- leak `a b vs String`.  Skip the unify (it would push the leaked
        -- mismatch as a SECOND diagnostic) and poison `r` to suppress cascade.
        --
        -- #894: the SAME shape also fires when this application is a `do`-lowered
        -- `andThen` call (`x <- b` / a bare statement line — `lowerDo`,
        -- `compiler/frontend/desugar.mdk`) whose bound value isn't monadic. That
        -- is not "pass a List or Array" — it is "use `let`, not `<-`". Detected
        -- by AST SHAPE off `appExpr`'s own callee (`isDoLoweredAndThenCallee`,
        -- `callAndThen` tags exactly its synthesized callee), NOT by name +
        -- the do-origin context: a name+ambient-state heuristic false-positives on a
        -- user's OWN explicit `andThen` call nested inside a do-bind's scrutinee
        -- (`x <- andThen b f`).  The shape check can't: the wrapper is only ever
        -- placed on the exact node `lowerDo` builds.
        let isDoBind = isDoLoweredAndThenCallee appExpr
        let msg =
          if isDoBind then
            doBindArgMsg scalarTy
          else
            containerArgMsg (appSpineName appExpr) scalarTy
        let hint =
          if isDoBind then doBindArgHint scalarTy else containerArgHint scalarTy
        pushTypeErrorHelpFixAt
          env.teDyn.dcModule
          "T-TYPE-MISMATCH"
          (orElseLoc (appArgLoc appExpr) env.teDyn.dcModule.mcLoc)
          msg
          hint
          None
        -- Poison the container tyvar + element vars (in ft) exactly as the generic
        -- unify sink would (`monoUnboundIds a ++ b`), so the dangling `Mappable f`
        -- obligation sees a poisoned var and suppresses its own cascade.
        poisonMismatchVars env.teDyn.dcModule ft xt
        poisonMismatchVars env.teDyn.dcModule r r
        r
      None =>
        -- Type-error span (Bite 3, fork 3 = ARGUMENT): a wrong-arg-type
        -- mismatch is located at the argument expression rather than the
        -- callee, so `len 5` (len : String -> Int) squiggles the `5`.
        let at = envAtIfSome (appArgLoc appExpr) env
        -- The argument flows INTO the callee's domain, so a closed~closed row
        -- pair there is checked directionally (`unifyInto`): a purer argument in
        -- an effect-allowing slot is accepted, the reverse is not.  A callee whose
        -- type is still a variable has no domain to direct against yet.
        let eff = applicationRow at appExpr ft xt r
        performEffect at.teDyn.dcModule at.teDyn.dcModule.mcCells.curEffect eff
        notePerformSite env eff
        r

-- The argument flows into the callee's domain.  A qualified domain also
-- receives the argument's abstraction as a lower bound of its authority: this
-- is the one route by which an argument determines an effect's parameter,
-- whatever the callee's name, position or implementation.
argumentInto : TcEnv -> Option Expr -> Mono -> Mono -> Unit
argumentInto env arg dom xt = argumentIntoOrd False env arg dom xt

-- [valueFirst] is only the operand order a plain type mismatch names the two
-- sides in: a call argument names the slot first, a supplied record field the
-- value first, as their `unify`s did.
argumentIntoOrd : Bool -> TcEnv -> Option Expr -> Mono -> Mono -> Unit
argumentIntoOrd valueFirst env arg dom xt =
  match arg
    Some e => recordValueFileBound env.teDyn.dcModule e dom
    None => ()
  match normalize dom
    TQual d q =>
      unifyIntoOrd env.teDyn valueFirst True d xt
      wantAuthority
        env.teDyn.dcModule
        (argumentAuthority env (authDomainTop q) arg xt)
        q
    _ => unifyIntoOrd env.teDyn valueFirst True dom xt

-- The same judgment for an expression that flows into a declared type rather
-- than a parameter: a signed body into its result, a lambda or method body into
-- the arrow it is checked against. A qualified declared type bounds the
-- expression's abstraction, and the expression then has the declared type, so
-- every use reads the declared qualifier. Any other declared type is left to
-- the caller's own directed check, and [actual] is returned unchanged.
checkedInto : TcEnv -> Expr -> Mono -> Mono -> Mono
checkedInto env e expected actual =
  recordValueFileBound env.teDyn.dcModule e expected
  match normalize expected
    TQual _ _ =>
      argumentInto (envAtIfSome (exprLoc e) env) (Some e) expected actual
      expected
    _ => actual

-- The argument node of an application, when the callee's syntax is an
-- application at all; every other node is not one and has no argument to
-- abstract (the catch-all is the projection's negative answer, not an
-- unhandled constructor).
appArgExpr : Expr -> Option Expr
appArgExpr (ELoc _ e) = appArgExpr e
appArgExpr (EApp _ x) = Some x
appArgExpr _ = None

-- All callable eliminations recover the selected arrow's row unchanged.
-- Inference introduces a new row only while the callee's shape is unknown.
-- The caller decides whether invocation happens now or in a composed closure.
applicationRow : TcEnv -> Expr -> Mono -> Mono -> Mono -> EffRow
applicationRow env appExpr ft xt result = match normalize ft
  TFun dom row res =>
    argumentInto env (appArgExpr appExpr) dom xt
    bindFrom env.teDyn result res
    row
  _ =>
    let unknown = openRow env.teDyn.dcModule ()
    unifyIn env.teDyn ft (TFun xt unknown result)
    unknown

-- The applied head is a ground non-function.  If the spine over-applies
-- a named function (callee name known AND at least one arg was consumed before
-- the type went non-arrow) use the arity-aware wording; otherwise fall back to
-- naming the non-function type.  Poison `r` to suppress downstream cascade.
inferAppNotFunction : ModuleCtx -> Expr -> Mono -> Mono -> Mono
inferAppNotFunction mctx appExpr ft r =
  let applied = appSpineArgCount appExpr
  let takes = applied - 1
  -- Reported at the application, not at a construct around it.
  let loc = appSpanLoc mctx.mcLoc appExpr
  match appSpineName appExpr
    Some name =>
      if takes >= 1 then
        pushTypeError
          (mctxAt loc mctx)
          "T-NOT-A-FUNCTION"
          (overAppliedMsg name takes applied)
      else
        pushTypeErrorHelpFixAt
          mctx
          "T-NOT-A-FUNCTION"
          loc
          (notAFunctionMsgFor (Some name) (ppMono (normalize ft)))
          (notAFunctionHint (Some name))
          None
    None =>
      pushTypeErrorHelpFixAt
        mctx
        "T-NOT-A-FUNCTION"
        loc
        (notAFunctionMsg (ppMono (normalize ft)))
        (notAFunctionHint None)
        None
  poisonMismatchVars mctx r r
  r

inferLam : TcEnv -> List Pat -> Expr -> Mono
inferLam env pats body =
  -- Patterns carry no source Loc, so a pattern-level type error (e.g. an
  -- over-applied nullary constructor `A _`) is located at THIS clause's body.
  inferLamChecked (envAtIfSome (exprLoc body) env) None pats body

inferLet : TcEnv -> Bool -> Pat -> Expr -> Expr -> Mono
inferLet env isFun pat e1 e2
  | isFun = match pat
    PVar x xloc bid => inferRecLet env x (Some xloc) bid e1 e2  -- #866: binder loc for the pin note
    _ => inferLetSimple env pat e1 e2
  | otherwise = inferLetSimple env pat e1 e2

-- Self-recursive inline `let` binding (mirrors blockRecLet + the oracle is_fun
-- arm): placeholder pre-bind, infer body, unify, generalize through the body.
inferRecLet : TcEnv -> String -> Option Loc -> BinderId -> Expr -> Expr -> Mono
inferRecLet outer x xloc bid e1 e2 =
  -- Located at the right-hand side, as `inferLetSimple`.
  let env = envAtIfSome (exprSpanLoc e1) outer
  checkRecBindNonFunction env.teDyn.dcModule x e1  -- #799
  enterLevel env.teDyn.dcModule ()
  let oblN0 = wMark env.teDyn.dcModule.mcCells.implObls
  let callN0 = wMark env.teDyn.dcModule.mcCells.obls
  let dictN0 = goalsMark env.teDyn.dcModule.mcGraph ()
  let lscope = openLocalScopeIf env.teDyn.dcModule x
  let (t1, residuals) = inferRecursiveValue env x e1
  closeLocalScope env.teDyn.dcModule lscope
  exitLevel env.teDyn.dcModule ()
  let addedObls = wWindow env.teDyn.dcModule.mcCells.implObls oblN0
  improveLocalGoals env.teDyn addedObls callN0
  let _ = finalizeNumBoundary env.teDyn NumBoundary {
    nbDisposition =
      NumBoundaryOwnedMember
        (env.teDyn.dcModule.mcCells.currentLevel.value + 1),
    nbMembers = [t1],
    nbSurvivingIds = memberTiedSurvivors env.teDyn.dcModule t1 addedObls callN0,
    nbDefaultObls = addedObls,
    nbAmbiguityObls = addedObls,
    nbGuard = localNumGuard env.teDyn.dcModule addedObls callN0,
  }  -- PLAN.md #11 / RETPOS soundness
  recordLocalBind env.teDyn.dcModule x xloc bid t1  -- LSP hover (recursive PVar let bypasses inferPat)
  let sch =
    genBindingRestricted env.teDyn Tip (residualsOf 0 residuals) True pureRow t1  -- #866
  registerLocalScheme env.teDyn.dcModule x sch oblN0 callN0 dictN0
  registerLocalAbsIf env.teDyn.dcModule x lscope sch oblN0 callN0
  infer
    (envAt
      outer.teDyn.dcModule.mcLoc
      (seedAlphaLets (extendLocalVar env x sch) x e1))
    e2  -- WS-2: α scope-seed

-- Recursive local bindings are strict. Their initializer is charged here;
-- recursive occurrences read only the value, never a lazy forcing descriptor.
-- A recursive local is a function, so it generalizes, and its scope keeps
-- residuals over its own quantified authorities.
inferRecursiveValue : TcEnv ->
  String ->
  Expr ->
  (Mono, List (Int, AuthResidual))
inferRecursiveValue env name expr =
  beginEffectSummaryScope env.teDyn.dcModule ()
  let arity = sourceBindingArity expr
  let owned =
    newBindingSummary
      arity
      (freshVar env.teDyn.dcModule)
      (freshEffectSummary env.teDyn.dcModule)
  let envSelf = extendLocalVar env name (monoScheme owned.bsRecursiveValue)
  let (actual, immediate) = captureEffects
    env.teDyn.dcModule.mcCells.curEffect
    (joinCellOf env.teDyn.dcModule.mcGraph)
    (_ => infer envSelf expr)
  unifySourceDomains env.teDyn arity owned.bsValue actual
  publishProducedResults env.teDyn owned [(exprLoc expr, actual)]
  recordEffectBody env.teDyn.dcModule owned.bsBody (if arity == 0 then
    immediate
  else
    bodyRowAt arity actual)
  checkRecursiveValue env.teDyn owned
  let residuals = finishValueEffectsKeeping env.teDyn [(True, owned.bsValue)]
  performEffect
    env.teDyn.dcModule
    env.teDyn.dcModule.mcCells.curEffect
    immediate
  (owned.bsValue, residuals)

-- Source arity is the count of syntactic lambda parameters under the transparent
-- wrappers; every other expression is a computation that yields its value when
-- forced, so it has arity 0 even when that value turns out to be a function
-- (a conditional between two lambdas is a thunk producing a closure). The
-- catch-all is that rule, not a set of unhandled constructors.
sourceBindingArity : Expr -> Int
sourceBindingArity (ELoc _ expr) = sourceBindingArity expr
sourceBindingArity (EDoOrigin _ expr) = sourceBindingArity expr
sourceBindingArity (EAnnot expr _) = sourceBindingArity expr
sourceBindingArity (EHeadAnnot expr _) = sourceBindingArity expr
sourceBindingArity (ELetGroup _ expr) = sourceBindingArity expr
sourceBindingArity (ELam pats _) = listLen pats
sourceBindingArity _ = 0

-- Round-2 adversarial break "let-alias evasion" (#816): register a LOCAL
-- binding's generalized scheme obligations exactly as processSCC does for
-- top-level members, so a later use re-instantiates them into the
-- call-obligation window every checker reads.  Before this, `let f = hh`
-- (re-generalizing `hh : Num x => x -> x`) registered NOTHING: the RHS
-- occurrence's obligation stayed on a var generalization then orphaned, Int
-- defaulting satisfied it quietly, and `f x` at a method-scheme var sailed
-- through check into an eval panic / native SEGFAULT.  Name collisions across
-- bodies are safe: obligations are keyed by the scheme's own quantified ids,
-- and substMonos skips ids a different scheme's instantiation does not map.
--
-- A local binding whose scheme keeps class predicates is dictionary-abstracted
-- (`registerLocalAbs`): each use applies it to dictionaries solved at the use, so its
-- constrained vars generalize and defer exactly as described above.
registerLocalScheme : ModuleCtx -> String -> Scheme -> Int -> Int -> Int -> Unit
registerLocalScheme mctx x sch oblN0 callN0 dictN0 =
  declareQuantified mctx sch
  -- Obligations registered universally (#827/#838 I2); do not gate to IMPL/DEFAULT
  -- bodies only. See docs/spec/DICT-SEMANTICS.md § "4.1 `gen` at a local binder".
  let addedObls = wWindow mctx.mcCells.implObls oblN0
  let callOblsDelta = callOblsWindow mctx callN0
  -- #838 I5: the dict-slot's forwarded obligation is ALREADY in callOblsDelta as the
  -- mirroring PCallSlot obligation recorded at inferDictAtFound (recordCallObligations,
  -- beside pushDictApp), reaching schemeOblsForMember via forwardedVecObls; the old
  -- `allDictObls` re-derivation was a redundant second source (deduped away). Retired.
  registerSchemeObligations mctx omEmpty [] callOblsDelta addedObls [(x, sch)]

-- A generalized local's quantified variables are its uses' to choose, as a
-- signature's are its callers' (DICT-SEMANTICS §3), so they are declared before
-- its context is read off its goals: an instance that answers a goal only by
-- binding one does not discharge it, the goal stays in the scheme, and each use
-- poses it at its own instantiation to the binder enclosing that use.
declareQuantified : ModuleCtx -> Scheme -> Unit
declareQuantified mctx sch =
  declareRigidVars mctx (map intToString (schemeIds sch))

inferLetSimple : TcEnv -> Pat -> Expr -> Expr -> Mono
inferLetSimple outer pat e1 e2 =
  -- The binding's own checks are located at its right-hand side; the body is
  -- the enclosing construct's.
  let env = envAtIfSome (exprSpanLoc e1) outer
  enterLevel env.teDyn.dcModule ()
  beginEffectSummaryScope env.teDyn.dcModule ()
  let oblN0 = wMark env.teDyn.dcModule.mcCells.implObls
  let callN0 = wMark env.teDyn.dcModule.mcCells.obls
  let dictN0 = goalsMark env.teDyn.dcModule.mcGraph ()
  let lscope = match pat
    PVar x _ _ => openLocalScopeIf env.teDyn.dcModule x
    _ => None
  let t1 = infer env e1
  closeLocalScope env.teDyn.dcModule lscope
  let residuals = finishValueEffectsKeeping env.teDyn [
    (patIsVar pat && isNonexpansive env e1, t1),
  ]
  exitLevel env.teDyn.dcModule ()
  -- PLAN.md #11 / D4: ground an ambiguous Num-only var owned by this inner let
  -- before it generalizes, so `let z = 2 in y + z` (y:Float) is a clean type
  -- error and never leaks an unbound Num var.  Scoped to this binding's new obligations.
  let addedObls = wWindow env.teDyn.dcModule.mcCells.implObls oblN0
  improveLocalGoals env.teDyn addedObls callN0
  let _ = finalizeNumBoundary env.teDyn NumBoundary {
    nbDisposition =
      NumBoundaryOwnedMember
        (env.teDyn.dcModule.mcCells.currentLevel.value + 1),
    nbMembers = [t1],
    nbSurvivingIds = memberTiedSurvivors env.teDyn.dcModule t1 addedObls callN0,
    nbDefaultObls = addedObls,
    nbAmbiguityObls = addedObls,
    nbGuard = localNumGuard env.teDyn.dcModule addedObls callN0,
  }
  inferLetBody
    env
    outer.teDyn.dcModule.mcLoc
    pat
    t1
    residuals
    e1
    e2
    oblN0
    callN0
    dictN0
    lscope

patIsVar : Pat -> Bool
patIsVar (PVar _ _ _) = True
patIsVar _ = False

-- [env] is located at the binding, [bodyLoc] is the span the body is inferred at.
inferLetBody : TcEnv ->
  Option Loc ->
  Pat ->
  Mono ->
  List (Int, AuthResidual) ->
  Expr ->
  Expr ->
  Int ->
  Int ->
  Int ->
  Option ScopeId ->
  Mono
inferLetBody env bodyLoc (PVar x xloc bid) t1 residuals e1 e2 oblN0 callN0 dictN0 lscope =
  recordLocalBind env.teDyn.dcModule x (Some xloc) bid t1  -- LSP hover (PVar let bypasses inferPat)
  let sch =
    genBindingRestricted
      env.teDyn
      Tip
      (residualsOf 0 residuals)
      (isNonexpansive env e1)
      pureRow
      t1  -- #866
  registerLocalScheme env.teDyn.dcModule x sch oblN0 callN0 dictN0
  registerLocalAbsIf env.teDyn.dcModule x lscope sch oblN0 callN0
  infer (envAt bodyLoc (seedAlphaLets (extendLocalVar env x sch) x e1)) e2  -- WS-2: α scope-seed
inferLetBody env bodyLoc pat t1 _ _ e2 _ _ _ _ =
  let lits = takePatLits env.teDyn.dcModule ()
  let pr = inferPat env pat
  unifyIn env.teDyn (fst pr) t1
  settlePatLits env.teDyn lits
  checkBinderPat env (fst pr) pat
  infer (envAt bodyLoc (extendLocalVars env (snd pr))) e2

inferIf : TcEnv -> Expr -> Expr -> Expr -> Mono
inferIf env c t e =
  -- A condition that is not a `Bool` is reported at the condition.
  unifyIn
    (dynAtIfSome (exprSpanLoc c) env.teDyn)
    (infer env c)
    (tconBuiltin "Bool")
  let tt = infer env t
  let ee = infer env e
  let context = if isOmittedElse e then JoinElselessIf else JoinIf
  joinValueTypes env.teDyn context [(exprLoc t, tt), (exprLoc e, ee)]

-- The parser builds an omitted `else` as a bare unit literal (`elseBranch`,
-- `compiler/frontend/parser.mdk`) and wraps every atom it reads in `ELoc`, a
-- written `()` included, so only an omitted branch arrives unwrapped.  The
-- final clause is a deliberate catch-all: the question is whether the branch is
-- exactly that one parser-built shape, and every other constructor, including
-- one added to `Expr` later, is a written branch.
isOmittedElse : Expr -> Bool
isOmittedElse (ELit LUnit) = True
isOmittedElse _ = False

publishProducedResults : DynCtx ->
  BindingSummary ->
  List (Option Loc, Mono) ->
  Unit
publishProducedResults dyn owned values =
  let results = map (clauseResult owned.bsArity) values
  let produced =
    optionOrFresh
      dyn.dcModule
      (joinProducedEnvelope
        (valueJoinOps dyn JoinClause (_ => collectProducedSummary dyn.dcModule))
        results)
  each
    ((loc, lower) => recordFileValueFlow dyn.dcModule loc produced lower)
    results
  match resultAfterArrows owned.bsArity owned.bsValue
    Some expected => bindFrom dyn expected produced
    None => panic "binding source arity differs from its allocated shape"

clauseResult : Int -> (Option Loc, Mono) -> (Option Loc, Mono)
clauseResult arity (loc, value) = match resultAfterArrows arity value
  Some result => (loc, result)
  None => (loc, value)

inferProduced : TcEnv -> List Expr -> List (Option Loc, Mono)
inferProduced env [] = []
inferProduced env (e :: es) =
  let value = infer env e
  (exprLoc e, value) :: inferProduced env es

inferEach : TcEnv -> List Expr -> List Mono
inferEach env [] = []
inferEach env (e :: es) =
  let t = infer env e
  t :: inferEach env es

inferListLit : TcEnv -> List Expr -> Mono
inferListLit env es =
  let elem = joinValueTypes env.teDyn JoinList (inferProduced env es)
  TApp (tconBuiltin "List") elem

inferAnnot : TcEnv -> Expr -> Ty -> Mono
inferAnnot env e ty =
  let oblN0 = wMark env.teDyn.dcModule.mcCells.implObls
  let callN0 = wMark env.teDyn.dcModule.mcCells.obls
  let t = infer env e
  let pair = astTypeFreshTbl env.teDyn.dcModule ty
  let annot = fst pair
  -- The annotated expression flows into the written type as an argument
  -- into its parameter: a qualified annotation bounds its abstraction.
  argumentIntoOrd True env (Some e) annot t
  checkAnnotTooGeneral env.teDyn.dcModule ty (map snd (snd pair))
  -- The written variables are declared for the annotated expression's goals.
  -- Past it they are not: an annotated local that generalizes declares them as
  -- its quantified variables, and one that does not leaves them to its binder.
  let annotation = [("", ty, snd pair)]
  let declared = sccProtectedSignatureIds annotation
  if omSize declared == 0 then
    ()
  else
    checkSigVarGoals
      env.teDyn.dcModule
      DeclaredByAnnotation
      declared
      annotation
      (wWindow env.teDyn.dcModule.mcCells.implObls oblN0
        ++ callUOblsWindow env.teDyn.dcModule callN0)
  annot

-- Head-pin (`:~`, EHeadAnnot): like inferAnnot but WITHOUT the
-- checkAnnotTooGeneral skolemization guard — the pin's type variables are MEANT
-- to ground (the container literal's element types).  Fixes `e`'s head tycon to
-- the named container so `fromEntries`'s return-position dispatch resolves to
-- that container's impl.
--
-- Ignore the *arity* the lowering happened
-- to supply and apply the head tycon to its *declared* arity of fresh vars.  The
-- parser can't tell empty `Map { }` from `Set { }` — both have no entries, so
-- classifyBrace falls through to `ESetLit name []` and the desugar pins a UNARY
-- `Map _a`, the wrong arity for `Map k v` (→ `Map vs Map …`).  Looking the arity
-- up by the head tycon makes empty literals work regardless of the lowering's
-- guess; element vars stay free and ground via inference.
inferHeadAnnot : TcEnv -> Expr -> Ty -> Mono
inferHeadAnnot env e ty =
  let t = infer env e
  let annot = headAnnotTy env.teDyn.dcModule ty
  unifyIn env.teDyn t annot
  t

inferMatch : TcEnv -> Mono -> List Arm -> Mono
inferMatch env scrutTy arms =
  let result = joinValueTypes env.teDyn JoinMatch (inferArms env scrutTy arms)
  scheduleMatchChecks
    env
    scrutTy
    arms
    (matchWarningLoc env.teDyn.dcModule.mcLoc arms)
  result

scheduleMatchChecks : TcEnv -> Mono -> List Arm -> Option Loc -> Unit
scheduleMatchChecks env scrutTy arms loc = match normalize scrutTy
  TVar _ =>
    env.teDyn.dcModule.mcCells.matchChecksDeferred :=
      (scrutTy, arms, loc)
        :: env.teDyn.dcModule.mcCells.matchChecksDeferred.value
  _ => checkMatchChecks (mctxAt loc env.teDyn.dcModule) scrutTy arms

-- A `let` pattern or lambda parameter is judged as the single arm of a match
-- on its own type, at the binding.  The parameters of one binding are judged as
-- one tuple pattern, so a binding with several refutable parameters warns once,
-- not once per parameter.
checkBinderPats : TcEnv -> List Mono -> List Pat -> Unit
checkBinderPats env [t] [p] = checkBinderPat env t p
checkBinderPats env ts ps
  | allList patIsVar ps = ()
  | otherwise = checkBinderPat env (tupleMono ts) (PTuple ps)

-- The variable that is the body of a binder's one arm: it marks the check as a binder's, whose
-- warning is worded for a pattern with no match to add an arm to.
binderMarker : String
binderMarker = "<binder>"

isBinderArms : List Arm -> Bool
isBinderArms [Arm _ [] (EVar n)] = n == binderMarker
isBinderArms _ = False

checkBinderPat : TcEnv -> Mono -> Pat -> Unit
checkBinderPat env ty pat =
  if patIsVar pat then
    ()
  else
    scheduleMatchChecks
      env
      ty
      [Arm pat [] (EVar binderMarker)]
      env.teDyn.dcModule.mcLoc

-- A match's warnings are located at the match through its last arm.  The
-- match's own span runs on over any comment or blank line that follows, on the
-- last arm's line or after it, so it is cut at the end of the last arm.  On
-- that arm's own line the cut takes the body's own span (its `ELoc`): the
-- parts of an unwrapped body do not reach its end (a field access's name has
-- no span).
matchWarningLoc : Option Loc -> List Arm -> Option Loc
matchWarningLoc (Some (Loc f sl sc el ec)) arms = match last arms
  Some (Arm _ _ body) => match exprSpanLoc body
    Some (Loc _ _ _ bel bec) if bel < el => Some (Loc f sl sc bel bec)
    _ => match exprLoc body
      Some (Loc _ _ _ bel bec) if bel == el && bec < ec =>
        Some (Loc f sl sc bel bec)
      _ => Some (Loc f sl sc el ec)
  None => Some (Loc f sl sc el ec)
matchWarningLoc None _ = None

-- A scrutinee whose type is still unknown after its arms (only literal, variable
-- and wildcard patterns, e.g. a lambda's parameter matched against integer
-- literals) is checked at the module's end instead, once `settleDeferredPatLits`
-- has given it its type, so the warning names it (`non-exhaustive match on U8`).
export
checkMatchChecks : ModuleCtx -> Mono -> List Arm -> Unit
checkMatchChecks mctx scrutTy arms =
  checkMatchExhaustive mctx scrutTy arms
  checkMatchRedundant mctx scrutTy arms

export
checkDeferredMatches : ModuleCtx -> List (Mono, List Arm, Option Loc) -> Unit
checkDeferredMatches mctx [] = ()
checkDeferredMatches mctx ((scrutTy, arms, loc) :: rest) =
  checkMatchChecks (mctxAt loc mctx) scrutTy arms
  checkDeferredMatches mctx rest

-- Warn if an all-wildcard query is still useful against the matrix of the
-- non-guarded arms — i.e. some scrutinee value escapes every arm.  Guarded arms
-- are excluded (their guard may fail at runtime), matching the reference.
--
-- `matchWarnings` is the channel for a typecheck-stage warning, so a push carries its own
-- `W-*` code: `diagOfTypeWarning` passes the code straight to `--json`, and `codeKind` derives
-- the JSON kind from its prefix.  A demoted error must not be pushed through `recordTypeError`
-- as a severity-2 diagnostic instead: that arms `typeErrorsSticky` and bumps `errorsDetected`
-- whatever the severity, so the warning would still abort `build` and `run`.
checkMatchExhaustive : ModuleCtx -> Mono -> List Arm -> Unit
checkMatchExhaustive mctx scrutTy arms =
  let rows = nonGuardedRows mctx arms
  if useful
    mctx.mcCells.matchOracle.value
    (matchCol0Type scrutTy)
    rows
    [PWild] then
    let binder = isBinderArms arms
    let (msg, help) = nonExhaustiveMsg mctx scrutTy rows binder
    -- A let-bound function is nested one-parameter lambdas that share the
    -- binding's location; the first refutable parameter's warning is the one.
    if binder
      && anyList (warnedAt mctx.mcLoc) mctx.mcCells.matchWarnings.value then
      ()
    else
      mctx.mcCells.matchWarnings :=
        writtenDiag (TcDiag "W-NONEXHAUSTIVE" 2 mctx.mcLoc msg help None)
          :: mctx.mcCells.matchWarnings.value

warnedAt : Option Loc -> TcDiag -> Bool
warnedAt loc (TcDiag code _ at _ _ _) =
  code == "W-NONEXHAUSTIVE" && locKey loc /= "" && locKey at == locKey loc

checkMatchRedundant : ModuleCtx -> Mono -> List Arm -> Unit
checkMatchRedundant mctx scrutTy arms =
  checkRedundantGo mctx (matchCol0Type scrutTy) [] omEmpty False arms

-- PERF: `prec` accumulates the preceding arms' patterns and is PREPENDED to, so
-- it holds them in REVERSE arm order.  Appending (`prec ++ [[dp]]`) would copy the
-- whole accumulator once per arm: O(N²) allocation on a match with many arms.
--
-- Reversing the rows is sound because `useful` is a predicate over the set of
-- matrix rows ("does some value match the query and no row?"): `specializeCon` /
-- `specializeLit` / `defaultMatrix` are row-wise filters, and the only decision
-- that reads rows in order is `columnCtors`, which just needs SOME column-0
-- constructor to name the column's type — and it is consulted only when `col0`
-- is `None`, i.e. when the scrutinee type has no concrete head, in which case no
-- arm carries a constructor pattern and there is no head constructor to find in
-- either order.
checkRedundantGo : ModuleCtx ->
  Option TabKey ->
  List (List Pat) ->
  OrdMap Unit ->
  Bool ->
  List Arm ->
  Unit
checkRedundantGo mctx _ _ _ _ [] = ()
checkRedundantGo mctx col0 prec heads offCol ((Arm pat gs body) :: rest) =
  let dp = desugarPat mctx.mcCells.matchOracle.value pat
  if armUnreachable mctx col0 prec heads offCol dp then
    mctx.mcCells.matchWarnings :=
      TcDiag
          "W-UNREACHABLE-ARM"
          2
          (orElseLoc (exprLoc body) mctx.mcLoc)
          unreachableArmWarning
          None
          None
        :: mctx.mcCells.matchWarnings.value
  -- Only UNGUARDED, range-free arms contribute to the covered set: a guarded arm
  -- may not fire, and a range collapses to a wildcard that over-states coverage
  -- (patHasRange) — either would produce a false "redundant" on a later arm.
  let contributes = armIsUnguarded gs && not (patHasRange pat)
  let prec2 = if contributes then [dp] :: prec else prec
  let heads2 = if contributes then noteHeadCtor dp heads else heads
  let offCol2 = offCol || contributes && not (isConPat dp)
  checkRedundantGo mctx col0 prec2 heads2 offCol2 rest

-- PERF fast path.  `patUnreachable` runs the full Maranget `useful` recursion, which
-- re-scans EVERY preceding row — so the fold as a whole is O(arms²) on a wide match.
-- But a constructor arm `C …` can only be unreachable if some preceding row could
-- match a `C` value, and the only rows that can are (a) rows headed by `C` itself and
-- (b) rows with a WILDCARD head, which match anything.  When neither exists,
-- `specializeCon C` yields the EMPTY matrix and `useful _ _ [] _` is `True` by
-- definition — the arm is reachable — so the recursion is guaranteed to say
-- "reachable" and we can skip it outright.
--
-- `heads` is the set of head constructors of the preceding contributing rows and
-- `offCol` records whether any of them has a NON-constructor head.  `offCol` is a
-- deliberate over-approximation of "has a wildcard head" (it also trips on a literal
-- head, which `specializeCon` would in fact discard): erring towards `True` only ever
-- costs us the fast path and falls back to the exact check, never an answer.
armUnreachable : ModuleCtx ->
  Option TabKey ->
  List (List Pat) ->
  OrdMap Unit ->
  Bool ->
  Pat ->
  Bool
armUnreachable mctx col0 prec heads offCol (PCon c args)
  | not offCol && not (omHasKey c heads) = False
  | otherwise =
    patUnreachable mctx.mcCells.matchOracle.value col0 prec (PCon c args)
armUnreachable mctx col0 prec _ _ dp =
  patUnreachable mctx.mcCells.matchOracle.value col0 prec dp

noteHeadCtor : Pat -> OrdMap Unit -> OrdMap Unit
noteHeadCtor (PCon c _) heads = omInsert c () heads
noteHeadCtor _ heads = heads

isConPat : Pat -> Bool
isConPat (PCon _ _) = True
isConPat _ = False

-- Only UNGUARDED arms contribute to the covered set (a guarded arm may not fire).
armIsUnguarded : List Guard -> Bool
armIsUnguarded [] = True
armIsUnguarded (_ :: _) = False

-- Build the specialised warning: recover a concrete uncovered pattern (the
-- Maranget witness) and name it, plus the scrutinee type when it has a real
-- head name.  Falls back to the generic wording if no witness is recoverable
-- (keeps the warning firing whenever `useful` should, never naming a wrong
-- constructor).  Actionable-fix hint (F dimension): when a witness IS
-- recoverable, append a concrete-edit suggestion using the witness string
-- VERBATIM (so `Triangle _` reads as `Triangle _`, not `Triangle`) and return it
-- as the `Some` help so `--json`'s `help` field carries it too.  #159: returns
-- `(message, Option help)` so the caller can stash both in the warning's TcDiag —
-- no more message-keyed `matchWarningHelp` side channel.
nonExhaustiveMsg : ModuleCtx ->
  Mono ->
  List (List Pat) ->
  Bool ->
  (String, Option String)
nonExhaustiveMsg mctx scrutTy rows binder =
  match (usefulWitness
    mctx.mcCells.matchOracle.value
    (matchCol0Type scrutTy)
    rows
    1)
    Some (w :: _) =>
      let witnessStr = renderWitness w
      if binder then
        let (msg, hint) =
          binderNonExhaustiveMsg (matchCol0Type scrutTy) witnessStr
        (msg, Some hint)
      else
        let hint =
          if witnessStr == "_" then
            "add a `_ => ...` arm"
          else
            "add a `\{witnessStr} => ...` arm or a `_` wildcard"
        let msg =
          "Warning: non-exhaustive match\{tyOfMsg (matchCol0Type scrutTy)}: missing `\{witnessStr}`; \{hint}"
        (msg, Some hint)
    _ => (nonExhaustiveMatchWarning, None)

-- one single-column matrix row per non-guarded arm (its desugared pattern)
nonGuardedRows : ModuleCtx -> List Arm -> List (List Pat)
nonGuardedRows mctx [] = []
nonGuardedRows mctx ((Arm pat [] _) :: rest) =
  [desugarPat mctx.mcCells.matchOracle.value pat] :: nonGuardedRows mctx rest
nonGuardedRows mctx ((Arm _ _ _) :: rest) = nonGuardedRows mctx rest

inferArms : TcEnv -> Mono -> List Arm -> List (Option Loc, Mono)
inferArms env _ [] = []
inferArms env scrutTy ((Arm pat gs body) :: rest) =
  let value = inferArm env scrutTy pat gs body
  (exprLoc body, value) :: inferArms env scrutTy rest

inferArm : TcEnv -> Mono -> Pat -> List Guard -> Expr -> Mono
inferArm env scrutTy pat gs body
  | env.teDyn.dcModule.mcGraph.graphRun.anyExistentialsRef.value
    && patOpensExistentials env pat = inferArmOpening env scrutTy pat gs body
  | otherwise =
    let lits = takePatLits env.teDyn.dcModule ()
    let pr = inferPat env pat
    bindFrom env.teDyn (fst pr) scrutTy
    settlePatLits env.teDyn lits
    let envBody = inferArmGuards (extendLocalVars env (snd pr)) gs
    infer envBody body

-- An arm whose pattern opened existential authorities (§4.1) is their scope.
-- The body runs one level deeper, so a cell bound into anything the arm did
-- not create is lowered by the ordinary level discipline and found at the
-- end; a cell in the arm's own value type is found there.  Either is an
-- escape (`T-AUTHORITY-ESCAPE`): the arm's value cannot carry an authority
-- nothing outside it can name.  A row the arm performs at the authority is
-- checked against the enclosing declaration as any row is (rigid: only the
-- label bare admits it), and an inferred row publishes it as the domain's
-- top (`defaultSourcelessAuthorities`).
inferArmOpening : TcEnv -> Mono -> Pat -> List Guard -> Expr -> Mono
inferArmOpening env scrutTy pat gs body =
  let lits = takePatLits env.teDyn.dcModule ()
  let pr = inferPat env pat
  bindFrom env.teDyn (fst pr) scrutTy
  let scope =
    openExistentialScope
      env.teDyn.dcModule
      (takeOpenedExistentials env.teDyn.dcModule ())
  settlePatLits env.teDyn lits
  let envBody = inferArmGuards (extendLocalVars env (snd pr)) gs
  let t = infer envBody body
  closeExistentialScope env.teDyn.dcModule scope t (exprLoc body)
  t

-- Thread an arm's guard qualifiers left-to-right: a `GBool` must be `Bool` and leaves the env unchanged; a
-- `GBind p e` infers `e`, binds `p` against it, and extends the env so the bound
-- vars are in scope for LATER qualifiers and the arm body.  A qualifier's own
-- check is located at its expression.
inferArmGuards : TcEnv -> List Guard -> TcEnv
inferArmGuards env [] = env
inferArmGuards env ((GBool g) :: rest) =
  unifyIn
    (dynAtIfSome (exprSpanLoc g) env.teDyn)
    (infer env g)
    (tconBuiltin "Bool")
  inferArmGuards env rest
inferArmGuards env ((GBind p e) :: rest) =
  let te = infer env e
  let at = envAtIfSome (exprSpanLoc e) env
  let lits = takePatLits at.teDyn.dcModule ()
  let pr = inferPat at p
  bindFrom at.teDyn (fst pr) te
  settlePatLits at.teDyn lits
  inferArmGuards (extendLocalVars env (snd pr)) rest

inferLetGroup : TcEnv -> List LetBind -> Expr -> Mono
inferLetGroup env binds body =
  checkLetGroupBindsLocated env.teDyn.dcModule binds  -- #799
  let env2 = fold processLetGroup env (letGroupComponents binds)
  infer env2 body

-- process one dependency component of a where block: bind names, infer,
-- generalize
processLetGroup : TcEnv -> List LetBind -> TcEnv
processLetGroup env binds =
  enterLevel env.teDyn.dcModule ()
  beginEffectSummaryScope env.teDyn.dcModule ()
  let oblN0 = wMark env.teDyn.dcModule.mcCells.implObls
  let callN0 = wMark env.teDyn.dcModule.mcCells.obls
  let dictN0 = goalsMark env.teDyn.dcModule.mcGraph ()
  let summaries = map (localBindingSummary env.teDyn.dcModule) binds
  each
    (entry => recordLetBindType env.teDyn.dcModule.mcGraph entry)
    (zipL binds summaries)
  let placeholders = map (p => (fst p, monoScheme (snd p).bsValue)) summaries
  let recursive =
    map (p => (fst p, monoScheme (snd p).bsRecursiveValue)) summaries
  let env2 = extendLocalVars env recursive
  each
    (bind => forgetLocalAbs env.teDyn.dcModule.mcGraph (letBindName bind))
    binds
  let lscopes = inferLetBinds env2 (zipL binds summaries)
  each (entry => checkRecursiveValue env.teDyn (snd entry)) summaries
  let residuals =
    finishValueEffectsKeeping
      env.teDyn
      (map (letBindGeneralizes env) (zipL binds summaries))
  flushPendingEscapes env.teDyn.dcModule env.teDyn.dcGroup
  exitLevel env.teDyn.dcModule ()
  -- PLAN.md #11 / D4, as a where block narrows it (#3487): ground the Num-only
  -- vars owned by this just-exited component that no member's type mentions
  -- (nothing can generalize them).  One a member's type does mention, even in
  -- return position, generalizes with its constraint, so a sibling or the
  -- enclosing body instantiates it (`two _ = 2` beside `go y = y / two ()`);
  -- the enclosing binding's boundary decides what its uses leave ambiguous.
  -- Scoped to this group's newly added obligations.
  let addedObls = wWindow env.teDyn.dcModule.mcCells.implObls oblN0
  improveLocalGoals env.teDyn addedObls callN0
  let memberMonos = map (p => schemeMono (snd p)) placeholders
  let _ = finalizeNumBoundary env.teDyn NumBoundary {
    nbDisposition =
      NumBoundaryOwnedGroup (env.teDyn.dcModule.mcCells.currentLevel.value + 1),
    nbMembers = memberMonos,
    nbSurvivingIds = omEmpty,
    nbDefaultObls = addedObls,
    nbAmbiguityObls = addedObls,
    nbGuard = localNumGuard env.teDyn.dcModule addedObls callN0,
  }  -- RETPOS soundness
  let genv = generalizeGroup env residuals 0 (zipL binds placeholders)
  -- Let-alias evasion (#816): a LOCAL constrained binding (`let f = hh`
  -- re-generalizing `hh : Num x => x -> x`) that registered NOTHING in
  -- schemeObligationsRef (only top-level SCCs do) would leave a later use `f x` with
  -- no obligation at all: the one recorded at the RHS occurrence stays on a var the
  -- generalization then orphans, Int defaulting quietly satisfies it, and a
  -- scheme-var instantiation sails through check into an eval panic / native
  -- SEGFAULT.  Register the group
  -- exactly as processSCC does; instantiateVarTrackedId's per-use re-recording
  -- then feeds the same call-obligation window every checker reads.  Name
  -- collisions across bodies are safe: the obligation ids are the scheme's own
  -- quantified ids, and substMonos skips entries whose ids a different scheme's
  -- instantiation does not map.
  let callOblsDelta = callOblsWindow env.teDyn.dcModule callN0
  let schemes = groupSchemesOf genv binds
  each (p => declareQuantified env.teDyn.dcModule (snd p)) schemes
  -- #827/#838 I2: register EVERYWHERE, not only inside a method body.  The
  -- uniform deferral (`undeterminedGoalExempt`'s OD2 test) makes a generalizable
  -- where/let var defer into the enclosing scheme rather than trip an ambiguity
  -- reject, closing the orphaned-local-constraint S0 (#827).  See registerLocalScheme.
  -- #838 I5: dict-slot forwarding rides callOblsDelta's PCallSlot obligations (see
  -- registerLocalScheme); the redundant `allDictObls` re-derivation is retired.
  registerSchemeObligations
    env.teDyn.dcModule
    omEmpty
    []
    callOblsDelta
    addedObls
    schemes
  registerLocalGroupAbs genv oblN0 callN0 (zipL binds lscopes)
  genv

-- the generalized (name, scheme) pairs of a just-closed local group
groupSchemesOf : TcEnv -> List LetBind -> List (String, Scheme)
groupSchemesOf env [] = []
groupSchemesOf genv ((LetBind name _ _ _) :: rest) = match lookupVar genv name
  Some sch => (name, sch) :: groupSchemesOf genv rest
  None => groupSchemesOf genv rest

inferLetBinds : TcEnv ->
  List (LetBind, (String, BindingSummary)) ->
  List (Option ScopeId)
inferLetBinds env [] = []
inferLetBinds env ((bind@(LetBind name clauses _ _), (_, owned)) :: rest) =
  let pairs = map funClausePair clauses
  let lscope =
    if isLocalAbsName name then
      Some (openLocalScope env.teDyn.dcModule name)
    else
      None
  let _ = inferMemberClauses env None owned pairs
  closeLocalScope env.teDyn.dcModule lscope
  match pairs
    [([], _)] =>
      performEffect
        env.teDyn.dcModule
        env.teDyn.dcModule.mcCells.curEffect
        owned.bsForce
    _ => ()
  lscope :: inferLetBinds env rest

-- A binder's declared variables join the set every instance-head matcher holds
-- rigid (`matchEqPairs`), from the binder's close on.
export
declareRigidVars : ModuleCtx -> List String -> Unit
declareRigidVars mctx [] = ()
declareRigidVars mctx keys =
  mctx.mcCells.declaredSigVarIds :=
    omFromNames keys mctx.mcCells.declaredSigVarIds.value

-- Extended Pass A: same as preunifySigs but also returns the tyvar maps (for
-- the signature-too-general check after body inference).  Returns a pair:
-- (constraintRegs, sigTvMaps) where sigTvMaps is [(name, sig_ast, tvs)] for
-- each signed member.
-- #1161: each reg is a TRIPLE — (name, slot-parallel (iface, mono) pairs,
-- slot-parallel predicate argument VECTORS).  The third is carried alongside the first
-- two, never instead of them, so nothing downstream that sizes or orders dict slots can
-- move.
export
preunifySigsEx : ModuleCtx ->
  List (String, Ty) ->
  List ScopedMember ->
  (List ConstraintReg, List (String, Ty, List (String, Mono)))
preunifySigsEx mctx _ [] = ([], [])
preunifySigsEx mctx sigs (member :: rest) =
  let m = member.smName
  let v = member.smMono
  let (restRegs, restTvs) = preunifySigsEx mctx sigs rest
  match omLookup m mctx.mcCells.sigTyMapRef.value
    Some ty =>
      member.smSigned := True
      let (signedMono, tvs, forceBound) = instantiateSigTracked mctx ty
      member.smDeclaredRoots :=
        effectRowRoots
          (optionOr pureRow forceBound)
          (effectRoots signedMono Tip)
      member.smDeclaredAuths :=
        authRowRoots (optionOr pureRow forceBound) (authRoots signedMono Tip)
      member.smForceBound := forceBound
      let (declaredScheme, declaredTvs) = sigToSchemeTvs mctx ty
      let (Forall ids eids aids _ declaredForce declaredValue) = declaredScheme
      let slots =
        declaredPredicateSlots
          (constraintVarIfaceMonos (sigConstraints ty) declaredTvs)
          (constraintVarArgMonos
            mctx
            (sigConstraints ty)
            (sigConstraintArgTys ty)
            declaredTvs)
      member.smRecursive := Some EnvBinding {
        ebValue = ValueScheme {
          vsScheme =
            Forall
              ids
              eids
              aids
              []
              (match forceBound
                Some _ => declaredForce
                None => optionOr pureRow member.smForce)
              declaredValue,
          vsDeclared = Some CDeclared {
            cdSlots = predicateSlotCSlots slots,
            cdPrefix =
              CDPLen (listLen (dedupSlotVecs (map predicateSlotView slots))),
            cdArgs = predicateSlotArgs slots,
          },
        },
        ebMethodRow = None,
        ebStandalone = None,
      }
      bindFrom (dynFor mctx) v signedMono
      let regs = [
        ConstraintReg {
          crName = m,
          crScope = member.smScope,
          crIfaceMonos = constraintVarIfaceMonos (sigConstraints ty) tvs,
          crArgVecs =
            constraintVarArgMonos
              mctx
              (sigConstraints ty)
              (sigConstraintArgTys ty)
              tvs,
        },
      ]
      (regs ++ restRegs, (m, ty, tvs) :: restTvs)
    None =>
      unify mctx v member.smOwned.bsValue
      (restRegs, restTvs)

-- The span of the expression whose value [e] is: a `let … in`, which has no
-- span of its own, returns its body's value, and a block returns its last
-- statement's.
export
valueSpanLoc : Expr -> Option Loc
valueSpanLoc (ELoc l _) = Some l
valueSpanLoc (ELet _ _ _ _ body) = valueSpanLoc body
valueSpanLoc (ELetGroup _ body) = valueSpanLoc body
valueSpanLoc (EBlock stmts) = match last stmts
  Some (DoExpr e) => valueSpanLoc e
  _ => exprSpanLoc (EBlock stmts)
valueSpanLoc e = exprSpanLoc e

-- zip-unify the equal-length prefix of param types and peeled sig domains; a
-- shorter [qs] (partial sig) pushes nothing past its end
-- Domains constrain the recursive placeholder as each clause is inferred.
-- Produced results join once after all alternatives are known: the first
-- clause must not fix a returned callback's row for its siblings.
export
inferMemberClauses : TcEnv ->
  Option Mono ->
  BindingSummary ->
  List (List Pat, Expr) ->
  List Atom
inferMemberClauses env _ _ [] = []
inferMemberClauses env peel owned clauses =
  let (values, effects) = inferClauseValues env peel owned clauses
  publishProducedResults env.teDyn owned values
  effrowLabels (collectRows (joinCellOf env.teDyn.dcModule.mcGraph) effects)

inferClauseValues : TcEnv ->
  Option Mono ->
  BindingSummary ->
  List (List Pat, Expr) ->
  (List (Option Loc, Mono), List EffRow)
inferClauseValues env _ _ [] = ([], [])
inferClauseValues env peel owned (cl :: rest) =
  let ce = inferClauseEff env peel cl
  -- A clause that does not fit the member's type is reported at the value it
  -- returns.
  let value = valueSpanLoc (snd cl)
  unifySourceDomains
    (dynAtIfSome value env.teDyn)
    (listLen (fst cl))
    owned.bsValue
    (fst ce)
  recordEffectBody env.teDyn.dcModule owned.bsBody (snd ce)
  let (values, effects) = inferClauseValues env peel owned rest
  ((value, fst ce) :: values, snd ce :: effects)

-- infer one clause, returning its arrow type AND the concrete effect labels its
-- body performs (captured in a fresh collection, then the ambient restored —
-- building a closure performs nothing).  Mirrors inferLam but exposes the effect.
-- When [peel] is Some(sig source) and the clause has params, peel the
-- signature's arrow domains and zip-unify them onto the clause param types BEFORE
-- inferring the body (bidirectional checking mode).
inferClauseEff : TcEnv -> Option Mono -> (List Pat, Expr) -> (Mono, EffRow)
inferClauseEff outer peel (pats, body) =
  -- The clause is located at its body: patterns carry no source Loc, so an
  -- over-applied-constructor / arity pattern error lands on this clause, and a
  -- body the parser leaves unwrapped (an application, an operator) is still
  -- located.  See the twin note in inferLam.
  let env = envAtIfSome (exprSpanLoc body) outer
  let lits = takePatLits env.teDyn.dcModule ()
  let pr = inferPats env pats
  peelOntoParams env.teDyn peel (fst pr) pats
  let scope =
    openExistentialScope
      env.teDyn.dcModule
      (takeOpenedExistentials env.teDyn.dcModule ())
  settlePatLits env.teDyn lits
  match peel
    Some src => recordClauseFileBound env.teDyn.dcModule body (listLen pats) src
    None => ()
  -- #2109: a signed clause's body is inferred AGAINST the signature's result
  -- type (result-first), so a fresh construction at a non-covariant slot meets
  -- the declaration while its own slot is still a metavariable.  See
  -- `inferExpected`.  An unsigned clause is byte-identical to before.
  let (bodyTy, bodyEff) = captureEffects
    env.teDyn.dcModule.mcCells.curEffect
    (joinCellOf env.teDyn.dcModule.mcGraph)
    (_ => match peel
      Some src => match resultAfterArrows (listLen pats) src
        Some expected =>
          let bodyEnv = extendLocalVars env (snd pr)
          checkedInto
            bodyEnv
            body
            expected
            (inferExpected bodyEnv body expected)
        None => infer (extendLocalVars env (snd pr)) body
      None => infer (extendLocalVars env (snd pr)) body)
  closeExistentialScope env.teDyn.dcModule scope bodyTy (exprLoc body)
  (bodyArrows (fst pr) bodyEff bodyTy, bodyEff)

-- For a signed clause with params, zip-unify the peeled sig
-- domains onto the inferred param types.  No-op for an unsigned member, a value
-- binding (no params), or a sig with no remaining arrows.
peelOntoParams : DynCtx -> Option Mono -> List Mono -> List Pat -> Unit
peelOntoParams dyn None _ _ = ()
peelOntoParams dyn (Some _) _ [] = ()
peelOntoParams dyn (Some src) patTypes pats =
  zipBindFrom dyn patTypes (peelArrows (listLen pats) src)

-- A local binding carries no signature of its own.
localRole : Bool -> BindingRole
localRole True = RoleQuantifies
localRole False = RoleMonomorphic

-- test-only observation: `hadMatchWarnings` of the last module checked, the only read of a
-- drive that returns no outputs (the projections).
export
matchWarningsNow : ModuleCtx -> Bool
matchWarningsNow mctx = match mctx.mcCells.matchWarnings.value
  [] => False
  _ => True
# DESUGAR
(DUse false (UseGroup ("types" "tc_types") ((mem "AdmittedVerdict" true) (mem "BindingRole" true) (mem "BuiltinClass" true) (mem "CDeclared" true) (mem "CDeclaredPrefix" true) (mem "ConstraintReg" true) (mem "DeclaringBinder" true) (mem "DoCtx" true) (mem "DynCtx" true) (mem "EnvBinding" true) (mem "GoalKind" true) (mem "JoinContext" true) (mem "NumBoundary" true) (mem "NumBoundaryDisposition" true) (mem "SiteKind" true) (mem "TcEnv" true) (mem "UObligation" true) (mem "ValueScheme" true) (mem "dynFor" false) (mem "GraphCtx" false) (mem "ModuleCtx" false) (mem "PendingEntry" false) (mem "RecordInfo" false) (mem "RecordSubst" false) (mem "ScopedMember" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "authRoots" false) (mem "authRowRoots" false) (mem "containerParamScalarArg" false) (mem "containsI" false) (mem "domainIsTupleOfArity" false) (mem "effectRoots" false) (mem "effectRowRoots" false) (mem "expectedParamTypes" false) (mem "funArity" false) (mem "headTyconMono" false) (mem "headTyconNameMono" false) (mem "joinCellOf" false) (mem "litType" false) (mem "matchCol0Type" false) (mem "monoHasArrowInSlot" false) (mem "monoIsBool" false) (mem "monoScheme" false) (mem "peelArrows" false) (mem "peelQual" false) (mem "resultAfterArrows" false) (mem "schemeIds" false) (mem "schemeMono" false) (mem "tconBuiltin" false) (mem "tupleMono" false))))
(DUse false (UseGroup ("types" "tc_diag_text") ((mem "appSpineName" false) (mem "bangOnBoolHelp" false) (mem "bangOnBoolMsg" false) (mem "binderNonExhaustiveMsg" false) (mem "bindOutsideDoMsg" false) (mem "containerArgHint" false) (mem "containerArgMsg" false) (mem "discardedValueFix" false) (mem "discardedValueMsg" false) (mem "doBindArgHint" false) (mem "doBindArgMsg" false) (mem "i64RangeText" false) (mem "locKey" false) (mem "nonExhaustiveMatchWarning" false) (mem "notAFunctionHint" false) (mem "notAFunctionMsg" false) (mem "notAFunctionMsgFor" false) (mem "overAppliedMsg" false) (mem "renderCallArgs" false) (mem "tyOfMsg" false) (mem "u64RangeText" false) (mem "unboundVarMsg" false) (mem "unknownFieldMsg" false) (mem "unreachableArmWarning" false) (mem "wideAnnotateHelp" false) (mem "writtenDiag" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "callUOblsWindow" false) (mem "currentScopeStore" false) (mem "dynAtIfSome" false) (mem "emptyShadowDicts" false) (mem "envAt" false) (mem "envAtIfSome" false) (mem "mctxAt" false) (mem "wMark" false) (mem "wWindow" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "extendLocalVar" false) (mem "extendLocalVars" false) (mem "funClausePair" false) (mem "lookupMethodRow" false) (mem "lookupRecordByName" false) (mem "lookupStandaloneValue" false) (mem "lookupVar" false) (mem "seedAlphaLets" false))))
(DUse false (UseGroup ("types" "tc_diag") ((mem "pushTypeError" false) (mem "pushTypeErrorHelpFixAt" false) (mem "recordTypeError" false))))
(DUse false (UseGroup ("types" "tc_scope") ((mem "admittedIfaceWord" false) (mem "argDispatchOf" false) (mem "ieImplExistsForHead" false) (mem "methodEntryHere" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "applicationRowTyped" false) (mem "bindFrom" false) (mem "calleeArrow" false) (mem "captureScope" false) (mem "enterLevel" false) (mem "exitLevel" false) (mem "forceInstantiation" false) (mem "freshVar" false) (mem "instantiateMethodTracked" false) (mem "instantiateValueTracked" false) (mem "joinValueTypes" false) (mem "monoHasNonCovariantSlot" false) (mem "noteNumlitCtx" false) (mem "openRow" false) (mem "optionOrFresh" false) (mem "performEffect" false) (mem "poisonMismatchVars" false) (mem "postponePendingJoins" false) (mem "predicateSlotArgs" false) (mem "predicateSlotCSlots" false) (mem "recordFileValueFlow" false) (mem "refStored" false) (mem "settlePendingJoins" false) (mem "unify" false) (mem "unifyIn" false) (mem "unifyIntoOrd" false) (mem "unifyParamsExpected" false) (mem "unifySourceDomains" false) (mem "valueJoinOps" false) (mem "wantAuthority" false) (mem "zipBindFrom" false) (mem "closeScope" false))))
(DUse false (UseGroup ("types" "tc_decls") ((mem "astTypeFreshTbl" false) (mem "instantiateSigTracked" false) (mem "sigToSchemeTvs" false) (mem "sigToSchemeTvsIn" false) (mem "headAnnotTy" false))))
(DUse false (UseGroup ("types" "tc_solve") ((mem "goalsMark" false) (mem "improveLocalGoals" false) (mem "isLocalAbsName" false) (mem "openScope" false) (mem "pushLocalDictApp" false) (mem "routeLocalSym" false))))
(DUse false (UseGroup ("types" "tc_solve_check") ((mem "callOblsWindow" false) (mem "checkSigVarGoals" false) (mem "declaredPredicateSlots" false) (mem "dedupSlotVecs" false) (mem "finalizeNumBoundary" false) (mem "localNumGuard" false) (mem "memberTiedSurvivors" false) (mem "numConstrainedIds" false) (mem "predicateSlotView" false))))
(DUse false (UseGroup ("types" "tc_shadow") ((mem "definerReceiverDispatches" false) (mem "definerReceiverIsDictVar" false) (mem "definerShadowArgHead" false) (mem "definerShadowSpineArgAt" false) (mem "definerShadowSpineVarAt" false) (mem "definerShadowVarHead" false) (mem "enforceStandaloneDomainAt" false) (mem "groundAdmittedReceivers" false) (mem "groundShadowReceiver" false) (mem "importerAdmittedVerdict" false) (mem "importerShadowDomain" false) (mem "importerShadowDomainAt" false) (mem "methodCellOf" false) (mem "plainAppHeadVar" false) (mem "pushAmbiguousShadowDecl" false) (mem "recoveredShadowSym" false) (mem "shadowDomainForAt" false) (mem "shadowHeadEnv" false) (mem "shadowStandaloneHead" false) (mem "shadowStandaloneSpineHeadAt" false) (mem "stampMethodArities" false) (mem "stampRoutes" false) (mem "standaloneShadowDomainAt" false))))
(DUse false (UseGroup ("types" "tc_effects") ((mem "appSpineArgCount" false) (mem "beginEffectSummaryScope" false) (mem "borrowedEffectCells" false) (mem "collectProducedSummary" false) (mem "finishEffectSummaryScopeKeeping" false) (mem "flushPendingEscapes" false) (mem "freshEffectSummary" false) (mem "grantOnlyBindingId" false) (mem "localBindingSummary" false) (mem "notePerformSite" false) (mem "recordClauseFileBound" false) (mem "recordEffectBody" false) (mem "recordGrantOcc" false) (mem "recordStandaloneAt" false) (mem "recordValueFileBound" false) (mem "registerLocalAbsIf" false) (mem "registerLocalGroupAbs" false) (mem "spineHeadEv" false) (mem "argumentAuthority" false))))
(DUse false (UseGroup ("types" "tc_occurrence") ((mem "bindingDeclaredAt" false) (mem "freshEvId" false) (mem "inferDeclaredDictAt" false) (mem "inferDictAtFound" false) (mem "inferMethodAtCell" false) (mem "inferNumLit" false) (mem "inferWideLit" false) (mem "instantiateStandaloneOccurrence" false) (mem "instantiateVarTrackedId" false) (mem "instantiateVarTrackedWithSubst" false) (mem "isGrantOnlyEv" false) (mem "markNumlitOpTaint" false) (mem "maybeStandaloneValueMono" false) (mem "methodOmittedVars" false) (mem "pushSiteGoal" false) (mem "recordBinopGoals" false) (mem "recordIfaceObligation" false) (mem "recordMethodObligationGuarded" false) (mem "recordMethodObligationOwned" false) (mem "recordNegatedLitRange" false) (mem "recordSelectedStandaloneRoutes" false) (mem "recordUnopSite" false) (mem "siteHeadCell" false) (mem "siteRouteCell" false) (mem "standaloneOccurrence" false) (mem "standaloneSchemeFor" false))))
(DUse false (UseGroup ("types" "tc_groups") ((mem "checkAnnotTooGeneral" false) (mem "checkLetGroupBindsLocated" false) (mem "checkRecBindNonFunction" false) (mem "checkRecursiveValue" false) (mem "constraintVarArgMonos" false) (mem "constraintVarIfaceMonos" false) (mem "exprLoc" false) (mem "genBindingRestricted" false) (mem "generalizeGroup" false) (mem "isNonexpansive" false) (mem "letBindGeneralizes" false) (mem "letGroupComponents" false) (mem "registerSchemeObligations" false) (mem "residualsOf" false) (mem "sccProtectedSignatureIds" false) (mem "scopeRolesOf" false) (mem "sigConstraintArgTys" false) (mem "sigConstraints" false))))
(DUse false (UseGroup ("types" "tc_pat") ((mem "closeExistentialScope" false) (mem "inferPat" false) (mem "inferPats" false) (mem "openExistentialScope" false) (mem "patOpensExistentials" false) (mem "recordLetBindType" false) (mem "recordLocalBind" false) (mem "settlePatLits" false) (mem "takeOpenedExistentials" false) (mem "takePatLits" false))))
(DUse false (UseGroup ("types" "tc_infer_records") ((mem "assignedFieldNames" false) (mem "checkMissingFields" false) (mem "fieldAssignNamePair" false) (mem "fieldSelectionWellTyped" false) (mem "firstFieldName" false) (mem "inferFieldOfRecord" false) (mem "instantiateRecordShared" false) (mem "instantiateRecordUpdate" false) (mem "recordFieldMap" false) (mem "recordFieldNames" false) (mem "recordUpdateWellTyped" false) (mem "resolveFieldRecord" false) (mem "stampedRecordHead" false) (mem "substRecordField" false) (mem "unknownRecordFresh" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "BinderId" true) (mem "DoStmt" true) (mem "EvId" true) (mem "Expr" true) (mem "FieldAssign" true) (mem "Guard" true) (mem "LetBind" true) (mem "Lit" true) (mem "Loc" true) (mem "Pat" true) (mem "Route" true) (mem "TabKey" true) (mem "Ty" true) (mem "intMinLiteralHelp" false) (mem "intMinLiteralMsg" false) (mem "isI64Head" false) (mem "isU64Head" false) (mem "letBindName" false) (mem "orElseLoc" false) (mem "taggedFixedRange" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" true) (mem "EffRow" true) (mem "collectRows" false) (mem "effrowLabels" false) (mem "joinRows" false) (mem "pureRow" false))))
(DUse false (UseGroup ("types" "repr") ((mem "AuthResidual" true) (mem "Mono" true) (mem "Scheme" true) (mem "Tyvar" true) (mem "normalize" false) (mem "ppMono" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "authDomainTop" false))))
(DUse false (UseGroup ("types" "effect_bindings") ((mem "BindingSummary" true) (mem "bodyArrows" false) (mem "bodyRowAt" false) (mem "newBindingSummary" false))))
(DUse false (UseGroup ("types" "evidence_complete") ((mem "Inner" true))))
(DUse false (UseGroup ("types" "scopes") ((mem "ScopeOwner" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omFromNames" false) (mem "omFromPairs" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omSize" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("types" "evidence") ((mem "ScopeId" true))))
(DUse false (UseGroup ("types" "publish") ((mem "TcDiag" true))))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "anyList" false) (mem "contains" false) (mem "isEmptyL" false) (mem "joinWith" false) (mem "listLen" false) (mem "zipL" false))))
(DUse false (UseGroup ("types" "effect_infer") ((mem "captureEffects" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "desugarPat" false) (mem "patHasRange" false) (mem "patUnreachable" false) (mem "renderWitness" false) (mem "useful" false) (mem "usefulWitness" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "exprSpanLoc" false))))
(DUse false (UseGroup ("types" "module_interface") ((mem "forgetLocalRows" false))))
(DUse false (UseGroup ("list") ((mem "head" false) (mem "last" false))))
(DUse false (UseGroup ("types" "effect_values") ((mem "joinProducedEnvelope" false))))
(DUse false (UseAlias ("types" "scopes") "Scopes"))
(DUse false (UseAlias ("map") "IdMap"))
(DTypeSig false "finishValueEffectsKeeping" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Bool") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "AuthResidual"))))))
(DFunDef false "finishValueEffectsKeeping" ((PVar "dyn") (PVar "generalizing")) (EBlock (DoLet false false (PVar "members") (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "generalizes") (PVar "mono"))) (ETuple (EApp (EVar "localRole") (EVar "generalizes")) (EVar "mono")))) (EVar "generalizing"))) (DoLet false false (PVar "level") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "currentLevel") "value")) (DoExpr (EIf (EApp (EApp (EVar "anyList") (EVar "fst")) (EVar "generalizing")) (EApp (EApp (EVar "settlePendingJoins") (EVar "dyn")) (EVar "level")) (EApp (EApp (EVar "postponePendingJoins") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "level")))) (DoLet false false (PVar "monos") (EApp (EApp (EVar "map") (EVar "snd")) (EVar "members"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "finishEffectSummaryScopeKeeping") (EFieldAccess (EVar "dyn") "dcModule")) (EApp (EVar "scopeRolesOf") (EVar "members"))) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "mono")) (EApp (EApp (EVar "effectRoots") (EVar "mono")) (EVar "acc")))) (EVar "Tip")) (EVar "monos"))) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "mono")) (EApp (EApp (EApp (EVar "borrowedEffectCells") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "mono")) (EVar "acc")))) (EVar "Tip")) (EVar "monos"))))))
(DTypeSig true "infer" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyCon "Mono"))))
(DFunDef false "infer" ((PVar "env") (PCon "ELit" (PVar "l"))) (EApp (EVar "litType") (EVar "l")))
(DFunDef false "infer" ((PVar "env") (PCon "ENumLit" (PVar "n") (PVar "ev") PWild)) (EApp (EApp (EApp (EVar "inferNumLit") (EVar "env")) (EVar "n")) (EVar "ev")))
(DFunDef false "infer" ((PVar "env") (PCon "EWideLit" (PVar "hi") (PVar "lo") (PVar "ev") (PVar "lx"))) (EApp (EApp (EApp (EApp (EApp (EVar "inferWideLit") (EVar "env")) (EVar "hi")) (EVar "lo")) (EVar "ev")) (EVar "lx")))
(DFunDef false "infer" ((PVar "env") (PCon "EVar" (PVar "x"))) (EApp (EApp (EVar "inferVar") (EVar "env")) (EVar "x")))
(DFunDef false "infer" ((PVar "env") (PCon "EVarId" (PVar "x") (PVar "id"))) (EApp (EApp (EApp (EVar "inferVarId") (EVar "env")) (EVar "x")) (EVar "id")))
(DFunDef false "infer" ((PVar "env") (PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EApp (EVar "inferAppExpr") (EVar "env")) (EVar "f")) (EVar "x")))
(DFunDef false "infer" ((PVar "env") (PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EVar "inferLam") (EVar "env")) (EVar "pats")) (EVar "body")))
(DFunDef false "infer" ((PVar "env") (PCon "ELet" PWild (PVar "isFun") (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "inferLet") (EVar "env")) (EVar "isFun")) (EVar "pat")) (EVar "e1")) (EVar "e2")))
(DFunDef false "infer" ((PVar "env") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EApp (EVar "inferLetGroup") (EVar "env")) (EVar "binds")) (EVar "body")))
(DFunDef false "infer" ((PVar "env") (PCon "EIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "inferIf") (EVar "env")) (EVar "c")) (EVar "t")) (EVar "e")))
(DFunDef false "infer" ((PVar "env") (PCon "EMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EApp (EVar "inferMatch") (EVar "env")) (EApp (EApp (EVar "infer") (EVar "env")) (EVar "scrut"))) (EVar "arms")))
(DFunDef false "infer" ((PVar "env") (PCon "ETuple" (PVar "es"))) (EApp (EVar "tupleMono") (EApp (EApp (EVar "inferEach") (EVar "env")) (EVar "es"))))
(DFunDef false "infer" ((PVar "env") (PCon "EListLit" (PVar "es"))) (EApp (EApp (EVar "inferListLit") (EVar "env")) (EVar "es")))
(DFunDef false "infer" ((PVar "env") (PCon "EAnnot" (PVar "e") (PVar "ty"))) (EApp (EApp (EApp (EVar "inferAnnot") (EVar "env")) (EVar "e")) (EVar "ty")))
(DFunDef false "infer" ((PVar "env") (PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") (PVar "ev"))) (EApp (EApp (EApp (EApp (EApp (EVar "inferBinopE") (EVar "env")) (EVar "op")) (EVar "l")) (EVar "r")) (EApp (EApp (EVar "siteRouteCell") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "ev"))))
(DFunDef false "infer" ((PVar "env") (PCon "EUnOp" (PVar "op") (PVar "e") (PVar "ev"))) (EApp (EApp (EApp (EApp (EVar "inferUnopE") (EApp (EApp (EVar "envAtIfSome") (EApp (EVar "exprSpanLoc") (EVar "e"))) (EVar "env"))) (EVar "op")) (EVar "e")) (EApp (EApp (EVar "siteRouteCell") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "ev"))))
(DFunDef false "infer" ((PVar "env") (PCon "EInfix" (PVar "op") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "inferInfix") (EVar "env")) (EVar "op")) (EVar "l")) (EVar "r")))
(DFunDef false "infer" ((PVar "env") (PCon "ERecordCreate" (PVar "name") (PVar "fields"))) (EApp (EApp (EApp (EVar "inferRecordCreate") (EVar "env")) (EVar "name")) (EVar "fields")))
(DFunDef false "infer" ((PVar "env") (PCon "EFieldAccess" (PVar "e") (PVar "fname") (PVar "ev"))) (EApp (EApp (EApp (EApp (EVar "inferFieldAccess") (EApp (EApp (EVar "envAtIfSome") (EApp (EVar "exprSpanLoc") (EVar "e"))) (EVar "env"))) (EVar "e")) (EVar "fname")) (EVar "ev")))
(DFunDef false "infer" ((PVar "env") (PCon "ERecordUpdate" (PVar "base") (PVar "fields") (PVar "ev"))) (EApp (EApp (EApp (EApp (EVar "inferRecordUpdate") (EVar "env")) (EVar "base")) (EVar "fields")) (EVar "ev")))
(DFunDef false "infer" ((PVar "env") (PCon "EVariantUpdate" (PVar "cname") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EApp (EVar "inferVariantUpdate") (EVar "env")) (EVar "cname")) (EVar "base")) (EVar "fields")))
(DFunDef false "infer" ((PVar "env") (PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "inferBlock") (EVar "env")) (EVar "stmts")))
(DFunDef false "infer" ((PVar "env") (PCon "EMethodAt" (PVar "name") PWild (PVar "ev"))) (EApp (EApp (EApp (EVar "inferMethodAtCell") (EVar "env")) (EVar "name")) (EApp (EApp (EVar "methodCellOf") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "ev"))))
(DFunDef false "infer" ((PVar "env") (PCon "EDictAt" (PVar "name") (PVar "ev"))) (EApp (EApp (EApp (EVar "inferGrantedAt") (EVar "env")) (EVar "name")) (EVar "ev")))
(DFunDef false "infer" ((PVar "env") (PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EVar "inferArrayLit") (EVar "env")) (EVar "es")))
(DFunDef false "infer" ((PVar "env") (PCon "ERangeList" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EApp (EApp (EVar "inferIntRange") (EVar "env")) (EVar "lo")) (EVar "hi")) (EApp (EVar "tconBuiltin") (ELit (LString "List")))))
(DFunDef false "infer" ((PVar "env") (PCon "ERangeArray" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EApp (EApp (EVar "inferIntRange") (EVar "env")) (EVar "lo")) (EVar "hi")) (EApp (EVar "tconBuiltin") (ELit (LString "Array")))))
(DFunDef false "infer" ((PVar "env") (PCon "EHeadAnnot" (PVar "e") (PVar "ty"))) (EApp (EApp (EApp (EVar "inferHeadAnnot") (EVar "env")) (EVar "e")) (EVar "ty")))
(DFunDef false "infer" ((PVar "env") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "infer") (EApp (EApp (EVar "envAt") (EApp (EVar "Some") (EVar "l"))) (EVar "env"))) (EVar "e")))
(DFunDef false "infer" ((PVar "env") (PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EBlock (DoLet false false (PVar "doCtx") (ERecordCreate "DoCtx" ((fa "doLoc" (EVar "l")) (fa "doDeferred" (EApp (EVar "doChainIsDeferred") (EVar "e"))) (fa "doReported" (EApp (EVar "Ref") (EVar "False")))))) (DoExpr (EApp (EApp (EVar "infer") (ERecordUpdate (EVar "env") ((fa "teDyn" (ERecordUpdate (EFieldAccess (EVar "env") "teDyn") ((fa "dcDo" (EApp (EVar "Some") (EVar "doCtx"))))))))) (EVar "e")))))
(DFunDef false "infer" ((PVar "env") PWild) (EApp (EVar "panic") (ELit (LString "typecheck: unsupported expression"))))
(DTypeSig false "doChainIsDeferred" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "doChainIsDeferred" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "doChainIsDeferred") (EVar "f")))
(DFunDef false "doChainIsDeferred" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "doChainIsDeferred") (EVar "e")))
(DFunDef false "doChainIsDeferred" ((PCon "EDoOrigin" PWild (PCon "EVar" (PLit (LString "deferThen"))))) (EVar "True"))
(DFunDef false "doChainIsDeferred" ((PCon "EDoOrigin" PWild (PCon "EVarId" (PLit (LString "deferThen")) PWild))) (EVar "True"))
(DFunDef false "doChainIsDeferred" (PWild) (EVar "False"))
(DTypeSig false "inferArrayLit" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Mono"))))
(DFunDef false "inferArrayLit" ((PVar "env") (PVar "es")) (EBlock (DoLet false false (PVar "elem") (EApp (EApp (EApp (EVar "joinValueTypes") (EFieldAccess (EVar "env") "teDyn")) (EVar "JoinArray")) (EApp (EApp (EVar "inferProduced") (EVar "env")) (EVar "es")))) (DoExpr (EApp (EApp (EVar "TApp") (EApp (EVar "tconBuiltin") (ELit (LString "Array")))) (EVar "elem")))))
(DTypeSig false "inferIntRange" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyCon "Mono"))))))
(DFunDef false "inferIntRange" ((PVar "env") (PVar "lo") (PVar "hi") (PVar "container")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EFieldAccess (EVar "env") "teDyn")) (EApp (EApp (EVar "infer") (EVar "env")) (EVar "lo"))) (EApp (EVar "tconBuiltin") (ELit (LString "Int"))))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EFieldAccess (EVar "env") "teDyn")) (EApp (EApp (EVar "infer") (EVar "env")) (EVar "hi"))) (EApp (EVar "tconBuiltin") (ELit (LString "Int"))))) (DoExpr (EApp (EApp (EVar "TApp") (EVar "container")) (EApp (EVar "tconBuiltin") (ELit (LString "Int")))))))
(DTypeSig false "forgetLocalAbs" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyCon "Unit"))))
(DFunDef false "forgetLocalAbs" ((PVar "gctx") (PVar "name")) (EApp (EApp (EApp (EVar "forgetLocalRows") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "localAbs")) (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (EVar "name")))
(DTypeSig false "openLocalScope" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "ScopeId"))))
(DFunDef false "openLocalScope" ((PVar "mctx") (PVar "name")) (EBlock (DoLet false false (PVar "parent") (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) (DoLet false false (PVar "sid") (EApp (EApp (EApp (EApp (EApp (EVar "Scopes.freshScope") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EApp (EVar "Some") (EVar "parent"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (EFieldAccess (EApp (EApp (EVar "Scopes.scopeFrame") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EVar "parent")) "sfModuleId")) (EApp (EVar "LocalBindingOwner") (EVar "name")))) (DoExpr (EApp (EApp (EVar "openScope") (EVar "mctx")) (EVar "sid"))) (DoExpr (EVar "sid"))))
(DTypeSig false "openLocalScopeIf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "ScopeId")))))
(DFunDef false "openLocalScopeIf" ((PVar "mctx") (PVar "name")) (EIf (EApp (EVar "isLocalAbsName") (EVar "name")) (EBlock (DoExpr (EApp (EApp (EVar "forgetLocalAbs") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "name"))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EVar "openLocalScope") (EVar "mctx")) (EVar "name"))))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "closeLocalScope" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "ScopeId")) (TyCon "Unit"))))
(DFunDef false "closeLocalScope" ((PVar "mctx") (PCon "Some" PWild)) (EApp (EApp (EVar "closeScope") (EVar "mctx")) (ELit LUnit)))
(DFunDef false "closeLocalScope" ((PVar "mctx") (PCon "None")) (ELit LUnit))
(DTypeSig false "inferLocalDictAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "Mono")))))
(DFunDef false "inferLocalDictAt" ((PVar "env") (PVar "name") (PVar "ev")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph") "graphRun") "localAbs") "lasBinders") "value")) (arm (PCon "Some" (PCon "Some" (PVar "la"))) () (EMatch (EApp (EApp (EVar "lookupVar") (EVar "env")) (EVar "name")) (arm (PCon "Some" (PVar "s")) () (EBlock (DoLet false false (PVar "inst") (EApp (EApp (EApp (EApp (EVar "instantiateVarTrackedWithSubst") (EVar "env")) (EVar "name")) (ELit (LInt 0))) (EVar "s"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushLocalDictApp") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "ev")) (EVar "la")) (EFieldAccess (EFieldAccess (EVar "inst") "mtiSubstitution") "misTypeSubst")) (EApp (EApp (EVar "captureScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit)))) (DoExpr (EFieldAccess (EVar "inst") "mtiBody")))) (arm (PCon "None") () (EApp (EApp (EVar "unboundVarFresh") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name"))))) (arm (PCon "Some" (PCon "None")) () (EApp (EApp (EApp (EVar "inferVarId") (EVar "env")) (EVar "name")) (ELit (LInt 0)))) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EApp (EVar "recordLocalRecOcc") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "ev"))) (DoExpr (EApp (EApp (EApp (EVar "inferVarId") (EVar "env")) (EVar "name")) (ELit (LInt 0))))))))
(DTypeSig false "recordLocalRecOcc" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "Unit")))))
(DFunDef false "recordLocalRecOcc" ((PVar "mctx") (PVar "name") (PVar "ev")) (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "localAbs")) (DoLet false false (PVar "occs") (EBinOp "::" (ETuple (EVar "ev") (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EFieldAccess (EVar "st") "lasRecOccs") "value"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "lasRecOccs")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EVar "occs")) (EFieldAccess (EFieldAccess (EVar "st") "lasRecOccs") "value"))))))
(DTypeSig false "inferDictAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "Mono")))))
(DFunDef false "inferDictAt" ((PVar "env") (PVar "name") (PVar "ev")) (EIf (EApp (EVar "isLocalAbsName") (EVar "name")) (EApp (EApp (EApp (EVar "inferLocalDictAt") (EVar "env")) (EVar "name")) (EVar "ev")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "inferGlobalDictAt") (EVar "env")) (EVar "name")) (EVar "ev")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "inferGlobalDictAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "Mono")))))
(DFunDef false "inferGlobalDictAt" ((PVar "env") (PVar "name") (PVar "ev")) (EMatch (EApp (EApp (EVar "lookupVar") (EVar "env")) (EVar "name")) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (ELit (LString "unbound constrained fn: ")) (EVar "name")))) (arm (PCon "Some" (PVar "scheme")) () (EBlock (DoLet false false (PVar "inst") (EApp (EApp (EApp (EVar "instantiateValueTracked") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "scheme"))) (DoLet false false (PVar "occurrence") (ETuple (EFieldAccess (EVar "inst") "mtiBody") (EFieldAccess (EFieldAccess (EVar "inst") "mtiSubstitution") "misTypeSubst"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "bindingDeclaredAt") (EVar "env")) (EVar "name")) (EVar "inst")) (arm (PCon "Some" (PVar "dc")) () (EApp (EApp (EApp (EApp (EApp (EVar "inferDeclaredDictAt") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "ev")) (EVar "dc")) (EVar "occurrence"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "inferDictAtFound") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "ev")) (EVar "occurrence")))))))))
(DTypeSig false "inferGrantedAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "Mono")))))
(DFunDef false "inferGrantedAt" ((PVar "env") (PVar "name") (PVar "ev")) (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsLastInst")) (EVar "None"))) (DoLet false false (PVar "t") (EIf (EApp (EApp (EVar "isGrantOnlyEv") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "ev")) (EApp (EApp (EApp (EVar "inferVarId") (EVar "env")) (EVar "name")) (EApp (EApp (EVar "grantOnlyBindingId") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name"))) (EApp (EApp (EApp (EVar "inferDictAt") (EVar "env")) (EVar "name")) (EVar "ev")))) (DoExpr (EMatch (EFieldAccess (EFieldAccess (EVar "st") "gsLastInst") "value") (arm (PCon "Some" (PTuple (PVar "scheme") (PVar "subst"))) () (EApp (EApp (EApp (EApp (EApp (EVar "recordGrantOcc") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "ev")) (EVar "scheme")) (EVar "subst"))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EVar "t"))))
(DTypeSig false "inferBlock" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "Mono"))))
(DFunDef false "inferBlock" ((PVar "env") (PList)) (EApp (EVar "tconBuiltin") (ELit (LString "Unit"))))
(DFunDef false "inferBlock" ((PVar "env") (PList (PVar "s"))) (EApp (EApp (EVar "inferLastStmt") (EVar "env")) (EVar "s")))
(DFunDef false "inferBlock" ((PVar "env") (PCons (PVar "s") (PVar "rest"))) (EApp (EApp (EVar "inferBlock") (EApp (EApp (EVar "inferStmt") (EVar "env")) (EVar "s"))) (EVar "rest")))
(DTypeSig false "inferLastStmt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "DoStmt") (TyCon "Mono"))))
(DFunDef false "inferLastStmt" ((PVar "env") (PCon "DoExpr" (PVar "e"))) (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e")))
(DFunDef false "inferLastStmt" ((PVar "env") (PVar "s")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "inferStmt") (EVar "env")) (EVar "s"))) (DoExpr (EApp (EVar "tconBuiltin") (ELit (LString "Unit"))))))
(DTypeSig false "inferStmt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "DoStmt") (TyCon "TcEnv"))))
(DFunDef false "inferStmt" ((PVar "outer") (PVar "s")) (EApp (EApp (EVar "envAt") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "outer") "teDyn") "dcModule") "mcLoc")) (EApp (EApp (EVar "inferStmtAt") (EApp (EApp (EVar "envAtIfSome") (EApp (EVar "stmtSpanLoc") (EVar "s"))) (EVar "outer"))) (EVar "s"))))
(DTypeSig false "stmtSpanLoc" (TyFun (TyCon "DoStmt") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "stmtSpanLoc" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "exprSpanLoc") (EVar "e")))
(DFunDef false "stmtSpanLoc" ((PCon "DoLet" PWild PWild PWild (PVar "e") PWild)) (EApp (EVar "exprSpanLoc") (EVar "e")))
(DFunDef false "stmtSpanLoc" ((PCon "DoAssign" PWild (PVar "e"))) (EApp (EVar "exprSpanLoc") (EVar "e")))
(DFunDef false "stmtSpanLoc" ((PCon "DoBind" PWild (PVar "e"))) (EApp (EVar "exprSpanLoc") (EVar "e")))
(DFunDef false "stmtSpanLoc" (PWild) (EVar "None"))
(DTypeSig false "inferStmtAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "DoStmt") (TyCon "TcEnv"))))
(DFunDef false "inferStmtAt" ((PVar "env") (PCon "DoExpr" (PVar "e"))) (EBlock (DoLet false false (PVar "oblN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls"))) (DoLet false false (PVar "t") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkStmtNotDiscarded") (EFieldAccess (EVar "env") "teDyn")) (EApp (EApp (EVar "wWindow") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls")) (EVar "oblN0"))) (EVar "t")) (EVar "e"))) (DoExpr (EVar "env"))))
(DFunDef false "inferStmtAt" ((PVar "env") (PCon "DoLet" PWild (PCon "True") (PCon "PVar" (PVar "x") (PVar "xloc") (PVar "bid")) (PVar "e") PWild)) (EApp (EApp (EApp (EApp (EApp (EVar "blockRecLet") (EVar "env")) (EVar "x")) (EApp (EVar "Some") (EVar "xloc"))) (EVar "bid")) (EVar "e")))
(DFunDef false "inferStmtAt" ((PVar "env") (PCon "DoLet" PWild PWild (PVar "pat") (PVar "e") PWild)) (EApp (EApp (EApp (EVar "blockLet") (EVar "env")) (EVar "pat")) (EVar "e")))
(DFunDef false "inferStmtAt" ((PVar "env") (PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EApp (EVar "extendLocalVar") (EVar "env")) (EVar "x")) (EApp (EVar "monoScheme") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e")))))
(DFunDef false "inferStmtAt" ((PVar "env") (PCon "DoBind" (PVar "pat") (PVar "e"))) (EBlock (DoLet false false (PVar "t") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EVar "pushTypeError") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit (LString "T-BIND-OUTSIDE-DO"))) (EVar "bindOutsideDoMsg"))) (DoLet false false (PVar "lits") (EApp (EApp (EVar "takePatLits") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "pr") (EApp (EApp (EVar "inferPat") (EVar "env")) (EVar "pat"))) (DoExpr (EApp (EApp (EApp (EVar "bindFrom") (EFieldAccess (EVar "env") "teDyn")) (EApp (EVar "fst") (EVar "pr"))) (EVar "t"))) (DoExpr (EApp (EApp (EVar "settlePatLits") (EFieldAccess (EVar "env") "teDyn")) (EVar "lits"))) (DoExpr (EApp (EApp (EVar "extendLocalVars") (EVar "env")) (EApp (EVar "snd") (EVar "pr"))))))
(DFunDef false "inferStmtAt" ((PVar "env") PWild) (EApp (EVar "panic") (ELit (LString "typecheck: unsupported block statement"))))
(DTypeSig false "checkStmtNotDiscarded" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyFun (TyCon "Mono") (TyFun (TyCon "Expr") (TyCon "Unit"))))))
(DFunDef false "checkStmtNotDiscarded" ((PVar "dyn") (PVar "stmtObls") (PVar "t") (PVar "e")) (EIf (EApp (EApp (EVar "isExemptInPlaceSetIndex") (EVar "t")) (EVar "e")) (ELit LUnit) (EIf (EVar "otherwise") (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TCon" (PLit (LString "Unit")) PWild) () (ELit LUnit)) (arm (PCon "TVar" (PVar "cell")) () (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Unbound" (PVar "id") PWild) () (EIf (EApp (EApp (EVar "containsI") (EVar "id")) (EApp (EVar "numConstrainedIds") (EVar "stmtObls"))) (EApp (EApp (EApp (EVar "pushDiscardedValueDesc") (EFieldAccess (EVar "dyn") "dcModule")) (ELit (LString "a number"))) (EVar "e")) (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "t")) (EApp (EVar "tconBuiltin") (ELit (LString "Unit")))))) (arm (PCon "Link" PWild) () (EApp (EVar "panic") (ELit (LString "checkStmtNotDiscarded: normalize left a Link")))))) (arm (PVar "nt") () (EApp (EApp (EApp (EVar "pushDiscardedValueError") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "nt")) (EVar "e")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "stmtCalleeName" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "stmtCalleeName" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "stmtCalleeName") (EVar "e")))
(DFunDef false "stmtCalleeName" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "stmtCalleeName") (EVar "e")))
(DFunDef false "stmtCalleeName" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "stmtCalleeName") (EVar "e")))
(DFunDef false "stmtCalleeName" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "stmtCalleeName") (EVar "f")))
(DFunDef false "stmtCalleeName" ((PCon "EVar" (PVar "n"))) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "stmtCalleeName" ((PCon "EVarId" (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "stmtCalleeName" ((PCon "EVarAt" (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "stmtCalleeName" ((PCon "EMethodRef" (PVar "n"))) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "stmtCalleeName" ((PCon "EMethodAt" (PVar "n") PWild PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "stmtCalleeName" ((PCon "EDictAt" (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "stmtCalleeName" (PWild) (EVar "None"))
(DTypeSig false "exemptInPlaceIndexMutHeads" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "exemptInPlaceIndexMutHeads" () (EListLit (ELit (LString "Array")) (ELit (LString "Vector"))))
(DTypeSig false "isExemptInPlaceSetIndex" (TyFun (TyCon "Mono") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "isExemptInPlaceSetIndex" ((PVar "t") (PVar "e")) (EMatch (EApp (EVar "headTyconNameMono") (EVar "t")) (arm (PCon "Some" (PVar "hd")) () (EBinOp "&&" (EBinOp "==" (EApp (EVar "stmtCalleeName") (EVar "e")) (EApp (EVar "Some") (ELit (LString "setIndex")))) (EApp (EApp (EVar "contains") (EVar "hd")) (EVar "exemptInPlaceIndexMutHeads")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "pushDiscardedValueError" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Expr") (TyCon "Unit")))))
(DFunDef false "pushDiscardedValueError" ((PVar "mctx") (PVar "nt") (PVar "e")) (EApp (EApp (EApp (EVar "pushDiscardedValueDesc") (EVar "mctx")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EApp (EVar "ppMono") (EVar "nt")))) (ELit (LString "`")))) (EVar "e")))
(DTypeSig false "pushDiscardedValueDesc" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Unit")))))
(DFunDef false "pushDiscardedValueDesc" ((PVar "mctx") (PVar "desc") (PVar "e")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushTypeErrorHelpFixAt") (EVar "mctx")) (ELit (LString "T-DISCARDED-VALUE"))) (EApp (EVar "exprSpanLoc") (EVar "e"))) (EApp (EVar "discardedValueMsg") (EVar "desc"))) (ELit (LString "bind it with `let _ = ...` if dropping the value is intentional"))) (EApp (EVar "discardedValueFix") (EApp (EVar "exprLoc") (EVar "e")))))
(DTypeSig false "blockRecLet" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "BinderId") (TyFun (TyCon "Expr") (TyCon "TcEnv")))))))
(DFunDef false "blockRecLet" ((PVar "env") (PVar "x") (PVar "xloc") (PVar "bid") (PVar "e")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "checkRecBindNonFunction") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EVar "e"))) (DoExpr (EApp (EApp (EVar "enterLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "oblN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls"))) (DoLet false false (PVar "callN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "obls"))) (DoLet false false (PVar "dictN0") (EApp (EApp (EVar "goalsMark") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (DoLet false false (PVar "lscope") (EApp (EApp (EVar "openLocalScopeIf") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x"))) (DoLet false false (PTuple (PVar "t1") (PVar "residuals")) (EApp (EApp (EApp (EVar "inferRecursiveValue") (EVar "env")) (EVar "x")) (EVar "e"))) (DoExpr (EApp (EApp (EVar "closeLocalScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "lscope"))) (DoExpr (EApp (EApp (EVar "exitLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "addedObls") (EApp (EApp (EVar "wWindow") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls")) (EVar "oblN0"))) (DoExpr (EApp (EApp (EApp (EVar "improveLocalGoals") (EFieldAccess (EVar "env") "teDyn")) (EVar "addedObls")) (EVar "callN0"))) (DoLet false false PWild (EApp (EApp (EVar "finalizeNumBoundary") (EFieldAccess (EVar "env") "teDyn")) (ERecordCreate "NumBoundary" ((fa "nbDisposition" (EApp (EVar "NumBoundaryOwnedMember") (EBinOp "+" (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentLevel") "value") (ELit (LInt 1))))) (fa "nbMembers" (EListLit (EVar "t1"))) (fa "nbSurvivingIds" (EApp (EApp (EApp (EApp (EVar "memberTiedSurvivors") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "t1")) (EVar "addedObls")) (EVar "callN0"))) (fa "nbDefaultObls" (EVar "addedObls")) (fa "nbAmbiguityObls" (EVar "addedObls")) (fa "nbGuard" (EApp (EApp (EApp (EVar "localNumGuard") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "addedObls")) (EVar "callN0"))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordLocalBind") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EVar "xloc")) (EVar "bid")) (EVar "t1"))) (DoLet false false (PVar "sch") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "genBindingRestricted") (EFieldAccess (EVar "env") "teDyn")) (EVar "Tip")) (EApp (EApp (EVar "residualsOf") (ELit (LInt 0))) (EVar "residuals"))) (EVar "True")) (EVar "pureRow")) (EVar "t1"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerLocalScheme") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EVar "sch")) (EVar "oblN0")) (EVar "callN0")) (EVar "dictN0"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerLocalAbsIf") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EVar "lscope")) (EVar "sch")) (EVar "oblN0")) (EVar "callN0"))) (DoExpr (EApp (EApp (EApp (EVar "seedAlphaLets") (EApp (EApp (EApp (EVar "extendLocalVar") (EVar "env")) (EVar "x")) (EVar "sch"))) (EVar "x")) (EVar "e")))))
(DTypeSig false "blockLet" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyCon "TcEnv")))))
(DFunDef false "blockLet" ((PVar "env") (PCon "PVar" (PVar "x") (PVar "xloc") (PVar "bid")) (PVar "e")) (EBlock (DoExpr (EApp (EApp (EVar "enterLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "beginEffectSummaryScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "oblN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls"))) (DoLet false false (PVar "callN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "obls"))) (DoLet false false (PVar "dictN0") (EApp (EApp (EVar "goalsMark") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (DoLet false false (PVar "lscope") (EApp (EApp (EVar "openLocalScopeIf") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x"))) (DoLet false false (PVar "t") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e"))) (DoExpr (EApp (EApp (EVar "closeLocalScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "lscope"))) (DoLet false false (PVar "residuals") (EApp (EApp (EVar "finishValueEffectsKeeping") (EFieldAccess (EVar "env") "teDyn")) (EListLit (ETuple (EApp (EApp (EVar "isNonexpansive") (EVar "env")) (EVar "e")) (EVar "t"))))) (DoExpr (EApp (EApp (EVar "exitLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "addedObls") (EApp (EApp (EVar "wWindow") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls")) (EVar "oblN0"))) (DoExpr (EApp (EApp (EApp (EVar "improveLocalGoals") (EFieldAccess (EVar "env") "teDyn")) (EVar "addedObls")) (EVar "callN0"))) (DoLet false false PWild (EApp (EApp (EVar "finalizeNumBoundary") (EFieldAccess (EVar "env") "teDyn")) (ERecordCreate "NumBoundary" ((fa "nbDisposition" (EApp (EVar "NumBoundaryOwnedMember") (EBinOp "+" (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentLevel") "value") (ELit (LInt 1))))) (fa "nbMembers" (EListLit (EVar "t"))) (fa "nbSurvivingIds" (EApp (EApp (EApp (EApp (EVar "memberTiedSurvivors") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "t")) (EVar "addedObls")) (EVar "callN0"))) (fa "nbDefaultObls" (EVar "addedObls")) (fa "nbAmbiguityObls" (EVar "addedObls")) (fa "nbGuard" (EApp (EApp (EApp (EVar "localNumGuard") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "addedObls")) (EVar "callN0"))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordLocalBind") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EApp (EVar "Some") (EVar "xloc"))) (EVar "bid")) (EVar "t"))) (DoLet false false (PVar "sch") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "genBindingRestricted") (EFieldAccess (EVar "env") "teDyn")) (EVar "Tip")) (EApp (EApp (EVar "residualsOf") (ELit (LInt 0))) (EVar "residuals"))) (EApp (EApp (EVar "isNonexpansive") (EVar "env")) (EVar "e"))) (EVar "pureRow")) (EVar "t"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerLocalScheme") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EVar "sch")) (EVar "oblN0")) (EVar "callN0")) (EVar "dictN0"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerLocalAbsIf") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EVar "lscope")) (EVar "sch")) (EVar "oblN0")) (EVar "callN0"))) (DoExpr (EApp (EApp (EApp (EVar "seedAlphaLets") (EApp (EApp (EApp (EVar "extendLocalVar") (EVar "env")) (EVar "x")) (EVar "sch"))) (EVar "x")) (EVar "e")))))
(DFunDef false "blockLet" ((PVar "env") (PVar "pat") (PVar "e")) (EBlock (DoLet false false (PVar "t") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e"))) (DoLet false false (PVar "lits") (EApp (EApp (EVar "takePatLits") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "pr") (EApp (EApp (EVar "inferPat") (EVar "env")) (EVar "pat"))) (DoExpr (EApp (EApp (EApp (EVar "bindFrom") (EFieldAccess (EVar "env") "teDyn")) (EApp (EVar "fst") (EVar "pr"))) (EVar "t"))) (DoExpr (EApp (EApp (EVar "settlePatLits") (EFieldAccess (EVar "env") "teDyn")) (EVar "lits"))) (DoExpr (EApp (EApp (EApp (EVar "checkBinderPat") (EVar "env")) (EApp (EVar "fst") (EVar "pr"))) (EVar "pat"))) (DoExpr (EApp (EApp (EVar "extendLocalVars") (EVar "env")) (EApp (EVar "snd") (EVar "pr"))))))
(DTypeSig false "inferRecordCreate" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyCon "Mono")))))
(DFunDef false "inferRecordCreate" ((PVar "env") (PVar "name") (PVar "fields")) (EMatch (EApp (EApp (EVar "lookupRecordByName") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (arm (PCon "None") () (EApp (EApp (EVar "unknownRecordFresh") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name"))) (arm (PCon "Some" (PVar "ri")) () (EApp (EApp (EApp (EApp (EVar "inferRecordCreateWith") (EVar "env")) (EVar "name")) (EVar "ri")) (EVar "fields")))))
(DTypeSig false "inferRecordCreateWith" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "RecordInfo") (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyCon "Mono"))))))
(DFunDef false "inferRecordCreateWith" ((PVar "env") (PVar "rname") (PVar "ri") (PVar "fields")) (EBlock (DoLet false false (PVar "sr") (EApp (EApp (EVar "instantiateRecordShared") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "ri"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkMissingFields") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "rname")) (EApp (EVar "recordFieldNames") (EVar "ri"))) (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EVar "map") (EVar "fieldAssignNamePair")) (EVar "fields"))) (EVar "omEmpty")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "unifyFieldAssignsIdx") (EVar "env")) (EVar "rname")) (EVar "ri")) (EApp (EVar "fst") (EVar "sr"))) (EVar "fields"))) (DoExpr (EApp (EVar "snd") (EVar "sr")))))
(DTypeSig false "unifyFieldAssignsIdx" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "RecordInfo") (TyFun (TyCon "RecordSubst") (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyCon "Unit")))))))
(DFunDef false "unifyFieldAssignsIdx" ((PVar "env") PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "unifyFieldAssignsIdx" ((PVar "env") (PVar "rname") (PVar "ri") (PVar "subst") (PCons (PCon "FieldAssign" (PVar "fn") (PVar "val")) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "unifyFieldAssignIdx") (EVar "env")) (EVar "rname")) (EVar "ri")) (EVar "subst")) (EVar "fn")) (EVar "val"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "unifyFieldAssignsIdx") (EVar "env")) (EVar "rname")) (EVar "ri")) (EVar "subst")) (EVar "rest")))))
(DTypeSig false "unifyFieldAssignIdx" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "RecordInfo") (TyFun (TyCon "RecordSubst") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Unit"))))))))
(DFunDef false "unifyFieldAssignIdx" ((PVar "env") (PVar "rname") (PVar "ri") (PVar "subst") (PVar "fn") (PVar "val")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "fn")) (EApp (EVar "recordFieldMap") (EVar "ri"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "pushTypeError") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit (LString "T-UNKNOWN-FIELD"))) (EApp (EApp (EVar "unknownFieldMsg") (EVar "fn")) (EVar "rname")))) (arm (PCon "Some" (PVar "fm")) () (EBlock (DoLet false false (PVar "at") (EApp (EApp (EVar "envAtIfSome") (EApp (EVar "exprSpanLoc") (EVar "val"))) (EVar "env"))) (DoLet false false (PVar "vt") (EApp (EApp (EVar "infer") (EVar "at")) (EVar "val"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "argumentIntoOrd") (EVar "True")) (EVar "at")) (EApp (EVar "Some") (EVar "val"))) (EApp (EApp (EApp (EVar "substRecordField") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "subst")) (EVar "fm"))) (EVar "vt")))))))
(DTypeSig false "inferFieldAccess" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "Mono"))))))
(DFunDef false "inferFieldAccess" ((PVar "env") (PVar "e") (PVar "fname") (PVar "ev")) (EIf (EBinOp "==" (EVar "fname") (ELit (LString "value"))) (EApp (EApp (EVar "inferValueField") (EVar "env")) (EVar "e")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "te") (EApp (EVar "normalize") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "resolveFieldRecord") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "te")) (EVar "fname")) (arm (PCon "None") () (EApp (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (arm (PCon "Some" (PTuple (PVar "rname") (PVar "ri"))) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EApp (EApp (EVar "siteHeadCell") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "ev"))) (EApp (EApp (EVar "stampedRecordHead") (EVar "rname")) (EVar "ri")))) (DoLet false false (PVar "ft") (EApp (EApp (EApp (EApp (EApp (EVar "inferFieldOfRecord") (EFieldAccess (EVar "env") "teDyn")) (EVar "te")) (EVar "rname")) (EVar "ri")) (EVar "fname"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fieldSelectionWellTyped") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "te")) (EVar "rname")) (EVar "ri")) (EVar "fname")) (EVar "ft")))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "inferValueField" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyCon "Mono"))))
(DFunDef false "inferValueField" ((PVar "env") (PVar "e")) (EApp (EApp (EVar "refStored") (EFieldAccess (EVar "env") "teDyn")) (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e"))))
(DTypeSig false "unboundVarFresh" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Mono"))))
(DFunDef false "unboundVarFresh" ((PVar "mctx") (PVar "name")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-UNBOUND"))) (EApp (EVar "unboundVarMsg") (EVar "name")))) (DoExpr (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit)))))
(DTypeSig false "inferRecordUpdate" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyFun (TyCon "EvId") (TyCon "Mono"))))))
(DFunDef false "inferRecordUpdate" ((PVar "env") (PVar "base") (PVar "fields") (PVar "ev")) (EMatch (EApp (EVar "firstFieldName") (EVar "fields")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "empty record update")))) (arm (PCon "Some" (PVar "fn")) () (EApp (EApp (EApp (EApp (EApp (EVar "inferRecordUpdateField") (EVar "env")) (EVar "base")) (EVar "fields")) (EVar "fn")) (EVar "ev")))))
(DTypeSig false "inferVariantUpdate" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyCon "Mono"))))))
(DFunDef false "inferVariantUpdate" ((PVar "env") (PVar "cname") (PVar "base") (PVar "fields")) (EMatch (EApp (EApp (EVar "lookupRecordByName") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "cname")) (arm (PCon "None") () (EApp (EApp (EVar "unknownRecordFresh") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "cname"))) (arm (PCon "Some" (PVar "ri")) () (EApp (EApp (EApp (EApp (EApp (EVar "inferRecordUpdateWith") (EVar "env")) (EVar "cname")) (EVar "base")) (EVar "fields")) (EVar "ri")))))
(DTypeSig false "inferRecordUpdateField" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "Mono")))))))
(DFunDef false "inferRecordUpdateField" ((PVar "env") (PVar "base") (PVar "fields") (PVar "fn") (PVar "ev")) (EBlock (DoLet false false (PVar "bt") (EApp (EVar "normalize") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "base")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "resolveFieldRecord") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "bt")) (EVar "fn")) (arm (PCon "None") () (EApp (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (arm (PCon "Some" (PTuple (PVar "rname") (PVar "ri"))) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EApp (EApp (EVar "siteHeadCell") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "ev"))) (EApp (EApp (EVar "stampedRecordHead") (EVar "rname")) (EVar "ri")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "inferRecordUpdatePicked") (EVar "rname")) (EVar "bt")) (EVar "env")) (EVar "fields")) (EVar "ri")))))))))
(DTypeSig false "inferRecordUpdatePicked" (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyFun (TyCon "RecordInfo") (TyCon "Mono")))))))
(DFunDef false "inferRecordUpdatePicked" ((PVar "rname") (PVar "bt") (PVar "env") (PVar "fields") (PVar "ri")) (EBlock (DoLet false false (PVar "sr") (EApp (EApp (EApp (EApp (EVar "instantiateRecordUpdate") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "rname")) (EVar "ri")) (EApp (EVar "assignedFieldNames") (EVar "fields")))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EFieldAccess (EVar "env") "teDyn")) (EVar "bt")) (EApp (EVar "snd") (EVar "sr")))) (DoExpr (EMatch (EApp (EVar "firstFieldName") (EVar "fields")) (arm (PCon "Some" (PVar "fn")) () (EApp (EApp (EApp (EApp (EApp (EVar "recordUpdateWellTyped") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "bt")) (EVar "rname")) (EVar "ri")) (EVar "fn"))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "unifyFieldAssignsIdx") (EVar "env")) (EVar "rname")) (EVar "ri")) (EApp (EVar "fst") (EVar "sr"))) (EVar "fields"))) (DoExpr (EApp (EVar "snd") (EVar "sr")))))
(DTypeSig false "inferRecordUpdateWith" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyFun (TyCon "RecordInfo") (TyCon "Mono")))))))
(DFunDef false "inferRecordUpdateWith" ((PVar "env") (PVar "rname") (PVar "base") (PVar "fields") (PVar "ri")) (EBlock (DoLet false false (PVar "sr") (EApp (EApp (EApp (EApp (EVar "instantiateRecordUpdate") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "rname")) (EVar "ri")) (EApp (EVar "assignedFieldNames") (EVar "fields")))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EFieldAccess (EVar "env") "teDyn")) (EApp (EApp (EVar "infer") (EVar "env")) (EVar "base"))) (EApp (EVar "snd") (EVar "sr")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "unifyFieldAssignsIdx") (EVar "env")) (EVar "rname")) (EVar "ri")) (EApp (EVar "fst") (EVar "sr"))) (EVar "fields"))) (DoExpr (EApp (EVar "snd") (EVar "sr")))))
(DTypeSig false "inferBinopE" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyCon "Mono")))))))
(DFunDef false "inferBinopE" ((PVar "env") (PVar "op") (PVar "l") (PVar "r") (PVar "dref")) (EBlock (DoLet false false (PVar "lt") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "l"))) (DoLet false false (PVar "rt") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "r"))) (DoLet false false (PVar "at") (EApp (EApp (EVar "envAtIfSome") (EApp (EApp (EVar "binopSpanLoc") (EVar "l")) (EVar "r"))) (EVar "env"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordBinopGoals") (EFieldAccess (EFieldAccess (EVar "at") "teDyn") "dcModule")) (EVar "op")) (EVar "dref")) (EVar "lt"))) (DoExpr (EIf (EBinOp "==" (EVar "op") (ELit (LString "|>"))) (EApp (EApp (EApp (EApp (EApp (EVar "pipeOp") (EVar "at")) (EVar "l")) (EVar "r")) (EVar "lt")) (EVar "rt")) (EApp (EApp (EApp (EApp (EVar "inferBinop") (EFieldAccess (EVar "at") "teDyn")) (EVar "op")) (EVar "lt")) (EVar "rt"))))))
(DTypeSig false "binopSpanLoc" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "binopSpanLoc" ((PVar "l") (PVar "r")) (EMatch (ETuple (EApp (EVar "exprLoc") (EVar "l")) (EApp (EVar "exprLoc") (EVar "r"))) (arm (PTuple (PCon "Some" (PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") PWild PWild)) (PCon "Some" (PCon "Loc" PWild PWild PWild (PVar "el") (PVar "ec")))) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec")))) (arm (PTuple (PCon "Some" (PVar "ll")) (PCon "None")) () (EApp (EVar "Some") (EVar "ll"))) (arm (PTuple (PCon "None") (PCon "Some" (PVar "rr"))) () (EApp (EVar "Some") (EVar "rr"))) (arm (PTuple (PCon "None") (PCon "None")) () (EVar "None"))))
(DTypeSig false "inferUnopE" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyCon "Mono"))))))
(DFunDef false "inferUnopE" ((PVar "env") (PVar "op") (PVar "e") (PVar "dref")) (EBlock (DoLet false false (PVar "t") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordUnopSite") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "op")) (EVar "dref")) (EVar "t"))) (DoExpr (EIf (EBinOp "==" (EVar "op") (ELit (LString "-"))) (EApp (EApp (EApp (EVar "recordNegatedLitRange") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "t")) (EVar "e")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "inferUnop") (EFieldAccess (EVar "env") "teDyn")) (EVar "op")) (EVar "t")))))
(DTypeSig false "inferBinop" (TyFun (TyCon "DynCtx") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Mono"))))))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString "+")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EVar "numArithOp") (EVar "dyn")) (EVar "lt")) (EVar "rt")))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString "-")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EVar "numArithOp") (EVar "dyn")) (EVar "lt")) (EVar "rt")))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString "*")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EVar "numArithOp") (EVar "dyn")) (EVar "lt")) (EVar "rt")))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString "/")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EVar "numArithOp") (EVar "dyn")) (EVar "lt")) (EVar "rt")))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString "%")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EVar "numArithOp") (EVar "dyn")) (EVar "lt")) (EVar "rt")))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString "++")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EVar "appendOp") (EVar "dyn")) (EVar "lt")) (EVar "rt")))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString "==")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EVar "eqCompareOp") (EVar "dyn")) (EVar "lt")) (EVar "rt")))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString "/=")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EVar "eqCompareOp") (EVar "dyn")) (EVar "lt")) (EVar "rt")))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString "<")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EVar "ordCompareOp") (EVar "dyn")) (EVar "lt")) (EVar "rt")))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString ">")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EVar "ordCompareOp") (EVar "dyn")) (EVar "lt")) (EVar "rt")))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString "<=")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EVar "ordCompareOp") (EVar "dyn")) (EVar "lt")) (EVar "rt")))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString ">=")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EVar "ordCompareOp") (EVar "dyn")) (EVar "lt")) (EVar "rt")))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString "&&")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EVar "boolOp") (EVar "dyn")) (EVar "lt")) (EVar "rt")))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString "||")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EVar "boolOp") (EVar "dyn")) (EVar "lt")) (EVar "rt")))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString "::")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EVar "consOp") (EVar "dyn")) (EVar "lt")) (EVar "rt")))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString ">>")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EApp (EVar "composeOp") (EVar "dyn")) (EVar "lt")) (EVar "rt")) (EVar "False")))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString "<<")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EApp (EVar "composeOp") (EVar "dyn")) (EVar "lt")) (EVar "rt")) (EVar "True")))
(DFunDef false "inferBinop" ((PVar "dyn") (PVar "op") PWild PWild) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "typecheck: unsupported operator ")) (EVar "op"))))
(DTypeSig false "appendOp" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Mono")))))
(DFunDef false "appendOp" ((PVar "dyn") (PVar "lt") (PVar "rt")) (EBlock (DoLet false false (PVar "plain") (EApp (EVar "peelQual") (EVar "lt"))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "plain")) (EVar "rt"))) (DoExpr (EApp (EApp (EApp (EVar "recordIfaceObligation") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "BSemigroup")) (EVar "plain"))) (DoExpr (EVar "plain"))))
(DTypeSig false "numArithOp" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Mono")))))
(DFunDef false "numArithOp" ((PVar "dyn") (PVar "lt") (PVar "rt")) (EBlock (DoExpr (EApp (EApp (EVar "markNumlitOpTaint") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "lt"))) (DoExpr (EApp (EApp (EVar "markNumlitOpTaint") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "rt"))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "lt")) (EVar "rt"))) (DoExpr (EApp (EApp (EApp (EVar "recordIfaceObligation") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "BNum")) (EVar "lt"))) (DoExpr (EVar "lt"))))
(DTypeSig false "wideFitsI64" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "Bool")))))
(DFunDef false "wideFitsI64" ((PVar "hi") (PVar "lo") (PVar "negated")) (EBinOp "||" (EBinOp "<" (EVar "hi") (ELit (LInt 2147483648))) (EBinOp "&&" (EBinOp "&&" (EVar "negated") (EBinOp "==" (EVar "hi") (ELit (LInt 2147483648)))) (EBinOp "==" (EVar "lo") (ELit (LInt 0))))))
(DTypeSig true "checkWideLiterals" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "String") (TyCon "Int") (TyCon "Int") (TyCon "Bool") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyCon "Unit"))))
(DFunDef false "checkWideLiterals" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "checkWideLiterals" ((PVar "mctx") (PCons (PTuple (PVar "m") (PVar "lx") (PVar "hi") (PVar "lo") (PVar "negated") (PVar "loc")) (PVar "rest"))) (EBlock (DoLet false false (PVar "at") (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EFieldAccess (EVar "mctx") "mcLoc"))) (DoLet false false (PVar "shown") (EIf (EVar "negated") (EBinOp "++" (ELit (LString "-")) (EVar "lx")) (EVar "lx"))) (DoLet false false (PVar "pow62") (EBinOp "&&" (EBinOp "==" (EVar "hi") (ELit (LInt 1073741824))) (EBinOp "==" (EVar "lo") (ELit (LInt 0))))) (DoExpr (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TCon" (PLit (LString "Int")) PWild) ((GBool (EBinOp "&&" (EVar "pow62") (EApp (EVar "not") (EVar "negated"))))) (EApp (EApp (EVar "recordTypeError") (EVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "L-INT-OVERFLOW"))) (ELit (LInt 1))) (EVar "at")) (EVar "intMinLiteralMsg")) (EApp (EVar "Some") (EVar "intMinLiteralHelp"))) (EVar "None")))) (arm (PCon "TCon" (PVar "tag") PWild) ((GBool (EApp (EVar "isU64Head") (EVar "tag")))) (EIf (EVar "negated") (EApp (EApp (EVar "recordTypeError") (EVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "L-INT-OVERFLOW"))) (ELit (LInt 1))) (EVar "at")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "integer literal ")) (EApp (EVar "display") (EVar "shown"))) (ELit (LString " does not fit U64 ("))) (EApp (EVar "display") (EVar "u64RangeText"))) (ELit (LString ")")))) (EVar "None")) (EVar "None"))) (ELit LUnit))) (arm (PCon "TCon" (PVar "tag") PWild) ((GBool (EApp (EVar "isI64Head") (EVar "tag")))) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EVar "wideFitsI64") (EVar "hi")) (EVar "lo")) (EVar "negated"))) (EApp (EApp (EVar "recordTypeError") (EVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "L-INT-OVERFLOW"))) (ELit (LInt 1))) (EVar "at")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "integer literal ")) (EApp (EVar "display") (EVar "shown"))) (ELit (LString " does not fit I64 ("))) (EApp (EVar "display") (EVar "i64RangeText"))) (ELit (LString ")")))) (EVar "None")) (EVar "None"))) (ELit LUnit))) (arm (PCon "TCon" (PVar "tag") PWild) () (EApp (EApp (EVar "recordTypeError") (EVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "L-INT-OVERFLOW"))) (ELit (LInt 1))) (EVar "at")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "integer literal ")) (EApp (EVar "display") (EVar "shown"))) (ELit (LString " does not fit "))) (EApp (EVar "display") (EVar "tag"))) (ELit (LString "")))) (EApp (EVar "Some") (ELit (LString "only a `U64` or an `I64` holds a literal above 2^62")))) (EVar "None")))) (arm PWild () (EApp (EApp (EVar "recordTypeError") (EVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "L-INT-OVERFLOW"))) (ELit (LInt 1))) (EVar "at")) (EBinOp "++" (EBinOp "++" (ELit (LString "integer literal ")) (EApp (EVar "display") (EVar "shown"))) (ELit (LString " fits only `U64` or `I64`, and its type here is undetermined")))) (EApp (EVar "Some") (EApp (EApp (EVar "wideAnnotateHelp") (EVar "shown")) (EVar "negated")))) (EVar "None")))))) (DoExpr (EApp (EApp (EVar "checkWideLiterals") (EVar "mctx")) (EVar "rest")))))
(DTypeSig true "checkFixedWidthLiterals" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyCon "Unit"))))
(DFunDef false "checkFixedWidthLiterals" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "checkFixedWidthLiterals" ((PVar "mctx") (PCons (PTuple (PVar "m") (PVar "n") (PVar "loc")) (PVar "rest"))) (EBlock (DoExpr (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TCon" (PVar "tag") PWild) () (EMatch (EApp (EVar "taggedFixedRange") (EVar "tag")) (arm (PCon "Some" (PTuple (PVar "lo") (PVar "hi"))) () (EIf (EBinOp "||" (EBinOp "<" (EVar "n") (EVar "lo")) (EBinOp ">" (EVar "n") (EVar "hi"))) (EApp (EApp (EVar "recordTypeError") (EVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "L-INT-OVERFLOW"))) (ELit (LInt 1))) (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EFieldAccess (EVar "mctx") "mcLoc"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "integer literal ")) (EApp (EVar "display") (EVar "n"))) (ELit (LString " does not fit "))) (EApp (EVar "display") (EVar "tag"))) (ELit (LString " ("))) (EApp (EVar "display") (EVar "lo"))) (ELit (LString ".."))) (EApp (EVar "display") (EVar "hi"))) (ELit (LString ")")))) (EVar "None")) (EVar "None"))) (ELit LUnit))) (arm (PCon "None") () (EIf (EBinOp "&&" (EApp (EVar "isU64Head") (EVar "tag")) (EBinOp "<" (EVar "n") (ELit (LInt 0)))) (EApp (EApp (EVar "recordTypeError") (EVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "L-INT-OVERFLOW"))) (ELit (LInt 1))) (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EFieldAccess (EVar "mctx") "mcLoc"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "integer literal ")) (EApp (EVar "display") (EVar "n"))) (ELit (LString " does not fit U64 ("))) (EApp (EVar "display") (EVar "u64RangeText"))) (ELit (LString ")")))) (EVar "None")) (EVar "None"))) (ELit LUnit))))) (arm PWild () (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "checkFixedWidthLiterals") (EVar "mctx")) (EVar "rest")))))
(DTypeSig false "eqCompareOp" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Mono")))))
(DFunDef false "eqCompareOp" ((PVar "dyn") (PVar "lt") (PVar "rt")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "lt")) (EVar "rt"))) (DoExpr (EApp (EApp (EApp (EVar "recordIfaceObligation") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "BEq")) (EVar "lt"))) (DoExpr (EApp (EVar "tconBuiltin") (ELit (LString "Bool"))))))
(DTypeSig false "ordCompareOp" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Mono")))))
(DFunDef false "ordCompareOp" ((PVar "dyn") (PVar "lt") (PVar "rt")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "lt")) (EVar "rt"))) (DoExpr (EApp (EApp (EApp (EVar "recordIfaceObligation") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "BOrd")) (EVar "lt"))) (DoExpr (EApp (EVar "tconBuiltin") (ELit (LString "Bool"))))))
(DTypeSig false "boolOp" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Mono")))))
(DFunDef false "boolOp" ((PVar "dyn") (PVar "lt") (PVar "rt")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "lt")) (EApp (EVar "tconBuiltin") (ELit (LString "Bool"))))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "rt")) (EApp (EVar "tconBuiltin") (ELit (LString "Bool"))))) (DoExpr (EApp (EVar "tconBuiltin") (ELit (LString "Bool"))))))
(DTypeSig false "consOp" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Mono")))))
(DFunDef false "consOp" ((PVar "dyn") (PVar "lt") (PVar "rt")) (EBlock (DoLet false false (PVar "tailElem") (EApp (EApp (EVar "freshVar") (EFieldAccess (EVar "dyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EVar "noteNumlitCtx") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "lt")) (EVar "rt")) (EVar "JoinCons"))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "rt")) (EApp (EApp (EVar "TApp") (EApp (EVar "tconBuiltin") (ELit (LString "List")))) (EVar "tailElem")))) (DoExpr (EApp (EApp (EVar "TApp") (EApp (EVar "tconBuiltin") (ELit (LString "List")))) (EApp (EApp (EApp (EVar "joinValueTypes") (EVar "dyn")) (EVar "JoinCons")) (EListLit (ETuple (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcLoc") (EVar "lt")) (ETuple (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcLoc") (EVar "tailElem"))))))))
(DTypeSig false "pipeOp" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Mono")))))))
(DFunDef false "pipeOp" ((PVar "env") (PVar "l") (PVar "r") (PVar "lt") (PVar "rt")) (EBlock (DoLet false false (PVar "res") (EApp (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "eff") (EApp (EApp (EApp (EApp (EApp (EVar "applicationRow") (EVar "env")) (EApp (EApp (EVar "EApp") (EVar "r")) (EVar "l"))) (EVar "rt")) (EVar "lt")) (EVar "res"))) (DoExpr (EApp (EApp (EApp (EVar "performEffect") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "curEffect")) (EVar "eff"))) (DoExpr (EApp (EApp (EVar "notePerformSite") (EVar "env")) (EVar "eff"))) (DoExpr (EVar "res"))))
(DTypeSig false "composeOp" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyFun (TyCon "Bool") (TyCon "Mono"))))))
(DFunDef false "composeOp" ((PVar "dyn") (PVar "gt") (PVar "ht") (PCon "False")) (EBlock (DoLet false false (PTuple (PVar "a") (PVar "first") (PVar "b")) (EApp (EApp (EVar "calleeArrow") (EVar "dyn")) (EVar "gt"))) (DoLet false false (PVar "c") (EApp (EApp (EVar "freshVar") (EFieldAccess (EVar "dyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "second") (EApp (EApp (EApp (EApp (EVar "applicationRowTyped") (EVar "dyn")) (EVar "ht")) (EVar "b")) (EVar "c"))) (DoExpr (EApp (EApp (EApp (EVar "TFun") (EVar "a")) (EApp (EApp (EApp (EVar "joinRows") (EApp (EVar "joinCellOf") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph"))) (EVar "first")) (EVar "second"))) (EVar "c")))))
(DFunDef false "composeOp" ((PVar "dyn") (PVar "gt") (PVar "ht") (PCon "True")) (EApp (EApp (EApp (EApp (EVar "composeOp") (EVar "dyn")) (EVar "ht")) (EVar "gt")) (EVar "False")))
(DTypeSig false "inferUnop" (TyFun (TyCon "DynCtx") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyCon "Mono")))))
(DFunDef false "inferUnop" ((PVar "dyn") (PLit (LString "-")) (PVar "t")) (EApp (EApp (EVar "negateOp") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "t")))
(DFunDef false "inferUnop" ((PVar "dyn") (PLit (LString "!")) (PVar "t")) (EApp (EApp (EVar "derefOp") (EVar "dyn")) (EVar "t")))
(DFunDef false "inferUnop" ((PVar "dyn") (PVar "op") PWild) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "typecheck: unsupported unary op ")) (EVar "op"))))
(DTypeSig false "derefOp" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyCon "Mono"))))
(DFunDef false "derefOp" ((PVar "dyn") (PVar "t")) (EIf (EApp (EVar "monoIsBool") (EApp (EVar "normalize") (EVar "t"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushTypeErrorHelpFixAt") (EFieldAccess (EVar "dyn") "dcModule")) (ELit (LString "T-BANG-ON-BOOL"))) (EVar "None")) (EVar "bangOnBoolMsg")) (EVar "bangOnBoolHelp")) (EVar "None"))) (DoExpr (EApp (EVar "tconBuiltin") (ELit (LString "Bool"))))) (EApp (EApp (EVar "refStored") (EVar "dyn")) (EVar "t"))))
(DTypeSig false "negateOp" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyCon "Mono"))))
(DFunDef false "negateOp" ((PVar "mctx") (PVar "t")) (EBlock (DoExpr (EApp (EApp (EVar "markNumlitOpTaint") (EVar "mctx")) (EVar "t"))) (DoExpr (EApp (EApp (EApp (EVar "recordIfaceObligation") (EVar "mctx")) (EVar "BNum")) (EVar "t"))) (DoExpr (EVar "t"))))
(DTypeSig false "inferInfix" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Mono"))))))
(DFunDef false "inferInfix" ((PVar "env") (PVar "op") (PVar "l") (PVar "r")) (EBlock (DoLet false false (PVar "ft") (EApp (EApp (EVar "inferVar") (EVar "env")) (EVar "op"))) (DoLet false false (PVar "lt") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "l"))) (DoLet false false (PVar "rt") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "r"))) (DoLet false false (PVar "inner") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "op"))) (EVar "l"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "inferApp") (EVar "env")) (EApp (EApp (EVar "EApp") (EVar "inner")) (EVar "r"))) (EApp (EApp (EApp (EApp (EVar "inferApp") (EVar "env")) (EVar "inner")) (EVar "ft")) (EVar "lt"))) (EVar "rt")))))
(DTypeSig false "inferVar" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyCon "Mono"))))
(DFunDef false "inferVar" ((PVar "env") (PVar "x")) (EApp (EApp (EApp (EVar "inferVarId") (EVar "env")) (EVar "x")) (ELit (LInt 0))))
(DTypeSig false "inferVarId" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Mono")))))
(DFunDef false "inferVarId" ((PVar "env") (PVar "x") (PVar "id")) (EMatch (EApp (EApp (EVar "maybeStandaloneValueMono") (EVar "env")) (EVar "x")) (arm (PCon "Some" (PVar "m")) () (EVar "m")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "inferVarPlainId") (EVar "env")) (EVar "x")) (EVar "id")))))
(DTypeSig false "inferVarPlainId" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Mono")))))
(DFunDef false "inferVarPlainId" ((PVar "env") (PVar "x") (PVar "id")) (EMatch (EApp (EApp (EVar "lookupVar") (EVar "env")) (EVar "x")) (arm (PCon "Some" (PVar "s")) () (EMatch (EApp (EApp (EVar "lookupMethodRow") (EVar "env")) (EVar "x")) (arm (PCon "Some" PWild) () (EBlock (DoLet false false (PVar "inst") (EApp (EApp (EApp (EApp (EVar "instantiateVarTrackedWithSubst") (EVar "env")) (EVar "x")) (EVar "id")) (EVar "s"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordMethodObligationOwned") (EVar "env")) (EVar "x")) (EVar "s")) (EFieldAccess (EVar "inst") "mtiBody")) (EFieldAccess (EVar "inst") "mtiSubstitution")) (EVar "None"))))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "mono") (EApp (EApp (EApp (EApp (EVar "instantiateVarTrackedId") (EVar "env")) (EVar "x")) (EVar "id")) (EVar "s"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordMethodObligationGuarded") (EVar "env")) (EVar "x")) (EVar "s")) (EVar "mono")) (EApp (EApp (EVar "methodOmittedVars") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")))))))) (arm (PCon "None") () (EApp (EApp (EVar "unboundVarFresh") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")))))
(DTypeSig true "appArgLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "appArgLoc" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "appArgLoc") (EVar "e")))
(DFunDef false "appArgLoc" ((PCon "EApp" PWild (PVar "x"))) (EApp (EVar "exprSpanLoc") (EVar "x")))
(DFunDef false "appArgLoc" (PWild) (EVar "None"))
(DTypeSig false "appSpanLoc" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "appSpanLoc" ((PVar "enclosing") (PVar "app")) (EMatch (EApp (EVar "exprSpanLoc") (EVar "app")) (arm (PCon "None") () (EVar "enclosing")) (arm (PCon "Some" (PVar "own")) () (EIf (EApp (EApp (EVar "beginsWithSpan") (EVar "enclosing")) (EVar "own")) (EVar "enclosing") (EApp (EVar "Some") (EVar "own"))))))
(DTypeSig false "beginsWithSpan" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Loc") (TyCon "Bool"))))
(DFunDef false "beginsWithSpan" ((PCon "Some" (PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))) (PCon "Loc" PWild (PVar "isl") (PVar "isc") (PVar "iel") (PVar "iec"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "sl") (EVar "isl")) (EBinOp ">=" (EBinOp "-" (EVar "isc") (EVar "sc")) (ELit (LInt 0)))) (EBinOp "<=" (EBinOp "-" (EVar "isc") (EVar "sc")) (ELit (LInt 1)))) (EBinOp "||" (EBinOp ">" (EVar "el") (EVar "iel")) (EBinOp "&&" (EBinOp "==" (EVar "el") (EVar "iel")) (EBinOp ">=" (EVar "ec") (EVar "iec"))))))
(DFunDef false "beginsWithSpan" ((PCon "None") PWild) (EVar "False"))
(DTypeSig false "appSpineHeadLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "appSpineHeadLoc" ((PCon "ELoc" (PVar "loc") (PVar "e"))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "appSpineHeadLoc") (EVar "e"))) (EApp (EVar "Some") (EVar "loc"))))
(DFunDef false "appSpineHeadLoc" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "appSpineHeadLoc") (EVar "f")))
(DFunDef false "appSpineHeadLoc" ((PVar "e")) (EApp (EVar "exprLoc") (EVar "e")))
(DTypeSig false "appNodeArg" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "appNodeArg" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "appNodeArg") (EVar "e")))
(DFunDef false "appNodeArg" ((PCon "EApp" PWild (PVar "x"))) (EVar "x"))
(DFunDef false "appNodeArg" ((PVar "e")) (EVar "e"))
(DTypeSig false "inferSpineArgs" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyTuple (TyCon "Expr") (TyCon "Mono"))))))
(DFunDef false "inferSpineArgs" ((PVar "env") (PList)) (EListLit))
(DFunDef false "inferSpineArgs" ((PVar "env") (PCons (PVar "n") (PVar "rest"))) (EBlock (DoLet false false (PVar "t") (EApp (EApp (EVar "infer") (EVar "env")) (EApp (EVar "appNodeArg") (EVar "n")))) (DoExpr (EBinOp "::" (ETuple (EVar "n") (EVar "t")) (EApp (EApp (EVar "inferSpineArgs") (EVar "env")) (EVar "rest"))))))
(DTypeSig false "inferAppNodes" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Expr") (TyCon "Mono"))) (TyCon "Mono")))))
(DFunDef false "inferAppNodes" ((PVar "env") (PVar "ft") (PList)) (EVar "ft"))
(DFunDef false "inferAppNodes" ((PVar "env") (PVar "ft") (PCons (PTuple (PVar "node") (PVar "at")) (PVar "rest"))) (EApp (EApp (EApp (EVar "inferAppNodes") (EVar "env")) (EApp (EApp (EApp (EApp (EVar "inferApp") (EVar "env")) (EVar "node")) (EVar "ft")) (EVar "at"))) (EVar "rest")))
(DTypeSig false "unifySpineResult" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Expr") (TyCon "Mono"))) (TyCon "Mono"))))))
(DFunDef false "unifySpineResult" ((PVar "env") PWild (PVar "ft") (PList)) (EVar "ft"))
(DFunDef false "unifySpineResult" ((PVar "env") (PVar "f") (PVar "ft") (PCons (PTuple (PVar "node") (PVar "at")) (PVar "rest"))) (EBlock (DoLet false false (PVar "r") (EApp (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "eff") (EApp (EApp (EApp (EApp (EApp (EVar "applicationRow") (EVar "env")) (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "node"))) (EVar "ft")) (EVar "at")) (EVar "r"))) (DoExpr (EApp (EApp (EApp (EVar "performEffect") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "curEffect")) (EVar "eff"))) (DoExpr (EApp (EApp (EVar "notePerformSite") (EVar "env")) (EVar "eff"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "unifySpineResult") (EVar "env")) (EVar "f")) (EVar "r")) (EVar "rest")))))
(DTypeSig false "inferExpected" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyCon "Mono")))))
(DFunDef false "inferExpected" ((PVar "env") (PCon "ELoc" (PVar "l") (PVar "e")) (PVar "expected")) (EApp (EApp (EApp (EVar "inferExpected") (EApp (EApp (EVar "envAt") (EApp (EVar "Some") (EVar "l"))) (EVar "env"))) (EVar "e")) (EVar "expected")))
(DFunDef false "inferExpected" ((PVar "env") (PCon "ELam" (PVar "pats") (PVar "body")) (PVar "expected")) (EMatch (EApp (EVar "normalize") (EVar "expected")) (arm (PCon "TFun" PWild PWild PWild) () (EApp (EApp (EApp (EApp (EVar "inferLamChecked") (EApp (EApp (EVar "envAtIfSome") (EApp (EVar "exprLoc") (EVar "body"))) (EVar "env"))) (EApp (EVar "Some") (EApp (EVar "normalize") (EVar "expected")))) (EVar "pats")) (EVar "body"))) (arm PWild () (EApp (EApp (EVar "infer") (EVar "env")) (EApp (EApp (EVar "ELam") (EVar "pats")) (EVar "body"))))))
(DFunDef false "inferExpected" ((PVar "env") (PVar "e") (PVar "expected")) (EIf (EBinOp "&&" (EApp (EVar "monoHasArrowInSlot") (EVar "expected")) (EApp (EApp (EVar "monoHasNonCovariantSlot") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "expected"))) (EMatch (EApp (EVar "appSpineExpr") (EVar "e")) (arm (PTuple (PVar "hd") (PVar "args")) () (EIf (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "args")) (EApp (EVar "not") (EApp (EApp (EVar "plainAppHead") (EVar "env")) (EVar "hd")))) (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e")) (EApp (EApp (EApp (EApp (EVar "inferAppResultFirst") (EVar "env")) (EVar "hd")) (EVar "args")) (EVar "expected"))))) (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e"))))
(DTypeSig false "appSpineExpr" (TyFun (TyCon "Expr") (TyTuple (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr")))))
(DFunDef false "appSpineExpr" ((PVar "e")) (EApp (EApp (EVar "appSpineExprGo") (EVar "e")) (EListLit)))
(DTypeSig false "appSpineExprGo" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))))
(DFunDef false "appSpineExprGo" ((PCon "EApp" (PVar "f") (PVar "x")) (PVar "args")) (EApp (EApp (EVar "appSpineExprGo") (EVar "f")) (EBinOp "::" (EVar "x") (EVar "args"))))
(DFunDef false "appSpineExprGo" ((PCon "ELoc" PWild (PCon "EApp" (PVar "f") (PVar "x"))) (PVar "args")) (EApp (EApp (EVar "appSpineExprGo") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))) (EVar "args")))
(DFunDef false "appSpineExprGo" ((PVar "e") (PVar "args")) (ETuple (EVar "e") (EVar "args")))
(DTypeSig false "plainAppHead" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "plainAppHead" ((PVar "env") (PCon "ELoc" PWild (PVar "inner"))) (EApp (EApp (EVar "plainAppHead") (EVar "env")) (EVar "inner")))
(DFunDef false "plainAppHead" ((PVar "env") (PAs "hd" (PCon "EVar" PWild))) (EApp (EApp (EVar "plainAppHeadVar") (EVar "env")) (EVar "hd")))
(DFunDef false "plainAppHead" ((PVar "env") (PAs "hd" (PCon "EVarId" PWild PWild))) (EApp (EApp (EVar "plainAppHeadVar") (EVar "env")) (EVar "hd")))
(DFunDef false "plainAppHead" ((PVar "env") (PCon "EDictAt" PWild PWild)) (EVar "True"))
(DFunDef false "plainAppHead" ((PVar "env") PWild) (EVar "False"))
(DTypeSig false "inferAppResultFirst" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyFun (TyCon "Mono") (TyCon "Mono"))))))
(DFunDef false "inferAppResultFirst" ((PVar "env") (PVar "hd") (PVar "args") (PVar "expected")) (EBlock (DoLet false false (PVar "ft") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "hd"))) (DoExpr (EMatch (EApp (EApp (EVar "resultAfterArrows") (EApp (EVar "listLen") (EVar "args"))) (EVar "ft")) (arm (PCon "Some" (PVar "res")) () (EApp (EApp (EApp (EVar "unifyIn") (EFieldAccess (EVar "env") "teDyn")) (EVar "res")) (EVar "expected"))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EApp (EApp (EApp (EApp (EVar "inferAppArgsAgainst") (EVar "env")) (EVar "hd")) (EVar "ft")) (EVar "args")))))
(DTypeSig false "inferAppArgsAgainst" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Mono"))))))
(DFunDef false "inferAppArgsAgainst" ((PVar "env") PWild (PVar "ft") (PList)) (EVar "ft"))
(DFunDef false "inferAppArgsAgainst" ((PVar "env") (PVar "appSoFar") (PVar "ft") (PCons (PVar "x") (PVar "rest"))) (EBlock (DoLet false false (PVar "xt") (EMatch (EApp (EVar "lamUnderLoc") (EVar "x")) (arm (PCon "Some" (PTuple (PVar "loc") (PVar "pats") (PVar "body"))) () (EApp (EApp (EApp (EApp (EVar "inferLamChecked") (EApp (EApp (EVar "envAtIfSome") (EVar "loc")) (EVar "env"))) (EApp (EVar "Some") (EApp (EApp (EVar "funDomain") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EVar "normalize") (EVar "ft"))))) (EVar "pats")) (EVar "body"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "inferExpected") (EVar "env")) (EVar "x")) (EApp (EApp (EVar "funDomain") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EVar "normalize") (EVar "ft"))))))) (DoLet false false (PVar "res") (EApp (EApp (EApp (EApp (EVar "inferApp") (EVar "env")) (EApp (EApp (EVar "EApp") (EVar "appSoFar")) (EVar "x"))) (EVar "ft")) (EVar "xt"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "inferAppArgsAgainst") (EVar "env")) (EApp (EApp (EVar "EApp") (EVar "appSoFar")) (EVar "x"))) (EVar "res")) (EVar "rest")))))
(DTypeSig false "inferAppExpr" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Mono")))))
(DFunDef false "inferAppExpr" ((PVar "env") (PVar "f") (PVar "x")) (EMatch (EApp (EVar "lamUnderLoc") (EVar "x")) (arm (PCon "Some" (PTuple (PVar "loc") (PVar "pats") (PVar "body"))) () (EBlock (DoLet false false (PVar "ft") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "f"))) (DoLet false false (PVar "lamExpected") (EApp (EApp (EVar "funDomain") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EVar "normalize") (EVar "ft")))) (DoLet false false (PVar "xt") (EApp (EApp (EApp (EApp (EVar "inferLamChecked") (EApp (EApp (EVar "envAtIfSome") (EVar "loc")) (EVar "env"))) (EApp (EVar "Some") (EVar "lamExpected"))) (EVar "pats")) (EVar "body"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "inferApp") (EVar "env")) (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))) (EVar "ft")) (EVar "xt"))))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "shadowStandaloneSpineHeadAt") (EVar "env")) (EVar "f")) (arm (PCon "Some" (PTuple (PVar "mname") (PVar "arityRefs") (PVar "tagRefs") (PVar "hd") (PVar "nodes"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferShadowAppAt") (EVar "env")) (EVar "mname")) (EVar "arityRefs")) (EVar "tagRefs")) (EVar "hd")) (EVar "nodes")) (EVar "f")) (EVar "x"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "shadowStandaloneHead") (EVar "env")) (EVar "f")) (arm (PCon "Some" (PTuple (PVar "mname") (PVar "arityRefs") (PVar "tagRefs"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferShadowApp") (EVar "env")) (EVar "mname")) (EVar "arityRefs")) (EVar "tagRefs")) (EVar "f")) (EVar "x"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "definerShadowSpineArgAt") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "f")) (arm (PCon "Some" (PTuple (PVar "dname") (PVar "darityRef") (PVar "dtagRef") (PVar "dimplRef") (PVar "dinnerRef") (PVar "dhd") (PVar "dnodes"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferDefinerShadowAppAt") (EVar "env")) (EVar "dname")) (EVar "darityRef")) (EVar "dtagRef")) (EVar "dimplRef")) (EVar "dinnerRef")) (EVar "dhd")) (EVar "dnodes")) (EVar "f")) (EVar "x"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "definerShadowSpineVarAt") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "f")) (arm (PCon "Some" (PTuple (PVar "dname") (PVar "dhd") (PVar "dnodes"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferDefinerShadowVarAppAt") (EVar "env")) (EVar "dname")) (EVar "dhd")) (EVar "dnodes")) (EVar "f")) (EVar "x"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "definerShadowArgHead") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "f")) (arm (PCon "Some" (PTuple (PVar "dname") (PVar "darityRef") (PVar "dtagRef") (PVar "dimplRef") (PVar "dinnerRef"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferDefinerShadowApp") (EVar "env")) (EVar "dname")) (EVar "darityRef")) (EVar "dtagRef")) (EVar "dimplRef")) (EVar "dinnerRef")) (EVar "f")) (EVar "x"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "definerShadowVarHead") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "f")) (arm (PCon "Some" (PVar "dname")) () (EApp (EApp (EApp (EApp (EVar "inferDefinerShadowVarApp") (EVar "env")) (EVar "dname")) (EVar "f")) (EVar "x"))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "ft") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "f"))) (DoLet false false (PVar "xt") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "x"))) (DoLet false false (PVar "pend") (EApp (EApp (EApp (EVar "tupleCallShapeHint") (EVar "f")) (EVar "x")) (EVar "ft"))) (DoLet false false (PVar "res") (EApp (EApp (EApp (EApp (EVar "inferApp") (EVar "env")) (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))) (EVar "ft")) (EVar "xt"))) (DoExpr (EMatch (EVar "pend") (arm (PCon "Some" (PTuple (PVar "help") (PVar "fix"))) () (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "tupleCallCandidates")) (EBinOp "::" (ETuple (EVar "res") (EVar "help") (EVar "fix")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "tupleCallCandidates") "value")))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EVar "res"))))))))))))))))))
(DTypeSig false "inferShadowApp" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Int")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Ref") (TyCon "Route")) (TyApp (TyCon "Ref") (TyCon "Inner")))) (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Mono"))))))))
(DFunDef false "inferShadowApp" ((PVar "env") (PVar "mname") (PVar "arityRefs") (PVar "tagRefs") (PVar "f") (PVar "x")) (EBlock (DoLet false false (PVar "dloc") (EApp (EApp (EVar "appSpanLoc") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")))) (DoLet false false (PVar "tx") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "x"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "groundShadowReceiver") (EFieldAccess (EVar "env") "teDyn")) (EApp (EApp (EVar "importerShadowDomain") (EVar "env")) (EVar "mname"))) (EVar "tx")) (EApp (EApp (EApp (EVar "definerReceiverIsDictVar") (EFieldAccess (EVar "env") "teDyn")) (EVar "mname")) (EVar "tx"))) (EVar "dloc"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "groundAdmittedReceivers") (EVar "env")) (EVar "mname")) (EListLit (EVar "tx"))) (EVar "dloc"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "importerAdmittedVerdict") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "bodyImplEnvRef") "value")) (EVar "mname")) (EListLit (EVar "tx"))) (arm (PCon "AdReject" (PVar "ifs")) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "pushAmbiguousShadowDecl") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "mname")) (EVar "ifs")) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "appSpineHeadLoc") (EVar "f"))) (EVar "dloc")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferShadowStandaloneArm") (EVar "env")) (EVar "mname")) (EVar "arityRefs")) (EVar "tagRefs")) (EVar "f")) (EVar "x")) (EVar "tx"))))) (arm (PCon "AdStandalone") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferShadowStandaloneArm") (EVar "env")) (EVar "mname")) (EVar "arityRefs")) (EVar "tagRefs")) (EVar "f")) (EVar "x")) (EVar "tx"))) (arm (PCon "AdDefer") () (EMatch (EApp (EVar "headTyconMono") (EVar "tx")) (arm (PCon "Some" (PVar "head")) () (EIf (EApp (EApp (EApp (EApp (EVar "ieImplExistsForHead") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "bodyImplEnvRef") "value")) (EVar "mname")) (EVar "head")) (EApp (EApp (EApp (EApp (EVar "inferApp") (EVar "env")) (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))) (EApp (EApp (EVar "inferShadowAppHead") (EVar "env")) (EVar "f"))) (EVar "tx")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferShadowStandaloneArm") (EVar "env")) (EVar "mname")) (EVar "arityRefs")) (EVar "tagRefs")) (EVar "f")) (EVar "x")) (EVar "tx")))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "inferApp") (EVar "env")) (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))) (EApp (EApp (EVar "inferShadowAppHead") (EVar "env")) (EVar "f"))) (EVar "tx")))))))))
(DTypeSig false "inferShadowStandaloneArm" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Int")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Ref") (TyCon "Route")) (TyApp (TyCon "Ref") (TyCon "Inner")))) (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyCon "Mono")))))))))
(DFunDef false "inferShadowStandaloneArm" ((PVar "env") (PVar "mname") (PVar "arityRefs") (PVar "tagRefs") (PVar "f") (PVar "x") (PVar "tx")) (EMatch (EApp (EApp (EVar "lookupStandaloneValue") (EVar "env")) (EVar "mname")) (arm (PCon "Some" (PVar "value")) () (EBlock (DoLet false false (PVar "occurrence") (EApp (EApp (EApp (EApp (EApp (EVar "instantiateStandaloneOccurrence") (EVar "env")) (EVar "mname")) (ELit (LString ""))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "appSpineHeadLoc") (EVar "f"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc"))) (EVar "value"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordStandaloneAt") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "mname")) (EVar "f")) (EVar "occurrence"))) (DoLet false false (PVar "smono") (EFieldAccess (EFieldAccess (EVar "occurrence") "svoInstance") "mtiBody")) (DoExpr (EApp (EApp (EVar "stampMethodArities") (EVar "arityRefs")) (EApp (EVar "funArity") (EVar "smono")))) (DoLet false false (PVar "r") (EApp (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "eff") (EApp (EApp (EApp (EApp (EApp (EVar "applicationRow") (EApp (EApp (EVar "envAtIfSome") (EApp (EApp (EVar "appSpanLoc") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")))) (EVar "env"))) (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))) (EVar "smono")) (EVar "tx")) (EVar "r"))) (DoExpr (EApp (EApp (EApp (EVar "performEffect") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "curEffect")) (EVar "eff"))) (DoExpr (EApp (EVar "stampRoutes") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "tagRefs")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordSelectedStandaloneRoutes") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "mname")) (EFieldAccess (EVar "occurrence") "svoDicts")) (EVar "tagRefs")) (EVar "tx"))) (DoExpr (EVar "r")))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "inferApp") (EVar "env")) (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))) (EApp (EApp (EVar "inferShadowAppHead") (EVar "env")) (EVar "f"))) (EVar "tx")))))
(DTypeSig false "inferShadowAppHead" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyCon "Mono"))))
(DFunDef false "inferShadowAppHead" ((PVar "env") (PVar "f")) (EApp (EApp (EVar "infer") (EApp (EVar "shadowHeadEnv") (EVar "env"))) (EVar "f")))
(DTypeSig false "inferShadowAppAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Int")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Ref") (TyCon "Route")) (TyApp (TyCon "Ref") (TyCon "Inner")))) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Mono"))))))))))
(DFunDef false "inferShadowAppAt" ((PVar "env") (PVar "mname") (PVar "arityRefs") (PVar "tagRefs") (PVar "hd") (PVar "nodes") (PVar "f") (PVar "x")) (EBlock (DoLet false false (PVar "dloc") (EApp (EApp (EVar "appSpanLoc") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")))) (DoLet false false (PVar "pre") (EApp (EApp (EVar "inferSpineArgs") (EVar "env")) (EVar "nodes"))) (DoLet false false (PVar "k") (EApp (EVar "listLen") (EVar "pre"))) (DoLet false false (PVar "tx") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "x"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "groundShadowReceiver") (EFieldAccess (EVar "env") "teDyn")) (EApp (EApp (EApp (EVar "importerShadowDomainAt") (EVar "env")) (EVar "mname")) (EVar "k"))) (EVar "tx")) (EApp (EApp (EApp (EVar "definerReceiverIsDictVar") (EFieldAccess (EVar "env") "teDyn")) (EVar "mname")) (EVar "tx"))) (EVar "dloc"))) (DoLet false false (PVar "ats") (EBinOp "++" (EApp (EApp (EVar "map") (EVar "snd")) (EVar "pre")) (EListLit (EVar "tx")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "groundAdmittedReceivers") (EVar "env")) (EVar "mname")) (EVar "ats")) (EVar "dloc"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "importerAdmittedVerdict") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "bodyImplEnvRef") "value")) (EVar "mname")) (EVar "ats")) (arm (PCon "AdReject" (PVar "ifs")) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "pushAmbiguousShadowDecl") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "mname")) (EVar "ifs")) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "appSpineHeadLoc") (EVar "f"))) (EVar "dloc")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferShadowStandaloneArmAt") (EVar "env")) (EVar "mname")) (EVar "arityRefs")) (EVar "tagRefs")) (EVar "hd")) (EVar "pre")) (EVar "f")) (EVar "x")) (EVar "tx"))))) (arm (PCon "AdStandalone") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferShadowStandaloneArmAt") (EVar "env")) (EVar "mname")) (EVar "arityRefs")) (EVar "tagRefs")) (EVar "hd")) (EVar "pre")) (EVar "f")) (EVar "x")) (EVar "tx"))) (arm (PCon "AdDefer") () (EMatch (EApp (EVar "headTyconMono") (EVar "tx")) (arm (PCon "Some" (PVar "head")) () (EIf (EApp (EApp (EApp (EApp (EVar "ieImplExistsForHead") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "bodyImplEnvRef") "value")) (EVar "mname")) (EVar "head")) (EApp (EApp (EApp (EVar "inferAppNodes") (EVar "env")) (EApp (EApp (EVar "inferShadowAppHead") (EVar "env")) (EVar "hd"))) (EBinOp "++" (EVar "pre") (EListLit (ETuple (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")) (EVar "tx"))))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferShadowStandaloneArmAt") (EVar "env")) (EVar "mname")) (EVar "arityRefs")) (EVar "tagRefs")) (EVar "hd")) (EVar "pre")) (EVar "f")) (EVar "x")) (EVar "tx")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "inferAppNodes") (EVar "env")) (EApp (EApp (EVar "inferShadowAppHead") (EVar "env")) (EVar "hd"))) (EBinOp "++" (EVar "pre") (EListLit (ETuple (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")) (EVar "tx"))))))))))))
(DTypeSig false "inferShadowStandaloneArmAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Int")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Ref") (TyCon "Route")) (TyApp (TyCon "Ref") (TyCon "Inner")))) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Expr") (TyCon "Mono"))) (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyCon "Mono")))))))))))
(DFunDef false "inferShadowStandaloneArmAt" ((PVar "env") (PVar "mname") (PVar "arityRefs") (PVar "tagRefs") (PVar "hd") (PVar "pre") (PVar "f") (PVar "x") (PVar "tx")) (EMatch (EApp (EApp (EVar "lookupStandaloneValue") (EVar "env")) (EVar "mname")) (arm (PCon "Some" (PVar "value")) () (EBlock (DoLet false false (PVar "occurrence") (EApp (EApp (EApp (EApp (EApp (EVar "instantiateStandaloneOccurrence") (EVar "env")) (EVar "mname")) (ELit (LString ""))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "appSpineHeadLoc") (EVar "f"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc"))) (EVar "value"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordStandaloneAt") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "mname")) (EVar "hd")) (EVar "occurrence"))) (DoLet false false (PVar "smono") (EFieldAccess (EFieldAccess (EVar "occurrence") "svoInstance") "mtiBody")) (DoExpr (EApp (EApp (EVar "stampMethodArities") (EVar "arityRefs")) (EApp (EVar "funArity") (EVar "smono")))) (DoLet false false (PVar "r") (EApp (EApp (EApp (EApp (EVar "unifySpineResult") (EApp (EApp (EVar "envAtIfSome") (EApp (EApp (EVar "appSpanLoc") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")))) (EVar "env"))) (EVar "f")) (EVar "smono")) (EBinOp "++" (EVar "pre") (EListLit (ETuple (EVar "x") (EVar "tx")))))) (DoExpr (EApp (EVar "stampRoutes") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "tagRefs")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordSelectedStandaloneRoutes") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "mname")) (EFieldAccess (EVar "occurrence") "svoDicts")) (EVar "tagRefs")) (EVar "tx"))) (DoExpr (EVar "r")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "inferAppNodes") (EVar "env")) (EApp (EApp (EVar "inferShadowAppHead") (EVar "env")) (EVar "hd"))) (EBinOp "++" (EVar "pre") (EListLit (ETuple (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")) (EVar "tx"))))))))
(DTypeSig false "inferDefinerShadowApp" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Int"))) (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyFun (TyApp (TyCon "Ref") (TyCon "Inner")) (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Mono"))))))))))
(DFunDef false "inferDefinerShadowApp" ((PVar "env") (PVar "name") (PVar "arityRef") (PVar "tagRef") (PVar "implRef") (PVar "innerRef") (PVar "f") (PVar "x")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferDefinerShadowAppAt") (EVar "env")) (EVar "name")) (EVar "arityRef")) (EVar "tagRef")) (EVar "implRef")) (EVar "innerRef")) (EVar "f")) (EListLit)) (EVar "f")) (EVar "x")))
(DTypeSig false "inferDefinerShadowAppAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Int"))) (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyFun (TyApp (TyCon "Ref") (TyCon "Inner")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Mono"))))))))))))
(DFunDef false "inferDefinerShadowAppAt" ((PVar "env") (PVar "name") (PVar "arityRef") (PVar "tagRef") (PVar "implRef") (PVar "innerRef") (PVar "hd") (PVar "nodes") (PVar "f") (PVar "x")) (EBlock (DoLet false false (PVar "sym") (EApp (EApp (EVar "recoveredShadowSym") (EVar "name")) (EVar "tagRef"))) (DoLet false false (PVar "dloc") (EApp (EApp (EVar "appSpanLoc") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")))) (DoLet false false (PVar "pre") (EApp (EApp (EVar "inferSpineArgs") (EVar "env")) (EVar "nodes"))) (DoLet false false (PVar "k") (EApp (EVar "listLen") (EVar "pre"))) (DoLet false false (PVar "xt") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "x"))) (DoLet false false (PVar "isDictVar") (EApp (EApp (EApp (EVar "definerReceiverIsDictVar") (EFieldAccess (EVar "env") "teDyn")) (EVar "name")) (EVar "xt"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "groundShadowReceiver") (EFieldAccess (EVar "env") "teDyn")) (EApp (EApp (EApp (EApp (EVar "shadowDomainForAt") (EVar "env")) (EVar "name")) (EVar "sym")) (EVar "k"))) (EVar "xt")) (EVar "isDictVar")) (EVar "dloc"))) (DoLet false false (PVar "dispatches") (EApp (EApp (EApp (EVar "definerReceiverDispatches") (EFieldAccess (EVar "env") "teDyn")) (EVar "name")) (EVar "xt"))) (DoExpr (EIf (EBinOp "||" (EVar "dispatches") (EVar "isDictVar")) (EMatch (EApp (EVar "spineHeadEv") (EVar "hd")) (arm (PCon "Some" (PVar "ev")) () (EBlock (DoLet false false (PVar "cell") (EApp (EApp (EVar "methodCellOf") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "ev"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "cell") "ecIface")) (EApp (EApp (EVar "admittedIfaceWord") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")))))) (arm (PCon "None") () (ELit LUnit))) (ELit LUnit))) (DoLet false false (PVar "headEnv") (ERecordUpdate (EVar "env") ((fa "teDyn" (ERecordUpdate (EFieldAccess (EVar "env") "teDyn") ((fa "dcSuppressRLocalRecord" (EVar "True")) (fa "dcSuppressArgStamp" (EVar "True")) (fa "dcShadowHeadCtx" (EVar "True")))))))) (DoLet false false (PVar "selected") (EIf (EVar "dispatches") (EVar "None") (EApp (EApp (EApp (EApp (EVar "standaloneOccurrence") (EVar "headEnv")) (EVar "name")) (EVar "sym")) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "appSpineHeadLoc") (EVar "f"))) (EVar "dloc"))))) (DoLet false false (PVar "ft") (EIf (EVar "dispatches") (EApp (EApp (EApp (EVar "shadowVarHeadMethodScheme") (EVar "headEnv")) (EVar "name")) (EVar "hd")) (EMatch (EVar "selected") (arm (PCon "Some" (PVar "occurrence")) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "recordStandaloneAt") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "hd")) (EVar "occurrence"))) (DoExpr (EFieldAccess (EFieldAccess (EVar "occurrence") "svoInstance") "mtiBody")))) (arm (PCon "None") () (EApp (EApp (EVar "infer") (EVar "headEnv")) (EVar "hd")))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "arityRef")) (EApp (EVar "Some") (EApp (EVar "funArity") (EVar "ft"))))) (DoLet false false (PVar "dicts") (EIf (EBinOp "||" (EVar "dispatches") (EVar "isDictVar")) (EVar "emptyShadowDicts") (EApp (EApp (EVar "optionOr") (EVar "emptyShadowDicts")) (EApp (EApp (EVar "map") (ELam ((PVar "occurrence")) (EFieldAccess (EVar "occurrence") "svoDicts"))) (EVar "selected"))))) (DoExpr (EIf (EVar "isDictVar") (ELit LUnit) (EApp (EApp (EApp (EApp (EVar "pushSiteGoal") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "GKRLocalSite")) (EVar "innerRef")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PendingEntry") (EVar "name")) (EVar "tagRef")) (EVar "xt")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentFn") "value")) (EApp (EApp (EApp (EApp (EApp (EVar "SKRLocal") (EApp (EVar "routeLocalSym") (EUnOp "!" (EVar "tagRef")))) (EApp (EVar "not") (EVar "dispatches"))) (EFieldAccess (EVar "dicts") "sdMonos")) (EFieldAccess (EVar "dicts") "sdIfaces")) (EFieldAccess (EVar "dicts") "sdArgVecs"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EApp (EApp (EVar "captureScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (EApp (EApp (EVar "freshEvId") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit)))))) (DoExpr (EMatch (EApp (EApp (EVar "argDispatchOf") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EApp (EVar "pushSiteGoal") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "GKArgStamp")) (EVar "innerRef")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PendingEntry") (EVar "name")) (EVar "tagRef")) (EVar "xt")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentFn") "value")) (EApp (EApp (EApp (EVar "SKArg") (EVar "implRef")) (EIf (EVar "dispatches") (EVar "ft") (EVar "xt"))) (EListLit))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EApp (EApp (EVar "captureScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (EApp (EApp (EVar "freshEvId") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EMatch (EIf (EBinOp "||" (EVar "dispatches") (EVar "isDictVar")) (EVar "None") (EApp (EApp (EApp (EVar "standaloneSchemeFor") (EVar "env")) (EVar "name")) (EVar "sym"))) (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EApp (EVar "unifySpineResult") (EApp (EApp (EVar "envAtIfSome") (EVar "dloc")) (EVar "env"))) (EVar "f")) (EVar "ft")) (EBinOp "++" (EVar "pre") (EListLit (ETuple (EVar "x") (EVar "xt")))))) (arm (PCon "None") () (EBlock (DoExpr (EIf (EBinOp "==" (EVar "sym") (ELit (LString ""))) (EApp (EApp (EApp (EApp (EApp (EVar "enforceStandaloneDomainAt") (EVar "env")) (EVar "name")) (EVar "xt")) (EVar "dloc")) (EVar "k")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "inferAppNodes") (EVar "env")) (EVar "ft")) (EBinOp "++" (EVar "pre") (EListLit (ETuple (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")) (EVar "xt"))))))))))))
(DTypeSig false "inferDefinerShadowVarApp" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Mono"))))))
(DFunDef false "inferDefinerShadowVarApp" ((PVar "env") (PVar "name") (PVar "f") (PVar "x")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferDefinerShadowVarAppAt") (EVar "env")) (EVar "name")) (EVar "f")) (EListLit)) (EVar "f")) (EVar "x")))
(DTypeSig false "inferDefinerShadowVarAppAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Mono"))))))))
(DFunDef false "inferDefinerShadowVarAppAt" ((PVar "env") (PVar "name") (PVar "hd") (PVar "nodes") (PVar "f") (PVar "x")) (EBlock (DoLet false false (PVar "dloc") (EApp (EApp (EVar "appSpanLoc") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")))) (DoLet false false (PVar "pre") (EApp (EApp (EVar "inferSpineArgs") (EVar "env")) (EVar "nodes"))) (DoLet false false (PVar "xt") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "x"))) (DoLet false false (PVar "isDictVar") (EApp (EApp (EApp (EVar "definerReceiverIsDictVar") (EFieldAccess (EVar "env") "teDyn")) (EVar "name")) (EVar "xt"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "groundShadowReceiver") (EFieldAccess (EVar "env") "teDyn")) (EApp (EApp (EApp (EVar "standaloneShadowDomainAt") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EApp (EVar "listLen") (EVar "pre")))) (EVar "xt")) (EVar "isDictVar")) (EVar "dloc"))) (DoExpr (EIf (EVar "isDictVar") (EApp (EApp (EApp (EVar "inferAppNodes") (EVar "env")) (EApp (EApp (EApp (EVar "shadowVarHeadMethodScheme") (EVar "env")) (EVar "name")) (EVar "hd"))) (EBinOp "++" (EVar "pre") (EListLit (ETuple (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")) (EVar "xt"))))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferDefinerStandaloneVarAppAt") (EVar "env")) (EVar "name")) (EVar "hd")) (EVar "pre")) (EVar "f")) (EVar "x")) (EVar "xt")) (EVar "dloc"))))))
(DTypeSig false "shadowVarHeadMethodScheme" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Mono")))))
(DFunDef false "shadowVarHeadMethodScheme" ((PVar "env") (PVar "name") (PVar "f")) (EMatch (EApp (EApp (EVar "methodEntryHere") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (arm (PCon "Some" (PTuple PWild PWild (PVar "ty") (PVar "scope"))) () (EApp (EApp (EApp (EVar "forceInstantiation") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EApp (EApp (EVar "instantiateMethodTracked") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EVar "fst") (EApp (EApp (EApp (EVar "sigToSchemeTvsIn") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "scope")) (EVar "ty")))))) (arm (PCon "None") () (EApp (EApp (EVar "infer") (EApp (EVar "shadowHeadEnv") (EVar "env"))) (EVar "f")))))
(DTypeSig false "inferDefinerStandaloneVarAppAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Expr") (TyCon "Mono"))) (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono"))))))))))
(DFunDef false "inferDefinerStandaloneVarAppAt" ((PVar "env") (PVar "name") (PVar "hd") (PVar "pre") (PVar "f") (PVar "x") (PVar "xt") (PVar "dloc")) (EMatch (EApp (EApp (EApp (EApp (EVar "standaloneOccurrence") (EVar "env")) (EVar "name")) (ELit (LString ""))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "appSpineHeadLoc") (EVar "f"))) (EVar "dloc"))) (arm (PCon "Some" (PVar "occurrence")) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "recordStandaloneAt") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "hd")) (EVar "occurrence"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "unifySpineResult") (EApp (EApp (EVar "envAtIfSome") (EVar "dloc")) (EVar "env"))) (EVar "f")) (EFieldAccess (EFieldAccess (EVar "occurrence") "svoInstance") "mtiBody")) (EBinOp "++" (EVar "pre") (EListLit (ETuple (EVar "x") (EVar "xt")))))))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "ft") (EApp (EApp (EVar "infer") (EApp (EVar "shadowHeadEnv") (EVar "env"))) (EVar "hd"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "enforceStandaloneDomainAt") (EVar "env")) (EVar "name")) (EVar "xt")) (EVar "dloc")) (EApp (EVar "listLen") (EVar "pre")))) (DoExpr (EApp (EApp (EApp (EVar "inferAppNodes") (EVar "env")) (EVar "ft")) (EBinOp "++" (EVar "pre") (EListLit (ETuple (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")) (EVar "xt"))))))))))
(DTypeSig false "lamUnderLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))
(DFunDef false "lamUnderLoc" ((PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EVar "Some") (ETuple (EVar "None") (EVar "pats") (EVar "body"))))
(DFunDef false "lamUnderLoc" ((PCon "ELoc" (PVar "l") (PCon "ELam" (PVar "pats") (PVar "body")))) (EApp (EVar "Some") (ETuple (EApp (EVar "Some") (EVar "l")) (EVar "pats") (EVar "body"))))
(DFunDef false "lamUnderLoc" (PWild) (EVar "None"))
(DTypeSig false "funDomain" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyCon "Mono"))))
(DFunDef false "funDomain" ((PVar "mctx") (PCon "TFun" (PVar "a") PWild PWild)) (EVar "a"))
(DFunDef false "funDomain" ((PVar "mctx") PWild) (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit)))
(DTypeSig false "inferLamChecked" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "Option") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyCon "Mono"))))))
(DFunDef false "inferLamChecked" ((PVar "env") (PVar "expected") (PVar "pats") (PVar "body")) (EApp (EVar "fst") (EApp (EApp (EApp (EApp (EApp (EVar "inferBindingChecked") (EVar "True")) (EVar "env")) (EVar "expected")) (EVar "pats")) (EVar "body"))))
(DTypeSig true "inferBindingChecked" (TyFun (TyCon "Bool") (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "Option") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyTuple (TyCon "Mono") (TyCon "EffRow"))))))))
(DFunDef false "inferBindingChecked" ((PVar "judge") (PVar "env") (PVar "expected") (PVar "pats") (PVar "body")) (EBlock (DoLet false false (PVar "lits") (EApp (EApp (EVar "takePatLits") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "pr") (EApp (EApp (EVar "inferPats") (EVar "env")) (EVar "pats"))) (DoLet false false (PVar "arity") (EApp (EVar "listLen") (EVar "pats"))) (DoExpr (EMatch (EVar "expected") (arm (PCon "Some" (PVar "want")) () (EApp (EApp (EApp (EVar "unifyParamsExpected") (EFieldAccess (EVar "env") "teDyn")) (EApp (EVar "fst") (EVar "pr"))) (EApp (EApp (EVar "expectedParamTypes") (EVar "want")) (EVar "arity")))) (arm (PCon "None") () (ELit LUnit)))) (DoLet false false (PVar "scope") (EApp (EApp (EVar "openExistentialScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EApp (EVar "takeOpenedExistentials") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "settlePatLits") (EFieldAccess (EVar "env") "teDyn")) (EVar "lits"))) (DoExpr (EIf (EVar "judge") (EApp (EApp (EApp (EVar "checkBinderPats") (EVar "env")) (EApp (EVar "fst") (EVar "pr"))) (EVar "pats")) (ELit LUnit))) (DoExpr (EMatch (EVar "expected") (arm (PCon "Some" (PVar "want")) () (EApp (EApp (EApp (EApp (EVar "recordClauseFileBound") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "body")) (EVar "arity")) (EVar "want"))) (arm (PCon "None") () (ELit LUnit)))) (DoLet false false (PTuple (PVar "bodyTy") (PVar "bodyEff")) (EApp (EApp (EApp (EVar "captureEffects") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "curEffect")) (EApp (EVar "joinCellOf") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph"))) (ELam (PWild) (EBlock (DoLet false false (PVar "bodyEnv") (EApp (EApp (EVar "extendLocalVars") (EVar "env")) (EApp (EVar "snd") (EVar "pr")))) (DoLet false false (PVar "actual") (EApp (EApp (EVar "infer") (EVar "bodyEnv")) (EVar "body"))) (DoExpr (EMatch (EVar "expected") (arm (PCon "Some" (PVar "want")) () (EMatch (EApp (EApp (EVar "resultAfterArrows") (EVar "arity")) (EVar "want")) (arm (PCon "Some" (PVar "result")) () (EApp (EApp (EApp (EApp (EVar "checkedInto") (EVar "bodyEnv")) (EVar "body")) (EVar "result")) (EVar "actual"))) (arm (PCon "None") () (EVar "actual")))) (arm (PCon "None") () (EVar "actual")))))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "closeExistentialScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "scope")) (EVar "bodyTy")) (EApp (EVar "exprLoc") (EVar "body")))) (DoLet false false (PVar "force") (EIf (EApp (EVar "isEmptyL") (EVar "pats")) (EVar "bodyEff") (EVar "pureRow"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "bodyArrows") (EApp (EVar "fst") (EVar "pr"))) (EVar "bodyEff")) (EVar "bodyTy")) (EVar "force")))))
(DTypeSig false "isDoLoweredAndThenCallee" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isDoLoweredAndThenCallee" ((PCon "EApp" (PVar "callee") PWild)) (EApp (EVar "isDoLoweredAndThenCalleeExpr") (EVar "callee")))
(DFunDef false "isDoLoweredAndThenCallee" (PWild) (EVar "False"))
(DTypeSig false "isDoLoweredAndThenCalleeExpr" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isDoLoweredAndThenCalleeExpr" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "isDoLoweredAndThenCalleeExpr") (EVar "e")))
(DFunDef false "isDoLoweredAndThenCalleeExpr" ((PCon "EDoOrigin" PWild (PCon "EVar" (PLit (LString "andThen"))))) (EVar "True"))
(DFunDef false "isDoLoweredAndThenCalleeExpr" ((PCon "EDoOrigin" PWild (PCon "EVar" (PLit (LString "deferThen"))))) (EVar "True"))
(DFunDef false "isDoLoweredAndThenCalleeExpr" ((PCon "EDoOrigin" PWild (PCon "EVarId" (PLit (LString "andThen")) PWild))) (EVar "True"))
(DFunDef false "isDoLoweredAndThenCalleeExpr" ((PCon "EDoOrigin" PWild (PCon "EVarId" (PLit (LString "deferThen")) PWild))) (EVar "True"))
(DFunDef false "isDoLoweredAndThenCalleeExpr" ((PCon "EDoOrigin" PWild (PCon "EMethodAt" (PLit (LString "andThen")) PWild PWild))) (EVar "True"))
(DFunDef false "isDoLoweredAndThenCalleeExpr" ((PCon "EDoOrigin" PWild (PCon "EMethodAt" (PLit (LString "deferThen")) PWild PWild))) (EVar "True"))
(DFunDef false "isDoLoweredAndThenCalleeExpr" ((PCon "EDoOrigin" PWild (PCon "EDictAt" (PLit (LString "andThen")) PWild))) (EVar "True"))
(DFunDef false "isDoLoweredAndThenCalleeExpr" ((PCon "EDoOrigin" PWild (PCon "EDictAt" (PLit (LString "deferThen")) PWild))) (EVar "True"))
(DFunDef false "isDoLoweredAndThenCalleeExpr" (PWild) (EVar "False"))
(DTypeSig false "tupleArgElems" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Expr")))))
(DFunDef false "tupleArgElems" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "tupleArgElems") (EVar "e")))
(DFunDef false "tupleArgElems" ((PCon "ETuple" (PVar "es"))) (EApp (EVar "Some") (EVar "es")))
(DFunDef false "tupleArgElems" (PWild) (EVar "None"))
(DTypeSig false "tupleCallSpanLoc" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "tupleCallSpanLoc" ((PVar "f") (PVar "x")) (EMatch (ETuple (EApp (EVar "exprLoc") (EVar "f")) (EApp (EVar "exprLoc") (EVar "x"))) (arm (PTuple (PCon "Some" (PCon "Loc" (PVar "file") (PVar "sl") (PVar "sc") PWild PWild)) (PCon "Some" (PCon "Loc" PWild PWild PWild (PVar "el") (PVar "ec")))) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "file")) (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec")))) (arm PWild () (EVar "None"))))
(DTypeSig false "buildTupleCallHint" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "Loc") (TyCon "String")))))))))
(DFunDef false "buildTupleCallHint" ((PVar "name") (PVar "es") (PVar "f") (PVar "x")) (EMatch (EApp (EVar "renderCallArgs") (EVar "es")) (arm (PCon "Some" (PVar "parts")) () (EBlock (DoLet false false (PVar "argsCsv") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "parts"))) (DoLet false false (PVar "argsSpaced") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EVar "parts"))) (DoLet false false (PVar "spread") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " "))) (EApp (EVar "display") (EVar "argsSpaced"))) (ELit (LString "")))) (DoLet false false (PVar "help") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Medaka calls functions with spaces, not parentheses: `")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "("))) (EApp (EVar "display") (EVar "argsCsv"))) (ELit (LString ")` passes the single tuple `("))) (EApp (EVar "display") (EVar "argsCsv"))) (ELit (LString ")`; did you mean `"))) (EApp (EVar "display") (EVar "spread"))) (ELit (LString "`?")))) (DoLet false false (PVar "fix") (EApp (EApp (EVar "map") (ELam ((PVar "span")) (ETuple (EVar "span") (EVar "spread")))) (EApp (EApp (EVar "tupleCallSpanLoc") (EVar "f")) (EVar "x")))) (DoExpr (ETuple (EVar "help") (EVar "fix"))))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "n") (EApp (EVar "listLen") (EVar "es"))) (DoLet false false (PVar "help") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Medaka calls functions with spaces, not parentheses: `")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "(...)` passes one "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString "-tuple, not "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " arguments; separate them with spaces, as in `"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString " x y`")))) (DoExpr (ETuple (EVar "help") (EVar "None")))))))
(DTypeSig false "tupleCallShapeHint" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "Loc") (TyCon "String")))))))))
(DFunDef false "tupleCallShapeHint" ((PVar "f") (PVar "x") (PVar "ft")) (EMatch (EApp (EVar "tupleArgElems") (EVar "x")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "es")) () (EBlock (DoLet false false (PVar "n") (EApp (EVar "listLen") (EVar "es"))) (DoExpr (EIf (EBinOp "<" (EVar "n") (ELit (LInt 2))) (EVar "None") (EIf (EBinOp "/=" (EApp (EVar "funArity") (EVar "ft")) (EVar "n")) (EVar "None") (EIf (EApp (EApp (EVar "domainIsTupleOfArity") (EVar "ft")) (EVar "n")) (EVar "None") (EApp (EApp (EVar "map") (ELam ((PVar "name")) (EApp (EApp (EApp (EApp (EVar "buildTupleCallHint") (EVar "name")) (EVar "es")) (EVar "f")) (EVar "x")))) (EApp (EVar "appSpineName") (EVar "f")))))))))))
(DTypeSig false "inferApp" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Mono"))))))
(DFunDef false "inferApp" ((PVar "env") (PVar "appExpr") (PVar "ft") (PVar "xt")) (EBlock (DoLet false false (PVar "r") (EApp (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoExpr (EMatch (EApp (EVar "headTyconNameMono") (EVar "ft")) (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EApp (EVar "inferAppNotFunction") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "appExpr")) (EVar "ft")) (EVar "r"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "containerParamScalarArg") (EVar "ft")) (EVar "xt")) (arm (PCon "Some" (PVar "scalarTy")) () (EBlock (DoLet false false (PVar "isDoBind") (EApp (EVar "isDoLoweredAndThenCallee") (EVar "appExpr"))) (DoLet false false (PVar "msg") (EIf (EVar "isDoBind") (EApp (EVar "doBindArgMsg") (EVar "scalarTy")) (EApp (EApp (EVar "containerArgMsg") (EApp (EVar "appSpineName") (EVar "appExpr"))) (EVar "scalarTy")))) (DoLet false false (PVar "hint") (EIf (EVar "isDoBind") (EApp (EVar "doBindArgHint") (EVar "scalarTy")) (EApp (EVar "containerArgHint") (EVar "scalarTy")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushTypeErrorHelpFixAt") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit (LString "T-TYPE-MISMATCH"))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "appArgLoc") (EVar "appExpr"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc"))) (EVar "msg")) (EVar "hint")) (EVar "None"))) (DoExpr (EApp (EApp (EApp (EVar "poisonMismatchVars") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "ft")) (EVar "xt"))) (DoExpr (EApp (EApp (EApp (EVar "poisonMismatchVars") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "r")) (EVar "r"))) (DoExpr (EVar "r")))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "at") (EApp (EApp (EVar "envAtIfSome") (EApp (EVar "appArgLoc") (EVar "appExpr"))) (EVar "env"))) (DoLet false false (PVar "eff") (EApp (EApp (EApp (EApp (EApp (EVar "applicationRow") (EVar "at")) (EVar "appExpr")) (EVar "ft")) (EVar "xt")) (EVar "r"))) (DoExpr (EApp (EApp (EApp (EVar "performEffect") (EFieldAccess (EFieldAccess (EVar "at") "teDyn") "dcModule")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "at") "teDyn") "dcModule") "mcCells") "curEffect")) (EVar "eff"))) (DoExpr (EApp (EApp (EVar "notePerformSite") (EVar "env")) (EVar "eff"))) (DoExpr (EVar "r"))))))))))
(DTypeSig false "argumentInto" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "Option") (TyCon "Expr")) (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit"))))))
(DFunDef false "argumentInto" ((PVar "env") (PVar "arg") (PVar "dom") (PVar "xt")) (EApp (EApp (EApp (EApp (EApp (EVar "argumentIntoOrd") (EVar "False")) (EVar "env")) (EVar "arg")) (EVar "dom")) (EVar "xt")))
(DTypeSig false "argumentIntoOrd" (TyFun (TyCon "Bool") (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "Option") (TyCon "Expr")) (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))))
(DFunDef false "argumentIntoOrd" ((PVar "valueFirst") (PVar "env") (PVar "arg") (PVar "dom") (PVar "xt")) (EBlock (DoExpr (EMatch (EVar "arg") (arm (PCon "Some" (PVar "e")) () (EApp (EApp (EApp (EVar "recordValueFileBound") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "e")) (EVar "dom"))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EMatch (EApp (EVar "normalize") (EVar "dom")) (arm (PCon "TQual" (PVar "d") (PVar "q")) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "unifyIntoOrd") (EFieldAccess (EVar "env") "teDyn")) (EVar "valueFirst")) (EVar "True")) (EVar "d")) (EVar "xt"))) (DoExpr (EApp (EApp (EApp (EVar "wantAuthority") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EApp (EApp (EApp (EVar "argumentAuthority") (EVar "env")) (EApp (EVar "authDomainTop") (EVar "q"))) (EVar "arg")) (EVar "xt"))) (EVar "q"))))) (arm PWild () (EApp (EApp (EApp (EApp (EApp (EVar "unifyIntoOrd") (EFieldAccess (EVar "env") "teDyn")) (EVar "valueFirst")) (EVar "True")) (EVar "dom")) (EVar "xt")))))))
(DTypeSig false "checkedInto" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Mono"))))))
(DFunDef false "checkedInto" ((PVar "env") (PVar "e") (PVar "expected") (PVar "actual")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "recordValueFileBound") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "e")) (EVar "expected"))) (DoExpr (EMatch (EApp (EVar "normalize") (EVar "expected")) (arm (PCon "TQual" PWild PWild) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "argumentInto") (EApp (EApp (EVar "envAtIfSome") (EApp (EVar "exprLoc") (EVar "e"))) (EVar "env"))) (EApp (EVar "Some") (EVar "e"))) (EVar "expected")) (EVar "actual"))) (DoExpr (EVar "expected")))) (arm PWild () (EVar "actual"))))))
(DTypeSig false "appArgExpr" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "appArgExpr" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "appArgExpr") (EVar "e")))
(DFunDef false "appArgExpr" ((PCon "EApp" PWild (PVar "x"))) (EApp (EVar "Some") (EVar "x")))
(DFunDef false "appArgExpr" (PWild) (EVar "None"))
(DTypeSig false "applicationRow" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "EffRow")))))))
(DFunDef false "applicationRow" ((PVar "env") (PVar "appExpr") (PVar "ft") (PVar "xt") (PVar "result")) (EMatch (EApp (EVar "normalize") (EVar "ft")) (arm (PCon "TFun" (PVar "dom") (PVar "row") (PVar "res")) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "argumentInto") (EVar "env")) (EApp (EVar "appArgExpr") (EVar "appExpr"))) (EVar "dom")) (EVar "xt"))) (DoExpr (EApp (EApp (EApp (EVar "bindFrom") (EFieldAccess (EVar "env") "teDyn")) (EVar "result")) (EVar "res"))) (DoExpr (EVar "row")))) (arm PWild () (EBlock (DoLet false false (PVar "unknown") (EApp (EApp (EVar "openRow") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EFieldAccess (EVar "env") "teDyn")) (EVar "ft")) (EApp (EApp (EApp (EVar "TFun") (EVar "xt")) (EVar "unknown")) (EVar "result")))) (DoExpr (EVar "unknown"))))))
(DTypeSig false "inferAppNotFunction" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Mono"))))))
(DFunDef false "inferAppNotFunction" ((PVar "mctx") (PVar "appExpr") (PVar "ft") (PVar "r")) (EBlock (DoLet false false (PVar "applied") (EApp (EVar "appSpineArgCount") (EVar "appExpr"))) (DoLet false false (PVar "takes") (EBinOp "-" (EVar "applied") (ELit (LInt 1)))) (DoLet false false (PVar "loc") (EApp (EApp (EVar "appSpanLoc") (EFieldAccess (EVar "mctx") "mcLoc")) (EVar "appExpr"))) (DoExpr (EMatch (EApp (EVar "appSpineName") (EVar "appExpr")) (arm (PCon "Some" (PVar "name")) () (EIf (EBinOp ">=" (EVar "takes") (ELit (LInt 1))) (EApp (EApp (EApp (EVar "pushTypeError") (EApp (EApp (EVar "mctxAt") (EVar "loc")) (EVar "mctx"))) (ELit (LString "T-NOT-A-FUNCTION"))) (EApp (EApp (EApp (EVar "overAppliedMsg") (EVar "name")) (EVar "takes")) (EVar "applied"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushTypeErrorHelpFixAt") (EVar "mctx")) (ELit (LString "T-NOT-A-FUNCTION"))) (EVar "loc")) (EApp (EApp (EVar "notAFunctionMsgFor") (EApp (EVar "Some") (EVar "name"))) (EApp (EVar "ppMono") (EApp (EVar "normalize") (EVar "ft"))))) (EApp (EVar "notAFunctionHint") (EApp (EVar "Some") (EVar "name")))) (EVar "None")))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushTypeErrorHelpFixAt") (EVar "mctx")) (ELit (LString "T-NOT-A-FUNCTION"))) (EVar "loc")) (EApp (EVar "notAFunctionMsg") (EApp (EVar "ppMono") (EApp (EVar "normalize") (EVar "ft"))))) (EApp (EVar "notAFunctionHint") (EVar "None"))) (EVar "None"))))) (DoExpr (EApp (EApp (EApp (EVar "poisonMismatchVars") (EVar "mctx")) (EVar "r")) (EVar "r"))) (DoExpr (EVar "r"))))
(DTypeSig false "inferLam" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyCon "Mono")))))
(DFunDef false "inferLam" ((PVar "env") (PVar "pats") (PVar "body")) (EApp (EApp (EApp (EApp (EVar "inferLamChecked") (EApp (EApp (EVar "envAtIfSome") (EApp (EVar "exprLoc") (EVar "body"))) (EVar "env"))) (EVar "None")) (EVar "pats")) (EVar "body")))
(DTypeSig false "inferLet" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Bool") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Mono")))))))
(DFunDef false "inferLet" ((PVar "env") (PVar "isFun") (PVar "pat") (PVar "e1") (PVar "e2")) (EIf (EVar "isFun") (EMatch (EVar "pat") (arm (PCon "PVar" (PVar "x") (PVar "xloc") (PVar "bid")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferRecLet") (EVar "env")) (EVar "x")) (EApp (EVar "Some") (EVar "xloc"))) (EVar "bid")) (EVar "e1")) (EVar "e2"))) (arm PWild () (EApp (EApp (EApp (EApp (EVar "inferLetSimple") (EVar "env")) (EVar "pat")) (EVar "e1")) (EVar "e2")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "inferLetSimple") (EVar "env")) (EVar "pat")) (EVar "e1")) (EVar "e2")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "inferRecLet" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "BinderId") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Mono"))))))))
(DFunDef false "inferRecLet" ((PVar "outer") (PVar "x") (PVar "xloc") (PVar "bid") (PVar "e1") (PVar "e2")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EVar "envAtIfSome") (EApp (EVar "exprSpanLoc") (EVar "e1"))) (EVar "outer"))) (DoExpr (EApp (EApp (EApp (EVar "checkRecBindNonFunction") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EVar "e1"))) (DoExpr (EApp (EApp (EVar "enterLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "oblN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls"))) (DoLet false false (PVar "callN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "obls"))) (DoLet false false (PVar "dictN0") (EApp (EApp (EVar "goalsMark") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (DoLet false false (PVar "lscope") (EApp (EApp (EVar "openLocalScopeIf") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x"))) (DoLet false false (PTuple (PVar "t1") (PVar "residuals")) (EApp (EApp (EApp (EVar "inferRecursiveValue") (EVar "env")) (EVar "x")) (EVar "e1"))) (DoExpr (EApp (EApp (EVar "closeLocalScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "lscope"))) (DoExpr (EApp (EApp (EVar "exitLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "addedObls") (EApp (EApp (EVar "wWindow") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls")) (EVar "oblN0"))) (DoExpr (EApp (EApp (EApp (EVar "improveLocalGoals") (EFieldAccess (EVar "env") "teDyn")) (EVar "addedObls")) (EVar "callN0"))) (DoLet false false PWild (EApp (EApp (EVar "finalizeNumBoundary") (EFieldAccess (EVar "env") "teDyn")) (ERecordCreate "NumBoundary" ((fa "nbDisposition" (EApp (EVar "NumBoundaryOwnedMember") (EBinOp "+" (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentLevel") "value") (ELit (LInt 1))))) (fa "nbMembers" (EListLit (EVar "t1"))) (fa "nbSurvivingIds" (EApp (EApp (EApp (EApp (EVar "memberTiedSurvivors") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "t1")) (EVar "addedObls")) (EVar "callN0"))) (fa "nbDefaultObls" (EVar "addedObls")) (fa "nbAmbiguityObls" (EVar "addedObls")) (fa "nbGuard" (EApp (EApp (EApp (EVar "localNumGuard") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "addedObls")) (EVar "callN0"))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordLocalBind") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EVar "xloc")) (EVar "bid")) (EVar "t1"))) (DoLet false false (PVar "sch") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "genBindingRestricted") (EFieldAccess (EVar "env") "teDyn")) (EVar "Tip")) (EApp (EApp (EVar "residualsOf") (ELit (LInt 0))) (EVar "residuals"))) (EVar "True")) (EVar "pureRow")) (EVar "t1"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerLocalScheme") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EVar "sch")) (EVar "oblN0")) (EVar "callN0")) (EVar "dictN0"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerLocalAbsIf") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EVar "lscope")) (EVar "sch")) (EVar "oblN0")) (EVar "callN0"))) (DoExpr (EApp (EApp (EVar "infer") (EApp (EApp (EVar "envAt") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "outer") "teDyn") "dcModule") "mcLoc")) (EApp (EApp (EApp (EVar "seedAlphaLets") (EApp (EApp (EApp (EVar "extendLocalVar") (EVar "env")) (EVar "x")) (EVar "sch"))) (EVar "x")) (EVar "e1")))) (EVar "e2")))))
(DTypeSig false "inferRecursiveValue" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "AuthResidual"))))))))
(DFunDef false "inferRecursiveValue" ((PVar "env") (PVar "name") (PVar "expr")) (EBlock (DoExpr (EApp (EApp (EVar "beginEffectSummaryScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "arity") (EApp (EVar "sourceBindingArity") (EVar "expr"))) (DoLet false false (PVar "owned") (EApp (EApp (EApp (EVar "newBindingSummary") (EVar "arity")) (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule"))) (EApp (EVar "freshEffectSummary") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")))) (DoLet false false (PVar "envSelf") (EApp (EApp (EApp (EVar "extendLocalVar") (EVar "env")) (EVar "name")) (EApp (EVar "monoScheme") (EFieldAccess (EVar "owned") "bsRecursiveValue")))) (DoLet false false (PTuple (PVar "actual") (PVar "immediate")) (EApp (EApp (EApp (EVar "captureEffects") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "curEffect")) (EApp (EVar "joinCellOf") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph"))) (ELam (PWild) (EApp (EApp (EVar "infer") (EVar "envSelf")) (EVar "expr"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "unifySourceDomains") (EFieldAccess (EVar "env") "teDyn")) (EVar "arity")) (EFieldAccess (EVar "owned") "bsValue")) (EVar "actual"))) (DoExpr (EApp (EApp (EApp (EVar "publishProducedResults") (EFieldAccess (EVar "env") "teDyn")) (EVar "owned")) (EListLit (ETuple (EApp (EVar "exprLoc") (EVar "expr")) (EVar "actual"))))) (DoExpr (EApp (EApp (EApp (EVar "recordEffectBody") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EVar "owned") "bsBody")) (EIf (EBinOp "==" (EVar "arity") (ELit (LInt 0))) (EVar "immediate") (EApp (EApp (EVar "bodyRowAt") (EVar "arity")) (EVar "actual"))))) (DoExpr (EApp (EApp (EVar "checkRecursiveValue") (EFieldAccess (EVar "env") "teDyn")) (EVar "owned"))) (DoLet false false (PVar "residuals") (EApp (EApp (EVar "finishValueEffectsKeeping") (EFieldAccess (EVar "env") "teDyn")) (EListLit (ETuple (EVar "True") (EFieldAccess (EVar "owned") "bsValue"))))) (DoExpr (EApp (EApp (EApp (EVar "performEffect") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "curEffect")) (EVar "immediate"))) (DoExpr (ETuple (EFieldAccess (EVar "owned") "bsValue") (EVar "residuals")))))
(DTypeSig false "sourceBindingArity" (TyFun (TyCon "Expr") (TyCon "Int")))
(DFunDef false "sourceBindingArity" ((PCon "ELoc" PWild (PVar "expr"))) (EApp (EVar "sourceBindingArity") (EVar "expr")))
(DFunDef false "sourceBindingArity" ((PCon "EDoOrigin" PWild (PVar "expr"))) (EApp (EVar "sourceBindingArity") (EVar "expr")))
(DFunDef false "sourceBindingArity" ((PCon "EAnnot" (PVar "expr") PWild)) (EApp (EVar "sourceBindingArity") (EVar "expr")))
(DFunDef false "sourceBindingArity" ((PCon "EHeadAnnot" (PVar "expr") PWild)) (EApp (EVar "sourceBindingArity") (EVar "expr")))
(DFunDef false "sourceBindingArity" ((PCon "ELetGroup" PWild (PVar "expr"))) (EApp (EVar "sourceBindingArity") (EVar "expr")))
(DFunDef false "sourceBindingArity" ((PCon "ELam" (PVar "pats") PWild)) (EApp (EVar "listLen") (EVar "pats")))
(DFunDef false "sourceBindingArity" (PWild) (ELit (LInt 0)))
(DTypeSig false "registerLocalScheme" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Scheme") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Unit"))))))))
(DFunDef false "registerLocalScheme" ((PVar "mctx") (PVar "x") (PVar "sch") (PVar "oblN0") (PVar "callN0") (PVar "dictN0")) (EBlock (DoExpr (EApp (EApp (EVar "declareQuantified") (EVar "mctx")) (EVar "sch"))) (DoLet false false (PVar "addedObls") (EApp (EApp (EVar "wWindow") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "implObls")) (EVar "oblN0"))) (DoLet false false (PVar "callOblsDelta") (EApp (EApp (EVar "callOblsWindow") (EVar "mctx")) (EVar "callN0"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerSchemeObligations") (EVar "mctx")) (EVar "omEmpty")) (EListLit)) (EVar "callOblsDelta")) (EVar "addedObls")) (EListLit (ETuple (EVar "x") (EVar "sch")))))))
(DTypeSig false "declareQuantified" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Scheme") (TyCon "Unit"))))
(DFunDef false "declareQuantified" ((PVar "mctx") (PVar "sch")) (EApp (EApp (EVar "declareRigidVars") (EVar "mctx")) (EApp (EApp (EVar "map") (EVar "intToString")) (EApp (EVar "schemeIds") (EVar "sch")))))
(DTypeSig false "inferLetSimple" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Mono"))))))
(DFunDef false "inferLetSimple" ((PVar "outer") (PVar "pat") (PVar "e1") (PVar "e2")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EVar "envAtIfSome") (EApp (EVar "exprSpanLoc") (EVar "e1"))) (EVar "outer"))) (DoExpr (EApp (EApp (EVar "enterLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "beginEffectSummaryScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "oblN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls"))) (DoLet false false (PVar "callN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "obls"))) (DoLet false false (PVar "dictN0") (EApp (EApp (EVar "goalsMark") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (DoLet false false (PVar "lscope") (EMatch (EVar "pat") (arm (PCon "PVar" (PVar "x") PWild PWild) () (EApp (EApp (EVar "openLocalScopeIf") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x"))) (arm PWild () (EVar "None")))) (DoLet false false (PVar "t1") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e1"))) (DoExpr (EApp (EApp (EVar "closeLocalScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "lscope"))) (DoLet false false (PVar "residuals") (EApp (EApp (EVar "finishValueEffectsKeeping") (EFieldAccess (EVar "env") "teDyn")) (EListLit (ETuple (EBinOp "&&" (EApp (EVar "patIsVar") (EVar "pat")) (EApp (EApp (EVar "isNonexpansive") (EVar "env")) (EVar "e1"))) (EVar "t1"))))) (DoExpr (EApp (EApp (EVar "exitLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "addedObls") (EApp (EApp (EVar "wWindow") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls")) (EVar "oblN0"))) (DoExpr (EApp (EApp (EApp (EVar "improveLocalGoals") (EFieldAccess (EVar "env") "teDyn")) (EVar "addedObls")) (EVar "callN0"))) (DoLet false false PWild (EApp (EApp (EVar "finalizeNumBoundary") (EFieldAccess (EVar "env") "teDyn")) (ERecordCreate "NumBoundary" ((fa "nbDisposition" (EApp (EVar "NumBoundaryOwnedMember") (EBinOp "+" (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentLevel") "value") (ELit (LInt 1))))) (fa "nbMembers" (EListLit (EVar "t1"))) (fa "nbSurvivingIds" (EApp (EApp (EApp (EApp (EVar "memberTiedSurvivors") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "t1")) (EVar "addedObls")) (EVar "callN0"))) (fa "nbDefaultObls" (EVar "addedObls")) (fa "nbAmbiguityObls" (EVar "addedObls")) (fa "nbGuard" (EApp (EApp (EApp (EVar "localNumGuard") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "addedObls")) (EVar "callN0"))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferLetBody") (EVar "env")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "outer") "teDyn") "dcModule") "mcLoc")) (EVar "pat")) (EVar "t1")) (EVar "residuals")) (EVar "e1")) (EVar "e2")) (EVar "oblN0")) (EVar "callN0")) (EVar "dictN0")) (EVar "lscope")))))
(DTypeSig false "patIsVar" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "patIsVar" ((PCon "PVar" PWild PWild PWild)) (EVar "True"))
(DFunDef false "patIsVar" (PWild) (EVar "False"))
(DTypeSig false "inferLetBody" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Pat") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "AuthResidual"))) (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "ScopeId")) (TyCon "Mono")))))))))))))
(DFunDef false "inferLetBody" ((PVar "env") (PVar "bodyLoc") (PCon "PVar" (PVar "x") (PVar "xloc") (PVar "bid")) (PVar "t1") (PVar "residuals") (PVar "e1") (PVar "e2") (PVar "oblN0") (PVar "callN0") (PVar "dictN0") (PVar "lscope")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordLocalBind") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EApp (EVar "Some") (EVar "xloc"))) (EVar "bid")) (EVar "t1"))) (DoLet false false (PVar "sch") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "genBindingRestricted") (EFieldAccess (EVar "env") "teDyn")) (EVar "Tip")) (EApp (EApp (EVar "residualsOf") (ELit (LInt 0))) (EVar "residuals"))) (EApp (EApp (EVar "isNonexpansive") (EVar "env")) (EVar "e1"))) (EVar "pureRow")) (EVar "t1"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerLocalScheme") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EVar "sch")) (EVar "oblN0")) (EVar "callN0")) (EVar "dictN0"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerLocalAbsIf") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EVar "lscope")) (EVar "sch")) (EVar "oblN0")) (EVar "callN0"))) (DoExpr (EApp (EApp (EVar "infer") (EApp (EApp (EVar "envAt") (EVar "bodyLoc")) (EApp (EApp (EApp (EVar "seedAlphaLets") (EApp (EApp (EApp (EVar "extendLocalVar") (EVar "env")) (EVar "x")) (EVar "sch"))) (EVar "x")) (EVar "e1")))) (EVar "e2")))))
(DFunDef false "inferLetBody" ((PVar "env") (PVar "bodyLoc") (PVar "pat") (PVar "t1") PWild PWild (PVar "e2") PWild PWild PWild PWild) (EBlock (DoLet false false (PVar "lits") (EApp (EApp (EVar "takePatLits") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "pr") (EApp (EApp (EVar "inferPat") (EVar "env")) (EVar "pat"))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EFieldAccess (EVar "env") "teDyn")) (EApp (EVar "fst") (EVar "pr"))) (EVar "t1"))) (DoExpr (EApp (EApp (EVar "settlePatLits") (EFieldAccess (EVar "env") "teDyn")) (EVar "lits"))) (DoExpr (EApp (EApp (EApp (EVar "checkBinderPat") (EVar "env")) (EApp (EVar "fst") (EVar "pr"))) (EVar "pat"))) (DoExpr (EApp (EApp (EVar "infer") (EApp (EApp (EVar "envAt") (EVar "bodyLoc")) (EApp (EApp (EVar "extendLocalVars") (EVar "env")) (EApp (EVar "snd") (EVar "pr"))))) (EVar "e2")))))
(DTypeSig false "inferIf" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Mono"))))))
(DFunDef false "inferIf" ((PVar "env") (PVar "c") (PVar "t") (PVar "e")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EApp (EApp (EVar "dynAtIfSome") (EApp (EVar "exprSpanLoc") (EVar "c"))) (EFieldAccess (EVar "env") "teDyn"))) (EApp (EApp (EVar "infer") (EVar "env")) (EVar "c"))) (EApp (EVar "tconBuiltin") (ELit (LString "Bool"))))) (DoLet false false (PVar "tt") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "t"))) (DoLet false false (PVar "ee") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e"))) (DoLet false false (PVar "context") (EIf (EApp (EVar "isOmittedElse") (EVar "e")) (EVar "JoinElselessIf") (EVar "JoinIf"))) (DoExpr (EApp (EApp (EApp (EVar "joinValueTypes") (EFieldAccess (EVar "env") "teDyn")) (EVar "context")) (EListLit (ETuple (EApp (EVar "exprLoc") (EVar "t")) (EVar "tt")) (ETuple (EApp (EVar "exprLoc") (EVar "e")) (EVar "ee")))))))
(DTypeSig false "isOmittedElse" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isOmittedElse" ((PCon "ELit" (PCon "LUnit"))) (EVar "True"))
(DFunDef false "isOmittedElse" (PWild) (EVar "False"))
(DTypeSig false "publishProducedResults" (TyFun (TyCon "DynCtx") (TyFun (TyCon "BindingSummary") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono"))) (TyCon "Unit")))))
(DFunDef false "publishProducedResults" ((PVar "dyn") (PVar "owned") (PVar "values")) (EBlock (DoLet false false (PVar "results") (EApp (EApp (EVar "map") (EApp (EVar "clauseResult") (EFieldAccess (EVar "owned") "bsArity"))) (EVar "values"))) (DoLet false false (PVar "produced") (EApp (EApp (EVar "optionOrFresh") (EFieldAccess (EVar "dyn") "dcModule")) (EApp (EApp (EVar "joinProducedEnvelope") (EApp (EApp (EApp (EVar "valueJoinOps") (EVar "dyn")) (EVar "JoinClause")) (ELam (PWild) (EApp (EVar "collectProducedSummary") (EFieldAccess (EVar "dyn") "dcModule"))))) (EVar "results")))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PTuple (PVar "loc") (PVar "lower"))) (EApp (EApp (EApp (EApp (EVar "recordFileValueFlow") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "loc")) (EVar "produced")) (EVar "lower")))) (EVar "results"))) (DoExpr (EMatch (EApp (EApp (EVar "resultAfterArrows") (EFieldAccess (EVar "owned") "bsArity")) (EFieldAccess (EVar "owned") "bsValue")) (arm (PCon "Some" (PVar "expected")) () (EApp (EApp (EApp (EVar "bindFrom") (EVar "dyn")) (EVar "expected")) (EVar "produced"))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "binding source arity differs from its allocated shape"))))))))
(DTypeSig false "clauseResult" (TyFun (TyCon "Int") (TyFun (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono")) (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono")))))
(DFunDef false "clauseResult" ((PVar "arity") (PTuple (PVar "loc") (PVar "value"))) (EMatch (EApp (EApp (EVar "resultAfterArrows") (EVar "arity")) (EVar "value")) (arm (PCon "Some" (PVar "result")) () (ETuple (EVar "loc") (EVar "result"))) (arm (PCon "None") () (ETuple (EVar "loc") (EVar "value")))))
(DTypeSig false "inferProduced" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono"))))))
(DFunDef false "inferProduced" ((PVar "env") (PList)) (EListLit))
(DFunDef false "inferProduced" ((PVar "env") (PCons (PVar "e") (PVar "es"))) (EBlock (DoLet false false (PVar "value") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e"))) (DoExpr (EBinOp "::" (ETuple (EApp (EVar "exprLoc") (EVar "e")) (EVar "value")) (EApp (EApp (EVar "inferProduced") (EVar "env")) (EVar "es"))))))
(DTypeSig false "inferEach" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "inferEach" ((PVar "env") (PList)) (EListLit))
(DFunDef false "inferEach" ((PVar "env") (PCons (PVar "e") (PVar "es"))) (EBlock (DoLet false false (PVar "t") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e"))) (DoExpr (EBinOp "::" (EVar "t") (EApp (EApp (EVar "inferEach") (EVar "env")) (EVar "es"))))))
(DTypeSig false "inferListLit" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Mono"))))
(DFunDef false "inferListLit" ((PVar "env") (PVar "es")) (EBlock (DoLet false false (PVar "elem") (EApp (EApp (EApp (EVar "joinValueTypes") (EFieldAccess (EVar "env") "teDyn")) (EVar "JoinList")) (EApp (EApp (EVar "inferProduced") (EVar "env")) (EVar "es")))) (DoExpr (EApp (EApp (EVar "TApp") (EApp (EVar "tconBuiltin") (ELit (LString "List")))) (EVar "elem")))))
(DTypeSig false "inferAnnot" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyFun (TyCon "Ty") (TyCon "Mono")))))
(DFunDef false "inferAnnot" ((PVar "env") (PVar "e") (PVar "ty")) (EBlock (DoLet false false (PVar "oblN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls"))) (DoLet false false (PVar "callN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "obls"))) (DoLet false false (PVar "t") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e"))) (DoLet false false (PVar "pair") (EApp (EApp (EVar "astTypeFreshTbl") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "ty"))) (DoLet false false (PVar "annot") (EApp (EVar "fst") (EVar "pair"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "argumentIntoOrd") (EVar "True")) (EVar "env")) (EApp (EVar "Some") (EVar "e"))) (EVar "annot")) (EVar "t"))) (DoExpr (EApp (EApp (EApp (EVar "checkAnnotTooGeneral") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "ty")) (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EVar "snd") (EVar "pair"))))) (DoLet false false (PVar "annotation") (EListLit (ETuple (ELit (LString "")) (EVar "ty") (EApp (EVar "snd") (EVar "pair"))))) (DoLet false false (PVar "declared") (EApp (EVar "sccProtectedSignatureIds") (EVar "annotation"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "omSize") (EVar "declared")) (ELit (LInt 0))) (ELit LUnit) (EApp (EApp (EApp (EApp (EApp (EVar "checkSigVarGoals") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "DeclaredByAnnotation")) (EVar "declared")) (EVar "annotation")) (EBinOp "++" (EApp (EApp (EVar "wWindow") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls")) (EVar "oblN0")) (EApp (EApp (EVar "callUOblsWindow") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "callN0")))))) (DoExpr (EVar "annot"))))
(DTypeSig false "inferHeadAnnot" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyFun (TyCon "Ty") (TyCon "Mono")))))
(DFunDef false "inferHeadAnnot" ((PVar "env") (PVar "e") (PVar "ty")) (EBlock (DoLet false false (PVar "t") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e"))) (DoLet false false (PVar "annot") (EApp (EApp (EVar "headAnnotTy") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "ty"))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EFieldAccess (EVar "env") "teDyn")) (EVar "t")) (EVar "annot"))) (DoExpr (EVar "t"))))
(DTypeSig false "inferMatch" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyCon "Mono")))))
(DFunDef false "inferMatch" ((PVar "env") (PVar "scrutTy") (PVar "arms")) (EBlock (DoLet false false (PVar "result") (EApp (EApp (EApp (EVar "joinValueTypes") (EFieldAccess (EVar "env") "teDyn")) (EVar "JoinMatch")) (EApp (EApp (EApp (EVar "inferArms") (EVar "env")) (EVar "scrutTy")) (EVar "arms")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "scheduleMatchChecks") (EVar "env")) (EVar "scrutTy")) (EVar "arms")) (EApp (EApp (EVar "matchWarningLoc") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EVar "arms")))) (DoExpr (EVar "result"))))
(DTypeSig false "scheduleMatchChecks" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit"))))))
(DFunDef false "scheduleMatchChecks" ((PVar "env") (PVar "scrutTy") (PVar "arms") (PVar "loc")) (EMatch (EApp (EVar "normalize") (EVar "scrutTy")) (arm (PCon "TVar" PWild) () (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "matchChecksDeferred")) (EBinOp "::" (ETuple (EVar "scrutTy") (EVar "arms") (EVar "loc")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "matchChecksDeferred") "value")))) (arm PWild () (EApp (EApp (EApp (EVar "checkMatchChecks") (EApp (EApp (EVar "mctxAt") (EVar "loc")) (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule"))) (EVar "scrutTy")) (EVar "arms")))))
(DTypeSig false "checkBinderPats" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Unit")))))
(DFunDef false "checkBinderPats" ((PVar "env") (PList (PVar "t")) (PList (PVar "p"))) (EApp (EApp (EApp (EVar "checkBinderPat") (EVar "env")) (EVar "t")) (EVar "p")))
(DFunDef false "checkBinderPats" ((PVar "env") (PVar "ts") (PVar "ps")) (EIf (EApp (EApp (EVar "allList") (EVar "patIsVar")) (EVar "ps")) (ELit LUnit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "checkBinderPat") (EVar "env")) (EApp (EVar "tupleMono") (EVar "ts"))) (EApp (EVar "PTuple") (EVar "ps"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "binderMarker" (TyCon "String"))
(DFunDef false "binderMarker" () (ELit (LString "<binder>")))
(DTypeSig false "isBinderArms" (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyCon "Bool")))
(DFunDef false "isBinderArms" ((PList (PCon "Arm" PWild (PList) (PCon "EVar" (PVar "n"))))) (EBinOp "==" (EVar "n") (EVar "binderMarker")))
(DFunDef false "isBinderArms" (PWild) (EVar "False"))
(DTypeSig false "checkBinderPat" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Mono") (TyFun (TyCon "Pat") (TyCon "Unit")))))
(DFunDef false "checkBinderPat" ((PVar "env") (PVar "ty") (PVar "pat")) (EIf (EApp (EVar "patIsVar") (EVar "pat")) (ELit LUnit) (EApp (EApp (EApp (EApp (EVar "scheduleMatchChecks") (EVar "env")) (EVar "ty")) (EListLit (EApp (EApp (EApp (EVar "Arm") (EVar "pat")) (EListLit)) (EApp (EVar "EVar") (EVar "binderMarker"))))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc"))))
(DTypeSig false "matchWarningLoc" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "matchWarningLoc" ((PCon "Some" (PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))) (PVar "arms")) (EMatch (EApp (EVar "last") (EVar "arms")) (arm (PCon "Some" (PCon "Arm" PWild PWild (PVar "body"))) () (EMatch (EApp (EVar "exprSpanLoc") (EVar "body")) (arm (PCon "Some" (PCon "Loc" PWild PWild PWild (PVar "bel") (PVar "bec"))) ((GBool (EBinOp "<" (EVar "bel") (EVar "el")))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "bel")) (EVar "bec")))) (arm PWild () (EMatch (EApp (EVar "exprLoc") (EVar "body")) (arm (PCon "Some" (PCon "Loc" PWild PWild PWild (PVar "bel") (PVar "bec"))) ((GBool (EBinOp "&&" (EBinOp "==" (EVar "bel") (EVar "el")) (EBinOp "<" (EVar "bec") (EVar "ec"))))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "bel")) (EVar "bec")))) (arm PWild () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec")))))))) (arm (PCon "None") () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec"))))))
(DFunDef false "matchWarningLoc" ((PCon "None") PWild) (EVar "None"))
(DTypeSig true "checkMatchChecks" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyCon "Unit")))))
(DFunDef false "checkMatchChecks" ((PVar "mctx") (PVar "scrutTy") (PVar "arms")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "checkMatchExhaustive") (EVar "mctx")) (EVar "scrutTy")) (EVar "arms"))) (DoExpr (EApp (EApp (EApp (EVar "checkMatchRedundant") (EVar "mctx")) (EVar "scrutTy")) (EVar "arms")))))
(DTypeSig true "checkDeferredMatches" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Arm")) (TyApp (TyCon "Option") (TyCon "Loc")))) (TyCon "Unit"))))
(DFunDef false "checkDeferredMatches" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "checkDeferredMatches" ((PVar "mctx") (PCons (PTuple (PVar "scrutTy") (PVar "arms") (PVar "loc")) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "checkMatchChecks") (EApp (EApp (EVar "mctxAt") (EVar "loc")) (EVar "mctx"))) (EVar "scrutTy")) (EVar "arms"))) (DoExpr (EApp (EApp (EVar "checkDeferredMatches") (EVar "mctx")) (EVar "rest")))))
(DTypeSig false "checkMatchExhaustive" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyCon "Unit")))))
(DFunDef false "checkMatchExhaustive" ((PVar "mctx") (PVar "scrutTy") (PVar "arms")) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EVar "nonGuardedRows") (EVar "mctx")) (EVar "arms"))) (DoExpr (EIf (EApp (EApp (EApp (EApp (EVar "useful") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchOracle") "value")) (EApp (EVar "matchCol0Type") (EVar "scrutTy"))) (EVar "rows")) (EListLit (EVar "PWild"))) (EBlock (DoLet false false (PVar "binder") (EApp (EVar "isBinderArms") (EVar "arms"))) (DoLet false false (PTuple (PVar "msg") (PVar "help")) (EApp (EApp (EApp (EApp (EVar "nonExhaustiveMsg") (EVar "mctx")) (EVar "scrutTy")) (EVar "rows")) (EVar "binder"))) (DoExpr (EIf (EBinOp "&&" (EVar "binder") (EApp (EApp (EVar "anyList") (EApp (EVar "warnedAt") (EFieldAccess (EVar "mctx") "mcLoc"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchWarnings") "value"))) (ELit LUnit) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchWarnings")) (EBinOp "::" (EApp (EVar "writtenDiag") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "W-NONEXHAUSTIVE"))) (ELit (LInt 2))) (EFieldAccess (EVar "mctx") "mcLoc")) (EVar "msg")) (EVar "help")) (EVar "None"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchWarnings") "value")))))) (ELit LUnit)))))
(DTypeSig false "warnedAt" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "TcDiag") (TyCon "Bool"))))
(DFunDef false "warnedAt" ((PVar "loc") (PCon "TcDiag" (PVar "code") PWild (PVar "at") PWild PWild PWild)) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "code") (ELit (LString "W-NONEXHAUSTIVE"))) (EBinOp "/=" (EApp (EVar "locKey") (EVar "loc")) (ELit (LString "")))) (EBinOp "==" (EApp (EVar "locKey") (EVar "at")) (EApp (EVar "locKey") (EVar "loc")))))
(DTypeSig false "checkMatchRedundant" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyCon "Unit")))))
(DFunDef false "checkMatchRedundant" ((PVar "mctx") (PVar "scrutTy") (PVar "arms")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkRedundantGo") (EVar "mctx")) (EApp (EVar "matchCol0Type") (EVar "scrutTy"))) (EListLit)) (EVar "omEmpty")) (EVar "False")) (EVar "arms")))
(DTypeSig false "checkRedundantGo" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "TabKey")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyCon "Unit"))))))))
(DFunDef false "checkRedundantGo" ((PVar "mctx") PWild PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "checkRedundantGo" ((PVar "mctx") (PVar "col0") (PVar "prec") (PVar "heads") (PVar "offCol") (PCons (PCon "Arm" (PVar "pat") (PVar "gs") (PVar "body")) (PVar "rest"))) (EBlock (DoLet false false (PVar "dp") (EApp (EApp (EVar "desugarPat") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchOracle") "value")) (EVar "pat"))) (DoExpr (EIf (EApp (EApp (EApp (EApp (EApp (EApp (EVar "armUnreachable") (EVar "mctx")) (EVar "col0")) (EVar "prec")) (EVar "heads")) (EVar "offCol")) (EVar "dp")) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchWarnings")) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "W-UNREACHABLE-ARM"))) (ELit (LInt 2))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "exprLoc") (EVar "body"))) (EFieldAccess (EVar "mctx") "mcLoc"))) (EVar "unreachableArmWarning")) (EVar "None")) (EVar "None")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchWarnings") "value"))) (ELit LUnit))) (DoLet false false (PVar "contributes") (EBinOp "&&" (EApp (EVar "armIsUnguarded") (EVar "gs")) (EApp (EVar "not") (EApp (EVar "patHasRange") (EVar "pat"))))) (DoLet false false (PVar "prec2") (EIf (EVar "contributes") (EBinOp "::" (EListLit (EVar "dp")) (EVar "prec")) (EVar "prec"))) (DoLet false false (PVar "heads2") (EIf (EVar "contributes") (EApp (EApp (EVar "noteHeadCtor") (EVar "dp")) (EVar "heads")) (EVar "heads"))) (DoLet false false (PVar "offCol2") (EBinOp "||" (EVar "offCol") (EBinOp "&&" (EVar "contributes") (EApp (EVar "not") (EApp (EVar "isConPat") (EVar "dp")))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkRedundantGo") (EVar "mctx")) (EVar "col0")) (EVar "prec2")) (EVar "heads2")) (EVar "offCol2")) (EVar "rest")))))
(DTypeSig false "armUnreachable" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "TabKey")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Bool") (TyFun (TyCon "Pat") (TyCon "Bool"))))))))
(DFunDef false "armUnreachable" ((PVar "mctx") (PVar "col0") (PVar "prec") (PVar "heads") (PVar "offCol") (PCon "PCon" (PVar "c") (PVar "args"))) (EIf (EBinOp "&&" (EApp (EVar "not") (EVar "offCol")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "c")) (EVar "heads")))) (EVar "False") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "patUnreachable") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchOracle") "value")) (EVar "col0")) (EVar "prec")) (EApp (EApp (EVar "PCon") (EVar "c")) (EVar "args"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "armUnreachable" ((PVar "mctx") (PVar "col0") (PVar "prec") PWild PWild (PVar "dp")) (EApp (EApp (EApp (EApp (EVar "patUnreachable") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchOracle") "value")) (EVar "col0")) (EVar "prec")) (EVar "dp")))
(DTypeSig false "noteHeadCtor" (TyFun (TyCon "Pat") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "noteHeadCtor" ((PCon "PCon" (PVar "c") PWild) (PVar "heads")) (EApp (EApp (EApp (EVar "omInsert") (EVar "c")) (ELit LUnit)) (EVar "heads")))
(DFunDef false "noteHeadCtor" (PWild (PVar "heads")) (EVar "heads"))
(DTypeSig false "isConPat" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "isConPat" ((PCon "PCon" PWild PWild)) (EVar "True"))
(DFunDef false "isConPat" (PWild) (EVar "False"))
(DTypeSig false "armIsUnguarded" (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyCon "Bool")))
(DFunDef false "armIsUnguarded" ((PList)) (EVar "True"))
(DFunDef false "armIsUnguarded" ((PCons PWild PWild)) (EVar "False"))
(DTypeSig false "nonExhaustiveMsg" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyCon "Bool") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))))
(DFunDef false "nonExhaustiveMsg" ((PVar "mctx") (PVar "scrutTy") (PVar "rows") (PVar "binder")) (EMatch (EApp (EApp (EApp (EApp (EVar "usefulWitness") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchOracle") "value")) (EApp (EVar "matchCol0Type") (EVar "scrutTy"))) (EVar "rows")) (ELit (LInt 1))) (arm (PCon "Some" (PCons (PVar "w") PWild)) () (EBlock (DoLet false false (PVar "witnessStr") (EApp (EVar "renderWitness") (EVar "w"))) (DoExpr (EIf (EVar "binder") (EBlock (DoLet false false (PTuple (PVar "msg") (PVar "hint")) (EApp (EApp (EVar "binderNonExhaustiveMsg") (EApp (EVar "matchCol0Type") (EVar "scrutTy"))) (EVar "witnessStr"))) (DoExpr (ETuple (EVar "msg") (EApp (EVar "Some") (EVar "hint"))))) (EBlock (DoLet false false (PVar "hint") (EIf (EBinOp "==" (EVar "witnessStr") (ELit (LString "_"))) (ELit (LString "add a `_ => ...` arm")) (EBinOp "++" (EBinOp "++" (ELit (LString "add a `")) (EApp (EVar "display") (EVar "witnessStr"))) (ELit (LString " => ...` arm or a `_` wildcard"))))) (DoLet false false (PVar "msg") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Warning: non-exhaustive match")) (EApp (EVar "display") (EApp (EVar "tyOfMsg") (EApp (EVar "matchCol0Type") (EVar "scrutTy"))))) (ELit (LString ": missing `"))) (EApp (EVar "display") (EVar "witnessStr"))) (ELit (LString "`; "))) (EApp (EVar "display") (EVar "hint"))) (ELit (LString "")))) (DoExpr (ETuple (EVar "msg") (EApp (EVar "Some") (EVar "hint"))))))))) (arm PWild () (ETuple (EVar "nonExhaustiveMatchWarning") (EVar "None")))))
(DTypeSig false "nonGuardedRows" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))))))
(DFunDef false "nonGuardedRows" ((PVar "mctx") (PList)) (EListLit))
(DFunDef false "nonGuardedRows" ((PVar "mctx") (PCons (PCon "Arm" (PVar "pat") (PList) PWild) (PVar "rest"))) (EBinOp "::" (EListLit (EApp (EApp (EVar "desugarPat") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchOracle") "value")) (EVar "pat"))) (EApp (EApp (EVar "nonGuardedRows") (EVar "mctx")) (EVar "rest"))))
(DFunDef false "nonGuardedRows" ((PVar "mctx") (PCons (PCon "Arm" PWild PWild PWild) (PVar "rest"))) (EApp (EApp (EVar "nonGuardedRows") (EVar "mctx")) (EVar "rest")))
(DTypeSig false "inferArms" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono")))))))
(DFunDef false "inferArms" ((PVar "env") PWild (PList)) (EListLit))
(DFunDef false "inferArms" ((PVar "env") (PVar "scrutTy") (PCons (PCon "Arm" (PVar "pat") (PVar "gs") (PVar "body")) (PVar "rest"))) (EBlock (DoLet false false (PVar "value") (EApp (EApp (EApp (EApp (EApp (EVar "inferArm") (EVar "env")) (EVar "scrutTy")) (EVar "pat")) (EVar "gs")) (EVar "body"))) (DoExpr (EBinOp "::" (ETuple (EApp (EVar "exprLoc") (EVar "body")) (EVar "value")) (EApp (EApp (EApp (EVar "inferArms") (EVar "env")) (EVar "scrutTy")) (EVar "rest"))))))
(DTypeSig false "inferArm" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Mono") (TyFun (TyCon "Pat") (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyFun (TyCon "Expr") (TyCon "Mono")))))))
(DFunDef false "inferArm" ((PVar "env") (PVar "scrutTy") (PVar "pat") (PVar "gs") (PVar "body")) (EIf (EBinOp "&&" (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph") "graphRun") "anyExistentialsRef") "value") (EApp (EApp (EVar "patOpensExistentials") (EVar "env")) (EVar "pat"))) (EApp (EApp (EApp (EApp (EApp (EVar "inferArmOpening") (EVar "env")) (EVar "scrutTy")) (EVar "pat")) (EVar "gs")) (EVar "body")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "lits") (EApp (EApp (EVar "takePatLits") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "pr") (EApp (EApp (EVar "inferPat") (EVar "env")) (EVar "pat"))) (DoExpr (EApp (EApp (EApp (EVar "bindFrom") (EFieldAccess (EVar "env") "teDyn")) (EApp (EVar "fst") (EVar "pr"))) (EVar "scrutTy"))) (DoExpr (EApp (EApp (EVar "settlePatLits") (EFieldAccess (EVar "env") "teDyn")) (EVar "lits"))) (DoLet false false (PVar "envBody") (EApp (EApp (EVar "inferArmGuards") (EApp (EApp (EVar "extendLocalVars") (EVar "env")) (EApp (EVar "snd") (EVar "pr")))) (EVar "gs"))) (DoExpr (EApp (EApp (EVar "infer") (EVar "envBody")) (EVar "body")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "inferArmOpening" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Mono") (TyFun (TyCon "Pat") (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyFun (TyCon "Expr") (TyCon "Mono")))))))
(DFunDef false "inferArmOpening" ((PVar "env") (PVar "scrutTy") (PVar "pat") (PVar "gs") (PVar "body")) (EBlock (DoLet false false (PVar "lits") (EApp (EApp (EVar "takePatLits") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "pr") (EApp (EApp (EVar "inferPat") (EVar "env")) (EVar "pat"))) (DoExpr (EApp (EApp (EApp (EVar "bindFrom") (EFieldAccess (EVar "env") "teDyn")) (EApp (EVar "fst") (EVar "pr"))) (EVar "scrutTy"))) (DoLet false false (PVar "scope") (EApp (EApp (EVar "openExistentialScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EApp (EVar "takeOpenedExistentials") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "settlePatLits") (EFieldAccess (EVar "env") "teDyn")) (EVar "lits"))) (DoLet false false (PVar "envBody") (EApp (EApp (EVar "inferArmGuards") (EApp (EApp (EVar "extendLocalVars") (EVar "env")) (EApp (EVar "snd") (EVar "pr")))) (EVar "gs"))) (DoLet false false (PVar "t") (EApp (EApp (EVar "infer") (EVar "envBody")) (EVar "body"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "closeExistentialScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "scope")) (EVar "t")) (EApp (EVar "exprLoc") (EVar "body")))) (DoExpr (EVar "t"))))
(DTypeSig false "inferArmGuards" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyCon "TcEnv"))))
(DFunDef false "inferArmGuards" ((PVar "env") (PList)) (EVar "env"))
(DFunDef false "inferArmGuards" ((PVar "env") (PCons (PCon "GBool" (PVar "g")) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EApp (EApp (EVar "dynAtIfSome") (EApp (EVar "exprSpanLoc") (EVar "g"))) (EFieldAccess (EVar "env") "teDyn"))) (EApp (EApp (EVar "infer") (EVar "env")) (EVar "g"))) (EApp (EVar "tconBuiltin") (ELit (LString "Bool"))))) (DoExpr (EApp (EApp (EVar "inferArmGuards") (EVar "env")) (EVar "rest")))))
(DFunDef false "inferArmGuards" ((PVar "env") (PCons (PCon "GBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "te") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e"))) (DoLet false false (PVar "at") (EApp (EApp (EVar "envAtIfSome") (EApp (EVar "exprSpanLoc") (EVar "e"))) (EVar "env"))) (DoLet false false (PVar "lits") (EApp (EApp (EVar "takePatLits") (EFieldAccess (EFieldAccess (EVar "at") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "pr") (EApp (EApp (EVar "inferPat") (EVar "at")) (EVar "p"))) (DoExpr (EApp (EApp (EApp (EVar "bindFrom") (EFieldAccess (EVar "at") "teDyn")) (EApp (EVar "fst") (EVar "pr"))) (EVar "te"))) (DoExpr (EApp (EApp (EVar "settlePatLits") (EFieldAccess (EVar "at") "teDyn")) (EVar "lits"))) (DoExpr (EApp (EApp (EVar "inferArmGuards") (EApp (EApp (EVar "extendLocalVars") (EVar "env")) (EApp (EVar "snd") (EVar "pr")))) (EVar "rest")))))
(DTypeSig false "inferLetGroup" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyCon "Expr") (TyCon "Mono")))))
(DFunDef false "inferLetGroup" ((PVar "env") (PVar "binds") (PVar "body")) (EBlock (DoExpr (EApp (EApp (EVar "checkLetGroupBindsLocated") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "binds"))) (DoLet false false (PVar "env2") (EApp (EApp (EApp (EVar "fold") (EVar "processLetGroup")) (EVar "env")) (EApp (EVar "letGroupComponents") (EVar "binds")))) (DoExpr (EApp (EApp (EVar "infer") (EVar "env2")) (EVar "body")))))
(DTypeSig false "processLetGroup" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyCon "TcEnv"))))
(DFunDef false "processLetGroup" ((PVar "env") (PVar "binds")) (EBlock (DoExpr (EApp (EApp (EVar "enterLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "beginEffectSummaryScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "oblN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls"))) (DoLet false false (PVar "callN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "obls"))) (DoLet false false (PVar "dictN0") (EApp (EApp (EVar "goalsMark") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (DoLet false false (PVar "summaries") (EApp (EApp (EVar "map") (EApp (EVar "localBindingSummary") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule"))) (EVar "binds"))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PVar "entry")) (EApp (EApp (EVar "recordLetBindType") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "entry")))) (EApp (EApp (EVar "zipL") (EVar "binds")) (EVar "summaries")))) (DoLet false false (PVar "placeholders") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (ETuple (EApp (EVar "fst") (EVar "p")) (EApp (EVar "monoScheme") (EFieldAccess (EApp (EVar "snd") (EVar "p")) "bsValue"))))) (EVar "summaries"))) (DoLet false false (PVar "recursive") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (ETuple (EApp (EVar "fst") (EVar "p")) (EApp (EVar "monoScheme") (EFieldAccess (EApp (EVar "snd") (EVar "p")) "bsRecursiveValue"))))) (EVar "summaries"))) (DoLet false false (PVar "env2") (EApp (EApp (EVar "extendLocalVars") (EVar "env")) (EVar "recursive"))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PVar "bind")) (EApp (EApp (EVar "forgetLocalAbs") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EApp (EVar "letBindName") (EVar "bind"))))) (EVar "binds"))) (DoLet false false (PVar "lscopes") (EApp (EApp (EVar "inferLetBinds") (EVar "env2")) (EApp (EApp (EVar "zipL") (EVar "binds")) (EVar "summaries")))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PVar "entry")) (EApp (EApp (EVar "checkRecursiveValue") (EFieldAccess (EVar "env") "teDyn")) (EApp (EVar "snd") (EVar "entry"))))) (EVar "summaries"))) (DoLet false false (PVar "residuals") (EApp (EApp (EVar "finishValueEffectsKeeping") (EFieldAccess (EVar "env") "teDyn")) (EApp (EApp (EVar "map") (EApp (EVar "letBindGeneralizes") (EVar "env"))) (EApp (EApp (EVar "zipL") (EVar "binds")) (EVar "summaries"))))) (DoExpr (EApp (EApp (EVar "flushPendingEscapes") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcGroup"))) (DoExpr (EApp (EApp (EVar "exitLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "addedObls") (EApp (EApp (EVar "wWindow") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls")) (EVar "oblN0"))) (DoExpr (EApp (EApp (EApp (EVar "improveLocalGoals") (EFieldAccess (EVar "env") "teDyn")) (EVar "addedObls")) (EVar "callN0"))) (DoLet false false (PVar "memberMonos") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EVar "schemeMono") (EApp (EVar "snd") (EVar "p"))))) (EVar "placeholders"))) (DoLet false false PWild (EApp (EApp (EVar "finalizeNumBoundary") (EFieldAccess (EVar "env") "teDyn")) (ERecordCreate "NumBoundary" ((fa "nbDisposition" (EApp (EVar "NumBoundaryOwnedGroup") (EBinOp "+" (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentLevel") "value") (ELit (LInt 1))))) (fa "nbMembers" (EVar "memberMonos")) (fa "nbSurvivingIds" (EVar "omEmpty")) (fa "nbDefaultObls" (EVar "addedObls")) (fa "nbAmbiguityObls" (EVar "addedObls")) (fa "nbGuard" (EApp (EApp (EApp (EVar "localNumGuard") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "addedObls")) (EVar "callN0"))))))) (DoLet false false (PVar "genv") (EApp (EApp (EApp (EApp (EVar "generalizeGroup") (EVar "env")) (EVar "residuals")) (ELit (LInt 0))) (EApp (EApp (EVar "zipL") (EVar "binds")) (EVar "placeholders")))) (DoLet false false (PVar "callOblsDelta") (EApp (EApp (EVar "callOblsWindow") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "callN0"))) (DoLet false false (PVar "schemes") (EApp (EApp (EVar "groupSchemesOf") (EVar "genv")) (EVar "binds"))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PVar "p")) (EApp (EApp (EVar "declareQuantified") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EVar "snd") (EVar "p"))))) (EVar "schemes"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerSchemeObligations") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "omEmpty")) (EListLit)) (EVar "callOblsDelta")) (EVar "addedObls")) (EVar "schemes"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "registerLocalGroupAbs") (EVar "genv")) (EVar "oblN0")) (EVar "callN0")) (EApp (EApp (EVar "zipL") (EVar "binds")) (EVar "lscopes")))) (DoExpr (EVar "genv"))))
(DTypeSig false "groupSchemesOf" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))
(DFunDef false "groupSchemesOf" ((PVar "env") (PList)) (EListLit))
(DFunDef false "groupSchemesOf" ((PVar "genv") (PCons (PCon "LetBind" (PVar "name") PWild PWild PWild) (PVar "rest"))) (EMatch (EApp (EApp (EVar "lookupVar") (EVar "genv")) (EVar "name")) (arm (PCon "Some" (PVar "sch")) () (EBinOp "::" (ETuple (EVar "name") (EVar "sch")) (EApp (EApp (EVar "groupSchemesOf") (EVar "genv")) (EVar "rest")))) (arm (PCon "None") () (EApp (EApp (EVar "groupSchemesOf") (EVar "genv")) (EVar "rest")))))
(DTypeSig false "inferLetBinds" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "LetBind") (TyTuple (TyCon "String") (TyCon "BindingSummary")))) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "ScopeId"))))))
(DFunDef false "inferLetBinds" ((PVar "env") (PList)) (EListLit))
(DFunDef false "inferLetBinds" ((PVar "env") (PCons (PTuple (PAs "bind" (PCon "LetBind" (PVar "name") (PVar "clauses") PWild PWild)) (PTuple PWild (PVar "owned"))) (PVar "rest"))) (EBlock (DoLet false false (PVar "pairs") (EApp (EApp (EVar "map") (EVar "funClausePair")) (EVar "clauses"))) (DoLet false false (PVar "lscope") (EIf (EApp (EVar "isLocalAbsName") (EVar "name")) (EApp (EVar "Some") (EApp (EApp (EVar "openLocalScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name"))) (EVar "None"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "inferMemberClauses") (EVar "env")) (EVar "None")) (EVar "owned")) (EVar "pairs"))) (DoExpr (EApp (EApp (EVar "closeLocalScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "lscope"))) (DoExpr (EMatch (EVar "pairs") (arm (PList (PTuple (PList) PWild)) () (EApp (EApp (EApp (EVar "performEffect") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "curEffect")) (EFieldAccess (EVar "owned") "bsForce"))) (arm PWild () (ELit LUnit)))) (DoExpr (EBinOp "::" (EVar "lscope") (EApp (EApp (EVar "inferLetBinds") (EVar "env")) (EVar "rest"))))))
(DTypeSig true "declareRigidVars" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "declareRigidVars" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "declareRigidVars" ((PVar "mctx") (PVar "keys")) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "declaredSigVarIds")) (EApp (EApp (EVar "omFromNames") (EVar "keys")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "declaredSigVarIds") "value"))))
(DTypeSig true "preunifySigsEx" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyApp (TyCon "List") (TyCon "ScopedMember")) (TyTuple (TyApp (TyCon "List") (TyCon "ConstraintReg")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))))))))
(DFunDef false "preunifySigsEx" ((PVar "mctx") PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "preunifySigsEx" ((PVar "mctx") (PVar "sigs") (PCons (PVar "member") (PVar "rest"))) (EBlock (DoLet false false (PVar "m") (EFieldAccess (EVar "member") "smName")) (DoLet false false (PVar "v") (EFieldAccess (EVar "member") "smMono")) (DoLet false false (PTuple (PVar "restRegs") (PVar "restTvs")) (EApp (EApp (EApp (EVar "preunifySigsEx") (EVar "mctx")) (EVar "sigs")) (EVar "rest"))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "m")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "sigTyMapRef") "value")) (arm (PCon "Some" (PVar "ty")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "member") "smSigned")) (EVar "True"))) (DoLet false false (PTuple (PVar "signedMono") (PVar "tvs") (PVar "forceBound")) (EApp (EApp (EVar "instantiateSigTracked") (EVar "mctx")) (EVar "ty"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "member") "smDeclaredRoots")) (EApp (EApp (EVar "effectRowRoots") (EApp (EApp (EVar "optionOr") (EVar "pureRow")) (EVar "forceBound"))) (EApp (EApp (EVar "effectRoots") (EVar "signedMono")) (EVar "Tip"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "member") "smDeclaredAuths")) (EApp (EApp (EVar "authRowRoots") (EApp (EApp (EVar "optionOr") (EVar "pureRow")) (EVar "forceBound"))) (EApp (EApp (EVar "authRoots") (EVar "signedMono")) (EVar "Tip"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "member") "smForceBound")) (EVar "forceBound"))) (DoLet false false (PTuple (PVar "declaredScheme") (PVar "declaredTvs")) (EApp (EApp (EVar "sigToSchemeTvs") (EVar "mctx")) (EVar "ty"))) (DoLet false false (PCon "Forall" (PVar "ids") (PVar "eids") (PVar "aids") PWild (PVar "declaredForce") (PVar "declaredValue")) (EVar "declaredScheme")) (DoLet false false (PVar "slots") (EApp (EApp (EVar "declaredPredicateSlots") (EApp (EApp (EVar "constraintVarIfaceMonos") (EApp (EVar "sigConstraints") (EVar "ty"))) (EVar "declaredTvs"))) (EApp (EApp (EApp (EApp (EVar "constraintVarArgMonos") (EVar "mctx")) (EApp (EVar "sigConstraints") (EVar "ty"))) (EApp (EVar "sigConstraintArgTys") (EVar "ty"))) (EVar "declaredTvs")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "member") "smRecursive")) (EApp (EVar "Some") (ERecordCreate "EnvBinding" ((fa "ebValue" (ERecordCreate "ValueScheme" ((fa "vsScheme" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Forall") (EVar "ids")) (EVar "eids")) (EVar "aids")) (EListLit)) (EMatch (EVar "forceBound") (arm (PCon "Some" PWild) () (EVar "declaredForce")) (arm (PCon "None") () (EApp (EApp (EVar "optionOr") (EVar "pureRow")) (EFieldAccess (EVar "member") "smForce"))))) (EVar "declaredValue"))) (fa "vsDeclared" (EApp (EVar "Some") (ERecordCreate "CDeclared" ((fa "cdSlots" (EApp (EVar "predicateSlotCSlots") (EVar "slots"))) (fa "cdPrefix" (EApp (EVar "CDPLen") (EApp (EVar "listLen") (EApp (EVar "dedupSlotVecs") (EApp (EApp (EVar "map") (EVar "predicateSlotView")) (EVar "slots")))))) (fa "cdArgs" (EApp (EVar "predicateSlotArgs") (EVar "slots")))))))))) (fa "ebMethodRow" (EVar "None")) (fa "ebStandalone" (EVar "None"))))))) (DoExpr (EApp (EApp (EApp (EVar "bindFrom") (EApp (EVar "dynFor") (EVar "mctx"))) (EVar "v")) (EVar "signedMono"))) (DoLet false false (PVar "regs") (EListLit (ERecordCreate "ConstraintReg" ((fa "crName" (EVar "m")) (fa "crScope" (EFieldAccess (EVar "member") "smScope")) (fa "crIfaceMonos" (EApp (EApp (EVar "constraintVarIfaceMonos") (EApp (EVar "sigConstraints") (EVar "ty"))) (EVar "tvs"))) (fa "crArgVecs" (EApp (EApp (EApp (EApp (EVar "constraintVarArgMonos") (EVar "mctx")) (EApp (EVar "sigConstraints") (EVar "ty"))) (EApp (EVar "sigConstraintArgTys") (EVar "ty"))) (EVar "tvs"))))))) (DoExpr (ETuple (EBinOp "++" (EVar "regs") (EVar "restRegs")) (EBinOp "::" (ETuple (EVar "m") (EVar "ty") (EVar "tvs")) (EVar "restTvs")))))) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EApp (EVar "unify") (EVar "mctx")) (EVar "v")) (EFieldAccess (EFieldAccess (EVar "member") "smOwned") "bsValue"))) (DoExpr (ETuple (EVar "restRegs") (EVar "restTvs")))))))))
(DTypeSig true "valueSpanLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "valueSpanLoc" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "valueSpanLoc" ((PCon "ELet" PWild PWild PWild PWild (PVar "body"))) (EApp (EVar "valueSpanLoc") (EVar "body")))
(DFunDef false "valueSpanLoc" ((PCon "ELetGroup" PWild (PVar "body"))) (EApp (EVar "valueSpanLoc") (EVar "body")))
(DFunDef false "valueSpanLoc" ((PCon "EBlock" (PVar "stmts"))) (EMatch (EApp (EVar "last") (EVar "stmts")) (arm (PCon "Some" (PCon "DoExpr" (PVar "e"))) () (EApp (EVar "valueSpanLoc") (EVar "e"))) (arm PWild () (EApp (EVar "exprSpanLoc") (EApp (EVar "EBlock") (EVar "stmts"))))))
(DFunDef false "valueSpanLoc" ((PVar "e")) (EApp (EVar "exprSpanLoc") (EVar "e")))
(DTypeSig true "inferMemberClauses" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "Option") (TyCon "Mono")) (TyFun (TyCon "BindingSummary") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyApp (TyCon "List") (TyCon "Atom")))))))
(DFunDef false "inferMemberClauses" ((PVar "env") PWild PWild (PList)) (EListLit))
(DFunDef false "inferMemberClauses" ((PVar "env") (PVar "peel") (PVar "owned") (PVar "clauses")) (EBlock (DoLet false false (PTuple (PVar "values") (PVar "effects")) (EApp (EApp (EApp (EApp (EVar "inferClauseValues") (EVar "env")) (EVar "peel")) (EVar "owned")) (EVar "clauses"))) (DoExpr (EApp (EApp (EApp (EVar "publishProducedResults") (EFieldAccess (EVar "env") "teDyn")) (EVar "owned")) (EVar "values"))) (DoExpr (EApp (EVar "effrowLabels") (EApp (EApp (EVar "collectRows") (EApp (EVar "joinCellOf") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph"))) (EVar "effects"))))))
(DTypeSig false "inferClauseValues" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "Option") (TyCon "Mono")) (TyFun (TyCon "BindingSummary") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "EffRow"))))))))
(DFunDef false "inferClauseValues" ((PVar "env") PWild PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "inferClauseValues" ((PVar "env") (PVar "peel") (PVar "owned") (PCons (PVar "cl") (PVar "rest"))) (EBlock (DoLet false false (PVar "ce") (EApp (EApp (EApp (EVar "inferClauseEff") (EVar "env")) (EVar "peel")) (EVar "cl"))) (DoLet false false (PVar "value") (EApp (EVar "valueSpanLoc") (EApp (EVar "snd") (EVar "cl")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "unifySourceDomains") (EApp (EApp (EVar "dynAtIfSome") (EVar "value")) (EFieldAccess (EVar "env") "teDyn"))) (EApp (EVar "listLen") (EApp (EVar "fst") (EVar "cl")))) (EFieldAccess (EVar "owned") "bsValue")) (EApp (EVar "fst") (EVar "ce")))) (DoExpr (EApp (EApp (EApp (EVar "recordEffectBody") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EVar "owned") "bsBody")) (EApp (EVar "snd") (EVar "ce")))) (DoLet false false (PTuple (PVar "values") (PVar "effects")) (EApp (EApp (EApp (EApp (EVar "inferClauseValues") (EVar "env")) (EVar "peel")) (EVar "owned")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (ETuple (EVar "value") (EApp (EVar "fst") (EVar "ce"))) (EVar "values")) (EBinOp "::" (EApp (EVar "snd") (EVar "ce")) (EVar "effects"))))))
(DTypeSig false "inferClauseEff" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "Option") (TyCon "Mono")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyTuple (TyCon "Mono") (TyCon "EffRow"))))))
(DFunDef false "inferClauseEff" ((PVar "outer") (PVar "peel") (PTuple (PVar "pats") (PVar "body"))) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EVar "envAtIfSome") (EApp (EVar "exprSpanLoc") (EVar "body"))) (EVar "outer"))) (DoLet false false (PVar "lits") (EApp (EApp (EVar "takePatLits") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "pr") (EApp (EApp (EVar "inferPats") (EVar "env")) (EVar "pats"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "peelOntoParams") (EFieldAccess (EVar "env") "teDyn")) (EVar "peel")) (EApp (EVar "fst") (EVar "pr"))) (EVar "pats"))) (DoLet false false (PVar "scope") (EApp (EApp (EVar "openExistentialScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EApp (EVar "takeOpenedExistentials") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "settlePatLits") (EFieldAccess (EVar "env") "teDyn")) (EVar "lits"))) (DoExpr (EMatch (EVar "peel") (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EApp (EApp (EVar "recordClauseFileBound") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "body")) (EApp (EVar "listLen") (EVar "pats"))) (EVar "src"))) (arm (PCon "None") () (ELit LUnit)))) (DoLet false false (PTuple (PVar "bodyTy") (PVar "bodyEff")) (EApp (EApp (EApp (EVar "captureEffects") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "curEffect")) (EApp (EVar "joinCellOf") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph"))) (ELam (PWild) (EMatch (EVar "peel") (arm (PCon "Some" (PVar "src")) () (EMatch (EApp (EApp (EVar "resultAfterArrows") (EApp (EVar "listLen") (EVar "pats"))) (EVar "src")) (arm (PCon "Some" (PVar "expected")) () (EBlock (DoLet false false (PVar "bodyEnv") (EApp (EApp (EVar "extendLocalVars") (EVar "env")) (EApp (EVar "snd") (EVar "pr")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkedInto") (EVar "bodyEnv")) (EVar "body")) (EVar "expected")) (EApp (EApp (EApp (EVar "inferExpected") (EVar "bodyEnv")) (EVar "body")) (EVar "expected")))))) (arm (PCon "None") () (EApp (EApp (EVar "infer") (EApp (EApp (EVar "extendLocalVars") (EVar "env")) (EApp (EVar "snd") (EVar "pr")))) (EVar "body"))))) (arm (PCon "None") () (EApp (EApp (EVar "infer") (EApp (EApp (EVar "extendLocalVars") (EVar "env")) (EApp (EVar "snd") (EVar "pr")))) (EVar "body"))))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "closeExistentialScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "scope")) (EVar "bodyTy")) (EApp (EVar "exprLoc") (EVar "body")))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "bodyArrows") (EApp (EVar "fst") (EVar "pr"))) (EVar "bodyEff")) (EVar "bodyTy")) (EVar "bodyEff")))))
(DTypeSig false "peelOntoParams" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "Option") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Unit"))))))
(DFunDef false "peelOntoParams" ((PVar "dyn") (PCon "None") PWild PWild) (ELit LUnit))
(DFunDef false "peelOntoParams" ((PVar "dyn") (PCon "Some" PWild) PWild (PList)) (ELit LUnit))
(DFunDef false "peelOntoParams" ((PVar "dyn") (PCon "Some" (PVar "src")) (PVar "patTypes") (PVar "pats")) (EApp (EApp (EApp (EVar "zipBindFrom") (EVar "dyn")) (EVar "patTypes")) (EApp (EApp (EVar "peelArrows") (EApp (EVar "listLen") (EVar "pats"))) (EVar "src"))))
(DTypeSig false "localRole" (TyFun (TyCon "Bool") (TyCon "BindingRole")))
(DFunDef false "localRole" ((PCon "True")) (EVar "RoleQuantifies"))
(DFunDef false "localRole" ((PCon "False")) (EVar "RoleMonomorphic"))
(DTypeSig true "matchWarningsNow" (TyFun (TyCon "ModuleCtx") (TyCon "Bool")))
(DFunDef false "matchWarningsNow" ((PVar "mctx")) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchWarnings") "value") (arm (PList) () (EVar "False")) (arm PWild () (EVar "True"))))
# MARK
(DUse false (UseGroup ("types" "tc_types") ((mem "AdmittedVerdict" true) (mem "BindingRole" true) (mem "BuiltinClass" true) (mem "CDeclared" true) (mem "CDeclaredPrefix" true) (mem "ConstraintReg" true) (mem "DeclaringBinder" true) (mem "DoCtx" true) (mem "DynCtx" true) (mem "EnvBinding" true) (mem "GoalKind" true) (mem "JoinContext" true) (mem "NumBoundary" true) (mem "NumBoundaryDisposition" true) (mem "SiteKind" true) (mem "TcEnv" true) (mem "UObligation" true) (mem "ValueScheme" true) (mem "dynFor" false) (mem "GraphCtx" false) (mem "ModuleCtx" false) (mem "PendingEntry" false) (mem "RecordInfo" false) (mem "RecordSubst" false) (mem "ScopedMember" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "authRoots" false) (mem "authRowRoots" false) (mem "containerParamScalarArg" false) (mem "containsI" false) (mem "domainIsTupleOfArity" false) (mem "effectRoots" false) (mem "effectRowRoots" false) (mem "expectedParamTypes" false) (mem "funArity" false) (mem "headTyconMono" false) (mem "headTyconNameMono" false) (mem "joinCellOf" false) (mem "litType" false) (mem "matchCol0Type" false) (mem "monoHasArrowInSlot" false) (mem "monoIsBool" false) (mem "monoScheme" false) (mem "peelArrows" false) (mem "peelQual" false) (mem "resultAfterArrows" false) (mem "schemeIds" false) (mem "schemeMono" false) (mem "tconBuiltin" false) (mem "tupleMono" false))))
(DUse false (UseGroup ("types" "tc_diag_text") ((mem "appSpineName" false) (mem "bangOnBoolHelp" false) (mem "bangOnBoolMsg" false) (mem "binderNonExhaustiveMsg" false) (mem "bindOutsideDoMsg" false) (mem "containerArgHint" false) (mem "containerArgMsg" false) (mem "discardedValueFix" false) (mem "discardedValueMsg" false) (mem "doBindArgHint" false) (mem "doBindArgMsg" false) (mem "i64RangeText" false) (mem "locKey" false) (mem "nonExhaustiveMatchWarning" false) (mem "notAFunctionHint" false) (mem "notAFunctionMsg" false) (mem "notAFunctionMsgFor" false) (mem "overAppliedMsg" false) (mem "renderCallArgs" false) (mem "tyOfMsg" false) (mem "u64RangeText" false) (mem "unboundVarMsg" false) (mem "unknownFieldMsg" false) (mem "unreachableArmWarning" false) (mem "wideAnnotateHelp" false) (mem "writtenDiag" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "callUOblsWindow" false) (mem "currentScopeStore" false) (mem "dynAtIfSome" false) (mem "emptyShadowDicts" false) (mem "envAt" false) (mem "envAtIfSome" false) (mem "mctxAt" false) (mem "wMark" false) (mem "wWindow" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "extendLocalVar" false) (mem "extendLocalVars" false) (mem "funClausePair" false) (mem "lookupMethodRow" false) (mem "lookupRecordByName" false) (mem "lookupStandaloneValue" false) (mem "lookupVar" false) (mem "seedAlphaLets" false))))
(DUse false (UseGroup ("types" "tc_diag") ((mem "pushTypeError" false) (mem "pushTypeErrorHelpFixAt" false) (mem "recordTypeError" false))))
(DUse false (UseGroup ("types" "tc_scope") ((mem "admittedIfaceWord" false) (mem "argDispatchOf" false) (mem "ieImplExistsForHead" false) (mem "methodEntryHere" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "applicationRowTyped" false) (mem "bindFrom" false) (mem "calleeArrow" false) (mem "captureScope" false) (mem "enterLevel" false) (mem "exitLevel" false) (mem "forceInstantiation" false) (mem "freshVar" false) (mem "instantiateMethodTracked" false) (mem "instantiateValueTracked" false) (mem "joinValueTypes" false) (mem "monoHasNonCovariantSlot" false) (mem "noteNumlitCtx" false) (mem "openRow" false) (mem "optionOrFresh" false) (mem "performEffect" false) (mem "poisonMismatchVars" false) (mem "postponePendingJoins" false) (mem "predicateSlotArgs" false) (mem "predicateSlotCSlots" false) (mem "recordFileValueFlow" false) (mem "refStored" false) (mem "settlePendingJoins" false) (mem "unify" false) (mem "unifyIn" false) (mem "unifyIntoOrd" false) (mem "unifyParamsExpected" false) (mem "unifySourceDomains" false) (mem "valueJoinOps" false) (mem "wantAuthority" false) (mem "zipBindFrom" false) (mem "closeScope" false))))
(DUse false (UseGroup ("types" "tc_decls") ((mem "astTypeFreshTbl" false) (mem "instantiateSigTracked" false) (mem "sigToSchemeTvs" false) (mem "sigToSchemeTvsIn" false) (mem "headAnnotTy" false))))
(DUse false (UseGroup ("types" "tc_solve") ((mem "goalsMark" false) (mem "improveLocalGoals" false) (mem "isLocalAbsName" false) (mem "openScope" false) (mem "pushLocalDictApp" false) (mem "routeLocalSym" false))))
(DUse false (UseGroup ("types" "tc_solve_check") ((mem "callOblsWindow" false) (mem "checkSigVarGoals" false) (mem "declaredPredicateSlots" false) (mem "dedupSlotVecs" false) (mem "finalizeNumBoundary" false) (mem "localNumGuard" false) (mem "memberTiedSurvivors" false) (mem "numConstrainedIds" false) (mem "predicateSlotView" false))))
(DUse false (UseGroup ("types" "tc_shadow") ((mem "definerReceiverDispatches" false) (mem "definerReceiverIsDictVar" false) (mem "definerShadowArgHead" false) (mem "definerShadowSpineArgAt" false) (mem "definerShadowSpineVarAt" false) (mem "definerShadowVarHead" false) (mem "enforceStandaloneDomainAt" false) (mem "groundAdmittedReceivers" false) (mem "groundShadowReceiver" false) (mem "importerAdmittedVerdict" false) (mem "importerShadowDomain" false) (mem "importerShadowDomainAt" false) (mem "methodCellOf" false) (mem "plainAppHeadVar" false) (mem "pushAmbiguousShadowDecl" false) (mem "recoveredShadowSym" false) (mem "shadowDomainForAt" false) (mem "shadowHeadEnv" false) (mem "shadowStandaloneHead" false) (mem "shadowStandaloneSpineHeadAt" false) (mem "stampMethodArities" false) (mem "stampRoutes" false) (mem "standaloneShadowDomainAt" false))))
(DUse false (UseGroup ("types" "tc_effects") ((mem "appSpineArgCount" false) (mem "beginEffectSummaryScope" false) (mem "borrowedEffectCells" false) (mem "collectProducedSummary" false) (mem "finishEffectSummaryScopeKeeping" false) (mem "flushPendingEscapes" false) (mem "freshEffectSummary" false) (mem "grantOnlyBindingId" false) (mem "localBindingSummary" false) (mem "notePerformSite" false) (mem "recordClauseFileBound" false) (mem "recordEffectBody" false) (mem "recordGrantOcc" false) (mem "recordStandaloneAt" false) (mem "recordValueFileBound" false) (mem "registerLocalAbsIf" false) (mem "registerLocalGroupAbs" false) (mem "spineHeadEv" false) (mem "argumentAuthority" false))))
(DUse false (UseGroup ("types" "tc_occurrence") ((mem "bindingDeclaredAt" false) (mem "freshEvId" false) (mem "inferDeclaredDictAt" false) (mem "inferDictAtFound" false) (mem "inferMethodAtCell" false) (mem "inferNumLit" false) (mem "inferWideLit" false) (mem "instantiateStandaloneOccurrence" false) (mem "instantiateVarTrackedId" false) (mem "instantiateVarTrackedWithSubst" false) (mem "isGrantOnlyEv" false) (mem "markNumlitOpTaint" false) (mem "maybeStandaloneValueMono" false) (mem "methodOmittedVars" false) (mem "pushSiteGoal" false) (mem "recordBinopGoals" false) (mem "recordIfaceObligation" false) (mem "recordMethodObligationGuarded" false) (mem "recordMethodObligationOwned" false) (mem "recordNegatedLitRange" false) (mem "recordSelectedStandaloneRoutes" false) (mem "recordUnopSite" false) (mem "siteHeadCell" false) (mem "siteRouteCell" false) (mem "standaloneOccurrence" false) (mem "standaloneSchemeFor" false))))
(DUse false (UseGroup ("types" "tc_groups") ((mem "checkAnnotTooGeneral" false) (mem "checkLetGroupBindsLocated" false) (mem "checkRecBindNonFunction" false) (mem "checkRecursiveValue" false) (mem "constraintVarArgMonos" false) (mem "constraintVarIfaceMonos" false) (mem "exprLoc" false) (mem "genBindingRestricted" false) (mem "generalizeGroup" false) (mem "isNonexpansive" false) (mem "letBindGeneralizes" false) (mem "letGroupComponents" false) (mem "registerSchemeObligations" false) (mem "residualsOf" false) (mem "sccProtectedSignatureIds" false) (mem "scopeRolesOf" false) (mem "sigConstraintArgTys" false) (mem "sigConstraints" false))))
(DUse false (UseGroup ("types" "tc_pat") ((mem "closeExistentialScope" false) (mem "inferPat" false) (mem "inferPats" false) (mem "openExistentialScope" false) (mem "patOpensExistentials" false) (mem "recordLetBindType" false) (mem "recordLocalBind" false) (mem "settlePatLits" false) (mem "takeOpenedExistentials" false) (mem "takePatLits" false))))
(DUse false (UseGroup ("types" "tc_infer_records") ((mem "assignedFieldNames" false) (mem "checkMissingFields" false) (mem "fieldAssignNamePair" false) (mem "fieldSelectionWellTyped" false) (mem "firstFieldName" false) (mem "inferFieldOfRecord" false) (mem "instantiateRecordShared" false) (mem "instantiateRecordUpdate" false) (mem "recordFieldMap" false) (mem "recordFieldNames" false) (mem "recordUpdateWellTyped" false) (mem "resolveFieldRecord" false) (mem "stampedRecordHead" false) (mem "substRecordField" false) (mem "unknownRecordFresh" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "BinderId" true) (mem "DoStmt" true) (mem "EvId" true) (mem "Expr" true) (mem "FieldAssign" true) (mem "Guard" true) (mem "LetBind" true) (mem "Lit" true) (mem "Loc" true) (mem "Pat" true) (mem "Route" true) (mem "TabKey" true) (mem "Ty" true) (mem "intMinLiteralHelp" false) (mem "intMinLiteralMsg" false) (mem "isI64Head" false) (mem "isU64Head" false) (mem "letBindName" false) (mem "orElseLoc" false) (mem "taggedFixedRange" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" true) (mem "EffRow" true) (mem "collectRows" false) (mem "effrowLabels" false) (mem "joinRows" false) (mem "pureRow" false))))
(DUse false (UseGroup ("types" "repr") ((mem "AuthResidual" true) (mem "Mono" true) (mem "Scheme" true) (mem "Tyvar" true) (mem "normalize" false) (mem "ppMono" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "authDomainTop" false))))
(DUse false (UseGroup ("types" "effect_bindings") ((mem "BindingSummary" true) (mem "bodyArrows" false) (mem "bodyRowAt" false) (mem "newBindingSummary" false))))
(DUse false (UseGroup ("types" "evidence_complete") ((mem "Inner" true))))
(DUse false (UseGroup ("types" "scopes") ((mem "ScopeOwner" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omFromNames" false) (mem "omFromPairs" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omSize" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("types" "evidence") ((mem "ScopeId" true))))
(DUse false (UseGroup ("types" "publish") ((mem "TcDiag" true))))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "anyList" false) (mem "contains" false) (mem "isEmptyL" false) (mem "joinWith" false) (mem "listLen" false) (mem "zipL" false))))
(DUse false (UseGroup ("types" "effect_infer") ((mem "captureEffects" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "desugarPat" false) (mem "patHasRange" false) (mem "patUnreachable" false) (mem "renderWitness" false) (mem "useful" false) (mem "usefulWitness" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "exprSpanLoc" false))))
(DUse false (UseGroup ("types" "module_interface") ((mem "forgetLocalRows" false))))
(DUse false (UseGroup ("list") ((mem "head" false) (mem "last" false))))
(DUse false (UseGroup ("types" "effect_values") ((mem "joinProducedEnvelope" false))))
(DUse false (UseAlias ("types" "scopes") "Scopes"))
(DUse false (UseAlias ("map") "IdMap"))
(DTypeSig false "finishValueEffectsKeeping" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Bool") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "AuthResidual"))))))
(DFunDef false "finishValueEffectsKeeping" ((PVar "dyn") (PVar "generalizing")) (EBlock (DoLet false false (PVar "members") (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "generalizes") (PVar "mono"))) (ETuple (EApp (EVar "localRole") (EVar "generalizes")) (EVar "mono")))) (EVar "generalizing"))) (DoLet false false (PVar "level") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "currentLevel") "value")) (DoExpr (EIf (EApp (EApp (EVar "anyList") (EVar "fst")) (EVar "generalizing")) (EApp (EApp (EVar "settlePendingJoins") (EVar "dyn")) (EVar "level")) (EApp (EApp (EVar "postponePendingJoins") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "level")))) (DoLet false false (PVar "monos") (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "members"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "finishEffectSummaryScopeKeeping") (EFieldAccess (EVar "dyn") "dcModule")) (EApp (EVar "scopeRolesOf") (EVar "members"))) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "mono")) (EApp (EApp (EVar "effectRoots") (EVar "mono")) (EVar "acc")))) (EVar "Tip")) (EVar "monos"))) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "mono")) (EApp (EApp (EApp (EVar "borrowedEffectCells") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "mono")) (EVar "acc")))) (EVar "Tip")) (EVar "monos"))))))
(DTypeSig true "infer" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyCon "Mono"))))
(DFunDef false "infer" ((PVar "env") (PCon "ELit" (PVar "l"))) (EApp (EVar "litType") (EVar "l")))
(DFunDef false "infer" ((PVar "env") (PCon "ENumLit" (PVar "n") (PVar "ev") PWild)) (EApp (EApp (EApp (EVar "inferNumLit") (EVar "env")) (EVar "n")) (EVar "ev")))
(DFunDef false "infer" ((PVar "env") (PCon "EWideLit" (PVar "hi") (PVar "lo") (PVar "ev") (PVar "lx"))) (EApp (EApp (EApp (EApp (EApp (EVar "inferWideLit") (EVar "env")) (EVar "hi")) (EVar "lo")) (EVar "ev")) (EVar "lx")))
(DFunDef false "infer" ((PVar "env") (PCon "EVar" (PVar "x"))) (EApp (EApp (EVar "inferVar") (EVar "env")) (EVar "x")))
(DFunDef false "infer" ((PVar "env") (PCon "EVarId" (PVar "x") (PVar "id"))) (EApp (EApp (EApp (EVar "inferVarId") (EVar "env")) (EVar "x")) (EVar "id")))
(DFunDef false "infer" ((PVar "env") (PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EApp (EVar "inferAppExpr") (EVar "env")) (EVar "f")) (EVar "x")))
(DFunDef false "infer" ((PVar "env") (PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EVar "inferLam") (EVar "env")) (EVar "pats")) (EVar "body")))
(DFunDef false "infer" ((PVar "env") (PCon "ELet" PWild (PVar "isFun") (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "inferLet") (EVar "env")) (EVar "isFun")) (EVar "pat")) (EVar "e1")) (EVar "e2")))
(DFunDef false "infer" ((PVar "env") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EApp (EVar "inferLetGroup") (EVar "env")) (EVar "binds")) (EVar "body")))
(DFunDef false "infer" ((PVar "env") (PCon "EIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "inferIf") (EVar "env")) (EVar "c")) (EVar "t")) (EVar "e")))
(DFunDef false "infer" ((PVar "env") (PCon "EMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EApp (EVar "inferMatch") (EVar "env")) (EApp (EApp (EVar "infer") (EVar "env")) (EVar "scrut"))) (EVar "arms")))
(DFunDef false "infer" ((PVar "env") (PCon "ETuple" (PVar "es"))) (EApp (EVar "tupleMono") (EApp (EApp (EVar "inferEach") (EVar "env")) (EVar "es"))))
(DFunDef false "infer" ((PVar "env") (PCon "EListLit" (PVar "es"))) (EApp (EApp (EVar "inferListLit") (EVar "env")) (EVar "es")))
(DFunDef false "infer" ((PVar "env") (PCon "EAnnot" (PVar "e") (PVar "ty"))) (EApp (EApp (EApp (EVar "inferAnnot") (EVar "env")) (EVar "e")) (EVar "ty")))
(DFunDef false "infer" ((PVar "env") (PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") (PVar "ev"))) (EApp (EApp (EApp (EApp (EApp (EVar "inferBinopE") (EVar "env")) (EVar "op")) (EVar "l")) (EVar "r")) (EApp (EApp (EVar "siteRouteCell") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "ev"))))
(DFunDef false "infer" ((PVar "env") (PCon "EUnOp" (PVar "op") (PVar "e") (PVar "ev"))) (EApp (EApp (EApp (EApp (EVar "inferUnopE") (EApp (EApp (EVar "envAtIfSome") (EApp (EVar "exprSpanLoc") (EVar "e"))) (EVar "env"))) (EVar "op")) (EVar "e")) (EApp (EApp (EVar "siteRouteCell") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "ev"))))
(DFunDef false "infer" ((PVar "env") (PCon "EInfix" (PVar "op") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "inferInfix") (EVar "env")) (EVar "op")) (EVar "l")) (EVar "r")))
(DFunDef false "infer" ((PVar "env") (PCon "ERecordCreate" (PVar "name") (PVar "fields"))) (EApp (EApp (EApp (EVar "inferRecordCreate") (EVar "env")) (EVar "name")) (EVar "fields")))
(DFunDef false "infer" ((PVar "env") (PCon "EFieldAccess" (PVar "e") (PVar "fname") (PVar "ev"))) (EApp (EApp (EApp (EApp (EVar "inferFieldAccess") (EApp (EApp (EVar "envAtIfSome") (EApp (EVar "exprSpanLoc") (EVar "e"))) (EVar "env"))) (EVar "e")) (EVar "fname")) (EVar "ev")))
(DFunDef false "infer" ((PVar "env") (PCon "ERecordUpdate" (PVar "base") (PVar "fields") (PVar "ev"))) (EApp (EApp (EApp (EApp (EVar "inferRecordUpdate") (EVar "env")) (EVar "base")) (EVar "fields")) (EVar "ev")))
(DFunDef false "infer" ((PVar "env") (PCon "EVariantUpdate" (PVar "cname") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EApp (EVar "inferVariantUpdate") (EVar "env")) (EVar "cname")) (EVar "base")) (EVar "fields")))
(DFunDef false "infer" ((PVar "env") (PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "inferBlock") (EVar "env")) (EVar "stmts")))
(DFunDef false "infer" ((PVar "env") (PCon "EMethodAt" (PVar "name") PWild (PVar "ev"))) (EApp (EApp (EApp (EVar "inferMethodAtCell") (EVar "env")) (EVar "name")) (EApp (EApp (EVar "methodCellOf") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "ev"))))
(DFunDef false "infer" ((PVar "env") (PCon "EDictAt" (PVar "name") (PVar "ev"))) (EApp (EApp (EApp (EVar "inferGrantedAt") (EVar "env")) (EVar "name")) (EVar "ev")))
(DFunDef false "infer" ((PVar "env") (PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EVar "inferArrayLit") (EVar "env")) (EVar "es")))
(DFunDef false "infer" ((PVar "env") (PCon "ERangeList" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EApp (EApp (EVar "inferIntRange") (EVar "env")) (EVar "lo")) (EVar "hi")) (EApp (EVar "tconBuiltin") (ELit (LString "List")))))
(DFunDef false "infer" ((PVar "env") (PCon "ERangeArray" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EApp (EApp (EVar "inferIntRange") (EVar "env")) (EVar "lo")) (EVar "hi")) (EApp (EVar "tconBuiltin") (ELit (LString "Array")))))
(DFunDef false "infer" ((PVar "env") (PCon "EHeadAnnot" (PVar "e") (PVar "ty"))) (EApp (EApp (EApp (EVar "inferHeadAnnot") (EVar "env")) (EVar "e")) (EVar "ty")))
(DFunDef false "infer" ((PVar "env") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "infer") (EApp (EApp (EVar "envAt") (EApp (EVar "Some") (EVar "l"))) (EVar "env"))) (EVar "e")))
(DFunDef false "infer" ((PVar "env") (PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EBlock (DoLet false false (PVar "doCtx") (ERecordCreate "DoCtx" ((fa "doLoc" (EVar "l")) (fa "doDeferred" (EApp (EVar "doChainIsDeferred") (EVar "e"))) (fa "doReported" (EApp (EVar "Ref") (EVar "False")))))) (DoExpr (EApp (EApp (EVar "infer") (ERecordUpdate (EVar "env") ((fa "teDyn" (ERecordUpdate (EFieldAccess (EVar "env") "teDyn") ((fa "dcDo" (EApp (EVar "Some") (EVar "doCtx"))))))))) (EVar "e")))))
(DFunDef false "infer" ((PVar "env") PWild) (EApp (EVar "panic") (ELit (LString "typecheck: unsupported expression"))))
(DTypeSig false "doChainIsDeferred" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "doChainIsDeferred" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "doChainIsDeferred") (EVar "f")))
(DFunDef false "doChainIsDeferred" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "doChainIsDeferred") (EVar "e")))
(DFunDef false "doChainIsDeferred" ((PCon "EDoOrigin" PWild (PCon "EVar" (PLit (LString "deferThen"))))) (EVar "True"))
(DFunDef false "doChainIsDeferred" ((PCon "EDoOrigin" PWild (PCon "EVarId" (PLit (LString "deferThen")) PWild))) (EVar "True"))
(DFunDef false "doChainIsDeferred" (PWild) (EVar "False"))
(DTypeSig false "inferArrayLit" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Mono"))))
(DFunDef false "inferArrayLit" ((PVar "env") (PVar "es")) (EBlock (DoLet false false (PVar "elem") (EApp (EApp (EApp (EVar "joinValueTypes") (EFieldAccess (EVar "env") "teDyn")) (EVar "JoinArray")) (EApp (EApp (EVar "inferProduced") (EVar "env")) (EVar "es")))) (DoExpr (EApp (EApp (EVar "TApp") (EApp (EVar "tconBuiltin") (ELit (LString "Array")))) (EDictApp "elem")))))
(DTypeSig false "inferIntRange" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyCon "Mono"))))))
(DFunDef false "inferIntRange" ((PVar "env") (PVar "lo") (PVar "hi") (PVar "container")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EFieldAccess (EVar "env") "teDyn")) (EApp (EApp (EVar "infer") (EVar "env")) (EVar "lo"))) (EApp (EVar "tconBuiltin") (ELit (LString "Int"))))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EFieldAccess (EVar "env") "teDyn")) (EApp (EApp (EVar "infer") (EVar "env")) (EVar "hi"))) (EApp (EVar "tconBuiltin") (ELit (LString "Int"))))) (DoExpr (EApp (EApp (EVar "TApp") (EVar "container")) (EApp (EVar "tconBuiltin") (ELit (LString "Int")))))))
(DTypeSig false "forgetLocalAbs" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyCon "Unit"))))
(DFunDef false "forgetLocalAbs" ((PVar "gctx") (PVar "name")) (EApp (EApp (EApp (EVar "forgetLocalRows") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "localAbs")) (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "grants")) (EVar "name")))
(DTypeSig false "openLocalScope" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "ScopeId"))))
(DFunDef false "openLocalScope" ((PVar "mctx") (PVar "name")) (EBlock (DoLet false false (PVar "parent") (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) (DoLet false false (PVar "sid") (EApp (EApp (EApp (EApp (EApp (EVar "Scopes.freshScope") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EApp (EVar "Some") (EVar "parent"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")) (EFieldAccess (EApp (EApp (EVar "Scopes.scopeFrame") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EVar "parent")) "sfModuleId")) (EApp (EVar "LocalBindingOwner") (EVar "name")))) (DoExpr (EApp (EApp (EVar "openScope") (EVar "mctx")) (EVar "sid"))) (DoExpr (EVar "sid"))))
(DTypeSig false "openLocalScopeIf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "ScopeId")))))
(DFunDef false "openLocalScopeIf" ((PVar "mctx") (PVar "name")) (EIf (EApp (EVar "isLocalAbsName") (EVar "name")) (EBlock (DoExpr (EApp (EApp (EVar "forgetLocalAbs") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "name"))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EVar "openLocalScope") (EVar "mctx")) (EVar "name"))))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "closeLocalScope" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "ScopeId")) (TyCon "Unit"))))
(DFunDef false "closeLocalScope" ((PVar "mctx") (PCon "Some" PWild)) (EApp (EApp (EVar "closeScope") (EVar "mctx")) (ELit LUnit)))
(DFunDef false "closeLocalScope" ((PVar "mctx") (PCon "None")) (ELit LUnit))
(DTypeSig false "inferLocalDictAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "Mono")))))
(DFunDef false "inferLocalDictAt" ((PVar "env") (PVar "name") (PVar "ev")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph") "graphRun") "localAbs") "lasBinders") "value")) (arm (PCon "Some" (PCon "Some" (PVar "la"))) () (EMatch (EApp (EApp (EVar "lookupVar") (EVar "env")) (EVar "name")) (arm (PCon "Some" (PVar "s")) () (EBlock (DoLet false false (PVar "inst") (EApp (EApp (EApp (EApp (EVar "instantiateVarTrackedWithSubst") (EVar "env")) (EVar "name")) (ELit (LInt 0))) (EVar "s"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushLocalDictApp") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "ev")) (EVar "la")) (EFieldAccess (EFieldAccess (EVar "inst") "mtiSubstitution") "misTypeSubst")) (EApp (EApp (EVar "captureScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit)))) (DoExpr (EFieldAccess (EVar "inst") "mtiBody")))) (arm (PCon "None") () (EApp (EApp (EVar "unboundVarFresh") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name"))))) (arm (PCon "Some" (PCon "None")) () (EApp (EApp (EApp (EVar "inferVarId") (EVar "env")) (EVar "name")) (ELit (LInt 0)))) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EApp (EVar "recordLocalRecOcc") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "ev"))) (DoExpr (EApp (EApp (EApp (EVar "inferVarId") (EVar "env")) (EVar "name")) (ELit (LInt 0))))))))
(DTypeSig false "recordLocalRecOcc" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "Unit")))))
(DFunDef false "recordLocalRecOcc" ((PVar "mctx") (PVar "name") (PVar "ev")) (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "localAbs")) (DoLet false false (PVar "occs") (EBinOp "::" (ETuple (EVar "ev") (EApp (EApp (EVar "captureScope") (EVar "mctx")) (ELit LUnit))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EFieldAccess (EVar "st") "lasRecOccs") "value"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "lasRecOccs")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EVar "occs")) (EFieldAccess (EFieldAccess (EVar "st") "lasRecOccs") "value"))))))
(DTypeSig false "inferDictAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "Mono")))))
(DFunDef false "inferDictAt" ((PVar "env") (PVar "name") (PVar "ev")) (EIf (EApp (EVar "isLocalAbsName") (EVar "name")) (EApp (EApp (EApp (EVar "inferLocalDictAt") (EVar "env")) (EVar "name")) (EVar "ev")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "inferGlobalDictAt") (EVar "env")) (EVar "name")) (EVar "ev")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "inferGlobalDictAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "Mono")))))
(DFunDef false "inferGlobalDictAt" ((PVar "env") (PVar "name") (PVar "ev")) (EMatch (EApp (EApp (EVar "lookupVar") (EVar "env")) (EVar "name")) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (ELit (LString "unbound constrained fn: ")) (EVar "name")))) (arm (PCon "Some" (PVar "scheme")) () (EBlock (DoLet false false (PVar "inst") (EApp (EApp (EApp (EVar "instantiateValueTracked") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "scheme"))) (DoLet false false (PVar "occurrence") (ETuple (EFieldAccess (EVar "inst") "mtiBody") (EFieldAccess (EFieldAccess (EVar "inst") "mtiSubstitution") "misTypeSubst"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "bindingDeclaredAt") (EVar "env")) (EVar "name")) (EVar "inst")) (arm (PCon "Some" (PVar "dc")) () (EApp (EApp (EApp (EApp (EApp (EVar "inferDeclaredDictAt") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "ev")) (EVar "dc")) (EVar "occurrence"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "inferDictAtFound") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "ev")) (EVar "occurrence")))))))))
(DTypeSig false "inferGrantedAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "Mono")))))
(DFunDef false "inferGrantedAt" ((PVar "env") (PVar "name") (PVar "ev")) (EBlock (DoLet false false (PVar "st") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph") "graphRun") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "gsLastInst")) (EVar "None"))) (DoLet false false (PVar "t") (EIf (EApp (EApp (EVar "isGrantOnlyEv") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "ev")) (EApp (EApp (EApp (EVar "inferVarId") (EVar "env")) (EVar "name")) (EApp (EApp (EVar "grantOnlyBindingId") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name"))) (EApp (EApp (EApp (EVar "inferDictAt") (EVar "env")) (EVar "name")) (EVar "ev")))) (DoExpr (EMatch (EFieldAccess (EFieldAccess (EVar "st") "gsLastInst") "value") (arm (PCon "Some" (PTuple (PVar "scheme") (PVar "subst"))) () (EApp (EApp (EApp (EApp (EApp (EVar "recordGrantOcc") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "ev")) (EVar "scheme")) (EVar "subst"))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EVar "t"))))
(DTypeSig false "inferBlock" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "Mono"))))
(DFunDef false "inferBlock" ((PVar "env") (PList)) (EApp (EVar "tconBuiltin") (ELit (LString "Unit"))))
(DFunDef false "inferBlock" ((PVar "env") (PList (PVar "s"))) (EApp (EApp (EVar "inferLastStmt") (EVar "env")) (EVar "s")))
(DFunDef false "inferBlock" ((PVar "env") (PCons (PVar "s") (PVar "rest"))) (EApp (EApp (EVar "inferBlock") (EApp (EApp (EVar "inferStmt") (EVar "env")) (EVar "s"))) (EVar "rest")))
(DTypeSig false "inferLastStmt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "DoStmt") (TyCon "Mono"))))
(DFunDef false "inferLastStmt" ((PVar "env") (PCon "DoExpr" (PVar "e"))) (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e")))
(DFunDef false "inferLastStmt" ((PVar "env") (PVar "s")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "inferStmt") (EVar "env")) (EVar "s"))) (DoExpr (EApp (EVar "tconBuiltin") (ELit (LString "Unit"))))))
(DTypeSig false "inferStmt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "DoStmt") (TyCon "TcEnv"))))
(DFunDef false "inferStmt" ((PVar "outer") (PVar "s")) (EApp (EApp (EVar "envAt") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "outer") "teDyn") "dcModule") "mcLoc")) (EApp (EApp (EVar "inferStmtAt") (EApp (EApp (EVar "envAtIfSome") (EApp (EVar "stmtSpanLoc") (EVar "s"))) (EVar "outer"))) (EVar "s"))))
(DTypeSig false "stmtSpanLoc" (TyFun (TyCon "DoStmt") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "stmtSpanLoc" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "exprSpanLoc") (EVar "e")))
(DFunDef false "stmtSpanLoc" ((PCon "DoLet" PWild PWild PWild (PVar "e") PWild)) (EApp (EVar "exprSpanLoc") (EVar "e")))
(DFunDef false "stmtSpanLoc" ((PCon "DoAssign" PWild (PVar "e"))) (EApp (EVar "exprSpanLoc") (EVar "e")))
(DFunDef false "stmtSpanLoc" ((PCon "DoBind" PWild (PVar "e"))) (EApp (EVar "exprSpanLoc") (EVar "e")))
(DFunDef false "stmtSpanLoc" (PWild) (EVar "None"))
(DTypeSig false "inferStmtAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "DoStmt") (TyCon "TcEnv"))))
(DFunDef false "inferStmtAt" ((PVar "env") (PCon "DoExpr" (PVar "e"))) (EBlock (DoLet false false (PVar "oblN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls"))) (DoLet false false (PVar "t") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkStmtNotDiscarded") (EFieldAccess (EVar "env") "teDyn")) (EApp (EApp (EVar "wWindow") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls")) (EVar "oblN0"))) (EVar "t")) (EVar "e"))) (DoExpr (EVar "env"))))
(DFunDef false "inferStmtAt" ((PVar "env") (PCon "DoLet" PWild (PCon "True") (PCon "PVar" (PVar "x") (PVar "xloc") (PVar "bid")) (PVar "e") PWild)) (EApp (EApp (EApp (EApp (EApp (EVar "blockRecLet") (EVar "env")) (EVar "x")) (EApp (EVar "Some") (EVar "xloc"))) (EVar "bid")) (EVar "e")))
(DFunDef false "inferStmtAt" ((PVar "env") (PCon "DoLet" PWild PWild (PVar "pat") (PVar "e") PWild)) (EApp (EApp (EApp (EVar "blockLet") (EVar "env")) (EVar "pat")) (EVar "e")))
(DFunDef false "inferStmtAt" ((PVar "env") (PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EApp (EVar "extendLocalVar") (EVar "env")) (EVar "x")) (EApp (EVar "monoScheme") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e")))))
(DFunDef false "inferStmtAt" ((PVar "env") (PCon "DoBind" (PVar "pat") (PVar "e"))) (EBlock (DoLet false false (PVar "t") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EVar "pushTypeError") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit (LString "T-BIND-OUTSIDE-DO"))) (EVar "bindOutsideDoMsg"))) (DoLet false false (PVar "lits") (EApp (EApp (EVar "takePatLits") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "pr") (EApp (EApp (EVar "inferPat") (EVar "env")) (EVar "pat"))) (DoExpr (EApp (EApp (EApp (EVar "bindFrom") (EFieldAccess (EVar "env") "teDyn")) (EApp (EVar "fst") (EVar "pr"))) (EVar "t"))) (DoExpr (EApp (EApp (EVar "settlePatLits") (EFieldAccess (EVar "env") "teDyn")) (EVar "lits"))) (DoExpr (EApp (EApp (EVar "extendLocalVars") (EVar "env")) (EApp (EVar "snd") (EVar "pr"))))))
(DFunDef false "inferStmtAt" ((PVar "env") PWild) (EApp (EVar "panic") (ELit (LString "typecheck: unsupported block statement"))))
(DTypeSig false "checkStmtNotDiscarded" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyFun (TyCon "Mono") (TyFun (TyCon "Expr") (TyCon "Unit"))))))
(DFunDef false "checkStmtNotDiscarded" ((PVar "dyn") (PVar "stmtObls") (PVar "t") (PVar "e")) (EIf (EApp (EApp (EVar "isExemptInPlaceSetIndex") (EVar "t")) (EVar "e")) (ELit LUnit) (EIf (EVar "otherwise") (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TCon" (PLit (LString "Unit")) PWild) () (ELit LUnit)) (arm (PCon "TVar" (PVar "cell")) () (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Unbound" (PVar "id") PWild) () (EIf (EApp (EApp (EVar "containsI") (EVar "id")) (EApp (EVar "numConstrainedIds") (EVar "stmtObls"))) (EApp (EApp (EApp (EVar "pushDiscardedValueDesc") (EFieldAccess (EVar "dyn") "dcModule")) (ELit (LString "a number"))) (EVar "e")) (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "t")) (EApp (EVar "tconBuiltin") (ELit (LString "Unit")))))) (arm (PCon "Link" PWild) () (EApp (EVar "panic") (ELit (LString "checkStmtNotDiscarded: normalize left a Link")))))) (arm (PVar "nt") () (EApp (EApp (EApp (EVar "pushDiscardedValueError") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "nt")) (EVar "e")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "stmtCalleeName" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "stmtCalleeName" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "stmtCalleeName") (EVar "e")))
(DFunDef false "stmtCalleeName" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "stmtCalleeName") (EVar "e")))
(DFunDef false "stmtCalleeName" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "stmtCalleeName") (EVar "e")))
(DFunDef false "stmtCalleeName" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "stmtCalleeName") (EVar "f")))
(DFunDef false "stmtCalleeName" ((PCon "EVar" (PVar "n"))) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "stmtCalleeName" ((PCon "EVarId" (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "stmtCalleeName" ((PCon "EVarAt" (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "stmtCalleeName" ((PCon "EMethodRef" (PVar "n"))) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "stmtCalleeName" ((PCon "EMethodAt" (PVar "n") PWild PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "stmtCalleeName" ((PCon "EDictAt" (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "stmtCalleeName" (PWild) (EVar "None"))
(DTypeSig false "exemptInPlaceIndexMutHeads" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "exemptInPlaceIndexMutHeads" () (EListLit (ELit (LString "Array")) (ELit (LString "Vector"))))
(DTypeSig false "isExemptInPlaceSetIndex" (TyFun (TyCon "Mono") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "isExemptInPlaceSetIndex" ((PVar "t") (PVar "e")) (EMatch (EApp (EVar "headTyconNameMono") (EVar "t")) (arm (PCon "Some" (PVar "hd")) () (EBinOp "&&" (EBinOp "==" (EApp (EVar "stmtCalleeName") (EVar "e")) (EApp (EVar "Some") (ELit (LString "setIndex")))) (EApp (EApp (EVar "contains") (EVar "hd")) (EVar "exemptInPlaceIndexMutHeads")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "pushDiscardedValueError" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Expr") (TyCon "Unit")))))
(DFunDef false "pushDiscardedValueError" ((PVar "mctx") (PVar "nt") (PVar "e")) (EApp (EApp (EApp (EVar "pushDiscardedValueDesc") (EVar "mctx")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EApp (EVar "ppMono") (EVar "nt")))) (ELit (LString "`")))) (EVar "e")))
(DTypeSig false "pushDiscardedValueDesc" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Unit")))))
(DFunDef false "pushDiscardedValueDesc" ((PVar "mctx") (PVar "desc") (PVar "e")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushTypeErrorHelpFixAt") (EVar "mctx")) (ELit (LString "T-DISCARDED-VALUE"))) (EApp (EVar "exprSpanLoc") (EVar "e"))) (EApp (EVar "discardedValueMsg") (EVar "desc"))) (ELit (LString "bind it with `let _ = ...` if dropping the value is intentional"))) (EApp (EVar "discardedValueFix") (EApp (EVar "exprLoc") (EVar "e")))))
(DTypeSig false "blockRecLet" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "BinderId") (TyFun (TyCon "Expr") (TyCon "TcEnv")))))))
(DFunDef false "blockRecLet" ((PVar "env") (PVar "x") (PVar "xloc") (PVar "bid") (PVar "e")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "checkRecBindNonFunction") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EVar "e"))) (DoExpr (EApp (EApp (EVar "enterLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "oblN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls"))) (DoLet false false (PVar "callN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "obls"))) (DoLet false false (PVar "dictN0") (EApp (EApp (EVar "goalsMark") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (DoLet false false (PVar "lscope") (EApp (EApp (EVar "openLocalScopeIf") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x"))) (DoLet false false (PTuple (PVar "t1") (PVar "residuals")) (EApp (EApp (EApp (EVar "inferRecursiveValue") (EVar "env")) (EVar "x")) (EVar "e"))) (DoExpr (EApp (EApp (EVar "closeLocalScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "lscope"))) (DoExpr (EApp (EApp (EVar "exitLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "addedObls") (EApp (EApp (EVar "wWindow") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls")) (EVar "oblN0"))) (DoExpr (EApp (EApp (EApp (EVar "improveLocalGoals") (EFieldAccess (EVar "env") "teDyn")) (EVar "addedObls")) (EVar "callN0"))) (DoLet false false PWild (EApp (EApp (EVar "finalizeNumBoundary") (EFieldAccess (EVar "env") "teDyn")) (ERecordCreate "NumBoundary" ((fa "nbDisposition" (EApp (EVar "NumBoundaryOwnedMember") (EBinOp "+" (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentLevel") "value") (ELit (LInt 1))))) (fa "nbMembers" (EListLit (EVar "t1"))) (fa "nbSurvivingIds" (EApp (EApp (EApp (EApp (EVar "memberTiedSurvivors") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "t1")) (EVar "addedObls")) (EVar "callN0"))) (fa "nbDefaultObls" (EVar "addedObls")) (fa "nbAmbiguityObls" (EVar "addedObls")) (fa "nbGuard" (EApp (EApp (EApp (EVar "localNumGuard") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "addedObls")) (EVar "callN0"))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordLocalBind") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EVar "xloc")) (EVar "bid")) (EVar "t1"))) (DoLet false false (PVar "sch") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "genBindingRestricted") (EFieldAccess (EVar "env") "teDyn")) (EVar "Tip")) (EApp (EApp (EVar "residualsOf") (ELit (LInt 0))) (EVar "residuals"))) (EVar "True")) (EVar "pureRow")) (EVar "t1"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerLocalScheme") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EVar "sch")) (EVar "oblN0")) (EVar "callN0")) (EVar "dictN0"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerLocalAbsIf") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EVar "lscope")) (EVar "sch")) (EVar "oblN0")) (EVar "callN0"))) (DoExpr (EApp (EApp (EApp (EVar "seedAlphaLets") (EApp (EApp (EApp (EVar "extendLocalVar") (EVar "env")) (EVar "x")) (EVar "sch"))) (EVar "x")) (EVar "e")))))
(DTypeSig false "blockLet" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyCon "TcEnv")))))
(DFunDef false "blockLet" ((PVar "env") (PCon "PVar" (PVar "x") (PVar "xloc") (PVar "bid")) (PVar "e")) (EBlock (DoExpr (EApp (EApp (EVar "enterLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "beginEffectSummaryScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "oblN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls"))) (DoLet false false (PVar "callN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "obls"))) (DoLet false false (PVar "dictN0") (EApp (EApp (EVar "goalsMark") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (DoLet false false (PVar "lscope") (EApp (EApp (EVar "openLocalScopeIf") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x"))) (DoLet false false (PVar "t") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e"))) (DoExpr (EApp (EApp (EVar "closeLocalScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "lscope"))) (DoLet false false (PVar "residuals") (EApp (EApp (EVar "finishValueEffectsKeeping") (EFieldAccess (EVar "env") "teDyn")) (EListLit (ETuple (EApp (EApp (EVar "isNonexpansive") (EVar "env")) (EVar "e")) (EVar "t"))))) (DoExpr (EApp (EApp (EVar "exitLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "addedObls") (EApp (EApp (EVar "wWindow") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls")) (EVar "oblN0"))) (DoExpr (EApp (EApp (EApp (EVar "improveLocalGoals") (EFieldAccess (EVar "env") "teDyn")) (EVar "addedObls")) (EVar "callN0"))) (DoLet false false PWild (EApp (EApp (EVar "finalizeNumBoundary") (EFieldAccess (EVar "env") "teDyn")) (ERecordCreate "NumBoundary" ((fa "nbDisposition" (EApp (EVar "NumBoundaryOwnedMember") (EBinOp "+" (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentLevel") "value") (ELit (LInt 1))))) (fa "nbMembers" (EListLit (EVar "t"))) (fa "nbSurvivingIds" (EApp (EApp (EApp (EApp (EVar "memberTiedSurvivors") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "t")) (EVar "addedObls")) (EVar "callN0"))) (fa "nbDefaultObls" (EVar "addedObls")) (fa "nbAmbiguityObls" (EVar "addedObls")) (fa "nbGuard" (EApp (EApp (EApp (EVar "localNumGuard") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "addedObls")) (EVar "callN0"))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordLocalBind") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EApp (EVar "Some") (EVar "xloc"))) (EVar "bid")) (EVar "t"))) (DoLet false false (PVar "sch") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "genBindingRestricted") (EFieldAccess (EVar "env") "teDyn")) (EVar "Tip")) (EApp (EApp (EVar "residualsOf") (ELit (LInt 0))) (EVar "residuals"))) (EApp (EApp (EVar "isNonexpansive") (EVar "env")) (EVar "e"))) (EVar "pureRow")) (EVar "t"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerLocalScheme") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EVar "sch")) (EVar "oblN0")) (EVar "callN0")) (EVar "dictN0"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerLocalAbsIf") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EVar "lscope")) (EVar "sch")) (EVar "oblN0")) (EVar "callN0"))) (DoExpr (EApp (EApp (EApp (EVar "seedAlphaLets") (EApp (EApp (EApp (EVar "extendLocalVar") (EVar "env")) (EVar "x")) (EVar "sch"))) (EVar "x")) (EVar "e")))))
(DFunDef false "blockLet" ((PVar "env") (PVar "pat") (PVar "e")) (EBlock (DoLet false false (PVar "t") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e"))) (DoLet false false (PVar "lits") (EApp (EApp (EVar "takePatLits") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "pr") (EApp (EApp (EVar "inferPat") (EVar "env")) (EVar "pat"))) (DoExpr (EApp (EApp (EApp (EVar "bindFrom") (EFieldAccess (EVar "env") "teDyn")) (EApp (EVar "fst") (EVar "pr"))) (EVar "t"))) (DoExpr (EApp (EApp (EVar "settlePatLits") (EFieldAccess (EVar "env") "teDyn")) (EVar "lits"))) (DoExpr (EApp (EApp (EApp (EVar "checkBinderPat") (EVar "env")) (EApp (EVar "fst") (EVar "pr"))) (EVar "pat"))) (DoExpr (EApp (EApp (EVar "extendLocalVars") (EVar "env")) (EApp (EVar "snd") (EVar "pr"))))))
(DTypeSig false "inferRecordCreate" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyCon "Mono")))))
(DFunDef false "inferRecordCreate" ((PVar "env") (PVar "name") (PVar "fields")) (EMatch (EApp (EApp (EVar "lookupRecordByName") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (arm (PCon "None") () (EApp (EApp (EVar "unknownRecordFresh") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name"))) (arm (PCon "Some" (PVar "ri")) () (EApp (EApp (EApp (EApp (EVar "inferRecordCreateWith") (EVar "env")) (EVar "name")) (EVar "ri")) (EVar "fields")))))
(DTypeSig false "inferRecordCreateWith" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "RecordInfo") (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyCon "Mono"))))))
(DFunDef false "inferRecordCreateWith" ((PVar "env") (PVar "rname") (PVar "ri") (PVar "fields")) (EBlock (DoLet false false (PVar "sr") (EApp (EApp (EVar "instantiateRecordShared") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "ri"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkMissingFields") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "rname")) (EApp (EVar "recordFieldNames") (EVar "ri"))) (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EMethodRef "map") (EVar "fieldAssignNamePair")) (EVar "fields"))) (EVar "omEmpty")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "unifyFieldAssignsIdx") (EVar "env")) (EVar "rname")) (EVar "ri")) (EApp (EVar "fst") (EVar "sr"))) (EVar "fields"))) (DoExpr (EApp (EVar "snd") (EVar "sr")))))
(DTypeSig false "unifyFieldAssignsIdx" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "RecordInfo") (TyFun (TyCon "RecordSubst") (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyCon "Unit")))))))
(DFunDef false "unifyFieldAssignsIdx" ((PVar "env") PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "unifyFieldAssignsIdx" ((PVar "env") (PVar "rname") (PVar "ri") (PVar "subst") (PCons (PCon "FieldAssign" (PVar "fn") (PVar "val")) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "unifyFieldAssignIdx") (EVar "env")) (EVar "rname")) (EVar "ri")) (EVar "subst")) (EVar "fn")) (EVar "val"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "unifyFieldAssignsIdx") (EVar "env")) (EVar "rname")) (EVar "ri")) (EVar "subst")) (EVar "rest")))))
(DTypeSig false "unifyFieldAssignIdx" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "RecordInfo") (TyFun (TyCon "RecordSubst") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Unit"))))))))
(DFunDef false "unifyFieldAssignIdx" ((PVar "env") (PVar "rname") (PVar "ri") (PVar "subst") (PVar "fn") (PVar "val")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "fn")) (EApp (EVar "recordFieldMap") (EVar "ri"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "pushTypeError") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit (LString "T-UNKNOWN-FIELD"))) (EApp (EApp (EVar "unknownFieldMsg") (EVar "fn")) (EVar "rname")))) (arm (PCon "Some" (PVar "fm")) () (EBlock (DoLet false false (PVar "at") (EApp (EApp (EVar "envAtIfSome") (EApp (EVar "exprSpanLoc") (EVar "val"))) (EVar "env"))) (DoLet false false (PVar "vt") (EApp (EApp (EVar "infer") (EVar "at")) (EVar "val"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "argumentIntoOrd") (EVar "True")) (EVar "at")) (EApp (EVar "Some") (EVar "val"))) (EApp (EApp (EApp (EVar "substRecordField") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "subst")) (EVar "fm"))) (EVar "vt")))))))
(DTypeSig false "inferFieldAccess" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "Mono"))))))
(DFunDef false "inferFieldAccess" ((PVar "env") (PVar "e") (PVar "fname") (PVar "ev")) (EIf (EBinOp "==" (EVar "fname") (ELit (LString "value"))) (EApp (EApp (EVar "inferValueField") (EVar "env")) (EVar "e")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "te") (EApp (EVar "normalize") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "resolveFieldRecord") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "te")) (EVar "fname")) (arm (PCon "None") () (EApp (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (arm (PCon "Some" (PTuple (PVar "rname") (PVar "ri"))) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EApp (EApp (EVar "siteHeadCell") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "ev"))) (EApp (EApp (EVar "stampedRecordHead") (EVar "rname")) (EVar "ri")))) (DoLet false false (PVar "ft") (EApp (EApp (EApp (EApp (EApp (EVar "inferFieldOfRecord") (EFieldAccess (EVar "env") "teDyn")) (EVar "te")) (EVar "rname")) (EVar "ri")) (EVar "fname"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fieldSelectionWellTyped") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "te")) (EVar "rname")) (EVar "ri")) (EVar "fname")) (EVar "ft")))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "inferValueField" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyCon "Mono"))))
(DFunDef false "inferValueField" ((PVar "env") (PVar "e")) (EApp (EApp (EVar "refStored") (EFieldAccess (EVar "env") "teDyn")) (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e"))))
(DTypeSig false "unboundVarFresh" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Mono"))))
(DFunDef false "unboundVarFresh" ((PVar "mctx") (PVar "name")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-UNBOUND"))) (EApp (EVar "unboundVarMsg") (EVar "name")))) (DoExpr (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit)))))
(DTypeSig false "inferRecordUpdate" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyFun (TyCon "EvId") (TyCon "Mono"))))))
(DFunDef false "inferRecordUpdate" ((PVar "env") (PVar "base") (PVar "fields") (PVar "ev")) (EMatch (EApp (EVar "firstFieldName") (EVar "fields")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "empty record update")))) (arm (PCon "Some" (PVar "fn")) () (EApp (EApp (EApp (EApp (EApp (EVar "inferRecordUpdateField") (EVar "env")) (EVar "base")) (EVar "fields")) (EVar "fn")) (EVar "ev")))))
(DTypeSig false "inferVariantUpdate" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyCon "Mono"))))))
(DFunDef false "inferVariantUpdate" ((PVar "env") (PVar "cname") (PVar "base") (PVar "fields")) (EMatch (EApp (EApp (EVar "lookupRecordByName") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "cname")) (arm (PCon "None") () (EApp (EApp (EVar "unknownRecordFresh") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "cname"))) (arm (PCon "Some" (PVar "ri")) () (EApp (EApp (EApp (EApp (EApp (EVar "inferRecordUpdateWith") (EVar "env")) (EVar "cname")) (EVar "base")) (EVar "fields")) (EVar "ri")))))
(DTypeSig false "inferRecordUpdateField" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "Mono")))))))
(DFunDef false "inferRecordUpdateField" ((PVar "env") (PVar "base") (PVar "fields") (PVar "fn") (PVar "ev")) (EBlock (DoLet false false (PVar "bt") (EApp (EVar "normalize") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "base")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "resolveFieldRecord") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "bt")) (EVar "fn")) (arm (PCon "None") () (EApp (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (arm (PCon "Some" (PTuple (PVar "rname") (PVar "ri"))) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EApp (EApp (EVar "siteHeadCell") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "ev"))) (EApp (EApp (EVar "stampedRecordHead") (EVar "rname")) (EVar "ri")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "inferRecordUpdatePicked") (EVar "rname")) (EVar "bt")) (EVar "env")) (EVar "fields")) (EVar "ri")))))))))
(DTypeSig false "inferRecordUpdatePicked" (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyFun (TyCon "RecordInfo") (TyCon "Mono")))))))
(DFunDef false "inferRecordUpdatePicked" ((PVar "rname") (PVar "bt") (PVar "env") (PVar "fields") (PVar "ri")) (EBlock (DoLet false false (PVar "sr") (EApp (EApp (EApp (EApp (EVar "instantiateRecordUpdate") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "rname")) (EVar "ri")) (EApp (EVar "assignedFieldNames") (EVar "fields")))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EFieldAccess (EVar "env") "teDyn")) (EVar "bt")) (EApp (EVar "snd") (EVar "sr")))) (DoExpr (EMatch (EApp (EVar "firstFieldName") (EVar "fields")) (arm (PCon "Some" (PVar "fn")) () (EApp (EApp (EApp (EApp (EApp (EVar "recordUpdateWellTyped") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "bt")) (EVar "rname")) (EVar "ri")) (EVar "fn"))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "unifyFieldAssignsIdx") (EVar "env")) (EVar "rname")) (EVar "ri")) (EApp (EVar "fst") (EVar "sr"))) (EVar "fields"))) (DoExpr (EApp (EVar "snd") (EVar "sr")))))
(DTypeSig false "inferRecordUpdateWith" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyFun (TyCon "RecordInfo") (TyCon "Mono")))))))
(DFunDef false "inferRecordUpdateWith" ((PVar "env") (PVar "rname") (PVar "base") (PVar "fields") (PVar "ri")) (EBlock (DoLet false false (PVar "sr") (EApp (EApp (EApp (EApp (EVar "instantiateRecordUpdate") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "rname")) (EVar "ri")) (EApp (EVar "assignedFieldNames") (EVar "fields")))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EFieldAccess (EVar "env") "teDyn")) (EApp (EApp (EVar "infer") (EVar "env")) (EVar "base"))) (EApp (EVar "snd") (EVar "sr")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "unifyFieldAssignsIdx") (EVar "env")) (EVar "rname")) (EVar "ri")) (EApp (EVar "fst") (EVar "sr"))) (EVar "fields"))) (DoExpr (EApp (EVar "snd") (EVar "sr")))))
(DTypeSig false "inferBinopE" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyCon "Mono")))))))
(DFunDef false "inferBinopE" ((PVar "env") (PVar "op") (PVar "l") (PVar "r") (PVar "dref")) (EBlock (DoLet false false (PVar "lt") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "l"))) (DoLet false false (PVar "rt") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "r"))) (DoLet false false (PVar "at") (EApp (EApp (EVar "envAtIfSome") (EApp (EApp (EVar "binopSpanLoc") (EVar "l")) (EVar "r"))) (EVar "env"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordBinopGoals") (EFieldAccess (EFieldAccess (EVar "at") "teDyn") "dcModule")) (EVar "op")) (EVar "dref")) (EMethodRef "lt"))) (DoExpr (EIf (EBinOp "==" (EVar "op") (ELit (LString "|>"))) (EApp (EApp (EApp (EApp (EApp (EVar "pipeOp") (EVar "at")) (EVar "l")) (EVar "r")) (EMethodRef "lt")) (EVar "rt")) (EApp (EApp (EApp (EApp (EVar "inferBinop") (EFieldAccess (EVar "at") "teDyn")) (EVar "op")) (EMethodRef "lt")) (EVar "rt"))))))
(DTypeSig false "binopSpanLoc" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "binopSpanLoc" ((PVar "l") (PVar "r")) (EMatch (ETuple (EApp (EVar "exprLoc") (EVar "l")) (EApp (EVar "exprLoc") (EVar "r"))) (arm (PTuple (PCon "Some" (PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") PWild PWild)) (PCon "Some" (PCon "Loc" PWild PWild PWild (PVar "el") (PVar "ec")))) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec")))) (arm (PTuple (PCon "Some" (PVar "ll")) (PCon "None")) () (EApp (EVar "Some") (EVar "ll"))) (arm (PTuple (PCon "None") (PCon "Some" (PVar "rr"))) () (EApp (EVar "Some") (EVar "rr"))) (arm (PTuple (PCon "None") (PCon "None")) () (EVar "None"))))
(DTypeSig false "inferUnopE" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyCon "Mono"))))))
(DFunDef false "inferUnopE" ((PVar "env") (PVar "op") (PVar "e") (PVar "dref")) (EBlock (DoLet false false (PVar "t") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordUnopSite") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "op")) (EVar "dref")) (EVar "t"))) (DoExpr (EIf (EBinOp "==" (EVar "op") (ELit (LString "-"))) (EApp (EApp (EApp (EVar "recordNegatedLitRange") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "t")) (EVar "e")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "inferUnop") (EFieldAccess (EVar "env") "teDyn")) (EVar "op")) (EVar "t")))))
(DTypeSig false "inferBinop" (TyFun (TyCon "DynCtx") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Mono"))))))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString "+")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EVar "numArithOp") (EVar "dyn")) (EMethodRef "lt")) (EVar "rt")))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString "-")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EVar "numArithOp") (EVar "dyn")) (EMethodRef "lt")) (EVar "rt")))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString "*")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EVar "numArithOp") (EVar "dyn")) (EMethodRef "lt")) (EVar "rt")))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString "/")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EVar "numArithOp") (EVar "dyn")) (EMethodRef "lt")) (EVar "rt")))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString "%")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EVar "numArithOp") (EVar "dyn")) (EMethodRef "lt")) (EVar "rt")))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString "++")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EVar "appendOp") (EVar "dyn")) (EMethodRef "lt")) (EVar "rt")))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString "==")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EVar "eqCompareOp") (EVar "dyn")) (EMethodRef "lt")) (EVar "rt")))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString "/=")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EVar "eqCompareOp") (EVar "dyn")) (EMethodRef "lt")) (EVar "rt")))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString "<")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EVar "ordCompareOp") (EVar "dyn")) (EMethodRef "lt")) (EVar "rt")))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString ">")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EVar "ordCompareOp") (EVar "dyn")) (EMethodRef "lt")) (EVar "rt")))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString "<=")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EVar "ordCompareOp") (EVar "dyn")) (EMethodRef "lt")) (EVar "rt")))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString ">=")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EVar "ordCompareOp") (EVar "dyn")) (EMethodRef "lt")) (EVar "rt")))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString "&&")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EVar "boolOp") (EVar "dyn")) (EMethodRef "lt")) (EVar "rt")))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString "||")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EVar "boolOp") (EVar "dyn")) (EMethodRef "lt")) (EVar "rt")))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString "::")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EVar "consOp") (EVar "dyn")) (EMethodRef "lt")) (EVar "rt")))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString ">>")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EApp (EVar "composeOp") (EVar "dyn")) (EMethodRef "lt")) (EVar "rt")) (EVar "False")))
(DFunDef false "inferBinop" ((PVar "dyn") (PLit (LString "<<")) (PVar "lt") (PVar "rt")) (EApp (EApp (EApp (EApp (EVar "composeOp") (EVar "dyn")) (EMethodRef "lt")) (EVar "rt")) (EVar "True")))
(DFunDef false "inferBinop" ((PVar "dyn") (PVar "op") PWild PWild) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "typecheck: unsupported operator ")) (EVar "op"))))
(DTypeSig false "appendOp" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Mono")))))
(DFunDef false "appendOp" ((PVar "dyn") (PVar "lt") (PVar "rt")) (EBlock (DoLet false false (PVar "plain") (EApp (EVar "peelQual") (EMethodRef "lt"))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "plain")) (EVar "rt"))) (DoExpr (EApp (EApp (EApp (EVar "recordIfaceObligation") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "BSemigroup")) (EVar "plain"))) (DoExpr (EVar "plain"))))
(DTypeSig false "numArithOp" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Mono")))))
(DFunDef false "numArithOp" ((PVar "dyn") (PVar "lt") (PVar "rt")) (EBlock (DoExpr (EApp (EApp (EVar "markNumlitOpTaint") (EFieldAccess (EVar "dyn") "dcModule")) (EMethodRef "lt"))) (DoExpr (EApp (EApp (EVar "markNumlitOpTaint") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "rt"))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EMethodRef "lt")) (EVar "rt"))) (DoExpr (EApp (EApp (EApp (EVar "recordIfaceObligation") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "BNum")) (EMethodRef "lt"))) (DoExpr (EMethodRef "lt"))))
(DTypeSig false "wideFitsI64" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "Bool")))))
(DFunDef false "wideFitsI64" ((PVar "hi") (PVar "lo") (PVar "negated")) (EBinOp "||" (EBinOp "<" (EVar "hi") (ELit (LInt 2147483648))) (EBinOp "&&" (EBinOp "&&" (EVar "negated") (EBinOp "==" (EVar "hi") (ELit (LInt 2147483648)))) (EBinOp "==" (EVar "lo") (ELit (LInt 0))))))
(DTypeSig true "checkWideLiterals" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "String") (TyCon "Int") (TyCon "Int") (TyCon "Bool") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyCon "Unit"))))
(DFunDef false "checkWideLiterals" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "checkWideLiterals" ((PVar "mctx") (PCons (PTuple (PVar "m") (PVar "lx") (PVar "hi") (PVar "lo") (PVar "negated") (PVar "loc")) (PVar "rest"))) (EBlock (DoLet false false (PVar "at") (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EFieldAccess (EVar "mctx") "mcLoc"))) (DoLet false false (PVar "shown") (EIf (EVar "negated") (EBinOp "++" (ELit (LString "-")) (EVar "lx")) (EVar "lx"))) (DoLet false false (PVar "pow62") (EBinOp "&&" (EBinOp "==" (EVar "hi") (ELit (LInt 1073741824))) (EBinOp "==" (EVar "lo") (ELit (LInt 0))))) (DoExpr (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TCon" (PLit (LString "Int")) PWild) ((GBool (EBinOp "&&" (EVar "pow62") (EApp (EVar "not") (EVar "negated"))))) (EApp (EApp (EVar "recordTypeError") (EVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "L-INT-OVERFLOW"))) (ELit (LInt 1))) (EVar "at")) (EVar "intMinLiteralMsg")) (EApp (EVar "Some") (EVar "intMinLiteralHelp"))) (EVar "None")))) (arm (PCon "TCon" (PVar "tag") PWild) ((GBool (EApp (EVar "isU64Head") (EVar "tag")))) (EIf (EVar "negated") (EApp (EApp (EVar "recordTypeError") (EVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "L-INT-OVERFLOW"))) (ELit (LInt 1))) (EVar "at")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "integer literal ")) (EApp (EMethodRef "display") (EVar "shown"))) (ELit (LString " does not fit U64 ("))) (EApp (EMethodRef "display") (EVar "u64RangeText"))) (ELit (LString ")")))) (EVar "None")) (EVar "None"))) (ELit LUnit))) (arm (PCon "TCon" (PVar "tag") PWild) ((GBool (EApp (EVar "isI64Head") (EVar "tag")))) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EVar "wideFitsI64") (EVar "hi")) (EVar "lo")) (EVar "negated"))) (EApp (EApp (EVar "recordTypeError") (EVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "L-INT-OVERFLOW"))) (ELit (LInt 1))) (EVar "at")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "integer literal ")) (EApp (EMethodRef "display") (EVar "shown"))) (ELit (LString " does not fit I64 ("))) (EApp (EMethodRef "display") (EVar "i64RangeText"))) (ELit (LString ")")))) (EVar "None")) (EVar "None"))) (ELit LUnit))) (arm (PCon "TCon" (PVar "tag") PWild) () (EApp (EApp (EVar "recordTypeError") (EVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "L-INT-OVERFLOW"))) (ELit (LInt 1))) (EVar "at")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "integer literal ")) (EApp (EMethodRef "display") (EVar "shown"))) (ELit (LString " does not fit "))) (EApp (EMethodRef "display") (EVar "tag"))) (ELit (LString "")))) (EApp (EVar "Some") (ELit (LString "only a `U64` or an `I64` holds a literal above 2^62")))) (EVar "None")))) (arm PWild () (EApp (EApp (EVar "recordTypeError") (EVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "L-INT-OVERFLOW"))) (ELit (LInt 1))) (EVar "at")) (EBinOp "++" (EBinOp "++" (ELit (LString "integer literal ")) (EApp (EMethodRef "display") (EVar "shown"))) (ELit (LString " fits only `U64` or `I64`, and its type here is undetermined")))) (EApp (EVar "Some") (EApp (EApp (EVar "wideAnnotateHelp") (EVar "shown")) (EVar "negated")))) (EVar "None")))))) (DoExpr (EApp (EApp (EVar "checkWideLiterals") (EVar "mctx")) (EVar "rest")))))
(DTypeSig true "checkFixedWidthLiterals" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyCon "Unit"))))
(DFunDef false "checkFixedWidthLiterals" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "checkFixedWidthLiterals" ((PVar "mctx") (PCons (PTuple (PVar "m") (PVar "n") (PVar "loc")) (PVar "rest"))) (EBlock (DoExpr (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TCon" (PVar "tag") PWild) () (EMatch (EApp (EVar "taggedFixedRange") (EVar "tag")) (arm (PCon "Some" (PTuple (PVar "lo") (PVar "hi"))) () (EIf (EBinOp "||" (EBinOp "<" (EVar "n") (EVar "lo")) (EBinOp ">" (EVar "n") (EVar "hi"))) (EApp (EApp (EVar "recordTypeError") (EVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "L-INT-OVERFLOW"))) (ELit (LInt 1))) (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EFieldAccess (EVar "mctx") "mcLoc"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "integer literal ")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString " does not fit "))) (EApp (EMethodRef "display") (EVar "tag"))) (ELit (LString " ("))) (EApp (EMethodRef "display") (EVar "lo"))) (ELit (LString ".."))) (EApp (EMethodRef "display") (EVar "hi"))) (ELit (LString ")")))) (EVar "None")) (EVar "None"))) (ELit LUnit))) (arm (PCon "None") () (EIf (EBinOp "&&" (EApp (EVar "isU64Head") (EVar "tag")) (EBinOp "<" (EVar "n") (ELit (LInt 0)))) (EApp (EApp (EVar "recordTypeError") (EVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "L-INT-OVERFLOW"))) (ELit (LInt 1))) (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EFieldAccess (EVar "mctx") "mcLoc"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "integer literal ")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString " does not fit U64 ("))) (EApp (EMethodRef "display") (EVar "u64RangeText"))) (ELit (LString ")")))) (EVar "None")) (EVar "None"))) (ELit LUnit))))) (arm PWild () (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "checkFixedWidthLiterals") (EVar "mctx")) (EVar "rest")))))
(DTypeSig false "eqCompareOp" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Mono")))))
(DFunDef false "eqCompareOp" ((PVar "dyn") (PVar "lt") (PVar "rt")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EMethodRef "lt")) (EVar "rt"))) (DoExpr (EApp (EApp (EApp (EVar "recordIfaceObligation") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "BEq")) (EMethodRef "lt"))) (DoExpr (EApp (EVar "tconBuiltin") (ELit (LString "Bool"))))))
(DTypeSig false "ordCompareOp" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Mono")))))
(DFunDef false "ordCompareOp" ((PVar "dyn") (PVar "lt") (PVar "rt")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EMethodRef "lt")) (EVar "rt"))) (DoExpr (EApp (EApp (EApp (EVar "recordIfaceObligation") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "BOrd")) (EMethodRef "lt"))) (DoExpr (EApp (EVar "tconBuiltin") (ELit (LString "Bool"))))))
(DTypeSig false "boolOp" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Mono")))))
(DFunDef false "boolOp" ((PVar "dyn") (PVar "lt") (PVar "rt")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EMethodRef "lt")) (EApp (EVar "tconBuiltin") (ELit (LString "Bool"))))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "rt")) (EApp (EVar "tconBuiltin") (ELit (LString "Bool"))))) (DoExpr (EApp (EVar "tconBuiltin") (ELit (LString "Bool"))))))
(DTypeSig false "consOp" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Mono")))))
(DFunDef false "consOp" ((PVar "dyn") (PVar "lt") (PVar "rt")) (EBlock (DoLet false false (PVar "tailElem") (EApp (EApp (EVar "freshVar") (EFieldAccess (EVar "dyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EVar "noteNumlitCtx") (EFieldAccess (EVar "dyn") "dcModule")) (EMethodRef "lt")) (EVar "rt")) (EVar "JoinCons"))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "rt")) (EApp (EApp (EVar "TApp") (EApp (EVar "tconBuiltin") (ELit (LString "List")))) (EVar "tailElem")))) (DoExpr (EApp (EApp (EVar "TApp") (EApp (EVar "tconBuiltin") (ELit (LString "List")))) (EApp (EApp (EApp (EVar "joinValueTypes") (EVar "dyn")) (EVar "JoinCons")) (EListLit (ETuple (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcLoc") (EMethodRef "lt")) (ETuple (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcLoc") (EVar "tailElem"))))))))
(DTypeSig false "pipeOp" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Mono")))))))
(DFunDef false "pipeOp" ((PVar "env") (PVar "l") (PVar "r") (PVar "lt") (PVar "rt")) (EBlock (DoLet false false (PVar "res") (EApp (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "eff") (EApp (EApp (EApp (EApp (EApp (EVar "applicationRow") (EVar "env")) (EApp (EApp (EVar "EApp") (EVar "r")) (EVar "l"))) (EVar "rt")) (EMethodRef "lt")) (EVar "res"))) (DoExpr (EApp (EApp (EApp (EVar "performEffect") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "curEffect")) (EVar "eff"))) (DoExpr (EApp (EApp (EVar "notePerformSite") (EVar "env")) (EVar "eff"))) (DoExpr (EVar "res"))))
(DTypeSig false "composeOp" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyFun (TyCon "Bool") (TyCon "Mono"))))))
(DFunDef false "composeOp" ((PVar "dyn") (PVar "gt") (PVar "ht") (PCon "False")) (EBlock (DoLet false false (PTuple (PVar "a") (PVar "first") (PVar "b")) (EApp (EApp (EVar "calleeArrow") (EVar "dyn")) (EMethodRef "gt"))) (DoLet false false (PVar "c") (EApp (EApp (EVar "freshVar") (EFieldAccess (EVar "dyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "second") (EApp (EApp (EApp (EApp (EVar "applicationRowTyped") (EVar "dyn")) (EVar "ht")) (EVar "b")) (EVar "c"))) (DoExpr (EApp (EApp (EApp (EVar "TFun") (EVar "a")) (EApp (EApp (EApp (EVar "joinRows") (EApp (EVar "joinCellOf") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph"))) (EVar "first")) (EVar "second"))) (EVar "c")))))
(DFunDef false "composeOp" ((PVar "dyn") (PVar "gt") (PVar "ht") (PCon "True")) (EApp (EApp (EApp (EApp (EVar "composeOp") (EVar "dyn")) (EVar "ht")) (EMethodRef "gt")) (EVar "False")))
(DTypeSig false "inferUnop" (TyFun (TyCon "DynCtx") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyCon "Mono")))))
(DFunDef false "inferUnop" ((PVar "dyn") (PLit (LString "-")) (PVar "t")) (EApp (EApp (EVar "negateOp") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "t")))
(DFunDef false "inferUnop" ((PVar "dyn") (PLit (LString "!")) (PVar "t")) (EApp (EApp (EVar "derefOp") (EVar "dyn")) (EVar "t")))
(DFunDef false "inferUnop" ((PVar "dyn") (PVar "op") PWild) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "typecheck: unsupported unary op ")) (EVar "op"))))
(DTypeSig false "derefOp" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyCon "Mono"))))
(DFunDef false "derefOp" ((PVar "dyn") (PVar "t")) (EIf (EApp (EVar "monoIsBool") (EApp (EVar "normalize") (EVar "t"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushTypeErrorHelpFixAt") (EFieldAccess (EVar "dyn") "dcModule")) (ELit (LString "T-BANG-ON-BOOL"))) (EVar "None")) (EVar "bangOnBoolMsg")) (EVar "bangOnBoolHelp")) (EVar "None"))) (DoExpr (EApp (EVar "tconBuiltin") (ELit (LString "Bool"))))) (EApp (EApp (EVar "refStored") (EVar "dyn")) (EVar "t"))))
(DTypeSig false "negateOp" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyCon "Mono"))))
(DFunDef false "negateOp" ((PVar "mctx") (PVar "t")) (EBlock (DoExpr (EApp (EApp (EVar "markNumlitOpTaint") (EVar "mctx")) (EVar "t"))) (DoExpr (EApp (EApp (EApp (EVar "recordIfaceObligation") (EVar "mctx")) (EVar "BNum")) (EVar "t"))) (DoExpr (EVar "t"))))
(DTypeSig false "inferInfix" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Mono"))))))
(DFunDef false "inferInfix" ((PVar "env") (PVar "op") (PVar "l") (PVar "r")) (EBlock (DoLet false false (PVar "ft") (EApp (EApp (EVar "inferVar") (EVar "env")) (EVar "op"))) (DoLet false false (PVar "lt") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "l"))) (DoLet false false (PVar "rt") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "r"))) (DoLet false false (PVar "inner") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "op"))) (EVar "l"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "inferApp") (EVar "env")) (EApp (EApp (EVar "EApp") (EVar "inner")) (EVar "r"))) (EApp (EApp (EApp (EApp (EVar "inferApp") (EVar "env")) (EVar "inner")) (EVar "ft")) (EMethodRef "lt"))) (EVar "rt")))))
(DTypeSig false "inferVar" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyCon "Mono"))))
(DFunDef false "inferVar" ((PVar "env") (PVar "x")) (EApp (EApp (EApp (EVar "inferVarId") (EVar "env")) (EVar "x")) (ELit (LInt 0))))
(DTypeSig false "inferVarId" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Mono")))))
(DFunDef false "inferVarId" ((PVar "env") (PVar "x") (PVar "id")) (EMatch (EApp (EApp (EVar "maybeStandaloneValueMono") (EVar "env")) (EVar "x")) (arm (PCon "Some" (PVar "m")) () (EVar "m")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "inferVarPlainId") (EVar "env")) (EVar "x")) (EVar "id")))))
(DTypeSig false "inferVarPlainId" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Mono")))))
(DFunDef false "inferVarPlainId" ((PVar "env") (PVar "x") (PVar "id")) (EMatch (EApp (EApp (EVar "lookupVar") (EVar "env")) (EVar "x")) (arm (PCon "Some" (PVar "s")) () (EMatch (EApp (EApp (EVar "lookupMethodRow") (EVar "env")) (EVar "x")) (arm (PCon "Some" PWild) () (EBlock (DoLet false false (PVar "inst") (EApp (EApp (EApp (EApp (EVar "instantiateVarTrackedWithSubst") (EVar "env")) (EVar "x")) (EVar "id")) (EVar "s"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordMethodObligationOwned") (EVar "env")) (EVar "x")) (EVar "s")) (EFieldAccess (EVar "inst") "mtiBody")) (EFieldAccess (EVar "inst") "mtiSubstitution")) (EVar "None"))))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "mono") (EApp (EApp (EApp (EApp (EVar "instantiateVarTrackedId") (EVar "env")) (EVar "x")) (EVar "id")) (EVar "s"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordMethodObligationGuarded") (EVar "env")) (EVar "x")) (EVar "s")) (EVar "mono")) (EApp (EApp (EVar "methodOmittedVars") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")))))))) (arm (PCon "None") () (EApp (EApp (EVar "unboundVarFresh") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")))))
(DTypeSig true "appArgLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "appArgLoc" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "appArgLoc") (EVar "e")))
(DFunDef false "appArgLoc" ((PCon "EApp" PWild (PVar "x"))) (EApp (EVar "exprSpanLoc") (EVar "x")))
(DFunDef false "appArgLoc" (PWild) (EVar "None"))
(DTypeSig false "appSpanLoc" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "appSpanLoc" ((PVar "enclosing") (PVar "app")) (EMatch (EApp (EVar "exprSpanLoc") (EVar "app")) (arm (PCon "None") () (EVar "enclosing")) (arm (PCon "Some" (PVar "own")) () (EIf (EApp (EApp (EVar "beginsWithSpan") (EVar "enclosing")) (EVar "own")) (EVar "enclosing") (EApp (EVar "Some") (EVar "own"))))))
(DTypeSig false "beginsWithSpan" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Loc") (TyCon "Bool"))))
(DFunDef false "beginsWithSpan" ((PCon "Some" (PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))) (PCon "Loc" PWild (PVar "isl") (PVar "isc") (PVar "iel") (PVar "iec"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "sl") (EVar "isl")) (EBinOp ">=" (EBinOp "-" (EVar "isc") (EVar "sc")) (ELit (LInt 0)))) (EBinOp "<=" (EBinOp "-" (EVar "isc") (EVar "sc")) (ELit (LInt 1)))) (EBinOp "||" (EBinOp ">" (EVar "el") (EVar "iel")) (EBinOp "&&" (EBinOp "==" (EVar "el") (EVar "iel")) (EBinOp ">=" (EVar "ec") (EVar "iec"))))))
(DFunDef false "beginsWithSpan" ((PCon "None") PWild) (EVar "False"))
(DTypeSig false "appSpineHeadLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "appSpineHeadLoc" ((PCon "ELoc" (PVar "loc") (PVar "e"))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "appSpineHeadLoc") (EVar "e"))) (EApp (EVar "Some") (EVar "loc"))))
(DFunDef false "appSpineHeadLoc" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "appSpineHeadLoc") (EVar "f")))
(DFunDef false "appSpineHeadLoc" ((PVar "e")) (EApp (EVar "exprLoc") (EVar "e")))
(DTypeSig false "appNodeArg" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "appNodeArg" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "appNodeArg") (EVar "e")))
(DFunDef false "appNodeArg" ((PCon "EApp" PWild (PVar "x"))) (EVar "x"))
(DFunDef false "appNodeArg" ((PVar "e")) (EVar "e"))
(DTypeSig false "inferSpineArgs" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyTuple (TyCon "Expr") (TyCon "Mono"))))))
(DFunDef false "inferSpineArgs" ((PVar "env") (PList)) (EListLit))
(DFunDef false "inferSpineArgs" ((PVar "env") (PCons (PVar "n") (PVar "rest"))) (EBlock (DoLet false false (PVar "t") (EApp (EApp (EVar "infer") (EVar "env")) (EApp (EVar "appNodeArg") (EVar "n")))) (DoExpr (EBinOp "::" (ETuple (EVar "n") (EVar "t")) (EApp (EApp (EVar "inferSpineArgs") (EVar "env")) (EVar "rest"))))))
(DTypeSig false "inferAppNodes" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Expr") (TyCon "Mono"))) (TyCon "Mono")))))
(DFunDef false "inferAppNodes" ((PVar "env") (PVar "ft") (PList)) (EVar "ft"))
(DFunDef false "inferAppNodes" ((PVar "env") (PVar "ft") (PCons (PTuple (PVar "node") (PVar "at")) (PVar "rest"))) (EApp (EApp (EApp (EVar "inferAppNodes") (EVar "env")) (EApp (EApp (EApp (EApp (EVar "inferApp") (EVar "env")) (EVar "node")) (EVar "ft")) (EVar "at"))) (EVar "rest")))
(DTypeSig false "unifySpineResult" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Expr") (TyCon "Mono"))) (TyCon "Mono"))))))
(DFunDef false "unifySpineResult" ((PVar "env") PWild (PVar "ft") (PList)) (EVar "ft"))
(DFunDef false "unifySpineResult" ((PVar "env") (PVar "f") (PVar "ft") (PCons (PTuple (PVar "node") (PVar "at")) (PVar "rest"))) (EBlock (DoLet false false (PVar "r") (EApp (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "eff") (EApp (EApp (EApp (EApp (EApp (EVar "applicationRow") (EVar "env")) (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "node"))) (EVar "ft")) (EVar "at")) (EVar "r"))) (DoExpr (EApp (EApp (EApp (EVar "performEffect") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "curEffect")) (EVar "eff"))) (DoExpr (EApp (EApp (EVar "notePerformSite") (EVar "env")) (EVar "eff"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "unifySpineResult") (EVar "env")) (EVar "f")) (EVar "r")) (EVar "rest")))))
(DTypeSig false "inferExpected" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyCon "Mono")))))
(DFunDef false "inferExpected" ((PVar "env") (PCon "ELoc" (PVar "l") (PVar "e")) (PVar "expected")) (EApp (EApp (EApp (EVar "inferExpected") (EApp (EApp (EVar "envAt") (EApp (EVar "Some") (EVar "l"))) (EVar "env"))) (EVar "e")) (EVar "expected")))
(DFunDef false "inferExpected" ((PVar "env") (PCon "ELam" (PVar "pats") (PVar "body")) (PVar "expected")) (EMatch (EApp (EVar "normalize") (EVar "expected")) (arm (PCon "TFun" PWild PWild PWild) () (EApp (EApp (EApp (EApp (EVar "inferLamChecked") (EApp (EApp (EVar "envAtIfSome") (EApp (EVar "exprLoc") (EVar "body"))) (EVar "env"))) (EApp (EVar "Some") (EApp (EVar "normalize") (EVar "expected")))) (EVar "pats")) (EVar "body"))) (arm PWild () (EApp (EApp (EVar "infer") (EVar "env")) (EApp (EApp (EVar "ELam") (EVar "pats")) (EVar "body"))))))
(DFunDef false "inferExpected" ((PVar "env") (PVar "e") (PVar "expected")) (EIf (EBinOp "&&" (EApp (EVar "monoHasArrowInSlot") (EVar "expected")) (EApp (EApp (EVar "monoHasNonCovariantSlot") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "expected"))) (EMatch (EApp (EVar "appSpineExpr") (EVar "e")) (arm (PTuple (PVar "hd") (PVar "args")) () (EIf (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "args")) (EApp (EVar "not") (EApp (EApp (EVar "plainAppHead") (EVar "env")) (EVar "hd")))) (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e")) (EApp (EApp (EApp (EApp (EVar "inferAppResultFirst") (EVar "env")) (EVar "hd")) (EVar "args")) (EVar "expected"))))) (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e"))))
(DTypeSig false "appSpineExpr" (TyFun (TyCon "Expr") (TyTuple (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr")))))
(DFunDef false "appSpineExpr" ((PVar "e")) (EApp (EApp (EVar "appSpineExprGo") (EVar "e")) (EListLit)))
(DTypeSig false "appSpineExprGo" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))))
(DFunDef false "appSpineExprGo" ((PCon "EApp" (PVar "f") (PVar "x")) (PVar "args")) (EApp (EApp (EVar "appSpineExprGo") (EVar "f")) (EBinOp "::" (EVar "x") (EVar "args"))))
(DFunDef false "appSpineExprGo" ((PCon "ELoc" PWild (PCon "EApp" (PVar "f") (PVar "x"))) (PVar "args")) (EApp (EApp (EVar "appSpineExprGo") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))) (EVar "args")))
(DFunDef false "appSpineExprGo" ((PVar "e") (PVar "args")) (ETuple (EVar "e") (EVar "args")))
(DTypeSig false "plainAppHead" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "plainAppHead" ((PVar "env") (PCon "ELoc" PWild (PVar "inner"))) (EApp (EApp (EVar "plainAppHead") (EVar "env")) (EVar "inner")))
(DFunDef false "plainAppHead" ((PVar "env") (PAs "hd" (PCon "EVar" PWild))) (EApp (EApp (EVar "plainAppHeadVar") (EVar "env")) (EVar "hd")))
(DFunDef false "plainAppHead" ((PVar "env") (PAs "hd" (PCon "EVarId" PWild PWild))) (EApp (EApp (EVar "plainAppHeadVar") (EVar "env")) (EVar "hd")))
(DFunDef false "plainAppHead" ((PVar "env") (PCon "EDictAt" PWild PWild)) (EVar "True"))
(DFunDef false "plainAppHead" ((PVar "env") PWild) (EVar "False"))
(DTypeSig false "inferAppResultFirst" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyFun (TyCon "Mono") (TyCon "Mono"))))))
(DFunDef false "inferAppResultFirst" ((PVar "env") (PVar "hd") (PVar "args") (PVar "expected")) (EBlock (DoLet false false (PVar "ft") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "hd"))) (DoExpr (EMatch (EApp (EApp (EVar "resultAfterArrows") (EApp (EVar "listLen") (EVar "args"))) (EVar "ft")) (arm (PCon "Some" (PVar "res")) () (EApp (EApp (EApp (EVar "unifyIn") (EFieldAccess (EVar "env") "teDyn")) (EVar "res")) (EVar "expected"))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EApp (EApp (EApp (EApp (EVar "inferAppArgsAgainst") (EVar "env")) (EVar "hd")) (EVar "ft")) (EVar "args")))))
(DTypeSig false "inferAppArgsAgainst" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Mono"))))))
(DFunDef false "inferAppArgsAgainst" ((PVar "env") PWild (PVar "ft") (PList)) (EVar "ft"))
(DFunDef false "inferAppArgsAgainst" ((PVar "env") (PVar "appSoFar") (PVar "ft") (PCons (PVar "x") (PVar "rest"))) (EBlock (DoLet false false (PVar "xt") (EMatch (EApp (EVar "lamUnderLoc") (EVar "x")) (arm (PCon "Some" (PTuple (PVar "loc") (PVar "pats") (PVar "body"))) () (EApp (EApp (EApp (EApp (EVar "inferLamChecked") (EApp (EApp (EVar "envAtIfSome") (EVar "loc")) (EVar "env"))) (EApp (EVar "Some") (EApp (EApp (EVar "funDomain") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EVar "normalize") (EVar "ft"))))) (EVar "pats")) (EVar "body"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "inferExpected") (EVar "env")) (EVar "x")) (EApp (EApp (EVar "funDomain") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EVar "normalize") (EVar "ft"))))))) (DoLet false false (PVar "res") (EApp (EApp (EApp (EApp (EVar "inferApp") (EVar "env")) (EApp (EApp (EVar "EApp") (EVar "appSoFar")) (EVar "x"))) (EVar "ft")) (EVar "xt"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "inferAppArgsAgainst") (EVar "env")) (EApp (EApp (EVar "EApp") (EVar "appSoFar")) (EVar "x"))) (EVar "res")) (EVar "rest")))))
(DTypeSig false "inferAppExpr" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Mono")))))
(DFunDef false "inferAppExpr" ((PVar "env") (PVar "f") (PVar "x")) (EMatch (EApp (EVar "lamUnderLoc") (EVar "x")) (arm (PCon "Some" (PTuple (PVar "loc") (PVar "pats") (PVar "body"))) () (EBlock (DoLet false false (PVar "ft") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "f"))) (DoLet false false (PVar "lamExpected") (EApp (EApp (EVar "funDomain") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EVar "normalize") (EVar "ft")))) (DoLet false false (PVar "xt") (EApp (EApp (EApp (EApp (EVar "inferLamChecked") (EApp (EApp (EVar "envAtIfSome") (EVar "loc")) (EVar "env"))) (EApp (EVar "Some") (EVar "lamExpected"))) (EVar "pats")) (EVar "body"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "inferApp") (EVar "env")) (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))) (EVar "ft")) (EVar "xt"))))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "shadowStandaloneSpineHeadAt") (EVar "env")) (EVar "f")) (arm (PCon "Some" (PTuple (PVar "mname") (PVar "arityRefs") (PVar "tagRefs") (PVar "hd") (PVar "nodes"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferShadowAppAt") (EVar "env")) (EVar "mname")) (EVar "arityRefs")) (EVar "tagRefs")) (EVar "hd")) (EVar "nodes")) (EVar "f")) (EVar "x"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "shadowStandaloneHead") (EVar "env")) (EVar "f")) (arm (PCon "Some" (PTuple (PVar "mname") (PVar "arityRefs") (PVar "tagRefs"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferShadowApp") (EVar "env")) (EVar "mname")) (EVar "arityRefs")) (EVar "tagRefs")) (EVar "f")) (EVar "x"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "definerShadowSpineArgAt") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "f")) (arm (PCon "Some" (PTuple (PVar "dname") (PVar "darityRef") (PVar "dtagRef") (PVar "dimplRef") (PVar "dinnerRef") (PVar "dhd") (PVar "dnodes"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferDefinerShadowAppAt") (EVar "env")) (EVar "dname")) (EVar "darityRef")) (EVar "dtagRef")) (EVar "dimplRef")) (EVar "dinnerRef")) (EVar "dhd")) (EVar "dnodes")) (EVar "f")) (EVar "x"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "definerShadowSpineVarAt") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "f")) (arm (PCon "Some" (PTuple (PVar "dname") (PVar "dhd") (PVar "dnodes"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferDefinerShadowVarAppAt") (EVar "env")) (EVar "dname")) (EVar "dhd")) (EVar "dnodes")) (EVar "f")) (EVar "x"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "definerShadowArgHead") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "f")) (arm (PCon "Some" (PTuple (PVar "dname") (PVar "darityRef") (PVar "dtagRef") (PVar "dimplRef") (PVar "dinnerRef"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferDefinerShadowApp") (EVar "env")) (EVar "dname")) (EVar "darityRef")) (EVar "dtagRef")) (EVar "dimplRef")) (EVar "dinnerRef")) (EVar "f")) (EVar "x"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "definerShadowVarHead") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "f")) (arm (PCon "Some" (PVar "dname")) () (EApp (EApp (EApp (EApp (EVar "inferDefinerShadowVarApp") (EVar "env")) (EVar "dname")) (EVar "f")) (EVar "x"))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "ft") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "f"))) (DoLet false false (PVar "xt") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "x"))) (DoLet false false (PVar "pend") (EApp (EApp (EApp (EVar "tupleCallShapeHint") (EVar "f")) (EVar "x")) (EVar "ft"))) (DoLet false false (PVar "res") (EApp (EApp (EApp (EApp (EVar "inferApp") (EVar "env")) (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))) (EVar "ft")) (EVar "xt"))) (DoExpr (EMatch (EVar "pend") (arm (PCon "Some" (PTuple (PVar "help") (PVar "fix"))) () (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "tupleCallCandidates")) (EBinOp "::" (ETuple (EVar "res") (EVar "help") (EVar "fix")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "tupleCallCandidates") "value")))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EVar "res"))))))))))))))))))
(DTypeSig false "inferShadowApp" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Int")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Ref") (TyCon "Route")) (TyApp (TyCon "Ref") (TyCon "Inner")))) (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Mono"))))))))
(DFunDef false "inferShadowApp" ((PVar "env") (PVar "mname") (PVar "arityRefs") (PVar "tagRefs") (PVar "f") (PVar "x")) (EBlock (DoLet false false (PVar "dloc") (EApp (EApp (EVar "appSpanLoc") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")))) (DoLet false false (PVar "tx") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "x"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "groundShadowReceiver") (EFieldAccess (EVar "env") "teDyn")) (EApp (EApp (EVar "importerShadowDomain") (EVar "env")) (EVar "mname"))) (EVar "tx")) (EApp (EApp (EApp (EVar "definerReceiverIsDictVar") (EFieldAccess (EVar "env") "teDyn")) (EVar "mname")) (EVar "tx"))) (EVar "dloc"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "groundAdmittedReceivers") (EVar "env")) (EVar "mname")) (EListLit (EVar "tx"))) (EVar "dloc"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "importerAdmittedVerdict") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "bodyImplEnvRef") "value")) (EVar "mname")) (EListLit (EVar "tx"))) (arm (PCon "AdReject" (PVar "ifs")) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "pushAmbiguousShadowDecl") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "mname")) (EVar "ifs")) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "appSpineHeadLoc") (EVar "f"))) (EVar "dloc")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferShadowStandaloneArm") (EVar "env")) (EVar "mname")) (EVar "arityRefs")) (EVar "tagRefs")) (EVar "f")) (EVar "x")) (EVar "tx"))))) (arm (PCon "AdStandalone") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferShadowStandaloneArm") (EVar "env")) (EVar "mname")) (EVar "arityRefs")) (EVar "tagRefs")) (EVar "f")) (EVar "x")) (EVar "tx"))) (arm (PCon "AdDefer") () (EMatch (EApp (EVar "headTyconMono") (EVar "tx")) (arm (PCon "Some" (PVar "head")) () (EIf (EApp (EApp (EApp (EApp (EVar "ieImplExistsForHead") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "bodyImplEnvRef") "value")) (EVar "mname")) (EVar "head")) (EApp (EApp (EApp (EApp (EVar "inferApp") (EVar "env")) (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))) (EApp (EApp (EVar "inferShadowAppHead") (EVar "env")) (EVar "f"))) (EVar "tx")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferShadowStandaloneArm") (EVar "env")) (EVar "mname")) (EVar "arityRefs")) (EVar "tagRefs")) (EVar "f")) (EVar "x")) (EVar "tx")))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "inferApp") (EVar "env")) (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))) (EApp (EApp (EVar "inferShadowAppHead") (EVar "env")) (EVar "f"))) (EVar "tx")))))))))
(DTypeSig false "inferShadowStandaloneArm" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Int")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Ref") (TyCon "Route")) (TyApp (TyCon "Ref") (TyCon "Inner")))) (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyCon "Mono")))))))))
(DFunDef false "inferShadowStandaloneArm" ((PVar "env") (PVar "mname") (PVar "arityRefs") (PVar "tagRefs") (PVar "f") (PVar "x") (PVar "tx")) (EMatch (EApp (EApp (EVar "lookupStandaloneValue") (EVar "env")) (EVar "mname")) (arm (PCon "Some" (PVar "value")) () (EBlock (DoLet false false (PVar "occurrence") (EApp (EApp (EApp (EApp (EApp (EVar "instantiateStandaloneOccurrence") (EVar "env")) (EVar "mname")) (ELit (LString ""))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "appSpineHeadLoc") (EVar "f"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc"))) (EVar "value"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordStandaloneAt") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "mname")) (EVar "f")) (EVar "occurrence"))) (DoLet false false (PVar "smono") (EFieldAccess (EFieldAccess (EVar "occurrence") "svoInstance") "mtiBody")) (DoExpr (EApp (EApp (EVar "stampMethodArities") (EVar "arityRefs")) (EApp (EVar "funArity") (EVar "smono")))) (DoLet false false (PVar "r") (EApp (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "eff") (EApp (EApp (EApp (EApp (EApp (EVar "applicationRow") (EApp (EApp (EVar "envAtIfSome") (EApp (EApp (EVar "appSpanLoc") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")))) (EVar "env"))) (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))) (EVar "smono")) (EVar "tx")) (EVar "r"))) (DoExpr (EApp (EApp (EApp (EVar "performEffect") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "curEffect")) (EVar "eff"))) (DoExpr (EApp (EVar "stampRoutes") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "tagRefs")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordSelectedStandaloneRoutes") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "mname")) (EFieldAccess (EVar "occurrence") "svoDicts")) (EVar "tagRefs")) (EVar "tx"))) (DoExpr (EVar "r")))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "inferApp") (EVar "env")) (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))) (EApp (EApp (EVar "inferShadowAppHead") (EVar "env")) (EVar "f"))) (EVar "tx")))))
(DTypeSig false "inferShadowAppHead" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyCon "Mono"))))
(DFunDef false "inferShadowAppHead" ((PVar "env") (PVar "f")) (EApp (EApp (EVar "infer") (EApp (EVar "shadowHeadEnv") (EVar "env"))) (EVar "f")))
(DTypeSig false "inferShadowAppAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Int")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Ref") (TyCon "Route")) (TyApp (TyCon "Ref") (TyCon "Inner")))) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Mono"))))))))))
(DFunDef false "inferShadowAppAt" ((PVar "env") (PVar "mname") (PVar "arityRefs") (PVar "tagRefs") (PVar "hd") (PVar "nodes") (PVar "f") (PVar "x")) (EBlock (DoLet false false (PVar "dloc") (EApp (EApp (EVar "appSpanLoc") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")))) (DoLet false false (PVar "pre") (EApp (EApp (EVar "inferSpineArgs") (EVar "env")) (EVar "nodes"))) (DoLet false false (PVar "k") (EApp (EVar "listLen") (EVar "pre"))) (DoLet false false (PVar "tx") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "x"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "groundShadowReceiver") (EFieldAccess (EVar "env") "teDyn")) (EApp (EApp (EApp (EVar "importerShadowDomainAt") (EVar "env")) (EVar "mname")) (EVar "k"))) (EVar "tx")) (EApp (EApp (EApp (EVar "definerReceiverIsDictVar") (EFieldAccess (EVar "env") "teDyn")) (EVar "mname")) (EVar "tx"))) (EVar "dloc"))) (DoLet false false (PVar "ats") (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "pre")) (EListLit (EVar "tx")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "groundAdmittedReceivers") (EVar "env")) (EVar "mname")) (EVar "ats")) (EVar "dloc"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "importerAdmittedVerdict") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "bodyImplEnvRef") "value")) (EVar "mname")) (EVar "ats")) (arm (PCon "AdReject" (PVar "ifs")) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "pushAmbiguousShadowDecl") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "mname")) (EVar "ifs")) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "appSpineHeadLoc") (EVar "f"))) (EVar "dloc")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferShadowStandaloneArmAt") (EVar "env")) (EVar "mname")) (EVar "arityRefs")) (EVar "tagRefs")) (EVar "hd")) (EVar "pre")) (EVar "f")) (EVar "x")) (EVar "tx"))))) (arm (PCon "AdStandalone") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferShadowStandaloneArmAt") (EVar "env")) (EVar "mname")) (EVar "arityRefs")) (EVar "tagRefs")) (EVar "hd")) (EVar "pre")) (EVar "f")) (EVar "x")) (EVar "tx"))) (arm (PCon "AdDefer") () (EMatch (EApp (EVar "headTyconMono") (EVar "tx")) (arm (PCon "Some" (PVar "head")) () (EIf (EApp (EApp (EApp (EApp (EVar "ieImplExistsForHead") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "bodyImplEnvRef") "value")) (EVar "mname")) (EVar "head")) (EApp (EApp (EApp (EVar "inferAppNodes") (EVar "env")) (EApp (EApp (EVar "inferShadowAppHead") (EVar "env")) (EVar "hd"))) (EBinOp "++" (EVar "pre") (EListLit (ETuple (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")) (EVar "tx"))))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferShadowStandaloneArmAt") (EVar "env")) (EVar "mname")) (EVar "arityRefs")) (EVar "tagRefs")) (EVar "hd")) (EVar "pre")) (EVar "f")) (EVar "x")) (EVar "tx")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "inferAppNodes") (EVar "env")) (EApp (EApp (EVar "inferShadowAppHead") (EVar "env")) (EVar "hd"))) (EBinOp "++" (EVar "pre") (EListLit (ETuple (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")) (EVar "tx"))))))))))))
(DTypeSig false "inferShadowStandaloneArmAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Int")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Ref") (TyCon "Route")) (TyApp (TyCon "Ref") (TyCon "Inner")))) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Expr") (TyCon "Mono"))) (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyCon "Mono")))))))))))
(DFunDef false "inferShadowStandaloneArmAt" ((PVar "env") (PVar "mname") (PVar "arityRefs") (PVar "tagRefs") (PVar "hd") (PVar "pre") (PVar "f") (PVar "x") (PVar "tx")) (EMatch (EApp (EApp (EVar "lookupStandaloneValue") (EVar "env")) (EVar "mname")) (arm (PCon "Some" (PVar "value")) () (EBlock (DoLet false false (PVar "occurrence") (EApp (EApp (EApp (EApp (EApp (EVar "instantiateStandaloneOccurrence") (EVar "env")) (EVar "mname")) (ELit (LString ""))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "appSpineHeadLoc") (EVar "f"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc"))) (EVar "value"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordStandaloneAt") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "mname")) (EVar "hd")) (EVar "occurrence"))) (DoLet false false (PVar "smono") (EFieldAccess (EFieldAccess (EVar "occurrence") "svoInstance") "mtiBody")) (DoExpr (EApp (EApp (EVar "stampMethodArities") (EVar "arityRefs")) (EApp (EVar "funArity") (EVar "smono")))) (DoLet false false (PVar "r") (EApp (EApp (EApp (EApp (EVar "unifySpineResult") (EApp (EApp (EVar "envAtIfSome") (EApp (EApp (EVar "appSpanLoc") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")))) (EVar "env"))) (EVar "f")) (EVar "smono")) (EBinOp "++" (EVar "pre") (EListLit (ETuple (EVar "x") (EVar "tx")))))) (DoExpr (EApp (EVar "stampRoutes") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "tagRefs")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordSelectedStandaloneRoutes") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "mname")) (EFieldAccess (EVar "occurrence") "svoDicts")) (EVar "tagRefs")) (EVar "tx"))) (DoExpr (EVar "r")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "inferAppNodes") (EVar "env")) (EApp (EApp (EVar "inferShadowAppHead") (EVar "env")) (EVar "hd"))) (EBinOp "++" (EVar "pre") (EListLit (ETuple (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")) (EVar "tx"))))))))
(DTypeSig false "inferDefinerShadowApp" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Int"))) (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyFun (TyApp (TyCon "Ref") (TyCon "Inner")) (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Mono"))))))))))
(DFunDef false "inferDefinerShadowApp" ((PVar "env") (PVar "name") (PVar "arityRef") (PVar "tagRef") (PVar "implRef") (PVar "innerRef") (PVar "f") (PVar "x")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferDefinerShadowAppAt") (EVar "env")) (EVar "name")) (EVar "arityRef")) (EVar "tagRef")) (EVar "implRef")) (EVar "innerRef")) (EVar "f")) (EListLit)) (EVar "f")) (EVar "x")))
(DTypeSig false "inferDefinerShadowAppAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Int"))) (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyFun (TyApp (TyCon "Ref") (TyCon "Inner")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Mono"))))))))))))
(DFunDef false "inferDefinerShadowAppAt" ((PVar "env") (PVar "name") (PVar "arityRef") (PVar "tagRef") (PVar "implRef") (PVar "innerRef") (PVar "hd") (PVar "nodes") (PVar "f") (PVar "x")) (EBlock (DoLet false false (PVar "sym") (EApp (EApp (EVar "recoveredShadowSym") (EVar "name")) (EVar "tagRef"))) (DoLet false false (PVar "dloc") (EApp (EApp (EVar "appSpanLoc") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")))) (DoLet false false (PVar "pre") (EApp (EApp (EVar "inferSpineArgs") (EVar "env")) (EVar "nodes"))) (DoLet false false (PVar "k") (EApp (EVar "listLen") (EVar "pre"))) (DoLet false false (PVar "xt") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "x"))) (DoLet false false (PVar "isDictVar") (EApp (EApp (EApp (EVar "definerReceiverIsDictVar") (EFieldAccess (EVar "env") "teDyn")) (EVar "name")) (EVar "xt"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "groundShadowReceiver") (EFieldAccess (EVar "env") "teDyn")) (EApp (EApp (EApp (EApp (EVar "shadowDomainForAt") (EVar "env")) (EVar "name")) (EVar "sym")) (EVar "k"))) (EVar "xt")) (EVar "isDictVar")) (EVar "dloc"))) (DoLet false false (PVar "dispatches") (EApp (EApp (EApp (EVar "definerReceiverDispatches") (EFieldAccess (EVar "env") "teDyn")) (EVar "name")) (EVar "xt"))) (DoExpr (EIf (EBinOp "||" (EVar "dispatches") (EVar "isDictVar")) (EMatch (EApp (EVar "spineHeadEv") (EVar "hd")) (arm (PCon "Some" (PVar "ev")) () (EBlock (DoLet false false (PVar "cell") (EApp (EApp (EVar "methodCellOf") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "ev"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "cell") "ecIface")) (EApp (EApp (EVar "admittedIfaceWord") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")))))) (arm (PCon "None") () (ELit LUnit))) (ELit LUnit))) (DoLet false false (PVar "headEnv") (ERecordUpdate (EVar "env") ((fa "teDyn" (ERecordUpdate (EFieldAccess (EVar "env") "teDyn") ((fa "dcSuppressRLocalRecord" (EVar "True")) (fa "dcSuppressArgStamp" (EVar "True")) (fa "dcShadowHeadCtx" (EVar "True")))))))) (DoLet false false (PVar "selected") (EIf (EVar "dispatches") (EVar "None") (EApp (EApp (EApp (EApp (EVar "standaloneOccurrence") (EVar "headEnv")) (EVar "name")) (EVar "sym")) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "appSpineHeadLoc") (EVar "f"))) (EVar "dloc"))))) (DoLet false false (PVar "ft") (EIf (EVar "dispatches") (EApp (EApp (EApp (EVar "shadowVarHeadMethodScheme") (EVar "headEnv")) (EVar "name")) (EVar "hd")) (EMatch (EVar "selected") (arm (PCon "Some" (PVar "occurrence")) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "recordStandaloneAt") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "hd")) (EVar "occurrence"))) (DoExpr (EFieldAccess (EFieldAccess (EVar "occurrence") "svoInstance") "mtiBody")))) (arm (PCon "None") () (EApp (EApp (EVar "infer") (EVar "headEnv")) (EVar "hd")))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "arityRef")) (EApp (EVar "Some") (EApp (EVar "funArity") (EVar "ft"))))) (DoLet false false (PVar "dicts") (EIf (EBinOp "||" (EVar "dispatches") (EVar "isDictVar")) (EVar "emptyShadowDicts") (EApp (EApp (EVar "optionOr") (EVar "emptyShadowDicts")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "occurrence")) (EFieldAccess (EVar "occurrence") "svoDicts"))) (EVar "selected"))))) (DoExpr (EIf (EVar "isDictVar") (ELit LUnit) (EApp (EApp (EApp (EApp (EVar "pushSiteGoal") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "GKRLocalSite")) (EVar "innerRef")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PendingEntry") (EVar "name")) (EVar "tagRef")) (EVar "xt")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentFn") "value")) (EApp (EApp (EApp (EApp (EApp (EVar "SKRLocal") (EApp (EVar "routeLocalSym") (EUnOp "!" (EVar "tagRef")))) (EApp (EVar "not") (EVar "dispatches"))) (EFieldAccess (EVar "dicts") "sdMonos")) (EFieldAccess (EVar "dicts") "sdIfaces")) (EFieldAccess (EVar "dicts") "sdArgVecs"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EApp (EApp (EVar "captureScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (EApp (EApp (EVar "freshEvId") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit)))))) (DoExpr (EMatch (EApp (EApp (EVar "argDispatchOf") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EApp (EVar "pushSiteGoal") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "GKArgStamp")) (EVar "innerRef")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PendingEntry") (EVar "name")) (EVar "tagRef")) (EVar "xt")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentFn") "value")) (EApp (EApp (EApp (EVar "SKArg") (EVar "implRef")) (EIf (EVar "dispatches") (EVar "ft") (EVar "xt"))) (EListLit))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EApp (EApp (EVar "captureScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (EApp (EApp (EVar "freshEvId") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EMatch (EIf (EBinOp "||" (EVar "dispatches") (EVar "isDictVar")) (EVar "None") (EApp (EApp (EApp (EVar "standaloneSchemeFor") (EVar "env")) (EVar "name")) (EVar "sym"))) (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EApp (EVar "unifySpineResult") (EApp (EApp (EVar "envAtIfSome") (EVar "dloc")) (EVar "env"))) (EVar "f")) (EVar "ft")) (EBinOp "++" (EVar "pre") (EListLit (ETuple (EVar "x") (EVar "xt")))))) (arm (PCon "None") () (EBlock (DoExpr (EIf (EBinOp "==" (EVar "sym") (ELit (LString ""))) (EApp (EApp (EApp (EApp (EApp (EVar "enforceStandaloneDomainAt") (EVar "env")) (EVar "name")) (EVar "xt")) (EVar "dloc")) (EVar "k")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "inferAppNodes") (EVar "env")) (EVar "ft")) (EBinOp "++" (EVar "pre") (EListLit (ETuple (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")) (EVar "xt"))))))))))))
(DTypeSig false "inferDefinerShadowVarApp" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Mono"))))))
(DFunDef false "inferDefinerShadowVarApp" ((PVar "env") (PVar "name") (PVar "f") (PVar "x")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferDefinerShadowVarAppAt") (EVar "env")) (EVar "name")) (EVar "f")) (EListLit)) (EVar "f")) (EVar "x")))
(DTypeSig false "inferDefinerShadowVarAppAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Mono"))))))))
(DFunDef false "inferDefinerShadowVarAppAt" ((PVar "env") (PVar "name") (PVar "hd") (PVar "nodes") (PVar "f") (PVar "x")) (EBlock (DoLet false false (PVar "dloc") (EApp (EApp (EVar "appSpanLoc") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")))) (DoLet false false (PVar "pre") (EApp (EApp (EVar "inferSpineArgs") (EVar "env")) (EVar "nodes"))) (DoLet false false (PVar "xt") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "x"))) (DoLet false false (PVar "isDictVar") (EApp (EApp (EApp (EVar "definerReceiverIsDictVar") (EFieldAccess (EVar "env") "teDyn")) (EVar "name")) (EVar "xt"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "groundShadowReceiver") (EFieldAccess (EVar "env") "teDyn")) (EApp (EApp (EApp (EVar "standaloneShadowDomainAt") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EApp (EVar "listLen") (EVar "pre")))) (EVar "xt")) (EVar "isDictVar")) (EVar "dloc"))) (DoExpr (EIf (EVar "isDictVar") (EApp (EApp (EApp (EVar "inferAppNodes") (EVar "env")) (EApp (EApp (EApp (EVar "shadowVarHeadMethodScheme") (EVar "env")) (EVar "name")) (EVar "hd"))) (EBinOp "++" (EVar "pre") (EListLit (ETuple (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")) (EVar "xt"))))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferDefinerStandaloneVarAppAt") (EVar "env")) (EVar "name")) (EVar "hd")) (EVar "pre")) (EVar "f")) (EVar "x")) (EVar "xt")) (EVar "dloc"))))))
(DTypeSig false "shadowVarHeadMethodScheme" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Mono")))))
(DFunDef false "shadowVarHeadMethodScheme" ((PVar "env") (PVar "name") (PVar "f")) (EMatch (EApp (EApp (EVar "methodEntryHere") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (arm (PCon "Some" (PTuple PWild PWild (PVar "ty") (PVar "scope"))) () (EApp (EApp (EApp (EVar "forceInstantiation") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EApp (EApp (EVar "instantiateMethodTracked") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EVar "fst") (EApp (EApp (EApp (EVar "sigToSchemeTvsIn") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "scope")) (EVar "ty")))))) (arm (PCon "None") () (EApp (EApp (EVar "infer") (EApp (EVar "shadowHeadEnv") (EVar "env"))) (EVar "f")))))
(DTypeSig false "inferDefinerStandaloneVarAppAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Expr") (TyCon "Mono"))) (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono"))))))))))
(DFunDef false "inferDefinerStandaloneVarAppAt" ((PVar "env") (PVar "name") (PVar "hd") (PVar "pre") (PVar "f") (PVar "x") (PVar "xt") (PVar "dloc")) (EMatch (EApp (EApp (EApp (EApp (EVar "standaloneOccurrence") (EVar "env")) (EVar "name")) (ELit (LString ""))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "appSpineHeadLoc") (EVar "f"))) (EVar "dloc"))) (arm (PCon "Some" (PVar "occurrence")) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "recordStandaloneAt") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "hd")) (EVar "occurrence"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "unifySpineResult") (EApp (EApp (EVar "envAtIfSome") (EVar "dloc")) (EVar "env"))) (EVar "f")) (EFieldAccess (EFieldAccess (EVar "occurrence") "svoInstance") "mtiBody")) (EBinOp "++" (EVar "pre") (EListLit (ETuple (EVar "x") (EVar "xt")))))))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "ft") (EApp (EApp (EVar "infer") (EApp (EVar "shadowHeadEnv") (EVar "env"))) (EVar "hd"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "enforceStandaloneDomainAt") (EVar "env")) (EVar "name")) (EVar "xt")) (EVar "dloc")) (EApp (EVar "listLen") (EVar "pre")))) (DoExpr (EApp (EApp (EApp (EVar "inferAppNodes") (EVar "env")) (EVar "ft")) (EBinOp "++" (EVar "pre") (EListLit (ETuple (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")) (EVar "xt"))))))))))
(DTypeSig false "lamUnderLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))
(DFunDef false "lamUnderLoc" ((PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EVar "Some") (ETuple (EVar "None") (EVar "pats") (EVar "body"))))
(DFunDef false "lamUnderLoc" ((PCon "ELoc" (PVar "l") (PCon "ELam" (PVar "pats") (PVar "body")))) (EApp (EVar "Some") (ETuple (EApp (EVar "Some") (EVar "l")) (EVar "pats") (EVar "body"))))
(DFunDef false "lamUnderLoc" (PWild) (EVar "None"))
(DTypeSig false "funDomain" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyCon "Mono"))))
(DFunDef false "funDomain" ((PVar "mctx") (PCon "TFun" (PVar "a") PWild PWild)) (EVar "a"))
(DFunDef false "funDomain" ((PVar "mctx") PWild) (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit)))
(DTypeSig false "inferLamChecked" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "Option") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyCon "Mono"))))))
(DFunDef false "inferLamChecked" ((PVar "env") (PVar "expected") (PVar "pats") (PVar "body")) (EApp (EVar "fst") (EApp (EApp (EApp (EApp (EApp (EVar "inferBindingChecked") (EVar "True")) (EVar "env")) (EVar "expected")) (EVar "pats")) (EVar "body"))))
(DTypeSig true "inferBindingChecked" (TyFun (TyCon "Bool") (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "Option") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyTuple (TyCon "Mono") (TyCon "EffRow"))))))))
(DFunDef false "inferBindingChecked" ((PVar "judge") (PVar "env") (PVar "expected") (PVar "pats") (PVar "body")) (EBlock (DoLet false false (PVar "lits") (EApp (EApp (EVar "takePatLits") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "pr") (EApp (EApp (EVar "inferPats") (EVar "env")) (EVar "pats"))) (DoLet false false (PVar "arity") (EApp (EVar "listLen") (EVar "pats"))) (DoExpr (EMatch (EVar "expected") (arm (PCon "Some" (PVar "want")) () (EApp (EApp (EApp (EVar "unifyParamsExpected") (EFieldAccess (EVar "env") "teDyn")) (EApp (EVar "fst") (EVar "pr"))) (EApp (EApp (EVar "expectedParamTypes") (EVar "want")) (EVar "arity")))) (arm (PCon "None") () (ELit LUnit)))) (DoLet false false (PVar "scope") (EApp (EApp (EVar "openExistentialScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EApp (EVar "takeOpenedExistentials") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "settlePatLits") (EFieldAccess (EVar "env") "teDyn")) (EVar "lits"))) (DoExpr (EIf (EVar "judge") (EApp (EApp (EApp (EVar "checkBinderPats") (EVar "env")) (EApp (EVar "fst") (EVar "pr"))) (EVar "pats")) (ELit LUnit))) (DoExpr (EMatch (EVar "expected") (arm (PCon "Some" (PVar "want")) () (EApp (EApp (EApp (EApp (EVar "recordClauseFileBound") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "body")) (EVar "arity")) (EVar "want"))) (arm (PCon "None") () (ELit LUnit)))) (DoLet false false (PTuple (PVar "bodyTy") (PVar "bodyEff")) (EApp (EApp (EApp (EVar "captureEffects") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "curEffect")) (EApp (EVar "joinCellOf") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph"))) (ELam (PWild) (EBlock (DoLet false false (PVar "bodyEnv") (EApp (EApp (EVar "extendLocalVars") (EVar "env")) (EApp (EVar "snd") (EVar "pr")))) (DoLet false false (PVar "actual") (EApp (EApp (EVar "infer") (EVar "bodyEnv")) (EVar "body"))) (DoExpr (EMatch (EVar "expected") (arm (PCon "Some" (PVar "want")) () (EMatch (EApp (EApp (EVar "resultAfterArrows") (EVar "arity")) (EVar "want")) (arm (PCon "Some" (PVar "result")) () (EApp (EApp (EApp (EApp (EVar "checkedInto") (EVar "bodyEnv")) (EVar "body")) (EVar "result")) (EVar "actual"))) (arm (PCon "None") () (EVar "actual")))) (arm (PCon "None") () (EVar "actual")))))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "closeExistentialScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "scope")) (EVar "bodyTy")) (EApp (EVar "exprLoc") (EVar "body")))) (DoLet false false (PVar "force") (EIf (EApp (EVar "isEmptyL") (EVar "pats")) (EVar "bodyEff") (EVar "pureRow"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "bodyArrows") (EApp (EVar "fst") (EVar "pr"))) (EVar "bodyEff")) (EVar "bodyTy")) (EVar "force")))))
(DTypeSig false "isDoLoweredAndThenCallee" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isDoLoweredAndThenCallee" ((PCon "EApp" (PVar "callee") PWild)) (EApp (EVar "isDoLoweredAndThenCalleeExpr") (EVar "callee")))
(DFunDef false "isDoLoweredAndThenCallee" (PWild) (EVar "False"))
(DTypeSig false "isDoLoweredAndThenCalleeExpr" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isDoLoweredAndThenCalleeExpr" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "isDoLoweredAndThenCalleeExpr") (EVar "e")))
(DFunDef false "isDoLoweredAndThenCalleeExpr" ((PCon "EDoOrigin" PWild (PCon "EVar" (PLit (LString "andThen"))))) (EVar "True"))
(DFunDef false "isDoLoweredAndThenCalleeExpr" ((PCon "EDoOrigin" PWild (PCon "EVar" (PLit (LString "deferThen"))))) (EVar "True"))
(DFunDef false "isDoLoweredAndThenCalleeExpr" ((PCon "EDoOrigin" PWild (PCon "EVarId" (PLit (LString "andThen")) PWild))) (EVar "True"))
(DFunDef false "isDoLoweredAndThenCalleeExpr" ((PCon "EDoOrigin" PWild (PCon "EVarId" (PLit (LString "deferThen")) PWild))) (EVar "True"))
(DFunDef false "isDoLoweredAndThenCalleeExpr" ((PCon "EDoOrigin" PWild (PCon "EMethodAt" (PLit (LString "andThen")) PWild PWild))) (EVar "True"))
(DFunDef false "isDoLoweredAndThenCalleeExpr" ((PCon "EDoOrigin" PWild (PCon "EMethodAt" (PLit (LString "deferThen")) PWild PWild))) (EVar "True"))
(DFunDef false "isDoLoweredAndThenCalleeExpr" ((PCon "EDoOrigin" PWild (PCon "EDictAt" (PLit (LString "andThen")) PWild))) (EVar "True"))
(DFunDef false "isDoLoweredAndThenCalleeExpr" ((PCon "EDoOrigin" PWild (PCon "EDictAt" (PLit (LString "deferThen")) PWild))) (EVar "True"))
(DFunDef false "isDoLoweredAndThenCalleeExpr" (PWild) (EVar "False"))
(DTypeSig false "tupleArgElems" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Expr")))))
(DFunDef false "tupleArgElems" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "tupleArgElems") (EVar "e")))
(DFunDef false "tupleArgElems" ((PCon "ETuple" (PVar "es"))) (EApp (EVar "Some") (EVar "es")))
(DFunDef false "tupleArgElems" (PWild) (EVar "None"))
(DTypeSig false "tupleCallSpanLoc" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "tupleCallSpanLoc" ((PVar "f") (PVar "x")) (EMatch (ETuple (EApp (EVar "exprLoc") (EVar "f")) (EApp (EVar "exprLoc") (EVar "x"))) (arm (PTuple (PCon "Some" (PCon "Loc" (PVar "file") (PVar "sl") (PVar "sc") PWild PWild)) (PCon "Some" (PCon "Loc" PWild PWild PWild (PVar "el") (PVar "ec")))) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "file")) (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec")))) (arm PWild () (EVar "None"))))
(DTypeSig false "buildTupleCallHint" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "Loc") (TyCon "String")))))))))
(DFunDef false "buildTupleCallHint" ((PVar "name") (PVar "es") (PVar "f") (PVar "x")) (EMatch (EApp (EVar "renderCallArgs") (EVar "es")) (arm (PCon "Some" (PVar "parts")) () (EBlock (DoLet false false (PVar "argsCsv") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "parts"))) (DoLet false false (PVar "argsSpaced") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EVar "parts"))) (DoLet false false (PVar "spread") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "argsSpaced"))) (ELit (LString "")))) (DoLet false false (PVar "help") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Medaka calls functions with spaces, not parentheses: `")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "("))) (EApp (EMethodRef "display") (EVar "argsCsv"))) (ELit (LString ")` passes the single tuple `("))) (EApp (EMethodRef "display") (EVar "argsCsv"))) (ELit (LString ")`; did you mean `"))) (EApp (EMethodRef "display") (EVar "spread"))) (ELit (LString "`?")))) (DoLet false false (PVar "fix") (EApp (EApp (EMethodRef "map") (ELam ((PVar "span")) (ETuple (EVar "span") (EVar "spread")))) (EApp (EApp (EVar "tupleCallSpanLoc") (EVar "f")) (EVar "x")))) (DoExpr (ETuple (EVar "help") (EVar "fix"))))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "n") (EApp (EVar "listLen") (EVar "es"))) (DoLet false false (PVar "help") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Medaka calls functions with spaces, not parentheses: `")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "(...)` passes one "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString "-tuple, not "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " arguments; separate them with spaces, as in `"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " x y`")))) (DoExpr (ETuple (EVar "help") (EVar "None")))))))
(DTypeSig false "tupleCallShapeHint" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "Loc") (TyCon "String")))))))))
(DFunDef false "tupleCallShapeHint" ((PVar "f") (PVar "x") (PVar "ft")) (EMatch (EApp (EVar "tupleArgElems") (EVar "x")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "es")) () (EBlock (DoLet false false (PVar "n") (EApp (EVar "listLen") (EVar "es"))) (DoExpr (EIf (EBinOp "<" (EVar "n") (ELit (LInt 2))) (EVar "None") (EIf (EBinOp "/=" (EApp (EVar "funArity") (EVar "ft")) (EVar "n")) (EVar "None") (EIf (EApp (EApp (EVar "domainIsTupleOfArity") (EVar "ft")) (EVar "n")) (EVar "None") (EApp (EApp (EMethodRef "map") (ELam ((PVar "name")) (EApp (EApp (EApp (EApp (EVar "buildTupleCallHint") (EVar "name")) (EVar "es")) (EVar "f")) (EVar "x")))) (EApp (EVar "appSpineName") (EVar "f")))))))))))
(DTypeSig false "inferApp" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Mono"))))))
(DFunDef false "inferApp" ((PVar "env") (PVar "appExpr") (PVar "ft") (PVar "xt")) (EBlock (DoLet false false (PVar "r") (EApp (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoExpr (EMatch (EApp (EVar "headTyconNameMono") (EVar "ft")) (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EApp (EVar "inferAppNotFunction") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "appExpr")) (EVar "ft")) (EVar "r"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "containerParamScalarArg") (EVar "ft")) (EVar "xt")) (arm (PCon "Some" (PVar "scalarTy")) () (EBlock (DoLet false false (PVar "isDoBind") (EApp (EVar "isDoLoweredAndThenCallee") (EVar "appExpr"))) (DoLet false false (PVar "msg") (EIf (EVar "isDoBind") (EApp (EVar "doBindArgMsg") (EVar "scalarTy")) (EApp (EApp (EVar "containerArgMsg") (EApp (EVar "appSpineName") (EVar "appExpr"))) (EVar "scalarTy")))) (DoLet false false (PVar "hint") (EIf (EVar "isDoBind") (EApp (EVar "doBindArgHint") (EVar "scalarTy")) (EApp (EVar "containerArgHint") (EVar "scalarTy")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushTypeErrorHelpFixAt") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit (LString "T-TYPE-MISMATCH"))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "appArgLoc") (EVar "appExpr"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc"))) (EVar "msg")) (EVar "hint")) (EVar "None"))) (DoExpr (EApp (EApp (EApp (EVar "poisonMismatchVars") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "ft")) (EVar "xt"))) (DoExpr (EApp (EApp (EApp (EVar "poisonMismatchVars") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "r")) (EVar "r"))) (DoExpr (EVar "r")))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "at") (EApp (EApp (EVar "envAtIfSome") (EApp (EVar "appArgLoc") (EVar "appExpr"))) (EVar "env"))) (DoLet false false (PVar "eff") (EApp (EApp (EApp (EApp (EApp (EVar "applicationRow") (EVar "at")) (EVar "appExpr")) (EVar "ft")) (EVar "xt")) (EVar "r"))) (DoExpr (EApp (EApp (EApp (EVar "performEffect") (EFieldAccess (EFieldAccess (EVar "at") "teDyn") "dcModule")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "at") "teDyn") "dcModule") "mcCells") "curEffect")) (EVar "eff"))) (DoExpr (EApp (EApp (EVar "notePerformSite") (EVar "env")) (EVar "eff"))) (DoExpr (EVar "r"))))))))))
(DTypeSig false "argumentInto" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "Option") (TyCon "Expr")) (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit"))))))
(DFunDef false "argumentInto" ((PVar "env") (PVar "arg") (PVar "dom") (PVar "xt")) (EApp (EApp (EApp (EApp (EApp (EVar "argumentIntoOrd") (EVar "False")) (EVar "env")) (EVar "arg")) (EVar "dom")) (EVar "xt")))
(DTypeSig false "argumentIntoOrd" (TyFun (TyCon "Bool") (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "Option") (TyCon "Expr")) (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Unit")))))))
(DFunDef false "argumentIntoOrd" ((PVar "valueFirst") (PVar "env") (PVar "arg") (PVar "dom") (PVar "xt")) (EBlock (DoExpr (EMatch (EVar "arg") (arm (PCon "Some" (PVar "e")) () (EApp (EApp (EApp (EVar "recordValueFileBound") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "e")) (EVar "dom"))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EMatch (EApp (EVar "normalize") (EVar "dom")) (arm (PCon "TQual" (PVar "d") (PVar "q")) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "unifyIntoOrd") (EFieldAccess (EVar "env") "teDyn")) (EVar "valueFirst")) (EVar "True")) (EVar "d")) (EVar "xt"))) (DoExpr (EApp (EApp (EApp (EVar "wantAuthority") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EApp (EApp (EApp (EVar "argumentAuthority") (EVar "env")) (EApp (EVar "authDomainTop") (EVar "q"))) (EVar "arg")) (EVar "xt"))) (EVar "q"))))) (arm PWild () (EApp (EApp (EApp (EApp (EApp (EVar "unifyIntoOrd") (EFieldAccess (EVar "env") "teDyn")) (EVar "valueFirst")) (EVar "True")) (EVar "dom")) (EVar "xt")))))))
(DTypeSig false "checkedInto" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Mono"))))))
(DFunDef false "checkedInto" ((PVar "env") (PVar "e") (PVar "expected") (PVar "actual")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "recordValueFileBound") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "e")) (EVar "expected"))) (DoExpr (EMatch (EApp (EVar "normalize") (EVar "expected")) (arm (PCon "TQual" PWild PWild) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "argumentInto") (EApp (EApp (EVar "envAtIfSome") (EApp (EVar "exprLoc") (EVar "e"))) (EVar "env"))) (EApp (EVar "Some") (EVar "e"))) (EVar "expected")) (EVar "actual"))) (DoExpr (EVar "expected")))) (arm PWild () (EVar "actual"))))))
(DTypeSig false "appArgExpr" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "appArgExpr" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "appArgExpr") (EVar "e")))
(DFunDef false "appArgExpr" ((PCon "EApp" PWild (PVar "x"))) (EApp (EVar "Some") (EVar "x")))
(DFunDef false "appArgExpr" (PWild) (EVar "None"))
(DTypeSig false "applicationRow" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "EffRow")))))))
(DFunDef false "applicationRow" ((PVar "env") (PVar "appExpr") (PVar "ft") (PVar "xt") (PVar "result")) (EMatch (EApp (EVar "normalize") (EVar "ft")) (arm (PCon "TFun" (PVar "dom") (PVar "row") (PVar "res")) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "argumentInto") (EVar "env")) (EApp (EVar "appArgExpr") (EVar "appExpr"))) (EVar "dom")) (EVar "xt"))) (DoExpr (EApp (EApp (EApp (EVar "bindFrom") (EFieldAccess (EVar "env") "teDyn")) (EVar "result")) (EVar "res"))) (DoExpr (EVar "row")))) (arm PWild () (EBlock (DoLet false false (PVar "unknown") (EApp (EApp (EVar "openRow") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EFieldAccess (EVar "env") "teDyn")) (EVar "ft")) (EApp (EApp (EApp (EVar "TFun") (EVar "xt")) (EVar "unknown")) (EVar "result")))) (DoExpr (EVar "unknown"))))))
(DTypeSig false "inferAppNotFunction" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Mono"))))))
(DFunDef false "inferAppNotFunction" ((PVar "mctx") (PVar "appExpr") (PVar "ft") (PVar "r")) (EBlock (DoLet false false (PVar "applied") (EApp (EVar "appSpineArgCount") (EVar "appExpr"))) (DoLet false false (PVar "takes") (EBinOp "-" (EVar "applied") (ELit (LInt 1)))) (DoLet false false (PVar "loc") (EApp (EApp (EVar "appSpanLoc") (EFieldAccess (EVar "mctx") "mcLoc")) (EVar "appExpr"))) (DoExpr (EMatch (EApp (EVar "appSpineName") (EVar "appExpr")) (arm (PCon "Some" (PVar "name")) () (EIf (EBinOp ">=" (EVar "takes") (ELit (LInt 1))) (EApp (EApp (EApp (EVar "pushTypeError") (EApp (EApp (EVar "mctxAt") (EVar "loc")) (EVar "mctx"))) (ELit (LString "T-NOT-A-FUNCTION"))) (EApp (EApp (EApp (EVar "overAppliedMsg") (EVar "name")) (EVar "takes")) (EVar "applied"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushTypeErrorHelpFixAt") (EVar "mctx")) (ELit (LString "T-NOT-A-FUNCTION"))) (EVar "loc")) (EApp (EApp (EVar "notAFunctionMsgFor") (EApp (EVar "Some") (EVar "name"))) (EApp (EVar "ppMono") (EApp (EVar "normalize") (EVar "ft"))))) (EApp (EVar "notAFunctionHint") (EApp (EVar "Some") (EVar "name")))) (EVar "None")))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushTypeErrorHelpFixAt") (EVar "mctx")) (ELit (LString "T-NOT-A-FUNCTION"))) (EVar "loc")) (EApp (EVar "notAFunctionMsg") (EApp (EVar "ppMono") (EApp (EVar "normalize") (EVar "ft"))))) (EApp (EVar "notAFunctionHint") (EVar "None"))) (EVar "None"))))) (DoExpr (EApp (EApp (EApp (EVar "poisonMismatchVars") (EVar "mctx")) (EVar "r")) (EVar "r"))) (DoExpr (EVar "r"))))
(DTypeSig false "inferLam" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyCon "Mono")))))
(DFunDef false "inferLam" ((PVar "env") (PVar "pats") (PVar "body")) (EApp (EApp (EApp (EApp (EVar "inferLamChecked") (EApp (EApp (EVar "envAtIfSome") (EApp (EVar "exprLoc") (EVar "body"))) (EVar "env"))) (EVar "None")) (EVar "pats")) (EVar "body")))
(DTypeSig false "inferLet" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Bool") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Mono")))))))
(DFunDef false "inferLet" ((PVar "env") (PVar "isFun") (PVar "pat") (PVar "e1") (PVar "e2")) (EIf (EVar "isFun") (EMatch (EVar "pat") (arm (PCon "PVar" (PVar "x") (PVar "xloc") (PVar "bid")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferRecLet") (EVar "env")) (EVar "x")) (EApp (EVar "Some") (EVar "xloc"))) (EVar "bid")) (EVar "e1")) (EVar "e2"))) (arm PWild () (EApp (EApp (EApp (EApp (EVar "inferLetSimple") (EVar "env")) (EVar "pat")) (EVar "e1")) (EVar "e2")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "inferLetSimple") (EVar "env")) (EVar "pat")) (EVar "e1")) (EVar "e2")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "inferRecLet" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "BinderId") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Mono"))))))))
(DFunDef false "inferRecLet" ((PVar "outer") (PVar "x") (PVar "xloc") (PVar "bid") (PVar "e1") (PVar "e2")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EVar "envAtIfSome") (EApp (EVar "exprSpanLoc") (EVar "e1"))) (EVar "outer"))) (DoExpr (EApp (EApp (EApp (EVar "checkRecBindNonFunction") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EVar "e1"))) (DoExpr (EApp (EApp (EVar "enterLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "oblN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls"))) (DoLet false false (PVar "callN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "obls"))) (DoLet false false (PVar "dictN0") (EApp (EApp (EVar "goalsMark") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (DoLet false false (PVar "lscope") (EApp (EApp (EVar "openLocalScopeIf") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x"))) (DoLet false false (PTuple (PVar "t1") (PVar "residuals")) (EApp (EApp (EApp (EVar "inferRecursiveValue") (EVar "env")) (EVar "x")) (EVar "e1"))) (DoExpr (EApp (EApp (EVar "closeLocalScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "lscope"))) (DoExpr (EApp (EApp (EVar "exitLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "addedObls") (EApp (EApp (EVar "wWindow") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls")) (EVar "oblN0"))) (DoExpr (EApp (EApp (EApp (EVar "improveLocalGoals") (EFieldAccess (EVar "env") "teDyn")) (EVar "addedObls")) (EVar "callN0"))) (DoLet false false PWild (EApp (EApp (EVar "finalizeNumBoundary") (EFieldAccess (EVar "env") "teDyn")) (ERecordCreate "NumBoundary" ((fa "nbDisposition" (EApp (EVar "NumBoundaryOwnedMember") (EBinOp "+" (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentLevel") "value") (ELit (LInt 1))))) (fa "nbMembers" (EListLit (EVar "t1"))) (fa "nbSurvivingIds" (EApp (EApp (EApp (EApp (EVar "memberTiedSurvivors") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "t1")) (EVar "addedObls")) (EVar "callN0"))) (fa "nbDefaultObls" (EVar "addedObls")) (fa "nbAmbiguityObls" (EVar "addedObls")) (fa "nbGuard" (EApp (EApp (EApp (EVar "localNumGuard") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "addedObls")) (EVar "callN0"))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordLocalBind") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EVar "xloc")) (EVar "bid")) (EVar "t1"))) (DoLet false false (PVar "sch") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "genBindingRestricted") (EFieldAccess (EVar "env") "teDyn")) (EVar "Tip")) (EApp (EApp (EVar "residualsOf") (ELit (LInt 0))) (EVar "residuals"))) (EVar "True")) (EVar "pureRow")) (EVar "t1"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerLocalScheme") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EVar "sch")) (EVar "oblN0")) (EVar "callN0")) (EVar "dictN0"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerLocalAbsIf") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EVar "lscope")) (EVar "sch")) (EVar "oblN0")) (EVar "callN0"))) (DoExpr (EApp (EApp (EVar "infer") (EApp (EApp (EVar "envAt") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "outer") "teDyn") "dcModule") "mcLoc")) (EApp (EApp (EApp (EVar "seedAlphaLets") (EApp (EApp (EApp (EVar "extendLocalVar") (EVar "env")) (EVar "x")) (EVar "sch"))) (EVar "x")) (EVar "e1")))) (EVar "e2")))))
(DTypeSig false "inferRecursiveValue" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "AuthResidual"))))))))
(DFunDef false "inferRecursiveValue" ((PVar "env") (PVar "name") (PVar "expr")) (EBlock (DoExpr (EApp (EApp (EVar "beginEffectSummaryScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "arity") (EApp (EVar "sourceBindingArity") (EVar "expr"))) (DoLet false false (PVar "owned") (EApp (EApp (EApp (EVar "newBindingSummary") (EVar "arity")) (EApp (EVar "freshVar") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule"))) (EApp (EVar "freshEffectSummary") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")))) (DoLet false false (PVar "envSelf") (EApp (EApp (EApp (EVar "extendLocalVar") (EVar "env")) (EVar "name")) (EApp (EVar "monoScheme") (EFieldAccess (EVar "owned") "bsRecursiveValue")))) (DoLet false false (PTuple (PVar "actual") (PVar "immediate")) (EApp (EApp (EApp (EVar "captureEffects") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "curEffect")) (EApp (EVar "joinCellOf") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph"))) (ELam (PWild) (EApp (EApp (EVar "infer") (EVar "envSelf")) (EVar "expr"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "unifySourceDomains") (EFieldAccess (EVar "env") "teDyn")) (EVar "arity")) (EFieldAccess (EVar "owned") "bsValue")) (EVar "actual"))) (DoExpr (EApp (EApp (EApp (EVar "publishProducedResults") (EFieldAccess (EVar "env") "teDyn")) (EVar "owned")) (EListLit (ETuple (EApp (EVar "exprLoc") (EVar "expr")) (EVar "actual"))))) (DoExpr (EApp (EApp (EApp (EVar "recordEffectBody") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EVar "owned") "bsBody")) (EIf (EBinOp "==" (EVar "arity") (ELit (LInt 0))) (EVar "immediate") (EApp (EApp (EVar "bodyRowAt") (EVar "arity")) (EVar "actual"))))) (DoExpr (EApp (EApp (EVar "checkRecursiveValue") (EFieldAccess (EVar "env") "teDyn")) (EVar "owned"))) (DoLet false false (PVar "residuals") (EApp (EApp (EVar "finishValueEffectsKeeping") (EFieldAccess (EVar "env") "teDyn")) (EListLit (ETuple (EVar "True") (EFieldAccess (EVar "owned") "bsValue"))))) (DoExpr (EApp (EApp (EApp (EVar "performEffect") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "curEffect")) (EVar "immediate"))) (DoExpr (ETuple (EFieldAccess (EVar "owned") "bsValue") (EVar "residuals")))))
(DTypeSig false "sourceBindingArity" (TyFun (TyCon "Expr") (TyCon "Int")))
(DFunDef false "sourceBindingArity" ((PCon "ELoc" PWild (PVar "expr"))) (EApp (EVar "sourceBindingArity") (EVar "expr")))
(DFunDef false "sourceBindingArity" ((PCon "EDoOrigin" PWild (PVar "expr"))) (EApp (EVar "sourceBindingArity") (EVar "expr")))
(DFunDef false "sourceBindingArity" ((PCon "EAnnot" (PVar "expr") PWild)) (EApp (EVar "sourceBindingArity") (EVar "expr")))
(DFunDef false "sourceBindingArity" ((PCon "EHeadAnnot" (PVar "expr") PWild)) (EApp (EVar "sourceBindingArity") (EVar "expr")))
(DFunDef false "sourceBindingArity" ((PCon "ELetGroup" PWild (PVar "expr"))) (EApp (EVar "sourceBindingArity") (EVar "expr")))
(DFunDef false "sourceBindingArity" ((PCon "ELam" (PVar "pats") PWild)) (EApp (EVar "listLen") (EVar "pats")))
(DFunDef false "sourceBindingArity" (PWild) (ELit (LInt 0)))
(DTypeSig false "registerLocalScheme" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Scheme") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Unit"))))))))
(DFunDef false "registerLocalScheme" ((PVar "mctx") (PVar "x") (PVar "sch") (PVar "oblN0") (PVar "callN0") (PVar "dictN0")) (EBlock (DoExpr (EApp (EApp (EVar "declareQuantified") (EVar "mctx")) (EVar "sch"))) (DoLet false false (PVar "addedObls") (EApp (EApp (EVar "wWindow") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "implObls")) (EVar "oblN0"))) (DoLet false false (PVar "callOblsDelta") (EApp (EApp (EVar "callOblsWindow") (EVar "mctx")) (EVar "callN0"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerSchemeObligations") (EVar "mctx")) (EVar "omEmpty")) (EListLit)) (EVar "callOblsDelta")) (EVar "addedObls")) (EListLit (ETuple (EVar "x") (EVar "sch")))))))
(DTypeSig false "declareQuantified" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Scheme") (TyCon "Unit"))))
(DFunDef false "declareQuantified" ((PVar "mctx") (PVar "sch")) (EApp (EApp (EVar "declareRigidVars") (EVar "mctx")) (EApp (EApp (EMethodRef "map") (EVar "intToString")) (EApp (EVar "schemeIds") (EVar "sch")))))
(DTypeSig false "inferLetSimple" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Mono"))))))
(DFunDef false "inferLetSimple" ((PVar "outer") (PVar "pat") (PVar "e1") (PVar "e2")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EVar "envAtIfSome") (EApp (EVar "exprSpanLoc") (EVar "e1"))) (EVar "outer"))) (DoExpr (EApp (EApp (EVar "enterLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "beginEffectSummaryScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "oblN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls"))) (DoLet false false (PVar "callN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "obls"))) (DoLet false false (PVar "dictN0") (EApp (EApp (EVar "goalsMark") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (DoLet false false (PVar "lscope") (EMatch (EVar "pat") (arm (PCon "PVar" (PVar "x") PWild PWild) () (EApp (EApp (EVar "openLocalScopeIf") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x"))) (arm PWild () (EVar "None")))) (DoLet false false (PVar "t1") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e1"))) (DoExpr (EApp (EApp (EVar "closeLocalScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "lscope"))) (DoLet false false (PVar "residuals") (EApp (EApp (EVar "finishValueEffectsKeeping") (EFieldAccess (EVar "env") "teDyn")) (EListLit (ETuple (EBinOp "&&" (EApp (EVar "patIsVar") (EVar "pat")) (EApp (EApp (EVar "isNonexpansive") (EVar "env")) (EVar "e1"))) (EVar "t1"))))) (DoExpr (EApp (EApp (EVar "exitLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "addedObls") (EApp (EApp (EVar "wWindow") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls")) (EVar "oblN0"))) (DoExpr (EApp (EApp (EApp (EVar "improveLocalGoals") (EFieldAccess (EVar "env") "teDyn")) (EVar "addedObls")) (EVar "callN0"))) (DoLet false false PWild (EApp (EApp (EVar "finalizeNumBoundary") (EFieldAccess (EVar "env") "teDyn")) (ERecordCreate "NumBoundary" ((fa "nbDisposition" (EApp (EVar "NumBoundaryOwnedMember") (EBinOp "+" (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentLevel") "value") (ELit (LInt 1))))) (fa "nbMembers" (EListLit (EVar "t1"))) (fa "nbSurvivingIds" (EApp (EApp (EApp (EApp (EVar "memberTiedSurvivors") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "t1")) (EVar "addedObls")) (EVar "callN0"))) (fa "nbDefaultObls" (EVar "addedObls")) (fa "nbAmbiguityObls" (EVar "addedObls")) (fa "nbGuard" (EApp (EApp (EApp (EVar "localNumGuard") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "addedObls")) (EVar "callN0"))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "inferLetBody") (EVar "env")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "outer") "teDyn") "dcModule") "mcLoc")) (EVar "pat")) (EVar "t1")) (EVar "residuals")) (EVar "e1")) (EVar "e2")) (EVar "oblN0")) (EVar "callN0")) (EVar "dictN0")) (EVar "lscope")))))
(DTypeSig false "patIsVar" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "patIsVar" ((PCon "PVar" PWild PWild PWild)) (EVar "True"))
(DFunDef false "patIsVar" (PWild) (EVar "False"))
(DTypeSig false "inferLetBody" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Pat") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "AuthResidual"))) (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "ScopeId")) (TyCon "Mono")))))))))))))
(DFunDef false "inferLetBody" ((PVar "env") (PVar "bodyLoc") (PCon "PVar" (PVar "x") (PVar "xloc") (PVar "bid")) (PVar "t1") (PVar "residuals") (PVar "e1") (PVar "e2") (PVar "oblN0") (PVar "callN0") (PVar "dictN0") (PVar "lscope")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "recordLocalBind") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EApp (EVar "Some") (EVar "xloc"))) (EVar "bid")) (EVar "t1"))) (DoLet false false (PVar "sch") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "genBindingRestricted") (EFieldAccess (EVar "env") "teDyn")) (EVar "Tip")) (EApp (EApp (EVar "residualsOf") (ELit (LInt 0))) (EVar "residuals"))) (EApp (EApp (EVar "isNonexpansive") (EVar "env")) (EVar "e1"))) (EVar "pureRow")) (EVar "t1"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerLocalScheme") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EVar "sch")) (EVar "oblN0")) (EVar "callN0")) (EVar "dictN0"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerLocalAbsIf") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "x")) (EVar "lscope")) (EVar "sch")) (EVar "oblN0")) (EVar "callN0"))) (DoExpr (EApp (EApp (EVar "infer") (EApp (EApp (EVar "envAt") (EVar "bodyLoc")) (EApp (EApp (EApp (EVar "seedAlphaLets") (EApp (EApp (EApp (EVar "extendLocalVar") (EVar "env")) (EVar "x")) (EVar "sch"))) (EVar "x")) (EVar "e1")))) (EVar "e2")))))
(DFunDef false "inferLetBody" ((PVar "env") (PVar "bodyLoc") (PVar "pat") (PVar "t1") PWild PWild (PVar "e2") PWild PWild PWild PWild) (EBlock (DoLet false false (PVar "lits") (EApp (EApp (EVar "takePatLits") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "pr") (EApp (EApp (EVar "inferPat") (EVar "env")) (EVar "pat"))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EFieldAccess (EVar "env") "teDyn")) (EApp (EVar "fst") (EVar "pr"))) (EVar "t1"))) (DoExpr (EApp (EApp (EVar "settlePatLits") (EFieldAccess (EVar "env") "teDyn")) (EVar "lits"))) (DoExpr (EApp (EApp (EApp (EVar "checkBinderPat") (EVar "env")) (EApp (EVar "fst") (EVar "pr"))) (EVar "pat"))) (DoExpr (EApp (EApp (EVar "infer") (EApp (EApp (EVar "envAt") (EVar "bodyLoc")) (EApp (EApp (EVar "extendLocalVars") (EVar "env")) (EApp (EVar "snd") (EVar "pr"))))) (EVar "e2")))))
(DTypeSig false "inferIf" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Mono"))))))
(DFunDef false "inferIf" ((PVar "env") (PVar "c") (PVar "t") (PVar "e")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EApp (EApp (EVar "dynAtIfSome") (EApp (EVar "exprSpanLoc") (EVar "c"))) (EFieldAccess (EVar "env") "teDyn"))) (EApp (EApp (EVar "infer") (EVar "env")) (EVar "c"))) (EApp (EVar "tconBuiltin") (ELit (LString "Bool"))))) (DoLet false false (PVar "tt") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "t"))) (DoLet false false (PVar "ee") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e"))) (DoLet false false (PVar "context") (EIf (EApp (EVar "isOmittedElse") (EVar "e")) (EVar "JoinElselessIf") (EVar "JoinIf"))) (DoExpr (EApp (EApp (EApp (EVar "joinValueTypes") (EFieldAccess (EVar "env") "teDyn")) (EVar "context")) (EListLit (ETuple (EApp (EVar "exprLoc") (EVar "t")) (EVar "tt")) (ETuple (EApp (EVar "exprLoc") (EVar "e")) (EVar "ee")))))))
(DTypeSig false "isOmittedElse" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isOmittedElse" ((PCon "ELit" (PCon "LUnit"))) (EVar "True"))
(DFunDef false "isOmittedElse" (PWild) (EVar "False"))
(DTypeSig false "publishProducedResults" (TyFun (TyCon "DynCtx") (TyFun (TyCon "BindingSummary") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono"))) (TyCon "Unit")))))
(DFunDef false "publishProducedResults" ((PVar "dyn") (PVar "owned") (PVar "values")) (EBlock (DoLet false false (PVar "results") (EApp (EApp (EMethodRef "map") (EApp (EVar "clauseResult") (EFieldAccess (EVar "owned") "bsArity"))) (EVar "values"))) (DoLet false false (PVar "produced") (EApp (EApp (EVar "optionOrFresh") (EFieldAccess (EVar "dyn") "dcModule")) (EApp (EApp (EVar "joinProducedEnvelope") (EApp (EApp (EApp (EVar "valueJoinOps") (EVar "dyn")) (EVar "JoinClause")) (ELam (PWild) (EApp (EVar "collectProducedSummary") (EFieldAccess (EVar "dyn") "dcModule"))))) (EVar "results")))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PTuple (PVar "loc") (PVar "lower"))) (EApp (EApp (EApp (EApp (EVar "recordFileValueFlow") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "loc")) (EVar "produced")) (EVar "lower")))) (EVar "results"))) (DoExpr (EMatch (EApp (EApp (EVar "resultAfterArrows") (EFieldAccess (EVar "owned") "bsArity")) (EFieldAccess (EVar "owned") "bsValue")) (arm (PCon "Some" (PVar "expected")) () (EApp (EApp (EApp (EVar "bindFrom") (EVar "dyn")) (EVar "expected")) (EVar "produced"))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "binding source arity differs from its allocated shape"))))))))
(DTypeSig false "clauseResult" (TyFun (TyCon "Int") (TyFun (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono")) (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono")))))
(DFunDef false "clauseResult" ((PVar "arity") (PTuple (PVar "loc") (PVar "value"))) (EMatch (EApp (EApp (EVar "resultAfterArrows") (EVar "arity")) (EVar "value")) (arm (PCon "Some" (PVar "result")) () (ETuple (EVar "loc") (EVar "result"))) (arm (PCon "None") () (ETuple (EVar "loc") (EVar "value")))))
(DTypeSig false "inferProduced" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono"))))))
(DFunDef false "inferProduced" ((PVar "env") (PList)) (EListLit))
(DFunDef false "inferProduced" ((PVar "env") (PCons (PVar "e") (PVar "es"))) (EBlock (DoLet false false (PVar "value") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e"))) (DoExpr (EBinOp "::" (ETuple (EApp (EVar "exprLoc") (EVar "e")) (EVar "value")) (EApp (EApp (EVar "inferProduced") (EVar "env")) (EVar "es"))))))
(DTypeSig false "inferEach" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "inferEach" ((PVar "env") (PList)) (EListLit))
(DFunDef false "inferEach" ((PVar "env") (PCons (PVar "e") (PVar "es"))) (EBlock (DoLet false false (PVar "t") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e"))) (DoExpr (EBinOp "::" (EVar "t") (EApp (EApp (EVar "inferEach") (EVar "env")) (EVar "es"))))))
(DTypeSig false "inferListLit" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Mono"))))
(DFunDef false "inferListLit" ((PVar "env") (PVar "es")) (EBlock (DoLet false false (PVar "elem") (EApp (EApp (EApp (EVar "joinValueTypes") (EFieldAccess (EVar "env") "teDyn")) (EVar "JoinList")) (EApp (EApp (EVar "inferProduced") (EVar "env")) (EVar "es")))) (DoExpr (EApp (EApp (EVar "TApp") (EApp (EVar "tconBuiltin") (ELit (LString "List")))) (EDictApp "elem")))))
(DTypeSig false "inferAnnot" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyFun (TyCon "Ty") (TyCon "Mono")))))
(DFunDef false "inferAnnot" ((PVar "env") (PVar "e") (PVar "ty")) (EBlock (DoLet false false (PVar "oblN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls"))) (DoLet false false (PVar "callN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "obls"))) (DoLet false false (PVar "t") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e"))) (DoLet false false (PVar "pair") (EApp (EApp (EVar "astTypeFreshTbl") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "ty"))) (DoLet false false (PVar "annot") (EApp (EVar "fst") (EVar "pair"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "argumentIntoOrd") (EVar "True")) (EVar "env")) (EApp (EVar "Some") (EVar "e"))) (EVar "annot")) (EVar "t"))) (DoExpr (EApp (EApp (EApp (EVar "checkAnnotTooGeneral") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "ty")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EVar "snd") (EVar "pair"))))) (DoLet false false (PVar "annotation") (EListLit (ETuple (ELit (LString "")) (EVar "ty") (EApp (EVar "snd") (EVar "pair"))))) (DoLet false false (PVar "declared") (EApp (EVar "sccProtectedSignatureIds") (EVar "annotation"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "omSize") (EVar "declared")) (ELit (LInt 0))) (ELit LUnit) (EApp (EApp (EApp (EApp (EApp (EVar "checkSigVarGoals") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "DeclaredByAnnotation")) (EVar "declared")) (EVar "annotation")) (EBinOp "++" (EApp (EApp (EVar "wWindow") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls")) (EVar "oblN0")) (EApp (EApp (EVar "callUOblsWindow") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "callN0")))))) (DoExpr (EVar "annot"))))
(DTypeSig false "inferHeadAnnot" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyFun (TyCon "Ty") (TyCon "Mono")))))
(DFunDef false "inferHeadAnnot" ((PVar "env") (PVar "e") (PVar "ty")) (EBlock (DoLet false false (PVar "t") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e"))) (DoLet false false (PVar "annot") (EApp (EApp (EVar "headAnnotTy") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "ty"))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EFieldAccess (EVar "env") "teDyn")) (EVar "t")) (EVar "annot"))) (DoExpr (EVar "t"))))
(DTypeSig false "inferMatch" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyCon "Mono")))))
(DFunDef false "inferMatch" ((PVar "env") (PVar "scrutTy") (PVar "arms")) (EBlock (DoLet false false (PVar "result") (EApp (EApp (EApp (EVar "joinValueTypes") (EFieldAccess (EVar "env") "teDyn")) (EVar "JoinMatch")) (EApp (EApp (EApp (EVar "inferArms") (EVar "env")) (EVar "scrutTy")) (EVar "arms")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "scheduleMatchChecks") (EVar "env")) (EVar "scrutTy")) (EVar "arms")) (EApp (EApp (EVar "matchWarningLoc") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EVar "arms")))) (DoExpr (EVar "result"))))
(DTypeSig false "scheduleMatchChecks" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit"))))))
(DFunDef false "scheduleMatchChecks" ((PVar "env") (PVar "scrutTy") (PVar "arms") (PVar "loc")) (EMatch (EApp (EVar "normalize") (EVar "scrutTy")) (arm (PCon "TVar" PWild) () (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "matchChecksDeferred")) (EBinOp "::" (ETuple (EVar "scrutTy") (EVar "arms") (EVar "loc")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "matchChecksDeferred") "value")))) (arm PWild () (EApp (EApp (EApp (EVar "checkMatchChecks") (EApp (EApp (EVar "mctxAt") (EVar "loc")) (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule"))) (EVar "scrutTy")) (EVar "arms")))))
(DTypeSig false "checkBinderPats" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Unit")))))
(DFunDef false "checkBinderPats" ((PVar "env") (PList (PVar "t")) (PList (PVar "p"))) (EApp (EApp (EApp (EVar "checkBinderPat") (EVar "env")) (EVar "t")) (EVar "p")))
(DFunDef false "checkBinderPats" ((PVar "env") (PVar "ts") (PVar "ps")) (EIf (EApp (EApp (EVar "allList") (EVar "patIsVar")) (EVar "ps")) (ELit LUnit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "checkBinderPat") (EVar "env")) (EApp (EVar "tupleMono") (EVar "ts"))) (EApp (EVar "PTuple") (EVar "ps"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "binderMarker" (TyCon "String"))
(DFunDef false "binderMarker" () (ELit (LString "<binder>")))
(DTypeSig false "isBinderArms" (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyCon "Bool")))
(DFunDef false "isBinderArms" ((PList (PCon "Arm" PWild (PList) (PCon "EVar" (PVar "n"))))) (EBinOp "==" (EVar "n") (EVar "binderMarker")))
(DFunDef false "isBinderArms" (PWild) (EVar "False"))
(DTypeSig false "checkBinderPat" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Mono") (TyFun (TyCon "Pat") (TyCon "Unit")))))
(DFunDef false "checkBinderPat" ((PVar "env") (PVar "ty") (PVar "pat")) (EIf (EApp (EVar "patIsVar") (EVar "pat")) (ELit LUnit) (EApp (EApp (EApp (EApp (EVar "scheduleMatchChecks") (EVar "env")) (EVar "ty")) (EListLit (EApp (EApp (EApp (EVar "Arm") (EVar "pat")) (EListLit)) (EApp (EVar "EVar") (EVar "binderMarker"))))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc"))))
(DTypeSig false "matchWarningLoc" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "matchWarningLoc" ((PCon "Some" (PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))) (PVar "arms")) (EMatch (EApp (EVar "last") (EVar "arms")) (arm (PCon "Some" (PCon "Arm" PWild PWild (PVar "body"))) () (EMatch (EApp (EVar "exprSpanLoc") (EVar "body")) (arm (PCon "Some" (PCon "Loc" PWild PWild PWild (PVar "bel") (PVar "bec"))) ((GBool (EBinOp "<" (EVar "bel") (EVar "el")))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "bel")) (EVar "bec")))) (arm PWild () (EMatch (EApp (EVar "exprLoc") (EVar "body")) (arm (PCon "Some" (PCon "Loc" PWild PWild PWild (PVar "bel") (PVar "bec"))) ((GBool (EBinOp "&&" (EBinOp "==" (EVar "bel") (EVar "el")) (EBinOp "<" (EVar "bec") (EVar "ec"))))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "bel")) (EVar "bec")))) (arm PWild () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec")))))))) (arm (PCon "None") () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec"))))))
(DFunDef false "matchWarningLoc" ((PCon "None") PWild) (EVar "None"))
(DTypeSig true "checkMatchChecks" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyCon "Unit")))))
(DFunDef false "checkMatchChecks" ((PVar "mctx") (PVar "scrutTy") (PVar "arms")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "checkMatchExhaustive") (EVar "mctx")) (EVar "scrutTy")) (EVar "arms"))) (DoExpr (EApp (EApp (EApp (EVar "checkMatchRedundant") (EVar "mctx")) (EVar "scrutTy")) (EVar "arms")))))
(DTypeSig true "checkDeferredMatches" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Arm")) (TyApp (TyCon "Option") (TyCon "Loc")))) (TyCon "Unit"))))
(DFunDef false "checkDeferredMatches" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "checkDeferredMatches" ((PVar "mctx") (PCons (PTuple (PVar "scrutTy") (PVar "arms") (PVar "loc")) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "checkMatchChecks") (EApp (EApp (EVar "mctxAt") (EVar "loc")) (EVar "mctx"))) (EVar "scrutTy")) (EVar "arms"))) (DoExpr (EApp (EApp (EVar "checkDeferredMatches") (EVar "mctx")) (EVar "rest")))))
(DTypeSig false "checkMatchExhaustive" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyCon "Unit")))))
(DFunDef false "checkMatchExhaustive" ((PVar "mctx") (PVar "scrutTy") (PVar "arms")) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EVar "nonGuardedRows") (EVar "mctx")) (EVar "arms"))) (DoExpr (EIf (EApp (EApp (EApp (EApp (EVar "useful") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchOracle") "value")) (EApp (EVar "matchCol0Type") (EVar "scrutTy"))) (EVar "rows")) (EListLit (EVar "PWild"))) (EBlock (DoLet false false (PVar "binder") (EApp (EVar "isBinderArms") (EVar "arms"))) (DoLet false false (PTuple (PVar "msg") (PVar "help")) (EApp (EApp (EApp (EApp (EVar "nonExhaustiveMsg") (EVar "mctx")) (EVar "scrutTy")) (EVar "rows")) (EVar "binder"))) (DoExpr (EIf (EBinOp "&&" (EVar "binder") (EApp (EApp (EVar "anyList") (EApp (EVar "warnedAt") (EFieldAccess (EVar "mctx") "mcLoc"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchWarnings") "value"))) (ELit LUnit) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchWarnings")) (EBinOp "::" (EApp (EVar "writtenDiag") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "W-NONEXHAUSTIVE"))) (ELit (LInt 2))) (EFieldAccess (EVar "mctx") "mcLoc")) (EVar "msg")) (EVar "help")) (EVar "None"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchWarnings") "value")))))) (ELit LUnit)))))
(DTypeSig false "warnedAt" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "TcDiag") (TyCon "Bool"))))
(DFunDef false "warnedAt" ((PVar "loc") (PCon "TcDiag" (PVar "code") PWild (PVar "at") PWild PWild PWild)) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "code") (ELit (LString "W-NONEXHAUSTIVE"))) (EBinOp "/=" (EApp (EVar "locKey") (EVar "loc")) (ELit (LString "")))) (EBinOp "==" (EApp (EVar "locKey") (EVar "at")) (EApp (EVar "locKey") (EVar "loc")))))
(DTypeSig false "checkMatchRedundant" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyCon "Unit")))))
(DFunDef false "checkMatchRedundant" ((PVar "mctx") (PVar "scrutTy") (PVar "arms")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkRedundantGo") (EVar "mctx")) (EApp (EVar "matchCol0Type") (EVar "scrutTy"))) (EListLit)) (EVar "omEmpty")) (EVar "False")) (EVar "arms")))
(DTypeSig false "checkRedundantGo" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "TabKey")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyCon "Unit"))))))))
(DFunDef false "checkRedundantGo" ((PVar "mctx") PWild PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "checkRedundantGo" ((PVar "mctx") (PVar "col0") (PVar "prec") (PVar "heads") (PVar "offCol") (PCons (PCon "Arm" (PVar "pat") (PVar "gs") (PVar "body")) (PVar "rest"))) (EBlock (DoLet false false (PVar "dp") (EApp (EApp (EVar "desugarPat") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchOracle") "value")) (EVar "pat"))) (DoExpr (EIf (EApp (EApp (EApp (EApp (EApp (EApp (EVar "armUnreachable") (EVar "mctx")) (EVar "col0")) (EVar "prec")) (EVar "heads")) (EVar "offCol")) (EVar "dp")) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchWarnings")) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "W-UNREACHABLE-ARM"))) (ELit (LInt 2))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "exprLoc") (EVar "body"))) (EFieldAccess (EVar "mctx") "mcLoc"))) (EVar "unreachableArmWarning")) (EVar "None")) (EVar "None")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchWarnings") "value"))) (ELit LUnit))) (DoLet false false (PVar "contributes") (EBinOp "&&" (EApp (EVar "armIsUnguarded") (EVar "gs")) (EApp (EVar "not") (EApp (EVar "patHasRange") (EVar "pat"))))) (DoLet false false (PVar "prec2") (EIf (EVar "contributes") (EBinOp "::" (EListLit (EVar "dp")) (EVar "prec")) (EVar "prec"))) (DoLet false false (PVar "heads2") (EIf (EVar "contributes") (EApp (EApp (EVar "noteHeadCtor") (EVar "dp")) (EVar "heads")) (EVar "heads"))) (DoLet false false (PVar "offCol2") (EBinOp "||" (EVar "offCol") (EBinOp "&&" (EVar "contributes") (EApp (EVar "not") (EApp (EVar "isConPat") (EVar "dp")))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkRedundantGo") (EVar "mctx")) (EVar "col0")) (EVar "prec2")) (EVar "heads2")) (EVar "offCol2")) (EVar "rest")))))
(DTypeSig false "armUnreachable" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "TabKey")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Bool") (TyFun (TyCon "Pat") (TyCon "Bool"))))))))
(DFunDef false "armUnreachable" ((PVar "mctx") (PVar "col0") (PVar "prec") (PVar "heads") (PVar "offCol") (PCon "PCon" (PVar "c") (PVar "args"))) (EIf (EBinOp "&&" (EApp (EVar "not") (EVar "offCol")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "c")) (EVar "heads")))) (EVar "False") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "patUnreachable") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchOracle") "value")) (EVar "col0")) (EVar "prec")) (EApp (EApp (EVar "PCon") (EVar "c")) (EVar "args"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "armUnreachable" ((PVar "mctx") (PVar "col0") (PVar "prec") PWild PWild (PVar "dp")) (EApp (EApp (EApp (EApp (EVar "patUnreachable") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchOracle") "value")) (EVar "col0")) (EVar "prec")) (EVar "dp")))
(DTypeSig false "noteHeadCtor" (TyFun (TyCon "Pat") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "noteHeadCtor" ((PCon "PCon" (PVar "c") PWild) (PVar "heads")) (EApp (EApp (EApp (EVar "omInsert") (EVar "c")) (ELit LUnit)) (EVar "heads")))
(DFunDef false "noteHeadCtor" (PWild (PVar "heads")) (EVar "heads"))
(DTypeSig false "isConPat" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "isConPat" ((PCon "PCon" PWild PWild)) (EVar "True"))
(DFunDef false "isConPat" (PWild) (EVar "False"))
(DTypeSig false "armIsUnguarded" (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyCon "Bool")))
(DFunDef false "armIsUnguarded" ((PList)) (EVar "True"))
(DFunDef false "armIsUnguarded" ((PCons PWild PWild)) (EVar "False"))
(DTypeSig false "nonExhaustiveMsg" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyCon "Bool") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))))
(DFunDef false "nonExhaustiveMsg" ((PVar "mctx") (PVar "scrutTy") (PVar "rows") (PVar "binder")) (EMatch (EApp (EApp (EApp (EApp (EVar "usefulWitness") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchOracle") "value")) (EApp (EVar "matchCol0Type") (EVar "scrutTy"))) (EVar "rows")) (ELit (LInt 1))) (arm (PCon "Some" (PCons (PVar "w") PWild)) () (EBlock (DoLet false false (PVar "witnessStr") (EApp (EVar "renderWitness") (EVar "w"))) (DoExpr (EIf (EVar "binder") (EBlock (DoLet false false (PTuple (PVar "msg") (PVar "hint")) (EApp (EApp (EVar "binderNonExhaustiveMsg") (EApp (EVar "matchCol0Type") (EVar "scrutTy"))) (EVar "witnessStr"))) (DoExpr (ETuple (EVar "msg") (EApp (EVar "Some") (EVar "hint"))))) (EBlock (DoLet false false (PVar "hint") (EIf (EBinOp "==" (EVar "witnessStr") (ELit (LString "_"))) (ELit (LString "add a `_ => ...` arm")) (EBinOp "++" (EBinOp "++" (ELit (LString "add a `")) (EApp (EMethodRef "display") (EVar "witnessStr"))) (ELit (LString " => ...` arm or a `_` wildcard"))))) (DoLet false false (PVar "msg") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Warning: non-exhaustive match")) (EApp (EMethodRef "display") (EApp (EVar "tyOfMsg") (EApp (EVar "matchCol0Type") (EVar "scrutTy"))))) (ELit (LString ": missing `"))) (EApp (EMethodRef "display") (EVar "witnessStr"))) (ELit (LString "`; "))) (EApp (EMethodRef "display") (EVar "hint"))) (ELit (LString "")))) (DoExpr (ETuple (EVar "msg") (EApp (EVar "Some") (EVar "hint"))))))))) (arm PWild () (ETuple (EVar "nonExhaustiveMatchWarning") (EVar "None")))))
(DTypeSig false "nonGuardedRows" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))))))
(DFunDef false "nonGuardedRows" ((PVar "mctx") (PList)) (EListLit))
(DFunDef false "nonGuardedRows" ((PVar "mctx") (PCons (PCon "Arm" (PVar "pat") (PList) PWild) (PVar "rest"))) (EBinOp "::" (EListLit (EApp (EApp (EVar "desugarPat") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchOracle") "value")) (EVar "pat"))) (EApp (EApp (EVar "nonGuardedRows") (EVar "mctx")) (EVar "rest"))))
(DFunDef false "nonGuardedRows" ((PVar "mctx") (PCons (PCon "Arm" PWild PWild PWild) (PVar "rest"))) (EApp (EApp (EVar "nonGuardedRows") (EVar "mctx")) (EVar "rest")))
(DTypeSig false "inferArms" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono")))))))
(DFunDef false "inferArms" ((PVar "env") PWild (PList)) (EListLit))
(DFunDef false "inferArms" ((PVar "env") (PVar "scrutTy") (PCons (PCon "Arm" (PVar "pat") (PVar "gs") (PVar "body")) (PVar "rest"))) (EBlock (DoLet false false (PVar "value") (EApp (EApp (EApp (EApp (EApp (EVar "inferArm") (EVar "env")) (EVar "scrutTy")) (EVar "pat")) (EVar "gs")) (EVar "body"))) (DoExpr (EBinOp "::" (ETuple (EApp (EVar "exprLoc") (EVar "body")) (EVar "value")) (EApp (EApp (EApp (EVar "inferArms") (EVar "env")) (EVar "scrutTy")) (EVar "rest"))))))
(DTypeSig false "inferArm" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Mono") (TyFun (TyCon "Pat") (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyFun (TyCon "Expr") (TyCon "Mono")))))))
(DFunDef false "inferArm" ((PVar "env") (PVar "scrutTy") (PVar "pat") (PVar "gs") (PVar "body")) (EIf (EBinOp "&&" (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph") "graphRun") "anyExistentialsRef") "value") (EApp (EApp (EVar "patOpensExistentials") (EVar "env")) (EVar "pat"))) (EApp (EApp (EApp (EApp (EApp (EVar "inferArmOpening") (EVar "env")) (EVar "scrutTy")) (EVar "pat")) (EVar "gs")) (EVar "body")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "lits") (EApp (EApp (EVar "takePatLits") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "pr") (EApp (EApp (EVar "inferPat") (EVar "env")) (EVar "pat"))) (DoExpr (EApp (EApp (EApp (EVar "bindFrom") (EFieldAccess (EVar "env") "teDyn")) (EApp (EVar "fst") (EVar "pr"))) (EVar "scrutTy"))) (DoExpr (EApp (EApp (EVar "settlePatLits") (EFieldAccess (EVar "env") "teDyn")) (EVar "lits"))) (DoLet false false (PVar "envBody") (EApp (EApp (EVar "inferArmGuards") (EApp (EApp (EVar "extendLocalVars") (EVar "env")) (EApp (EVar "snd") (EVar "pr")))) (EVar "gs"))) (DoExpr (EApp (EApp (EVar "infer") (EVar "envBody")) (EVar "body")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "inferArmOpening" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Mono") (TyFun (TyCon "Pat") (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyFun (TyCon "Expr") (TyCon "Mono")))))))
(DFunDef false "inferArmOpening" ((PVar "env") (PVar "scrutTy") (PVar "pat") (PVar "gs") (PVar "body")) (EBlock (DoLet false false (PVar "lits") (EApp (EApp (EVar "takePatLits") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "pr") (EApp (EApp (EVar "inferPat") (EVar "env")) (EVar "pat"))) (DoExpr (EApp (EApp (EApp (EVar "bindFrom") (EFieldAccess (EVar "env") "teDyn")) (EApp (EVar "fst") (EVar "pr"))) (EVar "scrutTy"))) (DoLet false false (PVar "scope") (EApp (EApp (EVar "openExistentialScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EApp (EVar "takeOpenedExistentials") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "settlePatLits") (EFieldAccess (EVar "env") "teDyn")) (EVar "lits"))) (DoLet false false (PVar "envBody") (EApp (EApp (EVar "inferArmGuards") (EApp (EApp (EVar "extendLocalVars") (EVar "env")) (EApp (EVar "snd") (EVar "pr")))) (EVar "gs"))) (DoLet false false (PVar "t") (EApp (EApp (EVar "infer") (EVar "envBody")) (EVar "body"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "closeExistentialScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "scope")) (EVar "t")) (EApp (EVar "exprLoc") (EVar "body")))) (DoExpr (EVar "t"))))
(DTypeSig false "inferArmGuards" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyCon "TcEnv"))))
(DFunDef false "inferArmGuards" ((PVar "env") (PList)) (EVar "env"))
(DFunDef false "inferArmGuards" ((PVar "env") (PCons (PCon "GBool" (PVar "g")) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EApp (EApp (EVar "dynAtIfSome") (EApp (EVar "exprSpanLoc") (EVar "g"))) (EFieldAccess (EVar "env") "teDyn"))) (EApp (EApp (EVar "infer") (EVar "env")) (EVar "g"))) (EApp (EVar "tconBuiltin") (ELit (LString "Bool"))))) (DoExpr (EApp (EApp (EVar "inferArmGuards") (EVar "env")) (EVar "rest")))))
(DFunDef false "inferArmGuards" ((PVar "env") (PCons (PCon "GBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "te") (EApp (EApp (EVar "infer") (EVar "env")) (EVar "e"))) (DoLet false false (PVar "at") (EApp (EApp (EVar "envAtIfSome") (EApp (EVar "exprSpanLoc") (EVar "e"))) (EVar "env"))) (DoLet false false (PVar "lits") (EApp (EApp (EVar "takePatLits") (EFieldAccess (EFieldAccess (EVar "at") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "pr") (EApp (EApp (EVar "inferPat") (EVar "at")) (EVar "p"))) (DoExpr (EApp (EApp (EApp (EVar "bindFrom") (EFieldAccess (EVar "at") "teDyn")) (EApp (EVar "fst") (EVar "pr"))) (EVar "te"))) (DoExpr (EApp (EApp (EVar "settlePatLits") (EFieldAccess (EVar "at") "teDyn")) (EVar "lits"))) (DoExpr (EApp (EApp (EVar "inferArmGuards") (EApp (EApp (EVar "extendLocalVars") (EVar "env")) (EApp (EVar "snd") (EVar "pr")))) (EVar "rest")))))
(DTypeSig false "inferLetGroup" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyCon "Expr") (TyCon "Mono")))))
(DFunDef false "inferLetGroup" ((PVar "env") (PVar "binds") (PVar "body")) (EBlock (DoExpr (EApp (EApp (EVar "checkLetGroupBindsLocated") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "binds"))) (DoLet false false (PVar "env2") (EApp (EApp (EApp (EMethodRef "fold") (EVar "processLetGroup")) (EVar "env")) (EApp (EVar "letGroupComponents") (EVar "binds")))) (DoExpr (EApp (EApp (EVar "infer") (EVar "env2")) (EVar "body")))))
(DTypeSig false "processLetGroup" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyCon "TcEnv"))))
(DFunDef false "processLetGroup" ((PVar "env") (PVar "binds")) (EBlock (DoExpr (EApp (EApp (EVar "enterLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "beginEffectSummaryScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "oblN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls"))) (DoLet false false (PVar "callN0") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "obls"))) (DoLet false false (PVar "dictN0") (EApp (EApp (EVar "goalsMark") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (ELit LUnit))) (DoLet false false (PVar "summaries") (EApp (EApp (EMethodRef "map") (EApp (EVar "localBindingSummary") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule"))) (EVar "binds"))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PVar "entry")) (EApp (EApp (EVar "recordLetBindType") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "entry")))) (EApp (EApp (EVar "zipL") (EVar "binds")) (EVar "summaries")))) (DoLet false false (PVar "placeholders") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (ETuple (EApp (EVar "fst") (EVar "p")) (EApp (EVar "monoScheme") (EFieldAccess (EApp (EVar "snd") (EVar "p")) "bsValue"))))) (EVar "summaries"))) (DoLet false false (PVar "recursive") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (ETuple (EApp (EVar "fst") (EVar "p")) (EApp (EVar "monoScheme") (EFieldAccess (EApp (EVar "snd") (EVar "p")) "bsRecursiveValue"))))) (EVar "summaries"))) (DoLet false false (PVar "env2") (EApp (EApp (EVar "extendLocalVars") (EVar "env")) (EVar "recursive"))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PVar "bind")) (EApp (EApp (EVar "forgetLocalAbs") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EApp (EVar "letBindName") (EVar "bind"))))) (EVar "binds"))) (DoLet false false (PVar "lscopes") (EApp (EApp (EVar "inferLetBinds") (EVar "env2")) (EApp (EApp (EVar "zipL") (EVar "binds")) (EVar "summaries")))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PVar "entry")) (EApp (EApp (EVar "checkRecursiveValue") (EFieldAccess (EVar "env") "teDyn")) (EApp (EVar "snd") (EVar "entry"))))) (EVar "summaries"))) (DoLet false false (PVar "residuals") (EApp (EApp (EVar "finishValueEffectsKeeping") (EFieldAccess (EVar "env") "teDyn")) (EApp (EApp (EMethodRef "map") (EApp (EVar "letBindGeneralizes") (EVar "env"))) (EApp (EApp (EVar "zipL") (EVar "binds")) (EVar "summaries"))))) (DoExpr (EApp (EApp (EVar "flushPendingEscapes") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcGroup"))) (DoExpr (EApp (EApp (EVar "exitLevel") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "addedObls") (EApp (EApp (EVar "wWindow") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "implObls")) (EVar "oblN0"))) (DoExpr (EApp (EApp (EApp (EVar "improveLocalGoals") (EFieldAccess (EVar "env") "teDyn")) (EVar "addedObls")) (EVar "callN0"))) (DoLet false false (PVar "memberMonos") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EVar "schemeMono") (EApp (EVar "snd") (EVar "p"))))) (EVar "placeholders"))) (DoLet false false PWild (EApp (EApp (EVar "finalizeNumBoundary") (EFieldAccess (EVar "env") "teDyn")) (ERecordCreate "NumBoundary" ((fa "nbDisposition" (EApp (EVar "NumBoundaryOwnedGroup") (EBinOp "+" (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "currentLevel") "value") (ELit (LInt 1))))) (fa "nbMembers" (EVar "memberMonos")) (fa "nbSurvivingIds" (EVar "omEmpty")) (fa "nbDefaultObls" (EVar "addedObls")) (fa "nbAmbiguityObls" (EVar "addedObls")) (fa "nbGuard" (EApp (EApp (EApp (EVar "localNumGuard") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "addedObls")) (EVar "callN0"))))))) (DoLet false false (PVar "genv") (EApp (EApp (EApp (EApp (EVar "generalizeGroup") (EVar "env")) (EVar "residuals")) (ELit (LInt 0))) (EApp (EApp (EVar "zipL") (EVar "binds")) (EVar "placeholders")))) (DoLet false false (PVar "callOblsDelta") (EApp (EApp (EVar "callOblsWindow") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "callN0"))) (DoLet false false (PVar "schemes") (EApp (EApp (EVar "groupSchemesOf") (EVar "genv")) (EVar "binds"))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PVar "p")) (EApp (EApp (EVar "declareQuantified") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EVar "snd") (EVar "p"))))) (EVar "schemes"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerSchemeObligations") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "omEmpty")) (EListLit)) (EVar "callOblsDelta")) (EVar "addedObls")) (EVar "schemes"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "registerLocalGroupAbs") (EVar "genv")) (EVar "oblN0")) (EVar "callN0")) (EApp (EApp (EVar "zipL") (EVar "binds")) (EVar "lscopes")))) (DoExpr (EVar "genv"))))
(DTypeSig false "groupSchemesOf" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))
(DFunDef false "groupSchemesOf" ((PVar "env") (PList)) (EListLit))
(DFunDef false "groupSchemesOf" ((PVar "genv") (PCons (PCon "LetBind" (PVar "name") PWild PWild PWild) (PVar "rest"))) (EMatch (EApp (EApp (EVar "lookupVar") (EVar "genv")) (EVar "name")) (arm (PCon "Some" (PVar "sch")) () (EBinOp "::" (ETuple (EVar "name") (EVar "sch")) (EApp (EApp (EVar "groupSchemesOf") (EVar "genv")) (EVar "rest")))) (arm (PCon "None") () (EApp (EApp (EVar "groupSchemesOf") (EVar "genv")) (EVar "rest")))))
(DTypeSig false "inferLetBinds" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "LetBind") (TyTuple (TyCon "String") (TyCon "BindingSummary")))) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "ScopeId"))))))
(DFunDef false "inferLetBinds" ((PVar "env") (PList)) (EListLit))
(DFunDef false "inferLetBinds" ((PVar "env") (PCons (PTuple (PAs "bind" (PCon "LetBind" (PVar "name") (PVar "clauses") PWild PWild)) (PTuple PWild (PVar "owned"))) (PVar "rest"))) (EBlock (DoLet false false (PVar "pairs") (EApp (EApp (EMethodRef "map") (EVar "funClausePair")) (EVar "clauses"))) (DoLet false false (PVar "lscope") (EIf (EApp (EVar "isLocalAbsName") (EVar "name")) (EApp (EVar "Some") (EApp (EApp (EVar "openLocalScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name"))) (EVar "None"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "inferMemberClauses") (EVar "env")) (EVar "None")) (EVar "owned")) (EVar "pairs"))) (DoExpr (EApp (EApp (EVar "closeLocalScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "lscope"))) (DoExpr (EMatch (EVar "pairs") (arm (PList (PTuple (PList) PWild)) () (EApp (EApp (EApp (EVar "performEffect") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "curEffect")) (EFieldAccess (EVar "owned") "bsForce"))) (arm PWild () (ELit LUnit)))) (DoExpr (EBinOp "::" (EVar "lscope") (EApp (EApp (EVar "inferLetBinds") (EVar "env")) (EVar "rest"))))))
(DTypeSig true "declareRigidVars" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "declareRigidVars" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "declareRigidVars" ((PVar "mctx") (PVar "keys")) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "declaredSigVarIds")) (EApp (EApp (EVar "omFromNames") (EVar "keys")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "declaredSigVarIds") "value"))))
(DTypeSig true "preunifySigsEx" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyApp (TyCon "List") (TyCon "ScopedMember")) (TyTuple (TyApp (TyCon "List") (TyCon "ConstraintReg")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))))))))
(DFunDef false "preunifySigsEx" ((PVar "mctx") PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "preunifySigsEx" ((PVar "mctx") (PVar "sigs") (PCons (PVar "member") (PVar "rest"))) (EBlock (DoLet false false (PVar "m") (EFieldAccess (EVar "member") "smName")) (DoLet false false (PVar "v") (EFieldAccess (EVar "member") "smMono")) (DoLet false false (PTuple (PVar "restRegs") (PVar "restTvs")) (EApp (EApp (EApp (EVar "preunifySigsEx") (EVar "mctx")) (EVar "sigs")) (EVar "rest"))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "m")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "sigTyMapRef") "value")) (arm (PCon "Some" (PVar "ty")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "member") "smSigned")) (EVar "True"))) (DoLet false false (PTuple (PVar "signedMono") (PVar "tvs") (PVar "forceBound")) (EApp (EApp (EVar "instantiateSigTracked") (EVar "mctx")) (EVar "ty"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "member") "smDeclaredRoots")) (EApp (EApp (EVar "effectRowRoots") (EApp (EApp (EVar "optionOr") (EVar "pureRow")) (EVar "forceBound"))) (EApp (EApp (EVar "effectRoots") (EVar "signedMono")) (EVar "Tip"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "member") "smDeclaredAuths")) (EApp (EApp (EVar "authRowRoots") (EApp (EApp (EVar "optionOr") (EVar "pureRow")) (EVar "forceBound"))) (EApp (EApp (EVar "authRoots") (EVar "signedMono")) (EVar "Tip"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "member") "smForceBound")) (EVar "forceBound"))) (DoLet false false (PTuple (PVar "declaredScheme") (PVar "declaredTvs")) (EApp (EApp (EVar "sigToSchemeTvs") (EVar "mctx")) (EVar "ty"))) (DoLet false false (PCon "Forall" (PVar "ids") (PVar "eids") (PVar "aids") PWild (PVar "declaredForce") (PVar "declaredValue")) (EVar "declaredScheme")) (DoLet false false (PVar "slots") (EApp (EApp (EVar "declaredPredicateSlots") (EApp (EApp (EVar "constraintVarIfaceMonos") (EApp (EVar "sigConstraints") (EVar "ty"))) (EVar "declaredTvs"))) (EApp (EApp (EApp (EApp (EVar "constraintVarArgMonos") (EVar "mctx")) (EApp (EVar "sigConstraints") (EVar "ty"))) (EApp (EVar "sigConstraintArgTys") (EVar "ty"))) (EVar "declaredTvs")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "member") "smRecursive")) (EApp (EVar "Some") (ERecordCreate "EnvBinding" ((fa "ebValue" (ERecordCreate "ValueScheme" ((fa "vsScheme" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Forall") (EVar "ids")) (EVar "eids")) (EVar "aids")) (EListLit)) (EMatch (EVar "forceBound") (arm (PCon "Some" PWild) () (EVar "declaredForce")) (arm (PCon "None") () (EApp (EApp (EVar "optionOr") (EVar "pureRow")) (EFieldAccess (EVar "member") "smForce"))))) (EVar "declaredValue"))) (fa "vsDeclared" (EApp (EVar "Some") (ERecordCreate "CDeclared" ((fa "cdSlots" (EApp (EVar "predicateSlotCSlots") (EVar "slots"))) (fa "cdPrefix" (EApp (EVar "CDPLen") (EApp (EVar "listLen") (EApp (EVar "dedupSlotVecs") (EApp (EApp (EMethodRef "map") (EVar "predicateSlotView")) (EVar "slots")))))) (fa "cdArgs" (EApp (EVar "predicateSlotArgs") (EVar "slots")))))))))) (fa "ebMethodRow" (EVar "None")) (fa "ebStandalone" (EVar "None"))))))) (DoExpr (EApp (EApp (EApp (EVar "bindFrom") (EApp (EVar "dynFor") (EVar "mctx"))) (EVar "v")) (EVar "signedMono"))) (DoLet false false (PVar "regs") (EListLit (ERecordCreate "ConstraintReg" ((fa "crName" (EVar "m")) (fa "crScope" (EFieldAccess (EVar "member") "smScope")) (fa "crIfaceMonos" (EApp (EApp (EVar "constraintVarIfaceMonos") (EApp (EVar "sigConstraints") (EVar "ty"))) (EVar "tvs"))) (fa "crArgVecs" (EApp (EApp (EApp (EApp (EVar "constraintVarArgMonos") (EVar "mctx")) (EApp (EVar "sigConstraints") (EVar "ty"))) (EApp (EVar "sigConstraintArgTys") (EVar "ty"))) (EVar "tvs"))))))) (DoExpr (ETuple (EBinOp "++" (EVar "regs") (EVar "restRegs")) (EBinOp "::" (ETuple (EVar "m") (EVar "ty") (EVar "tvs")) (EVar "restTvs")))))) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EApp (EVar "unify") (EVar "mctx")) (EVar "v")) (EFieldAccess (EFieldAccess (EVar "member") "smOwned") "bsValue"))) (DoExpr (ETuple (EVar "restRegs") (EVar "restTvs")))))))))
(DTypeSig true "valueSpanLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "valueSpanLoc" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "valueSpanLoc" ((PCon "ELet" PWild PWild PWild PWild (PVar "body"))) (EApp (EVar "valueSpanLoc") (EVar "body")))
(DFunDef false "valueSpanLoc" ((PCon "ELetGroup" PWild (PVar "body"))) (EApp (EVar "valueSpanLoc") (EVar "body")))
(DFunDef false "valueSpanLoc" ((PCon "EBlock" (PVar "stmts"))) (EMatch (EApp (EVar "last") (EVar "stmts")) (arm (PCon "Some" (PCon "DoExpr" (PVar "e"))) () (EApp (EVar "valueSpanLoc") (EVar "e"))) (arm PWild () (EApp (EVar "exprSpanLoc") (EApp (EVar "EBlock") (EVar "stmts"))))))
(DFunDef false "valueSpanLoc" ((PVar "e")) (EApp (EVar "exprSpanLoc") (EVar "e")))
(DTypeSig true "inferMemberClauses" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "Option") (TyCon "Mono")) (TyFun (TyCon "BindingSummary") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyApp (TyCon "List") (TyCon "Atom")))))))
(DFunDef false "inferMemberClauses" ((PVar "env") PWild PWild (PList)) (EListLit))
(DFunDef false "inferMemberClauses" ((PVar "env") (PVar "peel") (PVar "owned") (PVar "clauses")) (EBlock (DoLet false false (PTuple (PVar "values") (PVar "effects")) (EApp (EApp (EApp (EApp (EVar "inferClauseValues") (EVar "env")) (EVar "peel")) (EVar "owned")) (EVar "clauses"))) (DoExpr (EApp (EApp (EApp (EVar "publishProducedResults") (EFieldAccess (EVar "env") "teDyn")) (EVar "owned")) (EVar "values"))) (DoExpr (EApp (EVar "effrowLabels") (EApp (EApp (EVar "collectRows") (EApp (EVar "joinCellOf") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph"))) (EVar "effects"))))))
(DTypeSig false "inferClauseValues" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "Option") (TyCon "Mono")) (TyFun (TyCon "BindingSummary") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "EffRow"))))))))
(DFunDef false "inferClauseValues" ((PVar "env") PWild PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "inferClauseValues" ((PVar "env") (PVar "peel") (PVar "owned") (PCons (PVar "cl") (PVar "rest"))) (EBlock (DoLet false false (PVar "ce") (EApp (EApp (EApp (EVar "inferClauseEff") (EVar "env")) (EVar "peel")) (EVar "cl"))) (DoLet false false (PVar "value") (EApp (EVar "valueSpanLoc") (EApp (EVar "snd") (EVar "cl")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "unifySourceDomains") (EApp (EApp (EVar "dynAtIfSome") (EVar "value")) (EFieldAccess (EVar "env") "teDyn"))) (EApp (EVar "listLen") (EApp (EVar "fst") (EVar "cl")))) (EFieldAccess (EVar "owned") "bsValue")) (EApp (EVar "fst") (EVar "ce")))) (DoExpr (EApp (EApp (EApp (EVar "recordEffectBody") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EFieldAccess (EVar "owned") "bsBody")) (EApp (EVar "snd") (EVar "ce")))) (DoLet false false (PTuple (PVar "values") (PVar "effects")) (EApp (EApp (EApp (EApp (EVar "inferClauseValues") (EVar "env")) (EVar "peel")) (EVar "owned")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (ETuple (EVar "value") (EApp (EVar "fst") (EVar "ce"))) (EVar "values")) (EBinOp "::" (EApp (EVar "snd") (EVar "ce")) (EVar "effects"))))))
(DTypeSig false "inferClauseEff" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "Option") (TyCon "Mono")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyTuple (TyCon "Mono") (TyCon "EffRow"))))))
(DFunDef false "inferClauseEff" ((PVar "outer") (PVar "peel") (PTuple (PVar "pats") (PVar "body"))) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EVar "envAtIfSome") (EApp (EVar "exprSpanLoc") (EVar "body"))) (EVar "outer"))) (DoLet false false (PVar "lits") (EApp (EApp (EVar "takePatLits") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit))) (DoLet false false (PVar "pr") (EApp (EApp (EVar "inferPats") (EVar "env")) (EVar "pats"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "peelOntoParams") (EFieldAccess (EVar "env") "teDyn")) (EVar "peel")) (EApp (EVar "fst") (EVar "pr"))) (EVar "pats"))) (DoLet false false (PVar "scope") (EApp (EApp (EVar "openExistentialScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EApp (EVar "takeOpenedExistentials") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "settlePatLits") (EFieldAccess (EVar "env") "teDyn")) (EVar "lits"))) (DoExpr (EMatch (EVar "peel") (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EApp (EApp (EVar "recordClauseFileBound") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "body")) (EApp (EVar "listLen") (EVar "pats"))) (EVar "src"))) (arm (PCon "None") () (ELit LUnit)))) (DoLet false false (PTuple (PVar "bodyTy") (PVar "bodyEff")) (EApp (EApp (EApp (EVar "captureEffects") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "curEffect")) (EApp (EVar "joinCellOf") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph"))) (ELam (PWild) (EMatch (EVar "peel") (arm (PCon "Some" (PVar "src")) () (EMatch (EApp (EApp (EVar "resultAfterArrows") (EApp (EVar "listLen") (EVar "pats"))) (EVar "src")) (arm (PCon "Some" (PVar "expected")) () (EBlock (DoLet false false (PVar "bodyEnv") (EApp (EApp (EVar "extendLocalVars") (EVar "env")) (EApp (EVar "snd") (EVar "pr")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkedInto") (EVar "bodyEnv")) (EVar "body")) (EVar "expected")) (EApp (EApp (EApp (EVar "inferExpected") (EVar "bodyEnv")) (EVar "body")) (EVar "expected")))))) (arm (PCon "None") () (EApp (EApp (EVar "infer") (EApp (EApp (EVar "extendLocalVars") (EVar "env")) (EApp (EVar "snd") (EVar "pr")))) (EVar "body"))))) (arm (PCon "None") () (EApp (EApp (EVar "infer") (EApp (EApp (EVar "extendLocalVars") (EVar "env")) (EApp (EVar "snd") (EVar "pr")))) (EVar "body"))))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "closeExistentialScope") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "scope")) (EVar "bodyTy")) (EApp (EVar "exprLoc") (EVar "body")))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "bodyArrows") (EApp (EVar "fst") (EVar "pr"))) (EVar "bodyEff")) (EVar "bodyTy")) (EVar "bodyEff")))))
(DTypeSig false "peelOntoParams" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "Option") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Unit"))))))
(DFunDef false "peelOntoParams" ((PVar "dyn") (PCon "None") PWild PWild) (ELit LUnit))
(DFunDef false "peelOntoParams" ((PVar "dyn") (PCon "Some" PWild) PWild (PList)) (ELit LUnit))
(DFunDef false "peelOntoParams" ((PVar "dyn") (PCon "Some" (PVar "src")) (PVar "patTypes") (PVar "pats")) (EApp (EApp (EApp (EVar "zipBindFrom") (EVar "dyn")) (EVar "patTypes")) (EApp (EApp (EVar "peelArrows") (EApp (EVar "listLen") (EVar "pats"))) (EVar "src"))))
(DTypeSig false "localRole" (TyFun (TyCon "Bool") (TyCon "BindingRole")))
(DFunDef false "localRole" ((PCon "True")) (EVar "RoleQuantifies"))
(DFunDef false "localRole" ((PCon "False")) (EVar "RoleMonomorphic"))
(DTypeSig true "matchWarningsNow" (TyFun (TyCon "ModuleCtx") (TyCon "Bool")))
(DFunDef false "matchWarningsNow" ((PVar "mctx")) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchWarnings") "value") (arm (PList) () (EVar "False")) (arm PWild () (EVar "True"))))
