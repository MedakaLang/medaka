# META
source_lines=2295
stages=DESUGAR,MARK
# SOURCE
-- tc_shadow: standalone-vs-method shadow resolution (S1-S9) outside the inference recursion,
-- including the recorded-local site resolution `resolveRLocalSite` (SHADOW S2's inversion at route
-- time), the admitted-set occurrence checks (S2-DECL (d)), and the mark sets a module may name
-- (`methodMarkCtx`: S1-NS nameability; its module-level wrapper `moduleMarkCtx`).
--
-- Spec: SHADOW-SEMANTICS section 1 S1-S9, section 1.1; S2-DECL (d).
--
-- Placement: declarations are placed by R1-R6 of the Phase 4 module table,
-- compiler/ARCHITECTURE-PLAYBOOK.md section 6.
-- Closure rule: this module may not import `types.typecheck`, nor any of `tc_effects`,
-- `tc_occurrence`, `tc_groups`, `tc_pat`, `tc_infer_records`, `tc_infer`, `tc_elab`, `tc_global`,
-- `tc_module`.

import support.diag_codes.{DiagCode(..)}
import types.tc_types.{
  StandaloneOrigin(..),
  CDeclaredPrefix(..),
  AdmittedAnswer(..),
  AdmittedVerdict(..),
  BareLocals(..),
  CDeclared(..),
  DynCtx(..),
  ShadowDicts(..),
  SpellCtx(..),
  TcEnv(..),
  CSlot,
  DriveOutputs,
  EvCell,
  GraphCtx,
  ImplEnv,
  MethodTrackedInstantiation,
  ModuleCtx,
  SiteCtx,
  siteFor,
  ValueScheme,
  MarkCtx(..),
  MarkSets,
}
import types.tc_mono.{
  headMonoNode,
  headTyconMono,
  monoIsTyvarId,
  nthFunDomain,
  nthMono,
  substMono,
  tyvarId,
}
import types.tc_diag_text.{ambiguousShadowHelp, shadowIfaceLabel}
import types.tc_state.{dynAt, emptyShadowDicts}
import types.tc_env.{
  declTopFnNames,
  depExportsStandalone,
  depExportsUnknown,
  funDefs,
  graphPubDefiners,
  ieImplExistsForHeadOf,
  ifaceExportsIndex,
  ifaceMethodRows,
  importedBindings,
  lookupIdxById,
  lookupStandaloneValue,
  lookupStandaloneVar,
  lookupVar,
  methodRowIface,
  namesToSet,
  removeAllS,
  standaloneValueFor,
  hasImportDefiner,
  lookupImportedStandalone,
  allIfaceMethodNames,
}
import types.tc_diag.{pushTypeErrorAt, pushTypeErrorHelpFixAt}
import types.tc_scope.{
  ieImplExistsForHead,
  ifaceSortKey,
  methodAdmittedHere,
  methodDispatchIdx,
  methodEntryHere,
  methodVisibleHere,
  importedIfaceRows,
  aliasMethodSpellings,
  withAliasMethodNames,
}
import types.tc_unify.{
  clampPrefix,
  instantiate,
  instantiateMethodTracked,
  predicateSlotArgs,
  predicateSlotCSlots,
  qualConstraintDecl,
  unifyIn,
  unifySpineProbe,
  zipSlotVecs,
}
import types.tc_decls.{sigToScheme}
import types.tc_solve_givens.{lookupPredicateSlots}
import types.tc_solve.{admittedSelection, routeLocalSym, routesOfMonosTopV}
import types.tc_solve_check.{dedupSlotVecs, ifaceSelfAndSupers}
import frontend.ast.{
  Constraint(..),
  Decl(..),
  EffAtomTy(..),
  EvId(..),
  Expr(..),
  IfaceMethod(..),
  Loc(..),
  Route(..),
  Ty(..),
  UseMember(..),
  UsePath(..),
  effAtomSurface,
}
import types.repr.{
  IfaceRef(..), Mono(..), Scheme(..), lookupAssocI, normalize, ppMono, ppTy
}
import types.evidence_complete.{Inner(..)}
import support.ordmap.{
  omEmpty, omFromNames, omHasKey, omKeys, omLookup, omSize, OrdMap
}
import types.evidence.{ScopeId(..)}
import support.util.{
  allList,
  anyList,
  contains,
  dedup,
  escStr,
  filterList,
  isEmptyL,
  isNonEmptyL,
  isSome,
  joinWith,
  listLen,
  lookupAssoc,
  maxI,
  reverseL,
  startsWith,
}
import list.{head}
import frontend.marker.{localBoundNames}
import types.private_mangle.{mangledName}
import frontend.visibility.{useModId}
import map as IdMap
import types.tc_foreign.{declExternNames}

-- ── #2809: the seed's ROUTE half and its TYPING half are different questions ──
-- `routeLocalSym` (in `tc_solve`) is the ROUTE half: the symbol the emitter must call, which
-- `mangleRoute` renames once mangling runs.  Every reader below that instead asked
-- "is this occurrence a standalone shadow whose bare name no longer denotes the
-- standalone?" used a non-empty `routeLocalSym` as its answer, and that reading was
-- sound only while the seed was `<mid>__name` — a spelling that existed on the emit
-- path and nowhere else.  With mangling moved after elaboration the seed is the BARE
-- standalone name on EVERY path, so a seed equal to the occurrence's own method name
-- recovers nothing: the un-mangled classifiers (`definerShadowNamesRef`,
-- the standalone scheme carried by the env binding) already answer it, and reading
-- it as the old signal changed what `check` reports — measured on
-- `test/run_check_agreement_fixtures/s1_constrained_shadow_dispatch.mdk`, whose
-- specified `No impl of Num for Box` (clause S9's reject direction, named in the
-- fixture's own header) became `Type mismatch: Int literal vs Box` because the
-- standalone-domain enforcement below is gated on this test.
-- So: this is the RECOVERED-SYMBOL half — "" whenever the seed is just the bare name —
-- and every TYPING decision keys on it, while the route stamp keeps `routeLocalSym`.
export
recoveredShadowSym : String -> Ref Route -> String
recoveredShadowSym name tagRef =
  let s = routeLocalSym !tagRef
  if s == name then "" else s

-- The cells minted for [ev].  A miss is a bug in this file (every `EMethodAt` is
-- minted through `mintMethodCell`), so it panics rather than answering unrouted.
export
methodCellOf : GraphCtx -> EvId -> EvCell
methodCellOf gctx ev = match methodCellLookup gctx ev
  Ok c => c
  Err message => panic message

-- `methodCellOf`'s answer, or the reason it has none.
export
methodCellLookup : GraphCtx -> EvId -> Result String EvCell
methodCellLookup gctx (EvId m n) =
  let g = gctx.graphRun
  let i = n - g.evBase
  let arr = g.evCells.value
  if i < 0 then
    Err "method cell \{m}#\{intToString n} is from an earlier graph"
  else if i >= arrayLength arr then
    Err "method cell \{m}#\{intToString n} was never minted"
  else match arrayGetUnsafe i arr
    Some c => Ok c
    None => Err "method cell \{m}#\{intToString n} was never minted"

-- Slot projection below applies the type substitution after superclass expansion;
-- effect-index arguments use the same occurrence's row substitution here.
export
declaredEffectsAt : GraphCtx ->
  MethodTrackedInstantiation ->
  Option CDeclared ->
  Option CDeclared
declaredEffectsAt gctx inst declared =
  map
    (dc => CDeclared {
      cdSlots = dc.cdSlots,
      cdPrefix = dc.cdPrefix,
      cdArgs =
        map
          (map
            (substMono
              gctx
              []
              inst.mtiSubstitution.misEffectSubst
              inst.mtiSubstitution.misAuthSubst))
          dc.cdArgs,
    })
    declared

-- WS-2/D2 + B-2.2-f (#1113): the slots-only projection `declaredConstraintSlots` is
-- RETIRED.  It had exactly two readers — `inferDictAtFound` and the shadow route — and
-- FIX-shadow-arity-skew is what a slots-only projection costs: slice 3 widened what
-- `cdSlots` is keyed by (whole predicate, vector included), the call sides that had a
-- vector agreed with the widened definition side, and the one reader still taking the
-- bare-slots projection expanded against a constant `[]` and collapsed two slots into
-- one.  Take `declaredConstraintFor` and project BOTH halves off the one entry decision,
-- or you are re-opening this bug by construction.  (The same argument that removed
-- `declaredConstraintK`: two readers re-deriving which entry a name resolves to is the
-- drift `qualConstraintKey` was factored out to remove.)
--
-- B-2.2-f (#1113): the ONE resolution — a constrained callee's declared dict slots AND
-- how many of them its own `=>` context declared (the rest being super slots
-- `expandSupersPairs` appends downstream).  Arms mirror the retired `declaredConstraintSlots`'
-- former body exactly, keyed once through `qualConstraintKey`.
--
-- The prefix is CLAMPED against the slots actually returned (`clampPrefix`).
-- `pairSlots` truncates to the shorter of (ids, ifaces), a mismatch this seam can
-- manufacture by construction (see `CSlot`), and an unclamped `index < k` past the end
-- of a truncated list marks APPENDED slots declared — the unsafe direction.  UNWITNESSED
-- (instrumented over a full compiler build and a two-module probe; it never fired), so
-- the clamp is defensive, not measured — it is one token and it fails closed.
--
-- The qual arm is `qualConstraintDecl`, shared with `qualConstraintFor` and
-- `declaredCrossModuleObls`.  A qual KEY hit whose ids payload MISSES, and no qual key at
-- all with the name still an import, are one case, the `hasImportDefiner` test below: a
-- `qualConstraintKey` hit IS a `currentImportDefinersRef` hit (same ref, same lookup), and
-- both yield the empty `CDeclared`.
export
declaredConstraintFor : ModuleCtx -> String -> CDeclared
declaredConstraintFor mctx name = match qualConstraintDecl mctx name
  Some d => d
  -- #739: source-exact fallback.  An EXPLICITLY-imported name (present in
  -- currentImportDefinersRef) whose (import-source, name) qual entry is ABSENT is
  -- genuinely UNCONSTRAINED in its source module — every module's constrained fns ARE
  -- attributed into crossModuleFunConstraintsQualRef when it is processed, so a MISS for a
  -- known import means "no constraint", not "look elsewhere".  Do NOT fall back to the
  -- bare-name funConstraintsRef here: on the emit path that table is JOINTLY seeded across
  -- every module (aliasConstraintEntries), so a DIFFERENT module's same-named CONSTRAINED
  -- fn (`p.f : Display a => …`) would be misattributed to this unconstrained callee
  -- (`q.f`), and per-module tyvarCounter reset makes its constraint id collide with a fresh
  -- instantiation var → the call site records a phantom `Display Z` obligation and
  -- run/build OVER-REJECT a valid program (#739).  Mirrors the check-path
  -- declaredCrossModuleObls source-exact discipline (#673/#738).  Only local / wildcard /
  -- re-export / check-path (mid "") names — absent from currentImportDefinersRef — still
  -- take the bare-name path (byte-identical when there is no collision).
  None =>
    if hasImportDefiner mctx name then
      CDeclared { cdSlots = [], cdPrefix = CDPLen 0, cdArgs = [] }
    else
      localDeclaredConstraintFor mctx name

-- the LOCAL / wildcard / re-export / check-path arm of `declaredConstraintFor`, named so
-- that a reader who has ALREADY established the binding is this module's own can take it
-- directly instead of re-entering the import-keyed dispatch above.  The one such reader
-- is `shadowDeclaredFor` (a definer shadow's own standalone), whose bare name is in
-- `currentImportDefinersRef` by construction and so cannot reach this arm through
-- `declaredConstraintFor`.
--
-- The vector table is `funPredicateSlotsRef`, projected by `predicateSlotArgs` — the same
-- lookup `enclPreds` uses for the ENCLOSING fn.  Both halves come off ONE `stored`
-- resolution, which is the invariant `declaredConstraintFor`'s own header states.
localDeclaredConstraintFor : ModuleCtx -> String -> CDeclared
localDeclaredConstraintFor mctx name =
  let stored =
    optionOr
      []
      (lookupPredicateSlots name mctx.mcCells.funPredicateSlotsIdxRef.value)
  let slots = predicateSlotCSlots stored
  CDeclared {
    cdSlots = slots,
    cdPrefix =
      clampPrefix
        slots
        (lookupAssoc name mctx.mcCells.funConstraintDeclaredRef.value),
    cdArgs = predicateSlotArgs stored,
  }

-- Slot-parallel to constraintMonosOf's OUTPUT, and it must stay that way: it walks the
-- SAME slot list against the SAME [subst] and applies the SAME drop rule (an id absent
-- from the instantiation is skipped on both sides), so slot i of the result describes
-- slot i of [monos].
-- S-dict-arity-contract: each slot now arrives PAIRED with its own vector — the stored
-- signature vector of the declared slot.  A slot whose vector is empty — an
-- inferred/promoted fn — still yields the singleton `[m]`, the scalar
-- goal `routesOfMonosTop` already used.  A CROSS-module callee is no longer in that
-- LIST: S-xmod-vector-supply (#1868/#1867) gave it a real vector — see the `cdArgs`
-- arms of `declaredConstraintFor` (`grep -n 'cdArgs = predicateSlotArgs'`).
export
callArgVecsV : GraphCtx ->
  List (CSlot, List Mono) ->
  List (Int, Mono) ->
  List (List Mono)
callArgVecsV gctx [] _ = []
callArgVecsV gctx ((s, v) :: rest) subst = match lookupAssocI s.csId subst
  Some m => substArgVec gctx subst m v :: callArgVecsV gctx rest subst
  None => callArgVecsV gctx rest subst

-- STRUCTURAL, not top-level-only.  The stored vector is in the SIGNATURE's
-- instantiation vars; the call's [subst] maps the scheme's quantified ids to THIS
-- call's monos.  A vector argument like `List b` therefore has to have its INTERIOR
-- tyvar rewritten too, which is what `substMono` does and a top-level id lookup does
-- not: leave `List b` as a stale signature var and `matchTyMonos` fails against every
-- `impl Ix Int (List Char)`-shaped head, the candidate set comes back EMPTY, and the
-- route silently degrades to the bare head tag — i.e. first-declared-wins, the very bug
-- this closes, at a different shape.  F-3c cannot catch that class either:
-- `pickMostSpecificEntry []` returns None, not the ambiguity arm.  Regression:
-- test/dict_fixtures/s3-nary-sig-constraint-structured-arg.mdk, graded on its
-- value by diff_compiler_dict_semantics_test.mdk and on its order-freedom by
-- diff_compiler_dict_semantics_permute.sh (no _swapped file needed).
substArgVec : GraphCtx -> List (Int, Mono) -> Mono -> List Mono -> List Mono
substArgVec gctx _ m [] = [m]
substArgVec gctx subst _ v = map (substMono gctx subst [] []) v

export
constraintMonosOf : List Int -> List (Int, Mono) -> List Mono
constraintMonosOf [] _ = []
constraintMonosOf (id :: rest) subst = match lookupAssocI id subst
  Some m => m :: constraintMonosOf rest subst
  None => constraintMonosOf rest subst

export
checkAdmittedOccObls : ModuleCtx -> Unit -> Unit
checkAdmittedOccObls mctx _ =
  let env = mctx.mcCells.bodyImplEnvRef.value
  each
    (o => checkAdmittedOccObl mctx env o)
    (reverseL mctx.mcCells.admittedOccObls.value)

checkAdmittedOccObl : ModuleCtx -> ImplEnv -> (String, Mono, Option Loc) -> Unit
checkAdmittedOccObl mctx env (name, mono, loc) =
  let ifs = methodAdmittedHere mctx name
  match admittedSelection (siteFor mctx) env name mono
    Selects _ _ _ => ()
    Undecided => pushAmbiguousMethod mctx name ifs loc
    Unroutable sel => pushUnroutableAdmitted mctx name ifs sel loc
    SelectsNothing =>
      let recv = match admittedReceiverMono mctx name ifs mono
        Some at => ppMono at
        None => "this receiver"
      pushTypeErrorAt
        mctx
        TNoImpl
        loc
        "no impl of \{joinWith " or " (map (ir => ir.irName) ifs)} for \{recv}; write an impl of one of them for it"

-- The receiver named in the no-impl reject: the first admitted declaration's own
-- receiver argument.
admittedReceiverMono : ModuleCtx ->
  String ->
  List IfaceRef ->
  Mono ->
  Option Mono
admittedReceiverMono mctx _ [] _ = None
admittedReceiverMono mctx name (ir :: _) mono = do
  k <- lookupIdxById ir name mctx.mcCells.methodDispatchIdxByIdRef.value
  nthFunDomain k mono

-- ── #1815: application spines ───────────────────────────────────────────────
-- The ultimate head of an application spine, ELoc wrappers peeled.  A non-application
-- expression is its own head (so `appSpineNodes` below answers [] for it, which is what
-- makes every spine-keyed predicate decline at dispatch index 0 and leave the existing
-- bare-head paths byte-unchanged).
appSpineHead : Expr -> Expr
appSpineHead (ELoc _ e) = appSpineHead e
appSpineHead (EApp f _) = appSpineHead f
appSpineHead e = e

-- The `EApp` nodes of a spine in APPLICATION ORDER — node i is the one supplying
-- argument i.  ELoc wrappers are peeled off the nodes themselves (the argument keeps
-- its own, which is what `appArgLoc` reads for the error span).
appSpineNodes : Expr -> List Expr
appSpineNodes e = appSpineNodesGo e []

-- Walks from the outermost node inward, prepending, so the list comes out in
-- application order with no reverse.
appSpineNodesGo : Expr -> List Expr -> List Expr
appSpineNodesGo (ELoc _ e) acc = appSpineNodesGo e acc
appSpineNodesGo (EApp f x) acc = appSpineNodesGo f (EApp f x :: acc)
appSpineNodesGo _ acc = acc

export
plainAppHeadVar : TcEnv -> Expr -> Bool
plainAppHeadVar env hd = match shadowStandaloneHead env hd
  Some _ => False
  None => match definerShadowArgHead env.teDyn.dcModule hd
    Some _ => False
    None => match definerShadowVarHead env.teDyn.dcModule hd
      Some _ => False
      None => True

-- Bug C: peel a single-argument application's
-- head to a standalone-shadow interface-method reference (`size b` where `size`
-- is BOTH a `Sizeable` method AND an imported standalone —
-- `test/shadow_fixtures/i7_importer_value_pos_liveimpl/`).  Handles BOTH the
-- MARKED form (`EMethodAt`, the eval/build path — carries a route ref to stamp RLocal)
-- and the UNMARKED form (`EVar`, the `check` path — no route ref; the empty list).
-- Only fires for a SINGLE-param interface method whose name is a registered importer
-- shadow with a stashed standalone scheme — exactly the oracle's guard.  Everything
-- else (no shadow, multi-param iface, non-method head) returns None → the ordinary path.
export
shadowStandaloneHead : TcEnv ->
  Expr ->
  Option (String, List (Ref (Option Int)), List (Ref Route, Ref Inner))
shadowStandaloneHead env (ELoc _ f) = shadowStandaloneHead env f
shadowStandaloneHead env (EMethodAt name _ ev)
  | isShadowStandalone env name =
    let c = methodCellOf env.teDyn.dcModule.mcGraph ev
    Some (name, [c.ecArity], [(c.ecTag, c.ecInner)])
  | otherwise = None
shadowStandaloneHead env (EVar name)
  | isShadowStandalone env name = Some (name, [], [])
  | otherwise = None
shadowStandaloneHead env (EVarId name _)
  | isShadowStandalone env name = Some (name, [], [])
  | otherwise = None
shadowStandaloneHead env _ = None

-- #2154: the IMPORTER-side spine arm — the peer of definerShadowSpineArgAt /
-- definerShadowSpineVarAt for an imported standalone shadowing a method whose
-- interface dispatches at argument k > 0.  Peels the spine's ultimate head with the
-- SAME test shadowStandaloneHead already applies to a bare head (so a marked
-- EMethodAt receiver and an unmarked EVar/EVarId receiver both fire, exactly as
-- shadowStandaloneHead's own two arms do), then gates on `shadowSpineNodesAt`, which
-- declines (`None`) for a bare head (k == 0, nodes == []) — the existing
-- shadowStandaloneHead / inferShadowApp path stays byte-identical.
export
shadowStandaloneSpineHeadAt : TcEnv ->
  Expr ->
  Option (String, List (Ref (Option Int)), List (Ref Route, Ref Inner), Expr, List Expr)
shadowStandaloneSpineHeadAt env f =
  match shadowStandaloneHead env (appSpineHead f)
    None => None
    Some (name, arityRefs, tagRefs) =>
      map
        (nodes => (name, arityRefs, tagRefs, appSpineHead f, nodes))
        (shadowSpineNodesAtImporter env.teDyn.dcModule name f)

-- a name that is BOTH a registered importer shadow (standaloneValuesRef), has a
-- stashed standalone scheme, and names a single-TYPARAM interface's method.
--
-- IMPORTER side ⇒ singleTyparamIfaceMethod, NOT ifaceMethodName (#54).  Fork 1 keeps
-- the per-receiver rule here, and that rule keys the impl query on the receiver's head
-- tycon standing at the interface's ONE typaram.  A multi-typaram interface has no such
-- correspondence to key on -- `FromEntries c e`'s `fromEntries : List e -> c` does not
-- even take its first typaram as an argument -- so the importer arms stay scoped to the
-- single-typaram case.  The DEFINER arms do not: under the S2 inversion they never query
-- the impl universe at all, so they are typaram-agnostic (ifaceMethodName).
export
isShadowStandalone : TcEnv -> String -> Bool
isShadowStandalone env name =
  omHasKey name env.teDyn.dcModule.mcCells.standaloneValuesRef.value
    && isSome (lookupImportedStandalone env name)
    && singleTyparamIfaceMethod env.teDyn.dcModule name

-- True iff [name]'s interface (in methodEntryHere) takes exactly ONE type
-- parameter -- the receiver-directed case the per-receiver IMPORTER rule (Fork 1) is
-- scoped to.  When two or more declarations are admitted it answers over the whole
-- set (every admitted interface takes one), never by the absence of a single winner:
-- `False` would skip the importer route and with it S2-DECL (d)'s cardinality
-- decision (`importerAdmittedVerdict`).
--
-- It counts interface TYPE PARAMS, not method params (SHADOW-SEMANTICS.md S8, #54): a
-- two-PARAM method of a one-typaram interface (`comb : a -> a -> Int`, cell d7) passes.
singleTyparamIfaceMethod : ModuleCtx -> String -> Bool
singleTyparamIfaceMethod mctx name = match methodEntryHere mctx name
  Some (_, typarams, _, _) => listLen typarams == 1
  None => match methodAdmittedHere mctx name
    [] => False
    ifs =>
      allList
        (r => match r.mrEntry
          (_, typarams, _, _) => listLen typarams == 1)
        (filterList
          (r =>
            let key = ifaceSortKey (methodRowIface r)
            anyList (ir => ifaceSortKey ir == key) ifs)
          (methodVisibleHere mctx name))

-- True iff [name] is a method of SOME visible interface, whatever its typaram arity --
-- the DEFINER-side gate (#54, closing S-3 / SHADOW-SEMANTICS.md row 26).
--
-- Under the S2 inversion a definer shadow denotes its module's own standalone
-- unconditionally: the impl universe is never consulted, so there is no receiver-to-
-- typaram correspondence to require, and gating the definer entry points on the typaram
-- COUNT only excused `interface Ix a i` from the machinery.  That excusal was the S-3
-- bug: d11 typed+emitted per-receiver (the OLD, pre-inversion semantics) while eval, which
-- has no route stamp to follow, resolved the bare name lexically to the standalone and
-- E-PANICked `unknown op '*'` on a `Box` -- an S7 path-agreement violation.
-- Two or more admitted declarations are each a method of a visible interface, so the
-- admitted set answers True as well.
ifaceMethodName : ModuleCtx -> String -> Bool
ifaceMethodName mctx name =
  isSome (methodEntryHere mctx name)
    || isNonEmptyL (methodAdmittedHere mctx name)

-- stamp every route ref (one for the marked EMethodAt form, none for the unmarked
-- check-path EVar form) RLocal.  S-1: the standalone's own constraint dicts are NOT
-- resolvable here (inference has not solved the receiver yet) — the caller ALSO pushes
-- an RLocalSite so resolveRLocalSites re-stamps the same ref with the filled dicts
-- post-inference.  An unconstrained standalone never gets a second stamp that differs.
export
stampRoutes : List (Ref Route) -> Unit
stampRoutes [] = ()
stampRoutes (r :: rest) =
  r := RLocal (routeLocalSym !r) []
  stampRoutes rest

export
stampMethodArities : List (Ref (Option Int)) -> Int -> Unit
stampMethodArities [] _ = ()
stampMethodArities (r :: rest) arity =
  r := Some arity
  stampMethodArities rest arity

-- [env] for typing a shadow occurrence that heads its own application.
export
shadowHeadEnv : TcEnv -> TcEnv
shadowHeadEnv env = { env | teDyn = { env.teDyn | dcShadowHeadCtx = True } }

-- S1-RESIDUAL-B: the IMPORTED standalone's declared domain — the first arrow domain of the
-- scheme retained by the lexical binding descriptor. The importer peer of
-- shadowDomainFor's mangled arm, and it must NOT
-- be `lookupVar env mname`: env1 rebound the bare name to the interface METHOD, which is the
-- very scheme whose higher-kinded domain caused the bug.
--
-- None (⇒ grounding is a no-op) when the name has no stashed standalone scheme, or when that
-- standalone's own first parameter is itself polymorphic (`f : a -> Bool`) — unifying a bare
-- tyvar domain with an ungrounded receiver leaves it ungrounded anyway, so the caller's
-- headTyconMono still says None and the old ordinary-app arm runs, byte-identically.
export
importerShadowDomain : TcEnv -> String -> Option Mono
importerShadowDomain env mname = match lookupStandaloneVar env mname
  None => None
  Some s => match normalize (instantiate env.teDyn.dcModule s)
    TFun a _ _ => Some a
    _ => None

-- #2154: as importerShadowDomain, but the standalone's k-th declared parameter — the
-- one the receiver occupies when the interface dispatches at argument k > 0.  Peer of
-- shadowDomainForAt / standaloneShadowDomainAt (#1815).  `k = 0` is importerShadowDomain
-- verbatim (nthFunDomain 0 on a TFun matches its first arm exactly).
export
importerShadowDomainAt : TcEnv -> String -> Int -> Option Mono
importerShadowDomainAt env mname k = match lookupStandaloneVar env mname
  None => None
  Some s => nthFunDomain k (instantiate env.teDyn.dcModule s)

-- P0-18: peel a single-argument application's head to a DEFINER-shadow interface-
-- method occurrence (the user's OWN top-level fn reuses a single-param interface
-- method name, e.g. this module's `size : Int -> Int` shadowing `Sizeable`'s
-- `size`).  Unlike importer shadows (shadowStandaloneHead / inferShadowApp), the
-- user's definition SHADOWS the method in scope, so the occurrence is typed against
-- the standalone scheme whose declared domain (`Int`) is NOT the actual receiver.
-- Returning the route ref lets inferDefinerShadowApp record the REAL argument mono
-- for per-receiver routing (`Box` has a `Sizeable` impl → method; `Int` → standalone).
-- P0-18 (importer residual): on the EMIT path a definer shadow's bare name is NOT
-- in definerShadowNamesRef when the standalone is IMPORTED from another module (that
-- ref is keyed on module-local funDefs).  But the mark pass ALREADY seeded such an
-- occurrence's route with the mangled standalone symbol (`RLocal <sym>`), so a
-- non-empty route symbol is an equally-good "this is a shadow" signal that works
-- cross-module.  Firing here routes the occurrence through inferDefinerShadowApp,
-- which types it against the standalone scheme and records the per-receiver mono —
-- so an importer shadow on a live-impl receiver dispatches to the impl, and one on a
-- no-impl receiver falls back to the standalone (RLocal <sym>), exactly like a
-- definer shadow.  On the un-mangled run/check path the route is RNone (sym ""), so
-- this branch is inert there and the ordinary definerShadowNames branch governs.
export
definerShadowArgHead : ModuleCtx ->
  Expr ->
  Option (String, Ref (Option Int), Ref Route, Ref (List Route), Ref Inner)
definerShadowArgHead mctx (ELoc _ f) = definerShadowArgHead mctx f
-- #54: the two disjuncts carry DIFFERENT gates, because they serve different shadow
-- KINDS — this predicate is a Fork-1 boundary, not an arity test.  `isDefinerShadow` is
-- typaram-agnostic; `importerShadowOnEmitPath` is scoped to single-typaram interfaces (see
-- its header).  Spelling the definer disjunct as `isDefinerShadow` — rather than inlining
-- its conjuncts here — is deliberate: that function is ALSO what resolveRLocalSite routes
-- on, and "the typing entry point and the route stamper must apply the same gate" is the
-- P0-20 invariant.  Sharing the symbol makes them impossible to drift.
definerShadowArgHead mctx (EMethodAt name _ ev) =
  definerShadowArgHeadCell mctx name (methodCellOf mctx.mcGraph ev)
definerShadowArgHead mctx _ = None

definerShadowArgHeadCell : ModuleCtx ->
  String ->
  EvCell ->
  Option (String, Ref (Option Int), Ref Route, Ref (List Route), Ref Inner)
definerShadowArgHeadCell mctx name c
  | isDefinerShadow mctx name
    || importerShadowOnEmitPath mctx name c.ecTag =
    Some (name, c.ecArity, c.ecTag, c.ecImpl, c.ecInner)
  | otherwise = None

-- L4 (xmod-identity #1351 spine, RUN-XMOD-022/026): the mark pass's own per-occurrence
-- verdict, named rather than left as an anonymous `routeLocalSym … /= ""` idiom.
-- `rewriteArgScoped`'s `sm` arm is the SOLE origin of a non-empty RLocal symbol on an
-- EMethodAt route (F8); every other RLocal stamp propagates that origin symbol
-- unchanged.  This is NOT a graph-wide fact and is NOT interchangeable with one: "The
-- signal is PER-OCCURRENCE, not graph-wide … keying on it (not on the whole-graph
-- standaloneValuesRef) is what keeps this from pinning the compiler's genuine
-- method-values and breaking dispatch" (this file, historically beside this site).
-- #2809: the seed is the BARE standalone name on every path now, so "non-empty" no
-- longer says "the mangler moved the name" — `recoveredShadowSym` is what does.
occurrenceCarriesMangledShadowSym : String -> Ref Route -> Bool
occurrenceCarriesMangledShadowSym name tagRef =
  recoveredShadowSym name tagRef /= ""

-- #54: the SECOND disjunct of definerShadowArgHead — the IMPORTER-on-emit signal, kept
-- separate because it carries a DIFFERENT gate from the definer one.  The mark pass seeds
-- an importer shadow's route with the provider's mangled standalone symbol, so a non-empty
-- route symbol says "this is a shadow" cross-module, where definerShadowNamesRef (keyed on
-- module-local funDefs) cannot.  It stays scoped to singleTyparamIfaceMethod because what
-- it feeds is Fork 1's per-receiver rule; the definer disjunct (isDefinerShadow) does not,
-- because the S2 inversion never queries the impl universe.  On the un-mangled run/check
-- path the route is RNone (sym ""), so this is inert there.
--
-- L4: this predicate now names its two conjuncts separately instead of conflating them in
-- one `routeLocalSym … /= ""` test.  `gctx.mangledFunDefsPresentRef.value`
-- (L3) is the GRAPH-level fact "this compile's decls carry mangled funDefs at all";
-- `occurrenceCarriesMangledShadowSym tagRef` is the mark pass's own PER-OCCURRENCE verdict
-- for THIS route.  The new graph-level conjunct is ADDED, not substituted for the
-- occurrence test — F7 (this file) forbids replacing the per-occurrence route test with a
-- graph-wide one: doing so would fire for occurrences the mark pass never marked, and
-- would pin genuine method-values, breaking dispatch.
--
-- `mangledFunDefsPresentRef` is constant TRUE on every emit path, unconditionally (see
-- `graphCarriesMangledFunDefs`'s header for the mechanism: `private_mangle.mdk:14-16`
-- mangles core's own funDefs before the flag is computed, so a feature-free build's IR
-- carries about 70 `@mdk_<mid>__*` symbols with zero shadows).  A narrowing test would
-- need the flag to be False on some occurrence's compile, and on the emit path it never
-- is, so its conjunct can never reject an occurrence the un-mangled reading of
-- `occurrenceCarriesMangledShadowSym` would accept: the predicate's real discriminator
-- is, and only is, the per-occurrence route symbol.
--
-- This fact currently has no discriminating consumer — L4's conjunct
-- (`mangledFunDefsPresentRef`) is constant-True on emit and its partner
-- (`occurrenceCarriesMangledShadowSym`) is always-empty off emit.  It is explicit
-- documentation of an implicit invariant, not a live condition.  Do not migrate a
-- reader onto it expecting it to select.  It stays because "this graph was mangled" is
-- more readable than the anonymous `routeLocalSym … /= ""` idiom, even though it cannot
-- currently narrow anything a build-time `medaka check`/`run`/`build` differential
-- could observe from outside the compiler.
importerShadowOnEmitPath : ModuleCtx -> String -> Ref Route -> Bool
importerShadowOnEmitPath mctx name tagRef =
  singleTyparamIfaceMethod mctx name
    && mctx.mcGraph.mangledFunDefsPresentRef.value
    && occurrenceCarriesMangledShadowSym name tagRef

-- S1/S2: is [name] a DEFINER shadow — a top-level fn defined in
-- THIS module that reuses a single-param interface method's name?  This is the exact
-- predicate that decides whether the inversion applies (Fork 1: definer-only).
--
-- It is NOT the same question as "did we reach inferDefinerShadowApp".  That entry point
-- (definerShadowArgHead) ALSO fires for an IMPORTER shadow on the mangled emit path, where
-- the mark pass seeded the route with the provider's mangled symbol (`routeLocalSym /= ""`)
-- — see its header.  Inverting on that signal would invert importer shadows too, which
-- Fork 1 forbids: it breaks the everyday `import map` pattern (`isEmpty [1,2]` must still
-- reach `Foldable.isEmpty`).  definerShadowNamesRef holds bare names on EVERY path — the
-- emit path recovers a mangled local funDef through the mangle map (buildDefinerShadows) —
-- and never holds an imported standalone, so it is the reliable definer/importer test.
--
-- The ifaceMethodName conjunct mirrors definerShadowVarHead / definerShadowArgHead's
-- definer disjunct verbatim, so every entry point agrees on which occurrences the
-- machinery owns.  A multi-TYPARAM interface (`interface Ix a i`) is IN scope: gating on
-- the typaram count would leave its occurrences to ordinary dispatch, where check/build
-- keep the per-receiver answer while eval resolves the bare name lexically and E-PANICs
-- (SHADOW-SEMANTICS.md S8; the S7 violation d11 pins; row 26, #54).
export
isDefinerShadow : ModuleCtx -> String -> Bool
isDefinerShadow mctx name =
  ifaceMethodName mctx name
    && omHasKey name mctx.mcCells.definerShadowNamesRef.value

-- S2 (SHADOW-INVERSION-DESIGN.md): True iff the shadow [name]
-- applied to a receiver of type [xt] should DISPATCH to the interface method rather than
-- call the standalone.
--
-- For a definer shadow the impl universe is NOT consulted.  Dispatching whenever the
-- receiver's head tycon has a visible impl of the shadowed interface, with the standalone
-- only a fallback for a no-impl head, would silently ERASE the user's function —
--
--   eq : List Int -> List Int -> Bool
--   eq a b = True
--   main = println (debug (eq [1] [2]))   -- printed False: `impl Eq List` won
--
-- — and `check --types` did not even report the user's signature.  Since the prelude declares
-- ~49 method names over every common type (`map`, `filter`, `length`, `compare`, `eq`, `min`,
-- `empty`, `toList`, `display`, …), that made the most natural names in the language into
-- landmines.  A top-level name written in a module is now THAT MODULE'S NAME: a definer
-- shadow is the standalone, unconditionally, and the argument must type against the
-- standalone's declared domain (a mismatch is a located reject — S2/S3/S6).
--
-- The ONE carve-out (S5, Fork 2): a receiver that is a dict-bound `=>` constraint var of the
-- enclosing function still DISPATCHES.  Writing `Sz a => …` is an explicit, written-down
-- request to resolve through the interface, and there is currently no other way to name the
-- method inside a shadowing module (SHADOW-SEMANTICS.md §1.1).  A grounded head never
-- normalizes to a TVar, so it correctly answers False for every concrete receiver.
--
-- An IMPORTER shadow reaching here (via definerShadowArgHead's mangled-sym arm) keeps the
-- OLD per-receiver rule — Fork 1.
export
definerReceiverDispatches : DynCtx -> String -> Mono -> Bool
definerReceiverDispatches dyn name xt
  | isDefinerShadow dyn.dcModule name = definerReceiverIsDictVar dyn name xt
  | otherwise = match headTyconMono xt
    -- ARCH B-2.1-g: graph-global, off `bodyImplEnvRef` — see `ieImplExistsForHead`.
    -- The guard above means only the Fork-1 IMPORTER arm reaches here.
    Some head =>
      ieImplExistsForHead
        dyn.dcModule
        dyn.dcModule.mcCells.bodyImplEnvRef.value
        name
        head
    None => definerReceiverIsDictVar dyn name xt

-- P0-19 (constrained-receiver arm): True iff an UNGROUNDED definer-shadow receiver is
-- one of the ENCLOSING group's `=>`-constraint variables for the SHADOWED interface (or
-- a superinterface of it).  Such an occurrence dispatches through that dict — it is a
-- METHOD call, not the standalone — so it must be typed against the method scheme and
-- must NOT have the standalone's declared domain imposed on it.
--
-- Without this, ANY constrained function that calls the method on its own dict-bound
-- var, in a program where some top-level fn shadows that method's name, is silently
-- monomorphised to the shadow's domain.  That includes the PRELUDE's own bodies: on the
-- flat single-file path `prog` is core ++ user, so a user `eq : Int -> Int -> Int`
-- made core's `neq : Eq a => a -> a -> Bool` (`neq x y = not (eq x y)`) infer `eq x y :
-- Int` and reject with `Type mismatch: Bool vs Int` at the top of the user's file.
-- A higher-kinded receiver `t a` reads the written constraint on `t`.
export
definerReceiverIsDictVar : DynCtx -> String -> Mono -> Bool
definerReceiverIsDictVar dyn name xt = match headMonoNode xt
  TVar cell => match methodEntryHere dyn.dcModule name
    Some (mIface, _, _, _) =>
      dictVarSatisfiesIface
        dyn.dcModule
        mIface.irName
        (tyvarId cell)
        (groupMonos dyn)
    None => False
  _ => False

-- The enclosing group's constraint monos; empty outside a group (a tail body).
groupMonos : DynCtx -> List (String, Mono)
groupMonos dyn = match dyn.dcGroup
  None => []
  Some group => group.gcMonos

-- does any of the group's constraint vars BOTH normalize to tyvar [id] AND carry an
-- interface whose (self + transitive supers) closure includes [mIface]?
dictVarSatisfiesIface : ModuleCtx ->
  String ->
  Int ->
  List (String, Mono) ->
  Bool
dictVarSatisfiesIface mctx _ _ [] = False
dictVarSatisfiesIface mctx mIface id ((cIface, cm) :: rest)
  | monoIsTyvarId cm id && contains mIface (ifaceSelfAndSupers mctx cIface) =
    True
  | otherwise = dictVarSatisfiesIface mctx mIface id rest

-- P0-19: impose a definer-shadow standalone's declared domain on the actual argument
-- [xt] WHEN the occurrence resolves to the standalone (RLocal).  No declared signature ⇒
-- nothing to enforce (permissive fallback, unchanged).  [dloc] locates the check at the
-- application so a mismatch localizes to the call, not the argument.
--
-- S2: a definer shadow ALWAYS resolves to the standalone, so its domain is ALWAYS
-- enforced, whether or not the receiver's grounded head has a visible impl of the shadowed
-- interface.  Skipping enforcement at such a head is what would let `eq [1] [2]` sail
-- through `check` against the PRELUDE's `Eq.eq` while the user's
-- `eq : List Int -> List Int -> Bool` was discarded.  The only exemption is the Fork-2
-- dict-var carve-out: imposing a concrete domain on the
-- enclosing group's `=>`-constraint var would monomorphise its written signature.
-- #1815: [k] is the interface's dispatch index, so the domain imposed on the receiver is
-- the standalone's k-th parameter.  `k = 0` is the pre-#1815 behavior verbatim (the
-- bare-head arms pass it, and both of this function's callers now name the index).
export
enforceStandaloneDomainAt : TcEnv -> String -> Mono -> Option Loc -> Int -> Unit
enforceStandaloneDomainAt env name xt dloc k =
  match standaloneShadowDomainAt env.teDyn.dcModule name k
    None => ()
    Some dom =>
      if definerReceiverIsDictVar env.teDyn name xt then
        ()
      else
        unifyStandaloneDomain env.teDyn dom xt dloc

-- P0-20 (silent wrong answer, `eq 1 2` → the binary printed 0): typecheck's
-- dispatch-vs-standalone decision and the POST-inference route resolver
-- (resolveRLocalSite) must ask the S2 impl question about the SAME receiver head.
--
-- They did not.  A definer-shadow receiver that is not yet grounded at inference time —
-- a NUMERIC LITERAL is the everyday case, it is `Num a => a`, not `Int` — took the
-- ungrounded arm (S5 ⇒ standalone) and was typed against the standalone's scheme.  That
-- typing then UNIFIES the standalone's declared domain into the receiver, so by the time
-- resolveRLocalSite runs the receiver IS grounded — to `Int` — and `Int` has `impl Eq
-- Int`, so the route resolver left the site to DISPATCH.  Result: `check` typed
-- `eq 1 2 : Int` (the user's `eq : Int -> Int -> Int`) while eval/emit called the
-- interface method and produced a `Bool` — `run` panicked (`intToString: not an Int`)
-- and `build` SILENTLY PRINTED 0.  Only literal receivers were affected: `f k = eq k 1`
-- (k : Int, already grounded) dispatched consistently on all three paths.
--
-- Fix: perform S5's monomorphisation FIRST (it is the same unification the standalone
-- arm would have done, only earlier), then decide.  With the receiver grounded to `Int`,
-- S2 sees the impl and DISPATCHES on every path — check == run == build.  A grounded
-- receiver, a dict-bound one, and an unsignatured standalone (no domain to ground to)
-- are all untouched; so is a standalone whose domain head has NO impl of the shadowed
-- interface (`compiler/frontend/parser.mdk`'s `orElse : Parser a -> Parser a -> Parser a`
-- against `Alternative.orElse` — the compiler declares no `impl Alternative Parser`).
--
-- [dom] MUST come from shadowDomainFor, not standaloneShadowDomain: on the MANGLED emit
-- path the standalone was renamed `<mid>__eq`, so the bare-name sig table is empty there
-- and grounding would be silently inert — which is not a no-op, it flips the emit path to
-- the STANDALONE arm while check/run dispatch.  (Observed: `build` printed 3, `run`
-- printed False.)  Same bug, other direction.
export
groundShadowReceiver : DynCtx ->
  Option Mono ->
  Mono ->
  Bool ->
  Option Loc ->
  Unit
groundShadowReceiver dyn dom xt isDictVar dloc
  | isDictVar = ()
  | isSome (headTyconMono xt) = ()
  | otherwise = match dom
    None => ()
    Some d => unifyStandaloneDomain dyn d xt dloc

-- P0-20: the definer-shadow standalone's declared domain, resolved on EITHER path.
-- Un-mangled run/check (sym == ""): the module's own sig table, keyed by the bare name.
-- Mangled emit (sym /= ""): private_mangle renamed the standalone to `<mid>__name`, so
-- definerShadowSigsRef has no `name` entry — take the domain off the env binding for the
-- mangled symbol, whose value descriptor also supplies the selected occurrence.
-- #1815: [k] is the interface's dispatch index; `k = 0` is the pre-#1815 behavior.
export
shadowDomainForAt : TcEnv -> String -> String -> Int -> Option Mono
shadowDomainForAt env name "" k =
  standaloneShadowDomainAt env.teDyn.dcModule name k
shadowDomainForAt env _ sym k = match lookupVar env sym
  None => None
  Some s => nthFunDomain k (instantiate env.teDyn.dcModule s)

-- unify the standalone domain against the argument at the call's location.
unifyStandaloneDomain : DynCtx -> Mono -> Mono -> Option Loc -> Unit
unifyStandaloneDomain dyn dom xt dloc = unifyIn (dynAt dloc dyn) dom xt

-- a definer-shadow standalone's declared parameter type, freshly instantiated (so a
-- polymorphic standalone domain does not leak vars across sites).  None when there is
-- no top-level signature, or the signature is not a function type.
-- #1815: [k] is the interface's dispatch index — the standalone's k-th declared
-- parameter is the one the receiver occupies.  `k = 0` is the pre-#1815 behavior.
export
standaloneShadowDomainAt : ModuleCtx -> String -> Int -> Option Mono
standaloneShadowDomainAt mctx name k =
  match omLookup name mctx.mcCells.definerShadowSigsRef.value
    None => None
    Some ty => nthFunDomain k (instantiate mctx (sigToScheme mctx ty))

-- S2-DECL (d) for a VALUE occurrence of an importer shadow (`ap2 mth`, `g = mth`,
-- `flip mth`): no argument is applied, so no admitted declaration's own receiver can be
-- evaluated, and with two or more admitted the declarations have not been shown to
-- agree.  That is the located reject, in every import order.  The standalone still
-- types the occurrence, as at the applied arms' reject.  A definer shadow denotes its
-- own module's standalone and is never ambiguous.
export
rejectAdmittedValueOccurrence : ModuleCtx -> String -> Unit
rejectAdmittedValueOccurrence mctx name
  | isDefinerShadow mctx name = ()
  | otherwise =
    let ifs = methodAdmittedHere mctx name
    if listLen ifs >= 2 then pushAmbiguousShadowDecl mctx name ifs mctx.mcLoc

export
standaloneValueBinding : TcEnv -> String -> Option ValueScheme
standaloneValueBinding env name
  | env.teDyn.dcShadowHeadCtx = None
  | ifaceMethodName env.teDyn.dcModule name
    && omHasKey name env.teDyn.dcModule.mcCells.definerShadowNamesRef.value =
    lookupStandaloneValue env name
  | not (singleTyparamIfaceMethod env.teDyn.dcModule name) = None
  | otherwise = lookupStandaloneValue env name

-- #410/#669 (S4, EMIT path only): the sym-recovering peer of maybeStandaloneValueMono,
-- for the marked (EMethodAt) value-position occurrence whose bare name maybeStandaloneValueMono
-- can no longer see because the mangler renamed the definer standalone's funDef to
-- `<mid>__name`.  The signal is PER-OCCURRENCE, not graph-wide: rewriteArgScoped (:7937)
-- seeds the tagRef route with `RLocal <mangled>` for EXACTLY the value-position standalone
-- shadows (the `sm` mangled-shadow map), while an ordinary return/arg-position method value
-- gets `RNone` — so a non-empty routeLocalSym is the mark pass's own "this occurrence is a
-- standalone shadow" verdict, and keying on it (not on the whole-graph `standaloneValuesRef`)
-- is what keeps this from pinning the compiler's genuine method-values and breaking dispatch.
-- The scheme is recovered by `standaloneSchemeFor`: an IMPORTER shadow via
-- its lexical binding descriptor, a DEFINER shadow via the env under that mangled sym — the same
-- accessor recordRLocalSite already trusts to compute this site's RLocal dicts.  Value-position
-- ONLY (dcShadowHeadCtx False, mirroring maybeStandaloneValueMono's first guard); an
-- application head is bracketed True by inferShadowAppHead / inferDefinerShadowApp and keeps
-- ordinary per-receiver dispatch.  None (⇒ caller keeps the method scheme) when the route
-- carries no mangled sym, or when the standalone scheme is unavailable.
-- #724: the gate is per shadow kind (emitValueShadowGate), mirroring the check-path
-- maybeStandaloneValueMono's per-arm split exactly — NOT one blanket singleTyparamIfaceMethod.
-- The classifier is isDefinerShadow (`omHasKey name definerShadowNamesRef`, the SAME test the
-- check path uses), NOT standalone-scheme availability: that is a
-- scheme-SOURCE question and an importer occurrence may have a scheme here, so keying
-- on it mis-grounds i10's multi-typaram importer app head to a garbage-pointer build.
--   • DEFINER arm (isDefinerShadow): typaram-agnostic, mirroring the check-path definer arm
--     (which grounds a MULTI-typaram definer value position — #724's exact skew: check grounded,
--     emit declined, so `map size [1,2,3]` stamped a null Display element dict and SIGSEGVd).
--     Safe at multi-typaram width because a DEFINER app head is ALWAYS bracketed: it is caught
--     by definerShadowArgHead's isDefinerShadow disjunct (typaram-agnostic) →
--     inferDefinerShadowApp, which sets dcShadowHeadCtx True and types the head via
--     the method scheme or selected standalone occurrence, never inferMethodAt. So the
--     only definer occurrence reaching here with dcShadowHeadCtx False is a genuine value
--     position, which is precisely what must ground (d22z is the app-head control).
--   • otherwise (importer / non-shadow): singleTyparamIfaceMethod is REQUIRED, not incidental.
--     At MULTI-typaram width the importer app-head path (`get (Box 3) 1`, interface `Ix a i`,
--     i10) uses ORDINARY dispatch, so an app head can reach inferMethodAt with dcShadowHeadCtx
--     False AND a mangled route sym — indistinguishable from a value position by those two
--     signals alone.  The check-path importer arm is singleTyparamIfaceMethod-gated (Fork 1)
--     for exactly this reason; keeping the guard here leaves i10's per-receiver dispatch
--     (4 then 3) intact.  Sz/Sizeable are single-typaram, so #410/#669 still pin.
--
-- #410/#669 DIRECTION-2 (deliberately NOT taken): the alternative floor was to leave the type
-- alone and instead make a container element route that resolves to RNone from a genuinely-free
-- var a LOUD `T-AMBIGUOUS-INSTANCE` rather than a silent null dict.  Rejected: an empty
-- container's RNone element is BENIGN (never dereferenced) — `main = println []` is a VALID
-- program that stamps exactly that RNone element — so a fail-loud rule would reject valid code,
-- and the `Undetermined`/KeepNone design (:9899) forbids element-position errors for this reason.
-- Grounding the shadow occurrence's TYPE here (direction 1) closes the actual SIGSEGV vector at
-- its source without that hazard, so the loud-floor was not needed.
export
standaloneValueBindingEmit : TcEnv -> String -> Ref Route -> Option ValueScheme
-- #2809: keyed on `recoveredShadowSym`, not on the raw seed.  This pin exists to
-- recover a shadow the MANGLER hid; a bare seed hides nothing, and reading one as the
-- old signal fires this emit-only pin on `check`/`run`.
standaloneValueBindingEmit env name tagRef
  | env.teDyn.dcShadowHeadCtx = None
  | recoveredShadowSym name tagRef == "" = None
  | not (emitValueShadowGate env.teDyn.dcModule name) = None
  | otherwise = standaloneValueFor env name (recoveredShadowSym name tagRef)

-- #724: the per-shadow-kind gate for the emit-path value-position pin, mirroring the
-- check-path maybeStandaloneValueMono's per-arm split (definer arm typaram-agnostic; importer
-- arm singleTyparam-scoped, Fork 1).  The definer/importer classifier is isDefinerShadow —
-- `omHasKey name definerShadowNamesRef`, which holds BARE names on EVERY path (the emit path
-- recovers the mangled local funDef through the mangle map, buildDefinerShadows) and NEVER
-- holds an imported standalone, so it is the reliable test (its header, :5717).  It is NOT
-- standalone-scheme availability: that answers a SCHEME-SOURCE question,
-- not a definer/importer classifier — an importer occurrence may have a scheme
-- at this pin, so keying on it mis-grounded i10's multi-typaram importer APP head to a
-- garbage-pointer build (the P0-20 shape).
--   • DEFINER shadow (isDefinerShadow): admit typaram-agnostically.  Safe at multi-typaram
--     width because a definer app head is ALWAYS bracketed by inferDefinerShadowApp
--     (definerShadowArgHead's isDefinerShadow disjunct fires typaram-agnostically), so it
--     reaches standaloneValueBindingEmit with dcShadowHeadCtx True and is declined by that
--     function's first guard — the ONLY definer occurrence reaching the pin with
--     dcShadowHeadCtx False is a genuine value position, which is what must ground.
--   • otherwise (importer or non-shadow): keep singleTyparamIfaceMethod — a MULTI-typaram
--     importer app head (`get (Box 3) 1`, i10) uses ORDINARY dispatch and is NOT bracketed,
--     so it too can reach the pin with dcShadowHeadCtx False and a mangled route sym; the
--     singleTyparam gate is what keeps it (and its per-receiver dispatch, 4 then 3) intact,
--     exactly as the check-path importer arm does.
emitValueShadowGate : ModuleCtx -> String -> Bool
emitValueShadowGate mctx name
  | isDefinerShadow mctx name = True
  | otherwise = singleTyparamIfaceMethod mctx name

-- #411: is [name] an occurrence whose TYPE maybeStandaloneValueMono pins to the
-- standalone?  ⭐ the route must follow the arm (the P0-20 lesson): a site typed against
-- the standalone must ROUTE to the standalone, or type and route disagree — which is this
-- arc's recurring bug class.  So recordRLocalSite stamps such a site forceLocal, skipping
-- resolveRLocalSite's per-receiver query entirely.  Under S4 there is no receiver to
-- dispatch on, so the query was never meaningful for a value position in the first place.
--
-- For a DEFINER shadow this is behavior-preserving both ways: resolveRLocalSite's grounded
-- arm already forced RLocal, and its ungrounded arm already stamped RLocal for
-- definerShadowNamesRef members.
-- For an IMPORTER shadow it is the #411 fix: a grounded arm that let a live impl steal
-- the value (row 21b), or an ungrounded arm that left the route UNSTAMPED (row 21a), makes
-- eval arg-tag-dispatch into the Box impl and the emitter, having no standalone
-- fallback, panic `no impl of method 'size' for type 'Int'`.
--
-- Mirrors maybeStandaloneValueMono's guards exactly; keep the two in lockstep.
export
standaloneValuePinned : TcEnv -> String -> Bool
standaloneValuePinned env name = isSome (standaloneValueBinding env name)

-- P0-19: peel an application head to a definer-shadow interface-method occurrence on
-- the UN-MARKED path (the `check` pipeline runs no marker, so the head is a bare
-- `EVar`, not the `EMethodAt` that definerShadowArgHead matches on run/build).  Same
-- guard as definerShadowArgHead's DEFINER disjunct: an interface method (of an interface
-- of ANY typaram arity, #54) whose name is a module-local standalone
-- (definerShadowNamesRef).
export
definerShadowVarHead : ModuleCtx -> Expr -> Option String
definerShadowVarHead mctx (ELoc _ f) = definerShadowVarHead mctx f
definerShadowVarHead mctx (EVar name)
  | ifaceMethodName mctx name
    && omHasKey name mctx.mcCells.definerShadowNamesRef.value = Some name
  | otherwise = None
definerShadowVarHead mctx (EVarId name _)
  | ifaceMethodName mctx name
    && omHasKey name mctx.mcCells.definerShadowNamesRef.value = Some name
  | otherwise = None
definerShadowVarHead mctx _ = None

-- ── #1815: the dispatch argument is not always argument 0 ───────────────────
-- The two predicates above peel a BARE head, so they only ever fire on the node that
-- supplies argument 0.  For an interface that dispatches at index k > 0 that node is
-- not the dispatch site: `mth n x` is `EApp (EApp mth n) x`, and the receiver is `x`,
-- one node further out.  These two answer the SAME question as their bare-head peers —
-- "is this node a definer shadow's dispatch site?" — for k > 0.
--
-- `shadowSpineNodesAt` is the whole discriminator, and it declines in two ways that
-- keep the pre-existing behavior byte-identical: `[]` nodes (a bare head, k == 0 —
-- the peers below handle it), and a spine whose depth is not the interface's dispatch
-- index (over-applied `mth n x y`, whose OWN inner node is the dispatch site and fires
-- there; or under-applied `mth n` at k == 1, which has no receiver to decide on at all
-- and is left exactly as it is today).
shadowSpineNodesAt : ModuleCtx -> String -> Expr -> Option (List Expr)
shadowSpineNodesAt mctx name f =
  let nodes = appSpineNodes f
  if isEmptyL nodes then
    None
  else match methodDispatchIdx mctx name
    Some k => if k == listLen nodes then Some nodes else None
    None => None

-- #2188: the IMPORTER-path twin, differing in ONE respect — the index it gates on is
-- `importerDispatchIdxOuter`, the OUTERMOST index over the admitted SET, rather than the
-- single admitted winner's.  With two admitted declarations dispatching at different
-- argument positions there are two candidate dispatch NODES, and S2-DECL (b)'s
-- per-declaration (receiver, impl-query) pairs can only be evaluated jointly at the
-- outer one — the inner node has not inferred the outer argument yet.
--
-- The DEFINER arms keep `shadowSpineNodesAt`, deliberately: under the S2 inversion a
-- definer shadow never consults the impl universe, so it has no per-declaration query to
-- evaluate and no reason to move its node.  `importerDispatchIdxOuter` falls back to
-- `methodDispatchIdx` for every name with fewer than two admitted declarations, so this
-- function is `shadowSpineNodesAt` verbatim on every program that exists today.
shadowSpineNodesAtImporter : ModuleCtx -> String -> Expr -> Option (List Expr)
shadowSpineNodesAtImporter mctx name f =
  let nodes = appSpineNodes f
  if isEmptyL nodes then
    None
  else match importerDispatchIdxOuter mctx name
    Some k => if k == listLen nodes then Some nodes else None
    None => None

-- the MARKED (run/build) spine arm — peer of definerShadowArgHead.
export
definerShadowSpineArgAt : ModuleCtx ->
  Expr ->
  Option (String, Ref (Option Int), Ref Route, Ref (List Route), Ref Inner, Expr, List Expr)
definerShadowSpineArgAt mctx f =
  match definerShadowArgHead mctx (appSpineHead f)
    None => None
    Some (name, arityRef, tagRef, implRef, innerRef) =>
      map
        (nodes =>
          (name, arityRef, tagRef, implRef, innerRef, appSpineHead f, nodes))
        (shadowSpineNodesAt mctx name f)

-- the UNMARKED (`check`) spine arm — peer of definerShadowVarHead.
export
definerShadowSpineVarAt : ModuleCtx -> Expr -> Option (String, Expr, List Expr)
definerShadowSpineVarAt mctx f =
  match definerShadowVarHead mctx (appSpineHead f)
    None => None
    Some name =>
      map
        (nodes => (name, appSpineHead f, nodes))
        (shadowSpineNodesAt mctx name f)

-- the dict slots ONLY — no call obligations.
-- recordRLocalSite needs this: it fires for EVERY shadow method occurrence, at a point
-- where the standalone-vs-dispatch choice is NOT yet made (resolveRLocalSite decides it
-- post-inference from the grounded receiver).  Recording an obligation here would fire on
-- the DISPATCH arm too and spuriously reject `size (Box 3)` with `Num Box`.  When the
-- receiver does turn out to have an impl, resolveRLocalSite leaves these slots
-- unsolved and the route dispatches as before.
--
-- [name] is the BARE name and [key] the binding symbol (mangled on the emit path).
-- Both are needed: the tables below are keyed by the binding, while the definer/importer
-- classifier `isDefinerShadow` reads `definerShadowNamesRef`, which holds bare names on
-- every path.  Passing [key] to that classifier makes it silently answer False for every
-- mangled occurrence — see `shadowDeclaredFor`.
export
shadowStandaloneDictSlotsAt : DynCtx ->
  Option ValueScheme ->
  String ->
  String ->
  Mono ->
  ShadowDicts
shadowStandaloneDictSlotsAt dyn None _ _ _ = emptyShadowDicts
shadowStandaloneDictSlotsAt dyn (Some value) name key xt =
  let inst = instantiateMethodTracked dyn.dcModule value.vsScheme
  let dc =
    optionOr
      (shadowDeclaredFor dyn.dcModule name key)
      (declaredEffectsAt dyn.dcModule.mcGraph inst value.vsDeclared)
  if isEmptyL dc.cdSlots then
    emptyShadowDicts
  else
    unifySpineProbe dyn inst.mtiBody [xt]
    shadowStandaloneDictSlots
      dyn.dcModule.mcGraph
      dc.cdSlots
      dc.cdArgs
      inst.mtiSubstitution.misTypeSubst

-- #2722: a DEFINER SHADOW's own standalone, resolved from ITS module's table rather than
-- through the import-keyed dispatch.  `declaredConstraintFor` / `declaredConstraintIds`
-- cannot answer this case: a definer shadow's bare name is in `currentImportDefinersRef`
-- BY CONSTRUCTION (selectively importing the method it shadows is what makes it a shadow),
-- so #739's source-exact arm fires and reports "genuinely unconstrained in its source
-- module" — the right answer about the IMPORT, the wrong answer about the local binding
-- the occurrence already resolved to.  The result was `[]` dict slots against a definition
-- that takes one, i.e. a call under-applied by exactly its dict parameter: `run` E-PANICked
-- `intToString: not an Int` and the built binary printed a partial-application POINTER, a
-- different one every execution, at exit 0.
--
-- Scoped to the definer-shadow case only: one bare name with two bindings is the missing
-- per-occurrence discriminator #1898/#1899 name, and this does not re-key anything.
--
-- [P-NO-MARK-PASS]: [key] is only ever mangled post-mark-pass, which no production verb
-- runs, so [name] and [key] coincide on every reachable caller today — the [name]/[key]
-- split above is correct by construction but currently unwitnessable by any gate.
export
shadowDeclaredFor : ModuleCtx -> String -> String -> CDeclared
shadowDeclaredFor mctx name key
  | isDefinerShadow mctx name = localDeclaredConstraintFor mctx key
  | otherwise = declaredConstraintFor mctx key

-- the standalone's dict ROUTE slots for this call: its declared constraint ids mapped
-- through the call's instantiation subst.  Deduplicated EXACTLY as inferDictAtFound
-- does — dictArityOf sizes the DEFINITION's leading dict params from the same
-- declared table, so call and def must agree slot-for-slot or we have
-- merely moved the arity disagreement.  Empty on the plain `check` path
-- (funConstraintsRef is empty there) — check stamps no routes, so that is correct;
-- recordStandaloneSigObligations is what gives `check` its reject direction.
--
-- FIX-shadow-arity-skew: "EXACTLY as inferDictAtFound does" is a claim about the
-- (slot, VECTOR) pairs fed to the fixpoint, NOT about the slot list alone, and this is
-- where that distinction was paid for.  This expanded via `expandSupersPairs`, which
-- pairs every slot with a constant `[]`; once S-slot-key-vector (#1866) re-keyed
-- `dedupSlotVecs` on the WHOLE PREDICATE, `(Ix a Char, Ix a Bool) => …` opened TWO slots
-- on the definition side (`expandSupersEntry`, which `dictArityOf` sizes from) and this
-- call side still collapsed them to ONE — 1 dict passed to a 2-dict definition.  Measured
-- on the packet's reproducer at `e19298f5`: `check` exit 0, `run` E-PANIC
-- "intToString: not an Int", `build` exit 0 printing a DIFFERENT heap pointer every
-- execution, wasm "illegal cast".  Take the vectors from the same `declaredConstraintFor`
-- entry the slots came from, or re-open it.
export
shadowStandaloneDictSlots : GraphCtx ->
  List CSlot ->
  List (List Mono) ->
  List (Int, Mono) ->
  ShadowDicts
shadowStandaloneDictSlots gctx slots args subst =
  if isEmptyL slots then
    emptyShadowDicts
  else
    let expandedV = dedupSlotVecs (zipSlotVecs slots args)
    let expanded = map fst expandedV
    -- the ROUTE half stays a SPELLING, exactly as `inferDictAtFound`'s `pushDictApp`
    -- does — route words, not identities (see `dispHeadTab`).
    -- [sdArgVecs] is `callArgVecsV` over the SAME expansion against the SAME subst, so it
    -- is slot-parallel to [sdMonos] by construction (that function's own header states
    -- the invariant and the shared drop rule that preserves it).
    ShadowDicts {
      sdMonos = constraintMonosOf (map (sl => sl.csId) expanded) subst,
      sdIfaces = map (sl => sl.csIface) expanded,
      sdArgVecs = callArgVecsV gctx expandedV subst,
    }

export
importerAdmittedVerdict : ModuleCtx ->
  ImplEnv ->
  String ->
  List Mono ->
  AdmittedVerdict
importerAdmittedVerdict mctx env name ats = match methodAdmittedHere mctx name
  [] => AdDefer
  ifs =>
    if listLen ifs < 2 then
      AdDefer
    else match admittedDeclHitters mctx env name ifs ats
      None => AdReject ifs
      Some hits => if isEmptyL hits then AdStandalone else AdReject ifs

-- The admitted declarations whose OWN (receiver argument, impl query) pair — S2-DECL
-- (b), both halves from the same declaration — HITS.  `None` if any declaration's pair
-- cannot be evaluated at all, which `importerAdmittedVerdict` reads as an ambiguity.
admittedDeclHitters : ModuleCtx ->
  ImplEnv ->
  String ->
  List IfaceRef ->
  List Mono ->
  Option (List IfaceRef)
admittedDeclHitters mctx _ _ [] _ = Some []
admittedDeclHitters mctx env name (ir :: rest) ats =
  match admittedDeclHits mctx env name ir ats
    None => None
    Some hit =>
      map
        (hs => if hit then ir :: hs else hs)
        (admittedDeclHitters mctx env name rest ats)

-- S2-DECL (a)+(b) for ONE declaration: its receiver argument is the applied argument at
-- ITS OWN dispatch index (not the occurrence's first argument), and the impl query asks
-- about an impl of THAT interface at that receiver's head — over the unchanged
-- graph-global row set (`ieImplExistsForHeadOf` is `ieImplExistsForHead`'s own body).
admittedDeclHits : ModuleCtx ->
  ImplEnv ->
  String ->
  IfaceRef ->
  List Mono ->
  Option Bool
admittedDeclHits mctx env name ir ats = do
  k <- lookupIdxById ir name mctx.mcCells.methodDispatchIdxByIdRef.value
  at <- nthMono k ats
  hk <- headTyconMono at
  Some (ieImplExistsForHeadOf mctx env name hk (Some [ir]))

-- The OUTERMOST dispatch index over the admitted set — the spine node at which every
-- admitted declaration's receiver argument is already inferred, and therefore the only
-- node at which (b)'s per-declaration pairs can be evaluated JOINTLY.  Falls back to
-- `methodDispatchIdx` (the single-winner index) for every name with fewer than two
-- admitted declarations, i.e. for every program that exists today.
importerDispatchIdxOuter : ModuleCtx -> String -> Option Int
importerDispatchIdxOuter mctx name =
  match admittedIdxMax mctx name (methodAdmittedHere mctx name)
    Some k => Some k
    None => methodDispatchIdx mctx name

admittedIdxMax : ModuleCtx -> String -> List IfaceRef -> Option Int
admittedIdxMax mctx _ [] = None
admittedIdxMax mctx name (ir :: rest) =
  let here = lookupIdxById ir name mctx.mcCells.methodDispatchIdxByIdRef.value
  match admittedIdxMax mctx name rest
    None => here
    Some k => match here
      None => Some k
      Some j => Some (maxI j k)

-- Ground each admitted declaration's OWN receiver argument to the standalone's declared
-- domain at that index, before the impl queries are asked — the P0-20 symmetry rule
-- ("ask the impl question about the SAME head the route resolver will") applied once per
-- declaration instead of once per occurrence.  A no-op for every name with fewer than
-- two admitted declarations, since `methodAdmittedHere` answers `[]` there.
export
groundAdmittedReceivers : TcEnv -> String -> List Mono -> Option Loc -> Unit
groundAdmittedReceivers env mname ats dloc =
  groundAdmittedGo
    env
    mname
    (methodAdmittedHere env.teDyn.dcModule mname)
    ats
    dloc

groundAdmittedGo : TcEnv ->
  String ->
  List IfaceRef ->
  List Mono ->
  Option Loc ->
  Unit
groundAdmittedGo env _ [] _ _ = ()
groundAdmittedGo env mname (ir :: rest) ats dloc =
  match (lookupIdxById
    ir
    mname
    env.teDyn.dcModule.mcCells.methodDispatchIdxByIdRef.value)
    None => ()
    Some k => match nthMono k ats
      None => ()
      Some at =>
        groundShadowReceiver
          env.teDyn
          (importerShadowDomainAt env mname k)
          at
          (definerReceiverIsDictVar env.teDyn mname at)
          dloc
  groundAdmittedGo env mname rest ats dloc

-- ERROR-QUALITY: name the two things that collide, say what the collision costs, then
-- name the fixes.  Callers locate it at the occurrence's head (`appSpineHeadLoc`): an
-- application carries no location of its own, and the location current when the
-- occurrence is reached can belong to whichever module was checked last.  Phrased after `aliasAmbiguityMsg`, the nearest neighbour in this file.
-- The interface list is the SORTED admitted set, so the prose does not encode import
-- order any more than the verdict does (S2-DECL (e)).
export
pushAmbiguousShadowDecl : ModuleCtx ->
  String ->
  List IfaceRef ->
  Option Loc ->
  Unit
pushAmbiguousShadowDecl mctx name ifs dloc =
  pushTypeErrorHelpFixAt
    mctx
    TAmbiguousShadowDecl
    dloc
    "`\{name}` is ambiguous here: \{joinWith " and " (map shadowIfaceLabel ifs)} each declare a method `\{name}` and are both in scope; \{ambiguousShadowHelp}"
    ambiguousShadowHelp
    None

-- The method-only sibling of `pushAmbiguousShadowDecl`: no standalone is in scope,
-- so the admitted declarations are the only candidates, and the occurrence decides
-- none of them (`admittedSelection`).  Same sorted interface list, same help.
pushAmbiguousMethod : ModuleCtx -> String -> List IfaceRef -> Option Loc -> Unit
pushAmbiguousMethod mctx name ifs loc =
  pushTypeErrorHelpFixAt
    mctx
    TAmbiguousMethod
    loc
    "`\{name}` is ambiguous here: \{joinWith " and " (map shadowIfaceLabel ifs)} each declare a method `\{name}`, and this use does not decide which one it means; bring only one of those interfaces into scope"
    ambiguousShadowHelp
    None

-- The admitted set's one selecting declaration [sel] has method-level constraints,
-- which an admitted-set occurrence records no dictionaries for (`routableSelection`).
-- Same code and help as `pushAmbiguousMethod`: the ambiguity of the spelling is
-- what withholds those dictionaries.
pushUnroutableAdmitted : ModuleCtx ->
  String ->
  List IfaceRef ->
  IfaceRef ->
  Option Loc ->
  Unit
pushUnroutableAdmitted mctx name ifs sel loc =
  pushTypeErrorHelpFixAt
    mctx
    TAmbiguousMethod
    loc
    "`\{name}` names a method of more than one interface here (\{joinWith " and " (map shadowIfaceLabel ifs)}); the one this use selects, `\{sel.irName}.\{name}`, has method-level constraints, and a use of a name that more than one interface declares cannot supply their dictionaries; bring only one of those interfaces into scope"
    ambiguousShadowHelp
    None

-- C5: stamp RLocal on each recorded standalone-shadow arg-position site whose
-- receiver mono now grounds to a concrete head tycon with NO impl of the method.
-- The receiver HAS an impl (the genuine-method case, e.g. `toList (Some 7)`):
-- leave the route untouched — eval arg-tag-dispatches on RNone; emit already
-- stamped the correct RKey<receiverHead> via resolveArgStamps.
-- An ungrounded receiver (still a tyvar) → leave it.  The
-- RLocal-vs-ordinary-dispatch split keys the genuine case off the receiver.
export
resolveRLocalSite : SiteCtx ->
  String ->
  Ref Route ->
  Mono ->
  String ->
  ScopeId ->
  String ->
  List Mono ->
  List IfaceRef ->
  List (List Mono) ->
  Unit
resolveRLocalSite sx name tagRef am encl scope sym monos ifaces argVecs =
  match headTyconMono am
    -- S2: route by SHADOW KIND first, receiver second.
    --   * DEFINER shadow (the name is this module's own top-level fn) → the standalone,
    --     UNCONDITIONALLY.  The impl universe is not consulted; a grounded head with a live
    --     impl no longer steals the call.  (The APP path already forces this via the
    --     RLocalSite `forceLocal` flag; this arm is what carries the other recorders —
    --     notably the VALUE-position sites pushed by the generic recordRLocalSite, which is
    --     gated on standaloneValuesRef and that set holds definer AND importer shadows.)
    --   * IMPORTER shadow (Fork 1) → the OLD per-receiver rule, unchanged: a live impl at the
    --     receiver head dispatches, else the standalone.  An `import` is a SIBLING scope, not
    --     an inner one, so it does not shadow; inverting it too would break the everyday
    --     `import map` pattern (`isEmpty [1,2]` must still reach `Foldable.isEmpty`).
    -- am is the ACTUAL argument type (inferDefinerShadowApp records it), not the standalone's
    -- declared domain, so the importer arm's impl query is still meaningful.
    --
    -- isDefinerShadow — NOT a bare definerShadowNamesRef membership test.  It carries the
    -- SAME gate every typing entry point applies (ifaceMethodName, #54; it was the typaram-
    -- COUNT test singleParamIfaceMethod until S-3 / row 26 was closed).  Routing here on a
    -- gate the typing entry points do not share would route a site whose TYPE came from the
    -- dispatch path — route and type disagreeing is exactly the P0-20 bug class.  Keep the
    -- two gates identical.
    -- ARCH B-2.1-g: graph-global, off `bodyImplEnvRef` — see `ieImplExistsForHead`, and
    -- see the `#415 item 2` block in `typecheck` for why this read could only move TOGETHER with
    -- its sibling selection leg (`routesOfMonosTop … keyTable` → `keyForSite`, likewise
    -- repointed by this bite).  Both now read ONE table again, and it is the same table
    -- the emitter counts over.
    Some tag =>
      -- Route construction solves dictionary obligations. Do it only after
      -- committing to the standalone, never for a discarded method alternative.
      if not (isDefinerShadow sx.sxModule name)
        && ieImplExistsForHead
          sx.sxModule
          sx.sxModule.mcCells.bodyImplEnvRef.value
          name
          tag then
        ()
      else
        tagRef :=
          RLocal sym (routesOfMonosTopV sx encl scope monos ifaces argVecs)
    -- An UNGROUNDED definer-shadow receiver keeps the old default (RLocal → standalone);
    -- other (importer) ungrounded sites stay untouched (deferred/polymorphic).
    None =>
      if omHasKey name sx.sxModule.mcCells.definerShadowNamesRef.value then
        tagRef :=
          RLocal sym (routesOfMonosTopV sx encl scope monos ifaces argVecs)

-- True for either spelling of the prelude's module id.  The export indexes
-- (`meExports`, `deCtorExports`) key the prelude under "core", but the `mid` the core
-- pass receives is "" on both output selections, so a test of one spelling alone never
-- fires on either.
export
isPreludeMid : String -> Bool
isPreludeMid mid = mid == "core" || mid == ""

-- The names THIS module declares as a top-level funDef that also name an interface method
-- (`isMethod`).  Unlike importer shadows these keep their LOCAL standalone scheme, since
-- the impl bodies apply them to the concrete receiver.  `bares` recovers
-- the bare name of a mangled definer through `mangledShadowMapRef`.
export
definerShadowsFromSet : GraphCtx -> (String -> Bool) -> List Decl -> List String
definerShadowsFromSet gctx isMethod prog =
  let localNames = dedup (map fst (funDefs prog))
  let direct = filter isMethod localNames
  let sm = gctx.mangledShadowMapRef.value
  let bares =
    flatMap
      (n => match lookupAssoc n sm
        Some bare => [bare]
        None => [])
      localNames
  removeAllS (localBoundNames prog) (dedup (direct ++ bares))

-- A name qualifies as an importer shadow when it is a universe fn, an interface
-- method, and NOT defined in this module; `not (contains n localNames)` drops this
-- module's own funDefs.  The `mangled` arm recovers the bare method name via
-- mangledShadowMapRef: on the EMIT path every funDef is mangled, so `direct` — which
-- intersects mangled universe-fn names against bare interface-method names — matches
-- nothing on its own, and without recovery the standalone/method dispatch decision
-- (Fork-1's importer rule) silently loses its site. Empty on the un-mangled run/check
-- path (the map is empty there) → `direct` alone → byte-identical. See
-- docs/spec/SHADOW-SEMANTICS.md § "2. Decision matrix (re-observed 2026-07-14,
-- post-`eb92cdff`; now GATED)" rows 21a/21b for the fixed bug and its fixtures.
export
standaloneShadowsFromSet : GraphCtx ->
  (String -> Bool) ->
  OrdMap Unit ->
  List Decl ->
  List String
standaloneShadowsFromSet gctx isMethod fnSet prog =
  -- Both probes below run once per GRAPH-WIDE fn name, so both of their tables are
  -- sets: a `contains` over the module's own names and a `lookupAssoc` over the
  -- definer-shadow map were each O(names x table) here.
  let localNames = namesToSet (map fst (funDefs prog)) omEmpty
  let direct =
    filter (n => isMethod n && not (omHasKey n localNames)) (omKeys fnSet)
  let sm = gctx.mangledShadowMapRef.value
  let mangled =
    flatMap
      (n => match lookupAssoc n sm
        Some bare => if omHasKey n localNames then [] else [bare]
        None => [])
      (omKeys fnSet)
  dedup (direct ++ mangled)

-- ── #1354 unit A (#1353): SHADOW-SEMANTICS S1's `nameable in M` interface operand ──
-- `docs/spec/SHADOW-SEMANTICS.md` S1 (SCOPE RULED 2026-08-06, #1375) intersects
-- funDef-names(standalones defined in or imported into `M`) with
-- iface-method-names(interfaces **nameable in `M`**).  `methodNameDeclaredAt` answers
-- for the method names of EVERY module at or before `M`'s ordinal, so the two builders
-- above implement the LEFT operand's scope (the `fnSet`/`localNames` guards) and give the
-- RIGHT one none: an interface reachable only transitively, through a module that
-- re-exports nothing, captured a standalone the occurrence's module had explicitly
-- imported (#1353, S0 — `7` instead of `99`, at exit 0, no diagnostic).
--
-- The remedy is a SUPPLY, not a re-scope: the membership test is correct and narrowing
-- it would answer a question nobody asks of it.  This is the missing predicate, applied to
-- the ALREADY-COMPUTED intersection rather than inside either operand's filter — the
-- intersection is single-digit in practice (over `compiler/**` + `stdlib/*` it is 3:
-- `toList`, `isEmpty`, `orElse`) while `fnSet` holds every top-level fn name in the graph,
-- so filtering the result is cheap and filtering the operand is not.
--
-- The predicate asks A TYPE-NAMESPACE QUESTION, and getting that wrong is how the first
-- cut of this fix shipped two defects at once — see `meIfaceExports` for both, measured.
-- §1.0's row says `nameable in M` qualifies **S1's INTERFACE operand**; asking instead
-- whether the METHOD NAME is exported along the import path is a different question that
-- answers differently in BOTH directions.
--
-- It fails open, deliberately, and that direction is load-BEARING.  Dropping shadow-hood
-- from an occurrence that IS one makes it dispatch unconditionally (`recordRLocalSite`'s
-- `standaloneValuesRef` guard declines, so no pending site exists for
-- `resolveRLocalSites` to stamp and the route stays the method's RKey) — the S4/#410
-- class, up to `no impl of method … for type …` on a valid program and a SIGSEGV variant.
-- Adding shadow-hood is the pre-existing behaviour.  So an ABSENT index answers True for
-- every name rather than False: `meIfaceExports` rides `declEnvsRef`, written
-- unconditionally at the one Module-mode driver entry, `graphPreamble`
-- (`checkModulesPreambleK` is its projection — the conjunction stated in full on
-- `meExports`, which shares that write), and a driver
-- that ever omits that write must degrade to today's graph-global answer, not to "nothing
-- is a shadow anywhere".
--
-- SCOPE, stated so it is not over-read.  The predicate is `nameable in M` as §1.0 defines
-- it, applied to S1's INTERFACE operand — so it covers BOTH failures S1 names, the
-- reachability one (#1353: no import path reaches the declaring module) and the one where a
-- path exists but does not carry the interface.  What it does NOT decide is #1302's axis:
-- `meIfaceExports` has no `pub` filter, so a module that imports a dependency BY NAME can
-- still be told about that dependency's PRIVATE interface.  That is the fail-open direction
-- and it is left exactly where #1302 and `declMethodIdentsOf`'s F3 already own it.
export
nameableIfaceShadows : GraphCtx -> List Decl -> List String -> List String
nameableIfaceShadows gctx _ [] = []
nameableIfaceShadows gctx prog names
  -- fail OPEN on an absent index — see the paragraph above; `names` unchanged is exactly
  -- the pre-#1353 graph-global answer.
  | omSize (ifaceExportsIndex gctx ()) == 0 = names
  | otherwise =
    let nameable = nameableIfaceMethodSet gctx prog
    filterList (n => omHasKey n nameable) names

-- The bare method names of every interface NAMEABLE in module [prog] — S1's three
-- nameable-in-`M` positions, built ONCE per module: the implicit prelude (`core`'s row),
-- this module's own interfaces, and, for each `DUse`, the interfaces THAT USE-PATH ADMITS
-- out of the dependency's row (which already carries what the dependency re-exports, at any
-- chain depth — S1-CHAIN, #1380).
--
-- THE USE-path filter is the whole point, and its absence was this fix's first defect.
-- Taking a dependency's WHOLE row on any import makes `import smod.{sf}` — one unrelated
-- function — enough to make `smod`'s interface "nameable", which it demonstrably is not:
-- `impl Sizeable Blob` in that module is rejected `Unknown interface: Sizeable`.  That left
-- #1353 narrowed rather than fixed (its own repro with the bridge hop removed still printed
-- the impl's value).  `selectIfaceRows` is shared with the re-export side so the import and
-- chain answers cannot drift apart.
--
-- Name-level rather than identity-level ON PURPOSE.  S1's intersection is over NAMES, so
-- when two interfaces declare `n` and only one is nameable here, `n` is a shadow either
-- way; which declaration an occurrence then means is `methodScopeAt`'s question
-- about a different table (`MethodEnv`'s rows), and answering it here would be
-- a second resolver free to disagree with that one.
--
-- THIS IS S1's right operand under S1-NS (RULED 2026-08-08), and it is the ONLY predicate
-- in the compiler that answers it — `checkBodyImpl`'s shadow-hood and EVERY filter in the
-- mark pass read THIS set.  Named rather than counted, because a count rots silently and
-- this sentence already did (it said "all three" for a week after `rpNames` became the
-- fourth): `moduleMarkCtx` filters `rpNames`, `shadowNames` (through
-- `shadowBareName`), `argNames` and `shadowMap` — its own `otherwise` arm enumerates them
-- against what `rewriteArgScoped` can turn into an `EMethodAt`.  S1-NS (b) requires
-- shadow-hood to be a superset of dispatch
-- eligibility and rules two different predicates at the two sites non-conformant; one set
-- makes them equal, so the invariant holds by construction rather than by test.  Do not
-- introduce a second, wider set for marking: that splits `run` from the built binary or
-- yields a `build`-only E-PANIC (each an S0).
--
-- The per-METHOD union of the two namespaces lives in `selectIfaceRows`, applied on the
-- import arm here and on the re-export arm in `meIfaceExports`.
export
nameableIfaceMethodSet : GraphCtx -> List Decl -> OrdMap Unit
nameableIfaceMethodSet gctx prog =
  namesToSet (flatMap snd (nameableIfaceRows gctx prog)) omEmpty

-- The same operand ONE level less flattened: the (interface name, its method names)
-- ROWS, not just the union of their method names.  `nameableIfaceMethodSet` above is
-- defined as this list's flattening, so there is still exactly ONE derivation of S1's
-- right operand — a diagnostic that needs to name WHICH interface owns a colliding
-- method (#2738's `W-IMPORT-METHOD-SHADOW`) must not answer that from a second,
-- independently-scoped walk, which is what S1-NS (b) rules non-conformant.
--
-- `ifaceMethodRows prog` is `allIfaceMethodNames prog` grouped by declaration: both walk
-- `DAttrib`/`DInterface` in the same order and take `ifaceMethodNames methods`, so the
-- flattening above is the previous expression term for term.
export
nameableIfaceRows : GraphCtx -> List Decl -> List (String, List String)
nameableIfaceRows gctx prog =
  nameableIfaceRowsIn (ifaceExportsIndex gctx ()) prog

-- `nameableIfaceRows` over the interface-row index [idx].
nameableIfaceRowsIn : OrdMap (List (String, List String)) ->
  List Decl ->
  List (String, List String)
nameableIfaceRowsIn idx prog =
  optionOr [] (omLookup "core" idx)
    ++ ifaceMethodRows prog
    ++ importedIfaceRows idx prog

-- ── #2738: a selectively imported standalone displaced by a nameable method ──
-- The peer of `frontend/marker.mdk`'s `preludeStandaloneShadows` for the IMPORTER
-- direction, and it is sited here rather than beside it because the two operands it
-- needs live here: S1's right operand (`nameableIfaceRows`, the only predicate in the
-- compiler that answers `nameable in M`) and, through it, the interface a colliding
-- method name belongs to.  `compiler/frontend/marker.mdk` cannot reach either —
-- `types/typecheck.mdk` imports `frontend.marker`, so the edge does not run the other
-- way — and re-deriving the operand there is what S1-NS (b) rules non-conformant.
--
-- Yields one entry per DIFFERING-scheme collision, in declaration order:
--   (bound name, the interface declaring it, the standalone's declared signature,
--    the method's declared signature, the import member's own span).
-- The standalone signature is `None` when the defining module declares the function
-- without a signature: a scheme that cannot be read cannot be shown harmless, so it
-- counts as differing.  Identical (alpha-equivalent) signatures yield nothing, which is
-- what keeps the everyday `import m.{f}` silent.
--
-- SELECTIVE imports only (`UseGroup`).  A wildcard or bare import makes no statement
-- about the name, and a module alias binds a DOTTED local (`A.f`) that no bare method
-- name can collide with; the ruling is scoped to the explicit member list, which is the
-- strongest statement the language offers about which binding is meant.
--
-- Fails CLOSED on an absent index, the opposite of `nameableIfaceShadows` above and for
-- the opposite reason: that predicate decides resolution, where dropping shadow-hood
-- miscompiles, while this one only decides a warning, where a graph-global operand would
-- fire on collisions the module cannot name.
export
importedStandaloneShadows : DriveOutputs ->
  List (String, List Decl) ->
  List Decl ->
  List (String, String, Option Ty, Ty, Loc)
importedStandaloneShadows o graph prog =
  importedStandaloneShadowsIn o.doIfaceExports graph prog

-- `importedStandaloneShadows` over the interface-row index [idx], for a caller whose
-- index is not the last drive's: a single file analysed before its drive passes
-- `omEmpty`, which answers nothing.
export
importedStandaloneShadowsIn : OrdMap (List (String, List String)) ->
  List (String, List Decl) ->
  List Decl ->
  List (String, String, Option Ty, Ty, Loc)
importedStandaloneShadowsIn idx graph prog
  | omSize idx == 0 = []
  | otherwise =
    let rows = nameableIfaceRowsIn idx prog
    let nameable = namesToSet (flatMap snd rows) omEmpty
    let universe = flatMap snd graph ++ prog
    flatMap (importShadowsOfDecl graph rows nameable universe) prog

-- The catch-all arms here are exhaustive by construction, not by omission: a shadow can
-- only arise from an explicit member list, so every non-`DUse` declaration and every
-- non-`UseGroup` use path contributes nothing by the scoping rule stated above.
importShadowsOfDecl : List (String, List Decl) ->
  List (String, List String) ->
  OrdMap Unit ->
  List Decl ->
  Decl ->
  List (String, String, Option Ty, Ty, Loc)
importShadowsOfDecl graph rows nameable universe (DAttrib _ d) =
  importShadowsOfDecl graph rows nameable universe d
importShadowsOfDecl graph rows nameable universe (DUse _ path _) = match path
  UseGroup _ ms => match lookupAssoc (useModId path) graph
    None => []
    Some depDecls =>
      flatMap (importMemberShadow graph rows nameable universe depDecls) ms
  _ => []
importShadowsOfDecl _ _ _ _ _ = []

importMemberShadow : List (String, List Decl) ->
  List (String, List String) ->
  OrdMap Unit ->
  List Decl ->
  List Decl ->
  UseMember ->
  List (String, String, Option Ty, Ty, Loc)
importMemberShadow graph rows nameable universe depDecls (UseMember origin _ mloc alias) =
  let local = match alias
    Some a => a
    None => origin
  if not (omHasKey local nameable) then
    []
  else match reachableStandaloneSig graph (listLen graph) depDecls origin
    None => []
    Some sty => match ifaceMethodSigFor local sty rows universe
      None => []
      Some (iface, mty) => [(local, iface, sty, mty, mloc)]

schemesAgree : Option Ty -> Ty -> Bool
schemesAgree None _ = False
schemesAgree (Some sty) mty = tyAlphaEq sty mty

-- A NAMEABLE interface declaring [name] whose signature differs from the standalone's
-- [sty], with that signature.  When two or more differ, the least by interface name and
-- then by rendered signature, so the warning reads the same in every import order
-- (S2-DECL (e)).  Rows whose declaration is not in [universe] are skipped rather than
-- guessed at.
ifaceMethodSigFor : String ->
  Option Ty ->
  List (String, List String) ->
  List Decl ->
  Option (String, Ty)
ifaceMethodSigFor _ _ [] _ = None
ifaceMethodSigFor name sty ((iface, ms) :: rest) universe =
  let later = ifaceMethodSigFor name sty rest universe
  if not (contains name ms) then
    later
  else match ifaceMethodTyIn iface name universe
    Some ty =>
      if schemesAgree sty ty then later else leastIfaceSig (iface, ty) later
    None => later

leastIfaceSig : (String, Ty) -> Option (String, Ty) -> Option (String, Ty)
leastIfaceSig a None = Some a
leastIfaceSig (a@(ia, ta)) (Some (b@(ib, tb)))
  | ia < ib = Some a
  | ib < ia = Some b
  | ppTy ta <= ppTy tb = Some a
  | otherwise = Some b

ifaceMethodTyIn : String -> String -> List Decl -> Option Ty
ifaceMethodTyIn _ _ [] = None
ifaceMethodTyIn iface name ((DAttrib _ d) :: rest) =
  let inner = ifaceMethodTyIn iface name [d]
  match inner
    Some ty => Some ty
    None => ifaceMethodTyIn iface name rest
ifaceMethodTyIn iface name ((DInterface { name = n, methods, ... }) :: rest)
  | n == iface = match ifaceMethodTyOf name methods
    Some ty => Some ty
    None => ifaceMethodTyIn iface name rest
  | otherwise = ifaceMethodTyIn iface name rest
ifaceMethodTyIn iface name (_ :: rest) = ifaceMethodTyIn iface name rest

ifaceMethodTyOf : String -> List IfaceMethod -> Option Ty
ifaceMethodTyOf _ [] = None
ifaceMethodTyOf name ((IfaceMethod n ty _ _) :: rest)
  | n == name = Some ty
  | otherwise = ifaceMethodTyOf name rest

-- The standalone the imported member actually names, THROUGH `export import` hops:
-- `Some sig` when a module reachable from [decls] declares [name] as a top-level
-- function (`sig` being its declared signature, or `None` when it has none — a scheme
-- that cannot be read cannot be shown harmless, which is what `schemesAgree` then does
-- with it), and `None` when no such standalone exists at all.
--
-- The hop is not optional; it is what the spec asks for.  Reading only the DIRECTLY
-- imported module's own `DFunDef`s made the detector silent for a standalone that
-- reaches the importer through a re-exporter, which is the same silent displacement
-- #2738 names — `SHADOW-SEMANTICS.md`'s `nameable in M` row puts re-export chains in
-- scope (#1380) and S1-NS (a) rules the re-export arm SYMMETRIC with the import arm, so
-- a detector that answers only the direct case contradicts its own right operand, which
-- `meIfaceExports` already folds over chains of any depth.
--
-- The member list is followed the same way the re-export side follows it — through
-- `importedBindings`, the one place a use-path's (origin, local) bindings are derived —
-- so `export import m.{f as g}` re-exported as `g` looks `f` up in `m`, and a wildcard
-- re-export passes the name through unchanged.  A second walker keyed on a
-- hand-enumerated set of `UsePath` forms would drift from that one the first time a form
-- is added.
--
-- [fuel] bounds the chain at the number of modules in the compile, so a re-export cycle
-- terminates here rather than relying on the loader having rejected it upstream.
reachableStandaloneSig : List (String, List Decl) ->
  Int ->
  List Decl ->
  String ->
  Option (Option Ty)
reachableStandaloneSig graph fuel decls name
  | declaresStandalone name decls = Some (standaloneSigOf name decls)
  | fuel <= 0 = None
  | otherwise =
    reachableStandaloneSigGo graph (fuel - 1) (reexportedOrigins decls name)

reachableStandaloneSigGo : List (String, List Decl) ->
  Int ->
  List (String, String) ->
  Option (Option Ty)
reachableStandaloneSigGo _ _ [] = None
reachableStandaloneSigGo graph fuel ((mid, n) :: rest) =
  match lookupAssoc mid graph
    None => reachableStandaloneSigGo graph fuel rest
    Some ds => match reachableStandaloneSig graph fuel ds n
      Some sig => Some sig
      None => reachableStandaloneSigGo graph fuel rest

-- Every (dependency module id, name in THAT module) an `export import` in [decls] could
-- have re-exported [name] from.  A non-exporting `import` contributes nothing: it puts
-- no name into the re-exporter's own exports, so nothing downstream can reach through
-- it.
--
-- The catch-all arm is exhaustive by that rule rather than by omission — a re-export is
-- representable only as a `DUse True`, wrapped in `DAttrib` or not, so no other `Decl`
-- constructor can contribute a hop and a new one never will.  Its ledgered peer
-- `reexportedIfaceMethodsOf` (the interface-row half of the same walk) carries the same
-- two arms for the same reason.
reexportedOrigins : List Decl -> String -> List (String, String)
reexportedOrigins decls name = flatMap (d => reexportedOriginsOf d name) decls

reexportedOriginsOf : Decl -> String -> List (String, String)
reexportedOriginsOf (DAttrib _ d) name = reexportedOriginsOf d name
reexportedOriginsOf (DUse True path _) name = match importedBindings path
  None => [(useModId path, name)]
  Some bs =>
    map (b => (useModId path, fst b)) (filterList (b => snd b == name) bs)
reexportedOriginsOf _ _ = []

declaresStandalone : String -> List Decl -> Bool
declaresStandalone _ [] = False
declaresStandalone n ((DAttrib _ d) :: rest) =
  declaresStandalone n [d] || declaresStandalone n rest
declaresStandalone n ((DFunDef _ m _ _ _ _) :: rest) =
  m == n || declaresStandalone n rest
declaresStandalone n (_ :: rest) = declaresStandalone n rest

standaloneSigOf : String -> List Decl -> Option Ty
standaloneSigOf _ [] = None
standaloneSigOf n ((DAttrib _ d) :: rest) = match standaloneSigOf n [d]
  Some t => Some t
  None => standaloneSigOf n rest
standaloneSigOf n ((DTypeSig _ m ty _) :: rest)
  | m == n = Some ty
  | otherwise = standaloneSigOf n rest
standaloneSigOf n (_ :: rest) = standaloneSigOf n rest

-- Alpha-equivalence of two SURFACE signatures: equal up to a consistent renaming of
-- type variables, so `Box a -> a` and `Box b -> b` agree while `Box a -> (String, a)`
-- and `t a -> a` do not.  The bijection is carried both ways, so `a -> b` and `a -> a`
-- do not agree either.  Any shape not matched pairwise below is treated as DIFFERING,
-- which is the direction that warns, and every arm that IS matched pairwise compares
-- every field that can carry a type variable — a field skipped there errs toward
-- AGREEING, the silent direction, which is what a `listLen`-only `TyConstrained` arm did
-- (`Eq a => b -> a -> String` and `Debug a => t -> a -> String` compared equal, and the
-- displacement they name went unreported at exit 0).  The two fields deliberately not
-- compared are `TyCon`'s `tyConOrigin` and `TyRow`'s `Option Loc`: neither is part of the
-- written scheme, and `Constraint`'s `constraintOrigin` is skipped for the same reason.
tyAlphaEq : Ty -> Ty -> Bool
tyAlphaEq a b = match tyAlphaGo [] a b
  Some _ => True
  None => False

tyAlphaGo : List (String, String) -> Ty -> Ty -> Option (List (String, String))
tyAlphaGo m (TyVar x) (TyVar y) = bindTyName m x y
tyAlphaGo m (TyCon { tyConName = x }) (TyCon { tyConName = y })
  | x == y = Some m
  | otherwise = None
tyAlphaGo m (TyApp f x) (TyApp g y) = match tyAlphaGo m f g
  None => None
  Some m2 => tyAlphaGo m2 x y
tyAlphaGo m (TyFun a b) (TyFun c d) = match tyAlphaGo m a c
  None => None
  Some m2 => tyAlphaGo m2 b d
tyAlphaGo m (TyTuple xs) (TyTuple ys) = tyAlphaList m xs ys
tyAlphaGo m (TyEffect e1 t1 a) (TyEffect e2 t2 b)
  | sameWrittenAtoms e1 e2 && t1 == t2 = tyAlphaGo m a b
  | otherwise = None
-- BODY FIRST, then the constraints, and the order is load-bearing rather than
-- stylistic: the body is where a scheme's type variables are pinned, so matching it
-- first fixes the bijection the constraint comparison then only has to check.  The
-- reverse order has to GUESS which of two same-head constraints (`Eq a, Eq b => a -> b`
-- vs `Eq d, Eq c => c -> d`) pairs with which, and a wrong greedy guess reports a
-- false difference on two schemes that are the same.
tyAlphaGo m (TyConstrained c1 a) (TyConstrained c2 b)
  | listLen c1 /= listLen c2 = None
  | otherwise = match tyAlphaGo m a b
    None => None
    Some m2 => tyAlphaConstraints m2 c1 c2
tyAlphaGo m (TyRow e1 t1 _) (TyRow e2 t2 _)
  | sameWrittenAtoms e1 e2 && t1 == t2 = Some m
  | otherwise = None
tyAlphaGo _ _ _ = None

-- Two written rows agree when their atoms spell the same; the declaration
-- identity is not part of alpha-equivalence, which compares source shapes.
sameWrittenAtoms : List EffAtomTy -> List EffAtomTy -> Bool
sameWrittenAtoms e1 e2 =
  map (effAtomSurface escStr) e1 == map (effAtomSurface escStr) e2

tyAlphaList : List (String, String) ->
  List Ty ->
  List Ty ->
  Option (List (String, String))
tyAlphaList m [] [] = Some m
tyAlphaList m (x :: xs) (y :: ys) = match tyAlphaGo m x y
  None => None
  Some m2 => tyAlphaList m2 xs ys
tyAlphaList _ _ _ = None

-- A constraint SET, not a constraint list: `Eq a, Debug b =>` and `Debug b, Eq a =>`
-- are the same scheme, so a positional comparison would warn on two declarations that
-- differ only in the order the author wrote them — a false positive on correct code.
-- Each constraint of [c1] is therefore matched against any still-unconsumed member of
-- [c2].  The lists are equal-length at entry (the caller's guard), so consuming one per
-- step leaves nothing over.
tyAlphaConstraints : List (String, String) ->
  List Constraint ->
  List Constraint ->
  Option (List (String, String))
tyAlphaConstraints m [] _ = Some m
tyAlphaConstraints m (c :: rest) cs2 = match takeAlphaConstraint m c cs2 []
  None => None
  Some (m2, left) => tyAlphaConstraints m2 rest left

-- the first member of [cs] that matches [c], paired with the REMAINING members.  Their
-- order in that remainder is immaterial — this is a set comparison — so the rejected
-- prefix is simply appended back.
takeAlphaConstraint : List (String, String) ->
  Constraint ->
  List Constraint ->
  List Constraint ->
  Option (List (String, String), List Constraint)
takeAlphaConstraint _ _ [] _ = None
takeAlphaConstraint m c (d :: rest) tried = match tyAlphaConstraint m c d
  Some m2 => Some (m2, tried ++ rest)
  None => takeAlphaConstraint m c rest (d :: tried)

-- Same interface, and pairwise alpha-equal arguments under the map the body already
-- pinned.  `constraintOrigin` is identity metadata the surface signature does not carry
-- — the peer of `tyConOrigin`, skipped by the `TyCon` arm for the same reason.
tyAlphaConstraint : List (String, String) ->
  Constraint ->
  Constraint ->
  Option (List (String, String))
tyAlphaConstraint m (Constraint { constraintHead = h1, constraintArgs = as1, ... }) (Constraint { constraintHead = h2, constraintArgs = as2, ... })
  | h1 == h2 = tyAlphaList m as1 as2
  | otherwise = None

bindTyName : List (String, String) ->
  String ->
  String ->
  Option (List (String, String))
bindTyName m x y = match lookupAssoc x m
  Some y2 => if y2 == y then Some m else None
  None => if anyList (e => snd e == y) m then None else Some ((x, y) :: m)

-- C5: graph-wide standalone-shadow names — every top-level funDef name in [userDecls]
-- (the user modules, NOT core) that is also an interface method name anywhere in
-- [allDecls].  Used by the MARK pass to rewrite such occurrences to EMethodAt (so the
-- route ref exists for resolveRLocalSites to stamp).  Excludes core's own decls as the
-- funDef source so core's elaboration (no standalone shadows there) is untouched.
-- P0-18: recover, per (module, iface-method) pair, the mangled standalone symbol the
-- mangler produced for a definer-shadow funDef.  Forward-constructs `mangledName mid
-- method` (using the KNOWN mid — exact, not lossy prefix-stripping) and checks it
-- against the module's actual funDef names; a hit is a `(mangledSymbol ↦ bareMethod)`
-- entry.  On the un-mangled path no funDef matches → [] → every consumer unchanged.
export
computeMangledShadowMap : List Decl ->
  List (String, List Decl) ->
  List (String, String)
computeMangledShadowMap allDecls units =
  -- DEDUPED: `allIfaceMethodNames` walks every `DInterface` in the graph and a method
  -- name declared by two interfaces appears twice, so an undeduped list mints the SAME
  -- `(sym ↦ bare)` row twice per unit.  The rows are identical, so no reader's answer
  -- changes; what changes is the size of the table every reader below walks or indexes.
  let methodNames = dedup (allIfaceMethodNames allDecls)
  flatMap (unitMangledShadows methodNames) units

-- The unit's funDef names are an INDEX, not a list: this probes once per interface
-- method, so a `contains` here is O(methods x funDefs) — a shape where both grow
-- together (N interfaces beside N top-level bindings) makes it quadratic.  Same
-- treatment as `prePassDictArg`'s name sets (#2189).
-- #2809: the bare row.  Mangling now runs AFTER elaboration, so a definer shadow's
-- funDef carries the name its author wrote and the forward-constructed `<mid>__m` matches
-- nothing.  The row is what `rewriteArgScoped`'s `sm` arm reads to seed the occurrence
-- with its standalone SYMBOL, and that symbol is what the later rename moves
-- (`private_mangle`'s `EMethodAt` seed arm and `mangleRoute`) into the emitted direct
-- call.  Without it the route names the bare METHOD, whose define the rename has already
-- moved, and the emitter calls a symbol DCE pruned: `use of undefined value
-- '@mdk_orElse'`, on the compiler's own `frontend.parser`.
-- On the bare row `sym == bare`, so `moduleSpellsShadowBare`'s definer arm admits it in
-- the module that defines the standalone and its import arm in a module that spells the
-- bare name -- the same two admitting cases #1684 ruled for the mangled row.
-- The prelude unit contributes no row: shadow-SEMANTICS S1-PRELUDE (a) puts the implicit
-- prelude in neither half of S1's standalone operand, so no `core.mdk` occurrence is a
-- user interface method's shadow -- the asymmetry `appendUniverseAccums` states, and the
-- direction #2153's `core__not ↦ not` incident was paid for.
unitMangledShadows : List String -> (String, List Decl) -> List (String, String)
unitMangledShadows methodNames (mid, decls) =
  let fns = omFromNames (map fst (funDefs decls)) omEmpty
  flatMap
    (m =>
      let sym = mangledName mid m
      if omHasKey sym fns then
        [(sym, m)]
      else if not (isPreludeMid mid) && omHasKey m fns then
        [(m, m)]
      else
        [])
    methodNames

export
buildStandaloneShadowsGraph : List (String, String) ->
  List Decl ->
  List Decl ->
  List String
buildStandaloneShadowsGraph sm allDecls userDecls =
  -- INDEX, not a list: this probes once per user funDef, so a `contains` over the
  -- interface-method names is O(funDefs x methods) — quadratic on a program whose
  -- interface count and top-level binding count grow together.
  let methodNames = omFromNames (allIfaceMethodNames allDecls) omEmpty
  let fns = dedup (map fst (funDefs userDecls))
  let direct = filter (n => omHasKey n methodNames) fns
  -- P0-18: written for the order where the EMIT path's funDef names were MANGLED
  -- (`<mid>__toList`), which the `direct` name-intersection misses; the map recovered
  -- them so the prePass marked their occurrences `EMethodAt`.
  -- #2809: no path reaches this with mangled funDefs any more, and the map is non-empty
  -- on ALL of them — the rows are `(name ↦ name)`, so this filter selects the funDef
  -- names `direct` already selected and the union is unchanged.  The header 25 lines up
  -- states that retirement.  The filter stays because it recovers a genuinely mangled row
  -- if one appears (a hand-written `<mid>__toList` mints one), and `dedup` makes the
  -- redundancy free.
  let mangled = filter (n => isSome (lookupAssoc n sm)) fns
  dedup (direct ++ mangled)

-- ── #2153: S1's `nameable in M` for the PRELUDE unit ─────────────────────────
-- `moduleMarkCtx` filters the definer-shadow map at the CONSUMING module.
-- `core` is the one unit that never goes through that filter: its context is built
-- from the RAW graph-wide map.  That is
-- fine for `rpNames`/`argNames` — they are BARE method names, and core's references to its
-- own standalones are all mangled `core__<n>` by the time this runs, so neither set can
-- match one (the P0-21 argument `elaborateModules` states at `markRpNames`).  It is NOT
-- fine for the shadow map, which is keyed by exactly those mangled symbols.
--
-- MEASURED (#2153): `computeMangledShadowMap` walks `("core", coreDecls)` against the
-- GRAPH-WIDE method-name list, so a USER module declaring `interface Ifc c where not : …`
-- mints `core__not ↦ not`.  `rewriteArgScoped`'s `sm` arm then rewrote CORE's OWN
-- `core__not` occurrence (in `neq`, `notElem`, a core prop, …) to `EMethodAt "not"`, and
-- core's env has no `not` — so `medaka build` died `E-PANIC: unbound method: not` on a
-- program `check` and `run` both accept, and even on one that never mentions the method.
-- That is the whole 22-name FAIL_BUILD class in `test/prelude_shadow_census.ledger`: a
-- prelude standalone reaches this arm only when ANOTHER prelude decl references it, which
-- is the very split `frontend/marker.mdk`'s `droppablePreludeFns` names (`clamp` yes,
-- `count`/`find` no) — and it is why the fix `types/private_mangle.mdk` landed for the
-- module's OWN occurrences could not reach these: the surviving occurrence is core's.
--
-- The rule applied is S1's own: an interface method declared in a USER module is not
-- nameable in `core`, so no `core.mdk` occurrence can be its shadow.  Same predicate and
-- same fail-OPEN guard as the per-module filter above — sited beside it so the two stay
-- auditable as a SET rather than as two independent answers to one question.
--
-- #2809 added the second conjunct, and its absence was measured.  With mangling moved
-- after elaboration a definer-shadow row is `(name ↦ name)`, so `map`'s standalone
-- `toList` and the prelude's OWN `Foldable.toList` occurrence in a specialized default
-- body (`impl Foldable Option`'s `isEmpty`) spell the same key: the nameable test alone
-- admitted the row, `rewriteArgScoped`'s `sm` arm seeded core's method occurrence with
-- `RLocal "toList"`, and the emitter turned a dispatch into a direct call to a symbol
-- core does not define — `use of undefined value '@mdk_toList'`, i.e. #2153's incident
-- with the bare spelling as the key.  `moduleSpellsShadowBare` is the SAME occurrence-
-- spelling test the per-module filter applies, so core is scoped by one rule, not two.
export
coreShadowMapFor : GraphCtx ->
  List Decl ->
  List (String, String) ->
  List (String, String)
coreShadowMapFor gctx coreProg shadowMap
  | omSize (ifaceExportsIndex gctx ()) == 0 = shadowMap
  | otherwise =
    let nameable = nameableIfaceMethodSet gctx coreProg
    let sc = spellCtxOf gctx coreProg
    filterList
      (e =>
        omHasKey (snd e) nameable && moduleSpellsShadowBare sc (fst e) (snd e))
      shadowMap

-- ── #1684: S1's STANDALONE operand, at the OCCURRENCE spelling ───────────────
-- The two filters above answer S1's INTERFACE operand (`nameable in M`) and nothing
-- else.  That is sufficient on the un-mangled check/run path, where an occurrence
-- carries the spelling the author wrote — but NOT on the emit path, where
-- `types/private_mangle.mdk` has already collapsed BOTH spellings of an imported
-- standalone onto ONE symbol:
--
--   import amod.{shrink}  → `shrink`    ⎫
--   import amod as A      → `A.shrink`  ⎭ → both become `EVar "amod__shrink"`
--
-- `computeMangledShadowMap` then recovers `amod__shrink ↦ shrink` from the DEFINING
-- module's funDefs and `rewriteArgScoped`'s `sm` arm rewrites EVERY occurrence of that
-- symbol to `EMethodAt "shrink"` — including the alias-qualified one, which was never
-- an S1 occurrence at all.  §1.0's standalone-operand row is *"defined in `M` or
-- imported into `M`"*, and `import amod as A` imports the standalone into `M` under the
-- local name `A.shrink`; bare `shrink` is bound by no import form there, so it names
-- nothing in `M` and can shadow nothing in `M`.
--
-- MEASURED (#1684, S0): a two-file program whose only interface is the PRELUDE's
-- `Arbitrary` — no `impl` and no `interface` written anywhere in it — had `A.shrink 5`
-- emitted as a call to `@mdk_impl_Int_shrink`, so the built binary printed
-- `Arbitrary.shrink`'s list default `[0, 2]` while `run` printed the standalone's `6`.
-- Both at exit 0, no diagnostic on any channel.
--
-- So the emit path must reconstruct what the mangle erased: admit a mangled shadow
-- symbol only where `M` actually spells its BARE name.  Two admitting cases, and the
-- test is over IMPORT FORMS rather than over the symbol's origin module, so a name
-- reaching `M` through a re-export chain (whose `useModId` is the re-exporter,
-- not the definer) is admitted exactly as it is today:
--   * `M` DEFINES the symbol itself — the definer shadow (P0-18), unchanged.
--   * some import form in `M` binds the LOCAL name `bare`: a member list naming it, or
--     a wildcard.  A module alias (`Some []`) and a member alias (`{size as sz}`, whose
--     local is `sz`) bind it under a different spelling, so neither admits it — and
--     both then agree with what the un-mangled path already does with that spelling.
-- Empty shadowMap ⇒ `lookupAssoc` misses ⇒ True ⇒ the check/run path is untouched.
export
shadowSymSpelledBare : SpellCtx -> List (String, String) -> String -> Bool
shadowSymSpelledBare sc sm n = match lookupAssoc n sm
  None => True
  Some bare => moduleSpellsShadowBare sc n bare

spellCtxOf : GraphCtx -> List Decl -> SpellCtx
spellCtxOf gctx prog = SpellCtx {
  scTopFns = declTopFnNames prog,
  scBare = declBareLocals gctx prog BareLocals { blAll = False, blSet = [] },
  scCorePfx = mangledName "core" "",
}

export
moduleSpellsShadowBare : SpellCtx -> String -> String -> Bool
moduleSpellsShadowBare sc sym bare =
  contains sym sc.scTopFns
    || startsWith sc.scCorePfx sym && sym == "\{sc.scCorePfx}\{bare}"
    || bareLocalBound sc.scBare bare

bareLocalBound : BareLocals -> String -> Bool
bareLocalBound bl bare = bl.blAll || contains bare bl.blSet

declBareLocals : GraphCtx -> List Decl -> BareLocals -> BareLocals
declBareLocals gctx [] acc = acc
declBareLocals gctx ((DAttrib _ d) :: rest) acc =
  declBareLocals gctx rest (declBareLocals gctx [d] acc)
declBareLocals gctx ((DUse _ path _) :: rest) acc =
  declBareLocals gctx rest (formBareLocals gctx path acc)
declBareLocals gctx (_ :: rest) acc = declBareLocals gctx rest acc

-- one form's contribution.  `None` is the wildcard `import m.*`, which binds every export
-- of `m` under its own name; a module alias (`Some []`) and a member alias
-- (`{size as sz}`, whose local is `sz`) bind under a different spelling and so contribute
-- that spelling, not `size`.  Each contribution is intersected with what the dependency
-- actually EXPORTS AS A STANDALONE — S1's second conjunct, stated on
-- `depExportsStandalone` below.
formBareLocals : GraphCtx -> UsePath -> BareLocals -> BareLocals
formBareLocals gctx path acc =
  let depId = useModId path
  match importedBindings path
    None =>
      if depExportsUnknown gctx depId then
        { acc | blAll = True }
      else
        { acc | blSet = map fst (graphPubDefiners gctx depId) ++ acc.blSet }
    Some bindings => { acc |
      blSet =
        filterList (l => depExportsStandalone gctx depId l) (map snd bindings)
          ++ acc.blSet,
    }

-- the BARE interface-method name a (possibly mangled) standalone-shadow symbol stands for.
-- Identity on the un-mangled run/check path, where the map is empty.
export
shadowBareName : List (String, String) -> String -> String
shadowBareName sm n = match lookupAssoc n sm
  Some bare => bare
  None => n

-- Method nameability and standalone availability are independent. The wrapper
-- admits standalone routes only for this module's definitions or actual imported
-- standalone descriptors, never for private functions elsewhere in the graph.
export
methodMarkCtx : GraphCtx -> MarkSets -> String -> List Decl -> MarkCtx
methodMarkCtx gctx ms "" coreProg
  | omSize (ifaceExportsIndex gctx ()) == 0 = MarkCtx {
    mcRp = omFromNames ms.msMarkRpNames omEmpty,
    mcAn = omFromNames ms.msArgNames omEmpty,
    mcSm = ms.msCoreShadowMap,
  }
  | otherwise =
    let nameable = nameableIfaceMethodSet gctx coreProg
    let keep = n => omHasKey n nameable
    MarkCtx {
      mcRp = omFromNames (filterList keep ms.msMarkRpNames) omEmpty,
      mcAn = omFromNames (filterList keep ms.msArgNames) omEmpty,
      mcSm = ms.msCoreShadowMap,
    }
methodMarkCtx gctx ms _ prog
  -- fail OPEN when the graph index is absent, for the reason stated on
  -- `nameableIfaceShadows`: an unscoped mark set is today's behaviour, an empty one is the
  -- S4/#410 class.
  -- Guard the index this arm actually reads: the body reads `meIfaceExports`, so the
  -- guard tests that and not its sibling `meExports` — testing one while reading the
  -- other is an implicit conjunction of exactly the kind `registry_keying_ratchet`
  -- exists to forbid.  Run with an empty iface index, the other arm would filter out
  -- every imported and prelude shadow name, failing closed into the S4/#410 class that
  -- `nameableIfaceShadows` says must never happen.
  | omSize (ifaceExportsIndex gctx ()) == 0 =
    let aliasRows = aliasMethodSpellings gctx prog
    MarkCtx {
      mcRp =
        withAliasMethodNames
          aliasRows
          (omFromNames
            (dedup (ms.msMarkSharedNames ++ ms.msGraphShadowNames))
            omEmpty),
      mcAn = withAliasMethodNames aliasRows (omFromNames ms.msArgNames omEmpty),
      mcSm = gctx.mangledShadowMapRef.value,
    }
  | otherwise =
    -- S1-NS (b), the closure invariant.  The spec requires the predicate deciding
    -- SHADOW-HOOD to be a SUPERSET of the one deciding DISPATCH ELIGIBILITY, and rules two
    -- different predicates at the two sites non-conformant whichever way they differ.
    --
    -- The invariant is about inputs to dispatch, not about sets or selectors.
    -- `rewriteArgScoped` dispatches on `rp`, `an` AND `sm`, so every one of those
    -- inputs must be filtered, `rpNames` included: an unfiltered `rpNames` makes
    -- dispatch-eligibility a strict superset of shadow-hood, and a return-position
    -- method of a non-nameable interface then runs with no diagnostic (`run` gave 777
    -- against a built binary of 42, both exit 0).
    --
    -- THE ENUMERATION, so the next reader checks the SET rather than trusting a sentence.
    -- Every input `rewriteArgScoped` can turn into an `EMethodAt` is filtered here:
    --   * `rpNames`   — return-position method names AND method-level-constraint method
    --                   names (`markSharedNames` concatenates both).  BOTH are interface
    --                   METHOD names — each walks `DInterface`'s `methods` — so both are the
    --                   same kind of set as `argNames` and both are filtered.
    --   * `shadowNames` — via `shadowBareName`, because on the emit path these are mangled.
    --   * `argNames`  — arg-position dispatch indices.
    --   * `shadowMap` — the emit-path peer of `argNames`.
    -- `dictNames` is the ONE input deliberately NOT filtered, and it is not an input to
    -- dispatch at all: it produces `EDictAt`, a dict application of a `=>`-constrained
    -- FUNCTION, which selects no impl from a receiver.  Filtering it would drop a dict
    -- argument and UNDER-APPLY the callee (`unbound identifier: $dict_…`, the Phase-134
    -- shape) — so it is disjoint by node kind, not by name, and that is probed rather than
    -- argued (see `test/shadow_fixtures/`'s return-position cells and the PR body).
    let nameable = nameableIfaceMethodSet gctx prog
    let keep = n => omHasKey n nameable
    let shadowMap = gctx.mangledShadowMapRef.value
    -- The occurrence-spelling context, taken ONCE for this module rather than rebuilt
    -- inside each filter below — per row it was most of this cell's measured
    -- regression; see `SpellCtx`.
    let sc = spellCtxOf gctx prog
    let aliasRows = aliasMethodSpellings gctx prog
    MarkCtx {
      mcRp =
        withAliasMethodNames
          aliasRows
          (omFromNames
            (dedup
              (filterList keep ms.msMarkSharedNames
                ++ filterList
                  (n =>
                    omHasKey (shadowBareName shadowMap n) nameable
                      && shadowSymSpelledBare sc shadowMap n)
                  ms.msGraphShadowNames))
            omEmpty),
      mcAn =
        withAliasMethodNames
          aliasRows
          (omFromNames (filterList keep ms.msArgNames) omEmpty),
      mcSm =
        filterList
          (e =>
            omHasKey (snd e) nameable
              && moduleSpellsShadowBare sc (fst e) (snd e))
          shadowMap,
    }

-- `moduleMarkCtx ms mid prog`: core (`mid == ""`) is marked with the unsplit set and
-- the core-scoped shadow map (#2153).  A user module gets the split set, scoped by the
-- filter below.
--
-- CORE'S rp/arg SETS ARE S1-FILTERED TOO, and the argument that they need not be is
-- retired.  It read: "core's references to its own standalones are all mangled
-- `core__<n>` by the time this runs, so neither set can match one."  #2809 moved
-- mangling AFTER elaboration, so core's references now carry the names its author
-- wrote and a USER interface method spelled like a core standalone matches them.
-- MEASURED on `test/prelude_shadow_census.ledger`'s own probe shape — `interface Ifc c
-- where identity : c -> Int` beside `impl Ifc Int`, in a module that defines no
-- `identity` — `check` and `run` accept and print 1 while `build` died `E-PANIC: no
-- impl of method 'identity' for type 'List'`: core's own `identity` call, on a `List`,
-- had been rewritten to a dispatch on the USER's interface.  Four ledger rows
-- (`identity`, `otherwise`, `arbitraryList`, `arbitraryString`) moved PASS -> FAIL_BUILD
-- that way.  The rule applied is the one `coreShadowMapFor` already applies to the
-- shadow map for the same reason: an interface declared in a USER module is not
-- nameable in `core`, so no `core.mdk` occurrence is one of its method occurrences.
-- Same fail-OPEN guard as `nameableIfaceShadows`: an absent graph index leaves the sets
-- unfiltered rather than emptying them.
export
moduleMarkCtx : GraphCtx ->
  MarkSets ->
  String ->
  List Decl ->
  OrdMap Scheme ->
  MarkCtx
moduleMarkCtx gctx ms mid prog imported =
  let candidates = methodMarkCtx gctx ms mid prog
  let local = namesToSet (declTopFnNames prog) omEmpty
  -- A module's own extern denotes itself wherever the module spells it, as its
  -- own function named like an interface method does (SHADOW-SEMANTICS S2's
  -- definer arm), so its occurrences are never method occurrences.
  let externs = namesToSet (declExternNames prog) omEmpty
  MarkCtx {
    mcRp = IdMap.difference candidates.mcRp externs,
    mcAn = IdMap.difference candidates.mcAn externs,
    mcSm =
      filterList
        (entry => omHasKey (fst entry) local || omHasKey (snd entry) imported)
        candidates.mcSm,
  }
# DESUGAR
(DUse false (UseGroup ("support" "diag_codes") ((mem "DiagCode" true))))
(DUse false (UseGroup ("types" "tc_types") ((mem "StandaloneOrigin" true) (mem "CDeclaredPrefix" true) (mem "AdmittedAnswer" true) (mem "AdmittedVerdict" true) (mem "BareLocals" true) (mem "CDeclared" true) (mem "DynCtx" true) (mem "ShadowDicts" true) (mem "SpellCtx" true) (mem "TcEnv" true) (mem "CSlot" false) (mem "DriveOutputs" false) (mem "EvCell" false) (mem "GraphCtx" false) (mem "ImplEnv" false) (mem "MethodTrackedInstantiation" false) (mem "ModuleCtx" false) (mem "SiteCtx" false) (mem "siteFor" false) (mem "ValueScheme" false) (mem "MarkCtx" true) (mem "MarkSets" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "headMonoNode" false) (mem "headTyconMono" false) (mem "monoIsTyvarId" false) (mem "nthFunDomain" false) (mem "nthMono" false) (mem "substMono" false) (mem "tyvarId" false))))
(DUse false (UseGroup ("types" "tc_diag_text") ((mem "ambiguousShadowHelp" false) (mem "shadowIfaceLabel" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "dynAt" false) (mem "emptyShadowDicts" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "declTopFnNames" false) (mem "depExportsStandalone" false) (mem "depExportsUnknown" false) (mem "funDefs" false) (mem "graphPubDefiners" false) (mem "ieImplExistsForHeadOf" false) (mem "ifaceExportsIndex" false) (mem "ifaceMethodRows" false) (mem "importedBindings" false) (mem "lookupIdxById" false) (mem "lookupStandaloneValue" false) (mem "lookupStandaloneVar" false) (mem "lookupVar" false) (mem "methodRowIface" false) (mem "namesToSet" false) (mem "removeAllS" false) (mem "standaloneValueFor" false) (mem "hasImportDefiner" false) (mem "lookupImportedStandalone" false) (mem "allIfaceMethodNames" false))))
(DUse false (UseGroup ("types" "tc_diag") ((mem "pushTypeErrorAt" false) (mem "pushTypeErrorHelpFixAt" false))))
(DUse false (UseGroup ("types" "tc_scope") ((mem "ieImplExistsForHead" false) (mem "ifaceSortKey" false) (mem "methodAdmittedHere" false) (mem "methodDispatchIdx" false) (mem "methodEntryHere" false) (mem "methodVisibleHere" false) (mem "importedIfaceRows" false) (mem "aliasMethodSpellings" false) (mem "withAliasMethodNames" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "clampPrefix" false) (mem "instantiate" false) (mem "instantiateMethodTracked" false) (mem "predicateSlotArgs" false) (mem "predicateSlotCSlots" false) (mem "qualConstraintDecl" false) (mem "unifyIn" false) (mem "unifySpineProbe" false) (mem "zipSlotVecs" false))))
(DUse false (UseGroup ("types" "tc_decls") ((mem "sigToScheme" false))))
(DUse false (UseGroup ("types" "tc_solve_givens") ((mem "lookupPredicateSlots" false))))
(DUse false (UseGroup ("types" "tc_solve") ((mem "admittedSelection" false) (mem "routeLocalSym" false) (mem "routesOfMonosTopV" false))))
(DUse false (UseGroup ("types" "tc_solve_check") ((mem "dedupSlotVecs" false) (mem "ifaceSelfAndSupers" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Constraint" true) (mem "Decl" true) (mem "EffAtomTy" true) (mem "EvId" true) (mem "Expr" true) (mem "IfaceMethod" true) (mem "Loc" true) (mem "Route" true) (mem "Ty" true) (mem "UseMember" true) (mem "UsePath" true) (mem "effAtomSurface" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Mono" true) (mem "Scheme" true) (mem "lookupAssocI" false) (mem "normalize" false) (mem "ppMono" false) (mem "ppTy" false))))
(DUse false (UseGroup ("types" "evidence_complete") ((mem "Inner" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omKeys" false) (mem "omLookup" false) (mem "omSize" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("types" "evidence") ((mem "ScopeId" true))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "anyList" false) (mem "contains" false) (mem "dedup" false) (mem "escStr" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "isSome" false) (mem "joinWith" false) (mem "listLen" false) (mem "lookupAssoc" false) (mem "maxI" false) (mem "reverseL" false) (mem "startsWith" false))))
(DUse false (UseGroup ("list") ((mem "head" false))))
(DUse false (UseGroup ("frontend" "marker") ((mem "localBoundNames" false))))
(DUse false (UseGroup ("types" "private_mangle") ((mem "mangledName" false))))
(DUse false (UseGroup ("frontend" "visibility") ((mem "useModId" false))))
(DUse false (UseAlias ("map") "IdMap"))
(DUse false (UseGroup ("types" "tc_foreign") ((mem "declExternNames" false))))
(DTypeSig true "recoveredShadowSym" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyCon "String"))))
(DFunDef false "recoveredShadowSym" ((PVar "name") (PVar "tagRef")) (EBlock (DoLet false false (PVar "s") (EApp (EVar "routeLocalSym") (EUnOp "!" (EVar "tagRef")))) (DoExpr (EIf (EBinOp "==" (EVar "s") (EVar "name")) (ELit (LString "")) (EVar "s")))))
(DTypeSig true "methodCellOf" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvId") (TyCon "EvCell"))))
(DFunDef false "methodCellOf" ((PVar "gctx") (PVar "ev")) (EMatch (EApp (EApp (EVar "methodCellLookup") (EVar "gctx")) (EVar "ev")) (arm (PCon "Ok" (PVar "c")) () (EVar "c")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "panic") (EVar "message")))))
(DTypeSig true "methodCellLookup" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvId") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "EvCell")))))
(DFunDef false "methodCellLookup" ((PVar "gctx") (PCon "EvId" (PVar "m") (PVar "n"))) (EBlock (DoLet false false (PVar "g") (EFieldAccess (EVar "gctx") "graphRun")) (DoLet false false (PVar "i") (EBinOp "-" (EVar "n") (EFieldAccess (EVar "g") "evBase"))) (DoLet false false (PVar "arr") (EFieldAccess (EFieldAccess (EVar "g") "evCells") "value")) (DoExpr (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "method cell ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " is from an earlier graph")))) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "method cell ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " was never minted")))) (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (arm (PCon "Some" (PVar "c")) () (EApp (EVar "Ok") (EVar "c"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "method cell ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " was never minted")))))))))))
(DTypeSig true "declaredEffectsAt" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "MethodTrackedInstantiation") (TyFun (TyApp (TyCon "Option") (TyCon "CDeclared")) (TyApp (TyCon "Option") (TyCon "CDeclared"))))))
(DFunDef false "declaredEffectsAt" ((PVar "gctx") (PVar "inst") (PVar "declared")) (EApp (EApp (EVar "map") (ELam ((PVar "dc")) (ERecordCreate "CDeclared" ((fa "cdSlots" (EFieldAccess (EVar "dc") "cdSlots")) (fa "cdPrefix" (EFieldAccess (EVar "dc") "cdPrefix")) (fa "cdArgs" (EApp (EApp (EVar "map") (EApp (EVar "map") (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EListLit)) (EFieldAccess (EFieldAccess (EVar "inst") "mtiSubstitution") "misEffectSubst")) (EFieldAccess (EFieldAccess (EVar "inst") "mtiSubstitution") "misAuthSubst")))) (EFieldAccess (EVar "dc") "cdArgs"))))))) (EVar "declared")))
(DTypeSig true "declaredConstraintFor" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "CDeclared"))))
(DFunDef false "declaredConstraintFor" ((PVar "mctx") (PVar "name")) (EMatch (EApp (EApp (EVar "qualConstraintDecl") (EVar "mctx")) (EVar "name")) (arm (PCon "Some" (PVar "d")) () (EVar "d")) (arm (PCon "None") () (EIf (EApp (EApp (EVar "hasImportDefiner") (EVar "mctx")) (EVar "name")) (ERecordCreate "CDeclared" ((fa "cdSlots" (EListLit)) (fa "cdPrefix" (EApp (EVar "CDPLen") (ELit (LInt 0)))) (fa "cdArgs" (EListLit)))) (EApp (EApp (EVar "localDeclaredConstraintFor") (EVar "mctx")) (EVar "name"))))))
(DTypeSig false "localDeclaredConstraintFor" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "CDeclared"))))
(DFunDef false "localDeclaredConstraintFor" ((PVar "mctx") (PVar "name")) (EBlock (DoLet false false (PVar "stored") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "lookupPredicateSlots") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funPredicateSlotsIdxRef") "value")))) (DoLet false false (PVar "slots") (EApp (EVar "predicateSlotCSlots") (EVar "stored"))) (DoExpr (ERecordCreate "CDeclared" ((fa "cdSlots" (EVar "slots")) (fa "cdPrefix" (EApp (EApp (EVar "clampPrefix") (EVar "slots")) (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funConstraintDeclaredRef") "value")))) (fa "cdArgs" (EApp (EVar "predicateSlotArgs") (EVar "stored"))))))))
(DTypeSig true "callArgVecsV" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "CSlot") (TyApp (TyCon "List") (TyCon "Mono")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Mono")))))))
(DFunDef false "callArgVecsV" ((PVar "gctx") (PList) PWild) (EListLit))
(DFunDef false "callArgVecsV" ((PVar "gctx") (PCons (PTuple (PVar "s") (PVar "v")) (PVar "rest")) (PVar "subst")) (EMatch (EApp (EApp (EVar "lookupAssocI") (EFieldAccess (EVar "s") "csId")) (EVar "subst")) (arm (PCon "Some" (PVar "m")) () (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "substArgVec") (EVar "gctx")) (EVar "subst")) (EVar "m")) (EVar "v")) (EApp (EApp (EApp (EVar "callArgVecsV") (EVar "gctx")) (EVar "rest")) (EVar "subst")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "callArgVecsV") (EVar "gctx")) (EVar "rest")) (EVar "subst")))))
(DTypeSig false "substArgVec" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "Mono")))))))
(DFunDef false "substArgVec" ((PVar "gctx") PWild (PVar "m") (PList)) (EListLit (EVar "m")))
(DFunDef false "substArgVec" ((PVar "gctx") (PVar "subst") PWild (PVar "v")) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EVar "subst")) (EListLit)) (EListLit))) (EVar "v")))
(DTypeSig true "constraintMonosOf" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "constraintMonosOf" ((PList) PWild) (EListLit))
(DFunDef false "constraintMonosOf" ((PCons (PVar "id") (PVar "rest")) (PVar "subst")) (EMatch (EApp (EApp (EVar "lookupAssocI") (EVar "id")) (EVar "subst")) (arm (PCon "Some" (PVar "m")) () (EBinOp "::" (EVar "m") (EApp (EApp (EVar "constraintMonosOf") (EVar "rest")) (EVar "subst")))) (arm (PCon "None") () (EApp (EApp (EVar "constraintMonosOf") (EVar "rest")) (EVar "subst")))))
(DTypeSig true "checkAdmittedOccObls" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "Unit"))))
(DFunDef false "checkAdmittedOccObls" ((PVar "mctx") PWild) (EBlock (DoLet false false (PVar "env") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "bodyImplEnvRef") "value")) (DoExpr (EApp (EApp (EVar "each") (ELam ((PVar "o")) (EApp (EApp (EApp (EVar "checkAdmittedOccObl") (EVar "mctx")) (EVar "env")) (EVar "o")))) (EApp (EVar "reverseL") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "admittedOccObls") "value"))))))
(DTypeSig false "checkAdmittedOccObl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ImplEnv") (TyFun (TyTuple (TyCon "String") (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Unit")))))
(DFunDef false "checkAdmittedOccObl" ((PVar "mctx") (PVar "env") (PTuple (PVar "name") (PVar "mono") (PVar "loc"))) (EBlock (DoLet false false (PVar "ifs") (EApp (EApp (EVar "methodAdmittedHere") (EVar "mctx")) (EVar "name"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "admittedSelection") (EApp (EVar "siteFor") (EVar "mctx"))) (EVar "env")) (EVar "name")) (EVar "mono")) (arm (PCon "Selects" PWild PWild PWild) () (ELit LUnit)) (arm (PCon "Undecided") () (EApp (EApp (EApp (EApp (EVar "pushAmbiguousMethod") (EVar "mctx")) (EVar "name")) (EVar "ifs")) (EVar "loc"))) (arm (PCon "Unroutable" (PVar "sel")) () (EApp (EApp (EApp (EApp (EApp (EVar "pushUnroutableAdmitted") (EVar "mctx")) (EVar "name")) (EVar "ifs")) (EVar "sel")) (EVar "loc"))) (arm (PCon "SelectsNothing") () (EBlock (DoLet false false (PVar "recv") (EMatch (EApp (EApp (EApp (EApp (EVar "admittedReceiverMono") (EVar "mctx")) (EVar "name")) (EVar "ifs")) (EVar "mono")) (arm (PCon "Some" (PVar "at")) () (EApp (EVar "ppMono") (EVar "at"))) (arm (PCon "None") () (ELit (LString "this receiver"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (EVar "TNoImpl")) (EVar "loc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "no impl of ")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " or "))) (EApp (EApp (EVar "map") (ELam ((PVar "ir")) (EFieldAccess (EVar "ir") "irName"))) (EVar "ifs"))))) (ELit (LString " for "))) (EApp (EVar "display") (EVar "recv"))) (ELit (LString "; write an impl of one of them for it")))))))))))
(DTypeSig false "admittedReceiverMono" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "IfaceRef")) (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "Mono")))))))
(DFunDef false "admittedReceiverMono" ((PVar "mctx") PWild (PList) PWild) (EVar "None"))
(DFunDef false "admittedReceiverMono" ((PVar "mctx") (PVar "name") (PCons (PVar "ir") PWild) (PVar "mono")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "lookupIdxById") (EVar "ir")) (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodDispatchIdxByIdRef") "value"))) (ELam ((PVar "k")) (EApp (EApp (EVar "nthFunDomain") (EVar "k")) (EVar "mono")))))
(DTypeSig false "appSpineHead" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "appSpineHead" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "appSpineHead") (EVar "e")))
(DFunDef false "appSpineHead" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "appSpineHead") (EVar "f")))
(DFunDef false "appSpineHead" ((PVar "e")) (EVar "e"))
(DTypeSig false "appSpineNodes" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "appSpineNodes" ((PVar "e")) (EApp (EApp (EVar "appSpineNodesGo") (EVar "e")) (EListLit)))
(DTypeSig false "appSpineNodesGo" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Expr")))))
(DFunDef false "appSpineNodesGo" ((PCon "ELoc" PWild (PVar "e")) (PVar "acc")) (EApp (EApp (EVar "appSpineNodesGo") (EVar "e")) (EVar "acc")))
(DFunDef false "appSpineNodesGo" ((PCon "EApp" (PVar "f") (PVar "x")) (PVar "acc")) (EApp (EApp (EVar "appSpineNodesGo") (EVar "f")) (EBinOp "::" (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")) (EVar "acc"))))
(DFunDef false "appSpineNodesGo" (PWild (PVar "acc")) (EVar "acc"))
(DTypeSig true "plainAppHeadVar" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "plainAppHeadVar" ((PVar "env") (PVar "hd")) (EMatch (EApp (EApp (EVar "shadowStandaloneHead") (EVar "env")) (EVar "hd")) (arm (PCon "Some" PWild) () (EVar "False")) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "definerShadowArgHead") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "hd")) (arm (PCon "Some" PWild) () (EVar "False")) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "definerShadowVarHead") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "hd")) (arm (PCon "Some" PWild) () (EVar "False")) (arm (PCon "None") () (EVar "True"))))))))
(DTypeSig true "shadowStandaloneHead" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Int")))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Ref") (TyCon "Route")) (TyApp (TyCon "Ref") (TyCon "Inner")))))))))
(DFunDef false "shadowStandaloneHead" ((PVar "env") (PCon "ELoc" PWild (PVar "f"))) (EApp (EApp (EVar "shadowStandaloneHead") (EVar "env")) (EVar "f")))
(DFunDef false "shadowStandaloneHead" ((PVar "env") (PCon "EMethodAt" (PVar "name") PWild (PVar "ev"))) (EIf (EApp (EApp (EVar "isShadowStandalone") (EVar "env")) (EVar "name")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "methodCellOf") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "ev"))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "name") (EListLit (EFieldAccess (EVar "c") "ecArity")) (EListLit (ETuple (EFieldAccess (EVar "c") "ecTag") (EFieldAccess (EVar "c") "ecInner"))))))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "shadowStandaloneHead" ((PVar "env") (PCon "EVar" (PVar "name"))) (EIf (EApp (EApp (EVar "isShadowStandalone") (EVar "env")) (EVar "name")) (EApp (EVar "Some") (ETuple (EVar "name") (EListLit) (EListLit))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "shadowStandaloneHead" ((PVar "env") (PCon "EVarId" (PVar "name") PWild)) (EIf (EApp (EApp (EVar "isShadowStandalone") (EVar "env")) (EVar "name")) (EApp (EVar "Some") (ETuple (EVar "name") (EListLit) (EListLit))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "shadowStandaloneHead" ((PVar "env") PWild) (EVar "None"))
(DTypeSig true "shadowStandaloneSpineHeadAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Int")))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Ref") (TyCon "Route")) (TyApp (TyCon "Ref") (TyCon "Inner")))) (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr")))))))
(DFunDef false "shadowStandaloneSpineHeadAt" ((PVar "env") (PVar "f")) (EMatch (EApp (EApp (EVar "shadowStandaloneHead") (EVar "env")) (EApp (EVar "appSpineHead") (EVar "f"))) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple (PVar "name") (PVar "arityRefs") (PVar "tagRefs"))) () (EApp (EApp (EVar "map") (ELam ((PVar "nodes")) (ETuple (EVar "name") (EVar "arityRefs") (EVar "tagRefs") (EApp (EVar "appSpineHead") (EVar "f")) (EVar "nodes")))) (EApp (EApp (EApp (EVar "shadowSpineNodesAtImporter") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "f"))))))
(DTypeSig true "isShadowStandalone" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isShadowStandalone" ((PVar "env") (PVar "name")) (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "standaloneValuesRef") "value")) (EApp (EVar "isSome") (EApp (EApp (EVar "lookupImportedStandalone") (EVar "env")) (EVar "name")))) (EApp (EApp (EVar "singleTyparamIfaceMethod") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name"))))
(DTypeSig false "singleTyparamIfaceMethod" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "singleTyparamIfaceMethod" ((PVar "mctx") (PVar "name")) (EMatch (EApp (EApp (EVar "methodEntryHere") (EVar "mctx")) (EVar "name")) (arm (PCon "Some" (PTuple PWild (PVar "typarams") PWild PWild)) () (EBinOp "==" (EApp (EVar "listLen") (EVar "typarams")) (ELit (LInt 1)))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "methodAdmittedHere") (EVar "mctx")) (EVar "name")) (arm (PList) () (EVar "False")) (arm (PVar "ifs") () (EApp (EApp (EVar "allList") (ELam ((PVar "r")) (EMatch (EFieldAccess (EVar "r") "mrEntry") (arm (PTuple PWild (PVar "typarams") PWild PWild) () (EBinOp "==" (EApp (EVar "listLen") (EVar "typarams")) (ELit (LInt 1))))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EBlock (DoLet false false (PVar "key") (EApp (EVar "ifaceSortKey") (EApp (EVar "methodRowIface") (EVar "r")))) (DoExpr (EApp (EApp (EVar "anyList") (ELam ((PVar "ir")) (EBinOp "==" (EApp (EVar "ifaceSortKey") (EVar "ir")) (EVar "key")))) (EVar "ifs")))))) (EApp (EApp (EVar "methodVisibleHere") (EVar "mctx")) (EVar "name")))))))))
(DTypeSig false "ifaceMethodName" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "ifaceMethodName" ((PVar "mctx") (PVar "name")) (EBinOp "||" (EApp (EVar "isSome") (EApp (EApp (EVar "methodEntryHere") (EVar "mctx")) (EVar "name"))) (EApp (EVar "isNonEmptyL") (EApp (EApp (EVar "methodAdmittedHere") (EVar "mctx")) (EVar "name")))))
(DTypeSig true "stampRoutes" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Route"))) (TyCon "Unit")))
(DFunDef false "stampRoutes" ((PList)) (ELit LUnit))
(DFunDef false "stampRoutes" ((PCons (PVar "r") (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "r")) (EApp (EApp (EVar "RLocal") (EApp (EVar "routeLocalSym") (EUnOp "!" (EVar "r")))) (EListLit)))) (DoExpr (EApp (EVar "stampRoutes") (EVar "rest")))))
(DTypeSig true "stampMethodArities" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Int")))) (TyFun (TyCon "Int") (TyCon "Unit"))))
(DFunDef false "stampMethodArities" ((PList) PWild) (ELit LUnit))
(DFunDef false "stampMethodArities" ((PCons (PVar "r") (PVar "rest")) (PVar "arity")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "r")) (EApp (EVar "Some") (EVar "arity")))) (DoExpr (EApp (EApp (EVar "stampMethodArities") (EVar "rest")) (EVar "arity")))))
(DTypeSig true "shadowHeadEnv" (TyFun (TyCon "TcEnv") (TyCon "TcEnv")))
(DFunDef false "shadowHeadEnv" ((PVar "env")) (ERecordUpdate (EVar "env") ((fa "teDyn" (ERecordUpdate (EFieldAccess (EVar "env") "teDyn") ((fa "dcShadowHeadCtx" (EVar "True"))))))))
(DTypeSig true "importerShadowDomain" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Mono")))))
(DFunDef false "importerShadowDomain" ((PVar "env") (PVar "mname")) (EMatch (EApp (EApp (EVar "lookupStandaloneVar") (EVar "env")) (EVar "mname")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "s")) () (EMatch (EApp (EVar "normalize") (EApp (EApp (EVar "instantiate") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "s"))) (arm (PCon "TFun" (PVar "a") PWild PWild) () (EApp (EVar "Some") (EVar "a"))) (arm PWild () (EVar "None"))))))
(DTypeSig true "importerShadowDomainAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Mono"))))))
(DFunDef false "importerShadowDomainAt" ((PVar "env") (PVar "mname") (PVar "k")) (EMatch (EApp (EApp (EVar "lookupStandaloneVar") (EVar "env")) (EVar "mname")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "s")) () (EApp (EApp (EVar "nthFunDomain") (EVar "k")) (EApp (EApp (EVar "instantiate") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "s"))))))
(DTypeSig true "definerShadowArgHead" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Int"))) (TyApp (TyCon "Ref") (TyCon "Route")) (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyApp (TyCon "Ref") (TyCon "Inner")))))))
(DFunDef false "definerShadowArgHead" ((PVar "mctx") (PCon "ELoc" PWild (PVar "f"))) (EApp (EApp (EVar "definerShadowArgHead") (EVar "mctx")) (EVar "f")))
(DFunDef false "definerShadowArgHead" ((PVar "mctx") (PCon "EMethodAt" (PVar "name") PWild (PVar "ev"))) (EApp (EApp (EApp (EVar "definerShadowArgHeadCell") (EVar "mctx")) (EVar "name")) (EApp (EApp (EVar "methodCellOf") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ev"))))
(DFunDef false "definerShadowArgHead" ((PVar "mctx") PWild) (EVar "None"))
(DTypeSig false "definerShadowArgHeadCell" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "EvCell") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Int"))) (TyApp (TyCon "Ref") (TyCon "Route")) (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyApp (TyCon "Ref") (TyCon "Inner"))))))))
(DFunDef false "definerShadowArgHeadCell" ((PVar "mctx") (PVar "name") (PVar "c")) (EIf (EBinOp "||" (EApp (EApp (EVar "isDefinerShadow") (EVar "mctx")) (EVar "name")) (EApp (EApp (EApp (EVar "importerShadowOnEmitPath") (EVar "mctx")) (EVar "name")) (EFieldAccess (EVar "c") "ecTag"))) (EApp (EVar "Some") (ETuple (EVar "name") (EFieldAccess (EVar "c") "ecArity") (EFieldAccess (EVar "c") "ecTag") (EFieldAccess (EVar "c") "ecImpl") (EFieldAccess (EVar "c") "ecInner"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "occurrenceCarriesMangledShadowSym" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyCon "Bool"))))
(DFunDef false "occurrenceCarriesMangledShadowSym" ((PVar "name") (PVar "tagRef")) (EBinOp "/=" (EApp (EApp (EVar "recoveredShadowSym") (EVar "name")) (EVar "tagRef")) (ELit (LString ""))))
(DTypeSig false "importerShadowOnEmitPath" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyCon "Bool")))))
(DFunDef false "importerShadowOnEmitPath" ((PVar "mctx") (PVar "name") (PVar "tagRef")) (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "singleTyparamIfaceMethod") (EVar "mctx")) (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "mangledFunDefsPresentRef") "value")) (EApp (EApp (EVar "occurrenceCarriesMangledShadowSym") (EVar "name")) (EVar "tagRef"))))
(DTypeSig true "isDefinerShadow" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isDefinerShadow" ((PVar "mctx") (PVar "name")) (EBinOp "&&" (EApp (EApp (EVar "ifaceMethodName") (EVar "mctx")) (EVar "name")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "definerShadowNamesRef") "value"))))
(DTypeSig true "definerReceiverDispatches" (TyFun (TyCon "DynCtx") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyCon "Bool")))))
(DFunDef false "definerReceiverDispatches" ((PVar "dyn") (PVar "name") (PVar "xt")) (EIf (EApp (EApp (EVar "isDefinerShadow") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "name")) (EApp (EApp (EApp (EVar "definerReceiverIsDictVar") (EVar "dyn")) (EVar "name")) (EVar "xt")) (EIf (EVar "otherwise") (EMatch (EApp (EVar "headTyconMono") (EVar "xt")) (arm (PCon "Some" (PVar "head")) () (EApp (EApp (EApp (EApp (EVar "ieImplExistsForHead") (EFieldAccess (EVar "dyn") "dcModule")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "bodyImplEnvRef") "value")) (EVar "name")) (EVar "head"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "definerReceiverIsDictVar") (EVar "dyn")) (EVar "name")) (EVar "xt")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "definerReceiverIsDictVar" (TyFun (TyCon "DynCtx") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyCon "Bool")))))
(DFunDef false "definerReceiverIsDictVar" ((PVar "dyn") (PVar "name") (PVar "xt")) (EMatch (EApp (EVar "headMonoNode") (EVar "xt")) (arm (PCon "TVar" (PVar "cell")) () (EMatch (EApp (EApp (EVar "methodEntryHere") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "name")) (arm (PCon "Some" (PTuple (PVar "mIface") PWild PWild PWild)) () (EApp (EApp (EApp (EApp (EVar "dictVarSatisfiesIface") (EFieldAccess (EVar "dyn") "dcModule")) (EFieldAccess (EVar "mIface") "irName")) (EApp (EVar "tyvarId") (EVar "cell"))) (EApp (EVar "groupMonos") (EVar "dyn")))) (arm (PCon "None") () (EVar "False")))) (arm PWild () (EVar "False"))))
(DTypeSig false "groupMonos" (TyFun (TyCon "DynCtx") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))))
(DFunDef false "groupMonos" ((PVar "dyn")) (EMatch (EFieldAccess (EVar "dyn") "dcGroup") (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "group")) () (EFieldAccess (EVar "group") "gcMonos"))))
(DTypeSig false "dictVarSatisfiesIface" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyCon "Bool"))))))
(DFunDef false "dictVarSatisfiesIface" ((PVar "mctx") PWild PWild (PList)) (EVar "False"))
(DFunDef false "dictVarSatisfiesIface" ((PVar "mctx") (PVar "mIface") (PVar "id") (PCons (PTuple (PVar "cIface") (PVar "cm")) (PVar "rest"))) (EIf (EBinOp "&&" (EApp (EApp (EVar "monoIsTyvarId") (EVar "cm")) (EVar "id")) (EApp (EApp (EVar "contains") (EVar "mIface")) (EApp (EApp (EVar "ifaceSelfAndSupers") (EVar "mctx")) (EVar "cIface")))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "dictVarSatisfiesIface") (EVar "mctx")) (EVar "mIface")) (EVar "id")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "enforceStandaloneDomainAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Int") (TyCon "Unit")))))))
(DFunDef false "enforceStandaloneDomainAt" ((PVar "env") (PVar "name") (PVar "xt") (PVar "dloc") (PVar "k")) (EMatch (EApp (EApp (EApp (EVar "standaloneShadowDomainAt") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "k")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "dom")) () (EIf (EApp (EApp (EApp (EVar "definerReceiverIsDictVar") (EFieldAccess (EVar "env") "teDyn")) (EVar "name")) (EVar "xt")) (ELit LUnit) (EApp (EApp (EApp (EApp (EVar "unifyStandaloneDomain") (EFieldAccess (EVar "env") "teDyn")) (EVar "dom")) (EVar "xt")) (EVar "dloc"))))))
(DTypeSig true "groundShadowReceiver" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "Option") (TyCon "Mono")) (TyFun (TyCon "Mono") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit")))))))
(DFunDef false "groundShadowReceiver" ((PVar "dyn") (PVar "dom") (PVar "xt") (PVar "isDictVar") (PVar "dloc")) (EIf (EVar "isDictVar") (ELit LUnit) (EIf (EApp (EVar "isSome") (EApp (EVar "headTyconMono") (EVar "xt"))) (ELit LUnit) (EIf (EVar "otherwise") (EMatch (EVar "dom") (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "d")) () (EApp (EApp (EApp (EApp (EVar "unifyStandaloneDomain") (EVar "dyn")) (EVar "d")) (EVar "xt")) (EVar "dloc")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "shadowDomainForAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Mono")))))))
(DFunDef false "shadowDomainForAt" ((PVar "env") (PVar "name") (PLit (LString "")) (PVar "k")) (EApp (EApp (EApp (EVar "standaloneShadowDomainAt") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "k")))
(DFunDef false "shadowDomainForAt" ((PVar "env") PWild (PVar "sym") (PVar "k")) (EMatch (EApp (EApp (EVar "lookupVar") (EVar "env")) (EVar "sym")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "s")) () (EApp (EApp (EVar "nthFunDomain") (EVar "k")) (EApp (EApp (EVar "instantiate") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "s"))))))
(DTypeSig false "unifyStandaloneDomain" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit"))))))
(DFunDef false "unifyStandaloneDomain" ((PVar "dyn") (PVar "dom") (PVar "xt") (PVar "dloc")) (EApp (EApp (EApp (EVar "unifyIn") (EApp (EApp (EVar "dynAt") (EVar "dloc")) (EVar "dyn"))) (EVar "dom")) (EVar "xt")))
(DTypeSig true "standaloneShadowDomainAt" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Mono"))))))
(DFunDef false "standaloneShadowDomainAt" ((PVar "mctx") (PVar "name") (PVar "k")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "definerShadowSigsRef") "value")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "ty")) () (EApp (EApp (EVar "nthFunDomain") (EVar "k")) (EApp (EApp (EVar "instantiate") (EVar "mctx")) (EApp (EApp (EVar "sigToScheme") (EVar "mctx")) (EVar "ty")))))))
(DTypeSig true "rejectAdmittedValueOccurrence" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Unit"))))
(DFunDef false "rejectAdmittedValueOccurrence" ((PVar "mctx") (PVar "name")) (EIf (EApp (EApp (EVar "isDefinerShadow") (EVar "mctx")) (EVar "name")) (ELit LUnit) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "ifs") (EApp (EApp (EVar "methodAdmittedHere") (EVar "mctx")) (EVar "name"))) (DoExpr (EIf (EBinOp ">=" (EApp (EVar "listLen") (EVar "ifs")) (ELit (LInt 2))) (EApp (EApp (EApp (EApp (EVar "pushAmbiguousShadowDecl") (EVar "mctx")) (EVar "name")) (EVar "ifs")) (EFieldAccess (EVar "mctx") "mcLoc")) (ELit LUnit)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "standaloneValueBinding" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "ValueScheme")))))
(DFunDef false "standaloneValueBinding" ((PVar "env") (PVar "name")) (EIf (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcShadowHeadCtx") (EVar "None") (EIf (EBinOp "&&" (EApp (EApp (EVar "ifaceMethodName") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "definerShadowNamesRef") "value"))) (EApp (EApp (EVar "lookupStandaloneValue") (EVar "env")) (EVar "name")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "singleTyparamIfaceMethod") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name"))) (EVar "None") (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupStandaloneValue") (EVar "env")) (EVar "name")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig true "standaloneValueBindingEmit" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyApp (TyCon "Option") (TyCon "ValueScheme"))))))
(DFunDef false "standaloneValueBindingEmit" ((PVar "env") (PVar "name") (PVar "tagRef")) (EIf (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcShadowHeadCtx") (EVar "None") (EIf (EBinOp "==" (EApp (EApp (EVar "recoveredShadowSym") (EVar "name")) (EVar "tagRef")) (ELit (LString ""))) (EVar "None") (EIf (EApp (EVar "not") (EApp (EApp (EVar "emitValueShadowGate") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name"))) (EVar "None") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "standaloneValueFor") (EVar "env")) (EVar "name")) (EApp (EApp (EVar "recoveredShadowSym") (EVar "name")) (EVar "tagRef"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "emitValueShadowGate" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "emitValueShadowGate" ((PVar "mctx") (PVar "name")) (EIf (EApp (EApp (EVar "isDefinerShadow") (EVar "mctx")) (EVar "name")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "singleTyparamIfaceMethod") (EVar "mctx")) (EVar "name")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "standaloneValuePinned" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "standaloneValuePinned" ((PVar "env") (PVar "name")) (EApp (EVar "isSome") (EApp (EApp (EVar "standaloneValueBinding") (EVar "env")) (EVar "name"))))
(DTypeSig true "definerShadowVarHead" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "definerShadowVarHead" ((PVar "mctx") (PCon "ELoc" PWild (PVar "f"))) (EApp (EApp (EVar "definerShadowVarHead") (EVar "mctx")) (EVar "f")))
(DFunDef false "definerShadowVarHead" ((PVar "mctx") (PCon "EVar" (PVar "name"))) (EIf (EBinOp "&&" (EApp (EApp (EVar "ifaceMethodName") (EVar "mctx")) (EVar "name")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "definerShadowNamesRef") "value"))) (EApp (EVar "Some") (EVar "name")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "definerShadowVarHead" ((PVar "mctx") (PCon "EVarId" (PVar "name") PWild)) (EIf (EBinOp "&&" (EApp (EApp (EVar "ifaceMethodName") (EVar "mctx")) (EVar "name")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "definerShadowNamesRef") "value"))) (EApp (EVar "Some") (EVar "name")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "definerShadowVarHead" ((PVar "mctx") PWild) (EVar "None"))
(DTypeSig false "shadowSpineNodesAt" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Expr")))))))
(DFunDef false "shadowSpineNodesAt" ((PVar "mctx") (PVar "name") (PVar "f")) (EBlock (DoLet false false (PVar "nodes") (EApp (EVar "appSpineNodes") (EVar "f"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "nodes")) (EVar "None") (EMatch (EApp (EApp (EVar "methodDispatchIdx") (EVar "mctx")) (EVar "name")) (arm (PCon "Some" (PVar "k")) () (EIf (EBinOp "==" (EVar "k") (EApp (EVar "listLen") (EVar "nodes"))) (EApp (EVar "Some") (EVar "nodes")) (EVar "None"))) (arm (PCon "None") () (EVar "None")))))))
(DTypeSig false "shadowSpineNodesAtImporter" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Expr")))))))
(DFunDef false "shadowSpineNodesAtImporter" ((PVar "mctx") (PVar "name") (PVar "f")) (EBlock (DoLet false false (PVar "nodes") (EApp (EVar "appSpineNodes") (EVar "f"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "nodes")) (EVar "None") (EMatch (EApp (EApp (EVar "importerDispatchIdxOuter") (EVar "mctx")) (EVar "name")) (arm (PCon "Some" (PVar "k")) () (EIf (EBinOp "==" (EVar "k") (EApp (EVar "listLen") (EVar "nodes"))) (EApp (EVar "Some") (EVar "nodes")) (EVar "None"))) (arm (PCon "None") () (EVar "None")))))))
(DTypeSig true "definerShadowSpineArgAt" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Int"))) (TyApp (TyCon "Ref") (TyCon "Route")) (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyApp (TyCon "Ref") (TyCon "Inner")) (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr")))))))
(DFunDef false "definerShadowSpineArgAt" ((PVar "mctx") (PVar "f")) (EMatch (EApp (EApp (EVar "definerShadowArgHead") (EVar "mctx")) (EApp (EVar "appSpineHead") (EVar "f"))) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple (PVar "name") (PVar "arityRef") (PVar "tagRef") (PVar "implRef") (PVar "innerRef"))) () (EApp (EApp (EVar "map") (ELam ((PVar "nodes")) (ETuple (EVar "name") (EVar "arityRef") (EVar "tagRef") (EVar "implRef") (EVar "innerRef") (EApp (EVar "appSpineHead") (EVar "f")) (EVar "nodes")))) (EApp (EApp (EApp (EVar "shadowSpineNodesAt") (EVar "mctx")) (EVar "name")) (EVar "f"))))))
(DTypeSig true "definerShadowSpineVarAt" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr")))))))
(DFunDef false "definerShadowSpineVarAt" ((PVar "mctx") (PVar "f")) (EMatch (EApp (EApp (EVar "definerShadowVarHead") (EVar "mctx")) (EApp (EVar "appSpineHead") (EVar "f"))) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "name")) () (EApp (EApp (EVar "map") (ELam ((PVar "nodes")) (ETuple (EVar "name") (EApp (EVar "appSpineHead") (EVar "f")) (EVar "nodes")))) (EApp (EApp (EApp (EVar "shadowSpineNodesAt") (EVar "mctx")) (EVar "name")) (EVar "f"))))))
(DTypeSig true "shadowStandaloneDictSlotsAt" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "Option") (TyCon "ValueScheme")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyCon "ShadowDicts")))))))
(DFunDef false "shadowStandaloneDictSlotsAt" ((PVar "dyn") (PCon "None") PWild PWild PWild) (EVar "emptyShadowDicts"))
(DFunDef false "shadowStandaloneDictSlotsAt" ((PVar "dyn") (PCon "Some" (PVar "value")) (PVar "name") (PVar "key") (PVar "xt")) (EBlock (DoLet false false (PVar "inst") (EApp (EApp (EVar "instantiateMethodTracked") (EFieldAccess (EVar "dyn") "dcModule")) (EFieldAccess (EVar "value") "vsScheme"))) (DoLet false false (PVar "dc") (EApp (EApp (EVar "optionOr") (EApp (EApp (EApp (EVar "shadowDeclaredFor") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "name")) (EVar "key"))) (EApp (EApp (EApp (EVar "declaredEffectsAt") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph")) (EVar "inst")) (EFieldAccess (EVar "value") "vsDeclared")))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EFieldAccess (EVar "dc") "cdSlots")) (EVar "emptyShadowDicts") (EBlock (DoExpr (EApp (EApp (EApp (EVar "unifySpineProbe") (EVar "dyn")) (EFieldAccess (EVar "inst") "mtiBody")) (EListLit (EVar "xt")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "shadowStandaloneDictSlots") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph")) (EFieldAccess (EVar "dc") "cdSlots")) (EFieldAccess (EVar "dc") "cdArgs")) (EFieldAccess (EFieldAccess (EVar "inst") "mtiSubstitution") "misTypeSubst"))))))))
(DTypeSig true "shadowDeclaredFor" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "CDeclared")))))
(DFunDef false "shadowDeclaredFor" ((PVar "mctx") (PVar "name") (PVar "key")) (EIf (EApp (EApp (EVar "isDefinerShadow") (EVar "mctx")) (EVar "name")) (EApp (EApp (EVar "localDeclaredConstraintFor") (EVar "mctx")) (EVar "key")) (EIf (EVar "otherwise") (EApp (EApp (EVar "declaredConstraintFor") (EVar "mctx")) (EVar "key")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "shadowStandaloneDictSlots" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "CSlot")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyCon "ShadowDicts"))))))
(DFunDef false "shadowStandaloneDictSlots" ((PVar "gctx") (PVar "slots") (PVar "args") (PVar "subst")) (EIf (EApp (EVar "isEmptyL") (EVar "slots")) (EVar "emptyShadowDicts") (EBlock (DoLet false false (PVar "expandedV") (EApp (EVar "dedupSlotVecs") (EApp (EApp (EVar "zipSlotVecs") (EVar "slots")) (EVar "args")))) (DoLet false false (PVar "expanded") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "expandedV"))) (DoExpr (ERecordCreate "ShadowDicts" ((fa "sdMonos" (EApp (EApp (EVar "constraintMonosOf") (EApp (EApp (EVar "map") (ELam ((PVar "sl")) (EFieldAccess (EVar "sl") "csId"))) (EVar "expanded"))) (EVar "subst"))) (fa "sdIfaces" (EApp (EApp (EVar "map") (ELam ((PVar "sl")) (EFieldAccess (EVar "sl") "csIface"))) (EVar "expanded"))) (fa "sdArgVecs" (EApp (EApp (EApp (EVar "callArgVecsV") (EVar "gctx")) (EVar "expandedV")) (EVar "subst")))))))))
(DTypeSig true "importerAdmittedVerdict" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ImplEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "AdmittedVerdict"))))))
(DFunDef false "importerAdmittedVerdict" ((PVar "mctx") (PVar "env") (PVar "name") (PVar "ats")) (EMatch (EApp (EApp (EVar "methodAdmittedHere") (EVar "mctx")) (EVar "name")) (arm (PList) () (EVar "AdDefer")) (arm (PVar "ifs") () (EIf (EBinOp "<" (EApp (EVar "listLen") (EVar "ifs")) (ELit (LInt 2))) (EVar "AdDefer") (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "admittedDeclHitters") (EVar "mctx")) (EVar "env")) (EVar "name")) (EVar "ifs")) (EVar "ats")) (arm (PCon "None") () (EApp (EVar "AdReject") (EVar "ifs"))) (arm (PCon "Some" (PVar "hits")) () (EIf (EApp (EVar "isEmptyL") (EVar "hits")) (EVar "AdStandalone") (EApp (EVar "AdReject") (EVar "ifs")))))))))
(DTypeSig false "admittedDeclHitters" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ImplEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "IfaceRef")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "IfaceRef")))))))))
(DFunDef false "admittedDeclHitters" ((PVar "mctx") PWild PWild (PList) PWild) (EApp (EVar "Some") (EListLit)))
(DFunDef false "admittedDeclHitters" ((PVar "mctx") (PVar "env") (PVar "name") (PCons (PVar "ir") (PVar "rest")) (PVar "ats")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "admittedDeclHits") (EVar "mctx")) (EVar "env")) (EVar "name")) (EVar "ir")) (EVar "ats")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "hit")) () (EApp (EApp (EVar "map") (ELam ((PVar "hs")) (EIf (EVar "hit") (EBinOp "::" (EVar "ir") (EVar "hs")) (EVar "hs")))) (EApp (EApp (EApp (EApp (EApp (EVar "admittedDeclHitters") (EVar "mctx")) (EVar "env")) (EVar "name")) (EVar "rest")) (EVar "ats"))))))
(DTypeSig false "admittedDeclHits" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ImplEnv") (TyFun (TyCon "String") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "Bool"))))))))
(DFunDef false "admittedDeclHits" ((PVar "mctx") (PVar "env") (PVar "name") (PVar "ir") (PVar "ats")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "lookupIdxById") (EVar "ir")) (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodDispatchIdxByIdRef") "value"))) (ELam ((PVar "k")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "nthMono") (EVar "k")) (EVar "ats"))) (ELam ((PVar "at")) (EApp (EApp (EVar "andThen") (EApp (EVar "headTyconMono") (EVar "at"))) (ELam ((PVar "hk")) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "ieImplExistsForHeadOf") (EVar "mctx")) (EVar "env")) (EVar "name")) (EVar "hk")) (EApp (EVar "Some") (EListLit (EVar "ir"))))))))))))
(DTypeSig false "importerDispatchIdxOuter" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "importerDispatchIdxOuter" ((PVar "mctx") (PVar "name")) (EMatch (EApp (EApp (EApp (EVar "admittedIdxMax") (EVar "mctx")) (EVar "name")) (EApp (EApp (EVar "methodAdmittedHere") (EVar "mctx")) (EVar "name"))) (arm (PCon "Some" (PVar "k")) () (EApp (EVar "Some") (EVar "k"))) (arm (PCon "None") () (EApp (EApp (EVar "methodDispatchIdx") (EVar "mctx")) (EVar "name")))))
(DTypeSig false "admittedIdxMax" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "IfaceRef")) (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "admittedIdxMax" ((PVar "mctx") PWild (PList)) (EVar "None"))
(DFunDef false "admittedIdxMax" ((PVar "mctx") (PVar "name") (PCons (PVar "ir") (PVar "rest"))) (EBlock (DoLet false false (PVar "here") (EApp (EApp (EApp (EVar "lookupIdxById") (EVar "ir")) (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodDispatchIdxByIdRef") "value"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "admittedIdxMax") (EVar "mctx")) (EVar "name")) (EVar "rest")) (arm (PCon "None") () (EVar "here")) (arm (PCon "Some" (PVar "k")) () (EMatch (EVar "here") (arm (PCon "None") () (EApp (EVar "Some") (EVar "k"))) (arm (PCon "Some" (PVar "j")) () (EApp (EVar "Some") (EApp (EApp (EVar "maxI") (EVar "j")) (EVar "k"))))))))))
(DTypeSig true "groundAdmittedReceivers" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit"))))))
(DFunDef false "groundAdmittedReceivers" ((PVar "env") (PVar "mname") (PVar "ats") (PVar "dloc")) (EApp (EApp (EApp (EApp (EApp (EVar "groundAdmittedGo") (EVar "env")) (EVar "mname")) (EApp (EApp (EVar "methodAdmittedHere") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "mname"))) (EVar "ats")) (EVar "dloc")))
(DTypeSig false "groundAdmittedGo" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "IfaceRef")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit")))))))
(DFunDef false "groundAdmittedGo" ((PVar "env") PWild (PList) PWild PWild) (ELit LUnit))
(DFunDef false "groundAdmittedGo" ((PVar "env") (PVar "mname") (PCons (PVar "ir") (PVar "rest")) (PVar "ats") (PVar "dloc")) (EBlock (DoExpr (EMatch (EApp (EApp (EApp (EVar "lookupIdxById") (EVar "ir")) (EVar "mname")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "methodDispatchIdxByIdRef") "value")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "k")) () (EMatch (EApp (EApp (EVar "nthMono") (EVar "k")) (EVar "ats")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "at")) () (EApp (EApp (EApp (EApp (EApp (EVar "groundShadowReceiver") (EFieldAccess (EVar "env") "teDyn")) (EApp (EApp (EApp (EVar "importerShadowDomainAt") (EVar "env")) (EVar "mname")) (EVar "k"))) (EVar "at")) (EApp (EApp (EApp (EVar "definerReceiverIsDictVar") (EFieldAccess (EVar "env") "teDyn")) (EVar "mname")) (EVar "at"))) (EVar "dloc"))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "groundAdmittedGo") (EVar "env")) (EVar "mname")) (EVar "rest")) (EVar "ats")) (EVar "dloc")))))
(DTypeSig true "pushAmbiguousShadowDecl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "IfaceRef")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit"))))))
(DFunDef false "pushAmbiguousShadowDecl" ((PVar "mctx") (PVar "name") (PVar "ifs") (PVar "dloc")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushTypeErrorHelpFixAt") (EVar "mctx")) (EVar "TAmbiguousShadowDecl")) (EVar "dloc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` is ambiguous here: "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " and "))) (EApp (EApp (EVar "map") (EVar "shadowIfaceLabel")) (EVar "ifs"))))) (ELit (LString " each declare a method `"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` and are both in scope; "))) (EApp (EVar "display") (EVar "ambiguousShadowHelp"))) (ELit (LString "")))) (EVar "ambiguousShadowHelp")) (EVar "None")))
(DTypeSig false "pushAmbiguousMethod" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "IfaceRef")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit"))))))
(DFunDef false "pushAmbiguousMethod" ((PVar "mctx") (PVar "name") (PVar "ifs") (PVar "loc")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushTypeErrorHelpFixAt") (EVar "mctx")) (EVar "TAmbiguousMethod")) (EVar "loc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` is ambiguous here: "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " and "))) (EApp (EApp (EVar "map") (EVar "shadowIfaceLabel")) (EVar "ifs"))))) (ELit (LString " each declare a method `"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "`, and this use does not decide which one it means; bring only one of those interfaces into scope")))) (EVar "ambiguousShadowHelp")) (EVar "None")))
(DTypeSig false "pushUnroutableAdmitted" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "IfaceRef")) (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit")))))))
(DFunDef false "pushUnroutableAdmitted" ((PVar "mctx") (PVar "name") (PVar "ifs") (PVar "sel") (PVar "loc")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushTypeErrorHelpFixAt") (EVar "mctx")) (EVar "TAmbiguousMethod")) (EVar "loc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` names a method of more than one interface here ("))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " and "))) (EApp (EApp (EVar "map") (EVar "shadowIfaceLabel")) (EVar "ifs"))))) (ELit (LString "); the one this use selects, `"))) (EApp (EVar "display") (EFieldAccess (EVar "sel") "irName"))) (ELit (LString "."))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "`, has method-level constraints, and a use of a name that more than one interface declares cannot supply their dictionaries; bring only one of those interfaces into scope")))) (EVar "ambiguousShadowHelp")) (EVar "None")))
(DTypeSig true "resolveRLocalSite" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "IfaceRef")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Mono"))) (TyCon "Unit"))))))))))))
(DFunDef false "resolveRLocalSite" ((PVar "sx") (PVar "name") (PVar "tagRef") (PVar "am") (PVar "encl") (PVar "scope") (PVar "sym") (PVar "monos") (PVar "ifaces") (PVar "argVecs")) (EMatch (EApp (EVar "headTyconMono") (EVar "am")) (arm (PCon "Some" (PVar "tag")) () (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "isDefinerShadow") (EFieldAccess (EVar "sx") "sxModule")) (EVar "name"))) (EApp (EApp (EApp (EApp (EVar "ieImplExistsForHead") (EFieldAccess (EVar "sx") "sxModule")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "bodyImplEnvRef") "value")) (EVar "name")) (EVar "tag"))) (ELit LUnit) (EApp (EApp (EVar "setRef") (EVar "tagRef")) (EApp (EApp (EVar "RLocal") (EVar "sym")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routesOfMonosTopV") (EVar "sx")) (EVar "encl")) (EVar "scope")) (EVar "monos")) (EVar "ifaces")) (EVar "argVecs")))))) (arm (PCon "None") () (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "definerShadowNamesRef") "value")) (EApp (EApp (EVar "setRef") (EVar "tagRef")) (EApp (EApp (EVar "RLocal") (EVar "sym")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routesOfMonosTopV") (EVar "sx")) (EVar "encl")) (EVar "scope")) (EVar "monos")) (EVar "ifaces")) (EVar "argVecs")))) (ELit LUnit)))))
(DTypeSig true "isPreludeMid" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isPreludeMid" ((PVar "mid")) (EBinOp "||" (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EBinOp "==" (EVar "mid") (ELit (LString "")))))
(DTypeSig true "definerShadowsFromSet" (TyFun (TyCon "GraphCtx") (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "definerShadowsFromSet" ((PVar "gctx") (PVar "isMethod") (PVar "prog")) (EBlock (DoLet false false (PVar "localNames") (EApp (EVar "dedup") (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "funDefs") (EVar "prog"))))) (DoLet false false (PVar "direct") (EApp (EApp (EVar "filter") (EVar "isMethod")) (EVar "localNames"))) (DoLet false false (PVar "sm") (EFieldAccess (EFieldAccess (EVar "gctx") "mangledShadowMapRef") "value")) (DoLet false false (PVar "bares") (EApp (EApp (EVar "flatMap") (ELam ((PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "sm")) (arm (PCon "Some" (PVar "bare")) () (EListLit (EVar "bare"))) (arm (PCon "None") () (EListLit))))) (EVar "localNames"))) (DoExpr (EApp (EApp (EVar "removeAllS") (EApp (EVar "localBoundNames") (EVar "prog"))) (EApp (EVar "dedup") (EBinOp "++" (EVar "direct") (EVar "bares")))))))
(DTypeSig true "standaloneShadowsFromSet" (TyFun (TyCon "GraphCtx") (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "standaloneShadowsFromSet" ((PVar "gctx") (PVar "isMethod") (PVar "fnSet") (PVar "prog")) (EBlock (DoLet false false (PVar "localNames") (EApp (EApp (EVar "namesToSet") (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "funDefs") (EVar "prog")))) (EVar "omEmpty"))) (DoLet false false (PVar "direct") (EApp (EApp (EVar "filter") (ELam ((PVar "n")) (EBinOp "&&" (EApp (EVar "isMethod") (EVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "localNames")))))) (EApp (EVar "omKeys") (EVar "fnSet")))) (DoLet false false (PVar "sm") (EFieldAccess (EFieldAccess (EVar "gctx") "mangledShadowMapRef") "value")) (DoLet false false (PVar "mangled") (EApp (EApp (EVar "flatMap") (ELam ((PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "sm")) (arm (PCon "Some" (PVar "bare")) () (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "localNames")) (EListLit) (EListLit (EVar "bare")))) (arm (PCon "None") () (EListLit))))) (EApp (EVar "omKeys") (EVar "fnSet")))) (DoExpr (EApp (EVar "dedup") (EBinOp "++" (EVar "direct") (EVar "mangled"))))))
(DTypeSig true "nameableIfaceShadows" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "nameableIfaceShadows" ((PVar "gctx") PWild (PList)) (EListLit))
(DFunDef false "nameableIfaceShadows" ((PVar "gctx") (PVar "prog") (PVar "names")) (EIf (EBinOp "==" (EApp (EVar "omSize") (EApp (EApp (EVar "ifaceExportsIndex") (EVar "gctx")) (ELit LUnit))) (ELit (LInt 0))) (EVar "names") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "nameable") (EApp (EApp (EVar "nameableIfaceMethodSet") (EVar "gctx")) (EVar "prog"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "nameable")))) (EVar "names")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "nameableIfaceMethodSet" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "nameableIfaceMethodSet" ((PVar "gctx") (PVar "prog")) (EApp (EApp (EVar "namesToSet") (EApp (EApp (EVar "flatMap") (EVar "snd")) (EApp (EApp (EVar "nameableIfaceRows") (EVar "gctx")) (EVar "prog")))) (EVar "omEmpty")))
(DTypeSig true "nameableIfaceRows" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "nameableIfaceRows" ((PVar "gctx") (PVar "prog")) (EApp (EApp (EVar "nameableIfaceRowsIn") (EApp (EApp (EVar "ifaceExportsIndex") (EVar "gctx")) (ELit LUnit))) (EVar "prog")))
(DTypeSig false "nameableIfaceRowsIn" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "nameableIfaceRowsIn" ((PVar "idx") (PVar "prog")) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (ELit (LString "core"))) (EVar "idx"))) (EApp (EVar "ifaceMethodRows") (EVar "prog"))) (EApp (EApp (EVar "importedIfaceRows") (EVar "idx")) (EVar "prog"))))
(DTypeSig true "importedStandaloneShadows" (TyFun (TyCon "DriveOutputs") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Ty")) (TyCon "Ty") (TyCon "Loc")))))))
(DFunDef false "importedStandaloneShadows" ((PVar "o") (PVar "graph") (PVar "prog")) (EApp (EApp (EApp (EVar "importedStandaloneShadowsIn") (EFieldAccess (EVar "o") "doIfaceExports")) (EVar "graph")) (EVar "prog")))
(DTypeSig true "importedStandaloneShadowsIn" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Ty")) (TyCon "Ty") (TyCon "Loc")))))))
(DFunDef false "importedStandaloneShadowsIn" ((PVar "idx") (PVar "graph") (PVar "prog")) (EIf (EBinOp "==" (EApp (EVar "omSize") (EVar "idx")) (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EVar "nameableIfaceRowsIn") (EVar "idx")) (EVar "prog"))) (DoLet false false (PVar "nameable") (EApp (EApp (EVar "namesToSet") (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "rows"))) (EVar "omEmpty"))) (DoLet false false (PVar "universe") (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "graph")) (EVar "prog"))) (DoExpr (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EApp (EVar "importShadowsOfDecl") (EVar "graph")) (EVar "rows")) (EVar "nameable")) (EVar "universe"))) (EVar "prog")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "importShadowsOfDecl" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Ty")) (TyCon "Ty") (TyCon "Loc")))))))))
(DFunDef false "importShadowsOfDecl" ((PVar "graph") (PVar "rows") (PVar "nameable") (PVar "universe") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EApp (EVar "importShadowsOfDecl") (EVar "graph")) (EVar "rows")) (EVar "nameable")) (EVar "universe")) (EVar "d")))
(DFunDef false "importShadowsOfDecl" ((PVar "graph") (PVar "rows") (PVar "nameable") (PVar "universe") (PCon "DUse" PWild (PVar "path") PWild)) (EMatch (EVar "path") (arm (PCon "UseGroup" PWild (PVar "ms")) () (EMatch (EApp (EApp (EVar "lookupAssoc") (EApp (EVar "useModId") (EVar "path"))) (EVar "graph")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "depDecls")) () (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EApp (EApp (EVar "importMemberShadow") (EVar "graph")) (EVar "rows")) (EVar "nameable")) (EVar "universe")) (EVar "depDecls"))) (EVar "ms"))))) (arm PWild () (EListLit))))
(DFunDef false "importShadowsOfDecl" (PWild PWild PWild PWild PWild) (EListLit))
(DTypeSig false "importMemberShadow" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Ty")) (TyCon "Ty") (TyCon "Loc"))))))))))
(DFunDef false "importMemberShadow" ((PVar "graph") (PVar "rows") (PVar "nameable") (PVar "universe") (PVar "depDecls") (PCon "UseMember" (PVar "origin") PWild (PVar "mloc") (PVar "alias"))) (EBlock (DoLet false false (PVar "local") (EMatch (EVar "alias") (arm (PCon "Some" (PVar "a")) () (EVar "a")) (arm (PCon "None") () (EVar "origin")))) (DoExpr (EIf (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "local")) (EVar "nameable"))) (EListLit) (EMatch (EApp (EApp (EApp (EApp (EVar "reachableStandaloneSig") (EVar "graph")) (EApp (EVar "listLen") (EVar "graph"))) (EVar "depDecls")) (EVar "origin")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "sty")) () (EMatch (EApp (EApp (EApp (EApp (EVar "ifaceMethodSigFor") (EVar "local")) (EVar "sty")) (EVar "rows")) (EVar "universe")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple (PVar "iface") (PVar "mty"))) () (EListLit (ETuple (EVar "local") (EVar "iface") (EVar "sty") (EVar "mty") (EVar "mloc")))))))))))
(DTypeSig false "schemesAgree" (TyFun (TyApp (TyCon "Option") (TyCon "Ty")) (TyFun (TyCon "Ty") (TyCon "Bool"))))
(DFunDef false "schemesAgree" ((PCon "None") PWild) (EVar "False"))
(DFunDef false "schemesAgree" ((PCon "Some" (PVar "sty")) (PVar "mty")) (EApp (EApp (EVar "tyAlphaEq") (EVar "sty")) (EVar "mty")))
(DTypeSig false "ifaceMethodSigFor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Ty"))))))))
(DFunDef false "ifaceMethodSigFor" (PWild PWild (PList) PWild) (EVar "None"))
(DFunDef false "ifaceMethodSigFor" ((PVar "name") (PVar "sty") (PCons (PTuple (PVar "iface") (PVar "ms")) (PVar "rest")) (PVar "universe")) (EBlock (DoLet false false (PVar "later") (EApp (EApp (EApp (EApp (EVar "ifaceMethodSigFor") (EVar "name")) (EVar "sty")) (EVar "rest")) (EVar "universe"))) (DoExpr (EIf (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "name")) (EVar "ms"))) (EVar "later") (EMatch (EApp (EApp (EApp (EVar "ifaceMethodTyIn") (EVar "iface")) (EVar "name")) (EVar "universe")) (arm (PCon "Some" (PVar "ty")) () (EIf (EApp (EApp (EVar "schemesAgree") (EVar "sty")) (EVar "ty")) (EVar "later") (EApp (EApp (EVar "leastIfaceSig") (ETuple (EVar "iface") (EVar "ty"))) (EVar "later")))) (arm (PCon "None") () (EVar "later")))))))
(DTypeSig false "leastIfaceSig" (TyFun (TyTuple (TyCon "String") (TyCon "Ty")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Ty"))))))
(DFunDef false "leastIfaceSig" ((PVar "a") (PCon "None")) (EApp (EVar "Some") (EVar "a")))
(DFunDef false "leastIfaceSig" ((PAs "a" (PTuple (PVar "ia") (PVar "ta"))) (PCon "Some" (PAs "b" (PTuple (PVar "ib") (PVar "tb"))))) (EIf (EBinOp "<" (EVar "ia") (EVar "ib")) (EApp (EVar "Some") (EVar "a")) (EIf (EBinOp "<" (EVar "ib") (EVar "ia")) (EApp (EVar "Some") (EVar "b")) (EIf (EBinOp "<=" (EApp (EVar "ppTy") (EVar "ta")) (EApp (EVar "ppTy") (EVar "tb"))) (EApp (EVar "Some") (EVar "a")) (EIf (EVar "otherwise") (EApp (EVar "Some") (EVar "b")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "ifaceMethodTyIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Ty"))))))
(DFunDef false "ifaceMethodTyIn" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "ifaceMethodTyIn" ((PVar "iface") (PVar "name") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EApp (EVar "ifaceMethodTyIn") (EVar "iface")) (EVar "name")) (EListLit (EVar "d")))) (DoExpr (EMatch (EVar "inner") (arm (PCon "Some" (PVar "ty")) () (EApp (EVar "Some") (EVar "ty"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "ifaceMethodTyIn") (EVar "iface")) (EVar "name")) (EVar "rest")))))))
(DFunDef false "ifaceMethodTyIn" ((PVar "iface") (PVar "name") (PCons (PRec "DInterface" ((rf "name" (PVar "n")) (rf "methods" None)) true) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n") (EVar "iface")) (EMatch (EApp (EApp (EVar "ifaceMethodTyOf") (EVar "name")) (EVar "methods")) (arm (PCon "Some" (PVar "ty")) () (EApp (EVar "Some") (EVar "ty"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "ifaceMethodTyIn") (EVar "iface")) (EVar "name")) (EVar "rest")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "ifaceMethodTyIn") (EVar "iface")) (EVar "name")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "ifaceMethodTyIn" ((PVar "iface") (PVar "name") (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EVar "ifaceMethodTyIn") (EVar "iface")) (EVar "name")) (EVar "rest")))
(DTypeSig false "ifaceMethodTyOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "Option") (TyCon "Ty")))))
(DFunDef false "ifaceMethodTyOf" (PWild (PList)) (EVar "None"))
(DFunDef false "ifaceMethodTyOf" ((PVar "name") (PCons (PCon "IfaceMethod" (PVar "n") (PVar "ty") PWild PWild) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EVar "Some") (EVar "ty")) (EIf (EVar "otherwise") (EApp (EApp (EVar "ifaceMethodTyOf") (EVar "name")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reachableStandaloneSig" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "Option") (TyCon "Ty"))))))))
(DFunDef false "reachableStandaloneSig" ((PVar "graph") (PVar "fuel") (PVar "decls") (PVar "name")) (EIf (EApp (EApp (EVar "declaresStandalone") (EVar "name")) (EVar "decls")) (EApp (EVar "Some") (EApp (EApp (EVar "standaloneSigOf") (EVar "name")) (EVar "decls"))) (EIf (EBinOp "<=" (EVar "fuel") (ELit (LInt 0))) (EVar "None") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "reachableStandaloneSigGo") (EVar "graph")) (EBinOp "-" (EVar "fuel") (ELit (LInt 1)))) (EApp (EApp (EVar "reexportedOrigins") (EVar "decls")) (EVar "name"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "reachableStandaloneSigGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "Option") (TyApp (TyCon "Option") (TyCon "Ty")))))))
(DFunDef false "reachableStandaloneSigGo" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "reachableStandaloneSigGo" ((PVar "graph") (PVar "fuel") (PCons (PTuple (PVar "mid") (PVar "n")) (PVar "rest"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "mid")) (EVar "graph")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "reachableStandaloneSigGo") (EVar "graph")) (EVar "fuel")) (EVar "rest"))) (arm (PCon "Some" (PVar "ds")) () (EMatch (EApp (EApp (EApp (EApp (EVar "reachableStandaloneSig") (EVar "graph")) (EVar "fuel")) (EVar "ds")) (EVar "n")) (arm (PCon "Some" (PVar "sig")) () (EApp (EVar "Some") (EVar "sig"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "reachableStandaloneSigGo") (EVar "graph")) (EVar "fuel")) (EVar "rest")))))))
(DTypeSig false "reexportedOrigins" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reexportedOrigins" ((PVar "decls") (PVar "name")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "d")) (EApp (EApp (EVar "reexportedOriginsOf") (EVar "d")) (EVar "name")))) (EVar "decls")))
(DTypeSig false "reexportedOriginsOf" (TyFun (TyCon "Decl") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reexportedOriginsOf" ((PCon "DAttrib" PWild (PVar "d")) (PVar "name")) (EApp (EApp (EVar "reexportedOriginsOf") (EVar "d")) (EVar "name")))
(DFunDef false "reexportedOriginsOf" ((PCon "DUse" (PCon "True") (PVar "path") PWild) (PVar "name")) (EMatch (EApp (EVar "importedBindings") (EVar "path")) (arm (PCon "None") () (EListLit (ETuple (EApp (EVar "useModId") (EVar "path")) (EVar "name")))) (arm (PCon "Some" (PVar "bs")) () (EApp (EApp (EVar "map") (ELam ((PVar "b")) (ETuple (EApp (EVar "useModId") (EVar "path")) (EApp (EVar "fst") (EVar "b"))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EBinOp "==" (EApp (EVar "snd") (EVar "b")) (EVar "name")))) (EVar "bs"))))))
(DFunDef false "reexportedOriginsOf" (PWild PWild) (EListLit))
(DTypeSig false "declaresStandalone" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool"))))
(DFunDef false "declaresStandalone" (PWild (PList)) (EVar "False"))
(DFunDef false "declaresStandalone" ((PVar "n") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "||" (EApp (EApp (EVar "declaresStandalone") (EVar "n")) (EListLit (EVar "d"))) (EApp (EApp (EVar "declaresStandalone") (EVar "n")) (EVar "rest"))))
(DFunDef false "declaresStandalone" ((PVar "n") (PCons (PCon "DFunDef" PWild (PVar "m") PWild PWild PWild PWild) (PVar "rest"))) (EBinOp "||" (EBinOp "==" (EVar "m") (EVar "n")) (EApp (EApp (EVar "declaresStandalone") (EVar "n")) (EVar "rest"))))
(DFunDef false "declaresStandalone" ((PVar "n") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "declaresStandalone") (EVar "n")) (EVar "rest")))
(DTypeSig false "standaloneSigOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Ty")))))
(DFunDef false "standaloneSigOf" (PWild (PList)) (EVar "None"))
(DFunDef false "standaloneSigOf" ((PVar "n") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EMatch (EApp (EApp (EVar "standaloneSigOf") (EVar "n")) (EListLit (EVar "d"))) (arm (PCon "Some" (PVar "t")) () (EApp (EVar "Some") (EVar "t"))) (arm (PCon "None") () (EApp (EApp (EVar "standaloneSigOf") (EVar "n")) (EVar "rest")))))
(DFunDef false "standaloneSigOf" ((PVar "n") (PCons (PCon "DTypeSig" PWild (PVar "m") (PVar "ty") PWild) (PVar "rest"))) (EIf (EBinOp "==" (EVar "m") (EVar "n")) (EApp (EVar "Some") (EVar "ty")) (EIf (EVar "otherwise") (EApp (EApp (EVar "standaloneSigOf") (EVar "n")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "standaloneSigOf" ((PVar "n") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "standaloneSigOf") (EVar "n")) (EVar "rest")))
(DTypeSig false "tyAlphaEq" (TyFun (TyCon "Ty") (TyFun (TyCon "Ty") (TyCon "Bool"))))
(DFunDef false "tyAlphaEq" ((PVar "a") (PVar "b")) (EMatch (EApp (EApp (EApp (EVar "tyAlphaGo") (EListLit)) (EVar "a")) (EVar "b")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "tyAlphaGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "Ty") (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "tyAlphaGo" ((PVar "m") (PCon "TyVar" (PVar "x")) (PCon "TyVar" (PVar "y"))) (EApp (EApp (EApp (EVar "bindTyName") (EVar "m")) (EVar "x")) (EVar "y")))
(DFunDef false "tyAlphaGo" ((PVar "m") (PRec "TyCon" ((rf "tyConName" (PVar "x"))) false) (PRec "TyCon" ((rf "tyConName" (PVar "y"))) false)) (EIf (EBinOp "==" (EVar "x") (EVar "y")) (EApp (EVar "Some") (EVar "m")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "tyAlphaGo" ((PVar "m") (PCon "TyApp" (PVar "f") (PVar "x")) (PCon "TyApp" (PVar "g") (PVar "y"))) (EMatch (EApp (EApp (EApp (EVar "tyAlphaGo") (EVar "m")) (EVar "f")) (EVar "g")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "m2")) () (EApp (EApp (EApp (EVar "tyAlphaGo") (EVar "m2")) (EVar "x")) (EVar "y")))))
(DFunDef false "tyAlphaGo" ((PVar "m") (PCon "TyFun" (PVar "a") (PVar "b")) (PCon "TyFun" (PVar "c") (PVar "d"))) (EMatch (EApp (EApp (EApp (EVar "tyAlphaGo") (EVar "m")) (EVar "a")) (EVar "c")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "m2")) () (EApp (EApp (EApp (EVar "tyAlphaGo") (EVar "m2")) (EVar "b")) (EVar "d")))))
(DFunDef false "tyAlphaGo" ((PVar "m") (PCon "TyTuple" (PVar "xs")) (PCon "TyTuple" (PVar "ys"))) (EApp (EApp (EApp (EVar "tyAlphaList") (EVar "m")) (EVar "xs")) (EVar "ys")))
(DFunDef false "tyAlphaGo" ((PVar "m") (PCon "TyEffect" (PVar "e1") (PVar "t1") (PVar "a")) (PCon "TyEffect" (PVar "e2") (PVar "t2") (PVar "b"))) (EIf (EBinOp "&&" (EApp (EApp (EVar "sameWrittenAtoms") (EVar "e1")) (EVar "e2")) (EBinOp "==" (EVar "t1") (EVar "t2"))) (EApp (EApp (EApp (EVar "tyAlphaGo") (EVar "m")) (EVar "a")) (EVar "b")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "tyAlphaGo" ((PVar "m") (PCon "TyConstrained" (PVar "c1") (PVar "a")) (PCon "TyConstrained" (PVar "c2") (PVar "b"))) (EIf (EBinOp "/=" (EApp (EVar "listLen") (EVar "c1")) (EApp (EVar "listLen") (EVar "c2"))) (EVar "None") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "tyAlphaGo") (EVar "m")) (EVar "a")) (EVar "b")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "m2")) () (EApp (EApp (EApp (EVar "tyAlphaConstraints") (EVar "m2")) (EVar "c1")) (EVar "c2")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "tyAlphaGo" ((PVar "m") (PCon "TyRow" (PVar "e1") (PVar "t1") PWild) (PCon "TyRow" (PVar "e2") (PVar "t2") PWild)) (EIf (EBinOp "&&" (EApp (EApp (EVar "sameWrittenAtoms") (EVar "e1")) (EVar "e2")) (EBinOp "==" (EVar "t1") (EVar "t2"))) (EApp (EVar "Some") (EVar "m")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "tyAlphaGo" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "sameWrittenAtoms" (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyCon "Bool"))))
(DFunDef false "sameWrittenAtoms" ((PVar "e1") (PVar "e2")) (EBinOp "==" (EApp (EApp (EVar "map") (EApp (EVar "effAtomSurface") (EVar "escStr"))) (EVar "e1")) (EApp (EApp (EVar "map") (EApp (EVar "effAtomSurface") (EVar "escStr"))) (EVar "e2"))))
(DTypeSig false "tyAlphaList" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "tyAlphaList" ((PVar "m") (PList) (PList)) (EApp (EVar "Some") (EVar "m")))
(DFunDef false "tyAlphaList" ((PVar "m") (PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EMatch (EApp (EApp (EApp (EVar "tyAlphaGo") (EVar "m")) (EVar "x")) (EVar "y")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "m2")) () (EApp (EApp (EApp (EVar "tyAlphaList") (EVar "m2")) (EVar "xs")) (EVar "ys")))))
(DFunDef false "tyAlphaList" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "tyAlphaConstraints" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Constraint")) (TyFun (TyApp (TyCon "List") (TyCon "Constraint")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "tyAlphaConstraints" ((PVar "m") (PList) PWild) (EApp (EVar "Some") (EVar "m")))
(DFunDef false "tyAlphaConstraints" ((PVar "m") (PCons (PVar "c") (PVar "rest")) (PVar "cs2")) (EMatch (EApp (EApp (EApp (EApp (EVar "takeAlphaConstraint") (EVar "m")) (EVar "c")) (EVar "cs2")) (EListLit)) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple (PVar "m2") (PVar "left"))) () (EApp (EApp (EApp (EVar "tyAlphaConstraints") (EVar "m2")) (EVar "rest")) (EVar "left")))))
(DTypeSig false "takeAlphaConstraint" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "Constraint") (TyFun (TyApp (TyCon "List") (TyCon "Constraint")) (TyFun (TyApp (TyCon "List") (TyCon "Constraint")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "Constraint")))))))))
(DFunDef false "takeAlphaConstraint" (PWild PWild (PList) PWild) (EVar "None"))
(DFunDef false "takeAlphaConstraint" ((PVar "m") (PVar "c") (PCons (PVar "d") (PVar "rest")) (PVar "tried")) (EMatch (EApp (EApp (EApp (EVar "tyAlphaConstraint") (EVar "m")) (EVar "c")) (EVar "d")) (arm (PCon "Some" (PVar "m2")) () (EApp (EVar "Some") (ETuple (EVar "m2") (EBinOp "++" (EVar "tried") (EVar "rest"))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "takeAlphaConstraint") (EVar "m")) (EVar "c")) (EVar "rest")) (EBinOp "::" (EVar "d") (EVar "tried"))))))
(DTypeSig false "tyAlphaConstraint" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "Constraint") (TyFun (TyCon "Constraint") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "tyAlphaConstraint" ((PVar "m") (PRec "Constraint" ((rf "constraintHead" (PVar "h1")) (rf "constraintArgs" (PVar "as1"))) true) (PRec "Constraint" ((rf "constraintHead" (PVar "h2")) (rf "constraintArgs" (PVar "as2"))) true)) (EIf (EBinOp "==" (EVar "h1") (EVar "h2")) (EApp (EApp (EApp (EVar "tyAlphaList") (EVar "m")) (EVar "as1")) (EVar "as2")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "bindTyName" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "bindTyName" ((PVar "m") (PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "x")) (EVar "m")) (arm (PCon "Some" (PVar "y2")) () (EIf (EBinOp "==" (EVar "y2") (EVar "y")) (EApp (EVar "Some") (EVar "m")) (EVar "None"))) (arm (PCon "None") () (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "e")) (EBinOp "==" (EApp (EVar "snd") (EVar "e")) (EVar "y")))) (EVar "m")) (EVar "None") (EApp (EVar "Some") (EBinOp "::" (ETuple (EVar "x") (EVar "y")) (EVar "m")))))))
(DTypeSig true "computeMangledShadowMap" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "computeMangledShadowMap" ((PVar "allDecls") (PVar "units")) (EBlock (DoLet false false (PVar "methodNames") (EApp (EVar "dedup") (EApp (EVar "allIfaceMethodNames") (EVar "allDecls")))) (DoExpr (EApp (EApp (EVar "flatMap") (EApp (EVar "unitMangledShadows") (EVar "methodNames"))) (EVar "units")))))
(DTypeSig false "unitMangledShadows" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "unitMangledShadows" ((PVar "methodNames") (PTuple (PVar "mid") (PVar "decls"))) (EBlock (DoLet false false (PVar "fns") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "funDefs") (EVar "decls")))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "flatMap") (ELam ((PVar "m")) (EBlock (DoLet false false (PVar "sym") (EApp (EApp (EVar "mangledName") (EVar "mid")) (EVar "m"))) (DoExpr (EIf (EApp (EApp (EVar "omHasKey") (EVar "sym")) (EVar "fns")) (EListLit (ETuple (EVar "sym") (EVar "m"))) (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "isPreludeMid") (EVar "mid"))) (EApp (EApp (EVar "omHasKey") (EVar "m")) (EVar "fns"))) (EListLit (ETuple (EVar "m") (EVar "m"))) (EListLit))))))) (EVar "methodNames")))))
(DTypeSig true "buildStandaloneShadowsGraph" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "buildStandaloneShadowsGraph" ((PVar "sm") (PVar "allDecls") (PVar "userDecls")) (EBlock (DoLet false false (PVar "methodNames") (EApp (EApp (EVar "omFromNames") (EApp (EVar "allIfaceMethodNames") (EVar "allDecls"))) (EVar "omEmpty"))) (DoLet false false (PVar "fns") (EApp (EVar "dedup") (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "funDefs") (EVar "userDecls"))))) (DoLet false false (PVar "direct") (EApp (EApp (EVar "filter") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "methodNames")))) (EVar "fns"))) (DoLet false false (PVar "mangled") (EApp (EApp (EVar "filter") (ELam ((PVar "n")) (EApp (EVar "isSome") (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "sm"))))) (EVar "fns"))) (DoExpr (EApp (EVar "dedup") (EBinOp "++" (EVar "direct") (EVar "mangled"))))))
(DTypeSig true "coreShadowMapFor" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "coreShadowMapFor" ((PVar "gctx") (PVar "coreProg") (PVar "shadowMap")) (EIf (EBinOp "==" (EApp (EVar "omSize") (EApp (EApp (EVar "ifaceExportsIndex") (EVar "gctx")) (ELit LUnit))) (ELit (LInt 0))) (EVar "shadowMap") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "nameable") (EApp (EApp (EVar "nameableIfaceMethodSet") (EVar "gctx")) (EVar "coreProg"))) (DoLet false false (PVar "sc") (EApp (EApp (EVar "spellCtxOf") (EVar "gctx")) (EVar "coreProg"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EBinOp "&&" (EApp (EApp (EVar "omHasKey") (EApp (EVar "snd") (EVar "e"))) (EVar "nameable")) (EApp (EApp (EApp (EVar "moduleSpellsShadowBare") (EVar "sc")) (EApp (EVar "fst") (EVar "e"))) (EApp (EVar "snd") (EVar "e")))))) (EVar "shadowMap")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "shadowSymSpelledBare" (TyFun (TyCon "SpellCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "shadowSymSpelledBare" ((PVar "sc") (PVar "sm") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "sm")) (arm (PCon "None") () (EVar "True")) (arm (PCon "Some" (PVar "bare")) () (EApp (EApp (EApp (EVar "moduleSpellsShadowBare") (EVar "sc")) (EVar "n")) (EVar "bare")))))
(DTypeSig false "spellCtxOf" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "SpellCtx"))))
(DFunDef false "spellCtxOf" ((PVar "gctx") (PVar "prog")) (ERecordCreate "SpellCtx" ((fa "scTopFns" (EApp (EVar "declTopFnNames") (EVar "prog"))) (fa "scBare" (EApp (EApp (EApp (EVar "declBareLocals") (EVar "gctx")) (EVar "prog")) (ERecordCreate "BareLocals" ((fa "blAll" (EVar "False")) (fa "blSet" (EListLit)))))) (fa "scCorePfx" (EApp (EApp (EVar "mangledName") (ELit (LString "core"))) (ELit (LString "")))))))
(DTypeSig true "moduleSpellsShadowBare" (TyFun (TyCon "SpellCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "moduleSpellsShadowBare" ((PVar "sc") (PVar "sym") (PVar "bare")) (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "sym")) (EFieldAccess (EVar "sc") "scTopFns")) (EBinOp "&&" (EApp (EApp (EVar "startsWith") (EFieldAccess (EVar "sc") "scCorePfx")) (EVar "sym")) (EBinOp "==" (EVar "sym") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "sc") "scCorePfx"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "bare"))) (ELit (LString "")))))) (EApp (EApp (EVar "bareLocalBound") (EFieldAccess (EVar "sc") "scBare")) (EVar "bare"))))
(DTypeSig false "bareLocalBound" (TyFun (TyCon "BareLocals") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "bareLocalBound" ((PVar "bl") (PVar "bare")) (EBinOp "||" (EFieldAccess (EVar "bl") "blAll") (EApp (EApp (EVar "contains") (EVar "bare")) (EFieldAccess (EVar "bl") "blSet"))))
(DTypeSig false "declBareLocals" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "BareLocals") (TyCon "BareLocals")))))
(DFunDef false "declBareLocals" ((PVar "gctx") (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "declBareLocals" ((PVar "gctx") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "declBareLocals") (EVar "gctx")) (EVar "rest")) (EApp (EApp (EApp (EVar "declBareLocals") (EVar "gctx")) (EListLit (EVar "d"))) (EVar "acc"))))
(DFunDef false "declBareLocals" ((PVar "gctx") (PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "declBareLocals") (EVar "gctx")) (EVar "rest")) (EApp (EApp (EApp (EVar "formBareLocals") (EVar "gctx")) (EVar "path")) (EVar "acc"))))
(DFunDef false "declBareLocals" ((PVar "gctx") (PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "declBareLocals") (EVar "gctx")) (EVar "rest")) (EVar "acc")))
(DTypeSig false "formBareLocals" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "UsePath") (TyFun (TyCon "BareLocals") (TyCon "BareLocals")))))
(DFunDef false "formBareLocals" ((PVar "gctx") (PVar "path") (PVar "acc")) (EBlock (DoLet false false (PVar "depId") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EMatch (EApp (EVar "importedBindings") (EVar "path")) (arm (PCon "None") () (EIf (EApp (EApp (EVar "depExportsUnknown") (EVar "gctx")) (EVar "depId")) (ERecordUpdate (EVar "acc") ((fa "blAll" (EVar "True")))) (ERecordUpdate (EVar "acc") ((fa "blSet" (EBinOp "++" (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EVar "graphPubDefiners") (EVar "gctx")) (EVar "depId"))) (EFieldAccess (EVar "acc") "blSet"))))))) (arm (PCon "Some" (PVar "bindings")) () (ERecordUpdate (EVar "acc") ((fa "blSet" (EBinOp "++" (EApp (EApp (EVar "filterList") (ELam ((PVar "l")) (EApp (EApp (EApp (EVar "depExportsStandalone") (EVar "gctx")) (EVar "depId")) (EVar "l")))) (EApp (EApp (EVar "map") (EVar "snd")) (EVar "bindings"))) (EFieldAccess (EVar "acc") "blSet"))))))))))
(DTypeSig true "shadowBareName" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "shadowBareName" ((PVar "sm") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "sm")) (arm (PCon "Some" (PVar "bare")) () (EVar "bare")) (arm (PCon "None") () (EVar "n"))))
(DTypeSig true "methodMarkCtx" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "MarkSets") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "MarkCtx"))))))
(DFunDef false "methodMarkCtx" ((PVar "gctx") (PVar "ms") (PLit (LString "")) (PVar "coreProg")) (EIf (EBinOp "==" (EApp (EVar "omSize") (EApp (EApp (EVar "ifaceExportsIndex") (EVar "gctx")) (ELit LUnit))) (ELit (LInt 0))) (ERecordCreate "MarkCtx" ((fa "mcRp" (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "ms") "msMarkRpNames")) (EVar "omEmpty"))) (fa "mcAn" (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "ms") "msArgNames")) (EVar "omEmpty"))) (fa "mcSm" (EFieldAccess (EVar "ms") "msCoreShadowMap")))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "nameable") (EApp (EApp (EVar "nameableIfaceMethodSet") (EVar "gctx")) (EVar "coreProg"))) (DoLet false false (PVar "keep") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "nameable")))) (DoExpr (ERecordCreate "MarkCtx" ((fa "mcRp" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "filterList") (EVar "keep")) (EFieldAccess (EVar "ms") "msMarkRpNames"))) (EVar "omEmpty"))) (fa "mcAn" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "filterList") (EVar "keep")) (EFieldAccess (EVar "ms") "msArgNames"))) (EVar "omEmpty"))) (fa "mcSm" (EFieldAccess (EVar "ms") "msCoreShadowMap")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "methodMarkCtx" ((PVar "gctx") (PVar "ms") PWild (PVar "prog")) (EIf (EBinOp "==" (EApp (EVar "omSize") (EApp (EApp (EVar "ifaceExportsIndex") (EVar "gctx")) (ELit LUnit))) (ELit (LInt 0))) (EBlock (DoLet false false (PVar "aliasRows") (EApp (EApp (EVar "aliasMethodSpellings") (EVar "gctx")) (EVar "prog"))) (DoExpr (ERecordCreate "MarkCtx" ((fa "mcRp" (EApp (EApp (EVar "withAliasMethodNames") (EVar "aliasRows")) (EApp (EApp (EVar "omFromNames") (EApp (EVar "dedup") (EBinOp "++" (EFieldAccess (EVar "ms") "msMarkSharedNames") (EFieldAccess (EVar "ms") "msGraphShadowNames")))) (EVar "omEmpty")))) (fa "mcAn" (EApp (EApp (EVar "withAliasMethodNames") (EVar "aliasRows")) (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "ms") "msArgNames")) (EVar "omEmpty")))) (fa "mcSm" (EFieldAccess (EFieldAccess (EVar "gctx") "mangledShadowMapRef") "value")))))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "nameable") (EApp (EApp (EVar "nameableIfaceMethodSet") (EVar "gctx")) (EVar "prog"))) (DoLet false false (PVar "keep") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "nameable")))) (DoLet false false (PVar "shadowMap") (EFieldAccess (EFieldAccess (EVar "gctx") "mangledShadowMapRef") "value")) (DoLet false false (PVar "sc") (EApp (EApp (EVar "spellCtxOf") (EVar "gctx")) (EVar "prog"))) (DoLet false false (PVar "aliasRows") (EApp (EApp (EVar "aliasMethodSpellings") (EVar "gctx")) (EVar "prog"))) (DoExpr (ERecordCreate "MarkCtx" ((fa "mcRp" (EApp (EApp (EVar "withAliasMethodNames") (EVar "aliasRows")) (EApp (EApp (EVar "omFromNames") (EApp (EVar "dedup") (EBinOp "++" (EApp (EApp (EVar "filterList") (EVar "keep")) (EFieldAccess (EVar "ms") "msMarkSharedNames")) (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EBinOp "&&" (EApp (EApp (EVar "omHasKey") (EApp (EApp (EVar "shadowBareName") (EVar "shadowMap")) (EVar "n"))) (EVar "nameable")) (EApp (EApp (EApp (EVar "shadowSymSpelledBare") (EVar "sc")) (EVar "shadowMap")) (EVar "n"))))) (EFieldAccess (EVar "ms") "msGraphShadowNames"))))) (EVar "omEmpty")))) (fa "mcAn" (EApp (EApp (EVar "withAliasMethodNames") (EVar "aliasRows")) (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "filterList") (EVar "keep")) (EFieldAccess (EVar "ms") "msArgNames"))) (EVar "omEmpty")))) (fa "mcSm" (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EBinOp "&&" (EApp (EApp (EVar "omHasKey") (EApp (EVar "snd") (EVar "e"))) (EVar "nameable")) (EApp (EApp (EApp (EVar "moduleSpellsShadowBare") (EVar "sc")) (EApp (EVar "fst") (EVar "e"))) (EApp (EVar "snd") (EVar "e")))))) (EVar "shadowMap"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "moduleMarkCtx" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "MarkSets") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Scheme")) (TyCon "MarkCtx")))))))
(DFunDef false "moduleMarkCtx" ((PVar "gctx") (PVar "ms") (PVar "mid") (PVar "prog") (PVar "imported")) (EBlock (DoLet false false (PVar "candidates") (EApp (EApp (EApp (EApp (EVar "methodMarkCtx") (EVar "gctx")) (EVar "ms")) (EVar "mid")) (EVar "prog"))) (DoLet false false (PVar "local") (EApp (EApp (EVar "namesToSet") (EApp (EVar "declTopFnNames") (EVar "prog"))) (EVar "omEmpty"))) (DoLet false false (PVar "externs") (EApp (EApp (EVar "namesToSet") (EApp (EVar "declExternNames") (EVar "prog"))) (EVar "omEmpty"))) (DoExpr (ERecordCreate "MarkCtx" ((fa "mcRp" (EApp (EApp (EVar "IdMap.difference") (EFieldAccess (EVar "candidates") "mcRp")) (EVar "externs"))) (fa "mcAn" (EApp (EApp (EVar "IdMap.difference") (EFieldAccess (EVar "candidates") "mcAn")) (EVar "externs"))) (fa "mcSm" (EApp (EApp (EVar "filterList") (ELam ((PVar "entry")) (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EVar "entry"))) (EVar "local")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "snd") (EVar "entry"))) (EVar "imported"))))) (EFieldAccess (EVar "candidates") "mcSm"))))))))
# MARK
(DUse false (UseGroup ("support" "diag_codes") ((mem "DiagCode" true))))
(DUse false (UseGroup ("types" "tc_types") ((mem "StandaloneOrigin" true) (mem "CDeclaredPrefix" true) (mem "AdmittedAnswer" true) (mem "AdmittedVerdict" true) (mem "BareLocals" true) (mem "CDeclared" true) (mem "DynCtx" true) (mem "ShadowDicts" true) (mem "SpellCtx" true) (mem "TcEnv" true) (mem "CSlot" false) (mem "DriveOutputs" false) (mem "EvCell" false) (mem "GraphCtx" false) (mem "ImplEnv" false) (mem "MethodTrackedInstantiation" false) (mem "ModuleCtx" false) (mem "SiteCtx" false) (mem "siteFor" false) (mem "ValueScheme" false) (mem "MarkCtx" true) (mem "MarkSets" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "headMonoNode" false) (mem "headTyconMono" false) (mem "monoIsTyvarId" false) (mem "nthFunDomain" false) (mem "nthMono" false) (mem "substMono" false) (mem "tyvarId" false))))
(DUse false (UseGroup ("types" "tc_diag_text") ((mem "ambiguousShadowHelp" false) (mem "shadowIfaceLabel" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "dynAt" false) (mem "emptyShadowDicts" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "declTopFnNames" false) (mem "depExportsStandalone" false) (mem "depExportsUnknown" false) (mem "funDefs" false) (mem "graphPubDefiners" false) (mem "ieImplExistsForHeadOf" false) (mem "ifaceExportsIndex" false) (mem "ifaceMethodRows" false) (mem "importedBindings" false) (mem "lookupIdxById" false) (mem "lookupStandaloneValue" false) (mem "lookupStandaloneVar" false) (mem "lookupVar" false) (mem "methodRowIface" false) (mem "namesToSet" false) (mem "removeAllS" false) (mem "standaloneValueFor" false) (mem "hasImportDefiner" false) (mem "lookupImportedStandalone" false) (mem "allIfaceMethodNames" false))))
(DUse false (UseGroup ("types" "tc_diag") ((mem "pushTypeErrorAt" false) (mem "pushTypeErrorHelpFixAt" false))))
(DUse false (UseGroup ("types" "tc_scope") ((mem "ieImplExistsForHead" false) (mem "ifaceSortKey" false) (mem "methodAdmittedHere" false) (mem "methodDispatchIdx" false) (mem "methodEntryHere" false) (mem "methodVisibleHere" false) (mem "importedIfaceRows" false) (mem "aliasMethodSpellings" false) (mem "withAliasMethodNames" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "clampPrefix" false) (mem "instantiate" false) (mem "instantiateMethodTracked" false) (mem "predicateSlotArgs" false) (mem "predicateSlotCSlots" false) (mem "qualConstraintDecl" false) (mem "unifyIn" false) (mem "unifySpineProbe" false) (mem "zipSlotVecs" false))))
(DUse false (UseGroup ("types" "tc_decls") ((mem "sigToScheme" false))))
(DUse false (UseGroup ("types" "tc_solve_givens") ((mem "lookupPredicateSlots" false))))
(DUse false (UseGroup ("types" "tc_solve") ((mem "admittedSelection" false) (mem "routeLocalSym" false) (mem "routesOfMonosTopV" false))))
(DUse false (UseGroup ("types" "tc_solve_check") ((mem "dedupSlotVecs" false) (mem "ifaceSelfAndSupers" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Constraint" true) (mem "Decl" true) (mem "EffAtomTy" true) (mem "EvId" true) (mem "Expr" true) (mem "IfaceMethod" true) (mem "Loc" true) (mem "Route" true) (mem "Ty" true) (mem "UseMember" true) (mem "UsePath" true) (mem "effAtomSurface" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Mono" true) (mem "Scheme" true) (mem "lookupAssocI" false) (mem "normalize" false) (mem "ppMono" false) (mem "ppTy" false))))
(DUse false (UseGroup ("types" "evidence_complete") ((mem "Inner" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omKeys" false) (mem "omLookup" false) (mem "omSize" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("types" "evidence") ((mem "ScopeId" true))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "anyList" false) (mem "contains" false) (mem "dedup" false) (mem "escStr" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "isSome" false) (mem "joinWith" false) (mem "listLen" false) (mem "lookupAssoc" false) (mem "maxI" false) (mem "reverseL" false) (mem "startsWith" false))))
(DUse false (UseGroup ("list") ((mem "head" false))))
(DUse false (UseGroup ("frontend" "marker") ((mem "localBoundNames" false))))
(DUse false (UseGroup ("types" "private_mangle") ((mem "mangledName" false))))
(DUse false (UseGroup ("frontend" "visibility") ((mem "useModId" false))))
(DUse false (UseAlias ("map") "IdMap"))
(DUse false (UseGroup ("types" "tc_foreign") ((mem "declExternNames" false))))
(DTypeSig true "recoveredShadowSym" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyCon "String"))))
(DFunDef false "recoveredShadowSym" ((PVar "name") (PVar "tagRef")) (EBlock (DoLet false false (PVar "s") (EApp (EVar "routeLocalSym") (EUnOp "!" (EVar "tagRef")))) (DoExpr (EIf (EBinOp "==" (EVar "s") (EVar "name")) (ELit (LString "")) (EVar "s")))))
(DTypeSig true "methodCellOf" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvId") (TyCon "EvCell"))))
(DFunDef false "methodCellOf" ((PVar "gctx") (PVar "ev")) (EMatch (EApp (EApp (EVar "methodCellLookup") (EVar "gctx")) (EVar "ev")) (arm (PCon "Ok" (PVar "c")) () (EVar "c")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "panic") (EVar "message")))))
(DTypeSig true "methodCellLookup" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvId") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "EvCell")))))
(DFunDef false "methodCellLookup" ((PVar "gctx") (PCon "EvId" (PVar "m") (PVar "n"))) (EBlock (DoLet false false (PVar "g") (EFieldAccess (EVar "gctx") "graphRun")) (DoLet false false (PVar "i") (EBinOp "-" (EVar "n") (EFieldAccess (EVar "g") "evBase"))) (DoLet false false (PVar "arr") (EFieldAccess (EFieldAccess (EVar "g") "evCells") "value")) (DoExpr (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "method cell ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " is from an earlier graph")))) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "method cell ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " was never minted")))) (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (arm (PCon "Some" (PVar "c")) () (EApp (EVar "Ok") (EVar "c"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "method cell ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " was never minted")))))))))))
(DTypeSig true "declaredEffectsAt" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "MethodTrackedInstantiation") (TyFun (TyApp (TyCon "Option") (TyCon "CDeclared")) (TyApp (TyCon "Option") (TyCon "CDeclared"))))))
(DFunDef false "declaredEffectsAt" ((PVar "gctx") (PVar "inst") (PVar "declared")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "dc")) (ERecordCreate "CDeclared" ((fa "cdSlots" (EFieldAccess (EVar "dc") "cdSlots")) (fa "cdPrefix" (EFieldAccess (EVar "dc") "cdPrefix")) (fa "cdArgs" (EApp (EApp (EMethodRef "map") (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EListLit)) (EFieldAccess (EFieldAccess (EVar "inst") "mtiSubstitution") "misEffectSubst")) (EFieldAccess (EFieldAccess (EVar "inst") "mtiSubstitution") "misAuthSubst")))) (EFieldAccess (EVar "dc") "cdArgs"))))))) (EVar "declared")))
(DTypeSig true "declaredConstraintFor" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "CDeclared"))))
(DFunDef false "declaredConstraintFor" ((PVar "mctx") (PVar "name")) (EMatch (EApp (EApp (EVar "qualConstraintDecl") (EVar "mctx")) (EVar "name")) (arm (PCon "Some" (PVar "d")) () (EVar "d")) (arm (PCon "None") () (EIf (EApp (EApp (EVar "hasImportDefiner") (EVar "mctx")) (EVar "name")) (ERecordCreate "CDeclared" ((fa "cdSlots" (EListLit)) (fa "cdPrefix" (EApp (EVar "CDPLen") (ELit (LInt 0)))) (fa "cdArgs" (EListLit)))) (EApp (EApp (EVar "localDeclaredConstraintFor") (EVar "mctx")) (EVar "name"))))))
(DTypeSig false "localDeclaredConstraintFor" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "CDeclared"))))
(DFunDef false "localDeclaredConstraintFor" ((PVar "mctx") (PVar "name")) (EBlock (DoLet false false (PVar "stored") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "lookupPredicateSlots") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funPredicateSlotsIdxRef") "value")))) (DoLet false false (PVar "slots") (EApp (EVar "predicateSlotCSlots") (EVar "stored"))) (DoExpr (ERecordCreate "CDeclared" ((fa "cdSlots" (EVar "slots")) (fa "cdPrefix" (EApp (EApp (EVar "clampPrefix") (EVar "slots")) (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "funConstraintDeclaredRef") "value")))) (fa "cdArgs" (EApp (EVar "predicateSlotArgs") (EVar "stored"))))))))
(DTypeSig true "callArgVecsV" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "CSlot") (TyApp (TyCon "List") (TyCon "Mono")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Mono")))))))
(DFunDef false "callArgVecsV" ((PVar "gctx") (PList) PWild) (EListLit))
(DFunDef false "callArgVecsV" ((PVar "gctx") (PCons (PTuple (PVar "s") (PVar "v")) (PVar "rest")) (PVar "subst")) (EMatch (EApp (EApp (EVar "lookupAssocI") (EFieldAccess (EVar "s") "csId")) (EVar "subst")) (arm (PCon "Some" (PVar "m")) () (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "substArgVec") (EVar "gctx")) (EVar "subst")) (EVar "m")) (EVar "v")) (EApp (EApp (EApp (EVar "callArgVecsV") (EVar "gctx")) (EVar "rest")) (EVar "subst")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "callArgVecsV") (EVar "gctx")) (EVar "rest")) (EVar "subst")))))
(DTypeSig false "substArgVec" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "Mono")))))))
(DFunDef false "substArgVec" ((PVar "gctx") PWild (PVar "m") (PList)) (EListLit (EVar "m")))
(DFunDef false "substArgVec" ((PVar "gctx") (PVar "subst") PWild (PVar "v")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EVar "subst")) (EListLit)) (EListLit))) (EVar "v")))
(DTypeSig true "constraintMonosOf" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "constraintMonosOf" ((PList) PWild) (EListLit))
(DFunDef false "constraintMonosOf" ((PCons (PVar "id") (PVar "rest")) (PVar "subst")) (EMatch (EApp (EApp (EVar "lookupAssocI") (EVar "id")) (EVar "subst")) (arm (PCon "Some" (PVar "m")) () (EBinOp "::" (EVar "m") (EApp (EApp (EVar "constraintMonosOf") (EVar "rest")) (EVar "subst")))) (arm (PCon "None") () (EApp (EApp (EVar "constraintMonosOf") (EVar "rest")) (EVar "subst")))))
(DTypeSig true "checkAdmittedOccObls" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "Unit"))))
(DFunDef false "checkAdmittedOccObls" ((PVar "mctx") PWild) (EBlock (DoLet false false (PVar "env") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "bodyImplEnvRef") "value")) (DoExpr (EApp (EApp (EVar "each") (ELam ((PVar "o")) (EApp (EApp (EApp (EVar "checkAdmittedOccObl") (EVar "mctx")) (EVar "env")) (EVar "o")))) (EApp (EVar "reverseL") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "admittedOccObls") "value"))))))
(DTypeSig false "checkAdmittedOccObl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ImplEnv") (TyFun (TyTuple (TyCon "String") (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Unit")))))
(DFunDef false "checkAdmittedOccObl" ((PVar "mctx") (PVar "env") (PTuple (PVar "name") (PVar "mono") (PVar "loc"))) (EBlock (DoLet false false (PVar "ifs") (EApp (EApp (EVar "methodAdmittedHere") (EVar "mctx")) (EVar "name"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "admittedSelection") (EApp (EVar "siteFor") (EVar "mctx"))) (EVar "env")) (EVar "name")) (EVar "mono")) (arm (PCon "Selects" PWild PWild PWild) () (ELit LUnit)) (arm (PCon "Undecided") () (EApp (EApp (EApp (EApp (EVar "pushAmbiguousMethod") (EVar "mctx")) (EVar "name")) (EVar "ifs")) (EVar "loc"))) (arm (PCon "Unroutable" (PVar "sel")) () (EApp (EApp (EApp (EApp (EApp (EVar "pushUnroutableAdmitted") (EVar "mctx")) (EVar "name")) (EVar "ifs")) (EVar "sel")) (EVar "loc"))) (arm (PCon "SelectsNothing") () (EBlock (DoLet false false (PVar "recv") (EMatch (EApp (EApp (EApp (EApp (EVar "admittedReceiverMono") (EVar "mctx")) (EVar "name")) (EVar "ifs")) (EVar "mono")) (arm (PCon "Some" (PVar "at")) () (EApp (EVar "ppMono") (EVar "at"))) (arm (PCon "None") () (ELit (LString "this receiver"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (EVar "TNoImpl")) (EVar "loc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "no impl of ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " or "))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "ir")) (EFieldAccess (EVar "ir") "irName"))) (EVar "ifs"))))) (ELit (LString " for "))) (EApp (EMethodRef "display") (EVar "recv"))) (ELit (LString "; write an impl of one of them for it")))))))))))
(DTypeSig false "admittedReceiverMono" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "IfaceRef")) (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "Mono")))))))
(DFunDef false "admittedReceiverMono" ((PVar "mctx") PWild (PList) PWild) (EVar "None"))
(DFunDef false "admittedReceiverMono" ((PVar "mctx") (PVar "name") (PCons (PVar "ir") PWild) (PVar "mono")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "lookupIdxById") (EVar "ir")) (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodDispatchIdxByIdRef") "value"))) (ELam ((PVar "k")) (EApp (EApp (EVar "nthFunDomain") (EVar "k")) (EVar "mono")))))
(DTypeSig false "appSpineHead" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "appSpineHead" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "appSpineHead") (EVar "e")))
(DFunDef false "appSpineHead" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "appSpineHead") (EVar "f")))
(DFunDef false "appSpineHead" ((PVar "e")) (EVar "e"))
(DTypeSig false "appSpineNodes" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "appSpineNodes" ((PVar "e")) (EApp (EApp (EVar "appSpineNodesGo") (EVar "e")) (EListLit)))
(DTypeSig false "appSpineNodesGo" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Expr")))))
(DFunDef false "appSpineNodesGo" ((PCon "ELoc" PWild (PVar "e")) (PVar "acc")) (EApp (EApp (EVar "appSpineNodesGo") (EVar "e")) (EVar "acc")))
(DFunDef false "appSpineNodesGo" ((PCon "EApp" (PVar "f") (PVar "x")) (PVar "acc")) (EApp (EApp (EVar "appSpineNodesGo") (EVar "f")) (EBinOp "::" (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")) (EVar "acc"))))
(DFunDef false "appSpineNodesGo" (PWild (PVar "acc")) (EVar "acc"))
(DTypeSig true "plainAppHeadVar" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "plainAppHeadVar" ((PVar "env") (PVar "hd")) (EMatch (EApp (EApp (EVar "shadowStandaloneHead") (EVar "env")) (EVar "hd")) (arm (PCon "Some" PWild) () (EVar "False")) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "definerShadowArgHead") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "hd")) (arm (PCon "Some" PWild) () (EVar "False")) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "definerShadowVarHead") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "hd")) (arm (PCon "Some" PWild) () (EVar "False")) (arm (PCon "None") () (EVar "True"))))))))
(DTypeSig true "shadowStandaloneHead" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Int")))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Ref") (TyCon "Route")) (TyApp (TyCon "Ref") (TyCon "Inner")))))))))
(DFunDef false "shadowStandaloneHead" ((PVar "env") (PCon "ELoc" PWild (PVar "f"))) (EApp (EApp (EVar "shadowStandaloneHead") (EVar "env")) (EVar "f")))
(DFunDef false "shadowStandaloneHead" ((PVar "env") (PCon "EMethodAt" (PVar "name") PWild (PVar "ev"))) (EIf (EApp (EApp (EVar "isShadowStandalone") (EVar "env")) (EVar "name")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "methodCellOf") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "ev"))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "name") (EListLit (EFieldAccess (EVar "c") "ecArity")) (EListLit (ETuple (EFieldAccess (EVar "c") "ecTag") (EFieldAccess (EVar "c") "ecInner"))))))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "shadowStandaloneHead" ((PVar "env") (PCon "EVar" (PVar "name"))) (EIf (EApp (EApp (EVar "isShadowStandalone") (EVar "env")) (EVar "name")) (EApp (EVar "Some") (ETuple (EVar "name") (EListLit) (EListLit))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "shadowStandaloneHead" ((PVar "env") (PCon "EVarId" (PVar "name") PWild)) (EIf (EApp (EApp (EVar "isShadowStandalone") (EVar "env")) (EVar "name")) (EApp (EVar "Some") (ETuple (EVar "name") (EListLit) (EListLit))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "shadowStandaloneHead" ((PVar "env") PWild) (EVar "None"))
(DTypeSig true "shadowStandaloneSpineHeadAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Int")))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Ref") (TyCon "Route")) (TyApp (TyCon "Ref") (TyCon "Inner")))) (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr")))))))
(DFunDef false "shadowStandaloneSpineHeadAt" ((PVar "env") (PVar "f")) (EMatch (EApp (EApp (EVar "shadowStandaloneHead") (EVar "env")) (EApp (EVar "appSpineHead") (EVar "f"))) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple (PVar "name") (PVar "arityRefs") (PVar "tagRefs"))) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "nodes")) (ETuple (EVar "name") (EVar "arityRefs") (EVar "tagRefs") (EApp (EVar "appSpineHead") (EVar "f")) (EVar "nodes")))) (EApp (EApp (EApp (EVar "shadowSpineNodesAtImporter") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "f"))))))
(DTypeSig true "isShadowStandalone" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isShadowStandalone" ((PVar "env") (PVar "name")) (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "standaloneValuesRef") "value")) (EApp (EVar "isSome") (EApp (EApp (EVar "lookupImportedStandalone") (EVar "env")) (EVar "name")))) (EApp (EApp (EVar "singleTyparamIfaceMethod") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name"))))
(DTypeSig false "singleTyparamIfaceMethod" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "singleTyparamIfaceMethod" ((PVar "mctx") (PVar "name")) (EMatch (EApp (EApp (EVar "methodEntryHere") (EVar "mctx")) (EVar "name")) (arm (PCon "Some" (PTuple PWild (PVar "typarams") PWild PWild)) () (EBinOp "==" (EApp (EVar "listLen") (EVar "typarams")) (ELit (LInt 1)))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "methodAdmittedHere") (EVar "mctx")) (EVar "name")) (arm (PList) () (EVar "False")) (arm (PVar "ifs") () (EApp (EApp (EVar "allList") (ELam ((PVar "r")) (EMatch (EFieldAccess (EVar "r") "mrEntry") (arm (PTuple PWild (PVar "typarams") PWild PWild) () (EBinOp "==" (EApp (EVar "listLen") (EVar "typarams")) (ELit (LInt 1))))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EBlock (DoLet false false (PVar "key") (EApp (EVar "ifaceSortKey") (EApp (EVar "methodRowIface") (EVar "r")))) (DoExpr (EApp (EApp (EVar "anyList") (ELam ((PVar "ir")) (EBinOp "==" (EApp (EVar "ifaceSortKey") (EVar "ir")) (EVar "key")))) (EVar "ifs")))))) (EApp (EApp (EVar "methodVisibleHere") (EVar "mctx")) (EVar "name")))))))))
(DTypeSig false "ifaceMethodName" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "ifaceMethodName" ((PVar "mctx") (PVar "name")) (EBinOp "||" (EApp (EVar "isSome") (EApp (EApp (EVar "methodEntryHere") (EVar "mctx")) (EVar "name"))) (EApp (EVar "isNonEmptyL") (EApp (EApp (EVar "methodAdmittedHere") (EVar "mctx")) (EVar "name")))))
(DTypeSig true "stampRoutes" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Route"))) (TyCon "Unit")))
(DFunDef false "stampRoutes" ((PList)) (ELit LUnit))
(DFunDef false "stampRoutes" ((PCons (PVar "r") (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "r")) (EApp (EApp (EVar "RLocal") (EApp (EVar "routeLocalSym") (EUnOp "!" (EVar "r")))) (EListLit)))) (DoExpr (EApp (EVar "stampRoutes") (EVar "rest")))))
(DTypeSig true "stampMethodArities" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Int")))) (TyFun (TyCon "Int") (TyCon "Unit"))))
(DFunDef false "stampMethodArities" ((PList) PWild) (ELit LUnit))
(DFunDef false "stampMethodArities" ((PCons (PVar "r") (PVar "rest")) (PVar "arity")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "r")) (EApp (EVar "Some") (EVar "arity")))) (DoExpr (EApp (EApp (EVar "stampMethodArities") (EVar "rest")) (EVar "arity")))))
(DTypeSig true "shadowHeadEnv" (TyFun (TyCon "TcEnv") (TyCon "TcEnv")))
(DFunDef false "shadowHeadEnv" ((PVar "env")) (ERecordUpdate (EVar "env") ((fa "teDyn" (ERecordUpdate (EFieldAccess (EVar "env") "teDyn") ((fa "dcShadowHeadCtx" (EVar "True"))))))))
(DTypeSig true "importerShadowDomain" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Mono")))))
(DFunDef false "importerShadowDomain" ((PVar "env") (PVar "mname")) (EMatch (EApp (EApp (EVar "lookupStandaloneVar") (EVar "env")) (EVar "mname")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "s")) () (EMatch (EApp (EVar "normalize") (EApp (EApp (EVar "instantiate") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "s"))) (arm (PCon "TFun" (PVar "a") PWild PWild) () (EApp (EVar "Some") (EVar "a"))) (arm PWild () (EVar "None"))))))
(DTypeSig true "importerShadowDomainAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Mono"))))))
(DFunDef false "importerShadowDomainAt" ((PVar "env") (PVar "mname") (PVar "k")) (EMatch (EApp (EApp (EVar "lookupStandaloneVar") (EVar "env")) (EVar "mname")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "s")) () (EApp (EApp (EVar "nthFunDomain") (EVar "k")) (EApp (EApp (EVar "instantiate") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "s"))))))
(DTypeSig true "definerShadowArgHead" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Int"))) (TyApp (TyCon "Ref") (TyCon "Route")) (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyApp (TyCon "Ref") (TyCon "Inner")))))))
(DFunDef false "definerShadowArgHead" ((PVar "mctx") (PCon "ELoc" PWild (PVar "f"))) (EApp (EApp (EVar "definerShadowArgHead") (EVar "mctx")) (EVar "f")))
(DFunDef false "definerShadowArgHead" ((PVar "mctx") (PCon "EMethodAt" (PVar "name") PWild (PVar "ev"))) (EApp (EApp (EApp (EVar "definerShadowArgHeadCell") (EVar "mctx")) (EVar "name")) (EApp (EApp (EVar "methodCellOf") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ev"))))
(DFunDef false "definerShadowArgHead" ((PVar "mctx") PWild) (EVar "None"))
(DTypeSig false "definerShadowArgHeadCell" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "EvCell") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Int"))) (TyApp (TyCon "Ref") (TyCon "Route")) (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyApp (TyCon "Ref") (TyCon "Inner"))))))))
(DFunDef false "definerShadowArgHeadCell" ((PVar "mctx") (PVar "name") (PVar "c")) (EIf (EBinOp "||" (EApp (EApp (EVar "isDefinerShadow") (EVar "mctx")) (EVar "name")) (EApp (EApp (EApp (EVar "importerShadowOnEmitPath") (EVar "mctx")) (EVar "name")) (EFieldAccess (EVar "c") "ecTag"))) (EApp (EVar "Some") (ETuple (EVar "name") (EFieldAccess (EVar "c") "ecArity") (EFieldAccess (EVar "c") "ecTag") (EFieldAccess (EVar "c") "ecImpl") (EFieldAccess (EVar "c") "ecInner"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "occurrenceCarriesMangledShadowSym" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyCon "Bool"))))
(DFunDef false "occurrenceCarriesMangledShadowSym" ((PVar "name") (PVar "tagRef")) (EBinOp "/=" (EApp (EApp (EVar "recoveredShadowSym") (EVar "name")) (EVar "tagRef")) (ELit (LString ""))))
(DTypeSig false "importerShadowOnEmitPath" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyCon "Bool")))))
(DFunDef false "importerShadowOnEmitPath" ((PVar "mctx") (PVar "name") (PVar "tagRef")) (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "singleTyparamIfaceMethod") (EVar "mctx")) (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "mangledFunDefsPresentRef") "value")) (EApp (EApp (EVar "occurrenceCarriesMangledShadowSym") (EVar "name")) (EVar "tagRef"))))
(DTypeSig true "isDefinerShadow" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isDefinerShadow" ((PVar "mctx") (PVar "name")) (EBinOp "&&" (EApp (EApp (EVar "ifaceMethodName") (EVar "mctx")) (EVar "name")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "definerShadowNamesRef") "value"))))
(DTypeSig true "definerReceiverDispatches" (TyFun (TyCon "DynCtx") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyCon "Bool")))))
(DFunDef false "definerReceiverDispatches" ((PVar "dyn") (PVar "name") (PVar "xt")) (EIf (EApp (EApp (EVar "isDefinerShadow") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "name")) (EApp (EApp (EApp (EVar "definerReceiverIsDictVar") (EVar "dyn")) (EVar "name")) (EVar "xt")) (EIf (EVar "otherwise") (EMatch (EApp (EVar "headTyconMono") (EVar "xt")) (arm (PCon "Some" (PVar "head")) () (EApp (EApp (EApp (EApp (EVar "ieImplExistsForHead") (EFieldAccess (EVar "dyn") "dcModule")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcCells") "bodyImplEnvRef") "value")) (EVar "name")) (EVar "head"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "definerReceiverIsDictVar") (EVar "dyn")) (EVar "name")) (EVar "xt")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "definerReceiverIsDictVar" (TyFun (TyCon "DynCtx") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyCon "Bool")))))
(DFunDef false "definerReceiverIsDictVar" ((PVar "dyn") (PVar "name") (PVar "xt")) (EMatch (EApp (EVar "headMonoNode") (EVar "xt")) (arm (PCon "TVar" (PVar "cell")) () (EMatch (EApp (EApp (EVar "methodEntryHere") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "name")) (arm (PCon "Some" (PTuple (PVar "mIface") PWild PWild PWild)) () (EApp (EApp (EApp (EApp (EVar "dictVarSatisfiesIface") (EFieldAccess (EVar "dyn") "dcModule")) (EFieldAccess (EVar "mIface") "irName")) (EApp (EVar "tyvarId") (EVar "cell"))) (EApp (EVar "groupMonos") (EVar "dyn")))) (arm (PCon "None") () (EVar "False")))) (arm PWild () (EVar "False"))))
(DTypeSig false "groupMonos" (TyFun (TyCon "DynCtx") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))))
(DFunDef false "groupMonos" ((PVar "dyn")) (EMatch (EFieldAccess (EVar "dyn") "dcGroup") (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "group")) () (EFieldAccess (EVar "group") "gcMonos"))))
(DTypeSig false "dictVarSatisfiesIface" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyCon "Bool"))))))
(DFunDef false "dictVarSatisfiesIface" ((PVar "mctx") PWild PWild (PList)) (EVar "False"))
(DFunDef false "dictVarSatisfiesIface" ((PVar "mctx") (PVar "mIface") (PVar "id") (PCons (PTuple (PVar "cIface") (PVar "cm")) (PVar "rest"))) (EIf (EBinOp "&&" (EApp (EApp (EVar "monoIsTyvarId") (EVar "cm")) (EVar "id")) (EApp (EApp (EVar "contains") (EVar "mIface")) (EApp (EApp (EVar "ifaceSelfAndSupers") (EVar "mctx")) (EVar "cIface")))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "dictVarSatisfiesIface") (EVar "mctx")) (EVar "mIface")) (EVar "id")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "enforceStandaloneDomainAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Int") (TyCon "Unit")))))))
(DFunDef false "enforceStandaloneDomainAt" ((PVar "env") (PVar "name") (PVar "xt") (PVar "dloc") (PVar "k")) (EMatch (EApp (EApp (EApp (EVar "standaloneShadowDomainAt") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "k")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "dom")) () (EIf (EApp (EApp (EApp (EVar "definerReceiverIsDictVar") (EFieldAccess (EVar "env") "teDyn")) (EVar "name")) (EVar "xt")) (ELit LUnit) (EApp (EApp (EApp (EApp (EVar "unifyStandaloneDomain") (EFieldAccess (EVar "env") "teDyn")) (EVar "dom")) (EVar "xt")) (EVar "dloc"))))))
(DTypeSig true "groundShadowReceiver" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "Option") (TyCon "Mono")) (TyFun (TyCon "Mono") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit")))))))
(DFunDef false "groundShadowReceiver" ((PVar "dyn") (PVar "dom") (PVar "xt") (PVar "isDictVar") (PVar "dloc")) (EIf (EVar "isDictVar") (ELit LUnit) (EIf (EApp (EVar "isSome") (EApp (EVar "headTyconMono") (EVar "xt"))) (ELit LUnit) (EIf (EVar "otherwise") (EMatch (EVar "dom") (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "d")) () (EApp (EApp (EApp (EApp (EVar "unifyStandaloneDomain") (EVar "dyn")) (EVar "d")) (EVar "xt")) (EVar "dloc")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "shadowDomainForAt" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Mono")))))))
(DFunDef false "shadowDomainForAt" ((PVar "env") (PVar "name") (PLit (LString "")) (PVar "k")) (EApp (EApp (EApp (EVar "standaloneShadowDomainAt") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "k")))
(DFunDef false "shadowDomainForAt" ((PVar "env") PWild (PVar "sym") (PVar "k")) (EMatch (EApp (EApp (EVar "lookupVar") (EVar "env")) (EVar "sym")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "s")) () (EApp (EApp (EVar "nthFunDomain") (EVar "k")) (EApp (EApp (EVar "instantiate") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "s"))))))
(DTypeSig false "unifyStandaloneDomain" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit"))))))
(DFunDef false "unifyStandaloneDomain" ((PVar "dyn") (PVar "dom") (PVar "xt") (PVar "dloc")) (EApp (EApp (EApp (EVar "unifyIn") (EApp (EApp (EVar "dynAt") (EVar "dloc")) (EVar "dyn"))) (EVar "dom")) (EVar "xt")))
(DTypeSig true "standaloneShadowDomainAt" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Mono"))))))
(DFunDef false "standaloneShadowDomainAt" ((PVar "mctx") (PVar "name") (PVar "k")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "definerShadowSigsRef") "value")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "ty")) () (EApp (EApp (EVar "nthFunDomain") (EVar "k")) (EApp (EApp (EVar "instantiate") (EVar "mctx")) (EApp (EApp (EVar "sigToScheme") (EVar "mctx")) (EVar "ty")))))))
(DTypeSig true "rejectAdmittedValueOccurrence" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Unit"))))
(DFunDef false "rejectAdmittedValueOccurrence" ((PVar "mctx") (PVar "name")) (EIf (EApp (EApp (EVar "isDefinerShadow") (EVar "mctx")) (EVar "name")) (ELit LUnit) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "ifs") (EApp (EApp (EVar "methodAdmittedHere") (EVar "mctx")) (EVar "name"))) (DoExpr (EIf (EBinOp ">=" (EApp (EVar "listLen") (EVar "ifs")) (ELit (LInt 2))) (EApp (EApp (EApp (EApp (EVar "pushAmbiguousShadowDecl") (EVar "mctx")) (EVar "name")) (EVar "ifs")) (EFieldAccess (EVar "mctx") "mcLoc")) (ELit LUnit)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "standaloneValueBinding" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "ValueScheme")))))
(DFunDef false "standaloneValueBinding" ((PVar "env") (PVar "name")) (EIf (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcShadowHeadCtx") (EVar "None") (EIf (EBinOp "&&" (EApp (EApp (EVar "ifaceMethodName") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "definerShadowNamesRef") "value"))) (EApp (EApp (EVar "lookupStandaloneValue") (EVar "env")) (EVar "name")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "singleTyparamIfaceMethod") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name"))) (EVar "None") (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupStandaloneValue") (EVar "env")) (EVar "name")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig true "standaloneValueBindingEmit" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyApp (TyCon "Option") (TyCon "ValueScheme"))))))
(DFunDef false "standaloneValueBindingEmit" ((PVar "env") (PVar "name") (PVar "tagRef")) (EIf (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcShadowHeadCtx") (EVar "None") (EIf (EBinOp "==" (EApp (EApp (EVar "recoveredShadowSym") (EVar "name")) (EVar "tagRef")) (ELit (LString ""))) (EVar "None") (EIf (EApp (EVar "not") (EApp (EApp (EVar "emitValueShadowGate") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name"))) (EVar "None") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "standaloneValueFor") (EVar "env")) (EVar "name")) (EApp (EApp (EVar "recoveredShadowSym") (EVar "name")) (EVar "tagRef"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "emitValueShadowGate" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "emitValueShadowGate" ((PVar "mctx") (PVar "name")) (EIf (EApp (EApp (EVar "isDefinerShadow") (EVar "mctx")) (EVar "name")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "singleTyparamIfaceMethod") (EVar "mctx")) (EVar "name")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "standaloneValuePinned" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "standaloneValuePinned" ((PVar "env") (PVar "name")) (EApp (EVar "isSome") (EApp (EApp (EVar "standaloneValueBinding") (EVar "env")) (EVar "name"))))
(DTypeSig true "definerShadowVarHead" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "definerShadowVarHead" ((PVar "mctx") (PCon "ELoc" PWild (PVar "f"))) (EApp (EApp (EVar "definerShadowVarHead") (EVar "mctx")) (EVar "f")))
(DFunDef false "definerShadowVarHead" ((PVar "mctx") (PCon "EVar" (PVar "name"))) (EIf (EBinOp "&&" (EApp (EApp (EVar "ifaceMethodName") (EVar "mctx")) (EVar "name")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "definerShadowNamesRef") "value"))) (EApp (EVar "Some") (EVar "name")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "definerShadowVarHead" ((PVar "mctx") (PCon "EVarId" (PVar "name") PWild)) (EIf (EBinOp "&&" (EApp (EApp (EVar "ifaceMethodName") (EVar "mctx")) (EVar "name")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "definerShadowNamesRef") "value"))) (EApp (EVar "Some") (EVar "name")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "definerShadowVarHead" ((PVar "mctx") PWild) (EVar "None"))
(DTypeSig false "shadowSpineNodesAt" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Expr")))))))
(DFunDef false "shadowSpineNodesAt" ((PVar "mctx") (PVar "name") (PVar "f")) (EBlock (DoLet false false (PVar "nodes") (EApp (EVar "appSpineNodes") (EVar "f"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "nodes")) (EVar "None") (EMatch (EApp (EApp (EVar "methodDispatchIdx") (EVar "mctx")) (EVar "name")) (arm (PCon "Some" (PVar "k")) () (EIf (EBinOp "==" (EVar "k") (EApp (EVar "listLen") (EVar "nodes"))) (EApp (EVar "Some") (EVar "nodes")) (EVar "None"))) (arm (PCon "None") () (EVar "None")))))))
(DTypeSig false "shadowSpineNodesAtImporter" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Expr")))))))
(DFunDef false "shadowSpineNodesAtImporter" ((PVar "mctx") (PVar "name") (PVar "f")) (EBlock (DoLet false false (PVar "nodes") (EApp (EVar "appSpineNodes") (EVar "f"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "nodes")) (EVar "None") (EMatch (EApp (EApp (EVar "importerDispatchIdxOuter") (EVar "mctx")) (EVar "name")) (arm (PCon "Some" (PVar "k")) () (EIf (EBinOp "==" (EVar "k") (EApp (EVar "listLen") (EVar "nodes"))) (EApp (EVar "Some") (EVar "nodes")) (EVar "None"))) (arm (PCon "None") () (EVar "None")))))))
(DTypeSig true "definerShadowSpineArgAt" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Int"))) (TyApp (TyCon "Ref") (TyCon "Route")) (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyApp (TyCon "Ref") (TyCon "Inner")) (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr")))))))
(DFunDef false "definerShadowSpineArgAt" ((PVar "mctx") (PVar "f")) (EMatch (EApp (EApp (EVar "definerShadowArgHead") (EVar "mctx")) (EApp (EVar "appSpineHead") (EVar "f"))) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple (PVar "name") (PVar "arityRef") (PVar "tagRef") (PVar "implRef") (PVar "innerRef"))) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "nodes")) (ETuple (EVar "name") (EVar "arityRef") (EVar "tagRef") (EVar "implRef") (EVar "innerRef") (EApp (EVar "appSpineHead") (EVar "f")) (EVar "nodes")))) (EApp (EApp (EApp (EVar "shadowSpineNodesAt") (EVar "mctx")) (EVar "name")) (EVar "f"))))))
(DTypeSig true "definerShadowSpineVarAt" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr")))))))
(DFunDef false "definerShadowSpineVarAt" ((PVar "mctx") (PVar "f")) (EMatch (EApp (EApp (EVar "definerShadowVarHead") (EVar "mctx")) (EApp (EVar "appSpineHead") (EVar "f"))) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "name")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "nodes")) (ETuple (EVar "name") (EApp (EVar "appSpineHead") (EVar "f")) (EVar "nodes")))) (EApp (EApp (EApp (EVar "shadowSpineNodesAt") (EVar "mctx")) (EVar "name")) (EVar "f"))))))
(DTypeSig true "shadowStandaloneDictSlotsAt" (TyFun (TyCon "DynCtx") (TyFun (TyApp (TyCon "Option") (TyCon "ValueScheme")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyCon "ShadowDicts")))))))
(DFunDef false "shadowStandaloneDictSlotsAt" ((PVar "dyn") (PCon "None") PWild PWild PWild) (EVar "emptyShadowDicts"))
(DFunDef false "shadowStandaloneDictSlotsAt" ((PVar "dyn") (PCon "Some" (PVar "value")) (PVar "name") (PVar "key") (PVar "xt")) (EBlock (DoLet false false (PVar "inst") (EApp (EApp (EVar "instantiateMethodTracked") (EFieldAccess (EVar "dyn") "dcModule")) (EFieldAccess (EVar "value") "vsScheme"))) (DoLet false false (PVar "dc") (EApp (EApp (EVar "optionOr") (EApp (EApp (EApp (EVar "shadowDeclaredFor") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "name")) (EVar "key"))) (EApp (EApp (EApp (EVar "declaredEffectsAt") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph")) (EVar "inst")) (EFieldAccess (EVar "value") "vsDeclared")))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EFieldAccess (EVar "dc") "cdSlots")) (EVar "emptyShadowDicts") (EBlock (DoExpr (EApp (EApp (EApp (EVar "unifySpineProbe") (EVar "dyn")) (EFieldAccess (EVar "inst") "mtiBody")) (EListLit (EVar "xt")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "shadowStandaloneDictSlots") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph")) (EFieldAccess (EVar "dc") "cdSlots")) (EFieldAccess (EVar "dc") "cdArgs")) (EFieldAccess (EFieldAccess (EVar "inst") "mtiSubstitution") "misTypeSubst"))))))))
(DTypeSig true "shadowDeclaredFor" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "CDeclared")))))
(DFunDef false "shadowDeclaredFor" ((PVar "mctx") (PVar "name") (PVar "key")) (EIf (EApp (EApp (EVar "isDefinerShadow") (EVar "mctx")) (EVar "name")) (EApp (EApp (EVar "localDeclaredConstraintFor") (EVar "mctx")) (EVar "key")) (EIf (EVar "otherwise") (EApp (EApp (EVar "declaredConstraintFor") (EVar "mctx")) (EVar "key")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "shadowStandaloneDictSlots" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "CSlot")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyCon "ShadowDicts"))))))
(DFunDef false "shadowStandaloneDictSlots" ((PVar "gctx") (PVar "slots") (PVar "args") (PVar "subst")) (EIf (EApp (EVar "isEmptyL") (EVar "slots")) (EVar "emptyShadowDicts") (EBlock (DoLet false false (PVar "expandedV") (EApp (EVar "dedupSlotVecs") (EApp (EApp (EVar "zipSlotVecs") (EVar "slots")) (EVar "args")))) (DoLet false false (PVar "expanded") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "expandedV"))) (DoExpr (ERecordCreate "ShadowDicts" ((fa "sdMonos" (EApp (EApp (EVar "constraintMonosOf") (EApp (EApp (EMethodRef "map") (ELam ((PVar "sl")) (EFieldAccess (EVar "sl") "csId"))) (EVar "expanded"))) (EVar "subst"))) (fa "sdIfaces" (EApp (EApp (EMethodRef "map") (ELam ((PVar "sl")) (EFieldAccess (EVar "sl") "csIface"))) (EVar "expanded"))) (fa "sdArgVecs" (EApp (EApp (EApp (EVar "callArgVecsV") (EVar "gctx")) (EVar "expandedV")) (EVar "subst")))))))))
(DTypeSig true "importerAdmittedVerdict" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ImplEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "AdmittedVerdict"))))))
(DFunDef false "importerAdmittedVerdict" ((PVar "mctx") (PVar "env") (PVar "name") (PVar "ats")) (EMatch (EApp (EApp (EVar "methodAdmittedHere") (EVar "mctx")) (EVar "name")) (arm (PList) () (EVar "AdDefer")) (arm (PVar "ifs") () (EIf (EBinOp "<" (EApp (EVar "listLen") (EVar "ifs")) (ELit (LInt 2))) (EVar "AdDefer") (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "admittedDeclHitters") (EVar "mctx")) (EVar "env")) (EVar "name")) (EVar "ifs")) (EVar "ats")) (arm (PCon "None") () (EApp (EVar "AdReject") (EVar "ifs"))) (arm (PCon "Some" (PVar "hits")) () (EIf (EApp (EVar "isEmptyL") (EVar "hits")) (EVar "AdStandalone") (EApp (EVar "AdReject") (EVar "ifs")))))))))
(DTypeSig false "admittedDeclHitters" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ImplEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "IfaceRef")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "IfaceRef")))))))))
(DFunDef false "admittedDeclHitters" ((PVar "mctx") PWild PWild (PList) PWild) (EApp (EVar "Some") (EListLit)))
(DFunDef false "admittedDeclHitters" ((PVar "mctx") (PVar "env") (PVar "name") (PCons (PVar "ir") (PVar "rest")) (PVar "ats")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "admittedDeclHits") (EVar "mctx")) (EVar "env")) (EVar "name")) (EVar "ir")) (EVar "ats")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "hit")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "hs")) (EIf (EVar "hit") (EBinOp "::" (EVar "ir") (EVar "hs")) (EVar "hs")))) (EApp (EApp (EApp (EApp (EApp (EVar "admittedDeclHitters") (EVar "mctx")) (EVar "env")) (EVar "name")) (EVar "rest")) (EVar "ats"))))))
(DTypeSig false "admittedDeclHits" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ImplEnv") (TyFun (TyCon "String") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "Bool"))))))))
(DFunDef false "admittedDeclHits" ((PVar "mctx") (PVar "env") (PVar "name") (PVar "ir") (PVar "ats")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "lookupIdxById") (EVar "ir")) (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodDispatchIdxByIdRef") "value"))) (ELam ((PVar "k")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "nthMono") (EVar "k")) (EVar "ats"))) (ELam ((PVar "at")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "headTyconMono") (EVar "at"))) (ELam ((PVar "hk")) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "ieImplExistsForHeadOf") (EVar "mctx")) (EVar "env")) (EVar "name")) (EVar "hk")) (EApp (EVar "Some") (EListLit (EVar "ir"))))))))))))
(DTypeSig false "importerDispatchIdxOuter" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "importerDispatchIdxOuter" ((PVar "mctx") (PVar "name")) (EMatch (EApp (EApp (EApp (EVar "admittedIdxMax") (EVar "mctx")) (EVar "name")) (EApp (EApp (EVar "methodAdmittedHere") (EVar "mctx")) (EVar "name"))) (arm (PCon "Some" (PVar "k")) () (EApp (EVar "Some") (EVar "k"))) (arm (PCon "None") () (EApp (EApp (EVar "methodDispatchIdx") (EVar "mctx")) (EVar "name")))))
(DTypeSig false "admittedIdxMax" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "IfaceRef")) (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "admittedIdxMax" ((PVar "mctx") PWild (PList)) (EVar "None"))
(DFunDef false "admittedIdxMax" ((PVar "mctx") (PVar "name") (PCons (PVar "ir") (PVar "rest"))) (EBlock (DoLet false false (PVar "here") (EApp (EApp (EApp (EVar "lookupIdxById") (EVar "ir")) (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodDispatchIdxByIdRef") "value"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "admittedIdxMax") (EVar "mctx")) (EVar "name")) (EVar "rest")) (arm (PCon "None") () (EVar "here")) (arm (PCon "Some" (PVar "k")) () (EMatch (EVar "here") (arm (PCon "None") () (EApp (EVar "Some") (EVar "k"))) (arm (PCon "Some" (PVar "j")) () (EApp (EVar "Some") (EApp (EApp (EVar "maxI") (EVar "j")) (EVar "k"))))))))))
(DTypeSig true "groundAdmittedReceivers" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit"))))))
(DFunDef false "groundAdmittedReceivers" ((PVar "env") (PVar "mname") (PVar "ats") (PVar "dloc")) (EApp (EApp (EApp (EApp (EApp (EVar "groundAdmittedGo") (EVar "env")) (EVar "mname")) (EApp (EApp (EVar "methodAdmittedHere") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "mname"))) (EVar "ats")) (EVar "dloc")))
(DTypeSig false "groundAdmittedGo" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "IfaceRef")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit")))))))
(DFunDef false "groundAdmittedGo" ((PVar "env") PWild (PList) PWild PWild) (ELit LUnit))
(DFunDef false "groundAdmittedGo" ((PVar "env") (PVar "mname") (PCons (PVar "ir") (PVar "rest")) (PVar "ats") (PVar "dloc")) (EBlock (DoExpr (EMatch (EApp (EApp (EApp (EVar "lookupIdxById") (EVar "ir")) (EVar "mname")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "methodDispatchIdxByIdRef") "value")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "k")) () (EMatch (EApp (EApp (EVar "nthMono") (EVar "k")) (EVar "ats")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "at")) () (EApp (EApp (EApp (EApp (EApp (EVar "groundShadowReceiver") (EFieldAccess (EVar "env") "teDyn")) (EApp (EApp (EApp (EVar "importerShadowDomainAt") (EVar "env")) (EVar "mname")) (EVar "k"))) (EVar "at")) (EApp (EApp (EApp (EVar "definerReceiverIsDictVar") (EFieldAccess (EVar "env") "teDyn")) (EVar "mname")) (EVar "at"))) (EVar "dloc"))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "groundAdmittedGo") (EVar "env")) (EVar "mname")) (EVar "rest")) (EVar "ats")) (EVar "dloc")))))
(DTypeSig true "pushAmbiguousShadowDecl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "IfaceRef")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit"))))))
(DFunDef false "pushAmbiguousShadowDecl" ((PVar "mctx") (PVar "name") (PVar "ifs") (PVar "dloc")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushTypeErrorHelpFixAt") (EVar "mctx")) (EVar "TAmbiguousShadowDecl")) (EVar "dloc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` is ambiguous here: "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " and "))) (EApp (EApp (EMethodRef "map") (EVar "shadowIfaceLabel")) (EVar "ifs"))))) (ELit (LString " each declare a method `"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` and are both in scope; "))) (EApp (EMethodRef "display") (EVar "ambiguousShadowHelp"))) (ELit (LString "")))) (EVar "ambiguousShadowHelp")) (EVar "None")))
(DTypeSig false "pushAmbiguousMethod" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "IfaceRef")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit"))))))
(DFunDef false "pushAmbiguousMethod" ((PVar "mctx") (PVar "name") (PVar "ifs") (PVar "loc")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushTypeErrorHelpFixAt") (EVar "mctx")) (EVar "TAmbiguousMethod")) (EVar "loc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` is ambiguous here: "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " and "))) (EApp (EApp (EMethodRef "map") (EVar "shadowIfaceLabel")) (EVar "ifs"))))) (ELit (LString " each declare a method `"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "`, and this use does not decide which one it means; bring only one of those interfaces into scope")))) (EVar "ambiguousShadowHelp")) (EVar "None")))
(DTypeSig false "pushUnroutableAdmitted" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "IfaceRef")) (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Unit")))))))
(DFunDef false "pushUnroutableAdmitted" ((PVar "mctx") (PVar "name") (PVar "ifs") (PVar "sel") (PVar "loc")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushTypeErrorHelpFixAt") (EVar "mctx")) (EVar "TAmbiguousMethod")) (EVar "loc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` names a method of more than one interface here ("))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " and "))) (EApp (EApp (EMethodRef "map") (EVar "shadowIfaceLabel")) (EVar "ifs"))))) (ELit (LString "); the one this use selects, `"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "sel") "irName"))) (ELit (LString "."))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "`, has method-level constraints, and a use of a name that more than one interface declares cannot supply their dictionaries; bring only one of those interfaces into scope")))) (EVar "ambiguousShadowHelp")) (EVar "None")))
(DTypeSig true "resolveRLocalSite" (TyFun (TyCon "SiteCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "IfaceRef")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Mono"))) (TyCon "Unit"))))))))))))
(DFunDef false "resolveRLocalSite" ((PVar "sx") (PVar "name") (PVar "tagRef") (PVar "am") (PVar "encl") (PVar "scope") (PVar "sym") (PVar "monos") (PVar "ifaces") (PVar "argVecs")) (EMatch (EApp (EVar "headTyconMono") (EVar "am")) (arm (PCon "Some" (PVar "tag")) () (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "isDefinerShadow") (EFieldAccess (EVar "sx") "sxModule")) (EVar "name"))) (EApp (EApp (EApp (EApp (EVar "ieImplExistsForHead") (EFieldAccess (EVar "sx") "sxModule")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "bodyImplEnvRef") "value")) (EVar "name")) (EVar "tag"))) (ELit LUnit) (EApp (EApp (EVar "setRef") (EVar "tagRef")) (EApp (EApp (EVar "RLocal") (EVar "sym")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routesOfMonosTopV") (EVar "sx")) (EVar "encl")) (EVar "scope")) (EVar "monos")) (EVar "ifaces")) (EVar "argVecs")))))) (arm (PCon "None") () (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "sx") "sxModule") "mcCells") "definerShadowNamesRef") "value")) (EApp (EApp (EVar "setRef") (EVar "tagRef")) (EApp (EApp (EVar "RLocal") (EVar "sym")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routesOfMonosTopV") (EVar "sx")) (EVar "encl")) (EVar "scope")) (EVar "monos")) (EVar "ifaces")) (EVar "argVecs")))) (ELit LUnit)))))
(DTypeSig true "isPreludeMid" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isPreludeMid" ((PVar "mid")) (EBinOp "||" (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EBinOp "==" (EVar "mid") (ELit (LString "")))))
(DTypeSig true "definerShadowsFromSet" (TyFun (TyCon "GraphCtx") (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "definerShadowsFromSet" ((PVar "gctx") (PVar "isMethod") (PVar "prog")) (EBlock (DoLet false false (PVar "localNames") (EApp (EVar "dedup") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "funDefs") (EVar "prog"))))) (DoLet false false (PVar "direct") (EApp (EApp (EMethodRef "filter") (EVar "isMethod")) (EVar "localNames"))) (DoLet false false (PVar "sm") (EFieldAccess (EFieldAccess (EVar "gctx") "mangledShadowMapRef") "value")) (DoLet false false (PVar "bares") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "sm")) (arm (PCon "Some" (PVar "bare")) () (EListLit (EVar "bare"))) (arm (PCon "None") () (EListLit))))) (EVar "localNames"))) (DoExpr (EApp (EApp (EVar "removeAllS") (EApp (EVar "localBoundNames") (EVar "prog"))) (EApp (EVar "dedup") (EBinOp "++" (EVar "direct") (EVar "bares")))))))
(DTypeSig true "standaloneShadowsFromSet" (TyFun (TyCon "GraphCtx") (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "standaloneShadowsFromSet" ((PVar "gctx") (PVar "isMethod") (PVar "fnSet") (PVar "prog")) (EBlock (DoLet false false (PVar "localNames") (EApp (EApp (EVar "namesToSet") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "funDefs") (EVar "prog")))) (EVar "omEmpty"))) (DoLet false false (PVar "direct") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "n")) (EBinOp "&&" (EApp (EVar "isMethod") (EVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "localNames")))))) (EApp (EVar "omKeys") (EVar "fnSet")))) (DoLet false false (PVar "sm") (EFieldAccess (EFieldAccess (EVar "gctx") "mangledShadowMapRef") "value")) (DoLet false false (PVar "mangled") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "sm")) (arm (PCon "Some" (PVar "bare")) () (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "localNames")) (EListLit) (EListLit (EVar "bare")))) (arm (PCon "None") () (EListLit))))) (EApp (EVar "omKeys") (EVar "fnSet")))) (DoExpr (EApp (EVar "dedup") (EBinOp "++" (EVar "direct") (EVar "mangled"))))))
(DTypeSig true "nameableIfaceShadows" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "nameableIfaceShadows" ((PVar "gctx") PWild (PList)) (EListLit))
(DFunDef false "nameableIfaceShadows" ((PVar "gctx") (PVar "prog") (PVar "names")) (EIf (EBinOp "==" (EApp (EVar "omSize") (EApp (EApp (EVar "ifaceExportsIndex") (EVar "gctx")) (ELit LUnit))) (ELit (LInt 0))) (EVar "names") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "nameable") (EApp (EApp (EVar "nameableIfaceMethodSet") (EVar "gctx")) (EVar "prog"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "nameable")))) (EVar "names")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "nameableIfaceMethodSet" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "nameableIfaceMethodSet" ((PVar "gctx") (PVar "prog")) (EApp (EApp (EVar "namesToSet") (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EApp (EApp (EVar "nameableIfaceRows") (EVar "gctx")) (EVar "prog")))) (EVar "omEmpty")))
(DTypeSig true "nameableIfaceRows" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "nameableIfaceRows" ((PVar "gctx") (PVar "prog")) (EApp (EApp (EVar "nameableIfaceRowsIn") (EApp (EApp (EVar "ifaceExportsIndex") (EVar "gctx")) (ELit LUnit))) (EVar "prog")))
(DTypeSig false "nameableIfaceRowsIn" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "nameableIfaceRowsIn" ((PVar "idx") (PVar "prog")) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (ELit (LString "core"))) (EVar "idx"))) (EApp (EVar "ifaceMethodRows") (EVar "prog"))) (EApp (EApp (EVar "importedIfaceRows") (EVar "idx")) (EVar "prog"))))
(DTypeSig true "importedStandaloneShadows" (TyFun (TyCon "DriveOutputs") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Ty")) (TyCon "Ty") (TyCon "Loc")))))))
(DFunDef false "importedStandaloneShadows" ((PVar "o") (PVar "graph") (PVar "prog")) (EApp (EApp (EApp (EVar "importedStandaloneShadowsIn") (EFieldAccess (EVar "o") "doIfaceExports")) (EVar "graph")) (EVar "prog")))
(DTypeSig true "importedStandaloneShadowsIn" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Ty")) (TyCon "Ty") (TyCon "Loc")))))))
(DFunDef false "importedStandaloneShadowsIn" ((PVar "idx") (PVar "graph") (PVar "prog")) (EIf (EBinOp "==" (EApp (EVar "omSize") (EVar "idx")) (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EVar "nameableIfaceRowsIn") (EVar "idx")) (EVar "prog"))) (DoLet false false (PVar "nameable") (EApp (EApp (EVar "namesToSet") (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "rows"))) (EVar "omEmpty"))) (DoLet false false (PVar "universe") (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "graph")) (EVar "prog"))) (DoExpr (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EApp (EVar "importShadowsOfDecl") (EVar "graph")) (EVar "rows")) (EVar "nameable")) (EVar "universe"))) (EVar "prog")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "importShadowsOfDecl" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Ty")) (TyCon "Ty") (TyCon "Loc")))))))))
(DFunDef false "importShadowsOfDecl" ((PVar "graph") (PVar "rows") (PVar "nameable") (PVar "universe") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EApp (EVar "importShadowsOfDecl") (EVar "graph")) (EVar "rows")) (EVar "nameable")) (EVar "universe")) (EVar "d")))
(DFunDef false "importShadowsOfDecl" ((PVar "graph") (PVar "rows") (PVar "nameable") (PVar "universe") (PCon "DUse" PWild (PVar "path") PWild)) (EMatch (EVar "path") (arm (PCon "UseGroup" PWild (PVar "ms")) () (EMatch (EApp (EApp (EVar "lookupAssoc") (EApp (EVar "useModId") (EVar "path"))) (EVar "graph")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "depDecls")) () (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EApp (EApp (EVar "importMemberShadow") (EVar "graph")) (EVar "rows")) (EVar "nameable")) (EVar "universe")) (EVar "depDecls"))) (EVar "ms"))))) (arm PWild () (EListLit))))
(DFunDef false "importShadowsOfDecl" (PWild PWild PWild PWild PWild) (EListLit))
(DTypeSig false "importMemberShadow" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Ty")) (TyCon "Ty") (TyCon "Loc"))))))))))
(DFunDef false "importMemberShadow" ((PVar "graph") (PVar "rows") (PVar "nameable") (PVar "universe") (PVar "depDecls") (PCon "UseMember" (PVar "origin") PWild (PVar "mloc") (PVar "alias"))) (EBlock (DoLet false false (PVar "local") (EMatch (EVar "alias") (arm (PCon "Some" (PVar "a")) () (EVar "a")) (arm (PCon "None") () (EVar "origin")))) (DoExpr (EIf (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "local")) (EVar "nameable"))) (EListLit) (EMatch (EApp (EApp (EApp (EApp (EVar "reachableStandaloneSig") (EVar "graph")) (EApp (EVar "listLen") (EVar "graph"))) (EVar "depDecls")) (EVar "origin")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "sty")) () (EMatch (EApp (EApp (EApp (EApp (EVar "ifaceMethodSigFor") (EVar "local")) (EVar "sty")) (EVar "rows")) (EVar "universe")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple (PVar "iface") (PVar "mty"))) () (EListLit (ETuple (EVar "local") (EVar "iface") (EVar "sty") (EVar "mty") (EVar "mloc")))))))))))
(DTypeSig false "schemesAgree" (TyFun (TyApp (TyCon "Option") (TyCon "Ty")) (TyFun (TyCon "Ty") (TyCon "Bool"))))
(DFunDef false "schemesAgree" ((PCon "None") PWild) (EVar "False"))
(DFunDef false "schemesAgree" ((PCon "Some" (PVar "sty")) (PVar "mty")) (EApp (EApp (EVar "tyAlphaEq") (EVar "sty")) (EVar "mty")))
(DTypeSig false "ifaceMethodSigFor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Ty"))))))))
(DFunDef false "ifaceMethodSigFor" (PWild PWild (PList) PWild) (EVar "None"))
(DFunDef false "ifaceMethodSigFor" ((PVar "name") (PVar "sty") (PCons (PTuple (PVar "iface") (PVar "ms")) (PVar "rest")) (PVar "universe")) (EBlock (DoLet false false (PVar "later") (EApp (EApp (EApp (EApp (EVar "ifaceMethodSigFor") (EVar "name")) (EVar "sty")) (EVar "rest")) (EVar "universe"))) (DoExpr (EIf (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "name")) (EVar "ms"))) (EVar "later") (EMatch (EApp (EApp (EApp (EVar "ifaceMethodTyIn") (EVar "iface")) (EVar "name")) (EVar "universe")) (arm (PCon "Some" (PVar "ty")) () (EIf (EApp (EApp (EVar "schemesAgree") (EVar "sty")) (EVar "ty")) (EVar "later") (EApp (EApp (EVar "leastIfaceSig") (ETuple (EVar "iface") (EVar "ty"))) (EVar "later")))) (arm (PCon "None") () (EVar "later")))))))
(DTypeSig false "leastIfaceSig" (TyFun (TyTuple (TyCon "String") (TyCon "Ty")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Ty"))))))
(DFunDef false "leastIfaceSig" ((PVar "a") (PCon "None")) (EApp (EVar "Some") (EVar "a")))
(DFunDef false "leastIfaceSig" ((PAs "a" (PTuple (PVar "ia") (PVar "ta"))) (PCon "Some" (PAs "b" (PTuple (PVar "ib") (PVar "tb"))))) (EIf (EBinOp "<" (EVar "ia") (EVar "ib")) (EApp (EVar "Some") (EVar "a")) (EIf (EBinOp "<" (EVar "ib") (EVar "ia")) (EApp (EVar "Some") (EVar "b")) (EIf (EBinOp "<=" (EApp (EVar "ppTy") (EVar "ta")) (EApp (EVar "ppTy") (EVar "tb"))) (EApp (EVar "Some") (EVar "a")) (EIf (EVar "otherwise") (EApp (EVar "Some") (EVar "b")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "ifaceMethodTyIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Ty"))))))
(DFunDef false "ifaceMethodTyIn" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "ifaceMethodTyIn" ((PVar "iface") (PVar "name") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EApp (EVar "ifaceMethodTyIn") (EVar "iface")) (EVar "name")) (EListLit (EVar "d")))) (DoExpr (EMatch (EVar "inner") (arm (PCon "Some" (PVar "ty")) () (EApp (EVar "Some") (EVar "ty"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "ifaceMethodTyIn") (EVar "iface")) (EVar "name")) (EVar "rest")))))))
(DFunDef false "ifaceMethodTyIn" ((PVar "iface") (PVar "name") (PCons (PRec "DInterface" ((rf "name" (PVar "n")) (rf "methods" None)) true) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n") (EVar "iface")) (EMatch (EApp (EApp (EVar "ifaceMethodTyOf") (EVar "name")) (EVar "methods")) (arm (PCon "Some" (PVar "ty")) () (EApp (EVar "Some") (EVar "ty"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "ifaceMethodTyIn") (EVar "iface")) (EVar "name")) (EVar "rest")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "ifaceMethodTyIn") (EVar "iface")) (EVar "name")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "ifaceMethodTyIn" ((PVar "iface") (PVar "name") (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EVar "ifaceMethodTyIn") (EVar "iface")) (EVar "name")) (EVar "rest")))
(DTypeSig false "ifaceMethodTyOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "Option") (TyCon "Ty")))))
(DFunDef false "ifaceMethodTyOf" (PWild (PList)) (EVar "None"))
(DFunDef false "ifaceMethodTyOf" ((PVar "name") (PCons (PCon "IfaceMethod" (PVar "n") (PVar "ty") PWild PWild) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EVar "Some") (EVar "ty")) (EIf (EVar "otherwise") (EApp (EApp (EVar "ifaceMethodTyOf") (EVar "name")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reachableStandaloneSig" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "Option") (TyCon "Ty"))))))))
(DFunDef false "reachableStandaloneSig" ((PVar "graph") (PVar "fuel") (PVar "decls") (PVar "name")) (EIf (EApp (EApp (EVar "declaresStandalone") (EVar "name")) (EVar "decls")) (EApp (EVar "Some") (EApp (EApp (EVar "standaloneSigOf") (EVar "name")) (EVar "decls"))) (EIf (EBinOp "<=" (EVar "fuel") (ELit (LInt 0))) (EVar "None") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "reachableStandaloneSigGo") (EVar "graph")) (EBinOp "-" (EVar "fuel") (ELit (LInt 1)))) (EApp (EApp (EVar "reexportedOrigins") (EVar "decls")) (EVar "name"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "reachableStandaloneSigGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "Option") (TyApp (TyCon "Option") (TyCon "Ty")))))))
(DFunDef false "reachableStandaloneSigGo" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "reachableStandaloneSigGo" ((PVar "graph") (PVar "fuel") (PCons (PTuple (PVar "mid") (PVar "n")) (PVar "rest"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "mid")) (EVar "graph")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "reachableStandaloneSigGo") (EVar "graph")) (EVar "fuel")) (EVar "rest"))) (arm (PCon "Some" (PVar "ds")) () (EMatch (EApp (EApp (EApp (EApp (EVar "reachableStandaloneSig") (EVar "graph")) (EVar "fuel")) (EVar "ds")) (EVar "n")) (arm (PCon "Some" (PVar "sig")) () (EApp (EVar "Some") (EVar "sig"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "reachableStandaloneSigGo") (EVar "graph")) (EVar "fuel")) (EVar "rest")))))))
(DTypeSig false "reexportedOrigins" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reexportedOrigins" ((PVar "decls") (PVar "name")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "d")) (EApp (EApp (EVar "reexportedOriginsOf") (EVar "d")) (EVar "name")))) (EVar "decls")))
(DTypeSig false "reexportedOriginsOf" (TyFun (TyCon "Decl") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reexportedOriginsOf" ((PCon "DAttrib" PWild (PVar "d")) (PVar "name")) (EApp (EApp (EVar "reexportedOriginsOf") (EVar "d")) (EVar "name")))
(DFunDef false "reexportedOriginsOf" ((PCon "DUse" (PCon "True") (PVar "path") PWild) (PVar "name")) (EMatch (EApp (EVar "importedBindings") (EVar "path")) (arm (PCon "None") () (EListLit (ETuple (EApp (EVar "useModId") (EVar "path")) (EVar "name")))) (arm (PCon "Some" (PVar "bs")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "b")) (ETuple (EApp (EVar "useModId") (EVar "path")) (EApp (EVar "fst") (EVar "b"))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EBinOp "==" (EApp (EVar "snd") (EVar "b")) (EVar "name")))) (EVar "bs"))))))
(DFunDef false "reexportedOriginsOf" (PWild PWild) (EListLit))
(DTypeSig false "declaresStandalone" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool"))))
(DFunDef false "declaresStandalone" (PWild (PList)) (EVar "False"))
(DFunDef false "declaresStandalone" ((PVar "n") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "||" (EApp (EApp (EVar "declaresStandalone") (EVar "n")) (EListLit (EVar "d"))) (EApp (EApp (EVar "declaresStandalone") (EVar "n")) (EVar "rest"))))
(DFunDef false "declaresStandalone" ((PVar "n") (PCons (PCon "DFunDef" PWild (PVar "m") PWild PWild PWild PWild) (PVar "rest"))) (EBinOp "||" (EBinOp "==" (EVar "m") (EVar "n")) (EApp (EApp (EVar "declaresStandalone") (EVar "n")) (EVar "rest"))))
(DFunDef false "declaresStandalone" ((PVar "n") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "declaresStandalone") (EVar "n")) (EVar "rest")))
(DTypeSig false "standaloneSigOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Ty")))))
(DFunDef false "standaloneSigOf" (PWild (PList)) (EVar "None"))
(DFunDef false "standaloneSigOf" ((PVar "n") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EMatch (EApp (EApp (EVar "standaloneSigOf") (EVar "n")) (EListLit (EVar "d"))) (arm (PCon "Some" (PVar "t")) () (EApp (EVar "Some") (EVar "t"))) (arm (PCon "None") () (EApp (EApp (EVar "standaloneSigOf") (EVar "n")) (EVar "rest")))))
(DFunDef false "standaloneSigOf" ((PVar "n") (PCons (PCon "DTypeSig" PWild (PVar "m") (PVar "ty") PWild) (PVar "rest"))) (EIf (EBinOp "==" (EVar "m") (EVar "n")) (EApp (EVar "Some") (EVar "ty")) (EIf (EVar "otherwise") (EApp (EApp (EVar "standaloneSigOf") (EVar "n")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "standaloneSigOf" ((PVar "n") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "standaloneSigOf") (EVar "n")) (EVar "rest")))
(DTypeSig false "tyAlphaEq" (TyFun (TyCon "Ty") (TyFun (TyCon "Ty") (TyCon "Bool"))))
(DFunDef false "tyAlphaEq" ((PVar "a") (PVar "b")) (EMatch (EApp (EApp (EApp (EVar "tyAlphaGo") (EListLit)) (EVar "a")) (EVar "b")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "tyAlphaGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "Ty") (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "tyAlphaGo" ((PVar "m") (PCon "TyVar" (PVar "x")) (PCon "TyVar" (PVar "y"))) (EApp (EApp (EApp (EVar "bindTyName") (EVar "m")) (EVar "x")) (EVar "y")))
(DFunDef false "tyAlphaGo" ((PVar "m") (PRec "TyCon" ((rf "tyConName" (PVar "x"))) false) (PRec "TyCon" ((rf "tyConName" (PVar "y"))) false)) (EIf (EBinOp "==" (EVar "x") (EVar "y")) (EApp (EVar "Some") (EVar "m")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "tyAlphaGo" ((PVar "m") (PCon "TyApp" (PVar "f") (PVar "x")) (PCon "TyApp" (PVar "g") (PVar "y"))) (EMatch (EApp (EApp (EApp (EVar "tyAlphaGo") (EVar "m")) (EVar "f")) (EVar "g")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "m2")) () (EApp (EApp (EApp (EVar "tyAlphaGo") (EVar "m2")) (EVar "x")) (EVar "y")))))
(DFunDef false "tyAlphaGo" ((PVar "m") (PCon "TyFun" (PVar "a") (PVar "b")) (PCon "TyFun" (PVar "c") (PVar "d"))) (EMatch (EApp (EApp (EApp (EVar "tyAlphaGo") (EVar "m")) (EVar "a")) (EVar "c")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "m2")) () (EApp (EApp (EApp (EVar "tyAlphaGo") (EVar "m2")) (EVar "b")) (EVar "d")))))
(DFunDef false "tyAlphaGo" ((PVar "m") (PCon "TyTuple" (PVar "xs")) (PCon "TyTuple" (PVar "ys"))) (EApp (EApp (EApp (EVar "tyAlphaList") (EVar "m")) (EVar "xs")) (EVar "ys")))
(DFunDef false "tyAlphaGo" ((PVar "m") (PCon "TyEffect" (PVar "e1") (PVar "t1") (PVar "a")) (PCon "TyEffect" (PVar "e2") (PVar "t2") (PVar "b"))) (EIf (EBinOp "&&" (EApp (EApp (EVar "sameWrittenAtoms") (EVar "e1")) (EVar "e2")) (EBinOp "==" (EVar "t1") (EVar "t2"))) (EApp (EApp (EApp (EVar "tyAlphaGo") (EVar "m")) (EVar "a")) (EVar "b")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "tyAlphaGo" ((PVar "m") (PCon "TyConstrained" (PVar "c1") (PVar "a")) (PCon "TyConstrained" (PVar "c2") (PVar "b"))) (EIf (EBinOp "/=" (EApp (EVar "listLen") (EVar "c1")) (EApp (EVar "listLen") (EVar "c2"))) (EVar "None") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "tyAlphaGo") (EVar "m")) (EVar "a")) (EVar "b")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "m2")) () (EApp (EApp (EApp (EVar "tyAlphaConstraints") (EVar "m2")) (EVar "c1")) (EVar "c2")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "tyAlphaGo" ((PVar "m") (PCon "TyRow" (PVar "e1") (PVar "t1") PWild) (PCon "TyRow" (PVar "e2") (PVar "t2") PWild)) (EIf (EBinOp "&&" (EApp (EApp (EVar "sameWrittenAtoms") (EVar "e1")) (EVar "e2")) (EBinOp "==" (EVar "t1") (EVar "t2"))) (EApp (EVar "Some") (EVar "m")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "tyAlphaGo" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "sameWrittenAtoms" (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyCon "Bool"))))
(DFunDef false "sameWrittenAtoms" ((PVar "e1") (PVar "e2")) (EBinOp "==" (EApp (EApp (EMethodRef "map") (EApp (EVar "effAtomSurface") (EVar "escStr"))) (EVar "e1")) (EApp (EApp (EMethodRef "map") (EApp (EVar "effAtomSurface") (EVar "escStr"))) (EVar "e2"))))
(DTypeSig false "tyAlphaList" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "tyAlphaList" ((PVar "m") (PList) (PList)) (EApp (EVar "Some") (EVar "m")))
(DFunDef false "tyAlphaList" ((PVar "m") (PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EMatch (EApp (EApp (EApp (EVar "tyAlphaGo") (EVar "m")) (EVar "x")) (EVar "y")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "m2")) () (EApp (EApp (EApp (EVar "tyAlphaList") (EVar "m2")) (EVar "xs")) (EVar "ys")))))
(DFunDef false "tyAlphaList" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "tyAlphaConstraints" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Constraint")) (TyFun (TyApp (TyCon "List") (TyCon "Constraint")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "tyAlphaConstraints" ((PVar "m") (PList) PWild) (EApp (EVar "Some") (EVar "m")))
(DFunDef false "tyAlphaConstraints" ((PVar "m") (PCons (PVar "c") (PVar "rest")) (PVar "cs2")) (EMatch (EApp (EApp (EApp (EApp (EVar "takeAlphaConstraint") (EVar "m")) (EVar "c")) (EVar "cs2")) (EListLit)) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple (PVar "m2") (PVar "left"))) () (EApp (EApp (EApp (EVar "tyAlphaConstraints") (EVar "m2")) (EVar "rest")) (EVar "left")))))
(DTypeSig false "takeAlphaConstraint" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "Constraint") (TyFun (TyApp (TyCon "List") (TyCon "Constraint")) (TyFun (TyApp (TyCon "List") (TyCon "Constraint")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "Constraint")))))))))
(DFunDef false "takeAlphaConstraint" (PWild PWild (PList) PWild) (EVar "None"))
(DFunDef false "takeAlphaConstraint" ((PVar "m") (PVar "c") (PCons (PVar "d") (PVar "rest")) (PVar "tried")) (EMatch (EApp (EApp (EApp (EVar "tyAlphaConstraint") (EVar "m")) (EVar "c")) (EVar "d")) (arm (PCon "Some" (PVar "m2")) () (EApp (EVar "Some") (ETuple (EVar "m2") (EBinOp "++" (EVar "tried") (EVar "rest"))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "takeAlphaConstraint") (EVar "m")) (EVar "c")) (EVar "rest")) (EBinOp "::" (EVar "d") (EVar "tried"))))))
(DTypeSig false "tyAlphaConstraint" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "Constraint") (TyFun (TyCon "Constraint") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "tyAlphaConstraint" ((PVar "m") (PRec "Constraint" ((rf "constraintHead" (PVar "h1")) (rf "constraintArgs" (PVar "as1"))) true) (PRec "Constraint" ((rf "constraintHead" (PVar "h2")) (rf "constraintArgs" (PVar "as2"))) true)) (EIf (EBinOp "==" (EVar "h1") (EVar "h2")) (EApp (EApp (EApp (EVar "tyAlphaList") (EVar "m")) (EVar "as1")) (EVar "as2")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "bindTyName" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "bindTyName" ((PVar "m") (PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "x")) (EVar "m")) (arm (PCon "Some" (PVar "y2")) () (EIf (EBinOp "==" (EVar "y2") (EVar "y")) (EApp (EVar "Some") (EVar "m")) (EVar "None"))) (arm (PCon "None") () (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "e")) (EBinOp "==" (EApp (EVar "snd") (EVar "e")) (EVar "y")))) (EVar "m")) (EVar "None") (EApp (EVar "Some") (EBinOp "::" (ETuple (EVar "x") (EVar "y")) (EVar "m")))))))
(DTypeSig true "computeMangledShadowMap" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "computeMangledShadowMap" ((PVar "allDecls") (PVar "units")) (EBlock (DoLet false false (PVar "methodNames") (EApp (EVar "dedup") (EApp (EVar "allIfaceMethodNames") (EVar "allDecls")))) (DoExpr (EApp (EApp (EDictApp "flatMap") (EApp (EVar "unitMangledShadows") (EVar "methodNames"))) (EVar "units")))))
(DTypeSig false "unitMangledShadows" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "unitMangledShadows" ((PVar "methodNames") (PTuple (PVar "mid") (PVar "decls"))) (EBlock (DoLet false false (PVar "fns") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "funDefs") (EVar "decls")))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "m")) (EBlock (DoLet false false (PVar "sym") (EApp (EApp (EVar "mangledName") (EVar "mid")) (EVar "m"))) (DoExpr (EIf (EApp (EApp (EVar "omHasKey") (EVar "sym")) (EVar "fns")) (EListLit (ETuple (EVar "sym") (EVar "m"))) (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "isPreludeMid") (EVar "mid"))) (EApp (EApp (EVar "omHasKey") (EVar "m")) (EVar "fns"))) (EListLit (ETuple (EVar "m") (EVar "m"))) (EListLit))))))) (EVar "methodNames")))))
(DTypeSig true "buildStandaloneShadowsGraph" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "buildStandaloneShadowsGraph" ((PVar "sm") (PVar "allDecls") (PVar "userDecls")) (EBlock (DoLet false false (PVar "methodNames") (EApp (EApp (EVar "omFromNames") (EApp (EVar "allIfaceMethodNames") (EVar "allDecls"))) (EVar "omEmpty"))) (DoLet false false (PVar "fns") (EApp (EVar "dedup") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "funDefs") (EVar "userDecls"))))) (DoLet false false (PVar "direct") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "methodNames")))) (EVar "fns"))) (DoLet false false (PVar "mangled") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "n")) (EApp (EVar "isSome") (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "sm"))))) (EVar "fns"))) (DoExpr (EApp (EVar "dedup") (EBinOp "++" (EVar "direct") (EVar "mangled"))))))
(DTypeSig true "coreShadowMapFor" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "coreShadowMapFor" ((PVar "gctx") (PVar "coreProg") (PVar "shadowMap")) (EIf (EBinOp "==" (EApp (EVar "omSize") (EApp (EApp (EVar "ifaceExportsIndex") (EVar "gctx")) (ELit LUnit))) (ELit (LInt 0))) (EVar "shadowMap") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "nameable") (EApp (EApp (EVar "nameableIfaceMethodSet") (EVar "gctx")) (EVar "coreProg"))) (DoLet false false (PVar "sc") (EApp (EApp (EVar "spellCtxOf") (EVar "gctx")) (EVar "coreProg"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EBinOp "&&" (EApp (EApp (EVar "omHasKey") (EApp (EVar "snd") (EVar "e"))) (EVar "nameable")) (EApp (EApp (EApp (EVar "moduleSpellsShadowBare") (EVar "sc")) (EApp (EVar "fst") (EVar "e"))) (EApp (EVar "snd") (EVar "e")))))) (EVar "shadowMap")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "shadowSymSpelledBare" (TyFun (TyCon "SpellCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "shadowSymSpelledBare" ((PVar "sc") (PVar "sm") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "sm")) (arm (PCon "None") () (EVar "True")) (arm (PCon "Some" (PVar "bare")) () (EApp (EApp (EApp (EVar "moduleSpellsShadowBare") (EVar "sc")) (EVar "n")) (EVar "bare")))))
(DTypeSig false "spellCtxOf" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "SpellCtx"))))
(DFunDef false "spellCtxOf" ((PVar "gctx") (PVar "prog")) (ERecordCreate "SpellCtx" ((fa "scTopFns" (EApp (EVar "declTopFnNames") (EVar "prog"))) (fa "scBare" (EApp (EApp (EApp (EVar "declBareLocals") (EVar "gctx")) (EVar "prog")) (ERecordCreate "BareLocals" ((fa "blAll" (EVar "False")) (fa "blSet" (EListLit)))))) (fa "scCorePfx" (EApp (EApp (EVar "mangledName") (ELit (LString "core"))) (ELit (LString "")))))))
(DTypeSig true "moduleSpellsShadowBare" (TyFun (TyCon "SpellCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "moduleSpellsShadowBare" ((PVar "sc") (PVar "sym") (PVar "bare")) (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "sym")) (EFieldAccess (EVar "sc") "scTopFns")) (EBinOp "&&" (EApp (EApp (EVar "startsWith") (EFieldAccess (EVar "sc") "scCorePfx")) (EVar "sym")) (EBinOp "==" (EVar "sym") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "sc") "scCorePfx"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "bare"))) (ELit (LString "")))))) (EApp (EApp (EVar "bareLocalBound") (EFieldAccess (EVar "sc") "scBare")) (EVar "bare"))))
(DTypeSig false "bareLocalBound" (TyFun (TyCon "BareLocals") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "bareLocalBound" ((PVar "bl") (PVar "bare")) (EBinOp "||" (EFieldAccess (EVar "bl") "blAll") (EApp (EApp (EVar "contains") (EVar "bare")) (EFieldAccess (EVar "bl") "blSet"))))
(DTypeSig false "declBareLocals" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "BareLocals") (TyCon "BareLocals")))))
(DFunDef false "declBareLocals" ((PVar "gctx") (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "declBareLocals" ((PVar "gctx") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "declBareLocals") (EVar "gctx")) (EVar "rest")) (EApp (EApp (EApp (EVar "declBareLocals") (EVar "gctx")) (EListLit (EVar "d"))) (EVar "acc"))))
(DFunDef false "declBareLocals" ((PVar "gctx") (PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "declBareLocals") (EVar "gctx")) (EVar "rest")) (EApp (EApp (EApp (EVar "formBareLocals") (EVar "gctx")) (EVar "path")) (EVar "acc"))))
(DFunDef false "declBareLocals" ((PVar "gctx") (PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "declBareLocals") (EVar "gctx")) (EVar "rest")) (EVar "acc")))
(DTypeSig false "formBareLocals" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "UsePath") (TyFun (TyCon "BareLocals") (TyCon "BareLocals")))))
(DFunDef false "formBareLocals" ((PVar "gctx") (PVar "path") (PVar "acc")) (EBlock (DoLet false false (PVar "depId") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EMatch (EApp (EVar "importedBindings") (EVar "path")) (arm (PCon "None") () (EIf (EApp (EApp (EVar "depExportsUnknown") (EVar "gctx")) (EVar "depId")) (ERecordUpdate (EVar "acc") ((fa "blAll" (EVar "True")))) (ERecordUpdate (EVar "acc") ((fa "blSet" (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EVar "graphPubDefiners") (EVar "gctx")) (EVar "depId"))) (EFieldAccess (EVar "acc") "blSet"))))))) (arm (PCon "Some" (PVar "bindings")) () (ERecordUpdate (EVar "acc") ((fa "blSet" (EBinOp "++" (EApp (EApp (EVar "filterList") (ELam ((PVar "l")) (EApp (EApp (EApp (EVar "depExportsStandalone") (EVar "gctx")) (EVar "depId")) (EVar "l")))) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "bindings"))) (EFieldAccess (EVar "acc") "blSet"))))))))))
(DTypeSig true "shadowBareName" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "shadowBareName" ((PVar "sm") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "sm")) (arm (PCon "Some" (PVar "bare")) () (EVar "bare")) (arm (PCon "None") () (EVar "n"))))
(DTypeSig true "methodMarkCtx" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "MarkSets") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "MarkCtx"))))))
(DFunDef false "methodMarkCtx" ((PVar "gctx") (PVar "ms") (PLit (LString "")) (PVar "coreProg")) (EIf (EBinOp "==" (EApp (EVar "omSize") (EApp (EApp (EVar "ifaceExportsIndex") (EVar "gctx")) (ELit LUnit))) (ELit (LInt 0))) (ERecordCreate "MarkCtx" ((fa "mcRp" (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "ms") "msMarkRpNames")) (EVar "omEmpty"))) (fa "mcAn" (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "ms") "msArgNames")) (EVar "omEmpty"))) (fa "mcSm" (EFieldAccess (EVar "ms") "msCoreShadowMap")))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "nameable") (EApp (EApp (EVar "nameableIfaceMethodSet") (EVar "gctx")) (EVar "coreProg"))) (DoLet false false (PVar "keep") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "nameable")))) (DoExpr (ERecordCreate "MarkCtx" ((fa "mcRp" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "filterList") (EVar "keep")) (EFieldAccess (EVar "ms") "msMarkRpNames"))) (EVar "omEmpty"))) (fa "mcAn" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "filterList") (EVar "keep")) (EFieldAccess (EVar "ms") "msArgNames"))) (EVar "omEmpty"))) (fa "mcSm" (EFieldAccess (EVar "ms") "msCoreShadowMap")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "methodMarkCtx" ((PVar "gctx") (PVar "ms") PWild (PVar "prog")) (EIf (EBinOp "==" (EApp (EVar "omSize") (EApp (EApp (EVar "ifaceExportsIndex") (EVar "gctx")) (ELit LUnit))) (ELit (LInt 0))) (EBlock (DoLet false false (PVar "aliasRows") (EApp (EApp (EVar "aliasMethodSpellings") (EVar "gctx")) (EVar "prog"))) (DoExpr (ERecordCreate "MarkCtx" ((fa "mcRp" (EApp (EApp (EVar "withAliasMethodNames") (EVar "aliasRows")) (EApp (EApp (EVar "omFromNames") (EApp (EVar "dedup") (EBinOp "++" (EFieldAccess (EVar "ms") "msMarkSharedNames") (EFieldAccess (EVar "ms") "msGraphShadowNames")))) (EVar "omEmpty")))) (fa "mcAn" (EApp (EApp (EVar "withAliasMethodNames") (EVar "aliasRows")) (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "ms") "msArgNames")) (EVar "omEmpty")))) (fa "mcSm" (EFieldAccess (EFieldAccess (EVar "gctx") "mangledShadowMapRef") "value")))))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "nameable") (EApp (EApp (EVar "nameableIfaceMethodSet") (EVar "gctx")) (EVar "prog"))) (DoLet false false (PVar "keep") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "nameable")))) (DoLet false false (PVar "shadowMap") (EFieldAccess (EFieldAccess (EVar "gctx") "mangledShadowMapRef") "value")) (DoLet false false (PVar "sc") (EApp (EApp (EVar "spellCtxOf") (EVar "gctx")) (EVar "prog"))) (DoLet false false (PVar "aliasRows") (EApp (EApp (EVar "aliasMethodSpellings") (EVar "gctx")) (EVar "prog"))) (DoExpr (ERecordCreate "MarkCtx" ((fa "mcRp" (EApp (EApp (EVar "withAliasMethodNames") (EVar "aliasRows")) (EApp (EApp (EVar "omFromNames") (EApp (EVar "dedup") (EBinOp "++" (EApp (EApp (EVar "filterList") (EVar "keep")) (EFieldAccess (EVar "ms") "msMarkSharedNames")) (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EBinOp "&&" (EApp (EApp (EVar "omHasKey") (EApp (EApp (EVar "shadowBareName") (EVar "shadowMap")) (EVar "n"))) (EVar "nameable")) (EApp (EApp (EApp (EVar "shadowSymSpelledBare") (EVar "sc")) (EVar "shadowMap")) (EVar "n"))))) (EFieldAccess (EVar "ms") "msGraphShadowNames"))))) (EVar "omEmpty")))) (fa "mcAn" (EApp (EApp (EVar "withAliasMethodNames") (EVar "aliasRows")) (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "filterList") (EVar "keep")) (EFieldAccess (EVar "ms") "msArgNames"))) (EVar "omEmpty")))) (fa "mcSm" (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EBinOp "&&" (EApp (EApp (EVar "omHasKey") (EApp (EVar "snd") (EVar "e"))) (EVar "nameable")) (EApp (EApp (EApp (EVar "moduleSpellsShadowBare") (EVar "sc")) (EApp (EVar "fst") (EVar "e"))) (EApp (EVar "snd") (EVar "e")))))) (EVar "shadowMap"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "moduleMarkCtx" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "MarkSets") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Scheme")) (TyCon "MarkCtx")))))))
(DFunDef false "moduleMarkCtx" ((PVar "gctx") (PVar "ms") (PVar "mid") (PVar "prog") (PVar "imported")) (EBlock (DoLet false false (PVar "candidates") (EApp (EApp (EApp (EApp (EVar "methodMarkCtx") (EVar "gctx")) (EVar "ms")) (EVar "mid")) (EVar "prog"))) (DoLet false false (PVar "local") (EApp (EApp (EVar "namesToSet") (EApp (EVar "declTopFnNames") (EVar "prog"))) (EVar "omEmpty"))) (DoLet false false (PVar "externs") (EApp (EApp (EVar "namesToSet") (EApp (EVar "declExternNames") (EVar "prog"))) (EVar "omEmpty"))) (DoExpr (ERecordCreate "MarkCtx" ((fa "mcRp" (EApp (EApp (EVar "IdMap.difference") (EFieldAccess (EVar "candidates") "mcRp")) (EVar "externs"))) (fa "mcAn" (EApp (EApp (EVar "IdMap.difference") (EFieldAccess (EVar "candidates") "mcAn")) (EVar "externs"))) (fa "mcSm" (EApp (EApp (EVar "filterList") (ELam ((PVar "entry")) (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EVar "entry"))) (EVar "local")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "snd") (EVar "entry"))) (EVar "imported"))))) (EFieldAccess (EVar "candidates") "mcSm"))))))))
