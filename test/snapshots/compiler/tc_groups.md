# META
source_lines=2227
stages=DESUGAR,MARK
# SOURCE
-- tc_groups: binding-group analysis and the generalization policy at a binding boundary: the
-- free-variable walk that forms groups, the value restriction and the recursive-value restriction
-- (`checkRecursiveValue`, `checkRecBindNonFunction`, the `eagerRefs` walk), group generalization,
-- goals required below (`requireGoalsBelow`) and the prerequisite walk over them
-- (`nestedRequireGoals`), signature constraints.  The mark pass over groups and the write-back of
-- its clauses are `tc_occurrence`.
--
-- Spec: HM-CORE section 1 (gen-value), section 4, section 5 (owed, #2555); DICT section 4.1 G2,
-- section 6.3 at binders.
--
-- Placement: declarations are placed by R1-R6 of the Phase 4 module table,
-- compiler/ARCHITECTURE-PLAYBOOK.md section 6.
-- Closure rule: this module may not import `types.typecheck`, nor any of `tc_pat`,
-- `tc_infer_records`, `tc_infer`, `tc_elab`, `tc_global`, `tc_module`.

import list.{reverse}
import types.tc_types.{
  OblProjection(..),
  GoalReach(..),
  BindingRole(..),
  Predicate(..),
  UObligation(..),
  ConstraintReg,
  DynCtx,
  GraphCtx,
  ImplRow,
  ModuleCtx,
  ReqWalk,
  ScopedMember,
  siteFor,
  TcEnv,
  ReqStep(..),
}
import types.tc_mono.{
  abstractSlotIds,
  anyMember,
  authIdsIn,
  boundTyvarIds,
  cohApply,
  containsI,
  declaredOblArgId,
  declaredOblArgOk,
  hasDupI,
  headsUnifier,
  isBareTyvarMono,
  monoUnboundIds,
  monoVarCells,
  monoVectorClosed,
  oblArgKey,
  patVarsListTc,
  patVarsTc,
  qualifierAuthIds,
  schemeIds,
  schemeMono,
  sigCellsOf,
  sigTvarIds,
  tyvarId,
  tyVarNames,
  unrigidSig,
}
import types.tc_diag_text.{
  annotTooGeneralMsg,
  groundedSigVarMsg,
  letRecNonFunctionMsg,
  missingConstraintMsg,
  missingConstraintVecMsg,
  sigOverExpansiveMsg,
  sigTooGeneralMsg,
  siblingSharedSigVarMsg,
  varNameForId,
}
import types.tc_state.{mctxAtIfSome}
import types.tc_env.{
  extendLocalVar,
  funClausePair,
  lookupCtor,
  namesToSet,
  oblIfaceKey,
  sameIfaceDecl,
  seedAlphaLets,
  superLookup,
}
import types.tc_diag.{
  boundaryOwnsOpen, pushTypeError, pushTypeErrorAt, pushTypeErrorOnceAt
}
import types.tc_unify.{
  generalizeBindingDeclared,
  lowerAuthLevels,
  lowerRowLevels,
  lowerToCurrent,
  unifyInto,
  wantAuthorityWith,
}
import types.tc_decls_types.{fromAstType, sigConstraintsOf}
import types.tc_decls.{constraintNameMonos}
import types.tc_solve_givens.{goalGivenAt}
import types.tc_solve_entail.{
  freshRowHeadsTvs,
  goalCandidates,
  goalIsProjection,
  goalReach,
  goalRows,
  selectedRowReqMatch,
  reqWalkEnter,
  reqWalkMemo,
  reqWalkSeed,
}
import types.tc_solve.{
  goalVarsAllHeld,
  reqToObligation,
  uOblArgs,
  noteWalkGoalFollowed,
  solvedCleanly,
  walkGoalFollowed,
}
import types.tc_solve_check.{
  callPredOf,
  ifaceForInferredId,
  inferredConstraintIds,
  oblPredOf,
  residualBoundPreds,
  undeterminedGoalExempt,
  prerequisiteOnWalk,
}
import types.tc_effects.{clausesAt, clausesOf}
import types.tc_occurrence.{ctorHeadShaped}
import frontend.ast.{
  Arm(..),
  Constraint(..),
  Decl(..),
  DoStmt(..),
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
  Require(..),
  Section(..),
  Super(..),
  Ty(..),
  firstTyLoc,
  letBindName,
}
import types.repr.{
  AuthResidual(..),
  IfaceRef(..),
  Mono(..),
  Scheme(..),
  VecObl(..),
  normalize,
}
import types.effect_bindings.{BindingSummary(..)}
import types.effect_rows.{EffRow(..), pureRow}
import map.{Map(..)}
import support.ordmap.{
  omEmpty, omFromNames, omHasKey, omInsert, omLookup, omSize, OrdMap
}
import types.effect_solver.{ScopeRoles(..)}
import types.superclass.{SuperNode(..), lookupPos, mapAll, superClosure}
import support.util.{
  allList,
  anyList,
  contains,
  dedup,
  dedupBy,
  filterList,
  isEmptyL,
  isSome,
  joinWith,
  lenKey,
  listLen,
  lookupAssoc,
}
import frontend.desugar.{exprSpanLoc}
import types.registry.{regKeyOfTab, regKeyRender}
import support.scc.{tarjanSCCs}
import map as IdMap

idSetInsertAll : List Int -> Map Int Unit -> Map Int Unit
idSetInsertAll [] m = m
idSetInsertAll (i :: rest) m = idSetInsertAll rest (IdMap.set i () m)

-- ── value restriction (T1) ────────────────────────────────────────────────
-- A binding RHS is *non-expansive* (a syntactic value) iff it cannot allocate a
-- mutable cell: literals, variables and lambdas are values; annotations are
-- transparent; tuples/lists are values iff their elements are.  Constructor
-- applications of non-expansive arguments are non-expansive (SML value
-- restriction relaxation, Phase 66 extension) EXCEPT `Ref`, excluded by name in
-- `isCtorAppSpine` below: generalizing `Ref x` would be unsound (polymorphic
-- reference: write at one type, read at another).
--
-- The head test is an actual constructor lookup, not a spelling test —
-- issue 1150 (S0, memory-safety), fixed 2026-08-26.  `isCtorAppSpine`'s head
-- arms ask `lookupCtor env name`, so the predicate now answers "is this name a
-- REAL, DECLARED constructor?" instead of "does this name start with a capital
-- letter?".  Threading the `TcEnv` this needs is why `isNonexpansive`,
-- `isCtorAppSpine`, `clausesAreValue`/`clauseIsValue`,
-- `memberClauseIsValue` and `sccSchemes` all take an env parameter.
--
-- What the old first-character heuristic (`ctorHeadShaped`, retained below
-- only as a cheap pre-filter) got wrong: a MODULE ALIAS is REQUIRED to be
-- uppercase (`aliasNameFor`, frontend/parser.mdk — lowercase is a hard parse
-- error) and an alias-qualified value desugars to a FLAT `EVar` carrying the
-- dotted name (`rewriteAliasQual`, frontend/desugar.mdk, via `qualifiedLocal`
-- in frontend/ast.mdk: `"\{alias}.\{n}"`).  So `ctorHeadIsUpper "H.new"` (its first form) read
-- `'H'` and said True: EVERY alias-qualified call in the language was
-- CLASSIFIED as a constructor application.  Classification is not the whole
-- test — `isCtorAppSpine (EApp f x) = isCtorAppSpine f && isNonexpansive x`
-- still rejects the spine if any argument is expansive, so `H.f (g 1)` was
-- classified but NOT generalized.  It was enough for the repro, whose argument
-- is a value: `let m = H.new ()` over `stdlib/hash_map.mdk` yielded a
-- polymorphic mutable table — `check` exit 0, `run` E-NOT-A-FUNCTION, built
-- binary SEGFAULT.  Under the lookup, `"H.new"` is absent from the ctor map and
-- the binding is value-restricted: `check` REJECTS the program.
--
-- Why the lookup is sound (i.e. why "present in the ctor map" implies "really a
-- constructor").  `lookupCtor` reads `TcEnv`'s 2nd `OrdMap`, and that map is
-- written in exactly TWO places — `addCtor` (sole call site, inside
-- `addVariants`, reached only from `registerVariants`, itself called only from
-- `registerData`'s `DData` and `DNewtype` arms) and the two prelude ctors
-- `True`/`False`, hand-seeded straight into the map by `builtinCtors`, bypassing
-- `addCtor` entirely.  Both writers are constructor-only, so `addCtor` alone is
-- not the writer set.  Re-derive with
-- `grep -n 'addCtor\|builtinCtors' compiler/types/typecheck.mdk`.
--
-- An uppercase mutable-cell extern cannot pass the head test, BY CONSTRUCTION
-- rather than by audit: the grammar still permits an
-- uppercase extern NAME (`externNameFor (TUpper x) = emit x`,
-- frontend/parser.mdk, vs `identNameFor`, which accepts only `TIdent`), but an
-- extern is never passed to `addCtor`, so no extern — uppercase or not — can
-- pass the head test any more.  `Ref` (`extern Ref : a -> Ref a`,
-- stdlib/runtime.mdk) is exactly such an extern; its by-name exclusion is kept
-- below purely as defense-in-depth, since the lookup alone already rejects it.
-- See issue 1150 and docs/spec/DICT-SEMANTICS.md §4.1 G2.
--
-- Record creates are non-expansive iff all field expressions are.
-- Note: this ignores the `mut` flag (like the oracle), so `let mut x = []`
-- generalizes — the separate `mut`-gen hole is a both-sides follow-up (T1b).
export
isNonexpansive : TcEnv -> Expr -> Bool
isNonexpansive env (ELoc _ e) = isNonexpansive env e
isNonexpansive env (EDoOrigin _ e) = isNonexpansive env e
isNonexpansive env (ELit _) = True
isNonexpansive env (EVar _) = True
isNonexpansive env (EVarId _ _) = True
-- `run`/`build` rewrite a method reference into a dictionary-marked node before
-- typechecking (`prePassDict`); the marked node is still a variable, so the value
-- predicate must answer as it does for the `EVar` that `check` sees — otherwise
-- `callMin = min` is a value under one verb and expansive under another
-- (check green, build panics on an unbound dictionary witness).
isNonexpansive env (EMethodAt _ _ _) = True
isNonexpansive env (EDictAt _ _) = True
isNonexpansive env (EMethodRef _) = True
isNonexpansive env (ELam _ _) = True
isNonexpansive env (EAnnot e _) = isNonexpansive env e
isNonexpansive env (EHeadAnnot e _) = isNonexpansive env e
isNonexpansive env (ETuple es) = allList (isNonexpansive env) es
isNonexpansive env (EListLit es) = allList (isNonexpansive env) es
-- Constructor application: non-expansive iff the spine head is an EVar naming a
-- REAL, DECLARED constructor (`lookupCtor env`, see the head-test paragraph on
-- `isNonexpansive` above and issue 1150) — that is NOT `Ref`, and every spine argument is
-- itself non-expansive.
-- Partial ctor applications (e.g. `MkTwo []`) are also non-expansive — they are
-- closures, not mutable cells.  `isCtorAppSpine` strips ELoc/EDoOrigin wrappers
-- before testing.
isNonexpansive env (app@(EApp _ _)) = isCtorAppSpine env app
-- Record creation: non-expansive iff every field expression is non-expansive.
isNonexpansive env (ERecordCreate _ fs) =
  allList
    (fa => match fa
      FieldAssign _ e => isNonexpansive env e)
    fs
isNonexpansive env _ = False

-- Walk the left spine of an application to its head, testing EVERY argument met
-- on the way, and finally test whether the head IS a constructor that is safe to
-- generalize: an EVar naming a constructor DECLARED in this `TcEnv`, asked of
-- the environment via `lookupCtor` rather than guessed from the name's spelling
-- (issue 1150, fixed 2026-08-26 — see the head-test paragraph on `isNonexpansive` above for why
-- the ctor map's two writers make the lookup sound).  `Ref` stays excluded by
-- name as defense-in-depth: it is an extern FUNCTION, never passed to
-- `addCtor`, so `lookupCtor` already rejects it on its own.
--
-- `ctorHeadShaped` is retained as a pure FAST PATH in front of the lookup: an
-- ordinary function-application head — the overwhelmingly common `let` RHS —
-- fails on a character read instead of an `OrdMap` probe.  It can only ever
-- narrow, never widen.  It DID narrow on the emit path (#2089's census): the
-- emitter's tree carries constructors mangled to `<mid>__<Ctor>`
-- (`types/private_mangle.mdk`), so a first-character-uppercase test judged every
-- constructor CAF (`regEmpty = Registry omEmpty`) expansive there, narrowed it at
-- first use, and every later use at another element type was a type mismatch —
-- discarded, because nothing read them.  The fast path now accepts both spellings.
--
-- The arguments are tested HERE, on the single walk to the head, rather than by
-- re-entering `isNonexpansive` at each `EApp` level: re-entering would re-walk
-- the whole spine per level, i.e. quadratic in the constructor's arity.  Testing
-- only the LAST argument was issue 1139 — a `Ref` in any non-final position
-- escaped the exclusion entirely, so `let b = BR (Ref []) True` generalized and
-- a cell written at `Int` could be read at `Int -> Int`.
--
-- The head is tested BEFORE the argument: `&&` short-circuits, and the common
-- RHS at a `let` is an ordinary function application, whose head fails the test
-- immediately.  Testing the argument first would walk its whole subtree before
-- discovering the spine was never a constructor application at all.  Both
-- operands are pure `Bool`, so the order is semantically invisible.
isCtorAppSpine : TcEnv -> Expr -> Bool
isCtorAppSpine env (ELoc _ e) = isCtorAppSpine env e
isCtorAppSpine env (EDoOrigin _ e) = isCtorAppSpine env e
isCtorAppSpine env (EApp f x) = isCtorAppSpine env f && isNonexpansive env x
isCtorAppSpine env (EVar name) = isDeclaredCtorHead env name
isCtorAppSpine env (EVarId name _) = isDeclaredCtorHead env name
isCtorAppSpine env _ = False

-- The head test itself: `name` is a real, declared constructor and is not the
-- `Ref` extern.  See `isCtorAppSpine`'s docblock for why `lookupCtor` is the
-- authority, why `ctorHeadShaped` is only a fast path in front of it, and why
-- the `Ref` exclusion is redundant-but-kept.
isDeclaredCtorHead : TcEnv -> String -> Bool
isDeclaredCtorHead env name =
  name /= "Ref" && ctorHeadShaped name && isSome (lookupCtor env name)

-- Generalize a value RHS; value-restrict (monomorphize, lowering free vars)
-- otherwise.  monoScheme leaves the mono ungeneralized.
export
genBindingRestricted : DynCtx ->
  Map Int Unit ->
  List AuthResidual ->
  Bool ->
  EffRow ->
  Mono ->
  Scheme
genBindingRestricted dyn declared residual isValue force t
  | isValue = generalizeBindingDeclared dyn declared residual force t
  | otherwise =
    lowerToCurrent dyn.dcModule t
    lowerRowLevels dyn.dcModule.mcCells.currentLevel.value force
    -- a binding that turns out monomorphic after its scope kept residuals
    -- (a local pinned for dictionary forwarding) owes them where it lives
    each
      (r =>
        lowerAuthLevels dyn.dcModule.mcCells.currentLevel.value r.arLower
        lowerAuthLevels dyn.dcModule.mcCells.currentLevel.value r.arUpper
        wantAuthorityWith dyn.dcModule r.arExact r.arLower r.arUpper)
      residual
    Forall [] [] [] [] force t

-- Expected-type propagation for an application whose argument is a lambda.
-- Inferring `andThen e (stream => Ok [JArray stream])` naively infers the lambda
-- BODY first with `stream : freshVar`, so a downstream conflicting use inside the
-- body (`JArray stream` wants `Array Json`) pins `stream` to the WRONG type before
-- the function's declared param type (`List Json`) is ever reconciled — the later
-- reconciliation then fails at the application with no good site, and the hover
-- side-channel records the wrong `stream` type.  Fix (bidirectional "checking"
-- mode, the do-bind/higher-order case): infer `f` first, peel its parameter type,
-- and unify it onto the lambda's parameter BEFORE inferring the body.  Then the
-- body sees `stream : List Json` and the type error localizes to the `JArray`
-- USE, and recordLocalBind captures the right hover type.  Purely additive: the
-- final `unify ft (TFun xt …)` in inferApp imposes the same equality regardless,
-- so the solution is unchanged — we only make it available earlier.
export
exprLoc : Expr -> Option Loc
exprLoc (ELoc l _) = Some l
exprLoc (EDoOrigin l _) = Some l
exprLoc _ = None

-- the tyvar NAME a constraint argument mentions (`Num a` → "a"); None for a non-tyvar
-- argument (a concrete head), which carries no per-call obligation here.
constraintArgVarName : Ty -> Option String
constraintArgVarName (TyVar v) = Some v
constraintArgVarName _ = None

export
checkRecursiveValue : DynCtx -> BindingSummary -> Unit
checkRecursiveValue dyn owned =
  unifyInto dyn True owned.bsRecursiveValue owned.bsValue

-- C3: each type variable named in the
-- annotation asserts polymorphism, so after unification it must still be a
-- DISTINCT, unbound variable.  If one ground to a concrete type, or two
-- annotation variables collapsed to the same variable, the annotation is more
-- polymorphic than the expression — reject.  `sigTvarIds` keeps only the entries
-- that normalize to a TVar, so a grounded var drops out (count shrinks) and a
-- collapse shows as a duplicate id.  EHeadAnnot is exempt (no call to this).
export
checkAnnotTooGeneral : ModuleCtx -> Ty -> List Mono -> Unit
checkAnnotTooGeneral mctx ty resolved =
  let ids = sigTvarIds resolved
  if listLen ids < listLen resolved || hasDupI ids then
    pushTypeError mctx "T-TYPE-TOO-GENERAL" (annotTooGeneralMsg ty)

-- A `where` block is checked one dependency component at a time, a
-- component's dependencies first, as a module's top level is: a binding that
-- only USES a sibling sees it generalized, rather than sharing its type
-- variables as a member of one recursive group would, so a helper may be used
-- at two types and keeps its own authority residual (#3487).  Members keep
-- their source order inside a component.  A block that repeats a name stays
-- one group: its components are not well defined.
export
letGroupComponents : List LetBind -> List (List LetBind)
letGroupComponents binds =
  let names = map letBindName binds
  let nameSet = namesToSet names omEmpty
  if omSize nameSet < listLen names then
    [binds]
  else
    let grouped =
      fold
        (m (LetBind n clauses _ _) => omInsert n (map funClausePair clauses) m)
        omEmpty
        binds
    map
      (component =>
        let members = namesToSet component omEmpty
        filterList (b => omHasKey (letBindName b) members) binds)
      (tarjanSCCs names (depGraphMap names grouped))

-- True iff the expression is an explicit lambda at the top level.
-- #807 (pre-existing, out of scope here): does NOT see through an ELoc
-- wrapper, so a zero-param `let rec f = x => …` clause — whose RHS the parser
-- wraps in ELoc — is WRONGLY rejected as non-function even though it plainly
-- is one. Confirmed this predates #799's fix (reproduces identically against
-- pre-#799 top-level `let rec`, the only call site old enough to hit it) —
-- not something introduced by the block/expr-level guards added here.
isSyntacticLambda : Expr -> Bool
isSyntacticLambda (ELam _ _) = True
isSyntacticLambda _ = False

-- D2 fix: check all top-level DLetGroup declarations for non-function recursive
-- bindings.  A binding is illegal
-- when ALL its clauses have zero params AND none is a syntactic lambda.
-- Pushes the error into typeErrors for each violating member.
export
checkLetRecDecls : ModuleCtx -> List Decl -> Unit
checkLetRecDecls mctx [] = ()
checkLetRecDecls mctx ((DLetGroup _ binds) :: rest) =
  checkLetBinds mctx binds
  checkLetRecDecls mctx rest
checkLetRecDecls mctx (_ :: rest) = checkLetRecDecls mctx rest

checkLetBinds : ModuleCtx -> List LetBind -> Unit
checkLetBinds mctx [] = ()
checkLetBinds mctx ((LetBind name clauses _ _) :: rest) =
  checkLetBind mctx name clauses
  checkLetBinds mctx rest

checkLetBind : ModuleCtx -> String -> List FunClause -> Unit
checkLetBind mctx name clauses
  | allList clauseIsNonFunction clauses =
    pushTypeError
      (mctxAtIfSome (clausesSpanLoc clauses) mctx)
      "T-NONREC-VALUE-LET"
      (letRecNonFunctionMsg name)
  | otherwise = ()

clauseIsNonFunction : FunClause -> Bool
clauseIsNonFunction (FunClause [] rhs) = not (isSyntacticLambda rhs)
clauseIsNonFunction (FunClause _ _) = False

-- blockRecLet/inferRecLet already have the bound name's (possibly-curried) RHS
-- expr in hand: `curryLam pats e1` for a function-form clause is always an
-- ELam, so this only ever flags the genuinely zero-param, non-lambda case —
-- identical discrimination to clauseIsNonFunction, just on the curried form.
-- Both call sites are ELet, produced ONLY from a singleton binding (a plain
-- `let f a… = e1 [in e2]` or an explicit `let rec` — "with" mutual-grouping was
-- removed), so — unlike ELetGroup below — there is no risk of an innocent
-- bystander binding riding along; mirroring the top-level "not a syntactic
-- lambda ⇒ reject" rule verbatim is safe here. Unlike the top-level call site
-- (which has no expression in hand to locate against), this DOES have the RHS
-- expr and passes it to pushTypeErrorAt via exprLoc (ERROR-QUALITY.md) — but
-- that is a BEST-EFFORT location, not a guaranteed one: exprLoc only recognizes
-- an ELoc/EDoOrigin wrapper, and not every Expr shape the parser produces is
-- wrapped in one (e.g. a bare `EBinOp` RHS like `let rec x = x + 1` has no
-- ELoc, so exprLoc returns None and the diagnostic falls back to the zero
-- range — same as the top-level guard's own unlocated call). A wrapped RHS
-- (the common case — most expressions ARE ELoc-wrapped) gets a real range.
export
checkRecBindNonFunction : ModuleCtx -> String -> Expr -> Unit
checkRecBindNonFunction mctx name e
  | isSyntacticLambda e = ()
  | otherwise =
    pushTypeErrorAt
      mctx
      "T-NONREC-VALUE-LET"
      (exprLoc e)
      (letRecNonFunctionMsg name)

-- inferLetGroup's ELetGroup is DIFFERENT: it is the SAME node `where` clauses
-- desugar to (parser.mdk whereEol/whereTail/guard-arm-where — verified: no
-- `rec` keyword involved, no AST field distinguishing the two), and a `where`
-- group routinely bundles plain, NON-recursive value helpers alongside real
-- functions (e.g. stdlib/list.mdk's `split`: `where sepLen = length sep; go
-- ys = …` — sepLen never mentions itself or any sibling). Applying
-- checkRecBindNonFunction's blunt "not a lambda ⇒ reject" rule here false-
-- positived on exactly that (confirmed against the tree before landing this).
--
-- So this check is narrower and more precise instead of broader: a zero-param,
-- non-lambda clause is illegal only if its RHS EAGERLY (i.e. not deferred
-- behind a nested lambda) mentions itself or a NOT-YET-INSTALLED sibling — the
-- actual hazard (evalLetGroup pre-binds every member's cell to Ref VUnit and
-- installs each member's value in SOURCE ORDER, so an eager reference to a
-- cell installed BEFORE this one is already set — safe — while a reference to
-- itself or a cell installed AFTER this one reads stale VUnit — unsafe).
--
-- Concretely: for the clause at index i, only a self-or-FORWARD reference
-- (index >= i) is illegal; a BACKWARD reference (index < i) is the ordinary,
-- safe `where`-clause shape (`f x = b where a = x + 1; b = a + 100` — `b`
-- referencing the earlier `a` is fine, `a` referencing the later `b` would not
-- be). checkLetGroupBindsGo threads exactly that suffix: at each step the
-- current binding's own name is prepended to the REST of the list (every
-- sibling that installs after it), so "names" passed down is always "self +
-- forward", never "self + every sibling" — an earlier false-positive this
-- fixed (confirmed against the tree: it rejected working `where`-bound values
-- that only referenced an EARLIER sibling).
export
checkLetGroupBindsLocated : ModuleCtx -> List LetBind -> Unit
checkLetGroupBindsLocated mctx = checkLetGroupBindsGo mctx

checkLetGroupBindsGo : ModuleCtx -> List LetBind -> Unit
checkLetGroupBindsGo mctx [] = ()
checkLetGroupBindsGo mctx ((LetBind name clauses _ _) :: rest) =
  let selfAndForward = name :: map letBindName rest
  checkClausesNonFunctionLocated mctx selfAndForward name clauses
  checkLetGroupBindsGo mctx rest

checkClausesNonFunctionLocated : ModuleCtx ->
  List String ->
  String ->
  List FunClause ->
  Unit
checkClausesNonFunctionLocated mctx names name clauses
  | allList clauseIsNonFunction clauses
    && anyClauseEagerlyRefsGroup names clauses =
    pushTypeErrorAt
      mctx
      "T-NONREC-VALUE-LET"
      (clausesLoc clauses)
      (letRecNonFunctionMsg name)
  | otherwise = ()

anyClauseEagerlyRefsGroup : List String -> List FunClause -> Bool
anyClauseEagerlyRefsGroup names clauses =
  anyList (clauseEagerlyRefsGroup names) clauses

clauseEagerlyRefsGroup : List String -> FunClause -> Bool
clauseEagerlyRefsGroup names (FunClause _ rhs) = anyMember names (eagerRefs rhs)

clausesLoc : List FunClause -> Option Loc
clausesLoc [] = None
clausesLoc ((FunClause _ rhs) :: _) = exprLoc rhs

-- The span of the first clause's right-hand side, unwrapped nodes included.
clausesSpanLoc : List FunClause -> Option Loc
clausesSpanLoc [] = None
clausesSpanLoc ((FunClause _ rhs) :: _) = exprSpanLoc rhs

-- Names `e` reads WITHOUT first going under a lambda (a lambda DEFERS
-- evaluation, so a reference inside one cannot observe a still-uninstalled
-- letrec-group cell). Deliberately UNDER-approximates: an Expr shape not
-- explicitly handled falls to the catch-all `[]` (no eager reference
-- detected) rather than guessing — that can only make this check MORE
-- permissive than exhaustive coverage would, never less, so an unhandled
-- shape is a missed catch (no worse than status quo before #799's fix), not a
-- new false positive. Mirrors marker.mdk's collectVars (the DCE reference
-- walk) with ONE change: collectVars descends into ELam bodies (DCE needs
-- every eventually-reachable name); this stops at ELam (its body is deferred,
-- not eager).
eagerRefs : Expr -> List String
eagerRefs (EVar x) = [x]
eagerRefs (EVarId x _) = [x]
-- #2705: a marked occurrence is still a reference to the name (every driver marks
-- before inference now); dropping it here would make this check more permissive
-- than the un-marked tree it mirrors.
eagerRefs (EMethodAt x _ _) = [x]
eagerRefs (EDictAt x _) = [x]
eagerRefs (EApp a b) = eagerRefs a ++ eagerRefs b
eagerRefs (ELam _ _) = []
eagerRefs (ELet _ _ _ e1 e2) = eagerRefs e1 ++ eagerRefs e2
eagerRefs (ELetGroup bs e2) = flatMap eagerRefsLetBind bs ++ eagerRefs e2
eagerRefs (EMatch e0 arms) = eagerRefs e0 ++ flatMap eagerRefsArm arms
eagerRefs (EIf c t el) = eagerRefs c ++ eagerRefs t ++ eagerRefs el
eagerRefs (EBinOp _ a b _) = eagerRefs a ++ eagerRefs b
eagerRefs (EUnOp _ a _) = eagerRefs a
eagerRefs (EInfix op a b) = op :: eagerRefs a ++ eagerRefs b
eagerRefs (EFieldAccess e0 _ _) = eagerRefs e0
eagerRefs (ERecordCreate _ fs) = flatMap eagerRefsFieldAssign fs
eagerRefs (ERecordUpdate e0 fs _) =
  eagerRefs e0 ++ flatMap eagerRefsFieldAssign fs
eagerRefs (EVariantUpdate _ e0 fs) =
  eagerRefs e0 ++ flatMap eagerRefsFieldAssign fs
eagerRefs (EArrayLit es) = flatMap eagerRefs es
eagerRefs (EListLit es) = flatMap eagerRefs es
eagerRefs (ETuple es) = flatMap eagerRefs es
eagerRefs (EIndex e0 i) = eagerRefs e0 ++ eagerRefs i
eagerRefs (ERangeList lo hi _) = eagerRefs lo ++ eagerRefs hi
eagerRefs (ERangeArray lo hi _) = eagerRefs lo ++ eagerRefs hi
eagerRefs (ESlice e0 lo hi _) = eagerRefs e0 ++ eagerRefs lo ++ eagerRefs hi
eagerRefs (EBlock stmts) = flatMap eagerRefsDoStmt stmts
eagerRefs (EDo _ stmts) = flatMap eagerRefsDoStmt stmts
eagerRefs (EAnnot e0 _) = eagerRefs e0
eagerRefs (EHeadAnnot e0 _) = eagerRefs e0
eagerRefs (EStringInterp parts) = flatMap eagerRefsInterp parts
eagerRefs (EGuards arms) = flatMap eagerRefsGuardArm arms
eagerRefs (ESection (SecRight _ e0)) = eagerRefs e0
eagerRefs (ESection (SecLeft e0 _)) = eagerRefs e0
eagerRefs (EAsPat _ e0) = eagerRefs e0
eagerRefs (EMapLit _ kvs) = flatMap eagerRefsPair kvs
eagerRefs (ESetLit _ es) = flatMap eagerRefs es
eagerRefs (ELoc _ e) = eagerRefs e
eagerRefs (EDoOrigin _ e) = eagerRefs e
eagerRefs _ = []

eagerRefsLetBind : LetBind -> List String
eagerRefsLetBind (LetBind _ clauses _ _) =
  flatMap eagerRefsClauseAllPats clauses

-- Unlike the group-membership test above (which only examines zero-param
-- clauses), a NESTED ELetGroup's own function-form members are legitimately
-- deferred (their body only runs once applied) — so only fold in a nested
-- zero-param clause's refs eagerly; a nested function clause's body is safe
-- to skip, matching the ELam short-circuit above.
eagerRefsClauseAllPats : FunClause -> List String
eagerRefsClauseAllPats (FunClause [] rhs) = eagerRefs rhs
eagerRefsClauseAllPats (FunClause _ _) = []

eagerRefsArm : Arm -> List String
eagerRefsArm (Arm _ gs body) = flatMap eagerRefsGuard gs ++ eagerRefs body

eagerRefsGuard : Guard -> List String
eagerRefsGuard (GBool e) = eagerRefs e
eagerRefsGuard (GBind _ e) = eagerRefs e

eagerRefsGuardArm : GuardArm -> List String
eagerRefsGuardArm (GuardArm gs body) =
  flatMap eagerRefsGuard gs ++ eagerRefs body

eagerRefsFieldAssign : FieldAssign -> List String
eagerRefsFieldAssign (FieldAssign _ e) = eagerRefs e

eagerRefsDoStmt : DoStmt -> List String
eagerRefsDoStmt (DoExpr e) = eagerRefs e
eagerRefsDoStmt (DoBind _ e) = eagerRefs e
eagerRefsDoStmt (DoLet _ _ _ e _) = eagerRefs e
eagerRefsDoStmt _ = []

eagerRefsInterp : InterpPart -> List String
eagerRefsInterp (InterpExpr e) = eagerRefs e
eagerRefsInterp _ = []

eagerRefsPair : (Expr, Expr) -> List String
eagerRefsPair (k, v) = eagerRefs k ++ eagerRefs v

export
groupNames : List (String, (List Pat, Expr)) -> OrdMap Unit -> List String
groupNames [] _ = []
groupNames ((n, _) :: rest) seen = match omLookup n seen
  Some _ => groupNames rest seen
  None => n :: groupNames rest (omInsert n () seen)

-- Whether a where/let group member generalizes, and its type.
export
letBindGeneralizes : TcEnv ->
  (LetBind, (String, BindingSummary)) ->
  (Bool, Mono)
letBindGeneralizes env (LetBind _ clauses _ _, (_, summary)) =
  (clausesAreValue env clauses, summary.bsValue)

export
generalizeGroup : TcEnv ->
  List (Int, AuthResidual) ->
  Int ->
  List (LetBind, (String, Scheme)) ->
  TcEnv
generalizeGroup env _ _ [] = env
generalizeGroup env residuals index ((LetBind name clauses _ _, (_, sch)) :: rest) =
  let mono = schemeMono sch
  let isVal = clausesAreValue env clauses
  -- WS-2: α scope-seed — single-clause zero-param bindings only (mirror α's
  -- alphaCollectBinds rule); a multi-clause / parameterized binding is not a
  -- known prefix.
  let env1 =
    extendLocalVar
      env
      name
      (genBindingRestricted
        env.teDyn
        Tip
        (residualsOf index residuals)
        isVal
        pureRow
        mono)
  let env2 = match clauses
    [FunClause [] rhs] => seedAlphaLets env1 name rhs
    _ => env1
  generalizeGroup env2 residuals (index + 1) rest

-- A where-clause binding is a value (generalizable) iff every clause has params
-- (it's a function) or its zero-arg RHS is non-expansive.
clausesAreValue : TcEnv -> List FunClause -> Bool
clausesAreValue env clauses = allList (clauseIsValue env) clauses

clauseIsValue : TcEnv -> FunClause -> Bool
clauseIsValue env (FunClause [] rhs) = isNonexpansive env rhs
clauseIsValue env (FunClause _ _) = True

-- [o]'s prerequisites, each entered on [o]'s walk by [enter].
export
requireGoalsBelow : ModuleCtx ->
  (ReqWalk -> UObligation -> List (UObligation, ReqWalk)) ->
  OrdMap Unit ->
  OrdMap Unit ->
  (UObligation, ReqWalk) ->
  List (UObligation, ReqWalk)
requireGoalsBelow mctx enter rigidIds liveIds (o, walk) =
  let args = map normalize (uOblArgs mctx.mcGraph o)
  let iface = o.pred.iface
  let parentIds = flatMap monoUnboundIds args
  if isEmptyL args
    || monoVectorClosed args
    || goalVarsAllHeld rigidIds args
    || goalGivenAt mctx.mcGraph iface args o.uoScope
    || anyList (i => omHasKey (intToString i) liveIds) parentIds
      && not (undeterminedGoalExempt mctx iface args o.uoScope) then
    []
  else
    let rows = goalRows mctx iface args
    let reach =
      if goalIsProjection args rows then
        ReachMany
      else
        goalReach mctx args (goalCandidates mctx rigidIds args rows)
    match reach
      ReachOne row =>
        let goalsOf =
          ids subst reqs =>
            flatMap
              (req =>
                flatMap
                  (enter walk)
                  (requireGoalAt o ids (reqToObligation mctx subst req)))
              reqs
        match selectedRowReqMatch mctx args row
          Some (subst, reqs) => goalsOf parentIds subst reqs
          None => match unifiedRowReqs mctx rigidIds args row
            Some (subst, fresh, reqs) => goalsOf (parentIds ++ fresh) subst reqs
            None => []
      _ => []

-- The prerequisites of [row] under the unifier of its heads with [args] (every
-- variable in [rigidIds] held rigid), for a goal the row's head determines without
-- matching it as it stands (`B ?a` under `impl B (List b)`).  The unifier is not
-- committed, so the head variable it introduces (`?b` in `?a := List ?b`) stands
-- for a part of the goal's variable only while nothing outside the boundary can
-- still bind that variable: every goal variable it binds must be the boundary's.
-- One a scheme quantifies makes the goal the caller's, and the caller walks it on
-- its own variables.  The substitution keeps the goal's own variables where the
-- unifier held them rigid, and the variables it introduces are returned beside it.
unifiedRowReqs : ModuleCtx ->
  OrdMap Unit ->
  List Mono ->
  ImplRow ->
  Option (List (String, Mono), List Int, List Require)
unifiedRowReqs mctx rigidIds args (row@(ImplRow _ _ _ _ reqs _ _)) =
  let (tvs, heads) = freshRowHeadsTvs mctx row
  let goalIds = flatMap monoUnboundIds args
  match headsUnifier mctx.mcGraph rigidIds args heads
    Some scratch =>
      if allList
        (b =>
          not (containsI (fst b) goalIds)
            || boundaryOwnsOpen mctx rigidIds (fst b))
        !scratch then
        let sigCells = sigCellsOf rigidIds (flatMap monoVarCells args)
        let bound =
          map
            (nv => (fst nv, unrigidSig sigCells (cohApply scratch (snd nv))))
            tvs
        Some (bound, flatMap (nv => monoUnboundIds (snd nv)) bound, reqs)
      else
        None
    None => None

-- A prerequisite as a goal at [o]'s site.  One that mentions a variable the
-- instance's head does not fix is left to the module's obligation check.
requireGoalAt : UObligation ->
  List Int ->
  (IfaceRef, List Mono) ->
  List UObligation
requireGoalAt o parentIds (iface, args)
  | not (allList (i => containsI i parentIds) (flatMap monoUnboundIds args)) =
    []
  | otherwise = [
    UObligation {
      pred = Predicate { iface = iface, args = args },
      originId = o.originId,
      prov = o.prov,
      loc = o.loc,
      uoScope = o.uoScope,
      oblProj = OpProjected,
    },
  ]

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

-- every variable reference in an expr, bound ones included (an over-approximation
-- of its free references); the dependency graph uses `freeEVars` instead
export
allEVars : Expr -> List String
allEVars (EVar x) = [x]
allEVars (EVarId x _) = [x]
allEVars (EMethodAt n _ _) = [n]
allEVars (EDictAt n _) = [n]
allEVars (ELit _) = []
allEVars (EApp f x) = allEVars f ++ allEVars x
allEVars (ELam _ b) = allEVars b
allEVars (ELet _ _ _ e1 e2) = allEVars e1 ++ allEVars e2
allEVars (ELetGroup binds body) = flatMap letBindEVars binds ++ allEVars body
allEVars (EMatch e arms) = allEVars e ++ flatMap armEVars arms
allEVars (EIf c t e) = allEVars c ++ allEVars t ++ allEVars e
allEVars (EBinOp _ l r _) = allEVars l ++ allEVars r
allEVars (EUnOp _ e _) = allEVars e
allEVars (EInfix op l r) = op :: allEVars l ++ allEVars r
allEVars (EFieldAccess e _ _) = allEVars e
allEVars (ETuple es) = flatMap allEVars es
allEVars (EListLit es) = flatMap allEVars es
allEVars (EArrayLit es) = flatMap allEVars es
allEVars (ERangeList a b _) = allEVars a ++ allEVars b
allEVars (ERangeArray a b _) = allEVars a ++ allEVars b
allEVars (ESlice e a b _) = allEVars e ++ allEVars a ++ allEVars b
allEVars (EIndex e i) = allEVars e ++ allEVars i
allEVars (EAnnot e _) = allEVars e
allEVars (EBlock stmts) = flatMap doStmtEVars stmts
allEVars (ERecordCreate _ fs) = flatMap fieldAssignEVars fs
allEVars (ERecordUpdate e fs _) = allEVars e ++ flatMap fieldAssignEVars fs
allEVars (EVariantUpdate _ e fs) = allEVars e ++ flatMap fieldAssignEVars fs
allEVars (ELoc _ e) = allEVars e
allEVars (EDoOrigin _ e) = allEVars e
allEVars (EHeadAnnot e _) = allEVars e
allEVars (EAsPat _ e) = allEVars e
allEVars (EMapLit _ kvs) = flatMap kvEVars kvs
allEVars (ESetLit _ es) = flatMap allEVars es
allEVars (EDo _ stmts) = flatMap doStmtEVars stmts
allEVars (EStringInterp parts) = flatMap interpEVars parts
allEVars (EGuards arms) = flatMap guardArmEVars arms
allEVars (ESection s) = sectionEVars s
-- The arms above mirror `rewriteArgScoped`'s traversal (children only, binders
-- ignored).  What is left for the catch-all, derived against `Expr`'s full
-- constructor set, is exactly four
-- constructors that carry no sub-`Expr` reachable here:
--   ENumLit, EDictApp  — leaves;
--   EMethodRef         — no production verb mints one (see `declRefNames` below);
--   EVarAt             — minted by `annotateProgram`, which runs after typecheck.
-- A new reference-bearing constructor therefore needs an arm above: falling to the
-- catch-all silently drops a dependency edge rather than erroring.
allEVars _ = []

kvEVars : (Expr, Expr) -> List String
kvEVars (k, v) = allEVars k ++ allEVars v

interpEVars : InterpPart -> List String
interpEVars (InterpStr _) = []
interpEVars (InterpExpr e) = allEVars e

guardArmEVars : GuardArm -> List String
guardArmEVars (GuardArm guards body) =
  flatMap guardEVars guards ++ allEVars body

sectionEVars : Section -> List String
sectionEVars (SecBare op) = [op]
sectionEVars (SecRight op e) = op :: allEVars e
sectionEVars (SecLeft e op) = op :: allEVars e

letBindEVars : LetBind -> List String
letBindEVars (LetBind _ clauses _ _) = flatMap funClauseEVars clauses

funClauseEVars : FunClause -> List String
funClauseEVars (FunClause _ body) = allEVars body

armEVars : Arm -> List String
armEVars (Arm _ guards body) = flatMap guardEVars guards ++ allEVars body

guardEVars : Guard -> List String
guardEVars (GBool e) = allEVars e
guardEVars (GBind _ e) = allEVars e

doStmtEVars : DoStmt -> List String
doStmtEVars (DoExpr e) = allEVars e
doStmtEVars (DoLet _ _ _ e _) = allEVars e
doStmtEVars (DoBind _ e) = allEVars e
doStmtEVars (DoAssign _ e) = allEVars e
doStmtEVars (DoFieldAssign _ _ e) = allEVars e

fieldAssignEVars : FieldAssign -> List String
fieldAssignEVars (FieldAssign _ e) = allEVars e

-- The names `e` reads that are not bound by a binder inside `e` or in `bound`:
-- `allEVars` with the binders subtracted, for the dependency graph (`clauseRefs`).
-- Scoping follows resolve's `stampExpr`, the walk that decides which binding an
-- occurrence names: a lambda's and a clause's params, a let's pattern (in its own
-- right-hand side too when recursive), a let group's names, an arm's pattern and
-- its `<-` guards, and a statement's pattern for the statements after it.  An
-- `EVarId` is read by its name: a local letrec's bodies are stamped before they
-- are grouped, and every local occurrence carries the same id 0.
-- A recursive `DoLet` and a recursive non-`PVar` `ELet` bind the pattern in their own
-- right-hand side here, wider than `stampExpr`; the worst case is a group split that
-- could have stayed merged.
freeEVars : OrdMap Unit -> Expr -> List String
freeEVars bound (EVar x) = freeName bound x
freeEVars bound (EVarId x _) = freeName bound x
freeEVars _ (EMethodAt n _ _) = [n]
freeEVars _ (EDictAt n _) = [n]
freeEVars bound (EApp f x) = freeEVars bound f ++ freeEVars bound x
freeEVars bound (ELam ps b) = freeEVars (namesToSet (patVarsListTc ps) bound) b
freeEVars bound (ELet _ r p e1 e2) =
  let after = namesToSet (patVarsTc p) bound
  freeEVars (if r then after else bound) e1 ++ freeEVars after e2
freeEVars bound (ELetGroup binds body) =
  let inner = namesToSet (map letBindName binds) bound
  flatMap (freeLetBindEVars inner) binds ++ freeEVars inner body
freeEVars bound (EMatch e arms) =
  freeEVars bound e ++ flatMap (freeArmEVars bound) arms
freeEVars bound (EIf c t e) =
  freeEVars bound c ++ freeEVars bound t ++ freeEVars bound e
freeEVars bound (EBinOp _ l r _) = freeEVars bound l ++ freeEVars bound r
freeEVars bound (EUnOp _ e _) = freeEVars bound e
freeEVars bound (EInfix op l r) =
  freeName bound op ++ freeEVars bound l ++ freeEVars bound r
freeEVars bound (EFieldAccess e _ _) = freeEVars bound e
freeEVars bound (ETuple es) = flatMap (freeEVars bound) es
freeEVars bound (EListLit es) = flatMap (freeEVars bound) es
freeEVars bound (EArrayLit es) = flatMap (freeEVars bound) es
freeEVars bound (ERangeList a b _) = freeEVars bound a ++ freeEVars bound b
freeEVars bound (ERangeArray a b _) = freeEVars bound a ++ freeEVars bound b
freeEVars bound (ESlice e a b _) =
  freeEVars bound e ++ freeEVars bound a ++ freeEVars bound b
freeEVars bound (EIndex e i) = freeEVars bound e ++ freeEVars bound i
freeEVars bound (EAnnot e _) = freeEVars bound e
freeEVars bound (EBlock stmts) = freeStmtsEVars bound stmts
freeEVars bound (ERecordCreate _ fs) = flatMap (freeFieldEVars bound) fs
freeEVars bound (ERecordUpdate e fs _) =
  freeEVars bound e ++ flatMap (freeFieldEVars bound) fs
freeEVars bound (EVariantUpdate _ e fs) =
  freeEVars bound e ++ flatMap (freeFieldEVars bound) fs
freeEVars bound (ELoc _ e) = freeEVars bound e
freeEVars bound (EDoOrigin _ e) = freeEVars bound e
freeEVars bound (EHeadAnnot e _) = freeEVars bound e
freeEVars bound (EAsPat _ e) = freeEVars bound e
freeEVars bound (EMapLit _ kvs) = flatMap (freeKvEVars bound) kvs
freeEVars bound (ESetLit _ es) = flatMap (freeEVars bound) es
freeEVars bound (EDo _ stmts) = freeStmtsEVars bound stmts
freeEVars bound (EStringInterp parts) = flatMap (freeInterpEVars bound) parts
freeEVars bound (EGuards arms) = flatMap (freeGuardArmEVars bound) arms
freeEVars bound (ESection (SecBare op)) = freeName bound op
freeEVars bound (ESection (SecRight op e)) =
  freeName bound op ++ freeEVars bound e
freeEVars bound (ESection (SecLeft e op)) =
  freeName bound op ++ freeEVars bound e
-- Leaves.  `EMethodRef` and `EVarAt` never reach the dependency graph (see
-- `allEVars`'s catch-all), and are not counted there either.
freeEVars _ (ELit _) = []
freeEVars _ (ENumLit _ _ _) = []
freeEVars _ (EWideLit _ _ _ _) = []
freeEVars _ (EDictApp _) = []
freeEVars _ (EMethodRef _) = []
freeEVars _ (EVarAt _ _) = []

freeKvEVars : OrdMap Unit -> (Expr, Expr) -> List String
freeKvEVars bound (k, v) = freeEVars bound k ++ freeEVars bound v

freeName : OrdMap Unit -> String -> List String
freeName bound x = if omHasKey x bound then [] else [x]

freeInterpEVars : OrdMap Unit -> InterpPart -> List String
freeInterpEVars _ (InterpStr _) = []
freeInterpEVars bound (InterpExpr e) = freeEVars bound e

freeFieldEVars : OrdMap Unit -> FieldAssign -> List String
freeFieldEVars bound (FieldAssign _ e) = freeEVars bound e

freeLetBindEVars : OrdMap Unit -> LetBind -> List String
freeLetBindEVars bound (LetBind _ clauses _ _) =
  flatMap (c => clauseRefsUnder bound (funClausePair c)) clauses

clauseRefsUnder : OrdMap Unit -> (List Pat, Expr) -> List String
clauseRefsUnder bound (ps, body) =
  freeEVars (namesToSet (patVarsListTc ps) bound) body

freeArmEVars : OrdMap Unit -> Arm -> List String
freeArmEVars bound (Arm p guards body) =
  freeGuardsEVars (namesToSet (patVarsTc p) bound) guards body

freeGuardArmEVars : OrdMap Unit -> GuardArm -> List String
freeGuardArmEVars bound (GuardArm guards body) =
  freeGuardsEVars bound guards body

-- guards left to right, a `p <- e` guard binding `p` for the guards after it and
-- for the body
freeGuardsEVars : OrdMap Unit -> List Guard -> Expr -> List String
freeGuardsEVars bound [] body = freeEVars bound body
freeGuardsEVars bound ((GBool e) :: rest) body =
  freeEVars bound e ++ freeGuardsEVars bound rest body
freeGuardsEVars bound ((GBind p e) :: rest) body =
  freeEVars bound e
    ++ freeGuardsEVars (namesToSet (patVarsTc p) bound) rest body

freeStmtsEVars : OrdMap Unit -> List DoStmt -> List String
freeStmtsEVars _ [] = []
freeStmtsEVars bound ((DoExpr e) :: rest) =
  freeEVars bound e ++ freeStmtsEVars bound rest
freeStmtsEVars bound ((DoLet _ r p e _) :: rest) =
  let after = namesToSet (patVarsTc p) bound
  freeEVars (if r then after else bound) e ++ freeStmtsEVars after rest
freeStmtsEVars bound ((DoBind p e) :: rest) =
  freeEVars bound e ++ freeStmtsEVars (namesToSet (patVarsTc p) bound) rest
freeStmtsEVars bound ((DoAssign x e) :: rest) =
  freeEVars bound e ++ freeStmtsEVars (namesToSet [x] bound) rest
freeStmtsEVars bound ((DoFieldAssign _ _ e) :: rest) =
  freeEVars bound e ++ freeStmtsEVars bound rest

export
depGraphMap : List String ->
  OrdMap (List (List Pat, Expr)) ->
  OrdMap (List String)
depGraphMap names grouped =
  buildAdj names (namesToSet names omEmpty) grouped omEmpty

-- defs grouped by name ONCE (name -> its clauses, in defs order), so `depsOf`
-- does an O(log n) lookup instead of re-scanning all defs per name (was
-- O(names·defs)). Built by prepend (O(1)); `clausesOf` reverses on read to
-- restore defs order — so the per-name clause list is identical to the old
-- `clausesFor name defs`, keeping dep lists / SCC order / output byte-identical.
export
groupClauses : List (String, (List Pat, Expr)) -> OrdMap (List (List Pat, Expr))
groupClauses defs = groupClausesGo defs omEmpty

groupClausesGo : List (String, (List Pat, Expr)) ->
  OrdMap (List (List Pat, Expr)) ->
  OrdMap (List (List Pat, Expr))
groupClausesGo [] m = m
groupClausesGo ((n, c) :: rest) m =
  groupClausesGo rest (omInsert n (c :: clausesAt n m) m)

buildAdj : List String ->
  OrdMap Unit ->
  OrdMap (List (List Pat, Expr)) ->
  OrdMap (List String) ->
  OrdMap (List String)
buildAdj [] _ _ m = m
buildAdj (n :: rest) nameSet cbn m =
  buildAdj rest nameSet cbn (omInsert n (depsOf n nameSet cbn) m)

-- per-name dependencies: the other group names a binding's bodies reference FREE.
-- Consumed by depGraphMap → Tarjan.  An over-approximated edge is not harmless:
-- it merges two bindings into one SCC, which infers them monomorphically together
-- and can leak one member's constraints into the other's scheme.  So a local
-- binder or parameter that shadows a group name must not count as a reference to
-- it (`clauseRefs` → `freeEVars`).
depsOf : String -> OrdMap Unit -> OrdMap (List (List Pat, Expr)) -> List String
depsOf name nameSet cbn =
  filterNonSelf
    name
    (keepGroupNames nameSet (dedup (groupRefs (clausesOf name cbn))))

groupRefs : List (List Pat, Expr) -> List String
groupRefs clauses = flatMap clauseRefs clauses

clauseRefs : (List Pat, Expr) -> List String
clauseRefs clause = clauseRefsUnder omEmpty clause

keepGroupNames : OrdMap Unit -> List String -> List String
keepGroupNames nameSet refs = filterList (r => omHasKey r nameSet) refs

filterNonSelf : String -> List String -> List String
filterNonSelf name xs = filterList (/= name) xs

-- #23 (two-hop forward): the impl-obligation-shaped entries for EVERY iface (not
-- just Num) a group's constrained-callee instantiations recorded on the call/dict
-- deltas.  Unlike numCallObls/numDictObls (which feed only Num-defaulting), these
-- feed registerSchemeObligations so a constraint FORWARDED from a constrained callee
-- (`useApp g = app2 g`, whose Num lives on the call/dict deltas, never on
-- pendingImplObligations) is recorded in schemeObligationsRef — so a caller of the
-- forwarder (`main = println (useApp (==))`) re-instantiates it (instantiateVarTracked),
-- surfacing the constraint on the caller's own delta where group Num-defaulting can
-- ground the shared ambiguous var.  Without this the forwarded var never grounds on
-- the check path and a downstream Eq/Ord obligation on it is falsely ambiguous.
-- #23 two-hop forward, VECTOR-PRESERVING.  A constraint forwarded from a constrained
-- callee lives on the pendingCallObligations delta, never in addedObls, so a caller of
-- this group must re-instantiate it from schemeObligationsRef.
--
-- A pendingCallObligations entry carries its joint `List Mono`, so it is mapped to bound
-- tyvar ids directly and the vector survives at every arity.  Routing it through a
-- synthetic single-Mono addedObls entry would flat-map a joint predicate per ARGUMENT, and
-- because each 1-ary shard lands on a bound tyvar, boundTyvarIds would succeed and
-- fabricate `Ix a` + `Ix i` alongside the real `Ix a i` (one violation reported three
-- times; `(Ix a, Ix a b, Ix b) =>` displayed).  Mapping directly also closes the UNSIGNED
-- forwarding hole, which the declared-context path cannot reach (lookupSigTvMap is None
-- for an unsigned binding).
-- #1549: both scheme-obligation channels project their entry to a PREDICATE
-- (`callPredOf` / `oblPredOf`) and map it through the ONE `vecOblOfPred` — so the
-- residual reduction §4 `gen` requires cannot be present on one channel and absent
-- from the other (this file's signature failure mode).
forwardedVecObls : ModuleCtx ->
  Bool ->
  List Int ->
  List (IfaceRef, List Mono, Option Loc) ->
  List VecObl
forwardedVecObls mctx generalizing boundIds callObls =
  flatMap
    (vecOblOfPred mctx generalizing boundIds)
    (flatMap callPredOf callObls)

-- A multi-member SCC is a mutually-recursive group (always a function group, like
-- the oracle's DLetGroup); a singleton is a plain binding gated on its RHS.  Self-
-- recursive singletons have had their self-edge stripped (filterNonSelf) so they
-- arrive as size-1 SCCs — strict evaluation rules out a self-recursive zero-arg
-- value, so gating them on the RHS is sound and matches the oracle's DFunDef path.
export
isLetrecGroup : List String -> Bool
isLetrecGroup [] = False
isLetrecGroup [_] = False
isLetrecGroup _ = True

export
memberForce : ScopedMember -> EffRow
memberForce member =
  optionOr (optionOr pureRow member.smForce) member.smForceBound.value

sigTvMapUnboundIds : (String, Ty, List (String, Mono)) -> List Int
sigTvMapUnboundIds (_, _, tvs) = flatMap (p => monoUnboundIds (snd p)) tvs

-- A declared signature variable is a caller-chosen universal, so Num defaulting
-- never grounds it, whatever the group's shape. Every recursive occurrence of a
-- signed member instantiates its written contract afresh (`preunifySigsEx` installs
-- the declared scheme as `smRecursive`), so a declared variable never appears in
-- another member's type: an unsigned sibling's copy is its own inference variable
-- and defaults or generalizes under the ordinary rules. The former "shared by every
-- generalizable member" bound assumed monomorphic recursion, under which the
-- declared variable and the sibling's copy were one cell; with fresh contracts that
-- bound protected nothing, and both members of a signed mutual group defaulted to
-- Int without any too-general diagnostic.
export
sccProtectedSignatureIds : List (String, Ty, List (String, Mono)) -> OrdMap Unit
sccProtectedSignatureIds sigTvMaps =
  omFromNames (map intToString (flatMap sigTvMapUnboundIds sigTvMaps)) omEmpty

-- One entry per predicate (S-dict-arity-contract, #1318/B-4) — the (iface, bare
-- tyvar NAMES) pairs of a signature's `=>` constraints, ONE per constraint that has at
-- least one bare type variable ANYWHERE in its argument types, direct or NESTED
-- (`tyVarArgNames`'s `dedup (flatMap tyVarNames tys)` walks into `TyApp`/`TyFun`/`TyTuple`
-- spines, not just top-level `TyVar` arguments — S-structured-predicate-carry). So a
-- STRUCTURED-only constraint (`Tag (Wrap a) =>`, no bare argument, `a` only reachable by
-- descending into `Wrap a`) DOES carry a dict slot now.  Only a constraint whose
-- arguments are entirely ground/closed — no bare type variable anywhere in them, nested
-- or not — carries no dict slot and contributes nothing.
--
-- This list IS the dict-param cardinality of a `=>`-constrained top-level fn: it feeds
-- `registerMemberSlots` → `funConstraintsRef`, which `dictArityOf` (define side) and
-- `inferDictAtFound` (call side) both size from.  It emits one entry per PREDICATE,
-- not per bare tyvar ARGUMENT: `Ix a b =>` is ONE dict param, matching the
-- METHOD-level channel (`methodLevelConstraintVarNames`/`constraintSlotDispatchVar`,
-- one slot per constraint) and the impl-`requires` channel (`registerReqSlots`, one
-- slot per ENTRY).  All three channels agree: one dict per predicate.  The names are kept
-- as a LIST, not collapsed to the first one here, because WHICH of them is still an abstract tyvar after body inference is not knowable
-- until `registerMemberSlots` normalizes the instantiated monos — and every abstract one
-- must still reach `activeDictVars`, or a body use dispatching on the predicate's SECOND
-- variable loses its route.
export
sigConstraints : Ty -> List (IfaceRef, List String)
sigConstraints (TyConstrained cs _) = flatMap constraintTyVars cs
sigConstraints _ = []

-- U1b (#1482): carries `constraintOrigin` (the #1110 interface-occurrence identity)
-- alongside the spelling, so `registerMember`'s slot-parallel iface list — and hence
-- every obligation `recordCallObligations` later mints from it — is identity-carrying.
constraintTyVars : Constraint -> List (IfaceRef, List String)
constraintTyVars (Constraint { constraintHead = iface, constraintArgs = tys, constraintOrigin = co }) =
  match tyVarArgNames tys
    [] => []
    ns => [(IfaceRef { irName = iface, irOrigin = co }, ns)]

tyVarArgNames : List Ty -> List String
tyVarArgNames tys = dedup (flatMap tyVarNames tys)

-- #1161 (F-3a-ii): slot-parallel to `sigConstraints` — the WHOLE predicate's argument
-- type list, ONE per slot.  `Ix a Char` and `Ix a b` are each ONE slot carrying their
-- full argument list (`[TyVar a, TyCon Char]` / `[TyVar a, TyVar b]`) — evidence for one
-- predicate, so one goal.
-- Length-parallel to sigConstraints by construction: both are `flatMap … cs` over the
-- SAME constraint list, and both emit one element per constraint that has at least one
-- bare tyvar argument.
-- Matches sigConstraints' TOP-LEVEL-`TyConstrained`-only shape deliberately, so the two
-- cannot desynchronize on a nested-constraint spine.
export
sigConstraintArgTys : Ty -> List (List Ty)
sigConstraintArgTys (TyConstrained cs _) = flatMap constraintTyVarArgs cs
sigConstraintArgTys _ = []

constraintTyVarArgs : Constraint -> List (List Ty)
constraintTyVarArgs (Constraint { constraintArgs = tys }) =
  match tyVarArgNames tys
    [] => []
    _ => [tys]

-- like constraintVarMonos but KEEPS the iface name paired with each constraint var's
-- mono (slot order preserved), so registerMember can register call-obligation ifaces.
-- S-dict-arity-contract: the payload is now the predicate's WHOLE bare-tyvar mono list,
-- one entry per predicate.  An entry survives when at least one of its names is in
-- [tvMap] (the drop rule `constraintVarArgMonos` mirrors exactly); the monos of the
-- names that are absent are simply not carried, which is what the per-name walk did.
export
constraintVarIfaceMonos : List (IfaceRef, List String) ->
  List (String, Mono) ->
  List (IfaceRef, List Mono)
constraintVarIfaceMonos [] _ = []
constraintVarIfaceMonos ((iface, names) :: rest) tvMap =
  match constraintNameMonos names tvMap
    [] => constraintVarIfaceMonos rest tvMap
    monos => (iface, monos) :: constraintVarIfaceMonos rest tvMap

-- #1161 (F-3a-ii): as constraintVarIfaceMonos, but yields each kept slot's predicate
-- argument vector as MONOS at the signature instantiation.  Drops exactly the slots
-- constraintVarIfaceMonos drops (same `lookupAssoc name tvMap` test, same walk), so the
-- two lists stay slot-parallel.
-- Resolves arguments with `fromAstType tvMap`, NOT `constraintArgMonos` — the latter
-- returns `None` for any argument that is not a bare type variable, i.e. exactly the
-- concrete `Char` in `Ix a Char` that is the whole point of recording the vector.
-- Every tyvar NAME reachable inside an argument is in [tvMap]: instantiateSigTracked
-- builds it from `tyVarNamesWithConstraints`, whose constraint half
-- (`constraintArgVarNames`) is a full structural `tyVarNames` walk of each argument —
-- so the interior `b` of `List b` is mapped, and fromAstType's unmapped-var → `TCon n`
-- fallback is unreachable here.
export
constraintVarArgMonos : ModuleCtx ->
  List (IfaceRef, List String) ->
  List (List Ty) ->
  List (String, Mono) ->
  List (List Mono)
constraintVarArgMonos mctx [] _ _ = []
constraintVarArgMonos mctx _ [] _ = []
constraintVarArgMonos mctx ((_, names) :: rest) (args :: argsRest) tvMap =
  match constraintNameMonos names tvMap
    [] => constraintVarArgMonos mctx rest argsRest tvMap
    _ =>
      map (fromAstType mctx tvMap) args
        :: constraintVarArgMonos mctx rest argsRest tvMap

-- generalize each member's (sig-and-body-unified) placeholder.  A signature was
-- already unified into the placeholder by preunifySigs, so generalizing the
-- result respects it AND any further specialization the body forces (e.g.
-- sum : t a -> a with body `fold (+) 0` reports a Int -> Int, not the raw sig).
-- Value restriction (DICT-SEMANTICS §4.1 G2): generalize a member only if it is
-- a syntactic *value* — every one of its clauses has params, or its zero-arg RHS
-- is non-expansive (`isNonexpansive`).  The decision is per MEMBER and purely
-- syntactic, on every group shape:
--   * a multi-member SCC gets no exemption (#2554): a zero-arg expansive member
--     such as `cell = Ref (helper 0)` inside a mutually-recursive group is a
--     polymorphic reference if generalized, and its siblings with params are
--     values on their own account, so "a group is always a function group" was
--     never the premise that made generalizing it safe;
--   * a signed binding gets no exemption from its type (#2556): the old
--     "post-unify type is an arrow" reading admitted `weird : a -> a ;
--     weird = mk ()`, whose RHS allocates a Ref before returning the arrow, so
--     one cell was read at two types.  A point-free binding is a value only
--     if G2 says so — write `maximum xs = fold step None xs`, not
--     `maximum = fold step None`.
-- A non-function expansive binding (`r = Ref []`) is value-restricted and stays
-- monomorphic whether or not it is signed.  The `isLetrec` argument is retained
-- for the caller signature; it does not influence the decision.
export
sccSchemes : TcEnv ->
  List (String, Ty) ->
  OrdMap (List (List Pat, Expr)) ->
  Bool ->
  List (Int, AuthResidual) ->
  Int ->
  List ScopedMember ->
  List (String, Scheme)
sccSchemes env _ _ _ _ _ [] = []
sccSchemes env sigs grouped isLetrec residuals index (member :: rest) =
  let m = member.smName
  let isVal = allList (memberClauseIsValue env) (clausesOf m grouped)
  (
      m,
      genBindingRestricted
        env.teDyn
        member.smDeclaredAuths.value
        (residualsOf index residuals)
        isVal
        (memberForce member)
        member.smMono,
    )
    :: sccSchemes env sigs grouped isLetrec residuals (index + 1) rest

-- The authority variables each member of a group will quantify, keyed to the
-- member's index: the argument-position authorities of an unsigned value
-- member (`qualifierAuthIds`, the ones publication keeps).  A variable two
-- members' types share is a recursive group's monomorphic link and is solved
-- as before; a signed member publishes its signature, so it keeps none.
export
quantifiableAuthorities : TcEnv ->
  OrdMap (List (List Pat, Expr)) ->
  List ScopedMember ->
  ScopeRoles
quantifiableAuthorities env grouped members =
  scopeRolesOf
    (map
      (member => (
        memberRole
          -- the presence set, not a scan of every signature: this runs once
          -- per binding group (`sigNameSetRef`)
          (omHasKey
            member.smName
            env.teDyn.dcModule.mcCells.sigNameSetRef.value)
          (allList (memberClauseIsValue env) (clausesOf member.smName grouped)),
        member.smMono,
      ))
      members)

memberRole : Bool -> Bool -> BindingRole
memberRole True _ = RoleDeclared
memberRole False True = RoleQuantifies
memberRole False False = RoleMonomorphic

-- [members] in group order, each with its role and type.  A quantifying
-- member's argument-position authorities are quantified (a variable two
-- members share is a recursive group's monomorphic link and is solved as
-- before); a monomorphic member hands every authority of its type outward.
export
scopeRolesOf : List (BindingRole, Mono) -> ScopeRoles
scopeRolesOf members =
  let owners =
    fold
      ((acc, index) (role, mono) =>
        let ids = match role
          RoleQuantifies => IdMap.keys (qualifierAuthIds mono Tip)
          _ => []
        (
          fold
            (m id => IdMap.set id (index :: optionOr [] (IdMap.get id m)) m)
            acc
            ids,
          index + 1,
        ))
      (Tip, 0)
      members
  ScopeRoles {
    rlQuantified =
      IdMap.foldlWithKey
        (acc id indices => match indices
          [index] => IdMap.set id index acc
          _ => acc)
        Tip
        (fst owners),
    rlOutward =
      fold
        (acc (role, mono) => match role
          RoleMonomorphic => authIdsIn mono acc
          _ => acc)
        Tip
        members,
    rlTyped = Some (fold (acc (_, mono) => authIdsIn mono acc) Tip members),
    rlMemberAuths = _ => map ((_, mono) => authIdsIn mono Tip) members,
  }

export
residualsOf : Int -> List (Int, AuthResidual) -> List AuthResidual
residualsOf index residuals =
  flatMap ((owner, r) => if owner == index then [r] else []) residuals

-- a top-level clause is a value if it has params (function) or a non-expansive RHS
memberClauseIsValue : TcEnv -> (List Pat, Expr) -> Bool
memberClauseIsValue env ([], rhs) = isNonexpansive env rhs
memberClauseIsValue env (_, _) = True

-- ── polymorphic signature over an expansive body ─────────────────────────────
-- HM-CORE-SEMANTICS §1 clause 4 / DICT-SEMANTICS §4.1 G2.  A signed member whose
-- signature quantifies a type variable but whose clauses are not syntactic values
-- cannot generalize to what it declares: `sccSchemes` keeps it monomorphic, and
-- the declared scheme would otherwise be exported over a body that carries no
-- dictionary parameter — `check` narrowed it silently to its first use while
-- `build` panicked on an unbound witness (the former "point-free constrained
-- CAF", `sumOf : (Foldable t, Num a) => t a -> a ; sumOf = fold (+) 0`).  Reject
-- at the definition and name the remedy.
export
checkSigsOverExpansive : TcEnv ->
  OrdMap (List (List Pat, Expr)) ->
  List (String, Ty, List (String, Mono)) ->
  Unit
checkSigsOverExpansive env _ [] = ()
checkSigsOverExpansive env grouped ((m, ty, tvs) :: rest) =
  if not (isEmpty tvs)
    && not (allList (memberClauseIsValue env) (clausesOf m grouped)) then
    pushTypeError
      env.teDyn.dcModule
      "T-SIG-OVER-EXPANSIVE"
      (sigOverExpansiveMsg m ty)
  checkSigsOverExpansive env grouped rest

-- ── signature-too-general check ──────────────────────────────────────────────
-- After body inference, the declared signature's type variables must map to
-- DISTINCT TVar refs.  If two declared tyvars (e.g. `a` and `b` in `a -> b`)
-- collapse to the SAME TVar or become a concrete type, the body is not universal.
-- Recursive calls instantiate the written contract, so silently narrowing its
-- definition can also change dictionary arity underneath those calls.
export
checkSigsTooGeneral : ModuleCtx ->
  List (String, Ty, List (String, Mono)) ->
  Unit
checkSigsTooGeneral mctx [] = ()
checkSigsTooGeneral mctx ((m, ty, tvs) :: rest) =
  checkSigTooGeneral mctx m ty tvs
  checkSigsTooGeneral mctx rest

checkSigTooGeneral : ModuleCtx -> String -> Ty -> List (String, Mono) -> Unit
checkSigTooGeneral mctx name ty tvs =
  let tvarIds = sigTvarIds (map snd tvs)
  match groundedSignatureVariable tvs
    Some (vname, actual) =>
      pushTypeErrorOnceAt
        mctx
        "T-TYPE-TOO-GENERAL"
        (firstTyLoc ty)
        (groundedSigVarMsg vname name actual)
    None =>
      if hasDupI tvarIds then
        pushTypeError mctx "T-TYPE-TOO-GENERAL" (sigTooGeneralMsg name ty)

groundedSignatureVariable : List (String, Mono) -> Option (String, Mono)
groundedSignatureVariable [] = None
groundedSignatureVariable ((name, mono) :: rest) = match normalize mono
  TVar _ => groundedSignatureVariable rest
  actual => Some (name, actual)

-- The third way a declared variable stops being universal: a value-restricted
-- sibling in the same group shares it.  `sccSchemes` keeps that sibling
-- monomorphic (it is evaluated once, so it has one type), which fixes the signed
-- member's declared variable to that one evaluation; the group can neither
-- generalize the variable for the sibling nor default it for the signed member,
-- and publishing the sibling with the variable free would let a later use pick
-- the type after the shared value already ran.  Reported at the signature, like
-- the grounded and collapsed forms, because the contract is what the body fails.
-- A signed expansive member is `checkSigsOverExpansive`'s case and is skipped here.
export
checkSigsFixedByExpansive : TcEnv ->
  OrdMap (List (List Pat, Expr)) ->
  List ScopedMember ->
  List (String, Ty, List (String, Mono)) ->
  Unit
checkSigsFixedByExpansive env grouped members sigTvMaps =
  let fixed =
    flatMap
      (member =>
        if member.smSigned.value
          || allList
            (memberClauseIsValue env)
            (clausesOf member.smName grouped) then
          []
        else
          map (id => (id, member.smName)) (monoUnboundIds member.smMono))
      members
  match fixed
    [] => ()
    _ => checkSigsFixedBy env.teDyn.dcModule fixed sigTvMaps

checkSigsFixedBy : ModuleCtx ->
  List (Int, String) ->
  List (String, Ty, List (String, Mono)) ->
  Unit
checkSigsFixedBy mctx _ [] = ()
checkSigsFixedBy mctx fixed ((name, ty, tvs) :: rest) =
  match sigVarFixedBy fixed tvs
    Some (vname, sibling) =>
      pushTypeErrorOnceAt
        mctx
        "T-TYPE-TOO-GENERAL"
        (firstTyLoc ty)
        (siblingSharedSigVarMsg vname name sibling)
    None => ()
  checkSigsFixedBy mctx fixed rest

sigVarFixedBy : List (Int, String) ->
  List (String, Mono) ->
  Option (String, String)
sigVarFixedBy _ [] = None
sigVarFixedBy fixed ((vname, mono) :: rest) = match normalize mono
  TVar cell => match fixedSibling (tyvarId cell) fixed
    Some sibling => Some (vname, sibling)
    None => sigVarFixedBy fixed rest
  _ => sigVarFixedBy fixed rest

fixedSibling : Int -> List (Int, String) -> Option String
fixedSibling _ [] = None
fixedSibling id ((i, sibling) :: rest)
  | i == id = Some sibling
  | otherwise = fixedSibling id rest

-- #11 soundness (ALWAYS-ON): for each generalized member, record the deferred impl
-- obligations it quantifies over — an addedObls entry whose discriminating mono is a
-- TVar among the member's scheme ids becomes (iface, that id).  A signed member's
-- declared `=>` constraints come from its sig instead (registered via funConstraints);
-- but recording the inferred obligation list here too is harmless (a satisfiable
-- concrete instantiation passes; an unsatisfiable one SHOULD error).  Runs on every
-- path (NOT gated on dictEligibleSetRef), so the plain check path catches the hole.
-- SOURCING (#619 DECLARED-ONLY; supersedes the #607/#610 UNION): the predicates a
-- binding abstracts are its PRINCIPAL context, and per DICT-SEMANTICS §4 `gen`/`var`
-- an ASCRIBED signature IS that context — a contract the body must satisfy, not a
-- floor it can raise (Jones; Hall-Peyton-Jones-Wadler; Haskell).  So:
--   • SIGNED binding   → obligations come SOLELY from the declared `=>` context
--       (declaredSchemeOblsFor).  The body's inferred obligations
--       (schemeObligationsOf / forwardedVecObls) are NOT merged in — they are
--       CHECKED as entailed by the declared context (checkSigConstraintCoverage);
--       a body that genuinely needs MORE than the signature declares is a def-site
--       type error (T-MISSING-CONSTRAINT), not a silent widening.
--   • UNSIGNED binding → no declared context exists, so the inferred principal
--       context stands: direct body dispatch (schemeObligationsOf) plus any
--       constraint forwarded from a constrained callee (forwardedVecObls).  Its
--       inferred constraints are promoted, not checked (see checkSigConstraintOne).
-- #610 stays satisfied: a declared constraint the body never dispatches on
-- (`sz2 : Sz a => a -> Int; sz2 x = 9`) is still sourced from declaredSchemeOblsFor,
-- so the scheme keeps `Sz a` and every caller discharges it.  #619 additionally drops
-- the union's redundant superclass display — `when : Thenable m => …` whose body's
-- `pure` infers Applicative now renders just `Thenable a =>` (Applicative is entailed
-- by `Thenable requires Applicative`, so it is checked-and-dropped, not merged).
-- #837: [memberDefIds] carries each TOP-LEVEL member's binding id (processSCC passes
-- schemeDefIdsRef); the local/where call sites pass omEmpty so their members key under
-- the sentinel id 0.  A member absent from [memberDefIds] is a local/where binder → 0.
export
registerSchemeObligations : ModuleCtx ->
  OrdMap Int ->
  List (String, Ty, List (String, Mono)) ->
  List (IfaceRef, List Mono, Option Loc) ->
  List UObligation ->
  List (String, Scheme) ->
  Unit
registerSchemeObligations mctx _ _ _ _ [] = ()
registerSchemeObligations mctx memberDefIds sigTvMaps callObls addedObls ((m, sch) :: rest) =
  -- #838 I2 / #827: record this binding's QUANTIFIED (generalized) var ids as
  -- caller-deferrable.  A var this binding ∀-quantifies is FORWARDED to its callers
  -- (each use re-instantiates it fresh), so an end-of-run call obligation carrying
  -- that exact id is this binding's own deferred predicate — undeterminedGoalExempt
  -- defers it into the scheme instead of a spurious `Ambiguous instance` reject.
  -- CRITICAL (S0 #855-review): this uses the POST-generalization `schemeIds`, NOT the
  -- pre-generalization member monos.  A value-restricted intermediate (`let x = mk n`,
  -- `mk : Int -> a`) does NOT quantify its var (`Forall []`), so an escaped ambiguous
  -- var never enters this set and the undetermined-goal verdict rejects it (a1_greet/a1_letleak).
  mctx.mcCells.deferrableVarIds :=
    idSetInsertAll (schemeIds sch) mctx.mcCells.deferrableVarIds.value
  let obs =
    dedupVecObls (schemeOblsForMember mctx sigTvMaps callObls addedObls m sch)
  if isEmptyL obs then
    ()
  else
    let defId = optionOr 0 (omLookup m memberDefIds)
    mctx.mcCells.schemeObligationsRef :=
      ((m, defId), obs) :: mctx.mcCells.schemeObligationsRef.value
  registerSchemeObligations mctx memberDefIds sigTvMaps callObls addedObls rest

-- #619: a SIGNED binding's scheme context is EXACTLY its declared `=>` predicates
-- (authoritative); an UNSIGNED binding's is its inferred principal context (direct
-- dispatch + forwarded).  Signedness is `lookupSigTvMap … = Some` — true for any
-- signed member, including a signed binding with an EMPTY `=>` (whose declared
-- context is correctly empty), which is what distinguishes it from an unsigned one.
schemeOblsForMember : ModuleCtx ->
  List (String, Ty, List (String, Mono)) ->
  List (IfaceRef, List Mono, Option Loc) ->
  List UObligation ->
  String ->
  Scheme ->
  List VecObl
schemeOblsForMember mctx sigTvMaps callObls addedObls m sch =
  match lookupSigTvMap m sigTvMaps
    Some _ => declaredSchemeOblsFor mctx sigTvMaps m (schemeIds sch)
    None =>
      schemeObligationsOf mctx True (schemeIds sch) addedObls
        ++ forwardedVecObls mctx True (schemeIds sch) callObls

-- the DECLARED `=>` predicates of signed member [m], each as its argument vector of
-- scheme-quantified tyvar ids.  A predicate is kept only if EVERY argument is a plain
-- tyvar that instantiated to one of this scheme's quantified vars: a concrete-grounded
-- argument (`Sz Int =>`) carries no per-use obligation here, and a partial vector would
-- be a different predicate.  An unsigned member contributes nothing.
declaredSchemeOblsFor : ModuleCtx ->
  List (String, Ty, List (String, Mono)) ->
  String ->
  List Int ->
  List VecObl
declaredSchemeOblsFor mctx sigTvMaps m boundIds =
  match lookupSigTvMap m sigTvMaps
    None => []
    Some (ty, tvMap) =>
      flatMap (declaredOblOne mctx boundIds tvMap) (sigConstraintsOf ty)

declaredOblOne : ModuleCtx ->
  List Int ->
  List (String, Mono) ->
  Constraint ->
  List VecObl
declaredOblOne mctx boundIds tvMap (Constraint { constraintHead = iface, constraintArgs = args, constraintOrigin = co }) =
  -- U1b (#1482): `constraintOrigin` is the #1110 interface-OCCURRENCE identity of the
  -- `=>` predicate as written in this module's scope — the same layer `DImpl.implOrigin`
  -- is stamped in, which is what makes the goal and the impl comparable.
  let ifref = IfaceRef { irName = iface, irOrigin = co }
  match constraintArgMonos args tvMap
    None => declaredOblMixed mctx boundIds ifref tvMap args
    Some monos => match boundTyvarIds boundIds monos
      Some ids => [VecObl { voIface = ifref, voIds = ids, voArgs = [] }]
      None => []

-- #1161 SYMPTOM 2: the predicate has an argument that is not a bare tyvar, so
-- `constraintArgMonos` answers `None`, and discarding the WHOLE predicate would let
-- `Ix a Bool =>` with no `impl Ix _ Bool` anywhere reach neither the displayed scheme
-- nor any caller's obligation list: `check` would accept it at exit 0 while the call
-- dispatched to an unrelated impl.  DICT-SEMANTICS §3 makes `match(IE, Ix Int Bool)`
-- empty and the goal a missing-instance rejection, so the predicate must survive the
-- channel: record its WHOLE argument vector in `voArgs`, and the ids of its bare-tyvar
-- positions in `voIds` (one dict slot per deferred variable, unchanged cardinality).
--
-- The admission test is deliberately narrow, and every clause of it is load-bearing —
-- this is a NARROWING (programs that were accepted now reject), so an argument this
-- function admits without being able to instantiate CORRECTLY would substitute to a
-- wrong-but-CONCRETE goal, which is strictly worse than the missing one it replaces:
--   * a BARE tyvar bound by this scheme — `recordSchemeCallObligations` maps it through
--     the call's instantiation subst, exactly as the ids-only path always did;
--   * a GROUND argument (no tyvars anywhere, `monoTyvarIds` empty) — it needs no
--     substitution, so the signature's mono IS the call's mono;
--   * #1937: a STRUCTURED argument whose tyvar leaves are ALL bound by this scheme
--     (`Conv (Wrap a) b =>`) — `substOblArgs` now walks `TApp`/`TFun` structurally and
--     substitutes at each leaf, so the caller's goal is `Conv (Wrap Char) Bool`, not the
--     signature's own cell.  Before that walk existed this class HAD to be dropped, and
--     the two halves must stay together: admitting without the structural walk
--     substitutes to a wrong-but-CONCRETE goal;
--   * nothing else.  An unbound tyvar — bare, or as a leaf of a structured argument —
--     has no id to defer on and is dropped exactly as before.
-- At least one bare bound tyvar is REQUIRED: a fully ground declared context (`Sz Int =>`)
-- carries no per-use obligation on this channel and stays dropped, which keeps the
-- narrowing to the shape the issue is about.
declaredOblMixed : ModuleCtx ->
  List Int ->
  IfaceRef ->
  List (String, Mono) ->
  List Ty ->
  List VecObl
declaredOblMixed mctx boundIds ifref tvMap args =
  let monos = map (fromAstType mctx tvMap) args
  let ids = flatMap (declaredOblArgId boundIds) monos
  if isEmptyL ids
    || not (allList (declaredOblArgOk (i => containsI i boundIds)) monos) then
    []
  else
    [VecObl { voIface = ifref, voIds = ids, voArgs = monos }]

-- the monos a predicate's arguments resolve to under a tyvar-name -> mono map, in
-- declaration order; None if ANY argument is not a plain tyvar or is absent from the
-- map (a partial vector is a DIFFERENT predicate, so the whole thing is dropped).
-- Shared by the declared-context sourcing and recordSigConstraintArgs.
constraintArgMonos : List Ty -> List (String, Mono) -> Option (List Mono)
constraintArgMonos [] _ = Some []
constraintArgMonos (a :: rest) tvMap = match constraintArgMono a tvMap
  None => None
  Some mono => map (mono :: _) (constraintArgMonos rest tvMap)

-- the mono ONE predicate argument resolves to: None unless it is a plain tyvar
-- present in [tvMap] (a concrete-grounded argument like `Sz Int =>` carries no
-- per-use obligation here).
constraintArgMono : Ty -> List (String, Mono) -> Option Mono
constraintArgMono a tvMap = match constraintArgVarName a
  None => None
  Some v => lookupAssoc v tvMap

lookupSigTvMap : String ->
  List (String, Ty, List (String, Mono)) ->
  Option (Ty, List (String, Mono))
lookupSigTvMap _ [] = None
lookupSigTvMap m ((n, ty, tvMap) :: rest)
  | m == n = Some (ty, tvMap)
  | otherwise = lookupSigTvMap m rest

-- #242: routed through the canonical O(n·log n) `support.util.dedupBy` (was a
-- private O(n²) `List`-as-a-set scan).  The iface name is length-prefixed and
-- the id VECTOR is comma-joined — ints carry no comma, so the encoding is
-- injective over both components.
-- Keyed on the SPELLING (`voIface.irName`), deliberately: this dedup decides what a
-- binding's DISPLAYED and re-instantiated scheme context is, and keying it on identity
-- would split one printed `Num a =>` into two.  U1b (#1482) carries identity through the
-- payload without changing what counts as the same entry.
dedupVecObls : List VecObl -> List VecObl
dedupVecObls xs = dedupBy vecOblKey xs

-- #1161: the GROUND half of the vector joins the key.  `(Ix a Bool, Ix a Char)` is two
-- predicates sharing one interface AND one id vector — without the ground positions the
-- dedup would collapse them into one, silently dropping half a declared context.  An
-- ids-only entry contributes a constant empty suffix, so its key is order-equivalent to
-- the pre-widening one.
-- S-nonlead-arg-identity (#1904) made `oblArgKey` structural and id-carrying.  On THIS
-- channel that is mostly redundant — `voIds` already carries every position's id — but
-- not entirely: `voIds` is a FLATTENED concatenation with no position boundaries, so
-- `Ix (Pair a b) (Pair c d)` and `Ix (Pair a c) (Pair b d)` shared both `voIds` and the
-- old head-name-only suffix.  The partition this key induces is strictly FINER than
-- before and identical on bare-tyvar vectors (the shape `dedupVecObls`' spelling caveat
-- above is about), so a printed `Num a =>` still does not split.
vecOblKey : VecObl -> String
vecOblKey o =
  "\{lenKey o.voIface.irName}\{joinWith "," (map intToString o.voIds)}|\{joinWith "," (map oblArgKey o.voArgs)}"

-- membership of ONE vector in the DECLARED set (reportUncoveredVec) — not a
-- dedup, and the declared set is a handful of entries, so it stays a scan.
containsVecObl : VecObl -> List VecObl -> Bool
containsVecObl _ [] = False
containsVecObl o (o2 :: rest) =
  sameIfaceDecl o.voIface o2.voIface && o.voIds == o2.voIds
    || containsVecObl o rest

-- the (iface, var-id VECTOR) entries of the obligations whose discriminating monos are
-- all quantified ids of this scheme.  Deduped on (iface, ids).
schemeObligationsOf : ModuleCtx ->
  Bool ->
  List Int ->
  List UObligation ->
  List VecObl
schemeObligationsOf mctx generalizing boundIds obls =
  flatMap
    (vecOblOfPred mctx generalizing boundIds)
    (flatMap (oblPredOf mctx.mcGraph) obls)

-- a single recorded predicate contributes ONE joint (iface, ids) entry iff EVERY one of
-- its dispatch monos is a bound tyvar of the scheme.  Before #607 the multi-mono case
-- fell into a `_ => []` wildcard and the obligation was DISCARDED — which is why an
-- unsatisfiable `Ix a i =>` reached neither the displayed scheme nor any caller's
-- obligation list, and `check` accepted it at exit 0 while the built binary did raw
-- pointer arithmetic.
-- #1549: a predicate whose argument vector is NOT all bare bound tyvars is first REDUCED
-- by §3 entailment (`residualVecObls`), and the residual that reduction leaves over this
-- scheme's own quantified vars is deferred here.  Dropping it outright would sever
-- `nest x = tagOf (Wrap x)` from its `Tag a` (DICT-SEMANTICS §4 `gen` / §4.2 OD2).
vecOblOfPred : ModuleCtx ->
  Bool ->
  List Int ->
  (IfaceRef, List Mono, Option Loc) ->
  List VecObl
vecOblOfPred mctx generalizing boundIds (iface, ds, loc) =
  match boundTyvarIds boundIds ds
    Some ids => [VecObl { voIface = iface, voIds = ids, voArgs = [] }]
    None => residualVecObls mctx generalizing boundIds iface ds loc

-- ── #1549: residual reduction at `gen` ──────────────────────────────────────
-- DICT-SEMANTICS §4 `gen` makes a binding's principal context `P'` = "the predicates
-- DEFERRED to this binding", and §4.2 OD2 says a non-ground predicate defers to the
-- binder that quantifies its variables.  A predicate like `Tag (Wrap t)` is neither
-- deferrable as written (its head is concrete, so it is not `P'`) nor dischargeable
-- (its `t` is generalizable): §3 `inst` reduces it against `impl Tag (Wrap a) requires
-- Tag a`, and the RESIDUAL `Tag t` is what defers.  Reducing here is what makes the
-- deferral OD2 already performs on the CHECK side (`undeterminedGoalExempt`
-- defers `Tag t` "to the caller") actually reach a caller: without the residual in the
-- scheme there is no context for `(var)` to discharge and no `λd̄.` for `gen` to
-- abstract, so `check` was silent, `run` fell back to declaration order, and the built
-- binary read a dict word that was never passed (issue 1549, S0).
--
-- Deliberately the FALLBACK arm only: when every argument is already a bound tyvar the
-- predicate IS its own residual and the direct path above owns it, so this returns []
-- for that case and the behaviour of every predicate that reached a VecObl before is
-- unchanged.  A predicate mentioning none of this scheme's quantified vars can have no
-- residual over them either (grounding is monotone), and is rejected by the cheap guard
-- before any impl lookup — that keeps the common ground obligation (`Display String`)
-- off the reduction path entirely.
--
-- [loc] is load-bearing and is not decoration: dropping it moves a diagnostic.
-- `residualPredsOf` reaches `findMatchingImplReqsU`, which asks the min⊑ selector WHICH
-- impl matched — so this is a SECOND goal-posing site outside the five resolver drains
-- (the first is `checkNestedReqs`, whose header says the same thing).  When the goal is
-- ambiguous the selector calls `reportAmbiguousOverlap`, which reads the context's `sxSite` and
-- falls back to the record's `mcLoc` when it is `None`.  At a generalized group's close
-- that is the construct around the close, not the site that recorded the
-- predicate; and because `pushTypeErrorOnceAt` dedups on the message, that badly-located
-- push WINS over the well-located one a later resolver drain would emit.
-- MEASURED on `test/dict_fixtures/s6-c1-rigid-goal-no-call-discriminator.mdk`
-- (`firstRow xss = index xss 0`): with the recorded loc dropped, the caret moved off the
-- `index` call at 29:15 onto the literal `0` at 29:25 — same code, same message, worse
-- span, and NO gate saw it because the dict-semantics gate asserted the code alone.
-- So hand the reduction a context whose `sxSite` is the obligation's OWN snapshotted span,
-- as `checkNestedReqs` does; a walk outside a drain gets no site and the selector falls
-- back rather than inheriting a stale span.
residualVecObls : ModuleCtx ->
  Bool ->
  List Int ->
  IfaceRef ->
  List Mono ->
  Option Loc ->
  List VecObl
residualVecObls mctx generalizing boundIds iface ds loc =
  map
    keepBoundResidual
    (residualBoundPreds (siteFor mctx) generalizing boundIds iface ds loc)

-- `voArgs` is the ids-only `[]` for an all-bare residual and the whole vector for a
-- mixed one: the same split `declaredOblOne` makes between its own arm and
-- `declaredOblMixed`, so the OBLIGATION channel's readers (`substVecOblArgs`,
-- `dedupVecObls`, `reportUncoveredVec`) see, for each shape, precisely the shape they
-- have always seen from the declared channel.  Every residual that reached a `VecObl`
-- before this change is all-bare by construction (it came through `boundTyvarIds`), so
-- its entry is byte-identical; the mixed entries are the ones #1905 adds.
-- The argument vector the DICT channel consumes (`funConstraintArgsRef`) is the third
-- component of the triple and is unaffected by this projection.
keepBoundResidual : (IfaceRef, List Int, List Mono) -> VecObl
keepBoundResidual (iface, ids, args) =
  VecObl { voIface = iface, voIds = ids, voArgs = residualOblArgs ids args }

-- #1937: the test is not `listLen ids == listLen args`.  `declaredOblArgId` contributes
-- one id per bound leaf, so a STRUCTURED argument makes equal lengths not mean
-- "every position is a bare tyvar": `Conv (Wrap a) b` has two ids for two arguments and
-- would take the ids-only `[]` arm — instantiating through `substMonos o.voIds` to the goal `Conv a b`,
-- i.e. silently DROPPING the `Wrap`.  Ask the structural question directly instead:
-- every position a bare tyvar, and each of them one of [ids] (a bare variable the
-- scheme does not quantify contributes no id, and the ids-only arm would drop it).
residualOblArgs : List Int -> List Mono -> List Mono
residualOblArgs ids args
  | allList isBareTyvarMono args && listLen ids == listLen args = []
  | otherwise = args

-- shatter vector obligations into (interface declaration, id) pairs — the currency of the
-- coverage subset test.  See checkSigConstraintCoverage's header.
-- A signed body's inferred predicate is covered only by the same interface declaration;
-- same spelling from a foreign module is not evidence.
pairsOfVecObls : List VecObl -> List (IfaceRef, Int)
pairsOfVecObls [] = []
pairsOfVecObls (o :: rest) =
  map (id => (o.voIface, id)) o.voIds ++ pairsOfVecObls rest

-- ── signature-constraint soundness check ─────────────────────────────────────
-- For each SIGNED member, the interface constraints its body INFERS on the
-- member's own quantified vars must be covered by the DECLARED `=>` context,
-- closed under the interface `requires` (superclass) graph.  An uncovered
-- inferred constraint ⇒ def-site type_error (the constraint analogue of
-- checkEffectEscape).  Under #619 DECLARED-ONLY this is the SOLE enforcement of the
-- body's inferred obligations: registerSchemeObligations does not merge them into
-- the scheme, so a body needing more than its signature declares is caught HERE or
-- silently severed.  The inferred obligations are the UNION of the flat-path
-- (schemeObligationsOf over addedObls), the FORWARDED path (forwardedVecObls over the
-- constrained-callee call delta — #619: a signed forwarder that under-declares is not
-- backstopped by the union, so it must be checked here), and the marked-path
-- (inferredConstraintIds + ifaceForInferredId) sources — a return-position-method
-- constraint lands only in the last.
-- #607: the PAIR test runs in (iface, var-id) currency on both sides — a multi-param
-- predicate is shattered per argument before the subset test (pairsOfVecObls /
-- declaredPairsFor).  Shattering both sides is sound for a COVERAGE (subset) question
-- — declared `Ix a i` covers inferred `Ix a` and `Ix i` — and it makes the reject
-- direction live at n>=2.  On its own it UNDER-rejects the exotic cross-pairing
-- (declared `Ix a b, Ix c d` vs inferred `Ix a d`: all four pairs a,b,c,d are declared,
-- so pair coverage passes though the JOINT `Ix a d` is undeclared).
-- #619/#607 item 4: reportUncoveredVec closes that gap — an inferred JOINT vector
-- (arity >= 2) whose EXACT argument vector is not among the declared vectors
-- (vector-valued superclass closure, censusSuperCloseVec) is
-- uncovered, and is reported when the pair test did not already flag one of its args.
export
checkSigConstraintCoverage : ModuleCtx ->
  List ConstraintReg ->
  List (String, Ty) ->
  List (String, Ty, List (String, Mono)) ->
  List (IfaceRef, List Mono, Option Loc) ->
  List UObligation ->
  List (String, Scheme) ->
  Unit
checkSigConstraintCoverage mctx _ _ _ _ _ [] = ()
checkSigConstraintCoverage mctx regs sigs sigTvMaps callObls addedObls ((m, sch) :: rest) =
  checkSigConstraintOne mctx regs sigs sigTvMaps callObls addedObls m sch
  checkSigConstraintCoverage mctx regs sigs sigTvMaps callObls addedObls rest

checkSigConstraintOne : ModuleCtx ->
  List ConstraintReg ->
  List (String, Ty) ->
  List (String, Ty, List (String, Mono)) ->
  List (IfaceRef, List Mono, Option Loc) ->
  List UObligation ->
  String ->
  Scheme ->
  Unit
checkSigConstraintOne mctx regs sigs sigTvMaps callObls addedObls m sch =
  match omLookup m mctx.mcCells.sigTyMapRef.value
    None => ()  -- unsigned member: its inferred constraints are promoted, not checked
    Some _ =>
      let declaredPairs =
        censusSuperClose mctx.mcGraph (declaredPairsFor m regs)
      let boundIds = schemeIds sch
      let bodyVecs =
        quantifiedVecObls
          boundIds
          (schemeObligationsOf mctx False boundIds addedObls)
      let fwdVecs =
        quantifiedVecObls
          boundIds
          (forwardedVecObls mctx False boundIds callObls)
      let inferredB = inferredIfacePairs mctx m boundIds
      let inferred =
        dedupIfacePairs
          (pairsOfVecObls bodyVecs ++ pairsOfVecObls fwdVecs ++ inferredB)
      reportUncovered mctx m sigTvMaps declaredPairs inferred
      let declaredVecs =
        censusSuperCloseVec
          mctx.mcGraph
          (declaredSchemeOblsFor mctx sigTvMaps m boundIds)
      reportUncoveredVec
        mctx
        m
        sigTvMaps
        declaredPairs
        declaredVecs
        (bodyVecs ++ fwdVecs)

-- The vectors over [boundIds] alone.  A signature can declare no predicate on a
-- variable it does not quantify, so a residual that mentions one is never this
-- check's to cover: its verdict is the undetermined goal's, or `checkSigVarGoals`'.
quantifiedVecObls : List Int -> List VecObl -> List VecObl
quantifiedVecObls boundIds vecs =
  filterList
    (o =>
      allList (id => containsI id boundIds) (flatMap monoUnboundIds o.voArgs))
    vecs

-- inferred (iface, id) pairs from the marked path: each inferred constraint var id
-- paired with its recovered iface (skip an id whose iface can't be recovered).
inferredIfacePairs : ModuleCtx -> String -> List Int -> List (IfaceRef, Int)
inferredIfacePairs mctx m boundIds =
  flatMap (pairIface mctx m) (inferredConstraintIds mctx m boundIds)

pairIface : ModuleCtx -> String -> Int -> List (IfaceRef, Int)
pairIface mctx m id =
  let ir = ifaceForInferredId mctx m id
  match ir.irName
    "" => []
    _ => [(ir, id)]

-- the declared (iface, id) constraint pairs of member m: each declared constraint
-- mono normalized to its surviving tyvar id (single-param shape; concrete-grounded
-- constraints — no tyvar — carry no dict slot and are skipped).
declaredPairsFor : String -> List ConstraintReg -> List (IfaceRef, Int)
declaredPairsFor m regs = flatMap declaredPairOne (regIfaceMonosFor m regs)

-- #1161 (F-3a-ii): a reg is a triple, so its (iface, mono) component needs a named
-- accessor (`snd`/`lookupAssoc` do not apply).  Both spellings — first-match by name,
-- and the whole-list projection — are what the two consumers need.
regIfaceMonosFor : String -> List ConstraintReg -> List (IfaceRef, List Mono)
regIfaceMonosFor _ [] = []
regIfaceMonosFor m (reg :: rest)
  | m == reg.crName = reg.crIfaceMonos
  | otherwise = regIfaceMonosFor m rest

declaredPairOne : (IfaceRef, List Mono) -> List (IfaceRef, Int)
declaredPairOne (iface, monos) = map (id => (iface, id)) (abstractSlotIds monos)

-- Superclass closure over declared (iface, id) slots, so prelude super chains
-- (Applicative requires Mappable, Thenable requires Applicative, …) are included.  It
-- only feeds the read-only subset test; no dict slot comes from it.
censusSuperClose : GraphCtx -> List (IfaceRef, Int) -> List (IfaceRef, Int)
censusSuperClose gctx declared =
  map
    (n => (n.superIface, n.superPayload))
    (superClosure
      (superLookup gctx)
      censusSuperStep
      (iface id => ifacePairKey (iface, id))
      declared)

-- A super shares the sub-predicate's lead id (0 for a nullary super) when every one of
-- its parameters is one of the sub's type parameters.
censusSuperStep : List String -> Int -> Super -> Option Int
censusSuperStep typarams id (Super { superParams = params, ... })
  | not (all (p => contains p typarams) params) = None
  | isEmptyL params = Some 0
  | otherwise = Some id

-- #619/#607 item 4: VECTOR-valued superclass closure over declared constraint vectors.
-- Unlike censusSuperClose (which collapses each predicate to per-arg pairs), this
-- preserves the whole argument vector, so an inferred JOINT predicate can be tested for
-- membership as a unit — the exotic cross-pairing `Ix a d` is NOT a member of
-- {`Ix a b`, `Ix c d`} even though every one of its args appears in some declared
-- predicate.  Ungated, like censusSuperClose.  The interface's type parameters map
-- POSITIONALLY onto a predicate's ids, so a multi-param super carries the right per-arg
-- ids; a super's ground argument positions are not recovered.
censusSuperCloseVec : GraphCtx -> List VecObl -> List VecObl
censusSuperCloseVec gctx declared =
  map
    vecOblOfNode
    (superClosure
      (superLookup gctx)
      censusVecSuperStep
      (iface payload =>
        vecOblKey
          (vecOblOfNode SuperNode {
            superPath = [],
            superIface = iface,
            superPayload = payload,
          }))
      (map (o => (o.voIface, (o.voIds, o.voArgs))) declared))

censusVecSuperStep : List String ->
  (List Int, List Mono) ->
  Super ->
  Option (List Int, List Mono)
censusVecSuperStep typarams (ids, _) (Super { superParams = params, ... }) =
  map (mapped => (mapped, [])) (mapAll (p => lookupPos p typarams ids) params)

vecOblOfNode : SuperNode (List Int, List Mono) -> VecObl
vecOblOfNode n =
  let (ids, args) = n.superPayload
  VecObl { voIface = n.superIface, voIds = ids, voArgs = args }

-- one type_error per inferred JOINT vector (arity >= 2) whose exact vector the declared
-- (super-closed) set does not contain.  Skipped when the pair test already flagged one
-- of the vector's args (allPairsIn False) — so a genuinely absent constraint reports
-- ONCE, via reportUncovered, and only the cross-pairing (all args present, joint
-- vector absent) reports here.  Arity < 2 is fully handled by the pair test.
reportUncoveredVec : ModuleCtx ->
  String ->
  List (String, Ty, List (String, Mono)) ->
  List (IfaceRef, Int) ->
  List VecObl ->
  List VecObl ->
  Unit
reportUncoveredVec mctx _ _ _ _ [] = ()
reportUncoveredVec mctx m sigTvMaps declaredPairs declaredVecs (o :: rest) =
  if listLen o.voIds < 2 then
    ()
  else if containsVecObl o declaredVecs then
    ()
  else if not (allPairsIn o.voIface o.voIds declaredPairs) then
    ()
  else
    pushTypeError
      mctx
      "T-MISSING-CONSTRAINT"
      (missingConstraintVecMsg
        m
        o.voIface.irName
        (map (varNameForId sigTvMaps m) o.voIds))
  reportUncoveredVec mctx m sigTvMaps declaredPairs declaredVecs rest

allPairsIn : IfaceRef -> List Int -> List (IfaceRef, Int) -> Bool
allPairsIn iface ids declaredPairs =
  allList (id => containsIfacePair (iface, id) declaredPairs) ids

-- one type_error per inferred (iface, id) not covered by the declared-closed set.
reportUncovered : ModuleCtx ->
  String ->
  List (String, Ty, List (String, Mono)) ->
  List (IfaceRef, Int) ->
  List (IfaceRef, Int) ->
  Unit
reportUncovered mctx _ _ _ [] = ()
reportUncovered mctx m sigTvMaps declared ((iface, id) :: rest) =
  if containsIfacePair (iface, id) declared then
    ()
  else
    pushTypeError
      mctx
      "T-MISSING-CONSTRAINT"
      (missingConstraintMsg m iface.irName (varNameForId sigTvMaps m id))
  reportUncovered mctx m sigTvMaps declared rest

containsIfacePair : (IfaceRef, Int) -> List (IfaceRef, Int) -> Bool
containsIfacePair _ [] = False
containsIfacePair (i, d) ((i2, d2) :: rest) =
  sameIfaceDecl i i2 && d == d2 || containsIfacePair (i, d) rest

dedupIfacePairs : List (IfaceRef, Int) -> List (IfaceRef, Int)
dedupIfacePairs xs = dedupBy ifacePairKey xs

ifacePairKey : (IfaceRef, Int) -> String
ifacePairKey (iface, id) =
  regKeyRender (regKeyOfTab (oblIfaceKey iface)) ++ intToString id

export
declRefNames : Decl -> List String
declRefNames (DAttrib _ d) = declRefNames d
declRefNames (DFunDef _ _ _ body _ _) = allEVars body
declRefNames (DProp _ _ _ body) = allEVars body
declRefNames (DTest _ _ body) = allEVars body
declRefNames (DLetGroup _ binds) = flatMap letBindEVars binds
declRefNames (DImpl { methods, ... }) = flatMap implMethodEVars methods
declRefNames (DInterface { methods, ... }) = flatMap ifaceMethodEVars methods
declRefNames _ = []

implMethodEVars : ImplMethod -> List String
implMethodEVars (ImplMethod _ _ body) = allEVars body

ifaceMethodEVars : IfaceMethod -> List String
ifaceMethodEVars (IfaceMethod _ _ d _) = match d
  Some (MethodDefault _ body) => allEVars body
  None => []
# DESUGAR
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "OblProjection" true) (mem "GoalReach" true) (mem "BindingRole" true) (mem "Predicate" true) (mem "UObligation" true) (mem "ConstraintReg" false) (mem "DynCtx" false) (mem "GraphCtx" false) (mem "ImplRow" false) (mem "ModuleCtx" false) (mem "ReqWalk" false) (mem "ScopedMember" false) (mem "siteFor" false) (mem "TcEnv" false) (mem "ReqStep" true))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "abstractSlotIds" false) (mem "anyMember" false) (mem "authIdsIn" false) (mem "boundTyvarIds" false) (mem "cohApply" false) (mem "containsI" false) (mem "declaredOblArgId" false) (mem "declaredOblArgOk" false) (mem "hasDupI" false) (mem "headsUnifier" false) (mem "isBareTyvarMono" false) (mem "monoUnboundIds" false) (mem "monoVarCells" false) (mem "monoVectorClosed" false) (mem "oblArgKey" false) (mem "patVarsListTc" false) (mem "patVarsTc" false) (mem "qualifierAuthIds" false) (mem "schemeIds" false) (mem "schemeMono" false) (mem "sigCellsOf" false) (mem "sigTvarIds" false) (mem "tyvarId" false) (mem "tyVarNames" false) (mem "unrigidSig" false))))
(DUse false (UseGroup ("types" "tc_diag_text") ((mem "annotTooGeneralMsg" false) (mem "groundedSigVarMsg" false) (mem "letRecNonFunctionMsg" false) (mem "missingConstraintMsg" false) (mem "missingConstraintVecMsg" false) (mem "sigOverExpansiveMsg" false) (mem "sigTooGeneralMsg" false) (mem "siblingSharedSigVarMsg" false) (mem "varNameForId" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "mctxAtIfSome" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "extendLocalVar" false) (mem "funClausePair" false) (mem "lookupCtor" false) (mem "namesToSet" false) (mem "oblIfaceKey" false) (mem "sameIfaceDecl" false) (mem "seedAlphaLets" false) (mem "superLookup" false))))
(DUse false (UseGroup ("types" "tc_diag") ((mem "boundaryOwnsOpen" false) (mem "pushTypeError" false) (mem "pushTypeErrorAt" false) (mem "pushTypeErrorOnceAt" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "generalizeBindingDeclared" false) (mem "lowerAuthLevels" false) (mem "lowerRowLevels" false) (mem "lowerToCurrent" false) (mem "unifyInto" false) (mem "wantAuthorityWith" false))))
(DUse false (UseGroup ("types" "tc_decls_types") ((mem "fromAstType" false) (mem "sigConstraintsOf" false))))
(DUse false (UseGroup ("types" "tc_decls") ((mem "constraintNameMonos" false))))
(DUse false (UseGroup ("types" "tc_solve_givens") ((mem "goalGivenAt" false))))
(DUse false (UseGroup ("types" "tc_solve_entail") ((mem "freshRowHeadsTvs" false) (mem "goalCandidates" false) (mem "goalIsProjection" false) (mem "goalReach" false) (mem "goalRows" false) (mem "selectedRowReqMatch" false) (mem "reqWalkEnter" false) (mem "reqWalkMemo" false) (mem "reqWalkSeed" false))))
(DUse false (UseGroup ("types" "tc_solve") ((mem "goalVarsAllHeld" false) (mem "reqToObligation" false) (mem "uOblArgs" false) (mem "noteWalkGoalFollowed" false) (mem "solvedCleanly" false) (mem "walkGoalFollowed" false))))
(DUse false (UseGroup ("types" "tc_solve_check") ((mem "callPredOf" false) (mem "ifaceForInferredId" false) (mem "inferredConstraintIds" false) (mem "oblPredOf" false) (mem "residualBoundPreds" false) (mem "undeterminedGoalExempt" false) (mem "prerequisiteOnWalk" false))))
(DUse false (UseGroup ("types" "tc_effects") ((mem "clausesAt" false) (mem "clausesOf" false))))
(DUse false (UseGroup ("types" "tc_occurrence") ((mem "ctorHeadShaped" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "Constraint" true) (mem "Decl" true) (mem "DoStmt" true) (mem "Expr" true) (mem "FieldAssign" true) (mem "FunClause" true) (mem "Guard" true) (mem "GuardArm" true) (mem "IfaceMethod" true) (mem "ImplMethod" true) (mem "InterpPart" true) (mem "LetBind" true) (mem "Loc" true) (mem "MethodDefault" true) (mem "Pat" true) (mem "Require" true) (mem "Section" true) (mem "Super" true) (mem "Ty" true) (mem "firstTyLoc" false) (mem "letBindName" false))))
(DUse false (UseGroup ("types" "repr") ((mem "AuthResidual" true) (mem "IfaceRef" true) (mem "Mono" true) (mem "Scheme" true) (mem "VecObl" true) (mem "normalize" false))))
(DUse false (UseGroup ("types" "effect_bindings") ((mem "BindingSummary" true))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffRow" true) (mem "pureRow" false))))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omSize" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("types" "effect_solver") ((mem "ScopeRoles" true))))
(DUse false (UseGroup ("types" "superclass") ((mem "SuperNode" true) (mem "lookupPos" false) (mem "mapAll" false) (mem "superClosure" false))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "anyList" false) (mem "contains" false) (mem "dedup" false) (mem "dedupBy" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isSome" false) (mem "joinWith" false) (mem "lenKey" false) (mem "listLen" false) (mem "lookupAssoc" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "exprSpanLoc" false))))
(DUse false (UseGroup ("types" "registry") ((mem "regKeyOfTab" false) (mem "regKeyRender" false))))
(DUse false (UseGroup ("support" "scc") ((mem "tarjanSCCs" false))))
(DUse false (UseAlias ("map") "IdMap"))
(DTypeSig false "idSetInsertAll" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "idSetInsertAll" ((PList) (PVar "m")) (EVar "m"))
(DFunDef false "idSetInsertAll" ((PCons (PVar "i") (PVar "rest")) (PVar "m")) (EApp (EApp (EVar "idSetInsertAll") (EVar "rest")) (EApp (EApp (EApp (EVar "IdMap.set") (EVar "i")) (ELit LUnit)) (EVar "m"))))
(DTypeSig true "isNonexpansive" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "isNonexpansive" ((PVar "env") (PCon "ELoc" PWild (PVar "e"))) (EApp (EApp (EVar "isNonexpansive") (EVar "env")) (EVar "e")))
(DFunDef false "isNonexpansive" ((PVar "env") (PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EApp (EVar "isNonexpansive") (EVar "env")) (EVar "e")))
(DFunDef false "isNonexpansive" ((PVar "env") (PCon "ELit" PWild)) (EVar "True"))
(DFunDef false "isNonexpansive" ((PVar "env") (PCon "EVar" PWild)) (EVar "True"))
(DFunDef false "isNonexpansive" ((PVar "env") (PCon "EVarId" PWild PWild)) (EVar "True"))
(DFunDef false "isNonexpansive" ((PVar "env") (PCon "EMethodAt" PWild PWild PWild)) (EVar "True"))
(DFunDef false "isNonexpansive" ((PVar "env") (PCon "EDictAt" PWild PWild)) (EVar "True"))
(DFunDef false "isNonexpansive" ((PVar "env") (PCon "EMethodRef" PWild)) (EVar "True"))
(DFunDef false "isNonexpansive" ((PVar "env") (PCon "ELam" PWild PWild)) (EVar "True"))
(DFunDef false "isNonexpansive" ((PVar "env") (PCon "EAnnot" (PVar "e") PWild)) (EApp (EApp (EVar "isNonexpansive") (EVar "env")) (EVar "e")))
(DFunDef false "isNonexpansive" ((PVar "env") (PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EApp (EVar "isNonexpansive") (EVar "env")) (EVar "e")))
(DFunDef false "isNonexpansive" ((PVar "env") (PCon "ETuple" (PVar "es"))) (EApp (EApp (EVar "allList") (EApp (EVar "isNonexpansive") (EVar "env"))) (EVar "es")))
(DFunDef false "isNonexpansive" ((PVar "env") (PCon "EListLit" (PVar "es"))) (EApp (EApp (EVar "allList") (EApp (EVar "isNonexpansive") (EVar "env"))) (EVar "es")))
(DFunDef false "isNonexpansive" ((PVar "env") (PAs "app" (PCon "EApp" PWild PWild))) (EApp (EApp (EVar "isCtorAppSpine") (EVar "env")) (EVar "app")))
(DFunDef false "isNonexpansive" ((PVar "env") (PCon "ERecordCreate" PWild (PVar "fs"))) (EApp (EApp (EVar "allList") (ELam ((PVar "fa")) (EMatch (EVar "fa") (arm (PCon "FieldAssign" PWild (PVar "e")) () (EApp (EApp (EVar "isNonexpansive") (EVar "env")) (EVar "e")))))) (EVar "fs")))
(DFunDef false "isNonexpansive" ((PVar "env") PWild) (EVar "False"))
(DTypeSig false "isCtorAppSpine" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "isCtorAppSpine" ((PVar "env") (PCon "ELoc" PWild (PVar "e"))) (EApp (EApp (EVar "isCtorAppSpine") (EVar "env")) (EVar "e")))
(DFunDef false "isCtorAppSpine" ((PVar "env") (PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EApp (EVar "isCtorAppSpine") (EVar "env")) (EVar "e")))
(DFunDef false "isCtorAppSpine" ((PVar "env") (PCon "EApp" (PVar "f") (PVar "x"))) (EBinOp "&&" (EApp (EApp (EVar "isCtorAppSpine") (EVar "env")) (EVar "f")) (EApp (EApp (EVar "isNonexpansive") (EVar "env")) (EVar "x"))))
(DFunDef false "isCtorAppSpine" ((PVar "env") (PCon "EVar" (PVar "name"))) (EApp (EApp (EVar "isDeclaredCtorHead") (EVar "env")) (EVar "name")))
(DFunDef false "isCtorAppSpine" ((PVar "env") (PCon "EVarId" (PVar "name") PWild)) (EApp (EApp (EVar "isDeclaredCtorHead") (EVar "env")) (EVar "name")))
(DFunDef false "isCtorAppSpine" ((PVar "env") PWild) (EVar "False"))
(DTypeSig false "isDeclaredCtorHead" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isDeclaredCtorHead" ((PVar "env") (PVar "name")) (EBinOp "&&" (EBinOp "&&" (EBinOp "/=" (EVar "name") (ELit (LString "Ref"))) (EApp (EVar "ctorHeadShaped") (EVar "name"))) (EApp (EVar "isSome") (EApp (EApp (EVar "lookupCtor") (EVar "env")) (EVar "name")))))
(DTypeSig true "genBindingRestricted" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "AuthResidual")) (TyFun (TyCon "Bool") (TyFun (TyCon "EffRow") (TyFun (TyCon "Mono") (TyCon "Scheme"))))))))
(DFunDef false "genBindingRestricted" ((PVar "dyn") (PVar "declared") (PVar "residual") (PVar "isValue") (PVar "force") (PVar "t")) (EIf (EVar "isValue") (EApp (EApp (EApp (EApp (EApp (EVar "generalizeBindingDeclared") (EVar "dyn")) (EVar "declared")) (EVar "residual")) (EVar "force")) (EVar "t")) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EVar "lowerToCurrent") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "t"))) (DoExpr (EApp (EApp (EVar "lowerRowLevels") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "currentLevel") "value")) (EVar "force"))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PVar "r")) (EBlock (DoExpr (EApp (EApp (EVar "lowerAuthLevels") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "currentLevel") "value")) (EFieldAccess (EVar "r") "arLower"))) (DoExpr (EApp (EApp (EVar "lowerAuthLevels") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "currentLevel") "value")) (EFieldAccess (EVar "r") "arUpper"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "wantAuthorityWith") (EFieldAccess (EVar "dyn") "dcModule")) (EFieldAccess (EVar "r") "arExact")) (EFieldAccess (EVar "r") "arLower")) (EFieldAccess (EVar "r") "arUpper")))))) (EVar "residual"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Forall") (EListLit)) (EListLit)) (EListLit)) (EListLit)) (EVar "force")) (EVar "t")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "exprLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "exprLoc" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "exprLoc" ((PCon "EDoOrigin" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "exprLoc" (PWild) (EVar "None"))
(DTypeSig false "constraintArgVarName" (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "constraintArgVarName" ((PCon "TyVar" (PVar "v"))) (EApp (EVar "Some") (EVar "v")))
(DFunDef false "constraintArgVarName" (PWild) (EVar "None"))
(DTypeSig true "checkRecursiveValue" (TyFun (TyCon "DynCtx") (TyFun (TyCon "BindingSummary") (TyCon "Unit"))))
(DFunDef false "checkRecursiveValue" ((PVar "dyn") (PVar "owned")) (EApp (EApp (EApp (EApp (EVar "unifyInto") (EVar "dyn")) (EVar "True")) (EFieldAccess (EVar "owned") "bsRecursiveValue")) (EFieldAccess (EVar "owned") "bsValue")))
(DTypeSig true "checkAnnotTooGeneral" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Unit")))))
(DFunDef false "checkAnnotTooGeneral" ((PVar "mctx") (PVar "ty") (PVar "resolved")) (EBlock (DoLet false false (PVar "ids") (EApp (EVar "sigTvarIds") (EVar "resolved"))) (DoExpr (EIf (EBinOp "||" (EBinOp "<" (EApp (EVar "listLen") (EVar "ids")) (EApp (EVar "listLen") (EVar "resolved"))) (EApp (EVar "hasDupI") (EVar "ids"))) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-TYPE-TOO-GENERAL"))) (EApp (EVar "annotTooGeneralMsg") (EVar "ty"))) (ELit LUnit)))))
(DTypeSig true "letGroupComponents" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "LetBind")))))
(DFunDef false "letGroupComponents" ((PVar "binds")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds"))) (DoLet false false (PVar "nameSet") (EApp (EApp (EVar "namesToSet") (EVar "names")) (EVar "omEmpty"))) (DoExpr (EIf (EBinOp "<" (EApp (EVar "omSize") (EVar "nameSet")) (EApp (EVar "listLen") (EVar "names"))) (EListLit (EVar "binds")) (EBlock (DoLet false false (PVar "grouped") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PCon "LetBind" (PVar "n") (PVar "clauses") PWild PWild)) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EApp (EApp (EVar "map") (EVar "funClausePair")) (EVar "clauses"))) (EVar "m")))) (EVar "omEmpty")) (EVar "binds"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "component")) (EBlock (DoLet false false (PVar "members") (EApp (EApp (EVar "namesToSet") (EVar "component")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "letBindName") (EVar "b"))) (EVar "members")))) (EVar "binds")))))) (EApp (EApp (EVar "tarjanSCCs") (EVar "names")) (EApp (EApp (EVar "depGraphMap") (EVar "names")) (EVar "grouped"))))))))))
(DTypeSig false "isSyntacticLambda" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isSyntacticLambda" ((PCon "ELam" PWild PWild)) (EVar "True"))
(DFunDef false "isSyntacticLambda" (PWild) (EVar "False"))
(DTypeSig true "checkLetRecDecls" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "checkLetRecDecls" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "checkLetRecDecls" ((PVar "mctx") (PCons (PCon "DLetGroup" PWild (PVar "binds")) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EVar "checkLetBinds") (EVar "mctx")) (EVar "binds"))) (DoExpr (EApp (EApp (EVar "checkLetRecDecls") (EVar "mctx")) (EVar "rest")))))
(DFunDef false "checkLetRecDecls" ((PVar "mctx") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "checkLetRecDecls") (EVar "mctx")) (EVar "rest")))
(DTypeSig false "checkLetBinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyCon "Unit"))))
(DFunDef false "checkLetBinds" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "checkLetBinds" ((PVar "mctx") (PCons (PCon "LetBind" (PVar "name") (PVar "clauses") PWild PWild) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "checkLetBind") (EVar "mctx")) (EVar "name")) (EVar "clauses"))) (DoExpr (EApp (EApp (EVar "checkLetBinds") (EVar "mctx")) (EVar "rest")))))
(DTypeSig false "checkLetBind" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyCon "Unit")))))
(DFunDef false "checkLetBind" ((PVar "mctx") (PVar "name") (PVar "clauses")) (EIf (EApp (EApp (EVar "allList") (EVar "clauseIsNonFunction")) (EVar "clauses")) (EApp (EApp (EApp (EVar "pushTypeError") (EApp (EApp (EVar "mctxAtIfSome") (EApp (EVar "clausesSpanLoc") (EVar "clauses"))) (EVar "mctx"))) (ELit (LString "T-NONREC-VALUE-LET"))) (EApp (EVar "letRecNonFunctionMsg") (EVar "name"))) (EIf (EVar "otherwise") (ELit LUnit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "clauseIsNonFunction" (TyFun (TyCon "FunClause") (TyCon "Bool")))
(DFunDef false "clauseIsNonFunction" ((PCon "FunClause" (PList) (PVar "rhs"))) (EApp (EVar "not") (EApp (EVar "isSyntacticLambda") (EVar "rhs"))))
(DFunDef false "clauseIsNonFunction" ((PCon "FunClause" PWild PWild)) (EVar "False"))
(DTypeSig true "checkRecBindNonFunction" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Unit")))))
(DFunDef false "checkRecBindNonFunction" ((PVar "mctx") (PVar "name") (PVar "e")) (EIf (EApp (EVar "isSyntacticLambda") (EVar "e")) (ELit LUnit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (ELit (LString "T-NONREC-VALUE-LET"))) (EApp (EVar "exprLoc") (EVar "e"))) (EApp (EVar "letRecNonFunctionMsg") (EVar "name"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "checkLetGroupBindsLocated" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyCon "Unit"))))
(DFunDef false "checkLetGroupBindsLocated" ((PVar "mctx")) (EApp (EVar "checkLetGroupBindsGo") (EVar "mctx")))
(DTypeSig false "checkLetGroupBindsGo" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyCon "Unit"))))
(DFunDef false "checkLetGroupBindsGo" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "checkLetGroupBindsGo" ((PVar "mctx") (PCons (PCon "LetBind" (PVar "name") (PVar "clauses") PWild PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "selfAndForward") (EBinOp "::" (EVar "name") (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "rest")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkClausesNonFunctionLocated") (EVar "mctx")) (EVar "selfAndForward")) (EVar "name")) (EVar "clauses"))) (DoExpr (EApp (EApp (EVar "checkLetGroupBindsGo") (EVar "mctx")) (EVar "rest")))))
(DTypeSig false "checkClausesNonFunctionLocated" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyCon "Unit"))))))
(DFunDef false "checkClausesNonFunctionLocated" ((PVar "mctx") (PVar "names") (PVar "name") (PVar "clauses")) (EIf (EBinOp "&&" (EApp (EApp (EVar "allList") (EVar "clauseIsNonFunction")) (EVar "clauses")) (EApp (EApp (EVar "anyClauseEagerlyRefsGroup") (EVar "names")) (EVar "clauses"))) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (ELit (LString "T-NONREC-VALUE-LET"))) (EApp (EVar "clausesLoc") (EVar "clauses"))) (EApp (EVar "letRecNonFunctionMsg") (EVar "name"))) (EIf (EVar "otherwise") (ELit LUnit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "anyClauseEagerlyRefsGroup" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyCon "Bool"))))
(DFunDef false "anyClauseEagerlyRefsGroup" ((PVar "names") (PVar "clauses")) (EApp (EApp (EVar "anyList") (EApp (EVar "clauseEagerlyRefsGroup") (EVar "names"))) (EVar "clauses")))
(DTypeSig false "clauseEagerlyRefsGroup" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "FunClause") (TyCon "Bool"))))
(DFunDef false "clauseEagerlyRefsGroup" ((PVar "names") (PCon "FunClause" PWild (PVar "rhs"))) (EApp (EApp (EVar "anyMember") (EVar "names")) (EApp (EVar "eagerRefs") (EVar "rhs"))))
(DTypeSig false "clausesLoc" (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "clausesLoc" ((PList)) (EVar "None"))
(DFunDef false "clausesLoc" ((PCons (PCon "FunClause" PWild (PVar "rhs")) PWild)) (EApp (EVar "exprLoc") (EVar "rhs")))
(DTypeSig false "clausesSpanLoc" (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "clausesSpanLoc" ((PList)) (EVar "None"))
(DFunDef false "clausesSpanLoc" ((PCons (PCon "FunClause" PWild (PVar "rhs")) PWild)) (EApp (EVar "exprSpanLoc") (EVar "rhs")))
(DTypeSig false "eagerRefs" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "eagerRefs" ((PCon "EVar" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "eagerRefs" ((PCon "EVarId" (PVar "x") PWild)) (EListLit (EVar "x")))
(DFunDef false "eagerRefs" ((PCon "EMethodAt" (PVar "x") PWild PWild)) (EListLit (EVar "x")))
(DFunDef false "eagerRefs" ((PCon "EDictAt" (PVar "x") PWild)) (EListLit (EVar "x")))
(DFunDef false "eagerRefs" ((PCon "EApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "eagerRefs") (EVar "a")) (EApp (EVar "eagerRefs") (EVar "b"))))
(DFunDef false "eagerRefs" ((PCon "ELam" PWild PWild)) (EListLit))
(DFunDef false "eagerRefs" ((PCon "ELet" PWild PWild PWild (PVar "e1") (PVar "e2"))) (EBinOp "++" (EApp (EVar "eagerRefs") (EVar "e1")) (EApp (EVar "eagerRefs") (EVar "e2"))))
(DFunDef false "eagerRefs" ((PCon "ELetGroup" (PVar "bs") (PVar "e2"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "eagerRefsLetBind")) (EVar "bs")) (EApp (EVar "eagerRefs") (EVar "e2"))))
(DFunDef false "eagerRefs" ((PCon "EMatch" (PVar "e0") (PVar "arms"))) (EBinOp "++" (EApp (EVar "eagerRefs") (EVar "e0")) (EApp (EApp (EVar "flatMap") (EVar "eagerRefsArm")) (EVar "arms"))))
(DFunDef false "eagerRefs" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "eagerRefs") (EVar "c")) (EApp (EVar "eagerRefs") (EVar "t"))) (EApp (EVar "eagerRefs") (EVar "el"))))
(DFunDef false "eagerRefs" ((PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "eagerRefs") (EVar "a")) (EApp (EVar "eagerRefs") (EVar "b"))))
(DFunDef false "eagerRefs" ((PCon "EUnOp" PWild (PVar "a") PWild)) (EApp (EVar "eagerRefs") (EVar "a")))
(DFunDef false "eagerRefs" ((PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EBinOp "::" (EVar "op") (EBinOp "++" (EApp (EVar "eagerRefs") (EVar "a")) (EApp (EVar "eagerRefs") (EVar "b")))))
(DFunDef false "eagerRefs" ((PCon "EFieldAccess" (PVar "e0") PWild PWild)) (EApp (EVar "eagerRefs") (EVar "e0")))
(DFunDef false "eagerRefs" ((PCon "ERecordCreate" PWild (PVar "fs"))) (EApp (EApp (EVar "flatMap") (EVar "eagerRefsFieldAssign")) (EVar "fs")))
(DFunDef false "eagerRefs" ((PCon "ERecordUpdate" (PVar "e0") (PVar "fs") PWild)) (EBinOp "++" (EApp (EVar "eagerRefs") (EVar "e0")) (EApp (EApp (EVar "flatMap") (EVar "eagerRefsFieldAssign")) (EVar "fs"))))
(DFunDef false "eagerRefs" ((PCon "EVariantUpdate" PWild (PVar "e0") (PVar "fs"))) (EBinOp "++" (EApp (EVar "eagerRefs") (EVar "e0")) (EApp (EApp (EVar "flatMap") (EVar "eagerRefsFieldAssign")) (EVar "fs"))))
(DFunDef false "eagerRefs" ((PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EVar "eagerRefs")) (EVar "es")))
(DFunDef false "eagerRefs" ((PCon "EListLit" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EVar "eagerRefs")) (EVar "es")))
(DFunDef false "eagerRefs" ((PCon "ETuple" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EVar "eagerRefs")) (EVar "es")))
(DFunDef false "eagerRefs" ((PCon "EIndex" (PVar "e0") (PVar "i"))) (EBinOp "++" (EApp (EVar "eagerRefs") (EVar "e0")) (EApp (EVar "eagerRefs") (EVar "i"))))
(DFunDef false "eagerRefs" ((PCon "ERangeList" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EVar "eagerRefs") (EVar "lo")) (EApp (EVar "eagerRefs") (EVar "hi"))))
(DFunDef false "eagerRefs" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EVar "eagerRefs") (EVar "lo")) (EApp (EVar "eagerRefs") (EVar "hi"))))
(DFunDef false "eagerRefs" ((PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EVar "eagerRefs") (EVar "e0")) (EApp (EVar "eagerRefs") (EVar "lo"))) (EApp (EVar "eagerRefs") (EVar "hi"))))
(DFunDef false "eagerRefs" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "flatMap") (EVar "eagerRefsDoStmt")) (EVar "stmts")))
(DFunDef false "eagerRefs" ((PCon "EDo" PWild (PVar "stmts"))) (EApp (EApp (EVar "flatMap") (EVar "eagerRefsDoStmt")) (EVar "stmts")))
(DFunDef false "eagerRefs" ((PCon "EAnnot" (PVar "e0") PWild)) (EApp (EVar "eagerRefs") (EVar "e0")))
(DFunDef false "eagerRefs" ((PCon "EHeadAnnot" (PVar "e0") PWild)) (EApp (EVar "eagerRefs") (EVar "e0")))
(DFunDef false "eagerRefs" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EApp (EVar "flatMap") (EVar "eagerRefsInterp")) (EVar "parts")))
(DFunDef false "eagerRefs" ((PCon "EGuards" (PVar "arms"))) (EApp (EApp (EVar "flatMap") (EVar "eagerRefsGuardArm")) (EVar "arms")))
(DFunDef false "eagerRefs" ((PCon "ESection" (PCon "SecRight" PWild (PVar "e0")))) (EApp (EVar "eagerRefs") (EVar "e0")))
(DFunDef false "eagerRefs" ((PCon "ESection" (PCon "SecLeft" (PVar "e0") PWild))) (EApp (EVar "eagerRefs") (EVar "e0")))
(DFunDef false "eagerRefs" ((PCon "EAsPat" PWild (PVar "e0"))) (EApp (EVar "eagerRefs") (EVar "e0")))
(DFunDef false "eagerRefs" ((PCon "EMapLit" PWild (PVar "kvs"))) (EApp (EApp (EVar "flatMap") (EVar "eagerRefsPair")) (EVar "kvs")))
(DFunDef false "eagerRefs" ((PCon "ESetLit" PWild (PVar "es"))) (EApp (EApp (EVar "flatMap") (EVar "eagerRefs")) (EVar "es")))
(DFunDef false "eagerRefs" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "eagerRefs") (EVar "e")))
(DFunDef false "eagerRefs" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "eagerRefs") (EVar "e")))
(DFunDef false "eagerRefs" (PWild) (EListLit))
(DTypeSig false "eagerRefsLetBind" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "eagerRefsLetBind" ((PCon "LetBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EVar "flatMap") (EVar "eagerRefsClauseAllPats")) (EVar "clauses")))
(DTypeSig false "eagerRefsClauseAllPats" (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "eagerRefsClauseAllPats" ((PCon "FunClause" (PList) (PVar "rhs"))) (EApp (EVar "eagerRefs") (EVar "rhs")))
(DFunDef false "eagerRefsClauseAllPats" ((PCon "FunClause" PWild PWild)) (EListLit))
(DTypeSig false "eagerRefsArm" (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "eagerRefsArm" ((PCon "Arm" PWild (PVar "gs") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "eagerRefsGuard")) (EVar "gs")) (EApp (EVar "eagerRefs") (EVar "body"))))
(DTypeSig false "eagerRefsGuard" (TyFun (TyCon "Guard") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "eagerRefsGuard" ((PCon "GBool" (PVar "e"))) (EApp (EVar "eagerRefs") (EVar "e")))
(DFunDef false "eagerRefsGuard" ((PCon "GBind" PWild (PVar "e"))) (EApp (EVar "eagerRefs") (EVar "e")))
(DTypeSig false "eagerRefsGuardArm" (TyFun (TyCon "GuardArm") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "eagerRefsGuardArm" ((PCon "GuardArm" (PVar "gs") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "eagerRefsGuard")) (EVar "gs")) (EApp (EVar "eagerRefs") (EVar "body"))))
(DTypeSig false "eagerRefsFieldAssign" (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "eagerRefsFieldAssign" ((PCon "FieldAssign" PWild (PVar "e"))) (EApp (EVar "eagerRefs") (EVar "e")))
(DTypeSig false "eagerRefsDoStmt" (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "eagerRefsDoStmt" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "eagerRefs") (EVar "e")))
(DFunDef false "eagerRefsDoStmt" ((PCon "DoBind" PWild (PVar "e"))) (EApp (EVar "eagerRefs") (EVar "e")))
(DFunDef false "eagerRefsDoStmt" ((PCon "DoLet" PWild PWild PWild (PVar "e") PWild)) (EApp (EVar "eagerRefs") (EVar "e")))
(DFunDef false "eagerRefsDoStmt" (PWild) (EListLit))
(DTypeSig false "eagerRefsInterp" (TyFun (TyCon "InterpPart") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "eagerRefsInterp" ((PCon "InterpExpr" (PVar "e"))) (EApp (EVar "eagerRefs") (EVar "e")))
(DFunDef false "eagerRefsInterp" (PWild) (EListLit))
(DTypeSig false "eagerRefsPair" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "eagerRefsPair" ((PTuple (PVar "k") (PVar "v"))) (EBinOp "++" (EApp (EVar "eagerRefs") (EVar "k")) (EApp (EVar "eagerRefs") (EVar "v"))))
(DTypeSig true "groupNames" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "groupNames" ((PList) PWild) (EListLit))
(DFunDef false "groupNames" ((PCons (PTuple (PVar "n") PWild) (PVar "rest")) (PVar "seen")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "seen")) (arm (PCon "Some" PWild) () (EApp (EApp (EVar "groupNames") (EVar "rest")) (EVar "seen"))) (arm (PCon "None") () (EBinOp "::" (EVar "n") (EApp (EApp (EVar "groupNames") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "seen")))))))
(DTypeSig true "letBindGeneralizes" (TyFun (TyCon "TcEnv") (TyFun (TyTuple (TyCon "LetBind") (TyTuple (TyCon "String") (TyCon "BindingSummary"))) (TyTuple (TyCon "Bool") (TyCon "Mono")))))
(DFunDef false "letBindGeneralizes" ((PVar "env") (PTuple (PCon "LetBind" PWild (PVar "clauses") PWild PWild) (PTuple PWild (PVar "summary")))) (ETuple (EApp (EApp (EVar "clausesAreValue") (EVar "env")) (EVar "clauses")) (EFieldAccess (EVar "summary") "bsValue")))
(DTypeSig true "generalizeGroup" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "AuthResidual"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "LetBind") (TyTuple (TyCon "String") (TyCon "Scheme")))) (TyCon "TcEnv"))))))
(DFunDef false "generalizeGroup" ((PVar "env") PWild PWild (PList)) (EVar "env"))
(DFunDef false "generalizeGroup" ((PVar "env") (PVar "residuals") (PVar "index") (PCons (PTuple (PCon "LetBind" (PVar "name") (PVar "clauses") PWild PWild) (PTuple PWild (PVar "sch"))) (PVar "rest"))) (EBlock (DoLet false false (PVar "mono") (EApp (EVar "schemeMono") (EVar "sch"))) (DoLet false false (PVar "isVal") (EApp (EApp (EVar "clausesAreValue") (EVar "env")) (EVar "clauses"))) (DoLet false false (PVar "env1") (EApp (EApp (EApp (EVar "extendLocalVar") (EVar "env")) (EVar "name")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "genBindingRestricted") (EFieldAccess (EVar "env") "teDyn")) (EVar "Tip")) (EApp (EApp (EVar "residualsOf") (EVar "index")) (EVar "residuals"))) (EVar "isVal")) (EVar "pureRow")) (EVar "mono")))) (DoLet false false (PVar "env2") (EMatch (EVar "clauses") (arm (PList (PCon "FunClause" (PList) (PVar "rhs"))) () (EApp (EApp (EApp (EVar "seedAlphaLets") (EVar "env1")) (EVar "name")) (EVar "rhs"))) (arm PWild () (EVar "env1")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "generalizeGroup") (EVar "env2")) (EVar "residuals")) (EBinOp "+" (EVar "index") (ELit (LInt 1)))) (EVar "rest")))))
(DTypeSig false "clausesAreValue" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyCon "Bool"))))
(DFunDef false "clausesAreValue" ((PVar "env") (PVar "clauses")) (EApp (EApp (EVar "allList") (EApp (EVar "clauseIsValue") (EVar "env"))) (EVar "clauses")))
(DTypeSig false "clauseIsValue" (TyFun (TyCon "TcEnv") (TyFun (TyCon "FunClause") (TyCon "Bool"))))
(DFunDef false "clauseIsValue" ((PVar "env") (PCon "FunClause" (PList) (PVar "rhs"))) (EApp (EApp (EVar "isNonexpansive") (EVar "env")) (EVar "rhs")))
(DFunDef false "clauseIsValue" ((PVar "env") (PCon "FunClause" PWild PWild)) (EVar "True"))
(DTypeSig true "requireGoalsBelow" (TyFun (TyCon "ModuleCtx") (TyFun (TyFun (TyCon "ReqWalk") (TyFun (TyCon "UObligation") (TyApp (TyCon "List") (TyTuple (TyCon "UObligation") (TyCon "ReqWalk"))))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyTuple (TyCon "UObligation") (TyCon "ReqWalk")) (TyApp (TyCon "List") (TyTuple (TyCon "UObligation") (TyCon "ReqWalk")))))))))
(DFunDef false "requireGoalsBelow" ((PVar "mctx") (PVar "enter") (PVar "rigidIds") (PVar "liveIds") (PTuple (PVar "o") (PVar "walk"))) (EBlock (DoLet false false (PVar "args") (EApp (EApp (EVar "map") (EVar "normalize")) (EApp (EApp (EVar "uOblArgs") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "o")))) (DoLet false false (PVar "iface") (EFieldAccess (EFieldAccess (EVar "o") "pred") "iface")) (DoLet false false (PVar "parentIds") (EApp (EApp (EVar "flatMap") (EVar "monoUnboundIds")) (EVar "args"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "args")) (EApp (EVar "monoVectorClosed") (EVar "args"))) (EApp (EApp (EVar "goalVarsAllHeld") (EVar "rigidIds")) (EVar "args"))) (EApp (EApp (EApp (EApp (EVar "goalGivenAt") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "iface")) (EVar "args")) (EFieldAccess (EVar "o") "uoScope"))) (EBinOp "&&" (EApp (EApp (EVar "anyList") (ELam ((PVar "i")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "intToString") (EVar "i"))) (EVar "liveIds")))) (EVar "parentIds")) (EApp (EVar "not") (EApp (EApp (EApp (EApp (EVar "undeterminedGoalExempt") (EVar "mctx")) (EVar "iface")) (EVar "args")) (EFieldAccess (EVar "o") "uoScope"))))) (EListLit) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EApp (EVar "goalRows") (EVar "mctx")) (EVar "iface")) (EVar "args"))) (DoLet false false (PVar "reach") (EIf (EApp (EApp (EVar "goalIsProjection") (EVar "args")) (EVar "rows")) (EVar "ReachMany") (EApp (EApp (EApp (EVar "goalReach") (EVar "mctx")) (EVar "args")) (EApp (EApp (EApp (EApp (EVar "goalCandidates") (EVar "mctx")) (EVar "rigidIds")) (EVar "args")) (EVar "rows"))))) (DoExpr (EMatch (EVar "reach") (arm (PCon "ReachOne" (PVar "row")) () (EBlock (DoLet false false (PVar "goalsOf") (ELam ((PVar "ids") (PVar "subst") (PVar "reqs")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "req")) (EApp (EApp (EVar "flatMap") (EApp (EVar "enter") (EVar "walk"))) (EApp (EApp (EApp (EVar "requireGoalAt") (EVar "o")) (EVar "ids")) (EApp (EApp (EApp (EVar "reqToObligation") (EVar "mctx")) (EVar "subst")) (EVar "req")))))) (EVar "reqs")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "selectedRowReqMatch") (EVar "mctx")) (EVar "args")) (EVar "row")) (arm (PCon "Some" (PTuple (PVar "subst") (PVar "reqs"))) () (EApp (EApp (EApp (EVar "goalsOf") (EVar "parentIds")) (EVar "subst")) (EVar "reqs"))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EApp (EVar "unifiedRowReqs") (EVar "mctx")) (EVar "rigidIds")) (EVar "args")) (EVar "row")) (arm (PCon "Some" (PTuple (PVar "subst") (PVar "fresh") (PVar "reqs"))) () (EApp (EApp (EApp (EVar "goalsOf") (EBinOp "++" (EVar "parentIds") (EVar "fresh"))) (EVar "subst")) (EVar "reqs"))) (arm (PCon "None") () (EListLit)))))))) (arm PWild () (EListLit)))))))))
(DTypeSig false "unifiedRowReqs" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ImplRow") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Require")))))))))
(DFunDef false "unifiedRowReqs" ((PVar "mctx") (PVar "rigidIds") (PVar "args") (PAs "row" (PCon "ImplRow" PWild PWild PWild PWild (PVar "reqs") PWild PWild))) (EBlock (DoLet false false (PTuple (PVar "tvs") (PVar "heads")) (EApp (EApp (EVar "freshRowHeadsTvs") (EVar "mctx")) (EVar "row"))) (DoLet false false (PVar "goalIds") (EApp (EApp (EVar "flatMap") (EVar "monoUnboundIds")) (EVar "args"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "headsUnifier") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "rigidIds")) (EVar "args")) (EVar "heads")) (arm (PCon "Some" (PVar "scratch")) () (EIf (EApp (EApp (EVar "allList") (ELam ((PVar "b")) (EBinOp "||" (EApp (EVar "not") (EApp (EApp (EVar "containsI") (EApp (EVar "fst") (EVar "b"))) (EVar "goalIds"))) (EApp (EApp (EApp (EVar "boundaryOwnsOpen") (EVar "mctx")) (EVar "rigidIds")) (EApp (EVar "fst") (EVar "b")))))) (EUnOp "!" (EVar "scratch"))) (EBlock (DoLet false false (PVar "sigCells") (EApp (EApp (EVar "sigCellsOf") (EVar "rigidIds")) (EApp (EApp (EVar "flatMap") (EVar "monoVarCells")) (EVar "args")))) (DoLet false false (PVar "bound") (EApp (EApp (EVar "map") (ELam ((PVar "nv")) (ETuple (EApp (EVar "fst") (EVar "nv")) (EApp (EApp (EVar "unrigidSig") (EVar "sigCells")) (EApp (EApp (EVar "cohApply") (EVar "scratch")) (EApp (EVar "snd") (EVar "nv"))))))) (EVar "tvs"))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "bound") (EApp (EApp (EVar "flatMap") (ELam ((PVar "nv")) (EApp (EVar "monoUnboundIds") (EApp (EVar "snd") (EVar "nv"))))) (EVar "bound")) (EVar "reqs"))))) (EVar "None"))) (arm (PCon "None") () (EVar "None"))))))
(DTypeSig false "requireGoalAt" (TyFun (TyCon "UObligation") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "UObligation"))))))
(DFunDef false "requireGoalAt" ((PVar "o") (PVar "parentIds") (PTuple (PVar "iface") (PVar "args"))) (EIf (EApp (EVar "not") (EApp (EApp (EVar "allList") (ELam ((PVar "i")) (EApp (EApp (EVar "containsI") (EVar "i")) (EVar "parentIds")))) (EApp (EApp (EVar "flatMap") (EVar "monoUnboundIds")) (EVar "args")))) (EListLit) (EIf (EVar "otherwise") (EListLit (ERecordCreate "UObligation" ((fa "pred" (ERecordCreate "Predicate" ((fa "iface" (EVar "iface")) (fa "args" (EVar "args"))))) (fa "originId" (EFieldAccess (EVar "o") "originId")) (fa "prov" (EFieldAccess (EVar "o") "prov")) (fa "loc" (EFieldAccess (EVar "o") "loc")) (fa "uoScope" (EFieldAccess (EVar "o") "uoScope")) (fa "oblProj" (EVar "OpProjected"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
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
(DTypeSig true "allEVars" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "allEVars" ((PCon "EVar" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "allEVars" ((PCon "EVarId" (PVar "x") PWild)) (EListLit (EVar "x")))
(DFunDef false "allEVars" ((PCon "EMethodAt" (PVar "n") PWild PWild)) (EListLit (EVar "n")))
(DFunDef false "allEVars" ((PCon "EDictAt" (PVar "n") PWild)) (EListLit (EVar "n")))
(DFunDef false "allEVars" ((PCon "ELit" PWild)) (EListLit))
(DFunDef false "allEVars" ((PCon "EApp" (PVar "f") (PVar "x"))) (EBinOp "++" (EApp (EVar "allEVars") (EVar "f")) (EApp (EVar "allEVars") (EVar "x"))))
(DFunDef false "allEVars" ((PCon "ELam" PWild (PVar "b"))) (EApp (EVar "allEVars") (EVar "b")))
(DFunDef false "allEVars" ((PCon "ELet" PWild PWild PWild (PVar "e1") (PVar "e2"))) (EBinOp "++" (EApp (EVar "allEVars") (EVar "e1")) (EApp (EVar "allEVars") (EVar "e2"))))
(DFunDef false "allEVars" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "letBindEVars")) (EVar "binds")) (EApp (EVar "allEVars") (EVar "body"))))
(DFunDef false "allEVars" ((PCon "EMatch" (PVar "e") (PVar "arms"))) (EBinOp "++" (EApp (EVar "allEVars") (EVar "e")) (EApp (EApp (EVar "flatMap") (EVar "armEVars")) (EVar "arms"))))
(DFunDef false "allEVars" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "e"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "allEVars") (EVar "c")) (EApp (EVar "allEVars") (EVar "t"))) (EApp (EVar "allEVars") (EVar "e"))))
(DFunDef false "allEVars" ((PCon "EBinOp" PWild (PVar "l") (PVar "r") PWild)) (EBinOp "++" (EApp (EVar "allEVars") (EVar "l")) (EApp (EVar "allEVars") (EVar "r"))))
(DFunDef false "allEVars" ((PCon "EUnOp" PWild (PVar "e") PWild)) (EApp (EVar "allEVars") (EVar "e")))
(DFunDef false "allEVars" ((PCon "EInfix" (PVar "op") (PVar "l") (PVar "r"))) (EBinOp "::" (EVar "op") (EBinOp "++" (EApp (EVar "allEVars") (EVar "l")) (EApp (EVar "allEVars") (EVar "r")))))
(DFunDef false "allEVars" ((PCon "EFieldAccess" (PVar "e") PWild PWild)) (EApp (EVar "allEVars") (EVar "e")))
(DFunDef false "allEVars" ((PCon "ETuple" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EVar "allEVars")) (EVar "es")))
(DFunDef false "allEVars" ((PCon "EListLit" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EVar "allEVars")) (EVar "es")))
(DFunDef false "allEVars" ((PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EVar "allEVars")) (EVar "es")))
(DFunDef false "allEVars" ((PCon "ERangeList" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "allEVars") (EVar "a")) (EApp (EVar "allEVars") (EVar "b"))))
(DFunDef false "allEVars" ((PCon "ERangeArray" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "allEVars") (EVar "a")) (EApp (EVar "allEVars") (EVar "b"))))
(DFunDef false "allEVars" ((PCon "ESlice" (PVar "e") (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EVar "allEVars") (EVar "e")) (EApp (EVar "allEVars") (EVar "a"))) (EApp (EVar "allEVars") (EVar "b"))))
(DFunDef false "allEVars" ((PCon "EIndex" (PVar "e") (PVar "i"))) (EBinOp "++" (EApp (EVar "allEVars") (EVar "e")) (EApp (EVar "allEVars") (EVar "i"))))
(DFunDef false "allEVars" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "allEVars") (EVar "e")))
(DFunDef false "allEVars" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "flatMap") (EVar "doStmtEVars")) (EVar "stmts")))
(DFunDef false "allEVars" ((PCon "ERecordCreate" PWild (PVar "fs"))) (EApp (EApp (EVar "flatMap") (EVar "fieldAssignEVars")) (EVar "fs")))
(DFunDef false "allEVars" ((PCon "ERecordUpdate" (PVar "e") (PVar "fs") PWild)) (EBinOp "++" (EApp (EVar "allEVars") (EVar "e")) (EApp (EApp (EVar "flatMap") (EVar "fieldAssignEVars")) (EVar "fs"))))
(DFunDef false "allEVars" ((PCon "EVariantUpdate" PWild (PVar "e") (PVar "fs"))) (EBinOp "++" (EApp (EVar "allEVars") (EVar "e")) (EApp (EApp (EVar "flatMap") (EVar "fieldAssignEVars")) (EVar "fs"))))
(DFunDef false "allEVars" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "allEVars") (EVar "e")))
(DFunDef false "allEVars" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "allEVars") (EVar "e")))
(DFunDef false "allEVars" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EVar "allEVars") (EVar "e")))
(DFunDef false "allEVars" ((PCon "EAsPat" PWild (PVar "e"))) (EApp (EVar "allEVars") (EVar "e")))
(DFunDef false "allEVars" ((PCon "EMapLit" PWild (PVar "kvs"))) (EApp (EApp (EVar "flatMap") (EVar "kvEVars")) (EVar "kvs")))
(DFunDef false "allEVars" ((PCon "ESetLit" PWild (PVar "es"))) (EApp (EApp (EVar "flatMap") (EVar "allEVars")) (EVar "es")))
(DFunDef false "allEVars" ((PCon "EDo" PWild (PVar "stmts"))) (EApp (EApp (EVar "flatMap") (EVar "doStmtEVars")) (EVar "stmts")))
(DFunDef false "allEVars" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EApp (EVar "flatMap") (EVar "interpEVars")) (EVar "parts")))
(DFunDef false "allEVars" ((PCon "EGuards" (PVar "arms"))) (EApp (EApp (EVar "flatMap") (EVar "guardArmEVars")) (EVar "arms")))
(DFunDef false "allEVars" ((PCon "ESection" (PVar "s"))) (EApp (EVar "sectionEVars") (EVar "s")))
(DFunDef false "allEVars" (PWild) (EListLit))
(DTypeSig false "kvEVars" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "kvEVars" ((PTuple (PVar "k") (PVar "v"))) (EBinOp "++" (EApp (EVar "allEVars") (EVar "k")) (EApp (EVar "allEVars") (EVar "v"))))
(DTypeSig false "interpEVars" (TyFun (TyCon "InterpPart") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "interpEVars" ((PCon "InterpStr" PWild)) (EListLit))
(DFunDef false "interpEVars" ((PCon "InterpExpr" (PVar "e"))) (EApp (EVar "allEVars") (EVar "e")))
(DTypeSig false "guardArmEVars" (TyFun (TyCon "GuardArm") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "guardArmEVars" ((PCon "GuardArm" (PVar "guards") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "guardEVars")) (EVar "guards")) (EApp (EVar "allEVars") (EVar "body"))))
(DTypeSig false "sectionEVars" (TyFun (TyCon "Section") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "sectionEVars" ((PCon "SecBare" (PVar "op"))) (EListLit (EVar "op")))
(DFunDef false "sectionEVars" ((PCon "SecRight" (PVar "op") (PVar "e"))) (EBinOp "::" (EVar "op") (EApp (EVar "allEVars") (EVar "e"))))
(DFunDef false "sectionEVars" ((PCon "SecLeft" (PVar "e") (PVar "op"))) (EBinOp "::" (EVar "op") (EApp (EVar "allEVars") (EVar "e"))))
(DTypeSig false "letBindEVars" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "letBindEVars" ((PCon "LetBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EVar "flatMap") (EVar "funClauseEVars")) (EVar "clauses")))
(DTypeSig false "funClauseEVars" (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "funClauseEVars" ((PCon "FunClause" PWild (PVar "body"))) (EApp (EVar "allEVars") (EVar "body")))
(DTypeSig false "armEVars" (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "armEVars" ((PCon "Arm" PWild (PVar "guards") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "guardEVars")) (EVar "guards")) (EApp (EVar "allEVars") (EVar "body"))))
(DTypeSig false "guardEVars" (TyFun (TyCon "Guard") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "guardEVars" ((PCon "GBool" (PVar "e"))) (EApp (EVar "allEVars") (EVar "e")))
(DFunDef false "guardEVars" ((PCon "GBind" PWild (PVar "e"))) (EApp (EVar "allEVars") (EVar "e")))
(DTypeSig false "doStmtEVars" (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "doStmtEVars" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "allEVars") (EVar "e")))
(DFunDef false "doStmtEVars" ((PCon "DoLet" PWild PWild PWild (PVar "e") PWild)) (EApp (EVar "allEVars") (EVar "e")))
(DFunDef false "doStmtEVars" ((PCon "DoBind" PWild (PVar "e"))) (EApp (EVar "allEVars") (EVar "e")))
(DFunDef false "doStmtEVars" ((PCon "DoAssign" PWild (PVar "e"))) (EApp (EVar "allEVars") (EVar "e")))
(DFunDef false "doStmtEVars" ((PCon "DoFieldAssign" PWild PWild (PVar "e"))) (EApp (EVar "allEVars") (EVar "e")))
(DTypeSig false "fieldAssignEVars" (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "fieldAssignEVars" ((PCon "FieldAssign" PWild (PVar "e"))) (EApp (EVar "allEVars") (EVar "e")))
(DTypeSig false "freeEVars" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EVar" (PVar "x"))) (EApp (EApp (EVar "freeName") (EVar "bound")) (EVar "x")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EVarId" (PVar "x") PWild)) (EApp (EApp (EVar "freeName") (EVar "bound")) (EVar "x")))
(DFunDef false "freeEVars" (PWild (PCon "EMethodAt" (PVar "n") PWild PWild)) (EListLit (EVar "n")))
(DFunDef false "freeEVars" (PWild (PCon "EDictAt" (PVar "n") PWild)) (EListLit (EVar "n")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EApp" (PVar "f") (PVar "x"))) (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "f")) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "x"))))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "ELam" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "freeEVars") (EApp (EApp (EVar "namesToSet") (EApp (EVar "patVarsListTc") (EVar "ps"))) (EVar "bound"))) (EVar "b")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "ELet" PWild (PVar "r") (PVar "p") (PVar "e1") (PVar "e2"))) (EBlock (DoLet false false (PVar "after") (EApp (EApp (EVar "namesToSet") (EApp (EVar "patVarsTc") (EVar "p"))) (EVar "bound"))) (DoExpr (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EIf (EVar "r") (EVar "after") (EVar "bound"))) (EVar "e1")) (EApp (EApp (EVar "freeEVars") (EVar "after")) (EVar "e2"))))))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "namesToSet") (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds"))) (EVar "bound"))) (DoExpr (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EVar "freeLetBindEVars") (EVar "inner"))) (EVar "binds")) (EApp (EApp (EVar "freeEVars") (EVar "inner")) (EVar "body"))))))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EMatch" (PVar "e") (PVar "arms"))) (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")) (EApp (EApp (EVar "flatMap") (EApp (EVar "freeArmEVars") (EVar "bound"))) (EVar "arms"))))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EIf" (PVar "c") (PVar "t") (PVar "e"))) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "c")) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "t"))) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e"))))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EBinOp" PWild (PVar "l") (PVar "r") PWild)) (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "l")) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "r"))))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EUnOp" PWild (PVar "e") PWild)) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EInfix" (PVar "op") (PVar "l") (PVar "r"))) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "freeName") (EVar "bound")) (EVar "op")) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "l"))) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "r"))))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EFieldAccess" (PVar "e") PWild PWild)) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "ETuple" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "freeEVars") (EVar "bound"))) (EVar "es")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EListLit" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "freeEVars") (EVar "bound"))) (EVar "es")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "freeEVars") (EVar "bound"))) (EVar "es")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "ERangeList" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "a")) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "b"))))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "ERangeArray" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "a")) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "b"))))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "ESlice" (PVar "e") (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "a"))) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "b"))))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EIndex" (PVar "e") (PVar "i"))) (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "i"))))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EAnnot" (PVar "e") PWild)) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "freeStmtsEVars") (EVar "bound")) (EVar "stmts")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "ERecordCreate" PWild (PVar "fs"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "freeFieldEVars") (EVar "bound"))) (EVar "fs")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "ERecordUpdate" (PVar "e") (PVar "fs") PWild)) (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")) (EApp (EApp (EVar "flatMap") (EApp (EVar "freeFieldEVars") (EVar "bound"))) (EVar "fs"))))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EVariantUpdate" PWild (PVar "e") (PVar "fs"))) (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")) (EApp (EApp (EVar "flatMap") (EApp (EVar "freeFieldEVars") (EVar "bound"))) (EVar "fs"))))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "ELoc" PWild (PVar "e"))) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EAsPat" PWild (PVar "e"))) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EMapLit" PWild (PVar "kvs"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "freeKvEVars") (EVar "bound"))) (EVar "kvs")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "ESetLit" PWild (PVar "es"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "freeEVars") (EVar "bound"))) (EVar "es")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EDo" PWild (PVar "stmts"))) (EApp (EApp (EVar "freeStmtsEVars") (EVar "bound")) (EVar "stmts")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EStringInterp" (PVar "parts"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "freeInterpEVars") (EVar "bound"))) (EVar "parts")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EGuards" (PVar "arms"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "freeGuardArmEVars") (EVar "bound"))) (EVar "arms")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "ESection" (PCon "SecBare" (PVar "op")))) (EApp (EApp (EVar "freeName") (EVar "bound")) (EVar "op")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "ESection" (PCon "SecRight" (PVar "op") (PVar "e")))) (EBinOp "++" (EApp (EApp (EVar "freeName") (EVar "bound")) (EVar "op")) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e"))))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "ESection" (PCon "SecLeft" (PVar "e") (PVar "op")))) (EBinOp "++" (EApp (EApp (EVar "freeName") (EVar "bound")) (EVar "op")) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e"))))
(DFunDef false "freeEVars" (PWild (PCon "ELit" PWild)) (EListLit))
(DFunDef false "freeEVars" (PWild (PCon "ENumLit" PWild PWild PWild)) (EListLit))
(DFunDef false "freeEVars" (PWild (PCon "EWideLit" PWild PWild PWild PWild)) (EListLit))
(DFunDef false "freeEVars" (PWild (PCon "EDictApp" PWild)) (EListLit))
(DFunDef false "freeEVars" (PWild (PCon "EMethodRef" PWild)) (EListLit))
(DFunDef false "freeEVars" (PWild (PCon "EVarAt" PWild PWild)) (EListLit))
(DTypeSig false "freeKvEVars" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "freeKvEVars" ((PVar "bound") (PTuple (PVar "k") (PVar "v"))) (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "k")) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "v"))))
(DTypeSig false "freeName" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "freeName" ((PVar "bound") (PVar "x")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "x")) (EVar "bound")) (EListLit) (EListLit (EVar "x"))))
(DTypeSig false "freeInterpEVars" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "InterpPart") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "freeInterpEVars" (PWild (PCon "InterpStr" PWild)) (EListLit))
(DFunDef false "freeInterpEVars" ((PVar "bound") (PCon "InterpExpr" (PVar "e"))) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")))
(DTypeSig false "freeFieldEVars" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "freeFieldEVars" ((PVar "bound") (PCon "FieldAssign" PWild (PVar "e"))) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")))
(DTypeSig false "freeLetBindEVars" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "freeLetBindEVars" ((PVar "bound") (PCon "LetBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EVar "flatMap") (ELam ((PVar "c")) (EApp (EApp (EVar "clauseRefsUnder") (EVar "bound")) (EApp (EVar "funClausePair") (EVar "c"))))) (EVar "clauses")))
(DTypeSig false "clauseRefsUnder" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "clauseRefsUnder" ((PVar "bound") (PTuple (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "freeEVars") (EApp (EApp (EVar "namesToSet") (EApp (EVar "patVarsListTc") (EVar "ps"))) (EVar "bound"))) (EVar "body")))
(DTypeSig false "freeArmEVars" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "freeArmEVars" ((PVar "bound") (PCon "Arm" (PVar "p") (PVar "guards") (PVar "body"))) (EApp (EApp (EApp (EVar "freeGuardsEVars") (EApp (EApp (EVar "namesToSet") (EApp (EVar "patVarsTc") (EVar "p"))) (EVar "bound"))) (EVar "guards")) (EVar "body")))
(DTypeSig false "freeGuardArmEVars" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GuardArm") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "freeGuardArmEVars" ((PVar "bound") (PCon "GuardArm" (PVar "guards") (PVar "body"))) (EApp (EApp (EApp (EVar "freeGuardsEVars") (EVar "bound")) (EVar "guards")) (EVar "body")))
(DTypeSig false "freeGuardsEVars" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "freeGuardsEVars" ((PVar "bound") (PList) (PVar "body")) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "body")))
(DFunDef false "freeGuardsEVars" ((PVar "bound") (PCons (PCon "GBool" (PVar "e")) (PVar "rest")) (PVar "body")) (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")) (EApp (EApp (EApp (EVar "freeGuardsEVars") (EVar "bound")) (EVar "rest")) (EVar "body"))))
(DFunDef false "freeGuardsEVars" ((PVar "bound") (PCons (PCon "GBind" (PVar "p") (PVar "e")) (PVar "rest")) (PVar "body")) (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")) (EApp (EApp (EApp (EVar "freeGuardsEVars") (EApp (EApp (EVar "namesToSet") (EApp (EVar "patVarsTc") (EVar "p"))) (EVar "bound"))) (EVar "rest")) (EVar "body"))))
(DTypeSig false "freeStmtsEVars" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "freeStmtsEVars" (PWild (PList)) (EListLit))
(DFunDef false "freeStmtsEVars" ((PVar "bound") (PCons (PCon "DoExpr" (PVar "e")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")) (EApp (EApp (EVar "freeStmtsEVars") (EVar "bound")) (EVar "rest"))))
(DFunDef false "freeStmtsEVars" ((PVar "bound") (PCons (PCon "DoLet" PWild (PVar "r") (PVar "p") (PVar "e") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "after") (EApp (EApp (EVar "namesToSet") (EApp (EVar "patVarsTc") (EVar "p"))) (EVar "bound"))) (DoExpr (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EIf (EVar "r") (EVar "after") (EVar "bound"))) (EVar "e")) (EApp (EApp (EVar "freeStmtsEVars") (EVar "after")) (EVar "rest"))))))
(DFunDef false "freeStmtsEVars" ((PVar "bound") (PCons (PCon "DoBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")) (EApp (EApp (EVar "freeStmtsEVars") (EApp (EApp (EVar "namesToSet") (EApp (EVar "patVarsTc") (EVar "p"))) (EVar "bound"))) (EVar "rest"))))
(DFunDef false "freeStmtsEVars" ((PVar "bound") (PCons (PCon "DoAssign" (PVar "x") (PVar "e")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")) (EApp (EApp (EVar "freeStmtsEVars") (EApp (EApp (EVar "namesToSet") (EListLit (EVar "x"))) (EVar "bound"))) (EVar "rest"))))
(DFunDef false "freeStmtsEVars" ((PVar "bound") (PCons (PCon "DoFieldAssign" PWild PWild (PVar "e")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")) (EApp (EApp (EVar "freeStmtsEVars") (EVar "bound")) (EVar "rest"))))
(DTypeSig true "depGraphMap" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "depGraphMap" ((PVar "names") (PVar "grouped")) (EApp (EApp (EApp (EApp (EVar "buildAdj") (EVar "names")) (EApp (EApp (EVar "namesToSet") (EVar "names")) (EVar "omEmpty"))) (EVar "grouped")) (EVar "omEmpty")))
(DTypeSig true "groupClauses" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "groupClauses" ((PVar "defs")) (EApp (EApp (EVar "groupClausesGo") (EVar "defs")) (EVar "omEmpty")))
(DTypeSig false "groupClausesGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))
(DFunDef false "groupClausesGo" ((PList) (PVar "m")) (EVar "m"))
(DFunDef false "groupClausesGo" ((PCons (PTuple (PVar "n") (PVar "c")) (PVar "rest")) (PVar "m")) (EApp (EApp (EVar "groupClausesGo") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EBinOp "::" (EVar "c") (EApp (EApp (EVar "clausesAt") (EVar "n")) (EVar "m")))) (EVar "m"))))
(DTypeSig false "buildAdj" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "buildAdj" ((PList) PWild PWild (PVar "m")) (EVar "m"))
(DFunDef false "buildAdj" ((PCons (PVar "n") (PVar "rest")) (PVar "nameSet") (PVar "cbn") (PVar "m")) (EApp (EApp (EApp (EApp (EVar "buildAdj") (EVar "rest")) (EVar "nameSet")) (EVar "cbn")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EApp (EApp (EApp (EVar "depsOf") (EVar "n")) (EVar "nameSet")) (EVar "cbn"))) (EVar "m"))))
(DTypeSig false "depsOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "depsOf" ((PVar "name") (PVar "nameSet") (PVar "cbn")) (EApp (EApp (EVar "filterNonSelf") (EVar "name")) (EApp (EApp (EVar "keepGroupNames") (EVar "nameSet")) (EApp (EVar "dedup") (EApp (EVar "groupRefs") (EApp (EApp (EVar "clausesOf") (EVar "name")) (EVar "cbn")))))))
(DTypeSig false "groupRefs" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "groupRefs" ((PVar "clauses")) (EApp (EApp (EVar "flatMap") (EVar "clauseRefs")) (EVar "clauses")))
(DTypeSig false "clauseRefs" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "clauseRefs" ((PVar "clause")) (EApp (EApp (EVar "clauseRefsUnder") (EVar "omEmpty")) (EVar "clause")))
(DTypeSig false "keepGroupNames" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "keepGroupNames" ((PVar "nameSet") (PVar "refs")) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EVar "omHasKey") (EVar "r")) (EVar "nameSet")))) (EVar "refs")))
(DTypeSig false "filterNonSelf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "filterNonSelf" ((PVar "name") (PVar "xs")) (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (EVar "name")))) (EVar "xs")))
(DTypeSig false "forwardedVecObls" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "List") (TyCon "VecObl")))))))
(DFunDef false "forwardedVecObls" ((PVar "mctx") (PVar "generalizing") (PVar "boundIds") (PVar "callObls")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "vecOblOfPred") (EVar "mctx")) (EVar "generalizing")) (EVar "boundIds"))) (EApp (EApp (EVar "flatMap") (EVar "callPredOf")) (EVar "callObls"))))
(DTypeSig true "isLetrecGroup" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "isLetrecGroup" ((PList)) (EVar "False"))
(DFunDef false "isLetrecGroup" ((PList PWild)) (EVar "False"))
(DFunDef false "isLetrecGroup" (PWild) (EVar "True"))
(DTypeSig true "memberForce" (TyFun (TyCon "ScopedMember") (TyCon "EffRow")))
(DFunDef false "memberForce" ((PVar "member")) (EApp (EApp (EVar "optionOr") (EApp (EApp (EVar "optionOr") (EVar "pureRow")) (EFieldAccess (EVar "member") "smForce"))) (EFieldAccess (EFieldAccess (EVar "member") "smForceBound") "value")))
(DTypeSig false "sigTvMapUnboundIds" (TyFun (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "sigTvMapUnboundIds" ((PTuple PWild PWild (PVar "tvs"))) (EApp (EApp (EVar "flatMap") (ELam ((PVar "p")) (EApp (EVar "monoUnboundIds") (EApp (EVar "snd") (EVar "p"))))) (EVar "tvs")))
(DTypeSig true "sccProtectedSignatureIds" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))
(DFunDef false "sccProtectedSignatureIds" ((PVar "sigTvMaps")) (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (EVar "intToString")) (EApp (EApp (EVar "flatMap") (EVar "sigTvMapUnboundIds")) (EVar "sigTvMaps")))) (EVar "omEmpty")))
(DTypeSig true "sigConstraints" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "sigConstraints" ((PCon "TyConstrained" (PVar "cs") PWild)) (EApp (EApp (EVar "flatMap") (EVar "constraintTyVars")) (EVar "cs")))
(DFunDef false "sigConstraints" (PWild) (EListLit))
(DTypeSig false "constraintTyVars" (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "constraintTyVars" ((PRec "Constraint" ((rf "constraintHead" (PVar "iface")) (rf "constraintArgs" (PVar "tys")) (rf "constraintOrigin" (PVar "co"))) false)) (EMatch (EApp (EVar "tyVarArgNames") (EVar "tys")) (arm (PList) () (EListLit)) (arm (PVar "ns") () (EListLit (ETuple (ERecordCreate "IfaceRef" ((fa "irName" (EVar "iface")) (fa "irOrigin" (EVar "co")))) (EVar "ns"))))))
(DTypeSig false "tyVarArgNames" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "tyVarArgNames" ((PVar "tys")) (EApp (EVar "dedup") (EApp (EApp (EVar "flatMap") (EVar "tyVarNames")) (EVar "tys"))))
(DTypeSig true "sigConstraintArgTys" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Ty")))))
(DFunDef false "sigConstraintArgTys" ((PCon "TyConstrained" (PVar "cs") PWild)) (EApp (EApp (EVar "flatMap") (EVar "constraintTyVarArgs")) (EVar "cs")))
(DFunDef false "sigConstraintArgTys" (PWild) (EListLit))
(DTypeSig false "constraintTyVarArgs" (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Ty")))))
(DFunDef false "constraintTyVarArgs" ((PRec "Constraint" ((rf "constraintArgs" (PVar "tys"))) false)) (EMatch (EApp (EVar "tyVarArgNames") (EVar "tys")) (arm (PList) () (EListLit)) (arm PWild () (EListLit (EVar "tys")))))
(DTypeSig true "constraintVarIfaceMonos" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")))))))
(DFunDef false "constraintVarIfaceMonos" ((PList) PWild) (EListLit))
(DFunDef false "constraintVarIfaceMonos" ((PCons (PTuple (PVar "iface") (PVar "names")) (PVar "rest")) (PVar "tvMap")) (EMatch (EApp (EApp (EVar "constraintNameMonos") (EVar "names")) (EVar "tvMap")) (arm (PList) () (EApp (EApp (EVar "constraintVarIfaceMonos") (EVar "rest")) (EVar "tvMap"))) (arm (PVar "monos") () (EBinOp "::" (ETuple (EVar "iface") (EVar "monos")) (EApp (EApp (EVar "constraintVarIfaceMonos") (EVar "rest")) (EVar "tvMap"))))))
(DTypeSig true "constraintVarArgMonos" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Ty"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Mono"))))))))
(DFunDef false "constraintVarArgMonos" ((PVar "mctx") (PList) PWild PWild) (EListLit))
(DFunDef false "constraintVarArgMonos" ((PVar "mctx") PWild (PList) PWild) (EListLit))
(DFunDef false "constraintVarArgMonos" ((PVar "mctx") (PCons (PTuple PWild (PVar "names")) (PVar "rest")) (PCons (PVar "args") (PVar "argsRest")) (PVar "tvMap")) (EMatch (EApp (EApp (EVar "constraintNameMonos") (EVar "names")) (EVar "tvMap")) (arm (PList) () (EApp (EApp (EApp (EApp (EVar "constraintVarArgMonos") (EVar "mctx")) (EVar "rest")) (EVar "argsRest")) (EVar "tvMap"))) (arm PWild () (EBinOp "::" (EApp (EApp (EVar "map") (EApp (EApp (EVar "fromAstType") (EVar "mctx")) (EVar "tvMap"))) (EVar "args")) (EApp (EApp (EApp (EApp (EVar "constraintVarArgMonos") (EVar "mctx")) (EVar "rest")) (EVar "argsRest")) (EVar "tvMap"))))))
(DTypeSig true "sccSchemes" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "AuthResidual"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "ScopedMember")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))))))
(DFunDef false "sccSchemes" ((PVar "env") PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "sccSchemes" ((PVar "env") (PVar "sigs") (PVar "grouped") (PVar "isLetrec") (PVar "residuals") (PVar "index") (PCons (PVar "member") (PVar "rest"))) (EBlock (DoLet false false (PVar "m") (EFieldAccess (EVar "member") "smName")) (DoLet false false (PVar "isVal") (EApp (EApp (EVar "allList") (EApp (EVar "memberClauseIsValue") (EVar "env"))) (EApp (EApp (EVar "clausesOf") (EVar "m")) (EVar "grouped")))) (DoExpr (EBinOp "::" (ETuple (EVar "m") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "genBindingRestricted") (EFieldAccess (EVar "env") "teDyn")) (EFieldAccess (EFieldAccess (EVar "member") "smDeclaredAuths") "value")) (EApp (EApp (EVar "residualsOf") (EVar "index")) (EVar "residuals"))) (EVar "isVal")) (EApp (EVar "memberForce") (EVar "member"))) (EFieldAccess (EVar "member") "smMono"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "sccSchemes") (EVar "env")) (EVar "sigs")) (EVar "grouped")) (EVar "isLetrec")) (EVar "residuals")) (EBinOp "+" (EVar "index") (ELit (LInt 1)))) (EVar "rest"))))))
(DTypeSig true "quantifiableAuthorities" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyCon "ScopedMember")) (TyCon "ScopeRoles")))))
(DFunDef false "quantifiableAuthorities" ((PVar "env") (PVar "grouped") (PVar "members")) (EApp (EVar "scopeRolesOf") (EApp (EApp (EVar "map") (ELam ((PVar "member")) (ETuple (EApp (EApp (EVar "memberRole") (EApp (EApp (EVar "omHasKey") (EFieldAccess (EVar "member") "smName")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "sigNameSetRef") "value"))) (EApp (EApp (EVar "allList") (EApp (EVar "memberClauseIsValue") (EVar "env"))) (EApp (EApp (EVar "clausesOf") (EFieldAccess (EVar "member") "smName")) (EVar "grouped")))) (EFieldAccess (EVar "member") "smMono")))) (EVar "members"))))
(DTypeSig false "memberRole" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyCon "BindingRole"))))
(DFunDef false "memberRole" ((PCon "True") PWild) (EVar "RoleDeclared"))
(DFunDef false "memberRole" ((PCon "False") (PCon "True")) (EVar "RoleQuantifies"))
(DFunDef false "memberRole" ((PCon "False") (PCon "False")) (EVar "RoleMonomorphic"))
(DTypeSig true "scopeRolesOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "BindingRole") (TyCon "Mono"))) (TyCon "ScopeRoles")))
(DFunDef false "scopeRolesOf" ((PVar "members")) (EBlock (DoLet false false (PVar "owners") (EApp (EApp (EApp (EVar "fold") (ELam ((PTuple (PVar "acc") (PVar "index")) (PTuple (PVar "role") (PVar "mono"))) (EBlock (DoLet false false (PVar "ids") (EMatch (EVar "role") (arm (PCon "RoleQuantifies") () (EApp (EVar "IdMap.keys") (EApp (EApp (EVar "qualifierAuthIds") (EVar "mono")) (EVar "Tip")))) (arm PWild () (EListLit)))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PVar "id")) (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (EBinOp "::" (EVar "index") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EVar "m"))))) (EVar "m")))) (EVar "acc")) (EVar "ids")) (EBinOp "+" (EVar "index") (ELit (LInt 1)))))))) (ETuple (EVar "Tip") (ELit (LInt 0)))) (EVar "members"))) (DoExpr (ERecordCreate "ScopeRoles" ((fa "rlQuantified" (EApp (EApp (EApp (EVar "IdMap.foldlWithKey") (ELam ((PVar "acc") (PVar "id") (PVar "indices")) (EMatch (EVar "indices") (arm (PList (PVar "index")) () (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (EVar "index")) (EVar "acc"))) (arm PWild () (EVar "acc"))))) (EVar "Tip")) (EApp (EVar "fst") (EVar "owners")))) (fa "rlOutward" (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PTuple (PVar "role") (PVar "mono"))) (EMatch (EVar "role") (arm (PCon "RoleMonomorphic") () (EApp (EApp (EVar "authIdsIn") (EVar "mono")) (EVar "acc"))) (arm PWild () (EVar "acc"))))) (EVar "Tip")) (EVar "members"))) (fa "rlTyped" (EApp (EVar "Some") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PTuple PWild (PVar "mono"))) (EApp (EApp (EVar "authIdsIn") (EVar "mono")) (EVar "acc")))) (EVar "Tip")) (EVar "members")))) (fa "rlMemberAuths" (ELam (PWild) (EApp (EApp (EVar "map") (ELam ((PTuple PWild (PVar "mono"))) (EApp (EApp (EVar "authIdsIn") (EVar "mono")) (EVar "Tip")))) (EVar "members")))))))))
(DTypeSig true "residualsOf" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "AuthResidual"))) (TyApp (TyCon "List") (TyCon "AuthResidual")))))
(DFunDef false "residualsOf" ((PVar "index") (PVar "residuals")) (EApp (EApp (EVar "flatMap") (ELam ((PTuple (PVar "owner") (PVar "r"))) (EIf (EBinOp "==" (EVar "owner") (EVar "index")) (EListLit (EVar "r")) (EListLit)))) (EVar "residuals")))
(DTypeSig false "memberClauseIsValue" (TyFun (TyCon "TcEnv") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyCon "Bool"))))
(DFunDef false "memberClauseIsValue" ((PVar "env") (PTuple (PList) (PVar "rhs"))) (EApp (EApp (EVar "isNonexpansive") (EVar "env")) (EVar "rhs")))
(DFunDef false "memberClauseIsValue" ((PVar "env") (PTuple PWild PWild)) (EVar "True"))
(DTypeSig true "checkSigsOverExpansive" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyCon "Unit")))))
(DFunDef false "checkSigsOverExpansive" ((PVar "env") PWild (PList)) (ELit LUnit))
(DFunDef false "checkSigsOverExpansive" ((PVar "env") (PVar "grouped") (PCons (PTuple (PVar "m") (PVar "ty") (PVar "tvs")) (PVar "rest"))) (EBlock (DoExpr (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "isEmpty") (EVar "tvs"))) (EApp (EVar "not") (EApp (EApp (EVar "allList") (EApp (EVar "memberClauseIsValue") (EVar "env"))) (EApp (EApp (EVar "clausesOf") (EVar "m")) (EVar "grouped"))))) (EApp (EApp (EApp (EVar "pushTypeError") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit (LString "T-SIG-OVER-EXPANSIVE"))) (EApp (EApp (EVar "sigOverExpansiveMsg") (EVar "m")) (EVar "ty"))) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "checkSigsOverExpansive") (EVar "env")) (EVar "grouped")) (EVar "rest")))))
(DTypeSig true "checkSigsTooGeneral" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyCon "Unit"))))
(DFunDef false "checkSigsTooGeneral" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "checkSigsTooGeneral" ((PVar "mctx") (PCons (PTuple (PVar "m") (PVar "ty") (PVar "tvs")) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "checkSigTooGeneral") (EVar "mctx")) (EVar "m")) (EVar "ty")) (EVar "tvs"))) (DoExpr (EApp (EApp (EVar "checkSigsTooGeneral") (EVar "mctx")) (EVar "rest")))))
(DTypeSig false "checkSigTooGeneral" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyCon "Unit"))))))
(DFunDef false "checkSigTooGeneral" ((PVar "mctx") (PVar "name") (PVar "ty") (PVar "tvs")) (EBlock (DoLet false false (PVar "tvarIds") (EApp (EVar "sigTvarIds") (EApp (EApp (EVar "map") (EVar "snd")) (EVar "tvs")))) (DoExpr (EMatch (EApp (EVar "groundedSignatureVariable") (EVar "tvs")) (arm (PCon "Some" (PTuple (PVar "vname") (PVar "actual"))) () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-TYPE-TOO-GENERAL"))) (EApp (EVar "firstTyLoc") (EVar "ty"))) (EApp (EApp (EApp (EVar "groundedSigVarMsg") (EVar "vname")) (EVar "name")) (EVar "actual")))) (arm (PCon "None") () (EIf (EApp (EVar "hasDupI") (EVar "tvarIds")) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-TYPE-TOO-GENERAL"))) (EApp (EApp (EVar "sigTooGeneralMsg") (EVar "name")) (EVar "ty"))) (ELit LUnit)))))))
(DTypeSig false "groundedSignatureVariable" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Mono")))))
(DFunDef false "groundedSignatureVariable" ((PList)) (EVar "None"))
(DFunDef false "groundedSignatureVariable" ((PCons (PTuple (PVar "name") (PVar "mono")) (PVar "rest"))) (EMatch (EApp (EVar "normalize") (EVar "mono")) (arm (PCon "TVar" PWild) () (EApp (EVar "groundedSignatureVariable") (EVar "rest"))) (arm (PVar "actual") () (EApp (EVar "Some") (ETuple (EVar "name") (EVar "actual"))))))
(DTypeSig true "checkSigsFixedByExpansive" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyCon "ScopedMember")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyCon "Unit"))))))
(DFunDef false "checkSigsFixedByExpansive" ((PVar "env") (PVar "grouped") (PVar "members") (PVar "sigTvMaps")) (EBlock (DoLet false false (PVar "fixed") (EApp (EApp (EVar "flatMap") (ELam ((PVar "member")) (EIf (EBinOp "||" (EFieldAccess (EFieldAccess (EVar "member") "smSigned") "value") (EApp (EApp (EVar "allList") (EApp (EVar "memberClauseIsValue") (EVar "env"))) (EApp (EApp (EVar "clausesOf") (EFieldAccess (EVar "member") "smName")) (EVar "grouped")))) (EListLit) (EApp (EApp (EVar "map") (ELam ((PVar "id")) (ETuple (EVar "id") (EFieldAccess (EVar "member") "smName")))) (EApp (EVar "monoUnboundIds") (EFieldAccess (EVar "member") "smMono")))))) (EVar "members"))) (DoExpr (EMatch (EVar "fixed") (arm (PList) () (ELit LUnit)) (arm PWild () (EApp (EApp (EApp (EVar "checkSigsFixedBy") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "fixed")) (EVar "sigTvMaps")))))))
(DTypeSig false "checkSigsFixedBy" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyCon "Unit")))))
(DFunDef false "checkSigsFixedBy" ((PVar "mctx") PWild (PList)) (ELit LUnit))
(DFunDef false "checkSigsFixedBy" ((PVar "mctx") (PVar "fixed") (PCons (PTuple (PVar "name") (PVar "ty") (PVar "tvs")) (PVar "rest"))) (EBlock (DoExpr (EMatch (EApp (EApp (EVar "sigVarFixedBy") (EVar "fixed")) (EVar "tvs")) (arm (PCon "Some" (PTuple (PVar "vname") (PVar "sibling"))) () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-TYPE-TOO-GENERAL"))) (EApp (EVar "firstTyLoc") (EVar "ty"))) (EApp (EApp (EApp (EVar "siblingSharedSigVarMsg") (EVar "vname")) (EVar "name")) (EVar "sibling")))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EApp (EApp (EApp (EVar "checkSigsFixedBy") (EVar "mctx")) (EVar "fixed")) (EVar "rest")))))
(DTypeSig false "sigVarFixedBy" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "sigVarFixedBy" (PWild (PList)) (EVar "None"))
(DFunDef false "sigVarFixedBy" ((PVar "fixed") (PCons (PTuple (PVar "vname") (PVar "mono")) (PVar "rest"))) (EMatch (EApp (EVar "normalize") (EVar "mono")) (arm (PCon "TVar" (PVar "cell")) () (EMatch (EApp (EApp (EVar "fixedSibling") (EApp (EVar "tyvarId") (EVar "cell"))) (EVar "fixed")) (arm (PCon "Some" (PVar "sibling")) () (EApp (EVar "Some") (ETuple (EVar "vname") (EVar "sibling")))) (arm (PCon "None") () (EApp (EApp (EVar "sigVarFixedBy") (EVar "fixed")) (EVar "rest"))))) (arm PWild () (EApp (EApp (EVar "sigVarFixedBy") (EVar "fixed")) (EVar "rest")))))
(DTypeSig false "fixedSibling" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "fixedSibling" (PWild (PList)) (EVar "None"))
(DFunDef false "fixedSibling" ((PVar "id") (PCons (PTuple (PVar "i") (PVar "sibling")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "i") (EVar "id")) (EApp (EVar "Some") (EVar "sibling")) (EIf (EVar "otherwise") (EApp (EApp (EVar "fixedSibling") (EVar "id")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "registerSchemeObligations" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "Loc")))) (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyCon "Unit"))))))))
(DFunDef false "registerSchemeObligations" ((PVar "mctx") PWild PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "registerSchemeObligations" ((PVar "mctx") (PVar "memberDefIds") (PVar "sigTvMaps") (PVar "callObls") (PVar "addedObls") (PCons (PTuple (PVar "m") (PVar "sch")) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "deferrableVarIds")) (EApp (EApp (EVar "idSetInsertAll") (EApp (EVar "schemeIds") (EVar "sch"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "deferrableVarIds") "value")))) (DoLet false false (PVar "obs") (EApp (EVar "dedupVecObls") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "schemeOblsForMember") (EVar "mctx")) (EVar "sigTvMaps")) (EVar "callObls")) (EVar "addedObls")) (EVar "m")) (EVar "sch")))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "obs")) (ELit LUnit) (EBlock (DoLet false false (PVar "defId") (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EVar "m")) (EVar "memberDefIds")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "schemeObligationsRef")) (EBinOp "::" (ETuple (ETuple (EVar "m") (EVar "defId")) (EVar "obs")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "schemeObligationsRef") "value"))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerSchemeObligations") (EVar "mctx")) (EVar "memberDefIds")) (EVar "sigTvMaps")) (EVar "callObls")) (EVar "addedObls")) (EVar "rest")))))
(DTypeSig false "schemeOblsForMember" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "Loc")))) (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyFun (TyCon "String") (TyFun (TyCon "Scheme") (TyApp (TyCon "List") (TyCon "VecObl")))))))))
(DFunDef false "schemeOblsForMember" ((PVar "mctx") (PVar "sigTvMaps") (PVar "callObls") (PVar "addedObls") (PVar "m") (PVar "sch")) (EMatch (EApp (EApp (EVar "lookupSigTvMap") (EVar "m")) (EVar "sigTvMaps")) (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EApp (EVar "declaredSchemeOblsFor") (EVar "mctx")) (EVar "sigTvMaps")) (EVar "m")) (EApp (EVar "schemeIds") (EVar "sch")))) (arm (PCon "None") () (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "schemeObligationsOf") (EVar "mctx")) (EVar "True")) (EApp (EVar "schemeIds") (EVar "sch"))) (EVar "addedObls")) (EApp (EApp (EApp (EApp (EVar "forwardedVecObls") (EVar "mctx")) (EVar "True")) (EApp (EVar "schemeIds") (EVar "sch"))) (EVar "callObls"))))))
(DTypeSig false "declaredSchemeOblsFor" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "VecObl")))))))
(DFunDef false "declaredSchemeOblsFor" ((PVar "mctx") (PVar "sigTvMaps") (PVar "m") (PVar "boundIds")) (EMatch (EApp (EApp (EVar "lookupSigTvMap") (EVar "m")) (EVar "sigTvMaps")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple (PVar "ty") (PVar "tvMap"))) () (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "declaredOblOne") (EVar "mctx")) (EVar "boundIds")) (EVar "tvMap"))) (EApp (EVar "sigConstraintsOf") (EVar "ty"))))))
(DTypeSig false "declaredOblOne" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyCon "VecObl")))))))
(DFunDef false "declaredOblOne" ((PVar "mctx") (PVar "boundIds") (PVar "tvMap") (PRec "Constraint" ((rf "constraintHead" (PVar "iface")) (rf "constraintArgs" (PVar "args")) (rf "constraintOrigin" (PVar "co"))) false)) (EBlock (DoLet false false (PVar "ifref") (ERecordCreate "IfaceRef" ((fa "irName" (EVar "iface")) (fa "irOrigin" (EVar "co"))))) (DoExpr (EMatch (EApp (EApp (EVar "constraintArgMonos") (EVar "args")) (EVar "tvMap")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "declaredOblMixed") (EVar "mctx")) (EVar "boundIds")) (EVar "ifref")) (EVar "tvMap")) (EVar "args"))) (arm (PCon "Some" (PVar "monos")) () (EMatch (EApp (EApp (EVar "boundTyvarIds") (EVar "boundIds")) (EVar "monos")) (arm (PCon "Some" (PVar "ids")) () (EListLit (ERecordCreate "VecObl" ((fa "voIface" (EVar "ifref")) (fa "voIds" (EVar "ids")) (fa "voArgs" (EListLit)))))) (arm (PCon "None") () (EListLit))))))))
(DTypeSig false "declaredOblMixed" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "VecObl"))))))))
(DFunDef false "declaredOblMixed" ((PVar "mctx") (PVar "boundIds") (PVar "ifref") (PVar "tvMap") (PVar "args")) (EBlock (DoLet false false (PVar "monos") (EApp (EApp (EVar "map") (EApp (EApp (EVar "fromAstType") (EVar "mctx")) (EVar "tvMap"))) (EVar "args"))) (DoLet false false (PVar "ids") (EApp (EApp (EVar "flatMap") (EApp (EVar "declaredOblArgId") (EVar "boundIds"))) (EVar "monos"))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "ids")) (EApp (EVar "not") (EApp (EApp (EVar "allList") (EApp (EVar "declaredOblArgOk") (ELam ((PVar "i")) (EApp (EApp (EVar "containsI") (EVar "i")) (EVar "boundIds"))))) (EVar "monos")))) (EListLit) (EListLit (ERecordCreate "VecObl" ((fa "voIface" (EVar "ifref")) (fa "voIds" (EVar "ids")) (fa "voArgs" (EVar "monos")))))))))
(DTypeSig false "constraintArgMonos" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Mono"))))))
(DFunDef false "constraintArgMonos" ((PList) PWild) (EApp (EVar "Some") (EListLit)))
(DFunDef false "constraintArgMonos" ((PCons (PVar "a") (PVar "rest")) (PVar "tvMap")) (EMatch (EApp (EApp (EVar "constraintArgMono") (EVar "a")) (EVar "tvMap")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "mono")) () (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "mono") (EVar "_s")))) (EApp (EApp (EVar "constraintArgMonos") (EVar "rest")) (EVar "tvMap"))))))
(DTypeSig false "constraintArgMono" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyCon "Mono")))))
(DFunDef false "constraintArgMono" ((PVar "a") (PVar "tvMap")) (EMatch (EApp (EVar "constraintArgVarName") (EVar "a")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "v")) () (EApp (EApp (EVar "lookupAssoc") (EVar "v")) (EVar "tvMap")))))
(DTypeSig false "lookupSigTvMap" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyApp (TyCon "Option") (TyTuple (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))))))
(DFunDef false "lookupSigTvMap" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupSigTvMap" ((PVar "m") (PCons (PTuple (PVar "n") (PVar "ty") (PVar "tvMap")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "m") (EVar "n")) (EApp (EVar "Some") (ETuple (EVar "ty") (EVar "tvMap"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupSigTvMap") (EVar "m")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dedupVecObls" (TyFun (TyApp (TyCon "List") (TyCon "VecObl")) (TyApp (TyCon "List") (TyCon "VecObl"))))
(DFunDef false "dedupVecObls" ((PVar "xs")) (EApp (EApp (EVar "dedupBy") (EVar "vecOblKey")) (EVar "xs")))
(DTypeSig false "vecOblKey" (TyFun (TyCon "VecObl") (TyCon "String")))
(DFunDef false "vecOblKey" ((PVar "o")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "lenKey") (EFieldAccess (EFieldAccess (EVar "o") "voIface") "irName")))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EApp (EApp (EVar "map") (EVar "intToString")) (EFieldAccess (EVar "o") "voIds"))))) (ELit (LString "|"))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EApp (EApp (EVar "map") (EVar "oblArgKey")) (EFieldAccess (EVar "o") "voArgs"))))) (ELit (LString ""))))
(DTypeSig false "containsVecObl" (TyFun (TyCon "VecObl") (TyFun (TyApp (TyCon "List") (TyCon "VecObl")) (TyCon "Bool"))))
(DFunDef false "containsVecObl" (PWild (PList)) (EVar "False"))
(DFunDef false "containsVecObl" ((PVar "o") (PCons (PVar "o2") (PVar "rest"))) (EBinOp "||" (EBinOp "&&" (EApp (EApp (EVar "sameIfaceDecl") (EFieldAccess (EVar "o") "voIface")) (EFieldAccess (EVar "o2") "voIface")) (EBinOp "==" (EFieldAccess (EVar "o") "voIds") (EFieldAccess (EVar "o2") "voIds"))) (EApp (EApp (EVar "containsVecObl") (EVar "o")) (EVar "rest"))))
(DTypeSig false "schemeObligationsOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyApp (TyCon "List") (TyCon "VecObl")))))))
(DFunDef false "schemeObligationsOf" ((PVar "mctx") (PVar "generalizing") (PVar "boundIds") (PVar "obls")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "vecOblOfPred") (EVar "mctx")) (EVar "generalizing")) (EVar "boundIds"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "oblPredOf") (EFieldAccess (EVar "mctx") "mcGraph"))) (EVar "obls"))))
(DTypeSig false "vecOblOfPred" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "VecObl")))))))
(DFunDef false "vecOblOfPred" ((PVar "mctx") (PVar "generalizing") (PVar "boundIds") (PTuple (PVar "iface") (PVar "ds") (PVar "loc"))) (EMatch (EApp (EApp (EVar "boundTyvarIds") (EVar "boundIds")) (EVar "ds")) (arm (PCon "Some" (PVar "ids")) () (EListLit (ERecordCreate "VecObl" ((fa "voIface" (EVar "iface")) (fa "voIds" (EVar "ids")) (fa "voArgs" (EListLit)))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "residualVecObls") (EVar "mctx")) (EVar "generalizing")) (EVar "boundIds")) (EVar "iface")) (EVar "ds")) (EVar "loc")))))
(DTypeSig false "residualVecObls" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "List") (TyCon "VecObl")))))))))
(DFunDef false "residualVecObls" ((PVar "mctx") (PVar "generalizing") (PVar "boundIds") (PVar "iface") (PVar "ds") (PVar "loc")) (EApp (EApp (EVar "map") (EVar "keepBoundResidual")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "residualBoundPreds") (EApp (EVar "siteFor") (EVar "mctx"))) (EVar "generalizing")) (EVar "boundIds")) (EVar "iface")) (EVar "ds")) (EVar "loc"))))
(DTypeSig false "keepBoundResidual" (TyFun (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Mono"))) (TyCon "VecObl")))
(DFunDef false "keepBoundResidual" ((PTuple (PVar "iface") (PVar "ids") (PVar "args"))) (ERecordCreate "VecObl" ((fa "voIface" (EVar "iface")) (fa "voIds" (EVar "ids")) (fa "voArgs" (EApp (EApp (EVar "residualOblArgs") (EVar "ids")) (EVar "args"))))))
(DTypeSig false "residualOblArgs" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "residualOblArgs" ((PVar "ids") (PVar "args")) (EIf (EBinOp "&&" (EApp (EApp (EVar "allList") (EVar "isBareTyvarMono")) (EVar "args")) (EBinOp "==" (EApp (EVar "listLen") (EVar "ids")) (EApp (EVar "listLen") (EVar "args")))) (EListLit) (EIf (EVar "otherwise") (EVar "args") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "pairsOfVecObls" (TyFun (TyApp (TyCon "List") (TyCon "VecObl")) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyCon "Int")))))
(DFunDef false "pairsOfVecObls" ((PList)) (EListLit))
(DFunDef false "pairsOfVecObls" ((PCons (PVar "o") (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "id")) (ETuple (EFieldAccess (EVar "o") "voIface") (EVar "id")))) (EFieldAccess (EVar "o") "voIds")) (EApp (EVar "pairsOfVecObls") (EVar "rest"))))
(DTypeSig true "checkSigConstraintCoverage" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "ConstraintReg")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "Loc")))) (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyCon "Unit")))))))))
(DFunDef false "checkSigConstraintCoverage" ((PVar "mctx") PWild PWild PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "checkSigConstraintCoverage" ((PVar "mctx") (PVar "regs") (PVar "sigs") (PVar "sigTvMaps") (PVar "callObls") (PVar "addedObls") (PCons (PTuple (PVar "m") (PVar "sch")) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkSigConstraintOne") (EVar "mctx")) (EVar "regs")) (EVar "sigs")) (EVar "sigTvMaps")) (EVar "callObls")) (EVar "addedObls")) (EVar "m")) (EVar "sch"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkSigConstraintCoverage") (EVar "mctx")) (EVar "regs")) (EVar "sigs")) (EVar "sigTvMaps")) (EVar "callObls")) (EVar "addedObls")) (EVar "rest")))))
(DTypeSig false "checkSigConstraintOne" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "ConstraintReg")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "Loc")))) (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyFun (TyCon "String") (TyFun (TyCon "Scheme") (TyCon "Unit"))))))))))
(DFunDef false "checkSigConstraintOne" ((PVar "mctx") (PVar "regs") (PVar "sigs") (PVar "sigTvMaps") (PVar "callObls") (PVar "addedObls") (PVar "m") (PVar "sch")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "m")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "sigTyMapRef") "value")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" PWild) () (EBlock (DoLet false false (PVar "declaredPairs") (EApp (EApp (EVar "censusSuperClose") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "declaredPairsFor") (EVar "m")) (EVar "regs")))) (DoLet false false (PVar "boundIds") (EApp (EVar "schemeIds") (EVar "sch"))) (DoLet false false (PVar "bodyVecs") (EApp (EApp (EVar "quantifiedVecObls") (EVar "boundIds")) (EApp (EApp (EApp (EApp (EVar "schemeObligationsOf") (EVar "mctx")) (EVar "False")) (EVar "boundIds")) (EVar "addedObls")))) (DoLet false false (PVar "fwdVecs") (EApp (EApp (EVar "quantifiedVecObls") (EVar "boundIds")) (EApp (EApp (EApp (EApp (EVar "forwardedVecObls") (EVar "mctx")) (EVar "False")) (EVar "boundIds")) (EVar "callObls")))) (DoLet false false (PVar "inferredB") (EApp (EApp (EApp (EVar "inferredIfacePairs") (EVar "mctx")) (EVar "m")) (EVar "boundIds"))) (DoLet false false (PVar "inferred") (EApp (EVar "dedupIfacePairs") (EBinOp "++" (EBinOp "++" (EApp (EVar "pairsOfVecObls") (EVar "bodyVecs")) (EApp (EVar "pairsOfVecObls") (EVar "fwdVecs"))) (EVar "inferredB")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "reportUncovered") (EVar "mctx")) (EVar "m")) (EVar "sigTvMaps")) (EVar "declaredPairs")) (EVar "inferred"))) (DoLet false false (PVar "declaredVecs") (EApp (EApp (EVar "censusSuperCloseVec") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EApp (EApp (EVar "declaredSchemeOblsFor") (EVar "mctx")) (EVar "sigTvMaps")) (EVar "m")) (EVar "boundIds")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reportUncoveredVec") (EVar "mctx")) (EVar "m")) (EVar "sigTvMaps")) (EVar "declaredPairs")) (EVar "declaredVecs")) (EBinOp "++" (EVar "bodyVecs") (EVar "fwdVecs"))))))))
(DTypeSig false "quantifiedVecObls" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "VecObl")) (TyApp (TyCon "List") (TyCon "VecObl")))))
(DFunDef false "quantifiedVecObls" ((PVar "boundIds") (PVar "vecs")) (EApp (EApp (EVar "filterList") (ELam ((PVar "o")) (EApp (EApp (EVar "allList") (ELam ((PVar "id")) (EApp (EApp (EVar "containsI") (EVar "id")) (EVar "boundIds")))) (EApp (EApp (EVar "flatMap") (EVar "monoUnboundIds")) (EFieldAccess (EVar "o") "voArgs"))))) (EVar "vecs")))
(DTypeSig false "inferredIfacePairs" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyCon "Int")))))))
(DFunDef false "inferredIfacePairs" ((PVar "mctx") (PVar "m") (PVar "boundIds")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "pairIface") (EVar "mctx")) (EVar "m"))) (EApp (EApp (EApp (EVar "inferredConstraintIds") (EVar "mctx")) (EVar "m")) (EVar "boundIds"))))
(DTypeSig false "pairIface" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyCon "Int")))))))
(DFunDef false "pairIface" ((PVar "mctx") (PVar "m") (PVar "id")) (EBlock (DoLet false false (PVar "ir") (EApp (EApp (EApp (EVar "ifaceForInferredId") (EVar "mctx")) (EVar "m")) (EVar "id"))) (DoExpr (EMatch (EFieldAccess (EVar "ir") "irName") (arm (PLit (LString "")) () (EListLit)) (arm PWild () (EListLit (ETuple (EVar "ir") (EVar "id"))))))))
(DTypeSig false "declaredPairsFor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ConstraintReg")) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyCon "Int"))))))
(DFunDef false "declaredPairsFor" ((PVar "m") (PVar "regs")) (EApp (EApp (EVar "flatMap") (EVar "declaredPairOne")) (EApp (EApp (EVar "regIfaceMonosFor") (EVar "m")) (EVar "regs"))))
(DTypeSig false "regIfaceMonosFor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ConstraintReg")) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")))))))
(DFunDef false "regIfaceMonosFor" (PWild (PList)) (EListLit))
(DFunDef false "regIfaceMonosFor" ((PVar "m") (PCons (PVar "reg") (PVar "rest"))) (EIf (EBinOp "==" (EVar "m") (EFieldAccess (EVar "reg") "crName")) (EFieldAccess (EVar "reg") "crIfaceMonos") (EIf (EVar "otherwise") (EApp (EApp (EVar "regIfaceMonosFor") (EVar "m")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "declaredPairOne" (TyFun (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyCon "Int")))))
(DFunDef false "declaredPairOne" ((PTuple (PVar "iface") (PVar "monos"))) (EApp (EApp (EVar "map") (ELam ((PVar "id")) (ETuple (EVar "iface") (EVar "id")))) (EApp (EVar "abstractSlotIds") (EVar "monos"))))
(DTypeSig false "censusSuperClose" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyCon "Int"))))))
(DFunDef false "censusSuperClose" ((PVar "gctx") (PVar "declared")) (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EFieldAccess (EVar "n") "superIface") (EFieldAccess (EVar "n") "superPayload")))) (EApp (EApp (EApp (EApp (EVar "superClosure") (EApp (EVar "superLookup") (EVar "gctx"))) (EVar "censusSuperStep")) (ELam ((PVar "iface") (PVar "id")) (EApp (EVar "ifacePairKey") (ETuple (EVar "iface") (EVar "id"))))) (EVar "declared"))))
(DTypeSig false "censusSuperStep" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Super") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "censusSuperStep" ((PVar "typarams") (PVar "id") (PRec "Super" ((rf "superParams" (PVar "params"))) true)) (EIf (EApp (EVar "not") (EApp (EApp (EVar "all") (ELam ((PVar "p")) (EApp (EApp (EVar "contains") (EVar "p")) (EVar "typarams")))) (EVar "params"))) (EVar "None") (EIf (EApp (EVar "isEmptyL") (EVar "params")) (EApp (EVar "Some") (ELit (LInt 0))) (EIf (EVar "otherwise") (EApp (EVar "Some") (EVar "id")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "censusSuperCloseVec" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "VecObl")) (TyApp (TyCon "List") (TyCon "VecObl")))))
(DFunDef false "censusSuperCloseVec" ((PVar "gctx") (PVar "declared")) (EApp (EApp (EVar "map") (EVar "vecOblOfNode")) (EApp (EApp (EApp (EApp (EVar "superClosure") (EApp (EVar "superLookup") (EVar "gctx"))) (EVar "censusVecSuperStep")) (ELam ((PVar "iface") (PVar "payload")) (EApp (EVar "vecOblKey") (EApp (EVar "vecOblOfNode") (ERecordCreate "SuperNode" ((fa "superPath" (EListLit)) (fa "superIface" (EVar "iface")) (fa "superPayload" (EVar "payload")))))))) (EApp (EApp (EVar "map") (ELam ((PVar "o")) (ETuple (EFieldAccess (EVar "o") "voIface") (ETuple (EFieldAccess (EVar "o") "voIds") (EFieldAccess (EVar "o") "voArgs"))))) (EVar "declared")))))
(DTypeSig false "censusVecSuperStep" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Mono"))) (TyFun (TyCon "Super") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Mono"))))))))
(DFunDef false "censusVecSuperStep" ((PVar "typarams") (PTuple (PVar "ids") PWild) (PRec "Super" ((rf "superParams" (PVar "params"))) true)) (EApp (EApp (EVar "map") (ELam ((PVar "mapped")) (ETuple (EVar "mapped") (EListLit)))) (EApp (EApp (EVar "mapAll") (ELam ((PVar "p")) (EApp (EApp (EApp (EVar "lookupPos") (EVar "p")) (EVar "typarams")) (EVar "ids")))) (EVar "params"))))
(DTypeSig false "vecOblOfNode" (TyFun (TyApp (TyCon "SuperNode") (TyTuple (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Mono")))) (TyCon "VecObl")))
(DFunDef false "vecOblOfNode" ((PVar "n")) (EBlock (DoLet false false (PTuple (PVar "ids") (PVar "args")) (EFieldAccess (EVar "n") "superPayload")) (DoExpr (ERecordCreate "VecObl" ((fa "voIface" (EFieldAccess (EVar "n") "superIface")) (fa "voIds" (EVar "ids")) (fa "voArgs" (EVar "args")))))))
(DTypeSig false "reportUncoveredVec" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "VecObl")) (TyFun (TyApp (TyCon "List") (TyCon "VecObl")) (TyCon "Unit"))))))))
(DFunDef false "reportUncoveredVec" ((PVar "mctx") PWild PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "reportUncoveredVec" ((PVar "mctx") (PVar "m") (PVar "sigTvMaps") (PVar "declaredPairs") (PVar "declaredVecs") (PCons (PVar "o") (PVar "rest"))) (EBlock (DoExpr (EIf (EBinOp "<" (EApp (EVar "listLen") (EFieldAccess (EVar "o") "voIds")) (ELit (LInt 2))) (ELit LUnit) (EIf (EApp (EApp (EVar "containsVecObl") (EVar "o")) (EVar "declaredVecs")) (ELit LUnit) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EVar "allPairsIn") (EFieldAccess (EVar "o") "voIface")) (EFieldAccess (EVar "o") "voIds")) (EVar "declaredPairs"))) (ELit LUnit) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-MISSING-CONSTRAINT"))) (EApp (EApp (EApp (EVar "missingConstraintVecMsg") (EVar "m")) (EFieldAccess (EFieldAccess (EVar "o") "voIface") "irName")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "varNameForId") (EVar "sigTvMaps")) (EVar "m"))) (EFieldAccess (EVar "o") "voIds")))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reportUncoveredVec") (EVar "mctx")) (EVar "m")) (EVar "sigTvMaps")) (EVar "declaredPairs")) (EVar "declaredVecs")) (EVar "rest")))))
(DTypeSig false "allPairsIn" (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyCon "Int"))) (TyCon "Bool")))))
(DFunDef false "allPairsIn" ((PVar "iface") (PVar "ids") (PVar "declaredPairs")) (EApp (EApp (EVar "allList") (ELam ((PVar "id")) (EApp (EApp (EVar "containsIfacePair") (ETuple (EVar "iface") (EVar "id"))) (EVar "declaredPairs")))) (EVar "ids")))
(DTypeSig false "reportUncovered" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyCon "Int"))) (TyCon "Unit")))))))
(DFunDef false "reportUncovered" ((PVar "mctx") PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "reportUncovered" ((PVar "mctx") (PVar "m") (PVar "sigTvMaps") (PVar "declared") (PCons (PTuple (PVar "iface") (PVar "id")) (PVar "rest"))) (EBlock (DoExpr (EIf (EApp (EApp (EVar "containsIfacePair") (ETuple (EVar "iface") (EVar "id"))) (EVar "declared")) (ELit LUnit) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-MISSING-CONSTRAINT"))) (EApp (EApp (EApp (EVar "missingConstraintMsg") (EVar "m")) (EFieldAccess (EVar "iface") "irName")) (EApp (EApp (EApp (EVar "varNameForId") (EVar "sigTvMaps")) (EVar "m")) (EVar "id")))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "reportUncovered") (EVar "mctx")) (EVar "m")) (EVar "sigTvMaps")) (EVar "declared")) (EVar "rest")))))
(DTypeSig false "containsIfacePair" (TyFun (TyTuple (TyCon "IfaceRef") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyCon "Int"))) (TyCon "Bool"))))
(DFunDef false "containsIfacePair" (PWild (PList)) (EVar "False"))
(DFunDef false "containsIfacePair" ((PTuple (PVar "i") (PVar "d")) (PCons (PTuple (PVar "i2") (PVar "d2")) (PVar "rest"))) (EBinOp "||" (EBinOp "&&" (EApp (EApp (EVar "sameIfaceDecl") (EVar "i")) (EVar "i2")) (EBinOp "==" (EVar "d") (EVar "d2"))) (EApp (EApp (EVar "containsIfacePair") (ETuple (EVar "i") (EVar "d"))) (EVar "rest"))))
(DTypeSig false "dedupIfacePairs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyCon "Int")))))
(DFunDef false "dedupIfacePairs" ((PVar "xs")) (EApp (EApp (EVar "dedupBy") (EVar "ifacePairKey")) (EVar "xs")))
(DTypeSig false "ifacePairKey" (TyFun (TyTuple (TyCon "IfaceRef") (TyCon "Int")) (TyCon "String")))
(DFunDef false "ifacePairKey" ((PTuple (PVar "iface") (PVar "id"))) (EBinOp "++" (EApp (EVar "regKeyRender") (EApp (EVar "regKeyOfTab") (EApp (EVar "oblIfaceKey") (EVar "iface")))) (EApp (EVar "intToString") (EVar "id"))))
(DTypeSig true "declRefNames" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declRefNames" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declRefNames") (EVar "d")))
(DFunDef false "declRefNames" ((PCon "DFunDef" PWild PWild PWild (PVar "body") PWild PWild)) (EApp (EVar "allEVars") (EVar "body")))
(DFunDef false "declRefNames" ((PCon "DProp" PWild PWild PWild (PVar "body"))) (EApp (EVar "allEVars") (EVar "body")))
(DFunDef false "declRefNames" ((PCon "DTest" PWild PWild (PVar "body"))) (EApp (EVar "allEVars") (EVar "body")))
(DFunDef false "declRefNames" ((PCon "DLetGroup" PWild (PVar "binds"))) (EApp (EApp (EVar "flatMap") (EVar "letBindEVars")) (EVar "binds")))
(DFunDef false "declRefNames" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EVar "flatMap") (EVar "implMethodEVars")) (EVar "methods")))
(DFunDef false "declRefNames" ((PRec "DInterface" ((rf "methods" None)) true)) (EApp (EApp (EVar "flatMap") (EVar "ifaceMethodEVars")) (EVar "methods")))
(DFunDef false "declRefNames" (PWild) (EListLit))
(DTypeSig false "implMethodEVars" (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "implMethodEVars" ((PCon "ImplMethod" PWild PWild (PVar "body"))) (EApp (EVar "allEVars") (EVar "body")))
(DTypeSig false "ifaceMethodEVars" (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ifaceMethodEVars" ((PCon "IfaceMethod" PWild PWild (PVar "d") PWild)) (EMatch (EVar "d") (arm (PCon "Some" (PCon "MethodDefault" PWild (PVar "body"))) () (EApp (EVar "allEVars") (EVar "body"))) (arm (PCon "None") () (EListLit))))
# MARK
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "OblProjection" true) (mem "GoalReach" true) (mem "BindingRole" true) (mem "Predicate" true) (mem "UObligation" true) (mem "ConstraintReg" false) (mem "DynCtx" false) (mem "GraphCtx" false) (mem "ImplRow" false) (mem "ModuleCtx" false) (mem "ReqWalk" false) (mem "ScopedMember" false) (mem "siteFor" false) (mem "TcEnv" false) (mem "ReqStep" true))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "abstractSlotIds" false) (mem "anyMember" false) (mem "authIdsIn" false) (mem "boundTyvarIds" false) (mem "cohApply" false) (mem "containsI" false) (mem "declaredOblArgId" false) (mem "declaredOblArgOk" false) (mem "hasDupI" false) (mem "headsUnifier" false) (mem "isBareTyvarMono" false) (mem "monoUnboundIds" false) (mem "monoVarCells" false) (mem "monoVectorClosed" false) (mem "oblArgKey" false) (mem "patVarsListTc" false) (mem "patVarsTc" false) (mem "qualifierAuthIds" false) (mem "schemeIds" false) (mem "schemeMono" false) (mem "sigCellsOf" false) (mem "sigTvarIds" false) (mem "tyvarId" false) (mem "tyVarNames" false) (mem "unrigidSig" false))))
(DUse false (UseGroup ("types" "tc_diag_text") ((mem "annotTooGeneralMsg" false) (mem "groundedSigVarMsg" false) (mem "letRecNonFunctionMsg" false) (mem "missingConstraintMsg" false) (mem "missingConstraintVecMsg" false) (mem "sigOverExpansiveMsg" false) (mem "sigTooGeneralMsg" false) (mem "siblingSharedSigVarMsg" false) (mem "varNameForId" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "mctxAtIfSome" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "extendLocalVar" false) (mem "funClausePair" false) (mem "lookupCtor" false) (mem "namesToSet" false) (mem "oblIfaceKey" false) (mem "sameIfaceDecl" false) (mem "seedAlphaLets" false) (mem "superLookup" false))))
(DUse false (UseGroup ("types" "tc_diag") ((mem "boundaryOwnsOpen" false) (mem "pushTypeError" false) (mem "pushTypeErrorAt" false) (mem "pushTypeErrorOnceAt" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "generalizeBindingDeclared" false) (mem "lowerAuthLevels" false) (mem "lowerRowLevels" false) (mem "lowerToCurrent" false) (mem "unifyInto" false) (mem "wantAuthorityWith" false))))
(DUse false (UseGroup ("types" "tc_decls_types") ((mem "fromAstType" false) (mem "sigConstraintsOf" false))))
(DUse false (UseGroup ("types" "tc_decls") ((mem "constraintNameMonos" false))))
(DUse false (UseGroup ("types" "tc_solve_givens") ((mem "goalGivenAt" false))))
(DUse false (UseGroup ("types" "tc_solve_entail") ((mem "freshRowHeadsTvs" false) (mem "goalCandidates" false) (mem "goalIsProjection" false) (mem "goalReach" false) (mem "goalRows" false) (mem "selectedRowReqMatch" false) (mem "reqWalkEnter" false) (mem "reqWalkMemo" false) (mem "reqWalkSeed" false))))
(DUse false (UseGroup ("types" "tc_solve") ((mem "goalVarsAllHeld" false) (mem "reqToObligation" false) (mem "uOblArgs" false) (mem "noteWalkGoalFollowed" false) (mem "solvedCleanly" false) (mem "walkGoalFollowed" false))))
(DUse false (UseGroup ("types" "tc_solve_check") ((mem "callPredOf" false) (mem "ifaceForInferredId" false) (mem "inferredConstraintIds" false) (mem "oblPredOf" false) (mem "residualBoundPreds" false) (mem "undeterminedGoalExempt" false) (mem "prerequisiteOnWalk" false))))
(DUse false (UseGroup ("types" "tc_effects") ((mem "clausesAt" false) (mem "clausesOf" false))))
(DUse false (UseGroup ("types" "tc_occurrence") ((mem "ctorHeadShaped" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "Constraint" true) (mem "Decl" true) (mem "DoStmt" true) (mem "Expr" true) (mem "FieldAssign" true) (mem "FunClause" true) (mem "Guard" true) (mem "GuardArm" true) (mem "IfaceMethod" true) (mem "ImplMethod" true) (mem "InterpPart" true) (mem "LetBind" true) (mem "Loc" true) (mem "MethodDefault" true) (mem "Pat" true) (mem "Require" true) (mem "Section" true) (mem "Super" true) (mem "Ty" true) (mem "firstTyLoc" false) (mem "letBindName" false))))
(DUse false (UseGroup ("types" "repr") ((mem "AuthResidual" true) (mem "IfaceRef" true) (mem "Mono" true) (mem "Scheme" true) (mem "VecObl" true) (mem "normalize" false))))
(DUse false (UseGroup ("types" "effect_bindings") ((mem "BindingSummary" true))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffRow" true) (mem "pureRow" false))))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omSize" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("types" "effect_solver") ((mem "ScopeRoles" true))))
(DUse false (UseGroup ("types" "superclass") ((mem "SuperNode" true) (mem "lookupPos" false) (mem "mapAll" false) (mem "superClosure" false))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "anyList" false) (mem "contains" false) (mem "dedup" false) (mem "dedupBy" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isSome" false) (mem "joinWith" false) (mem "lenKey" false) (mem "listLen" false) (mem "lookupAssoc" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "exprSpanLoc" false))))
(DUse false (UseGroup ("types" "registry") ((mem "regKeyOfTab" false) (mem "regKeyRender" false))))
(DUse false (UseGroup ("support" "scc") ((mem "tarjanSCCs" false))))
(DUse false (UseAlias ("map") "IdMap"))
(DTypeSig false "idSetInsertAll" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "idSetInsertAll" ((PList) (PVar "m")) (EVar "m"))
(DFunDef false "idSetInsertAll" ((PCons (PVar "i") (PVar "rest")) (PVar "m")) (EApp (EApp (EVar "idSetInsertAll") (EVar "rest")) (EApp (EApp (EApp (EVar "IdMap.set") (EVar "i")) (ELit LUnit)) (EVar "m"))))
(DTypeSig true "isNonexpansive" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "isNonexpansive" ((PVar "env") (PCon "ELoc" PWild (PVar "e"))) (EApp (EApp (EVar "isNonexpansive") (EVar "env")) (EVar "e")))
(DFunDef false "isNonexpansive" ((PVar "env") (PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EApp (EVar "isNonexpansive") (EVar "env")) (EVar "e")))
(DFunDef false "isNonexpansive" ((PVar "env") (PCon "ELit" PWild)) (EVar "True"))
(DFunDef false "isNonexpansive" ((PVar "env") (PCon "EVar" PWild)) (EVar "True"))
(DFunDef false "isNonexpansive" ((PVar "env") (PCon "EVarId" PWild PWild)) (EVar "True"))
(DFunDef false "isNonexpansive" ((PVar "env") (PCon "EMethodAt" PWild PWild PWild)) (EVar "True"))
(DFunDef false "isNonexpansive" ((PVar "env") (PCon "EDictAt" PWild PWild)) (EVar "True"))
(DFunDef false "isNonexpansive" ((PVar "env") (PCon "EMethodRef" PWild)) (EVar "True"))
(DFunDef false "isNonexpansive" ((PVar "env") (PCon "ELam" PWild PWild)) (EVar "True"))
(DFunDef false "isNonexpansive" ((PVar "env") (PCon "EAnnot" (PVar "e") PWild)) (EApp (EApp (EVar "isNonexpansive") (EVar "env")) (EVar "e")))
(DFunDef false "isNonexpansive" ((PVar "env") (PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EApp (EVar "isNonexpansive") (EVar "env")) (EVar "e")))
(DFunDef false "isNonexpansive" ((PVar "env") (PCon "ETuple" (PVar "es"))) (EApp (EApp (EVar "allList") (EApp (EVar "isNonexpansive") (EVar "env"))) (EVar "es")))
(DFunDef false "isNonexpansive" ((PVar "env") (PCon "EListLit" (PVar "es"))) (EApp (EApp (EVar "allList") (EApp (EVar "isNonexpansive") (EVar "env"))) (EVar "es")))
(DFunDef false "isNonexpansive" ((PVar "env") (PAs "app" (PCon "EApp" PWild PWild))) (EApp (EApp (EVar "isCtorAppSpine") (EVar "env")) (EVar "app")))
(DFunDef false "isNonexpansive" ((PVar "env") (PCon "ERecordCreate" PWild (PVar "fs"))) (EApp (EApp (EVar "allList") (ELam ((PVar "fa")) (EMatch (EVar "fa") (arm (PCon "FieldAssign" PWild (PVar "e")) () (EApp (EApp (EVar "isNonexpansive") (EVar "env")) (EVar "e")))))) (EVar "fs")))
(DFunDef false "isNonexpansive" ((PVar "env") PWild) (EVar "False"))
(DTypeSig false "isCtorAppSpine" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "isCtorAppSpine" ((PVar "env") (PCon "ELoc" PWild (PVar "e"))) (EApp (EApp (EVar "isCtorAppSpine") (EVar "env")) (EVar "e")))
(DFunDef false "isCtorAppSpine" ((PVar "env") (PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EApp (EVar "isCtorAppSpine") (EVar "env")) (EVar "e")))
(DFunDef false "isCtorAppSpine" ((PVar "env") (PCon "EApp" (PVar "f") (PVar "x"))) (EBinOp "&&" (EApp (EApp (EVar "isCtorAppSpine") (EVar "env")) (EVar "f")) (EApp (EApp (EVar "isNonexpansive") (EVar "env")) (EVar "x"))))
(DFunDef false "isCtorAppSpine" ((PVar "env") (PCon "EVar" (PVar "name"))) (EApp (EApp (EVar "isDeclaredCtorHead") (EVar "env")) (EVar "name")))
(DFunDef false "isCtorAppSpine" ((PVar "env") (PCon "EVarId" (PVar "name") PWild)) (EApp (EApp (EVar "isDeclaredCtorHead") (EVar "env")) (EVar "name")))
(DFunDef false "isCtorAppSpine" ((PVar "env") PWild) (EVar "False"))
(DTypeSig false "isDeclaredCtorHead" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isDeclaredCtorHead" ((PVar "env") (PVar "name")) (EBinOp "&&" (EBinOp "&&" (EBinOp "/=" (EVar "name") (ELit (LString "Ref"))) (EApp (EVar "ctorHeadShaped") (EVar "name"))) (EApp (EVar "isSome") (EApp (EApp (EVar "lookupCtor") (EVar "env")) (EVar "name")))))
(DTypeSig true "genBindingRestricted" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "AuthResidual")) (TyFun (TyCon "Bool") (TyFun (TyCon "EffRow") (TyFun (TyCon "Mono") (TyCon "Scheme"))))))))
(DFunDef false "genBindingRestricted" ((PVar "dyn") (PVar "declared") (PVar "residual") (PVar "isValue") (PVar "force") (PVar "t")) (EIf (EVar "isValue") (EApp (EApp (EApp (EApp (EApp (EVar "generalizeBindingDeclared") (EVar "dyn")) (EVar "declared")) (EVar "residual")) (EVar "force")) (EVar "t")) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EVar "lowerToCurrent") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "t"))) (DoExpr (EApp (EApp (EVar "lowerRowLevels") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "currentLevel") "value")) (EVar "force"))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PVar "r")) (EBlock (DoExpr (EApp (EApp (EVar "lowerAuthLevels") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "currentLevel") "value")) (EFieldAccess (EVar "r") "arLower"))) (DoExpr (EApp (EApp (EVar "lowerAuthLevels") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "currentLevel") "value")) (EFieldAccess (EVar "r") "arUpper"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "wantAuthorityWith") (EFieldAccess (EVar "dyn") "dcModule")) (EFieldAccess (EVar "r") "arExact")) (EFieldAccess (EVar "r") "arLower")) (EFieldAccess (EVar "r") "arUpper")))))) (EVar "residual"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Forall") (EListLit)) (EListLit)) (EListLit)) (EListLit)) (EVar "force")) (EVar "t")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "exprLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "exprLoc" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "exprLoc" ((PCon "EDoOrigin" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "exprLoc" (PWild) (EVar "None"))
(DTypeSig false "constraintArgVarName" (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "constraintArgVarName" ((PCon "TyVar" (PVar "v"))) (EApp (EVar "Some") (EVar "v")))
(DFunDef false "constraintArgVarName" (PWild) (EVar "None"))
(DTypeSig true "checkRecursiveValue" (TyFun (TyCon "DynCtx") (TyFun (TyCon "BindingSummary") (TyCon "Unit"))))
(DFunDef false "checkRecursiveValue" ((PVar "dyn") (PVar "owned")) (EApp (EApp (EApp (EApp (EVar "unifyInto") (EVar "dyn")) (EVar "True")) (EFieldAccess (EVar "owned") "bsRecursiveValue")) (EFieldAccess (EVar "owned") "bsValue")))
(DTypeSig true "checkAnnotTooGeneral" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Unit")))))
(DFunDef false "checkAnnotTooGeneral" ((PVar "mctx") (PVar "ty") (PVar "resolved")) (EBlock (DoLet false false (PVar "ids") (EApp (EVar "sigTvarIds") (EVar "resolved"))) (DoExpr (EIf (EBinOp "||" (EBinOp "<" (EApp (EVar "listLen") (EVar "ids")) (EApp (EVar "listLen") (EVar "resolved"))) (EApp (EVar "hasDupI") (EVar "ids"))) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-TYPE-TOO-GENERAL"))) (EApp (EVar "annotTooGeneralMsg") (EVar "ty"))) (ELit LUnit)))))
(DTypeSig true "letGroupComponents" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "LetBind")))))
(DFunDef false "letGroupComponents" ((PVar "binds")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds"))) (DoLet false false (PVar "nameSet") (EApp (EApp (EVar "namesToSet") (EVar "names")) (EVar "omEmpty"))) (DoExpr (EIf (EBinOp "<" (EApp (EVar "omSize") (EVar "nameSet")) (EApp (EVar "listLen") (EVar "names"))) (EListLit (EVar "binds")) (EBlock (DoLet false false (PVar "grouped") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PCon "LetBind" (PVar "n") (PVar "clauses") PWild PWild)) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "funClausePair")) (EVar "clauses"))) (EVar "m")))) (EVar "omEmpty")) (EVar "binds"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "component")) (EBlock (DoLet false false (PVar "members") (EApp (EApp (EVar "namesToSet") (EVar "component")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "letBindName") (EVar "b"))) (EVar "members")))) (EVar "binds")))))) (EApp (EApp (EVar "tarjanSCCs") (EVar "names")) (EApp (EApp (EVar "depGraphMap") (EVar "names")) (EVar "grouped"))))))))))
(DTypeSig false "isSyntacticLambda" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isSyntacticLambda" ((PCon "ELam" PWild PWild)) (EVar "True"))
(DFunDef false "isSyntacticLambda" (PWild) (EVar "False"))
(DTypeSig true "checkLetRecDecls" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "checkLetRecDecls" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "checkLetRecDecls" ((PVar "mctx") (PCons (PCon "DLetGroup" PWild (PVar "binds")) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EVar "checkLetBinds") (EVar "mctx")) (EVar "binds"))) (DoExpr (EApp (EApp (EVar "checkLetRecDecls") (EVar "mctx")) (EVar "rest")))))
(DFunDef false "checkLetRecDecls" ((PVar "mctx") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "checkLetRecDecls") (EVar "mctx")) (EVar "rest")))
(DTypeSig false "checkLetBinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyCon "Unit"))))
(DFunDef false "checkLetBinds" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "checkLetBinds" ((PVar "mctx") (PCons (PCon "LetBind" (PVar "name") (PVar "clauses") PWild PWild) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "checkLetBind") (EVar "mctx")) (EVar "name")) (EVar "clauses"))) (DoExpr (EApp (EApp (EVar "checkLetBinds") (EVar "mctx")) (EVar "rest")))))
(DTypeSig false "checkLetBind" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyCon "Unit")))))
(DFunDef false "checkLetBind" ((PVar "mctx") (PVar "name") (PVar "clauses")) (EIf (EApp (EApp (EVar "allList") (EVar "clauseIsNonFunction")) (EVar "clauses")) (EApp (EApp (EApp (EVar "pushTypeError") (EApp (EApp (EVar "mctxAtIfSome") (EApp (EVar "clausesSpanLoc") (EVar "clauses"))) (EVar "mctx"))) (ELit (LString "T-NONREC-VALUE-LET"))) (EApp (EVar "letRecNonFunctionMsg") (EVar "name"))) (EIf (EVar "otherwise") (ELit LUnit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "clauseIsNonFunction" (TyFun (TyCon "FunClause") (TyCon "Bool")))
(DFunDef false "clauseIsNonFunction" ((PCon "FunClause" (PList) (PVar "rhs"))) (EApp (EVar "not") (EApp (EVar "isSyntacticLambda") (EVar "rhs"))))
(DFunDef false "clauseIsNonFunction" ((PCon "FunClause" PWild PWild)) (EVar "False"))
(DTypeSig true "checkRecBindNonFunction" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Unit")))))
(DFunDef false "checkRecBindNonFunction" ((PVar "mctx") (PVar "name") (PVar "e")) (EIf (EApp (EVar "isSyntacticLambda") (EVar "e")) (ELit LUnit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (ELit (LString "T-NONREC-VALUE-LET"))) (EApp (EVar "exprLoc") (EVar "e"))) (EApp (EVar "letRecNonFunctionMsg") (EVar "name"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "checkLetGroupBindsLocated" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyCon "Unit"))))
(DFunDef false "checkLetGroupBindsLocated" ((PVar "mctx")) (EApp (EVar "checkLetGroupBindsGo") (EVar "mctx")))
(DTypeSig false "checkLetGroupBindsGo" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyCon "Unit"))))
(DFunDef false "checkLetGroupBindsGo" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "checkLetGroupBindsGo" ((PVar "mctx") (PCons (PCon "LetBind" (PVar "name") (PVar "clauses") PWild PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "selfAndForward") (EBinOp "::" (EVar "name") (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "rest")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkClausesNonFunctionLocated") (EVar "mctx")) (EVar "selfAndForward")) (EVar "name")) (EVar "clauses"))) (DoExpr (EApp (EApp (EVar "checkLetGroupBindsGo") (EVar "mctx")) (EVar "rest")))))
(DTypeSig false "checkClausesNonFunctionLocated" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyCon "Unit"))))))
(DFunDef false "checkClausesNonFunctionLocated" ((PVar "mctx") (PVar "names") (PVar "name") (PVar "clauses")) (EIf (EBinOp "&&" (EApp (EApp (EVar "allList") (EVar "clauseIsNonFunction")) (EVar "clauses")) (EApp (EApp (EVar "anyClauseEagerlyRefsGroup") (EVar "names")) (EVar "clauses"))) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (ELit (LString "T-NONREC-VALUE-LET"))) (EApp (EVar "clausesLoc") (EVar "clauses"))) (EApp (EVar "letRecNonFunctionMsg") (EVar "name"))) (EIf (EVar "otherwise") (ELit LUnit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "anyClauseEagerlyRefsGroup" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyCon "Bool"))))
(DFunDef false "anyClauseEagerlyRefsGroup" ((PVar "names") (PVar "clauses")) (EApp (EApp (EVar "anyList") (EApp (EVar "clauseEagerlyRefsGroup") (EVar "names"))) (EVar "clauses")))
(DTypeSig false "clauseEagerlyRefsGroup" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "FunClause") (TyCon "Bool"))))
(DFunDef false "clauseEagerlyRefsGroup" ((PVar "names") (PCon "FunClause" PWild (PVar "rhs"))) (EApp (EApp (EVar "anyMember") (EVar "names")) (EApp (EVar "eagerRefs") (EVar "rhs"))))
(DTypeSig false "clausesLoc" (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "clausesLoc" ((PList)) (EVar "None"))
(DFunDef false "clausesLoc" ((PCons (PCon "FunClause" PWild (PVar "rhs")) PWild)) (EApp (EVar "exprLoc") (EVar "rhs")))
(DTypeSig false "clausesSpanLoc" (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "clausesSpanLoc" ((PList)) (EVar "None"))
(DFunDef false "clausesSpanLoc" ((PCons (PCon "FunClause" PWild (PVar "rhs")) PWild)) (EApp (EVar "exprSpanLoc") (EVar "rhs")))
(DTypeSig false "eagerRefs" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "eagerRefs" ((PCon "EVar" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "eagerRefs" ((PCon "EVarId" (PVar "x") PWild)) (EListLit (EVar "x")))
(DFunDef false "eagerRefs" ((PCon "EMethodAt" (PVar "x") PWild PWild)) (EListLit (EVar "x")))
(DFunDef false "eagerRefs" ((PCon "EDictAt" (PVar "x") PWild)) (EListLit (EVar "x")))
(DFunDef false "eagerRefs" ((PCon "EApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "eagerRefs") (EVar "a")) (EApp (EVar "eagerRefs") (EVar "b"))))
(DFunDef false "eagerRefs" ((PCon "ELam" PWild PWild)) (EListLit))
(DFunDef false "eagerRefs" ((PCon "ELet" PWild PWild PWild (PVar "e1") (PVar "e2"))) (EBinOp "++" (EApp (EVar "eagerRefs") (EVar "e1")) (EApp (EVar "eagerRefs") (EVar "e2"))))
(DFunDef false "eagerRefs" ((PCon "ELetGroup" (PVar "bs") (PVar "e2"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "eagerRefsLetBind")) (EVar "bs")) (EApp (EVar "eagerRefs") (EVar "e2"))))
(DFunDef false "eagerRefs" ((PCon "EMatch" (PVar "e0") (PVar "arms"))) (EBinOp "++" (EApp (EVar "eagerRefs") (EVar "e0")) (EApp (EApp (EDictApp "flatMap") (EVar "eagerRefsArm")) (EVar "arms"))))
(DFunDef false "eagerRefs" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "eagerRefs") (EVar "c")) (EApp (EVar "eagerRefs") (EVar "t"))) (EApp (EVar "eagerRefs") (EVar "el"))))
(DFunDef false "eagerRefs" ((PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "eagerRefs") (EVar "a")) (EApp (EVar "eagerRefs") (EVar "b"))))
(DFunDef false "eagerRefs" ((PCon "EUnOp" PWild (PVar "a") PWild)) (EApp (EVar "eagerRefs") (EVar "a")))
(DFunDef false "eagerRefs" ((PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EBinOp "::" (EVar "op") (EBinOp "++" (EApp (EVar "eagerRefs") (EVar "a")) (EApp (EVar "eagerRefs") (EVar "b")))))
(DFunDef false "eagerRefs" ((PCon "EFieldAccess" (PVar "e0") PWild PWild)) (EApp (EVar "eagerRefs") (EVar "e0")))
(DFunDef false "eagerRefs" ((PCon "ERecordCreate" PWild (PVar "fs"))) (EApp (EApp (EDictApp "flatMap") (EVar "eagerRefsFieldAssign")) (EVar "fs")))
(DFunDef false "eagerRefs" ((PCon "ERecordUpdate" (PVar "e0") (PVar "fs") PWild)) (EBinOp "++" (EApp (EVar "eagerRefs") (EVar "e0")) (EApp (EApp (EDictApp "flatMap") (EVar "eagerRefsFieldAssign")) (EVar "fs"))))
(DFunDef false "eagerRefs" ((PCon "EVariantUpdate" PWild (PVar "e0") (PVar "fs"))) (EBinOp "++" (EApp (EVar "eagerRefs") (EVar "e0")) (EApp (EApp (EDictApp "flatMap") (EVar "eagerRefsFieldAssign")) (EVar "fs"))))
(DFunDef false "eagerRefs" ((PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EVar "eagerRefs")) (EVar "es")))
(DFunDef false "eagerRefs" ((PCon "EListLit" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EVar "eagerRefs")) (EVar "es")))
(DFunDef false "eagerRefs" ((PCon "ETuple" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EVar "eagerRefs")) (EVar "es")))
(DFunDef false "eagerRefs" ((PCon "EIndex" (PVar "e0") (PVar "i"))) (EBinOp "++" (EApp (EVar "eagerRefs") (EVar "e0")) (EApp (EVar "eagerRefs") (EVar "i"))))
(DFunDef false "eagerRefs" ((PCon "ERangeList" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EVar "eagerRefs") (EVar "lo")) (EApp (EVar "eagerRefs") (EVar "hi"))))
(DFunDef false "eagerRefs" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EVar "eagerRefs") (EVar "lo")) (EApp (EVar "eagerRefs") (EVar "hi"))))
(DFunDef false "eagerRefs" ((PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EVar "eagerRefs") (EVar "e0")) (EApp (EVar "eagerRefs") (EVar "lo"))) (EApp (EVar "eagerRefs") (EVar "hi"))))
(DFunDef false "eagerRefs" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EDictApp "flatMap") (EVar "eagerRefsDoStmt")) (EVar "stmts")))
(DFunDef false "eagerRefs" ((PCon "EDo" PWild (PVar "stmts"))) (EApp (EApp (EDictApp "flatMap") (EVar "eagerRefsDoStmt")) (EVar "stmts")))
(DFunDef false "eagerRefs" ((PCon "EAnnot" (PVar "e0") PWild)) (EApp (EVar "eagerRefs") (EVar "e0")))
(DFunDef false "eagerRefs" ((PCon "EHeadAnnot" (PVar "e0") PWild)) (EApp (EVar "eagerRefs") (EVar "e0")))
(DFunDef false "eagerRefs" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EApp (EDictApp "flatMap") (EVar "eagerRefsInterp")) (EVar "parts")))
(DFunDef false "eagerRefs" ((PCon "EGuards" (PVar "arms"))) (EApp (EApp (EDictApp "flatMap") (EVar "eagerRefsGuardArm")) (EVar "arms")))
(DFunDef false "eagerRefs" ((PCon "ESection" (PCon "SecRight" PWild (PVar "e0")))) (EApp (EVar "eagerRefs") (EVar "e0")))
(DFunDef false "eagerRefs" ((PCon "ESection" (PCon "SecLeft" (PVar "e0") PWild))) (EApp (EVar "eagerRefs") (EVar "e0")))
(DFunDef false "eagerRefs" ((PCon "EAsPat" PWild (PVar "e0"))) (EApp (EVar "eagerRefs") (EVar "e0")))
(DFunDef false "eagerRefs" ((PCon "EMapLit" PWild (PVar "kvs"))) (EApp (EApp (EDictApp "flatMap") (EVar "eagerRefsPair")) (EVar "kvs")))
(DFunDef false "eagerRefs" ((PCon "ESetLit" PWild (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EVar "eagerRefs")) (EVar "es")))
(DFunDef false "eagerRefs" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "eagerRefs") (EVar "e")))
(DFunDef false "eagerRefs" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "eagerRefs") (EVar "e")))
(DFunDef false "eagerRefs" (PWild) (EListLit))
(DTypeSig false "eagerRefsLetBind" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "eagerRefsLetBind" ((PCon "LetBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EDictApp "flatMap") (EVar "eagerRefsClauseAllPats")) (EVar "clauses")))
(DTypeSig false "eagerRefsClauseAllPats" (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "eagerRefsClauseAllPats" ((PCon "FunClause" (PList) (PVar "rhs"))) (EApp (EVar "eagerRefs") (EVar "rhs")))
(DFunDef false "eagerRefsClauseAllPats" ((PCon "FunClause" PWild PWild)) (EListLit))
(DTypeSig false "eagerRefsArm" (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "eagerRefsArm" ((PCon "Arm" PWild (PVar "gs") (PVar "body"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "eagerRefsGuard")) (EVar "gs")) (EApp (EVar "eagerRefs") (EVar "body"))))
(DTypeSig false "eagerRefsGuard" (TyFun (TyCon "Guard") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "eagerRefsGuard" ((PCon "GBool" (PVar "e"))) (EApp (EVar "eagerRefs") (EVar "e")))
(DFunDef false "eagerRefsGuard" ((PCon "GBind" PWild (PVar "e"))) (EApp (EVar "eagerRefs") (EVar "e")))
(DTypeSig false "eagerRefsGuardArm" (TyFun (TyCon "GuardArm") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "eagerRefsGuardArm" ((PCon "GuardArm" (PVar "gs") (PVar "body"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "eagerRefsGuard")) (EVar "gs")) (EApp (EVar "eagerRefs") (EVar "body"))))
(DTypeSig false "eagerRefsFieldAssign" (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "eagerRefsFieldAssign" ((PCon "FieldAssign" PWild (PVar "e"))) (EApp (EVar "eagerRefs") (EVar "e")))
(DTypeSig false "eagerRefsDoStmt" (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "eagerRefsDoStmt" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "eagerRefs") (EVar "e")))
(DFunDef false "eagerRefsDoStmt" ((PCon "DoBind" PWild (PVar "e"))) (EApp (EVar "eagerRefs") (EVar "e")))
(DFunDef false "eagerRefsDoStmt" ((PCon "DoLet" PWild PWild PWild (PVar "e") PWild)) (EApp (EVar "eagerRefs") (EVar "e")))
(DFunDef false "eagerRefsDoStmt" (PWild) (EListLit))
(DTypeSig false "eagerRefsInterp" (TyFun (TyCon "InterpPart") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "eagerRefsInterp" ((PCon "InterpExpr" (PVar "e"))) (EApp (EVar "eagerRefs") (EVar "e")))
(DFunDef false "eagerRefsInterp" (PWild) (EListLit))
(DTypeSig false "eagerRefsPair" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "eagerRefsPair" ((PTuple (PVar "k") (PVar "v"))) (EBinOp "++" (EApp (EVar "eagerRefs") (EVar "k")) (EApp (EVar "eagerRefs") (EVar "v"))))
(DTypeSig true "groupNames" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "groupNames" ((PList) PWild) (EListLit))
(DFunDef false "groupNames" ((PCons (PTuple (PVar "n") PWild) (PVar "rest")) (PVar "seen")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "seen")) (arm (PCon "Some" PWild) () (EApp (EApp (EVar "groupNames") (EVar "rest")) (EVar "seen"))) (arm (PCon "None") () (EBinOp "::" (EVar "n") (EApp (EApp (EVar "groupNames") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "seen")))))))
(DTypeSig true "letBindGeneralizes" (TyFun (TyCon "TcEnv") (TyFun (TyTuple (TyCon "LetBind") (TyTuple (TyCon "String") (TyCon "BindingSummary"))) (TyTuple (TyCon "Bool") (TyCon "Mono")))))
(DFunDef false "letBindGeneralizes" ((PVar "env") (PTuple (PCon "LetBind" PWild (PVar "clauses") PWild PWild) (PTuple PWild (PVar "summary")))) (ETuple (EApp (EApp (EVar "clausesAreValue") (EVar "env")) (EVar "clauses")) (EFieldAccess (EVar "summary") "bsValue")))
(DTypeSig true "generalizeGroup" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "AuthResidual"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "LetBind") (TyTuple (TyCon "String") (TyCon "Scheme")))) (TyCon "TcEnv"))))))
(DFunDef false "generalizeGroup" ((PVar "env") PWild PWild (PList)) (EVar "env"))
(DFunDef false "generalizeGroup" ((PVar "env") (PVar "residuals") (PVar "index") (PCons (PTuple (PCon "LetBind" (PVar "name") (PVar "clauses") PWild PWild) (PTuple PWild (PVar "sch"))) (PVar "rest"))) (EBlock (DoLet false false (PVar "mono") (EApp (EVar "schemeMono") (EVar "sch"))) (DoLet false false (PVar "isVal") (EApp (EApp (EVar "clausesAreValue") (EVar "env")) (EVar "clauses"))) (DoLet false false (PVar "env1") (EApp (EApp (EApp (EVar "extendLocalVar") (EVar "env")) (EVar "name")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "genBindingRestricted") (EFieldAccess (EVar "env") "teDyn")) (EVar "Tip")) (EApp (EApp (EVar "residualsOf") (EMethodRef "index")) (EVar "residuals"))) (EVar "isVal")) (EVar "pureRow")) (EVar "mono")))) (DoLet false false (PVar "env2") (EMatch (EVar "clauses") (arm (PList (PCon "FunClause" (PList) (PVar "rhs"))) () (EApp (EApp (EApp (EVar "seedAlphaLets") (EVar "env1")) (EVar "name")) (EVar "rhs"))) (arm PWild () (EVar "env1")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "generalizeGroup") (EVar "env2")) (EVar "residuals")) (EBinOp "+" (EMethodRef "index") (ELit (LInt 1)))) (EVar "rest")))))
(DTypeSig false "clausesAreValue" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyCon "Bool"))))
(DFunDef false "clausesAreValue" ((PVar "env") (PVar "clauses")) (EApp (EApp (EVar "allList") (EApp (EVar "clauseIsValue") (EVar "env"))) (EVar "clauses")))
(DTypeSig false "clauseIsValue" (TyFun (TyCon "TcEnv") (TyFun (TyCon "FunClause") (TyCon "Bool"))))
(DFunDef false "clauseIsValue" ((PVar "env") (PCon "FunClause" (PList) (PVar "rhs"))) (EApp (EApp (EVar "isNonexpansive") (EVar "env")) (EVar "rhs")))
(DFunDef false "clauseIsValue" ((PVar "env") (PCon "FunClause" PWild PWild)) (EVar "True"))
(DTypeSig true "requireGoalsBelow" (TyFun (TyCon "ModuleCtx") (TyFun (TyFun (TyCon "ReqWalk") (TyFun (TyCon "UObligation") (TyApp (TyCon "List") (TyTuple (TyCon "UObligation") (TyCon "ReqWalk"))))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyTuple (TyCon "UObligation") (TyCon "ReqWalk")) (TyApp (TyCon "List") (TyTuple (TyCon "UObligation") (TyCon "ReqWalk")))))))))
(DFunDef false "requireGoalsBelow" ((PVar "mctx") (PVar "enter") (PVar "rigidIds") (PVar "liveIds") (PTuple (PVar "o") (PVar "walk"))) (EBlock (DoLet false false (PVar "args") (EApp (EApp (EMethodRef "map") (EVar "normalize")) (EApp (EApp (EVar "uOblArgs") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "o")))) (DoLet false false (PVar "iface") (EFieldAccess (EFieldAccess (EVar "o") "pred") "iface")) (DoLet false false (PVar "parentIds") (EApp (EApp (EDictApp "flatMap") (EVar "monoUnboundIds")) (EVar "args"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "args")) (EApp (EVar "monoVectorClosed") (EVar "args"))) (EApp (EApp (EVar "goalVarsAllHeld") (EVar "rigidIds")) (EVar "args"))) (EApp (EApp (EApp (EApp (EVar "goalGivenAt") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "iface")) (EVar "args")) (EFieldAccess (EVar "o") "uoScope"))) (EBinOp "&&" (EApp (EApp (EVar "anyList") (ELam ((PVar "i")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "intToString") (EVar "i"))) (EVar "liveIds")))) (EVar "parentIds")) (EApp (EVar "not") (EApp (EApp (EApp (EApp (EVar "undeterminedGoalExempt") (EVar "mctx")) (EVar "iface")) (EVar "args")) (EFieldAccess (EVar "o") "uoScope"))))) (EListLit) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EApp (EVar "goalRows") (EVar "mctx")) (EVar "iface")) (EVar "args"))) (DoLet false false (PVar "reach") (EIf (EApp (EApp (EVar "goalIsProjection") (EVar "args")) (EVar "rows")) (EVar "ReachMany") (EApp (EApp (EApp (EVar "goalReach") (EVar "mctx")) (EVar "args")) (EApp (EApp (EApp (EApp (EVar "goalCandidates") (EVar "mctx")) (EVar "rigidIds")) (EVar "args")) (EVar "rows"))))) (DoExpr (EMatch (EVar "reach") (arm (PCon "ReachOne" (PVar "row")) () (EBlock (DoLet false false (PVar "goalsOf") (ELam ((PVar "ids") (PVar "subst") (PVar "reqs")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "req")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "enter") (EVar "walk"))) (EApp (EApp (EApp (EVar "requireGoalAt") (EVar "o")) (EVar "ids")) (EApp (EApp (EApp (EVar "reqToObligation") (EVar "mctx")) (EVar "subst")) (EVar "req")))))) (EVar "reqs")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "selectedRowReqMatch") (EVar "mctx")) (EVar "args")) (EVar "row")) (arm (PCon "Some" (PTuple (PVar "subst") (PVar "reqs"))) () (EApp (EApp (EApp (EVar "goalsOf") (EVar "parentIds")) (EVar "subst")) (EVar "reqs"))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EApp (EVar "unifiedRowReqs") (EVar "mctx")) (EVar "rigidIds")) (EVar "args")) (EVar "row")) (arm (PCon "Some" (PTuple (PVar "subst") (PVar "fresh") (PVar "reqs"))) () (EApp (EApp (EApp (EVar "goalsOf") (EBinOp "++" (EVar "parentIds") (EVar "fresh"))) (EVar "subst")) (EVar "reqs"))) (arm (PCon "None") () (EListLit)))))))) (arm PWild () (EListLit)))))))))
(DTypeSig false "unifiedRowReqs" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ImplRow") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Require")))))))))
(DFunDef false "unifiedRowReqs" ((PVar "mctx") (PVar "rigidIds") (PVar "args") (PAs "row" (PCon "ImplRow" PWild PWild PWild PWild (PVar "reqs") PWild PWild))) (EBlock (DoLet false false (PTuple (PVar "tvs") (PVar "heads")) (EApp (EApp (EVar "freshRowHeadsTvs") (EVar "mctx")) (EVar "row"))) (DoLet false false (PVar "goalIds") (EApp (EApp (EDictApp "flatMap") (EVar "monoUnboundIds")) (EVar "args"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "headsUnifier") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "rigidIds")) (EVar "args")) (EVar "heads")) (arm (PCon "Some" (PVar "scratch")) () (EIf (EApp (EApp (EVar "allList") (ELam ((PVar "b")) (EBinOp "||" (EApp (EVar "not") (EApp (EApp (EVar "containsI") (EApp (EVar "fst") (EVar "b"))) (EVar "goalIds"))) (EApp (EApp (EApp (EVar "boundaryOwnsOpen") (EVar "mctx")) (EVar "rigidIds")) (EApp (EVar "fst") (EVar "b")))))) (EUnOp "!" (EVar "scratch"))) (EBlock (DoLet false false (PVar "sigCells") (EApp (EApp (EVar "sigCellsOf") (EVar "rigidIds")) (EApp (EApp (EDictApp "flatMap") (EVar "monoVarCells")) (EVar "args")))) (DoLet false false (PVar "bound") (EApp (EApp (EMethodRef "map") (ELam ((PVar "nv")) (ETuple (EApp (EVar "fst") (EVar "nv")) (EApp (EApp (EVar "unrigidSig") (EVar "sigCells")) (EApp (EApp (EVar "cohApply") (EVar "scratch")) (EApp (EVar "snd") (EVar "nv"))))))) (EVar "tvs"))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "bound") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "nv")) (EApp (EVar "monoUnboundIds") (EApp (EVar "snd") (EVar "nv"))))) (EVar "bound")) (EVar "reqs"))))) (EVar "None"))) (arm (PCon "None") () (EVar "None"))))))
(DTypeSig false "requireGoalAt" (TyFun (TyCon "UObligation") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "UObligation"))))))
(DFunDef false "requireGoalAt" ((PVar "o") (PVar "parentIds") (PTuple (PVar "iface") (PVar "args"))) (EIf (EApp (EVar "not") (EApp (EApp (EVar "allList") (ELam ((PVar "i")) (EApp (EApp (EVar "containsI") (EVar "i")) (EVar "parentIds")))) (EApp (EApp (EDictApp "flatMap") (EVar "monoUnboundIds")) (EVar "args")))) (EListLit) (EIf (EVar "otherwise") (EListLit (ERecordCreate "UObligation" ((fa "pred" (ERecordCreate "Predicate" ((fa "iface" (EVar "iface")) (fa "args" (EVar "args"))))) (fa "originId" (EFieldAccess (EVar "o") "originId")) (fa "prov" (EFieldAccess (EVar "o") "prov")) (fa "loc" (EFieldAccess (EVar "o") "loc")) (fa "uoScope" (EFieldAccess (EVar "o") "uoScope")) (fa "oblProj" (EVar "OpProjected"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
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
(DTypeSig true "allEVars" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "allEVars" ((PCon "EVar" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "allEVars" ((PCon "EVarId" (PVar "x") PWild)) (EListLit (EVar "x")))
(DFunDef false "allEVars" ((PCon "EMethodAt" (PVar "n") PWild PWild)) (EListLit (EVar "n")))
(DFunDef false "allEVars" ((PCon "EDictAt" (PVar "n") PWild)) (EListLit (EVar "n")))
(DFunDef false "allEVars" ((PCon "ELit" PWild)) (EListLit))
(DFunDef false "allEVars" ((PCon "EApp" (PVar "f") (PVar "x"))) (EBinOp "++" (EApp (EVar "allEVars") (EVar "f")) (EApp (EVar "allEVars") (EVar "x"))))
(DFunDef false "allEVars" ((PCon "ELam" PWild (PVar "b"))) (EApp (EVar "allEVars") (EVar "b")))
(DFunDef false "allEVars" ((PCon "ELet" PWild PWild PWild (PVar "e1") (PVar "e2"))) (EBinOp "++" (EApp (EVar "allEVars") (EVar "e1")) (EApp (EVar "allEVars") (EVar "e2"))))
(DFunDef false "allEVars" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "letBindEVars")) (EVar "binds")) (EApp (EVar "allEVars") (EVar "body"))))
(DFunDef false "allEVars" ((PCon "EMatch" (PVar "e") (PVar "arms"))) (EBinOp "++" (EApp (EVar "allEVars") (EVar "e")) (EApp (EApp (EDictApp "flatMap") (EVar "armEVars")) (EVar "arms"))))
(DFunDef false "allEVars" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "e"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "allEVars") (EVar "c")) (EApp (EVar "allEVars") (EVar "t"))) (EApp (EVar "allEVars") (EVar "e"))))
(DFunDef false "allEVars" ((PCon "EBinOp" PWild (PVar "l") (PVar "r") PWild)) (EBinOp "++" (EApp (EVar "allEVars") (EVar "l")) (EApp (EVar "allEVars") (EVar "r"))))
(DFunDef false "allEVars" ((PCon "EUnOp" PWild (PVar "e") PWild)) (EApp (EVar "allEVars") (EVar "e")))
(DFunDef false "allEVars" ((PCon "EInfix" (PVar "op") (PVar "l") (PVar "r"))) (EBinOp "::" (EVar "op") (EBinOp "++" (EApp (EVar "allEVars") (EVar "l")) (EApp (EVar "allEVars") (EVar "r")))))
(DFunDef false "allEVars" ((PCon "EFieldAccess" (PVar "e") PWild PWild)) (EApp (EVar "allEVars") (EVar "e")))
(DFunDef false "allEVars" ((PCon "ETuple" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EVar "allEVars")) (EVar "es")))
(DFunDef false "allEVars" ((PCon "EListLit" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EVar "allEVars")) (EVar "es")))
(DFunDef false "allEVars" ((PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EVar "allEVars")) (EVar "es")))
(DFunDef false "allEVars" ((PCon "ERangeList" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "allEVars") (EVar "a")) (EApp (EVar "allEVars") (EVar "b"))))
(DFunDef false "allEVars" ((PCon "ERangeArray" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "allEVars") (EVar "a")) (EApp (EVar "allEVars") (EVar "b"))))
(DFunDef false "allEVars" ((PCon "ESlice" (PVar "e") (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EVar "allEVars") (EVar "e")) (EApp (EVar "allEVars") (EVar "a"))) (EApp (EVar "allEVars") (EVar "b"))))
(DFunDef false "allEVars" ((PCon "EIndex" (PVar "e") (PVar "i"))) (EBinOp "++" (EApp (EVar "allEVars") (EVar "e")) (EApp (EVar "allEVars") (EVar "i"))))
(DFunDef false "allEVars" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "allEVars") (EVar "e")))
(DFunDef false "allEVars" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EDictApp "flatMap") (EVar "doStmtEVars")) (EVar "stmts")))
(DFunDef false "allEVars" ((PCon "ERecordCreate" PWild (PVar "fs"))) (EApp (EApp (EDictApp "flatMap") (EVar "fieldAssignEVars")) (EVar "fs")))
(DFunDef false "allEVars" ((PCon "ERecordUpdate" (PVar "e") (PVar "fs") PWild)) (EBinOp "++" (EApp (EVar "allEVars") (EVar "e")) (EApp (EApp (EDictApp "flatMap") (EVar "fieldAssignEVars")) (EVar "fs"))))
(DFunDef false "allEVars" ((PCon "EVariantUpdate" PWild (PVar "e") (PVar "fs"))) (EBinOp "++" (EApp (EVar "allEVars") (EVar "e")) (EApp (EApp (EDictApp "flatMap") (EVar "fieldAssignEVars")) (EVar "fs"))))
(DFunDef false "allEVars" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "allEVars") (EVar "e")))
(DFunDef false "allEVars" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "allEVars") (EVar "e")))
(DFunDef false "allEVars" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EVar "allEVars") (EVar "e")))
(DFunDef false "allEVars" ((PCon "EAsPat" PWild (PVar "e"))) (EApp (EVar "allEVars") (EVar "e")))
(DFunDef false "allEVars" ((PCon "EMapLit" PWild (PVar "kvs"))) (EApp (EApp (EDictApp "flatMap") (EVar "kvEVars")) (EVar "kvs")))
(DFunDef false "allEVars" ((PCon "ESetLit" PWild (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EVar "allEVars")) (EVar "es")))
(DFunDef false "allEVars" ((PCon "EDo" PWild (PVar "stmts"))) (EApp (EApp (EDictApp "flatMap") (EVar "doStmtEVars")) (EVar "stmts")))
(DFunDef false "allEVars" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EApp (EDictApp "flatMap") (EVar "interpEVars")) (EVar "parts")))
(DFunDef false "allEVars" ((PCon "EGuards" (PVar "arms"))) (EApp (EApp (EDictApp "flatMap") (EVar "guardArmEVars")) (EVar "arms")))
(DFunDef false "allEVars" ((PCon "ESection" (PVar "s"))) (EApp (EVar "sectionEVars") (EVar "s")))
(DFunDef false "allEVars" (PWild) (EListLit))
(DTypeSig false "kvEVars" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "kvEVars" ((PTuple (PVar "k") (PVar "v"))) (EBinOp "++" (EApp (EVar "allEVars") (EVar "k")) (EApp (EVar "allEVars") (EVar "v"))))
(DTypeSig false "interpEVars" (TyFun (TyCon "InterpPart") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "interpEVars" ((PCon "InterpStr" PWild)) (EListLit))
(DFunDef false "interpEVars" ((PCon "InterpExpr" (PVar "e"))) (EApp (EVar "allEVars") (EVar "e")))
(DTypeSig false "guardArmEVars" (TyFun (TyCon "GuardArm") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "guardArmEVars" ((PCon "GuardArm" (PVar "guards") (PVar "body"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "guardEVars")) (EVar "guards")) (EApp (EVar "allEVars") (EVar "body"))))
(DTypeSig false "sectionEVars" (TyFun (TyCon "Section") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "sectionEVars" ((PCon "SecBare" (PVar "op"))) (EListLit (EVar "op")))
(DFunDef false "sectionEVars" ((PCon "SecRight" (PVar "op") (PVar "e"))) (EBinOp "::" (EVar "op") (EApp (EVar "allEVars") (EVar "e"))))
(DFunDef false "sectionEVars" ((PCon "SecLeft" (PVar "e") (PVar "op"))) (EBinOp "::" (EVar "op") (EApp (EVar "allEVars") (EVar "e"))))
(DTypeSig false "letBindEVars" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "letBindEVars" ((PCon "LetBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EDictApp "flatMap") (EVar "funClauseEVars")) (EVar "clauses")))
(DTypeSig false "funClauseEVars" (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "funClauseEVars" ((PCon "FunClause" PWild (PVar "body"))) (EApp (EVar "allEVars") (EVar "body")))
(DTypeSig false "armEVars" (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "armEVars" ((PCon "Arm" PWild (PVar "guards") (PVar "body"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "guardEVars")) (EVar "guards")) (EApp (EVar "allEVars") (EVar "body"))))
(DTypeSig false "guardEVars" (TyFun (TyCon "Guard") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "guardEVars" ((PCon "GBool" (PVar "e"))) (EApp (EVar "allEVars") (EVar "e")))
(DFunDef false "guardEVars" ((PCon "GBind" PWild (PVar "e"))) (EApp (EVar "allEVars") (EVar "e")))
(DTypeSig false "doStmtEVars" (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "doStmtEVars" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "allEVars") (EVar "e")))
(DFunDef false "doStmtEVars" ((PCon "DoLet" PWild PWild PWild (PVar "e") PWild)) (EApp (EVar "allEVars") (EVar "e")))
(DFunDef false "doStmtEVars" ((PCon "DoBind" PWild (PVar "e"))) (EApp (EVar "allEVars") (EVar "e")))
(DFunDef false "doStmtEVars" ((PCon "DoAssign" PWild (PVar "e"))) (EApp (EVar "allEVars") (EVar "e")))
(DFunDef false "doStmtEVars" ((PCon "DoFieldAssign" PWild PWild (PVar "e"))) (EApp (EVar "allEVars") (EVar "e")))
(DTypeSig false "fieldAssignEVars" (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "fieldAssignEVars" ((PCon "FieldAssign" PWild (PVar "e"))) (EApp (EVar "allEVars") (EVar "e")))
(DTypeSig false "freeEVars" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EVar" (PVar "x"))) (EApp (EApp (EVar "freeName") (EVar "bound")) (EVar "x")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EVarId" (PVar "x") PWild)) (EApp (EApp (EVar "freeName") (EVar "bound")) (EVar "x")))
(DFunDef false "freeEVars" (PWild (PCon "EMethodAt" (PVar "n") PWild PWild)) (EListLit (EVar "n")))
(DFunDef false "freeEVars" (PWild (PCon "EDictAt" (PVar "n") PWild)) (EListLit (EVar "n")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EApp" (PVar "f") (PVar "x"))) (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "f")) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "x"))))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "ELam" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "freeEVars") (EApp (EApp (EVar "namesToSet") (EApp (EVar "patVarsListTc") (EVar "ps"))) (EVar "bound"))) (EVar "b")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "ELet" PWild (PVar "r") (PVar "p") (PVar "e1") (PVar "e2"))) (EBlock (DoLet false false (PVar "after") (EApp (EApp (EVar "namesToSet") (EApp (EVar "patVarsTc") (EVar "p"))) (EVar "bound"))) (DoExpr (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EIf (EVar "r") (EVar "after") (EVar "bound"))) (EVar "e1")) (EApp (EApp (EVar "freeEVars") (EVar "after")) (EVar "e2"))))))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "namesToSet") (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds"))) (EVar "bound"))) (DoExpr (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EVar "freeLetBindEVars") (EVar "inner"))) (EVar "binds")) (EApp (EApp (EVar "freeEVars") (EVar "inner")) (EVar "body"))))))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EMatch" (PVar "e") (PVar "arms"))) (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "freeArmEVars") (EVar "bound"))) (EVar "arms"))))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EIf" (PVar "c") (PVar "t") (PVar "e"))) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "c")) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "t"))) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e"))))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EBinOp" PWild (PVar "l") (PVar "r") PWild)) (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "l")) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "r"))))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EUnOp" PWild (PVar "e") PWild)) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EInfix" (PVar "op") (PVar "l") (PVar "r"))) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "freeName") (EVar "bound")) (EVar "op")) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "l"))) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "r"))))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EFieldAccess" (PVar "e") PWild PWild)) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "ETuple" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "freeEVars") (EVar "bound"))) (EVar "es")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EListLit" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "freeEVars") (EVar "bound"))) (EVar "es")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "freeEVars") (EVar "bound"))) (EVar "es")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "ERangeList" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "a")) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "b"))))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "ERangeArray" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "a")) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "b"))))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "ESlice" (PVar "e") (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "a"))) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "b"))))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EIndex" (PVar "e") (PVar "i"))) (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "i"))))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EAnnot" (PVar "e") PWild)) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "freeStmtsEVars") (EVar "bound")) (EVar "stmts")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "ERecordCreate" PWild (PVar "fs"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "freeFieldEVars") (EVar "bound"))) (EVar "fs")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "ERecordUpdate" (PVar "e") (PVar "fs") PWild)) (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "freeFieldEVars") (EVar "bound"))) (EVar "fs"))))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EVariantUpdate" PWild (PVar "e") (PVar "fs"))) (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "freeFieldEVars") (EVar "bound"))) (EVar "fs"))))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "ELoc" PWild (PVar "e"))) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EAsPat" PWild (PVar "e"))) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EMapLit" PWild (PVar "kvs"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "freeKvEVars") (EVar "bound"))) (EVar "kvs")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "ESetLit" PWild (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "freeEVars") (EVar "bound"))) (EVar "es")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EDo" PWild (PVar "stmts"))) (EApp (EApp (EVar "freeStmtsEVars") (EVar "bound")) (EVar "stmts")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EStringInterp" (PVar "parts"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "freeInterpEVars") (EVar "bound"))) (EVar "parts")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "EGuards" (PVar "arms"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "freeGuardArmEVars") (EVar "bound"))) (EVar "arms")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "ESection" (PCon "SecBare" (PVar "op")))) (EApp (EApp (EVar "freeName") (EVar "bound")) (EVar "op")))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "ESection" (PCon "SecRight" (PVar "op") (PVar "e")))) (EBinOp "++" (EApp (EApp (EVar "freeName") (EVar "bound")) (EVar "op")) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e"))))
(DFunDef false "freeEVars" ((PVar "bound") (PCon "ESection" (PCon "SecLeft" (PVar "e") (PVar "op")))) (EBinOp "++" (EApp (EApp (EVar "freeName") (EVar "bound")) (EVar "op")) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e"))))
(DFunDef false "freeEVars" (PWild (PCon "ELit" PWild)) (EListLit))
(DFunDef false "freeEVars" (PWild (PCon "ENumLit" PWild PWild PWild)) (EListLit))
(DFunDef false "freeEVars" (PWild (PCon "EWideLit" PWild PWild PWild PWild)) (EListLit))
(DFunDef false "freeEVars" (PWild (PCon "EDictApp" PWild)) (EListLit))
(DFunDef false "freeEVars" (PWild (PCon "EMethodRef" PWild)) (EListLit))
(DFunDef false "freeEVars" (PWild (PCon "EVarAt" PWild PWild)) (EListLit))
(DTypeSig false "freeKvEVars" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "freeKvEVars" ((PVar "bound") (PTuple (PVar "k") (PVar "v"))) (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "k")) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "v"))))
(DTypeSig false "freeName" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "freeName" ((PVar "bound") (PVar "x")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "x")) (EVar "bound")) (EListLit) (EListLit (EVar "x"))))
(DTypeSig false "freeInterpEVars" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "InterpPart") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "freeInterpEVars" (PWild (PCon "InterpStr" PWild)) (EListLit))
(DFunDef false "freeInterpEVars" ((PVar "bound") (PCon "InterpExpr" (PVar "e"))) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")))
(DTypeSig false "freeFieldEVars" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "freeFieldEVars" ((PVar "bound") (PCon "FieldAssign" PWild (PVar "e"))) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")))
(DTypeSig false "freeLetBindEVars" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "freeLetBindEVars" ((PVar "bound") (PCon "LetBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "c")) (EApp (EApp (EVar "clauseRefsUnder") (EVar "bound")) (EApp (EVar "funClausePair") (EVar "c"))))) (EVar "clauses")))
(DTypeSig false "clauseRefsUnder" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "clauseRefsUnder" ((PVar "bound") (PTuple (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "freeEVars") (EApp (EApp (EVar "namesToSet") (EApp (EVar "patVarsListTc") (EVar "ps"))) (EVar "bound"))) (EVar "body")))
(DTypeSig false "freeArmEVars" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "freeArmEVars" ((PVar "bound") (PCon "Arm" (PVar "p") (PVar "guards") (PVar "body"))) (EApp (EApp (EApp (EVar "freeGuardsEVars") (EApp (EApp (EVar "namesToSet") (EApp (EVar "patVarsTc") (EVar "p"))) (EVar "bound"))) (EVar "guards")) (EVar "body")))
(DTypeSig false "freeGuardArmEVars" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GuardArm") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "freeGuardArmEVars" ((PVar "bound") (PCon "GuardArm" (PVar "guards") (PVar "body"))) (EApp (EApp (EApp (EVar "freeGuardsEVars") (EVar "bound")) (EVar "guards")) (EVar "body")))
(DTypeSig false "freeGuardsEVars" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "freeGuardsEVars" ((PVar "bound") (PList) (PVar "body")) (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "body")))
(DFunDef false "freeGuardsEVars" ((PVar "bound") (PCons (PCon "GBool" (PVar "e")) (PVar "rest")) (PVar "body")) (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")) (EApp (EApp (EApp (EVar "freeGuardsEVars") (EVar "bound")) (EVar "rest")) (EVar "body"))))
(DFunDef false "freeGuardsEVars" ((PVar "bound") (PCons (PCon "GBind" (PVar "p") (PVar "e")) (PVar "rest")) (PVar "body")) (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")) (EApp (EApp (EApp (EVar "freeGuardsEVars") (EApp (EApp (EVar "namesToSet") (EApp (EVar "patVarsTc") (EVar "p"))) (EVar "bound"))) (EVar "rest")) (EVar "body"))))
(DTypeSig false "freeStmtsEVars" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "freeStmtsEVars" (PWild (PList)) (EListLit))
(DFunDef false "freeStmtsEVars" ((PVar "bound") (PCons (PCon "DoExpr" (PVar "e")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")) (EApp (EApp (EVar "freeStmtsEVars") (EVar "bound")) (EVar "rest"))))
(DFunDef false "freeStmtsEVars" ((PVar "bound") (PCons (PCon "DoLet" PWild (PVar "r") (PVar "p") (PVar "e") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "after") (EApp (EApp (EVar "namesToSet") (EApp (EVar "patVarsTc") (EVar "p"))) (EVar "bound"))) (DoExpr (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EIf (EVar "r") (EVar "after") (EVar "bound"))) (EVar "e")) (EApp (EApp (EVar "freeStmtsEVars") (EVar "after")) (EVar "rest"))))))
(DFunDef false "freeStmtsEVars" ((PVar "bound") (PCons (PCon "DoBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")) (EApp (EApp (EVar "freeStmtsEVars") (EApp (EApp (EVar "namesToSet") (EApp (EVar "patVarsTc") (EVar "p"))) (EVar "bound"))) (EVar "rest"))))
(DFunDef false "freeStmtsEVars" ((PVar "bound") (PCons (PCon "DoAssign" (PVar "x") (PVar "e")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")) (EApp (EApp (EVar "freeStmtsEVars") (EApp (EApp (EVar "namesToSet") (EListLit (EVar "x"))) (EVar "bound"))) (EVar "rest"))))
(DFunDef false "freeStmtsEVars" ((PVar "bound") (PCons (PCon "DoFieldAssign" PWild PWild (PVar "e")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "freeEVars") (EVar "bound")) (EVar "e")) (EApp (EApp (EVar "freeStmtsEVars") (EVar "bound")) (EVar "rest"))))
(DTypeSig true "depGraphMap" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "depGraphMap" ((PVar "names") (PVar "grouped")) (EApp (EApp (EApp (EApp (EVar "buildAdj") (EVar "names")) (EApp (EApp (EVar "namesToSet") (EVar "names")) (EVar "omEmpty"))) (EVar "grouped")) (EVar "omEmpty")))
(DTypeSig true "groupClauses" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "groupClauses" ((PVar "defs")) (EApp (EApp (EVar "groupClausesGo") (EVar "defs")) (EVar "omEmpty")))
(DTypeSig false "groupClausesGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))
(DFunDef false "groupClausesGo" ((PList) (PVar "m")) (EVar "m"))
(DFunDef false "groupClausesGo" ((PCons (PTuple (PVar "n") (PVar "c")) (PVar "rest")) (PVar "m")) (EApp (EApp (EVar "groupClausesGo") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EBinOp "::" (EVar "c") (EApp (EApp (EVar "clausesAt") (EVar "n")) (EVar "m")))) (EVar "m"))))
(DTypeSig false "buildAdj" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "buildAdj" ((PList) PWild PWild (PVar "m")) (EVar "m"))
(DFunDef false "buildAdj" ((PCons (PVar "n") (PVar "rest")) (PVar "nameSet") (PVar "cbn") (PVar "m")) (EApp (EApp (EApp (EApp (EVar "buildAdj") (EVar "rest")) (EVar "nameSet")) (EVar "cbn")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EApp (EApp (EApp (EVar "depsOf") (EVar "n")) (EVar "nameSet")) (EVar "cbn"))) (EVar "m"))))
(DTypeSig false "depsOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "depsOf" ((PVar "name") (PVar "nameSet") (PVar "cbn")) (EApp (EApp (EVar "filterNonSelf") (EVar "name")) (EApp (EApp (EVar "keepGroupNames") (EVar "nameSet")) (EApp (EVar "dedup") (EApp (EVar "groupRefs") (EApp (EApp (EVar "clausesOf") (EVar "name")) (EVar "cbn")))))))
(DTypeSig false "groupRefs" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "groupRefs" ((PVar "clauses")) (EApp (EApp (EDictApp "flatMap") (EVar "clauseRefs")) (EVar "clauses")))
(DTypeSig false "clauseRefs" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "clauseRefs" ((PVar "clause")) (EApp (EApp (EVar "clauseRefsUnder") (EVar "omEmpty")) (EVar "clause")))
(DTypeSig false "keepGroupNames" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "keepGroupNames" ((PVar "nameSet") (PVar "refs")) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EVar "omHasKey") (EVar "r")) (EVar "nameSet")))) (EVar "refs")))
(DTypeSig false "filterNonSelf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "filterNonSelf" ((PVar "name") (PVar "xs")) (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (EVar "name")))) (EVar "xs")))
(DTypeSig false "forwardedVecObls" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "List") (TyCon "VecObl")))))))
(DFunDef false "forwardedVecObls" ((PVar "mctx") (PVar "generalizing") (PVar "boundIds") (PVar "callObls")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "vecOblOfPred") (EVar "mctx")) (EVar "generalizing")) (EVar "boundIds"))) (EApp (EApp (EDictApp "flatMap") (EVar "callPredOf")) (EVar "callObls"))))
(DTypeSig true "isLetrecGroup" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "isLetrecGroup" ((PList)) (EVar "False"))
(DFunDef false "isLetrecGroup" ((PList PWild)) (EVar "False"))
(DFunDef false "isLetrecGroup" (PWild) (EVar "True"))
(DTypeSig true "memberForce" (TyFun (TyCon "ScopedMember") (TyCon "EffRow")))
(DFunDef false "memberForce" ((PVar "member")) (EApp (EApp (EVar "optionOr") (EApp (EApp (EVar "optionOr") (EVar "pureRow")) (EFieldAccess (EVar "member") "smForce"))) (EFieldAccess (EFieldAccess (EVar "member") "smForceBound") "value")))
(DTypeSig false "sigTvMapUnboundIds" (TyFun (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "sigTvMapUnboundIds" ((PTuple PWild PWild (PVar "tvs"))) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "p")) (EApp (EVar "monoUnboundIds") (EApp (EVar "snd") (EVar "p"))))) (EVar "tvs")))
(DTypeSig true "sccProtectedSignatureIds" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))
(DFunDef false "sccProtectedSignatureIds" ((PVar "sigTvMaps")) (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (EVar "intToString")) (EApp (EApp (EDictApp "flatMap") (EVar "sigTvMapUnboundIds")) (EVar "sigTvMaps")))) (EVar "omEmpty")))
(DTypeSig true "sigConstraints" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "sigConstraints" ((PCon "TyConstrained" (PVar "cs") PWild)) (EApp (EApp (EDictApp "flatMap") (EVar "constraintTyVars")) (EVar "cs")))
(DFunDef false "sigConstraints" (PWild) (EListLit))
(DTypeSig false "constraintTyVars" (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "constraintTyVars" ((PRec "Constraint" ((rf "constraintHead" (PVar "iface")) (rf "constraintArgs" (PVar "tys")) (rf "constraintOrigin" (PVar "co"))) false)) (EMatch (EApp (EVar "tyVarArgNames") (EVar "tys")) (arm (PList) () (EListLit)) (arm (PVar "ns") () (EListLit (ETuple (ERecordCreate "IfaceRef" ((fa "irName" (EVar "iface")) (fa "irOrigin" (EVar "co")))) (EVar "ns"))))))
(DTypeSig false "tyVarArgNames" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "tyVarArgNames" ((PVar "tys")) (EApp (EVar "dedup") (EApp (EApp (EDictApp "flatMap") (EVar "tyVarNames")) (EVar "tys"))))
(DTypeSig true "sigConstraintArgTys" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Ty")))))
(DFunDef false "sigConstraintArgTys" ((PCon "TyConstrained" (PVar "cs") PWild)) (EApp (EApp (EDictApp "flatMap") (EVar "constraintTyVarArgs")) (EVar "cs")))
(DFunDef false "sigConstraintArgTys" (PWild) (EListLit))
(DTypeSig false "constraintTyVarArgs" (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Ty")))))
(DFunDef false "constraintTyVarArgs" ((PRec "Constraint" ((rf "constraintArgs" (PVar "tys"))) false)) (EMatch (EApp (EVar "tyVarArgNames") (EVar "tys")) (arm (PList) () (EListLit)) (arm PWild () (EListLit (EVar "tys")))))
(DTypeSig true "constraintVarIfaceMonos" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")))))))
(DFunDef false "constraintVarIfaceMonos" ((PList) PWild) (EListLit))
(DFunDef false "constraintVarIfaceMonos" ((PCons (PTuple (PVar "iface") (PVar "names")) (PVar "rest")) (PVar "tvMap")) (EMatch (EApp (EApp (EVar "constraintNameMonos") (EVar "names")) (EVar "tvMap")) (arm (PList) () (EApp (EApp (EVar "constraintVarIfaceMonos") (EVar "rest")) (EVar "tvMap"))) (arm (PVar "monos") () (EBinOp "::" (ETuple (EVar "iface") (EVar "monos")) (EApp (EApp (EVar "constraintVarIfaceMonos") (EVar "rest")) (EVar "tvMap"))))))
(DTypeSig true "constraintVarArgMonos" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Ty"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Mono"))))))))
(DFunDef false "constraintVarArgMonos" ((PVar "mctx") (PList) PWild PWild) (EListLit))
(DFunDef false "constraintVarArgMonos" ((PVar "mctx") PWild (PList) PWild) (EListLit))
(DFunDef false "constraintVarArgMonos" ((PVar "mctx") (PCons (PTuple PWild (PVar "names")) (PVar "rest")) (PCons (PVar "args") (PVar "argsRest")) (PVar "tvMap")) (EMatch (EApp (EApp (EVar "constraintNameMonos") (EVar "names")) (EVar "tvMap")) (arm (PList) () (EApp (EApp (EApp (EApp (EVar "constraintVarArgMonos") (EVar "mctx")) (EVar "rest")) (EVar "argsRest")) (EVar "tvMap"))) (arm PWild () (EBinOp "::" (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "fromAstType") (EVar "mctx")) (EVar "tvMap"))) (EVar "args")) (EApp (EApp (EApp (EApp (EVar "constraintVarArgMonos") (EVar "mctx")) (EVar "rest")) (EVar "argsRest")) (EVar "tvMap"))))))
(DTypeSig true "sccSchemes" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "AuthResidual"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "ScopedMember")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))))))
(DFunDef false "sccSchemes" ((PVar "env") PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "sccSchemes" ((PVar "env") (PVar "sigs") (PVar "grouped") (PVar "isLetrec") (PVar "residuals") (PVar "index") (PCons (PVar "member") (PVar "rest"))) (EBlock (DoLet false false (PVar "m") (EFieldAccess (EVar "member") "smName")) (DoLet false false (PVar "isVal") (EApp (EApp (EVar "allList") (EApp (EVar "memberClauseIsValue") (EVar "env"))) (EApp (EApp (EVar "clausesOf") (EVar "m")) (EVar "grouped")))) (DoExpr (EBinOp "::" (ETuple (EVar "m") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "genBindingRestricted") (EFieldAccess (EVar "env") "teDyn")) (EFieldAccess (EFieldAccess (EVar "member") "smDeclaredAuths") "value")) (EApp (EApp (EVar "residualsOf") (EMethodRef "index")) (EVar "residuals"))) (EVar "isVal")) (EApp (EVar "memberForce") (EVar "member"))) (EFieldAccess (EVar "member") "smMono"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "sccSchemes") (EVar "env")) (EVar "sigs")) (EVar "grouped")) (EVar "isLetrec")) (EVar "residuals")) (EBinOp "+" (EMethodRef "index") (ELit (LInt 1)))) (EVar "rest"))))))
(DTypeSig true "quantifiableAuthorities" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyCon "ScopedMember")) (TyCon "ScopeRoles")))))
(DFunDef false "quantifiableAuthorities" ((PVar "env") (PVar "grouped") (PVar "members")) (EApp (EVar "scopeRolesOf") (EApp (EApp (EMethodRef "map") (ELam ((PVar "member")) (ETuple (EApp (EApp (EVar "memberRole") (EApp (EApp (EVar "omHasKey") (EFieldAccess (EVar "member") "smName")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "sigNameSetRef") "value"))) (EApp (EApp (EVar "allList") (EApp (EVar "memberClauseIsValue") (EVar "env"))) (EApp (EApp (EVar "clausesOf") (EFieldAccess (EVar "member") "smName")) (EVar "grouped")))) (EFieldAccess (EVar "member") "smMono")))) (EVar "members"))))
(DTypeSig false "memberRole" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyCon "BindingRole"))))
(DFunDef false "memberRole" ((PCon "True") PWild) (EVar "RoleDeclared"))
(DFunDef false "memberRole" ((PCon "False") (PCon "True")) (EVar "RoleQuantifies"))
(DFunDef false "memberRole" ((PCon "False") (PCon "False")) (EVar "RoleMonomorphic"))
(DTypeSig true "scopeRolesOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "BindingRole") (TyCon "Mono"))) (TyCon "ScopeRoles")))
(DFunDef false "scopeRolesOf" ((PVar "members")) (EBlock (DoLet false false (PVar "owners") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PTuple (PVar "acc") (PVar "index")) (PTuple (PVar "role") (PVar "mono"))) (EBlock (DoLet false false (PVar "ids") (EMatch (EVar "role") (arm (PCon "RoleQuantifies") () (EApp (EVar "IdMap.keys") (EApp (EApp (EVar "qualifierAuthIds") (EVar "mono")) (EVar "Tip")))) (arm PWild () (EListLit)))) (DoExpr (ETuple (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PVar "id")) (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (EBinOp "::" (EMethodRef "index") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EVar "m"))))) (EVar "m")))) (EVar "acc")) (EVar "ids")) (EBinOp "+" (EMethodRef "index") (ELit (LInt 1)))))))) (ETuple (EVar "Tip") (ELit (LInt 0)))) (EVar "members"))) (DoExpr (ERecordCreate "ScopeRoles" ((fa "rlQuantified" (EApp (EApp (EApp (EVar "IdMap.foldlWithKey") (ELam ((PVar "acc") (PVar "id") (PVar "indices")) (EMatch (EVar "indices") (arm (PList (PVar "index")) () (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (EMethodRef "index")) (EVar "acc"))) (arm PWild () (EVar "acc"))))) (EVar "Tip")) (EApp (EVar "fst") (EVar "owners")))) (fa "rlOutward" (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PTuple (PVar "role") (PVar "mono"))) (EMatch (EVar "role") (arm (PCon "RoleMonomorphic") () (EApp (EApp (EVar "authIdsIn") (EVar "mono")) (EVar "acc"))) (arm PWild () (EVar "acc"))))) (EVar "Tip")) (EVar "members"))) (fa "rlTyped" (EApp (EVar "Some") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PTuple PWild (PVar "mono"))) (EApp (EApp (EVar "authIdsIn") (EVar "mono")) (EVar "acc")))) (EVar "Tip")) (EVar "members")))) (fa "rlMemberAuths" (ELam (PWild) (EApp (EApp (EMethodRef "map") (ELam ((PTuple PWild (PVar "mono"))) (EApp (EApp (EVar "authIdsIn") (EVar "mono")) (EVar "Tip")))) (EVar "members")))))))))
(DTypeSig true "residualsOf" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "AuthResidual"))) (TyApp (TyCon "List") (TyCon "AuthResidual")))))
(DFunDef false "residualsOf" ((PVar "index") (PVar "residuals")) (EApp (EApp (EDictApp "flatMap") (ELam ((PTuple (PVar "owner") (PVar "r"))) (EIf (EBinOp "==" (EVar "owner") (EMethodRef "index")) (EListLit (EVar "r")) (EListLit)))) (EVar "residuals")))
(DTypeSig false "memberClauseIsValue" (TyFun (TyCon "TcEnv") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyCon "Bool"))))
(DFunDef false "memberClauseIsValue" ((PVar "env") (PTuple (PList) (PVar "rhs"))) (EApp (EApp (EVar "isNonexpansive") (EVar "env")) (EVar "rhs")))
(DFunDef false "memberClauseIsValue" ((PVar "env") (PTuple PWild PWild)) (EVar "True"))
(DTypeSig true "checkSigsOverExpansive" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyCon "Unit")))))
(DFunDef false "checkSigsOverExpansive" ((PVar "env") PWild (PList)) (ELit LUnit))
(DFunDef false "checkSigsOverExpansive" ((PVar "env") (PVar "grouped") (PCons (PTuple (PVar "m") (PVar "ty") (PVar "tvs")) (PVar "rest"))) (EBlock (DoExpr (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EMethodRef "isEmpty") (EVar "tvs"))) (EApp (EVar "not") (EApp (EApp (EVar "allList") (EApp (EVar "memberClauseIsValue") (EVar "env"))) (EApp (EApp (EVar "clausesOf") (EVar "m")) (EVar "grouped"))))) (EApp (EApp (EApp (EVar "pushTypeError") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (ELit (LString "T-SIG-OVER-EXPANSIVE"))) (EApp (EApp (EVar "sigOverExpansiveMsg") (EVar "m")) (EVar "ty"))) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "checkSigsOverExpansive") (EVar "env")) (EVar "grouped")) (EVar "rest")))))
(DTypeSig true "checkSigsTooGeneral" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyCon "Unit"))))
(DFunDef false "checkSigsTooGeneral" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "checkSigsTooGeneral" ((PVar "mctx") (PCons (PTuple (PVar "m") (PVar "ty") (PVar "tvs")) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "checkSigTooGeneral") (EVar "mctx")) (EVar "m")) (EVar "ty")) (EVar "tvs"))) (DoExpr (EApp (EApp (EVar "checkSigsTooGeneral") (EVar "mctx")) (EVar "rest")))))
(DTypeSig false "checkSigTooGeneral" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyCon "Unit"))))))
(DFunDef false "checkSigTooGeneral" ((PVar "mctx") (PVar "name") (PVar "ty") (PVar "tvs")) (EBlock (DoLet false false (PVar "tvarIds") (EApp (EVar "sigTvarIds") (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "tvs")))) (DoExpr (EMatch (EApp (EVar "groundedSignatureVariable") (EVar "tvs")) (arm (PCon "Some" (PTuple (PVar "vname") (PVar "actual"))) () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-TYPE-TOO-GENERAL"))) (EApp (EVar "firstTyLoc") (EVar "ty"))) (EApp (EApp (EApp (EVar "groundedSigVarMsg") (EVar "vname")) (EVar "name")) (EVar "actual")))) (arm (PCon "None") () (EIf (EApp (EVar "hasDupI") (EVar "tvarIds")) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-TYPE-TOO-GENERAL"))) (EApp (EApp (EVar "sigTooGeneralMsg") (EVar "name")) (EVar "ty"))) (ELit LUnit)))))))
(DTypeSig false "groundedSignatureVariable" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Mono")))))
(DFunDef false "groundedSignatureVariable" ((PList)) (EVar "None"))
(DFunDef false "groundedSignatureVariable" ((PCons (PTuple (PVar "name") (PVar "mono")) (PVar "rest"))) (EMatch (EApp (EVar "normalize") (EVar "mono")) (arm (PCon "TVar" PWild) () (EApp (EVar "groundedSignatureVariable") (EVar "rest"))) (arm (PVar "actual") () (EApp (EVar "Some") (ETuple (EVar "name") (EVar "actual"))))))
(DTypeSig true "checkSigsFixedByExpansive" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyCon "ScopedMember")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyCon "Unit"))))))
(DFunDef false "checkSigsFixedByExpansive" ((PVar "env") (PVar "grouped") (PVar "members") (PVar "sigTvMaps")) (EBlock (DoLet false false (PVar "fixed") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "member")) (EIf (EBinOp "||" (EFieldAccess (EFieldAccess (EVar "member") "smSigned") "value") (EApp (EApp (EVar "allList") (EApp (EVar "memberClauseIsValue") (EVar "env"))) (EApp (EApp (EVar "clausesOf") (EFieldAccess (EVar "member") "smName")) (EVar "grouped")))) (EListLit) (EApp (EApp (EMethodRef "map") (ELam ((PVar "id")) (ETuple (EVar "id") (EFieldAccess (EVar "member") "smName")))) (EApp (EVar "monoUnboundIds") (EFieldAccess (EVar "member") "smMono")))))) (EVar "members"))) (DoExpr (EMatch (EVar "fixed") (arm (PList) () (ELit LUnit)) (arm PWild () (EApp (EApp (EApp (EVar "checkSigsFixedBy") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "fixed")) (EVar "sigTvMaps")))))))
(DTypeSig false "checkSigsFixedBy" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyCon "Unit")))))
(DFunDef false "checkSigsFixedBy" ((PVar "mctx") PWild (PList)) (ELit LUnit))
(DFunDef false "checkSigsFixedBy" ((PVar "mctx") (PVar "fixed") (PCons (PTuple (PVar "name") (PVar "ty") (PVar "tvs")) (PVar "rest"))) (EBlock (DoExpr (EMatch (EApp (EApp (EVar "sigVarFixedBy") (EVar "fixed")) (EVar "tvs")) (arm (PCon "Some" (PTuple (PVar "vname") (PVar "sibling"))) () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-TYPE-TOO-GENERAL"))) (EApp (EVar "firstTyLoc") (EVar "ty"))) (EApp (EApp (EApp (EVar "siblingSharedSigVarMsg") (EVar "vname")) (EVar "name")) (EVar "sibling")))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EApp (EApp (EApp (EVar "checkSigsFixedBy") (EVar "mctx")) (EVar "fixed")) (EVar "rest")))))
(DTypeSig false "sigVarFixedBy" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "sigVarFixedBy" (PWild (PList)) (EVar "None"))
(DFunDef false "sigVarFixedBy" ((PVar "fixed") (PCons (PTuple (PVar "vname") (PVar "mono")) (PVar "rest"))) (EMatch (EApp (EVar "normalize") (EVar "mono")) (arm (PCon "TVar" (PVar "cell")) () (EMatch (EApp (EApp (EVar "fixedSibling") (EApp (EVar "tyvarId") (EVar "cell"))) (EVar "fixed")) (arm (PCon "Some" (PVar "sibling")) () (EApp (EVar "Some") (ETuple (EVar "vname") (EVar "sibling")))) (arm (PCon "None") () (EApp (EApp (EVar "sigVarFixedBy") (EVar "fixed")) (EVar "rest"))))) (arm PWild () (EApp (EApp (EVar "sigVarFixedBy") (EVar "fixed")) (EVar "rest")))))
(DTypeSig false "fixedSibling" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "fixedSibling" (PWild (PList)) (EVar "None"))
(DFunDef false "fixedSibling" ((PVar "id") (PCons (PTuple (PVar "i") (PVar "sibling")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "i") (EVar "id")) (EApp (EVar "Some") (EVar "sibling")) (EIf (EVar "otherwise") (EApp (EApp (EVar "fixedSibling") (EVar "id")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "registerSchemeObligations" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "Loc")))) (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyCon "Unit"))))))))
(DFunDef false "registerSchemeObligations" ((PVar "mctx") PWild PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "registerSchemeObligations" ((PVar "mctx") (PVar "memberDefIds") (PVar "sigTvMaps") (PVar "callObls") (PVar "addedObls") (PCons (PTuple (PVar "m") (PVar "sch")) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "deferrableVarIds")) (EApp (EApp (EVar "idSetInsertAll") (EApp (EVar "schemeIds") (EVar "sch"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "deferrableVarIds") "value")))) (DoLet false false (PVar "obs") (EApp (EVar "dedupVecObls") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "schemeOblsForMember") (EVar "mctx")) (EVar "sigTvMaps")) (EVar "callObls")) (EVar "addedObls")) (EVar "m")) (EVar "sch")))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "obs")) (ELit LUnit) (EBlock (DoLet false false (PVar "defId") (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EVar "m")) (EVar "memberDefIds")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "schemeObligationsRef")) (EBinOp "::" (ETuple (ETuple (EVar "m") (EVar "defId")) (EVar "obs")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "schemeObligationsRef") "value"))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerSchemeObligations") (EVar "mctx")) (EVar "memberDefIds")) (EVar "sigTvMaps")) (EVar "callObls")) (EVar "addedObls")) (EVar "rest")))))
(DTypeSig false "schemeOblsForMember" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "Loc")))) (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyFun (TyCon "String") (TyFun (TyCon "Scheme") (TyApp (TyCon "List") (TyCon "VecObl")))))))))
(DFunDef false "schemeOblsForMember" ((PVar "mctx") (PVar "sigTvMaps") (PVar "callObls") (PVar "addedObls") (PVar "m") (PVar "sch")) (EMatch (EApp (EApp (EVar "lookupSigTvMap") (EVar "m")) (EVar "sigTvMaps")) (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EApp (EVar "declaredSchemeOblsFor") (EVar "mctx")) (EVar "sigTvMaps")) (EVar "m")) (EApp (EVar "schemeIds") (EVar "sch")))) (arm (PCon "None") () (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "schemeObligationsOf") (EVar "mctx")) (EVar "True")) (EApp (EVar "schemeIds") (EVar "sch"))) (EVar "addedObls")) (EApp (EApp (EApp (EApp (EVar "forwardedVecObls") (EVar "mctx")) (EVar "True")) (EApp (EVar "schemeIds") (EVar "sch"))) (EVar "callObls"))))))
(DTypeSig false "declaredSchemeOblsFor" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "VecObl")))))))
(DFunDef false "declaredSchemeOblsFor" ((PVar "mctx") (PVar "sigTvMaps") (PVar "m") (PVar "boundIds")) (EMatch (EApp (EApp (EVar "lookupSigTvMap") (EVar "m")) (EVar "sigTvMaps")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple (PVar "ty") (PVar "tvMap"))) () (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "declaredOblOne") (EVar "mctx")) (EVar "boundIds")) (EVar "tvMap"))) (EApp (EVar "sigConstraintsOf") (EVar "ty"))))))
(DTypeSig false "declaredOblOne" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyCon "VecObl")))))))
(DFunDef false "declaredOblOne" ((PVar "mctx") (PVar "boundIds") (PVar "tvMap") (PRec "Constraint" ((rf "constraintHead" (PVar "iface")) (rf "constraintArgs" (PVar "args")) (rf "constraintOrigin" (PVar "co"))) false)) (EBlock (DoLet false false (PVar "ifref") (ERecordCreate "IfaceRef" ((fa "irName" (EVar "iface")) (fa "irOrigin" (EVar "co"))))) (DoExpr (EMatch (EApp (EApp (EVar "constraintArgMonos") (EVar "args")) (EVar "tvMap")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "declaredOblMixed") (EVar "mctx")) (EVar "boundIds")) (EVar "ifref")) (EVar "tvMap")) (EVar "args"))) (arm (PCon "Some" (PVar "monos")) () (EMatch (EApp (EApp (EVar "boundTyvarIds") (EVar "boundIds")) (EVar "monos")) (arm (PCon "Some" (PVar "ids")) () (EListLit (ERecordCreate "VecObl" ((fa "voIface" (EVar "ifref")) (fa "voIds" (EVar "ids")) (fa "voArgs" (EListLit)))))) (arm (PCon "None") () (EListLit))))))))
(DTypeSig false "declaredOblMixed" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "VecObl"))))))))
(DFunDef false "declaredOblMixed" ((PVar "mctx") (PVar "boundIds") (PVar "ifref") (PVar "tvMap") (PVar "args")) (EBlock (DoLet false false (PVar "monos") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "fromAstType") (EVar "mctx")) (EVar "tvMap"))) (EVar "args"))) (DoLet false false (PVar "ids") (EApp (EApp (EDictApp "flatMap") (EApp (EVar "declaredOblArgId") (EVar "boundIds"))) (EVar "monos"))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "ids")) (EApp (EVar "not") (EApp (EApp (EVar "allList") (EApp (EVar "declaredOblArgOk") (ELam ((PVar "i")) (EApp (EApp (EVar "containsI") (EVar "i")) (EVar "boundIds"))))) (EVar "monos")))) (EListLit) (EListLit (ERecordCreate "VecObl" ((fa "voIface" (EVar "ifref")) (fa "voIds" (EVar "ids")) (fa "voArgs" (EVar "monos")))))))))
(DTypeSig false "constraintArgMonos" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Mono"))))))
(DFunDef false "constraintArgMonos" ((PList) PWild) (EApp (EVar "Some") (EListLit)))
(DFunDef false "constraintArgMonos" ((PCons (PVar "a") (PVar "rest")) (PVar "tvMap")) (EMatch (EApp (EApp (EVar "constraintArgMono") (EVar "a")) (EVar "tvMap")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "mono")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "mono") (EVar "_s")))) (EApp (EApp (EVar "constraintArgMonos") (EVar "rest")) (EVar "tvMap"))))))
(DTypeSig false "constraintArgMono" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyCon "Mono")))))
(DFunDef false "constraintArgMono" ((PVar "a") (PVar "tvMap")) (EMatch (EApp (EVar "constraintArgVarName") (EVar "a")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "v")) () (EApp (EApp (EVar "lookupAssoc") (EVar "v")) (EVar "tvMap")))))
(DTypeSig false "lookupSigTvMap" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyApp (TyCon "Option") (TyTuple (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))))))
(DFunDef false "lookupSigTvMap" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupSigTvMap" ((PVar "m") (PCons (PTuple (PVar "n") (PVar "ty") (PVar "tvMap")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "m") (EVar "n")) (EApp (EVar "Some") (ETuple (EVar "ty") (EVar "tvMap"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupSigTvMap") (EVar "m")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dedupVecObls" (TyFun (TyApp (TyCon "List") (TyCon "VecObl")) (TyApp (TyCon "List") (TyCon "VecObl"))))
(DFunDef false "dedupVecObls" ((PVar "xs")) (EApp (EApp (EVar "dedupBy") (EVar "vecOblKey")) (EVar "xs")))
(DTypeSig false "vecOblKey" (TyFun (TyCon "VecObl") (TyCon "String")))
(DFunDef false "vecOblKey" ((PVar "o")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "lenKey") (EFieldAccess (EFieldAccess (EVar "o") "voIface") "irName")))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EApp (EApp (EMethodRef "map") (EVar "intToString")) (EFieldAccess (EVar "o") "voIds"))))) (ELit (LString "|"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EApp (EApp (EMethodRef "map") (EVar "oblArgKey")) (EFieldAccess (EVar "o") "voArgs"))))) (ELit (LString ""))))
(DTypeSig false "containsVecObl" (TyFun (TyCon "VecObl") (TyFun (TyApp (TyCon "List") (TyCon "VecObl")) (TyCon "Bool"))))
(DFunDef false "containsVecObl" (PWild (PList)) (EVar "False"))
(DFunDef false "containsVecObl" ((PVar "o") (PCons (PVar "o2") (PVar "rest"))) (EBinOp "||" (EBinOp "&&" (EApp (EApp (EVar "sameIfaceDecl") (EFieldAccess (EVar "o") "voIface")) (EFieldAccess (EVar "o2") "voIface")) (EBinOp "==" (EFieldAccess (EVar "o") "voIds") (EFieldAccess (EVar "o2") "voIds"))) (EApp (EApp (EVar "containsVecObl") (EVar "o")) (EVar "rest"))))
(DTypeSig false "schemeObligationsOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyApp (TyCon "List") (TyCon "VecObl")))))))
(DFunDef false "schemeObligationsOf" ((PVar "mctx") (PVar "generalizing") (PVar "boundIds") (PVar "obls")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "vecOblOfPred") (EVar "mctx")) (EVar "generalizing")) (EVar "boundIds"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "oblPredOf") (EFieldAccess (EVar "mctx") "mcGraph"))) (EVar "obls"))))
(DTypeSig false "vecOblOfPred" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "VecObl")))))))
(DFunDef false "vecOblOfPred" ((PVar "mctx") (PVar "generalizing") (PVar "boundIds") (PTuple (PVar "iface") (PVar "ds") (PVar "loc"))) (EMatch (EApp (EApp (EVar "boundTyvarIds") (EVar "boundIds")) (EVar "ds")) (arm (PCon "Some" (PVar "ids")) () (EListLit (ERecordCreate "VecObl" ((fa "voIface" (EVar "iface")) (fa "voIds" (EVar "ids")) (fa "voArgs" (EListLit)))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "residualVecObls") (EVar "mctx")) (EVar "generalizing")) (EVar "boundIds")) (EVar "iface")) (EVar "ds")) (EVar "loc")))))
(DTypeSig false "residualVecObls" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "List") (TyCon "VecObl")))))))))
(DFunDef false "residualVecObls" ((PVar "mctx") (PVar "generalizing") (PVar "boundIds") (PVar "iface") (PVar "ds") (PVar "loc")) (EApp (EApp (EMethodRef "map") (EVar "keepBoundResidual")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "residualBoundPreds") (EApp (EVar "siteFor") (EVar "mctx"))) (EVar "generalizing")) (EVar "boundIds")) (EVar "iface")) (EVar "ds")) (EVar "loc"))))
(DTypeSig false "keepBoundResidual" (TyFun (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Mono"))) (TyCon "VecObl")))
(DFunDef false "keepBoundResidual" ((PTuple (PVar "iface") (PVar "ids") (PVar "args"))) (ERecordCreate "VecObl" ((fa "voIface" (EVar "iface")) (fa "voIds" (EVar "ids")) (fa "voArgs" (EApp (EApp (EVar "residualOblArgs") (EVar "ids")) (EVar "args"))))))
(DTypeSig false "residualOblArgs" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "residualOblArgs" ((PVar "ids") (PVar "args")) (EIf (EBinOp "&&" (EApp (EApp (EVar "allList") (EVar "isBareTyvarMono")) (EVar "args")) (EBinOp "==" (EApp (EVar "listLen") (EVar "ids")) (EApp (EVar "listLen") (EVar "args")))) (EListLit) (EIf (EVar "otherwise") (EVar "args") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "pairsOfVecObls" (TyFun (TyApp (TyCon "List") (TyCon "VecObl")) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyCon "Int")))))
(DFunDef false "pairsOfVecObls" ((PList)) (EListLit))
(DFunDef false "pairsOfVecObls" ((PCons (PVar "o") (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "id")) (ETuple (EFieldAccess (EVar "o") "voIface") (EVar "id")))) (EFieldAccess (EVar "o") "voIds")) (EApp (EVar "pairsOfVecObls") (EVar "rest"))))
(DTypeSig true "checkSigConstraintCoverage" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "ConstraintReg")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "Loc")))) (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyCon "Unit")))))))))
(DFunDef false "checkSigConstraintCoverage" ((PVar "mctx") PWild PWild PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "checkSigConstraintCoverage" ((PVar "mctx") (PVar "regs") (PVar "sigs") (PVar "sigTvMaps") (PVar "callObls") (PVar "addedObls") (PCons (PTuple (PVar "m") (PVar "sch")) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkSigConstraintOne") (EVar "mctx")) (EVar "regs")) (EVar "sigs")) (EVar "sigTvMaps")) (EVar "callObls")) (EVar "addedObls")) (EVar "m")) (EVar "sch"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkSigConstraintCoverage") (EVar "mctx")) (EVar "regs")) (EVar "sigs")) (EVar "sigTvMaps")) (EVar "callObls")) (EVar "addedObls")) (EVar "rest")))))
(DTypeSig false "checkSigConstraintOne" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "ConstraintReg")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "Loc")))) (TyFun (TyApp (TyCon "List") (TyCon "UObligation")) (TyFun (TyCon "String") (TyFun (TyCon "Scheme") (TyCon "Unit"))))))))))
(DFunDef false "checkSigConstraintOne" ((PVar "mctx") (PVar "regs") (PVar "sigs") (PVar "sigTvMaps") (PVar "callObls") (PVar "addedObls") (PVar "m") (PVar "sch")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "m")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "sigTyMapRef") "value")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" PWild) () (EBlock (DoLet false false (PVar "declaredPairs") (EApp (EApp (EVar "censusSuperClose") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "declaredPairsFor") (EVar "m")) (EVar "regs")))) (DoLet false false (PVar "boundIds") (EApp (EVar "schemeIds") (EVar "sch"))) (DoLet false false (PVar "bodyVecs") (EApp (EApp (EVar "quantifiedVecObls") (EVar "boundIds")) (EApp (EApp (EApp (EApp (EVar "schemeObligationsOf") (EVar "mctx")) (EVar "False")) (EVar "boundIds")) (EVar "addedObls")))) (DoLet false false (PVar "fwdVecs") (EApp (EApp (EVar "quantifiedVecObls") (EVar "boundIds")) (EApp (EApp (EApp (EApp (EVar "forwardedVecObls") (EVar "mctx")) (EVar "False")) (EVar "boundIds")) (EVar "callObls")))) (DoLet false false (PVar "inferredB") (EApp (EApp (EApp (EVar "inferredIfacePairs") (EVar "mctx")) (EVar "m")) (EVar "boundIds"))) (DoLet false false (PVar "inferred") (EApp (EVar "dedupIfacePairs") (EBinOp "++" (EBinOp "++" (EApp (EVar "pairsOfVecObls") (EVar "bodyVecs")) (EApp (EVar "pairsOfVecObls") (EVar "fwdVecs"))) (EVar "inferredB")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "reportUncovered") (EVar "mctx")) (EVar "m")) (EVar "sigTvMaps")) (EVar "declaredPairs")) (EVar "inferred"))) (DoLet false false (PVar "declaredVecs") (EApp (EApp (EVar "censusSuperCloseVec") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EApp (EApp (EVar "declaredSchemeOblsFor") (EVar "mctx")) (EVar "sigTvMaps")) (EVar "m")) (EVar "boundIds")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reportUncoveredVec") (EVar "mctx")) (EVar "m")) (EVar "sigTvMaps")) (EVar "declaredPairs")) (EVar "declaredVecs")) (EBinOp "++" (EVar "bodyVecs") (EVar "fwdVecs"))))))))
(DTypeSig false "quantifiedVecObls" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "VecObl")) (TyApp (TyCon "List") (TyCon "VecObl")))))
(DFunDef false "quantifiedVecObls" ((PVar "boundIds") (PVar "vecs")) (EApp (EApp (EVar "filterList") (ELam ((PVar "o")) (EApp (EApp (EVar "allList") (ELam ((PVar "id")) (EApp (EApp (EVar "containsI") (EVar "id")) (EVar "boundIds")))) (EApp (EApp (EDictApp "flatMap") (EVar "monoUnboundIds")) (EFieldAccess (EVar "o") "voArgs"))))) (EVar "vecs")))
(DTypeSig false "inferredIfacePairs" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyCon "Int")))))))
(DFunDef false "inferredIfacePairs" ((PVar "mctx") (PVar "m") (PVar "boundIds")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "pairIface") (EVar "mctx")) (EVar "m"))) (EApp (EApp (EApp (EVar "inferredConstraintIds") (EVar "mctx")) (EVar "m")) (EVar "boundIds"))))
(DTypeSig false "pairIface" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyCon "Int")))))))
(DFunDef false "pairIface" ((PVar "mctx") (PVar "m") (PVar "id")) (EBlock (DoLet false false (PVar "ir") (EApp (EApp (EApp (EVar "ifaceForInferredId") (EVar "mctx")) (EVar "m")) (EVar "id"))) (DoExpr (EMatch (EFieldAccess (EVar "ir") "irName") (arm (PLit (LString "")) () (EListLit)) (arm PWild () (EListLit (ETuple (EVar "ir") (EVar "id"))))))))
(DTypeSig false "declaredPairsFor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ConstraintReg")) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyCon "Int"))))))
(DFunDef false "declaredPairsFor" ((PVar "m") (PVar "regs")) (EApp (EApp (EDictApp "flatMap") (EVar "declaredPairOne")) (EApp (EApp (EVar "regIfaceMonosFor") (EVar "m")) (EVar "regs"))))
(DTypeSig false "regIfaceMonosFor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ConstraintReg")) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")))))))
(DFunDef false "regIfaceMonosFor" (PWild (PList)) (EListLit))
(DFunDef false "regIfaceMonosFor" ((PVar "m") (PCons (PVar "reg") (PVar "rest"))) (EIf (EBinOp "==" (EVar "m") (EFieldAccess (EVar "reg") "crName")) (EFieldAccess (EVar "reg") "crIfaceMonos") (EIf (EVar "otherwise") (EApp (EApp (EVar "regIfaceMonosFor") (EVar "m")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "declaredPairOne" (TyFun (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyCon "Int")))))
(DFunDef false "declaredPairOne" ((PTuple (PVar "iface") (PVar "monos"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "id")) (ETuple (EVar "iface") (EVar "id")))) (EApp (EVar "abstractSlotIds") (EVar "monos"))))
(DTypeSig false "censusSuperClose" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyCon "Int"))))))
(DFunDef false "censusSuperClose" ((PVar "gctx") (PVar "declared")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EFieldAccess (EVar "n") "superIface") (EFieldAccess (EVar "n") "superPayload")))) (EApp (EApp (EApp (EApp (EVar "superClosure") (EApp (EVar "superLookup") (EVar "gctx"))) (EVar "censusSuperStep")) (ELam ((PVar "iface") (PVar "id")) (EApp (EVar "ifacePairKey") (ETuple (EVar "iface") (EVar "id"))))) (EVar "declared"))))
(DTypeSig false "censusSuperStep" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Super") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "censusSuperStep" ((PVar "typarams") (PVar "id") (PRec "Super" ((rf "superParams" (PVar "params"))) true)) (EIf (EApp (EVar "not") (EApp (EApp (EDictApp "all") (ELam ((PVar "p")) (EApp (EApp (EVar "contains") (EVar "p")) (EVar "typarams")))) (EVar "params"))) (EVar "None") (EIf (EApp (EVar "isEmptyL") (EVar "params")) (EApp (EVar "Some") (ELit (LInt 0))) (EIf (EVar "otherwise") (EApp (EVar "Some") (EVar "id")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "censusSuperCloseVec" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "VecObl")) (TyApp (TyCon "List") (TyCon "VecObl")))))
(DFunDef false "censusSuperCloseVec" ((PVar "gctx") (PVar "declared")) (EApp (EApp (EMethodRef "map") (EVar "vecOblOfNode")) (EApp (EApp (EApp (EApp (EVar "superClosure") (EApp (EVar "superLookup") (EVar "gctx"))) (EVar "censusVecSuperStep")) (ELam ((PVar "iface") (PVar "payload")) (EApp (EVar "vecOblKey") (EApp (EVar "vecOblOfNode") (ERecordCreate "SuperNode" ((fa "superPath" (EListLit)) (fa "superIface" (EVar "iface")) (fa "superPayload" (EVar "payload")))))))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "o")) (ETuple (EFieldAccess (EVar "o") "voIface") (ETuple (EFieldAccess (EVar "o") "voIds") (EFieldAccess (EVar "o") "voArgs"))))) (EVar "declared")))))
(DTypeSig false "censusVecSuperStep" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Mono"))) (TyFun (TyCon "Super") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Mono"))))))))
(DFunDef false "censusVecSuperStep" ((PVar "typarams") (PTuple (PVar "ids") PWild) (PRec "Super" ((rf "superParams" (PVar "params"))) true)) (EApp (EApp (EMethodRef "map") (ELam ((PVar "mapped")) (ETuple (EVar "mapped") (EListLit)))) (EApp (EApp (EVar "mapAll") (ELam ((PVar "p")) (EApp (EApp (EApp (EVar "lookupPos") (EVar "p")) (EVar "typarams")) (EVar "ids")))) (EVar "params"))))
(DTypeSig false "vecOblOfNode" (TyFun (TyApp (TyCon "SuperNode") (TyTuple (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Mono")))) (TyCon "VecObl")))
(DFunDef false "vecOblOfNode" ((PVar "n")) (EBlock (DoLet false false (PTuple (PVar "ids") (PVar "args")) (EFieldAccess (EVar "n") "superPayload")) (DoExpr (ERecordCreate "VecObl" ((fa "voIface" (EFieldAccess (EVar "n") "superIface")) (fa "voIds" (EVar "ids")) (fa "voArgs" (EVar "args")))))))
(DTypeSig false "reportUncoveredVec" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "VecObl")) (TyFun (TyApp (TyCon "List") (TyCon "VecObl")) (TyCon "Unit"))))))))
(DFunDef false "reportUncoveredVec" ((PVar "mctx") PWild PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "reportUncoveredVec" ((PVar "mctx") (PVar "m") (PVar "sigTvMaps") (PVar "declaredPairs") (PVar "declaredVecs") (PCons (PVar "o") (PVar "rest"))) (EBlock (DoExpr (EIf (EBinOp "<" (EApp (EVar "listLen") (EFieldAccess (EVar "o") "voIds")) (ELit (LInt 2))) (ELit LUnit) (EIf (EApp (EApp (EVar "containsVecObl") (EVar "o")) (EVar "declaredVecs")) (ELit LUnit) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EVar "allPairsIn") (EFieldAccess (EVar "o") "voIface")) (EFieldAccess (EVar "o") "voIds")) (EVar "declaredPairs"))) (ELit LUnit) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-MISSING-CONSTRAINT"))) (EApp (EApp (EApp (EVar "missingConstraintVecMsg") (EVar "m")) (EFieldAccess (EFieldAccess (EVar "o") "voIface") "irName")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "varNameForId") (EVar "sigTvMaps")) (EVar "m"))) (EFieldAccess (EVar "o") "voIds")))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reportUncoveredVec") (EVar "mctx")) (EVar "m")) (EVar "sigTvMaps")) (EVar "declaredPairs")) (EVar "declaredVecs")) (EVar "rest")))))
(DTypeSig false "allPairsIn" (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyCon "Int"))) (TyCon "Bool")))))
(DFunDef false "allPairsIn" ((PVar "iface") (PVar "ids") (PVar "declaredPairs")) (EApp (EApp (EVar "allList") (ELam ((PVar "id")) (EApp (EApp (EVar "containsIfacePair") (ETuple (EVar "iface") (EVar "id"))) (EVar "declaredPairs")))) (EVar "ids")))
(DTypeSig false "reportUncovered" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyCon "Int"))) (TyCon "Unit")))))))
(DFunDef false "reportUncovered" ((PVar "mctx") PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "reportUncovered" ((PVar "mctx") (PVar "m") (PVar "sigTvMaps") (PVar "declared") (PCons (PTuple (PVar "iface") (PVar "id")) (PVar "rest"))) (EBlock (DoExpr (EIf (EApp (EApp (EVar "containsIfacePair") (ETuple (EVar "iface") (EVar "id"))) (EVar "declared")) (ELit LUnit) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-MISSING-CONSTRAINT"))) (EApp (EApp (EApp (EVar "missingConstraintMsg") (EVar "m")) (EFieldAccess (EVar "iface") "irName")) (EApp (EApp (EApp (EVar "varNameForId") (EVar "sigTvMaps")) (EVar "m")) (EVar "id")))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "reportUncovered") (EVar "mctx")) (EVar "m")) (EVar "sigTvMaps")) (EVar "declared")) (EVar "rest")))))
(DTypeSig false "containsIfacePair" (TyFun (TyTuple (TyCon "IfaceRef") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyCon "Int"))) (TyCon "Bool"))))
(DFunDef false "containsIfacePair" (PWild (PList)) (EVar "False"))
(DFunDef false "containsIfacePair" ((PTuple (PVar "i") (PVar "d")) (PCons (PTuple (PVar "i2") (PVar "d2")) (PVar "rest"))) (EBinOp "||" (EBinOp "&&" (EApp (EApp (EVar "sameIfaceDecl") (EVar "i")) (EVar "i2")) (EBinOp "==" (EVar "d") (EVar "d2"))) (EApp (EApp (EVar "containsIfacePair") (ETuple (EVar "i") (EVar "d"))) (EVar "rest"))))
(DTypeSig false "dedupIfacePairs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyCon "Int")))))
(DFunDef false "dedupIfacePairs" ((PVar "xs")) (EApp (EApp (EVar "dedupBy") (EVar "ifacePairKey")) (EVar "xs")))
(DTypeSig false "ifacePairKey" (TyFun (TyTuple (TyCon "IfaceRef") (TyCon "Int")) (TyCon "String")))
(DFunDef false "ifacePairKey" ((PTuple (PVar "iface") (PVar "id"))) (EBinOp "++" (EApp (EVar "regKeyRender") (EApp (EVar "regKeyOfTab") (EApp (EVar "oblIfaceKey") (EVar "iface")))) (EApp (EVar "intToString") (EVar "id"))))
(DTypeSig true "declRefNames" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declRefNames" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declRefNames") (EVar "d")))
(DFunDef false "declRefNames" ((PCon "DFunDef" PWild PWild PWild (PVar "body") PWild PWild)) (EApp (EVar "allEVars") (EVar "body")))
(DFunDef false "declRefNames" ((PCon "DProp" PWild PWild PWild (PVar "body"))) (EApp (EVar "allEVars") (EVar "body")))
(DFunDef false "declRefNames" ((PCon "DTest" PWild PWild (PVar "body"))) (EApp (EVar "allEVars") (EVar "body")))
(DFunDef false "declRefNames" ((PCon "DLetGroup" PWild (PVar "binds"))) (EApp (EApp (EDictApp "flatMap") (EVar "letBindEVars")) (EVar "binds")))
(DFunDef false "declRefNames" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EDictApp "flatMap") (EVar "implMethodEVars")) (EVar "methods")))
(DFunDef false "declRefNames" ((PRec "DInterface" ((rf "methods" None)) true)) (EApp (EApp (EDictApp "flatMap") (EVar "ifaceMethodEVars")) (EVar "methods")))
(DFunDef false "declRefNames" (PWild) (EListLit))
(DTypeSig false "implMethodEVars" (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "implMethodEVars" ((PCon "ImplMethod" PWild PWild (PVar "body"))) (EApp (EVar "allEVars") (EVar "body")))
(DTypeSig false "ifaceMethodEVars" (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ifaceMethodEVars" ((PCon "IfaceMethod" PWild PWild (PVar "d") PWild)) (EMatch (EVar "d") (arm (PCon "Some" (PCon "MethodDefault" PWild (PVar "body"))) () (EApp (EVar "allEVars") (EVar "body"))) (arm (PCon "None") () (EListLit))))
