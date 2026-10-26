# META
source_lines=1245
stages=DESUGAR,MARK
# SOURCE
-- tc_state: mints, copies and carries of the state records (including `emptyShadowDicts` and the
-- span carries `sameSpan`, `mctxAt`, `dynAt`, `envAt` with their `IfSome` forms), the process
-- interners cell, the `Windowed` channel ops, and the test-only trace-sink probes that only build
-- or read a `TraceSink` or the graph-run evidence cells (`beginAssumptionTrace`,
-- `beginNumericPredicateTrace`, `beginMethodReturnTrace`, `beginEvidenceObservation`,
-- `evCellsSpanProbe` and their `finish` forms).
--
-- Spec: TYPECHECK-CONTRACTS section 5; CELL-LIFETIMES.md.
--
-- Placement: declarations are placed by R1-R6 of the Phase 4 module table,
-- compiler/ARCHITECTURE-PLAYBOOK.md section 6.
-- Closure rule: this module may not import `types.typecheck`, nor any of `tc_env`, `tc_diag`,
-- `tc_scope`, `tc_unify`, `tc_decls_variance`, `tc_decls_types`, `tc_decls`, `tc_foreign`,
-- `tc_solve_givens`, `tc_solve_entail`, `tc_solve`, `tc_solve_check`, `tc_shadow`, `tc_effects`,
-- `tc_occurrence`, `tc_groups`, `tc_pat`, `tc_infer_records`, `tc_infer`, `tc_elab`, `tc_global`,
-- `tc_module`.

import types.tc_mono.{locEq, monoScheme, tconBuiltin}
import frontend.ast.{Decl(..), Loc(..), TyConOrigin(..), defaultReceiverDict}
import types.repr.{IfaceRef(..), Scheme(..)}
import types.effect_solver as EffectSolver
import types.tc_types.{
  AbsorptionEvent(..),
  AssumptionTraceEntry(..),
  BuiltinClasses(..),
  CheckRunSeed(..),
  ClassEnv(..),
  CrossRun(..),
  DataEnv(..),
  DeclEnvs(..),
  DeclEnvSeedAcc(..),
  DriveInputs(..),
  DynCtx(..),
  EvidenceObservationEntry(..),
  GrantState(..),
  GraphCtx(..),
  GraphRun(..),
  ImplEnv(..),
  ImplUniverse(..),
  Interners(..),
  InvocationView(..),
  Lineage(..),
  LocalAbsState(..),
  MethodEnv(..),
  ModuleCells(..),
  ModuleCtx(..),
  NumericPredicateTraceEntry(..),
  Predicate(..),
  ShadowDicts(..),
  SigVars(..),
  TcConfig(..),
  TcEnv(..),
  TraceSink(..),
  UObligation(..),
  Windowed(..),
}
import map.{Map(..)}
import types.evidence.{EvidenceBinderId(..), ScopeId(..)}
import types.scopes.{
  DefaultBodyIdentity(..), ScopeCursor(..), ScopeOwner(..), ScopeStore
}
import types.scopes as Scopes
import types.solver_contract.{Instantiation(..)}
import types.registry.{regEmpty}
import frontend.exhaust.{buildOracle, Oracle}
import support.ordmap.{omEmpty, omInsert, OrdMap}
import support.util.{reverseL}
import types.registry.{mregEmpty, regEmpty, spEmpty, spFromFloor}
import types.disposition.{MethodDisposition(..)}
import types.runtime_types.{emptyBinderTypes}

-- Bug C: importer-shadow method names → their IMPORTED STANDALONE scheme (e.g.
-- `eval/eval.mdk`'s imported `add` → `U64 -> U64 -> U64`, which `Num.add` shadows).
-- env1 rebinds these names to the polymorphic
-- INTERFACE-METHOD scheme (so a genuine method call types polymorphically), which
-- loses the standalone's concrete argument and result types — typing `add x y : a`
-- (a free) instead of `U64`, so a downstream `debug` dispatches on the
-- ungrounded type and renders garbage.  inferAppExpr's standalone-shadow arm reads
-- THIS to recover the standalone result type when the receiver has no impl.
-- Populated per module
-- in checkModuleFullImpl from seedVars (the import seed, pre-rebind).

-- Bug C: the impl key table for the CURRENT module's full impl universe, stashed at
-- module start so inferAppExpr's standalone-shadow arm can ask, DURING inference,
-- whether a concrete receiver head has an impl of the method's interface (the static
-- analogue of resolveRLocalSite's post-inference check, but needed eagerly so the
-- call's RESULT type unifies against the standalone — not the method scheme — before
-- a downstream `debug` dispatches on it).  Set in checkModuleFullImpl from implDecls.

-- Persistent per-run universe accumulators for the multi-module path. The
-- four core accumulators grow ONE module at a time, appended in
-- checkBodyImpl's Module arm and consumed by MEMBERSHIP/EXISTENCE/by-unique-
-- key LOOKUP readers only, so appending a module's contribution is
-- byte-identical to rebuilding over the full universe. They survive
-- per-module `freshModuleCtx`, are cleared per RUN by `mintGraphCtx`,
-- and are seeded by the core pass.
--   * interface-method names (buildDefinerShadows / buildStandaloneShadows): not an
--     accumulator; `methodNameDeclaredAt` reads `deMethods` at the reader's ordinal.
--   * top-level funDef name SET (buildStandaloneShadows' importedFns)
--     (Do not add an impl KEY-BUCKET accumulator beside this list: all three
--     boolean existence reads read the graph-global `bodyImplEnvRef` instead
--     (`ieImplExistsForHead`), and a cumulative topological PREFIX is the wrong
--     universe for that test -- see `docs/spec/SHADOW-SEMANTICS.md`'s
--     graph-global-vs-prefix distinction.)
--   * interface name -> REQUIRED-method names, read via checkImplCompletenessMap's
--     ceRequiredAt lookup on CE (typecheck.mdk:23989/6924). Interface names are
--     NOT globally unique across modules (only within one) -- the correction,
--     and the #1258 defect it fixed, are recorded at
--     compiler/TYPECHECK-TARGET-ARCHITECTURE.md:3499.
--   * interface-method NAME -> (iface name, iface typarams, declared method
--     Ty). Method names are NOT globally unique (two interfaces may each
--     declare the same method), so this one is not an accumulator: stage K's
--     `deMethods` holds every declaration and the reading module's scope
--     picks one per spelling (`methodScopeAt`).
--
-- The keyed impl universe for the obligation checkers
-- (checkImplObligations / checkCallObligations): three refs keyed for
-- O(1)/O(log N) lookup, grown ONE module at a time in
-- `appendUniverseAccums`, consumed by the keyed checkers (implMatchesU /
-- oblCallVerdict / findMatchingImplReqsU). Same
-- lifecycle as above. Head-tag alignment: `headTyconTy` (impl side) and
-- `headTyconMono` (goal side) agree on the head's SPELLING, not its origin —
-- see `dispHeadTab` for the measurement. The one deliberate non-identity:
-- `findMatchingImplReqsU` canonicalizes overlapping impls to the
-- MOST-SPECIFIC match (a soundness fix), not an order-invariant coherence
-- argument.
--   * concrete-head impls: keyed by (interface, receiver-head), each bucket
--     in forward declaration order
--   * headless-receiver impls (TyVar / function / empty receiver): keyed by
--     iface, match ANY receiver. Almost always empty (`impl Foo a` -- the
--     overlapping-impls / parse fixtures are the only corpus sources), but
--     MUST be kept: dropping them would change `implMatches` from True to
--     False on such a program.
--   * iface name -> SET of its impls' concrete head tags (headless, arrow-
--     and effect-headed impls excluded — this is the acceptance census, not
--     a dispatch table)
--
-- Persistent per-run DATA-universe accumulators for the multi-module path.
-- Five structures persist (recordByName / fieldOwners / dataParamKinds /
-- aliasTable / ctor ENV), seeded by the core pass, grown ONE module at a
-- time by `appendDataUniverse`. Module k sees published interfaces 1..k-1,
-- never its own twice. Copied into `freshModuleCtx`-wiped working refs and
-- OVERLAID with prog0. First-wins order preserved: accumulated
-- [pub_{k-1}..pub_1] + overlay prog0 -> [prog0, pub_{k-1}..pub_1], the same
-- order the old left fold yielded. Stored tyvar ids never leak (every
-- reader refreshes them); only the count shifts (registered once, not per
-- module), invisible via ppMono/ppScheme normalization. Survive per-module
-- `freshModuleCtx`; cleared per RUN by `mintGraphCtx`.
--
-- Constrained-receiver arm: the `=>`-constraint variables of the top-level
-- group currently being inferred, as (interface name, the constraint's
-- instantiated mono). Held in the group's `GroupCtx`, which processSCC mints
-- after preunifySigsEx and hands to inferMembers in the env's `DynCtx`. Read by
-- definerReceiverIsDictVar to dispatch a definer-shadow occurrence through the
-- dict rather than treat it as a standalone.

-- C5: method name → dispatch-arg index, built graph-wide from ALL interface decls
-- (so a PRELUDE method like Foldable's `toList` — absent from a user module's own
-- decls — still resolves its index during that module's check).  Set per module by
-- checkModuleFullImpl from [implDecls].  Independent of `methodEntryHere`.

-- #154 PR-B: PERSISTENT per-run dispatch-index accumulator for the multi-module path.
-- checkBodyImpl's Module arm used to `argDispatchIndices implDecls` (= `accAll ++ prog`) —
-- a flatMap over EVERY earlier module's decls once per module, an O(N²) rebuild on the
-- emit path (graphModuleWorker / elabModuleStamp).  The scan is pure and structural (no tyvars,
-- no side effects) and distributes over `++`, so the accumulator grown ONE module at a
-- time in `appendUniverseAccums` (BEFORE the Module arm copies it, so module k sees
-- interfaces 1..k INCLUDING its own — the same membership `accAll ++ prog` gave) holds
-- exactly what the per-module rebuild held.
--
-- ✅ #1351 L5 (CONTRACT): the accumulator this paragraph described is now the
-- IDENTITY-KEYED one, `universeMethodDispatchIdxByIdRef`, copied into
-- `methodDispatchIdxByIdRef`.  Its bare-name predecessor is DELETED, and with it the
-- whole hazard the rest of this comment used to carry: the pick between two same-named
-- methods' dispatch indices is no longer made by a first-wins `lookupAssoc` over
-- registration order, because the key now carries the declaring interface's identity
-- (`IfaceRef`, `irOrigin` included) and `dispatchIdxScoped` asks for ONE declaration —
-- the one `methodIfaceHere` says this module admits.  A prior module's entry that this
-- module cannot name is unreachable by construction rather than merely unqueried.
-- Survives per-module `freshModuleCtx`; cleared per
-- RUN by `mintGraphCtx`; seeded by the core pass (also Module mode).
-- C5: arg-position method occurrences whose name is a standalone-shadow, recorded
-- UNGATED (the ordinary arg-stamp machinery is emit-path-only, but eval also
-- arg-tag-dispatches and panics on a receiver with no impl — box's `toList b`).
-- Each entry is (name, route ref, the discriminating-argument mono CELL);
-- resolveRLocalSites reads the cell post-inference and stamps RLocal when the
-- receiver grounds to a head with no impl.
-- Reset by `freshModuleCtx`.
-- (name, routeRef, receiverMono, mangledSym, forceLocal) — mangledSym (P0-18) is the
-- mangled standalone symbol read off the marked route at record time; resolveRLocalSite
-- stamps `RLocal mangledSym` for a no-impl receiver.  "" on the un-mangled path.
-- P0-20: forceLocal — the definer-shadow APP path (inferDefinerShadowApp) has ALREADY
-- committed the site's TYPE to the standalone's scheme, so its route is not open to
-- re-derivation: post-inference the receiver can ground to a head that HAS an impl (Num
-- defaulting on an unsignatured standalone) and resolveRLocalSite would dispatch a site
-- typed as the standalone — check says one thing, the binary does another.  True pins
-- the route to RLocal.  recordRLocalSite (value position / importer shadows) pushes
-- False and keeps the old per-receiver re-derivation.
-- S-1: `dictMonos`/`dictIfaces` are the SHADOWING STANDALONE's own `=>`-constraint
-- slots (slot-parallel, expanded-supers, from shadowStandaloneDicts), carried here so
-- the stamp can turn them into dict Routes.  They are read INSIDE resolveRLocalSites
-- via routesOfMonosTop — a PURE function of the union-find-solved monos — rather than
-- pushed through pendingDictApps, because resolveRLocalSites runs BEFORE
-- resolveDictApps in elabModuleStamp: routing them through pendingDictApps would read
-- `[]` and reproduce the S-1 bug with more code.  This way the fix is ordering-immune
-- and the route has a single writer.  Empty for an unconstrained standalone.
-- #156 S3a: these fields now live in `PendingEntry`'s `SKRLocal` kind (mangledSym,
-- forceLocal, dictMonos, dictIfaces); the name/route/receiver-mono/enclosing-fn are
-- the shared PendingEntry fields.

-- INITIAL construction only, exactly as `initialGraphCtx` is: a driver that never
-- calls `buildDeclEnvs` reads an empty graph, on which every `declEnvsOrdOf`
-- misses.  See `declEnvsOrdOf` for why a miss is fail-CLOSED.
emptyDeclEnvs : DeclEnvs
emptyDeclEnvs = DeclEnvs {
  deModules = [],
  deOrdIndex = omEmpty,
  deDefiners = omEmpty,
  deAmbigValues = omEmpty,
  deAllDecls = [],
  deData = emptyDataEnv,
  deImpls = emptyImplEnv,
  deIfaces = emptyClassEnv,
  deMethods = emptyMethodEnv,
  deKindsBefore = omEmpty,
  deNameIndexBefore = omEmpty,
  dePolaritiesBefore = omEmpty,
  deAtomsBefore = omEmpty,
  deOwnersBefore = omEmpty,
  deOwnerModules = omEmpty,
  deReach = omEmpty,
}

-- The `""` seeds mirror `declEnvOrdIndex`'s: the core pass arrives under that
-- spelling and its seed is empty because nothing precedes ordinal 0.
export
emptyDeclEnvSeedAcc : DeclEnvSeedAcc
emptyDeclEnvSeedAcc = DeclEnvSeedAcc {
  dsKAcc = [],
  dsOAcc = omEmpty,
  dsNAcc = omEmpty,
  dsKinds = omInsert "" [] omEmpty,
  dsOwners = omInsert "" omEmpty omEmpty,
  dsNames = omInsert "" omEmpty omEmpty,
}

-- ── A-3.2a (#1112): the `DataEnv` slice ─────────────────────────────────────
-- This index is deliberately syntactic: an identity-keyed table over the raw
-- `Variant`/`Field`/`Ty` declaration nodes, carrying no elaborated
-- `Scheme`/`RecordInfo`/`Mono`. Elaborating (`registerAllData`,
-- `insertCtorPop`, `insertRecordPop`) writes `ModuleCtx`/`GraphCtx.crossRun` refs as
-- a side effect (`recordParamKinds`, `registerRecordInfoKeyed`, alias
-- resolution through `ModuleCells.mcCells.aliasTableRef`) and emits diagnostics
-- deduped per module (`ModuleCells.mcCells.typeErrorMsgSetRef`, reset by `freshModuleCtx`).
-- `buildDeclEnvs` runs in the driver preamble, before any module's own state
-- exists, so calling those functions here would merge the diagnostic dedupe
-- scope across the whole module graph and relocate the push outside any
-- module's harvest window — strictly fewer diagnostics on a program that is
-- rejected today, the loud-to-silent shape this repo's ladder counts as a
-- severity increase.
--
-- Visibility divergence: `buildDataEnv` folds every decl, private included,
-- so `deFieldOwnerIdents` is a superset of a visibility-filtered reader. The
-- field-owner seed is built from `declEnvRowVisible` over the per-module rows
-- instead, because `DataEnv` is ordinal-free and cannot answer a visibility
-- question — reading `deFieldOwnerIdents` unfiltered would let a private
-- record in an unrelated module vote in `resolveFieldByOwners`'s ambiguity
-- test.
--
-- Latent divergence, noted rather than fixed: `addCtorIdentRaw` (below)
-- upserts unconditionally, unlike `spInsert`'s upsert-by-identity.
-- `buildDataEnv` folds `deAllDecls` exactly once, so no producer re-presents
-- the same identity today — a future caller folding a decl list twice would
-- need the same guard.

export
emptyDataEnv : DataEnv
emptyDataEnv = DataEnv {
  deTypes = [],
  deCtorIdents = omEmpty,
  deRecordIdents = omEmpty,
  deFieldOwnerIdents = omEmpty,
  deAliases = [],
  deCtorExports = omEmpty,
}

export
emptyImplEnv : ImplEnv
emptyImplEnv = ImplEnv {
  ieRows = [],
  ieConcrete = mregEmpty,
  ieHeadless = mregEmpty,
  ieByHead = mregEmpty,
  ieUnivSnaps = [],
}

export
emptyClassEnv : ClassEnv
emptyClassEnv = ClassEnv { ceRows = [], ceByKey = regEmpty }

-- the blank line above is load-BEARING — do not close the gap.  Same trap
-- A-3.2a's own banner documents: a doctest's expected output runs to the end
-- of the contiguous comment run, so without this blank line the CE-BLOCK-END
-- banner is absorbed into the ungraded-kind doctest's expected value and it
-- FAILS with `expected == actual` plus the banner spliced in.  MEASURED on
-- this branch while writing this unit — not a borrowed warning.
-- ── #1519 A-3.3: CE-BLOCK-END ─────────────────────────────────────────────────

export
emptyMethodEnv : MethodEnv
emptyMethodEnv = MethodEnv {
  meByName = omEmpty,
  meExports = omEmpty,
  meIfaceExports = omEmpty,
}

-- The configuration before any drive has built one: no IO join, no profile, nothing
-- owned by the stdlib.
emptyTcConfig : TcConfig
emptyTcConfig = TcConfig {
  tcIoJoin = [],
  tcIoJoinProfile = "",
  tcStdlibOwned = omEmpty,
  tcFlatEntryIsStdlib = False,
  tcKey = "\n\n",
}

-- A graph record with every field fresh and [run] as its graph run: the process's
-- first record, before any drive, and the base each mint builds on.  [ctors] is the
-- builtin constructor map (always `builtinCtors`), a parameter for the reason
-- `freshCrossRun` states: the `interners` initializer must name `builtinCtors` in its
-- own body.
export
initialGraphCtx : OrdMap Scheme -> GraphRun -> GraphCtx
initialGraphCtx ctors run = GraphCtx {
  crossRun = freshCrossRun ctors,
  graphRun = run,
  effectDomains = Ref [],
  config = Ref emptyTcConfig,
  trace = None,
  graphAdmittedMethodsRef = Ref omEmpty,
  declEnvsRef = Ref emptyDeclEnvs,
  abstractRecordTypesRef = Ref omEmpty,
  argDispatchIdxByIdRef = Ref [],
  dictEligibleRef = Ref [],
  dictEligibleSetRef = Ref omEmpty,
  mangledShadowMapRef = Ref [],
  mangledFunDefsPresentRef = Ref False,
  builtinExternNamesRef = Ref omEmpty,
  promotionHarvestRef = Ref [],
  mainSchemeRef = Ref None,
  markSetsRef = Ref None,
  typeErrorsSticky = Ref False,
  typeErrorsStickyDiags = Ref [],
}

-- The process's interners (see `Interners`): the lineage objects and the extern
-- catalog of the graph record a drive continues from.  The drive's mint, the record
-- past the core pass each write it (`noteInterners`), so the next mint continues
-- from the last of them.  Before any drive they are a fresh record's.
export
interners : Ref Interners
interners = Ref (internersOf (initialGraphCtx builtinCtors (freshGraphRun ())))

export
internersOf : GraphCtx -> Interners
internersOf c = Interners {
  lineage = Lineage {
    lnEvCounter = c.graphRun.evCounter,
    lnLocalAbs = c.graphRun.localAbs,
    lnGrants = c.graphRun.grants,
    lnTyvarHigh = Ref 0,
    lnEffvarHigh = Ref 0,
  },
  externCatalog = c.builtinExternNamesRef,
}

-- [c] becomes the record the next drive continues from: the interners take its
-- lineage objects and extern catalog, and keep the process's counter high-water.
export
noteInterners : GraphCtx -> Unit
noteInterners c =
  let high = interners.value.lineage
  let next = internersOf c
  interners := Interners { next |
    lineage = Lineage { next.lineage |
      lnTyvarHigh = high.lnTyvarHigh,
      lnEffvarHigh = high.lnEffvarHigh,
    },
  }

-- A test probe's graph record: every field fresh, as a process's first record.
export
probeGraphCtx : Unit -> GraphCtx
probeGraphCtx _ = initialGraphCtx builtinCtors (freshGraphRun ())

-- [g] with fresh cross-module accumulators and a fresh graph run: the record a test
-- probe's next phase runs in, keeping [g]'s other fields.
export
freshSubRecordsOf : GraphCtx -> GraphCtx
freshSubRecordsOf g = GraphCtx { g |
  crossRun = freshCrossRun builtinCtors,
  graphRun = freshGraphRun (),
}

-- dict-passing state (the typed pipeline's `=>`-constraint layer):
--   activeDictVars   : constraint tyvar id → the dict parameter name a method
--                      occurrence at that variable's type reads (RDict).
--   funConstraintsRef: constrained fn name → its constraints' quantified tyvar
--                      ids (one per `=>` constraint, in slot order) — a call site
--                      maps each to its fresh instantiation var to pick a route.
--   pendingDictApps  : a constrained-fn occurrence's routes ref + the instantiated
--                      constraint monos, resolved to RKey/RDict after inference.

-- WS-1b: the program decls (interfaces) the supers-expansion reads.  Set by each
-- graph driver before inference; read by inferDictAtFound
-- to expand a call site's constraint slots with their transitive supers.  Read-only
-- during inference, so it needs no reset-lifecycle care.

-- WS-1b: the USER-module interface names (NOT core/prelude).  Super-expansion is
-- gated to user interfaces only: a prelude super chain (Ord requires Eq) is already
-- serviced by arg-tag dispatch and is NOT dict-passed on the eval path, so adding an
-- Eq slot to `clamp : Ord a =>` would desync its def arity from its arg-tag call sites
-- (the prior-attempt clamp regression).  User interfaces (Sub requires Sup) ARE
-- dict-passed and need the super slot.  Set by elaborateModules.

-- #11 soundness (native obligation hole): the INTERFACE names of a constrained
-- fn's `=>` constraints, slot-parallel to funConstraintsRef's ids.  funConstraintsRef
-- keeps only the tyvar ids (enough to pick a dict route); but to record a real impl
-- obligation when a constrained fn is INSTANTIATED at a concrete type (`g = f "hello"`
-- where `f : Num a => a -> a`), the call site needs the iface ("Num") so it can check
-- `Num String` against the impl table.  funConstraintsRef CANNOT supply that name —
-- it holds tyvar ids and nothing else — which is exactly why this separate
-- funConstraintIfacesRef table exists: it is the one that carries the iface name into
-- the constraint-obligation check.  Populated at the SAME
-- three sites as funConstraintsRef (registerMember / registerInferredFor /
-- seedDictAritiesFromSigs), with the SAME cross-module accumulate+reseed lifecycle.

-- a constrained-fn CALL site's instantiated constraint obligations: (iface, the
-- call's instantiated constraint mono).  Resolved after inference (when the mono is
-- ground) by checkCallObligations — a CONCRETE-head mono with no matching impl is an
-- ERROR; a still-polymorphic head is DEFERRED (left to a further-out caller).  This
-- is the compiler analog of the oracle's constraint_obligations + check_constraint_
-- obligations: pendingDictApps routes the dict, this list checks the impl exists.

wNew : Unit -> Windowed a
wNew _ = Windowed { items = Ref [], n = Ref 0 }

-- the ONLY extend.
export
wPush : Windowed a -> a -> Unit
wPush w x =
  w.items := x :: !w.items
  w.n := !w.n + 1

-- O(1) length snapshot, replacing a channel's `…N.value` read.
export
wMark : Windowed a -> Int
wMark w = !w.n

-- recover exactly the items pushed since [mark] (consed on the front, so
-- `takeFirst` recovers them in push order).
export
wWindow : Windowed a -> Int -> List a
wWindow w mark = takeFirst (!w.n - mark) !w.items

-- the WHOLE channel, newest-first, with no copy — the unwindowed read `wWindow w 0`
-- performs (takeFirst n items).  For a per-binding reader of a module-wide channel
-- (methodOccArgPairs) that copy is a quadratic; this is the same list wWindow would
-- have rebuilt.
export
wAll : Windowed a -> List a
wAll w = !w.items

-- for an error-rollback window (inferUserImplBodies): capture both refs together.
export
wSnapshot : Windowed a -> (List a, Int)
wSnapshot w = (!w.items, !w.n)

-- the ONLY rollback.
export
wRestore : Windowed a -> (List a, Int) -> Unit
wRestore w snap =
  w.items := fst snap
  w.n := snd snap

-- #1114: re-push a list of items in order, for a GROUND-PRESERVING rollback (DICT
-- §4.2 D6(b)) — `wRestore` to the snapshot, then `wPushAll` the subset the policy
-- keeps.  Monomorphic recursion, not a fold over a prelude method: this runs inside
-- the per-module inference path (compiler/AGENTS.md's hot-helper rule).
export
wPushAll : Windowed a -> List a -> Unit
wPushAll _ [] = ()
wPushAll w (x :: rest) =
  let _ = wPush w x
  wPushAll w rest

-- the empty shadow-dict stamp: an unconstrained standalone, or a route that resolves to
-- nothing.  Byte-identical to the `([], [])` this returned before the vectors joined it.
export
emptyShadowDicts : ShadowDicts
emptyShadowDicts = ShadowDicts { sdMonos = [], sdIfaces = [], sdArgVecs = [] }

-- #11 soundness (native obligation hole, ALWAYS-ON, independent of the dict-
-- elaboration machinery): per top-level binding, the deferred impl obligations it
-- generalizes over — (iface, the quantified-var id the obligation discriminates on).
-- Populated UNCONDITIONALLY at generalization in processSCC/processTopGroups (unlike
-- funPredicateSlotsRef, which the check path leaves empty because inferred-constraint
-- registration is gated on dictEligibleSetRef).  At a USE site (inferVar) the binding's
-- entry is freshened through the call's instantiation subst and checked against the
-- impl table — inferred constraints carried
-- on a scheme and re-checked at every instantiation.

-- E6 (module emit path only): funPredicateSlotsRef is wiped by `freshModuleCtx` at the start
-- of EACH module's typecheck, but a cross-module `=>`-constrained CALL site (entry
-- calling an imported `clampU`) must still find the callee's generalized constraint
-- slots so inferDictAt records a real pendingDictApp (→ the call gets its dict ARG).
-- The cross-run carrier accumulates every module's predicates across the graph;
-- checkModuleFullImpl re-seeds the per-run carrier after reset.  The defining
-- module's complete record, registered first, wins lookupPredicateSlots first-match.
-- WS-2/D2: module-attributed mirror of the bare cross-run carrier.  Keyed by
-- (owning module id, fn name) so the final scopePredicateSlots projection keeps only
-- the inferred-arity entry whose DEFINING module is in the dict-passed module's
-- scope.  Without this, two distinct top-level fns sharing a bare name but with
-- different `=>`-constraint arity (e.g. `wrap : Tag a => …` in module A vs
-- `wrap : (P a, Q a) => …` in module B) both land in the bare cross-module table;
-- a bare-name-only scope keeps both, and
-- dictArityOf's first-match returns the WRONG module's arity → a call site in A's
-- importer is sized to B's 2 dict params (over-application) → run-path crash while
-- the emit path's arg-stamp recovers (the §1 D2 repro).  Populated per-module in
-- checkModuleFullImpl (each fn DEFINED in this module's `prog` is attributed to mid);
-- consumed by scopePredicateSlots.  The bare cross-run carrier is kept — the
-- per-module reseed at checkModuleFullImpl:7546 needs the bare form for the current
-- module's E6 cross-module call-site discovery.
-- Predicate interface identity is stored in the same cross-module carrier record as
-- its arguments and ids; there is no slot-parallel interface accumulator.
-- the two stay aligned across a bare-name cross-module collision (a foreign same-named
-- fn of different `=>`-arity must not contribute its ifaces).  Populated/reset in
-- lockstep with the ids qual ref (checkModuleFullImpl / elaborateModules).
-- WS-2/D2: the current module's imported VALUE name → its source module id (the dotted
-- id its `import` form names == the loader mid == the qual tables' DEFINER key for a
-- DIRECT import).  Lets inferDictAtFound resolve a cross-module constrained callee's
-- dict arity by MODULE IDENTITY (the (definer,name)-keyed qual tables) instead of the
-- bare-name first-match over the jointly-seeded funConstraintsRef — which picks the
-- MOST-RECENTLY-PREPENDED same-named entry, i.e. a FOREIGN module's `wrap` when the
-- importer merely imports a different `wrap`.  That bare-name collision is an
-- observable run-crash today (`applied non-function`) on `medaka run` of a direct
-- cross-module import of two same-named, different-`=>`-arity constrained fns, while
-- `check` accepts and `build` is saved by universal mangling.  Set per-module in
-- checkModuleFullImpl from `prog`'s DUse decls; only EXPLICIT imports
-- (UseName/UseGroup/UseAlias) are mapped — a wildcard `import mod.*` can't enumerate
-- names here, and a re-exported fn's import source ≠ its definer, so both fall back to
-- the bare table (correct, byte-identical; the qual path is the fix for the common
-- direct-import case).  Reset by `freshModuleCtx` (per module).

-- WS-1c: the third field is the slot-parallel interface-name list (one per mono),
-- so resolveDictApps can resolve an UNDETERMINED top-level constraint (a constraint
-- tyvar pinned by neither arg nor result) by counting that interface's impls: sole
-- impl → a concrete RKey to it; ≥2 → an AmbiguousImpl error.  Recorded from the same
-- `expanded` (iface, id) pairing inferDictAtFound already builds for recordCallObligations.

-- #1161 (F-3a-ii): the FOURTH field is the slot-parallel GOAL VECTOR list — for each
-- slot, the whole predicate's instantiated argument vector (`Ix a Char` at `a = Int`
-- ⇒ `[Int, Char]`).  Slots 2/3 are unchanged and remain the authority on slot COUNT
-- and ORDER; this field only widens the GOAL each slot's route is selected with, so
-- emitted dict arity is untouched (dictArityOf/dictPass/scopeArities read
-- funConstraintsRef, not this).  A slot with nothing better to offer carries the
-- singleton `[its own mono]`, which reduces the vector path to the scalar one term
-- for term — see routesOfMonosTopV.

-- PERF: this channel's length in O(1) — same O(N²)-per-group length scan the call
-- channel had before #838 I1 ported it onto `Windowed` (see `wMark` above).  #841
-- ports `pendingDictApps` onto `Windowed` too (see `dictApps` below); mutated ONLY
-- by `freshModuleCtx` and `pushDictApp`.

-- Construct every field-Ref fresh (each reproduces its former top-level ref's initial);
-- the constructor is exhaustive, which is the property that matters.
-- [ctors] is the builtin constructor map (always `builtinCtors`) and is a parameter
-- rather than a direct `builtinCtors` reference on purpose: the `interners` cell is
-- a nullary top-level binding, a global initialized eagerly at startup, and the
-- backends order those globals by the value globals each initializer names
-- (`eagerVars`, backend/emit_support.mdk).  A read hidden inside this function is
-- invisible to that order, so the cell would be initialized before `builtinCtors` and
-- read a zero: a null dereference at wasm instantiate, and a silent zero on native
-- until the first drive's mint overwrites it.  Taking the map as an argument puts
-- `builtinCtors` in that initializer's own body
-- (`initialGraphCtx builtinCtors`).
freshCrossRun : OrdMap Scheme -> CrossRun
freshCrossRun ctors = CrossRun {
  universeFunNamesRef = Ref omEmpty,
  universeMethodDispatchIdxByIdRef = Ref [],
  universeDataCtors = Ref [],
  universeCtorPop = Ref (spFromFloor ctors),
  universeRecordPop = Ref spEmpty,
  builtinClassesRef = Ref emptyBuiltinClasses,
  crossModuleFunPredicateSlotsRef = Ref [],
  crossModuleFunPredicateSlotsQualRef = Ref [],
  crossModuleFunConstraintDeclaredRef = Ref [],
  crossModuleFunConstraintDeclaredQualRef = Ref [],
  crossModuleMethodPredicateSlotsRef = Ref [],
  crossModuleMethodPredicateSlotsQualRef = Ref [],
  coreSchemeObligationsRef = Ref omEmpty,
  crossModuleSchemeOblsQualRef = Ref [],
}

-- Source-location attribution: the span of the innermost construct around a check
-- is the module record's `mcLoc`.  A construct hands the checks below it a copy
-- carrying its own span (`mctxAt`); nothing restores it, because the caller's copy
-- never changed.  `IfSome` keeps the enclosing span when the construct has none.
-- The copy is the three-field record (the module's cells are one shared
-- `ModuleCells`), and a construct whose span is the enclosing one (an `ELoc` under
-- a construct that names the same span) hands on the record it was given.
export
mctxAt : Option Loc -> ModuleCtx -> ModuleCtx
mctxAt loc mctx =
  if sameSpan loc mctx.mcLoc then mctx else { mctx | mcLoc = loc }

sameSpan : Option Loc -> Option Loc -> Bool
sameSpan None None = True
sameSpan (Some a) (Some b) = locEq a b
sameSpan None (Some _) = False
sameSpan (Some _) None = False

export
mctxAtIfSome : Option Loc -> ModuleCtx -> ModuleCtx
mctxAtIfSome None mctx = mctx
mctxAtIfSome loc mctx = mctxAt loc mctx

export
dynAt : Option Loc -> DynCtx -> DynCtx
dynAt loc dyn =
  if sameSpan loc dyn.dcModule.mcLoc then
    dyn
  else
    { dyn | dcModule = { dyn.dcModule | mcLoc = loc } }

export
dynAtIfSome : Option Loc -> DynCtx -> DynCtx
dynAtIfSome None dyn = dyn
dynAtIfSome loc dyn = dynAt loc dyn

export
envAt : Option Loc -> TcEnv -> TcEnv
envAt loc env =
  if sameSpan loc env.teDyn.dcModule.mcLoc then
    env
  else
    { env |
      teDyn = { env.teDyn | dcModule = { env.teDyn.dcModule | mcLoc = loc } },
    }

export
envAtIfSome : Option Loc -> TcEnv -> TcEnv
envAtIfSome None env = env
envAtIfSome loc env = envAt loc env

export
renderEvidenceBinder : GraphCtx -> EvidenceBinderId -> String
renderEvidenceBinder gctx (EvidenceBinderId sid ordinal) =
  match (Scopes.scopeFrame (currentScopeStore gctx ()) sid).sfOwner
    BindingOwner owner => dictParamName owner ordinal
    LocalBindingOwner owner => dictParamName owner ordinal
    DefaultBodyOwner owner =>
      if ordinal == defaultReceiverOrdinal then
        defaultReceiverDict owner.dbiMethod
      else
        dictParamName owner.dbiMethod ordinal
    _ => panic "evidence binder outside binding scope"

export
freshGraphRun : Unit -> GraphRun
freshGraphRun _ = GraphRun {
  tyvarCounter = Ref 0,
  effvarCounter = Ref 0,
  ctorExistentialsRef = Ref Tip,
  patternAuthIdsRef = Ref Tip,
  anyExistentialsRef = Ref False,
  goals = Ref [],
  numlitRefs = Ref [],
  numlitN = Ref 0,
  activeDictVars = Ref [],
  gGiven = Ref omEmpty,
  moduleRanges = Ref [],
  stampCtxs = Ref [],
  goalsN = Ref 0,
  evCounter = Ref 0,
  evBase = 0,
  evJudged = Ref 0,
  evScopedJudged = Ref [],
  evTable = Ref [],
  evCells = Ref (arrayMake 0 None),
  siteCells = Ref (arrayMake 0 None),
  scopeStore = Scopes.freshScopeStore (),
  localAbs = freshLocalAbsState (),
  grants = freshGrantState (),
  binderPending = Ref [],
  binderRows = Ref emptyBinderTypes,
  liveRoots = Ref [],
  liveNumRoots = Ref [],
  liveNumGoals = Ref [],
  liveGoals = Ref [],
}

-- Scope storage is graph-owned; this accessor keeps the request store explicit
-- at service calls without allocating or threading it through inference.
export
currentScopeStore : GraphCtx -> Unit -> ScopeStore
currentScopeStore gctx _ = gctx.graphRun.scopeStore

-- #2549 M2: start a new graph lineage from [lineage], the interners' (the run
-- most recently minted or restored).  The evidence ORDINAL continues from that run's counter, so an
-- id minted from here does not repeat one the previous drive's tree holds, and a
-- stray read of such an id fails loudly instead of answering for another node.
-- What is indexed by ordinal is not carried: `evBase`
-- moves up to the counter and `evCells` starts empty, so a long-lived process's
-- arrays span one graph rather than its whole life.
--
-- Nothing reads the cell arrays across a new lineage.  Every driver's mint
-- (`mintGraphCtx`) starts one before it marks.  Trees outlive their drive only
-- through the facts the drive returned, so a caller that runs a second elaboration
-- before it reads the first's trees keeps the first's facts.
--
-- The binder-name and grant state are the lineage's own objects, cleared in place
-- below.
export
graphLineageRun : Lineage -> GraphRun
graphLineageRun lineage =
  let n = lineage.lnEvCounter.value
  let base = n
  let localAbs = lineage.lnLocalAbs
  let grants = lineage.lnGrants
  let fresh = freshGraphRun ()
  fresh.evCounter := n
  -- The cells below the base belong to an earlier drive, which judged them or never
  -- solved them; this drive judges only the cells of its own lineage.
  fresh.evJudged := base
  -- The binder names survive; the quantified ids do not: they are type-variable
  -- ids, and the fresh run restarts the counter that minted them.
  localAbs.lasQuantified := omEmpty
  -- Grant-marked occurrences survive.  The sourceless variables do not: the
  -- inference that follows registers them under ids the restarted counter mints
  -- again.  Nor do the method-body binders, keyed by the ordinals of a scope store
  -- this run starts afresh.  Nor do the file bounds, keyed by site: a check of the
  -- module adds its own, whose variables are this drive's, and a bound an earlier
  -- check left would be read against them.  A served module's come back with its
  -- trees.  The tables keyed by names are kept (`GrantState`).
  grants.gsSourceless := Tip
  grants.gsBodies := Tip
  grants.gsBounds := omEmpty
  grants.gsValueBounds := omEmpty
  GraphRun { fresh |
    localAbs = localAbs,
    grants = grants,
    evBase = base,
  }

-- #1557 A-3.5c REMOVED `ifaceParamKindsRef` from this record, and with it the
-- `universeIfaceParamKinds` CrossRun cell that marshalled it between modules.  Its
-- one reader (`checkGradedImplTys`) reads stage K's `CE` instead; the writer
-- (`registerIfaceParamKinds`) is gone too, since a table nobody reads is not a
-- second source of truth worth keeping (design law L1).

-- Construct every field fresh (each reproduces its former top-level ref's initial).
-- no count here, deliberately: a number written into this comment has twice gone stale
-- without anyone touching the record — once by inheriting an already-wrong figure, once
-- when a whole-file reflow moved the indentation this recipe anchors on.  Derive it:
--   sed -n '/^public export data ModuleCells = ModuleCells {$/,/^}/p' compiler/types/tc_types.mdk \
--     | grep -cE '^  [a-zA-Z][A-Za-z0-9_]* : '            # fields
--   ... | grep -cE '^  [a-zA-Z][A-Za-z0-9_]* : Ref '      # of which Refs
-- Both anchors are load-bearing.  The END anchor is `/^}/`: this record's closing brace
-- sits at column 0, so `/^  }/` misses it and the range runs on into the next record
-- instead.  The FIELD anchor is TWO leading spaces; the four-space form this recipe
-- once used matches nothing and silently returns 0.
-- A derivation is only honest if someone ran it — so run it, don't read a number here.
-- The module fields start empty except the four the mint is given: the graph record,
-- the module id and the seed's oracle and warnings.  A mint is outside every construct,
-- so it holds no span.
export
freshModuleCtx : GraphCtx -> CheckRunSeed -> String -> ModuleCtx
freshModuleCtx gctx seed mid = ModuleCtx {
  mcCells = freshModuleCells seed mid,
  mcGraph = gctx,
  mcLoc = None,
}

freshModuleCells : CheckRunSeed -> String -> ModuleCells
freshModuleCells seed mid = ModuleCells {
  currentScope = Ref ScopeClosed,
  admittedOccObls = Ref [],
  curEffect = Ref [],
  effectSummaries = EffectSolver.newSolver (),
  pendingJoinsRef = Ref [],
  fileValueFlows = wNew (),
  fileValueScopes = Ref [],
  rigidEffvarsRef = Ref Tip,
  rigidAuthvarsRef = Ref Tip,
  effectSitesRef = Ref omEmpty,
  rowFailureReportedRef = Ref omEmpty,
  typeErrorKeySetRef = Ref omEmpty,
  escapedExistentialsRef = Ref Tip,
  openedAuthvarsRef = Ref Tip,
  indexSubstitutedRef = Ref Tip,
  extendedBindersRef = Ref Tip,
  displayHiddenBindersRef = Ref Tip,
  openedExistentialsRef = Ref [],
  openedExistentialsStackRef = Ref [],
  recordByNameRef = Ref omEmpty,
  fieldOwnersRef = Ref omEmpty,
  dataParamKindsRef = Ref [],
  dataParamNameIndexRef = Ref omEmpty,
  dataParamPolarityRef = Ref [],
  dataParamRowAtomsRef = Ref [],
  aliasTableRef = Ref [],
  numLitFromIntAnchorRef = Ref None,
  definerShadowNamesRef = Ref omEmpty,
  definerShadowSigsRef = Ref omEmpty,
  bodyImplEnvRef = Ref emptyImplEnv,
  methodAliasEntriesRef = Ref omEmpty,
  methodScopeCtxRef = Ref None,
  methodScopeMemoRef = Ref omEmpty,
  aliasMethodOriginsRef = Ref omEmpty,
  implObls = wNew (),
  poisonedVars = Ref [],
  deferrableVarIds = Ref Tip,
  liveMemberMonosRef = Ref [],
  quiescentGoalsRef = Ref [],
  heldLiveGoalsRef = Ref [],
  determinedRowsRef = Ref Tip,
  declaredSigVarIds = Ref omEmpty,
  tupleCallCandidates = Ref [],
  numlitVarLocs = Ref [],
  numlitRanges = Ref [],
  wideLitRanges = Ref [],
  patLitPending = Ref [],
  patLitDeferred = Ref [],
  matchChecksDeferred = Ref [],
  numlitUntainted = Ref [],
  numlitOpLocs = Ref [],
  numlitCtxTags = Ref [],
  localBindRefs = Ref [],
  localSchemesOut = Ref [],
  seedSchemesOut = Ref [],
  funPredicateSlotsRef = Ref [],
  funPredicateSlotsIdxRef = Ref omEmpty,
  funConstraintDeclaredRef = Ref [],
  currentImportDefinersRef = Ref omEmpty,
  currentImportOriginsRef = Ref omEmpty,
  importedSchemeOblsRef = Ref omEmpty,
  obls = wNew (),
  absorptions = wNew (),  -- #839 2a: resets per module for free via this whole-record re-mint
  schemeObligationsRef = Ref [],
  schemeDefIdsRef = Ref omEmpty,
  methodPredicateSlotsRef = Ref [],
  currentFn = Ref "",
  currentImplBody = Ref False,
  methodSiteFns = Ref omEmpty,
  dictAppFns = Ref omEmpty,
  residualUnivRef = Ref emptyImplUniverse,
  promotedRef = Ref [],
  fieldOwnerModulesRef = Ref omEmpty,
  fieldOwnerReachRef = Ref omEmpty,
  typeErrors = wNew (),
  typeErrorMsgSetRef = Ref omEmpty,
  ambiguitySitesRef = Ref omEmpty,
  ambiguityVarsRef = Ref Tip,
  errorsDetected = Ref 0,
  occursCheckFailed = Ref False,
  currentLevel = Ref 0,
  markingRef = Ref None,
  superDeclsRef = Ref [],
  standaloneValuesRef = Ref omEmpty,
  methodDispatchIdxByIdRef = Ref [],
  matchOracle = Ref seed.crsOracle,
  matchWarnings = Ref seed.crsWarnings,
  sigNameSetRef = Ref omEmpty,
  sigTyMapRef = Ref omEmpty,
  currentModuleRef = Ref mid,
  invocationViewRef = Ref (InvocationView [] [] []),
  ownPopsRef = Ref (spEmpty, spEmpty),
}

-- The record a drive starts from in the graph record [gctx]: no module, an empty
-- oracle, no warnings.
export
initialModuleCtx : GraphCtx -> ModuleCtx
initialModuleCtx gctx = blankModuleCtx gctx ""

-- A fresh record for the module [mid] in [gctx], with an empty oracle and no warnings.
export
blankModuleCtx : GraphCtx -> String -> ModuleCtx
blankModuleCtx gctx mid =
  freshModuleCtx
    gctx
    CheckRunSeed { crsOracle = emptyOracle, crsWarnings = [] }
    mid

-- Built once: a stamp context keeps no oracle, and building one per stamp is
-- counted by `exhaust.oracle` in the per-verb stage counts.
emptyOracle : Oracle
emptyOracle = buildOracle []

-- The module-field partition, written once: every field of `ModuleCtx` and of its
-- `ModuleCells` by class, each taken from the argument its class names (the cells field
-- by field in `moduleCellsFrom`).  A mint makes every field fresh (`freshModuleCtx`),
-- taking the module id and the oracle and warnings from its seed; every other
-- whole-record operation is a call of this function.
--   [run] — what the module's inference, its channels and its stampers accumulate, the
--     graph record they accumulate in (`mcGraph`), and the span of the construct around
--     a check (`mcLoc`, none in every record passed here).  A carry takes a fresh
--     record's, minted in the graph it is given; a stamp context takes the
--     module's own (shared); the drain's enter takes the stamp context's.
--   [tables] — the module's declared tables and its match oracle and warnings.  A carry
--     copies the module's; a stamp context drops them (its `superDeclsRef` holds the
--     interface decls of the module's universe instead).
--   [drain] — the two tables the stampers read (`standaloneValuesRef`,
--     `methodDispatchIdxByIdRef`).  As [tables], except that the drain's enter takes the
--     live record's: a stamp context holds none of its own.
--   [ident] — the module id and the invocation view.  As [tables].
-- With [detach] every field of the last three classes is a fresh `Ref` over the
-- source's value, so later writes on either side do not reach the other.
export
moduleCtxFrom : Bool ->
  ModuleCtx ->
  ModuleCtx ->
  ModuleCtx ->
  ModuleCtx ->
  ModuleCtx
moduleCtxFrom detach run tables drain ident = ModuleCtx {
  mcCells =
    moduleCellsFrom
      detach
      run.mcCells
      tables.mcCells
      drain.mcCells
      ident.mcCells,
  mcGraph = run.mcGraph,
  mcLoc = run.mcLoc,
}

moduleCellsFrom : Bool ->
  ModuleCells ->
  ModuleCells ->
  ModuleCells ->
  ModuleCells ->
  ModuleCells
moduleCellsFrom detach run tables drain ident = ModuleCells {
  currentScope = run.currentScope,
  admittedOccObls = run.admittedOccObls,
  curEffect = run.curEffect,
  effectSummaries = run.effectSummaries,
  pendingJoinsRef = run.pendingJoinsRef,
  fileValueFlows = run.fileValueFlows,
  fileValueScopes = run.fileValueScopes,
  rigidEffvarsRef = run.rigidEffvarsRef,
  rigidAuthvarsRef = run.rigidAuthvarsRef,
  effectSitesRef = run.effectSitesRef,
  rowFailureReportedRef = run.rowFailureReportedRef,
  typeErrorKeySetRef = run.typeErrorKeySetRef,
  escapedExistentialsRef = run.escapedExistentialsRef,
  openedAuthvarsRef = run.openedAuthvarsRef,
  indexSubstitutedRef = run.indexSubstitutedRef,
  extendedBindersRef = run.extendedBindersRef,
  displayHiddenBindersRef = run.displayHiddenBindersRef,
  openedExistentialsRef = run.openedExistentialsRef,
  openedExistentialsStackRef = run.openedExistentialsStackRef,
  recordByNameRef = run.recordByNameRef,
  fieldOwnersRef = run.fieldOwnersRef,
  dataParamKindsRef = run.dataParamKindsRef,
  dataParamNameIndexRef = run.dataParamNameIndexRef,
  dataParamPolarityRef = run.dataParamPolarityRef,
  dataParamRowAtomsRef = run.dataParamRowAtomsRef,
  aliasTableRef = run.aliasTableRef,
  numLitFromIntAnchorRef = run.numLitFromIntAnchorRef,
  definerShadowNamesRef = run.definerShadowNamesRef,
  definerShadowSigsRef = run.definerShadowSigsRef,
  bodyImplEnvRef = run.bodyImplEnvRef,
  methodAliasEntriesRef = run.methodAliasEntriesRef,
  methodScopeCtxRef = run.methodScopeCtxRef,
  methodScopeMemoRef = run.methodScopeMemoRef,
  aliasMethodOriginsRef = run.aliasMethodOriginsRef,
  implObls = run.implObls,
  poisonedVars = run.poisonedVars,
  deferrableVarIds = run.deferrableVarIds,
  liveMemberMonosRef = run.liveMemberMonosRef,
  quiescentGoalsRef = run.quiescentGoalsRef,
  heldLiveGoalsRef = run.heldLiveGoalsRef,
  determinedRowsRef = run.determinedRowsRef,
  declaredSigVarIds = run.declaredSigVarIds,
  tupleCallCandidates = run.tupleCallCandidates,
  numlitVarLocs = run.numlitVarLocs,
  patLitPending = run.patLitPending,
  patLitDeferred = run.patLitDeferred,
  matchChecksDeferred = run.matchChecksDeferred,
  numlitRanges = run.numlitRanges,
  wideLitRanges = run.wideLitRanges,
  numlitUntainted = run.numlitUntainted,
  numlitOpLocs = run.numlitOpLocs,
  numlitCtxTags = run.numlitCtxTags,
  localBindRefs = run.localBindRefs,
  localSchemesOut = run.localSchemesOut,
  seedSchemesOut = run.seedSchemesOut,
  funPredicateSlotsRef = run.funPredicateSlotsRef,
  funPredicateSlotsIdxRef = run.funPredicateSlotsIdxRef,
  funConstraintDeclaredRef = run.funConstraintDeclaredRef,
  currentImportDefinersRef = run.currentImportDefinersRef,
  currentImportOriginsRef = run.currentImportOriginsRef,
  importedSchemeOblsRef = run.importedSchemeOblsRef,
  obls = run.obls,
  absorptions = run.absorptions,
  schemeObligationsRef = run.schemeObligationsRef,
  schemeDefIdsRef = run.schemeDefIdsRef,
  methodPredicateSlotsRef = run.methodPredicateSlotsRef,
  currentFn = run.currentFn,
  currentImplBody = run.currentImplBody,
  methodSiteFns = run.methodSiteFns,
  dictAppFns = run.dictAppFns,
  residualUnivRef = run.residualUnivRef,
  promotedRef = run.promotedRef,
  fieldOwnerModulesRef = run.fieldOwnerModulesRef,
  fieldOwnerReachRef = run.fieldOwnerReachRef,
  typeErrors = run.typeErrors,
  typeErrorMsgSetRef = run.typeErrorMsgSetRef,
  ambiguitySitesRef = run.ambiguitySitesRef,
  ambiguityVarsRef = run.ambiguityVarsRef,
  errorsDetected = run.errorsDetected,
  occursCheckFailed = run.occursCheckFailed,
  currentLevel = run.currentLevel,
  markingRef = run.markingRef,
  ownPopsRef = run.ownPopsRef,
  superDeclsRef = refFrom detach tables.superDeclsRef,
  sigNameSetRef = refFrom detach tables.sigNameSetRef,
  sigTyMapRef = refFrom detach tables.sigTyMapRef,
  matchOracle = refFrom detach tables.matchOracle,
  matchWarnings = refFrom detach tables.matchWarnings,
  standaloneValuesRef = refFrom detach drain.standaloneValuesRef,
  methodDispatchIdxByIdRef = refFrom detach drain.methodDispatchIdxByIdRef,
  currentModuleRef = refFrom detach ident.currentModuleRef,
  invocationViewRef = refFrom detach ident.invocationViewRef,
}

refFrom : Bool -> Ref a -> Ref a
refFrom detach r = if detach then Ref r.value else r

-- A record with fresh run fields in the graph record [gctx] and [m]'s other fields,
-- copied by value: what a test probe runs in.
export
carryModuleCtx : GraphCtx -> ModuleCtx -> ModuleCtx
carryModuleCtx gctx m = moduleCtxFrom True (initialModuleCtx gctx) m m m

export
emptySigVars : SigVars
emptySigVars = SigVars { svRows = [], svAuths = [] }

freshLocalAbsState : Unit -> LocalAbsState
freshLocalAbsState _ = LocalAbsState {
  lasBinders = Ref omEmpty,
  lasRecOccs = Ref omEmpty,
  lasNext = Ref ("", 0),
  lasMinted = Ref [],
  lasQuantified = Ref omEmpty,
}

freshGrantState : Unit -> GrantState
freshGrantState _ = GrantState {
  gsOccs = Ref Tip,
  gsGrantOnly = Ref Tip,
  gsTopIds = Ref omEmpty,
  gsLocalIds = Ref omEmpty,
  gsMethods = Ref omEmpty,
  gsBodies = Ref Tip,
  gsLastInst = Ref None,
  gsLastMethodInst = Ref None,
  gsLastStandalone = Ref None,
  gsSourceless = Ref Tip,
  gsTakers = Ref omEmpty,
  gsFresh = Ref 0,
  gsBounds = Ref omEmpty,
  gsValueBounds = Ref omEmpty,
  gsPassingModule = Ref "",
}

export
emptyBuiltinClasses : BuiltinClasses
emptyBuiltinClasses = BuiltinClasses {
  bcNum = OriginUnresolved,
  bcEq = OriginUnresolved,
  bcOrd = OriginUnresolved,
  bcSemigroup = OriginUnresolved,
  bcNumPresent = False,
  bcEqPresent = False,
  bcOrdPresent = False,
  bcSemigroupPresent = False,
  bcPreludeSeeded = False,
}

-- the first [n] entries of a list (the newly-prepended obligations of a group)
export
takeFirst : Int -> List a -> List a
takeFirst n _
  | n <= 0 = []
takeFirst _ [] = []
takeFirst n (x :: xs) = x :: takeFirst (n - 1) xs

export
dictParamName : String -> Int -> String
dictParamName fn slot = "$dict_\{fn}_\{intToString slot}"

-- The evidence-binder ordinal a default body's receiver is registered under.  Real
-- slots count up from 0, so a negative ordinal can never alias one.
export
defaultReceiverOrdinal : Int
defaultReceiverOrdinal = -1

export
emptyImplUniverse : ImplUniverse
emptyImplUniverse = ImplUniverse mregEmpty mregEmpty

-- builtin constructors available without the prelude (mirrors initial_env)
export
builtinCtors : OrdMap Scheme
builtinCtors =
  omInsert
    "True"
    (monoScheme (tconBuiltin "Bool"))
    (omInsert "False" (monoScheme (tconBuiltin "Bool")) omEmpty)

-- Mint the drive's graph record, once, at the head of `graphPreamble`, from the
-- drive's [inputs], the [admitted] map its driver computed (`renameAliasedMethods`;
-- empty on the projections) and the interners, and nothing else of an earlier
-- drive: a long-lived process (LSP, playground, snapshot runner, `medaka test`)
-- drives repeatedly, and drive K+1 must not start from drive K's residue.  Every
-- field is fresh (`initialGraphCtx`) except the trace sink and the admitted map,
-- which are this drive's, the extern catalog, which is the interners' (a union over
-- the process; see `noteBuiltinExternNames`), and `graphRun`, a new lineage from
-- the interners' (`graphLineageRun`).  The record is returned, and the
-- drive continues from it; the interners take its lineage and catalog.
export
mintGraphCtx : DriveInputs -> OrdMap (List (String, String)) -> GraphCtx
mintGraphCtx inputs admitted =
  let carried = interners.value
  let base = initialGraphCtx builtinCtors (graphLineageRun carried.lineage)
  let gctx = GraphCtx { base |
    trace = inputs.diTrace,
    graphAdmittedMethodsRef = Ref admitted,
    builtinExternNamesRef = carried.externCatalog,
  }
  noteInterners gctx
  gctx

-- test-only observation: declarations whose only callers are tests and probes.

-- A sink with every gate off and fresh buffers; each `begin*` turns one gate on.
offTraceSink : Unit -> TraceSink
offTraceSink _ = TraceSink {
  tsAssumptionEnabled = False,
  tsAssumptionEntries = Ref [],
  tsNumericPredicateEnabled = False,
  tsNumericPredicateEntries = Ref [],
  tsMethodReturnEnabled = False,
  tsMethodReturnEntries = Ref [],
  tsEvidenceObservationEnabled = False,
  tsEvidenceObservationEntries = Ref [],
}

-- The trace builders and readers: a test builds a sink with `begin*`, passes it as
-- the `diTrace` of the drives it observes, and reads its buffer with `finish*`.
export
beginAssumptionTrace : Unit -> TraceSink
beginAssumptionTrace _ = { offTraceSink () | tsAssumptionEnabled = True }

export
finishAssumptionTrace : TraceSink -> List AssumptionTraceEntry
finishAssumptionTrace sink = reverseL sink.tsAssumptionEntries.value

export
beginNumericPredicateTrace : Unit -> TraceSink
beginNumericPredicateTrace _ =
  { offTraceSink () | tsNumericPredicateEnabled = True }

export
finishNumericPredicateTrace : TraceSink -> List NumericPredicateTraceEntry
finishNumericPredicateTrace sink = reverseL sink.tsNumericPredicateEntries.value

export
beginMethodReturnTrace : Unit -> TraceSink
beginMethodReturnTrace _ = { offTraceSink () | tsMethodReturnEnabled = True }

-- #2095: trace-gated, zero cost when off — same discipline as
-- `methodReturnTrace`. Generalizes that pattern from
-- the one migrated return family to every `Obligation` `recordEvidence`
-- publishes: a method occurrence and a dictionary application alike, whatever
-- family produced the goal, read back from the SAME cells the stampers wrote
-- (never re-derived), so this can never disagree with the published `EvTable`.
export
beginEvidenceObservation : Unit -> TraceSink
beginEvidenceObservation _ =
  { offTraceSink () | tsEvidenceObservationEnabled = True }

export
finishEvidenceObservation : TraceSink -> List EvidenceObservationEntry
finishEvidenceObservation sink =
  reverseL sink.tsEvidenceObservationEntries.value

-- Test visibility (`typecheck_test.mdk`): the length of [gctx]'s method-cell index,
-- which spans only its graph lineage.
export
evCellsSpanProbe : GraphCtx -> Int
evCellsSpanProbe gctx = arrayLength gctx.graphRun.evCells.value

export
scopeTraceContext : GraphCtx -> ScopeId -> (String, String)
scopeTraceContext gctx sid =
  Scopes.scopeTraceContext (currentScopeStore gctx ()) sid

export
scopeFrameStats : GraphCtx -> (Int, Int)
scopeFrameStats gctx = Scopes.scopeFrameStats (currentScopeStore gctx ())

-- Test-only seam: the names a default body's evidence binders render to.  Its
-- method-level slots are dictionary parameters of the lowered body; its receiver is
-- never a parameter -- lowering and eval rebind it per instance (`defaultReceiverDict`).
defaultBodyBinderNamesProbe : Unit -> List String
defaultBodyBinderNamesProbe _ =
  let gctx = probeGraphCtx ()
  let iface =
    IfaceRef { irName = "Supply", irOrigin = OriginModule "owner-module" }
  let owner = DefaultBodyIdentity { dbiIface = iface, dbiMethod = "copy" }
  let store = currentScopeStore gctx ()
  let root = Scopes.freshScope store None 0 "owner-module" ModuleOwner
  let body =
    Scopes.freshScope
      store
      (Some root)
      1
      "owner-module"
      (DefaultBodyOwner owner)
  let rendered = [
    renderEvidenceBinder gctx (Scopes.binderAt body 0),
    renderEvidenceBinder gctx (Scopes.binderAt body 1),
    renderEvidenceBinder gctx (Scopes.binderAt body defaultReceiverOrdinal),
  ]
  rendered

-- > defaultBodyBinderNamesProbe ()
-- ["$dict_copy_0", "$dict_copy_1", "$self_copy"]
# DESUGAR
(DUse false (UseGroup ("types" "tc_mono") ((mem "locEq" false) (mem "monoScheme" false) (mem "tconBuiltin" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Loc" true) (mem "TyConOrigin" true) (mem "defaultReceiverDict" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Scheme" true))))
(DUse false (UseAlias ("types" "effect_solver") "EffectSolver"))
(DUse false (UseGroup ("types" "tc_types") ((mem "AbsorptionEvent" true) (mem "AssumptionTraceEntry" true) (mem "BuiltinClasses" true) (mem "CheckRunSeed" true) (mem "ClassEnv" true) (mem "CrossRun" true) (mem "DataEnv" true) (mem "DeclEnvs" true) (mem "DeclEnvSeedAcc" true) (mem "DriveInputs" true) (mem "DynCtx" true) (mem "EvidenceObservationEntry" true) (mem "GrantState" true) (mem "GraphCtx" true) (mem "GraphRun" true) (mem "ImplEnv" true) (mem "ImplUniverse" true) (mem "Interners" true) (mem "InvocationView" true) (mem "Lineage" true) (mem "LocalAbsState" true) (mem "MethodEnv" true) (mem "ModuleCells" true) (mem "ModuleCtx" true) (mem "NumericPredicateTraceEntry" true) (mem "Predicate" true) (mem "ShadowDicts" true) (mem "SigVars" true) (mem "TcConfig" true) (mem "TcEnv" true) (mem "TraceSink" true) (mem "UObligation" true) (mem "Windowed" true))))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("types" "evidence") ((mem "EvidenceBinderId" true) (mem "ScopeId" true))))
(DUse false (UseGroup ("types" "scopes") ((mem "DefaultBodyIdentity" true) (mem "ScopeCursor" true) (mem "ScopeOwner" true) (mem "ScopeStore" false))))
(DUse false (UseAlias ("types" "scopes") "Scopes"))
(DUse false (UseGroup ("types" "solver_contract") ((mem "Instantiation" true))))
(DUse false (UseGroup ("types" "registry") ((mem "regEmpty" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "buildOracle" false) (mem "Oracle" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omInsert" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false))))
(DUse false (UseGroup ("types" "registry") ((mem "mregEmpty" false) (mem "regEmpty" false) (mem "spEmpty" false) (mem "spFromFloor" false))))
(DUse false (UseGroup ("types" "disposition") ((mem "MethodDisposition" true))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "emptyBinderTypes" false))))
(DTypeSig false "emptyDeclEnvs" (TyCon "DeclEnvs"))
(DFunDef false "emptyDeclEnvs" () (ERecordCreate "DeclEnvs" ((fa "deModules" (EListLit)) (fa "deOrdIndex" (EVar "omEmpty")) (fa "deDefiners" (EVar "omEmpty")) (fa "deAmbigValues" (EVar "omEmpty")) (fa "deAllDecls" (EListLit)) (fa "deData" (EVar "emptyDataEnv")) (fa "deImpls" (EVar "emptyImplEnv")) (fa "deIfaces" (EVar "emptyClassEnv")) (fa "deMethods" (EVar "emptyMethodEnv")) (fa "deKindsBefore" (EVar "omEmpty")) (fa "deNameIndexBefore" (EVar "omEmpty")) (fa "dePolaritiesBefore" (EVar "omEmpty")) (fa "deAtomsBefore" (EVar "omEmpty")) (fa "deOwnersBefore" (EVar "omEmpty")) (fa "deOwnerModules" (EVar "omEmpty")) (fa "deReach" (EVar "omEmpty")))))
(DTypeSig true "emptyDeclEnvSeedAcc" (TyCon "DeclEnvSeedAcc"))
(DFunDef false "emptyDeclEnvSeedAcc" () (ERecordCreate "DeclEnvSeedAcc" ((fa "dsKAcc" (EListLit)) (fa "dsOAcc" (EVar "omEmpty")) (fa "dsNAcc" (EVar "omEmpty")) (fa "dsKinds" (EApp (EApp (EApp (EVar "omInsert") (ELit (LString ""))) (EListLit)) (EVar "omEmpty"))) (fa "dsOwners" (EApp (EApp (EApp (EVar "omInsert") (ELit (LString ""))) (EVar "omEmpty")) (EVar "omEmpty"))) (fa "dsNames" (EApp (EApp (EApp (EVar "omInsert") (ELit (LString ""))) (EVar "omEmpty")) (EVar "omEmpty"))))))
(DTypeSig true "emptyDataEnv" (TyCon "DataEnv"))
(DFunDef false "emptyDataEnv" () (ERecordCreate "DataEnv" ((fa "deTypes" (EListLit)) (fa "deCtorIdents" (EVar "omEmpty")) (fa "deRecordIdents" (EVar "omEmpty")) (fa "deFieldOwnerIdents" (EVar "omEmpty")) (fa "deAliases" (EListLit)) (fa "deCtorExports" (EVar "omEmpty")))))
(DTypeSig true "emptyImplEnv" (TyCon "ImplEnv"))
(DFunDef false "emptyImplEnv" () (ERecordCreate "ImplEnv" ((fa "ieRows" (EListLit)) (fa "ieConcrete" (EVar "mregEmpty")) (fa "ieHeadless" (EVar "mregEmpty")) (fa "ieByHead" (EVar "mregEmpty")) (fa "ieUnivSnaps" (EListLit)))))
(DTypeSig true "emptyClassEnv" (TyCon "ClassEnv"))
(DFunDef false "emptyClassEnv" () (ERecordCreate "ClassEnv" ((fa "ceRows" (EListLit)) (fa "ceByKey" (EVar "regEmpty")))))
(DTypeSig true "emptyMethodEnv" (TyCon "MethodEnv"))
(DFunDef false "emptyMethodEnv" () (ERecordCreate "MethodEnv" ((fa "meByName" (EVar "omEmpty")) (fa "meExports" (EVar "omEmpty")) (fa "meIfaceExports" (EVar "omEmpty")))))
(DTypeSig false "emptyTcConfig" (TyCon "TcConfig"))
(DFunDef false "emptyTcConfig" () (ERecordCreate "TcConfig" ((fa "tcIoJoin" (EListLit)) (fa "tcIoJoinProfile" (ELit (LString ""))) (fa "tcStdlibOwned" (EVar "omEmpty")) (fa "tcFlatEntryIsStdlib" (EVar "False")) (fa "tcKey" (ELit (LString "\n\n"))))))
(DTypeSig true "initialGraphCtx" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Scheme")) (TyFun (TyCon "GraphRun") (TyCon "GraphCtx"))))
(DFunDef false "initialGraphCtx" ((PVar "ctors") (PVar "run")) (ERecordCreate "GraphCtx" ((fa "crossRun" (EApp (EVar "freshCrossRun") (EVar "ctors"))) (fa "graphRun" (EVar "run")) (fa "effectDomains" (EApp (EVar "Ref") (EListLit))) (fa "config" (EApp (EVar "Ref") (EVar "emptyTcConfig"))) (fa "trace" (EVar "None")) (fa "graphAdmittedMethodsRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "declEnvsRef" (EApp (EVar "Ref") (EVar "emptyDeclEnvs"))) (fa "abstractRecordTypesRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "argDispatchIdxByIdRef" (EApp (EVar "Ref") (EListLit))) (fa "dictEligibleRef" (EApp (EVar "Ref") (EListLit))) (fa "dictEligibleSetRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "mangledShadowMapRef" (EApp (EVar "Ref") (EListLit))) (fa "mangledFunDefsPresentRef" (EApp (EVar "Ref") (EVar "False"))) (fa "builtinExternNamesRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "promotionHarvestRef" (EApp (EVar "Ref") (EListLit))) (fa "mainSchemeRef" (EApp (EVar "Ref") (EVar "None"))) (fa "markSetsRef" (EApp (EVar "Ref") (EVar "None"))) (fa "typeErrorsSticky" (EApp (EVar "Ref") (EVar "False"))) (fa "typeErrorsStickyDiags" (EApp (EVar "Ref") (EListLit))))))
(DTypeSig true "interners" (TyApp (TyCon "Ref") (TyCon "Interners")))
(DFunDef false "interners" () (EApp (EVar "Ref") (EApp (EVar "internersOf") (EApp (EApp (EVar "initialGraphCtx") (EVar "builtinCtors")) (EApp (EVar "freshGraphRun") (ELit LUnit))))))
(DTypeSig true "internersOf" (TyFun (TyCon "GraphCtx") (TyCon "Interners")))
(DFunDef false "internersOf" ((PVar "c")) (ERecordCreate "Interners" ((fa "lineage" (ERecordCreate "Lineage" ((fa "lnEvCounter" (EFieldAccess (EFieldAccess (EVar "c") "graphRun") "evCounter")) (fa "lnLocalAbs" (EFieldAccess (EFieldAccess (EVar "c") "graphRun") "localAbs")) (fa "lnGrants" (EFieldAccess (EFieldAccess (EVar "c") "graphRun") "grants")) (fa "lnTyvarHigh" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "lnEffvarHigh" (EApp (EVar "Ref") (ELit (LInt 0))))))) (fa "externCatalog" (EFieldAccess (EVar "c") "builtinExternNamesRef")))))
(DTypeSig true "noteInterners" (TyFun (TyCon "GraphCtx") (TyCon "Unit")))
(DFunDef false "noteInterners" ((PVar "c")) (EBlock (DoLet false false (PVar "high") (EFieldAccess (EFieldAccess (EVar "interners") "value") "lineage")) (DoLet false false (PVar "next") (EApp (EVar "internersOf") (EVar "c"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "interners")) (EVariantUpdate "Interners" (EVar "next") ((fa "lineage" (EVariantUpdate "Lineage" (EFieldAccess (EVar "next") "lineage") ((fa "lnTyvarHigh" (EFieldAccess (EVar "high") "lnTyvarHigh")) (fa "lnEffvarHigh" (EFieldAccess (EVar "high") "lnEffvarHigh")))))))))))
(DTypeSig true "probeGraphCtx" (TyFun (TyCon "Unit") (TyCon "GraphCtx")))
(DFunDef false "probeGraphCtx" (PWild) (EApp (EApp (EVar "initialGraphCtx") (EVar "builtinCtors")) (EApp (EVar "freshGraphRun") (ELit LUnit))))
(DTypeSig true "freshSubRecordsOf" (TyFun (TyCon "GraphCtx") (TyCon "GraphCtx")))
(DFunDef false "freshSubRecordsOf" ((PVar "g")) (EVariantUpdate "GraphCtx" (EVar "g") ((fa "crossRun" (EApp (EVar "freshCrossRun") (EVar "builtinCtors"))) (fa "graphRun" (EApp (EVar "freshGraphRun") (ELit LUnit))))))
(DTypeSig false "wNew" (TyFun (TyCon "Unit") (TyApp (TyCon "Windowed") (TyVar "a"))))
(DFunDef false "wNew" (PWild) (ERecordCreate "Windowed" ((fa "items" (EApp (EVar "Ref") (EListLit))) (fa "n" (EApp (EVar "Ref") (ELit (LInt 0)))))))
(DTypeSig true "wPush" (TyFun (TyApp (TyCon "Windowed") (TyVar "a")) (TyFun (TyVar "a") (TyCon "Unit"))))
(DFunDef false "wPush" ((PVar "w") (PVar "x")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "w") "items")) (EBinOp "::" (EVar "x") (EUnOp "!" (EFieldAccess (EVar "w") "items"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "w") "n")) (EBinOp "+" (EUnOp "!" (EFieldAccess (EVar "w") "n")) (ELit (LInt 1)))))))
(DTypeSig true "wMark" (TyFun (TyApp (TyCon "Windowed") (TyVar "a")) (TyCon "Int")))
(DFunDef false "wMark" ((PVar "w")) (EUnOp "!" (EFieldAccess (EVar "w") "n")))
(DTypeSig true "wWindow" (TyFun (TyApp (TyCon "Windowed") (TyVar "a")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "wWindow" ((PVar "w") (PVar "mark")) (EApp (EApp (EVar "takeFirst") (EBinOp "-" (EUnOp "!" (EFieldAccess (EVar "w") "n")) (EVar "mark"))) (EUnOp "!" (EFieldAccess (EVar "w") "items"))))
(DTypeSig true "wAll" (TyFun (TyApp (TyCon "Windowed") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "wAll" ((PVar "w")) (EUnOp "!" (EFieldAccess (EVar "w") "items")))
(DTypeSig true "wSnapshot" (TyFun (TyApp (TyCon "Windowed") (TyVar "a")) (TyTuple (TyApp (TyCon "List") (TyVar "a")) (TyCon "Int"))))
(DFunDef false "wSnapshot" ((PVar "w")) (ETuple (EUnOp "!" (EFieldAccess (EVar "w") "items")) (EUnOp "!" (EFieldAccess (EVar "w") "n"))))
(DTypeSig true "wRestore" (TyFun (TyApp (TyCon "Windowed") (TyVar "a")) (TyFun (TyTuple (TyApp (TyCon "List") (TyVar "a")) (TyCon "Int")) (TyCon "Unit"))))
(DFunDef false "wRestore" ((PVar "w") (PVar "snap")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "w") "items")) (EApp (EVar "fst") (EVar "snap")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "w") "n")) (EApp (EVar "snd") (EVar "snap"))))))
(DTypeSig true "wPushAll" (TyFun (TyApp (TyCon "Windowed") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Unit"))))
(DFunDef false "wPushAll" (PWild (PList)) (ELit LUnit))
(DFunDef false "wPushAll" ((PVar "w") (PCons (PVar "x") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "wPush") (EVar "w")) (EVar "x"))) (DoExpr (EApp (EApp (EVar "wPushAll") (EVar "w")) (EVar "rest")))))
(DTypeSig true "emptyShadowDicts" (TyCon "ShadowDicts"))
(DFunDef false "emptyShadowDicts" () (ERecordCreate "ShadowDicts" ((fa "sdMonos" (EListLit)) (fa "sdIfaces" (EListLit)) (fa "sdArgVecs" (EListLit)))))
(DTypeSig false "freshCrossRun" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Scheme")) (TyCon "CrossRun")))
(DFunDef false "freshCrossRun" ((PVar "ctors")) (ERecordCreate "CrossRun" ((fa "universeFunNamesRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "universeMethodDispatchIdxByIdRef" (EApp (EVar "Ref") (EListLit))) (fa "universeDataCtors" (EApp (EVar "Ref") (EListLit))) (fa "universeCtorPop" (EApp (EVar "Ref") (EApp (EVar "spFromFloor") (EVar "ctors")))) (fa "universeRecordPop" (EApp (EVar "Ref") (EVar "spEmpty"))) (fa "builtinClassesRef" (EApp (EVar "Ref") (EVar "emptyBuiltinClasses"))) (fa "crossModuleFunPredicateSlotsRef" (EApp (EVar "Ref") (EListLit))) (fa "crossModuleFunPredicateSlotsQualRef" (EApp (EVar "Ref") (EListLit))) (fa "crossModuleFunConstraintDeclaredRef" (EApp (EVar "Ref") (EListLit))) (fa "crossModuleFunConstraintDeclaredQualRef" (EApp (EVar "Ref") (EListLit))) (fa "crossModuleMethodPredicateSlotsRef" (EApp (EVar "Ref") (EListLit))) (fa "crossModuleMethodPredicateSlotsQualRef" (EApp (EVar "Ref") (EListLit))) (fa "coreSchemeObligationsRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "crossModuleSchemeOblsQualRef" (EApp (EVar "Ref") (EListLit))))))
(DTypeSig true "mctxAt" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ModuleCtx") (TyCon "ModuleCtx"))))
(DFunDef false "mctxAt" ((PVar "loc") (PVar "mctx")) (EIf (EApp (EApp (EVar "sameSpan") (EVar "loc")) (EFieldAccess (EVar "mctx") "mcLoc")) (EVar "mctx") (ERecordUpdate (EVar "mctx") ((fa "mcLoc" (EVar "loc"))))))
(DTypeSig false "sameSpan" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Bool"))))
(DFunDef false "sameSpan" ((PCon "None") (PCon "None")) (EVar "True"))
(DFunDef false "sameSpan" ((PCon "Some" (PVar "a")) (PCon "Some" (PVar "b"))) (EApp (EApp (EVar "locEq") (EVar "a")) (EVar "b")))
(DFunDef false "sameSpan" ((PCon "None") (PCon "Some" PWild)) (EVar "False"))
(DFunDef false "sameSpan" ((PCon "Some" PWild) (PCon "None")) (EVar "False"))
(DTypeSig true "mctxAtIfSome" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ModuleCtx") (TyCon "ModuleCtx"))))
(DFunDef false "mctxAtIfSome" ((PCon "None") (PVar "mctx")) (EVar "mctx"))
(DFunDef false "mctxAtIfSome" ((PVar "loc") (PVar "mctx")) (EApp (EApp (EVar "mctxAt") (EVar "loc")) (EVar "mctx")))
(DTypeSig true "dynAt" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "DynCtx") (TyCon "DynCtx"))))
(DFunDef false "dynAt" ((PVar "loc") (PVar "dyn")) (EIf (EApp (EApp (EVar "sameSpan") (EVar "loc")) (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcLoc")) (EVar "dyn") (ERecordUpdate (EVar "dyn") ((fa "dcModule" (ERecordUpdate (EFieldAccess (EVar "dyn") "dcModule") ((fa "mcLoc" (EVar "loc")))))))))
(DTypeSig true "dynAtIfSome" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "DynCtx") (TyCon "DynCtx"))))
(DFunDef false "dynAtIfSome" ((PCon "None") (PVar "dyn")) (EVar "dyn"))
(DFunDef false "dynAtIfSome" ((PVar "loc") (PVar "dyn")) (EApp (EApp (EVar "dynAt") (EVar "loc")) (EVar "dyn")))
(DTypeSig true "envAt" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "TcEnv") (TyCon "TcEnv"))))
(DFunDef false "envAt" ((PVar "loc") (PVar "env")) (EIf (EApp (EApp (EVar "sameSpan") (EVar "loc")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EVar "env") (ERecordUpdate (EVar "env") ((fa "teDyn" (ERecordUpdate (EFieldAccess (EVar "env") "teDyn") ((fa "dcModule" (ERecordUpdate (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") ((fa "mcLoc" (EVar "loc"))))))))))))
(DTypeSig true "envAtIfSome" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "TcEnv") (TyCon "TcEnv"))))
(DFunDef false "envAtIfSome" ((PCon "None") (PVar "env")) (EVar "env"))
(DFunDef false "envAtIfSome" ((PVar "loc") (PVar "env")) (EApp (EApp (EVar "envAt") (EVar "loc")) (EVar "env")))
(DTypeSig true "renderEvidenceBinder" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvidenceBinderId") (TyCon "String"))))
(DFunDef false "renderEvidenceBinder" ((PVar "gctx") (PCon "EvidenceBinderId" (PVar "sid") (PVar "ordinal"))) (EMatch (EFieldAccess (EApp (EApp (EVar "Scopes.scopeFrame") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))) (EVar "sid")) "sfOwner") (arm (PCon "BindingOwner" (PVar "owner")) () (EApp (EApp (EVar "dictParamName") (EVar "owner")) (EVar "ordinal"))) (arm (PCon "LocalBindingOwner" (PVar "owner")) () (EApp (EApp (EVar "dictParamName") (EVar "owner")) (EVar "ordinal"))) (arm (PCon "DefaultBodyOwner" (PVar "owner")) () (EIf (EBinOp "==" (EVar "ordinal") (EVar "defaultReceiverOrdinal")) (EApp (EVar "defaultReceiverDict") (EFieldAccess (EVar "owner") "dbiMethod")) (EApp (EApp (EVar "dictParamName") (EFieldAccess (EVar "owner") "dbiMethod")) (EVar "ordinal")))) (arm PWild () (EApp (EVar "panic") (ELit (LString "evidence binder outside binding scope"))))))
(DTypeSig true "freshGraphRun" (TyFun (TyCon "Unit") (TyCon "GraphRun")))
(DFunDef false "freshGraphRun" (PWild) (ERecordCreate "GraphRun" ((fa "tyvarCounter" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "effvarCounter" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "ctorExistentialsRef" (EApp (EVar "Ref") (EVar "Tip"))) (fa "patternAuthIdsRef" (EApp (EVar "Ref") (EVar "Tip"))) (fa "anyExistentialsRef" (EApp (EVar "Ref") (EVar "False"))) (fa "goals" (EApp (EVar "Ref") (EListLit))) (fa "numlitRefs" (EApp (EVar "Ref") (EListLit))) (fa "numlitN" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "activeDictVars" (EApp (EVar "Ref") (EListLit))) (fa "gGiven" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "moduleRanges" (EApp (EVar "Ref") (EListLit))) (fa "stampCtxs" (EApp (EVar "Ref") (EListLit))) (fa "goalsN" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "evCounter" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "evBase" (ELit (LInt 0))) (fa "evJudged" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "evScopedJudged" (EApp (EVar "Ref") (EListLit))) (fa "evTable" (EApp (EVar "Ref") (EListLit))) (fa "evCells" (EApp (EVar "Ref") (EApp (EApp (EVar "arrayMake") (ELit (LInt 0))) (EVar "None")))) (fa "siteCells" (EApp (EVar "Ref") (EApp (EApp (EVar "arrayMake") (ELit (LInt 0))) (EVar "None")))) (fa "scopeStore" (EApp (EVar "Scopes.freshScopeStore") (ELit LUnit))) (fa "localAbs" (EApp (EVar "freshLocalAbsState") (ELit LUnit))) (fa "grants" (EApp (EVar "freshGrantState") (ELit LUnit))) (fa "binderPending" (EApp (EVar "Ref") (EListLit))) (fa "binderRows" (EApp (EVar "Ref") (EVar "emptyBinderTypes"))) (fa "liveRoots" (EApp (EVar "Ref") (EListLit))) (fa "liveNumRoots" (EApp (EVar "Ref") (EListLit))) (fa "liveNumGoals" (EApp (EVar "Ref") (EListLit))) (fa "liveGoals" (EApp (EVar "Ref") (EListLit))))))
(DTypeSig true "currentScopeStore" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyCon "ScopeStore"))))
(DFunDef false "currentScopeStore" ((PVar "gctx") PWild) (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "scopeStore"))
(DTypeSig true "graphLineageRun" (TyFun (TyCon "Lineage") (TyCon "GraphRun")))
(DFunDef false "graphLineageRun" ((PVar "lineage")) (EBlock (DoLet false false (PVar "n") (EFieldAccess (EFieldAccess (EVar "lineage") "lnEvCounter") "value")) (DoLet false false (PVar "base") (EVar "n")) (DoLet false false (PVar "localAbs") (EFieldAccess (EVar "lineage") "lnLocalAbs")) (DoLet false false (PVar "grants") (EFieldAccess (EVar "lineage") "lnGrants")) (DoLet false false (PVar "fresh") (EApp (EVar "freshGraphRun") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "fresh") "evCounter")) (EVar "n"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "fresh") "evJudged")) (EVar "base"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "localAbs") "lasQuantified")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "grants") "gsSourceless")) (EVar "Tip"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "grants") "gsBodies")) (EVar "Tip"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "grants") "gsBounds")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "grants") "gsValueBounds")) (EVar "omEmpty"))) (DoExpr (EVariantUpdate "GraphRun" (EVar "fresh") ((fa "localAbs" (EVar "localAbs")) (fa "grants" (EVar "grants")) (fa "evBase" (EVar "base")))))))
(DTypeSig true "freshModuleCtx" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "CheckRunSeed") (TyFun (TyCon "String") (TyCon "ModuleCtx")))))
(DFunDef false "freshModuleCtx" ((PVar "gctx") (PVar "seed") (PVar "mid")) (ERecordCreate "ModuleCtx" ((fa "mcCells" (EApp (EApp (EVar "freshModuleCells") (EVar "seed")) (EVar "mid"))) (fa "mcGraph" (EVar "gctx")) (fa "mcLoc" (EVar "None")))))
(DTypeSig false "freshModuleCells" (TyFun (TyCon "CheckRunSeed") (TyFun (TyCon "String") (TyCon "ModuleCells"))))
(DFunDef false "freshModuleCells" ((PVar "seed") (PVar "mid")) (ERecordCreate "ModuleCells" ((fa "currentScope" (EApp (EVar "Ref") (EVar "ScopeClosed"))) (fa "admittedOccObls" (EApp (EVar "Ref") (EListLit))) (fa "curEffect" (EApp (EVar "Ref") (EListLit))) (fa "effectSummaries" (EApp (EVar "EffectSolver.newSolver") (ELit LUnit))) (fa "pendingJoinsRef" (EApp (EVar "Ref") (EListLit))) (fa "fileValueFlows" (EApp (EVar "wNew") (ELit LUnit))) (fa "fileValueScopes" (EApp (EVar "Ref") (EListLit))) (fa "rigidEffvarsRef" (EApp (EVar "Ref") (EVar "Tip"))) (fa "rigidAuthvarsRef" (EApp (EVar "Ref") (EVar "Tip"))) (fa "effectSitesRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "rowFailureReportedRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "typeErrorKeySetRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "escapedExistentialsRef" (EApp (EVar "Ref") (EVar "Tip"))) (fa "openedAuthvarsRef" (EApp (EVar "Ref") (EVar "Tip"))) (fa "indexSubstitutedRef" (EApp (EVar "Ref") (EVar "Tip"))) (fa "extendedBindersRef" (EApp (EVar "Ref") (EVar "Tip"))) (fa "displayHiddenBindersRef" (EApp (EVar "Ref") (EVar "Tip"))) (fa "openedExistentialsRef" (EApp (EVar "Ref") (EListLit))) (fa "openedExistentialsStackRef" (EApp (EVar "Ref") (EListLit))) (fa "recordByNameRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "fieldOwnersRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "dataParamKindsRef" (EApp (EVar "Ref") (EListLit))) (fa "dataParamNameIndexRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "dataParamPolarityRef" (EApp (EVar "Ref") (EListLit))) (fa "dataParamRowAtomsRef" (EApp (EVar "Ref") (EListLit))) (fa "aliasTableRef" (EApp (EVar "Ref") (EListLit))) (fa "numLitFromIntAnchorRef" (EApp (EVar "Ref") (EVar "None"))) (fa "definerShadowNamesRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "definerShadowSigsRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "bodyImplEnvRef" (EApp (EVar "Ref") (EVar "emptyImplEnv"))) (fa "methodAliasEntriesRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "methodScopeCtxRef" (EApp (EVar "Ref") (EVar "None"))) (fa "methodScopeMemoRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "aliasMethodOriginsRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "implObls" (EApp (EVar "wNew") (ELit LUnit))) (fa "poisonedVars" (EApp (EVar "Ref") (EListLit))) (fa "deferrableVarIds" (EApp (EVar "Ref") (EVar "Tip"))) (fa "liveMemberMonosRef" (EApp (EVar "Ref") (EListLit))) (fa "quiescentGoalsRef" (EApp (EVar "Ref") (EListLit))) (fa "heldLiveGoalsRef" (EApp (EVar "Ref") (EListLit))) (fa "determinedRowsRef" (EApp (EVar "Ref") (EVar "Tip"))) (fa "declaredSigVarIds" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "tupleCallCandidates" (EApp (EVar "Ref") (EListLit))) (fa "numlitVarLocs" (EApp (EVar "Ref") (EListLit))) (fa "numlitRanges" (EApp (EVar "Ref") (EListLit))) (fa "wideLitRanges" (EApp (EVar "Ref") (EListLit))) (fa "patLitPending" (EApp (EVar "Ref") (EListLit))) (fa "patLitDeferred" (EApp (EVar "Ref") (EListLit))) (fa "matchChecksDeferred" (EApp (EVar "Ref") (EListLit))) (fa "numlitUntainted" (EApp (EVar "Ref") (EListLit))) (fa "numlitOpLocs" (EApp (EVar "Ref") (EListLit))) (fa "numlitCtxTags" (EApp (EVar "Ref") (EListLit))) (fa "localBindRefs" (EApp (EVar "Ref") (EListLit))) (fa "localSchemesOut" (EApp (EVar "Ref") (EListLit))) (fa "seedSchemesOut" (EApp (EVar "Ref") (EListLit))) (fa "funPredicateSlotsRef" (EApp (EVar "Ref") (EListLit))) (fa "funPredicateSlotsIdxRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "funConstraintDeclaredRef" (EApp (EVar "Ref") (EListLit))) (fa "currentImportDefinersRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "currentImportOriginsRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "importedSchemeOblsRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "obls" (EApp (EVar "wNew") (ELit LUnit))) (fa "absorptions" (EApp (EVar "wNew") (ELit LUnit))) (fa "schemeObligationsRef" (EApp (EVar "Ref") (EListLit))) (fa "schemeDefIdsRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "methodPredicateSlotsRef" (EApp (EVar "Ref") (EListLit))) (fa "currentFn" (EApp (EVar "Ref") (ELit (LString "")))) (fa "currentImplBody" (EApp (EVar "Ref") (EVar "False"))) (fa "methodSiteFns" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "dictAppFns" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "residualUnivRef" (EApp (EVar "Ref") (EVar "emptyImplUniverse"))) (fa "promotedRef" (EApp (EVar "Ref") (EListLit))) (fa "fieldOwnerModulesRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "fieldOwnerReachRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "typeErrors" (EApp (EVar "wNew") (ELit LUnit))) (fa "typeErrorMsgSetRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "ambiguitySitesRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "ambiguityVarsRef" (EApp (EVar "Ref") (EVar "Tip"))) (fa "errorsDetected" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "occursCheckFailed" (EApp (EVar "Ref") (EVar "False"))) (fa "currentLevel" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "markingRef" (EApp (EVar "Ref") (EVar "None"))) (fa "superDeclsRef" (EApp (EVar "Ref") (EListLit))) (fa "standaloneValuesRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "methodDispatchIdxByIdRef" (EApp (EVar "Ref") (EListLit))) (fa "matchOracle" (EApp (EVar "Ref") (EFieldAccess (EVar "seed") "crsOracle"))) (fa "matchWarnings" (EApp (EVar "Ref") (EFieldAccess (EVar "seed") "crsWarnings"))) (fa "sigNameSetRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "sigTyMapRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "currentModuleRef" (EApp (EVar "Ref") (EVar "mid"))) (fa "invocationViewRef" (EApp (EVar "Ref") (EApp (EApp (EApp (EVar "InvocationView") (EListLit)) (EListLit)) (EListLit)))) (fa "ownPopsRef" (EApp (EVar "Ref") (ETuple (EVar "spEmpty") (EVar "spEmpty")))))))
(DTypeSig true "initialModuleCtx" (TyFun (TyCon "GraphCtx") (TyCon "ModuleCtx")))
(DFunDef false "initialModuleCtx" ((PVar "gctx")) (EApp (EApp (EVar "blankModuleCtx") (EVar "gctx")) (ELit (LString ""))))
(DTypeSig true "blankModuleCtx" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyCon "ModuleCtx"))))
(DFunDef false "blankModuleCtx" ((PVar "gctx") (PVar "mid")) (EApp (EApp (EApp (EVar "freshModuleCtx") (EVar "gctx")) (ERecordCreate "CheckRunSeed" ((fa "crsOracle" (EVar "emptyOracle")) (fa "crsWarnings" (EListLit))))) (EVar "mid")))
(DTypeSig false "emptyOracle" (TyCon "Oracle"))
(DFunDef false "emptyOracle" () (EApp (EVar "buildOracle") (EListLit)))
(DTypeSig true "moduleCtxFrom" (TyFun (TyCon "Bool") (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ModuleCtx") (TyCon "ModuleCtx")))))))
(DFunDef false "moduleCtxFrom" ((PVar "detach") (PVar "run") (PVar "tables") (PVar "drain") (PVar "ident")) (ERecordCreate "ModuleCtx" ((fa "mcCells" (EApp (EApp (EApp (EApp (EApp (EVar "moduleCellsFrom") (EVar "detach")) (EFieldAccess (EVar "run") "mcCells")) (EFieldAccess (EVar "tables") "mcCells")) (EFieldAccess (EVar "drain") "mcCells")) (EFieldAccess (EVar "ident") "mcCells"))) (fa "mcGraph" (EFieldAccess (EVar "run") "mcGraph")) (fa "mcLoc" (EFieldAccess (EVar "run") "mcLoc")))))
(DTypeSig false "moduleCellsFrom" (TyFun (TyCon "Bool") (TyFun (TyCon "ModuleCells") (TyFun (TyCon "ModuleCells") (TyFun (TyCon "ModuleCells") (TyFun (TyCon "ModuleCells") (TyCon "ModuleCells")))))))
(DFunDef false "moduleCellsFrom" ((PVar "detach") (PVar "run") (PVar "tables") (PVar "drain") (PVar "ident")) (ERecordCreate "ModuleCells" ((fa "currentScope" (EFieldAccess (EVar "run") "currentScope")) (fa "admittedOccObls" (EFieldAccess (EVar "run") "admittedOccObls")) (fa "curEffect" (EFieldAccess (EVar "run") "curEffect")) (fa "effectSummaries" (EFieldAccess (EVar "run") "effectSummaries")) (fa "pendingJoinsRef" (EFieldAccess (EVar "run") "pendingJoinsRef")) (fa "fileValueFlows" (EFieldAccess (EVar "run") "fileValueFlows")) (fa "fileValueScopes" (EFieldAccess (EVar "run") "fileValueScopes")) (fa "rigidEffvarsRef" (EFieldAccess (EVar "run") "rigidEffvarsRef")) (fa "rigidAuthvarsRef" (EFieldAccess (EVar "run") "rigidAuthvarsRef")) (fa "effectSitesRef" (EFieldAccess (EVar "run") "effectSitesRef")) (fa "rowFailureReportedRef" (EFieldAccess (EVar "run") "rowFailureReportedRef")) (fa "typeErrorKeySetRef" (EFieldAccess (EVar "run") "typeErrorKeySetRef")) (fa "escapedExistentialsRef" (EFieldAccess (EVar "run") "escapedExistentialsRef")) (fa "openedAuthvarsRef" (EFieldAccess (EVar "run") "openedAuthvarsRef")) (fa "indexSubstitutedRef" (EFieldAccess (EVar "run") "indexSubstitutedRef")) (fa "extendedBindersRef" (EFieldAccess (EVar "run") "extendedBindersRef")) (fa "displayHiddenBindersRef" (EFieldAccess (EVar "run") "displayHiddenBindersRef")) (fa "openedExistentialsRef" (EFieldAccess (EVar "run") "openedExistentialsRef")) (fa "openedExistentialsStackRef" (EFieldAccess (EVar "run") "openedExistentialsStackRef")) (fa "recordByNameRef" (EFieldAccess (EVar "run") "recordByNameRef")) (fa "fieldOwnersRef" (EFieldAccess (EVar "run") "fieldOwnersRef")) (fa "dataParamKindsRef" (EFieldAccess (EVar "run") "dataParamKindsRef")) (fa "dataParamNameIndexRef" (EFieldAccess (EVar "run") "dataParamNameIndexRef")) (fa "dataParamPolarityRef" (EFieldAccess (EVar "run") "dataParamPolarityRef")) (fa "dataParamRowAtomsRef" (EFieldAccess (EVar "run") "dataParamRowAtomsRef")) (fa "aliasTableRef" (EFieldAccess (EVar "run") "aliasTableRef")) (fa "numLitFromIntAnchorRef" (EFieldAccess (EVar "run") "numLitFromIntAnchorRef")) (fa "definerShadowNamesRef" (EFieldAccess (EVar "run") "definerShadowNamesRef")) (fa "definerShadowSigsRef" (EFieldAccess (EVar "run") "definerShadowSigsRef")) (fa "bodyImplEnvRef" (EFieldAccess (EVar "run") "bodyImplEnvRef")) (fa "methodAliasEntriesRef" (EFieldAccess (EVar "run") "methodAliasEntriesRef")) (fa "methodScopeCtxRef" (EFieldAccess (EVar "run") "methodScopeCtxRef")) (fa "methodScopeMemoRef" (EFieldAccess (EVar "run") "methodScopeMemoRef")) (fa "aliasMethodOriginsRef" (EFieldAccess (EVar "run") "aliasMethodOriginsRef")) (fa "implObls" (EFieldAccess (EVar "run") "implObls")) (fa "poisonedVars" (EFieldAccess (EVar "run") "poisonedVars")) (fa "deferrableVarIds" (EFieldAccess (EVar "run") "deferrableVarIds")) (fa "liveMemberMonosRef" (EFieldAccess (EVar "run") "liveMemberMonosRef")) (fa "quiescentGoalsRef" (EFieldAccess (EVar "run") "quiescentGoalsRef")) (fa "heldLiveGoalsRef" (EFieldAccess (EVar "run") "heldLiveGoalsRef")) (fa "determinedRowsRef" (EFieldAccess (EVar "run") "determinedRowsRef")) (fa "declaredSigVarIds" (EFieldAccess (EVar "run") "declaredSigVarIds")) (fa "tupleCallCandidates" (EFieldAccess (EVar "run") "tupleCallCandidates")) (fa "numlitVarLocs" (EFieldAccess (EVar "run") "numlitVarLocs")) (fa "patLitPending" (EFieldAccess (EVar "run") "patLitPending")) (fa "patLitDeferred" (EFieldAccess (EVar "run") "patLitDeferred")) (fa "matchChecksDeferred" (EFieldAccess (EVar "run") "matchChecksDeferred")) (fa "numlitRanges" (EFieldAccess (EVar "run") "numlitRanges")) (fa "wideLitRanges" (EFieldAccess (EVar "run") "wideLitRanges")) (fa "numlitUntainted" (EFieldAccess (EVar "run") "numlitUntainted")) (fa "numlitOpLocs" (EFieldAccess (EVar "run") "numlitOpLocs")) (fa "numlitCtxTags" (EFieldAccess (EVar "run") "numlitCtxTags")) (fa "localBindRefs" (EFieldAccess (EVar "run") "localBindRefs")) (fa "localSchemesOut" (EFieldAccess (EVar "run") "localSchemesOut")) (fa "seedSchemesOut" (EFieldAccess (EVar "run") "seedSchemesOut")) (fa "funPredicateSlotsRef" (EFieldAccess (EVar "run") "funPredicateSlotsRef")) (fa "funPredicateSlotsIdxRef" (EFieldAccess (EVar "run") "funPredicateSlotsIdxRef")) (fa "funConstraintDeclaredRef" (EFieldAccess (EVar "run") "funConstraintDeclaredRef")) (fa "currentImportDefinersRef" (EFieldAccess (EVar "run") "currentImportDefinersRef")) (fa "currentImportOriginsRef" (EFieldAccess (EVar "run") "currentImportOriginsRef")) (fa "importedSchemeOblsRef" (EFieldAccess (EVar "run") "importedSchemeOblsRef")) (fa "obls" (EFieldAccess (EVar "run") "obls")) (fa "absorptions" (EFieldAccess (EVar "run") "absorptions")) (fa "schemeObligationsRef" (EFieldAccess (EVar "run") "schemeObligationsRef")) (fa "schemeDefIdsRef" (EFieldAccess (EVar "run") "schemeDefIdsRef")) (fa "methodPredicateSlotsRef" (EFieldAccess (EVar "run") "methodPredicateSlotsRef")) (fa "currentFn" (EFieldAccess (EVar "run") "currentFn")) (fa "currentImplBody" (EFieldAccess (EVar "run") "currentImplBody")) (fa "methodSiteFns" (EFieldAccess (EVar "run") "methodSiteFns")) (fa "dictAppFns" (EFieldAccess (EVar "run") "dictAppFns")) (fa "residualUnivRef" (EFieldAccess (EVar "run") "residualUnivRef")) (fa "promotedRef" (EFieldAccess (EVar "run") "promotedRef")) (fa "fieldOwnerModulesRef" (EFieldAccess (EVar "run") "fieldOwnerModulesRef")) (fa "fieldOwnerReachRef" (EFieldAccess (EVar "run") "fieldOwnerReachRef")) (fa "typeErrors" (EFieldAccess (EVar "run") "typeErrors")) (fa "typeErrorMsgSetRef" (EFieldAccess (EVar "run") "typeErrorMsgSetRef")) (fa "ambiguitySitesRef" (EFieldAccess (EVar "run") "ambiguitySitesRef")) (fa "ambiguityVarsRef" (EFieldAccess (EVar "run") "ambiguityVarsRef")) (fa "errorsDetected" (EFieldAccess (EVar "run") "errorsDetected")) (fa "occursCheckFailed" (EFieldAccess (EVar "run") "occursCheckFailed")) (fa "currentLevel" (EFieldAccess (EVar "run") "currentLevel")) (fa "markingRef" (EFieldAccess (EVar "run") "markingRef")) (fa "ownPopsRef" (EFieldAccess (EVar "run") "ownPopsRef")) (fa "superDeclsRef" (EApp (EApp (EVar "refFrom") (EVar "detach")) (EFieldAccess (EVar "tables") "superDeclsRef"))) (fa "sigNameSetRef" (EApp (EApp (EVar "refFrom") (EVar "detach")) (EFieldAccess (EVar "tables") "sigNameSetRef"))) (fa "sigTyMapRef" (EApp (EApp (EVar "refFrom") (EVar "detach")) (EFieldAccess (EVar "tables") "sigTyMapRef"))) (fa "matchOracle" (EApp (EApp (EVar "refFrom") (EVar "detach")) (EFieldAccess (EVar "tables") "matchOracle"))) (fa "matchWarnings" (EApp (EApp (EVar "refFrom") (EVar "detach")) (EFieldAccess (EVar "tables") "matchWarnings"))) (fa "standaloneValuesRef" (EApp (EApp (EVar "refFrom") (EVar "detach")) (EFieldAccess (EVar "drain") "standaloneValuesRef"))) (fa "methodDispatchIdxByIdRef" (EApp (EApp (EVar "refFrom") (EVar "detach")) (EFieldAccess (EVar "drain") "methodDispatchIdxByIdRef"))) (fa "currentModuleRef" (EApp (EApp (EVar "refFrom") (EVar "detach")) (EFieldAccess (EVar "ident") "currentModuleRef"))) (fa "invocationViewRef" (EApp (EApp (EVar "refFrom") (EVar "detach")) (EFieldAccess (EVar "ident") "invocationViewRef"))))))
(DTypeSig false "refFrom" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Ref") (TyVar "a")) (TyApp (TyCon "Ref") (TyVar "a")))))
(DFunDef false "refFrom" ((PVar "detach") (PVar "r")) (EIf (EVar "detach") (EApp (EVar "Ref") (EFieldAccess (EVar "r") "value")) (EVar "r")))
(DTypeSig true "carryModuleCtx" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ModuleCtx") (TyCon "ModuleCtx"))))
(DFunDef false "carryModuleCtx" ((PVar "gctx") (PVar "m")) (EApp (EApp (EApp (EApp (EApp (EVar "moduleCtxFrom") (EVar "True")) (EApp (EVar "initialModuleCtx") (EVar "gctx"))) (EVar "m")) (EVar "m")) (EVar "m")))
(DTypeSig true "emptySigVars" (TyCon "SigVars"))
(DFunDef false "emptySigVars" () (ERecordCreate "SigVars" ((fa "svRows" (EListLit)) (fa "svAuths" (EListLit)))))
(DTypeSig false "freshLocalAbsState" (TyFun (TyCon "Unit") (TyCon "LocalAbsState")))
(DFunDef false "freshLocalAbsState" (PWild) (ERecordCreate "LocalAbsState" ((fa "lasBinders" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "lasRecOccs" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "lasNext" (EApp (EVar "Ref") (ETuple (ELit (LString "")) (ELit (LInt 0))))) (fa "lasMinted" (EApp (EVar "Ref") (EListLit))) (fa "lasQuantified" (EApp (EVar "Ref") (EVar "omEmpty"))))))
(DTypeSig false "freshGrantState" (TyFun (TyCon "Unit") (TyCon "GrantState")))
(DFunDef false "freshGrantState" (PWild) (ERecordCreate "GrantState" ((fa "gsOccs" (EApp (EVar "Ref") (EVar "Tip"))) (fa "gsGrantOnly" (EApp (EVar "Ref") (EVar "Tip"))) (fa "gsTopIds" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "gsLocalIds" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "gsMethods" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "gsBodies" (EApp (EVar "Ref") (EVar "Tip"))) (fa "gsLastInst" (EApp (EVar "Ref") (EVar "None"))) (fa "gsLastMethodInst" (EApp (EVar "Ref") (EVar "None"))) (fa "gsLastStandalone" (EApp (EVar "Ref") (EVar "None"))) (fa "gsSourceless" (EApp (EVar "Ref") (EVar "Tip"))) (fa "gsTakers" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "gsFresh" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "gsBounds" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "gsValueBounds" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "gsPassingModule" (EApp (EVar "Ref") (ELit (LString "")))))))
(DTypeSig true "emptyBuiltinClasses" (TyCon "BuiltinClasses"))
(DFunDef false "emptyBuiltinClasses" () (ERecordCreate "BuiltinClasses" ((fa "bcNum" (EVar "OriginUnresolved")) (fa "bcEq" (EVar "OriginUnresolved")) (fa "bcOrd" (EVar "OriginUnresolved")) (fa "bcSemigroup" (EVar "OriginUnresolved")) (fa "bcNumPresent" (EVar "False")) (fa "bcEqPresent" (EVar "False")) (fa "bcOrdPresent" (EVar "False")) (fa "bcSemigroupPresent" (EVar "False")) (fa "bcPreludeSeeded" (EVar "False")))))
(DTypeSig true "takeFirst" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "takeFirst" ((PVar "n") PWild) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "takeFirst" (PWild (PList)) (EListLit))
(DFunDef false "takeFirst" ((PVar "n") (PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "takeFirst") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "xs"))))
(DTypeSig true "dictParamName" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "dictParamName" ((PVar "fn") (PVar "slot")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "$dict_")) (EApp (EVar "display") (EVar "fn"))) (ELit (LString "_"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "slot")))) (ELit (LString ""))))
(DTypeSig true "defaultReceiverOrdinal" (TyCon "Int"))
(DFunDef false "defaultReceiverOrdinal" () (EUnOp "-" (ELit (LInt 1))))
(DTypeSig true "emptyImplUniverse" (TyCon "ImplUniverse"))
(DFunDef false "emptyImplUniverse" () (EApp (EApp (EVar "ImplUniverse") (EVar "mregEmpty")) (EVar "mregEmpty")))
(DTypeSig true "builtinCtors" (TyApp (TyCon "OrdMap") (TyCon "Scheme")))
(DFunDef false "builtinCtors" () (EApp (EApp (EApp (EVar "omInsert") (ELit (LString "True"))) (EApp (EVar "monoScheme") (EApp (EVar "tconBuiltin") (ELit (LString "Bool"))))) (EApp (EApp (EApp (EVar "omInsert") (ELit (LString "False"))) (EApp (EVar "monoScheme") (EApp (EVar "tconBuiltin") (ELit (LString "Bool"))))) (EVar "omEmpty"))))
(DTypeSig true "mintGraphCtx" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyCon "GraphCtx"))))
(DFunDef false "mintGraphCtx" ((PVar "inputs") (PVar "admitted")) (EBlock (DoLet false false (PVar "carried") (EFieldAccess (EVar "interners") "value")) (DoLet false false (PVar "base") (EApp (EApp (EVar "initialGraphCtx") (EVar "builtinCtors")) (EApp (EVar "graphLineageRun") (EFieldAccess (EVar "carried") "lineage")))) (DoLet false false (PVar "gctx") (EVariantUpdate "GraphCtx" (EVar "base") ((fa "trace" (EFieldAccess (EVar "inputs") "diTrace")) (fa "graphAdmittedMethodsRef" (EApp (EVar "Ref") (EVar "admitted"))) (fa "builtinExternNamesRef" (EFieldAccess (EVar "carried") "externCatalog"))))) (DoExpr (EApp (EVar "noteInterners") (EVar "gctx"))) (DoExpr (EVar "gctx"))))
(DTypeSig false "offTraceSink" (TyFun (TyCon "Unit") (TyCon "TraceSink")))
(DFunDef false "offTraceSink" (PWild) (ERecordCreate "TraceSink" ((fa "tsAssumptionEnabled" (EVar "False")) (fa "tsAssumptionEntries" (EApp (EVar "Ref") (EListLit))) (fa "tsNumericPredicateEnabled" (EVar "False")) (fa "tsNumericPredicateEntries" (EApp (EVar "Ref") (EListLit))) (fa "tsMethodReturnEnabled" (EVar "False")) (fa "tsMethodReturnEntries" (EApp (EVar "Ref") (EListLit))) (fa "tsEvidenceObservationEnabled" (EVar "False")) (fa "tsEvidenceObservationEntries" (EApp (EVar "Ref") (EListLit))))))
(DTypeSig true "beginAssumptionTrace" (TyFun (TyCon "Unit") (TyCon "TraceSink")))
(DFunDef false "beginAssumptionTrace" (PWild) (ERecordUpdate (EApp (EVar "offTraceSink") (ELit LUnit)) ((fa "tsAssumptionEnabled" (EVar "True")))))
(DTypeSig true "finishAssumptionTrace" (TyFun (TyCon "TraceSink") (TyApp (TyCon "List") (TyCon "AssumptionTraceEntry"))))
(DFunDef false "finishAssumptionTrace" ((PVar "sink")) (EApp (EVar "reverseL") (EFieldAccess (EFieldAccess (EVar "sink") "tsAssumptionEntries") "value")))
(DTypeSig true "beginNumericPredicateTrace" (TyFun (TyCon "Unit") (TyCon "TraceSink")))
(DFunDef false "beginNumericPredicateTrace" (PWild) (ERecordUpdate (EApp (EVar "offTraceSink") (ELit LUnit)) ((fa "tsNumericPredicateEnabled" (EVar "True")))))
(DTypeSig true "finishNumericPredicateTrace" (TyFun (TyCon "TraceSink") (TyApp (TyCon "List") (TyCon "NumericPredicateTraceEntry"))))
(DFunDef false "finishNumericPredicateTrace" ((PVar "sink")) (EApp (EVar "reverseL") (EFieldAccess (EFieldAccess (EVar "sink") "tsNumericPredicateEntries") "value")))
(DTypeSig true "beginMethodReturnTrace" (TyFun (TyCon "Unit") (TyCon "TraceSink")))
(DFunDef false "beginMethodReturnTrace" (PWild) (ERecordUpdate (EApp (EVar "offTraceSink") (ELit LUnit)) ((fa "tsMethodReturnEnabled" (EVar "True")))))
(DTypeSig true "beginEvidenceObservation" (TyFun (TyCon "Unit") (TyCon "TraceSink")))
(DFunDef false "beginEvidenceObservation" (PWild) (ERecordUpdate (EApp (EVar "offTraceSink") (ELit LUnit)) ((fa "tsEvidenceObservationEnabled" (EVar "True")))))
(DTypeSig true "finishEvidenceObservation" (TyFun (TyCon "TraceSink") (TyApp (TyCon "List") (TyCon "EvidenceObservationEntry"))))
(DFunDef false "finishEvidenceObservation" ((PVar "sink")) (EApp (EVar "reverseL") (EFieldAccess (EFieldAccess (EVar "sink") "tsEvidenceObservationEntries") "value")))
(DTypeSig true "evCellsSpanProbe" (TyFun (TyCon "GraphCtx") (TyCon "Int")))
(DFunDef false "evCellsSpanProbe" ((PVar "gctx")) (EApp (EVar "arrayLength") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "evCells") "value")))
(DTypeSig true "scopeTraceContext" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ScopeId") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "scopeTraceContext" ((PVar "gctx") (PVar "sid")) (EApp (EApp (EVar "Scopes.scopeTraceContext") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))) (EVar "sid")))
(DTypeSig true "scopeFrameStats" (TyFun (TyCon "GraphCtx") (TyTuple (TyCon "Int") (TyCon "Int"))))
(DFunDef false "scopeFrameStats" ((PVar "gctx")) (EApp (EVar "Scopes.scopeFrameStats") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))))
(DTypeSig false "defaultBodyBinderNamesProbe" (TyFun (TyCon "Unit") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "defaultBodyBinderNamesProbe" (PWild) (EBlock (DoLet false false (PVar "gctx") (EApp (EVar "probeGraphCtx") (ELit LUnit))) (DoLet false false (PVar "iface") (ERecordCreate "IfaceRef" ((fa "irName" (ELit (LString "Supply"))) (fa "irOrigin" (EApp (EVar "OriginModule") (ELit (LString "owner-module"))))))) (DoLet false false (PVar "owner") (ERecordCreate "DefaultBodyIdentity" ((fa "dbiIface" (EVar "iface")) (fa "dbiMethod" (ELit (LString "copy")))))) (DoLet false false (PVar "store") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))) (DoLet false false (PVar "root") (EApp (EApp (EApp (EApp (EApp (EVar "Scopes.freshScope") (EVar "store")) (EVar "None")) (ELit (LInt 0))) (ELit (LString "owner-module"))) (EVar "ModuleOwner"))) (DoLet false false (PVar "body") (EApp (EApp (EApp (EApp (EApp (EVar "Scopes.freshScope") (EVar "store")) (EApp (EVar "Some") (EVar "root"))) (ELit (LInt 1))) (ELit (LString "owner-module"))) (EApp (EVar "DefaultBodyOwner") (EVar "owner")))) (DoLet false false (PVar "rendered") (EListLit (EApp (EApp (EVar "renderEvidenceBinder") (EVar "gctx")) (EApp (EApp (EVar "Scopes.binderAt") (EVar "body")) (ELit (LInt 0)))) (EApp (EApp (EVar "renderEvidenceBinder") (EVar "gctx")) (EApp (EApp (EVar "Scopes.binderAt") (EVar "body")) (ELit (LInt 1)))) (EApp (EApp (EVar "renderEvidenceBinder") (EVar "gctx")) (EApp (EApp (EVar "Scopes.binderAt") (EVar "body")) (EVar "defaultReceiverOrdinal"))))) (DoExpr (EVar "rendered"))))
# MARK
(DUse false (UseGroup ("types" "tc_mono") ((mem "locEq" false) (mem "monoScheme" false) (mem "tconBuiltin" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Loc" true) (mem "TyConOrigin" true) (mem "defaultReceiverDict" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Scheme" true))))
(DUse false (UseAlias ("types" "effect_solver") "EffectSolver"))
(DUse false (UseGroup ("types" "tc_types") ((mem "AbsorptionEvent" true) (mem "AssumptionTraceEntry" true) (mem "BuiltinClasses" true) (mem "CheckRunSeed" true) (mem "ClassEnv" true) (mem "CrossRun" true) (mem "DataEnv" true) (mem "DeclEnvs" true) (mem "DeclEnvSeedAcc" true) (mem "DriveInputs" true) (mem "DynCtx" true) (mem "EvidenceObservationEntry" true) (mem "GrantState" true) (mem "GraphCtx" true) (mem "GraphRun" true) (mem "ImplEnv" true) (mem "ImplUniverse" true) (mem "Interners" true) (mem "InvocationView" true) (mem "Lineage" true) (mem "LocalAbsState" true) (mem "MethodEnv" true) (mem "ModuleCells" true) (mem "ModuleCtx" true) (mem "NumericPredicateTraceEntry" true) (mem "Predicate" true) (mem "ShadowDicts" true) (mem "SigVars" true) (mem "TcConfig" true) (mem "TcEnv" true) (mem "TraceSink" true) (mem "UObligation" true) (mem "Windowed" true))))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("types" "evidence") ((mem "EvidenceBinderId" true) (mem "ScopeId" true))))
(DUse false (UseGroup ("types" "scopes") ((mem "DefaultBodyIdentity" true) (mem "ScopeCursor" true) (mem "ScopeOwner" true) (mem "ScopeStore" false))))
(DUse false (UseAlias ("types" "scopes") "Scopes"))
(DUse false (UseGroup ("types" "solver_contract") ((mem "Instantiation" true))))
(DUse false (UseGroup ("types" "registry") ((mem "regEmpty" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "buildOracle" false) (mem "Oracle" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omInsert" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false))))
(DUse false (UseGroup ("types" "registry") ((mem "mregEmpty" false) (mem "regEmpty" false) (mem "spEmpty" false) (mem "spFromFloor" false))))
(DUse false (UseGroup ("types" "disposition") ((mem "MethodDisposition" true))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "emptyBinderTypes" false))))
(DTypeSig false "emptyDeclEnvs" (TyCon "DeclEnvs"))
(DFunDef false "emptyDeclEnvs" () (ERecordCreate "DeclEnvs" ((fa "deModules" (EListLit)) (fa "deOrdIndex" (EVar "omEmpty")) (fa "deDefiners" (EVar "omEmpty")) (fa "deAmbigValues" (EVar "omEmpty")) (fa "deAllDecls" (EListLit)) (fa "deData" (EVar "emptyDataEnv")) (fa "deImpls" (EVar "emptyImplEnv")) (fa "deIfaces" (EVar "emptyClassEnv")) (fa "deMethods" (EVar "emptyMethodEnv")) (fa "deKindsBefore" (EVar "omEmpty")) (fa "deNameIndexBefore" (EVar "omEmpty")) (fa "dePolaritiesBefore" (EVar "omEmpty")) (fa "deAtomsBefore" (EVar "omEmpty")) (fa "deOwnersBefore" (EVar "omEmpty")) (fa "deOwnerModules" (EVar "omEmpty")) (fa "deReach" (EVar "omEmpty")))))
(DTypeSig true "emptyDeclEnvSeedAcc" (TyCon "DeclEnvSeedAcc"))
(DFunDef false "emptyDeclEnvSeedAcc" () (ERecordCreate "DeclEnvSeedAcc" ((fa "dsKAcc" (EListLit)) (fa "dsOAcc" (EVar "omEmpty")) (fa "dsNAcc" (EVar "omEmpty")) (fa "dsKinds" (EApp (EApp (EApp (EVar "omInsert") (ELit (LString ""))) (EListLit)) (EVar "omEmpty"))) (fa "dsOwners" (EApp (EApp (EApp (EVar "omInsert") (ELit (LString ""))) (EVar "omEmpty")) (EVar "omEmpty"))) (fa "dsNames" (EApp (EApp (EApp (EVar "omInsert") (ELit (LString ""))) (EVar "omEmpty")) (EVar "omEmpty"))))))
(DTypeSig true "emptyDataEnv" (TyCon "DataEnv"))
(DFunDef false "emptyDataEnv" () (ERecordCreate "DataEnv" ((fa "deTypes" (EListLit)) (fa "deCtorIdents" (EVar "omEmpty")) (fa "deRecordIdents" (EVar "omEmpty")) (fa "deFieldOwnerIdents" (EVar "omEmpty")) (fa "deAliases" (EListLit)) (fa "deCtorExports" (EVar "omEmpty")))))
(DTypeSig true "emptyImplEnv" (TyCon "ImplEnv"))
(DFunDef false "emptyImplEnv" () (ERecordCreate "ImplEnv" ((fa "ieRows" (EListLit)) (fa "ieConcrete" (EVar "mregEmpty")) (fa "ieHeadless" (EVar "mregEmpty")) (fa "ieByHead" (EVar "mregEmpty")) (fa "ieUnivSnaps" (EListLit)))))
(DTypeSig true "emptyClassEnv" (TyCon "ClassEnv"))
(DFunDef false "emptyClassEnv" () (ERecordCreate "ClassEnv" ((fa "ceRows" (EListLit)) (fa "ceByKey" (EVar "regEmpty")))))
(DTypeSig true "emptyMethodEnv" (TyCon "MethodEnv"))
(DFunDef false "emptyMethodEnv" () (ERecordCreate "MethodEnv" ((fa "meByName" (EVar "omEmpty")) (fa "meExports" (EVar "omEmpty")) (fa "meIfaceExports" (EVar "omEmpty")))))
(DTypeSig false "emptyTcConfig" (TyCon "TcConfig"))
(DFunDef false "emptyTcConfig" () (ERecordCreate "TcConfig" ((fa "tcIoJoin" (EListLit)) (fa "tcIoJoinProfile" (ELit (LString ""))) (fa "tcStdlibOwned" (EVar "omEmpty")) (fa "tcFlatEntryIsStdlib" (EVar "False")) (fa "tcKey" (ELit (LString "\n\n"))))))
(DTypeSig true "initialGraphCtx" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Scheme")) (TyFun (TyCon "GraphRun") (TyCon "GraphCtx"))))
(DFunDef false "initialGraphCtx" ((PVar "ctors") (PVar "run")) (ERecordCreate "GraphCtx" ((fa "crossRun" (EApp (EVar "freshCrossRun") (EVar "ctors"))) (fa "graphRun" (EVar "run")) (fa "effectDomains" (EApp (EVar "Ref") (EListLit))) (fa "config" (EApp (EVar "Ref") (EVar "emptyTcConfig"))) (fa "trace" (EVar "None")) (fa "graphAdmittedMethodsRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "declEnvsRef" (EApp (EVar "Ref") (EVar "emptyDeclEnvs"))) (fa "abstractRecordTypesRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "argDispatchIdxByIdRef" (EApp (EVar "Ref") (EListLit))) (fa "dictEligibleRef" (EApp (EVar "Ref") (EListLit))) (fa "dictEligibleSetRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "mangledShadowMapRef" (EApp (EVar "Ref") (EListLit))) (fa "mangledFunDefsPresentRef" (EApp (EVar "Ref") (EVar "False"))) (fa "builtinExternNamesRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "promotionHarvestRef" (EApp (EVar "Ref") (EListLit))) (fa "mainSchemeRef" (EApp (EVar "Ref") (EVar "None"))) (fa "markSetsRef" (EApp (EVar "Ref") (EVar "None"))) (fa "typeErrorsSticky" (EApp (EVar "Ref") (EVar "False"))) (fa "typeErrorsStickyDiags" (EApp (EVar "Ref") (EListLit))))))
(DTypeSig true "interners" (TyApp (TyCon "Ref") (TyCon "Interners")))
(DFunDef false "interners" () (EApp (EVar "Ref") (EApp (EVar "internersOf") (EApp (EApp (EVar "initialGraphCtx") (EVar "builtinCtors")) (EApp (EVar "freshGraphRun") (ELit LUnit))))))
(DTypeSig true "internersOf" (TyFun (TyCon "GraphCtx") (TyCon "Interners")))
(DFunDef false "internersOf" ((PVar "c")) (ERecordCreate "Interners" ((fa "lineage" (ERecordCreate "Lineage" ((fa "lnEvCounter" (EFieldAccess (EFieldAccess (EVar "c") "graphRun") "evCounter")) (fa "lnLocalAbs" (EFieldAccess (EFieldAccess (EVar "c") "graphRun") "localAbs")) (fa "lnGrants" (EFieldAccess (EFieldAccess (EVar "c") "graphRun") "grants")) (fa "lnTyvarHigh" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "lnEffvarHigh" (EApp (EVar "Ref") (ELit (LInt 0))))))) (fa "externCatalog" (EFieldAccess (EVar "c") "builtinExternNamesRef")))))
(DTypeSig true "noteInterners" (TyFun (TyCon "GraphCtx") (TyCon "Unit")))
(DFunDef false "noteInterners" ((PVar "c")) (EBlock (DoLet false false (PVar "high") (EFieldAccess (EFieldAccess (EVar "interners") "value") "lineage")) (DoLet false false (PVar "next") (EApp (EVar "internersOf") (EVar "c"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "interners")) (EVariantUpdate "Interners" (EVar "next") ((fa "lineage" (EVariantUpdate "Lineage" (EFieldAccess (EVar "next") "lineage") ((fa "lnTyvarHigh" (EFieldAccess (EVar "high") "lnTyvarHigh")) (fa "lnEffvarHigh" (EFieldAccess (EVar "high") "lnEffvarHigh")))))))))))
(DTypeSig true "probeGraphCtx" (TyFun (TyCon "Unit") (TyCon "GraphCtx")))
(DFunDef false "probeGraphCtx" (PWild) (EApp (EApp (EVar "initialGraphCtx") (EVar "builtinCtors")) (EApp (EVar "freshGraphRun") (ELit LUnit))))
(DTypeSig true "freshSubRecordsOf" (TyFun (TyCon "GraphCtx") (TyCon "GraphCtx")))
(DFunDef false "freshSubRecordsOf" ((PVar "g")) (EVariantUpdate "GraphCtx" (EVar "g") ((fa "crossRun" (EApp (EVar "freshCrossRun") (EVar "builtinCtors"))) (fa "graphRun" (EApp (EVar "freshGraphRun") (ELit LUnit))))))
(DTypeSig false "wNew" (TyFun (TyCon "Unit") (TyApp (TyCon "Windowed") (TyVar "a"))))
(DFunDef false "wNew" (PWild) (ERecordCreate "Windowed" ((fa "items" (EApp (EVar "Ref") (EListLit))) (fa "n" (EApp (EVar "Ref") (ELit (LInt 0)))))))
(DTypeSig true "wPush" (TyFun (TyApp (TyCon "Windowed") (TyVar "a")) (TyFun (TyVar "a") (TyCon "Unit"))))
(DFunDef false "wPush" ((PVar "w") (PVar "x")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "w") "items")) (EBinOp "::" (EVar "x") (EUnOp "!" (EFieldAccess (EVar "w") "items"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "w") "n")) (EBinOp "+" (EUnOp "!" (EFieldAccess (EVar "w") "n")) (ELit (LInt 1)))))))
(DTypeSig true "wMark" (TyFun (TyApp (TyCon "Windowed") (TyVar "a")) (TyCon "Int")))
(DFunDef false "wMark" ((PVar "w")) (EUnOp "!" (EFieldAccess (EVar "w") "n")))
(DTypeSig true "wWindow" (TyFun (TyApp (TyCon "Windowed") (TyVar "a")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "wWindow" ((PVar "w") (PVar "mark")) (EApp (EApp (EVar "takeFirst") (EBinOp "-" (EUnOp "!" (EFieldAccess (EVar "w") "n")) (EVar "mark"))) (EUnOp "!" (EFieldAccess (EVar "w") "items"))))
(DTypeSig true "wAll" (TyFun (TyApp (TyCon "Windowed") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "wAll" ((PVar "w")) (EUnOp "!" (EFieldAccess (EVar "w") "items")))
(DTypeSig true "wSnapshot" (TyFun (TyApp (TyCon "Windowed") (TyVar "a")) (TyTuple (TyApp (TyCon "List") (TyVar "a")) (TyCon "Int"))))
(DFunDef false "wSnapshot" ((PVar "w")) (ETuple (EUnOp "!" (EFieldAccess (EVar "w") "items")) (EUnOp "!" (EFieldAccess (EVar "w") "n"))))
(DTypeSig true "wRestore" (TyFun (TyApp (TyCon "Windowed") (TyVar "a")) (TyFun (TyTuple (TyApp (TyCon "List") (TyVar "a")) (TyCon "Int")) (TyCon "Unit"))))
(DFunDef false "wRestore" ((PVar "w") (PVar "snap")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "w") "items")) (EApp (EVar "fst") (EVar "snap")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "w") "n")) (EApp (EVar "snd") (EVar "snap"))))))
(DTypeSig true "wPushAll" (TyFun (TyApp (TyCon "Windowed") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Unit"))))
(DFunDef false "wPushAll" (PWild (PList)) (ELit LUnit))
(DFunDef false "wPushAll" ((PVar "w") (PCons (PVar "x") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "wPush") (EVar "w")) (EVar "x"))) (DoExpr (EApp (EApp (EVar "wPushAll") (EVar "w")) (EVar "rest")))))
(DTypeSig true "emptyShadowDicts" (TyCon "ShadowDicts"))
(DFunDef false "emptyShadowDicts" () (ERecordCreate "ShadowDicts" ((fa "sdMonos" (EListLit)) (fa "sdIfaces" (EListLit)) (fa "sdArgVecs" (EListLit)))))
(DTypeSig false "freshCrossRun" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Scheme")) (TyCon "CrossRun")))
(DFunDef false "freshCrossRun" ((PVar "ctors")) (ERecordCreate "CrossRun" ((fa "universeFunNamesRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "universeMethodDispatchIdxByIdRef" (EApp (EVar "Ref") (EListLit))) (fa "universeDataCtors" (EApp (EVar "Ref") (EListLit))) (fa "universeCtorPop" (EApp (EVar "Ref") (EApp (EVar "spFromFloor") (EVar "ctors")))) (fa "universeRecordPop" (EApp (EVar "Ref") (EVar "spEmpty"))) (fa "builtinClassesRef" (EApp (EVar "Ref") (EVar "emptyBuiltinClasses"))) (fa "crossModuleFunPredicateSlotsRef" (EApp (EVar "Ref") (EListLit))) (fa "crossModuleFunPredicateSlotsQualRef" (EApp (EVar "Ref") (EListLit))) (fa "crossModuleFunConstraintDeclaredRef" (EApp (EVar "Ref") (EListLit))) (fa "crossModuleFunConstraintDeclaredQualRef" (EApp (EVar "Ref") (EListLit))) (fa "crossModuleMethodPredicateSlotsRef" (EApp (EVar "Ref") (EListLit))) (fa "crossModuleMethodPredicateSlotsQualRef" (EApp (EVar "Ref") (EListLit))) (fa "coreSchemeObligationsRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "crossModuleSchemeOblsQualRef" (EApp (EVar "Ref") (EListLit))))))
(DTypeSig true "mctxAt" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ModuleCtx") (TyCon "ModuleCtx"))))
(DFunDef false "mctxAt" ((PVar "loc") (PVar "mctx")) (EIf (EApp (EApp (EVar "sameSpan") (EVar "loc")) (EFieldAccess (EVar "mctx") "mcLoc")) (EVar "mctx") (ERecordUpdate (EVar "mctx") ((fa "mcLoc" (EVar "loc"))))))
(DTypeSig false "sameSpan" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Bool"))))
(DFunDef false "sameSpan" ((PCon "None") (PCon "None")) (EVar "True"))
(DFunDef false "sameSpan" ((PCon "Some" (PVar "a")) (PCon "Some" (PVar "b"))) (EApp (EApp (EVar "locEq") (EVar "a")) (EVar "b")))
(DFunDef false "sameSpan" ((PCon "None") (PCon "Some" PWild)) (EVar "False"))
(DFunDef false "sameSpan" ((PCon "Some" PWild) (PCon "None")) (EVar "False"))
(DTypeSig true "mctxAtIfSome" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ModuleCtx") (TyCon "ModuleCtx"))))
(DFunDef false "mctxAtIfSome" ((PCon "None") (PVar "mctx")) (EVar "mctx"))
(DFunDef false "mctxAtIfSome" ((PVar "loc") (PVar "mctx")) (EApp (EApp (EVar "mctxAt") (EVar "loc")) (EVar "mctx")))
(DTypeSig true "dynAt" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "DynCtx") (TyCon "DynCtx"))))
(DFunDef false "dynAt" ((PVar "loc") (PVar "dyn")) (EIf (EApp (EApp (EVar "sameSpan") (EVar "loc")) (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcLoc")) (EVar "dyn") (ERecordUpdate (EVar "dyn") ((fa "dcModule" (ERecordUpdate (EFieldAccess (EVar "dyn") "dcModule") ((fa "mcLoc" (EVar "loc")))))))))
(DTypeSig true "dynAtIfSome" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "DynCtx") (TyCon "DynCtx"))))
(DFunDef false "dynAtIfSome" ((PCon "None") (PVar "dyn")) (EVar "dyn"))
(DFunDef false "dynAtIfSome" ((PVar "loc") (PVar "dyn")) (EApp (EApp (EVar "dynAt") (EVar "loc")) (EVar "dyn")))
(DTypeSig true "envAt" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "TcEnv") (TyCon "TcEnv"))))
(DFunDef false "envAt" ((PVar "loc") (PVar "env")) (EIf (EApp (EApp (EVar "sameSpan") (EVar "loc")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcLoc")) (EVar "env") (ERecordUpdate (EVar "env") ((fa "teDyn" (ERecordUpdate (EFieldAccess (EVar "env") "teDyn") ((fa "dcModule" (ERecordUpdate (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") ((fa "mcLoc" (EVar "loc"))))))))))))
(DTypeSig true "envAtIfSome" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "TcEnv") (TyCon "TcEnv"))))
(DFunDef false "envAtIfSome" ((PCon "None") (PVar "env")) (EVar "env"))
(DFunDef false "envAtIfSome" ((PVar "loc") (PVar "env")) (EApp (EApp (EVar "envAt") (EVar "loc")) (EVar "env")))
(DTypeSig true "renderEvidenceBinder" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EvidenceBinderId") (TyCon "String"))))
(DFunDef false "renderEvidenceBinder" ((PVar "gctx") (PCon "EvidenceBinderId" (PVar "sid") (PVar "ordinal"))) (EMatch (EFieldAccess (EApp (EApp (EVar "Scopes.scopeFrame") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))) (EVar "sid")) "sfOwner") (arm (PCon "BindingOwner" (PVar "owner")) () (EApp (EApp (EVar "dictParamName") (EVar "owner")) (EVar "ordinal"))) (arm (PCon "LocalBindingOwner" (PVar "owner")) () (EApp (EApp (EVar "dictParamName") (EVar "owner")) (EVar "ordinal"))) (arm (PCon "DefaultBodyOwner" (PVar "owner")) () (EIf (EBinOp "==" (EVar "ordinal") (EVar "defaultReceiverOrdinal")) (EApp (EVar "defaultReceiverDict") (EFieldAccess (EVar "owner") "dbiMethod")) (EApp (EApp (EVar "dictParamName") (EFieldAccess (EVar "owner") "dbiMethod")) (EVar "ordinal")))) (arm PWild () (EApp (EVar "panic") (ELit (LString "evidence binder outside binding scope"))))))
(DTypeSig true "freshGraphRun" (TyFun (TyCon "Unit") (TyCon "GraphRun")))
(DFunDef false "freshGraphRun" (PWild) (ERecordCreate "GraphRun" ((fa "tyvarCounter" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "effvarCounter" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "ctorExistentialsRef" (EApp (EVar "Ref") (EVar "Tip"))) (fa "patternAuthIdsRef" (EApp (EVar "Ref") (EVar "Tip"))) (fa "anyExistentialsRef" (EApp (EVar "Ref") (EVar "False"))) (fa "goals" (EApp (EVar "Ref") (EListLit))) (fa "numlitRefs" (EApp (EVar "Ref") (EListLit))) (fa "numlitN" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "activeDictVars" (EApp (EVar "Ref") (EListLit))) (fa "gGiven" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "moduleRanges" (EApp (EVar "Ref") (EListLit))) (fa "stampCtxs" (EApp (EVar "Ref") (EListLit))) (fa "goalsN" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "evCounter" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "evBase" (ELit (LInt 0))) (fa "evJudged" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "evScopedJudged" (EApp (EVar "Ref") (EListLit))) (fa "evTable" (EApp (EVar "Ref") (EListLit))) (fa "evCells" (EApp (EVar "Ref") (EApp (EApp (EVar "arrayMake") (ELit (LInt 0))) (EVar "None")))) (fa "siteCells" (EApp (EVar "Ref") (EApp (EApp (EVar "arrayMake") (ELit (LInt 0))) (EVar "None")))) (fa "scopeStore" (EApp (EVar "Scopes.freshScopeStore") (ELit LUnit))) (fa "localAbs" (EApp (EVar "freshLocalAbsState") (ELit LUnit))) (fa "grants" (EApp (EVar "freshGrantState") (ELit LUnit))) (fa "binderPending" (EApp (EVar "Ref") (EListLit))) (fa "binderRows" (EApp (EVar "Ref") (EVar "emptyBinderTypes"))) (fa "liveRoots" (EApp (EVar "Ref") (EListLit))) (fa "liveNumRoots" (EApp (EVar "Ref") (EListLit))) (fa "liveNumGoals" (EApp (EVar "Ref") (EListLit))) (fa "liveGoals" (EApp (EVar "Ref") (EListLit))))))
(DTypeSig true "currentScopeStore" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyCon "ScopeStore"))))
(DFunDef false "currentScopeStore" ((PVar "gctx") PWild) (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "scopeStore"))
(DTypeSig true "graphLineageRun" (TyFun (TyCon "Lineage") (TyCon "GraphRun")))
(DFunDef false "graphLineageRun" ((PVar "lineage")) (EBlock (DoLet false false (PVar "n") (EFieldAccess (EFieldAccess (EVar "lineage") "lnEvCounter") "value")) (DoLet false false (PVar "base") (EVar "n")) (DoLet false false (PVar "localAbs") (EFieldAccess (EVar "lineage") "lnLocalAbs")) (DoLet false false (PVar "grants") (EFieldAccess (EVar "lineage") "lnGrants")) (DoLet false false (PVar "fresh") (EApp (EVar "freshGraphRun") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "fresh") "evCounter")) (EVar "n"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "fresh") "evJudged")) (EVar "base"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "localAbs") "lasQuantified")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "grants") "gsSourceless")) (EVar "Tip"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "grants") "gsBodies")) (EVar "Tip"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "grants") "gsBounds")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "grants") "gsValueBounds")) (EVar "omEmpty"))) (DoExpr (EVariantUpdate "GraphRun" (EVar "fresh") ((fa "localAbs" (EVar "localAbs")) (fa "grants" (EVar "grants")) (fa "evBase" (EVar "base")))))))
(DTypeSig true "freshModuleCtx" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "CheckRunSeed") (TyFun (TyCon "String") (TyCon "ModuleCtx")))))
(DFunDef false "freshModuleCtx" ((PVar "gctx") (PVar "seed") (PVar "mid")) (ERecordCreate "ModuleCtx" ((fa "mcCells" (EApp (EApp (EVar "freshModuleCells") (EVar "seed")) (EVar "mid"))) (fa "mcGraph" (EVar "gctx")) (fa "mcLoc" (EVar "None")))))
(DTypeSig false "freshModuleCells" (TyFun (TyCon "CheckRunSeed") (TyFun (TyCon "String") (TyCon "ModuleCells"))))
(DFunDef false "freshModuleCells" ((PVar "seed") (PVar "mid")) (ERecordCreate "ModuleCells" ((fa "currentScope" (EApp (EVar "Ref") (EVar "ScopeClosed"))) (fa "admittedOccObls" (EApp (EVar "Ref") (EListLit))) (fa "curEffect" (EApp (EVar "Ref") (EListLit))) (fa "effectSummaries" (EApp (EVar "EffectSolver.newSolver") (ELit LUnit))) (fa "pendingJoinsRef" (EApp (EVar "Ref") (EListLit))) (fa "fileValueFlows" (EApp (EVar "wNew") (ELit LUnit))) (fa "fileValueScopes" (EApp (EVar "Ref") (EListLit))) (fa "rigidEffvarsRef" (EApp (EVar "Ref") (EVar "Tip"))) (fa "rigidAuthvarsRef" (EApp (EVar "Ref") (EVar "Tip"))) (fa "effectSitesRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "rowFailureReportedRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "typeErrorKeySetRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "escapedExistentialsRef" (EApp (EVar "Ref") (EVar "Tip"))) (fa "openedAuthvarsRef" (EApp (EVar "Ref") (EVar "Tip"))) (fa "indexSubstitutedRef" (EApp (EVar "Ref") (EVar "Tip"))) (fa "extendedBindersRef" (EApp (EVar "Ref") (EVar "Tip"))) (fa "displayHiddenBindersRef" (EApp (EVar "Ref") (EVar "Tip"))) (fa "openedExistentialsRef" (EApp (EVar "Ref") (EListLit))) (fa "openedExistentialsStackRef" (EApp (EVar "Ref") (EListLit))) (fa "recordByNameRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "fieldOwnersRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "dataParamKindsRef" (EApp (EVar "Ref") (EListLit))) (fa "dataParamNameIndexRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "dataParamPolarityRef" (EApp (EVar "Ref") (EListLit))) (fa "dataParamRowAtomsRef" (EApp (EVar "Ref") (EListLit))) (fa "aliasTableRef" (EApp (EVar "Ref") (EListLit))) (fa "numLitFromIntAnchorRef" (EApp (EVar "Ref") (EVar "None"))) (fa "definerShadowNamesRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "definerShadowSigsRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "bodyImplEnvRef" (EApp (EVar "Ref") (EVar "emptyImplEnv"))) (fa "methodAliasEntriesRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "methodScopeCtxRef" (EApp (EVar "Ref") (EVar "None"))) (fa "methodScopeMemoRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "aliasMethodOriginsRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "implObls" (EApp (EVar "wNew") (ELit LUnit))) (fa "poisonedVars" (EApp (EVar "Ref") (EListLit))) (fa "deferrableVarIds" (EApp (EVar "Ref") (EVar "Tip"))) (fa "liveMemberMonosRef" (EApp (EVar "Ref") (EListLit))) (fa "quiescentGoalsRef" (EApp (EVar "Ref") (EListLit))) (fa "heldLiveGoalsRef" (EApp (EVar "Ref") (EListLit))) (fa "determinedRowsRef" (EApp (EVar "Ref") (EVar "Tip"))) (fa "declaredSigVarIds" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "tupleCallCandidates" (EApp (EVar "Ref") (EListLit))) (fa "numlitVarLocs" (EApp (EVar "Ref") (EListLit))) (fa "numlitRanges" (EApp (EVar "Ref") (EListLit))) (fa "wideLitRanges" (EApp (EVar "Ref") (EListLit))) (fa "patLitPending" (EApp (EVar "Ref") (EListLit))) (fa "patLitDeferred" (EApp (EVar "Ref") (EListLit))) (fa "matchChecksDeferred" (EApp (EVar "Ref") (EListLit))) (fa "numlitUntainted" (EApp (EVar "Ref") (EListLit))) (fa "numlitOpLocs" (EApp (EVar "Ref") (EListLit))) (fa "numlitCtxTags" (EApp (EVar "Ref") (EListLit))) (fa "localBindRefs" (EApp (EVar "Ref") (EListLit))) (fa "localSchemesOut" (EApp (EVar "Ref") (EListLit))) (fa "seedSchemesOut" (EApp (EVar "Ref") (EListLit))) (fa "funPredicateSlotsRef" (EApp (EVar "Ref") (EListLit))) (fa "funPredicateSlotsIdxRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "funConstraintDeclaredRef" (EApp (EVar "Ref") (EListLit))) (fa "currentImportDefinersRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "currentImportOriginsRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "importedSchemeOblsRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "obls" (EApp (EVar "wNew") (ELit LUnit))) (fa "absorptions" (EApp (EVar "wNew") (ELit LUnit))) (fa "schemeObligationsRef" (EApp (EVar "Ref") (EListLit))) (fa "schemeDefIdsRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "methodPredicateSlotsRef" (EApp (EVar "Ref") (EListLit))) (fa "currentFn" (EApp (EVar "Ref") (ELit (LString "")))) (fa "currentImplBody" (EApp (EVar "Ref") (EVar "False"))) (fa "methodSiteFns" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "dictAppFns" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "residualUnivRef" (EApp (EVar "Ref") (EVar "emptyImplUniverse"))) (fa "promotedRef" (EApp (EVar "Ref") (EListLit))) (fa "fieldOwnerModulesRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "fieldOwnerReachRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "typeErrors" (EApp (EVar "wNew") (ELit LUnit))) (fa "typeErrorMsgSetRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "ambiguitySitesRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "ambiguityVarsRef" (EApp (EVar "Ref") (EVar "Tip"))) (fa "errorsDetected" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "occursCheckFailed" (EApp (EVar "Ref") (EVar "False"))) (fa "currentLevel" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "markingRef" (EApp (EVar "Ref") (EVar "None"))) (fa "superDeclsRef" (EApp (EVar "Ref") (EListLit))) (fa "standaloneValuesRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "methodDispatchIdxByIdRef" (EApp (EVar "Ref") (EListLit))) (fa "matchOracle" (EApp (EVar "Ref") (EFieldAccess (EVar "seed") "crsOracle"))) (fa "matchWarnings" (EApp (EVar "Ref") (EFieldAccess (EVar "seed") "crsWarnings"))) (fa "sigNameSetRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "sigTyMapRef" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "currentModuleRef" (EApp (EVar "Ref") (EVar "mid"))) (fa "invocationViewRef" (EApp (EVar "Ref") (EApp (EApp (EApp (EVar "InvocationView") (EListLit)) (EListLit)) (EListLit)))) (fa "ownPopsRef" (EApp (EVar "Ref") (ETuple (EVar "spEmpty") (EVar "spEmpty")))))))
(DTypeSig true "initialModuleCtx" (TyFun (TyCon "GraphCtx") (TyCon "ModuleCtx")))
(DFunDef false "initialModuleCtx" ((PVar "gctx")) (EApp (EApp (EVar "blankModuleCtx") (EVar "gctx")) (ELit (LString ""))))
(DTypeSig true "blankModuleCtx" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyCon "ModuleCtx"))))
(DFunDef false "blankModuleCtx" ((PVar "gctx") (PVar "mid")) (EApp (EApp (EApp (EVar "freshModuleCtx") (EVar "gctx")) (ERecordCreate "CheckRunSeed" ((fa "crsOracle" (EVar "emptyOracle")) (fa "crsWarnings" (EListLit))))) (EVar "mid")))
(DTypeSig false "emptyOracle" (TyCon "Oracle"))
(DFunDef false "emptyOracle" () (EApp (EVar "buildOracle") (EListLit)))
(DTypeSig true "moduleCtxFrom" (TyFun (TyCon "Bool") (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ModuleCtx") (TyCon "ModuleCtx")))))))
(DFunDef false "moduleCtxFrom" ((PVar "detach") (PVar "run") (PVar "tables") (PVar "drain") (PVar "ident")) (ERecordCreate "ModuleCtx" ((fa "mcCells" (EApp (EApp (EApp (EApp (EApp (EVar "moduleCellsFrom") (EVar "detach")) (EFieldAccess (EVar "run") "mcCells")) (EFieldAccess (EVar "tables") "mcCells")) (EFieldAccess (EVar "drain") "mcCells")) (EFieldAccess (EVar "ident") "mcCells"))) (fa "mcGraph" (EFieldAccess (EVar "run") "mcGraph")) (fa "mcLoc" (EFieldAccess (EVar "run") "mcLoc")))))
(DTypeSig false "moduleCellsFrom" (TyFun (TyCon "Bool") (TyFun (TyCon "ModuleCells") (TyFun (TyCon "ModuleCells") (TyFun (TyCon "ModuleCells") (TyFun (TyCon "ModuleCells") (TyCon "ModuleCells")))))))
(DFunDef false "moduleCellsFrom" ((PVar "detach") (PVar "run") (PVar "tables") (PVar "drain") (PVar "ident")) (ERecordCreate "ModuleCells" ((fa "currentScope" (EFieldAccess (EVar "run") "currentScope")) (fa "admittedOccObls" (EFieldAccess (EVar "run") "admittedOccObls")) (fa "curEffect" (EFieldAccess (EVar "run") "curEffect")) (fa "effectSummaries" (EFieldAccess (EVar "run") "effectSummaries")) (fa "pendingJoinsRef" (EFieldAccess (EVar "run") "pendingJoinsRef")) (fa "fileValueFlows" (EFieldAccess (EVar "run") "fileValueFlows")) (fa "fileValueScopes" (EFieldAccess (EVar "run") "fileValueScopes")) (fa "rigidEffvarsRef" (EFieldAccess (EVar "run") "rigidEffvarsRef")) (fa "rigidAuthvarsRef" (EFieldAccess (EVar "run") "rigidAuthvarsRef")) (fa "effectSitesRef" (EFieldAccess (EVar "run") "effectSitesRef")) (fa "rowFailureReportedRef" (EFieldAccess (EVar "run") "rowFailureReportedRef")) (fa "typeErrorKeySetRef" (EFieldAccess (EVar "run") "typeErrorKeySetRef")) (fa "escapedExistentialsRef" (EFieldAccess (EVar "run") "escapedExistentialsRef")) (fa "openedAuthvarsRef" (EFieldAccess (EVar "run") "openedAuthvarsRef")) (fa "indexSubstitutedRef" (EFieldAccess (EVar "run") "indexSubstitutedRef")) (fa "extendedBindersRef" (EFieldAccess (EVar "run") "extendedBindersRef")) (fa "displayHiddenBindersRef" (EFieldAccess (EVar "run") "displayHiddenBindersRef")) (fa "openedExistentialsRef" (EFieldAccess (EVar "run") "openedExistentialsRef")) (fa "openedExistentialsStackRef" (EFieldAccess (EVar "run") "openedExistentialsStackRef")) (fa "recordByNameRef" (EFieldAccess (EVar "run") "recordByNameRef")) (fa "fieldOwnersRef" (EFieldAccess (EVar "run") "fieldOwnersRef")) (fa "dataParamKindsRef" (EFieldAccess (EVar "run") "dataParamKindsRef")) (fa "dataParamNameIndexRef" (EFieldAccess (EVar "run") "dataParamNameIndexRef")) (fa "dataParamPolarityRef" (EFieldAccess (EVar "run") "dataParamPolarityRef")) (fa "dataParamRowAtomsRef" (EFieldAccess (EVar "run") "dataParamRowAtomsRef")) (fa "aliasTableRef" (EFieldAccess (EVar "run") "aliasTableRef")) (fa "numLitFromIntAnchorRef" (EFieldAccess (EVar "run") "numLitFromIntAnchorRef")) (fa "definerShadowNamesRef" (EFieldAccess (EVar "run") "definerShadowNamesRef")) (fa "definerShadowSigsRef" (EFieldAccess (EVar "run") "definerShadowSigsRef")) (fa "bodyImplEnvRef" (EFieldAccess (EVar "run") "bodyImplEnvRef")) (fa "methodAliasEntriesRef" (EFieldAccess (EVar "run") "methodAliasEntriesRef")) (fa "methodScopeCtxRef" (EFieldAccess (EVar "run") "methodScopeCtxRef")) (fa "methodScopeMemoRef" (EFieldAccess (EVar "run") "methodScopeMemoRef")) (fa "aliasMethodOriginsRef" (EFieldAccess (EVar "run") "aliasMethodOriginsRef")) (fa "implObls" (EFieldAccess (EVar "run") "implObls")) (fa "poisonedVars" (EFieldAccess (EVar "run") "poisonedVars")) (fa "deferrableVarIds" (EFieldAccess (EVar "run") "deferrableVarIds")) (fa "liveMemberMonosRef" (EFieldAccess (EVar "run") "liveMemberMonosRef")) (fa "quiescentGoalsRef" (EFieldAccess (EVar "run") "quiescentGoalsRef")) (fa "heldLiveGoalsRef" (EFieldAccess (EVar "run") "heldLiveGoalsRef")) (fa "determinedRowsRef" (EFieldAccess (EVar "run") "determinedRowsRef")) (fa "declaredSigVarIds" (EFieldAccess (EVar "run") "declaredSigVarIds")) (fa "tupleCallCandidates" (EFieldAccess (EVar "run") "tupleCallCandidates")) (fa "numlitVarLocs" (EFieldAccess (EVar "run") "numlitVarLocs")) (fa "patLitPending" (EFieldAccess (EVar "run") "patLitPending")) (fa "patLitDeferred" (EFieldAccess (EVar "run") "patLitDeferred")) (fa "matchChecksDeferred" (EFieldAccess (EVar "run") "matchChecksDeferred")) (fa "numlitRanges" (EFieldAccess (EVar "run") "numlitRanges")) (fa "wideLitRanges" (EFieldAccess (EVar "run") "wideLitRanges")) (fa "numlitUntainted" (EFieldAccess (EVar "run") "numlitUntainted")) (fa "numlitOpLocs" (EFieldAccess (EVar "run") "numlitOpLocs")) (fa "numlitCtxTags" (EFieldAccess (EVar "run") "numlitCtxTags")) (fa "localBindRefs" (EFieldAccess (EVar "run") "localBindRefs")) (fa "localSchemesOut" (EFieldAccess (EVar "run") "localSchemesOut")) (fa "seedSchemesOut" (EFieldAccess (EVar "run") "seedSchemesOut")) (fa "funPredicateSlotsRef" (EFieldAccess (EVar "run") "funPredicateSlotsRef")) (fa "funPredicateSlotsIdxRef" (EFieldAccess (EVar "run") "funPredicateSlotsIdxRef")) (fa "funConstraintDeclaredRef" (EFieldAccess (EVar "run") "funConstraintDeclaredRef")) (fa "currentImportDefinersRef" (EFieldAccess (EVar "run") "currentImportDefinersRef")) (fa "currentImportOriginsRef" (EFieldAccess (EVar "run") "currentImportOriginsRef")) (fa "importedSchemeOblsRef" (EFieldAccess (EVar "run") "importedSchemeOblsRef")) (fa "obls" (EFieldAccess (EVar "run") "obls")) (fa "absorptions" (EFieldAccess (EVar "run") "absorptions")) (fa "schemeObligationsRef" (EFieldAccess (EVar "run") "schemeObligationsRef")) (fa "schemeDefIdsRef" (EFieldAccess (EVar "run") "schemeDefIdsRef")) (fa "methodPredicateSlotsRef" (EFieldAccess (EVar "run") "methodPredicateSlotsRef")) (fa "currentFn" (EFieldAccess (EVar "run") "currentFn")) (fa "currentImplBody" (EFieldAccess (EVar "run") "currentImplBody")) (fa "methodSiteFns" (EFieldAccess (EVar "run") "methodSiteFns")) (fa "dictAppFns" (EFieldAccess (EVar "run") "dictAppFns")) (fa "residualUnivRef" (EFieldAccess (EVar "run") "residualUnivRef")) (fa "promotedRef" (EFieldAccess (EVar "run") "promotedRef")) (fa "fieldOwnerModulesRef" (EFieldAccess (EVar "run") "fieldOwnerModulesRef")) (fa "fieldOwnerReachRef" (EFieldAccess (EVar "run") "fieldOwnerReachRef")) (fa "typeErrors" (EFieldAccess (EVar "run") "typeErrors")) (fa "typeErrorMsgSetRef" (EFieldAccess (EVar "run") "typeErrorMsgSetRef")) (fa "ambiguitySitesRef" (EFieldAccess (EVar "run") "ambiguitySitesRef")) (fa "ambiguityVarsRef" (EFieldAccess (EVar "run") "ambiguityVarsRef")) (fa "errorsDetected" (EFieldAccess (EVar "run") "errorsDetected")) (fa "occursCheckFailed" (EFieldAccess (EVar "run") "occursCheckFailed")) (fa "currentLevel" (EFieldAccess (EVar "run") "currentLevel")) (fa "markingRef" (EFieldAccess (EVar "run") "markingRef")) (fa "ownPopsRef" (EFieldAccess (EVar "run") "ownPopsRef")) (fa "superDeclsRef" (EApp (EApp (EVar "refFrom") (EVar "detach")) (EFieldAccess (EVar "tables") "superDeclsRef"))) (fa "sigNameSetRef" (EApp (EApp (EVar "refFrom") (EVar "detach")) (EFieldAccess (EVar "tables") "sigNameSetRef"))) (fa "sigTyMapRef" (EApp (EApp (EVar "refFrom") (EVar "detach")) (EFieldAccess (EVar "tables") "sigTyMapRef"))) (fa "matchOracle" (EApp (EApp (EVar "refFrom") (EVar "detach")) (EFieldAccess (EVar "tables") "matchOracle"))) (fa "matchWarnings" (EApp (EApp (EVar "refFrom") (EVar "detach")) (EFieldAccess (EVar "tables") "matchWarnings"))) (fa "standaloneValuesRef" (EApp (EApp (EVar "refFrom") (EVar "detach")) (EFieldAccess (EVar "drain") "standaloneValuesRef"))) (fa "methodDispatchIdxByIdRef" (EApp (EApp (EVar "refFrom") (EVar "detach")) (EFieldAccess (EVar "drain") "methodDispatchIdxByIdRef"))) (fa "currentModuleRef" (EApp (EApp (EVar "refFrom") (EVar "detach")) (EFieldAccess (EVar "ident") "currentModuleRef"))) (fa "invocationViewRef" (EApp (EApp (EVar "refFrom") (EVar "detach")) (EFieldAccess (EVar "ident") "invocationViewRef"))))))
(DTypeSig false "refFrom" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Ref") (TyVar "a")) (TyApp (TyCon "Ref") (TyVar "a")))))
(DFunDef false "refFrom" ((PVar "detach") (PVar "r")) (EIf (EVar "detach") (EApp (EVar "Ref") (EFieldAccess (EVar "r") "value")) (EVar "r")))
(DTypeSig true "carryModuleCtx" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ModuleCtx") (TyCon "ModuleCtx"))))
(DFunDef false "carryModuleCtx" ((PVar "gctx") (PVar "m")) (EApp (EApp (EApp (EApp (EApp (EVar "moduleCtxFrom") (EVar "True")) (EApp (EVar "initialModuleCtx") (EVar "gctx"))) (EVar "m")) (EVar "m")) (EVar "m")))
(DTypeSig true "emptySigVars" (TyCon "SigVars"))
(DFunDef false "emptySigVars" () (ERecordCreate "SigVars" ((fa "svRows" (EListLit)) (fa "svAuths" (EListLit)))))
(DTypeSig false "freshLocalAbsState" (TyFun (TyCon "Unit") (TyCon "LocalAbsState")))
(DFunDef false "freshLocalAbsState" (PWild) (ERecordCreate "LocalAbsState" ((fa "lasBinders" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "lasRecOccs" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "lasNext" (EApp (EVar "Ref") (ETuple (ELit (LString "")) (ELit (LInt 0))))) (fa "lasMinted" (EApp (EVar "Ref") (EListLit))) (fa "lasQuantified" (EApp (EVar "Ref") (EVar "omEmpty"))))))
(DTypeSig false "freshGrantState" (TyFun (TyCon "Unit") (TyCon "GrantState")))
(DFunDef false "freshGrantState" (PWild) (ERecordCreate "GrantState" ((fa "gsOccs" (EApp (EVar "Ref") (EVar "Tip"))) (fa "gsGrantOnly" (EApp (EVar "Ref") (EVar "Tip"))) (fa "gsTopIds" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "gsLocalIds" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "gsMethods" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "gsBodies" (EApp (EVar "Ref") (EVar "Tip"))) (fa "gsLastInst" (EApp (EVar "Ref") (EVar "None"))) (fa "gsLastMethodInst" (EApp (EVar "Ref") (EVar "None"))) (fa "gsLastStandalone" (EApp (EVar "Ref") (EVar "None"))) (fa "gsSourceless" (EApp (EVar "Ref") (EVar "Tip"))) (fa "gsTakers" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "gsFresh" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "gsBounds" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "gsValueBounds" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "gsPassingModule" (EApp (EVar "Ref") (ELit (LString "")))))))
(DTypeSig true "emptyBuiltinClasses" (TyCon "BuiltinClasses"))
(DFunDef false "emptyBuiltinClasses" () (ERecordCreate "BuiltinClasses" ((fa "bcNum" (EVar "OriginUnresolved")) (fa "bcEq" (EVar "OriginUnresolved")) (fa "bcOrd" (EVar "OriginUnresolved")) (fa "bcSemigroup" (EVar "OriginUnresolved")) (fa "bcNumPresent" (EVar "False")) (fa "bcEqPresent" (EVar "False")) (fa "bcOrdPresent" (EVar "False")) (fa "bcSemigroupPresent" (EVar "False")) (fa "bcPreludeSeeded" (EVar "False")))))
(DTypeSig true "takeFirst" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "takeFirst" ((PVar "n") PWild) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "takeFirst" (PWild (PList)) (EListLit))
(DFunDef false "takeFirst" ((PVar "n") (PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "takeFirst") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "xs"))))
(DTypeSig true "dictParamName" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "dictParamName" ((PVar "fn") (PVar "slot")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "$dict_")) (EApp (EMethodRef "display") (EVar "fn"))) (ELit (LString "_"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "slot")))) (ELit (LString ""))))
(DTypeSig true "defaultReceiverOrdinal" (TyCon "Int"))
(DFunDef false "defaultReceiverOrdinal" () (EUnOp "-" (ELit (LInt 1))))
(DTypeSig true "emptyImplUniverse" (TyCon "ImplUniverse"))
(DFunDef false "emptyImplUniverse" () (EApp (EApp (EVar "ImplUniverse") (EVar "mregEmpty")) (EVar "mregEmpty")))
(DTypeSig true "builtinCtors" (TyApp (TyCon "OrdMap") (TyCon "Scheme")))
(DFunDef false "builtinCtors" () (EApp (EApp (EApp (EVar "omInsert") (ELit (LString "True"))) (EApp (EVar "monoScheme") (EApp (EVar "tconBuiltin") (ELit (LString "Bool"))))) (EApp (EApp (EApp (EVar "omInsert") (ELit (LString "False"))) (EApp (EVar "monoScheme") (EApp (EVar "tconBuiltin") (ELit (LString "Bool"))))) (EVar "omEmpty"))))
(DTypeSig true "mintGraphCtx" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyCon "GraphCtx"))))
(DFunDef false "mintGraphCtx" ((PVar "inputs") (PVar "admitted")) (EBlock (DoLet false false (PVar "carried") (EFieldAccess (EVar "interners") "value")) (DoLet false false (PVar "base") (EApp (EApp (EVar "initialGraphCtx") (EVar "builtinCtors")) (EApp (EVar "graphLineageRun") (EFieldAccess (EVar "carried") "lineage")))) (DoLet false false (PVar "gctx") (EVariantUpdate "GraphCtx" (EVar "base") ((fa "trace" (EFieldAccess (EVar "inputs") "diTrace")) (fa "graphAdmittedMethodsRef" (EApp (EVar "Ref") (EVar "admitted"))) (fa "builtinExternNamesRef" (EFieldAccess (EVar "carried") "externCatalog"))))) (DoExpr (EApp (EVar "noteInterners") (EVar "gctx"))) (DoExpr (EVar "gctx"))))
(DTypeSig false "offTraceSink" (TyFun (TyCon "Unit") (TyCon "TraceSink")))
(DFunDef false "offTraceSink" (PWild) (ERecordCreate "TraceSink" ((fa "tsAssumptionEnabled" (EVar "False")) (fa "tsAssumptionEntries" (EApp (EVar "Ref") (EListLit))) (fa "tsNumericPredicateEnabled" (EVar "False")) (fa "tsNumericPredicateEntries" (EApp (EVar "Ref") (EListLit))) (fa "tsMethodReturnEnabled" (EVar "False")) (fa "tsMethodReturnEntries" (EApp (EVar "Ref") (EListLit))) (fa "tsEvidenceObservationEnabled" (EVar "False")) (fa "tsEvidenceObservationEntries" (EApp (EVar "Ref") (EListLit))))))
(DTypeSig true "beginAssumptionTrace" (TyFun (TyCon "Unit") (TyCon "TraceSink")))
(DFunDef false "beginAssumptionTrace" (PWild) (ERecordUpdate (EApp (EVar "offTraceSink") (ELit LUnit)) ((fa "tsAssumptionEnabled" (EVar "True")))))
(DTypeSig true "finishAssumptionTrace" (TyFun (TyCon "TraceSink") (TyApp (TyCon "List") (TyCon "AssumptionTraceEntry"))))
(DFunDef false "finishAssumptionTrace" ((PVar "sink")) (EApp (EVar "reverseL") (EFieldAccess (EFieldAccess (EVar "sink") "tsAssumptionEntries") "value")))
(DTypeSig true "beginNumericPredicateTrace" (TyFun (TyCon "Unit") (TyCon "TraceSink")))
(DFunDef false "beginNumericPredicateTrace" (PWild) (ERecordUpdate (EApp (EVar "offTraceSink") (ELit LUnit)) ((fa "tsNumericPredicateEnabled" (EVar "True")))))
(DTypeSig true "finishNumericPredicateTrace" (TyFun (TyCon "TraceSink") (TyApp (TyCon "List") (TyCon "NumericPredicateTraceEntry"))))
(DFunDef false "finishNumericPredicateTrace" ((PVar "sink")) (EApp (EVar "reverseL") (EFieldAccess (EFieldAccess (EVar "sink") "tsNumericPredicateEntries") "value")))
(DTypeSig true "beginMethodReturnTrace" (TyFun (TyCon "Unit") (TyCon "TraceSink")))
(DFunDef false "beginMethodReturnTrace" (PWild) (ERecordUpdate (EApp (EVar "offTraceSink") (ELit LUnit)) ((fa "tsMethodReturnEnabled" (EVar "True")))))
(DTypeSig true "beginEvidenceObservation" (TyFun (TyCon "Unit") (TyCon "TraceSink")))
(DFunDef false "beginEvidenceObservation" (PWild) (ERecordUpdate (EApp (EVar "offTraceSink") (ELit LUnit)) ((fa "tsEvidenceObservationEnabled" (EVar "True")))))
(DTypeSig true "finishEvidenceObservation" (TyFun (TyCon "TraceSink") (TyApp (TyCon "List") (TyCon "EvidenceObservationEntry"))))
(DFunDef false "finishEvidenceObservation" ((PVar "sink")) (EApp (EVar "reverseL") (EFieldAccess (EFieldAccess (EVar "sink") "tsEvidenceObservationEntries") "value")))
(DTypeSig true "evCellsSpanProbe" (TyFun (TyCon "GraphCtx") (TyCon "Int")))
(DFunDef false "evCellsSpanProbe" ((PVar "gctx")) (EApp (EVar "arrayLength") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "evCells") "value")))
(DTypeSig true "scopeTraceContext" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ScopeId") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "scopeTraceContext" ((PVar "gctx") (PVar "sid")) (EApp (EApp (EVar "Scopes.scopeTraceContext") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))) (EVar "sid")))
(DTypeSig true "scopeFrameStats" (TyFun (TyCon "GraphCtx") (TyTuple (TyCon "Int") (TyCon "Int"))))
(DFunDef false "scopeFrameStats" ((PVar "gctx")) (EApp (EVar "Scopes.scopeFrameStats") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))))
(DTypeSig false "defaultBodyBinderNamesProbe" (TyFun (TyCon "Unit") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "defaultBodyBinderNamesProbe" (PWild) (EBlock (DoLet false false (PVar "gctx") (EApp (EVar "probeGraphCtx") (ELit LUnit))) (DoLet false false (PVar "iface") (ERecordCreate "IfaceRef" ((fa "irName" (ELit (LString "Supply"))) (fa "irOrigin" (EApp (EVar "OriginModule") (ELit (LString "owner-module"))))))) (DoLet false false (PVar "owner") (ERecordCreate "DefaultBodyIdentity" ((fa "dbiIface" (EVar "iface")) (fa "dbiMethod" (ELit (LString "copy")))))) (DoLet false false (PVar "store") (EApp (EApp (EVar "currentScopeStore") (EVar "gctx")) (ELit LUnit))) (DoLet false false (PVar "root") (EApp (EApp (EApp (EApp (EApp (EVar "Scopes.freshScope") (EVar "store")) (EVar "None")) (ELit (LInt 0))) (ELit (LString "owner-module"))) (EVar "ModuleOwner"))) (DoLet false false (PVar "body") (EApp (EApp (EApp (EApp (EApp (EVar "Scopes.freshScope") (EVar "store")) (EApp (EVar "Some") (EVar "root"))) (ELit (LInt 1))) (ELit (LString "owner-module"))) (EApp (EVar "DefaultBodyOwner") (EVar "owner")))) (DoLet false false (PVar "rendered") (EListLit (EApp (EApp (EVar "renderEvidenceBinder") (EVar "gctx")) (EApp (EApp (EVar "Scopes.binderAt") (EVar "body")) (ELit (LInt 0)))) (EApp (EApp (EVar "renderEvidenceBinder") (EVar "gctx")) (EApp (EApp (EVar "Scopes.binderAt") (EVar "body")) (ELit (LInt 1)))) (EApp (EApp (EVar "renderEvidenceBinder") (EVar "gctx")) (EApp (EApp (EVar "Scopes.binderAt") (EVar "body")) (EVar "defaultReceiverOrdinal"))))) (DoExpr (EVar "rendered"))))
