# META
source_lines=2396
stages=DESUGAR,MARK
# SOURCE
-- tc_solve_entail: entailment as routes: the judgment `P ⊢ π ⇝ e` at a site (`entail` and its
-- assumption, instance, determined and rigid-lead arms `entailAssum`, `entailInst`,
-- `entailDetermined`, `entailRigidLead`), the selection of the most specific matching impl row
-- (`ieSelectRowByIface`, `ieSelectRowByMethod`, `pickMostSpecificEntry`, `goalCandidates`,
-- `goalReach`) with the closed-goal ambiguous-overlap report (`goalsClosed`,
-- `reportAmbiguousOverlap`), the route words a site stamps (`keyForSite`, `stampOpRouteVal`,
-- `stampPredicateOpRouteVal`), the route walk over a selected row's `requires` and supers with its
-- memo (`routeOfD`, `argImplRequiresRoutesForRow` and `superRouteAt` are mutually recursive;
-- `routeWalkMemoized` is outside that cycle, taking the follow function as an argument), the
-- return-position route selection (`selectReturnRow`, `legacyReturnReqRoutesForRow`), and instance
-- matching for the judgments above entailment (`implMatchesU`, `implMatchesWithReqsU`,
-- `findMatchingImplReqsU` and the bucket readers `univConcreteBucket`, `univHeadless`).
--
-- Spec: DICT section 3 (the entailment judgment, specificity, determination, W2 the termination
-- measure of the route walk), section 5 (return-position dispatch through the dictionary), section
-- 6.1 (the per-goal unique minimum), section 6.2 T3 (the closed goal), section 8 I2 (qualified
-- instance identity).
--
-- Placement: declarations are placed by R1-R6 of the Phase 4 module table,
-- compiler/ARCHITECTURE-PLAYBOOK.md section 6.
-- Closure rule: this module may not import `types.typecheck`, nor any of `tc_solve`,
-- `tc_solve_check`, `tc_shadow`, `tc_effects`, `tc_occurrence`, `tc_groups`, `tc_pat`,
-- `tc_infer_records`, `tc_infer`, `tc_elab`, `tc_global`, `tc_module`.

import types.tc_types.{
  PredicateSlotArgs(..),
  AssumAnswer(..),
  EntailKind(..),
  GoalReach(..),
  ImplUniverse(..),
  NumericPredicateTraceEntry(..),
  NumericPredicateTraceStage(..),
  PredicateRequest(..),
  ReqStep(..),
  RouteWalkEntry(..),
  SiteCtx(..),
  Undetermined(..),
  WalkMemo(..),
  GraphCtx,
  ImplEnv,
  ImplRow,
  KeyEntry,
  ModuleCtx,
  ReqWalk,
}
import types.tc_mono.{
  anyListM,
  cohEqMono,
  cohOverlapGo,
  containsI,
  dedupI,
  headsUnifier,
  headTyconMono,
  headTySpineNode,
  isBareTyvarMono,
  matchEqMono,
  matchTyMono,
  mergeOne,
  mergeSubstPreferConcrete,
  monoSizes,
  monoUnboundIds,
  monoVecSameGiven,
  monoVectorClosed,
  rigidSigPairs,
  tyHeadEqV,
  tyStrictlyMoreSpecificV,
  tySubsumesV,
  tyvarId,
  tyVarNames,
}
import types.tc_diag_text.{ambiguousOverlapMsg}
import types.tc_env.{
  ieCandidatesForIface,
  ieCandidatesForMethod,
  ieDefinesReqMethodAt,
  ieEntriesForIface,
  ieHeadRows,
  ieRowHeadTriple,
  ieRowIface,
  ieRowOfEntry,
  ieRowOfIface,
  ieRowsAll,
  ieRowTys,
  keyEntryIface,
  originMethodName,
  sameIfaceDecl,
  superLookup,
  dispHeadTab,
  oblIfaceKey,
}
import types.tc_diag.{erredDuring, pushAmbiguityAt, typeErrorsArmed}
import types.tc_scope.{methodAdmissionHere, methodEntryHere, methodIfaceHere}
import types.tc_unify.{freshTvMap}
import types.tc_decls_types.{fromAstType}
import types.tc_solve_givens.{
  activeDictPredOf,
  activeDictVarAnswering,
  activeDictVarOf,
  activeDictVarOfEncl,
  activeFunDictPredOf,
  activeFunDictPredOfResidual,
  assumAnswerRoute,
  enclDictVarOf,
  implReqDictVarOf,
  noteAssumption,
  scalarGivenAnswers,
}
import types.solver_contract.{ClassPredicate(..)}
import types.registry.{
  HeadKey(..), headKeyTag, mregLookupK, regKeyNTab, regKeyOfTab
}
import types.repr.{IfaceRef(..), Mono(..), normalize}
import types.evidence_complete.{Inner(..), innerNone, innerOfRoute, innerOr}
import frontend.ast.{
  Loc(..),
  Require(..),
  Route(..),
  Super(..),
  Ty(..),
  isBoxed64Head,
  isFixedIntHead,
  isTaggedFixedHead,
}
import support.ordmap.{
  omEmpty, omFromNames, omHasKey, omInsert, omLookup, OrdMap
}
import types.evidence.{ScopeId(..)}
import support.util.{
  allList,
  anyList,
  contains,
  dedup,
  filterList,
  isEmptyL,
  isSome,
  listLen,
  lookupAssoc,
  isNonEmptyL,
}
import types.runtime_ops.{arithmeticTag}
import types.route_key.{implRouteKeyWord}
import types.superclass.{lookupPos, mapAll, superIfaceRef}
import list.{reverse, take, zip}
import map as IdMap

export
noteNumericPredicateTrace : GraphCtx ->
  NumericPredicateTraceStage ->
  ClassPredicate ->
  ScopeId ->
  Option Loc ->
  Option IfaceRef ->
  Option Route ->
  List Route ->
  Unit
noteNumericPredicateTrace gctx stage predicate scope origin selected route prereqs =
  match gctx.trace
    Some sink =>
      if sink.tsNumericPredicateEnabled then
        sink.tsNumericPredicateEntries :=
          NumericPredicateTraceEntry {
              nptStage = stage,
              nptPredicate = predicate,
              nptScope = scope,
              nptOrigin = origin,
              nptSelectedInterface = selected,
              nptRoute = route,
              nptPrerequisites = prereqs,
            }
            :: sink.tsNumericPredicateEntries.value
    None => ()

-- How many non-shrinking `requires` steps one walk may take (DICT-SEMANTICS §3 W2).
-- Only a context that does not shrink its goal (`impl C (T a) requires C (T (T a))`)
-- spends this, so the constant bounds divergence without bounding the depth of a
-- shrinking chain.  It is named in `requiresDepthMsg`, so changing it changes
-- user-visible text.
export
requiresNonShrinkingFuel : Int
requiresNonShrinkingFuel = 32

newWalkMemo : Unit -> WalkMemo
newWalkMemo _ = WalkMemo {
  wmRoutes = Ref omEmpty,
  wmDischarged = Ref omEmpty,
  wmCuts = Ref 0,
  wmSolved = Ref omEmpty,
  wmFollowed = Ref omEmpty,
  wmStopped = Ref False,
}

-- A walk whose seed is the goal [iface] [args].
export
reqWalkSeed : IfaceRef -> List Mono -> ReqWalk
reqWalkSeed iface args =
  ReqWalk
    [(iface, args, monoSizes args)]
    requiresNonShrinkingFuel
    (newWalkMemo ())

-- A walk with no goal on it yet: the first goal entered is its seed.
export
reqWalkStart : Unit -> ReqWalk
reqWalkStart _ = ReqWalk [] requiresNonShrinkingFuel (newWalkMemo ())

export
reqWalkEnter : ReqWalk -> IfaceRef -> List Mono -> ReqStep
reqWalkEnter (ReqWalk path fuel memo) iface args =
  let size = monoSizes args
  match path
    [] => ReqOn (ReqWalk [(iface, args, size)] fuel memo)
    (parentIface, parentArgs, parentSize) :: _ =>
      if anyListM (sameWalkGoal iface args size) path then
        ReqCycle parentIface parentArgs iface args
      else if size < parentSize then
        ReqOn (ReqWalk ((iface, args, size) :: path) fuel memo)
      else if fuel <= 0 then
        ReqDeep iface args
      else
        ReqOn (ReqWalk ((iface, args, size) :: path) (fuel - 1) memo)

-- The memo bucket of the goal [walk] has just entered, the head of its path: that
-- goal's interface spelling and size and the fuel left.  Goals that are one goal by
-- `sameWalkGoal` share a bucket; a bucket may also hold goals that are not, so every
-- hit is confirmed against the goal itself: `walkGoalSame` for the solved and followed
-- tables, `sameIfaceDecl` and `monoVecSameGiven` for the rest.
export
enteredGoalKey : ReqWalk -> String
enteredGoalKey (ReqWalk ((iface, _, size) :: _) fuel _) =
  let name = iface.irName
  "\{name}#\{intToString size}#\{intToString fuel}"
enteredGoalKey (ReqWalk [] fuel _) = "#\{intToString fuel}"

export
reqWalkMemo : ReqWalk -> WalkMemo
reqWalkMemo (ReqWalk _ _ memo) = memo

-- The route walk below the goal [row]'s `requires` discharge at [goals], which [walk]
-- has just entered: the recorded routes if this walk already built them, otherwise
-- [follow]'s, recorded when they came out clean.
routeWalkMemoized : SiteCtx ->
  String ->
  ScopeId ->
  List Mono ->
  ImplRow ->
  ReqWalk ->
  (SiteCtx -> List Route) ->
  List Route
routeWalkMemoized sx encl useScope goals row walk follow =
  let memo = reqWalkMemo walk
  let iface = ieRowIface row
  let key = enteredGoalKey walk
  let entries = optionOr [] (omLookup key memo.wmRoutes.value)
  match routeWalkRecorded iface goals row encl useScope entries
    Some entry =>
      noteInner sx entry.rweInner
      entry.rweRoutes
    None =>
      let cutsBefore = memo.wmCuts.value
      let acc = Ref innerNone
      let (erred, routes) =
        erredDuring sx.sxModule (_ => follow { sx | sxInner = Some acc })
      let inner = acc.value
      noteInner sx inner
      if erred || memo.wmCuts.value /= cutsBefore then
        ()
      else
        let entry = RouteWalkEntry {
          rweIface = iface,
          rweGoals = goals,
          rweRow = row,
          rweEncl = encl,
          rweScope = useScope,
          rweRoutes = routes,
          rweInner = inner,
        }
        memo.wmRoutes :=
          omInsert
            key
            (entry :: optionOr [] (omLookup key memo.wmRoutes.value))
            memo.wmRoutes.value
      routes

routeWalkRecorded : IfaceRef ->
  List Mono ->
  ImplRow ->
  String ->
  ScopeId ->
  List RouteWalkEntry ->
  Option RouteWalkEntry
routeWalkRecorded _ _ _ _ _ [] = None
routeWalkRecorded iface goals row encl useScope (entry :: rest) =
  if entry.rweEncl == encl
    && entry.rweScope == useScope
    && sameIfaceDecl entry.rweIface iface
    && monoVecSameGiven entry.rweGoals goals
    && rowRouteKey entry.rweRow == rowRouteKey row then
    Some entry
  else
    routeWalkRecorded iface goals row encl useScope rest

-- What the stamper running now has built below its destination's top level.  The
-- three producers of the routes inside a dictionary (`argReqRoute`, `superRouteAt`,
-- `undeterminedRowRoute`'s supers) note each route they return, so a sub-route the
-- solver shares between paths is noted once, where it is built.
noteInner : SiteCtx -> Inner -> Unit
noteInner sx inner = match sx.sxInner
  Some acc => acc := innerOr acc.value inner
  None => ()

-- [r], noted as a route inside a dictionary.
noteInnerRoute : SiteCtx -> Route -> Route
noteInnerRoute sx r =
  noteInner sx (innerOfRoute r)
  r

-- A route walk's cut, counted so no subtree containing one is recorded.
noteRouteWalkCut : ReqWalk -> Unit
noteRouteWalkCut walk =
  let memo = reqWalkMemo walk
  memo.wmCuts := memo.wmCuts.value + 1

-- Two goals are one goal when their interface is the same declaration and their
-- argument vectors are pointwise identical (`monoVecSameGiven`); equal sizes are
-- necessary, so they are compared first.
sameWalkGoal : IfaceRef ->
  List Mono ->
  Int ->
  (IfaceRef, List Mono, Int) ->
  Bool
sameWalkGoal iface args size (otherIface, otherArgs, otherSize) =
  otherSize == size
    && sameIfaceDecl otherIface iface
    && monoVecSameGiven otherArgs args

-- Recover the FULL list of interface-type-parameter monos for a method occurrence,
-- ordered by the interface's typaram declaration.  Look up the method's interface
-- (methodEntryHere: iface, typarams, declared method Ty), match the declared Ty
-- against the occurrence's full mono to bind each typaram → its inferred mono, then
-- read them out in typaram order.  For `fromEntries : List e -> c` matched against the
-- occurrence `List Int -> Set _a`, this yields [Set _a, Int] (c then e) — the element
-- grounding (`e ↦ Int`) the result-only `resultMono` (= c = Set _a) had lost.  None
-- when the method has no registered interface (a plain `=>`-constrained fn) or the
-- declared/occurrence shapes do not match — resolveSite falls back to [resultMono].
ifaceParamMonos : ModuleCtx -> String -> Mono -> Option (List Mono)
ifaceParamMonos mctx name fullMono = occurrenceParamMonos mctx name fullMono []

-- `ifaceParamMonos` at an occurrence that posed its goal with [omitted]
-- (`methodOmittedVars`): a typaram the declared type never mentions reads the
-- goal's own variable, so the route selects on the vector §3 determined.
occurrenceParamMonos : ModuleCtx ->
  String ->
  Mono ->
  List (String, Mono) ->
  Option (List Mono)
occurrenceParamMonos mctx name fullMono omitted =
  match methodEntryHere mctx name
    None => None
    Some (_, typarams, mty, _) =>
      map
        (subst => map (paramMonoOf (subst ++ omitted)) typarams)
        (matchTyMono mty fullMono)

-- RIGID PRODUCER 2 of 2 (#1110): [tp] is an interface type-PARAMETER name, so
-- the fallback when the head match bound nothing for it is a rigid variable,
-- not a type constructor.  See `Mono.TRigid`.
export
paramMonoOf : List (String, Mono) -> String -> Mono
paramMonoOf subst tp = optionOr (TRigid tp) (lookupAssoc tp subst)

-- #1177: the predicate a METHOD occurrence discharges — the interface [name] is
-- declared by, plus its full instantiated type-parameter vector when [fullMono] lets
-- `ifaceParamMonos` recover one.  `None` for a non-method name (a top-level
-- constrained call), which is what keeps those sites on the tyvar-keyed lookup.
--
-- The interface is read from `methodIfaceHere` (#1182), so the goal carries the
-- declaration's identity rather than `OriginUnresolved`.  This predicate's only
-- consumers are `enclSlotIndex`/`indexOfPredGo` and `implReqDictVarOf`/
-- `firstPredForEnclAt`, both of which compare `sp.iface.irName == p.iface.irName` — a
-- NAME compare that cannot see an origin — so the identity selects nothing there yet;
-- it is the precondition for re-keying those two comparators onto `sameTyConHead`.
goalPredOf : ModuleCtx -> String -> Mono -> Option PredicateRequest
goalPredOf mctx name fullMono = occurrencePredOf mctx name fullMono []

-- `goalPredOf` at an occurrence that posed its goal with [omitted]: the request
-- reads the vector `occurrenceParamMonos` builds, the one `entailInst` selects the
-- impl row on, so a typaram the declared type never mentions compares as the goal's
-- own variable rather than as the interface's rigid parameter name.
occurrencePredOf : ModuleCtx ->
  String ->
  Mono ->
  List (String, Mono) ->
  Option PredicateRequest
occurrencePredOf mctx name fullMono omitted =
  let args = match occurrenceParamMonos mctx name fullMono omitted
    Some xs => PSArgsKnown xs
    None => PSArgsUnknown
  map
    (ifr => PredicateRequest { prIface = ifr, prArgs = args })
    (methodIfaceHere mctx name)

-- the operator/unop form: the node carries one operand mono, not a method occurrence,
-- so no argument vector is recoverable (`stampOpRouteVal` says the same).  Every
-- operator interface is single-param anyway, so the interface alone is the predicate.
-- Same SLICE-1 supply as `goalPredOf` above, same table, same reasoning.
goalPredOfOp : ModuleCtx -> String -> Option PredicateRequest
goalPredOfOp mctx name =
  map
    (ifr => PredicateRequest { prIface = ifr, prArgs = PSArgsUnknown })
    (methodIfaceHere mctx name)

-- Phase 151 / Gap G: stamp each comparison/equality OPERATOR site's EBinOp route
-- ref with the resolved Eq/Ord impl key (RKey) — but ONLY when the operand type
-- grounds to a NON-primitive head tycon.  Primitive (Int/Float/String/Bool/Char)
-- and ungroundable operands stay RNone → the structural-builtin EBinOp eval path
-- (so `eq a b = a == b` on Int never recurses).  Mirrors resolveSite's concrete
-- branch (head tycon → canonical key) minus the impl-dicts: the rewritten `eq`/`lt`
-- is arg-position, so it narrows by arg tag and needs no forwarded element dict.
binopPrimitiveHead : String -> Bool
binopPrimitiveHead h = contains h ["Int", "Float", "String", "Bool", "Char"]

-- Roadmap #18a: the heads a binop lowers to a BUILTIN for, and must therefore never
-- route to a typeclass method.  For the comparison operators that is exactly the
-- scalar primitives.  For `++` (→ Semigroup's `append`) it is those PLUS `List`:
-- `++` on a String/List is lowered structurally (eval's `appendVal`; the emitter's
-- `mdk_string_append`/`mdk_list_append`), and core.mdk's own builtin impls are
-- written in terms of the operator —
--     impl Semigroup (List a) where append xs ys = xs ++ ys
--     impl Semigroup String   where append s1 s2 = s1 ++ s2
-- — so routing a List/String `++` to `append` would make those bodies call
-- themselves unboundedly.  Every OTHER head still routes, which is precisely what
-- makes a user `impl Semigroup MyRope` reachable from `a ++ b`.
--
-- The fixed-width heads (`U8`/`U16`/`U32`/`U64`/`I32`/`I64`) are builtin for the
-- COMPARISON methods only.  The tagged ones share `Int`'s word, held in
-- `0 .. 2^n - 1` or, for `I32`, sign-extended, so the signed word compare is their
-- order; a `U64` or `I64` compares its boxed payloads, unsigned or signed
-- (`stampOpRouteVal`).  They are deliberately NOT in
-- `binopPrimitiveHead`, which the unary-minus path also reads: a builtin `-x` on a
-- `U8` would be `Int` negation and leave a negative word, so `negate` routes to
-- the type's own `Num` impl instead.
binopBuiltinHead : String -> String -> Bool
binopBuiltinHead "append" tag = binopPrimitiveHead tag || tag == "List"
binopBuiltinHead method tag =
  binopPrimitiveHead tag || isFixedIntHead tag && isCompareMethod method

-- G4: an `==`/`<`/… INSIDE an impl body ([inImpl]) whose operand is the enclosing
-- impl's abstract `requires`-constrained tyvar routes RDict that impl's element dict
-- (`activeDictVarOf` maps the operand's surviving tyvar id → `$dict_<method>_<slot>`,
-- registered by registerImplRequires after body inference; this deferred batch sees
-- the populated table).  binopMethodApp then rewrites it to a dict-dispatched
-- `eq x y` and `usesImplDict` prepends the matching param.  Without this the abstract
-- operand never grounds to a head tycon → the route stayed RNone → the SHALLOW
-- structural builtin (`mdk_value_eq` / pointer-eq), silently mis-comparing any non-Int
-- element (List → False, nested Box → False) and crashing once the dicts were threaded.
-- The [inImpl] gate is REQUIRED for the GLOBAL activeDictVars route: activeDictVars
-- is global + uncleared, so a TOP-LEVEL comparison's operand tyvar id can collide
-- with a stale impl element-var entry → a spurious RDict (this flipped the repl's
-- String-keyed `:browse` sort).  But a legitimately-constrained TOP-LEVEL operator
-- (`f x y = x == y` under `Eq a =>`) must STILL forward the enclosing fn's own class
-- dict, exactly as the direct `eq x y` arg-stamp path does.  enclDictVarOf draws that
-- line PRECISELY: it consults `funPredicateSlotsRef[encl]` (the enclosing fn's OWN
-- declared constraint slots, keyed by fn name) — NOT the global activeDictVars — so
-- it fires ONLY when the operand var is genuinely one of encl's constraint vars, and
-- can never pick up a stale cross-impl element-var id.  A concrete operand (no active
-- dict var / not a constraint var, grounds to Some tag) keeps the existing RKey path.
--
-- Roadmap #18a RESIDUAL — `++`/`append` does NOT take the IN-IMPL element-dict route.
-- `binopDictVarOf` sends `append` to `enclDictVarOf` even when inImpl, so an operand
-- that is an impl's abstract `requires` tyvar stays RNone (the structural builtin)
-- instead of routing the impl's threaded element dict.
--
-- WHY (measured, not assumed).  Taking that route for `append` regresses
-- `test/eval_typed_modules_fixtures/impl_requires_nonfunctor_sibling`:
--     impl Applicative (VT e) requires Semigroup e where
--       pure a = VS a
--       ap (VF e1) (VF e2) = VF (e1 ++ e2)
-- Routing `e1 ++ e2` to `$dict_ap_0` makes `usesImplDict "ap"` true for the FIRST
-- time, so `implDictPassMethods` PREPENDS an impl-`requires` dict param to `ap` —
-- which shifts `ap`'s arg-position dispatch index by one.  The VTypedImpl's recorded
-- discriminating indices are NOT re-offset to match, so the impl then tag-checks its
-- leading DICT argument instead of its receiver, rejects it, and every candidate
-- falls through → `no matching impl for dispatch`.  (Before #18a that
-- `requires Semigroup e` was effectively DEAD — nothing in the body consumed it —
-- which is why the latent hole never fired.)  Fixing it properly means re-offsetting
-- arg-dispatch indices when impl-dict params are prepended: Phase 83/84 territory,
-- across ast/typecheck/dict_pass/eval, and deliberately NOT attempted here.
--
-- What still works (all gated): a GROUND non-builtin operand (`Rope "a" ++ Rope "b"`)
-- routes RKey to the user impl — the whole point of #18a, and the fix for the `build`
-- SIGSEGV; a TOP-LEVEL declared `Semigroup a => a -> a` routes RDict through
-- `enclDictVarOf` (the enclosing fn's OWN declared constraint slot, a different and
-- already-sound dict source); and String/List stay on the structural builtin.
-- What does NOT: `++` on an impl's abstract `requires`-bound tyvar — it keeps the
-- pre-#18a builtin behaviour exactly (correct for List/String, which is every such
-- site in the tree today), so this is a residual, not a regression.
-- BINOP path (`isBinop`): `append` → enclDictVarOf even when inImpl (Roadmap #18a
-- residual, above); any other method → activeDictVarOf when inImpl, else enclDictVarOf.
-- UNOP path (not `isBinop`): ALWAYS enclDictVarOf.  Roadmap #18a/#45 landmine (same
-- shape as the `append` residual): routing `-x` through activeDictVarOf can make
-- usesImplDict true for a method for the FIRST time, prepending a dict param that
-- shifts the impl's arg-dispatch index without re-offsetting the VTypedImpl's
-- discriminating indices — dispatch then tag-checks the dict instead of the receiver.
-- So `-x` on an impl's own abstract `requires`-bound tyvar stays on the structural
-- builtin (RNone) via a top-level fn's own declared constraint slot, never
-- activeDictVarOf — a residual, not a regression (mirrors the `++` residual exactly).
opDictVarOf : ModuleCtx ->
  Option PredicateRequest ->
  Bool ->
  String ->
  Mono ->
  Bool ->
  String ->
  ScopeId ->
  Option AssumAnswer
opDictVarOf mctx request True "append" m _ encl useScope =
  map LegacyScalar (enclDictVarOf mctx request m encl useScope)
opDictVarOf mctx request True _ m inImpl encl useScope
  | inImpl = map LegacyScalar (activeDictVarOf mctx.mcGraph m useScope)
  | otherwise = map LegacyScalar (enclDictVarOf mctx request m encl useScope)
opDictVarOf mctx request False _ m _ encl useScope =
  map LegacyScalar (enclDictVarOf mctx request m encl useScope)

-- Native Gap C: a tuple (or other parametric-with-requires) Eq/Ord impl carries
-- element `requires` dicts (Eq a, Eq b) that the rewritten `eq`/`compare` method body
-- reads.  Stamp them into the RKey route's reqs so binopMethodApp can forward them
-- as the EMethodAt impl-dict routes — exactly as resolveArgStamp does for a direct
-- `eq`/`compare` call.  A concrete non-parametric impl (user `Eq MyType`) has no
-- requires → empty reqs → the plain direct call, behaviour unchanged.
--
-- Parametric default case (now routed RKey, gap closed 2026-06-12): a comparison
-- OPERATOR (`<`/`>`/`<=`/`>=` → `lt`/`gt`/`lte`/`gte`) whose method is NOT itself
-- impl'd at this head (an Ord interface DEFAULT reducing to inner `compare`) AND the
-- head's Ord impl HAS `requires` (parametric, e.g. tuple / `List a` / `Box a`).  This
-- stamps the RKey route with the SAME element-dict reqs as the `==`/`eq` path, but
-- keyed on the INNER same-interface `compare` (the relational method has no own impl
-- at this head, so `argImplDictRoutesForEncl` keyed on it would find nothing).
-- binopMethodApp forwards them as the EMethodAt impl-dicts; emitDefaultRKey passes
-- them as leading words to `@mdk_default_<op>_<tag>`, whose emitDefaultDefine
-- eta-PREPENDS the matching dict params and threads them into the inner
-- `@mdk_impl_<tag>_compare(dict.., a, b)` call.  Previously this case BACKED OFF to
-- RNone, which the backend lowered as a raw pointer `icmp` (silently WRONG result) /
-- SIGSEGV on the by-name `lt` path.  Concrete Ord (no requires) keeps empty reqs →
-- the plain `@mdk_default_<op>_<tag>(a, b)` direct call, unchanged.
-- Flag-keyed differences between the two paths:
--   * builtin-head guard — BINOP: `binopBuiltinHead method tag` (append also treats
--     List as builtin); UNOP: `binopPrimitiveHead tag` (a ground Int/Float stays on
--     evalUnop's VInt/VFloat fast path, the unop analogue of the comparison guard).
--   * dictMethod — BINOP reduces an Ord-style interface DEFAULT to its inner
--     same-interface `compare` (innerDefaultMethod) when the head does not impl the
--     method directly; UNOP has no interface-level default to reduce through (every
--     `impl Num`, including Int/Float's own `negate a = 0 - a`, defines `negate`
--     directly), so dictMethod is just `method`.
-- #156 S3c: the PURE op-site inst route (called from entailInst's EKOp arm).  A builtin
-- head → RNone (the do-nothing case the old `if isBuiltin then ()` arm expressed; the
-- adapter's RNone guard turns it back into a no-op that preserves the ref's RNone seed).
-- Else a concrete non-builtin head → `RKey key reqs` with the element `requires` dicts
-- PACKED into the primary route's reqs (binopRouteSplit later rips them onto the
-- EMethodAt impl-dict ref).  Byte-identical to the pre-S3c stampOpRoute stamper.
stampOpRouteVal : SiteCtx ->
  Bool ->
  String ->
  ScopeId ->
  String ->
  Mono ->
  String ->
  Route
stampOpRouteVal sx isBinop encl useScope method operandMono tag =
  let isBuiltin =
    if isBinop then binopBuiltinHead method tag else binopPrimitiveHead tag
  -- #2356: a builtin head is not a dispatch, but it is not nothing either.  A
  -- comparison whose operand GROUNDS to `Int` gets the positive scalar stamp
  -- `RScalar "Int"`, the same carrier resolveArithSite uses for Float, so the
  -- native emitter can compare the two tagged words inline instead of calling the
  -- opaque @mdk_value_eq/@mdk_value_lt runtime discriminators.  The stamp is the
  -- ONLY sound witness for that: the emitter's own `LTInt` is its default for an
  -- operand whose type it could not recover, so an `icmp` keyed on LTy would
  -- compare boxed String/Float POINTERS as integers.  Every other builtin head
  -- (Float/String/Bool/Char) and every ungrounded operand stay RNone, i.e. on the
  -- runtime-discriminated path they are on today.
  if isBuiltin then
    -- a tagged fixed-width comparison is the `Int` word compare (see
    -- binopBuiltinHead); a `U64` or `I64` one compares the two boxed cells'
    -- 64-bit payloads, unsigned or signed.
    if isBinop
      && (tag == "Int" || isTaggedFixedHead tag)
      && isCompareMethod method then
      RScalar "Int"
    else if isBinop && tag == "Char" && isCompareMethod method then
      RScalar "Char"
    else if isBinop && isBoxed64Head tag && isCompareMethod method then
      RScalar tag
    else
      RNone
  else
    -- #609: no interface param vector is recoverable at an operator site (the
    -- node carries one operand mono, not a method occurrence), so the goal is the
    -- singleton — entryHeadMatches then takes its arg-0 fallback, byte-identical
    -- to the pre-#609 scan.  Every operator interface (Eq/Ord/Num) is single-param
    -- anyway, where the singleton IS the full vector.
    let (siteKey, selected) = keyForSite sx method [operandMono]
    -- Graph-global, off `bodyImplEnvRef` — see `ieDefinesReqMethodAt`.
    -- The head projection is `headTyconMono operandMono`, i.e. the `HeadKey` whose
    -- `headKeyName` IS the `tag` this arm was passed (`entail` derives both from the
    -- same mono, and on the nominal heads `TCon`/`TRigid` that carry a name the two
    -- classifiers agree; they differ only on `TFun`, which `headTyconMono` keys and
    -- `headTyconNameMono` does not), so the LOOKUP is the same question at the same
    -- key strength.
    let dictMethod =
      if isBinop then
        if ieDefinesReqMethodAt
          sx.sxModule.mcCells.bodyImplEnvRef.value
          method
          (headTyconMono operandMono) then
          method
        else
          innerDefaultMethod method
      else
        method
    let reqs = argImplDictRoutesForEncl
      sx
      encl
      useScope
      dictMethod
      tag
      operandMono
      [operandMono]
    -- No row: the operand's type has no instance, and the site keeps its RNone seed.
    match siteKey
      Some key =>
        RKey
          key
          reqs
          (selectedCallSupers sx method selected encl useScope [operandMono])
      None => RNone

-- Exact Num arithmetic uses the predicate selected by the producer for both the
-- implementation word and its prerequisite routes. Supported solved primitive
-- heads bypass method dispatch; a user Num impl for any other head, including
-- String/Bool/Char, is selected through the exact interface identity.
stampPredicateOpRouteVal : SiteCtx ->
  String ->
  ScopeId ->
  String ->
  Mono ->
  ClassPredicate ->
  Route
stampPredicateOpRouteVal sx encl useScope method operandMono predicate =
  match predicateScalarRoute method operandMono
    Some route =>
      noteNumericPredicateTrace
        sx.sxModule.mcGraph
        NPTArithmetic
        predicate
        useScope
        sx.sxSite
        None
        (Some route)
        []
      route
    None =>
      let env = sx.sxModule.mcCells.bodyImplEnvRef.value
      let goals = predicate.predicateArguments
      match ieSelectRowByIface sx env predicate.predicateInterface goals
        Some (row@(ImplRow _ _ selectedIface _ _ _ _)) =>
          let reqs = implDictRoutesForRow sx encl useScope goals row
          let key = rowRouteKey row
          let route =
            RKey
              key
              reqs
              (selectedCallSupers sx method (Some row) encl useScope goals)
          noteNumericPredicateTrace
            sx.sxModule.mcGraph
            NPTArithmetic
            predicate
            useScope
            sx.sxSite
            (Some selectedIface)
            (Some (RKey key [] []))
            reqs
          route
        None =>
          let route = RNone
          noteNumericPredicateTrace
            sx.sxModule.mcGraph
            NPTArithmetic
            predicate
            useScope
            sx.sxSite
            None
            (Some route)
            []
          route

predicateScalarRoute : String -> Mono -> Option Route
predicateScalarRoute method operandMono = match arithmeticTag operandMono
  -- Unary Int negation already has its dedicated primitive path and the unop
  -- carrier does not publish a scalar annotation.
  Some "Int" => Some (if method == "negate" then RNone else RScalar "Int")
  Some "Float" => Some (RScalar "Float")
  -- A fixed-width head's binary arithmetic is a builtin too, stamped with its
  -- own tag so every engine wraps the result at that width. Its unary negation
  -- takes the head's `Num` impl like any other instance.
  Some scalar => if method == "negate" then None else Some (RScalar scalar)
  None => None

-- The inner same-interface method an interface DEFAULT reduces to, supplying the
-- element `requires` dicts.  Ord's `lt`/`gt`/`lte`/`gte`/`min`/`max` defaults all
-- reduce to `compare`; any other relational/equality method has its own impl so the
-- `ieDefinesReqMethodAt` guard keeps it on `method`, never reaching here.
innerDefaultMethod : String -> String
innerDefaultMethod m =
  if contains m ["lt", "gt", "lte", "gte", "min", "max"] then "compare" else m

-- #2356: the five comparison OPERATOR methods (`==`/`/=` -> `eq`, `<`/`>`/`<=`/`>=`
-- -> `lt`/`gt`/`lte`/`gte`).  `min`/`max` are deliberately absent: they are Ord
-- methods but no operator records a site for them, so a name-only match on them
-- would stamp nothing and claim a reach this predicate does not have.
isCompareMethod : String -> Bool
isCompareMethod m = contains m ["eq", "lt", "gt", "lte", "gte"]

-- The route word a method site stamps, and the row it names, selected once over
-- `ModuleCells.mcCells.bodyImplEnvRef` (the graph-global `IE`): the selected instance's canonical
-- key (`rowRouteKey`), whichever other rows share its head, so one instance has one
-- word in every module.  #609: [goals] is the interface's FULL param-mono vector `τ̄`
-- at this site (recovered by `ifaceParamMonos`), or the singleton result mono when
-- the caller has none.  A general winner's word is its own key (#1128 F-3b), so the
-- dictionary names the instance actually selected.  `None` when no row is selected:
-- the arg-position caller then stamps no route word.  A definer-shadow site reaches
-- that stamp and is restamped `RLocal` afterwards by `resolveRLocalSites`
-- (`moduleStampOrder`).
--
-- An ambiguous method goal is the boundary verdict's to reject (`goalReach`, through
-- `rejectUndeterminedVectors`): the occurrence's obligation carries the vector selected
-- on here, omitted interface positions included (`occurrenceDispatchMonos`).  Nothing
-- here can report it instead: stamping runs in the graph-end drain
-- (`drainStampQueue`), after `check` has collected each module's diagnostics, so a
-- diagnostic pushed from here reaches `run` and `build` but never `check`.
-- The site's route word and the row it names, selected once: a caller that also
-- needs the row (`selectedCallSupers`) must not select a second time.
keyForSite : SiteCtx -> String -> List Mono -> (Option String, Option ImplRow)
keyForSite sx name goals =
  let env = sx.sxModule.mcCells.bodyImplEnvRef.value
  let selected = ieSelectRowByMethod sx env name goals
  (map rowRouteKey selected, selected)

-- The dictionary word of a selected instance row: its canonical key, the identity
-- every engine files that instance's entries under.  It never depends on which other
-- rows share the head, so one instance has one word in every module of the graph.
export
rowRouteKey : ImplRow -> String
rowRouteKey (ImplRow _ _ ir tys _ _ _) =
  implRouteKeyWord ir.irOrigin ir.irName tys None

-- the head tycon that buckets a goal vector: the spine head of its FIRST component
-- (the receiver).  Unchanged from the pre-#609 scalar bucketing — widening the
-- BUCKET key to the whole vector is exactly where a 14th `List`-as-a-map quadratic
-- would appear (compiler/AGENTS.md), and it buys nothing: two impls of one
-- interface that differ past arg 0 still share arg 0's tycon, so they must land in
-- the same bucket for the min⊑ comparison to see them at all.  The vector is
-- consulted by the MATCH (entryHeadMatches) and by ⊑ (entryCovers), both O(head
-- size) per bucket entry — a constant factor on an unchanged O(bucket) scan.
-- The projection is `headTyconMono`, so the GOAL side of this table carries the
-- same `HeadKey` the IMPL side (`keyEntryOf` via `headTyconTy`) does, and the two
-- compare as identities instead of as spellings.
export
goalHeadCon : List Mono -> Option HeadKey
goalHeadCon (g :: _) = headTyconMono g
goalHeadCon [] = None

-- §3 `inst` = `min⊑(match(IE, π))`: pick the entry strictly more specific than (or
-- equal to) every OTHER matching entry.
--
-- What reaches the `None` ARM, since the prose here was wrong about it until
-- #1155 and the error is expensive in BOTH directions.  It said the arm covers "≤1
-- match, equal heads, or incomparable overlap".  Two of those three never get here:
-- `entryCovers` is `tyHeadEqV … || tyStrictlyMoreSpecificV …`, so a single match
-- covers ITSELF and two EQUAL heads cover EACH OTHER — both make
-- `entryCoversAllOthers` true and return `Some` (see `entryCoversAllOthers`' own
-- comment, "Equal-head entries are covered trivially").  The description was
-- outcome-equivalent while every arm produced a first-match result, and became
-- load-bearing the moment one of them became a REJECT: keyed to the prose, this
-- would hard-reject every duplicate-instance and user-overrides-prelude program.
-- **Only ⊑-INCOMPARABLE OVERLAP lands here** (confirmed on
-- test/typecheck_error_fixtures/overlapping_impls.mdk, whose equal heads stay silent).
--
-- #1155 (F-3c): returning `Some e` in silence would let DECLARATION ORDER decide the
-- program's meaning — swap two `impl` blocks and the answer changes, at exit 0 on every
-- engine (#1154, #1162).  So the arm also REPORTS, under the goal-site half of §6 C1: at
-- most one ⊑-minimal matching instance, quantified over the goals
-- `inst` decides rather than over ground goals.
--
-- The winner is still `Some e`, deliberately.  `recordTypeError` arms
-- `typeErrorsSticky`, so `check` reports and `run`/`build` abort — the program is
-- rejected either way — while every route this compile stamps stays byte-identical.
-- Returning `None` instead would ALSO move every route on the rejected path (RKey →
-- the caller's fallback), which changes emitted IR on a program nobody can run and
-- buys nothing.
--
-- The reject is not gated on the goal being closed.  Every candidate here MATCHES
-- the goal as it stands, and a match survives any later binding of the goal's
-- variables, so no instantiation can leave fewer than two incomparable matches:
-- an open goal that reaches this arm is as ambiguous at quiescence as it is now
-- (§6.2 T4, "rejected as ambiguous — never committed to a default instance").
pickMostSpecificEntry : SiteCtx -> List Mono -> List KeyEntry -> Option KeyEntry
pickMostSpecificEntry sx _ [] = None
pickMostSpecificEntry sx goals (e :: rest) =
  match findMostSpecificEntry (e :: rest) (e :: rest)
    Some best => Some best
    None =>
      reportAmbiguousOverlap sx goals (e :: rest)
      Some e

-- #1155: the goal-site `T-AMBIGUOUS-INSTANCE`, with the two gates that keep it from
-- over-rejecting.  [cands] is always ≥2 entries with no ⊑-minimum among them.
--
--  Open or closed, the same verdict, never a commit to the first-declared
--     candidate.  Matching is preserved by every later binding of
--     the goal's variables, so an open goal here can never become unambiguous;
--     §6.2 T4 rejects it.  Pinned by the one-token pair
--     `test/dict_fixtures/s6-2-t3-closed-goal-reported.mdk` (ground goal) and
--     `…/s6-2-t4-open-goal-deferred.mdk` (open goal): both reject at their goal.
--
--  🚦 ONE INTERFACE.  A filter by METHOD NAME alone would let two impls of two
--     DIFFERENT interfaces that happen to share a method name arrive together.  Their
--     head vectors are ⊑-incomparable for a reason that has
--     nothing to do with overlap, and §6 C1 is a condition on the instances of ONE
--     class (`match(IE, C τ̄)`).  Selecting across that set is a candidate-set
--     DEFORMATION of the method-keyed path, not an ambiguous program, so reporting
--     it as ambiguity would be the wrong message.  (The iface-keyed caller
--     `ieEntriesForIface` cannot produce such a set, so the gate is a no-op
--     there.)
--
--     #1182 has landed, and this gate is *still not deletable*.  The bug it was
--     declining to report is fixed — `ieEntriesForMethod` now admits on the
--     ADMITTED DECLARATION as well as the spelling — and the pinned repro
--     (`test/must_fail_fixtures/1182-two-ifaces-same-method-name-order-decides`)
--     drained: both impl-block orderings now answer `1` on `run` AND on the built
--     binary.  What is NOT true is the tempting corollary "every candidate set now
--     shares one interface by construction".  DERIVED, not assumed:
--       * on the `Some [iface]` arm the corollary holds (`Some []`, two or more
--         admitted declarations, admits no row at all).  `ieRowAdmittedBy` →
--         `ieRowIfaceMatches` → `sameTyConHead n1 o1 n2 o2 = n1 == n2 && …`, so every
--         admitted row carries `ir.irName == iface.irName`; `keyEntryOfRow` writes
--         exactly that `ir.irName` into the `KeyEntry` field `keyEntryIface` reads.
--         Two admitted rows therefore cannot disagree, and `candsOneIface` is `Some`.
--       * on the `None` arm it DOES NOT.  `ieRowAdmittedBy _ None = True` is the
--         deliberate fall-back to the bare-name answer for a `methodEntryHere`
--         miss (its own doc-comment owns that derivation, and answering `False`
--         there would be a routing change, not a conservative one).  On that arm the
--         scan is byte-for-byte the pre-#1182 one, so a two-interface set is exactly
--         as constructible as it ever was.
--     ⇒ the disagree branch is NOT unreachable by construction; deleting it would
--     re-arm the wrong message on precisely the shape the fix does not reach.  It
--     stays.  What DID change is its extent: it can now only be reached through a
--     table miss, never through a scoped name.
--
-- NOT SUPPRESSED when the declaration-time coherence sweep already fired for the
-- same interface, and that was a considered call rather than an oversight.  The two
-- in-tree fixtures this arm newly reports on — check_json_fixtures/conflicting_impl_overlap
-- and dict_fixtures/s6-1c-incomparable-no-minimum-control — carry BOTH diagnostics.
-- They are two different RULES at two different SITES: the declaration-time one is
-- §6.1 condition (a) at the `impl`, and the corpus records it as an OVER-rejection
-- (its sibling s6-1c-per-goal-unique-min-rejected is a program the spec's condition
-- (c) accepts); this one is (c) at the goal.  The control fixture's own header says
-- both conditions reject it, so reporting both is the checker saying what it actually
-- did.  Suppressing would make this rule's extent depend on whether another rule
-- fired first — the implementation-relative extent §6 C1 rejects for its own
-- quantifier.  (The suppression was recommended on the premise that
-- `diff_compiler_dict_semantics_test.mdk` grades the FIRST code; it does not —
-- `contains "\"code\":\"\{c}\"" json`, presence anywhere.  Verified.)
--
-- F-3d (#614/#311) changed the OTHER half of that pairing, and the earlier wording
-- here predicted it wrongly: it said F-3d "deletes (a)", so un-suppression would be
-- forced.  (a) was DEMOTED, not deleted — the companion diagnostic on both fixtures is
-- now a `W-INCOMPARABLE-IMPLS` WARNING, not `T-CONFLICTING-IMPL`.  The
-- non-suppression argument is unchanged, and the pairing improves ON THE `--json`
-- SURFACE ONLY: the two diagnostics now differ in SEVERITY, so a machine consumer
-- sees one error plus one advisory note about the declarations rather than two
-- same-severity errors with the same primary remedy printed out of source order (the
-- ERROR-QUALITY dim X/R cost F-3c accepted knowingly).  A HUMAN `medaka check` user
-- sees NO improvement, because they never saw the second diagnostic at all: the CLI's
-- error arm prints `filter isDiagError diags` and returns, so on any file with an
-- error the warnings are dropped — a pre-existing suppression this change neither
-- causes nor repairs.  Do not restate the improvement as general.
reportAmbiguousOverlap : SiteCtx -> List Mono -> List KeyEntry -> Unit
reportAmbiguousOverlap sx goals cands = match candsOneIface cands
  None => ()
  Some iface => reportOverlapForIface sx iface goals cands

reportOverlapForIface : SiteCtx -> String -> List Mono -> List KeyEntry -> Unit
reportOverlapForIface sx iface goals cands =
  pushAmbiguityAt
    sx.sxModule
    True
    sx.sxSite
    (ambiguousOverlapMsg iface goals cands)

-- §6.2 T3's "closed": every variable of the goal is *"either quantified by the scheme
-- just produced or already ground"* — the ground goals PLUS the rigid-variable ones.
--
-- `isEmptyL (flatMap monoUnboundIds goals)` is the WRONG test and it silently costs
-- #1155 its whole rigid half.  A rigid signature variable is NOT reified to a `TCon`
-- here: `firstRow : List (List a) -> List a` still carries `a` as an UNBOUND `TVar`
-- when the post-HM resolvers run (verified — under the unbound-ids test the #1155
-- rigid fixture is classified non-closed and the reject never fires).  The
-- rigid-vs-undetermined distinction is not visible in the `Mono` at all; it lives in
-- whether some enclosing scheme QUANTIFIED that id, which is exactly what
-- `deferrableVarIds` records (`schemeIds` at each generalized group close).  Same
-- test `undeterminedGoalExempt` uses, for the same reason.
--
-- A var recorded outside any generalized-group-close window is in NEITHER set (see
-- checkCallObligations' #838 I4 note), so it reads as non-closed: the caller of this
-- test reports such a goal rather than deferring it.
--
-- One deliberate imprecision, so nobody has to spot it twice: T3 says "quantified
-- by the scheme JUST PRODUCED", whereas `deferrableVarIds` is a RUN-GLOBAL
-- accumulation over every scheme closed so far in this module.  That is a strictly
-- WIDER set than T3 names.  The two coincide in practice because tyvar ids are unique
-- per run, so a var quantified by some other binding's scheme cannot also be free in
-- this goal — but the coincidence is a property of id allocation, not of the test, and
-- it would stop holding if ids were ever recycled.
goalsClosed : ModuleCtx -> List Mono -> Bool
goalsClosed mctx goals =
  allList
    (i => IdMap.has i mctx.mcCells.deferrableVarIds.value)
    (flatMap monoUnboundIds goals)

-- the ONE interface all candidates implement, or None if they disagree (see the
-- second gate on reportAmbiguousOverlap).
candsOneIface : List KeyEntry -> Option String
candsOneIface [] = None
candsOneIface ((KeyEntry _ _ _ _ ifn _ _ _) :: rest) =
  if allList (e => keyEntryIface e == ifn) rest then Some ifn else None

findMostSpecificEntry : List KeyEntry -> List KeyEntry -> Option KeyEntry
findMostSpecificEntry [] _ = None
findMostSpecificEntry (c :: cs) all
  | entryCoversAllOthers c all = Some c
  | otherwise = findMostSpecificEntry cs all

-- is [cand]'s head pattern more specific than (or structurally equal to) every
-- entry in [all]?  Equal-head entries are covered trivially; a genuinely more-
-- general entry is NOT covered, so [cand] is rejected for it.
entryCoversAllOthers : KeyEntry -> List KeyEntry -> Bool
entryCoversAllOthers cand all = allList (entryCovers cand) all

-- #609: compares the entries' FULL head vectors (`itys`), not their arg-0 head
-- patterns.  Arg-0-only made `Ix Int Bool` and `Ix Int Char` mutually "tyHeadEq" —
-- ⊑-EQUAL, hence no unique min⊑ — so pickMostSpecificEntry fell to first-match and
-- DECLARATION ORDER decided the program's meaning.  For a single-param impl
-- `itys == [candTy]`, so this reduces to the old two lines algebraically (see
-- tySubsumesV).
entryCovers : KeyEntry -> KeyEntry -> Bool
entryCovers (KeyEntry _ _ _ _ _ candTys _ _) (KeyEntry _ _ _ _ _ otherTys _ _) =
  tyHeadEqV candTys otherTys || tyStrictlyMoreSpecificV candTys otherTys

-- ENTRY POINT 1 of 3 — the INTERFACE-keyed row selector (§3 `inst` =
-- min⊑(match)), read by the checker leg and by BOTH halves of the router leg.
-- Replaces `selectImplEntryByIface` for those three sites.
--
-- 🆕 it returns the row, not A KEY OR A string, and that is an interface
-- Obligation to the next bite.  The row carries `InstRef` — the instance identity
-- this tree does not otherwise have — so Phase 3′'s stamping bite can name the
-- selected instance at the site that selected it.  A `String`-returning selector
-- makes that bite unstatable, and a `KeyEntry`-returning one loses the identity on
-- the way out (`keyEntryOfRow` is lossy: it keeps `instRefSeq`, not `InstRef`).
--
-- A goal with no head tycon keys no bucket and selects nothing — the `None => None` arm
-- below.
export
ieSelectRowByIface : SiteCtx ->
  ImplEnv ->
  IfaceRef ->
  List Mono ->
  Option ImplRow
ieSelectRowByIface sx env iface goals = match goalHeadCon goals
  Some hk =>
    ieRowOfEntry
      env
      (pickMostSpecificEntry sx goals (ieCandidatesForIface env hk iface goals))
  None => None

-- ENTRY POINT 2 of 3 — the METHOD-keyed row selector, read by the two element-dict
-- route sites AND by the route WORD itself, through `keyForSite`.
--
-- ── #1182: the admitted declaration is read HERE, from [name] alone ───────────
-- DELIBERATELY NOT A new parameter on this function, and the reason is
-- `ieImplExistsForHead`'s verbatim — its three existence readers move together "by
-- construction rather than by diligence" precisely because the scope is projected
-- inside the one query.  Every caller passes a bare `name : String`; threading
-- `methodIfaceHere name` through them would let selection sites disagree on scope.
-- Reading it here makes that partial move unrepresentable.
--
-- ONE `omLookup` PER SELECTION, hoisted out of the row scan for the same reason
-- `ieImplExistsForHead` hoists its own ([T-PERF-HUNT]: Medaka is strict, so an in-loop
-- projection is rebuilt once per row).  It is inside the `Some hk` arm because a goal
-- with no head tycon selects nothing and must not pay for the lookup.
ieSelectRowByMethod : SiteCtx ->
  ImplEnv ->
  String ->
  List Mono ->
  Option ImplRow
ieSelectRowByMethod sx env name goals = match goalHeadCon goals
  Some hk =>
    ieRowOfEntry
      env
      (pickMostSpecificEntry
        sx
        goals
        -- #1386: interface from the OCCURRENCE spelling, method-set membership from
        -- its ORIGIN — both projected off the one name, inside the one query.
        (ieCandidatesForMethod
          sx.sxModule.mcGraph
          env
          hk
          (originMethodName sx.sxModule name)
          (methodAdmissionHere sx.sxModule name)
          goals))
  None => None

-- Match an already-selected instance row against the complete predicate goal.
-- The substitution and prerequisites are projections of that same row.
export
selectedRowReqMatch : ModuleCtx ->
  List Mono ->
  ImplRow ->
  Option (List (String, Mono), List Require)
selectedRowReqMatch mctx goals (ImplRow _ _ _ itys reqs _ _) =
  map (subst => (subst, reqs)) (implHeadSubst mctx itys goals)

-- Exact prerequisite routing consumes the complete predicate vector and the row
-- already selected for the route word.  The checker uses the same row matcher.
export
implDictRoutesForRow : SiteCtx ->
  String ->
  ScopeId ->
  List Mono ->
  ImplRow ->
  List Route
implDictRoutesForRow sx encl useScope goals row =
  match selectedRowReqMatch sx.sxModule goals row
    Some (subst, reqs) =>
      argImplReqRoutes
        sx
        encl
        useScope
        subst
        reqs
        (reqWalkSeed (ieRowIface row) goals)
    None => []

-- Missing predicate-vector metadata keeps the scalar result-head match used by
-- the legacy return path.  Exact callers use selectedRowReqMatch instead.
legacyReturnReqRoutesForRow : SiteCtx ->
  String ->
  ScopeId ->
  Mono ->
  ImplRow ->
  List Route
legacyReturnReqRoutesForRow sx encl useScope resultMono row =
  match ieRowHeadTriple (Some row)
    Some (headTy, implTys, reqs) =>
      match (headSubstWithParams sx.sxModule headTy implTys resultMono [
        resultMono,
      ])
        Some subst =>
          argImplReqRoutes
            sx
            encl
            useScope
            subst
            reqs
            (reqWalkSeed (ieRowIface row) [resultMono])
        None => []
    None => []

-- Build the impl head substitution.  Always match the impl HEAD (`Set a`) against
-- the result mono (the historical single-param behaviour, byte-identical when no
-- extra param info is supplied).  THEN, when the caller has the interface's FULL
-- param monos (`[Set _a, Int]` for a multi-param interface) and they line up with
-- the impl's full type-arg patterns (`[Set a, a]`), additionally match the trailing
-- patterns against the trailing param monos and merge — preferring a concrete head
-- (Int) over a free var (_a) on a key collision.  This recovers the element grounding
-- (`a ↦ Int`) the head-only match lost.  When the param monos don't line up (a plain
-- result-only call, or a shape mismatch) the head match alone stands.
headSubstWithParams : ModuleCtx ->
  Ty ->
  List Ty ->
  Mono ->
  List Mono ->
  Option (List (String, Mono))
headSubstWithParams mctx headTy implTys resultMono paramMonos =
  map
    (headSub => augmentWithParams mctx headSub implTys paramMonos)
    (matchTyMono headTy resultMono)

-- When the impl's full type-arg patterns line up with the interface's full param
-- monos (a multi-param interface), fold the trailing element groundings into the
-- head subst (concrete-wins); otherwise return the head subst unchanged.
augmentWithParams : ModuleCtx ->
  List (String, Mono) ->
  List Ty ->
  List Mono ->
  List (String, Mono)
augmentWithParams mctx headSub implTys paramMonos
  | listLen implTys == listLen paramMonos
    && listLen paramMonos > 1 = match implHeadSubst mctx implTys paramMonos
    Some full => mergeSubstPreferConcrete headSub full
    None => headSub
  | otherwise = headSub

-- Match the impl's full type-arg patterns [pats] (`[Set a, a]`) against the
-- interface's concrete param monos [concretes] (`[Set _a, Int]`), accumulating a
-- name→mono subst.  When the SAME impl var appears in several positions (here `a`
-- is both the head element and the standalone element param), prefer the binding
-- whose mono has a CONCRETE head tycon (Int) over a still-free var (_a) — that is
-- what recovers the element grounding the result-only match missed.  Mirrors the
-- oracle's impl_head_subst (Hashtbl.replace last-wins, with concrete winning here).
-- A length mismatch / structural failure → None (no match, try the next impl), so a
-- single-param interface ([resultMono] only) behaves exactly as the old matchTyMono.
export
implHeadSubst : ModuleCtx ->
  List Ty ->
  List Mono ->
  Option (List (String, Mono))
implHeadSubst mctx pats concretes
  | listLen pats /= listLen concretes = None
  | otherwise = match positionBindings pats concretes []
    None => None
    Some binds =>
      if matchEqPairs mctx (repeatedBindings binds []) then
        Some (fold (acc b => mergeOne acc (fst b) (snd b)) [] binds)
      else
        None

-- A variable a closed binder declared (`declaredSigVarIds`) is a constant here, not
-- one of the goal's free variables: a repeated head variable never equates it with
-- another type (DICT-SEMANTICS §3).
matchEqPairs : ModuleCtx -> List (Mono, Mono) -> Bool
matchEqPairs mctx [] = True
matchEqPairs mctx pairs0 =
  let pairs =
    rigidSigPairs mctx.mcGraph mctx.mcCells.declaredSigVarIds.value pairs0
  let subst = Ref []
  cohOverlapGo subst pairs
    && allList (p => matchEqMono subst (fst p) (snd p)) pairs

-- Each head position matched on its own, its bindings in position order.
export
positionBindings : List Ty ->
  List Mono ->
  List (String, Mono) ->
  Option (List (String, Mono))
positionBindings [] [] acc = Some acc
positionBindings (p :: ps) (c :: cs) acc = match matchTyMono p c
  None => None
  Some s => positionBindings ps cs (acc ++ s)
positionBindings _ _ _ = None

-- A variable the head repeats is one type: every later binding of it must
-- unify with its first, all of them under one substitution of the goal's free
-- variables (`cohOverlapGo`), so `Get (Box a) a` never matches
-- `Get (Box Float) Int`, nor `Pick a a a` a goal whose three positions cannot
-- be made equal together, whatever order they are visited in.
export
repeatedBindings : List (String, Mono) ->
  List (String, Mono) ->
  List (Mono, Mono)
repeatedBindings [] _ = []
repeatedBindings ((k, v) :: rest) seen = match lookupAssoc k seen
  Some first => (first, v) :: repeatedBindings rest seen
  None => repeatedBindings rest ((k, v) :: seen)

-- THE LADDER'S SELECTOR-REACHABILITY PROPERTY, inscribed so the next refactor
-- cannot violate it silently.  Every impl-row SELECTOR call reachable from `entail`
-- lies in an `inst` arm (`entailInst`) or in an element-route helper called from one.
-- No selector call may be reachable from `entailAssum`, `entailAssumVar` or
-- `entailAssumRoute` — verified at this pin by enumerating the assum chain
-- (`activeDictVarOfEncl`/`activeDictVarOf`/`enclDictVarOf`/`opDictVarOf`/
-- `activeDictPredOf`/`ifaceOfMethodName`): every one is a module-record registry lookup and
-- none reaches a selector.
--
-- `entailFallback` has two reaching paths, and neither is a violation, but they are why
-- the rule above stops naming it.  `EKNestedTop`'s `CountImpls` policy goes
-- `undeterminedRoute` → `routeUndeterminedTop`, which answers THIS goal by its
-- CANDIDATES (`goalCandidates`: one, or a stable minimum → that instance; two or more
-- otherwise → `T-AMBIGUOUS-INSTANCE`), never by selection — and only THEN routes the
-- chosen impl's own nested `requires` through `argImplRequiresRoutesForRow`, each a
-- FRESH sub-goal descending the ladder again, not this goal being answered on a later rung.  A refactor
-- that let the fallback rung answer the ladder's own goal by selection IS the violation
-- this property forbids; the `KeepNone` policy (every element-dict recursion) cannot
-- reach even this path.  The `CommitSuper` policy (a super segment) reaches
-- `committedSuperRoute` the same way: it answers a goal over variables alone by the
-- candidates the checker's super judgment counted (`stableGoalReach`).
--
-- Why it matters.  DICT-SEMANTICS §3 pins the precedence: `assum` strictly precedes
-- `inst`, which strictly precedes `fallback`.  Letting a later rung answer a goal an
-- earlier rung could have answered re-routes a dict cell from a CALLER-SUPPLIED
-- PARAMETER to a STATICALLY SELECTED impl — the wrong value, at exit 0, with no
-- diagnostic.  A selector call sitting on an `assum` or `fallback` arm is precisely how
-- that happens, which is why this is a placement rule and not a tidiness point.
--
-- IT IS A reachability property, not A COUNT — and the count form is false on A
-- CORRECT TREE.  There are legitimately TWO selector calls per `inst` arm: one for the
-- primary route word, one inside the element-route helper.  At `EKArg` and `EKOp` those
-- two deliberately ask about DIFFERENT methods — the element helper is keyed on the
-- `innerDefaultMethod`-reduced name when the head's impl does not itself define the
-- method (`ieDefinesReqMethodAt`).  Any *"one selector call per arm"* rule would license
-- collapsing them, which changes WHICH IMPL'S context is discharged (§6 C2).  Do not
-- restate this property in the count form.
--
-- AND A GREP OF `ieSelectRowBy*` is not the check.  `concreteReqMatchByIface` is a
-- LEGITIMATE selector call outside this ladder — it is the obligation channel's evidence
-- check, not a routing decision — and is out of scope here.  An audit that greps the
-- selector names without excluding it reports a false violation.
-- THE `inst` arm projects through `headTyconMono`, THE DISPATCH-KEY PROJECTION,
-- not through the name-only `headTyconNameMono`, as `goalHeadCon` does: `entail` is
-- a ROUTING decision (its result is stamped straight into a site's route ref by
-- `resolveArgStamp`), so it owes the goal-side dispatch key, and the name-only
-- projection cannot express that because the two answer differently at `TFun`.
--
-- MEASURED (#1617): this line alone decides it, with both head projections
-- and both definition-side tags agreeing on `__fun__`: an arg-position
-- occurrence (`sz : a -> Int` dispatches on its ARGUMENT, so it is stamped here
-- and not by `resolveSites`) took the `None => entailFallback` arm, left the site
-- `RNone`, and the emitter arg-tag-dispatched over a closure.  The typed Core-IR
-- dump showed `CMethod "sz" RNone` beside two correctly-tagged
-- `CImplTagged "__fun__"` entries — impl side fixed, goal side fixed, route still
-- unstamped.
--
-- The name is projected INSIDE the arm, not with `map headKeyName` over the
-- `Option` — same reason `headTyconNameTy`/`headTyconNameMono` exist at all
-- (`compiler/AGENTS.md`): Medaka is strict, so the combinator spelling would
-- allocate a second `Option` on every entailment to throw it away.
export
entail : SiteCtx ->
  String ->
  Mono ->
  String ->
  ScopeId ->
  EntailKind ->
  (Route, List Route)
entail sx name m encl useScope kind =
  match entailAssum sx.sxModule m encl name useScope kind
    Some answer =>
      noteAssumption sx.sxModule.mcGraph useScope answer
      let result = (
        assumAnswerRoute sx.sxModule.mcGraph answer (goalIfaceOfKind
          sx.sxModule
          name
          kind) useScope (dname =>
          entailAssumRoute dname kind),
        [],
      )
      noteNumericEntailment sx kind useScope None (fst result) (snd result)
      result
    None => match headTyconMono m
      Some hk => entailInst sx name m encl useScope (headKeyTag hk) kind
      None => match entailRigidLead sx m encl useScope kind
        Some result => result
        None => match entailDetermined sx name encl useScope kind
          Some result => result
          None =>
            let result = (entailFallback sx encl useScope m kind, [])
            noteNumericEntailment
              sx
              kind
              useScope
              None
              (fst result)
              (snd result)
            result

-- An argument-position occurrence whose goal a boundary determined by its one
-- unifying instance (DICT-SEMANTICS §3 "Determination by the one unifying
-- instance") dispatches through that instance, though its lead position is still
-- a variable that selection by head cannot read.
entailDetermined : SiteCtx ->
  String ->
  String ->
  ScopeId ->
  EntailKind ->
  Option (Route, List Route)
entailDetermined sx name encl useScope (EKArg fullMono omitted) = match (
  occurrenceParamMonos sx.sxModule name fullMono omitted,
  methodIfaceHere sx.sxModule name,
)
  (Some goals, Some iface) =>
    map
      (row => (
        RKey
          (rowRouteKey row)
          []
          (selectedCallSupers sx name (Some row) encl useScope goals),
        implDictRoutesForRow sx encl useScope goals row,
      ))
      (determinedGoalInstance sx.sxModule iface goals)
  _ => None
entailDetermined sx _ _ _ _ = None

-- `inst` for a nested/top goal whose lead position is a variable, when every variable
-- of the vector is one a closed binder declared (DICT-SEMANTICS §6.1 points 2-3, §3
-- W3-inst).  Such a goal is closed: its variables are rigid in the matcher, so an
-- instance reduces it when some position is constructed, and it selects min⊑ of the
-- matches.  A goal over variables alone is its own residual and is not reduced.  Only
-- an instance whose first head position is a variable can match a variable lead, so
-- the headless bucket is the whole candidate set.  The rung lives here rather than in
-- `ieSelectRowByIface`'s headless arm because rigidity is a property of the goal's
-- scope, which that selector's other callers do not share.
entailRigidLead : SiteCtx ->
  Mono ->
  String ->
  ScopeId ->
  EntailKind ->
  Option (Route, List Route)
entailRigidLead sx m encl useScope (EKNestedTop iface _ walk rest) =
  let goals = m :: rest
  let ids = flatMap monoUnboundIds goals
  let declared = sx.sxModule.mcCells.declaredSigVarIds.value
  if isEmptyL ids
    || anyList (i => not (omHasKey (intToString i) declared)) ids
    || allList isBareTyvarMono goals then
    None
  else
    let env = sx.sxModule.mcCells.bodyImplEnvRef.value
    let picked =
      pickMostSpecificEntry
        sx
        goals
        (ieEntriesForIface (ieHeadRows None env) iface goals)
    map
      (row => (nestedRowRoute sx encl useScope m goals walk row, []))
      (ieRowOfEntry env picked)
entailRigidLead sx _ _ _ _ = None

noteNumericEntailment : SiteCtx ->
  EntailKind ->
  ScopeId ->
  Option IfaceRef ->
  Route ->
  List Route ->
  Unit
noteNumericEntailment sx (EKNumReturn predicate _ _ origin) scope selected route prereqs =
  noteNumericPredicateTrace
    sx.sxModule.mcGraph
    NPTReturn
    predicate
    scope
    origin
    selected
    (Some route)
    prereqs
noteNumericEntailment sx (EKPredicateOp _ _ predicate) scope selected route prereqs =
  noteNumericPredicateTrace
    sx.sxModule.mcGraph
    NPTArithmetic
    predicate
    scope
    sx.sxSite
    selected
    (Some route)
    prereqs
noteNumericEntailment sx _ _ _ _ _ = ()

-- #412: `assum`, both halves.  DICT-SEMANTICS §3 pins the precedence — `assum`/`super`
-- takes precedence over `inst`; a predicate already in scope is USED, and `inst` fires only
-- when no assumption matches (GHC's rule) — which is what makes :160's "sub-evidence is
-- never pre-baked at the instance declaration" realisable.  The tyvar-keyed registry runs
-- first and unchanged; the predicate-keyed one (registerPredGiven) then answers the
-- STRUCTURED given (`requires S (List a)`) that `activeDictVarOf` structurally cannot see,
-- because it recurses to the spine head and a structured subject has a TCon there.
-- Strictly additive: every goal the tyvar path already answers routes exactly as before.
entailAssum : ModuleCtx ->
  Mono ->
  String ->
  String ->
  ScopeId ->
  EntailKind ->
  Option AssumAnswer
entailAssum mctx m encl name useScope kind =
  let request = goalRequestOfKind mctx name kind
  match entailAssumVar mctx request m encl name useScope kind
    Some answer => Some answer
    None => match request
      Some req => activeDictPredOf mctx.mcGraph req m useScope
      None => None

goalRequestOfKind : ModuleCtx -> String -> EntailKind -> Option PredicateRequest
goalRequestOfKind mctx name (EKReturn fullMono _) =
  goalPredOf mctx name fullMono
goalRequestOfKind mctx _ (EKNumReturn predicate _ _ _) = Some PredicateRequest {
  prIface = predicate.predicateInterface,
  prArgs = PSArgsKnown predicate.predicateArguments,
}
goalRequestOfKind mctx name (EKArg fullMono omitted) =
  occurrencePredOf mctx name fullMono omitted
goalRequestOfKind mctx name (EKOp _ _) = goalPredOfOp mctx name
goalRequestOfKind mctx _ (EKPredicateOp _ _ predicate) = Some PredicateRequest {
  prIface = predicate.predicateInterface,
  prArgs = PSArgsKnown predicate.predicateArguments,
}
goalRequestOfKind mctx _ (EKNestedTop _ _ _ _) = None

-- assum: which in-scope dict-param (if any) does [m]'s head constraint var read?  The
-- genuine/arg kinds prefer the enclosing method's own slot (activeDictVarOfEncl); the
-- nested/top kind uses the plain lookup (activeDictVarOf); the op kind
-- routes through opDictVarOf (isBinop/inImpl-keyed, needs the method [name]).  [name] is
-- ignored by the non-op kinds.
entailAssumVar : ModuleCtx ->
  Option PredicateRequest ->
  Mono ->
  String ->
  String ->
  ScopeId ->
  EntailKind ->
  Option AssumAnswer
-- #1177: the genuine/arg kinds now hand `activeDictVarOfEncl` the site's PREDICATE —
-- [name]'s interface plus the vector `ifaceParamMonos` recovers from the kind's own
-- full occurrence mono, the SAME vector `entailInst` selects the impl row on — so the
-- slot the body reads and the impl the site dispatches to answer one question.  The
-- nested/top kind keeps `activeDictVarOf` (no predicate: [name] there is a
-- constrained FUNCTION, not a method occurrence).
entailAssumVar mctx request m encl _ useScope (EKReturn _ _) =
  activeDictVarOfEncl mctx request m encl useScope
entailAssumVar mctx request m encl _ useScope (EKNumReturn _ _ _ _) =
  activeDictVarOfEncl mctx request m encl useScope
entailAssumVar mctx _ m encl _ useScope (EKNestedTop iface _ _ rest) =
  let request =
    PredicateRequest { prIface = iface, prArgs = PSArgsKnown (m :: rest) }
  match activeFunDictPredOf mctx.mcGraph request useScope
    Some answer => Some answer
    -- #1318 residual: EKNestedTop can still carry OriginUnresolved (#1507).  Preserve
    -- its pre-migration spelling fallback until that producer has declaration identity.
    None =>
      match (activeFunDictPredOfResidual
        mctx.mcGraph
        iface.irName
        (m :: rest)
        useScope)
        Some answer => Some answer
        -- An impl's `requires` givens are id-witnessed, so the predicate-only rungs above
        -- cannot see them; this rung matches them by predicate, as a method occurrence's
        -- does (#1154).  The tyvar-keyed registry that follows holds one entry per
        -- `requires` predicate on the variable, so it answers with the first binder
        -- whose interface is the goal's or reaches it through superclasses.
        None => match implReqDictVarOf mctx.mcGraph (Some request) m useScope
          Some answer => Some answer
          None =>
            map
              LegacyScalar
              (activeDictVarAnswering mctx.mcGraph m useScope (b =>
                scalarGivenAnswers mctx.mcGraph b iface useScope))
entailAssumVar mctx request m encl _ useScope (EKArg _ _) =
  activeDictVarOfEncl mctx request m encl useScope
entailAssumVar mctx request m encl name useScope (EKOp isBinop inImpl) =
  -- #1318: the in-impl non-append operator arm in opDictVarOf retains its scalar
  -- bypass pending a parameter-offset contract fix.
  opDictVarOf mctx request isBinop name m inImpl encl useScope
entailAssumVar mctx request m encl _ useScope (EKPredicateOp _ _ _) =
  activeDictVarOfEncl mctx request m encl useScope

-- The interface of the predicate a goal of [kind] discharges, when the kind knows it.
goalIfaceOfKind : ModuleCtx -> String -> EntailKind -> Option IfaceRef
goalIfaceOfKind mctx _ (EKNestedTop iface _ _ _) =
  if iface.irName == "" then None else Some iface
goalIfaceOfKind mctx _ (EKNumReturn predicate _ _ _) =
  Some predicate.predicateInterface
goalIfaceOfKind mctx _ (EKPredicateOp _ _ predicate) =
  Some predicate.predicateInterface
goalIfaceOfKind mctx name _ = methodIfaceHere mctx name

entailAssumRoute : String -> EntailKind -> Route
entailAssumRoute dname (EKReturn _ isRp) =
  if isRp then RDictFwd dname else RDict dname
entailAssumRoute dname (EKNumReturn _ _ isRp _) =
  if isRp then RDictFwd dname else RDict dname
entailAssumRoute dname (EKNestedTop _ _ _ _) = RDict dname
entailAssumRoute dname (EKArg _ _) = RDict dname
entailAssumRoute dname (EKOp _ _) = RDict dname
entailAssumRoute dname (EKPredicateOp _ _ _) = RDict dname

selectReturnRow : SiteCtx -> ImplEnv -> String -> List Mono -> Option ImplRow
selectReturnRow sx env name goals = match ieSelectRowByMethod sx env name goals
  Some row => Some row
  None => match methodIfaceHere sx.sxModule name
    Some iface => determinedGoalInstance sx.sxModule iface goals
    None => None

-- The instance a boundary's determination committed [iface]'s goal [goals] to
-- (`fileDeterminedRow`).  Selection by head constructor names nothing for a goal
-- whose first position is still a variable, such as one committed to a headless
-- instance; the commit is that goal's evidence.  The route reads the boundary's
-- decision rather than deciding again.
export
determinedGoalInstance : ModuleCtx -> IfaceRef -> List Mono -> Option ImplRow
determinedGoalInstance mctx _ [] = None
determinedGoalInstance mctx iface (first :: rest) = match normalize first
  TVar cell =>
    let goals = first :: rest
    let filed =
      optionOr
        []
        (IdMap.get (tyvarId cell) mctx.mcCells.determinedRowsRef.value)
    match filterList (entry => determinedEntryAnswers iface goals entry) filed
      (row, _) :: _ => Some row
      [] => None
  _ => None

-- inst: a concrete head [tag].  EKReturn → canonical full-type key + split element routes
-- (implRef-bound); EKNestedTop → the min⊑ winner's canonical key with requires PACKED
-- into the primary RKey (RNone when no row answers the vector);
-- EKArg → same canonical RKey primary as EKReturn but element routes keyed on the
-- (default-reduced) method via argImplDictRoutesForEncl; EKOp → stampOpRouteVal (builtin
-- head → RNone do-nothing, else RKey with reqs packed in, no separate element routes).
entailInst : SiteCtx ->
  String ->
  Mono ->
  String ->
  ScopeId ->
  String ->
  EntailKind ->
  (Route, List Route)
-- The exact arm selects on the interface's full instantiated parameter vector and
-- uses that same row and vector for both the route word and prerequisites.  A method
-- with no registered vector retains the legacy scalar result-head match.
entailInst sx name m encl useScope tag (EKReturn fullMono _) =
  let env = sx.sxModule.mcCells.bodyImplEnvRef.value
  match ifaceParamMonos sx.sxModule name fullMono
    Some goals => match selectReturnRow sx env name goals
      Some row =>
        let routeKey = rowRouteKey row
        let routes = implDictRoutesForRow sx encl useScope goals row
        (
          RKey
            routeKey
            []
            (selectedCallSupers sx name (Some row) encl useScope goals),
          routes,
        )
      -- No row: the goal has no instance, and the site keeps no route.
      None => (RNone, [])
    -- A method without predicate-vector metadata retains the scalar result-head
    -- selection and substitution used by the compatibility path.
    None => match ieSelectRowByMethod sx env name [m]
      Some row =>
        let routeKey = rowRouteKey row
        let routes = legacyReturnReqRoutesForRow sx encl useScope m row
        (
          RKey
            routeKey
            []
            (selectedCallSupers sx name (Some row) encl useScope [m]),
          routes,
        )
      -- No vector and no row: the site keeps no route.  An occurrence of a spelling
      -- with two or more admitted declarations never reaches here: its route is
      -- `resolveAdmittedSite`'s, and its verdict `checkAdmittedOccObl`'s.
      None => (RNone, [])
entailInst sx name m encl useScope _ (kind@(EKNumReturn predicate _ _ _)) =
  let goals = predicate.predicateArguments
  let env = sx.sxModule.mcCells.bodyImplEnvRef.value
  match ieSelectRowByIface sx env predicate.predicateInterface goals
    Some (row@(ImplRow _ _ selectedIface _ _ _ _)) =>
      let sups = selectedCallSupers sx name (Some row) encl useScope goals
      let route = RKey (rowRouteKey row) [] sups
      let routes = implDictRoutesForRow sx encl useScope goals row
      noteNumericEntailment sx kind useScope (Some selectedIface) route routes
      (route, routes)
    None =>
      noteNumericEntailment sx kind useScope None RNone []
      (RNone, [])
-- The primary route is the canonical key of the MOST-SPECIFIC impl (iface-keyed),
-- and every nested-`requires`/super-projection goal funnels through here, with
-- the packed requires coming from that same winner.
--
-- A nested/top `requires` goal is a PREDICATE: its goal is the predicate's whole
-- argument vector (§3 `match(IE, C τ̄)`), not its subject mono. [rest] is `[]` at
-- every caller with no goal vector, so those sites are unchanged.
--
-- The top-level `=>`-constrained-call leg also threads its own goal vector through
-- this arm, carrying the vector recorded at SIGNATURE REGISTRATION
-- (the `psArgs` of the function's `funPredicateSlotsRef` slots).  A dict slot per
-- predicate would move the emitted dict arity; that is #607 punch-list item 3, open.
entailInst sx _ m encl useScope _ (EKNestedTop iface _ walk rest) =
  -- Select the row once and hand that same value to both the route-word and
  -- prerequisite projections.  This makes §6 C2 structural: the dictionary names
  -- the same impl whose context it discharges.
  let goals = m :: rest
  let env = sx.sxModule.mcCells.bodyImplEnvRef.value
  match ieSelectRowByIface sx env iface goals
    Some row => (nestedRowRoute sx encl useScope m goals walk row, [])
    -- No instance answers the vector (a call of `f : K x y => x -> String` leaves
    -- the constraint-only `y` undetermined): the dictionary keeps no route, and the
    -- evidence judgment rejects the call (`compiler/types/evidence_complete.mdk`).
    None => (RNone, [])
-- #609: select on the interface's FULL param vector (§5 — the dispatch type is the
-- instantiated vector `T̄`), not on the discriminating ARGUMENT's mono alone.
-- [goals] is bound ONCE and fed to BOTH arms: the method route (`routeKey`) and the
-- selected impl's own `requires`-context routes.  That is not a tidiness point — §6
-- C2 requires the impl dispatched to and the impl whose context is discharged to be
-- the SAME impl; computing the vector here but handing the scalar `m` to
-- argImplDictRoutesForEncl would let the two arms select differently at n≥2.  Sharing
-- one binding makes them agree by construction.
entailInst sx name m encl useScope tag (EKArg fullMono omitted) =
  let goals =
    optionOr [m] (occurrenceParamMonos sx.sxModule name fullMono omitted)
  let (siteKey, selected) = keyForSite sx name goals
  -- Graph-global, off `bodyImplEnvRef` — see `ieDefinesReqMethodAt`,
  -- which carries the measured repro.  The head is `headTyconMono m`, the `HeadKey`
  -- whose name IS this arm's `tag` (`entail` derives `tag` from the same `m` via
  -- `headKeyTag`), NOT `goalHeadCon goals` — this guard asks about
  -- the DISCRIMINATING mono's head, and re-aiming it at the vector's head would be a
  -- second, unrelated semantic change at n>=2.
  let dictName =
    if ieDefinesReqMethodAt
      sx.sxModule.mcCells.bodyImplEnvRef.value
      name
      (headTyconMono m) then
      name
    else
      innerDefaultMethod name
  -- The selected impl's head is matched against the interface's first parameter,
  -- not the discriminating argument: `shL : List a -> …` dispatches on a `List a`
  -- argument, and at `a = List Int` matching `impl Sh (List b)` against that argument
  -- would bind `b` to `List Int` where the instance's `b` is `Int`.
  let subject = match goals
    g :: _ => g
    [] => m
  -- No instance answers the vector: the site keeps no route word, and its
  -- obligation is the verdict.  A standalone occurrence that reaches here is
  -- restamped `RLocal` (`resolveRLocalSites`).
  let word = match siteKey
    Some routeKey =>
      RKey routeKey [] (selectedCallSupers sx name selected encl useScope goals)
    None => RNone
  (word, argImplDictRoutesForEncl sx encl useScope dictName tag subject goals)
entailInst sx name m encl useScope tag (EKOp isBinop _) =
  (stampOpRouteVal sx isBinop encl useScope name m tag, [])
entailInst sx name m encl useScope _ (EKPredicateOp _ _ predicate) =
  (stampPredicateOpRouteVal sx encl useScope name m predicate, [])

-- A dictionary's super segment at the goal vector [goals]: one route per DIRECT
-- super of [iface], in declaration order, each solved at that same goal by the whole
-- ladder (DICT-SEMANTICS §2: supers are resolved per construction goal, `assum`
-- before `inst`).  [walk] is the walk that reached [goals], before [goals] itself was
-- entered: a super goal is entered beside it, not below it, and the declared super graph
-- is acyclic (W1), so it cannot recur on its own.
export
superRoutesAt : SiteCtx ->
  IfaceRef ->
  String ->
  ScopeId ->
  List Mono ->
  ReqWalk ->
  List Route
superRoutesAt sx iface encl useScope goals walk =
  map
    (superRouteAt sx encl useScope walk)
    (directSuperGoals sx.sxModule.mcGraph iface goals)

superRouteAt : SiteCtx ->
  String ->
  ScopeId ->
  ReqWalk ->
  (IfaceRef, Option (List Mono)) ->
  Route
superRouteAt sx encl useScope walk (superIface, superArgs) = match superArgs
  Some (g0 :: gs) =>
    noteInnerRoute
      sx
      (routeOfD sx superIface encl useScope CommitSuper g0 gs walk)
  _ => noteInnerRoute sx RNone

-- The dictionary of a goal's selected instance [row]: the row's word, its `requires`
-- answered at [goals], and its own supers.  The word and the context are projections
-- of one row, so the dictionary names the impl whose context it discharges (§6 C2).
nestedRowRoute : SiteCtx ->
  String ->
  ScopeId ->
  Mono ->
  List Mono ->
  ReqWalk ->
  ImplRow ->
  Route
nestedRowRoute sx encl useScope m goals walk (row@(ImplRow _ _ selectedIface _ _ _ _)) =
  RKey
    (rowRouteKey row)
    (argImplRequiresRoutesForRow sx encl useScope m goals walk row)
    (superRoutesAt sx selectedIface encl useScope goals walk)

-- A super goal no dictionary in scope answers and no head constructor selects for: a
-- goal over variables alone.  It is built from the instance the checker's super
-- judgment selected for it (`superGoalEntered`, `residualSelectionStable`), never
-- re-selected at the value: a variable a binder declared is rigid, so the instance is
-- the min⊑ of those matching the goal (DICT-SEMANTICS §6.1.3); a variable the binder
-- generalized reaches it here only when that selection is stable.
committedSuperRoute : SiteCtx ->
  String ->
  ScopeId ->
  IfaceRef ->
  ReqWalk ->
  List Mono ->
  Route
committedSuperRoute sx _ _ _ _ [] = RNone
committedSuperRoute sx encl useScope iface walk (goals@(m :: _)) =
  match stableGoalReach sx.sxModule [] iface goals
    ReachOne row if rowHeadMatches sx.sxModule goals row =>
      nestedRowRoute sx encl useScope m goals walk row
    _ => RNone

-- The super segment of a method-call primary `RKey`.  A call whose selected instance
-- supplies [name] only selects it, so the route carries none; a call whose instance
-- inherits [name]'s default hands that default the instance's dictionary itself (the
-- default's receiver), so the route carries the dictionary's supers, solved at the
-- goal like any dictionary's.
export
selectedCallSupers : SiteCtx ->
  String ->
  Option ImplRow ->
  String ->
  ScopeId ->
  List Mono ->
  List Route
selectedCallSupers sx name (Some (ImplRow _ _ iface _ _ supplied _)) encl useScope goals =
  if contains name supplied then
    []
  else
    superRoutesAt sx iface encl useScope goals (reqWalkStart ())
selectedCallSupers sx _ None _ _ _ = []

entailFallback : SiteCtx -> String -> ScopeId -> Mono -> EntailKind -> Route
entailFallback sx _ _ _ (EKReturn _ _) = RNone
entailFallback sx _ _ _ (EKNumReturn _ _ _ _) = RNone
entailFallback sx encl scope m (EKNestedTop iface policy walk rest) =
  undeterminedRoute sx encl scope iface policy walk (m :: rest)
entailFallback sx _ _ _ (EKArg _ _) = RNone
entailFallback sx _ _ _ (EKOp _ _) = RNone
entailFallback sx _ _ _ (EKPredicateOp _ _ _) = RNone

-- #217: the walk-carrying core of routeOf.  [walk] threads the shared `requires`
-- measure through the aware recursion (routeOfD → argImplRequiresRoutesForRow →
-- argImplReqRoutes → argReqRoute → routeOfD); the goal is entered in
-- argImplRequiresRoutesForRow, once per impl level.
-- #1154 (F-3a): [rest] carries the predicate's goal args past arg 0 (see EKNestedTop).
export
routeOfD : SiteCtx ->
  IfaceRef ->
  String ->
  ScopeId ->
  Undetermined ->
  Mono ->
  List Mono ->
  ReqWalk ->
  Route
-- #156 S3b: a thin adapter over `entail` (EKNestedTop kind).  The nested/top ladder
-- packs its `requires` into the primary RKey, so `snd` is empty and only `fst` is read —
-- byte-identical to the pre-S3b arm-by-arm body.  The requires recursion still lands back
-- here via argImplRequiresRoutesForRow → argImplReqRoutes → argReqRoute → routeOfD, with the
-- walk threaded through the EKNestedTop payload.
routeOfD sx iface encl useScope policy m rest walk =
  fst (entail sx "" m encl useScope (EKNestedTop iface policy walk rest))

undeterminedRoute : SiteCtx ->
  String ->
  ScopeId ->
  IfaceRef ->
  Undetermined ->
  ReqWalk ->
  List Mono ->
  Route
undeterminedRoute sx _ _ _ KeepNone _ _ = RNone
undeterminedRoute sx _ scope _ (CountImpls iface) _ goal =
  routeUndeterminedTop sx scope iface goal
undeterminedRoute sx encl scope iface CommitSuper walk goal =
  committedSuperRoute sx encl scope iface walk goal

-- The undetermined-constraint resolution (DICT-SEMANTICS §3): the instances the
-- goal [goal] can still reach, counted by `goalCandidates` and decided by
-- `goalReach` exactly as a boundary's verdict decides them.  None leaves the goal no
-- route; one, or a stable minimum, is its route; any other count is ambiguous.
routeUndeterminedTop : SiteCtx -> ScopeId -> IfaceRef -> List Mono -> Route
routeUndeterminedTop sx scope ifaceRef goal
  | ifaceRef.irName == "" = RNone
  | otherwise =
    match (goalReach
      sx.sxModule
      goal
      (goalCandidates
        sx.sxModule
        omEmpty
        goal
        (goalRows sx.sxModule ifaceRef goal)))
      ReachNone => RNone
      -- A goal on a scheme-quantified variable is the caller's: the one instance it
      -- reaches is not chosen for it.
      ReachOne _ if not (monoVectorClosed goal)
        && goalsClosed sx.sxModule goal => RNone
      ReachOne row => undeterminedRowRoute sx scope ifaceRef goal row
      -- No route and no diagnostic: the boundary verdict (`goalReach` at quiescence)
      -- owns an ambiguous goal and reports it once at its own site.
      ReachMany => RNone

-- The route of the one instance [row] an undetermined goal reaches: its canonical
-- word, its prerequisites answered at the goal, and each super of [ifaceRef], which
-- the goal leaves undetermined too, answered by the same rule.
undeterminedRowRoute : SiteCtx ->
  ScopeId ->
  IfaceRef ->
  List Mono ->
  ImplRow ->
  Route
undeterminedRowRoute sx _ _ [] _ = RNone
undeterminedRowRoute sx scope ifaceRef (m :: rest) row =
  RKey
    (rowRouteKey row)
    (argImplRequiresRoutesForRow
      sx
      ""
      scope
      m
      (m :: rest)
      (reqWalkStart ())
      row)
    (map
      ((superIface, _) =>
        noteInnerRoute
          sx
          (routeUndeterminedTop sx scope superIface (m :: rest)))
      (directSuperGoals sx.sxModule.mcGraph ifaceRef []))

-- Native #54/#21 residual: the activeDictVar-AWARE requires recursion.  Recursing
-- via routeOf (not the removed blind reqRoute) keeps every nesting level
-- activeDictVar-aware: e.g. a `Debug (Map k v)` impl body's `debug (toList m)` arg-
-- stamps `List (k, v)` → RKey "List" recursing into the tuple `(k, v)` whose element
-- vars `k`/`v` ARE the enclosing impl's `requires Debug k, Debug v` dict params
-- (registered in activeDictVars), so they route RDict $dict_debug_<slot>, NOT RNone.
-- The emitted element-dict cell carries the live impl dicts instead of a null (0)
-- field — the null field was the SIGSEGV (the inner per-element debug/eq/compare
-- dispatched through a 0 dict).
-- #217: this is now the SOLE requires recursion — the return position
-- (implDictRoutesIn) routes through here too, no longer through a blind twin.  [encl]
-- threads the enclosing method so nested element dicts forward its own
-- `$dict_<encl>_<slot>` params (encl == "" recovers the global routing).
-- (#1154 folded away the depth-0 wrapper `argImplRequiresRoutesRec`: two names for one
-- body, one caller each.  Seed `reqWalkStart` at an entry point instead.)
--
-- Termination is the shared `requires` measure (`reqWalkEnter`, DICT §3 W2), the same
-- one every solving walk uses: a step to a strictly smaller goal is free, so a ground
-- chain like `impl Tag (Wrap a) requires Tag a` at `Wrap^34 Int` routes at any depth
-- its type needs (#1576); a non-shrinking step spends fuel; a repeated goal is a cycle.
-- This walk also enters each super of a goal beside it (`superRoutesAt`) and follows
-- that super instance's `requires`.  The solving walks follow the same goals under that
-- measure, the super goals included (`superGoalsEntered`, entered beside the goal the
-- same way), and reject a cycle or a spent walk at the goal's site, so this walk
-- reaches either outcome only on a rejected program (`requiresRouteWalkCut`).
--
-- The caller supplies the selected row, so the route word and the context it
-- discharges name the same impl (§6 C2) by construction.
argImplRequiresRoutesForRow : SiteCtx ->
  String ->
  ScopeId ->
  Mono ->
  List Mono ->
  ReqWalk ->
  ImplRow ->
  List Route
argImplRequiresRoutesForRow sx encl useScope m goals walk row =
  match reqWalkEnter walk (ieRowIface row) goals
    ReqOn next => routeWalkMemoized
      sx
      encl
      useScope
      goals
      row
      next
      (walkSx => match ieRowHeadTriple (Some row)
        Some (headTy, itys, reqs) =>
          match headSubstWithParams sx.sxModule headTy itys m goals
            Some subst => argImplReqRoutes walkSx encl useScope subst reqs next
            None => []
        None => [])
    cut =>
      noteRouteWalkCut walk
      requiresRouteWalkCut sx.sxModule.mcGraph cut

-- A route walk that met a cycle or ran out of fuel.  The solving walks share its
-- measure and follow the same goals, a super instance's `requires` included
-- (`superGoalsEntered`), and reject the goal at its site, so this is reached only on a
-- program that already carries a type error, and its routes are never emitted.  With no error
-- recorded it is a compiler invariant failure, never a silent `[]` (#1910).
requiresRouteWalkCut : GraphCtx -> ReqStep -> List Route
requiresRouteWalkCut gctx _ =
  if typeErrorsArmed gctx () then
    []
  else
    panic "requires route walk reached a goal the solving walks did not accept"

-- ── D3b-1: arg-position element-dict routing ────────────────────────────────
-- The argument-position analogue of implDictRoutesFor.  Same impl-table match +
-- head-pattern unification against the discriminating-argument mono, but each
-- requires route is computed by routeOf (activeDictVar-aware): a recursive
-- element of the SAME parametric type (the impl's own element tyvar `a`, still a
-- registered constraint var) forwards the in-scope `$dict_<method>_<slot>` param
-- (RDict); a concrete element (`MyList Int`) materializes a static RKey.  #217: the
-- return position (implDictRoutesIn) now shares this same aware requires recursion — the
-- two chains were unified; this entry runs for emit-path arg stamps specifically.
-- #609: the operator route passes the singleton [mono] — and unlike the
-- deferred EKNestedTop case this is not a scope cut, it is EXACT: every interface
-- owning an operator method is single-param (`Eq a`, `Ord a`, `Num a`,
-- `Semigroup a`, `Monoid a` in stdlib/core.mdk), so `itys` has length 1, the
-- lengths agree, and the singleton IS the full vector — matchTyMonos [hty] [m]
-- reduces to matchTyMono hty m.  Should a multi-param interface ever own an
-- operator, entryHeadMatches degrades to the arg-0 fallback rather than
-- mis-selecting.
-- encl-aware variant: thread the ENCLOSING method [encl] so the recursively-routed
-- element dicts forward [encl]'s own `$dict_<encl>_<slot>` params (not whichever
-- method registered the shared impl tyvar id LAST — see activeDictVarOf).  An
-- empty [encl] has no lexical dict owner and therefore cannot forward one.
-- #203: the arg/op-position element routes select the MOST-SPECIFIC matching impl over
-- the graph-global impl universe (`IE`) via the shared method-keyed selector
-- (`ieSelectRowByMethod`) and discharge THAT impl's OWN requires; a first-match scan
-- would be blind to no-requires siblings (see implDictRoutesForRow).  A
-- non-overlapping site (one match) selects the impl a first-match scan would ⇒
-- identical routes.
-- #609 (arg position): selects on the goal VECTOR [goals] and binds the subst from
-- the winner's FULL head types, as the return-position selected-row matcher does.
-- This is the SAME defect as #609 proper, one leg over:
-- selecting on `[mono]` length-mismatches a multi-param impl's `itys`, so
-- entryHeadMatches fell back to arg-0 and two siblings differing only past arg 0 both
-- matched.  They are genuinely disjoint, so coherence never rejected them and
-- entryCovers finds them incomparable ⇒ pickMostSpecificEntry took the FIRST-DECLARED,
-- and the impl whose `requires`-context was routed could differ from the impl
-- `routeKey` dispatched to — evidence for instance A attached to methods of instance
-- B (§2 "evidence is a tree"; §6 C2 coherence), order-dependently (§6 C3).
--
-- Only observable when the siblings' requires differ in COUNT.  The dict cell is a
-- TYPE tag (`@mdk_dc_0 = [1 x i64] [193460240]` — the `Int` tag, shared with
-- println's dict), and the routes are built from the subst, so two siblings whose
-- requires range over the SAME tyvar produce the SAME dict whichever is picked; the
-- interface is re-chosen at the use site by a method-specific dispatcher
-- (`@mdk_disp_bar_0_1`).  Differing COUNTS thread the wrong NUMBER of dicts, shifting
-- every later argument.  Regression:
-- test/eval_typed_fixtures/multiparam_impl_requires_arity{,_swapped}.mdk.
argImplDictRoutesForEncl : SiteCtx ->
  String ->
  ScopeId ->
  String ->
  String ->
  Mono ->
  List Mono ->
  List Route
-- The two element-dict route sites select the SAME way at the same goal; a split
-- between them is the §6 C2 break (the route word and the prerequisite routes must
-- name one row).
argImplDictRoutesForEncl sx encl useScope name _tag mono goals =
  match (ieRowHeadTriple
    (ieSelectRowByMethod
      sx
      sx.sxModule.mcCells.bodyImplEnvRef.value
      name
      goals))
    Some (headTy, implTys, reqs) =>
      match headSubstWithParams sx.sxModule headTy implTys mono goals
        Some subst =>
          argImplReqRoutes sx encl useScope subst reqs (reqWalkStart ())
        None => []
    None => []

-- #217: [walk] carries the shared `requires` measure through the aware recursion (see
-- argImplRequiresRoutesForRow, where each goal is entered).  An entry point seeds
-- `reqWalkStart`, or `reqWalkSeed` at the goal whose selected row's `requires` these are.
argImplReqRoutes : SiteCtx ->
  String ->
  ScopeId ->
  List (String, Mono) ->
  List Require ->
  ReqWalk ->
  List Route
argImplReqRoutes sx _ _ _ [] _ = []
argImplReqRoutes sx encl useScope subst ((Require { requireHead = rIface, requireArgs = rargs, requireOrigin = ro }) :: rest) walk =
  let iface = IfaceRef { irName = rIface, irOrigin = ro }
  argReqRoute sx iface encl useScope subst rargs walk
    :: argImplReqRoutes sx encl useScope subst rest walk

-- [iface] is the requirement's resolved interface, origin included: two interfaces
-- spelled alike (`requires A.Sh a, B.Sh a`) select their impls by declaration, and a
-- bare spelling here selects whichever same-named row matches first (#3534).
argReqRoute : SiteCtx ->
  IfaceRef ->
  String ->
  ScopeId ->
  List (String, Mono) ->
  List Ty ->
  ReqWalk ->
  Route
argReqRoute sx _ _ _ _ [] _ = noteInnerRoute sx RNone
-- #1154 (F-3a): matching `(arg::_)` would drop every argument past arg 0, so a
-- multi-param `requires Ix a Char` would reach the selector as the singleton `[Int]` and
-- match every `Ix Int _` impl.  Keep the whole vector; `routeOfD` threads the tail down the
-- EKNestedTop leg.  Single-param requires bind `more == []` ⇒ unchanged.
argReqRoute sx iface encl useScope subst (arg :: more) walk =
  noteInnerRoute
    sx
    (routeOfD
      sx
      iface
      encl
      useScope
      KeepNone
      (fromAstType sx.sxModule subst arg)
      (map (fromAstType sx.sxModule subst) more)
      walk)

-- Each direct super of [iface] at the goal vector [goals], in declaration order, with
-- its argument vector — `None` when a super parameter does not resolve against the
-- goal (a shorter-than-declared vector).  One entry per declared super, always, so
-- a super's position in this list is its index in every dictionary of [iface].
export
directSuperGoals : GraphCtx ->
  IfaceRef ->
  List Mono ->
  List (IfaceRef, Option (List Mono))
directSuperGoals gctx iface goals = match superLookup gctx iface
  None => []
  Some (typarams, supers) =>
    map
      (sup => (
        superIfaceRef sup,
        if listLen goals == listLen typarams then
          mapAll (p => lookupPos p typarams goals) (superParamsOf sup)
        else
          None,
      ))
      supers

export
superParamsOf : Super -> List String
superParamsOf (Super { superParams = params, ... }) = params

determinedEntryAnswers : IfaceRef -> List Mono -> (ImplRow, List Mono) -> Bool
determinedEntryAnswers iface goals (row, committed) =
  ieRowOfIface iface row
    && listLen committed == listLen goals
    && allList (pair => cohEqMono (fst pair) (snd pair)) (zip committed goals)

-- The rows of [iface] a goal can unify with: those filed under the goal's first
-- head constructor or under none, or every row of [iface] when the goal's first
-- position is a variable.
export
goalRows : ModuleCtx -> IfaceRef -> List Mono -> List ImplRow
goalRows mctx iface args =
  let env = mctx.mcCells.bodyImplEnvRef.value
  let pool = match goalHeadCon args
    Some hk => ieHeadRows (Some hk) env ++ ieHeadRows None env
    None => ieRowsAll env
  filterList (ieRowOfIface iface) pool

-- A goal with fewer positions than some head of its interface is the projection
-- of a wider goal onto its first positions: a per-slot goal `recordCallObligations`
-- shatters a predicate into, or the receiver position of a method occurrence.
export
goalIsProjection : List Mono -> List ImplRow -> Bool
goalIsProjection args rows =
  anyList (row => listLen (ieRowTys row) > listLen args) rows

-- The instances an undetermined goal can still reach (DICT-SEMANTICS §3): the rows
-- of [rows] whose heads unify with [args], every variable in [rigidIds] held rigid
-- and the instance's variables fresh, each with the substitution that unifies it.
-- Every head shape is unified by its structure: data, tuple, arrow, qualified and
-- variable heads alike.  A projection is unified with each head's first positions,
-- and heads that agree there reach it as one candidate.
export
goalCandidates : ModuleCtx ->
  OrdMap Unit ->
  List Mono ->
  List ImplRow ->
  List (ImplRow, List (Int, Mono))
goalCandidates mctx rigidIds args rows =
  let unifying =
    flatMap
      (row => match rowPrefixSubstRigid mctx rigidIds args row
        Some subst => [(row, subst)]
        None => [])
      rows
  if goalIsProjection args rows then
    distinctPrefixes (listLen args) unifying []
  else
    unifying

-- [row]'s first `listLen args` heads, freshened, unified with [args] in a scratch
-- substitution with every variable in [rigidIds] held rigid.
rowPrefixSubstRigid : ModuleCtx ->
  OrdMap Unit ->
  List Mono ->
  ImplRow ->
  Option (List (Int, Mono))
rowPrefixSubstRigid mctx rigidIds args row =
  map
    (scratch => !scratch)
    (headsUnifier mctx.mcGraph rigidIds args (freshRowHeads mctx row))

distinctPrefixes : Int ->
  List (ImplRow, List (Int, Mono)) ->
  List (ImplRow, List (Int, Mono)) ->
  List (ImplRow, List (Int, Mono))
distinctPrefixes _ [] kept = reverse kept
distinctPrefixes k (cand :: rest) kept =
  let prefix = take k (ieRowTys (fst cand))
  if anyList (seen => tyHeadEqV prefix (take k (ieRowTys (fst seen)))) kept then
    distinctPrefixes k rest kept
  else
    distinctPrefixes k rest (cand :: kept)

export
goalReach : ModuleCtx ->
  List Mono ->
  List (ImplRow, List (Int, Mono)) ->
  GoalReach
goalReach mctx _ [] = ReachNone
goalReach mctx _ [(row, _)] = ReachOne row
goalReach mctx args cands =
  let rows = map fst cands
  match filterList (row => stableMinimum mctx args rows row) rows
    row :: _ => ReachOne row
    [] => ReachMany

stableMinimum : ModuleCtx -> List Mono -> List ImplRow -> ImplRow -> Bool
stableMinimum mctx args rows row =
  rowHeadMatches mctx args row
    && allList (other => tySubsumesV (ieRowTys other) (ieRowTys row)) rows

-- A candidate does not count when its first head unifies with the goal only by
-- peeling a qualifier: `<Stdout> Int` elaborates to `Int`, and the head matcher
-- reads through a constraint or authority qualifier the same way, so against a
-- goal whose first position is already `Int` such an instance is not a second
-- type the goal could have (`test/engine_fixtures/fun_head_impl_bystander.mdk`).
-- A goal whose first position is a variable binds it to the qualified head
-- without peeling anything, so there the instance counts.  An arrow-, tuple- or
-- variable-headed instance unifies by its structure and counts.
export
rowCountsFor : List Mono -> ImplRow -> Bool
rowCountsFor args row = match ieRowTys row
  headTy :: _ =>
    not (tyIsQualified (headTySpineNode headTy)) || goalFirstIsVariable args
  [] => False

goalFirstIsVariable : List Mono -> Bool
goalFirstIsVariable (a :: _) = match normalize a
  TVar _ => True
  _ => False
goalFirstIsVariable [] = False

tyIsQualified : Ty -> Bool
tyIsQualified (TyEffect _ _ _) = True
tyIsQualified (TyConstrained _ _) = True
tyIsQualified (TyQual _ _ _) = True
tyIsQualified _ = False

export
freshRowHeads : ModuleCtx -> ImplRow -> List Mono
freshRowHeads mctx row = snd (freshRowHeadsTvs mctx row)

-- [row]'s heads with each of its variables fresh, and the name each fresh variable
-- stands for.
export
freshRowHeadsTvs : ModuleCtx -> ImplRow -> (List (String, Mono), List Mono)
freshRowHeadsTvs mctx row =
  let tys = ieRowTys row
  let tvs = freshTvMap mctx (dedup (flatMap tyVarNames tys))
  (tvs, map (fromAstType mctx tvs) tys)

export
rowHeadMatches : ModuleCtx -> List Mono -> ImplRow -> Bool
rowHeadMatches mctx args row = isSome (implHeadSubst mctx (ieRowTys row) args)

-- What the instance heads that unify with the goal decide (`goalReach`), with the
-- goal's variables that some binder declared (`declaredSigVarIds`) and [chosen] does
-- not name held rigid.
export
stableGoalReach : ModuleCtx -> List Int -> IfaceRef -> List Mono -> GoalReach
stableGoalReach mctx chosen iface args =
  let declared = mctx.mcCells.declaredSigVarIds.value
  let rigidIds =
    omFromNames
      (map
        intToString
        (filterList
          (i => not (containsI i chosen) && omHasKey (intToString i) declared)
          (dedupI (flatMap monoUnboundIds args))))
      omEmpty
  goalReach
    mctx
    args
    (filterList
      (c => rowCountsFor args (fst c))
      (goalCandidates mctx rigidIds args (goalRows mctx iface args)))

-- does SOME impl of [iface] match the concrete dispatch monos [args]? (existence)
export
implMatchesU : ModuleCtx -> ImplUniverse -> IfaceRef -> List Mono -> Bool
implMatchesU mctx _ _ [] = False
implMatchesU mctx univ iface (a0 :: rest) =
  bucketArgsMatch
      mctx
      (univConcreteBucket univ iface (headTyconMono a0))
      (a0 :: rest)
    || bucketArgsMatch mctx (univHeadless univ iface) (a0 :: rest)

bucketArgsMatch : ModuleCtx -> List (List Ty, List Require) -> List Mono -> Bool
bucketArgsMatch mctx [] _ = False
bucketArgsMatch mctx ((tys, _) :: rest) args =
  implHeadMatchesArgs mctx tys args || bucketArgsMatch mctx rest args

-- the impl of [iface] whose `requires` we must check at a dispatch to [args] (the
-- receiver-head mono [args[0]]), with its (subst, reqs) — the impl checkNestedReqs
-- then discharges.  The concrete RECEIVER-head bucket is consulted BEFORE the iface's
-- headless bucket, so a specific impl always outranks a `impl Foo a` catch-all.
--
-- Coherence ACCEPTS a specific-vs-general overlap (`impl Foo Int` + `impl Foo a`,
-- most-specific-wins), so TWO impls can match one concrete mono.  Selecting the WRONG
-- one's requires is a soundness hole: parametric `impl Foo a` (no reqs) first + concrete
-- `impl Foo Int requires Bar Int` (no `impl Bar`) → an ACCEPT then a runtime null-dict
-- crash, because `foo (3:Int)` dispatches to the MOST-SPECIFIC `impl Foo Int`.
--
-- #326: the within-bucket winner is chosen by the SHARED min⊑ selector — the SAME
-- registry, and the SAME selector, the dispatch ROUTER stamps with (PR #319 fixed the
-- router, this makes the CHECKER agree).  That registry is `ieSelectRowByIface` over the
-- graph-global `IE` (`bodyImplEnvRef`); checker and router select through the one
-- function, so they cannot disagree.  It returns the most-specific impl's
-- OWN requires — [] for a no-requires specific `impl Foo (List Int)` sibling declared
-- ALONGSIDE a `impl Foo (List a) requires Show a`, both in the same `List` head bucket —
-- never the general sibling's.  A concrete-then-headless first-match would rank
-- concrete-vs-headless correctly but take DECLARATION-ORDER first-match WITHIN a shared
-- head bucket, so `Foo (List Int)` could inherit `List a`'s `Show a` requirement (a false
-- reject/accept).  A non-overlapping receiver head has exactly one match, which
-- pickMostSpecificEntry returns unchanged.
-- Headless impls are in the candidate scan: `keyEntryOf` registers a bare-TyVar head
-- under `noneHeadTag` and the scan (`ieCandidatesForIface`/`…ForMethod`) unions it into
-- every goal-head lookup, so a HEADLESS winner can be returned directly.  That does not
-- change which impl's requires get discharged — the union goes through the same min⊑
-- selector, and concrete ⊑ headless strictly at every single-param head, so a concrete
-- match outranks the catch-all.  The `firstReqMatch (univHeadless …)` fallback is
-- therefore reached only when the candidate union has no match at all (e.g. an empty
-- arg list, the arm above).  It is retained because `ImplUniverse` and the impl
-- environment are populated from different decl sets; `findMatchingImplReqsU` below
-- reads `ImplUniverse` only.  Regression:
-- test/typecheck_error_fixtures/overlap_specific_req_wins.mdk (concrete-vs-headless) and
-- overlap_same_head_req_wins{,_swapped}.mdk (#326 within-bucket min⊑).
export
findMatchingImplReqsU : SiteCtx ->
  ImplUniverse ->
  IfaceRef ->
  List Mono ->
  Option (List (String, Mono), List Require)
findMatchingImplReqsU sx univ iface [] =
  firstReqMatch sx.sxModule (univHeadless univ iface) []
-- B-4b-ii supplies the identity here — B-4b-i's `ifaceRefBare iface.irName`
-- wrapper is DELETED, and this is the behaviour change that bite deferred.
--
-- Why this source is trustworthy, stated as a derivation rather than an assertion:
-- `iface` reaches this function from `reqObligationsFor` and `residualPredsOf`, whose
-- own `IfaceRef` is minted by `reqToObligation` off `Require.requireHead` +
-- `Require.requireOrigin` — a carrier `resolve.fillIfaceOccOrigin` stamps from the
-- DECLARING module's `iface:`-tagged scope, under the immunity rule (an occurrence
-- that already carries identity is never re-stamped).  It is NOT taken from
-- `methodEntryHere`, the bare-method-name-keyed table whose own S0s are open;
-- nothing on this path consults it.
--
-- The two legs of this function disagreed, and that is what this fixes.  The
-- HEADLESS fallback one line below has ALWAYS been identity-keyed — `univHeadless`
-- looks the bucket up through `oblIfaceKey`, i.e. `tabKeyOf NsIface ir.irOrigin
-- ir.irName`, which is `TkIdent` for an origin-bearing interface — while the CONCRETE
-- leg re-minted the query bare and asked a SPELLING question over the same population.
-- One function, two keyings, and the concrete leg is the one tried first.
--
-- MEASURED false reject this removes (hand-derived first, then run): two unrelated
-- modules each declaring `interface Same a`, each with `impl Same (Box a)` — one plain,
-- one `requires Eq a`.  A use of the PLAIN one's method at `Box Opaque` was rejected
-- with *"No impl of Eq for Opaque"*, because the spelling scan reached the OTHER
-- module's row and imposed ITS `requires`.  Swapping the two modules' names made the
-- same program compile: the answer depended on declaration order, which is the
-- signature of a spelling-keyed selection. See `test/dict_fixtures/b4bii-*`.
--
-- Absence is still A WILDCARD, and that is what keeps the flat drivers alive:
-- `sameTyConHead`'s `tyConIdsConflict` answers True only when BOTH origins are
-- identities and they differ, so a single-file `check`/lsp/repl/doc run — which stamps
-- nothing — is unaffected, term for term.  This is NOT `ifaceIdMatches`; see
-- `ieRowIfaceMatches`.
findMatchingImplReqsU sx univ iface (a0 :: rest) =
  match concreteReqMatchByIface sx iface (a0 :: rest)
    Some r => Some r
    None => firstReqMatch sx.sxModule (univHeadless univ iface) (a0 :: rest)

-- #326: the concrete-receiver-head requires match, routed through the shared min⊑
-- selector over the all-impls KeyBuckets registry (the router's `ieSelectRowByIface`
-- selects the SAME entry the SAME way).  Bind the winning
-- impl's typaram vars by matching its FULL head types against [args] (multi-param subst
-- preserved), then hand back that impl's OWN requires.  A selected entry whose full head
-- fails to match [args] yields None, so findMatchingImplReqsU falls through to the
-- headless bucket, mirroring the old scan.
-- #609: select on [args] — the FULL head-mono vector this function already matches
-- the winner's `itys` against two lines down.  Selecting on the receiver alone while
-- substituting against the whole vector was the same split #609 names: the checker
-- saw the vector, the selector saw arg 0.  With one goal for both, a selected entry
-- can no longer fail the subst for a reason the selector could have seen.
concreteReqMatchByIface : SiteCtx ->
  IfaceRef ->
  List Mono ->
  Option (List (String, Mono), List Require)
-- Use `bodyImplEnvRef`, not `shadowKeyTableRef`: the latter is a topological PREFIX,
-- so an impl in a later module contributes no `requires` and the goal reads as
-- unroutable. The checker and the two element-dict route sites read this one registry;
-- repointing this function alone produces an S0.
concreteReqMatchByIface sx iface args =
  match (ieSelectRowByIface
    sx
    sx.sxModule.mcCells.bodyImplEnvRef.value
    iface
    args)
    Some row => selectedRowReqMatch sx.sxModule args row
    None => None

firstReqMatch : ModuleCtx ->
  List (List Ty, List Require) ->
  List Mono ->
  Option (List (String, Mono), List Require)
firstReqMatch mctx [] _ = None
firstReqMatch mctx ((tys, reqs) :: rest) args =
  match implHeadSubst mctx tys args
    Some sub => Some (sub, reqs)
    None => firstReqMatch mctx rest args

-- the concrete "iface|tag" bucket (empty when the tag is None / no such impl).
-- The GOAL-side head arrives as a `HeadKey` that can carry identity; the concrete
-- bucket's key is built from it on both sides (`insertUnivImpl` is the impl side),
-- and the tag is that key's bare NAME.  The key is a structured two-component
-- `RegKey`, so a `|` inside either half cannot forge the other, and each half
-- carries its namespace.  Both halves are keyed by SPELLING; `dispHeadTab` derives
-- why.
export
univConcreteBucket : ImplUniverse ->
  IfaceRef ->
  Option HeadKey ->
  List (List Ty, List Require)
univConcreteBucket (ImplUniverse conc _) iface (Some hk) =
  mregLookupK (regKeyNTab [oblIfaceKey iface, dispHeadTab hk]) conc
univConcreteBucket _ _ None = []

export
univHeadless : ImplUniverse -> IfaceRef -> List (List Ty, List Require)
univHeadless (ImplUniverse _ hl) iface =
  mregLookupK (regKeyOfTab (oblIfaceKey iface)) hl

-- does SOME impl of [iface] matching [args] carry a non-empty `requires`?  The
-- reqs-aware twin of `implMatchesU`: same buckets, same concrete-then-headless order,
-- same `implHeadMatchesArgs` success condition, so True-here-with-`findMatchingImplReqsU`-None
-- isolates precisely the two-registry disagreement on a goal that needs a dict.
-- TWO CALLERS, and they must stay the same predicate: `unroutedGroundReqs` (the ground
-- obligation site, SA-1) and `unroutedResidual` (Door 4's residual site, moved here by
-- SA-4 / RUN-055).  They share `requiresUnroutedMsg` verbatim because
-- `pushTypeErrorOnceAt` dedups on message text and a deferred goal reaches BOTH; if the
-- two guards ever disagree about what counts as a match, one of them starts reporting a
-- defect the other has already ruled out.
export
implMatchesWithReqsU : ModuleCtx ->
  ImplUniverse ->
  IfaceRef ->
  List Mono ->
  Bool
implMatchesWithReqsU mctx _ _ [] = False
implMatchesWithReqsU mctx univ iface (a0 :: rest) =
  bucketArgsMatchReqs
      mctx
      (univConcreteBucket univ iface (headTyconMono a0))
      (a0 :: rest)
    || bucketArgsMatchReqs mctx (univHeadless univ iface) (a0 :: rest)

bucketArgsMatchReqs : ModuleCtx ->
  List (List Ty, List Require) ->
  List Mono ->
  Bool
bucketArgsMatchReqs mctx [] _ = False
bucketArgsMatchReqs mctx ((tys, reqs) :: rest) args =
  isNonEmptyL reqs && implHeadMatchesArgs mctx tys args
    || bucketArgsMatchReqs mctx rest args

-- The keyed matchers (`bucketArgsMatch`, `bucketArgsMatchReqs`) test a bucket entry with
-- implHeadMatchesArgs: each head-arg type pattern is
-- matched against the corresponding mono via matchTyMono (a TyVar in the head is a
-- wildcard; a parametric impl `impl Eq (List a)` thus matches `List Int`), and a
-- variable the head repeats must be bound consistently across positions
-- (`implHeadSubst`).
implHeadMatchesArgs : ModuleCtx -> List Ty -> List Mono -> Bool
implHeadMatchesArgs mctx tys args = isSome (implHeadSubst mctx tys args)
# DESUGAR
(DUse false (UseGroup ("types" "tc_types") ((mem "PredicateSlotArgs" true) (mem "AssumAnswer" true) (mem "EntailKind" true) (mem "GoalReach" true) (mem "ImplUniverse" true) (mem "NumericPredicateTraceEntry" true) (mem "NumericPredicateTraceStage" true) (mem "PredicateRequest" true) (mem "ReqStep" true) (mem "RouteWalkEntry" true) (mem "SiteCtx" true) (mem "Undetermined" true) (mem "WalkMemo" true) (mem "GraphCtx" false) (mem "ImplEnv" false) (mem "ImplRow" false) (mem "KeyEntry" false) (mem "ModuleCtx" false) (mem "ReqWalk" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "anyListM" false) (mem "cohEqMono" false) (mem "cohOverlapGo" false) (mem "containsI" false) (mem "dedupI" false) (mem "headsUnifier" false) (mem "headTyconMono" false) (mem "headTySpineNode" false) (mem "isBareTyvarMono" false) (mem "matchEqMono" false) (mem "matchTyMono" false) (mem "mergeOne" false) (mem "mergeSubstPreferConcrete" false) (mem "monoSizes" false) (mem "monoUnboundIds" false) (mem "monoVecSameGiven" false) (mem "monoVectorClosed" false) (mem "rigidSigPairs" false) (mem "tyHeadEqV" false) (mem "tyStrictlyMoreSpecificV" false) (mem "tySubsumesV" false) (mem "tyvarId" false) (mem "tyVarNames" false))))
(DUse false (UseGroup ("types" "tc_diag_text") ((mem "ambiguousOverlapMsg" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "ieCandidatesForIface" false) (mem "ieCandidatesForMethod" false) (mem "ieDefinesReqMethodAt" false) (mem "ieEntriesForIface" false) (mem "ieHeadRows" false) (mem "ieRowHeadTriple" false) (mem "ieRowIface" false) (mem "ieRowOfEntry" false) (mem "ieRowOfIface" false) (mem "ieRowsAll" false) (mem "ieRowTys" false) (mem "keyEntryIface" false) (mem "originMethodName" false) (mem "sameIfaceDecl" false) (mem "superLookup" false) (mem "dispHeadTab" false) (mem "oblIfaceKey" false))))
(DUse false (UseGroup ("types" "tc_diag") ((mem "erredDuring" false) (mem "pushAmbiguityAt" false) (mem "typeErrorsArmed" false))))
(DUse false (UseGroup ("types" "tc_scope") ((mem "methodAdmissionHere" false) (mem "methodEntryHere" false) (mem "methodIfaceHere" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "freshTvMap" false))))
(DUse false (UseGroup ("types" "tc_decls_types") ((mem "fromAstType" false))))
(DUse false (UseGroup ("types" "tc_solve_givens") ((mem "activeDictPredOf" false) (mem "activeDictVarAnswering" false) (mem "activeDictVarOf" false) (mem "activeDictVarOfEncl" false) (mem "activeFunDictPredOf" false) (mem "activeFunDictPredOfResidual" false) (mem "assumAnswerRoute" false) (mem "enclDictVarOf" false) (mem "implReqDictVarOf" false) (mem "noteAssumption" false) (mem "scalarGivenAnswers" false))))
(DUse false (UseGroup ("types" "solver_contract") ((mem "ClassPredicate" true))))
(DUse false (UseGroup ("types" "registry") ((mem "HeadKey" true) (mem "headKeyTag" false) (mem "mregLookupK" false) (mem "regKeyNTab" false) (mem "regKeyOfTab" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Mono" true) (mem "normalize" false))))
(DUse false (UseGroup ("types" "evidence_complete") ((mem "Inner" true) (mem "innerNone" false) (mem "innerOfRoute" false) (mem "innerOr" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Require" true) (mem "Route" true) (mem "Super" true) (mem "Ty" true) (mem "isBoxed64Head" false) (mem "isFixedIntHead" false) (mem "isTaggedFixedHead" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("types" "evidence") ((mem "ScopeId" true))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "anyList" false) (mem "contains" false) (mem "dedup" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isSome" false) (mem "listLen" false) (mem "lookupAssoc" false) (mem "isNonEmptyL" false))))
(DUse false (UseGroup ("types" "runtime_ops") ((mem "arithmeticTag" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "implRouteKeyWord" false))))
(DUse false (UseGroup ("types" "superclass") ((mem "lookupPos" false) (mem "mapAll" false) (mem "superIfaceRef" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false) (mem "take" false) (mem "zip" false))))
(DUse false (UseAlias ("map") "IdMap"))
(DTypeSig true "noteNumericPredicateTrace" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "NumericPredicateTraceStage") (TyFun (TyCon "ClassPredicate") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "Option") (TyCon "IfaceRef")) (TyFun (TyApp (TyCon "Option") (TyCon "Route")) (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyCon "Unit"))))))))))
(DFunDef false "noteNumericPredicateTrace" ((PVar "gctx") (PVar "stage") (PVar "predicate") (PVar "scope") (PVar "origin") (PVar "selected") (PVar "route") (PVar "prereqs")) (EMatch (EFieldAccess (EVar "gctx") "trace") (arm (PCon "Some" (PVar "sink")) () (EIf (EFieldAccess (EVar "sink") "tsNumericPredicateEnabled") (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "sink") "tsNumericPredicateEntries")) (EBinOp "::" (ERecordCreate "NumericPredicateTraceEntry" ((fa "nptStage" (EVar "stage")) (fa "nptPredicate" (EVar "predicate")) (fa "nptScope" (EVar "scope")) (fa "nptOrigin" (EVar "origin")) (fa "nptSelectedInterface" (EVar "selected")) (fa "nptRoute" (EVar "route")) (fa "nptPrerequisites" (EVar "prereqs")))) (EFieldAccess (EFieldAccess (EVar "sink") "tsNumericPredicateEntries") "value"))) (ELit LUnit))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig true "requiresNonShrinkingFuel" (TyCon "Int"))
(DFunDef false "requiresNonShrinkingFuel" () (ELit (LInt 32)))
(DTypeSig false "newWalkMemo" (TyFun (TyCon "Unit") (TyCon "WalkMemo")))
(DFunDef false "newWalkMemo" (PWild) (ERecordCreate "WalkMemo" ((fa "wmRoutes" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "wmDischarged" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "wmCuts" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "wmSolved" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "wmFollowed" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "wmStopped" (EApp (EVar "Ref") (EVar "False"))))))
(DTypeSig true "reqWalkSeed" (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "ReqWalk"))))
(DFunDef false "reqWalkSeed" ((PVar "iface") (PVar "args")) (EApp (EApp (EApp (EVar "ReqWalk") (EListLit (ETuple (EVar "iface") (EVar "args") (EApp (EVar "monoSizes") (EVar "args"))))) (EVar "requiresNonShrinkingFuel")) (EApp (EVar "newWalkMemo") (ELit LUnit))))
(DTypeSig true "reqWalkStart" (TyFun (TyCon "Unit") (TyCon "ReqWalk")))
(DFunDef false "reqWalkStart" (PWild) (EApp (EApp (EApp (EVar "ReqWalk") (EListLit)) (EVar "requiresNonShrinkingFuel")) (EApp (EVar "newWalkMemo") (ELit LUnit))))
(DTypeSig true "reqWalkEnter" (TyFun (TyCon "ReqWalk") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "ReqStep")))))
(DFunDef false "reqWalkEnter" ((PCon "ReqWalk" (PVar "path") (PVar "fuel") (PVar "memo")) (PVar "iface") (PVar "args")) (EBlock (DoLet false false (PVar "size") (EApp (EVar "monoSizes") (EVar "args"))) (DoExpr (EMatch (EVar "path") (arm (PList) () (EApp (EVar "ReqOn") (EApp (EApp (EApp (EVar "ReqWalk") (EListLit (ETuple (EVar "iface") (EVar "args") (EVar "size")))) (EVar "fuel")) (EVar "memo")))) (arm (PCons (PTuple (PVar "parentIface") (PVar "parentArgs") (PVar "parentSize")) PWild) () (EIf (EApp (EApp (EVar "anyListM") (EApp (EApp (EApp (EVar "sameWalkGoal") (EVar "iface")) (EVar "args")) (EVar "size"))) (EVar "path")) (EApp (EApp (EApp (EApp (EVar "ReqCycle") (EVar "parentIface")) (EVar "parentArgs")) (EVar "iface")) (EVar "args")) (EIf (EBinOp "<" (EVar "size") (EVar "parentSize")) (EApp (EVar "ReqOn") (EApp (EApp (EApp (EVar "ReqWalk") (EBinOp "::" (ETuple (EVar "iface") (EVar "args") (EVar "size")) (EVar "path"))) (EVar "fuel")) (EVar "memo"))) (EIf (EBinOp "<=" (EVar "fuel") (ELit (LInt 0))) (EApp (EApp (EVar "ReqDeep") (EVar "iface")) (EVar "args")) (EApp (EVar "ReqOn") (EApp (EApp (EApp (EVar "ReqWalk") (EBinOp "::" (ETuple (EVar "iface") (EVar "args") (EVar "size")) (EVar "path"))) (EBinOp "-" (EVar "fuel") (ELit (LInt 1)))) (EVar "memo")))))))))))
(DTypeSig true "enteredGoalKey" (TyFun (TyCon "ReqWalk") (TyCon "String")))
(DFunDef false "enteredGoalKey" ((PCon "ReqWalk" (PCons (PTuple (PVar "iface") PWild (PVar "size")) PWild) (PVar "fuel") PWild)) (EBlock (DoLet false false (PVar "name") (EFieldAccess (EVar "iface") "irName")) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "#"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "size")))) (ELit (LString "#"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "fuel")))) (ELit (LString ""))))))
(DFunDef false "enteredGoalKey" ((PCon "ReqWalk" (PList) (PVar "fuel") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "#")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "fuel")))) (ELit (LString ""))))
(DTypeSig true "reqWalkMemo" (TyFun (TyCon "ReqWalk") (TyCon "WalkMemo")))
(DFunDef false "reqWalkMemo" ((PCon "ReqWalk" PWild PWild (PVar "memo"))) (EVar "memo"))
(DTypeSig false "routeWalkMemoized" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ImplRow") (TyFun (TyCon "ReqWalk") (TyFun (TyFun (TyCon "SiteCtx") (TyApp (TyCon "List") (TyCon "Route"))) (TyApp (TyCon "List") (TyCon "Route"))))))))))
(DFunDef false "routeWalkMemoized" ((PVar "sx") (PVar "encl") (PVar "useScope") (PVar "goals") (PVar "row") (PVar "walk") (PVar "follow")) (EBlock (DoLet false false (PVar "memo") (EApp (EVar "reqWalkMemo") (EVar "walk"))) (DoLet false false (PVar "iface") (EApp (EVar "ieRowIface") (EVar "row"))) (DoLet false false (PVar "key") (EApp (EVar "enteredGoalKey") (EVar "walk"))) (DoLet false false (PVar "entries") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EFieldAccess (EVar "memo") "wmRoutes") "value")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeWalkRecorded") (EVar "iface")) (EVar "goals")) (EVar "row")) (EVar "encl")) (EVar "useScope")) (EVar "entries")) (arm (PCon "Some" (PVar "entry")) () (EBlock (DoExpr (EApp (EApp (EVar "noteInner") (EVar "sx")) (EFieldAccess (EVar "entry") "rweInner"))) (DoExpr (EFieldAccess (EVar "entry") "rweRoutes")))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "cutsBefore") (EFieldAccess (EFieldAccess (EVar "memo") "wmCuts") "value")) (DoLet false false (PVar "acc") (EApp (EVar "Ref") (EVar "innerNone"))) (DoLet false false (PTuple (PVar "erred") (PVar "routes")) (EApp (EApp (EVar "erredDuring") (EFieldAccess (EVar "sx") "sxModule")) (ELam (PWild) (EApp (EVar "follow") (ERecordUpdate (EVar "sx") ((fa "sxInner" (EApp (EVar "Some") (EVar "acc"))))))))) (DoLet false false (PVar "inner") (EFieldAccess (EVar "acc") "value")) (DoExpr (EApp (EApp (EVar "noteInner") (EVar "sx")) (EVar "inner"))) (DoExpr (EIf (EBinOp "||" (EVar "erred") (EBinOp "/=" (EFieldAccess (EFieldAccess (EVar "memo") "wmCuts") "value") (EVar "cutsBefore"))) (ELit LUnit) (EBlock (DoLet false false (PVar "entry") (ERecordCreate "RouteWalkEntry" ((fa "rweIface" (EVar "iface")) (fa "rweGoals" (EVar "goals")) (fa "rweRow" (EVar "row")) (fa "rweEncl" (EVar "encl")) (fa "rweScope" (EVar "useScope")) (fa "rweRoutes" (EVar "routes")) (fa "rweInner" (EVar "inner"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "memo") "wmRoutes")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "::" (EVar "entry") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EFieldAccess (EVar "memo") "wmRoutes") "value"))))) (EFieldAccess (EFieldAccess (EVar "memo") "wmRoutes") "value"))))))) (DoExpr (EVar "routes"))))))))
(DTypeSig false "routeWalkRecorded" (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ImplRow") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyCon "RouteWalkEntry")) (TyApp (TyCon "Option") (TyCon "RouteWalkEntry")))))))))
(DFunDef false "routeWalkRecorded" (PWild PWild PWild PWild PWild (PList)) (EVar "None"))
(DFunDef false "routeWalkRecorded" ((PVar "iface") (PVar "goals") (PVar "row") (PVar "encl") (PVar "useScope") (PCons (PVar "entry") (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "entry") "rweEncl") (EVar "encl")) (EBinOp "==" (EFieldAccess (EVar "entry") "rweScope") (EVar "useScope"))) (EApp (EApp (EVar "sameIfaceDecl") (EFieldAccess (EVar "entry") "rweIface")) (EVar "iface"))) (EApp (EApp (EVar "monoVecSameGiven") (EFieldAccess (EVar "entry") "rweGoals")) (EVar "goals"))) (EBinOp "==" (EApp (EVar "rowRouteKey") (EFieldAccess (EVar "entry") "rweRow")) (EApp (EVar "rowRouteKey") (EVar "row")))) (EApp (EVar "Some") (EVar "entry")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeWalkRecorded") (EVar "iface")) (EVar "goals")) (EVar "row")) (EVar "encl")) (EVar "useScope")) (EVar "rest"))))
(DTypeSig false "noteInner" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "Inner") (TyCon "Unit"))))
(DFunDef false "noteInner" ((PVar "sx") (PVar "inner")) (EMatch (EFieldAccess (EVar "sx") "sxInner") (arm (PCon "Some" (PVar "acc")) () (EApp (EApp (EVar "setRef") (EVar "acc")) (EApp (EApp (EVar "innerOr") (EFieldAccess (EVar "acc") "value")) (EVar "inner")))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig false "noteInnerRoute" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "Route") (TyCon "Route"))))
(DFunDef false "noteInnerRoute" ((PVar "sx") (PVar "r")) (EBlock (DoExpr (EApp (EApp (EVar "noteInner") (EVar "sx")) (EApp (EVar "innerOfRoute") (EVar "r")))) (DoExpr (EVar "r"))))
(DTypeSig false "noteRouteWalkCut" (TyFun (TyCon "ReqWalk") (TyCon "Unit")))
(DFunDef false "noteRouteWalkCut" ((PVar "walk")) (EBlock (DoLet false false (PVar "memo") (EApp (EVar "reqWalkMemo") (EVar "walk"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "memo") "wmCuts")) (EBinOp "+" (EFieldAccess (EFieldAccess (EVar "memo") "wmCuts") "value") (ELit (LInt 1)))))))
(DTypeSig false "sameWalkGoal" (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "Int") (TyFun (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Int")) (TyCon "Bool"))))))
(DFunDef false "sameWalkGoal" ((PVar "iface") (PVar "args") (PVar "size") (PTuple (PVar "otherIface") (PVar "otherArgs") (PVar "otherSize"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "otherSize") (EVar "size")) (EApp (EApp (EVar "sameIfaceDecl") (EVar "otherIface")) (EVar "iface"))) (EApp (EApp (EVar "monoVecSameGiven") (EVar "otherArgs")) (EVar "args"))))
(DTypeSig false "ifaceParamMonos" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Mono")))))))
(DFunDef false "ifaceParamMonos" ((PVar "mctx") (PVar "name") (PVar "fullMono")) (EApp (EApp (EApp (EApp (EVar "occurrenceParamMonos") (EVar "mctx")) (EVar "name")) (EVar "fullMono")) (EListLit)))
(DTypeSig false "occurrenceParamMonos" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Mono"))))))))
(DFunDef false "occurrenceParamMonos" ((PVar "mctx") (PVar "name") (PVar "fullMono") (PVar "omitted")) (EMatch (EApp (EApp (EVar "methodEntryHere") (EVar "mctx")) (EVar "name")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple PWild (PVar "typarams") (PVar "mty") PWild)) () (EApp (EApp (EVar "map") (ELam ((PVar "subst")) (EApp (EApp (EVar "map") (EApp (EVar "paramMonoOf") (EBinOp "++" (EVar "subst") (EVar "omitted")))) (EVar "typarams")))) (EApp (EApp (EVar "matchTyMono") (EVar "mty")) (EVar "fullMono"))))))
(DTypeSig true "paramMonoOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "String") (TyCon "Mono"))))
(DFunDef false "paramMonoOf" ((PVar "subst") (PVar "tp")) (EApp (EApp (EVar "optionOr") (EApp (EVar "TRigid") (EVar "tp"))) (EApp (EApp (EVar "lookupAssoc") (EVar "tp")) (EVar "subst"))))
(DTypeSig false "goalPredOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "PredicateRequest"))))))
(DFunDef false "goalPredOf" ((PVar "mctx") (PVar "name") (PVar "fullMono")) (EApp (EApp (EApp (EApp (EVar "occurrencePredOf") (EVar "mctx")) (EVar "name")) (EVar "fullMono")) (EListLit)))
(DTypeSig false "occurrencePredOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyCon "PredicateRequest")))))))
(DFunDef false "occurrencePredOf" ((PVar "mctx") (PVar "name") (PVar "fullMono") (PVar "omitted")) (EBlock (DoLet false false (PVar "args") (EMatch (EApp (EApp (EApp (EApp (EVar "occurrenceParamMonos") (EVar "mctx")) (EVar "name")) (EVar "fullMono")) (EVar "omitted")) (arm (PCon "Some" (PVar "xs")) () (EApp (EVar "PSArgsKnown") (EVar "xs"))) (arm (PCon "None") () (EVar "PSArgsUnknown")))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "ifr")) (ERecordCreate "PredicateRequest" ((fa "prIface" (EVar "ifr")) (fa "prArgs" (EVar "args")))))) (EApp (EApp (EVar "methodIfaceHere") (EVar "mctx")) (EVar "name"))))))
(DTypeSig false "goalPredOfOp" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "PredicateRequest")))))
(DFunDef false "goalPredOfOp" ((PVar "mctx") (PVar "name")) (EApp (EApp (EVar "map") (ELam ((PVar "ifr")) (ERecordCreate "PredicateRequest" ((fa "prIface" (EVar "ifr")) (fa "prArgs" (EVar "PSArgsUnknown")))))) (EApp (EApp (EVar "methodIfaceHere") (EVar "mctx")) (EVar "name"))))
(DTypeSig false "binopPrimitiveHead" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "binopPrimitiveHead" ((PVar "h")) (EApp (EApp (EVar "contains") (EVar "h")) (EListLit (ELit (LString "Int")) (ELit (LString "Float")) (ELit (LString "String")) (ELit (LString "Bool")) (ELit (LString "Char")))))
(DTypeSig false "binopBuiltinHead" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "binopBuiltinHead" ((PLit (LString "append")) (PVar "tag")) (EBinOp "||" (EApp (EVar "binopPrimitiveHead") (EVar "tag")) (EBinOp "==" (EVar "tag") (ELit (LString "List")))))
(DFunDef false "binopBuiltinHead" ((PVar "method") (PVar "tag")) (EBinOp "||" (EApp (EVar "binopPrimitiveHead") (EVar "tag")) (EBinOp "&&" (EApp (EVar "isFixedIntHead") (EVar "tag")) (EApp (EVar "isCompareMethod") (EVar "method")))))
(DTypeSig false "opDictVarOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "PredicateRequest")) (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyApp (TyCon "Option") (TyCon "AssumAnswer")))))))))))
(DFunDef false "opDictVarOf" ((PVar "mctx") (PVar "request") (PCon "True") (PLit (LString "append")) (PVar "m") PWild (PVar "encl") (PVar "useScope")) (EApp (EApp (EVar "map") (EVar "LegacyScalar")) (EApp (EApp (EApp (EApp (EApp (EVar "enclDictVarOf") (EVar "mctx")) (EVar "request")) (EVar "m")) (EVar "encl")) (EVar "useScope"))))
(DFunDef false "opDictVarOf" ((PVar "mctx") (PVar "request") (PCon "True") PWild (PVar "m") (PVar "inImpl") (PVar "encl") (PVar "useScope")) (EIf (EVar "inImpl") (EApp (EApp (EVar "map") (EVar "LegacyScalar")) (EApp (EApp (EApp (EVar "activeDictVarOf") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "m")) (EVar "useScope"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "map") (EVar "LegacyScalar")) (EApp (EApp (EApp (EApp (EApp (EVar "enclDictVarOf") (EVar "mctx")) (EVar "request")) (EVar "m")) (EVar "encl")) (EVar "useScope"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "opDictVarOf" ((PVar "mctx") (PVar "request") (PCon "False") PWild (PVar "m") PWild (PVar "encl") (PVar "useScope")) (EApp (EApp (EVar "map") (EVar "LegacyScalar")) (EApp (EApp (EApp (EApp (EApp (EVar "enclDictVarOf") (EVar "mctx")) (EVar "request")) (EVar "m")) (EVar "encl")) (EVar "useScope"))))
(DTypeSig false "stampOpRouteVal" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyCon "Route")))))))))
(DFunDef false "stampOpRouteVal" ((PVar "sx") (PVar "isBinop") (PVar "encl") (PVar "useScope") (PVar "method") (PVar "operandMono") (PVar "tag")) (EBlock (DoLet false false (PVar "isBuiltin") (EIf (EVar "isBinop") (EApp (EApp (EVar "binopBuiltinHead") (EVar "method")) (EVar "tag")) (EApp (EVar "binopPrimitiveHead") (EVar "tag")))) (DoExpr (EIf (EVar "isBuiltin") (EIf (EBinOp "&&" (EBinOp "&&" (EVar "isBinop") (EBinOp "||" (EBinOp "==" (EVar "tag") (ELit (LString "Int"))) (EApp (EVar "isTaggedFixedHead") (EVar "tag")))) (EApp (EVar "isCompareMethod") (EVar "method"))) (EApp (EVar "RScalar") (ELit (LString "Int"))) (EIf (EBinOp "&&" (EBinOp "&&" (EVar "isBinop") (EBinOp "==" (EVar "tag") (ELit (LString "Char")))) (EApp (EVar "isCompareMethod") (EVar "method"))) (EApp (EVar "RScalar") (ELit (LString "Char"))) (EIf (EBinOp "&&" (EBinOp "&&" (EVar "isBinop") (EApp (EVar "isBoxed64Head") (EVar "tag"))) (EApp (EVar "isCompareMethod") (EVar "method"))) (EApp (EVar "RScalar") (EVar "tag")) (EVar "RNone")))) (EBlock (DoLet false false (PTuple (PVar "siteKey") (PVar "selected")) (EApp (EApp (EApp (EVar "keyForSite") (EVar "sx")) (EVar "method")) (EListLit (EVar "operandMono")))) (DoLet false false (PVar "dictMethod") (EIf (EVar "isBinop") (EIf (EApp (EApp (EApp (EVar "ieDefinesReqMethodAt") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "bodyImplEnvRef") "value")) (EVar "method")) (EApp (EVar "headTyconMono") (EVar "operandMono"))) (EVar "method") (EApp (EVar "innerDefaultMethod") (EVar "method"))) (EVar "method"))) (DoLet false false (PVar "reqs") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "argImplDictRoutesForEncl") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "dictMethod")) (EVar "tag")) (EVar "operandMono")) (EListLit (EVar "operandMono")))) (DoExpr (EMatch (EVar "siteKey") (arm (PCon "Some" (PVar "key")) () (EApp (EApp (EApp (EVar "RKey") (EVar "key")) (EVar "reqs")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "selectedCallSupers") (EVar "sx")) (EVar "method")) (EVar "selected")) (EVar "encl")) (EVar "useScope")) (EListLit (EVar "operandMono"))))) (arm (PCon "None") () (EVar "RNone")))))))))
(DTypeSig false "stampPredicateOpRouteVal" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyFun (TyCon "ClassPredicate") (TyCon "Route"))))))))
(DFunDef false "stampPredicateOpRouteVal" ((PVar "sx") (PVar "encl") (PVar "useScope") (PVar "method") (PVar "operandMono") (PVar "predicate")) (EMatch (EApp (EApp (EVar "predicateScalarRoute") (EVar "method")) (EVar "operandMono")) (arm (PCon "Some" (PVar "route")) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteNumericPredicateTrace") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "NPTArithmetic")) (EVar "predicate")) (EVar "useScope")) (EFieldAccess (EVar "sx") "sxSite")) (EVar "None")) (EApp (EVar "Some") (EVar "route"))) (EListLit))) (DoExpr (EVar "route")))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "env") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "bodyImplEnvRef") "value")) (DoLet false false (PVar "goals") (EFieldAccess (EVar "predicate") "predicateArguments")) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "ieSelectRowByIface") (EVar "sx")) (EVar "env")) (EFieldAccess (EVar "predicate") "predicateInterface")) (EVar "goals")) (arm (PCon "Some" (PAs "row" (PCon "ImplRow" PWild PWild (PVar "selectedIface") PWild PWild PWild PWild))) () (EBlock (DoLet false false (PVar "reqs") (EApp (EApp (EApp (EApp (EApp (EVar "implDictRoutesForRow") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "goals")) (EVar "row"))) (DoLet false false (PVar "key") (EApp (EVar "rowRouteKey") (EVar "row"))) (DoLet false false (PVar "route") (EApp (EApp (EApp (EVar "RKey") (EVar "key")) (EVar "reqs")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "selectedCallSupers") (EVar "sx")) (EVar "method")) (EApp (EVar "Some") (EVar "row"))) (EVar "encl")) (EVar "useScope")) (EVar "goals")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteNumericPredicateTrace") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "NPTArithmetic")) (EVar "predicate")) (EVar "useScope")) (EFieldAccess (EVar "sx") "sxSite")) (EApp (EVar "Some") (EVar "selectedIface"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "RKey") (EVar "key")) (EListLit)) (EListLit)))) (EVar "reqs"))) (DoExpr (EVar "route")))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "route") (EVar "RNone")) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteNumericPredicateTrace") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "NPTArithmetic")) (EVar "predicate")) (EVar "useScope")) (EFieldAccess (EVar "sx") "sxSite")) (EVar "None")) (EApp (EVar "Some") (EVar "route"))) (EListLit))) (DoExpr (EVar "route"))))))))))
(DTypeSig false "predicateScalarRoute" (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "Route")))))
(DFunDef false "predicateScalarRoute" ((PVar "method") (PVar "operandMono")) (EMatch (EApp (EVar "arithmeticTag") (EVar "operandMono")) (arm (PCon "Some" (PLit (LString "Int"))) () (EApp (EVar "Some") (EIf (EBinOp "==" (EVar "method") (ELit (LString "negate"))) (EVar "RNone") (EApp (EVar "RScalar") (ELit (LString "Int")))))) (arm (PCon "Some" (PLit (LString "Float"))) () (EApp (EVar "Some") (EApp (EVar "RScalar") (ELit (LString "Float"))))) (arm (PCon "Some" (PVar "scalar")) () (EIf (EBinOp "==" (EVar "method") (ELit (LString "negate"))) (EVar "None") (EApp (EVar "Some") (EApp (EVar "RScalar") (EVar "scalar"))))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "innerDefaultMethod" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "innerDefaultMethod" ((PVar "m")) (EIf (EApp (EApp (EVar "contains") (EVar "m")) (EListLit (ELit (LString "lt")) (ELit (LString "gt")) (ELit (LString "lte")) (ELit (LString "gte")) (ELit (LString "min")) (ELit (LString "max")))) (ELit (LString "compare")) (EVar "m")))
(DTypeSig false "isCompareMethod" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isCompareMethod" ((PVar "m")) (EApp (EApp (EVar "contains") (EVar "m")) (EListLit (ELit (LString "eq")) (ELit (LString "lt")) (ELit (LString "gt")) (ELit (LString "lte")) (ELit (LString "gte")))))
(DTypeSig false "keyForSite" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "ImplRow")))))))
(DFunDef false "keyForSite" ((PVar "sx") (PVar "name") (PVar "goals")) (EBlock (DoLet false false (PVar "env") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "bodyImplEnvRef") "value")) (DoLet false false (PVar "selected") (EApp (EApp (EApp (EApp (EVar "ieSelectRowByMethod") (EVar "sx")) (EVar "env")) (EVar "name")) (EVar "goals"))) (DoExpr (ETuple (EApp (EApp (EVar "map") (EVar "rowRouteKey")) (EVar "selected")) (EVar "selected")))))
(DTypeSig true "rowRouteKey" (TyFun (TyCon "ImplRow") (TyCon "String")))
(DFunDef false "rowRouteKey" ((PCon "ImplRow" PWild PWild (PVar "ir") (PVar "tys") PWild PWild PWild)) (EApp (EApp (EApp (EApp (EVar "implRouteKeyWord") (EFieldAccess (EVar "ir") "irOrigin")) (EFieldAccess (EVar "ir") "irName")) (EVar "tys")) (EVar "None")))
(DTypeSig true "goalHeadCon" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "HeadKey"))))
(DFunDef false "goalHeadCon" ((PCons (PVar "g") PWild)) (EApp (EVar "headTyconMono") (EVar "g")))
(DFunDef false "goalHeadCon" ((PList)) (EVar "None"))
(DTypeSig false "pickMostSpecificEntry" (TyFun (TyCon "SiteCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "KeyEntry")) (TyApp (TyCon "Option") (TyCon "KeyEntry"))))))
(DFunDef false "pickMostSpecificEntry" ((PVar "sx") PWild (PList)) (EVar "None"))
(DFunDef false "pickMostSpecificEntry" ((PVar "sx") (PVar "goals") (PCons (PVar "e") (PVar "rest"))) (EMatch (EApp (EApp (EVar "findMostSpecificEntry") (EBinOp "::" (EVar "e") (EVar "rest"))) (EBinOp "::" (EVar "e") (EVar "rest"))) (arm (PCon "Some" (PVar "best")) () (EApp (EVar "Some") (EVar "best"))) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EApp (EVar "reportAmbiguousOverlap") (EVar "sx")) (EVar "goals")) (EBinOp "::" (EVar "e") (EVar "rest")))) (DoExpr (EApp (EVar "Some") (EVar "e")))))))
(DTypeSig false "reportAmbiguousOverlap" (TyFun (TyCon "SiteCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "KeyEntry")) (TyCon "Unit")))))
(DFunDef false "reportAmbiguousOverlap" ((PVar "sx") (PVar "goals") (PVar "cands")) (EMatch (EApp (EVar "candsOneIface") (EVar "cands")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "iface")) () (EApp (EApp (EApp (EApp (EVar "reportOverlapForIface") (EVar "sx")) (EVar "iface")) (EVar "goals")) (EVar "cands")))))
(DTypeSig false "reportOverlapForIface" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "KeyEntry")) (TyCon "Unit"))))))
(DFunDef false "reportOverlapForIface" ((PVar "sx") (PVar "iface") (PVar "goals") (PVar "cands")) (EApp (EApp (EApp (EApp (EVar "pushAmbiguityAt") (EFieldAccess (EVar "sx") "sxModule")) (EVar "True")) (EFieldAccess (EVar "sx") "sxSite")) (EApp (EApp (EApp (EVar "ambiguousOverlapMsg") (EVar "iface")) (EVar "goals")) (EVar "cands"))))
(DTypeSig false "goalsClosed" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))
(DFunDef false "goalsClosed" ((PVar "mctx") (PVar "goals")) (EApp (EApp (EVar "allList") (ELam ((PVar "i")) (EApp (EApp (EVar "IdMap.has") (EVar "i")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "deferrableVarIds") "value")))) (EApp (EApp (EVar "flatMap") (EVar "monoUnboundIds")) (EVar "goals"))))
(DTypeSig false "candsOneIface" (TyFun (TyApp (TyCon "List") (TyCon "KeyEntry")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "candsOneIface" ((PList)) (EVar "None"))
(DFunDef false "candsOneIface" ((PCons (PCon "KeyEntry" PWild PWild PWild PWild (PVar "ifn") PWild PWild PWild) (PVar "rest"))) (EIf (EApp (EApp (EVar "allList") (ELam ((PVar "e")) (EBinOp "==" (EApp (EVar "keyEntryIface") (EVar "e")) (EVar "ifn")))) (EVar "rest")) (EApp (EVar "Some") (EVar "ifn")) (EVar "None")))
(DTypeSig false "findMostSpecificEntry" (TyFun (TyApp (TyCon "List") (TyCon "KeyEntry")) (TyFun (TyApp (TyCon "List") (TyCon "KeyEntry")) (TyApp (TyCon "Option") (TyCon "KeyEntry")))))
(DFunDef false "findMostSpecificEntry" ((PList) PWild) (EVar "None"))
(DFunDef false "findMostSpecificEntry" ((PCons (PVar "c") (PVar "cs")) (PVar "all")) (EIf (EApp (EApp (EVar "entryCoversAllOthers") (EVar "c")) (EVar "all")) (EApp (EVar "Some") (EVar "c")) (EIf (EVar "otherwise") (EApp (EApp (EVar "findMostSpecificEntry") (EVar "cs")) (EVar "all")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "entryCoversAllOthers" (TyFun (TyCon "KeyEntry") (TyFun (TyApp (TyCon "List") (TyCon "KeyEntry")) (TyCon "Bool"))))
(DFunDef false "entryCoversAllOthers" ((PVar "cand") (PVar "all")) (EApp (EApp (EVar "allList") (EApp (EVar "entryCovers") (EVar "cand"))) (EVar "all")))
(DTypeSig false "entryCovers" (TyFun (TyCon "KeyEntry") (TyFun (TyCon "KeyEntry") (TyCon "Bool"))))
(DFunDef false "entryCovers" ((PCon "KeyEntry" PWild PWild PWild PWild PWild (PVar "candTys") PWild PWild) (PCon "KeyEntry" PWild PWild PWild PWild PWild (PVar "otherTys") PWild PWild)) (EBinOp "||" (EApp (EApp (EVar "tyHeadEqV") (EVar "candTys")) (EVar "otherTys")) (EApp (EApp (EVar "tyStrictlyMoreSpecificV") (EVar "candTys")) (EVar "otherTys"))))
(DTypeSig true "ieSelectRowByIface" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "ImplEnv") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "ImplRow")))))))
(DFunDef false "ieSelectRowByIface" ((PVar "sx") (PVar "env") (PVar "iface") (PVar "goals")) (EMatch (EApp (EVar "goalHeadCon") (EVar "goals")) (arm (PCon "Some" (PVar "hk")) () (EApp (EApp (EVar "ieRowOfEntry") (EVar "env")) (EApp (EApp (EApp (EVar "pickMostSpecificEntry") (EVar "sx")) (EVar "goals")) (EApp (EApp (EApp (EApp (EVar "ieCandidatesForIface") (EVar "env")) (EVar "hk")) (EVar "iface")) (EVar "goals"))))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "ieSelectRowByMethod" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "ImplEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "ImplRow")))))))
(DFunDef false "ieSelectRowByMethod" ((PVar "sx") (PVar "env") (PVar "name") (PVar "goals")) (EMatch (EApp (EVar "goalHeadCon") (EVar "goals")) (arm (PCon "Some" (PVar "hk")) () (EApp (EApp (EVar "ieRowOfEntry") (EVar "env")) (EApp (EApp (EApp (EVar "pickMostSpecificEntry") (EVar "sx")) (EVar "goals")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ieCandidatesForMethod") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "env")) (EVar "hk")) (EApp (EApp (EVar "originMethodName") (EFieldAccess (EVar "sx") "sxModule")) (EVar "name"))) (EApp (EApp (EVar "methodAdmissionHere") (EFieldAccess (EVar "sx") "sxModule")) (EVar "name"))) (EVar "goals"))))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig true "selectedRowReqMatch" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ImplRow") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "Require"))))))))
(DFunDef false "selectedRowReqMatch" ((PVar "mctx") (PVar "goals") (PCon "ImplRow" PWild PWild PWild (PVar "itys") (PVar "reqs") PWild PWild)) (EApp (EApp (EVar "map") (ELam ((PVar "subst")) (ETuple (EVar "subst") (EVar "reqs")))) (EApp (EApp (EApp (EVar "implHeadSubst") (EVar "mctx")) (EVar "itys")) (EVar "goals"))))
(DTypeSig true "implDictRoutesForRow" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ImplRow") (TyApp (TyCon "List") (TyCon "Route"))))))))
(DFunDef false "implDictRoutesForRow" ((PVar "sx") (PVar "encl") (PVar "useScope") (PVar "goals") (PVar "row")) (EMatch (EApp (EApp (EApp (EVar "selectedRowReqMatch") (EFieldAccess (EVar "sx") "sxModule")) (EVar "goals")) (EVar "row")) (arm (PCon "Some" (PTuple (PVar "subst") (PVar "reqs"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "argImplReqRoutes") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "subst")) (EVar "reqs")) (EApp (EApp (EVar "reqWalkSeed") (EApp (EVar "ieRowIface") (EVar "row"))) (EVar "goals")))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "legacyReturnReqRoutesForRow" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "Mono") (TyFun (TyCon "ImplRow") (TyApp (TyCon "List") (TyCon "Route"))))))))
(DFunDef false "legacyReturnReqRoutesForRow" ((PVar "sx") (PVar "encl") (PVar "useScope") (PVar "resultMono") (PVar "row")) (EMatch (EApp (EVar "ieRowHeadTriple") (EApp (EVar "Some") (EVar "row"))) (arm (PCon "Some" (PTuple (PVar "headTy") (PVar "implTys") (PVar "reqs"))) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "headSubstWithParams") (EFieldAccess (EVar "sx") "sxModule")) (EVar "headTy")) (EVar "implTys")) (EVar "resultMono")) (EListLit (EVar "resultMono"))) (arm (PCon "Some" (PVar "subst")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "argImplReqRoutes") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "subst")) (EVar "reqs")) (EApp (EApp (EVar "reqWalkSeed") (EApp (EVar "ieRowIface") (EVar "row"))) (EListLit (EVar "resultMono"))))) (arm (PCon "None") () (EListLit)))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "headSubstWithParams" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))))))))
(DFunDef false "headSubstWithParams" ((PVar "mctx") (PVar "headTy") (PVar "implTys") (PVar "resultMono") (PVar "paramMonos")) (EApp (EApp (EVar "map") (ELam ((PVar "headSub")) (EApp (EApp (EApp (EApp (EVar "augmentWithParams") (EVar "mctx")) (EVar "headSub")) (EVar "implTys")) (EVar "paramMonos")))) (EApp (EApp (EVar "matchTyMono") (EVar "headTy")) (EVar "resultMono"))))
(DTypeSig false "augmentWithParams" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))))))
(DFunDef false "augmentWithParams" ((PVar "mctx") (PVar "headSub") (PVar "implTys") (PVar "paramMonos")) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "listLen") (EVar "implTys")) (EApp (EVar "listLen") (EVar "paramMonos"))) (EBinOp ">" (EApp (EVar "listLen") (EVar "paramMonos")) (ELit (LInt 1)))) (EMatch (EApp (EApp (EApp (EVar "implHeadSubst") (EVar "mctx")) (EVar "implTys")) (EVar "paramMonos")) (arm (PCon "Some" (PVar "full")) () (EApp (EApp (EVar "mergeSubstPreferConcrete") (EVar "headSub")) (EVar "full"))) (arm (PCon "None") () (EVar "headSub"))) (EIf (EVar "otherwise") (EVar "headSub") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "implHeadSubst" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))))))
(DFunDef false "implHeadSubst" ((PVar "mctx") (PVar "pats") (PVar "concretes")) (EIf (EBinOp "/=" (EApp (EVar "listLen") (EVar "pats")) (EApp (EVar "listLen") (EVar "concretes"))) (EVar "None") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "positionBindings") (EVar "pats")) (EVar "concretes")) (EListLit)) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "binds")) () (EIf (EApp (EApp (EVar "matchEqPairs") (EVar "mctx")) (EApp (EApp (EVar "repeatedBindings") (EVar "binds")) (EListLit))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "b")) (EApp (EApp (EApp (EVar "mergeOne") (EVar "acc")) (EApp (EVar "fst") (EVar "b"))) (EApp (EVar "snd") (EVar "b"))))) (EListLit)) (EVar "binds"))) (EVar "None")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "matchEqPairs" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Mono"))) (TyCon "Bool"))))
(DFunDef false "matchEqPairs" ((PVar "mctx") (PList)) (EVar "True"))
(DFunDef false "matchEqPairs" ((PVar "mctx") (PVar "pairs0")) (EBlock (DoLet false false (PVar "pairs") (EApp (EApp (EApp (EVar "rigidSigPairs") (EFieldAccess (EVar "mctx") "mcGraph")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "declaredSigVarIds") "value")) (EVar "pairs0"))) (DoLet false false (PVar "subst") (EApp (EVar "Ref") (EListLit))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "cohOverlapGo") (EVar "subst")) (EVar "pairs")) (EApp (EApp (EVar "allList") (ELam ((PVar "p")) (EApp (EApp (EApp (EVar "matchEqMono") (EVar "subst")) (EApp (EVar "fst") (EVar "p"))) (EApp (EVar "snd") (EVar "p"))))) (EVar "pairs"))))))
(DTypeSig true "positionBindings" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))))))
(DFunDef false "positionBindings" ((PList) (PList) (PVar "acc")) (EApp (EVar "Some") (EVar "acc")))
(DFunDef false "positionBindings" ((PCons (PVar "p") (PVar "ps")) (PCons (PVar "c") (PVar "cs")) (PVar "acc")) (EMatch (EApp (EApp (EVar "matchTyMono") (EVar "p")) (EVar "c")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "s")) () (EApp (EApp (EApp (EVar "positionBindings") (EVar "ps")) (EVar "cs")) (EBinOp "++" (EVar "acc") (EVar "s"))))))
(DFunDef false "positionBindings" (PWild PWild PWild) (EVar "None"))
(DTypeSig true "repeatedBindings" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Mono"))))))
(DFunDef false "repeatedBindings" ((PList) PWild) (EListLit))
(DFunDef false "repeatedBindings" ((PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest")) (PVar "seen")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "k")) (EVar "seen")) (arm (PCon "Some" (PVar "first")) () (EBinOp "::" (ETuple (EVar "first") (EVar "v")) (EApp (EApp (EVar "repeatedBindings") (EVar "rest")) (EVar "seen")))) (arm (PCon "None") () (EApp (EApp (EVar "repeatedBindings") (EVar "rest")) (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EVar "seen"))))))
(DTypeSig true "entail" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "EntailKind") (TyTuple (TyCon "Route") (TyApp (TyCon "List") (TyCon "Route"))))))))))
(DFunDef false "entail" ((PVar "sx") (PVar "name") (PVar "m") (PVar "encl") (PVar "useScope") (PVar "kind")) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "entailAssum") (EFieldAccess (EVar "sx") "sxModule")) (EVar "m")) (EVar "encl")) (EVar "name")) (EVar "useScope")) (EVar "kind")) (arm (PCon "Some" (PVar "answer")) () (EBlock (DoExpr (EApp (EApp (EApp (EVar "noteAssumption") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "useScope")) (EVar "answer"))) (DoLet false false (PVar "result") (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "assumAnswerRoute") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "answer")) (EApp (EApp (EApp (EVar "goalIfaceOfKind") (EFieldAccess (EVar "sx") "sxModule")) (EVar "name")) (EVar "kind"))) (EVar "useScope")) (ELam ((PVar "dname")) (EApp (EApp (EVar "entailAssumRoute") (EVar "dname")) (EVar "kind")))) (EListLit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteNumericEntailment") (EVar "sx")) (EVar "kind")) (EVar "useScope")) (EVar "None")) (EApp (EVar "fst") (EVar "result"))) (EApp (EVar "snd") (EVar "result")))) (DoExpr (EVar "result")))) (arm (PCon "None") () (EMatch (EApp (EVar "headTyconMono") (EVar "m")) (arm (PCon "Some" (PVar "hk")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "entailInst") (EVar "sx")) (EVar "name")) (EVar "m")) (EVar "encl")) (EVar "useScope")) (EApp (EVar "headKeyTag") (EVar "hk"))) (EVar "kind"))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "entailRigidLead") (EVar "sx")) (EVar "m")) (EVar "encl")) (EVar "useScope")) (EVar "kind")) (arm (PCon "Some" (PVar "result")) () (EVar "result")) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "entailDetermined") (EVar "sx")) (EVar "name")) (EVar "encl")) (EVar "useScope")) (EVar "kind")) (arm (PCon "Some" (PVar "result")) () (EVar "result")) (arm (PCon "None") () (EBlock (DoLet false false (PVar "result") (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "entailFallback") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "m")) (EVar "kind")) (EListLit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteNumericEntailment") (EVar "sx")) (EVar "kind")) (EVar "useScope")) (EVar "None")) (EApp (EVar "fst") (EVar "result"))) (EApp (EVar "snd") (EVar "result")))) (DoExpr (EVar "result"))))))))))))
(DTypeSig false "entailDetermined" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "EntailKind") (TyApp (TyCon "Option") (TyTuple (TyCon "Route") (TyApp (TyCon "List") (TyCon "Route"))))))))))
(DFunDef false "entailDetermined" ((PVar "sx") (PVar "name") (PVar "encl") (PVar "useScope") (PCon "EKArg" (PVar "fullMono") (PVar "omitted"))) (EMatch (ETuple (EApp (EApp (EApp (EApp (EVar "occurrenceParamMonos") (EFieldAccess (EVar "sx") "sxModule")) (EVar "name")) (EVar "fullMono")) (EVar "omitted")) (EApp (EApp (EVar "methodIfaceHere") (EFieldAccess (EVar "sx") "sxModule")) (EVar "name"))) (arm (PTuple (PCon "Some" (PVar "goals")) (PCon "Some" (PVar "iface"))) () (EApp (EApp (EVar "map") (ELam ((PVar "row")) (ETuple (EApp (EApp (EApp (EVar "RKey") (EApp (EVar "rowRouteKey") (EVar "row"))) (EListLit)) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "selectedCallSupers") (EVar "sx")) (EVar "name")) (EApp (EVar "Some") (EVar "row"))) (EVar "encl")) (EVar "useScope")) (EVar "goals"))) (EApp (EApp (EApp (EApp (EApp (EVar "implDictRoutesForRow") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "goals")) (EVar "row"))))) (EApp (EApp (EApp (EVar "determinedGoalInstance") (EFieldAccess (EVar "sx") "sxModule")) (EVar "iface")) (EVar "goals")))) (arm PWild () (EVar "None"))))
(DFunDef false "entailDetermined" ((PVar "sx") PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "entailRigidLead" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "EntailKind") (TyApp (TyCon "Option") (TyTuple (TyCon "Route") (TyApp (TyCon "List") (TyCon "Route"))))))))))
(DFunDef false "entailRigidLead" ((PVar "sx") (PVar "m") (PVar "encl") (PVar "useScope") (PCon "EKNestedTop" (PVar "iface") PWild (PVar "walk") (PVar "rest"))) (EBlock (DoLet false false (PVar "goals") (EBinOp "::" (EVar "m") (EVar "rest"))) (DoLet false false (PVar "ids") (EApp (EApp (EVar "flatMap") (EVar "monoUnboundIds")) (EVar "goals"))) (DoLet false false (PVar "declared") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "declaredSigVarIds") "value")) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "ids")) (EApp (EApp (EVar "anyList") (ELam ((PVar "i")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EApp (EVar "intToString") (EVar "i"))) (EVar "declared"))))) (EVar "ids"))) (EApp (EApp (EVar "allList") (EVar "isBareTyvarMono")) (EVar "goals"))) (EVar "None") (EBlock (DoLet false false (PVar "env") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "bodyImplEnvRef") "value")) (DoLet false false (PVar "picked") (EApp (EApp (EApp (EVar "pickMostSpecificEntry") (EVar "sx")) (EVar "goals")) (EApp (EApp (EApp (EVar "ieEntriesForIface") (EApp (EApp (EVar "ieHeadRows") (EVar "None")) (EVar "env"))) (EVar "iface")) (EVar "goals")))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "row")) (ETuple (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "nestedRowRoute") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "m")) (EVar "goals")) (EVar "walk")) (EVar "row")) (EListLit)))) (EApp (EApp (EVar "ieRowOfEntry") (EVar "env")) (EVar "picked")))))))))
(DFunDef false "entailRigidLead" ((PVar "sx") PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "noteNumericEntailment" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "EntailKind") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "Option") (TyCon "IfaceRef")) (TyFun (TyCon "Route") (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyCon "Unit"))))))))
(DFunDef false "noteNumericEntailment" ((PVar "sx") (PCon "EKNumReturn" (PVar "predicate") PWild PWild (PVar "origin")) (PVar "scope") (PVar "selected") (PVar "route") (PVar "prereqs")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteNumericPredicateTrace") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "NPTReturn")) (EVar "predicate")) (EVar "scope")) (EVar "origin")) (EVar "selected")) (EApp (EVar "Some") (EVar "route"))) (EVar "prereqs")))
(DFunDef false "noteNumericEntailment" ((PVar "sx") (PCon "EKPredicateOp" PWild PWild (PVar "predicate")) (PVar "scope") (PVar "selected") (PVar "route") (PVar "prereqs")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteNumericPredicateTrace") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "NPTArithmetic")) (EVar "predicate")) (EVar "scope")) (EFieldAccess (EVar "sx") "sxSite")) (EVar "selected")) (EApp (EVar "Some") (EVar "route"))) (EVar "prereqs")))
(DFunDef false "noteNumericEntailment" ((PVar "sx") PWild PWild PWild PWild PWild) (ELit LUnit))
(DTypeSig false "entailAssum" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "EntailKind") (TyApp (TyCon "Option") (TyCon "AssumAnswer")))))))))
(DFunDef false "entailAssum" ((PVar "mctx") (PVar "m") (PVar "encl") (PVar "name") (PVar "useScope") (PVar "kind")) (EBlock (DoLet false false (PVar "request") (EApp (EApp (EApp (EVar "goalRequestOfKind") (EVar "mctx")) (EVar "name")) (EVar "kind"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "entailAssumVar") (EVar "mctx")) (EVar "request")) (EVar "m")) (EVar "encl")) (EVar "name")) (EVar "useScope")) (EVar "kind")) (arm (PCon "Some" (PVar "answer")) () (EApp (EVar "Some") (EVar "answer"))) (arm (PCon "None") () (EMatch (EVar "request") (arm (PCon "Some" (PVar "req")) () (EApp (EApp (EApp (EApp (EVar "activeDictPredOf") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "req")) (EVar "m")) (EVar "useScope"))) (arm (PCon "None") () (EVar "None"))))))))
(DTypeSig false "goalRequestOfKind" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "EntailKind") (TyApp (TyCon "Option") (TyCon "PredicateRequest"))))))
(DFunDef false "goalRequestOfKind" ((PVar "mctx") (PVar "name") (PCon "EKReturn" (PVar "fullMono") PWild)) (EApp (EApp (EApp (EVar "goalPredOf") (EVar "mctx")) (EVar "name")) (EVar "fullMono")))
(DFunDef false "goalRequestOfKind" ((PVar "mctx") PWild (PCon "EKNumReturn" (PVar "predicate") PWild PWild PWild)) (EApp (EVar "Some") (ERecordCreate "PredicateRequest" ((fa "prIface" (EFieldAccess (EVar "predicate") "predicateInterface")) (fa "prArgs" (EApp (EVar "PSArgsKnown") (EFieldAccess (EVar "predicate") "predicateArguments")))))))
(DFunDef false "goalRequestOfKind" ((PVar "mctx") (PVar "name") (PCon "EKArg" (PVar "fullMono") (PVar "omitted"))) (EApp (EApp (EApp (EApp (EVar "occurrencePredOf") (EVar "mctx")) (EVar "name")) (EVar "fullMono")) (EVar "omitted")))
(DFunDef false "goalRequestOfKind" ((PVar "mctx") (PVar "name") (PCon "EKOp" PWild PWild)) (EApp (EApp (EVar "goalPredOfOp") (EVar "mctx")) (EVar "name")))
(DFunDef false "goalRequestOfKind" ((PVar "mctx") PWild (PCon "EKPredicateOp" PWild PWild (PVar "predicate"))) (EApp (EVar "Some") (ERecordCreate "PredicateRequest" ((fa "prIface" (EFieldAccess (EVar "predicate") "predicateInterface")) (fa "prArgs" (EApp (EVar "PSArgsKnown") (EFieldAccess (EVar "predicate") "predicateArguments")))))))
(DFunDef false "goalRequestOfKind" ((PVar "mctx") PWild (PCon "EKNestedTop" PWild PWild PWild PWild)) (EVar "None"))
(DTypeSig false "entailAssumVar" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "PredicateRequest")) (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "EntailKind") (TyApp (TyCon "Option") (TyCon "AssumAnswer"))))))))))
(DFunDef false "entailAssumVar" ((PVar "mctx") (PVar "request") (PVar "m") (PVar "encl") PWild (PVar "useScope") (PCon "EKReturn" PWild PWild)) (EApp (EApp (EApp (EApp (EApp (EVar "activeDictVarOfEncl") (EVar "mctx")) (EVar "request")) (EVar "m")) (EVar "encl")) (EVar "useScope")))
(DFunDef false "entailAssumVar" ((PVar "mctx") (PVar "request") (PVar "m") (PVar "encl") PWild (PVar "useScope") (PCon "EKNumReturn" PWild PWild PWild PWild)) (EApp (EApp (EApp (EApp (EApp (EVar "activeDictVarOfEncl") (EVar "mctx")) (EVar "request")) (EVar "m")) (EVar "encl")) (EVar "useScope")))
(DFunDef false "entailAssumVar" ((PVar "mctx") PWild (PVar "m") (PVar "encl") PWild (PVar "useScope") (PCon "EKNestedTop" (PVar "iface") PWild PWild (PVar "rest"))) (EBlock (DoLet false false (PVar "request") (ERecordCreate "PredicateRequest" ((fa "prIface" (EVar "iface")) (fa "prArgs" (EApp (EVar "PSArgsKnown") (EBinOp "::" (EVar "m") (EVar "rest"))))))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "activeFunDictPredOf") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "request")) (EVar "useScope")) (arm (PCon "Some" (PVar "answer")) () (EApp (EVar "Some") (EVar "answer"))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EApp (EVar "activeFunDictPredOfResidual") (EFieldAccess (EVar "mctx") "mcGraph")) (EFieldAccess (EVar "iface") "irName")) (EBinOp "::" (EVar "m") (EVar "rest"))) (EVar "useScope")) (arm (PCon "Some" (PVar "answer")) () (EApp (EVar "Some") (EVar "answer"))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EApp (EVar "implReqDictVarOf") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EVar "Some") (EVar "request"))) (EVar "m")) (EVar "useScope")) (arm (PCon "Some" (PVar "answer")) () (EApp (EVar "Some") (EVar "answer"))) (arm (PCon "None") () (EApp (EApp (EVar "map") (EVar "LegacyScalar")) (EApp (EApp (EApp (EApp (EVar "activeDictVarAnswering") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "m")) (EVar "useScope")) (ELam ((PVar "b")) (EApp (EApp (EApp (EApp (EVar "scalarGivenAnswers") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "b")) (EVar "iface")) (EVar "useScope"))))))))))))))
(DFunDef false "entailAssumVar" ((PVar "mctx") (PVar "request") (PVar "m") (PVar "encl") PWild (PVar "useScope") (PCon "EKArg" PWild PWild)) (EApp (EApp (EApp (EApp (EApp (EVar "activeDictVarOfEncl") (EVar "mctx")) (EVar "request")) (EVar "m")) (EVar "encl")) (EVar "useScope")))
(DFunDef false "entailAssumVar" ((PVar "mctx") (PVar "request") (PVar "m") (PVar "encl") (PVar "name") (PVar "useScope") (PCon "EKOp" (PVar "isBinop") (PVar "inImpl"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "opDictVarOf") (EVar "mctx")) (EVar "request")) (EVar "isBinop")) (EVar "name")) (EVar "m")) (EVar "inImpl")) (EVar "encl")) (EVar "useScope")))
(DFunDef false "entailAssumVar" ((PVar "mctx") (PVar "request") (PVar "m") (PVar "encl") PWild (PVar "useScope") (PCon "EKPredicateOp" PWild PWild PWild)) (EApp (EApp (EApp (EApp (EApp (EVar "activeDictVarOfEncl") (EVar "mctx")) (EVar "request")) (EVar "m")) (EVar "encl")) (EVar "useScope")))
(DTypeSig false "goalIfaceOfKind" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "EntailKind") (TyApp (TyCon "Option") (TyCon "IfaceRef"))))))
(DFunDef false "goalIfaceOfKind" ((PVar "mctx") PWild (PCon "EKNestedTop" (PVar "iface") PWild PWild PWild)) (EIf (EBinOp "==" (EFieldAccess (EVar "iface") "irName") (ELit (LString ""))) (EVar "None") (EApp (EVar "Some") (EVar "iface"))))
(DFunDef false "goalIfaceOfKind" ((PVar "mctx") PWild (PCon "EKNumReturn" (PVar "predicate") PWild PWild PWild)) (EApp (EVar "Some") (EFieldAccess (EVar "predicate") "predicateInterface")))
(DFunDef false "goalIfaceOfKind" ((PVar "mctx") PWild (PCon "EKPredicateOp" PWild PWild (PVar "predicate"))) (EApp (EVar "Some") (EFieldAccess (EVar "predicate") "predicateInterface")))
(DFunDef false "goalIfaceOfKind" ((PVar "mctx") (PVar "name") PWild) (EApp (EApp (EVar "methodIfaceHere") (EVar "mctx")) (EVar "name")))
(DTypeSig false "entailAssumRoute" (TyFun (TyCon "String") (TyFun (TyCon "EntailKind") (TyCon "Route"))))
(DFunDef false "entailAssumRoute" ((PVar "dname") (PCon "EKReturn" PWild (PVar "isRp"))) (EIf (EVar "isRp") (EApp (EVar "RDictFwd") (EVar "dname")) (EApp (EVar "RDict") (EVar "dname"))))
(DFunDef false "entailAssumRoute" ((PVar "dname") (PCon "EKNumReturn" PWild PWild (PVar "isRp") PWild)) (EIf (EVar "isRp") (EApp (EVar "RDictFwd") (EVar "dname")) (EApp (EVar "RDict") (EVar "dname"))))
(DFunDef false "entailAssumRoute" ((PVar "dname") (PCon "EKNestedTop" PWild PWild PWild PWild)) (EApp (EVar "RDict") (EVar "dname")))
(DFunDef false "entailAssumRoute" ((PVar "dname") (PCon "EKArg" PWild PWild)) (EApp (EVar "RDict") (EVar "dname")))
(DFunDef false "entailAssumRoute" ((PVar "dname") (PCon "EKOp" PWild PWild)) (EApp (EVar "RDict") (EVar "dname")))
(DFunDef false "entailAssumRoute" ((PVar "dname") (PCon "EKPredicateOp" PWild PWild PWild)) (EApp (EVar "RDict") (EVar "dname")))
(DTypeSig false "selectReturnRow" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "ImplEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "ImplRow")))))))
(DFunDef false "selectReturnRow" ((PVar "sx") (PVar "env") (PVar "name") (PVar "goals")) (EMatch (EApp (EApp (EApp (EApp (EVar "ieSelectRowByMethod") (EVar "sx")) (EVar "env")) (EVar "name")) (EVar "goals")) (arm (PCon "Some" (PVar "row")) () (EApp (EVar "Some") (EVar "row"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "methodIfaceHere") (EFieldAccess (EVar "sx") "sxModule")) (EVar "name")) (arm (PCon "Some" (PVar "iface")) () (EApp (EApp (EApp (EVar "determinedGoalInstance") (EFieldAccess (EVar "sx") "sxModule")) (EVar "iface")) (EVar "goals"))) (arm (PCon "None") () (EVar "None"))))))
(DTypeSig true "determinedGoalInstance" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "ImplRow"))))))
(DFunDef false "determinedGoalInstance" ((PVar "mctx") PWild (PList)) (EVar "None"))
(DFunDef false "determinedGoalInstance" ((PVar "mctx") (PVar "iface") (PCons (PVar "first") (PVar "rest"))) (EMatch (EApp (EVar "normalize") (EVar "first")) (arm (PCon "TVar" (PVar "cell")) () (EBlock (DoLet false false (PVar "goals") (EBinOp "::" (EVar "first") (EVar "rest"))) (DoLet false false (PVar "filed") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "IdMap.get") (EApp (EVar "tyvarId") (EVar "cell"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "determinedRowsRef") "value")))) (DoExpr (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "entry")) (EApp (EApp (EApp (EVar "determinedEntryAnswers") (EVar "iface")) (EVar "goals")) (EVar "entry")))) (EVar "filed")) (arm (PCons (PTuple (PVar "row") PWild) PWild) () (EApp (EVar "Some") (EVar "row"))) (arm (PList) () (EVar "None")))))) (arm PWild () (EVar "None"))))
(DTypeSig false "entailInst" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "String") (TyFun (TyCon "EntailKind") (TyTuple (TyCon "Route") (TyApp (TyCon "List") (TyCon "Route")))))))))))
(DFunDef false "entailInst" ((PVar "sx") (PVar "name") (PVar "m") (PVar "encl") (PVar "useScope") (PVar "tag") (PCon "EKReturn" (PVar "fullMono") PWild)) (EBlock (DoLet false false (PVar "env") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "bodyImplEnvRef") "value")) (DoExpr (EMatch (EApp (EApp (EApp (EVar "ifaceParamMonos") (EFieldAccess (EVar "sx") "sxModule")) (EVar "name")) (EVar "fullMono")) (arm (PCon "Some" (PVar "goals")) () (EMatch (EApp (EApp (EApp (EApp (EVar "selectReturnRow") (EVar "sx")) (EVar "env")) (EVar "name")) (EVar "goals")) (arm (PCon "Some" (PVar "row")) () (EBlock (DoLet false false (PVar "routeKey") (EApp (EVar "rowRouteKey") (EVar "row"))) (DoLet false false (PVar "routes") (EApp (EApp (EApp (EApp (EApp (EVar "implDictRoutesForRow") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "goals")) (EVar "row"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "RKey") (EVar "routeKey")) (EListLit)) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "selectedCallSupers") (EVar "sx")) (EVar "name")) (EApp (EVar "Some") (EVar "row"))) (EVar "encl")) (EVar "useScope")) (EVar "goals"))) (EVar "routes"))))) (arm (PCon "None") () (ETuple (EVar "RNone") (EListLit))))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EApp (EVar "ieSelectRowByMethod") (EVar "sx")) (EVar "env")) (EVar "name")) (EListLit (EVar "m"))) (arm (PCon "Some" (PVar "row")) () (EBlock (DoLet false false (PVar "routeKey") (EApp (EVar "rowRouteKey") (EVar "row"))) (DoLet false false (PVar "routes") (EApp (EApp (EApp (EApp (EApp (EVar "legacyReturnReqRoutesForRow") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "m")) (EVar "row"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "RKey") (EVar "routeKey")) (EListLit)) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "selectedCallSupers") (EVar "sx")) (EVar "name")) (EApp (EVar "Some") (EVar "row"))) (EVar "encl")) (EVar "useScope")) (EListLit (EVar "m")))) (EVar "routes"))))) (arm (PCon "None") () (ETuple (EVar "RNone") (EListLit)))))))))
(DFunDef false "entailInst" ((PVar "sx") (PVar "name") (PVar "m") (PVar "encl") (PVar "useScope") PWild (PAs "kind" (PCon "EKNumReturn" (PVar "predicate") PWild PWild PWild))) (EBlock (DoLet false false (PVar "goals") (EFieldAccess (EVar "predicate") "predicateArguments")) (DoLet false false (PVar "env") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "bodyImplEnvRef") "value")) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "ieSelectRowByIface") (EVar "sx")) (EVar "env")) (EFieldAccess (EVar "predicate") "predicateInterface")) (EVar "goals")) (arm (PCon "Some" (PAs "row" (PCon "ImplRow" PWild PWild (PVar "selectedIface") PWild PWild PWild PWild))) () (EBlock (DoLet false false (PVar "sups") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "selectedCallSupers") (EVar "sx")) (EVar "name")) (EApp (EVar "Some") (EVar "row"))) (EVar "encl")) (EVar "useScope")) (EVar "goals"))) (DoLet false false (PVar "route") (EApp (EApp (EApp (EVar "RKey") (EApp (EVar "rowRouteKey") (EVar "row"))) (EListLit)) (EVar "sups"))) (DoLet false false (PVar "routes") (EApp (EApp (EApp (EApp (EApp (EVar "implDictRoutesForRow") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "goals")) (EVar "row"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteNumericEntailment") (EVar "sx")) (EVar "kind")) (EVar "useScope")) (EApp (EVar "Some") (EVar "selectedIface"))) (EVar "route")) (EVar "routes"))) (DoExpr (ETuple (EVar "route") (EVar "routes"))))) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteNumericEntailment") (EVar "sx")) (EVar "kind")) (EVar "useScope")) (EVar "None")) (EVar "RNone")) (EListLit))) (DoExpr (ETuple (EVar "RNone") (EListLit)))))))))
(DFunDef false "entailInst" ((PVar "sx") PWild (PVar "m") (PVar "encl") (PVar "useScope") PWild (PCon "EKNestedTop" (PVar "iface") PWild (PVar "walk") (PVar "rest"))) (EBlock (DoLet false false (PVar "goals") (EBinOp "::" (EVar "m") (EVar "rest"))) (DoLet false false (PVar "env") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "bodyImplEnvRef") "value")) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "ieSelectRowByIface") (EVar "sx")) (EVar "env")) (EVar "iface")) (EVar "goals")) (arm (PCon "Some" (PVar "row")) () (ETuple (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "nestedRowRoute") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "m")) (EVar "goals")) (EVar "walk")) (EVar "row")) (EListLit))) (arm (PCon "None") () (ETuple (EVar "RNone") (EListLit)))))))
(DFunDef false "entailInst" ((PVar "sx") (PVar "name") (PVar "m") (PVar "encl") (PVar "useScope") (PVar "tag") (PCon "EKArg" (PVar "fullMono") (PVar "omitted"))) (EBlock (DoLet false false (PVar "goals") (EApp (EApp (EVar "optionOr") (EListLit (EVar "m"))) (EApp (EApp (EApp (EApp (EVar "occurrenceParamMonos") (EFieldAccess (EVar "sx") "sxModule")) (EVar "name")) (EVar "fullMono")) (EVar "omitted")))) (DoLet false false (PTuple (PVar "siteKey") (PVar "selected")) (EApp (EApp (EApp (EVar "keyForSite") (EVar "sx")) (EVar "name")) (EVar "goals"))) (DoLet false false (PVar "dictName") (EIf (EApp (EApp (EApp (EVar "ieDefinesReqMethodAt") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "bodyImplEnvRef") "value")) (EVar "name")) (EApp (EVar "headTyconMono") (EVar "m"))) (EVar "name") (EApp (EVar "innerDefaultMethod") (EVar "name")))) (DoLet false false (PVar "subject") (EMatch (EVar "goals") (arm (PCons (PVar "g") PWild) () (EVar "g")) (arm (PList) () (EVar "m")))) (DoLet false false (PVar "word") (EMatch (EVar "siteKey") (arm (PCon "Some" (PVar "routeKey")) () (EApp (EApp (EApp (EVar "RKey") (EVar "routeKey")) (EListLit)) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "selectedCallSupers") (EVar "sx")) (EVar "name")) (EVar "selected")) (EVar "encl")) (EVar "useScope")) (EVar "goals")))) (arm (PCon "None") () (EVar "RNone")))) (DoExpr (ETuple (EVar "word") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "argImplDictRoutesForEncl") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "dictName")) (EVar "tag")) (EVar "subject")) (EVar "goals"))))))
(DFunDef false "entailInst" ((PVar "sx") (PVar "name") (PVar "m") (PVar "encl") (PVar "useScope") (PVar "tag") (PCon "EKOp" (PVar "isBinop") PWild)) (ETuple (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "stampOpRouteVal") (EVar "sx")) (EVar "isBinop")) (EVar "encl")) (EVar "useScope")) (EVar "name")) (EVar "m")) (EVar "tag")) (EListLit)))
(DFunDef false "entailInst" ((PVar "sx") (PVar "name") (PVar "m") (PVar "encl") (PVar "useScope") PWild (PCon "EKPredicateOp" PWild PWild (PVar "predicate"))) (ETuple (EApp (EApp (EApp (EApp (EApp (EApp (EVar "stampPredicateOpRouteVal") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "name")) (EVar "m")) (EVar "predicate")) (EListLit)))
(DTypeSig true "superRoutesAt" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ReqWalk") (TyApp (TyCon "List") (TyCon "Route")))))))))
(DFunDef false "superRoutesAt" ((PVar "sx") (PVar "iface") (PVar "encl") (PVar "useScope") (PVar "goals") (PVar "walk")) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EVar "superRouteAt") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "walk"))) (EApp (EApp (EApp (EVar "directSuperGoals") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "iface")) (EVar "goals"))))
(DTypeSig false "superRouteAt" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "ReqWalk") (TyFun (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Mono")))) (TyCon "Route")))))))
(DFunDef false "superRouteAt" ((PVar "sx") (PVar "encl") (PVar "useScope") (PVar "walk") (PTuple (PVar "superIface") (PVar "superArgs"))) (EMatch (EVar "superArgs") (arm (PCon "Some" (PCons (PVar "g0") (PVar "gs"))) () (EApp (EApp (EVar "noteInnerRoute") (EVar "sx")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeOfD") (EVar "sx")) (EVar "superIface")) (EVar "encl")) (EVar "useScope")) (EVar "CommitSuper")) (EVar "g0")) (EVar "gs")) (EVar "walk")))) (arm PWild () (EApp (EApp (EVar "noteInnerRoute") (EVar "sx")) (EVar "RNone")))))
(DTypeSig false "nestedRowRoute" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ReqWalk") (TyFun (TyCon "ImplRow") (TyCon "Route")))))))))
(DFunDef false "nestedRowRoute" ((PVar "sx") (PVar "encl") (PVar "useScope") (PVar "m") (PVar "goals") (PVar "walk") (PAs "row" (PCon "ImplRow" PWild PWild (PVar "selectedIface") PWild PWild PWild PWild))) (EApp (EApp (EApp (EVar "RKey") (EApp (EVar "rowRouteKey") (EVar "row"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "argImplRequiresRoutesForRow") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "m")) (EVar "goals")) (EVar "walk")) (EVar "row"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "superRoutesAt") (EVar "sx")) (EVar "selectedIface")) (EVar "encl")) (EVar "useScope")) (EVar "goals")) (EVar "walk"))))
(DTypeSig false "committedSuperRoute" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "ReqWalk") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Route"))))))))
(DFunDef false "committedSuperRoute" ((PVar "sx") PWild PWild PWild PWild (PList)) (EVar "RNone"))
(DFunDef false "committedSuperRoute" ((PVar "sx") (PVar "encl") (PVar "useScope") (PVar "iface") (PVar "walk") (PAs "goals" (PCons (PVar "m") PWild))) (EMatch (EApp (EApp (EApp (EApp (EVar "stableGoalReach") (EFieldAccess (EVar "sx") "sxModule")) (EListLit)) (EVar "iface")) (EVar "goals")) (arm (PCon "ReachOne" (PVar "row")) ((GBool (EApp (EApp (EApp (EVar "rowHeadMatches") (EFieldAccess (EVar "sx") "sxModule")) (EVar "goals")) (EVar "row")))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "nestedRowRoute") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "m")) (EVar "goals")) (EVar "walk")) (EVar "row"))) (arm PWild () (EVar "RNone"))))
(DTypeSig true "selectedCallSupers" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "ImplRow")) (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "Route")))))))))
(DFunDef false "selectedCallSupers" ((PVar "sx") (PVar "name") (PCon "Some" (PCon "ImplRow" PWild PWild (PVar "iface") PWild PWild (PVar "supplied") PWild)) (PVar "encl") (PVar "useScope") (PVar "goals")) (EIf (EApp (EApp (EVar "contains") (EVar "name")) (EVar "supplied")) (EListLit) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "superRoutesAt") (EVar "sx")) (EVar "iface")) (EVar "encl")) (EVar "useScope")) (EVar "goals")) (EApp (EVar "reqWalkStart") (ELit LUnit)))))
(DFunDef false "selectedCallSupers" ((PVar "sx") PWild (PCon "None") PWild PWild PWild) (EListLit))
(DTypeSig false "entailFallback" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "Mono") (TyFun (TyCon "EntailKind") (TyCon "Route")))))))
(DFunDef false "entailFallback" ((PVar "sx") PWild PWild PWild (PCon "EKReturn" PWild PWild)) (EVar "RNone"))
(DFunDef false "entailFallback" ((PVar "sx") PWild PWild PWild (PCon "EKNumReturn" PWild PWild PWild PWild)) (EVar "RNone"))
(DFunDef false "entailFallback" ((PVar "sx") (PVar "encl") (PVar "scope") (PVar "m") (PCon "EKNestedTop" (PVar "iface") (PVar "policy") (PVar "walk") (PVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "undeterminedRoute") (EVar "sx")) (EVar "encl")) (EVar "scope")) (EVar "iface")) (EVar "policy")) (EVar "walk")) (EBinOp "::" (EVar "m") (EVar "rest"))))
(DFunDef false "entailFallback" ((PVar "sx") PWild PWild PWild (PCon "EKArg" PWild PWild)) (EVar "RNone"))
(DFunDef false "entailFallback" ((PVar "sx") PWild PWild PWild (PCon "EKOp" PWild PWild)) (EVar "RNone"))
(DFunDef false "entailFallback" ((PVar "sx") PWild PWild PWild (PCon "EKPredicateOp" PWild PWild PWild)) (EVar "RNone"))
(DTypeSig true "routeOfD" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "Undetermined") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ReqWalk") (TyCon "Route"))))))))))
(DFunDef false "routeOfD" ((PVar "sx") (PVar "iface") (PVar "encl") (PVar "useScope") (PVar "policy") (PVar "m") (PVar "rest") (PVar "walk")) (EApp (EVar "fst") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "entail") (EVar "sx")) (ELit (LString ""))) (EVar "m")) (EVar "encl")) (EVar "useScope")) (EApp (EApp (EApp (EApp (EVar "EKNestedTop") (EVar "iface")) (EVar "policy")) (EVar "walk")) (EVar "rest")))))
(DTypeSig false "undeterminedRoute" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "Undetermined") (TyFun (TyCon "ReqWalk") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Route")))))))))
(DFunDef false "undeterminedRoute" ((PVar "sx") PWild PWild PWild (PCon "KeepNone") PWild PWild) (EVar "RNone"))
(DFunDef false "undeterminedRoute" ((PVar "sx") PWild (PVar "scope") PWild (PCon "CountImpls" (PVar "iface")) PWild (PVar "goal")) (EApp (EApp (EApp (EApp (EVar "routeUndeterminedTop") (EVar "sx")) (EVar "scope")) (EVar "iface")) (EVar "goal")))
(DFunDef false "undeterminedRoute" ((PVar "sx") (PVar "encl") (PVar "scope") (PVar "iface") (PCon "CommitSuper") (PVar "walk") (PVar "goal")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "committedSuperRoute") (EVar "sx")) (EVar "encl")) (EVar "scope")) (EVar "iface")) (EVar "walk")) (EVar "goal")))
(DTypeSig false "routeUndeterminedTop" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "ScopeId") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Route"))))))
(DFunDef false "routeUndeterminedTop" ((PVar "sx") (PVar "scope") (PVar "ifaceRef") (PVar "goal")) (EIf (EBinOp "==" (EFieldAccess (EVar "ifaceRef") "irName") (ELit (LString ""))) (EVar "RNone") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "goalReach") (EFieldAccess (EVar "sx") "sxModule")) (EVar "goal")) (EApp (EApp (EApp (EApp (EVar "goalCandidates") (EFieldAccess (EVar "sx") "sxModule")) (EVar "omEmpty")) (EVar "goal")) (EApp (EApp (EApp (EVar "goalRows") (EFieldAccess (EVar "sx") "sxModule")) (EVar "ifaceRef")) (EVar "goal")))) (arm (PCon "ReachNone") () (EVar "RNone")) (arm (PCon "ReachOne" PWild) ((GBool (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "monoVectorClosed") (EVar "goal"))) (EApp (EApp (EVar "goalsClosed") (EFieldAccess (EVar "sx") "sxModule")) (EVar "goal"))))) (EVar "RNone")) (arm (PCon "ReachOne" (PVar "row")) () (EApp (EApp (EApp (EApp (EApp (EVar "undeterminedRowRoute") (EVar "sx")) (EVar "scope")) (EVar "ifaceRef")) (EVar "goal")) (EVar "row"))) (arm (PCon "ReachMany") () (EVar "RNone"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "undeterminedRowRoute" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "ScopeId") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ImplRow") (TyCon "Route")))))))
(DFunDef false "undeterminedRowRoute" ((PVar "sx") PWild PWild (PList) PWild) (EVar "RNone"))
(DFunDef false "undeterminedRowRoute" ((PVar "sx") (PVar "scope") (PVar "ifaceRef") (PCons (PVar "m") (PVar "rest")) (PVar "row")) (EApp (EApp (EApp (EVar "RKey") (EApp (EVar "rowRouteKey") (EVar "row"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "argImplRequiresRoutesForRow") (EVar "sx")) (ELit (LString ""))) (EVar "scope")) (EVar "m")) (EBinOp "::" (EVar "m") (EVar "rest"))) (EApp (EVar "reqWalkStart") (ELit LUnit))) (EVar "row"))) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "superIface") PWild)) (EApp (EApp (EVar "noteInnerRoute") (EVar "sx")) (EApp (EApp (EApp (EApp (EVar "routeUndeterminedTop") (EVar "sx")) (EVar "scope")) (EVar "superIface")) (EBinOp "::" (EVar "m") (EVar "rest")))))) (EApp (EApp (EApp (EVar "directSuperGoals") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "ifaceRef")) (EListLit)))))
(DTypeSig false "argImplRequiresRoutesForRow" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ReqWalk") (TyFun (TyCon "ImplRow") (TyApp (TyCon "List") (TyCon "Route"))))))))))
(DFunDef false "argImplRequiresRoutesForRow" ((PVar "sx") (PVar "encl") (PVar "useScope") (PVar "m") (PVar "goals") (PVar "walk") (PVar "row")) (EMatch (EApp (EApp (EApp (EVar "reqWalkEnter") (EVar "walk")) (EApp (EVar "ieRowIface") (EVar "row"))) (EVar "goals")) (arm (PCon "ReqOn" (PVar "next")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeWalkMemoized") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "goals")) (EVar "row")) (EVar "next")) (ELam ((PVar "walkSx")) (EMatch (EApp (EVar "ieRowHeadTriple") (EApp (EVar "Some") (EVar "row"))) (arm (PCon "Some" (PTuple (PVar "headTy") (PVar "itys") (PVar "reqs"))) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "headSubstWithParams") (EFieldAccess (EVar "sx") "sxModule")) (EVar "headTy")) (EVar "itys")) (EVar "m")) (EVar "goals")) (arm (PCon "Some" (PVar "subst")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "argImplReqRoutes") (EVar "walkSx")) (EVar "encl")) (EVar "useScope")) (EVar "subst")) (EVar "reqs")) (EVar "next"))) (arm (PCon "None") () (EListLit)))) (arm (PCon "None") () (EListLit)))))) (arm (PVar "cut") () (EBlock (DoExpr (EApp (EVar "noteRouteWalkCut") (EVar "walk"))) (DoExpr (EApp (EApp (EVar "requiresRouteWalkCut") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "cut")))))))
(DTypeSig false "requiresRouteWalkCut" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ReqStep") (TyApp (TyCon "List") (TyCon "Route")))))
(DFunDef false "requiresRouteWalkCut" ((PVar "gctx") PWild) (EIf (EApp (EApp (EVar "typeErrorsArmed") (EVar "gctx")) (ELit LUnit)) (EListLit) (EApp (EVar "panic") (ELit (LString "requires route walk reached a goal the solving walks did not accept")))))
(DTypeSig false "argImplDictRoutesForEncl" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "Route"))))))))))
(DFunDef false "argImplDictRoutesForEncl" ((PVar "sx") (PVar "encl") (PVar "useScope") (PVar "name") (PVar "_tag") (PVar "mono") (PVar "goals")) (EMatch (EApp (EVar "ieRowHeadTriple") (EApp (EApp (EApp (EApp (EVar "ieSelectRowByMethod") (EVar "sx")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "bodyImplEnvRef") "value")) (EVar "name")) (EVar "goals"))) (arm (PCon "Some" (PTuple (PVar "headTy") (PVar "implTys") (PVar "reqs"))) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "headSubstWithParams") (EFieldAccess (EVar "sx") "sxModule")) (EVar "headTy")) (EVar "implTys")) (EVar "mono")) (EVar "goals")) (arm (PCon "Some" (PVar "subst")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "argImplReqRoutes") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "subst")) (EVar "reqs")) (EApp (EVar "reqWalkStart") (ELit LUnit)))) (arm (PCon "None") () (EListLit)))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "argImplReqRoutes" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyFun (TyCon "ReqWalk") (TyApp (TyCon "List") (TyCon "Route")))))))))
(DFunDef false "argImplReqRoutes" ((PVar "sx") PWild PWild PWild (PList) PWild) (EListLit))
(DFunDef false "argImplReqRoutes" ((PVar "sx") (PVar "encl") (PVar "useScope") (PVar "subst") (PCons (PRec "Require" ((rf "requireHead" (PVar "rIface")) (rf "requireArgs" (PVar "rargs")) (rf "requireOrigin" (PVar "ro"))) false) (PVar "rest")) (PVar "walk")) (EBlock (DoLet false false (PVar "iface") (ERecordCreate "IfaceRef" ((fa "irName" (EVar "rIface")) (fa "irOrigin" (EVar "ro"))))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "argReqRoute") (EVar "sx")) (EVar "iface")) (EVar "encl")) (EVar "useScope")) (EVar "subst")) (EVar "rargs")) (EVar "walk")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "argImplReqRoutes") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "subst")) (EVar "rest")) (EVar "walk"))))))
(DTypeSig false "argReqRoute" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyCon "ReqWalk") (TyCon "Route")))))))))
(DFunDef false "argReqRoute" ((PVar "sx") PWild PWild PWild PWild (PList) PWild) (EApp (EApp (EVar "noteInnerRoute") (EVar "sx")) (EVar "RNone")))
(DFunDef false "argReqRoute" ((PVar "sx") (PVar "iface") (PVar "encl") (PVar "useScope") (PVar "subst") (PCons (PVar "arg") (PVar "more")) (PVar "walk")) (EApp (EApp (EVar "noteInnerRoute") (EVar "sx")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeOfD") (EVar "sx")) (EVar "iface")) (EVar "encl")) (EVar "useScope")) (EVar "KeepNone")) (EApp (EApp (EApp (EVar "fromAstType") (EFieldAccess (EVar "sx") "sxModule")) (EVar "subst")) (EVar "arg"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "fromAstType") (EFieldAccess (EVar "sx") "sxModule")) (EVar "subst"))) (EVar "more"))) (EVar "walk"))))
(DTypeSig true "directSuperGoals" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Mono")))))))))
(DFunDef false "directSuperGoals" ((PVar "gctx") (PVar "iface") (PVar "goals")) (EMatch (EApp (EApp (EVar "superLookup") (EVar "gctx")) (EVar "iface")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple (PVar "typarams") (PVar "supers"))) () (EApp (EApp (EVar "map") (ELam ((PVar "sup")) (ETuple (EApp (EVar "superIfaceRef") (EVar "sup")) (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "goals")) (EApp (EVar "listLen") (EVar "typarams"))) (EApp (EApp (EVar "mapAll") (ELam ((PVar "p")) (EApp (EApp (EApp (EVar "lookupPos") (EVar "p")) (EVar "typarams")) (EVar "goals")))) (EApp (EVar "superParamsOf") (EVar "sup"))) (EVar "None"))))) (EVar "supers")))))
(DTypeSig true "superParamsOf" (TyFun (TyCon "Super") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "superParamsOf" ((PRec "Super" ((rf "superParams" (PVar "params"))) true)) (EVar "params"))
(DTypeSig false "determinedEntryAnswers" (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyTuple (TyCon "ImplRow") (TyApp (TyCon "List") (TyCon "Mono"))) (TyCon "Bool")))))
(DFunDef false "determinedEntryAnswers" ((PVar "iface") (PVar "goals") (PTuple (PVar "row") (PVar "committed"))) (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "ieRowOfIface") (EVar "iface")) (EVar "row")) (EBinOp "==" (EApp (EVar "listLen") (EVar "committed")) (EApp (EVar "listLen") (EVar "goals")))) (EApp (EApp (EVar "allList") (ELam ((PVar "pair")) (EApp (EApp (EVar "cohEqMono") (EApp (EVar "fst") (EVar "pair"))) (EApp (EVar "snd") (EVar "pair"))))) (EApp (EApp (EVar "zip") (EVar "committed")) (EVar "goals")))))
(DTypeSig true "goalRows" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "ImplRow"))))))
(DFunDef false "goalRows" ((PVar "mctx") (PVar "iface") (PVar "args")) (EBlock (DoLet false false (PVar "env") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "bodyImplEnvRef") "value")) (DoLet false false (PVar "pool") (EMatch (EApp (EVar "goalHeadCon") (EVar "args")) (arm (PCon "Some" (PVar "hk")) () (EBinOp "++" (EApp (EApp (EVar "ieHeadRows") (EApp (EVar "Some") (EVar "hk"))) (EVar "env")) (EApp (EApp (EVar "ieHeadRows") (EVar "None")) (EVar "env")))) (arm (PCon "None") () (EApp (EVar "ieRowsAll") (EVar "env"))))) (DoExpr (EApp (EApp (EVar "filterList") (EApp (EVar "ieRowOfIface") (EVar "iface"))) (EVar "pool")))))
(DTypeSig true "goalIsProjection" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyCon "Bool"))))
(DFunDef false "goalIsProjection" ((PVar "args") (PVar "rows")) (EApp (EApp (EVar "anyList") (ELam ((PVar "row")) (EBinOp ">" (EApp (EVar "listLen") (EApp (EVar "ieRowTys") (EVar "row"))) (EApp (EVar "listLen") (EVar "args"))))) (EVar "rows")))
(DTypeSig true "goalCandidates" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyApp (TyCon "List") (TyTuple (TyCon "ImplRow") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))))))))))
(DFunDef false "goalCandidates" ((PVar "mctx") (PVar "rigidIds") (PVar "args") (PVar "rows")) (EBlock (DoLet false false (PVar "unifying") (EApp (EApp (EVar "flatMap") (ELam ((PVar "row")) (EMatch (EApp (EApp (EApp (EApp (EVar "rowPrefixSubstRigid") (EVar "mctx")) (EVar "rigidIds")) (EVar "args")) (EVar "row")) (arm (PCon "Some" (PVar "subst")) () (EListLit (ETuple (EVar "row") (EVar "subst")))) (arm (PCon "None") () (EListLit))))) (EVar "rows"))) (DoExpr (EIf (EApp (EApp (EVar "goalIsProjection") (EVar "args")) (EVar "rows")) (EApp (EApp (EApp (EVar "distinctPrefixes") (EApp (EVar "listLen") (EVar "args"))) (EVar "unifying")) (EListLit)) (EVar "unifying")))))
(DTypeSig false "rowPrefixSubstRigid" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ImplRow") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))))))))
(DFunDef false "rowPrefixSubstRigid" ((PVar "mctx") (PVar "rigidIds") (PVar "args") (PVar "row")) (EApp (EApp (EVar "map") (ELam ((PVar "scratch")) (EUnOp "!" (EVar "scratch")))) (EApp (EApp (EApp (EApp (EVar "headsUnifier") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "rigidIds")) (EVar "args")) (EApp (EApp (EVar "freshRowHeads") (EVar "mctx")) (EVar "row")))))
(DTypeSig false "distinctPrefixes" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "ImplRow") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "ImplRow") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))))) (TyApp (TyCon "List") (TyTuple (TyCon "ImplRow") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))))))))
(DFunDef false "distinctPrefixes" (PWild (PList) (PVar "kept")) (EApp (EVar "reverse") (EVar "kept")))
(DFunDef false "distinctPrefixes" ((PVar "k") (PCons (PVar "cand") (PVar "rest")) (PVar "kept")) (EBlock (DoLet false false (PVar "prefix") (EApp (EApp (EVar "take") (EVar "k")) (EApp (EVar "ieRowTys") (EApp (EVar "fst") (EVar "cand"))))) (DoExpr (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "seen")) (EApp (EApp (EVar "tyHeadEqV") (EVar "prefix")) (EApp (EApp (EVar "take") (EVar "k")) (EApp (EVar "ieRowTys") (EApp (EVar "fst") (EVar "seen"))))))) (EVar "kept")) (EApp (EApp (EApp (EVar "distinctPrefixes") (EVar "k")) (EVar "rest")) (EVar "kept")) (EApp (EApp (EApp (EVar "distinctPrefixes") (EVar "k")) (EVar "rest")) (EBinOp "::" (EVar "cand") (EVar "kept")))))))
(DTypeSig true "goalReach" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "ImplRow") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))))) (TyCon "GoalReach")))))
(DFunDef false "goalReach" ((PVar "mctx") PWild (PList)) (EVar "ReachNone"))
(DFunDef false "goalReach" ((PVar "mctx") PWild (PList (PTuple (PVar "row") PWild))) (EApp (EVar "ReachOne") (EVar "row")))
(DFunDef false "goalReach" ((PVar "mctx") (PVar "args") (PVar "cands")) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "cands"))) (DoExpr (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "row")) (EApp (EApp (EApp (EApp (EVar "stableMinimum") (EVar "mctx")) (EVar "args")) (EVar "rows")) (EVar "row")))) (EVar "rows")) (arm (PCons (PVar "row") PWild) () (EApp (EVar "ReachOne") (EVar "row"))) (arm (PList) () (EVar "ReachMany"))))))
(DTypeSig false "stableMinimum" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyCon "ImplRow") (TyCon "Bool"))))))
(DFunDef false "stableMinimum" ((PVar "mctx") (PVar "args") (PVar "rows") (PVar "row")) (EBinOp "&&" (EApp (EApp (EApp (EVar "rowHeadMatches") (EVar "mctx")) (EVar "args")) (EVar "row")) (EApp (EApp (EVar "allList") (ELam ((PVar "other")) (EApp (EApp (EVar "tySubsumesV") (EApp (EVar "ieRowTys") (EVar "other"))) (EApp (EVar "ieRowTys") (EVar "row"))))) (EVar "rows"))))
(DTypeSig true "rowCountsFor" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ImplRow") (TyCon "Bool"))))
(DFunDef false "rowCountsFor" ((PVar "args") (PVar "row")) (EMatch (EApp (EVar "ieRowTys") (EVar "row")) (arm (PCons (PVar "headTy") PWild) () (EBinOp "||" (EApp (EVar "not") (EApp (EVar "tyIsQualified") (EApp (EVar "headTySpineNode") (EVar "headTy")))) (EApp (EVar "goalFirstIsVariable") (EVar "args")))) (arm (PList) () (EVar "False"))))
(DTypeSig false "goalFirstIsVariable" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool")))
(DFunDef false "goalFirstIsVariable" ((PCons (PVar "a") PWild)) (EMatch (EApp (EVar "normalize") (EVar "a")) (arm (PCon "TVar" PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DFunDef false "goalFirstIsVariable" ((PList)) (EVar "False"))
(DTypeSig false "tyIsQualified" (TyFun (TyCon "Ty") (TyCon "Bool")))
(DFunDef false "tyIsQualified" ((PCon "TyEffect" PWild PWild PWild)) (EVar "True"))
(DFunDef false "tyIsQualified" ((PCon "TyConstrained" PWild PWild)) (EVar "True"))
(DFunDef false "tyIsQualified" ((PCon "TyQual" PWild PWild PWild)) (EVar "True"))
(DFunDef false "tyIsQualified" (PWild) (EVar "False"))
(DTypeSig true "freshRowHeads" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ImplRow") (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "freshRowHeads" ((PVar "mctx") (PVar "row")) (EApp (EVar "snd") (EApp (EApp (EVar "freshRowHeadsTvs") (EVar "mctx")) (EVar "row"))))
(DTypeSig true "freshRowHeadsTvs" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ImplRow") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "Mono"))))))
(DFunDef false "freshRowHeadsTvs" ((PVar "mctx") (PVar "row")) (EBlock (DoLet false false (PVar "tys") (EApp (EVar "ieRowTys") (EVar "row"))) (DoLet false false (PVar "tvs") (EApp (EApp (EVar "freshTvMap") (EVar "mctx")) (EApp (EVar "dedup") (EApp (EApp (EVar "flatMap") (EVar "tyVarNames")) (EVar "tys"))))) (DoExpr (ETuple (EVar "tvs") (EApp (EApp (EVar "map") (EApp (EApp (EVar "fromAstType") (EVar "mctx")) (EVar "tvs"))) (EVar "tys"))))))
(DTypeSig true "rowHeadMatches" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ImplRow") (TyCon "Bool")))))
(DFunDef false "rowHeadMatches" ((PVar "mctx") (PVar "args") (PVar "row")) (EApp (EVar "isSome") (EApp (EApp (EApp (EVar "implHeadSubst") (EVar "mctx")) (EApp (EVar "ieRowTys") (EVar "row"))) (EVar "args"))))
(DTypeSig true "stableGoalReach" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "GoalReach"))))))
(DFunDef false "stableGoalReach" ((PVar "mctx") (PVar "chosen") (PVar "iface") (PVar "args")) (EBlock (DoLet false false (PVar "declared") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "declaredSigVarIds") "value")) (DoLet false false (PVar "rigidIds") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (EVar "intToString")) (EApp (EApp (EVar "filterList") (ELam ((PVar "i")) (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "containsI") (EVar "i")) (EVar "chosen"))) (EApp (EApp (EVar "omHasKey") (EApp (EVar "intToString") (EVar "i"))) (EVar "declared"))))) (EApp (EVar "dedupI") (EApp (EApp (EVar "flatMap") (EVar "monoUnboundIds")) (EVar "args")))))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EApp (EVar "goalReach") (EVar "mctx")) (EVar "args")) (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EApp (EVar "rowCountsFor") (EVar "args")) (EApp (EVar "fst") (EVar "c"))))) (EApp (EApp (EApp (EApp (EVar "goalCandidates") (EVar "mctx")) (EVar "rigidIds")) (EVar "args")) (EApp (EApp (EApp (EVar "goalRows") (EVar "mctx")) (EVar "iface")) (EVar "args"))))))))
(DTypeSig true "implMatchesU" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ImplUniverse") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))))
(DFunDef false "implMatchesU" ((PVar "mctx") PWild PWild (PList)) (EVar "False"))
(DFunDef false "implMatchesU" ((PVar "mctx") (PVar "univ") (PVar "iface") (PCons (PVar "a0") (PVar "rest"))) (EBinOp "||" (EApp (EApp (EApp (EVar "bucketArgsMatch") (EVar "mctx")) (EApp (EApp (EApp (EVar "univConcreteBucket") (EVar "univ")) (EVar "iface")) (EApp (EVar "headTyconMono") (EVar "a0")))) (EBinOp "::" (EVar "a0") (EVar "rest"))) (EApp (EApp (EApp (EVar "bucketArgsMatch") (EVar "mctx")) (EApp (EApp (EVar "univHeadless") (EVar "univ")) (EVar "iface"))) (EBinOp "::" (EVar "a0") (EVar "rest")))))
(DTypeSig false "bucketArgsMatch" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require")))) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool")))))
(DFunDef false "bucketArgsMatch" ((PVar "mctx") (PList) PWild) (EVar "False"))
(DFunDef false "bucketArgsMatch" ((PVar "mctx") (PCons (PTuple (PVar "tys") PWild) (PVar "rest")) (PVar "args")) (EBinOp "||" (EApp (EApp (EApp (EVar "implHeadMatchesArgs") (EVar "mctx")) (EVar "tys")) (EVar "args")) (EApp (EApp (EApp (EVar "bucketArgsMatch") (EVar "mctx")) (EVar "rest")) (EVar "args"))))
(DTypeSig true "findMatchingImplReqsU" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "ImplUniverse") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "Require")))))))))
(DFunDef false "findMatchingImplReqsU" ((PVar "sx") (PVar "univ") (PVar "iface") (PList)) (EApp (EApp (EApp (EVar "firstReqMatch") (EFieldAccess (EVar "sx") "sxModule")) (EApp (EApp (EVar "univHeadless") (EVar "univ")) (EVar "iface"))) (EListLit)))
(DFunDef false "findMatchingImplReqsU" ((PVar "sx") (PVar "univ") (PVar "iface") (PCons (PVar "a0") (PVar "rest"))) (EMatch (EApp (EApp (EApp (EVar "concreteReqMatchByIface") (EVar "sx")) (EVar "iface")) (EBinOp "::" (EVar "a0") (EVar "rest"))) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "Some") (EVar "r"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "firstReqMatch") (EFieldAccess (EVar "sx") "sxModule")) (EApp (EApp (EVar "univHeadless") (EVar "univ")) (EVar "iface"))) (EBinOp "::" (EVar "a0") (EVar "rest"))))))
(DTypeSig false "concreteReqMatchByIface" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "Require"))))))))
(DFunDef false "concreteReqMatchByIface" ((PVar "sx") (PVar "iface") (PVar "args")) (EMatch (EApp (EApp (EApp (EApp (EVar "ieSelectRowByIface") (EVar "sx")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "bodyImplEnvRef") "value")) (EVar "iface")) (EVar "args")) (arm (PCon "Some" (PVar "row")) () (EApp (EApp (EApp (EVar "selectedRowReqMatch") (EFieldAccess (EVar "sx") "sxModule")) (EVar "args")) (EVar "row"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "firstReqMatch" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require")))) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "Require"))))))))
(DFunDef false "firstReqMatch" ((PVar "mctx") (PList) PWild) (EVar "None"))
(DFunDef false "firstReqMatch" ((PVar "mctx") (PCons (PTuple (PVar "tys") (PVar "reqs")) (PVar "rest")) (PVar "args")) (EMatch (EApp (EApp (EApp (EVar "implHeadSubst") (EVar "mctx")) (EVar "tys")) (EVar "args")) (arm (PCon "Some" (PVar "sub")) () (EApp (EVar "Some") (ETuple (EVar "sub") (EVar "reqs")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "firstReqMatch") (EVar "mctx")) (EVar "rest")) (EVar "args")))))
(DTypeSig true "univConcreteBucket" (TyFun (TyCon "ImplUniverse") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "Option") (TyCon "HeadKey")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require"))))))))
(DFunDef false "univConcreteBucket" ((PCon "ImplUniverse" (PVar "conc") PWild) (PVar "iface") (PCon "Some" (PVar "hk"))) (EApp (EApp (EVar "mregLookupK") (EApp (EVar "regKeyNTab") (EListLit (EApp (EVar "oblIfaceKey") (EVar "iface")) (EApp (EVar "dispHeadTab") (EVar "hk"))))) (EVar "conc")))
(DFunDef false "univConcreteBucket" (PWild PWild (PCon "None")) (EListLit))
(DTypeSig true "univHeadless" (TyFun (TyCon "ImplUniverse") (TyFun (TyCon "IfaceRef") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require")))))))
(DFunDef false "univHeadless" ((PCon "ImplUniverse" PWild (PVar "hl")) (PVar "iface")) (EApp (EApp (EVar "mregLookupK") (EApp (EVar "regKeyOfTab") (EApp (EVar "oblIfaceKey") (EVar "iface")))) (EVar "hl")))
(DTypeSig true "implMatchesWithReqsU" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ImplUniverse") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))))
(DFunDef false "implMatchesWithReqsU" ((PVar "mctx") PWild PWild (PList)) (EVar "False"))
(DFunDef false "implMatchesWithReqsU" ((PVar "mctx") (PVar "univ") (PVar "iface") (PCons (PVar "a0") (PVar "rest"))) (EBinOp "||" (EApp (EApp (EApp (EVar "bucketArgsMatchReqs") (EVar "mctx")) (EApp (EApp (EApp (EVar "univConcreteBucket") (EVar "univ")) (EVar "iface")) (EApp (EVar "headTyconMono") (EVar "a0")))) (EBinOp "::" (EVar "a0") (EVar "rest"))) (EApp (EApp (EApp (EVar "bucketArgsMatchReqs") (EVar "mctx")) (EApp (EApp (EVar "univHeadless") (EVar "univ")) (EVar "iface"))) (EBinOp "::" (EVar "a0") (EVar "rest")))))
(DTypeSig false "bucketArgsMatchReqs" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require")))) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool")))))
(DFunDef false "bucketArgsMatchReqs" ((PVar "mctx") (PList) PWild) (EVar "False"))
(DFunDef false "bucketArgsMatchReqs" ((PVar "mctx") (PCons (PTuple (PVar "tys") (PVar "reqs")) (PVar "rest")) (PVar "args")) (EBinOp "||" (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "reqs")) (EApp (EApp (EApp (EVar "implHeadMatchesArgs") (EVar "mctx")) (EVar "tys")) (EVar "args"))) (EApp (EApp (EApp (EVar "bucketArgsMatchReqs") (EVar "mctx")) (EVar "rest")) (EVar "args"))))
(DTypeSig false "implHeadMatchesArgs" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool")))))
(DFunDef false "implHeadMatchesArgs" ((PVar "mctx") (PVar "tys") (PVar "args")) (EApp (EVar "isSome") (EApp (EApp (EApp (EVar "implHeadSubst") (EVar "mctx")) (EVar "tys")) (EVar "args"))))
# MARK
(DUse false (UseGroup ("types" "tc_types") ((mem "PredicateSlotArgs" true) (mem "AssumAnswer" true) (mem "EntailKind" true) (mem "GoalReach" true) (mem "ImplUniverse" true) (mem "NumericPredicateTraceEntry" true) (mem "NumericPredicateTraceStage" true) (mem "PredicateRequest" true) (mem "ReqStep" true) (mem "RouteWalkEntry" true) (mem "SiteCtx" true) (mem "Undetermined" true) (mem "WalkMemo" true) (mem "GraphCtx" false) (mem "ImplEnv" false) (mem "ImplRow" false) (mem "KeyEntry" false) (mem "ModuleCtx" false) (mem "ReqWalk" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "anyListM" false) (mem "cohEqMono" false) (mem "cohOverlapGo" false) (mem "containsI" false) (mem "dedupI" false) (mem "headsUnifier" false) (mem "headTyconMono" false) (mem "headTySpineNode" false) (mem "isBareTyvarMono" false) (mem "matchEqMono" false) (mem "matchTyMono" false) (mem "mergeOne" false) (mem "mergeSubstPreferConcrete" false) (mem "monoSizes" false) (mem "monoUnboundIds" false) (mem "monoVecSameGiven" false) (mem "monoVectorClosed" false) (mem "rigidSigPairs" false) (mem "tyHeadEqV" false) (mem "tyStrictlyMoreSpecificV" false) (mem "tySubsumesV" false) (mem "tyvarId" false) (mem "tyVarNames" false))))
(DUse false (UseGroup ("types" "tc_diag_text") ((mem "ambiguousOverlapMsg" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "ieCandidatesForIface" false) (mem "ieCandidatesForMethod" false) (mem "ieDefinesReqMethodAt" false) (mem "ieEntriesForIface" false) (mem "ieHeadRows" false) (mem "ieRowHeadTriple" false) (mem "ieRowIface" false) (mem "ieRowOfEntry" false) (mem "ieRowOfIface" false) (mem "ieRowsAll" false) (mem "ieRowTys" false) (mem "keyEntryIface" false) (mem "originMethodName" false) (mem "sameIfaceDecl" false) (mem "superLookup" false) (mem "dispHeadTab" false) (mem "oblIfaceKey" false))))
(DUse false (UseGroup ("types" "tc_diag") ((mem "erredDuring" false) (mem "pushAmbiguityAt" false) (mem "typeErrorsArmed" false))))
(DUse false (UseGroup ("types" "tc_scope") ((mem "methodAdmissionHere" false) (mem "methodEntryHere" false) (mem "methodIfaceHere" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "freshTvMap" false))))
(DUse false (UseGroup ("types" "tc_decls_types") ((mem "fromAstType" false))))
(DUse false (UseGroup ("types" "tc_solve_givens") ((mem "activeDictPredOf" false) (mem "activeDictVarAnswering" false) (mem "activeDictVarOf" false) (mem "activeDictVarOfEncl" false) (mem "activeFunDictPredOf" false) (mem "activeFunDictPredOfResidual" false) (mem "assumAnswerRoute" false) (mem "enclDictVarOf" false) (mem "implReqDictVarOf" false) (mem "noteAssumption" false) (mem "scalarGivenAnswers" false))))
(DUse false (UseGroup ("types" "solver_contract") ((mem "ClassPredicate" true))))
(DUse false (UseGroup ("types" "registry") ((mem "HeadKey" true) (mem "headKeyTag" false) (mem "mregLookupK" false) (mem "regKeyNTab" false) (mem "regKeyOfTab" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Mono" true) (mem "normalize" false))))
(DUse false (UseGroup ("types" "evidence_complete") ((mem "Inner" true) (mem "innerNone" false) (mem "innerOfRoute" false) (mem "innerOr" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Require" true) (mem "Route" true) (mem "Super" true) (mem "Ty" true) (mem "isBoxed64Head" false) (mem "isFixedIntHead" false) (mem "isTaggedFixedHead" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("types" "evidence") ((mem "ScopeId" true))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "anyList" false) (mem "contains" false) (mem "dedup" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isSome" false) (mem "listLen" false) (mem "lookupAssoc" false) (mem "isNonEmptyL" false))))
(DUse false (UseGroup ("types" "runtime_ops") ((mem "arithmeticTag" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "implRouteKeyWord" false))))
(DUse false (UseGroup ("types" "superclass") ((mem "lookupPos" false) (mem "mapAll" false) (mem "superIfaceRef" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false) (mem "take" false) (mem "zip" false))))
(DUse false (UseAlias ("map") "IdMap"))
(DTypeSig true "noteNumericPredicateTrace" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "NumericPredicateTraceStage") (TyFun (TyCon "ClassPredicate") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "Option") (TyCon "IfaceRef")) (TyFun (TyApp (TyCon "Option") (TyCon "Route")) (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyCon "Unit"))))))))))
(DFunDef false "noteNumericPredicateTrace" ((PVar "gctx") (PVar "stage") (PVar "predicate") (PVar "scope") (PVar "origin") (PVar "selected") (PVar "route") (PVar "prereqs")) (EMatch (EFieldAccess (EVar "gctx") "trace") (arm (PCon "Some" (PVar "sink")) () (EIf (EFieldAccess (EVar "sink") "tsNumericPredicateEnabled") (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "sink") "tsNumericPredicateEntries")) (EBinOp "::" (ERecordCreate "NumericPredicateTraceEntry" ((fa "nptStage" (EVar "stage")) (fa "nptPredicate" (EVar "predicate")) (fa "nptScope" (EVar "scope")) (fa "nptOrigin" (EVar "origin")) (fa "nptSelectedInterface" (EVar "selected")) (fa "nptRoute" (EVar "route")) (fa "nptPrerequisites" (EVar "prereqs")))) (EFieldAccess (EFieldAccess (EVar "sink") "tsNumericPredicateEntries") "value"))) (ELit LUnit))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig true "requiresNonShrinkingFuel" (TyCon "Int"))
(DFunDef false "requiresNonShrinkingFuel" () (ELit (LInt 32)))
(DTypeSig false "newWalkMemo" (TyFun (TyCon "Unit") (TyCon "WalkMemo")))
(DFunDef false "newWalkMemo" (PWild) (ERecordCreate "WalkMemo" ((fa "wmRoutes" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "wmDischarged" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "wmCuts" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "wmSolved" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "wmFollowed" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "wmStopped" (EApp (EVar "Ref") (EVar "False"))))))
(DTypeSig true "reqWalkSeed" (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "ReqWalk"))))
(DFunDef false "reqWalkSeed" ((PVar "iface") (PVar "args")) (EApp (EApp (EApp (EVar "ReqWalk") (EListLit (ETuple (EVar "iface") (EVar "args") (EApp (EVar "monoSizes") (EVar "args"))))) (EVar "requiresNonShrinkingFuel")) (EApp (EVar "newWalkMemo") (ELit LUnit))))
(DTypeSig true "reqWalkStart" (TyFun (TyCon "Unit") (TyCon "ReqWalk")))
(DFunDef false "reqWalkStart" (PWild) (EApp (EApp (EApp (EVar "ReqWalk") (EListLit)) (EVar "requiresNonShrinkingFuel")) (EApp (EVar "newWalkMemo") (ELit LUnit))))
(DTypeSig true "reqWalkEnter" (TyFun (TyCon "ReqWalk") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "ReqStep")))))
(DFunDef false "reqWalkEnter" ((PCon "ReqWalk" (PVar "path") (PVar "fuel") (PVar "memo")) (PVar "iface") (PVar "args")) (EBlock (DoLet false false (PVar "size") (EApp (EVar "monoSizes") (EVar "args"))) (DoExpr (EMatch (EVar "path") (arm (PList) () (EApp (EVar "ReqOn") (EApp (EApp (EApp (EVar "ReqWalk") (EListLit (ETuple (EVar "iface") (EVar "args") (EVar "size")))) (EVar "fuel")) (EVar "memo")))) (arm (PCons (PTuple (PVar "parentIface") (PVar "parentArgs") (PVar "parentSize")) PWild) () (EIf (EApp (EApp (EVar "anyListM") (EApp (EApp (EApp (EVar "sameWalkGoal") (EVar "iface")) (EVar "args")) (EVar "size"))) (EVar "path")) (EApp (EApp (EApp (EApp (EVar "ReqCycle") (EVar "parentIface")) (EVar "parentArgs")) (EVar "iface")) (EVar "args")) (EIf (EBinOp "<" (EVar "size") (EVar "parentSize")) (EApp (EVar "ReqOn") (EApp (EApp (EApp (EVar "ReqWalk") (EBinOp "::" (ETuple (EVar "iface") (EVar "args") (EVar "size")) (EVar "path"))) (EVar "fuel")) (EVar "memo"))) (EIf (EBinOp "<=" (EVar "fuel") (ELit (LInt 0))) (EApp (EApp (EVar "ReqDeep") (EVar "iface")) (EVar "args")) (EApp (EVar "ReqOn") (EApp (EApp (EApp (EVar "ReqWalk") (EBinOp "::" (ETuple (EVar "iface") (EVar "args") (EVar "size")) (EVar "path"))) (EBinOp "-" (EVar "fuel") (ELit (LInt 1)))) (EVar "memo")))))))))))
(DTypeSig true "enteredGoalKey" (TyFun (TyCon "ReqWalk") (TyCon "String")))
(DFunDef false "enteredGoalKey" ((PCon "ReqWalk" (PCons (PTuple (PVar "iface") PWild (PVar "size")) PWild) (PVar "fuel") PWild)) (EBlock (DoLet false false (PVar "name") (EFieldAccess (EVar "iface") "irName")) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "size")))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "fuel")))) (ELit (LString ""))))))
(DFunDef false "enteredGoalKey" ((PCon "ReqWalk" (PList) (PVar "fuel") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "#")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "fuel")))) (ELit (LString ""))))
(DTypeSig true "reqWalkMemo" (TyFun (TyCon "ReqWalk") (TyCon "WalkMemo")))
(DFunDef false "reqWalkMemo" ((PCon "ReqWalk" PWild PWild (PVar "memo"))) (EVar "memo"))
(DTypeSig false "routeWalkMemoized" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ImplRow") (TyFun (TyCon "ReqWalk") (TyFun (TyFun (TyCon "SiteCtx") (TyApp (TyCon "List") (TyCon "Route"))) (TyApp (TyCon "List") (TyCon "Route"))))))))))
(DFunDef false "routeWalkMemoized" ((PVar "sx") (PVar "encl") (PVar "useScope") (PVar "goals") (PVar "row") (PVar "walk") (PVar "follow")) (EBlock (DoLet false false (PVar "memo") (EApp (EVar "reqWalkMemo") (EVar "walk"))) (DoLet false false (PVar "iface") (EApp (EVar "ieRowIface") (EVar "row"))) (DoLet false false (PVar "key") (EApp (EVar "enteredGoalKey") (EVar "walk"))) (DoLet false false (PVar "entries") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EFieldAccess (EVar "memo") "wmRoutes") "value")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeWalkRecorded") (EVar "iface")) (EVar "goals")) (EVar "row")) (EVar "encl")) (EVar "useScope")) (EVar "entries")) (arm (PCon "Some" (PVar "entry")) () (EBlock (DoExpr (EApp (EApp (EVar "noteInner") (EVar "sx")) (EFieldAccess (EVar "entry") "rweInner"))) (DoExpr (EFieldAccess (EVar "entry") "rweRoutes")))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "cutsBefore") (EFieldAccess (EFieldAccess (EVar "memo") "wmCuts") "value")) (DoLet false false (PVar "acc") (EApp (EVar "Ref") (EVar "innerNone"))) (DoLet false false (PTuple (PVar "erred") (PVar "routes")) (EApp (EApp (EVar "erredDuring") (EFieldAccess (EVar "sx") "sxModule")) (ELam (PWild) (EApp (EVar "follow") (ERecordUpdate (EVar "sx") ((fa "sxInner" (EApp (EVar "Some") (EVar "acc"))))))))) (DoLet false false (PVar "inner") (EFieldAccess (EVar "acc") "value")) (DoExpr (EApp (EApp (EVar "noteInner") (EVar "sx")) (EVar "inner"))) (DoExpr (EIf (EBinOp "||" (EVar "erred") (EBinOp "/=" (EFieldAccess (EFieldAccess (EVar "memo") "wmCuts") "value") (EVar "cutsBefore"))) (ELit LUnit) (EBlock (DoLet false false (PVar "entry") (ERecordCreate "RouteWalkEntry" ((fa "rweIface" (EVar "iface")) (fa "rweGoals" (EVar "goals")) (fa "rweRow" (EVar "row")) (fa "rweEncl" (EVar "encl")) (fa "rweScope" (EVar "useScope")) (fa "rweRoutes" (EVar "routes")) (fa "rweInner" (EVar "inner"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "memo") "wmRoutes")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "::" (EVar "entry") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EFieldAccess (EVar "memo") "wmRoutes") "value"))))) (EFieldAccess (EFieldAccess (EVar "memo") "wmRoutes") "value"))))))) (DoExpr (EVar "routes"))))))))
(DTypeSig false "routeWalkRecorded" (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ImplRow") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyCon "RouteWalkEntry")) (TyApp (TyCon "Option") (TyCon "RouteWalkEntry")))))))))
(DFunDef false "routeWalkRecorded" (PWild PWild PWild PWild PWild (PList)) (EVar "None"))
(DFunDef false "routeWalkRecorded" ((PVar "iface") (PVar "goals") (PVar "row") (PVar "encl") (PVar "useScope") (PCons (PVar "entry") (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "entry") "rweEncl") (EVar "encl")) (EBinOp "==" (EFieldAccess (EVar "entry") "rweScope") (EVar "useScope"))) (EApp (EApp (EVar "sameIfaceDecl") (EFieldAccess (EVar "entry") "rweIface")) (EVar "iface"))) (EApp (EApp (EVar "monoVecSameGiven") (EFieldAccess (EVar "entry") "rweGoals")) (EVar "goals"))) (EBinOp "==" (EApp (EVar "rowRouteKey") (EFieldAccess (EVar "entry") "rweRow")) (EApp (EVar "rowRouteKey") (EVar "row")))) (EApp (EVar "Some") (EVar "entry")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeWalkRecorded") (EVar "iface")) (EVar "goals")) (EVar "row")) (EVar "encl")) (EVar "useScope")) (EVar "rest"))))
(DTypeSig false "noteInner" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "Inner") (TyCon "Unit"))))
(DFunDef false "noteInner" ((PVar "sx") (PVar "inner")) (EMatch (EFieldAccess (EVar "sx") "sxInner") (arm (PCon "Some" (PVar "acc")) () (EApp (EApp (EVar "setRef") (EVar "acc")) (EApp (EApp (EVar "innerOr") (EFieldAccess (EVar "acc") "value")) (EVar "inner")))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig false "noteInnerRoute" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "Route") (TyCon "Route"))))
(DFunDef false "noteInnerRoute" ((PVar "sx") (PVar "r")) (EBlock (DoExpr (EApp (EApp (EVar "noteInner") (EVar "sx")) (EApp (EVar "innerOfRoute") (EVar "r")))) (DoExpr (EVar "r"))))
(DTypeSig false "noteRouteWalkCut" (TyFun (TyCon "ReqWalk") (TyCon "Unit")))
(DFunDef false "noteRouteWalkCut" ((PVar "walk")) (EBlock (DoLet false false (PVar "memo") (EApp (EVar "reqWalkMemo") (EVar "walk"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "memo") "wmCuts")) (EBinOp "+" (EFieldAccess (EFieldAccess (EVar "memo") "wmCuts") "value") (ELit (LInt 1)))))))
(DTypeSig false "sameWalkGoal" (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "Int") (TyFun (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Int")) (TyCon "Bool"))))))
(DFunDef false "sameWalkGoal" ((PVar "iface") (PVar "args") (PVar "size") (PTuple (PVar "otherIface") (PVar "otherArgs") (PVar "otherSize"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "otherSize") (EVar "size")) (EApp (EApp (EVar "sameIfaceDecl") (EVar "otherIface")) (EVar "iface"))) (EApp (EApp (EVar "monoVecSameGiven") (EVar "otherArgs")) (EVar "args"))))
(DTypeSig false "ifaceParamMonos" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Mono")))))))
(DFunDef false "ifaceParamMonos" ((PVar "mctx") (PVar "name") (PVar "fullMono")) (EApp (EApp (EApp (EApp (EVar "occurrenceParamMonos") (EVar "mctx")) (EVar "name")) (EVar "fullMono")) (EListLit)))
(DTypeSig false "occurrenceParamMonos" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Mono"))))))))
(DFunDef false "occurrenceParamMonos" ((PVar "mctx") (PVar "name") (PVar "fullMono") (PVar "omitted")) (EMatch (EApp (EApp (EVar "methodEntryHere") (EVar "mctx")) (EVar "name")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple PWild (PVar "typarams") (PVar "mty") PWild)) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "subst")) (EApp (EApp (EMethodRef "map") (EApp (EVar "paramMonoOf") (EBinOp "++" (EVar "subst") (EVar "omitted")))) (EVar "typarams")))) (EApp (EApp (EVar "matchTyMono") (EVar "mty")) (EVar "fullMono"))))))
(DTypeSig true "paramMonoOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "String") (TyCon "Mono"))))
(DFunDef false "paramMonoOf" ((PVar "subst") (PVar "tp")) (EApp (EApp (EVar "optionOr") (EApp (EVar "TRigid") (EVar "tp"))) (EApp (EApp (EVar "lookupAssoc") (EVar "tp")) (EVar "subst"))))
(DTypeSig false "goalPredOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "PredicateRequest"))))))
(DFunDef false "goalPredOf" ((PVar "mctx") (PVar "name") (PVar "fullMono")) (EApp (EApp (EApp (EApp (EVar "occurrencePredOf") (EVar "mctx")) (EVar "name")) (EVar "fullMono")) (EListLit)))
(DTypeSig false "occurrencePredOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyCon "PredicateRequest")))))))
(DFunDef false "occurrencePredOf" ((PVar "mctx") (PVar "name") (PVar "fullMono") (PVar "omitted")) (EBlock (DoLet false false (PVar "args") (EMatch (EApp (EApp (EApp (EApp (EVar "occurrenceParamMonos") (EVar "mctx")) (EVar "name")) (EVar "fullMono")) (EVar "omitted")) (arm (PCon "Some" (PVar "xs")) () (EApp (EVar "PSArgsKnown") (EVar "xs"))) (arm (PCon "None") () (EVar "PSArgsUnknown")))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "ifr")) (ERecordCreate "PredicateRequest" ((fa "prIface" (EVar "ifr")) (fa "prArgs" (EVar "args")))))) (EApp (EApp (EVar "methodIfaceHere") (EVar "mctx")) (EVar "name"))))))
(DTypeSig false "goalPredOfOp" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "PredicateRequest")))))
(DFunDef false "goalPredOfOp" ((PVar "mctx") (PVar "name")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "ifr")) (ERecordCreate "PredicateRequest" ((fa "prIface" (EVar "ifr")) (fa "prArgs" (EVar "PSArgsUnknown")))))) (EApp (EApp (EVar "methodIfaceHere") (EVar "mctx")) (EVar "name"))))
(DTypeSig false "binopPrimitiveHead" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "binopPrimitiveHead" ((PVar "h")) (EApp (EApp (EVar "contains") (EVar "h")) (EListLit (ELit (LString "Int")) (ELit (LString "Float")) (ELit (LString "String")) (ELit (LString "Bool")) (ELit (LString "Char")))))
(DTypeSig false "binopBuiltinHead" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "binopBuiltinHead" ((PLit (LString "append")) (PVar "tag")) (EBinOp "||" (EApp (EVar "binopPrimitiveHead") (EVar "tag")) (EBinOp "==" (EVar "tag") (ELit (LString "List")))))
(DFunDef false "binopBuiltinHead" ((PVar "method") (PVar "tag")) (EBinOp "||" (EApp (EVar "binopPrimitiveHead") (EVar "tag")) (EBinOp "&&" (EApp (EVar "isFixedIntHead") (EVar "tag")) (EApp (EVar "isCompareMethod") (EVar "method")))))
(DTypeSig false "opDictVarOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "PredicateRequest")) (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyApp (TyCon "Option") (TyCon "AssumAnswer")))))))))))
(DFunDef false "opDictVarOf" ((PVar "mctx") (PVar "request") (PCon "True") (PLit (LString "append")) (PVar "m") PWild (PVar "encl") (PVar "useScope")) (EApp (EApp (EMethodRef "map") (EVar "LegacyScalar")) (EApp (EApp (EApp (EApp (EApp (EVar "enclDictVarOf") (EVar "mctx")) (EVar "request")) (EVar "m")) (EVar "encl")) (EVar "useScope"))))
(DFunDef false "opDictVarOf" ((PVar "mctx") (PVar "request") (PCon "True") PWild (PVar "m") (PVar "inImpl") (PVar "encl") (PVar "useScope")) (EIf (EVar "inImpl") (EApp (EApp (EMethodRef "map") (EVar "LegacyScalar")) (EApp (EApp (EApp (EVar "activeDictVarOf") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "m")) (EVar "useScope"))) (EIf (EVar "otherwise") (EApp (EApp (EMethodRef "map") (EVar "LegacyScalar")) (EApp (EApp (EApp (EApp (EApp (EVar "enclDictVarOf") (EVar "mctx")) (EVar "request")) (EVar "m")) (EVar "encl")) (EVar "useScope"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "opDictVarOf" ((PVar "mctx") (PVar "request") (PCon "False") PWild (PVar "m") PWild (PVar "encl") (PVar "useScope")) (EApp (EApp (EMethodRef "map") (EVar "LegacyScalar")) (EApp (EApp (EApp (EApp (EApp (EVar "enclDictVarOf") (EVar "mctx")) (EVar "request")) (EVar "m")) (EVar "encl")) (EVar "useScope"))))
(DTypeSig false "stampOpRouteVal" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyCon "Route")))))))))
(DFunDef false "stampOpRouteVal" ((PVar "sx") (PVar "isBinop") (PVar "encl") (PVar "useScope") (PVar "method") (PVar "operandMono") (PVar "tag")) (EBlock (DoLet false false (PVar "isBuiltin") (EIf (EVar "isBinop") (EApp (EApp (EVar "binopBuiltinHead") (EVar "method")) (EVar "tag")) (EApp (EVar "binopPrimitiveHead") (EVar "tag")))) (DoExpr (EIf (EVar "isBuiltin") (EIf (EBinOp "&&" (EBinOp "&&" (EVar "isBinop") (EBinOp "||" (EBinOp "==" (EVar "tag") (ELit (LString "Int"))) (EApp (EVar "isTaggedFixedHead") (EVar "tag")))) (EApp (EVar "isCompareMethod") (EVar "method"))) (EApp (EVar "RScalar") (ELit (LString "Int"))) (EIf (EBinOp "&&" (EBinOp "&&" (EVar "isBinop") (EBinOp "==" (EVar "tag") (ELit (LString "Char")))) (EApp (EVar "isCompareMethod") (EVar "method"))) (EApp (EVar "RScalar") (ELit (LString "Char"))) (EIf (EBinOp "&&" (EBinOp "&&" (EVar "isBinop") (EApp (EVar "isBoxed64Head") (EVar "tag"))) (EApp (EVar "isCompareMethod") (EVar "method"))) (EApp (EVar "RScalar") (EVar "tag")) (EVar "RNone")))) (EBlock (DoLet false false (PTuple (PVar "siteKey") (PVar "selected")) (EApp (EApp (EApp (EVar "keyForSite") (EVar "sx")) (EVar "method")) (EListLit (EVar "operandMono")))) (DoLet false false (PVar "dictMethod") (EIf (EVar "isBinop") (EIf (EApp (EApp (EApp (EVar "ieDefinesReqMethodAt") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "bodyImplEnvRef") "value")) (EVar "method")) (EApp (EVar "headTyconMono") (EVar "operandMono"))) (EVar "method") (EApp (EVar "innerDefaultMethod") (EVar "method"))) (EVar "method"))) (DoLet false false (PVar "reqs") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "argImplDictRoutesForEncl") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "dictMethod")) (EVar "tag")) (EVar "operandMono")) (EListLit (EVar "operandMono")))) (DoExpr (EMatch (EVar "siteKey") (arm (PCon "Some" (PVar "key")) () (EApp (EApp (EApp (EVar "RKey") (EVar "key")) (EVar "reqs")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "selectedCallSupers") (EVar "sx")) (EVar "method")) (EVar "selected")) (EVar "encl")) (EVar "useScope")) (EListLit (EVar "operandMono"))))) (arm (PCon "None") () (EVar "RNone")))))))))
(DTypeSig false "stampPredicateOpRouteVal" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyFun (TyCon "ClassPredicate") (TyCon "Route"))))))))
(DFunDef false "stampPredicateOpRouteVal" ((PVar "sx") (PVar "encl") (PVar "useScope") (PVar "method") (PVar "operandMono") (PVar "predicate")) (EMatch (EApp (EApp (EVar "predicateScalarRoute") (EVar "method")) (EVar "operandMono")) (arm (PCon "Some" (PVar "route")) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteNumericPredicateTrace") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "NPTArithmetic")) (EVar "predicate")) (EVar "useScope")) (EFieldAccess (EVar "sx") "sxSite")) (EVar "None")) (EApp (EVar "Some") (EVar "route"))) (EListLit))) (DoExpr (EVar "route")))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "env") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "bodyImplEnvRef") "value")) (DoLet false false (PVar "goals") (EFieldAccess (EVar "predicate") "predicateArguments")) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "ieSelectRowByIface") (EVar "sx")) (EVar "env")) (EFieldAccess (EVar "predicate") "predicateInterface")) (EVar "goals")) (arm (PCon "Some" (PAs "row" (PCon "ImplRow" PWild PWild (PVar "selectedIface") PWild PWild PWild PWild))) () (EBlock (DoLet false false (PVar "reqs") (EApp (EApp (EApp (EApp (EApp (EVar "implDictRoutesForRow") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "goals")) (EVar "row"))) (DoLet false false (PVar "key") (EApp (EVar "rowRouteKey") (EVar "row"))) (DoLet false false (PVar "route") (EApp (EApp (EApp (EVar "RKey") (EVar "key")) (EVar "reqs")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "selectedCallSupers") (EVar "sx")) (EVar "method")) (EApp (EVar "Some") (EVar "row"))) (EVar "encl")) (EVar "useScope")) (EVar "goals")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteNumericPredicateTrace") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "NPTArithmetic")) (EVar "predicate")) (EVar "useScope")) (EFieldAccess (EVar "sx") "sxSite")) (EApp (EVar "Some") (EVar "selectedIface"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "RKey") (EVar "key")) (EListLit)) (EListLit)))) (EVar "reqs"))) (DoExpr (EVar "route")))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "route") (EVar "RNone")) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteNumericPredicateTrace") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "NPTArithmetic")) (EVar "predicate")) (EVar "useScope")) (EFieldAccess (EVar "sx") "sxSite")) (EVar "None")) (EApp (EVar "Some") (EVar "route"))) (EListLit))) (DoExpr (EVar "route"))))))))))
(DTypeSig false "predicateScalarRoute" (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "Route")))))
(DFunDef false "predicateScalarRoute" ((PVar "method") (PVar "operandMono")) (EMatch (EApp (EVar "arithmeticTag") (EVar "operandMono")) (arm (PCon "Some" (PLit (LString "Int"))) () (EApp (EVar "Some") (EIf (EBinOp "==" (EVar "method") (ELit (LString "negate"))) (EVar "RNone") (EApp (EVar "RScalar") (ELit (LString "Int")))))) (arm (PCon "Some" (PLit (LString "Float"))) () (EApp (EVar "Some") (EApp (EVar "RScalar") (ELit (LString "Float"))))) (arm (PCon "Some" (PVar "scalar")) () (EIf (EBinOp "==" (EVar "method") (ELit (LString "negate"))) (EVar "None") (EApp (EVar "Some") (EApp (EVar "RScalar") (EVar "scalar"))))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "innerDefaultMethod" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "innerDefaultMethod" ((PVar "m")) (EIf (EApp (EApp (EVar "contains") (EVar "m")) (EListLit (ELit (LString "lt")) (ELit (LString "gt")) (ELit (LString "lte")) (ELit (LString "gte")) (ELit (LString "min")) (ELit (LString "max")))) (ELit (LString "compare")) (EVar "m")))
(DTypeSig false "isCompareMethod" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isCompareMethod" ((PVar "m")) (EApp (EApp (EVar "contains") (EVar "m")) (EListLit (ELit (LString "eq")) (ELit (LString "lt")) (ELit (LString "gt")) (ELit (LString "lte")) (ELit (LString "gte")))))
(DTypeSig false "keyForSite" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "ImplRow")))))))
(DFunDef false "keyForSite" ((PVar "sx") (PVar "name") (PVar "goals")) (EBlock (DoLet false false (PVar "env") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "bodyImplEnvRef") "value")) (DoLet false false (PVar "selected") (EApp (EApp (EApp (EApp (EVar "ieSelectRowByMethod") (EVar "sx")) (EVar "env")) (EVar "name")) (EVar "goals"))) (DoExpr (ETuple (EApp (EApp (EMethodRef "map") (EVar "rowRouteKey")) (EVar "selected")) (EVar "selected")))))
(DTypeSig true "rowRouteKey" (TyFun (TyCon "ImplRow") (TyCon "String")))
(DFunDef false "rowRouteKey" ((PCon "ImplRow" PWild PWild (PVar "ir") (PVar "tys") PWild PWild PWild)) (EApp (EApp (EApp (EApp (EVar "implRouteKeyWord") (EFieldAccess (EVar "ir") "irOrigin")) (EFieldAccess (EVar "ir") "irName")) (EVar "tys")) (EVar "None")))
(DTypeSig true "goalHeadCon" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "HeadKey"))))
(DFunDef false "goalHeadCon" ((PCons (PVar "g") PWild)) (EApp (EVar "headTyconMono") (EVar "g")))
(DFunDef false "goalHeadCon" ((PList)) (EVar "None"))
(DTypeSig false "pickMostSpecificEntry" (TyFun (TyCon "SiteCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "KeyEntry")) (TyApp (TyCon "Option") (TyCon "KeyEntry"))))))
(DFunDef false "pickMostSpecificEntry" ((PVar "sx") PWild (PList)) (EVar "None"))
(DFunDef false "pickMostSpecificEntry" ((PVar "sx") (PVar "goals") (PCons (PVar "e") (PVar "rest"))) (EMatch (EApp (EApp (EVar "findMostSpecificEntry") (EBinOp "::" (EVar "e") (EVar "rest"))) (EBinOp "::" (EVar "e") (EVar "rest"))) (arm (PCon "Some" (PVar "best")) () (EApp (EVar "Some") (EVar "best"))) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EApp (EVar "reportAmbiguousOverlap") (EVar "sx")) (EVar "goals")) (EBinOp "::" (EVar "e") (EVar "rest")))) (DoExpr (EApp (EVar "Some") (EVar "e")))))))
(DTypeSig false "reportAmbiguousOverlap" (TyFun (TyCon "SiteCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "KeyEntry")) (TyCon "Unit")))))
(DFunDef false "reportAmbiguousOverlap" ((PVar "sx") (PVar "goals") (PVar "cands")) (EMatch (EApp (EVar "candsOneIface") (EVar "cands")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "iface")) () (EApp (EApp (EApp (EApp (EVar "reportOverlapForIface") (EVar "sx")) (EVar "iface")) (EVar "goals")) (EVar "cands")))))
(DTypeSig false "reportOverlapForIface" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "KeyEntry")) (TyCon "Unit"))))))
(DFunDef false "reportOverlapForIface" ((PVar "sx") (PVar "iface") (PVar "goals") (PVar "cands")) (EApp (EApp (EApp (EApp (EVar "pushAmbiguityAt") (EFieldAccess (EVar "sx") "sxModule")) (EVar "True")) (EFieldAccess (EVar "sx") "sxSite")) (EApp (EApp (EApp (EVar "ambiguousOverlapMsg") (EVar "iface")) (EVar "goals")) (EVar "cands"))))
(DTypeSig false "goalsClosed" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))
(DFunDef false "goalsClosed" ((PVar "mctx") (PVar "goals")) (EApp (EApp (EVar "allList") (ELam ((PVar "i")) (EApp (EApp (EVar "IdMap.has") (EVar "i")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "deferrableVarIds") "value")))) (EApp (EApp (EDictApp "flatMap") (EVar "monoUnboundIds")) (EVar "goals"))))
(DTypeSig false "candsOneIface" (TyFun (TyApp (TyCon "List") (TyCon "KeyEntry")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "candsOneIface" ((PList)) (EVar "None"))
(DFunDef false "candsOneIface" ((PCons (PCon "KeyEntry" PWild PWild PWild PWild (PVar "ifn") PWild PWild PWild) (PVar "rest"))) (EIf (EApp (EApp (EVar "allList") (ELam ((PVar "e")) (EBinOp "==" (EApp (EVar "keyEntryIface") (EVar "e")) (EVar "ifn")))) (EVar "rest")) (EApp (EVar "Some") (EVar "ifn")) (EVar "None")))
(DTypeSig false "findMostSpecificEntry" (TyFun (TyApp (TyCon "List") (TyCon "KeyEntry")) (TyFun (TyApp (TyCon "List") (TyCon "KeyEntry")) (TyApp (TyCon "Option") (TyCon "KeyEntry")))))
(DFunDef false "findMostSpecificEntry" ((PList) PWild) (EVar "None"))
(DFunDef false "findMostSpecificEntry" ((PCons (PVar "c") (PVar "cs")) (PVar "all")) (EIf (EApp (EApp (EVar "entryCoversAllOthers") (EVar "c")) (EDictApp "all")) (EApp (EVar "Some") (EVar "c")) (EIf (EVar "otherwise") (EApp (EApp (EVar "findMostSpecificEntry") (EVar "cs")) (EDictApp "all")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "entryCoversAllOthers" (TyFun (TyCon "KeyEntry") (TyFun (TyApp (TyCon "List") (TyCon "KeyEntry")) (TyCon "Bool"))))
(DFunDef false "entryCoversAllOthers" ((PVar "cand") (PVar "all")) (EApp (EApp (EVar "allList") (EApp (EVar "entryCovers") (EVar "cand"))) (EDictApp "all")))
(DTypeSig false "entryCovers" (TyFun (TyCon "KeyEntry") (TyFun (TyCon "KeyEntry") (TyCon "Bool"))))
(DFunDef false "entryCovers" ((PCon "KeyEntry" PWild PWild PWild PWild PWild (PVar "candTys") PWild PWild) (PCon "KeyEntry" PWild PWild PWild PWild PWild (PVar "otherTys") PWild PWild)) (EBinOp "||" (EApp (EApp (EVar "tyHeadEqV") (EVar "candTys")) (EVar "otherTys")) (EApp (EApp (EVar "tyStrictlyMoreSpecificV") (EVar "candTys")) (EVar "otherTys"))))
(DTypeSig true "ieSelectRowByIface" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "ImplEnv") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "ImplRow")))))))
(DFunDef false "ieSelectRowByIface" ((PVar "sx") (PVar "env") (PVar "iface") (PVar "goals")) (EMatch (EApp (EVar "goalHeadCon") (EVar "goals")) (arm (PCon "Some" (PVar "hk")) () (EApp (EApp (EVar "ieRowOfEntry") (EVar "env")) (EApp (EApp (EApp (EVar "pickMostSpecificEntry") (EVar "sx")) (EVar "goals")) (EApp (EApp (EApp (EApp (EVar "ieCandidatesForIface") (EVar "env")) (EVar "hk")) (EVar "iface")) (EVar "goals"))))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "ieSelectRowByMethod" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "ImplEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "ImplRow")))))))
(DFunDef false "ieSelectRowByMethod" ((PVar "sx") (PVar "env") (PVar "name") (PVar "goals")) (EMatch (EApp (EVar "goalHeadCon") (EVar "goals")) (arm (PCon "Some" (PVar "hk")) () (EApp (EApp (EVar "ieRowOfEntry") (EVar "env")) (EApp (EApp (EApp (EVar "pickMostSpecificEntry") (EVar "sx")) (EVar "goals")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ieCandidatesForMethod") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "env")) (EVar "hk")) (EApp (EApp (EVar "originMethodName") (EFieldAccess (EVar "sx") "sxModule")) (EVar "name"))) (EApp (EApp (EVar "methodAdmissionHere") (EFieldAccess (EVar "sx") "sxModule")) (EVar "name"))) (EVar "goals"))))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig true "selectedRowReqMatch" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ImplRow") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "Require"))))))))
(DFunDef false "selectedRowReqMatch" ((PVar "mctx") (PVar "goals") (PCon "ImplRow" PWild PWild PWild (PVar "itys") (PVar "reqs") PWild PWild)) (EApp (EApp (EMethodRef "map") (ELam ((PVar "subst")) (ETuple (EVar "subst") (EVar "reqs")))) (EApp (EApp (EApp (EVar "implHeadSubst") (EVar "mctx")) (EVar "itys")) (EVar "goals"))))
(DTypeSig true "implDictRoutesForRow" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ImplRow") (TyApp (TyCon "List") (TyCon "Route"))))))))
(DFunDef false "implDictRoutesForRow" ((PVar "sx") (PVar "encl") (PVar "useScope") (PVar "goals") (PVar "row")) (EMatch (EApp (EApp (EApp (EVar "selectedRowReqMatch") (EFieldAccess (EVar "sx") "sxModule")) (EVar "goals")) (EVar "row")) (arm (PCon "Some" (PTuple (PVar "subst") (PVar "reqs"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "argImplReqRoutes") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "subst")) (EVar "reqs")) (EApp (EApp (EVar "reqWalkSeed") (EApp (EVar "ieRowIface") (EVar "row"))) (EVar "goals")))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "legacyReturnReqRoutesForRow" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "Mono") (TyFun (TyCon "ImplRow") (TyApp (TyCon "List") (TyCon "Route"))))))))
(DFunDef false "legacyReturnReqRoutesForRow" ((PVar "sx") (PVar "encl") (PVar "useScope") (PVar "resultMono") (PVar "row")) (EMatch (EApp (EVar "ieRowHeadTriple") (EApp (EVar "Some") (EVar "row"))) (arm (PCon "Some" (PTuple (PVar "headTy") (PVar "implTys") (PVar "reqs"))) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "headSubstWithParams") (EFieldAccess (EVar "sx") "sxModule")) (EVar "headTy")) (EVar "implTys")) (EVar "resultMono")) (EListLit (EVar "resultMono"))) (arm (PCon "Some" (PVar "subst")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "argImplReqRoutes") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "subst")) (EVar "reqs")) (EApp (EApp (EVar "reqWalkSeed") (EApp (EVar "ieRowIface") (EVar "row"))) (EListLit (EVar "resultMono"))))) (arm (PCon "None") () (EListLit)))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "headSubstWithParams" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))))))))
(DFunDef false "headSubstWithParams" ((PVar "mctx") (PVar "headTy") (PVar "implTys") (PVar "resultMono") (PVar "paramMonos")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "headSub")) (EApp (EApp (EApp (EApp (EVar "augmentWithParams") (EVar "mctx")) (EVar "headSub")) (EVar "implTys")) (EVar "paramMonos")))) (EApp (EApp (EVar "matchTyMono") (EVar "headTy")) (EVar "resultMono"))))
(DTypeSig false "augmentWithParams" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))))))
(DFunDef false "augmentWithParams" ((PVar "mctx") (PVar "headSub") (PVar "implTys") (PVar "paramMonos")) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "listLen") (EVar "implTys")) (EApp (EVar "listLen") (EVar "paramMonos"))) (EBinOp ">" (EApp (EVar "listLen") (EVar "paramMonos")) (ELit (LInt 1)))) (EMatch (EApp (EApp (EApp (EVar "implHeadSubst") (EVar "mctx")) (EVar "implTys")) (EVar "paramMonos")) (arm (PCon "Some" (PVar "full")) () (EApp (EApp (EVar "mergeSubstPreferConcrete") (EVar "headSub")) (EVar "full"))) (arm (PCon "None") () (EVar "headSub"))) (EIf (EVar "otherwise") (EVar "headSub") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "implHeadSubst" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))))))
(DFunDef false "implHeadSubst" ((PVar "mctx") (PVar "pats") (PVar "concretes")) (EIf (EBinOp "/=" (EApp (EVar "listLen") (EVar "pats")) (EApp (EVar "listLen") (EVar "concretes"))) (EVar "None") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "positionBindings") (EVar "pats")) (EVar "concretes")) (EListLit)) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "binds")) () (EIf (EApp (EApp (EVar "matchEqPairs") (EVar "mctx")) (EApp (EApp (EVar "repeatedBindings") (EVar "binds")) (EListLit))) (EApp (EVar "Some") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "b")) (EApp (EApp (EApp (EVar "mergeOne") (EVar "acc")) (EApp (EVar "fst") (EVar "b"))) (EApp (EVar "snd") (EVar "b"))))) (EListLit)) (EVar "binds"))) (EVar "None")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "matchEqPairs" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Mono"))) (TyCon "Bool"))))
(DFunDef false "matchEqPairs" ((PVar "mctx") (PList)) (EVar "True"))
(DFunDef false "matchEqPairs" ((PVar "mctx") (PVar "pairs0")) (EBlock (DoLet false false (PVar "pairs") (EApp (EApp (EApp (EVar "rigidSigPairs") (EFieldAccess (EVar "mctx") "mcGraph")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "declaredSigVarIds") "value")) (EVar "pairs0"))) (DoLet false false (PVar "subst") (EApp (EVar "Ref") (EListLit))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "cohOverlapGo") (EVar "subst")) (EVar "pairs")) (EApp (EApp (EVar "allList") (ELam ((PVar "p")) (EApp (EApp (EApp (EVar "matchEqMono") (EVar "subst")) (EApp (EVar "fst") (EVar "p"))) (EApp (EVar "snd") (EVar "p"))))) (EVar "pairs"))))))
(DTypeSig true "positionBindings" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))))))
(DFunDef false "positionBindings" ((PList) (PList) (PVar "acc")) (EApp (EVar "Some") (EVar "acc")))
(DFunDef false "positionBindings" ((PCons (PVar "p") (PVar "ps")) (PCons (PVar "c") (PVar "cs")) (PVar "acc")) (EMatch (EApp (EApp (EVar "matchTyMono") (EVar "p")) (EVar "c")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "s")) () (EApp (EApp (EApp (EVar "positionBindings") (EVar "ps")) (EVar "cs")) (EBinOp "++" (EVar "acc") (EVar "s"))))))
(DFunDef false "positionBindings" (PWild PWild PWild) (EVar "None"))
(DTypeSig true "repeatedBindings" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "Mono"))))))
(DFunDef false "repeatedBindings" ((PList) PWild) (EListLit))
(DFunDef false "repeatedBindings" ((PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest")) (PVar "seen")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "k")) (EVar "seen")) (arm (PCon "Some" (PVar "first")) () (EBinOp "::" (ETuple (EVar "first") (EVar "v")) (EApp (EApp (EVar "repeatedBindings") (EVar "rest")) (EVar "seen")))) (arm (PCon "None") () (EApp (EApp (EVar "repeatedBindings") (EVar "rest")) (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EVar "seen"))))))
(DTypeSig true "entail" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "EntailKind") (TyTuple (TyCon "Route") (TyApp (TyCon "List") (TyCon "Route"))))))))))
(DFunDef false "entail" ((PVar "sx") (PVar "name") (PVar "m") (PVar "encl") (PVar "useScope") (PVar "kind")) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "entailAssum") (EFieldAccess (EVar "sx") "sxModule")) (EVar "m")) (EVar "encl")) (EVar "name")) (EVar "useScope")) (EVar "kind")) (arm (PCon "Some" (PVar "answer")) () (EBlock (DoExpr (EApp (EApp (EApp (EVar "noteAssumption") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "useScope")) (EVar "answer"))) (DoLet false false (PVar "result") (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "assumAnswerRoute") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "answer")) (EApp (EApp (EApp (EVar "goalIfaceOfKind") (EFieldAccess (EVar "sx") "sxModule")) (EVar "name")) (EVar "kind"))) (EVar "useScope")) (ELam ((PVar "dname")) (EApp (EApp (EVar "entailAssumRoute") (EVar "dname")) (EVar "kind")))) (EListLit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteNumericEntailment") (EVar "sx")) (EVar "kind")) (EVar "useScope")) (EVar "None")) (EApp (EVar "fst") (EVar "result"))) (EApp (EVar "snd") (EVar "result")))) (DoExpr (EVar "result")))) (arm (PCon "None") () (EMatch (EApp (EVar "headTyconMono") (EVar "m")) (arm (PCon "Some" (PVar "hk")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "entailInst") (EVar "sx")) (EVar "name")) (EVar "m")) (EVar "encl")) (EVar "useScope")) (EApp (EVar "headKeyTag") (EVar "hk"))) (EVar "kind"))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "entailRigidLead") (EVar "sx")) (EVar "m")) (EVar "encl")) (EVar "useScope")) (EVar "kind")) (arm (PCon "Some" (PVar "result")) () (EVar "result")) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "entailDetermined") (EVar "sx")) (EVar "name")) (EVar "encl")) (EVar "useScope")) (EVar "kind")) (arm (PCon "Some" (PVar "result")) () (EVar "result")) (arm (PCon "None") () (EBlock (DoLet false false (PVar "result") (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "entailFallback") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "m")) (EVar "kind")) (EListLit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteNumericEntailment") (EVar "sx")) (EVar "kind")) (EVar "useScope")) (EVar "None")) (EApp (EVar "fst") (EVar "result"))) (EApp (EVar "snd") (EVar "result")))) (DoExpr (EVar "result"))))))))))))
(DTypeSig false "entailDetermined" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "EntailKind") (TyApp (TyCon "Option") (TyTuple (TyCon "Route") (TyApp (TyCon "List") (TyCon "Route"))))))))))
(DFunDef false "entailDetermined" ((PVar "sx") (PVar "name") (PVar "encl") (PVar "useScope") (PCon "EKArg" (PVar "fullMono") (PVar "omitted"))) (EMatch (ETuple (EApp (EApp (EApp (EApp (EVar "occurrenceParamMonos") (EFieldAccess (EVar "sx") "sxModule")) (EVar "name")) (EVar "fullMono")) (EVar "omitted")) (EApp (EApp (EVar "methodIfaceHere") (EFieldAccess (EVar "sx") "sxModule")) (EVar "name"))) (arm (PTuple (PCon "Some" (PVar "goals")) (PCon "Some" (PVar "iface"))) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "row")) (ETuple (EApp (EApp (EApp (EVar "RKey") (EApp (EVar "rowRouteKey") (EVar "row"))) (EListLit)) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "selectedCallSupers") (EVar "sx")) (EVar "name")) (EApp (EVar "Some") (EVar "row"))) (EVar "encl")) (EVar "useScope")) (EVar "goals"))) (EApp (EApp (EApp (EApp (EApp (EVar "implDictRoutesForRow") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "goals")) (EVar "row"))))) (EApp (EApp (EApp (EVar "determinedGoalInstance") (EFieldAccess (EVar "sx") "sxModule")) (EVar "iface")) (EVar "goals")))) (arm PWild () (EVar "None"))))
(DFunDef false "entailDetermined" ((PVar "sx") PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "entailRigidLead" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "EntailKind") (TyApp (TyCon "Option") (TyTuple (TyCon "Route") (TyApp (TyCon "List") (TyCon "Route"))))))))))
(DFunDef false "entailRigidLead" ((PVar "sx") (PVar "m") (PVar "encl") (PVar "useScope") (PCon "EKNestedTop" (PVar "iface") PWild (PVar "walk") (PVar "rest"))) (EBlock (DoLet false false (PVar "goals") (EBinOp "::" (EVar "m") (EVar "rest"))) (DoLet false false (PVar "ids") (EApp (EApp (EDictApp "flatMap") (EVar "monoUnboundIds")) (EVar "goals"))) (DoLet false false (PVar "declared") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "declaredSigVarIds") "value")) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "ids")) (EApp (EApp (EVar "anyList") (ELam ((PVar "i")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EApp (EVar "intToString") (EVar "i"))) (EVar "declared"))))) (EVar "ids"))) (EApp (EApp (EVar "allList") (EVar "isBareTyvarMono")) (EVar "goals"))) (EVar "None") (EBlock (DoLet false false (PVar "env") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "bodyImplEnvRef") "value")) (DoLet false false (PVar "picked") (EApp (EApp (EApp (EVar "pickMostSpecificEntry") (EVar "sx")) (EVar "goals")) (EApp (EApp (EApp (EVar "ieEntriesForIface") (EApp (EApp (EVar "ieHeadRows") (EVar "None")) (EVar "env"))) (EVar "iface")) (EVar "goals")))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "row")) (ETuple (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "nestedRowRoute") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "m")) (EVar "goals")) (EVar "walk")) (EVar "row")) (EListLit)))) (EApp (EApp (EVar "ieRowOfEntry") (EVar "env")) (EVar "picked")))))))))
(DFunDef false "entailRigidLead" ((PVar "sx") PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "noteNumericEntailment" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "EntailKind") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "Option") (TyCon "IfaceRef")) (TyFun (TyCon "Route") (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyCon "Unit"))))))))
(DFunDef false "noteNumericEntailment" ((PVar "sx") (PCon "EKNumReturn" (PVar "predicate") PWild PWild (PVar "origin")) (PVar "scope") (PVar "selected") (PVar "route") (PVar "prereqs")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteNumericPredicateTrace") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "NPTReturn")) (EVar "predicate")) (EVar "scope")) (EVar "origin")) (EVar "selected")) (EApp (EVar "Some") (EVar "route"))) (EVar "prereqs")))
(DFunDef false "noteNumericEntailment" ((PVar "sx") (PCon "EKPredicateOp" PWild PWild (PVar "predicate")) (PVar "scope") (PVar "selected") (PVar "route") (PVar "prereqs")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteNumericPredicateTrace") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "NPTArithmetic")) (EVar "predicate")) (EVar "scope")) (EFieldAccess (EVar "sx") "sxSite")) (EVar "selected")) (EApp (EVar "Some") (EVar "route"))) (EVar "prereqs")))
(DFunDef false "noteNumericEntailment" ((PVar "sx") PWild PWild PWild PWild PWild) (ELit LUnit))
(DTypeSig false "entailAssum" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "EntailKind") (TyApp (TyCon "Option") (TyCon "AssumAnswer")))))))))
(DFunDef false "entailAssum" ((PVar "mctx") (PVar "m") (PVar "encl") (PVar "name") (PVar "useScope") (PVar "kind")) (EBlock (DoLet false false (PVar "request") (EApp (EApp (EApp (EVar "goalRequestOfKind") (EVar "mctx")) (EVar "name")) (EVar "kind"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "entailAssumVar") (EVar "mctx")) (EVar "request")) (EVar "m")) (EVar "encl")) (EVar "name")) (EVar "useScope")) (EVar "kind")) (arm (PCon "Some" (PVar "answer")) () (EApp (EVar "Some") (EVar "answer"))) (arm (PCon "None") () (EMatch (EVar "request") (arm (PCon "Some" (PVar "req")) () (EApp (EApp (EApp (EApp (EVar "activeDictPredOf") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "req")) (EVar "m")) (EVar "useScope"))) (arm (PCon "None") () (EVar "None"))))))))
(DTypeSig false "goalRequestOfKind" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "EntailKind") (TyApp (TyCon "Option") (TyCon "PredicateRequest"))))))
(DFunDef false "goalRequestOfKind" ((PVar "mctx") (PVar "name") (PCon "EKReturn" (PVar "fullMono") PWild)) (EApp (EApp (EApp (EVar "goalPredOf") (EVar "mctx")) (EVar "name")) (EVar "fullMono")))
(DFunDef false "goalRequestOfKind" ((PVar "mctx") PWild (PCon "EKNumReturn" (PVar "predicate") PWild PWild PWild)) (EApp (EVar "Some") (ERecordCreate "PredicateRequest" ((fa "prIface" (EFieldAccess (EVar "predicate") "predicateInterface")) (fa "prArgs" (EApp (EVar "PSArgsKnown") (EFieldAccess (EVar "predicate") "predicateArguments")))))))
(DFunDef false "goalRequestOfKind" ((PVar "mctx") (PVar "name") (PCon "EKArg" (PVar "fullMono") (PVar "omitted"))) (EApp (EApp (EApp (EApp (EVar "occurrencePredOf") (EVar "mctx")) (EVar "name")) (EVar "fullMono")) (EVar "omitted")))
(DFunDef false "goalRequestOfKind" ((PVar "mctx") (PVar "name") (PCon "EKOp" PWild PWild)) (EApp (EApp (EVar "goalPredOfOp") (EVar "mctx")) (EVar "name")))
(DFunDef false "goalRequestOfKind" ((PVar "mctx") PWild (PCon "EKPredicateOp" PWild PWild (PVar "predicate"))) (EApp (EVar "Some") (ERecordCreate "PredicateRequest" ((fa "prIface" (EFieldAccess (EVar "predicate") "predicateInterface")) (fa "prArgs" (EApp (EVar "PSArgsKnown") (EFieldAccess (EVar "predicate") "predicateArguments")))))))
(DFunDef false "goalRequestOfKind" ((PVar "mctx") PWild (PCon "EKNestedTop" PWild PWild PWild PWild)) (EVar "None"))
(DTypeSig false "entailAssumVar" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "PredicateRequest")) (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "EntailKind") (TyApp (TyCon "Option") (TyCon "AssumAnswer"))))))))))
(DFunDef false "entailAssumVar" ((PVar "mctx") (PVar "request") (PVar "m") (PVar "encl") PWild (PVar "useScope") (PCon "EKReturn" PWild PWild)) (EApp (EApp (EApp (EApp (EApp (EVar "activeDictVarOfEncl") (EVar "mctx")) (EVar "request")) (EVar "m")) (EVar "encl")) (EVar "useScope")))
(DFunDef false "entailAssumVar" ((PVar "mctx") (PVar "request") (PVar "m") (PVar "encl") PWild (PVar "useScope") (PCon "EKNumReturn" PWild PWild PWild PWild)) (EApp (EApp (EApp (EApp (EApp (EVar "activeDictVarOfEncl") (EVar "mctx")) (EVar "request")) (EVar "m")) (EVar "encl")) (EVar "useScope")))
(DFunDef false "entailAssumVar" ((PVar "mctx") PWild (PVar "m") (PVar "encl") PWild (PVar "useScope") (PCon "EKNestedTop" (PVar "iface") PWild PWild (PVar "rest"))) (EBlock (DoLet false false (PVar "request") (ERecordCreate "PredicateRequest" ((fa "prIface" (EVar "iface")) (fa "prArgs" (EApp (EVar "PSArgsKnown") (EBinOp "::" (EVar "m") (EVar "rest"))))))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "activeFunDictPredOf") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "request")) (EVar "useScope")) (arm (PCon "Some" (PVar "answer")) () (EApp (EVar "Some") (EVar "answer"))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EApp (EVar "activeFunDictPredOfResidual") (EFieldAccess (EVar "mctx") "mcGraph")) (EFieldAccess (EVar "iface") "irName")) (EBinOp "::" (EVar "m") (EVar "rest"))) (EVar "useScope")) (arm (PCon "Some" (PVar "answer")) () (EApp (EVar "Some") (EVar "answer"))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EApp (EVar "implReqDictVarOf") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EVar "Some") (EVar "request"))) (EVar "m")) (EVar "useScope")) (arm (PCon "Some" (PVar "answer")) () (EApp (EVar "Some") (EVar "answer"))) (arm (PCon "None") () (EApp (EApp (EMethodRef "map") (EVar "LegacyScalar")) (EApp (EApp (EApp (EApp (EVar "activeDictVarAnswering") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "m")) (EVar "useScope")) (ELam ((PVar "b")) (EApp (EApp (EApp (EApp (EVar "scalarGivenAnswers") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "b")) (EVar "iface")) (EVar "useScope"))))))))))))))
(DFunDef false "entailAssumVar" ((PVar "mctx") (PVar "request") (PVar "m") (PVar "encl") PWild (PVar "useScope") (PCon "EKArg" PWild PWild)) (EApp (EApp (EApp (EApp (EApp (EVar "activeDictVarOfEncl") (EVar "mctx")) (EVar "request")) (EVar "m")) (EVar "encl")) (EVar "useScope")))
(DFunDef false "entailAssumVar" ((PVar "mctx") (PVar "request") (PVar "m") (PVar "encl") (PVar "name") (PVar "useScope") (PCon "EKOp" (PVar "isBinop") (PVar "inImpl"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "opDictVarOf") (EVar "mctx")) (EVar "request")) (EVar "isBinop")) (EVar "name")) (EVar "m")) (EVar "inImpl")) (EVar "encl")) (EVar "useScope")))
(DFunDef false "entailAssumVar" ((PVar "mctx") (PVar "request") (PVar "m") (PVar "encl") PWild (PVar "useScope") (PCon "EKPredicateOp" PWild PWild PWild)) (EApp (EApp (EApp (EApp (EApp (EVar "activeDictVarOfEncl") (EVar "mctx")) (EVar "request")) (EVar "m")) (EVar "encl")) (EVar "useScope")))
(DTypeSig false "goalIfaceOfKind" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "EntailKind") (TyApp (TyCon "Option") (TyCon "IfaceRef"))))))
(DFunDef false "goalIfaceOfKind" ((PVar "mctx") PWild (PCon "EKNestedTop" (PVar "iface") PWild PWild PWild)) (EIf (EBinOp "==" (EFieldAccess (EVar "iface") "irName") (ELit (LString ""))) (EVar "None") (EApp (EVar "Some") (EVar "iface"))))
(DFunDef false "goalIfaceOfKind" ((PVar "mctx") PWild (PCon "EKNumReturn" (PVar "predicate") PWild PWild PWild)) (EApp (EVar "Some") (EFieldAccess (EVar "predicate") "predicateInterface")))
(DFunDef false "goalIfaceOfKind" ((PVar "mctx") PWild (PCon "EKPredicateOp" PWild PWild (PVar "predicate"))) (EApp (EVar "Some") (EFieldAccess (EVar "predicate") "predicateInterface")))
(DFunDef false "goalIfaceOfKind" ((PVar "mctx") (PVar "name") PWild) (EApp (EApp (EVar "methodIfaceHere") (EVar "mctx")) (EVar "name")))
(DTypeSig false "entailAssumRoute" (TyFun (TyCon "String") (TyFun (TyCon "EntailKind") (TyCon "Route"))))
(DFunDef false "entailAssumRoute" ((PVar "dname") (PCon "EKReturn" PWild (PVar "isRp"))) (EIf (EVar "isRp") (EApp (EVar "RDictFwd") (EVar "dname")) (EApp (EVar "RDict") (EVar "dname"))))
(DFunDef false "entailAssumRoute" ((PVar "dname") (PCon "EKNumReturn" PWild PWild (PVar "isRp") PWild)) (EIf (EVar "isRp") (EApp (EVar "RDictFwd") (EVar "dname")) (EApp (EVar "RDict") (EVar "dname"))))
(DFunDef false "entailAssumRoute" ((PVar "dname") (PCon "EKNestedTop" PWild PWild PWild PWild)) (EApp (EVar "RDict") (EVar "dname")))
(DFunDef false "entailAssumRoute" ((PVar "dname") (PCon "EKArg" PWild PWild)) (EApp (EVar "RDict") (EVar "dname")))
(DFunDef false "entailAssumRoute" ((PVar "dname") (PCon "EKOp" PWild PWild)) (EApp (EVar "RDict") (EVar "dname")))
(DFunDef false "entailAssumRoute" ((PVar "dname") (PCon "EKPredicateOp" PWild PWild PWild)) (EApp (EVar "RDict") (EVar "dname")))
(DTypeSig false "selectReturnRow" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "ImplEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "ImplRow")))))))
(DFunDef false "selectReturnRow" ((PVar "sx") (PVar "env") (PVar "name") (PVar "goals")) (EMatch (EApp (EApp (EApp (EApp (EVar "ieSelectRowByMethod") (EVar "sx")) (EVar "env")) (EVar "name")) (EVar "goals")) (arm (PCon "Some" (PVar "row")) () (EApp (EVar "Some") (EVar "row"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "methodIfaceHere") (EFieldAccess (EVar "sx") "sxModule")) (EVar "name")) (arm (PCon "Some" (PVar "iface")) () (EApp (EApp (EApp (EVar "determinedGoalInstance") (EFieldAccess (EVar "sx") "sxModule")) (EVar "iface")) (EVar "goals"))) (arm (PCon "None") () (EVar "None"))))))
(DTypeSig true "determinedGoalInstance" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "ImplRow"))))))
(DFunDef false "determinedGoalInstance" ((PVar "mctx") PWild (PList)) (EVar "None"))
(DFunDef false "determinedGoalInstance" ((PVar "mctx") (PVar "iface") (PCons (PVar "first") (PVar "rest"))) (EMatch (EApp (EVar "normalize") (EVar "first")) (arm (PCon "TVar" (PVar "cell")) () (EBlock (DoLet false false (PVar "goals") (EBinOp "::" (EVar "first") (EVar "rest"))) (DoLet false false (PVar "filed") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "IdMap.get") (EApp (EVar "tyvarId") (EVar "cell"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "determinedRowsRef") "value")))) (DoExpr (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "entry")) (EApp (EApp (EApp (EVar "determinedEntryAnswers") (EVar "iface")) (EVar "goals")) (EVar "entry")))) (EVar "filed")) (arm (PCons (PTuple (PVar "row") PWild) PWild) () (EApp (EVar "Some") (EVar "row"))) (arm (PList) () (EVar "None")))))) (arm PWild () (EVar "None"))))
(DTypeSig false "entailInst" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "String") (TyFun (TyCon "EntailKind") (TyTuple (TyCon "Route") (TyApp (TyCon "List") (TyCon "Route")))))))))))
(DFunDef false "entailInst" ((PVar "sx") (PVar "name") (PVar "m") (PVar "encl") (PVar "useScope") (PVar "tag") (PCon "EKReturn" (PVar "fullMono") PWild)) (EBlock (DoLet false false (PVar "env") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "bodyImplEnvRef") "value")) (DoExpr (EMatch (EApp (EApp (EApp (EVar "ifaceParamMonos") (EFieldAccess (EVar "sx") "sxModule")) (EVar "name")) (EVar "fullMono")) (arm (PCon "Some" (PVar "goals")) () (EMatch (EApp (EApp (EApp (EApp (EVar "selectReturnRow") (EVar "sx")) (EVar "env")) (EVar "name")) (EVar "goals")) (arm (PCon "Some" (PVar "row")) () (EBlock (DoLet false false (PVar "routeKey") (EApp (EVar "rowRouteKey") (EVar "row"))) (DoLet false false (PVar "routes") (EApp (EApp (EApp (EApp (EApp (EVar "implDictRoutesForRow") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "goals")) (EVar "row"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "RKey") (EVar "routeKey")) (EListLit)) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "selectedCallSupers") (EVar "sx")) (EVar "name")) (EApp (EVar "Some") (EVar "row"))) (EVar "encl")) (EVar "useScope")) (EVar "goals"))) (EVar "routes"))))) (arm (PCon "None") () (ETuple (EVar "RNone") (EListLit))))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EApp (EVar "ieSelectRowByMethod") (EVar "sx")) (EVar "env")) (EVar "name")) (EListLit (EVar "m"))) (arm (PCon "Some" (PVar "row")) () (EBlock (DoLet false false (PVar "routeKey") (EApp (EVar "rowRouteKey") (EVar "row"))) (DoLet false false (PVar "routes") (EApp (EApp (EApp (EApp (EApp (EVar "legacyReturnReqRoutesForRow") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "m")) (EVar "row"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "RKey") (EVar "routeKey")) (EListLit)) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "selectedCallSupers") (EVar "sx")) (EVar "name")) (EApp (EVar "Some") (EVar "row"))) (EVar "encl")) (EVar "useScope")) (EListLit (EVar "m")))) (EVar "routes"))))) (arm (PCon "None") () (ETuple (EVar "RNone") (EListLit)))))))))
(DFunDef false "entailInst" ((PVar "sx") (PVar "name") (PVar "m") (PVar "encl") (PVar "useScope") PWild (PAs "kind" (PCon "EKNumReturn" (PVar "predicate") PWild PWild PWild))) (EBlock (DoLet false false (PVar "goals") (EFieldAccess (EVar "predicate") "predicateArguments")) (DoLet false false (PVar "env") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "bodyImplEnvRef") "value")) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "ieSelectRowByIface") (EVar "sx")) (EVar "env")) (EFieldAccess (EVar "predicate") "predicateInterface")) (EVar "goals")) (arm (PCon "Some" (PAs "row" (PCon "ImplRow" PWild PWild (PVar "selectedIface") PWild PWild PWild PWild))) () (EBlock (DoLet false false (PVar "sups") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "selectedCallSupers") (EVar "sx")) (EVar "name")) (EApp (EVar "Some") (EVar "row"))) (EVar "encl")) (EVar "useScope")) (EVar "goals"))) (DoLet false false (PVar "route") (EApp (EApp (EApp (EVar "RKey") (EApp (EVar "rowRouteKey") (EVar "row"))) (EListLit)) (EVar "sups"))) (DoLet false false (PVar "routes") (EApp (EApp (EApp (EApp (EApp (EVar "implDictRoutesForRow") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "goals")) (EVar "row"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteNumericEntailment") (EVar "sx")) (EVar "kind")) (EVar "useScope")) (EApp (EVar "Some") (EVar "selectedIface"))) (EVar "route")) (EVar "routes"))) (DoExpr (ETuple (EVar "route") (EVar "routes"))))) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteNumericEntailment") (EVar "sx")) (EVar "kind")) (EVar "useScope")) (EVar "None")) (EVar "RNone")) (EListLit))) (DoExpr (ETuple (EVar "RNone") (EListLit)))))))))
(DFunDef false "entailInst" ((PVar "sx") PWild (PVar "m") (PVar "encl") (PVar "useScope") PWild (PCon "EKNestedTop" (PVar "iface") PWild (PVar "walk") (PVar "rest"))) (EBlock (DoLet false false (PVar "goals") (EBinOp "::" (EVar "m") (EVar "rest"))) (DoLet false false (PVar "env") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "bodyImplEnvRef") "value")) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "ieSelectRowByIface") (EVar "sx")) (EVar "env")) (EVar "iface")) (EVar "goals")) (arm (PCon "Some" (PVar "row")) () (ETuple (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "nestedRowRoute") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "m")) (EVar "goals")) (EVar "walk")) (EVar "row")) (EListLit))) (arm (PCon "None") () (ETuple (EVar "RNone") (EListLit)))))))
(DFunDef false "entailInst" ((PVar "sx") (PVar "name") (PVar "m") (PVar "encl") (PVar "useScope") (PVar "tag") (PCon "EKArg" (PVar "fullMono") (PVar "omitted"))) (EBlock (DoLet false false (PVar "goals") (EApp (EApp (EVar "optionOr") (EListLit (EVar "m"))) (EApp (EApp (EApp (EApp (EVar "occurrenceParamMonos") (EFieldAccess (EVar "sx") "sxModule")) (EVar "name")) (EVar "fullMono")) (EVar "omitted")))) (DoLet false false (PTuple (PVar "siteKey") (PVar "selected")) (EApp (EApp (EApp (EVar "keyForSite") (EVar "sx")) (EVar "name")) (EVar "goals"))) (DoLet false false (PVar "dictName") (EIf (EApp (EApp (EApp (EVar "ieDefinesReqMethodAt") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "bodyImplEnvRef") "value")) (EVar "name")) (EApp (EVar "headTyconMono") (EVar "m"))) (EVar "name") (EApp (EVar "innerDefaultMethod") (EVar "name")))) (DoLet false false (PVar "subject") (EMatch (EVar "goals") (arm (PCons (PVar "g") PWild) () (EVar "g")) (arm (PList) () (EVar "m")))) (DoLet false false (PVar "word") (EMatch (EVar "siteKey") (arm (PCon "Some" (PVar "routeKey")) () (EApp (EApp (EApp (EVar "RKey") (EVar "routeKey")) (EListLit)) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "selectedCallSupers") (EVar "sx")) (EVar "name")) (EVar "selected")) (EVar "encl")) (EVar "useScope")) (EVar "goals")))) (arm (PCon "None") () (EVar "RNone")))) (DoExpr (ETuple (EVar "word") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "argImplDictRoutesForEncl") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "dictName")) (EVar "tag")) (EVar "subject")) (EVar "goals"))))))
(DFunDef false "entailInst" ((PVar "sx") (PVar "name") (PVar "m") (PVar "encl") (PVar "useScope") (PVar "tag") (PCon "EKOp" (PVar "isBinop") PWild)) (ETuple (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "stampOpRouteVal") (EVar "sx")) (EVar "isBinop")) (EVar "encl")) (EVar "useScope")) (EVar "name")) (EVar "m")) (EVar "tag")) (EListLit)))
(DFunDef false "entailInst" ((PVar "sx") (PVar "name") (PVar "m") (PVar "encl") (PVar "useScope") PWild (PCon "EKPredicateOp" PWild PWild (PVar "predicate"))) (ETuple (EApp (EApp (EApp (EApp (EApp (EApp (EVar "stampPredicateOpRouteVal") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "name")) (EVar "m")) (EVar "predicate")) (EListLit)))
(DTypeSig true "superRoutesAt" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ReqWalk") (TyApp (TyCon "List") (TyCon "Route")))))))))
(DFunDef false "superRoutesAt" ((PVar "sx") (PVar "iface") (PVar "encl") (PVar "useScope") (PVar "goals") (PVar "walk")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EVar "superRouteAt") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "walk"))) (EApp (EApp (EApp (EVar "directSuperGoals") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "iface")) (EVar "goals"))))
(DTypeSig false "superRouteAt" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "ReqWalk") (TyFun (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Mono")))) (TyCon "Route")))))))
(DFunDef false "superRouteAt" ((PVar "sx") (PVar "encl") (PVar "useScope") (PVar "walk") (PTuple (PVar "superIface") (PVar "superArgs"))) (EMatch (EVar "superArgs") (arm (PCon "Some" (PCons (PVar "g0") (PVar "gs"))) () (EApp (EApp (EVar "noteInnerRoute") (EVar "sx")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeOfD") (EVar "sx")) (EVar "superIface")) (EVar "encl")) (EVar "useScope")) (EVar "CommitSuper")) (EVar "g0")) (EVar "gs")) (EVar "walk")))) (arm PWild () (EApp (EApp (EVar "noteInnerRoute") (EVar "sx")) (EVar "RNone")))))
(DTypeSig false "nestedRowRoute" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ReqWalk") (TyFun (TyCon "ImplRow") (TyCon "Route")))))))))
(DFunDef false "nestedRowRoute" ((PVar "sx") (PVar "encl") (PVar "useScope") (PVar "m") (PVar "goals") (PVar "walk") (PAs "row" (PCon "ImplRow" PWild PWild (PVar "selectedIface") PWild PWild PWild PWild))) (EApp (EApp (EApp (EVar "RKey") (EApp (EVar "rowRouteKey") (EVar "row"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "argImplRequiresRoutesForRow") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "m")) (EVar "goals")) (EVar "walk")) (EVar "row"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "superRoutesAt") (EVar "sx")) (EVar "selectedIface")) (EVar "encl")) (EVar "useScope")) (EVar "goals")) (EVar "walk"))))
(DTypeSig false "committedSuperRoute" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "ReqWalk") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Route"))))))))
(DFunDef false "committedSuperRoute" ((PVar "sx") PWild PWild PWild PWild (PList)) (EVar "RNone"))
(DFunDef false "committedSuperRoute" ((PVar "sx") (PVar "encl") (PVar "useScope") (PVar "iface") (PVar "walk") (PAs "goals" (PCons (PVar "m") PWild))) (EMatch (EApp (EApp (EApp (EApp (EVar "stableGoalReach") (EFieldAccess (EVar "sx") "sxModule")) (EListLit)) (EVar "iface")) (EVar "goals")) (arm (PCon "ReachOne" (PVar "row")) ((GBool (EApp (EApp (EApp (EVar "rowHeadMatches") (EFieldAccess (EVar "sx") "sxModule")) (EVar "goals")) (EVar "row")))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "nestedRowRoute") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "m")) (EVar "goals")) (EVar "walk")) (EVar "row"))) (arm PWild () (EVar "RNone"))))
(DTypeSig true "selectedCallSupers" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "ImplRow")) (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "Route")))))))))
(DFunDef false "selectedCallSupers" ((PVar "sx") (PVar "name") (PCon "Some" (PCon "ImplRow" PWild PWild (PVar "iface") PWild PWild (PVar "supplied") PWild)) (PVar "encl") (PVar "useScope") (PVar "goals")) (EIf (EApp (EApp (EVar "contains") (EVar "name")) (EVar "supplied")) (EListLit) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "superRoutesAt") (EVar "sx")) (EVar "iface")) (EVar "encl")) (EVar "useScope")) (EVar "goals")) (EApp (EVar "reqWalkStart") (ELit LUnit)))))
(DFunDef false "selectedCallSupers" ((PVar "sx") PWild (PCon "None") PWild PWild PWild) (EListLit))
(DTypeSig false "entailFallback" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "Mono") (TyFun (TyCon "EntailKind") (TyCon "Route")))))))
(DFunDef false "entailFallback" ((PVar "sx") PWild PWild PWild (PCon "EKReturn" PWild PWild)) (EVar "RNone"))
(DFunDef false "entailFallback" ((PVar "sx") PWild PWild PWild (PCon "EKNumReturn" PWild PWild PWild PWild)) (EVar "RNone"))
(DFunDef false "entailFallback" ((PVar "sx") (PVar "encl") (PVar "scope") (PVar "m") (PCon "EKNestedTop" (PVar "iface") (PVar "policy") (PVar "walk") (PVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "undeterminedRoute") (EVar "sx")) (EVar "encl")) (EVar "scope")) (EVar "iface")) (EVar "policy")) (EVar "walk")) (EBinOp "::" (EVar "m") (EVar "rest"))))
(DFunDef false "entailFallback" ((PVar "sx") PWild PWild PWild (PCon "EKArg" PWild PWild)) (EVar "RNone"))
(DFunDef false "entailFallback" ((PVar "sx") PWild PWild PWild (PCon "EKOp" PWild PWild)) (EVar "RNone"))
(DFunDef false "entailFallback" ((PVar "sx") PWild PWild PWild (PCon "EKPredicateOp" PWild PWild PWild)) (EVar "RNone"))
(DTypeSig true "routeOfD" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "Undetermined") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ReqWalk") (TyCon "Route"))))))))))
(DFunDef false "routeOfD" ((PVar "sx") (PVar "iface") (PVar "encl") (PVar "useScope") (PVar "policy") (PVar "m") (PVar "rest") (PVar "walk")) (EApp (EVar "fst") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "entail") (EVar "sx")) (ELit (LString ""))) (EVar "m")) (EVar "encl")) (EVar "useScope")) (EApp (EApp (EApp (EApp (EVar "EKNestedTop") (EVar "iface")) (EVar "policy")) (EVar "walk")) (EVar "rest")))))
(DTypeSig false "undeterminedRoute" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "Undetermined") (TyFun (TyCon "ReqWalk") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Route")))))))))
(DFunDef false "undeterminedRoute" ((PVar "sx") PWild PWild PWild (PCon "KeepNone") PWild PWild) (EVar "RNone"))
(DFunDef false "undeterminedRoute" ((PVar "sx") PWild (PVar "scope") PWild (PCon "CountImpls" (PVar "iface")) PWild (PVar "goal")) (EApp (EApp (EApp (EApp (EVar "routeUndeterminedTop") (EVar "sx")) (EVar "scope")) (EVar "iface")) (EVar "goal")))
(DFunDef false "undeterminedRoute" ((PVar "sx") (PVar "encl") (PVar "scope") (PVar "iface") (PCon "CommitSuper") (PVar "walk") (PVar "goal")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "committedSuperRoute") (EVar "sx")) (EVar "encl")) (EVar "scope")) (EVar "iface")) (EVar "walk")) (EVar "goal")))
(DTypeSig false "routeUndeterminedTop" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "ScopeId") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Route"))))))
(DFunDef false "routeUndeterminedTop" ((PVar "sx") (PVar "scope") (PVar "ifaceRef") (PVar "goal")) (EIf (EBinOp "==" (EFieldAccess (EVar "ifaceRef") "irName") (ELit (LString ""))) (EVar "RNone") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "goalReach") (EFieldAccess (EVar "sx") "sxModule")) (EVar "goal")) (EApp (EApp (EApp (EApp (EVar "goalCandidates") (EFieldAccess (EVar "sx") "sxModule")) (EVar "omEmpty")) (EVar "goal")) (EApp (EApp (EApp (EVar "goalRows") (EFieldAccess (EVar "sx") "sxModule")) (EVar "ifaceRef")) (EVar "goal")))) (arm (PCon "ReachNone") () (EVar "RNone")) (arm (PCon "ReachOne" PWild) ((GBool (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "monoVectorClosed") (EVar "goal"))) (EApp (EApp (EVar "goalsClosed") (EFieldAccess (EVar "sx") "sxModule")) (EVar "goal"))))) (EVar "RNone")) (arm (PCon "ReachOne" (PVar "row")) () (EApp (EApp (EApp (EApp (EApp (EVar "undeterminedRowRoute") (EVar "sx")) (EVar "scope")) (EVar "ifaceRef")) (EVar "goal")) (EVar "row"))) (arm (PCon "ReachMany") () (EVar "RNone"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "undeterminedRowRoute" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "ScopeId") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ImplRow") (TyCon "Route")))))))
(DFunDef false "undeterminedRowRoute" ((PVar "sx") PWild PWild (PList) PWild) (EVar "RNone"))
(DFunDef false "undeterminedRowRoute" ((PVar "sx") (PVar "scope") (PVar "ifaceRef") (PCons (PVar "m") (PVar "rest")) (PVar "row")) (EApp (EApp (EApp (EVar "RKey") (EApp (EVar "rowRouteKey") (EVar "row"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "argImplRequiresRoutesForRow") (EVar "sx")) (ELit (LString ""))) (EVar "scope")) (EVar "m")) (EBinOp "::" (EVar "m") (EVar "rest"))) (EApp (EVar "reqWalkStart") (ELit LUnit))) (EVar "row"))) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "superIface") PWild)) (EApp (EApp (EVar "noteInnerRoute") (EVar "sx")) (EApp (EApp (EApp (EApp (EVar "routeUndeterminedTop") (EVar "sx")) (EVar "scope")) (EVar "superIface")) (EBinOp "::" (EVar "m") (EVar "rest")))))) (EApp (EApp (EApp (EVar "directSuperGoals") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "ifaceRef")) (EListLit)))))
(DTypeSig false "argImplRequiresRoutesForRow" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ReqWalk") (TyFun (TyCon "ImplRow") (TyApp (TyCon "List") (TyCon "Route"))))))))))
(DFunDef false "argImplRequiresRoutesForRow" ((PVar "sx") (PVar "encl") (PVar "useScope") (PVar "m") (PVar "goals") (PVar "walk") (PVar "row")) (EMatch (EApp (EApp (EApp (EVar "reqWalkEnter") (EVar "walk")) (EApp (EVar "ieRowIface") (EVar "row"))) (EVar "goals")) (arm (PCon "ReqOn" (PVar "next")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeWalkMemoized") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "goals")) (EVar "row")) (EVar "next")) (ELam ((PVar "walkSx")) (EMatch (EApp (EVar "ieRowHeadTriple") (EApp (EVar "Some") (EVar "row"))) (arm (PCon "Some" (PTuple (PVar "headTy") (PVar "itys") (PVar "reqs"))) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "headSubstWithParams") (EFieldAccess (EVar "sx") "sxModule")) (EVar "headTy")) (EVar "itys")) (EVar "m")) (EVar "goals")) (arm (PCon "Some" (PVar "subst")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "argImplReqRoutes") (EVar "walkSx")) (EVar "encl")) (EVar "useScope")) (EVar "subst")) (EVar "reqs")) (EVar "next"))) (arm (PCon "None") () (EListLit)))) (arm (PCon "None") () (EListLit)))))) (arm (PVar "cut") () (EBlock (DoExpr (EApp (EVar "noteRouteWalkCut") (EVar "walk"))) (DoExpr (EApp (EApp (EVar "requiresRouteWalkCut") (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcGraph")) (EVar "cut")))))))
(DTypeSig false "requiresRouteWalkCut" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ReqStep") (TyApp (TyCon "List") (TyCon "Route")))))
(DFunDef false "requiresRouteWalkCut" ((PVar "gctx") PWild) (EIf (EApp (EApp (EVar "typeErrorsArmed") (EVar "gctx")) (ELit LUnit)) (EListLit) (EApp (EVar "panic") (ELit (LString "requires route walk reached a goal the solving walks did not accept")))))
(DTypeSig false "argImplDictRoutesForEncl" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "Route"))))))))))
(DFunDef false "argImplDictRoutesForEncl" ((PVar "sx") (PVar "encl") (PVar "useScope") (PVar "name") (PVar "_tag") (PVar "mono") (PVar "goals")) (EMatch (EApp (EVar "ieRowHeadTriple") (EApp (EApp (EApp (EApp (EVar "ieSelectRowByMethod") (EVar "sx")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "bodyImplEnvRef") "value")) (EVar "name")) (EVar "goals"))) (arm (PCon "Some" (PTuple (PVar "headTy") (PVar "implTys") (PVar "reqs"))) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "headSubstWithParams") (EFieldAccess (EVar "sx") "sxModule")) (EVar "headTy")) (EVar "implTys")) (EVar "mono")) (EVar "goals")) (arm (PCon "Some" (PVar "subst")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "argImplReqRoutes") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "subst")) (EVar "reqs")) (EApp (EVar "reqWalkStart") (ELit LUnit)))) (arm (PCon "None") () (EListLit)))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "argImplReqRoutes" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyFun (TyCon "ReqWalk") (TyApp (TyCon "List") (TyCon "Route")))))))))
(DFunDef false "argImplReqRoutes" ((PVar "sx") PWild PWild PWild (PList) PWild) (EListLit))
(DFunDef false "argImplReqRoutes" ((PVar "sx") (PVar "encl") (PVar "useScope") (PVar "subst") (PCons (PRec "Require" ((rf "requireHead" (PVar "rIface")) (rf "requireArgs" (PVar "rargs")) (rf "requireOrigin" (PVar "ro"))) false) (PVar "rest")) (PVar "walk")) (EBlock (DoLet false false (PVar "iface") (ERecordCreate "IfaceRef" ((fa "irName" (EVar "rIface")) (fa "irOrigin" (EVar "ro"))))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "argReqRoute") (EVar "sx")) (EVar "iface")) (EVar "encl")) (EVar "useScope")) (EVar "subst")) (EVar "rargs")) (EVar "walk")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "argImplReqRoutes") (EVar "sx")) (EVar "encl")) (EVar "useScope")) (EVar "subst")) (EVar "rest")) (EVar "walk"))))))
(DTypeSig false "argReqRoute" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyCon "ReqWalk") (TyCon "Route")))))))))
(DFunDef false "argReqRoute" ((PVar "sx") PWild PWild PWild PWild (PList) PWild) (EApp (EApp (EVar "noteInnerRoute") (EVar "sx")) (EVar "RNone")))
(DFunDef false "argReqRoute" ((PVar "sx") (PVar "iface") (PVar "encl") (PVar "useScope") (PVar "subst") (PCons (PVar "arg") (PVar "more")) (PVar "walk")) (EApp (EApp (EVar "noteInnerRoute") (EVar "sx")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routeOfD") (EVar "sx")) (EVar "iface")) (EVar "encl")) (EVar "useScope")) (EVar "KeepNone")) (EApp (EApp (EApp (EVar "fromAstType") (EFieldAccess (EVar "sx") "sxModule")) (EVar "subst")) (EVar "arg"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "fromAstType") (EFieldAccess (EVar "sx") "sxModule")) (EVar "subst"))) (EVar "more"))) (EVar "walk"))))
(DTypeSig true "directSuperGoals" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Mono")))))))))
(DFunDef false "directSuperGoals" ((PVar "gctx") (PVar "iface") (PVar "goals")) (EMatch (EApp (EApp (EVar "superLookup") (EVar "gctx")) (EVar "iface")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple (PVar "typarams") (PVar "supers"))) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "sup")) (ETuple (EApp (EVar "superIfaceRef") (EVar "sup")) (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "goals")) (EApp (EVar "listLen") (EVar "typarams"))) (EApp (EApp (EVar "mapAll") (ELam ((PVar "p")) (EApp (EApp (EApp (EVar "lookupPos") (EVar "p")) (EVar "typarams")) (EVar "goals")))) (EApp (EVar "superParamsOf") (EVar "sup"))) (EVar "None"))))) (EVar "supers")))))
(DTypeSig true "superParamsOf" (TyFun (TyCon "Super") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "superParamsOf" ((PRec "Super" ((rf "superParams" (PVar "params"))) true)) (EVar "params"))
(DTypeSig false "determinedEntryAnswers" (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyTuple (TyCon "ImplRow") (TyApp (TyCon "List") (TyCon "Mono"))) (TyCon "Bool")))))
(DFunDef false "determinedEntryAnswers" ((PVar "iface") (PVar "goals") (PTuple (PVar "row") (PVar "committed"))) (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "ieRowOfIface") (EVar "iface")) (EVar "row")) (EBinOp "==" (EApp (EVar "listLen") (EVar "committed")) (EApp (EVar "listLen") (EVar "goals")))) (EApp (EApp (EVar "allList") (ELam ((PVar "pair")) (EApp (EApp (EVar "cohEqMono") (EApp (EVar "fst") (EVar "pair"))) (EApp (EVar "snd") (EVar "pair"))))) (EApp (EApp (EVar "zip") (EVar "committed")) (EVar "goals")))))
(DTypeSig true "goalRows" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "ImplRow"))))))
(DFunDef false "goalRows" ((PVar "mctx") (PVar "iface") (PVar "args")) (EBlock (DoLet false false (PVar "env") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "bodyImplEnvRef") "value")) (DoLet false false (PVar "pool") (EMatch (EApp (EVar "goalHeadCon") (EVar "args")) (arm (PCon "Some" (PVar "hk")) () (EBinOp "++" (EApp (EApp (EVar "ieHeadRows") (EApp (EVar "Some") (EVar "hk"))) (EVar "env")) (EApp (EApp (EVar "ieHeadRows") (EVar "None")) (EVar "env")))) (arm (PCon "None") () (EApp (EVar "ieRowsAll") (EVar "env"))))) (DoExpr (EApp (EApp (EVar "filterList") (EApp (EVar "ieRowOfIface") (EVar "iface"))) (EVar "pool")))))
(DTypeSig true "goalIsProjection" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyCon "Bool"))))
(DFunDef false "goalIsProjection" ((PVar "args") (PVar "rows")) (EApp (EApp (EVar "anyList") (ELam ((PVar "row")) (EBinOp ">" (EApp (EVar "listLen") (EApp (EVar "ieRowTys") (EVar "row"))) (EApp (EVar "listLen") (EVar "args"))))) (EVar "rows")))
(DTypeSig true "goalCandidates" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyApp (TyCon "List") (TyTuple (TyCon "ImplRow") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))))))))))
(DFunDef false "goalCandidates" ((PVar "mctx") (PVar "rigidIds") (PVar "args") (PVar "rows")) (EBlock (DoLet false false (PVar "unifying") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "row")) (EMatch (EApp (EApp (EApp (EApp (EVar "rowPrefixSubstRigid") (EVar "mctx")) (EVar "rigidIds")) (EVar "args")) (EVar "row")) (arm (PCon "Some" (PVar "subst")) () (EListLit (ETuple (EVar "row") (EVar "subst")))) (arm (PCon "None") () (EListLit))))) (EVar "rows"))) (DoExpr (EIf (EApp (EApp (EVar "goalIsProjection") (EVar "args")) (EVar "rows")) (EApp (EApp (EApp (EVar "distinctPrefixes") (EApp (EVar "listLen") (EVar "args"))) (EVar "unifying")) (EListLit)) (EVar "unifying")))))
(DTypeSig false "rowPrefixSubstRigid" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ImplRow") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))))))))
(DFunDef false "rowPrefixSubstRigid" ((PVar "mctx") (PVar "rigidIds") (PVar "args") (PVar "row")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "scratch")) (EUnOp "!" (EVar "scratch")))) (EApp (EApp (EApp (EApp (EVar "headsUnifier") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "rigidIds")) (EVar "args")) (EApp (EApp (EVar "freshRowHeads") (EVar "mctx")) (EVar "row")))))
(DTypeSig false "distinctPrefixes" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "ImplRow") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "ImplRow") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))))) (TyApp (TyCon "List") (TyTuple (TyCon "ImplRow") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono")))))))))
(DFunDef false "distinctPrefixes" (PWild (PList) (PVar "kept")) (EApp (EVar "reverse") (EVar "kept")))
(DFunDef false "distinctPrefixes" ((PVar "k") (PCons (PVar "cand") (PVar "rest")) (PVar "kept")) (EBlock (DoLet false false (PVar "prefix") (EApp (EApp (EVar "take") (EVar "k")) (EApp (EVar "ieRowTys") (EApp (EVar "fst") (EVar "cand"))))) (DoExpr (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "seen")) (EApp (EApp (EVar "tyHeadEqV") (EVar "prefix")) (EApp (EApp (EVar "take") (EVar "k")) (EApp (EVar "ieRowTys") (EApp (EVar "fst") (EVar "seen"))))))) (EVar "kept")) (EApp (EApp (EApp (EVar "distinctPrefixes") (EVar "k")) (EVar "rest")) (EVar "kept")) (EApp (EApp (EApp (EVar "distinctPrefixes") (EVar "k")) (EVar "rest")) (EBinOp "::" (EVar "cand") (EVar "kept")))))))
(DTypeSig true "goalReach" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "ImplRow") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))))) (TyCon "GoalReach")))))
(DFunDef false "goalReach" ((PVar "mctx") PWild (PList)) (EVar "ReachNone"))
(DFunDef false "goalReach" ((PVar "mctx") PWild (PList (PTuple (PVar "row") PWild))) (EApp (EVar "ReachOne") (EVar "row")))
(DFunDef false "goalReach" ((PVar "mctx") (PVar "args") (PVar "cands")) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "cands"))) (DoExpr (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "row")) (EApp (EApp (EApp (EApp (EVar "stableMinimum") (EVar "mctx")) (EVar "args")) (EVar "rows")) (EVar "row")))) (EVar "rows")) (arm (PCons (PVar "row") PWild) () (EApp (EVar "ReachOne") (EVar "row"))) (arm (PList) () (EVar "ReachMany"))))))
(DTypeSig false "stableMinimum" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyCon "ImplRow") (TyCon "Bool"))))))
(DFunDef false "stableMinimum" ((PVar "mctx") (PVar "args") (PVar "rows") (PVar "row")) (EBinOp "&&" (EApp (EApp (EApp (EVar "rowHeadMatches") (EVar "mctx")) (EVar "args")) (EVar "row")) (EApp (EApp (EVar "allList") (ELam ((PVar "other")) (EApp (EApp (EVar "tySubsumesV") (EApp (EVar "ieRowTys") (EVar "other"))) (EApp (EVar "ieRowTys") (EVar "row"))))) (EVar "rows"))))
(DTypeSig true "rowCountsFor" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ImplRow") (TyCon "Bool"))))
(DFunDef false "rowCountsFor" ((PVar "args") (PVar "row")) (EMatch (EApp (EVar "ieRowTys") (EVar "row")) (arm (PCons (PVar "headTy") PWild) () (EBinOp "||" (EApp (EVar "not") (EApp (EVar "tyIsQualified") (EApp (EVar "headTySpineNode") (EVar "headTy")))) (EApp (EVar "goalFirstIsVariable") (EVar "args")))) (arm (PList) () (EVar "False"))))
(DTypeSig false "goalFirstIsVariable" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool")))
(DFunDef false "goalFirstIsVariable" ((PCons (PVar "a") PWild)) (EMatch (EApp (EVar "normalize") (EVar "a")) (arm (PCon "TVar" PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DFunDef false "goalFirstIsVariable" ((PList)) (EVar "False"))
(DTypeSig false "tyIsQualified" (TyFun (TyCon "Ty") (TyCon "Bool")))
(DFunDef false "tyIsQualified" ((PCon "TyEffect" PWild PWild PWild)) (EVar "True"))
(DFunDef false "tyIsQualified" ((PCon "TyConstrained" PWild PWild)) (EVar "True"))
(DFunDef false "tyIsQualified" ((PCon "TyQual" PWild PWild PWild)) (EVar "True"))
(DFunDef false "tyIsQualified" (PWild) (EVar "False"))
(DTypeSig true "freshRowHeads" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ImplRow") (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "freshRowHeads" ((PVar "mctx") (PVar "row")) (EApp (EVar "snd") (EApp (EApp (EVar "freshRowHeadsTvs") (EVar "mctx")) (EVar "row"))))
(DTypeSig true "freshRowHeadsTvs" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ImplRow") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "Mono"))))))
(DFunDef false "freshRowHeadsTvs" ((PVar "mctx") (PVar "row")) (EBlock (DoLet false false (PVar "tys") (EApp (EVar "ieRowTys") (EVar "row"))) (DoLet false false (PVar "tvs") (EApp (EApp (EVar "freshTvMap") (EVar "mctx")) (EApp (EVar "dedup") (EApp (EApp (EDictApp "flatMap") (EVar "tyVarNames")) (EVar "tys"))))) (DoExpr (ETuple (EVar "tvs") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "fromAstType") (EVar "mctx")) (EVar "tvs"))) (EVar "tys"))))))
(DTypeSig true "rowHeadMatches" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "ImplRow") (TyCon "Bool")))))
(DFunDef false "rowHeadMatches" ((PVar "mctx") (PVar "args") (PVar "row")) (EApp (EVar "isSome") (EApp (EApp (EApp (EVar "implHeadSubst") (EVar "mctx")) (EApp (EVar "ieRowTys") (EVar "row"))) (EVar "args"))))
(DTypeSig true "stableGoalReach" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "GoalReach"))))))
(DFunDef false "stableGoalReach" ((PVar "mctx") (PVar "chosen") (PVar "iface") (PVar "args")) (EBlock (DoLet false false (PVar "declared") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "declaredSigVarIds") "value")) (DoLet false false (PVar "rigidIds") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (EVar "intToString")) (EApp (EApp (EVar "filterList") (ELam ((PVar "i")) (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "containsI") (EVar "i")) (EVar "chosen"))) (EApp (EApp (EVar "omHasKey") (EApp (EVar "intToString") (EVar "i"))) (EVar "declared"))))) (EApp (EVar "dedupI") (EApp (EApp (EDictApp "flatMap") (EVar "monoUnboundIds")) (EVar "args")))))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EApp (EVar "goalReach") (EVar "mctx")) (EVar "args")) (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EApp (EVar "rowCountsFor") (EVar "args")) (EApp (EVar "fst") (EVar "c"))))) (EApp (EApp (EApp (EApp (EVar "goalCandidates") (EVar "mctx")) (EVar "rigidIds")) (EVar "args")) (EApp (EApp (EApp (EVar "goalRows") (EVar "mctx")) (EVar "iface")) (EVar "args"))))))))
(DTypeSig true "implMatchesU" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ImplUniverse") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))))
(DFunDef false "implMatchesU" ((PVar "mctx") PWild PWild (PList)) (EVar "False"))
(DFunDef false "implMatchesU" ((PVar "mctx") (PVar "univ") (PVar "iface") (PCons (PVar "a0") (PVar "rest"))) (EBinOp "||" (EApp (EApp (EApp (EVar "bucketArgsMatch") (EVar "mctx")) (EApp (EApp (EApp (EVar "univConcreteBucket") (EVar "univ")) (EVar "iface")) (EApp (EVar "headTyconMono") (EVar "a0")))) (EBinOp "::" (EVar "a0") (EVar "rest"))) (EApp (EApp (EApp (EVar "bucketArgsMatch") (EVar "mctx")) (EApp (EApp (EVar "univHeadless") (EVar "univ")) (EVar "iface"))) (EBinOp "::" (EVar "a0") (EVar "rest")))))
(DTypeSig false "bucketArgsMatch" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require")))) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool")))))
(DFunDef false "bucketArgsMatch" ((PVar "mctx") (PList) PWild) (EVar "False"))
(DFunDef false "bucketArgsMatch" ((PVar "mctx") (PCons (PTuple (PVar "tys") PWild) (PVar "rest")) (PVar "args")) (EBinOp "||" (EApp (EApp (EApp (EVar "implHeadMatchesArgs") (EVar "mctx")) (EVar "tys")) (EVar "args")) (EApp (EApp (EApp (EVar "bucketArgsMatch") (EVar "mctx")) (EVar "rest")) (EVar "args"))))
(DTypeSig true "findMatchingImplReqsU" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "ImplUniverse") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "Require")))))))))
(DFunDef false "findMatchingImplReqsU" ((PVar "sx") (PVar "univ") (PVar "iface") (PList)) (EApp (EApp (EApp (EVar "firstReqMatch") (EFieldAccess (EVar "sx") "sxModule")) (EApp (EApp (EVar "univHeadless") (EVar "univ")) (EVar "iface"))) (EListLit)))
(DFunDef false "findMatchingImplReqsU" ((PVar "sx") (PVar "univ") (PVar "iface") (PCons (PVar "a0") (PVar "rest"))) (EMatch (EApp (EApp (EApp (EVar "concreteReqMatchByIface") (EVar "sx")) (EVar "iface")) (EBinOp "::" (EVar "a0") (EVar "rest"))) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "Some") (EVar "r"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "firstReqMatch") (EFieldAccess (EVar "sx") "sxModule")) (EApp (EApp (EVar "univHeadless") (EVar "univ")) (EVar "iface"))) (EBinOp "::" (EVar "a0") (EVar "rest"))))))
(DTypeSig false "concreteReqMatchByIface" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "Require"))))))))
(DFunDef false "concreteReqMatchByIface" ((PVar "sx") (PVar "iface") (PVar "args")) (EMatch (EApp (EApp (EApp (EApp (EVar "ieSelectRowByIface") (EVar "sx")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "bodyImplEnvRef") "value")) (EVar "iface")) (EVar "args")) (arm (PCon "Some" (PVar "row")) () (EApp (EApp (EApp (EVar "selectedRowReqMatch") (EFieldAccess (EVar "sx") "sxModule")) (EVar "args")) (EVar "row"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "firstReqMatch" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require")))) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "Require"))))))))
(DFunDef false "firstReqMatch" ((PVar "mctx") (PList) PWild) (EVar "None"))
(DFunDef false "firstReqMatch" ((PVar "mctx") (PCons (PTuple (PVar "tys") (PVar "reqs")) (PVar "rest")) (PVar "args")) (EMatch (EApp (EApp (EApp (EVar "implHeadSubst") (EVar "mctx")) (EVar "tys")) (EVar "args")) (arm (PCon "Some" (PVar "sub")) () (EApp (EVar "Some") (ETuple (EMethodRef "sub") (EVar "reqs")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "firstReqMatch") (EVar "mctx")) (EVar "rest")) (EVar "args")))))
(DTypeSig true "univConcreteBucket" (TyFun (TyCon "ImplUniverse") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "Option") (TyCon "HeadKey")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require"))))))))
(DFunDef false "univConcreteBucket" ((PCon "ImplUniverse" (PVar "conc") PWild) (PVar "iface") (PCon "Some" (PVar "hk"))) (EApp (EApp (EVar "mregLookupK") (EApp (EVar "regKeyNTab") (EListLit (EApp (EVar "oblIfaceKey") (EVar "iface")) (EApp (EVar "dispHeadTab") (EVar "hk"))))) (EVar "conc")))
(DFunDef false "univConcreteBucket" (PWild PWild (PCon "None")) (EListLit))
(DTypeSig true "univHeadless" (TyFun (TyCon "ImplUniverse") (TyFun (TyCon "IfaceRef") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require")))))))
(DFunDef false "univHeadless" ((PCon "ImplUniverse" PWild (PVar "hl")) (PVar "iface")) (EApp (EApp (EVar "mregLookupK") (EApp (EVar "regKeyOfTab") (EApp (EVar "oblIfaceKey") (EVar "iface")))) (EVar "hl")))
(DTypeSig true "implMatchesWithReqsU" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ImplUniverse") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))))
(DFunDef false "implMatchesWithReqsU" ((PVar "mctx") PWild PWild (PList)) (EVar "False"))
(DFunDef false "implMatchesWithReqsU" ((PVar "mctx") (PVar "univ") (PVar "iface") (PCons (PVar "a0") (PVar "rest"))) (EBinOp "||" (EApp (EApp (EApp (EVar "bucketArgsMatchReqs") (EVar "mctx")) (EApp (EApp (EApp (EVar "univConcreteBucket") (EVar "univ")) (EVar "iface")) (EApp (EVar "headTyconMono") (EVar "a0")))) (EBinOp "::" (EVar "a0") (EVar "rest"))) (EApp (EApp (EApp (EVar "bucketArgsMatchReqs") (EVar "mctx")) (EApp (EApp (EVar "univHeadless") (EVar "univ")) (EVar "iface"))) (EBinOp "::" (EVar "a0") (EVar "rest")))))
(DTypeSig false "bucketArgsMatchReqs" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require")))) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool")))))
(DFunDef false "bucketArgsMatchReqs" ((PVar "mctx") (PList) PWild) (EVar "False"))
(DFunDef false "bucketArgsMatchReqs" ((PVar "mctx") (PCons (PTuple (PVar "tys") (PVar "reqs")) (PVar "rest")) (PVar "args")) (EBinOp "||" (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "reqs")) (EApp (EApp (EApp (EVar "implHeadMatchesArgs") (EVar "mctx")) (EVar "tys")) (EVar "args"))) (EApp (EApp (EApp (EVar "bucketArgsMatchReqs") (EVar "mctx")) (EVar "rest")) (EVar "args"))))
(DTypeSig false "implHeadMatchesArgs" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool")))))
(DFunDef false "implHeadMatchesArgs" ((PVar "mctx") (PVar "tys") (PVar "args")) (EApp (EVar "isSome") (EApp (EApp (EApp (EVar "implHeadSubst") (EVar "mctx")) (EVar "tys")) (EVar "args"))))
